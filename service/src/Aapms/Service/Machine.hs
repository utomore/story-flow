-- | 本機與註冊表門面(design.md「內部模組劃分」的 Machine;契約 C)。
--
-- 這一層把 @aapms-workspace@ 的生命週期那一組、型別註冊表與縮圖快取包成
-- 'Aapms.Service.Monad.ServiceM' 動作(唯一的例外是 'workspaceSetup',見下),
-- 並把下層的報告型別投影成__線上格式__。三個殼(CLI \/ HTTP \/ MCP)看到的本機
-- 操作只有這一份。
--
-- 擁有的事實(唯一真相來源):__無__。design.md「內部模組劃分」對 Machine 的
-- 「擁有的事實」欄是 @—@ ——本模組是門面,每一個事實都屬於下層:中樞的內容屬
-- @aapms-workspace@、型別宣告屬 @aapms-types@、索引內容屬 graph-core。本模組
-- 只負責__投影__與__組合__。
--
-- == View 型別住 'Aapms.Service.Types',本模組原地 re-export
--
-- 'SetupView' \/ 'PurgeView' \/ 'VaultView' \/ 'VaultInfoView' \/ 'DoctorView' \/
-- 'ProjectView' 六個型別__宣告在__ 'Aapms.Service.Types'(design.md「內部模組
-- 劃分」的 Types 列:「全部 View 型別住這裡」;2026-08-30 W2 閘門 A1),本模組在
-- 匯出清單裡原地 re-export ——消費端要嘛從 Types 拿型別、要嘛從本模組連同操作
-- 一起拿,兩條路指向同一個型別。
--
-- 投影是__單向無狀態__的:'SetupView' \/ 'PurgeView' 是 @aapms-workspace@ 的
-- 'Aapms.Workspace.Types.SetupReport' \/ 'Aapms.Workspace.Types.PurgeReport' 的
-- 線上投影(欄位一一對應、語意與值域相同)。線上格式屬本層,被投影的事實仍屬
-- @aapms-workspace@(@boundary-rules.md@ 的知識歸屬:投影函數可以住在消費端,
-- 被投影的事實不行)。
--
-- 'Aapms.Store.Schema.VaultKind' \/ 'Aapms.Workspace.Types.InitMode' \/
-- 'Aapms.Workspace.Types.DeleteIndex' \/ 'Aapms.Workspace.Types.PurgeScope' \/
-- 'Aapms.Workspace.Types.ScopeIssue' \/ 'Aapms.Workspace.Types.ToolStatus' \/
-- 'Aapms.Workspace.Types.HubSource' 一律 __re-export 不重新定義__
-- (design.md 契約 C):那些是判斷,不是投影。
--
-- == 'workspaceSetup' 不在 'Aapms.Service.Monad.ServiceM' 裡
--
-- 它要在__中樞還不存在__時就跑得起來,而 'Aapms.Service.Monad.openEnv' 對
-- 「中樞載不起來」一律回 @Left@(契約 A;主架構全域錯誤策略第 3 條)。留在
-- @ServiceM@ 裡等於這個操作永遠跑不到、@svHubCreated@ 恒為 @False@,而 @shell@
-- 依 ADR-015 又不能自己建中樞(2026-08-30 W2 閘門 A2)。它與
-- 'Aapms.Service.Monad.openEnv' __同層__:兩個參數同形,回一個 @Either@。
--
-- == 明確不做(契約卡)
--
-- 不重新定義中樞的檔案格式;__不自己拼 @.aapms\/@ 底下的路徑__(一律用
-- @aapms-workspace@ 與 graph-core 的函式,守衛是 L26);不把 7-Zip 缺席當錯誤;
-- 不決定 HTTP 狀態碼與終端輸出(@shell@);不做任何圖譜寫入(F004 起)。
--
-- == 兩條 F001 的既有 law 對本模組生效
--
-- F001 的 __L23__:本檔的程式碼行不得提到 'Aapms.Service.Monad' 那個唯一的執行
-- 入口(巢狀會死結)——本模組交出去的是 'Aapms.Service.Monad.ServiceM' 動作,
-- 執行是 @shell@ 的事;'workspaceSetup' 雖然是頂層 IO,也__不得__自己跑那個入口
-- (它根本不需要 @Env@)。F001 的 __L25__:本檔不得有任何 @instance@ 宣告或
-- standalone deriving。
module Aapms.Service.Machine
  ( -- * 契約 C:本機 View 型別(宣告在 "Aapms.Service.Types",此處 re-export)
    SetupView (..)
  , PurgeView (..)
  , VaultView (..)
  , VaultInfoView (..)
  , DoctorView (..)
  , ProjectView (..)

    -- * 契約 C:工作區
  , workspaceSetup
  , workspaceDoctor
  , workspaceTools
  , workspacePurge

    -- * 契約 C:vault 生命週期
  , vaultInit
  , vaultAdd
  , vaultList
  , vaultInfo
  , vaultForget
  , vaultCheck

    -- * 契約 C:專案登錄
  , projectRegister
  , projectList
  , projectForget

    -- * 契約 C:型別註冊表
  , listTypes
  , showType

    -- * 契約 C:縮圖快取
  , thumbPath

    -- * re-export(契約 C:一律 re-export 不重新定義)
  , VaultKind (..)
  , InitMode (..)
  , DeleteIndex (..)
  , PurgeScope (..)
  , ScopeIssue (..)
  , ToolStatus (..)
  , ToolOrigin (..)
  , HubSource (..)
  , IndexIssue (..)
  , AdoptNotice (..)
  ) where

