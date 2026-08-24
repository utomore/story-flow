-- | SQLite 索引的 schema 與連線開啟(graph-core\/F005、擴充自 graph-core\/F006)。
--
-- ADR-013\/ADR-002:索引是__衍生物__,任何時候可以刪掉重建。'schemaVersion' 與
-- @meta_info@ 裡記的值不符時,'openIndexAt' 直接把所有表砍掉重建——schema
-- 變更不寫遷移程式。
--
-- graph-core\/F006 把業務表(@nodes@ 等 11 張)接上,'schemaVersion' 因此從
-- F005 的 1 改成 2(shape 變了,依 ADR-013 不寫 migration)。擴充
-- 'indexTables'\/'schemaDDL' 時繼續在這份清單上加,不另開一份。
--
-- graph-core\/F007 再加三張 FTS 相關的表(@fts_tri@ \/ @fts_cjk@ \/ @fts_map@)
-- 與一個觸發器,'schemaVersion' 因此 2 → 3。__ADR-016 第四條__:切詞規則
-- ("Aapms.Store.Tokenize")改版一樣只 bump 這個數字讓索引整庫重建,不遷移。
--
-- 兩張 FTS 表的__列維護__也住在本模組('insertFtsRows'):FTS5 虛擬表沒有外鍵,
-- 是整份 schema 裡唯一不能靠 @files@ → @nodes@ 的級聯自動清乾淨的東西,而
-- @fts_map@ 的刪除觸發器(建在本模組的 DDL 裡)正是補上那條級聯的機制;
-- 宣告表結構的人一併負責它的列生命週期,兩者分家就會漂移。
module Aapms.Store.Schema
  ( -- * VaultKind
    VaultKind (..)
  , renderVaultKind
  , parseVaultKind

    -- * 版本
  , schemaVersion

    -- * 索引問題回報
  , IndexIssue (..)
  , renderIndexIssue

    -- * 連線
  , openIndexAt
  , closeIndex

    -- * Schema
  , createSchema
  , resetSchema
  , currentVersion
  , indexTables

    -- * 連線知道自己屬於哪個 Vault
  , setVaultInfo

    -- * FTS 列維護(graph-core\/F007)
  , insertFtsRows
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Asset (LogicalName (..))
import Aapms.Core.Id (Id, VaultId (..), renderId)
import Aapms.Core.Meta (MetaWarning (..), TypeKey (..))
import Aapms.Core.Tree (TreeError, renderTreeError)
import Aapms.Md.Error (MdError, renderMdError)
import Aapms.Store.Error (StoreError, trySqlite)
import Aapms.Store.Tokenize (FtsRow)

-- | 一個 vault 主要裝什麼(ADR-017)。運維分界,不是資料模型分界。
data VaultKind = AssetVault | StoryVault
  deriving stock (Show, Eq)

renderVaultKind :: VaultKind -> Text
renderVaultKind AssetVault = "asset"
renderVaultKind StoryVault = "story"

-- | 只認 @"asset"@\/@"story"@,其餘一律 'Nothing'。
parseVaultKind :: Text -> Maybe VaultKind
parseVaultKind "asset" = Just AssetVault
parseVaultKind "story" = Just StoryVault
parseVaultKind _ = Nothing

-- | graph-core\/F006 把業務表接上,shape 變了(1 → 2);graph-core\/F007 再加
-- 兩張 FTS5 虛擬表與 @fts_map@(2 → 3)。依 ADR-013 \/ ADR-016 第四條,舊索引
-- 一律視為需要重建,不寫 migration——__切詞規則改版也只 bump 這個數字__。
schemaVersion :: Int
schemaVersion = 3

-- | 索引重建\/索引時回報的問題。graph-core\/F005 只有 'SchemaRebuilt';
-- graph-core\/F006__擴充__加三個建構子(不重新定義,契約 G「骨架」原則):
-- 單檔解析\/驗證失敗時「整檔不進索引」的三種理由。
data IndexIssue
  = SchemaRebuilt
      { irOldVersion :: Maybe Int
      -- ^ @meta_info@ 讀到的舊值;'Nothing' 代表全新索引檔(表都還不存在)
      , irNewVersion :: Int
      }
  | -- | 檔案、'Aapms.Md.Error.MdError'。@parseDocument@ 或 @to*@ 解析失敗,
    -- 整檔不進索引
    ParseFailed FilePath MdError
  | -- | 檔案、'Aapms.Core.Tree.TreeError' 清單。@LevelDoc@ 的 @buildTree@
    -- 驗證失敗,整檔不進索引
    TreeInvalid FilePath [TreeError]
  | -- | 檔案、撞名的 'LogicalName'。@assets.name UNIQUE@ 與既有索引衝突,
    -- 整個 @indexOne@ transaction 回滾,整檔不進索引
    DuplicateAssetName FilePath LogicalName
  | -- | 檔案、節點 id、'Aapms.Core.Registry.checkMeta' 的警告清單。__不__讓
    -- 該節點不進索引('checkMeta' 本身的契約是「只回警告,不決定要不要擋」)
    -- ——節點正常寫入,警告只是附帶回報,供上層(@service@)決定怎麼辦
    MetaWarningsFound FilePath Id [MetaWarning]
  deriving stock (Show, Eq)

renderIndexIssue :: IndexIssue -> Text
renderIndexIssue (SchemaRebuilt old new) =
  "索引已重建:schema 版本從 "
    <> maybe "(全新索引檔)" (T.pack . show) old
    <> " 變成 "
    <> T.pack (show new)
renderIndexIssue (ParseFailed fp e) =
  T.pack fp <> ": 解析失敗,不進索引 —— " <> renderMdError e
renderIndexIssue (TreeInvalid fp es) =
  T.pack fp
    <> ": Level 場景樹不合法,不進索引 —— "
    <> T.intercalate "; " (map renderTreeError es)
renderIndexIssue (DuplicateAssetName fp (LogicalName nm)) =
  T.pack fp <> ": asset 名稱 `" <> nm <> "` 與既有索引重複,整檔不進索引"
renderIndexIssue (MetaWarningsFound fp nodeId ws) =
  T.pack fp
    <> ": 節點 "
    <> renderId nodeId
    <> " 的型別檢查警告(不擋索引)—— "
    <> T.intercalate "; " (map renderMetaWarning ws)

-- | 本模組自己的 'MetaWarning' 文字化——"Aapms.Core.Registry" 只匯出
-- 'checkMeta' 本身,沒有匯出對應的 render 函式(只有型別 'MetaWarning (..)'
-- 公開),索引層要顯示訊息只能自己寫一份。
renderMetaWarning :: MetaWarning -> Text
renderMetaWarning = \case
  MissingRequiredField (TypeKey k) f -> "型別 " <> k <> " 缺少必填欄位 `" <> f <> "`"
  LinkNotAllowed (TypeKey k) kind -> "型別 " <> k <> " 不允許關聯 `" <> kind <> "`"
  UnknownNodeType (TypeKey k) -> "型別 `" <> k <> "` 不在註冊表內"
  NameKindNotAllowed (TypeKey k) kind ->
    "型別 " <> k <> " 的命名第一段 `" <> kind <> "` 不在允許的 name_kinds 內"

-- | 全部的表,順序固定(依外鍵相依順序:@files@ → @nodes@ → 其餘 → 三張
-- FTS 相關表)。之後的 feature 加業務表時擴充這份清單,不是另開一份。
--
-- @fts_map@ 排在最後有實質意義:'resetSchema' 以__反向__順序 DROP,先砍
-- @fts_map@ 會連帶砍掉建在它上面的觸發器,之後砍兩張虛擬表才不會留下指向
-- 不存在的表的觸發器。
indexTables :: [Text]
indexTables =
  [ "meta_info"
  , "files"
  , "nodes"
  , "node_aliases"
  , "node_tags"
  , "links"
  , "assets"
  , "packs"
  , "licenses"
  , "levels"
  , "tree_nodes"
  , "tree_node_entities"
  , "fts_tri"
  , "fts_cjk"
  , "fts_map"
  ]

-- | 開啟指定路徑的索引:開連線 → PRAGMA → schema_version 判斷(不符即重建)→
-- 寫入 vault 身分,全部收在同一個 'trySqlite' 區塊內。
--
-- 自動建立空檔案是 SQLite 內建行為,不是本函式主動「建檔」——呼叫端(
-- 'Aapms.Store.Marker.openVault' \/ 'Aapms.Store.Marker.initVaultAt')負責
-- 判斷檔案原本存不存在。
openIndexAt
  :: FilePath
  -> VaultId
  -> VaultKind
  -> Text
  -> IO (Either StoreError (Connection, [IndexIssue]))
openIndexAt fp vid kind name =
  trySqlite $ do
    conn <- open fp
    prepareConnection conn
    issues <- ensureSchema conn
    setVaultInfo conn (unVaultId vid) (renderVaultKind kind) name
    pure (conn, issues)
  where
    unVaultId (VaultId t) = t

closeIndex :: Connection -> IO ()
closeIndex = close

prepareConnection :: Connection -> IO ()
prepareConnection conn = do
  execute_ conn "PRAGMA foreign_keys = ON"
  -- graph-core/F007:外鍵級聯造成的刪除,預設__不會__觸發 DELETE 觸發器。
  -- @fts_map@ 的觸發器正是靠 files → nodes → fts_map 這條級聯被叫起來的,
  -- 沒有這一行,兩張 FTS 表就永遠清不掉舊列。
  execute_ conn "PRAGMA recursive_triggers = ON"
  -- journal_mode / busy_timeout 都回傳一列結果,execute_ 不接受這種語句
  void (query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text])
  void (query_ conn "PRAGMA busy_timeout = 5000" :: IO [Only Int])

