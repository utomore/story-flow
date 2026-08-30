-- | 業務層的錯誤型別(ADR-006)。
--
-- 錯誤定義在 @service@ 而不是各介面各一份,是雙模式決策的直接後果:CLI 的
-- @--json@、servant 的錯誤 body、未來 MCP 的錯誤回報必須講同一套話,否則
-- AI Agent 要為每個介面各學一次。
--
-- 兩個輸出各有分工:
--
-- * 'renderServiceError' 給人看,繁中,每一則都說出__下一步該做什麼__
-- * 'errorCode' 給機器看,snake_case,是三種介面共用的穩定識別碼
--
-- 'StoreFailed' __原樣包住__ 'StoreError' 而不逐個翻譯:
-- 'renderStoreError' 每一則訊息都已經寫成「說出下一步」的形式,重寫一遍
-- 只會讓兩份訊息隨時間漂移。
module Aapms.Service.Error
  ( ServiceError (..)
  , renderServiceError
  , errorCode
  , renderEntityWarning
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, Ref, renderId, renderRef)
import Aapms.Core.Registry (EntityWarning (..))
import Aapms.Core.Tree (TreeError, renderTreeError)
import Aapms.Store (StoreError (..), renderStoreError)
import Aapms.Types.Loader (LoadError, renderLoadError)

data ServiceError
  = -- | 落地層的失敗原樣帶上
    StoreFailed StoreError
  | -- | 型別註冊表的目錄找不到,附上找過哪裡
    RegistryUnavailable Text
  | -- | 註冊表載得到但內容不合法。__不叫 @RegistryInvalid@__:
    -- 'LoadError' 已經佔用了那個名稱
    RegistryLoadFailed [LoadError]
  | -- | 必填欄位缺漏,拒絕寫入。@Nothing@ = 還沒配置 id 的新實體
    ValidationFailed (Maybe Id) [EntityWarning]
  | -- | 建立時給了註冊表沒有的型別
    UnknownType Text
  | -- | 關聯指向本 Vault 裡不存在的 id
    DanglingLinkTarget Ref
  | CrossVaultUnsupported Ref
  | -- | 讀出來的 Level 樹不合法(作者手改標題層級改壞了)
    LevelTreeInvalid Id [TreeError]
  deriving stock (Show, Eq)

renderServiceError :: ServiceError -> Text
renderServiceError = \case
  StoreFailed e -> renderStoreError e
  RegistryUnavailable hint ->
    "找不到型別註冊表 —— "
      <> hint
      <> ";沒有註冊表的話每個 Entity 都會被判成未知型別,因此直接中止"
  RegistryLoadFailed es ->
    "型別註冊表載入失敗,以下宣告要先修好:\n"
      <> T.intercalate "\n" (map (("  " <>) . renderLoadError) es)
  ValidationFailed mi ws ->
    "寫入被拒絕:"
      <> subject mi
      <> " 缺少型別宣告的必填欄位,一個位元組都沒有寫進去\n"
      <> T.intercalate "\n" (map (("  " <>) . renderEntityWarning) ws)
  UnknownType t ->
    "型別「"
      <> t
      <> "」不在型別註冊表裡,不知道新檔案該放哪個目錄;"
      <> "請先在 types/registry/ 加一份宣告(或檢查有沒有打錯字)"
  DanglingLinkTarget r ->
    "關聯的目標 "
      <> renderRef r
      <> " 在這個 Vault 裡不存在;請先確認 id 是否打錯,或先把目標建起來"
  CrossVaultUnsupported r ->
    "跨 Vault 的讀寫還沒支援(目標 "
      <> renderRef r
      <> ");關聯本身寫得進檔案也查得出來,但工具這一層目前只操作目前的 Vault"
  LevelTreeInvalid i es ->
    "Level "
      <> renderId i
      <> " 的場景樹不合法,讀不出樹狀結構:\n"
      <> T.intercalate "\n" (map (("  " <>) . renderTreeError) es)
      <> "\n請在編輯器裡把標題層級修好"
  where
    subject = maybe "新建的實體" renderId

-- | 給機器看的穩定識別碼。
--
-- 'StoreFailed' 往內取 'StoreError' 的建構子名,而不是一律回
-- @store_failed@:對 Agent 來說「revision 過時」與「檔案已存在」是兩種要用
-- 不同方式重試的失敗,壓成同一個代碼等於沒給資訊。
errorCode :: ServiceError -> Text
errorCode = \case
  StoreFailed e -> storeErrorCode e
  RegistryUnavailable _ -> "registry_unavailable"
  RegistryLoadFailed _ -> "registry_load_failed"
  ValidationFailed _ _ -> "validation_failed"
  UnknownType _ -> "unknown_type"
  DanglingLinkTarget _ -> "dangling_link_target"
  CrossVaultUnsupported _ -> "cross_vault_unsupported"
  LevelTreeInvalid _ _ -> "level_tree_invalid"

storeErrorCode :: StoreError -> Text
storeErrorCode = \case
  VaultNotFound _ -> "vault_not_found"
  VaultConfigInvalid _ _ -> "vault_config_invalid"
  VaultAlreadyExists _ -> "vault_already_exists"
  EntityNotFound _ -> "entity_not_found"
  StaleRevision _ _ _ -> "stale_revision"
  IdCollision _ -> "id_collision"
  FileReadFailed _ _ -> "file_read_failed"
  FileWriteFailed _ _ -> "file_write_failed"
  IndexUpdateFailed _ _ -> "index_update_failed"
  ParseFailed _ _ -> "parse_failed"
  ReferencedBy _ _ -> "referenced_by"
  NotAFileMain _ -> "not_a_file_main"
  NotAFragment _ -> "not_a_fragment"
  NodeDepthExceeded _ _ -> "node_depth_exceeded"
  CannotRemoveRootNode _ -> "cannot_remove_root_node"
  LinkNotFound _ _ _ -> "link_not_found"
  FileAlreadyExists _ -> "file_already_exists"
  TreeInvalid _ _ -> "tree_invalid"
  RegistryDirUnknown _ -> "registry_dir_unknown"
  SqliteError _ -> "sqlite_error"

-- | 型別警告的繁中訊息。
--
-- 放在 service 而不是 @core@:'Aapms.Core.Registry' 是零 IO 的純模型,
-- 而「要不要把這件事講給人聽、怎麼講」是介面層的決定。@core@ 那一層只負責
-- 判斷發生了什麼。
renderEntityWarning :: EntityWarning -> Text
renderEntityWarning = \case
  MissingRequiredField ty f ->
    "型別「" <> ty <> "」把 " <> f <> " 宣告為必填,但這個實體沒有填"
  LinkNotAllowed ty k ->
    "關聯「"
      <> k
      <> "」不在型別「"
      <> ty
      <> "」的 allowed_links 裡;引擎會照存,但不會對它做任何推論"
  UnknownEntityType t ->
    "型別「"
      <> t
      <> "」不在型別註冊表裡;欄位提示與關聯檢查對它不會生效"
      <> "(檔案層主體的型別本來就常常不在註冊表裡,由 owner_type 認領)"
