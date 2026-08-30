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
-- 劃分」的 Types 列:「全部 View 型別住這裡」;2026-08-30 WAVE-2 閘門 ASM-1),本模組在
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
-- 依 ADR-015 又不能自己建中樞(2026-08-30 WAVE-2 閘門 ASM-2)。它與
-- 'Aapms.Service.Monad.openEnv' __同層__:兩個參數同形,回一個 @Either@。
--
-- == 明確不做(契約卡)
--
-- 不重新定義中樞的檔案格式;__不自己拼 @.aapms\/@ 底下的路徑__(一律用
-- @aapms-workspace@ 與 graph-core 的函式,守衛是 LAW-26);不把 7-Zip 缺席當錯誤;
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

import Control.Monad.IO.Class (liftIO)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import Aapms.Core.Asset (Sha256)
import Aapms.Core.Id (VaultId, idPrefix, renderIdPrefix)
import Aapms.Core.Meta (Meta (metaId), TypeKey (..))
import Aapms.Core.Registry (TypeDecl)
import qualified Aapms.Core.Registry as Registry
import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName))
import Aapms.Store.Query (NodeFilter (..), emptyNodeFilter, listNodes)
import Aapms.Store.Schema (IndexIssue (..), VaultKind (..))
import Aapms.Workspace.Discovery
  ( detectVault
  , lookupSelector
  , readVaultRef
  , readVaultRefAt
  )
import Aapms.Workspace.Lifecycle
  ( addVault
  , checkVaults
  , forgetVault
  , initVault
  , purge
  , setupHub
  )
import Aapms.Workspace.Location (hubLocation, thumbCachePath)
import Aapms.Workspace.Projects (forgetProject, registerProject)
import Aapms.Workspace.Tools (detectSevenZip)
import Aapms.Workspace.Types
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , Hub
  , HubLocation (..)
  , HubSource (..)
  , InitMode (..)
  , ProjectEntry (..)
  , PurgeReport (..)
  , PurgeScope (..)
  , ScopeIssue (..)
  , SetupReport (..)
  , ToolOrigin (..)
  , ToolStatus (..)
  , VaultEntry (..)
  , VaultRef (..)
  , hubLlm
  , hubProjects
  , hubTools
  , hubVaults
  )
import System.Directory (doesDirectoryExist, doesFileExist)

import Aapms.Service.Monad
  ( ServiceM
  , askCwd
  , askHub
  , askHubLocation
  , askRegistry
  , askRegistrySource
  , handleFor
  , indexIssuesFor
  , liftWorkspace
  , reloadHub
  , throwService
  )
import Aapms.Service.Types
  ( DoctorView (..)
  , ProjectView (..)
  , PurgeView (..)
  , ServiceError (..)
  , SetupView (..)
  , VaultInfoView (..)
  , VaultView (..)
  )

--------------------------------------------------------------------------------
-- 契約 C:工作區

-- | 建立中樞註冊表檔與縮圖快取目錄;冪等。
--
-- __不在 'ServiceM' 裡__(2026-08-30 WAVE-2 閘門 ASM-2):它是「先於環境」的操作,要在
-- 中樞還不存在時就跑得起來。兩個參數與 'Aapms.Service.Monad.openEnv' 同形
-- (selector 與向上探測的起點),讓 @shell@ 對本機子指令用同一種分派;__本層都不
-- 解讀__——中樞位置由 @aapms-workspace@ 的 'Aapms.Workspace.Location.hubLocation'
-- 從 @AAPMS_HOME@ 與平台預設決定,與這兩個參數無關。
--
-- 兩個 @*Created@ 欄讓 @shell@ 分得出「剛裝好」與「早就裝好」。
workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)
workspaceSetup _sel _cwd = do
  loc <- hubLocation
  result <- setupHub loc
  pure $ case result of
    Left e -> Left (WorkspaceFailed e)
    Right report ->
      Right (SetupView (spHubPath report) (spHubCreated report) (spCacheCreated report))