import Data.Text (Text)

import Aapms.Core.Asset (Sha256)
import Aapms.Core.Meta (TypeKey)
import Aapms.Core.Registry (TypeDecl)
import Aapms.Store.Schema (IndexIssue (..), VaultKind (..))
import Aapms.Workspace.Types
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , HubSource (..)
  , InitMode (..)
  , PurgeScope (..)
  , ScopeIssue (..)
  , ToolOrigin (..)
  , ToolStatus (..)
  )

import Aapms.Service.Monad (ServiceM)
import Aapms.Service.Types
  ( DoctorView (..)
  , ProjectView (..)
  , PurgeView (..)
  , ServiceError
  , SetupView (..)
  , VaultInfoView (..)
  , VaultView (..)
  )

--------------------------------------------------------------------------------
-- 契約 C:工作區

-- | 建立中樞註冊表檔與縮圖快取目錄;冪等。
--
-- __不在 'ServiceM' 裡__(2026-08-30 W2 閘門 A2):它是「先於環境」的操作,要在
-- 中樞還不存在時就跑得起來。兩個參數與 'Aapms.Service.Monad.openEnv' 同形
-- (selector 與向上探測的起點),讓 @shell@ 對本機子指令用同一種分派;__本層都不
-- 解讀__——中樞位置由 @aapms-workspace@ 的 'Aapms.Workspace.Location.hubLocation'
-- 從 @AAPMS_HOME@ 與平台預設決定,與這兩個參數無關。
--
-- 兩個 @*Created@ 欄讓 @shell@ 分得出「剛裝好」與「早就裝好」。
workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)
workspaceSetup = undefined

-- | 彙總這台機器的狀態:中樞位置與來源、註冊表來源、全部 vault(含向上探測到
-- 的那個未註冊 vault)、範圍降級紀錄、外部工具、以及中樞有沒有 @[llm]@ 段。
--
-- __不寫任何檔案__。
workspaceDoctor :: ServiceM DoctorView
workspaceDoctor = undefined

-- | 探測這台機器上的外部工具。7-Zip 缺席__不是錯誤__。
workspaceTools :: ServiceM [ToolStatus]
workspaceTools = undefined

-- | 清理中樞與(可選)各 vault 的索引;冪等。
--
-- 任何 'Aapms.Workspace.Types.PurgeScope' 下都不刪除任何素材檔與 vault 的
-- marker——索引是衍生物,重建即可。
workspacePurge :: PurgeScope -> ServiceM PurgeView
workspacePurge = undefined

