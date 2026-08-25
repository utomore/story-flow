-- | 落地層的錯誤型別(契約 G)。
--
-- __'StoreError' 是 @aapms-store@ 的唯一錯誤型別__(design.md 契約 G,
-- 2026-08-24 釐清):寫入、索引、marker、跨 vault 的失敗全部是它的建構子,由各
-- feature 依需要__擴充__(F005 建骨架、F006 加索引類、graph-core\/F008 加寫入類),
-- __不得另立平行的錯誤型別再橋接__ ——契約 E 的每個函式都寫
-- @Either StoreError a@,多一個型別就是多一套 @render*@ 與多一次翻譯。
--
-- 本模組因此依賴 @aapms-core@ 與 @aapms-md@ 的型別(錯誤要說得出「哪個節點、
-- 哪一筆關聯、哪一種文件」),但__不 import 任何 @Aapms.Store.*@__:它是
-- @aapms-store@ 內部依賴圖的葉子,誰都可以往上帶錯誤,沒有模組環。
module Aapms.Store.Error
  ( StoreError (..)
  , renderStoreError
  , trySqlite
  ) where

import Control.Exception (Handler (..), catches)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (FormatError, ResultError, SQLError)
import Aapms.Core.Id (Id)
import Aapms.Core.Link (Link)
import Aapms.Core.Meta (Revision, TypeKey)
import Aapms.Core.Tree (TreeError)
import Aapms.Md.Document (DocKind)
import Aapms.Md.Error (MdError)

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
  | -- | 索引裡查不到這個 id(graph-core\/F008)
    NodeNotFound Id
  | -- | 索引說某檔有這一節,重讀檔案卻找不到 —— 索引過時,不是資料不見
    SectionMissing FilePath Id
  | -- | 節點 id、呼叫端手上的 revision、檔案裡的實際 revision
    RevisionMismatch Id Revision Revision
  | -- | 檔案、'Aapms.Md.Error.MdError'。md 的編輯\/解析函式回 'Left'
    MdWriteFailed FilePath MdError
  | -- | 檔案、'Aapms.Core.Tree.TreeError' 清單。編輯後的 Level 樹不合法,__寫檔之前__就中止
    TreeInvalidOnWrite FilePath [TreeError]
  | -- | 檔案、原因。__檔案已經落地__,只有索引沒跟上;'Aapms.Store.Index.rebuildIndex' 修得回來
    IndexUpdateFailed FilePath Text
  | -- | 呼叫端明確指定的路徑已經有檔案(推導出來的路徑會自動遞增,不走這裡)
    FileAlreadyExists FilePath
  | -- | 型別註冊表查不到這個型別該落在哪個目錄
    RegistryDirUnknown TypeKey
  | -- | 對非 asset 的節點呼叫 'Aapms.Store.Write.writeAssetFields'
    NotAnAsset Id
  | -- | 對非 license 的節點呼叫 'Aapms.Store.Write.upsertLicense'
    NotALicense Id
  | -- | 目標節點、目標檔案的種類。'Aapms.Store.Create.addSection' 的
    -- 'Aapms.Md.Render.NewSectionPayload' 與檔案種類不相容
    BadSectionPayload Id DocKind
  | -- | 節點、要刪的那一筆關聯。一筆都沒命中時回這個而不是靜默成功
    LinkNotFound Id Link
  | -- | 被刪的節點、指向它的 (來源節點, 關聯)。'Aapms.Store.Create.DeleteSafe' 專用
    ReferencedBy Id [(Id, Link)]
  | -- | Level 的根 Node 刪不得(刪了就解析不出 @root@),請改刪整份 Level 檔
    CannotDeleteRootNode Id
  | -- | 父節點、算出來的標題層級。Markdown 只有六級標題
    NodeDepthExceeded Id Int
  deriving stock (Show, Eq)

-- | 繁中訊息,__每一則說出下一步該做什麼__(契約 G;system.md 全域錯誤處理策略
-- 第 2 條)。
--
-- graph-core\/F008 把寫入路徑的十五個建構子併進來之後,本函式的責任範圍是
-- __'StoreError' 的全部建構子__(含 F005\/F006 原有的六個),不再有第二個
-- @render*@。
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
  -- graph-core/F008 的寫入路徑(骨架未實作)
  NodeNotFound _ -> undefined
  SectionMissing _ _ -> undefined
  RevisionMismatch _ _ _ -> undefined
  MdWriteFailed _ _ -> undefined
  TreeInvalidOnWrite _ _ -> undefined
  IndexUpdateFailed _ _ -> undefined
  FileAlreadyExists _ -> undefined
  RegistryDirUnknown _ -> undefined
  NotAnAsset _ -> undefined
  NotALicense _ -> undefined
  BadSectionPayload _ _ -> undefined
  LinkNotFound _ _ -> undefined
  ReferencedBy _ _ -> undefined
  CannotDeleteRootNode _ -> undefined
  NodeDepthExceeded _ _ -> undefined
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
