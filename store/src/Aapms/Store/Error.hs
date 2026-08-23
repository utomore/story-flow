-- | 落地層的錯誤型別(契約 G 的骨架)。
--
-- 本 feature(graph-core\/F005)只定義自己用得到的建構子;之後每個 feature
-- 往這個型別__加__建構子(如 F006 的 @IndexUpdateFailed@、F008 的
-- @StaleRevision@),不是重新定義。
module Aapms.Store.Error
  ( StoreError (..)
  , renderStoreError
  , trySqlite
  ) where

import Control.Exception (Handler (..), catches)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (FormatError, ResultError, SQLError)

data StoreError
  = -- | 該路徑沒有 @.aapms\/config.toml@。'Aapms.Store.Marker.openVault' 不會
    -- 因此自動建檔
    VaultMarkerMissing FilePath
  | -- | marker 存在但欄位不合法;'Text' 指出是哪個欄位、為什麼不合法
    VaultMarkerInvalid FilePath Text
  | -- | 'Aapms.Store.Marker.initVaultAt' 對已有 marker 的目錄再次呼叫
    VaultAlreadyInitialized FilePath
  | FileReadFailed FilePath Text
  | FileWriteFailed FilePath Text
  | -- | 本套件與 SQLite 之間的例外都收斂到這裡
    SqliteError Text
  deriving stock (Show, Eq)

renderStoreError :: StoreError -> Text
renderStoreError = \case
  VaultMarkerMissing fp ->
    pack fp
      <> ": 找不到 vault marker(.aapms/config.toml 不存在);"
      <> "請先執行 vault init 建立"
  VaultMarkerInvalid fp msg ->
    pack fp <> ": vault marker 無法解析 —— " <> msg <> ";請修正後再試"
  VaultAlreadyInitialized fp ->
    pack fp
      <> ": 這裡已經有 vault marker(.aapms/config.toml 已存在),不會覆寫;"
      <> "如需重建,請先手動移除該檔案"
  FileReadFailed fp msg ->
    pack fp <> ": 讀檔失敗 —— " <> msg <> ";請確認檔案存在且可讀"
  FileWriteFailed fp msg ->
    pack fp <> ": 寫檔失敗 —— " <> msg <> ";請確認目錄存在且可寫"
  SqliteError msg ->
    "索引操作失敗 —— " <> msg <> ";可以嘗試重新開啟 vault"
  where
    pack = T.pack

-- | 本套件與 SQLite 之間的唯一邊界。
--
-- @sqlite-simple@ 的三種例外都在這裡收斂成 'SqliteError';其餘例外(例如
-- 非同步中斷)照常往上拋,不被誤吞。
trySqlite :: IO a -> IO (Either StoreError a)
trySqlite act =
  (Right <$> act)
    `catches` [ Handler (\e -> failWith (e :: SQLError))
              , Handler (\e -> failWith (e :: FormatError))
              , Handler (\e -> failWith (e :: ResultError))
              ]
  where
    failWith :: (Show e) => e -> IO (Either StoreError a)
    failWith = pure . Left . SqliteError . T.pack . show
