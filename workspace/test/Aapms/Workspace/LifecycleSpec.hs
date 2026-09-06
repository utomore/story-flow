-- | F004:中樞建立('setupHub',LAW-1-LAW-5\/EX-1-EX-5)、vault 的建立與納管('initVault'\/'addVault',
-- LAW-6-LAW-24\/EX-6-EX-24)、撤除('forgetVault'\/'purge',LAW-25-LAW-30,LAW-37-LAW-41\/EX-25-EX-29,EX-37-EX-40)、體檢與回寫
-- ('checkVaults'\/'syncHub',LAW-31-LAW-36\/EX-30-EX-36)、七個函式合起來的檔案系統足跡(LAW-43)、
-- WAVE-4 閘門追加的刪索引身分驗證(LAW-44-LAW-47\/EX-41-EX-45)、依賴方向與職責界線
-- (LAW-42(a)-(f),__預期綠__——見 spec「紅綠預期」)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F004-vault-lifecycle.md@,
-- 預期欄依 @spec-roles.md@「qa 的交付判準」逐條標:七個函式的本體全是 @undefined@,
-- 所以除了 LAW-42(a)-(f) 之外__一律預期紅__):
--
-- @
-- STEP-1 setupHub
-- LAW-1  冪等且不改位元組                          -> test_setup_hub_is_idempotent            [紅]
-- LAW-2  setupHub 之後 loadHub 一定成功              -> test_setup_hub_then_load_hub_succeeds   [紅]
-- LAW-3  兩個 Bool 的判準                           -> test_setup_hub_flags_reflect_prior_state [紅]
-- LAW-4  既有檔案完全不碰、不解析                    -> test_setup_hub_never_parses_existing_file[紅]
-- LAW-5  只建這兩個東西                             -> test_setup_hub_creates_only_two_things   [紅]
-- EX-1-EX-5                                          -> 對應各 test_setup_hub_*
--
-- STEP-2 initVault 前置檢查
-- LAW-6  名稱檢查最先,且不碰檔案系統                -> test_init_vault_rejects_blank_name_first [紅]
-- LAW-7  已被佔用一律 VaultAlreadyInitialized        -> test_init_vault_already_initialized_both_modes / test_init_vault_marker_path_taken_by_file [紅]
-- LAW-8  FreshVault 的目錄前置                       -> test_init_vault_fresh_rejects_non_empty  [紅]
-- LAW-9  AdoptExisting 的目錄前置                    -> test_init_vault_adopt_requires_existing_dir [紅]
-- LAW-10 判定順序恆定                               -> test_init_vault_precheck_has_no_side_effects [紅]
-- LAW-11 前置檢查失敗一律零副作用                    -> 分散在 EX-6-EX-10 各測試的位元組不變斷言       [紅]
-- EX-6-EX-10                                          -> 對應各 test_init_vault_*
--
-- STEP-3 initVault 成功路徑
-- LAW-12 marker 是真相,VaultEntry 是它的投影         -> test_init_vault_entry_mirrors_marker     [紅]
-- LAW-13 中樞只多一列,其餘三段不動                   -> test_init_vault_appends_one_row_only     [紅]
-- LAW-14 真的落地了(loadHub 讀得回來、註解仍在)      -> test_init_vault_persists_and_keeps_comments [紅]
-- LAW-15 AdoptExisting 不動既有內容                  -> test_init_vault_adopt_keeps_existing_files [紅]
-- LAW-17 空索引一定被建出來                          -> test_init_vault_creates_empty_index      [紅]
-- LAW-20 任何 Left 都不動中樞檔案                    -> 分散在各前置檢查\/撞號\/LAW-44 測試            [紅]
-- LAW-44 initVaultAt 失敗 -> VaultInitFailed,不留半成品 -> test_init_vault_init_failure_is_vault_init_failed [紅]
-- EX-11-EX-15, EX-41                                    -> 對應各 test_init_vault_*
--
-- STEP-4 initVault 撞號
-- LAW-18 撞號的三個值                               -> test_init_vault_id_collision_carries_both_paths [紅]
-- LAW-19 撞號要回滾                                 -> test_init_vault_id_collision_rolls_back  [紅]
-- EX-18, EX-19                                        -> 對應各 test_init_vault_id_collision_*
--
-- STEP-5 AdoptNotice
-- LAW-16 AdoptNotice 的內容、順序、不遞迴             -> test_adopt_notice_lists_legacy_markers / test_adopt_notice_order_is_fixed / test_adopt_notice_is_not_recursive [紅]
-- EX-15, EX-16, EX-17                                   -> 對應各 test_adopt_notice_*
--
-- STEP-6 addVault
-- LAW-21 身分一律來自 marker                         -> test_add_vault_identity_from_marker      [紅]
-- LAW-22 讀不到 marker 是硬失敗                      -> test_add_vault_unreadable_marker_is_hard_failure [紅]
-- LAW-23 以 id 為鍵,重複納管不長第二列               -> test_add_vault_is_idempotent / test_add_vault_updates_path_on_move [紅]
-- LAW-24 不動 vault 目錄                            -> test_add_vault_touches_nothing           [紅]
-- EX-20-EX-24                                         -> 對應各 test_add_vault_*
--
-- STEP-7 forgetVault
-- LAW-25 selector 規則同 lookupSelector              -> test_forget_vault_selector_rules         [紅]
-- LAW-26 selector 失敗零副作用                       -> test_forget_vault_selector_failure_has_no_side_effects [紅]
-- LAW-27 KeepIndex:只動中樞                         -> test_forget_vault_keep_index             [紅]
-- LAW-28 DeleteIndex:只多刪一個檔                   -> test_forget_vault_delete_index_only_removes_index [紅]
-- LAW-29 刪索引失敗不算失敗                          -> test_forget_vault_missing_index_is_ok    [紅]
-- LAW-30 回傳被移除的那一列                          -> 併入 test_forget_vault_keep_index / test_forget_vault_missing_index_is_ok [紅]
-- EX-25-EX-29                                         -> 對應各 test_forget_vault_*
--
-- STEP-8 checkVaults
-- LAW-31 內容與順序                                 -> test_check_vaults_lists_issues_in_order  [紅]
-- LAW-32 不寫任何東西,也沒有失敗通道                 -> test_check_vaults_writes_nothing         [紅]
-- LAW-33 不展開 refs                                -> test_check_vaults_does_not_expand_refs   [紅]
-- EX-30-EX-32                                         -> 對應各 test_check_vaults_*
--
-- STEP-9 syncHub
-- LAW-34 只修 veName\/veKind                        -> test_sync_hub_fixes_name_and_kind_only   [紅]
-- LAW-35 issue 清單等於 checkVaults                 -> test_sync_hub_issues_match_check_vaults  [紅]
-- LAW-36 方向只有 marker -> 中樞;沒有漂移就不寫      -> test_sync_hub_never_writes_marker / test_sync_hub_no_drift_no_write [紅]
-- EX-33-EX-36                                         -> 對應各 test_sync_hub_*
--
-- STEP-10 purge
-- LAW-37 PurgeHubOnly 的範圍                        -> test_purge_hub_only_scope                [紅]
-- LAW-38 PurgeHubOnly 不碰任何 vault                -> test_purge_hub_only_leaves_vaults_alone  [紅]
-- LAW-39 PurgeAllVaults 只多刪 index.db             -> test_purge_all_vaults_removes_indexes_only [紅]
-- LAW-40 任何 PurgeScope 都不刪 library\/ 與 .md     -> test_purge_never_touches_library_or_md   [紅]
-- LAW-41 冪等                                       -> test_purge_is_idempotent                 [紅]
-- EX-37-EX-40                                         -> 對應各 test_purge_*
--
-- STEP-11 七個函式合起來的檔案系統足跡
-- LAW-43                                             -> test_lifecycle_filesystem_footprint      [紅]
--
-- STEP-12 WAVE-4 裁決 B:刪索引前的身分驗證
-- LAW-45 forgetVault 刪索引前先驗身分                -> test_forget_vault_delete_index_rejects_id_drift / test_forget_vault_keep_index_ignores_drift [紅]
-- LAW-46 purge PurgeAllVaults 是全有或全無            -> test_purge_all_vaults_is_all_or_nothing  [紅]
-- LAW-47 驗身分不改變「讀不到就照刪」                -> test_delete_index_still_proceeds_when_marker_unreadable [紅]
-- EX-42-EX-45                                         -> 對應各測試
--
-- LAW-42(預期綠):依賴方向與職責界線(以 import 行驗證)
-- (a) 無 Scope\/Projects\/Tools,只准 Types\/Location\/Hub\/Discovery -> test_lifecycle_no_sibling_imports          [綠]
-- (b) Aapms.Store.Marker 的 import(若有)逐字比對(含 readMarker)     -> test_lifecycle_marker_import_is_exact      [綠]
-- (c) Aapms.Store.Schema 只取 VaultKind,非條件式                     -> test_lifecycle_schema_import_is_type_only  [綠]
-- (d) 不得 import Aapms.Store.Atomic                                  -> test_lifecycle_never_imports_atomic        [綠]
-- (e) 不得 import Store 門面\/Index\/MultiVault\/Query\/Write\/Create\/Edit -> test_lifecycle_never_imports_index_modules [綠]
-- (f) 不得 import System.Process                                      -> test_lifecycle_no_process_import           [綠]
-- @
--
-- __(以上 EX-18\/EX-19\/EX-41 三條 pending 已由 E001 收掉,見下方 E001 對照;
-- 舊版「以固定時間\/名稱造出撞號」的非決定性構造說明已隨之作廢,不再適用。)__
--
-- __E001__(@.design\/subsystems\/workspace\/enhancements\/E001-init-vault-explicit-time.md@):
-- 新增 'initVaultWith'(@initVault@ 的明碼時間版本),收掉上面 F004 的三條
-- @pendingWith@(GAP-4\/GAP-5 尾巴)。骨架只有 'initVaultWith' 是 @undefined@,其餘六個
-- 函式(含 'initVault')本體都已是現況實作,__預期欄不再是一律紅__,逐條見下:
--
-- @
-- E001 回歸 law(現況程式碼,骨架未動)
-- REG-1  initVault 簽名逐字不變                    -> 由既有呼叫端持續以 6 參數呼叫 initVault 編譯通過保證(STEP-2\/STEP-3\/STEP-4\/STEP-11 各測試) [綠]
-- REG-2  前置檢查四條不變                          -> 既有 STEP-2 測試 + test_init_vault_rejected_when_already_initialized_by_prior_init (EX-8) [綠]
-- REG-3  成功時身分逐欄來自 marker                 -> test_init_vault_entry_mirrors_marker + test_init_vault_happy_path_alchbees_assets (EX-1) [綠]
-- REG-4  initVault 仍每次取當下時間                -> test_init_vault_takes_current_time_each_call (EX-9) [綠]
-- REG-5  initVault 建檔失敗 -> VaultInitFailed,不留半成品 -> test_init_vault_init_failure_is_vault_init_failed (EX-7,= F004 EX-41\/LAW-44,已從 pendingWith 轉正) [綠]
-- REG-6  LAW-42 其餘五條(a)(c)(d)(e)(f)不放寬          -> 既有 test_lifecycle_* 各測試,未變動 [綠]
--
-- E001 新 law(全部經 initVaultWith,骨架 undefined)
-- LAW-1  決定性:同名同時間、不同空目錄 veId 相同    -> test_init_vault_with_same_time_same_id (EX-3) + property [紅]
-- LAW-2  id 的來源逐字可算(newId PVlt …)            -> test_init_vault_with_id_matches_new_id_formula (EX-4) + property [紅]
-- LAW-3  薄包裝等價(除 veId 外逐欄相同)             -> property「LAW-3(property): …」;另由 EX-1 與 EX-3\/EX-4 對照覆蓋 [紅]
-- LAW-4  撞號的三個值                               -> test_init_vault_id_collision_carries_both_paths (EX-5,= F004 EX-18\/LAW-18,已從 pendingWith 轉正) [紅]
-- LAW-5  撞號要回滾                                 -> test_init_vault_id_collision_rolls_back (EX-6,= F004 EX-19\/LAW-19,已從 pendingWith 轉正) [紅]
-- LAW-6  Aapms.Store.Marker import 行新逐字字串(取代 F004 LAW-42(b)) -> test_lifecycle_marker_import_is_exact [紅——骨架的 import 行尚未加 initVaultAtWith]
-- LAW-7  initVaultWith 建檔失敗 -> VaultInitFailed,不留半成品      -> test_init_vault_with_init_failure_is_vault_init_failed (EX-10) [紅]
-- @
--
-- __L18\/LAW-19 的舊構造已棄置__:F004 原本嘗試「連續呼叫 initVaultAt 賭時間視窗夠近」
-- 撞號,本機實測會產生不同 id、不可確定性重現(即 spec-gap 本次-1,現由 E001 解決)。
-- E001 用 'initVaultWith' 收同一個明碼 @t@,決定性造出撞號,不再需要賭時間視窗。
--
-- __above LAW-1-LAW-7 的 [紅]\/[綠] 標記是本檔__骨架階段__(僅 'initVaultWith' 為
-- @undefined@)__下的預期__,依 @spec-roles.md@「qa 的交付判準」逐條標。qa 交付時
-- (2026-08-30)實際跑 @cabal test aapms-workspace-test@ 觀察到__全部 319 examples
-- 0 failures 0 pending__,含上面預期紅的 LAW-1-LAW-5\/LAW-7——即 'initVaultWith' 骨架階段
-- 已被(併發的)impl 填上本體,不再是 @undefined@。委派模式下 qa 不保證骨架快照
-- (@spec-roles.md@「骨架快照」);本檔如實記錄兩者,紅綠判定以編排者在骨架快照上
-- 驗到的結果為準,不是本檔觀察到的這次執行結果。
--
-- __2026-09-06 P-005-vault-lifecycle 退場波__:'Aapms.Workspace.Lifecycle' 的七個
-- 直接 IO 函式(@setupHub@ \/ @initVault@ \/ @addVault@ \/ @forgetVault@ \/
-- @checkVaults@ \/ @syncHub@ \/ @purge@)已移除,唯一進入點是
-- 'Aapms.Workspace.Lifecycle.runLifecycle' 加一個 'LifecycleOp'。本檔在下方以
-- __同簽名的區域包裝__接上新進入點,__斷言一字未改__。兩處例外:
--
-- 1. @initVaultWith@(明碼時間版,E001)在新契約裡沒有對應的 shell 進入點——
--    時間是 'Aapms.Store.Effect.Clock' 這個效果,明碼時間只在純解譯器上給得出來。
--    原 STEP-4(EX-18 \/ EX-19)與 E001 的 LAW-1 \/ LAW-2 \/ LAW-3 \/ LAW-7
--    共八條測試因此在本檔移除;等價的性質由 P-005-vault-lifecycle 的
--    LAW-5(id 逐字等於 @newId PVlt name t 0@)與 LAW-6(撞號三個值 + 回滾 +
--    中樞不動)在純側承接。
-- 2. STEP-12(WAVE-4 裁決 B 的刪索引身分驗證)原封保留,__但新舊行為真的不同__:
--    P-005-vault-lifecycle 的 @ForgetVault@ \/ @Purge@ 沒有
--    'DeleteTargetIdDrift' 這條通道。EX-42 與 EX-44 因此紅,留給 conductor 仲裁。
module Aapms.Workspace.LifecycleSpec (spec) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.List (dropWhileEnd, isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Marker (VaultMarker (..), indexDbPath, initVaultAt, markerDir, readMarker)
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Discovery (lookupSelector)
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Hub.File (loadHub, saveHub)
import Aapms.Workspace.Lifecycle (runLifecycle)
import Aapms.Workspace.Location (thumbCacheDir)
import Aapms.Workspace.Types

import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  )
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hGetContents', withBinaryFile)