-- | 版本相符就什麼都不做且不回報問題,否則砍掉重建並回報一筆 'SchemaRebuilt'。
ensureSchema :: Connection -> IO [IndexIssue]
ensureSchema conn = do
  ver <- currentVersion conn
  if ver == Just schemaVersion
    then pure []
    else do
      resetSchema conn
      pure [SchemaRebuilt ver schemaVersion]

-- | @meta_info@ 裡記的 schema 版本。表還不存在或值不是整數時為 'Nothing'。
currentVersion :: Connection -> IO (Maybe Int)
currentVersion conn = do
  has <- tableExists conn "meta_info"
  if not has
    then pure Nothing
    else do
      rows <-
        query conn "SELECT value FROM meta_info WHERE key = ?" (Only ("schema_version" :: Text)) ::
          IO [Only Text]
      pure $ case rows of
        [Only t] -> readInt t
        _ -> Nothing
  where
    readInt t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _ -> Nothing

tableExists :: Connection -> Text -> IO Bool
tableExists conn name = do
  rows <-
    query
      conn
      "SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?"
      (Only name) ::
      IO [Only Int]
  pure $ case rows of
    [Only n] -> n > 0
    _ -> False

-- | 砍掉全部的表再建一次。這就是本專案的「遷移程式」(ADR-013)。
resetSchema :: Connection -> IO ()
resetSchema conn = withTransaction conn $ do
  forM_ (reverse indexTables) $ \t ->
    execute_ conn (Query ("DROP TABLE IF EXISTS " <> t))
  createSchema conn