--------------------------------------------------------------------------------
-- 契約 C:vault 生命週期

-- | 在一個目錄上建立 vault 並登錄進中樞。
--
-- 參數依序是:vault 根目錄、@kind@(__必填,不猜__)、名稱、
-- 'Aapms.Workspace.Types.InitMode'。
--
-- 第二個回傳值是 @aapms-workspace@ 掃到的舊 marker 清單(__只報告不刪除__;
-- 2026-08-30 W2 閘門 A3):'VaultView' 六欄裝不下它,而丟棄等於 workspace 花力氣
-- 掃出來的東西在這一層被揉掉。
vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)
vaultInit = undefined

-- | 把一個__已經是 vault__ 的目錄納管進中樞。不建立、不修改該目錄下的任何東西。
vaultAdd :: FilePath -> ServiceM VaultView
vaultAdd = undefined

-- | 中樞裡的每一列各回一筆,順序同中樞。
vaultList :: ServiceM [VaultView]
vaultList = undefined

-- | 一個 vault 的詳情。參數是 selector(比對規則由 @aapms-workspace@ 決定)。
--
-- 這是本模組唯一__要開索引__的操作:節點數算不出來就沒有這個操作。目標是
-- __這個參數指到的 vault__,不是 @--vault@ 解出來的讀取範圍(2026-08-30 W2 閘門
-- A4),所以本操作直接用 'Aapms.Service.Monad.handleFor' 對目標取 handle。
vaultInfo :: Text -> ServiceM VaultInfoView
vaultInfo = undefined

-- | 把一個 vault 從中樞移除。第二參數決定要不要順手刪索引檔;marker 與素材
-- __任何情況都不碰__。
vaultForget :: Text -> DeleteIndex -> ServiceM VaultView
vaultForget = undefined

-- | 對中樞每一列重讀 marker 的純體檢。__不寫任何檔案、沒有失敗通道__。
vaultCheck :: ServiceM [ScopeIssue]
vaultCheck = undefined

--------------------------------------------------------------------------------
-- 契約 C:專案登錄

-- | 把一個目錄登錄成專案。參數依序是:專案根目錄、名稱。
projectRegister :: FilePath -> Text -> ServiceM ProjectView
projectRegister = undefined

-- | 中樞裡的每一列各回一筆,順序同中樞。
projectList :: ServiceM [ProjectView]
projectList = undefined

-- | 把一列從中樞移除。專案目錄本身完全不動。
projectForget :: Text -> ServiceM ProjectView
projectForget = undefined

--------------------------------------------------------------------------------
-- 契約 C:型別註冊表

-- | 型別註冊表的全部宣告,順序同 @aapms-core@ 的排序(本層不過濾、不重排)。
--
-- __與 'Aapms.Core.Registry.listTypes' 同名__:本層的版本不收參數,註冊表來自
-- 'Aapms.Service.Monad.askRegistry'。取用下層那一個時必須 qualified。
listTypes :: ServiceM [TypeDecl]
listTypes = undefined

-- | 依鍵查一份型別宣告。註冊表沒有這個鍵時以
-- 'Aapms.Service.Types.UnknownType' 短路,酬載是__那個鍵的字串本身__。
showType :: TypeKey -> ServiceM TypeDecl
showType = undefined

--------------------------------------------------------------------------------
-- 契約 C:縮圖快取

-- | 一個內容位址對應的縮圖檔在哪裡。
--
-- @Nothing@ = 快取裡__沒有這個檔__;@Just p@ = @p@ 存在且可讀。位置由
-- @aapms-workspace@ 算,本層只多做一次存在性檢查——__不自己拼路徑__。
--
-- 本操作__不碰位元組、不解碼影像__:@shell@ 拿到路徑後自己回檔案。
thumbPath :: Sha256 -> ServiceM (Maybe FilePath)
thumbPath = undefined
