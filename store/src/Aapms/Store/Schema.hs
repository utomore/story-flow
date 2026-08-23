-- | SQLite 索引的 schema 與連線開啟(graph-core\/F005)。
--
-- ADR-013\/ADR-002:索引是__衍生物__,任何時候可以刪掉重建。'schemaVersion' 與
-- @meta_info@ 裡記的值不符時,'openIndexAt' 直接把所有表砍掉重建——schema
-- 變更不寫遷移程式。
--
-- 本 feature 只建 @meta_info@ 一張表;業務表(@nodes@ 等)屬
-- graph-core\/F006(store-unified-index),擴充 'indexTables' 這份清單時一併
-- 擴充 'schemaDDL',不是另開一份。
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
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Error (StoreError, trySqlite)

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

-- | 本 feature 起算的新 schema(只有 @meta_info@),與合併前 entity-graph-core
-- 的舊值 1 語意不同——舊索引一律視為需要重建,不是「相容」。
schemaVersion :: Int
schemaVersion = 1

-- | 索引重建時回報的問題。目前只有一種建構子:'schemaVersion' 不符觸發整庫
-- 重建。graph-core\/F006 依 design.md「模組間公開介面」擴充__加__建構子
-- (如過時偵測、@checkMeta@ 警告),不得整個重新定義。
data IndexIssue = SchemaRebuilt
  { irOldVersion :: Maybe Int
  -- ^ @meta_info@ 讀到的舊值;'Nothing' 代表全新索引檔(表都還不存在)
  , irNewVersion :: Int
  }
  deriving stock (Show, Eq)

renderIndexIssue :: IndexIssue -> Text
renderIndexIssue (SchemaRebuilt old new) =
  "索引已重建:schema 版本從 "
    <> maybe "(全新索引檔)" (T.pack . show) old
    <> " 變成 "
    <> T.pack (show new)

-- | 全部的表,順序固定。graph-core\/F006 加業務表時擴充這份清單,不是另開一份。
indexTables :: [Text]
indexTables = ["meta_info"]

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

-- | 目前只有 @meta_info@ 一張表;graph-core\/F006 加業務表時擴充這份清單。
schemaDDL :: [Text]
schemaDDL =
  [ "CREATE TABLE meta_info(\
    \  key TEXT PRIMARY KEY,\
    \  value TEXT NOT NULL)"
  ]