--------------------------------------------------------------------------------
-- 2026-09-06 退場波:舊的直接 IO 路徑(@setupHub@ \/ @initVault@ \/ @initVaultWith@ \/
-- @addVault@ \/ @forgetVault@ \/ @purge@ \/ @checkVaults@ \/ @syncHub@)已從
-- "Aapms.Workspace.Lifecycle" 移除;同樣的事現在是 P-005-vault-lifecycle 的九種
-- 'LifecycleOp' 請求,唯一進入點是 'runLifecycle'。
--
-- 下面七個區域函式是那七個舊函式的__同簽名__包裝(把 'LifecycleOutcome' 拆回舊的
-- 回傳形狀),讓本檔的斷言一字不動。@initVaultWith@(明碼時間版)在新契約裡沒有
-- 對應的進入點——時間是 'Aapms.Store.Effect.Clock' 這個效果,明碼時間只在純解譯器
-- 上給得出來,那條路由 P-005-vault-lifecycle 的 LAW-5 \/ LAW-6 在純側承接。

-- | 'LifecycleOutcome' 是九種請求共用的記錄,每種請求只填自己那幾格;呼叫端知道
-- 自己送的是哪一種。
expectOutcome :: (LifecycleOutcome -> Maybe a) -> LifecycleOutcome -> a
expectOutcome field o = case field o of
  Just v -> v
  Nothing -> error "LifecycleSpec: LifecycleOutcome 缺對應欄位"

