-- | vault marker 的讀寫、初始化、開關(graph-core\/F005;ADR-017)。
--
-- 一個 vault = 一個目錄 + @.aapms\/@ marker。本模組只負責「已知根目錄之後」
-- 的讀寫;__不探測、不讀中樞註冊表、不處理 @--vault@__——那些是 @workspace@
-- 子系統的職責(P3),本模組刻意不 import 任何會做這些事的東西。
module Aapms.Store.Marker
  ( -- * 型別
    VaultMarker (..)
  , VaultHandle (..)

    -- * 讀寫
  , readMarker
  , initVaultAt
  , openVault
  , closeVault

    -- * 路徑
  , markerDir
  , configPath
  , indexDbPath
  ) where

import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Connection)
import Aapms.Core.Id (IdPrefix (PVlt), VaultId (..), newId, parseId, renderId)
import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (StoreError (..))
import Aapms.Store.Schema
  ( IndexIssue
  , VaultKind (..)
  , closeIndex
  , openIndexAt
  , parseVaultKind
  , renderVaultKind
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.FilePath ((</>))
import qualified TOML

-- 路徑 ------------------------------------------------------------------------

markerDir :: FilePath -> FilePath
markerDir root = root </> ".aapms"

configPath :: FilePath -> FilePath
configPath root = markerDir root </> "config.toml"

indexDbPath :: FilePath -> FilePath
indexDbPath root = markerDir root </> "index.db"

-- 型別 ------------------------------------------------------------------------

data VaultMarker = VaultMarker
  { vmId :: VaultId
  , vmKind :: VaultKind
  , vmName :: Text
  , vmRefs :: [VaultId]
  }
  deriving stock (Show, Eq)

-- | 含 marker、根目錄、已開的索引連線。欄位全部匯出:graph-core\/F006 起的
-- 查詢\/寫入函式都要能直接拿 'vhConn' 操作索引、拿 'vhRoot' 組出檔案的絕對路徑。
data VaultHandle = VaultHandle
  { vhMarker :: VaultMarker
  , vhRoot :: FilePath
  , vhConn :: Connection
  }

-- 讀 ---------------------------------------------------------------------------

-- | 讀 @\<root\>\/.aapms\/config.toml@。檔案不存在回 'VaultMarkerMissing'
-- (__不自動建檔__);存在但欄位不合法回 'VaultMarkerInvalid',訊息指出是哪個
-- 欄位。
readMarker :: FilePath -> IO (Either StoreError VaultMarker)
readMarker root = do
  let fp = configPath root
  exists <- doesFileExist fp
  if not exists
    then pure (Left (VaultMarkerMissing fp))
    else do
      txtR <- readTextFile fp
      pure (txtR >>= parseMarker fp)

parseMarker :: FilePath -> Text -> Either StoreError VaultMarker
parseMarker fp txt = case TOML.decode txt of
  Left e -> Left (VaultMarkerInvalid fp (TOML.renderTOMLError e))
  Right (TOML.Table tbl) -> do
    idText <- requiredString tbl "id"
    vid <- case parseId idText of
      Right (PVlt, i) -> Right (VaultId (renderId i))
      _ -> Left (invalid ("鍵 `id` 不是合法的 vlt- id:" <> idText))
    kindText <- requiredString tbl "kind"
    kind <- case parseVaultKind kindText of
      Just k -> Right k
      Nothing -> Left (invalid ("鍵 `kind` 必須是 asset 或 story,收到 " <> kindText))
    name <- requiredString tbl "name"
    refs <- case M.lookup "refs" tbl of
      Nothing -> Right []
      Just (TOML.Array xs) -> traverse refItem xs
      Just _ -> Left (invalid "鍵 `refs` 必須是字串陣列")
    Right (VaultMarker vid kind name refs)
  Right _ -> Left (invalid "檔案的最上層不是 TOML 表")
  where
    invalid = VaultMarkerInvalid fp

    requiredString tbl key = case M.lookup key tbl of
      Just (TOML.String s) -> Right s
      Just _ -> Left (invalid ("鍵 `" <> key <> "` 必須是字串"))
      Nothing -> Left (invalid ("缺少必填鍵 " <> key))

    refItem (TOML.String s) = case parseId s of
      Right (PVlt, i) -> Right (VaultId (renderId i))
      _ -> Left (invalid ("鍵 `refs` 內有不是合法 vlt- id 的項目:" <> s))
    refItem _ = Left (invalid "鍵 `refs` 必須是字串陣列")

-- 寫 ---------------------------------------------------------------------------

-- | 建立 vault 骨架:發新 @vlt-@ id、寫 marker、建空索引。目錄已有 marker
-- 時回 'VaultAlreadyInitialized' 且__不覆寫任何東西__。
--
-- __不建業務子目錄、不寫 @.gitignore@__——那是 @kind@ 專屬的業務知識,屬
-- @workspace@ 的 @vault init@ 指令組裝本函式之後才做的事。
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
initVaultAt givenRoot kind name = do
  root <- makeAbsolute givenRoot
  exists <- doesFileExist (configPath root)
  if exists
    then pure (Left (VaultAlreadyInitialized root))
    else do
      createDirectoryIfMissing True (markerDir root)
      now <- getCurrentTime
      let vid = VaultId (renderId (newId PVlt name now 0))
          marker = VaultMarker vid kind name []
      writeR <- atomicWriteText (configPath root) (renderMarker marker)
      case writeR of
        Left e -> pure (Left e)
        Right () ->
          openIndexAt (indexDbPath root) vid kind name >>= \case
            Left e -> pure (Left e)
            Right (conn, _issues) -> do
              -- 全新索引檔一定會有一筆 SchemaRebuilt,對 initVaultAt 而言這不
              -- 是「問題」而是預期行為,忽略回傳的 issues
              closeIndex conn
              pure (Right marker)

renderMarker :: VaultMarker -> Text
renderMarker VaultMarker {..} =
  T.unlines
    [ "id   = " <> quote (unVaultId vmId)
    , "kind = " <> quote (renderVaultKind vmKind)
    , "name = " <> quote vmName
    , "refs = [" <> T.intercalate ", " (map (quote . unVaultId) vmRefs) <> "]"
    ]
  where
    unVaultId (VaultId t) = t

quote :: Text -> Text
quote t = "\"" <> T.concatMap esc t <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc c = T.singleton c

-- 開關 ---------------------------------------------------------------------------

-- | 讀取管線「openVault:讀 marker → 開索引 → schema 判斷」的完整落地。
openVault :: FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))
openVault givenRoot = do
  root <- makeAbsolute givenRoot
  readMarker root >>= \case
    Left e -> pure (Left e)
    Right marker ->
      openIndexAt (indexDbPath root) (vmId marker) (vmKind marker) (vmName marker) >>= \case
        Left e -> pure (Left e)
        Right (conn, issues) -> pure (Right (VaultHandle marker root conn, issues))

closeVault :: VaultHandle -> IO ()
closeVault = closeIndex . vhConn