createSchema :: Connection -> IO ()
createSchema conn = do
  forM_ schemaDDL (execute_ conn . Query)
  execute
    conn
    "INSERT OR REPLACE INTO meta_info(key, value) VALUES ('schema_version', ?)"
    (Only (T.pack (show schemaVersion)))

-- | 讓連線自己知道屬於哪個 vault(vault_id \/ vault_kind \/ vault_name),
-- 以 marker 的內容為準。
setVaultInfo :: Connection -> Text -> Text -> Text -> IO ()
setVaultInfo conn vid kind name = do
  put "vault_id" vid
  put "vault_kind" kind
  put "vault_name" name
  where
    put k val =
      execute conn "INSERT OR REPLACE INTO meta_info(key, value) VALUES (?, ?)" (k :: Text, val)

-- | 15 張表的建表語句(外加 @fts_map@ 的刪除觸發器),順序與 'indexTables' 一致。
--
-- 外鍵全部 @ON DELETE CASCADE@,以 @nodes.file_path@\/@links.file_path@
-- @REFERENCES files(path)@ 為根(design.md「索引結構」):刪一筆 @files@
-- 連帶砍光該檔的 @nodes@ 與全部專屬表\/@links@\/@node_aliases@\/@node_tags@;
-- @assets@\/@packs@\/@licenses@\/@levels@\/@tree_nodes@ 的 @id@ 是外鍵指向
-- @nodes(id)@,@tree_node_entities@ 掛在 @tree_nodes(id)@ 底下。
schemaDDL :: [Text]
schemaDDL =
  [ "CREATE TABLE meta_info(\
    \  key TEXT PRIMARY KEY,\
    \  value TEXT NOT NULL)"
  , "CREATE TABLE files(\
    \  path TEXT PRIMARY KEY,\
    \  mtime INTEGER NOT NULL,\
    \  size INTEGER NOT NULL,\
    \  doc_kind TEXT NOT NULL)"
  , "CREATE TABLE nodes(\
    \  id TEXT PRIMARY KEY,\
    \  prefix TEXT NOT NULL,\
    \  type TEXT NOT NULL,\
    \  title TEXT NOT NULL,\
    \  summary TEXT NOT NULL,\
    \  status TEXT NOT NULL,\
    \  timeline TEXT,\
    \  timeline_order INTEGER,\
    \  source TEXT NOT NULL,\
    \  revision INTEGER NOT NULL,\
    \  created TEXT NOT NULL,\
    \  updated TEXT NOT NULL,\
    \  file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,\
    \  section_anchor TEXT,\
    \  owner TEXT)"
  , "CREATE TABLE node_aliases(\
    \  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,\
    \  alias TEXT NOT NULL)"
  , "CREATE TABLE node_tags(\
    \  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,\
    \  tag TEXT NOT NULL)"
  , "CREATE TABLE links(\
    \  src TEXT NOT NULL,\
    \  dst_vault TEXT,\
    \  dst TEXT NOT NULL,\
    \  kind TEXT NOT NULL,\
    \  note TEXT,\
    \  file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE)"
  , "CREATE TABLE assets(\
    \  id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,\
    \  name TEXT UNIQUE,\
    \  sha256 TEXT NOT NULL,\
    \  entry TEXT NOT NULL,\
    \  ext TEXT,\
    \  meta_json TEXT NOT NULL,\
    \  license TEXT,\
    \  author TEXT)"
  , "CREATE TABLE packs(\
    \  id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,\
    \  vendor TEXT,\
    \  archive TEXT,\
    \  sha256 TEXT,\
    \  license TEXT,\
    \  author_json TEXT,\
    \  source_url TEXT,\
    \  ai_disclosure TEXT NOT NULL,\
    \  is_reference INTEGER NOT NULL)"
  , "CREATE TABLE licenses(\
    \  id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,\
    \  commercial INTEGER NOT NULL,\
    \  attribution_required INTEGER NOT NULL,\
    \  credit_text TEXT,\
    \  modification_allowed INTEGER,\
    \  redistribution_allowed INTEGER,\
    \  resale_allowed INTEGER,\
    \  nft_allowed INTEGER,\
    \  source_url TEXT)"
  , "CREATE TABLE levels(\
    \  id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,\
    \  root TEXT NOT NULL)"
  , "CREATE TABLE tree_nodes(\
    \  id TEXT PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,\
    \  level_id TEXT NOT NULL,\
    \  parent_id TEXT,\
    \  order_idx INTEGER NOT NULL,\
    \  kind TEXT NOT NULL)"
  , "CREATE TABLE tree_node_entities(\
    \  node_id TEXT NOT NULL REFERENCES tree_nodes(id) ON DELETE CASCADE,\
    \  ref TEXT NOT NULL)"
  , -- graph-core/F007(ADR-016):兩張 FTS5 表,同一份來源文字、同一個 rowid。
    -- 六個欄位與 'Aapms.Store.Tokenize.FtsText' 的欄位順序逐一對應。
    -- 兩張都__不是__ contentless:snippet() 要得到內容,而且要能整批刪列。
    "CREATE VIRTUAL TABLE fts_tri USING fts5(\
    \  title, summary, body, aliases, tags, name,\
    \  tokenize = 'trigram')"
  , -- 內容是 Tokenize 預切過的 unigram + bigram 串,unicode61 遇空白斷詞,
    -- 二字詞因此變成精確比對。
    "CREATE VIRTUAL TABLE fts_cjk USING fts5(\
    \  title, summary, body, aliases, tags, name,\
    \  tokenize = 'unicode61')"
  , -- FTS5 的 rowid 是整數,節點 id 是文字,這張表是兩者的對照。
    -- 外鍵讓 files → nodes 的級聯一路走到這裡。
    "CREATE TABLE fts_map(\
    \  rowid INTEGER PRIMARY KEY,\
    \  node_id TEXT NOT NULL UNIQUE REFERENCES nodes(id) ON DELETE CASCADE)"
  , -- 虛擬表沒有外鍵,只有這個觸發器補得上最後一段級聯(需要
    -- PRAGMA recursive_triggers = ON,見 prepareConnection)。
    "CREATE TRIGGER fts_map_after_delete AFTER DELETE ON fts_map BEGIN\
    \  DELETE FROM fts_tri WHERE rowid = old.rowid;\
    \  DELETE FROM fts_cjk WHERE rowid = old.rowid;\
    \ END"
  ]

--------------------------------------------------------------------------------
-- FTS 列維護(graph-core/F007)

-- | 把一批節點的 FTS 內容寫進 @fts_tri@ \/ @fts_cjk@,並在 @fts_map@ 建立
-- 節點 id ↔ rowid 的對照。__以節點 id 為單位取代__:同一個節點已經有列時先
-- 清掉再寫,所以對同一份檔案重複索引不會留下重複列,也不會讓新節點撿到舊
-- rowid 的殘留內容。
--
-- 呼叫端是 "Aapms.Store.Index" 的單檔索引交易(整檔替換的 FTS 部分):
-- 節點列已經寫進 @nodes@ 之後、同一個 transaction 之內呼叫。本函式__不__自己
-- 開交易、不做任何檔案 IO(ADR-022 寫鎖預算)。
insertFtsRows :: Connection -> [FtsRow] -> IO ()
insertFtsRows = undefined