-- | 彙總這台機器的狀態:中樞位置與來源、註冊表來源、全部 vault(含向上探測到
-- 的那個未註冊 vault)、範圍降級紀錄、外部工具、以及中樞有沒有 @[llm]@ 段。
--
-- __不寫任何檔案__。
workspaceDoctor :: ServiceM DoctorView
workspaceDoctor = do
  loc <- askHubLocation
  hub <- askHub
  regSrc <- askRegistrySource
  issues <- liftIO (checkVaults hub)
  let registered = map (vaultViewOf issues) (hubVaults hub)
  cwd <- askCwd
  extra <- liftIO (unregisteredVaultView hub cwd)
  tools <- workspaceTools
  pure
    DoctorView
      { dvHubPath = hlPath loc
      , dvHubSource = hlSource loc
      , dvRegistry = regSrc
      , dvVaults = registered ++ maybe [] (: []) extra
      , dvScopeIssues = issues
      , dvTools = tools
      , dvLlmConfigured = maybe False (const True) (hubLlm hub)
      }

-- | 探測這台機器上的外部工具。7-Zip 缺席__不是錯誤__。
workspaceTools :: ServiceM [ToolStatus]
workspaceTools = do
  hub <- askHub
  status <- liftIO (detectSevenZip (hubTools hub))
  pure [status]

-- | 清理中樞與(可選)各 vault 的索引;冪等。
--
-- 任何 'Aapms.Workspace.Types.PurgeScope' 下都不刪除任何素材檔與 vault 的
-- marker——索引是衍生物,重建即可。
workspacePurge :: PurgeScope -> ServiceM PurgeView
workspacePurge scope = do
  loc <- askHubLocation
  hub <- askHub
  report <- liftWorkspace (purge loc hub scope)
  pure
    (PurgeView (prHubRemoved report) (prThumbsRemoved report) (prVaultIndexesRemoved report))

--------------------------------------------------------------------------------
-- 契約 C:vault 生命週期

-- | 在一個目錄上建立 vault 並登錄進中樞。
--
-- 參數依序是:vault 根目錄、@kind@(__必填,不猜__)、名稱、
-- 'Aapms.Workspace.Types.InitMode'。
--
-- 第二個回傳值是 @aapms-workspace@ 掃到的舊 marker 清單(__只報告不刪除__;
-- 2026-08-30 WAVE-2 閘門 ASM-3):'VaultView' 六欄裝不下它,而丟棄等於 workspace 花力氣
-- 掃出來的東西在這一層被揉掉。
vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)
vaultInit dir kind name mode = do
  loc <- askHubLocation
  hub <- askHub
  (_, entry, notice) <- liftWorkspace (initVault loc hub dir kind name mode)
  _ <- reloadHub
  pure (registeredView entry, notice)

-- | 把一個__已經是 vault__ 的目錄納管進中樞。不建立、不修改該目錄下的任何東西。
vaultAdd :: FilePath -> ServiceM VaultView
vaultAdd dir = do
  loc <- askHubLocation
  hub <- askHub
  (_, entry) <- liftWorkspace (addVault loc hub dir)
  _ <- reloadHub
  pure (registeredView entry)

-- | 中樞裡的每一列各回一筆,順序同中樞。
vaultList :: ServiceM [VaultView]
vaultList = do
  hub <- askHub
  issues <- liftIO (checkVaults hub)
  pure (map (vaultViewOf issues) (hubVaults hub))

-- | 一個 vault 的詳情。參數是 selector(比對規則由 @aapms-workspace@ 決定)。
--
-- 這是本模組唯一__要開索引__的操作:節點數算不出來就沒有這個操作。目標是
-- __這個參數指到的 vault__,不是 @--vault@ 解出來的讀取範圍(2026-08-30 WAVE-2 閘門
-- ASM-4),所以本操作直接用 'Aapms.Service.Monad.handleFor' 對目標取 handle。
vaultInfo :: Text -> ServiceM VaultInfoView
vaultInfo sel = do
  hub <- askHub
  entry <- liftWorkspace (pure (lookupSelector hub sel))
  ref <- liftWorkspace (readVaultRefAt hub (vePath entry))
  handle <- handleFor ref
  metas <-
    liftIO (listNodes handle emptyNodeFilter {nfLimit = maxBound, nfIncludeReference = True})
  issues <- liftIO (checkVaults hub)
  issuesOut <- indexIssuesFor (veId entry)
  pure (VaultInfoView (vaultViewOf issues entry) (countByPrefix metas) issuesOut)

