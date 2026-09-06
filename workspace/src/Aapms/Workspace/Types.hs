-- | @aapms-workspace@ 全部對外型別的定義,以及 'WorkspaceError' 與
-- 'renderWorkspaceError'(design.md「內部模組劃分」的 Types)。
--
-- __本模組不得 import 本套件的任何其他模組__:'WorkspaceError' 的
-- 'VaultSelectorAmbiguous' 捧著 @['VaultEntry']@,而 'Aapms.Workspace.Hub.loadHub'
-- 又回 @Either 'WorkspaceError' 'Hub'@——型別定義與錯誤型別若分居兩處就是相依環。
-- 做法是把全部純型別與錯誤型別收在這裡,它只依賴 @aapms-core@ 與 @aapms-store@
-- 的型別,其餘六個模組全部往這裡依賴,型別歸屬圖因此是一棵樹。
--
-- 「只依賴型別」這句話現在由 import 行本身守住:@aapms-store@ 那一邊統一走
-- "Aapms.Store.Types"(該套件全部對外型別的宣告處,零 IO),不再 import
-- "Aapms.Store.Error" \/ "Aapms.Store.Marker" \/ "Aapms.Store.Schema" ——那三個模組
-- 各自帶著 sqlite 與檔案系統,拿一個型別要付整條 IO 相依鏈。
--
-- __一次寫齊,不由各 feature 逐波擴充__(build-log DEC-2):契約 A–F 的型別與
-- 'WorkspaceError' 的全部建構子都在 F001 寫完。階段二的三個 feature 平行執行,
-- 若各自往本檔加建構子,那是同一個檔案的併發寫入——互蓋當下不會有任何錯誤訊息。
--
-- 契約 C \/ D \/ E 的__函式__不在本套件的 F001 範圍內,它們住在 Discovery \/
-- Scope \/ Lifecycle \/ Projects \/ Tools;本模組只把那些函式會用到的__型別__
-- 一次宣告到位。
module Aapms.Workspace.Types
  ( -- * 契約 A:中樞位置與載入
    HubLocation (..)
  , HubSource (..)
  , Hub
  , mkHub
  , hubSourceText

    -- * 契約 B:中樞內容
  , VaultEntry (..)
  , ProjectEntry (..)
  , LlmSection (..)
  , ToolsConfig (..)
  , hubVaults
  , hubProjects
  , hubLlm
  , hubTools

    -- * 契約 C:探測與作用範圍裁決(只有型別;函式屬 F002 \/ F003)
  , VaultRef (..)
  , ScopeIssue (..)
  , ReadScope (..)
  , WriteScope (..)
  , PipelineScope (..)

    -- * 契約 D:生命週期(只有型別;函式屬 F004 \/ F005)
  , InitMode (..)
  , DeleteIndex (..)
  , PurgeScope (..)
  , SetupReport (..)
  , AdoptNotice (..)
  , PurgeReport (..)

    -- * 契約 E:本機外部工具(只有型別;函式屬 F006)
  , ToolOrigin (..)
  , ToolStatus (..)

    -- * 契約 F:錯誤
  , WorkspaceError (..)
  , renderWorkspaceError

    -- * 純增刪的請求(P-028-hub-config 的觀察點 applyHubEdits 用)
  , HubEdit (..)

    -- * P-029-scope-resolve:裁決的類別與結果
  , ScopeKind (..)
  , Scope (..)
  , scopeRefs
  , scopeIssues
  , refIds
  , isRefNotRegistered
  , selectorHits

    -- * P-029-scope-resolve:'Aapms.Workspace.Effect.Markers' 的世界(觀察點)
  , MarkerWorld (..)
  , worldMarker

    -- * P-004-vault-scope:'Aapms.Workspace.Effect.HubFile' 的世界(觀察點)
  , HubWorld (..)

    -- * P-005-vault-lifecycle:請求、結果與 'Aapms.Workspace.Effect.VaultDir' 的世界
  , LifecycleOp (..)
  , LifecycleOutcome (..)
  , LifecycleRun (..)
  , VaultWorld (..)
  , vwEntries
  , vwMarkerDir
  , vwMarker
  , vwHasIndex
  , vwDirExists
  , vwWithout

    -- * P-006-workspace-doctor:工具探測的計畫與 'Aapms.Workspace.Effect.ToolProbe' 的世界
  , ToolSearchPlan (..)
  , ToolWorld (..)
  , unreachableIds
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as T

import Aapms.Core.Id (Id, VaultId (..), renderId)
import Aapms.Store.Types (StoreError, VaultKind, VaultMarker (..), renderStoreError, renderVaultKind)
import qualified TOML

-- 契約 A:中樞位置與載入 -------------------------------------------------------

-- | 中樞根目錄與「這個位置怎麼決定的」。@doctor@ 兩者都要印。
data HubLocation = HubLocation
  { hlPath :: FilePath
  -- ^ 絕對路徑,指向__目錄__(不是 @config.toml@)。
  , hlSource :: HubSource
  }
  deriving stock (Show, Eq)

-- | 中樞位置的來源。解析順序固定兩層,__沒有第三層、不搜尋、不猜__。
data HubSource
  = -- | 環境變數 @AAPMS_HOME@ 已設且非空
    FromEnv
  | -- | 平台預設(Windows @%APPDATA%\\aapms@;其他平台 XDG)
    FromPlatformDefault
  deriving stock (Show, Eq)

-- | 已載入的中樞快照,不可變。__建構子不匯出__:'hubSourceText' 與四段結構化
-- 內容之間有「同一次載入」的不變量,允許外部逐欄拼裝就是允許拼出不一致的快照。
-- 建構走 'mkHub',讀取走 'hubVaults' \/ 'hubProjects' \/ 'hubLlm' \/ 'hubTools',
-- 增刪走 'Aapms.Workspace.Hub.upsertVault' 那一組純函式。
data Hub = Hub
  { hubVaults :: [VaultEntry]
  -- ^ 契約 B 的 getter:中樞 @[[vaults]]@ 的全部列,__保留檔案中的順序__。
  , hubProjects :: [ProjectEntry]
  -- ^ 契約 B 的 getter:中樞 @[[projects]]@ 的全部列,__保留檔案中的順序__。
  , hubLlm :: Maybe LlmSection
  -- ^ 契約 B 的 getter:@Nothing@(整段缺席)與 @Just@ 空表(設了一個空段)是
  -- __不同的兩件事__。
  , hubTools :: ToolsConfig
  -- ^ 契約 B 的 getter:@[tools]@ 段;整段缺席時每個欄位都是 @Nothing@。
  , hubSourceText :: Text
  -- ^ 載入當下的原始檔案文字,__逐字保留__。'Aapms.Workspace.Hub.saveHub' 靠它
  -- 保住使用者寫的註解與空白行(ADR-017 決策二的「可手寫」)。全新中樞(尚無
  -- 檔案)以空字串表示。
  }
  deriving stock (Show, Eq)

-- | 'Hub' 的唯一建構入口。參數順序同 'Hub' 的欄位順序:vaults、projects、llm、
-- tools、原始檔案文字。
mkHub
  :: [VaultEntry]
  -> [ProjectEntry]
  -> Maybe LlmSection
  -> ToolsConfig
  -> Text
  -> Hub
mkHub = Hub

-- 契約 B:中樞內容 -------------------------------------------------------------

-- | 中樞 @[[vaults]]@ 的一列。__鍵是 'veId'__,搬動 vault 只改 'vePath'
-- (ADR-017 決策二)。
data VaultEntry = VaultEntry
  { veId :: VaultId
  -- ^ @vlt-@ + 8 位小寫十六進位;中樞內唯一。
  , veName :: Text
  -- ^ 非空;__允許重複__。marker @vmName@ 的__快取__,不是真相。
  , veKind :: VaultKind
  -- ^ marker @vmKind@ 的__快取__,不是真相。
  , vePath :: FilePath
  -- ^ 絕對路徑,指向 vault 根目錄(__含__ @.aapms\/@ 的那一層)。路徑不是身分。
  }
  deriving stock (Show, Eq)

-- | 中樞 @[[projects]]@ 的一列。
data ProjectEntry = ProjectEntry
  { peId :: Id
  -- ^ @prj-@ + 8 位小寫十六進位;中樞內唯一。
  , peName :: Text
  -- ^ 非空。
  , pePath :: FilePath
  -- ^ 絕對路徑,指向含 @assets\/@ 與 @story\/@ 的那一層。
  }
  deriving stock (Show, Eq)

-- | 中樞 @[llm]@ 段的原樣 TOML 表。__鍵與語意屬 @ai@ 子系統__,本套件只保證
-- 「TOML 表裡有什麼,捧出來就有什麼」,不解讀任何鍵。
newtype LlmSection = LlmSection (Map Text TOML.Value)
  deriving stock (Show)
  deriving newtype (Eq)

-- | 中樞 @[tools]@ 段:外部工具的位置覆寫。
data ToolsConfig = ToolsConfig
  { tcSevenZip :: Maybe FilePath
  -- ^ 絕對路徑;@Nothing@ = __沒有覆寫__(去探測),不是「沒有 7-Zip」。
  }
  deriving stock (Show, Eq)

-- 契約 C:探測與作用範圍裁決(只有型別) ---------------------------------------

-- | 一個候選 vault 的權威身分。'vrMarker' __一律來自檔案__,中樞的
-- 'veName' \/ 'veKind' 只在 marker 讀不到時作為降級顯示。
data VaultRef = VaultRef
  { vrEntry :: Maybe VaultEntry
  -- ^ @Nothing@ ⟺ 這個 vault 不在中樞 @[[vaults]]@ 裡(向上探測到的未註冊 vault)。
  , vrPath :: FilePath
  -- ^ 絕對路徑,已正規化;指向含 @.aapms\/@ 的那一層。
  , vrMarker :: VaultMarker
  -- ^ 權威的 @id@ \/ @kind@ \/ @name@ \/ @refs@。
  }
  deriving stock (Show, Eq)

-- | 降級紀錄。__不中止查詢__,由 @shell@ 印成警告。
data ScopeIssue
  = -- | 中樞的那一列、它指的__不存在__的路徑
    VaultPathMissing VaultEntry FilePath
  | -- | 中樞的那一列、graph-core @readMarker@ 回的__原件__(訊息由對方的
    -- 'Aapms.Store.Error.renderStoreError' 產生,這一層不翻譯)
    VaultMarkerBroken VaultEntry StoreError
  | -- | 中樞的那一列(含它記的 id)、marker 裡__實際__的 id
    VaultIdDrift VaultEntry VaultId
  | -- | @refs@ 的__來源__ vault、@refs@ 裡那個在中樞查不到的__目標__
    RefVaultNotRegistered VaultId VaultId
  deriving stock (Show, Eq)

-- | 查詢類指令的作用範圍(ADR-017:讀跨全部 vault)。
data ReadScope = ReadScope
  { rsVaults :: [VaultRef]
  -- ^ __保序去重__(以 @vmId@ 去重);可為空清單。
  , rsIssues :: [ScopeIssue]
  }
  deriving stock (Show, Eq)

-- | 寫入類指令的作用範圍(ADR-017:寫單一)。
data WriteScope = WriteScope
  { wsTarget :: VaultRef
  -- ^ 恰好一個;__恒不來自 @refs@ 展開__。
  , wsRead :: [VaultRef]
  -- ^ 保序去重;@refs@ 展開進來的一律唯讀。
  , wsIssues :: [ScopeIssue]
  }
  deriving stock (Show, Eq)

-- | 管線類指令的作用範圍(對每個符合 @kind@ 的 vault 各跑一次)。
data PipelineScope = PipelineScope
  { psRuns :: [VaultRef]
  -- ^ 保序去重;每個各跑一次,每次只寫自己的索引。
  , psIssues :: [ScopeIssue]
  }
  deriving stock (Show, Eq)

-- 契約 D:生命週期(只有型別) -------------------------------------------------

-- | @vault init@ 的兩種模式(ADR-017 決策六,2026-08-29 由 @vault migrate@ 收成)。
data InitMode
  = -- | 目錄不存在或為空,由本子系統建立
    FreshVault
  | -- | 目錄已存在且可非空,內容__一律不動__
    AdoptExisting
  deriving stock (Show, Eq)

-- | @vault forget@ 要不要順手刪索引。@config.toml@ 與 @library\/@ __任何情況都
-- 不碰__。
data DeleteIndex = KeepIndex | DeleteIndex
  deriving stock (Show, Eq)

-- | @workspace purge@ 的清理範圍。
data PurgeScope = PurgeHubOnly | PurgeAllVaults
  deriving stock (Show, Eq)

-- | @workspace setup@ 的結果。'spHubCreated' \/ 'spCacheCreated' 讓 @shell@ 分得出
-- 「剛裝好」與「早就裝好」('Aapms.Workspace.Types' 不做這件事,'setupHub' 冪等)。
data SetupReport = SetupReport
  { spHubPath :: FilePath
  , spHubCreated :: Bool
  , spCacheCreated :: Bool
  }
  deriving stock (Show, Eq)

-- | @vault init --adopt@ 在目標目錄下發現的舊 marker。__只報告不刪除__。
newtype AdoptNotice = AdoptNotice
  { anLegacyMarkers :: [FilePath]
  -- ^ 絕對路徑;可為空。@.assetdb\/@ 或 @.storyflow\/@。
  }
  deriving stock (Show, Eq)

-- | @workspace purge@ 的結果。'prVaultIndexesRemoved' 只列 @index.db@ 路徑——
-- 任何情況不碰 @library\/@ 與任何 @.md@。
data PurgeReport = PurgeReport
  { prHubRemoved :: Bool
  , prThumbsRemoved :: Int
  , prVaultIndexesRemoved :: [FilePath]
  }
  deriving stock (Show, Eq)

-- 契約 E:本機外部工具(只有型別) ---------------------------------------------

-- | 找到的執行檔__哪裡來的__。
data ToolOrigin
  = -- | 中樞 @[tools]@ 的覆寫
    FromToolsConfig
  | -- | PATH 上找到
    FromPath
  | -- | 內建候選清單
    FromCandidate
  | -- | 三層都沒找到(__不是錯誤__)
    NotFound
  deriving stock (Show, Eq)

-- | 一個外部工具的探測結果。7-Zip 缺席不是錯誤,所以本型別__一律回得出來__。
data ToolStatus = ToolStatus
  { tsName :: Text
  -- ^ 給人看的工具名,如 @"7-Zip"@。
  , tsPath :: Maybe FilePath
  -- ^ 絕對路徑;@Nothing@ ⟺ @'tsOrigin' == 'NotFound'@。
  , tsOrigin :: ToolOrigin
  , tsSearched :: [FilePath]
  -- ^ 依序、去重;@'NotFound'@ 時__必為非空__——訊息要說出下一步。
  }
  deriving stock (Show, Eq)

-- 契約 F:錯誤 -----------------------------------------------------------------

-- | @aapms-workspace@ 的__唯一__錯誤型別。不得另立平行的錯誤型別再橋接——多一個
-- 型別就是多一套 @render*@ 與多一次翻譯,@service@ 也會看到兩種形狀。
--
-- 'MarkerUnreadable' 捧著 'StoreError' 而不是字串:訊息由 graph-core 的
-- 'Aapms.Store.Error.renderStoreError' 產生,這一層不翻譯。
data WorkspaceError
  = -- | 中樞 @config.toml@ 不存在。__不回空中樞__:空註冊表會把「你還沒跑
    -- @workspace setup@」偽裝成「你一個 vault 都沒有」
    HubNotFound FilePath
  | -- | 中樞檔案讀不進來或 TOML 解不開;'Text' 是原因
    HubUnreadable FilePath Text
  | -- | TOML 解得開但欄位不合規;'Text' 指出是哪一段哪個欄位、為什麼不合規
    HubMalformed FilePath Text
  | -- | 中樞檔案寫不出去;'Text' 是原因
    HubWriteFailed FilePath Text
  | -- | @--vault@ 的字串在中樞比不到任何 'veId' 或 'veName'
    VaultSelectorNotFound Text
  | -- | 撞名。清單必須列出__全部__撞名的列(含 id 與路徑),使用者才知道改用哪個 id
    VaultSelectorAmbiguous Text [VaultEntry]
  | -- | vault 的 id、要求的 kind、實際的 kind
    VaultKindMismatch VaultId VaultKind VaultKind
  | -- | 沒給 @--vault@,且從這個起點一路向上都沒有 @.aapms\/@
    NoWriteTarget FilePath
  | -- | 該目錄已經有 @.aapms\/@;@vault init@ __不覆寫__該檔
    VaultAlreadyInitialized FilePath
  | -- | 'AdoptExisting' 要求目錄存在,但它不存在
    VaultDirMissing FilePath
  | -- | 'FreshVault' 要求目錄不存在或為空,但它非空
    VaultDirNotEmpty FilePath
  | -- | 撞到的 'VaultId'、__中樞裡既有__那個 vault 的路徑、__這次要建立__的路徑
    -- ——兩個路徑都要印,使用者才看得出是不是自己複製了整個 vault 目錄
    VaultIdCollision VaultId FilePath FilePath
  | -- | 寫入目標已經鎖定到這個 vault(中樞記的 id、它的路徑),但重讀 marker
    -- 發現實際的 id 不是這個——寫入目標決定不了就該硬失敗,不猜(ADR-017)。
    -- 讀取路徑上同一件事是 'ScopeIssue.VaultIdDrift' 的降級,不是這裡
    -- (2026-08-29 WAVE-3 閘門新增)
    WriteTargetIdDrift VaultId FilePath VaultId
  | -- | vault 根目錄、graph-core @readMarker@ 回的原件
    MarkerUnreadable FilePath StoreError
  | -- | selector 在中樞比不到任何 'peId' 或 'peName'
    ProjectSelectorNotFound Text
  | -- | 專案名、那個不存在的路徑
    ProjectPathMissing Text FilePath
  | -- | selector 字串、__全部__撞名的 'ProjectEntry'。借用 'ProjectSelectorNotFound'
    -- 會說「找不到」,但其實找到了兩個以上(2026-08-29 WAVE-4 閘門新增)
    ProjectSelectorAmbiguous Text [ProjectEntry]
  | -- | 既有那一列的 'peId'、它的路徑。同一個路徑註冊兩次時 'pePath' 沒有唯一性
    -- 要求,靜默發第二個 id 是合法的,但中樞會出現兩列指同一個目錄
    -- (2026-08-29 WAVE-4 閘門新增)
    ProjectAlreadyRegistered Id FilePath
  | -- | vault 根目錄、graph-core 的 'StoreError' 原件。'initVaultAt' __建__ marker
    -- 失敗,不是讀失敗——借用 'MarkerUnreadable' 會叫使用者去看一個還沒被建出來
    -- 的檔(2026-08-29 WAVE-4 閘門新增)
    VaultInitFailed FilePath StoreError
  | -- | 中樞那一列的 'veId'、該 vault 的 'vePath'、marker 裡實際的 'VaultId'。與
    -- 'WriteTargetIdDrift' 完全對稱,構成「寫入目標漂移 \/ 刪除目標漂移」家族,
    -- 但這條路徑上__沒有__寫入目標,也__不該__建議重新執行 @vault add@ 以外的
    -- 動作(2026-08-29 WAVE-4 閘門新增)
    DeleteTargetIdDrift VaultId FilePath VaultId
  | -- | 收到的原始字串(去除前後空白後長度為 0)
    InvalidName Text
  deriving stock (Show, Eq)

-- | 繁中訊息,__每一則說出下一步該做什麼__(system.md 全域錯誤處理策略第 2 條;
-- 與 'Aapms.Store.Error.renderStoreError' 同一個模式)。
--
-- 責任範圍是 'WorkspaceError' 的__全部__建構子,不再有第二個 @render*@;每一則
-- 都要含該建構子攜帶的路徑 \/ 名稱 \/ id。
renderWorkspaceError :: WorkspaceError -> Text
renderWorkspaceError = \case
  HubNotFound fp ->
    pack fp
      <> ": 找不到中樞設定檔(config.toml 不存在);請先執行 workspace setup 建立"
  HubUnreadable fp reason ->
    pack fp
      <> ": 中樞設定檔讀取失敗 —— "
      <> reason
      <> ";請確認檔案存在、可讀,且是合法的 TOML"
  HubMalformed fp reason ->
    pack fp <> ": 中樞設定檔內容不合規 —— " <> reason <> ";請修正後再試"
  HubWriteFailed fp reason ->
    pack fp <> ": 中樞設定檔寫入失敗 —— " <> reason <> ";請確認目錄存在且可寫"
  VaultSelectorNotFound s ->
    "找不到符合「"
      <> s
      <> "」的 vault;請確認 id 或名稱是否正確,或先執行 vault list 查看可用的 vault"
  VaultSelectorAmbiguous s es ->
    "「"
      <> s
      <> "」在中樞裡比對到多個 vault:"
      <> T.intercalate "、" (map ambiguousEntry es)
      <> ";請改用完整的 id 指定"
  VaultKindMismatch vid want got ->
    "vault "
      <> unVaultId vid
      <> " 的種類是 "
      <> renderVaultKind got
      <> ",與要求的 "
      <> renderVaultKind want
      <> " 不符;請改用符合種類的 vault,或改用 --vault 指定其他 vault"
  NoWriteTarget start ->
    pack start
      <> ": 從這裡向上找不到任何 .aapms 目錄,且未指定 --vault;"
      <> "請先執行 vault init,或改用 --vault 指定寫入目標"
  VaultAlreadyInitialized dir ->
    pack dir
      <> ": 這個目錄已經是 vault(.aapms 已存在);請改用既有的 vault,或指定其他空目錄"
  VaultDirMissing dir ->
    pack dir <> ": 目錄不存在,無法採用既有內容;請確認路徑,或改用建立全新 vault 的模式"
  VaultDirNotEmpty dir ->
    pack dir
      <> ": 目錄非空,無法建立全新 vault;請改用採用既有內容的模式,或指定空目錄"
  VaultIdCollision vid old new ->
    "vault id "
      <> unVaultId vid
      <> " 已經被 "
      <> pack old
      <> " 使用,無法再指派給 "
      <> pack new
      <> ";這通常是整個 vault 目錄被複製過,請只保留其中一個,"
      <> "或對新的那一份重新執行 vault init"
  WriteTargetIdDrift registered dir actual ->
    "寫入目標 "
      <> pack dir
      <> " 在中樞裡登記的 id 是 "
      <> unVaultId registered
      <> ",但 vault marker 裡實際的 id 是 "
      <> unVaultId actual
      <> "(id 已經漂移);寫入目標無法確定,請先執行 vault check 或 syncHub 更新中樞,"
      <> "或對這個目錄重新執行 vault add"
  MarkerUnreadable root e ->
    pack root <> ": 讀取 vault marker 失敗 —— " <> renderStoreError e <> ";請確認後再試"
  ProjectSelectorNotFound s ->
    "找不到符合「"
      <> s
      <> "」的專案;請確認 id 或名稱是否正確,或先執行 project list 查看可用的專案"
  ProjectPathMissing name fp ->
    "專案「" <> name <> "」指向的路徑 " <> pack fp <> " 不存在;請確認路徑,或改用其他專案"
  ProjectSelectorAmbiguous s es ->
    "「"
      <> s
      <> "」在中樞裡比對到多個專案:"
      <> T.intercalate "、" (map ambiguousProjectEntry es)
      <> ";請改用完整的 id 指定"
  ProjectAlreadyRegistered pid fp ->
    "路徑 "
      <> pack fp
      <> " 已經以專案 id "
      <> renderId pid
      <> " 登記在中樞裡;如果要用新名稱重新登記,請先執行 forget 取消這一筆既有登記,"
      <> "再重新註冊"
  VaultInitFailed dir e ->
    pack dir <> ": 建立 vault marker 失敗 —— " <> renderStoreError e <> ";請確認後再試"
  DeleteTargetIdDrift vid dir actual ->
    "中樞記錄的 vault "
      <> unVaultId vid
      <> " 應該在 "
      <> pack dir
      <> ",但這個路徑實際上是另一個 vault(id 是 "
      <> unVaultId actual
      <> ");為避免刪錯 vault,請改用不加 --delete-index 的 vault forget 只移除中樞登記,"
      <> "再執行 vault check 或 vault add 重新登記正確的位置"
  InvalidName raw ->
    "名稱「" <> raw <> "」不合法(去除前後空白後為空);請提供非空的名稱"
  where
    pack = T.pack
    unVaultId (VaultId t) = t
    ambiguousEntry e = unVaultId (veId e) <> "(" <> pack (vePath e) <> ")"
    ambiguousProjectEntry e = renderId (peId e) <> "(" <> pack (pePath e) <> ")"

-- | 對 'Hub' 值的四種純增刪,依序套用(P-028-hub-config 的 LAW-2 前提:
-- 快照來自 'Aapms.Workspace.Hub.parseHubText' 再經這些增刪)。
data HubEdit
  = PutVault VaultEntry
  | DropVault VaultId
  | PutProject ProjectEntry
  | DropProject Id
  deriving stock (Show, Eq)

-- P-029-scope-resolve:裁決的類別與結果 ----------------------------------------

-- | 這一次裁決要的是哪一種範圍。三種 scope 共用 selector 解析、重讀 marker 與
-- @refs@ 展開,只在最後一步分流,所以收成一個標籤加一列
-- 'Aapms.Workspace.Resolve.resolveScope'(P-029 的決定)。
data ScopeKind
  = -- | 查詢類:讀跨全部生效的 vault
    ForRead
  | -- | 寫入類:恰好一個寫入目標,加它的讀取範圍
    ForWrite
  | -- | 管線類:kind 相符的那些,各跑一次
    ForPipeline VaultKind
  deriving stock (Show, Eq)

-- | 一次裁決的結果,與 'ScopeKind' 一一對應。
data Scope
  = SRead ReadScope
  | SWrite WriteScope
  | SPipeline PipelineScope
  deriving stock (Show, Eq)

-- | 觀察:三種 scope 的 vault 清單(寫入 scope 是目標開頭的 'wsRead')。
scopeRefs :: Scope -> [VaultRef]
scopeRefs = \case
  SRead rs -> rsVaults rs
  SWrite ws -> wsRead ws
  SPipeline ps -> psRuns ps

-- | 觀察:三種 scope 的降級紀錄。
scopeIssues :: Scope -> [ScopeIssue]
scopeIssues = \case
  SRead rs -> rsIssues rs
  SWrite ws -> wsIssues ws
  SPipeline ps -> psIssues ps

-- | 觀察:每個 ref 的 marker id。__身分來自 marker__,不是中樞那一列。
refIds :: [VaultRef] -> [VaultId]
refIds = map (vmId . vrMarker)

-- | 觀察:是不是 'RefVaultNotRegistered'。
isRefNotRegistered :: ScopeIssue -> Bool
isRefNotRegistered = \case
  RefVaultNotRegistered _ _ -> True
  _ -> False

-- | 觀察:selector 生效的命中集合(id 命中非空就是它,否則是 name 命中),
-- 順序同 'hubVaults'。
--
-- 兩階段都__逐字精確__比對:不去空白、不忽略大小寫、不做前綴比對。這是
-- 'Aapms.Workspace.Resolve.lookupSelector' 的判定依據,兩者必須是同一套規則。
selectorHits :: Hub -> Text -> [VaultEntry]
selectorHits h s
  | not (null byId) = byId
  | otherwise = byName
  where
    entries = hubVaults h
    byId = filter ((== VaultId s) . veId) entries
    byName = filter ((== s) . veName) entries

-- P-029-scope-resolve:Markers 的世界 ------------------------------------------

-- | 'Aapms.Workspace.Effect.Markers' 的純解譯器跑在這張表上:路徑 → marker 讀數,
-- 加上「哪些路徑是既存目錄」。正規化在純世界裡是恆等,所以世界本身不記它。
data MarkerWorld = MarkerWorld
  { mwMarkers :: Map FilePath (Either StoreError VaultMarker)
  -- ^ 路徑 → 那個路徑上讀 marker 的結果;不在表上 = 讀不到任何 marker。
  , worldDirs :: [FilePath]
  -- ^ 觀察:世界裡存在的目錄(含 @.aapms@ 這種 marker 目錄本身)。
  }
  deriving stock (Show, Eq)

-- | 空世界:沒有任何 marker、沒有任何目錄。
instance Monoid MarkerWorld where
  mempty = MarkerWorld mempty []

-- | 併兩個世界:marker 表左偏,目錄清單相接。
instance Semigroup MarkerWorld where
  a <> b = MarkerWorld (mwMarkers a <> mwMarkers b) (worldDirs a <> worldDirs b)

-- | 觀察:某路徑在世界裡的 marker 讀數;@Nothing@ = 那個路徑上讀不到任何 marker。
worldMarker :: MarkerWorld -> FilePath -> Maybe (Either StoreError VaultMarker)
worldMarker w p = Map.lookup p (mwMarkers w)

-- P-004-vault-scope:HubFile 的世界 --------------------------------------------

-- | 'Aapms.Workspace.Effect.HubFile' 的純解譯器跑在這上面:中樞位置固定,中樞檔
-- 的全文有或沒有。
data HubWorld = HubWorld
  { hubTextIn :: Maybe Text
  -- ^ 觀察:世界裡的中樞文字;@Nothing@ = 中樞檔不存在。
  , hubLocationIn :: HubLocation
  -- ^ 觀察:世界裡的中樞位置與它的來源。
  }
  deriving stock (Show, Eq)

-- P-005-vault-lifecycle:請求、結果與 VaultDir 的世界 --------------------------

-- | 十個生命週期操作收成一個請求 sum(P-005 的決定):全部走「前置檢查 → 改 Hub
-- 值 → 原子寫回」同一條紀律。
data LifecycleOp
  = -- | 建中樞目錄與縮圖快取;冪等,完全不碰既有的 @config.toml@
    SetupHub
  | -- | vault 目錄、種類、名稱、模式
    InitVault FilePath VaultKind Text InitMode
  | -- | 把一個已經是 vault 的目錄納管;身分一律來自 marker
    AddVault FilePath
  | -- | selector、要不要順手刪索引
    ForgetVault Text DeleteIndex
  | -- | 中樞逐列重讀 marker,只報告不回寫
    CheckVaults
  | -- | 以 marker 修中樞的 name \/ kind
    SyncHub
  | -- | 清理範圍
    Purge PurgeScope
  | -- | 專案目錄、專案名
    RegisterProject FilePath Text
  | -- | 專案 selector
    ForgetProject Text
  deriving stock (Show, Eq)

-- | 一次生命週期請求的結果。每個欄位只有相關的請求會填,其餘是 @Nothing@ \/ 空。
data LifecycleOutcome = LifecycleOutcome
  { outcomeHub :: Maybe Hub
  -- ^ 觀察:結果裡的新 'Hub' 值;@Nothing@ = 這個請求不改中樞。
  , outcomeEntry :: Maybe VaultEntry
  -- ^ 觀察:被加入或移除的 vault 列。
  , outcomeNotice :: Maybe AdoptNotice
  -- ^ 觀察:@--adopt@ 在目標目錄第一層發現的舊 marker。
  , outcomeProject :: Maybe ProjectEntry
  -- ^ 觀察:被加入或移除的專案列。
  , outcomeIssues :: [ScopeIssue]
  -- ^ 觀察:'CheckVaults' \/ 'SyncHub' 的漂移紀錄。
  , outcomeSetup :: Maybe SetupReport
  -- ^ 觀察:'SetupHub' 的報告。
  , outcomePurge :: Maybe PurgeReport
  -- ^ 觀察:'Purge' 的報告。
  }
  deriving stock (Show, Eq)

-- | 'Aapms.Workspace.Effect.VaultDir' 的純解譯器跑在這棵記憶體目錄樹上。
data VaultWorld = VaultWorld
  { vwTree :: Map FilePath [FilePath]
  -- ^ 目錄 → 它第一層的名字,保序;不在表上 = 那個路徑不是既存目錄。
  , vwMarkers :: Map FilePath (Either StoreError VaultMarker)
  -- ^ vault 根目錄 → 讀 marker 的結果。
  , vwMarkerDirs :: Set FilePath
  -- ^ @.aapms@ 這個路徑被佔用的 vault 根目錄(目錄或檔案都算)。
  , vwIndexDbs :: Set FilePath
  -- ^ 有 @index.db@ 的 vault 根目錄。
  }
  deriving stock (Show, Eq)

-- | 觀察:目錄第一層的名字。
vwEntries :: VaultWorld -> FilePath -> [FilePath]
vwEntries _vw _d = error "P-005#vwEntries stub"

-- | 觀察:@.aapms@ 路徑被佔用。
vwMarkerDir :: VaultWorld -> FilePath -> Bool
vwMarkerDir _vw _d = error "P-005#vwMarkerDir stub"

-- | 觀察:marker 讀數。
vwMarker :: VaultWorld -> FilePath -> Maybe (Either StoreError VaultMarker)
vwMarker _vw _d = error "P-005#vwMarker stub"

-- | 觀察:@index.db@ 在不在。
vwHasIndex :: VaultWorld -> FilePath -> Bool
vwHasIndex _vw _d = error "P-005#vwHasIndex stub"

-- | 觀察:目錄在不在。
vwDirExists :: VaultWorld -> FilePath -> Bool
vwDirExists _vw _d = error "P-005#vwDirExists stub"

-- | 觀察:拿掉這些路徑後的目錄樹(比較「其餘不動」用)。
vwWithout :: [FilePath] -> VaultWorld -> VaultWorld
vwWithout _ps _vw = error "P-005#vwWithout stub"

-- | 一次 'LifecycleOp' 在純世界裡跑完之後看得到的三件事。
data LifecycleRun a = LifecycleRun
  { lcResult :: a
  -- ^ 觀察:結果。
  , lcHubText :: Maybe Text
  -- ^ 觀察:最終中樞文字(沒有檔就 @Nothing@)。
  , lcVaults :: VaultWorld
  -- ^ 觀察:最終目錄樹。
  , hubWorldAfter :: HubWorld
  -- ^ 觀察:跑完之後的中樞世界(拿來接著跑下一個請求)。
  }
  deriving stock (Show, Eq)

-- P-006-workspace-doctor:工具探測 ----------------------------------------------

-- | 三層探測裡__可以被替換掉的那兩層__的來源(自 "Aapms.Workspace.Tools" 搬進
-- 型別層:'Aapms.Workspace.Tools.Plan.probes' 是純函數,不能依賴 shell 模組)。
data ToolSearchPlan = ToolSearchPlan
  { tspExeExtension :: String
  -- ^ 平台的可執行檔副檔名(Windows 是 @".exe"@,其他平台是 @""@)。這是 shell 才知道的
  -- 平台事實,由 `!` 列用 @System.Directory.exeExtension@ 填進來;純層的 `probes` 只拿它拼路徑。
  , tspPathDirs :: [FilePath]
  -- ^ 第二層:要當成 @PATH@ 來掃的目錄清單,__保留順序__。真實呼叫時是 @PATH@
  -- 環境變數切開的結果;該變數未設時是空清單(不是失敗)。
  , tspCandidates :: [FilePath]
  -- ^ 第三層:要逐一探測的__完整檔案路徑__清單,__保留順序__。
  }
  deriving stock (Show, Eq)

-- | 'Aapms.Workspace.Effect.ToolProbe' 的純解譯器跑在這上面。
data ToolWorld = ToolWorld
  { executables :: [FilePath]
  -- ^ 觀察:世界裡可執行的路徑。
  , twPathDirs :: [FilePath]
  -- ^ @PATH@ 拆開後的目錄清單,保序。
  }
  deriving stock (Show, Eq)

-- | 觀察:'VaultPathMissing' 與 'VaultMarkerBroken' 點到的列的 id
-- ('VaultIdDrift' 不算)。
unreachableIds :: [ScopeIssue] -> [VaultId]
unreachableIds _iss = error "P-006#unreachableIds stub"
