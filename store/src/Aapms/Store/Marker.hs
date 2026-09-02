-- | vault marker 的讀寫、初始化、開關(graph-core\/F005;ADR-017)。
--
-- 一個 vault = 一個目錄 + @.aapms\/@ marker。本模組只負責「已知根目錄之後」
-- 的讀寫;__不探測、不讀中樞註冊表、不處理 @--vault@__——那些是 @workspace@
-- 子系統的職責(S3),本模組刻意不 import 任何會做這些事的東西。
module Aapms.Store.Marker
  ( -- * 型別
    VaultMarker (..)
  , VaultHandle (..)

    -- * 讀寫
  , readMarker
  , initVaultAt
  , initVaultAtWith
  , openVault
  , closeVault

    -- * 路徑
  , markerDir
  , configPath
  , indexDbPath
  ) where

import Control.Exception (IOException, try)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import Database.SQLite.Simple (Connection)
import Aapms.Core.Id (IdPrefix (PVlt), VaultId (..), newId, parseId, renderId)
import Aapms.Core.Registry (TypeRegistry)
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

-- | 含 marker、根目錄、已開的索引連線、型別註冊表。欄位全部匯出:
-- graph-core\/F006 起的查詢\/寫入函式都要能直接拿 'vhConn' 操作索引、拿
-- 'vhRoot' 組出檔案的絕對路徑、拿 'vhRegistry' 跑 'Aapms.Core.Registry.checkMeta'。
--
-- 註冊表併入 'VaultHandle'(DEC-9,取代原本「各索引函式加一個參數」的方案):
-- @openVault@ 自己就要做過時刷新(graph-core\/F006),那條路徑同樣需要註冊表,
-- 只補索引函式的參數會漏掉 @openVault@ 這一段;由 @openVault@ 收下也把「先載入
-- 註冊表、再開 vault」這個順序用型別釘死。
data VaultHandle = VaultHandle
  { vhMarker :: VaultMarker
  , vhRoot :: FilePath
  , vhConn :: Connection
  , vhRegistry :: TypeRegistry
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
-- | 'initVaultAt' 的明碼時間版本(graph-core\/E002)。
--
-- __時間是明碼參數__,與 'Aapms.Core.Id.newId' 及 'Aapms.Store.Write.allocateId'
-- (2026-08-25 GAP-8 裁決)一致:vault 的 id 是 @newId PVlt name t 0@ 的結果,時間
-- 藏在函式內部取樣時,呼叫端就無法預先造出兩個相同的 id —— 而
-- @workspace@ 的 @initVault@ 有一整條「新 id 撞到中樞既有 id 就回
-- @VaultIdCollision@ 並回滾」的分支,它的正確性只能靠造出一次碰撞來驗。
--
-- __不逸出 @IOException@__(graph-core\/B002):簽名承諾了
-- @Either StoreError@,檔案系統的失敗一律轉成 'StoreError' 回傳。
initVaultAtWith :: FilePath -> VaultKind -> Text -> UTCTime -> IO (Either StoreError VaultMarker)
initVaultAtWith givenRoot kind name now = do
  rootR <- try (makeAbsolute givenRoot) :: IO (Either IOException FilePath)
  case rootR of
    Left e -> pure (Left (FileReadFailed givenRoot (T.pack (show e))))
    Right root -> do
      existsR <- try (doesFileExist (configPath root)) :: IO (Either IOException Bool)
      case existsR of
        Left e -> pure (Left (FileReadFailed (configPath root) (T.pack (show e))))
        Right True -> pure (Left (VaultAlreadyInitialized root))
        Right False -> do
          mkDirR <- try (createDirectoryIfMissing True (markerDir root)) :: IO (Either IOException ())
          case mkDirR of
            Left e -> pure (Left (FileWriteFailed (markerDir root) (T.pack (show e))))
            Right () -> do
              let vid = VaultId (renderId (newId PVlt name now 0))
                  marker = VaultMarker vid kind name []
              writeR <- atomicWriteText (configPath root) (renderMarker marker)
              case writeR of
                Left e -> pure (Left e)
                Right () ->
                  openIndexAt (indexDbPath root) vid kind name >>= \case
                    Left e -> pure (Left e)
                    Right (conn, _issues) -> do
                      -- 全新索引檔一定會有一筆 SchemaRebuilt,對 initVaultAtWith
                      -- 而言這不是「問題」而是預期行為,忽略回傳的 issues
                      closeIndex conn
                      pure (Right marker)

-- | 'initVaultAtWith' 的薄包裝:取當下時間後轉呼(graph-core\/E002)。對外行為
-- 除了「不再拋 'IOException'」以外完全不變。
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
initVaultAt givenRoot kind name = do
  now <- getCurrentTime
  initVaultAtWith givenRoot kind name now

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
--
-- 型別註冊表由呼叫端先載入好再給(DEC-9):本函式只是把它收進 'VaultHandle',
-- 不在這裡載入——載入是 IO 且有自己的錯誤型別(契約 C 的 'RegistryError'),
-- 屬 @aapms-types@\/呼叫端的責任,不是 @openVault@ 的責任。
openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))
openVault registry givenRoot = do
  root <- makeAbsolute givenRoot
  readMarker root >>= \case
    Left e -> pure (Left e)
    Right marker ->
      openIndexAt (indexDbPath root) (vmId marker) (vmKind marker) (vmName marker) >>= \case
        Left e -> pure (Left e)
        Right (conn, issues) -> pure (Right (VaultHandle marker root conn registry, issues))

closeVault :: VaultHandle -> IO ()
closeVault = closeIndex . vhConn
