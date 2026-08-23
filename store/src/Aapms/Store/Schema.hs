-- | SQLite 索引的 schema 與連線開啟。
--
-- ADR-002:索引是__衍生物__,任何時候可以刪掉重建。這件事在本模組換來一個
-- 具體的好處——__schema 變更不寫遷移程式__。'schemaVersion' 與 @meta_info@ 裡
-- 記的值不符時,'openIndex' 直接把所有表砍掉重建(對照 design-studio 的
-- bug-0003「session schema 從未遷移」)。
--
-- 三處與 system.md 原本的索引結構不同,都是實作時碰到硬限制後回寫的:
--
-- * @entities_fts@ __不是 contentless__。contentless 的 FTS5 表既不支援
--   @snippet()@(檢索要回傳命中片段),也不支援刪除單列(單檔重新索引要能
--   整批換掉舊記錄)。代價只是 body 在可丟棄的索引裡多存一份
-- * 新增 @entity_tags@:@EntityFilter@ 要依 tag 過濾,原本的結構沒有地方存 tags
-- * @links@ 多一個 @file_path@ 欄位:關聯的來源可能是 Entity / Level / Node
--   三種表的任何一種,靠 @src@ 反查要三個子查詢;帶上檔案路徑後,
--   單檔重新索引就只是一次外鍵級聯
module Aapms.Store.Schema
  ( -- * 版本
    schemaVersion

    -- * 連線
  , openIndex
  , openIndexAt
  , closeIndex

    -- * Schema
  , createSchema
  , resetSchema
  , currentVersion
  , indexTables

    -- * 連線知道自己屬於哪個 Vault
  , setVaultInfo
  , vaultRootOf
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Store.Error (StoreError, trySqlite)
import Aapms.Store.Vault (Vault (..), indexDbPath)

-- | 內建的 schema 版本。改動 'schemaDDL' 就要 +1——不符即全量重建,
-- 沒有遷移程式可寫。
schemaVersion :: Int
schemaVersion = 1

-- | 全部的表,順序固定。重建等價性測試逐表 dump 時用同一份清單。
indexTables :: [Text]
indexTables =
  [ "meta_info"
  , "files"
  , "entities"
  , "entity_aliases"
  , "entity_tags"
  , "links"
  , "levels"
  , "nodes"
  , "node_entities"
  , "entities_fts"
  , "fts_map"
  ]

-- | 開啟 Vault 的 @.storyflow\/index.db@。
--
-- 只負責「schema 是對的版本」這件事;資料層的自動重建由
-- "Aapms.Store.Index" 的 @openVaultIndex@ 接手(Schema 不能 import Index,
-- 否則兩個模組互相依賴)。schema 被重建後 @files@ 表是空的,於是每一份 @.md@
-- 都會被 @refreshStale@ 判定為過時而重新索引——資料自然回來。
openIndex :: Vault -> IO (Either StoreError Connection)
openIndex v =
  trySqlite $ do
    conn <- open (indexDbPath v)
    prepareConnection conn
    ensureSchema conn
    setVaultInfo conn v
    pure conn

-- | 指定資料庫路徑的版本,@\":memory:\"@ 也走這裡。
openIndexAt :: FilePath -> IO (Either StoreError Connection)
openIndexAt fp =
  trySqlite $ do
    conn <- open fp
    prepareConnection conn
    ensureSchema conn
    pure conn

closeIndex :: Connection -> IO ()
closeIndex = close

prepareConnection :: Connection -> IO ()
prepareConnection conn = do
  execute_ conn "PRAGMA foreign_keys = ON"
  -- journal_mode 會回傳一列結果,execute_ 不接受這種語句
  void (query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text])

-- | 版本相符就什麼都不做,否則砍掉重建。
ensureSchema :: Connection -> IO ()
ensureSchema conn = do
  ver <- currentVersion conn
  if ver == Just schemaVersion
    then pure ()
    else resetSchema conn

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

-- | 砍掉全部的表再建一次。這就是本專案的「遷移程式」。
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

-- | 讓連線自己知道屬於哪個 Vault。
--
-- 'Aapms.Store.Query.lookupEntity' 要回讀檔案才拿得到 body,而它的簽名只有
-- 'Connection';根目錄記在 @meta_info@ 裡,連線就是自足的。
setVaultInfo :: Connection -> Vault -> IO ()
setVaultInfo conn v = do
  put "vault_root" (T.pack (vaultRoot v))
  put "vault_name" (vaultName v)
  where
    put k val =
      execute conn "INSERT OR REPLACE INTO meta_info(key, value) VALUES (?, ?)" (k :: Text, val)