-- | 把一個 vault 從中樞移除。第二參數決定要不要順手刪索引檔;marker 與素材
-- __任何情況都不碰__。
vaultForget :: Text -> DeleteIndex -> ServiceM VaultView
vaultForget sel di = do
  loc <- askHubLocation
  hub <- askHub
  (_, entry) <- liftWorkspace (forgetVault loc hub sel di)
  _ <- reloadHub
  reachable <- liftIO (reachableSingle entry)
  pure
    VaultView
      { vvId = veId entry
      , vvName = veName entry
      , vvKind = veKind entry
      , vvPath = vePath entry
      , vvRegistered = False
      , vvReachable = reachable
      }

-- | 對中樞每一列重讀 marker 的純體檢。__不寫任何檔案、沒有失敗通道__。
vaultCheck :: ServiceM [ScopeIssue]
vaultCheck = do
  hub <- askHub
  liftIO (checkVaults hub)

--------------------------------------------------------------------------------
-- 契約 C:專案登錄

-- | 把一個目錄登錄成專案。參數依序是:專案根目錄、名稱。
projectRegister :: FilePath -> Text -> ServiceM ProjectView
projectRegister dir name = do
  loc <- askHubLocation
  hub <- askHub
  (_, entry) <- liftWorkspace (registerProject loc hub dir name)
  _ <- reloadHub
  liftIO (projectViewOf entry)

-- | 中樞裡的每一列各回一筆,順序同中樞。
projectList :: ServiceM [ProjectView]
projectList = do
  hub <- askHub
  liftIO (mapM projectViewOf (hubProjects hub))

-- | 把一列從中樞移除。專案目錄本身完全不動。
projectForget :: Text -> ServiceM ProjectView
projectForget sel = do
  loc <- askHubLocation
  hub <- askHub
  (_, entry) <- liftWorkspace (forgetProject loc hub sel)
  _ <- reloadHub
  liftIO (projectViewOf entry)

--------------------------------------------------------------------------------
-- 契約 C:型別註冊表

-- | 型別註冊表的全部宣告,順序同 @aapms-core@ 的排序(本層不過濾、不重排)。
--
-- __與 'Aapms.Core.Registry.listTypes' 同名__:本層的版本不收參數,註冊表來自
-- 'Aapms.Service.Monad.askRegistry'。取用下層那一個時必須 qualified。
listTypes :: ServiceM [TypeDecl]
listTypes = do
  reg <- askRegistry
  pure (Registry.listTypes reg)

-- | 依鍵查一份型別宣告。註冊表沒有這個鍵時以
-- 'Aapms.Service.Types.UnknownType' 短路,酬載是__那個鍵的字串本身__。
showType :: TypeKey -> ServiceM TypeDecl
showType k = do
  reg <- askRegistry
  case Registry.lookupType reg k of
    Just d -> pure d
    Nothing -> throwService (UnknownType (typeKeyText k))
  where
    typeKeyText (TypeKey t) = t

--------------------------------------------------------------------------------
-- 契約 C:縮圖快取

-- | 一個內容位址對應的縮圖檔在哪裡。
--
-- @Nothing@ = 快取裡__沒有這個檔__;@Just p@ = @p@ 存在且可讀。位置由
-- @aapms-workspace@ 算,本層只多做一次存在性檢查——__不自己拼路徑__。
--
-- 本操作__不碰位元組、不解碼影像__:@shell@ 拿到路徑後自己回檔案。
thumbPath :: Sha256 -> ServiceM (Maybe FilePath)
thumbPath h = do
  loc <- askHubLocation
  let p = thumbCachePath loc h
  exists <- liftIO (doesFileExist p)
  pure (if exists then Just p else Nothing)

