-- | @aapms-service@ 的線上格式與錯誤語彙(design.md「內部模組劃分」的 Types)。
--
-- 擁有的事實(唯一真相來源):__線上格式__——契約 C \/ B 的全部 View 型別;
-- 以及__錯誤語彙__——'errorCode' 的 snake_case 識別碼與 'renderServiceError' 的
-- 繁中訊息。三個殼(CLI \/ HTTP \/ MCP)共用的 @code@ 與訊息只有這一份
-- (system.md 全域錯誤策略第 1 條)。
--
-- __全部 View 型別住這裡__(2026-08-30 WAVE-2 閘門 ASM-1):契約卡的「負責模組」指的是
-- 誰__實作那些操作__,不是型別住哪。View 散進六個模組會讓 @shell@ 要 import 六處
-- 才拿得齊一個回應,而「線上格式」這個事實依知識歸屬只能有一個持有者。實作那些
-- 操作的模組('Aapms.Service.Machine' 等)在自己的匯出清單裡原地 re-export,
-- 消費端的 import 路徑因此不受影響。
--
-- __本模組不得 import 本套件的任何其他模組__(design.md「Types 為什麼要獨立」):
-- 'ServiceError' 捧著下層的 'StoreError' \/ 'WorkspaceError' \/ 'RegistryError',
-- 而其餘六個模組每一個都回 @Either 'ServiceError' a@;型別定義與錯誤型別若分居
-- 兩處就是相依環。本模組只依賴 @aapms-core@ \/ @aapms-store@ \/ @aapms-types@ \/
-- @aapms-workspace@ 的型別。
--
-- __建構子逐波擴充__(build-log DEC-1 \/ 配號表):F001 只寫契約 F 的前四個建構子
-- (執行環境開得起來所需的那些);'UnknownType' 由 F002 加入(@showType@ 的失敗
-- 路徑);'ValidationFailed' 起的其餘建構子屬 F003–F006 的範圍,由編排者在該波的
-- 白名單裡明確授權後加入。這與 @aapms-workspace@ 的 Types「一次寫齊」相反,理由是
-- 本子系統的波次__不平行__(build-log 排程表),沒有併發互蓋的風險,而分波加入能
-- 讓每一波的 -Wincomplete-patterns 直接指出還沒處理的建構子。
module Aapms.Service.Types
  ( -- * 契約 C:本機 View 型別
    SetupView (..)
  , PurgeView (..)
  , VaultView (..)
  , VaultInfoView (..)
  , DoctorView (..)
  , ProjectView (..)

    -- * 契約 F:錯誤
  , ServiceError (..)
  , errorCode
  , renderServiceError
  ) where

import Data.Text (Text)

import Aapms.Core.Id (Id, VaultId)
import Aapms.Core.Registry (RegistryError, renderRegistryError)
import Aapms.Store.Error (StoreError, renderStoreError)
import Aapms.Store.Schema (IndexIssue, VaultKind)
import Aapms.Types.Loader (RegistrySource)
import Aapms.Workspace.Types
  ( HubSource
  , ScopeIssue
  , ToolStatus
  , WorkspaceError
  , renderWorkspaceError
  )

--------------------------------------------------------------------------------
-- 契約 C:本機 View 型別

-- | @workspace setup@ 的線上投影:'Aapms.Workspace.Types.SetupReport' 的三欄
-- 逐欄對應(@spHubPath@ \/ @spHubCreated@ \/ @spCacheCreated@)。
--
-- 'svHubPath' 是__中樞根目錄__(等於 'Aapms.Workspace.Types.hlPath'),不是
-- @config.toml@ 的路徑。
data SetupView = SetupView
  { svHubPath :: FilePath
  -- ^ 中樞根目錄。
  , svHubCreated :: Bool
  -- ^ 這次呼叫__建立了__中樞註冊表檔;@False@ = 它本來就在。
  , svCacheCreated :: Bool
  -- ^ 這次呼叫__建立了__縮圖快取目錄;@False@ = 它本來就在。
  }
  deriving stock (Show, Eq)