vaultRootOf :: Connection -> IO (Maybe FilePath)
vaultRootOf conn = do
  rows <-
    query conn "SELECT value FROM meta_info WHERE key = ?" (Only ("vault_root" :: Text)) ::
      IO [Only Text]
  pure $ case rows of
    [Only t] -> Just (T.unpack t)
    _ -> Nothing

-- | 全部 DDL。順序有意義:被外鍵指到的表要先建。
schemaDDL :: [Text]
schemaDDL =
  [ "CREATE TABLE meta_info(\
    \  key TEXT PRIMARY KEY,\
    \  value TEXT NOT NULL)"
  , -- mtime / size 是外部改動的過時偵測依據;它同時讓「這個檔案的所有記錄」
    -- 變成一次級聯刪除,單檔重新索引因此是整檔替換而不是逐筆 diff
    "CREATE TABLE files(\
    \  path TEXT PRIMARY KEY,\
    \  mtime INTEGER NOT NULL,\
    \  size INTEGER NOT NULL)"
  , "CREATE TABLE entities(\
    \  id TEXT PRIMARY KEY,\
    \  vault TEXT NOT NULL,\
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
    \  section_anchor TEXT)"
  , "CREATE INDEX idx_entities_file ON entities(file_path)"
  , "CREATE INDEX idx_entities_type ON entities(type)"
  , "CREATE INDEX idx_entities_status ON entities(status)"
  , "CREATE TABLE entity_aliases(\
    \  entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,\
    \  alias TEXT NOT NULL)"
  , "CREATE INDEX idx_aliases_entity ON entity_aliases(entity_id)"
  , "CREATE TABLE entity_tags(\
    \  entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,\
    \  tag TEXT NOT NULL)"
  , "CREATE INDEX idx_tags_entity ON entity_tags(entity_id)"
  , "CREATE INDEX idx_tags_tag ON entity_tags(tag)"
  , -- src 可能是 Entity / Level / Node 任一種,所以不下外鍵;file_path 才是
    -- 級聯的依據。dst_vault 為 NULL 代表本 Vault(索引時正規化)
    "CREATE TABLE links(\
    \  src TEXT NOT NULL,\
    \  dst_vault TEXT,\
    \  dst TEXT NOT NULL,\
    \  kind TEXT NOT NULL,\
    \  note TEXT,\
    \  file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE)"
  , "CREATE INDEX idx_links_src ON links(src)"
  , "CREATE INDEX idx_links_dst ON links(dst)"
  , "CREATE INDEX idx_links_file ON links(file_path)"
  , "CREATE TABLE levels(\
    \  id TEXT PRIMARY KEY,\
    \  vault TEXT NOT NULL,\
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
    \  root TEXT NOT NULL,\
    \  file_path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE)"
  , "CREATE INDEX idx_levels_file ON levels(file_path)"
  , "CREATE TABLE nodes(\
    \  id TEXT PRIMARY KEY,\
    \  level_id TEXT NOT NULL,\
    \  parent_id TEXT,\
    \  order_idx INTEGER NOT NULL,\
    \  kind TEXT NOT NULL,\
    \  vault TEXT NOT NULL,\
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
    \  section_anchor TEXT)"
  , "CREATE INDEX idx_nodes_file ON nodes(file_path)"
  , "CREATE INDEX idx_nodes_level ON nodes(level_id)"
  , -- entity_id 存的是 Ref 的字串形式(可能是 <vault>:<id>),因此不下外鍵
    "CREATE TABLE node_entities(\
    \  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,\
    \  entity_id TEXT NOT NULL)"
  , "CREATE INDEX idx_node_entities_node ON node_entities(node_id)"
  , -- 中文檢索靠 trigram:搜「織紋」要能命中「織紋刀」的內部位置,
    -- 預設 tokenizer 對中文等於整段不切
    "CREATE VIRTUAL TABLE entities_fts USING fts5(\
    \  title, summary, body, aliases, tags,\
    \  tokenize='trigram')"
  , -- FTS5 的 rowid 是整數,我們的 id 是字串,需要一張對照表
    "CREATE TABLE fts_map(\
    \  rowid INTEGER PRIMARY KEY,\
    \  entity_id TEXT NOT NULL UNIQUE REFERENCES entities(id) ON DELETE CASCADE)"
  ]