--------------------------------------------------------------------------------
-- 私有 helper

-- | 依同一份 'checkVaults' 結果,判斷某個 vault 現在算不算「可達」(design.md
-- 不可逆決定第二列:'VaultIdDrift' 仍算可達)。
reachableFor :: VaultId -> [ScopeIssue] -> Bool
reachableFor vid issues = maybe True reachableFromIssue (find (relatesTo vid) issues)
  where
    relatesTo v (VaultPathMissing e _) = veId e == v
    relatesTo v (VaultMarkerBroken e _) = veId e == v
    relatesTo v (VaultIdDrift e _) = veId e == v
    relatesTo _ (RefVaultNotRegistered _ _) = False

reachableFromIssue :: ScopeIssue -> Bool
reachableFromIssue (VaultIdDrift _ _) = True
reachableFromIssue (RefVaultNotRegistered _ _) = True
reachableFromIssue _ = False

-- | 單一 vault 的可達性,不經整批 'checkVaults':'vaultForget' 移除中樞那一列
-- 之後,那一列已經不在 'checkVaults' 的掃描範圍裡,只能對它單獨重讀。
reachableSingle :: VaultEntry -> IO Bool
reachableSingle e = either reachableFromIssue (const True) <$> readVaultRef e (vePath e)

-- | 中樞一列 + 一份 'checkVaults' 結果 → 對外的 'VaultView'(已註冊)。
vaultViewOf :: [ScopeIssue] -> VaultEntry -> VaultView
vaultViewOf issues e =
  VaultView
    { vvId = veId e
    , vvName = veName e
    , vvKind = veKind e
    , vvPath = vePath e
    , vvRegistered = True
    , vvReachable = reachableFor (veId e) issues
    }

-- | 剛被寫中樞操作(@init@ \/ @add@)交回來的那一列:一定已註冊、一定可達
-- (marker 剛被寫出或剛被讀成功)。
registeredView :: VaultEntry -> VaultView
registeredView e =
  VaultView
    { vvId = veId e
    , vvName = veName e
    , vvKind = veKind e
    , vvPath = vePath e
    , vvRegistered = True
    , vvReachable = True
    }

-- | @doctor@ 向上探測到的那一筆未註冊 vault(LAW-7):探測不到、或 marker 讀不開
-- 時回 'Nothing';探測到但其實已註冊時也回 'Nothing'。
unregisteredVaultView :: Hub -> FilePath -> IO (Maybe VaultView)
unregisteredVaultView hub cwd = do
  mRoot <- detectVault cwd
  case mRoot of
    Nothing -> pure Nothing
    Just root -> do
      refR <- readVaultRefAt hub root
      pure $ case refR of
        Right ref@VaultRef {vrEntry = Nothing} -> Just (unregisteredView ref)
        _ -> Nothing

unregisteredView :: VaultRef -> VaultView
unregisteredView VaultRef {vrPath = p, vrMarker = m} =
  VaultView
    { vvId = vmId m
    , vvName = vmName m
    , vvKind = vmKind m
    , vvPath = p
    , vvRegistered = False
    , vvReachable = True
    }

-- | 一個 vault 索引裡每個 'Aapms.Core.Id.IdPrefix' 的節點總數(LAW-21):零值鍵不
-- 出現,依 'Aapms.Core.Id.IdPrefix' 的 'Ord' 排序('Data.Map.Strict' 的鍵序與
-- 宣告順序一致)。
countByPrefix :: [Meta] -> [(Text, Int)]
countByPrefix metas =
  [ (renderIdPrefix p, c)
  | (p, c) <- Map.toAscList (Map.fromListWith (+) [(idPrefix (metaId m), 1) | m <- metas])
  ]

-- | 一個已登錄專案的目錄還在不在。
projectViewOf :: ProjectEntry -> IO ProjectView
projectViewOf e = do
  reachable <- doesDirectoryExist (pePath e)
  pure (ProjectView (peId e) (peName e) (pePath e) reachable)