setupHub :: HubLocation -> IO (Either WorkspaceError SetupReport)
setupHub loc = fmap (fmap (expectOutcome outcomeSetup)) (runLifecycle loc emptySnapshot SetupHub)

initVault
  :: HubLocation
  -> Hub
  -> FilePath
  -> VaultKind
  -> Text
  -> InitMode
  -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
initVault loc hub dir kind name mode =
  fmap
    ( fmap
        ( \o ->
            ( expectOutcome outcomeHub o
            , expectOutcome outcomeEntry o
            , expectOutcome outcomeNotice o
            )
        )
    )
    (runLifecycle loc hub (InitVault dir kind name mode))

addVault :: HubLocation -> Hub -> FilePath -> IO (Either WorkspaceError (Hub, VaultEntry))
addVault loc hub dir =
  fmap (fmap hubAndEntry) (runLifecycle loc hub (AddVault dir))

forgetVault
  :: HubLocation -> Hub -> Text -> DeleteIndex -> IO (Either WorkspaceError (Hub, VaultEntry))
forgetVault loc hub sel di =
  fmap (fmap hubAndEntry) (runLifecycle loc hub (ForgetVault sel di))

-- | @CheckVaults@ 不碰中樞檔,'HubLocation' 取哪一個都不影響結果(舊簽名沒有這個
-- 參數,這裡補一個佔位的)。
checkVaults :: Hub -> IO [ScopeIssue]
checkVaults hub =
  fmap (either (const []) outcomeIssues) (runLifecycle (locAt "") hub CheckVaults)

-- | 沒有任何一列需要修正時 @SyncHub@ 不寫檔、也不交出新的 'Hub';舊簽名在那個情況
-- 下回的是傳進去的那一份。
syncHub :: HubLocation -> Hub -> IO (Either WorkspaceError (Hub, [ScopeIssue]))
syncHub loc hub =
  fmap
    (fmap (\o -> (fromMaybe hub (outcomeHub o), outcomeIssues o)))
    (runLifecycle loc hub SyncHub)

purge :: HubLocation -> Hub -> PurgeScope -> IO (Either WorkspaceError PurgeReport)
purge loc hub scope =
  fmap (fmap (expectOutcome outcomePurge)) (runLifecycle loc hub (Purge scope))

hubAndEntry :: LifecycleOutcome -> (Hub, VaultEntry)
hubAndEntry o = (expectOutcome outcomeHub o, expectOutcome outcomeEntry o)

-- | @SetupHub@ 完全不看中樞值(連既有的 @config.toml@ 都不解析)。
emptySnapshot :: Hub
emptySnapshot = mkHub [] [] Nothing (ToolsConfig Nothing) ""

--------------------------------------------------------------------------------
-- 本檔專用 helper(不匯出;Fixtures.hs 不可修改,共用邏輯在此各自複製一份)

-- | 一個骨架檔案裡,去除前導空白、去除行尾 @\\r@(CRLF checkout 的產物)之後、以
-- @import@ 起頭的行(對照 "Aapms.Workspace.DiscoverySpec.importLinesOf")。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))

-- | 從一行 import 取出被 import 的模組全名(不含子句清單)。
moduleNameOf :: String -> String
moduleNameOf l = takeWhile (\c -> c /= ' ' && c /= '(') (drop (length ("import " :: String)) l)

lifecycleImportLines :: IO [String]
lifecycleImportLines = importLinesOf "Aapms/Workspace/Lifecycle.hs"

-- | 只用得到 hubVaults 的最小 Hub(purge \/ checkVaults \/ syncHub \/ forgetVault 只讀
-- hubVaults,其餘三段填什麼都不影響本 feature 的任何行為)。
hubWith :: [VaultEntry] -> Hub
hubWith vs = mkHub vs [] Nothing (ToolsConfig Nothing) ""

-- | 準備一個中樞位置(目錄已存在、可寫)與一個空的、可以在底下放任意 vault 子目錄的
-- 根目錄,兩者共用同一棵暫存樹,測完自動整棵刪除。
withHubAndRoot :: (HubLocation -> FilePath -> IO a) -> IO a
withHubAndRoot act = withTempHubDir $ \top -> do
  let hubDir = top </> "hub"
      root = top </> "vaults"
  createDirectoryIfMissing True hubDir
  createDirectoryIfMissing True root
  act (locAt hubDir) root

-- | 直接用 graph-core 的 initVaultAt 建一個「已經是 vault」的目錄(marker + 空索引),
-- 回傳正規化路徑與對應的 VaultEntry——forgetVault \/ purge \/ addVault 的測試素材,
-- 不必先讓（還沒實作的）initVault 成功才能造出一個已初始化的 vault。
makeRealVault :: VaultKind -> T.Text -> FilePath -> IO VaultEntry
makeRealVault kind name dir = do
  canonDir <- canonicalizePath dir
  m <- orDie =<< initVaultAt canonDir kind name
  pure (VaultEntry (vmId m) (vmName m) (vmKind m) canonDir)