-- | @workspace purge@ 的線上投影:'Aapms.Workspace.Types.PurgeReport' 的三欄
-- 逐欄對應(@prHubRemoved@ \/ @prThumbsRemoved@ \/ @prVaultIndexesRemoved@)。
data PurgeView = PurgeView
  { pvHubRemoved :: Bool
  -- ^ 中樞註冊表檔本來存在且已被刪除。
  , pvThumbsRemoved :: Int
  -- ^ 被刪掉的縮圖檔數,@>= 0@。
  , pvVaultIndexesRemoved :: [FilePath]
  -- ^ 被刪掉的每個 vault 索引檔路徑;'Aapms.Workspace.Types.PurgeHubOnly' 時
  -- 恒為空清單。
  }
  deriving stock (Show, Eq)

-- | 一個 vault 在本機的樣子(design.md 契約 C)。
--
-- 前四欄逐欄來自中樞的那一列(或未註冊 vault 的 marker),後兩欄是本層對「這一列
-- 現在還算不算數」的兩個判斷。
data VaultView = VaultView
  { vvId :: VaultId
  , vvName :: Text
  , vvKind :: VaultKind
  , vvPath :: FilePath
  -- ^ vault 根目錄的絕對路徑。
  , vvRegistered :: Bool
  -- ^ @False@ = 這是向上探測到、但__不在中樞__的 vault。讓 @doctor@ 說得出
  -- 「你在一個未註冊的 vault 裡」。
  , vvReachable :: Bool
  -- ^ @False@ = 路徑不存在或 marker 讀不出來;對應 @aapms-workspace@ 的
  -- 'Aapms.Workspace.Types.VaultPathMissing' \/
  -- 'Aapms.Workspace.Types.VaultMarkerBroken'。
  -- 'Aapms.Workspace.Types.VaultIdDrift' __不__使本欄為 @False@:marker 讀得到、
  -- 路徑也在,只是身分與中樞記的那一列不符。
  }
  deriving stock (Show, Eq)

-- | @vault info@ 的結果:一筆 'VaultView' 加上__要開索引才算得出來__的兩欄。
data VaultInfoView = VaultInfoView
  { viVault :: VaultView
  , viCounts :: [(Text, Int)]
  -- ^ 節點數。鍵是 'Aapms.Core.Id.IdPrefix' 的文字表示
  -- (@ent@ \/ @ast@ \/ @pck@ \/ …),值 @> 0@;數量為零的 prefix __不出現__。
  , viIssues :: [IndexIssue]
  -- ^ 該 vault 被開啟時一併回報的索引問題清單。
  }
  deriving stock (Show, Eq)

-- | @workspace doctor@ 的結果:這台機器的狀態彙總。
--
-- 這是唯一一個「彙總這台機器狀態」的地方。組合的全部來自 @aapms-workspace@ 與
-- graph-core,__不 import 任何領域子系統__。
data DoctorView = DoctorView
  { dvHubPath :: FilePath
  -- ^ 中樞根目錄。
  , dvHubSource :: HubSource
  -- ^ 中樞位置是怎麼決定的。
  , dvRegistry :: RegistrySource
  -- ^ 型別註冊表是從三層定位的哪一層找到的。
  , dvVaults :: [VaultView]
  , dvScopeIssues :: [ScopeIssue]
  , dvTools :: [ToolStatus]
  , dvLlmConfigured :: Bool
  -- ^ @True@ ⟺ 中樞有 @[llm]@ 段。__只報告有沒有,不報告內容__——鍵與語意屬
  -- @ai@ 子系統,而且金鑰不該進診斷輸出。
  }
  deriving stock (Show, Eq)