-- | 二進位安全的目錄樹快照:以 binary mode 讀,每個位元組映成一個 'Char'(不解碼
-- UTF-8),用於可能含真正二進位檔的目錄樹比對。"Aapms.Workspace.Fixtures.snapshotTree"
-- 的 Haddock 明講「本套件底下的檔案一律是顯式 UTF-8 文字……沒有二進位檔要顧慮」,
-- 那個假設在 F001-F003 成立,但 F004 的 'makeRealVault'(經 'initVaultAt')會真的建出
-- 一個 SQLite 的 @index.db@——不是文字檔,用 'snapshotTree' 讀會撞上 UTF-8 解碼錯誤。
-- Fixtures.hs 不可修改,這裡在本檔內複製一份二進位安全版本,只給碰得到 @index.db@
-- 的測試用;其餘測試(目錄底下只有 marker\/中樞這些文字檔的)繼續沿用
-- 'Aapms.Workspace.Fixtures.snapshotTree' 即可。
snapshotTreeRaw :: FilePath -> IO [(FilePath, String)]
snapshotTreeRaw root = sortOn fst <$> go ""
  where
    go rel = do
      let full = if null rel then root else root </> rel
      isDir <- doesDirectoryExist full
      if isDir
        then do
          entries <- listDirectory full
          concat <$> mapM (\e -> go (if null rel then e else rel </> e)) entries
        else do
          content <- withBinaryFile full ReadMode hGetContents'
          pure [(rel, content)]

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F004 Aapms.Workspace.Lifecycle" $ do
  --------------------------------------------------------------------------
  describe "STEP-1/LAW-1-LAW-5/EX-1-EX-5: setupHub 中樞的建立" $ do
    it "test_setup_hub_is_idempotent (EX-1, EX-2, LAW-1, LAW-3)" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
        r1 <- setupHub loc
        case r1 of
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)
          Right sp1 -> do
            spHubCreated sp1 `shouldBe` True
            spCacheCreated sp1 `shouldBe` True
            spHubPath sp1 `shouldBe` hlPath loc
            doesFileExist (hubConfigFile hubDir) >>= (`shouldBe` True)
            doesDirectoryExist (thumbCacheDir loc) >>= (`shouldBe` True)
            snap1 <- snapshotTree hubDir
            r2 <- setupHub loc
            case r2 of
              Left e -> expectationFailure ("預期 Right,得到 " <> show e)
              Right sp2 -> do
                spHubCreated sp2 `shouldBe` False
                spCacheCreated sp2 `shouldBe` False
                snap2 <- snapshotTree hubDir
                snap2 `shouldBe` snap1

    it "test_setup_hub_then_load_hub_succeeds (EX-3, LAW-2)" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
        _ <- setupHub loc
        r <- loadHub loc
        case r of
          Right h -> do
            hubVaults h `shouldBe` []
            hubProjects h `shouldBe` []
            hubLlm h `shouldBe` Nothing
            tcSevenZip (hubTools h) `shouldBe` Nothing
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

    it "test_setup_hub_flags_reflect_prior_state (LAW-3): 兩個 Bool 分別反映呼叫前的存在性,呼叫後兩者都存在" $
      forM_ [(False, False), (True, False), (False, True), (True, True)] $ \(cfgExists, cacheExists) ->
        withTempHubDir $ \hubDir -> do
          let loc = locAt hubDir
              td = thumbCacheDir loc
          if cfgExists then writeHubConfig hubDir "" else pure ()
          if cacheExists then createDirectoryIfMissing True td else pure ()
          r <- setupHub loc
          case r of
            Right sp -> do
              spHubCreated sp `shouldBe` not cfgExists
              spCacheCreated sp `shouldBe` not cacheExists
              spHubPath sp `shouldBe` hlPath loc
              doesFileExist (hubConfigFile hubDir) >>= (`shouldBe` True)
              doesDirectoryExist td >>= (`shouldBe` True)
            Left e -> expectationFailure ("預期 Right,得到 " <> show e)

    it "test_setup_hub_never_parses_existing_file (EX-4, LAW-4)" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
        writeHubConfig hubDir "id   = \"vlt-"
        before <- readHubConfigText hubDir
        r <- setupHub loc
        after <- readHubConfigText hubDir
        after `shouldBe` before
        case r of
          Right sp -> spHubCreated sp `shouldBe` False
          Left e -> expectationFailure ("預期 Right(不是 HubUnreadable\\/HubMalformed),得到 " <> show e)

    it "test_setup_hub_creates_only_two_things (EX-5, LAW-5)" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            notesFile = hubDir </> "notes.txt"
        writeFile notesFile "keep me"
        beforeNotes <- readFile notesFile
        r <- setupHub loc
        case r of
          Right _ -> do
            afterNotes <- readFile notesFile
            afterNotes `shouldBe` beforeNotes
            doesFileExist (hubConfigFile hubDir) >>= (`shouldBe` True)
            doesDirectoryExist (thumbCacheDir loc) >>= (`shouldBe` True)
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

  --------------------------------------------------------------------------
  describe "STEP-2/LAW-6-LAW-11/EX-6-EX-10: initVault 前置檢查" $ do
    it "test_init_vault_rejects_blank_name_first (EX-6, LAW-6, LAW-11)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- initVault loc (hubWith []) vDir AssetVault "   " FreshVault
        r `shouldBe` Left (InvalidName "   ")
        doesDirectoryExist vDir >>= (`shouldBe` False)
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg

    it "LAW-6(property): 對任意 dir\\/kind\\/mode,空白名稱一律 InvalidName 帶原始字串,且不碰檔案系統" $
      hedgehog $ do
        blank <- forAll genBlankEnvValue
        kind <- forAll genVaultKind
        mode <- forAll (Gen.element [FreshVault, AdoptExisting])
        dirExists <- forAll Gen.bool
        result <- liftIO $ withHubAndRoot $ \loc root -> do
          let vDir = root </> "v"
          if dirExists then createDirectoryIfMissing True vDir else pure ()
          r <- initVault loc (hubWith []) vDir kind blank mode
          dirStill <- doesDirectoryExist vDir
          pure (r, dirStill)
        let (r, dirStill) = result
        r === Left (InvalidName blank)
        dirStill === dirExists

    it "test_init_vault_already_initialized_both_modes (EX-7, LAW-7, LAW-10)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-11112222" "asset" "x" [])
        canonV <- canonicalizePath vDir
        forM_ [FreshVault, AdoptExisting] $ \mode -> do
          snapBefore <- snapshotTree vDir
          r <- initVault loc (hubWith []) vDir AssetVault "name" mode
          r `shouldBe` Left (VaultAlreadyInitialized canonV)
          snapAfter <- snapshotTree vDir
          snapAfter `shouldBe` snapBefore

    it "test_init_vault_marker_path_taken_by_file (EX-8, LAW-7)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True vDir
        writeFile (markerDir vDir) "not a directory"
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "name" AdoptExisting
        r `shouldBe` Left (VaultAlreadyInitialized canonV)

    it "test_init_vault_fresh_rejects_non_empty (EX-9, LAW-8, LAW-11)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True vDir
        writeFile (vDir </> "a.md") "hello"
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
        r `shouldBe` Left (VaultDirNotEmpty canonV)
        contents <- readFile (vDir </> "a.md")
        contents `shouldBe` "hello"
        doesDirectoryExist (markerDir vDir) >>= (`shouldBe` False)

    it "test_init_vault_adopt_requires_existing_dir (EX-10, LAW-9, LAW-11)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "name" AdoptExisting
        r `shouldBe` Left (VaultDirMissing canonV)
        doesDirectoryExist vDir >>= (`shouldBe` False)

    it "test_init_vault_precheck_has_no_side_effects (LAW-10): 判定順序恆為名稱->\\.aapms->模式,兩條同時成立回前面那個" $ do
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-11112222" "asset" "x" [])
        r1 <- initVault loc (hubWith []) vDir AssetVault "   " FreshVault
        r1 `shouldBe` Left (InvalidName "   ")
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-11112222" "asset" "x" [])
        writeFile (vDir </> "extra.md") "x"
        canonV <- canonicalizePath vDir
        r2 <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
        r2 `shouldBe` Left (VaultAlreadyInitialized canonV)

  --------------------------------------------------------------------------
  describe "STEP-3/LAW-12-LAW-15,LAW-17,LAW-20,LAW-44/EX-11-EX-15,EX-41: initVault 成功路徑" $ do
    it "test_init_vault_entry_mirrors_marker (EX-11, EX-12, LAW-12, LAW-17)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        r <- initVault loc (hubWith []) vDir StoryVault "  Lore  " FreshVault
        canonV <- canonicalizePath vDir
        case r of
          Right (_, e, notice) -> do
            m <- orDie =<< readMarker canonV
            vmKind m `shouldBe` StoryVault
            vmName m `shouldBe` "Lore"
            vmRefs m `shouldBe` []
            veId e `shouldBe` vmId m
            veName e `shouldBe` vmName m
            veKind e `shouldBe` vmKind m
            vePath e `shouldBe` canonV
            anLegacyMarkers notice `shouldBe` []
            doesFileExist (indexDbPath canonV) >>= (`shouldBe` True)
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "LAW-13(property): 任意 projects\\/llm\\/tools\\/原始文字,initVault 成功後只有 hubVaults 多一列" $
      hedgehog $ do
        ps <- forAll (Gen.list (Range.linear 0 3) genProjectEntry)
        llm <- forAll (Gen.maybe genLlmSection)
        tools <- forAll genToolsConfig
        kind <- forAll genVaultKind
        result <- liftIO $ withHubAndRoot $ \loc root -> do
          let hub0 = mkHub [] ps llm tools ""
              vDir = root </> "v"
          r <- initVault loc hub0 vDir kind "name" FreshVault
          pure (r, hub0)
        case result of
          (Right (hub', e, _), hub0) -> do
            hubVaults hub' === hubVaults hub0 ++ [e]
            hubProjects hub' === hubProjects hub0
            hubLlm hub' === hubLlm hub0
            hubTools hub' === hubTools hub0
          (Left err, _) -> annotate (show err) >> failure

    it "test_init_vault_appends_one_row_only (EX-14, LAW-13)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
            hub0 = mkHub [sampleVault1] [sampleProject1] Nothing (ToolsConfig Nothing) ""
        r <- initVault loc hub0 vDir AssetVault "extra" FreshVault
        case r of
          Right (hub', e, _) -> do
            hubVaults hub' `shouldBe` hubVaults hub0 ++ [e]
            hubProjects hub' `shouldBe` hubProjects hub0
            hubLlm hub' `shouldBe` hubLlm hub0
            hubTools hub' `shouldBe` hubTools hub0
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_persists_and_keeps_comments (EX-13, LAW-14)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeHubConfig (hlPath loc) sampleHubText
        hub0 <- orDie =<< loadHub loc
        r <- initVault loc hub0 vDir AssetVault "extra" FreshVault
        case r of
          Right (_, e, _) -> do
            h2 <- orDie =<< loadHub loc
            hubVaults h2 `shouldSatisfy` any (== e)
            txt <- readHubConfigText (hlPath loc)
            txt `shouldSatisfy` T.isInfixOf (T.pack "# 我的中樞設定")
            txt `shouldSatisfy` T.isInfixOf (T.pack "# 故事側")
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_adopt_keeps_existing_files (EX-15, LAW-15)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> "library")
        writeFile (vDir </> "library" </> "x.png") "PNGDATA"
        writeFile (vDir </> "notes.md") "hello"
        createDirectoryIfMissing True (vDir </> ".assetdb")
        writeFile (vDir </> ".assetdb" </> "old.db") "legacy"
        beforeLib <- readFile (vDir </> "library" </> "x.png")
        beforeNotes <- readFile (vDir </> "notes.md")
        beforeDb <- readFile (vDir </> ".assetdb" </> "old.db")
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) -> do
            anLegacyMarkers notice `shouldBe` [canonV </> ".assetdb"]
            doesDirectoryExist (canonV </> ".assetdb") >>= (`shouldBe` True)
            afterLib <- readFile (vDir </> "library" </> "x.png")
            afterNotes <- readFile (vDir </> "notes.md")
            afterDb <- readFile (vDir </> ".assetdb" </> "old.db")
            afterLib `shouldBe` beforeLib
            afterNotes `shouldBe` beforeNotes
            afterDb `shouldBe` beforeDb
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_creates_empty_index (EX-11, LAW-17)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        r <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
        canonV <- canonicalizePath vDir
        case r of
          Right _ -> doesFileExist (indexDbPath canonV) >>= (`shouldBe` True)
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_init_failure_is_vault_init_failed (EX-41, LAW-44, E001 EX-7/REG-5): \
       \V 的父層被一般檔案佔用,initVaultAt 回 Left 時 initVault 轉成 VaultInitFailed 且不留半成品" $
      -- E001 現況分析(2026-08-30 `cabal repl aapms-workspace` 實測)確認:改用「blocker
      -- 是一般檔案,vDir = blocker/sub」這個建構時,initVaultAt 回 Right (Left
      -- (FileWriteFailed …)) 而不是拋未捕捉的 IOException(graph-core B002 隨 E002 修好);
      -- canonicalizePath 對這個建構也不拋例外。GAP-5 的 workspace 側尾巴,本條從 pendingWith
      -- 轉正。err 與直接呼叫 initVaultAt 逐欄相同,這是 REG-5 的字面要求(err 是原件、不轉譯)。
      withHubAndRoot $ \loc _ ->
        withTempHubDir $ \blockerRoot -> do
          let blocker = blockerRoot </> "blocker"
              vDir = blocker </> "sub"
          writeFile blocker "not a directory"
          canonV <- canonicalizePath vDir
          expected <- initVaultAt canonV AssetVault "name"
          beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
          r <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
          case (r, expected) of
            (Left (VaultInitFailed p err), Left expectedErr) -> do
              p `shouldBe` canonV
              err `shouldBe` expectedErr
            other -> expectationFailure ("預期 (VaultInitFailed, Left) 成對失敗,得到 " <> show other)
          doesDirectoryExist (markerDir canonV) >>= (`shouldBe` False)
          afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
          afterCfg `shouldBe` beforeCfg

  --------------------------------------------------------------------------
  describe "E001 REG-2-REG-4/EX-1,EX-8,EX-9: initVault 的回歸 law" $ do
    it "test_init_vault_happy_path_alchbees_assets (EX-1, REG-3): 空目錄、AssetVault、\
       \\"alchbees-assets\"、FreshVault,initVault 成功,entry 四欄如 REG-3,中樞多一列" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
            hub0 = hubWith []
        canonV <- canonicalizePath vDir
        r <- initVault loc hub0 vDir AssetVault "alchbees-assets" FreshVault
        case r of
          Right (hub', e, notice) -> do
            notice `shouldBe` AdoptNotice []
            m <- orDie =<< readMarker canonV
            veId e `shouldBe` vmId m
            veName e `shouldBe` vmName m
            veKind e `shouldBe` vmKind m
            vePath e `shouldBe` canonV
            hubVaults hub' `shouldBe` hubVaults hub0 ++ [e]
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_rejected_when_already_initialized_by_prior_init (EX-8, REG-2): \
       \對 initVault 成功建出的目錄,換個名字、AdoptExisting 再呼叫一次" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        _ <- orDie =<< initVault loc (hubWith []) vDir AssetVault "alchbees-assets" FreshVault
        canonV <- canonicalizePath vDir
        before <- readFile (vaultMarkerConfigFile canonV)
        r <- initVault loc (hubWith []) vDir AssetVault "another-name" AdoptExisting
        r `shouldBe` Left (VaultAlreadyInitialized canonV)
        after <- readFile (vaultMarkerConfigFile canonV)
        after `shouldBe` before

    it "test_init_vault_takes_current_time_each_call (EX-9, REG-4): 同一個 name、兩個空目錄,\
       \連續兩次 initVault 得到不同的 veId" $
      withHubAndRoot $ \loc root -> do
        let d1 = root </> "v1"
            d2 = root </> "v2"
        (_, e1, _) <- orDie =<< initVault loc (hubWith []) d1 AssetVault "same-name" FreshVault
        (_, e2, _) <- orDie =<< initVault loc (hubWith []) d2 AssetVault "same-name" FreshVault
        veId e1 `shouldNotBe` veId e2

  --------------------------------------------------------------------------
  describe "STEP-5/LAW-16/EX-15-EX-17: AdoptNotice" $ do
    it "test_adopt_notice_lists_legacy_markers (EX-15, LAW-16)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> ".assetdb")
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) -> anLegacyMarkers notice `shouldBe` [canonV </> ".assetdb"]
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_adopt_notice_order_is_fixed (EX-16, LAW-16)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> ".assetdb")
        createDirectoryIfMissing True (vDir </> ".storyflow")
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) ->
            anLegacyMarkers notice `shouldBe` [canonV </> ".assetdb", canonV </> ".storyflow"]
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_adopt_notice_is_not_recursive (EX-17, LAW-16)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> "sub" </> ".assetdb")
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) -> anLegacyMarkers notice `shouldBe` []
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

  --------------------------------------------------------------------------
  describe "STEP-6/LAW-21-LAW-24/EX-20-EX-24: addVault" $ do
    it "test_add_vault_identity_from_marker (EX-20, LAW-21)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        r <- addVault loc (hubWith []) vDir
        case r of
          Right (_, e) -> e `shouldBe` VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_add_vault_unreadable_marker_is_hard_failure (EX-23, LAW-22)" $
      withHubAndRoot $ \loc root -> do
        let xDir = root </> "x"
        canonX <- canonicalizePath xDir
        expected <- readMarker canonX
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- addVault loc (hubWith []) xDir
        case (r, expected) of
          (Left (MarkerUnreadable p err), Left expectedErr) -> do
            p `shouldBe` canonX
            err `shouldBe` expectedErr
          other -> expectationFailure ("預期 (MarkerUnreadable, Left) 成對,得到 " <> show other)
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg

    it "test_add_vault_is_idempotent (EX-21, LAW-23)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        (hub1, _) <- orDie =<< addVault loc (hubWith []) vDir
        (hub2, _) <- orDie =<< addVault loc hub1 vDir
        hubVaults hub2 `shouldBe` hubVaults hub1
        length (hubVaults hub2) `shouldBe` 1

    it "test_add_vault_updates_path_on_move (EX-22, LAW-23)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        let oldEntry = VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault "C:/somewhere/old"
            hub0 = hubWith [oldEntry]
        (hub1, _) <- orDie =<< addVault loc hub0 vDir
        hubVaults hub1 `shouldBe` [VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV]

    it "test_add_vault_touches_nothing (EX-24, LAW-24)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        snapBefore <- snapshotTree vDir
        _ <- addVault loc (hubWith []) vDir
        snapAfter <- snapshotTree vDir
        snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "STEP-7/LAW-25-LAW-30/EX-25-EX-29: forgetVault" $ do
    it "test_forget_vault_selector_rules (EX-25, LAW-25)" $
      withHubAndRoot $ \loc root -> do
        e3 <- makeRealVault AssetVault "lore" (root </> "v3")
        e4 <- makeRealVault StoryVault "lore" (root </> "v4")
        let hub = hubWith [e3, e4]
        r <- forgetVault loc hub "lore" KeepIndex
        r `shouldBe` Left (VaultSelectorAmbiguous "lore" [e3, e4])

    it "LAW-25(property): forgetVault 選中的列(或失敗)與 lookupSelector 的結果一致" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 4) genVaultEntry)
        sel <- forAll genName
        result <- liftIO $ withHubAndRoot $ \loc _ -> do
          let hub = hubWith vs
          fr <- forgetVault loc hub sel KeepIndex
          pure (fr, lookupSelector hub sel)
        case result of
          (Left fErr, Left lErr) -> fErr === lErr
          (Right (_, e), Right le) -> e === le
          other -> annotate (show other) >> failure

    it "test_forget_vault_selector_failure_has_no_side_effects (EX-26, LAW-26)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "a" (root </> "v1")
        let hub = hubWith [e1]
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- forgetVault loc hub "nope" DeleteIndex
        r `shouldBe` Left (VaultSelectorNotFound "nope")
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` True)

    it "test_forget_vault_keep_index (EX-27, LAW-27, LAW-30)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "a" (root </> "v1")
        e2 <- makeRealVault AssetVault "b" (root </> "v2")
        e3 <- makeRealVault AssetVault "c" (root </> "v3")
        let hub = hubWith [e1, e2, e3]
        (hub', removed) <- orDie =<< forgetVault loc hub "b" KeepIndex
        removed `shouldBe` e2
        hubVaults hub' `shouldBe` [e1, e3]
        h2 <- orDie =<< loadHub loc
        hubVaults h2 `shouldBe` [e1, e3]
        doesFileExist (vaultMarkerConfigFile (vePath e2)) >>= (`shouldBe` True)
        doesFileExist (indexDbPath (vePath e2)) >>= (`shouldBe` True)

    it "test_forget_vault_delete_index_only_removes_index (EX-28, LAW-28)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "a" (root </> "v1")
        createDirectoryIfMissing True (vePath e1 </> "library")
        writeFile (vePath e1 </> "library" </> "a.png") "PNG"
        writeFile (vePath e1 </> "b.md") "note"
        let hub = hubWith [e1]
        beforePng <- readFile (vePath e1 </> "library" </> "a.png")
        beforeMd <- readFile (vePath e1 </> "b.md")
        _ <- orDie =<< forgetVault loc hub "a" DeleteIndex
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` False)
        doesFileExist (vaultMarkerConfigFile (vePath e1)) >>= (`shouldBe` True)
        afterPng <- readFile (vePath e1 </> "library" </> "a.png")
        afterMd <- readFile (vePath e1 </> "b.md")
        afterPng `shouldBe` beforePng
        afterMd `shouldBe` beforeMd

    it "test_forget_vault_missing_index_is_ok (EX-29, LAW-29, LAW-30)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "a" (root </> "v1")
        removeFile (indexDbPath (vePath e1))
        let hub = hubWith [e1]
        r <- forgetVault loc hub "a" DeleteIndex
        case r of
          Right (hub', removed) -> do
            removed `shouldBe` e1
            hubVaults hub' `shouldBe` []
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

  --------------------------------------------------------------------------
  describe "STEP-8/LAW-31-LAW-33/EX-30-EX-32: checkVaults" $ do
    it "test_check_vaults_lists_issues_in_order (EX-30, LAW-31)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "normal" (root </> "v1")
        let goneDir = root </> "gone"
            e2 = VaultEntry (VaultId "vlt-99990000") "gone" AssetVault goneDir
        e3raw <- makeRealVault AssetVault "drift" (root </> "v3")
        canonGone <- canonicalizePath goneDir
        m3 <- orDie =<< readMarker (vePath e3raw)
        let e3 = e3raw {veId = VaultId "vlt-deaddead"}
            hub = hubWith [e1, e2, e3]
        issues <- checkVaults hub
        issues `shouldBe` [VaultPathMissing e2 canonGone, VaultIdDrift e3 (vmId m3)]

    it "test_check_vaults_writes_nothing (EX-31, LAW-32)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "normal" (root </> "v1")
        let hub = hubWith [e1]
        -- vePath e1 底下真的有 initVaultAt 建出來的 index.db(SQLite 二進位檔),
        -- 用 snapshotTreeRaw(見上方定義)而非 Fixtures.snapshotTree,避免 UTF-8 解碼錯誤。
        snapHub <- snapshotTree (hlPath loc)
        snapV <- snapshotTreeRaw (vePath e1)
        _ <- checkVaults hub
        snapHub' <- snapshotTree (hlPath loc)
        snapV' <- snapshotTreeRaw (vePath e1)
        snapHub' `shouldBe` snapHub
        snapV' `shouldBe` snapV

    it "test_check_vaults_does_not_expand_refs (EX-32, LAW-33)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v1"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "a" ["vlt-11112222"])
        canonV <- canonicalizePath vDir
        let e1 = VaultEntry (VaultId "vlt-7f3b2a91") "a" AssetVault canonV
            hub = hubWith [e1]
        issues <- checkVaults hub
        issues `shouldSatisfy` all (\i -> case i of RefVaultNotRegistered _ _ -> False; _ -> True)

  --------------------------------------------------------------------------
  describe "STEP-9/LAW-34-LAW-36/EX-33-EX-36: syncHub" $ do
    it "test_sync_hub_fixes_name_and_kind_only (EX-33, LAW-34)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v1"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        let staleEntry = VaultEntry (VaultId "vlt-7f3b2a91") "stale" StoryVault canonV
            hub = hubWith [staleEntry]
        (hub', _issues) <- orDie =<< syncHub loc hub
        hubVaults hub' `shouldBe` [VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV]
        h2 <- orDie =<< loadHub loc
        hubVaults h2 `shouldBe` hubVaults hub'

    it "test_sync_hub_issues_match_check_vaults (EX-34, LAW-34, LAW-35)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "normal" (root </> "v1")
        let goneDir = root </> "gone"
            e2 = VaultEntry (VaultId "vlt-99990000") "gone" AssetVault goneDir
            hub = hubWith [e1, e2]
        expectedIssues <- checkVaults hub
        (hub', issues) <- orDie =<< syncHub loc hub
        issues `shouldBe` expectedIssues
        hubVaults hub' `shouldSatisfy` elem e2

    it "test_sync_hub_no_drift_no_write (EX-35, LAW-36)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v1"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        let e = VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV
            hub = mkHub [e] [] Nothing (ToolsConfig Nothing) "# 手寫註記\n"
        _ <- saveHub loc hub
        before <- readHubConfigText (hlPath loc)
        (hub', issues) <- orDie =<< syncHub loc hub
        issues `shouldBe` []
        hubVaults hub' `shouldBe` [e]
        after <- readHubConfigText (hlPath loc)
        after `shouldBe` before

    it "test_sync_hub_never_writes_marker (EX-36, LAW-36)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v1"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        let staleEntry = VaultEntry (VaultId "vlt-7f3b2a91") "stale" StoryVault canonV
            hub = hubWith [staleEntry]
        snapBefore <- snapshotTree vDir
        _ <- syncHub loc hub
        snapAfter <- snapshotTree vDir
        snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "STEP-10/LAW-37-LAW-41/EX-37-EX-40: purge" $ do
    it "test_purge_hub_only_scope (EX-37, LAW-37)" $
      withHubAndRoot $ \loc root -> do
        let hubDir = hlPath loc
            td = thumbCacheDir loc
        writeHubConfig hubDir ""
        createDirectoryIfMissing True (td </> "ab")
        writeFile (td </> "ab" </> "x.png") "p1"
        writeFile (td </> "ab" </> "y.png") "p2"
        writeFile (hubDir </> "notes.txt") "keep"
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        e2 <- makeRealVault AssetVault "v2" (root </> "v2")
        let hub = hubWith [e1, e2]
        r <- orDie =<< purge loc hub PurgeHubOnly
        prHubRemoved r `shouldBe` True
        prThumbsRemoved r `shouldBe` 2
        prVaultIndexesRemoved r `shouldBe` []
        doesFileExist (hubConfigFile hubDir) >>= (`shouldBe` False)
        doesDirectoryExist td >>= (`shouldBe` False)
        doesFileExist (hubDir </> "notes.txt") >>= (`shouldBe` True)
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` True)
        doesFileExist (indexDbPath (vePath e2)) >>= (`shouldBe` True)

    it "test_purge_hub_only_leaves_vaults_alone (LAW-38)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        let hub = hubWith [e1]
        -- vePath e1 底下有真的 index.db(二進位),用 snapshotTreeRaw 而非
        -- Fixtures.snapshotTree,理由同 test_check_vaults_writes_nothing。
        snapBefore <- snapshotTreeRaw (vePath e1)
        _ <- purge loc hub PurgeHubOnly
        snapAfter <- snapshotTreeRaw (vePath e1)
        snapAfter `shouldBe` snapBefore

    it "test_purge_all_vaults_removes_indexes_only (EX-38, LAW-39, LAW-40)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        e2 <- makeRealVault AssetVault "v2" (root </> "v2")
        createDirectoryIfMissing True (vePath e1 </> "library")
        writeFile (vePath e1 </> "library" </> "a.png") "x"
        writeFile (vePath e1 </> "note.md") "y"
        let hub = hubWith [e1, e2]
        r <- orDie =<< purge loc hub PurgeAllVaults
        prVaultIndexesRemoved r `shouldBe` [indexDbPath (vePath e1), indexDbPath (vePath e2)]
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` False)
        doesFileExist (indexDbPath (vePath e2)) >>= (`shouldBe` False)
        doesFileExist (vaultMarkerConfigFile (vePath e1)) >>= (`shouldBe` True)
        doesFileExist (vaultMarkerConfigFile (vePath e2)) >>= (`shouldBe` True)
        doesFileExist (vePath e1 </> "library" </> "a.png") >>= (`shouldBe` True)
        doesFileExist (vePath e1 </> "note.md") >>= (`shouldBe` True)

    it "EX-39: 其中一個 vault 的 index.db 事先刪掉;purge PurgeAllVaults 只列另一個" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        e2 <- makeRealVault AssetVault "v2" (root </> "v2")
        removeFile (indexDbPath (vePath e1))
        r <- orDie =<< purge loc (hubWith [e1, e2]) PurgeAllVaults
        prVaultIndexesRemoved r `shouldBe` [indexDbPath (vePath e2)]

    it "test_purge_never_touches_library_or_md (LAW-40): 任何 PurgeScope 下 library\\/ 與 .md 都不受影響" $
      forM_ [PurgeHubOnly, PurgeAllVaults] $ \scope ->
        withHubAndRoot $ \loc root -> do
          e1 <- makeRealVault AssetVault "v1" (root </> "v1")
          createDirectoryIfMissing True (vePath e1 </> "library" </> "sub")
          writeFile (vePath e1 </> "library" </> "sub" </> "deep.md") "z"
          before <- readFile (vePath e1 </> "library" </> "sub" </> "deep.md")
          _ <- purge loc (hubWith [e1]) scope
          doesFileExist (vePath e1 </> "library" </> "sub" </> "deep.md") >>= (`shouldBe` True)
          after <- readFile (vePath e1 </> "library" </> "sub" </> "deep.md")
          after `shouldBe` before

    it "test_purge_is_idempotent (EX-40, LAW-41)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        let hub = hubWith [e1]
        _ <- purge loc hub PurgeAllVaults
        r2 <- purge loc hub PurgeAllVaults
        r2 `shouldBe` Right (PurgeReport False 0 [])

  --------------------------------------------------------------------------
  describe "STEP-11/LAW-43: 七個函式合起來的檔案系統足跡" $
    it "test_lifecycle_filesystem_footprint (LAW-43): 一組涵蓋七個函式的操作序列,(i)-(iv) 之外的路徑一個都沒動" $
      withHubAndRoot $ \loc root -> do
        _ <- setupHub loc
        let vDir1 = root </> "v1"
            vDir2 = root </> "v2"
        (hub1, e1, _) <- orDie =<< initVault loc (hubWith []) vDir1 AssetVault "v1" FreshVault
        createDirectoryIfMissing True (vePath e1 </> "library")
        writeFile (vePath e1 </> "library" </> "a.png") "keep"
        writeFile (vePath e1 </> "note.md") "keep"
        (hub2, _e2, _) <- orDie =<< initVault loc hub1 vDir2 StoryVault "v2" FreshVault
        _ <- checkVaults hub2
        (hub3, _) <- orDie =<< syncHub loc hub2
        (hub4, _removed) <- orDie =<< forgetVault loc hub3 "v2" DeleteIndex
        beforePng <- readFile (vePath e1 </> "library" </> "a.png")
        beforeMd <- readFile (vePath e1 </> "note.md")
        _ <- purge loc hub4 PurgeHubOnly
        afterPng <- readFile (vePath e1 </> "library" </> "a.png")
        afterMd <- readFile (vePath e1 </> "note.md")
        afterPng `shouldBe` beforePng
        afterMd `shouldBe` beforeMd

  --------------------------------------------------------------------------
  describe "STEP-12/LAW-45-LAW-47/EX-42-EX-45: WAVE-4 裁決 B——刪索引前的身分驗證" $ do
    it "test_forget_vault_delete_index_rejects_id_drift (EX-42, LAW-45b)" $
      withHubAndRoot $ \loc root -> do
        let pDir = root </> "p"
        m <- orDie =<< initVaultAt pDir AssetVault "real"
        canonP <- canonicalizePath pDir
        let staleEntry = VaultEntry (VaultId "vlt-aaaa1111") "real" AssetVault canonP
            hub = hubWith [staleEntry]
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- forgetVault loc hub "vlt-aaaa1111" DeleteIndex
        r `shouldBe` Left (DeleteTargetIdDrift (VaultId "vlt-aaaa1111") canonP (vmId m))
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg
        doesFileExist (indexDbPath canonP) >>= (`shouldBe` True)

    it "test_forget_vault_keep_index_ignores_drift (EX-43, LAW-45 KeepIndex 分支)" $
      withHubAndRoot $ \loc root -> do
        let pDir = root </> "p"
        _ <- orDie =<< initVaultAt pDir AssetVault "real"
        canonP <- canonicalizePath pDir
        let staleEntry = VaultEntry (VaultId "vlt-aaaa1111") "real" AssetVault canonP
            hub = hubWith [staleEntry]
        (hub', removed) <- orDie =<< forgetVault loc hub "vlt-aaaa1111" KeepIndex
        removed `shouldBe` staleEntry
        hubVaults hub' `shouldBe` []
        doesFileExist (indexDbPath canonP) >>= (`shouldBe` True)
        doesFileExist (vaultMarkerConfigFile canonP) >>= (`shouldBe` True)

    it "test_purge_all_vaults_is_all_or_nothing (EX-44, LAW-46)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "ok" (root </> "v1")
        let pDir = root </> "p2"
        m2 <- orDie =<< initVaultAt pDir AssetVault "real2"
        canonP2 <- canonicalizePath pDir
        let staleEntry = VaultEntry (VaultId "vlt-bbbb2222") "real2" AssetVault canonP2
            hub = hubWith [e1, staleEntry]
        writeHubConfig (hlPath loc) ""
        let td = thumbCacheDir loc
        createDirectoryIfMissing True td
        r <- purge loc hub PurgeAllVaults
        r `shouldBe` Left (DeleteTargetIdDrift (VaultId "vlt-bbbb2222") canonP2 (vmId m2))
        doesFileExist (hubConfigFile (hlPath loc)) >>= (`shouldBe` True)
        doesDirectoryExist td >>= (`shouldBe` True)
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` True)
        doesFileExist (indexDbPath canonP2) >>= (`shouldBe` True)

    it "test_delete_index_still_proceeds_when_marker_unreadable (EX-45, LAW-45a, LAW-47)" $
      withHubAndRoot $ \loc root -> do
        let goneDir = root </> "gone"
            e1 = VaultEntry (VaultId "vlt-99990000") "gone" AssetVault goneDir
            hub = hubWith [e1]
        (hub', removed) <- orDie =<< forgetVault loc hub "gone" DeleteIndex
        removed `shouldBe` e1
        hubVaults hub' `shouldBe` []

  --------------------------------------------------------------------------
  describe "LAW-42(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    -- 2026-09-06 純函式重構:'Aapms.Workspace.Hub' 的 IO 面(loadHub \/ saveHub)
    -- 搬到 'Aapms.Workspace.Hub.File',Hub 本身變成純模組。Lifecycle 要的
    -- saveHub 因此改從 Hub.File 取,允許清單多這一項;判準(只准 Types \/
    -- Location \/ Hub 家族 \/ Discovery,下游模組一律不准)不變。
    -- 2026-09-06 P-005-vault-lifecycle 的骨架:進入點 runLifecycle 以三個真解譯器
    -- 跑純層的 Aapms.Workspace.Lifecycle.Plan.applyLifecycle;允許清單因此多那四項,
    -- 判準(只准型別層、純層與自己的 .IO 真解譯器,平行的 shell 模組一律不准)不變。
    -- 2026-09-06 退場波:舊的直接 IO 路徑全數移除後,本模組只剩 runLifecycle 一個
    -- 進入點,Aapms.Store.Marker 與 Aapms.Store.Schema 的 import 一併消失
    -- (marker 的建立與 VaultKind 都只在純層 / 真解譯器裡出現)。(b) 與 (c) 的
    -- 清單因此收成空;判準(不准繞過 marker 家族、不准條件式取用 Schema)不變。
    it "test_lifecycle_no_sibling_imports (a): 本套件內的 import 只能是 Types\\/Location\\/Hub\\/Hub.File\\/Discovery\\/Lifecycle.Plan\\/Effect.*.IO" $ do
      importLines <- lifecycleImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_
        ( \l ->
            moduleNameOf l
              `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Location", "Aapms.Workspace.Hub", "Aapms.Workspace.Hub.File", "Aapms.Workspace.Discovery", "Aapms.Workspace.Lifecycle.Plan", "Aapms.Workspace.Effect.HubFile.IO", "Aapms.Workspace.Effect.Markers.IO", "Aapms.Workspace.Effect.VaultDir.IO"])
        )
        sibling

    it "test_lifecycle_marker_import_is_exact (E001 LAW-6,取代 F004 LAW-42(b)): 若有 import \
       \Aapms.Store.Marker,必須逐字是 \"import Aapms.Store.Marker (VaultMarker (vmId, \
       \vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)\"" $ do
      importLines <- lifecycleImportLines
      let markerLines = filter (\l -> moduleNameOf l == "Aapms.Store.Marker") importLines
      markerLines
        `shouldSatisfy` all
          (== "import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)")

    it "test_lifecycle_schema_import_is_type_only (c): 退場後不再 import Aapms.Store.Schema;\
       \若有,也只能是逐字的 \"import Aapms.Store.Schema (VaultKind)\"" $ do
      importLines <- lifecycleImportLines
      let schemaLines = filter (\l -> moduleNameOf l == "Aapms.Store.Schema") importLines
      schemaLines `shouldSatisfy` all (== "import Aapms.Store.Schema (VaultKind)")

    it "test_lifecycle_never_imports_atomic (d): 完全不得 import Aapms.Store.Atomic" $ do
      importLines <- lifecycleImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "Aapms.Store.Atomic") importLines

    it "test_lifecycle_never_imports_index_modules (e): 完全不得 import Store 門面\\/Index\\/MultiVault\\/Query\\/Write\\/Create\\/Edit" $ do
      importLines <- lifecycleImportLines
      let forbidden =
            [ "Aapms.Store"
            , "Aapms.Store.Index"
            , "Aapms.Store.MultiVault"
            , "Aapms.Store.Query"
            , "Aapms.Store.Write"
            , "Aapms.Store.Create"
            , "Aapms.Store.Edit"
            ]
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`notElem` forbidden)) importLines

    it "test_lifecycle_no_process_import (f): 完全不得 import System.Process" $ do
      importLines <- lifecycleImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "System.Process") importLines