-- | 一個已登錄專案在本機的樣子(design.md 契約 C)。
data ProjectView = ProjectView
  { pvId :: Id
  , pvName :: Text
  , pvPath :: FilePath
  -- ^ 專案根目錄的絕對路徑。
  , pvReachable :: Bool
  -- ^ @False@ = 那個路徑不是既存目錄。
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 契約 F:錯誤

-- | @aapms-service@ 的__唯一__錯誤型別(design.md 契約 F)。不得另立平行的錯誤
-- 型別再橋接——多一個型別就是多一套 @render*@,@shell@ 也會看到兩種形狀。
--
-- 下層錯誤__原樣包、不重寫訊息__:前四個建構子都捧著下層的錯誤原件,訊息由對方的
-- @render*@ 產生;本層擁有的是 @code@(哪一類失敗),不是訊息。'UnknownType'
-- 相反:它是__本層自己的判斷__(下面沒有對應的錯誤原件),訊息因此也由本層擁有。
data ServiceError
  = -- | graph-core 的落地失敗,原件。訊息委派
    -- 'Aapms.Store.Error.renderStoreError'
    StoreFailed StoreError
  | -- | @aapms-workspace@ 的工作區設定失敗,原件。訊息委派
    -- 'Aapms.Workspace.Types.renderWorkspaceError'
    WorkspaceFailed WorkspaceError
  | -- | 型別註冊表__定位不到__(三層都沒找到,或環境變數指向不存在的目錄):
    -- 'Aapms.Types.Loader.locateRegistry' 回的原件。與 'RegistryLoadFailed' 分成
    -- 兩個建構子是因為 @code@ 要分得出「去裝\/去設環境變數」與「型別宣告寫錯了」
    RegistryUnavailable RegistryError
  | -- | 型別註冊表__載入失敗__(目錄找到了但內容不合規):
    -- 'Aapms.Types.Loader.loadRegistry' 回的原件
    RegistryLoadFailed RegistryError
  | -- | 註冊表裡沒有這個型別鍵(F002 的 @showType@;F004 起的寫入路徑同用)。
    -- 酬載是__那個鍵的字串本身__,不是別的訊息
    UnknownType Text
  deriving stock (Show, Eq)

-- | 機器用的穩定識別碼:snake_case、__不帶產品前綴__(legacy MCP 的
-- @story_flow_*@ 在此退場)。
--
-- 規則只有一條:__建構子名的 snake_case__(@StoreFailed@ → @store_failed@)。
-- 規則寫下來而不是逐條列舉,是為了讓後續波次加建構子時不必回頭問「這個該叫
-- 什麼」——@code@ 表因此不是一份要維護的對照表,而是建構子名的函數。
--
-- 責任範圍是 'ServiceError' 的__全部__建構子;回傳恒非空、兩兩相異。
errorCode :: ServiceError -> Text
errorCode = \case
  StoreFailed _ -> "store_failed"
  WorkspaceFailed _ -> "workspace_failed"
  RegistryUnavailable _ -> "registry_unavailable"
  RegistryLoadFailed _ -> "registry_load_failed"
  UnknownType _ -> "unknown_type"

-- | 繁中訊息,__每一則說出下一步該做什麼__(system.md 全域錯誤策略第 2 條)。
--
-- 四個__包裝__建構子一律逐字委派下層的 @render*@,本層一個字都不加:
-- 'Aapms.Store.Error.renderStoreError' \/
-- 'Aapms.Workspace.Types.renderWorkspaceError' \/
-- 'Aapms.Core.Registry.renderRegistryError'。加前綴會讓同一則訊息在 @service@
-- 與在下層各長一個樣,而下層的訊息已經寫過「下一步」。
--
-- 兩個註冊表建構子因此渲染成__相同__的文字;分辨它們是 'errorCode' 的責任。
--
-- 'UnknownType' __本層自撰、不委派__:它下面沒有對應的錯誤原件可委派,判斷是
-- 本層做的,訊息也就屬本層。訊息必須帶出那個鍵,並說出兩條下一步。
renderServiceError :: ServiceError -> Text
renderServiceError = \case
  StoreFailed e -> renderStoreError e
  WorkspaceFailed e -> renderWorkspaceError e
  RegistryUnavailable e -> renderRegistryError e
  RegistryLoadFailed e -> renderRegistryError e
  UnknownType k ->
    "型別註冊表裡沒有「"
      <> k
      <> "」這個型別鍵。用 type list 看目前有哪些型別,或到型別註冊表目錄"
      <> "(types/registry/)補一份宣告後重試。"
