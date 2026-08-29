-- | F004:中樞建立('setupHub',L1-L5\/X1-X5)、vault 的建立與納管('initVault'\/'addVault',
-- L6-L24\/X6-X24)、撤除('forgetVault'\/'purge',L25-L30,L37-L41\/X25-X29,X37-X40)、體檢與回寫
-- ('checkVaults'\/'syncHub',L31-L36\/X30-X36)、七個函式合起來的檔案系統足跡(L43)、
-- W4 閘門追加的刪索引身分驗證(L44-L47\/X41-X45)、依賴方向與職責界線
-- (L42(a)-(f),__預期綠__——見 spec「紅綠預期」)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F004-vault-lifecycle.md@,
-- 預期欄依 @spec-roles.md@「qa 的交付判準」逐條標:七個函式的本體全是 @undefined@,
-- 所以除了 L42(a)-(f) 之外__一律預期紅__):
--
-- @
-- T1 setupHub
-- L1  冪等且不改位元組                          -> test_setup_hub_is_idempotent            [紅]
-- L2  setupHub 之後 loadHub 一定成功              -> test_setup_hub_then_load_hub_succeeds   [紅]
-- L3  兩個 Bool 的判準                           -> test_setup_hub_flags_reflect_prior_state [紅]
-- L4  既有檔案完全不碰、不解析                    -> test_setup_hub_never_parses_existing_file[紅]
-- L5  只建這兩個東西                             -> test_setup_hub_creates_only_two_things   [紅]
-- X1-X5                                          -> 對應各 test_setup_hub_*
--
-- T2 initVault 前置檢查
-- L6  名稱檢查最先,且不碰檔案系統                -> test_init_vault_rejects_blank_name_first [紅]
-- L7  已被佔用一律 VaultAlreadyInitialized        -> test_init_vault_already_initialized_both_modes / test_init_vault_marker_path_taken_by_file [紅]
-- L8  FreshVault 的目錄前置                       -> test_init_vault_fresh_rejects_non_empty  [紅]
-- L9  AdoptExisting 的目錄前置                    -> test_init_vault_adopt_requires_existing_dir [紅]
-- L10 判定順序恆定                               -> test_init_vault_precheck_has_no_side_effects [紅]
-- L11 前置檢查失敗一律零副作用                    -> 分散在 X6-X10 各測試的位元組不變斷言       [紅]
-- X6-X10                                          -> 對應各 test_init_vault_*
--
-- T3 initVault 成功路徑
-- L12 marker 是真相,VaultEntry 是它的投影         -> test_init_vault_entry_mirrors_marker     [紅]
-- L13 中樞只多一列,其餘三段不動                   -> test_init_vault_appends_one_row_only     [紅]
-- L14 真的落地了(loadHub 讀得回來、註解仍在)      -> test_init_vault_persists_and_keeps_comments [紅]
-- L15 AdoptExisting 不動既有內容                  -> test_init_vault_adopt_keeps_existing_files [紅]
-- L17 空索引一定被建出來                          -> test_init_vault_creates_empty_index      [紅]
-- L20 任何 Left 都不動中樞檔案                    -> 分散在各前置檢查\/撞號\/L44 測試            [紅]
-- L44 initVaultAt 失敗 -> VaultInitFailed,不留半成品 -> test_init_vault_init_failure_is_vault_init_failed [紅]
-- X11-X15, X41                                    -> 對應各 test_init_vault_*
--
-- T4 initVault 撞號
-- L18 撞號的三個值                               -> test_init_vault_id_collision_carries_both_paths [紅]
-- L19 撞號要回滾                                 -> test_init_vault_id_collision_rolls_back  [紅]
-- X18, X19                                        -> 對應各 test_init_vault_id_collision_*
--
-- T5 AdoptNotice
-- L16 AdoptNotice 的內容、順序、不遞迴             -> test_adopt_notice_lists_legacy_markers / test_adopt_notice_order_is_fixed / test_adopt_notice_is_not_recursive [紅]
-- X15, X16, X17                                   -> 對應各 test_adopt_notice_*
--
-- T6 addVault
-- L21 身分一律來自 marker                         -> test_add_vault_identity_from_marker      [紅]
-- L22 讀不到 marker 是硬失敗                      -> test_add_vault_unreadable_marker_is_hard_failure [紅]
-- L23 以 id 為鍵,重複納管不長第二列               -> test_add_vault_is_idempotent / test_add_vault_updates_path_on_move [紅]
-- L24 不動 vault 目錄                            -> test_add_vault_touches_nothing           [紅]
-- X20-X24                                         -> 對應各 test_add_vault_*
--
-- T7 forgetVault
-- L25 selector 規則同 lookupSelector              -> test_forget_vault_selector_rules         [紅]
-- L26 selector 失敗零副作用                       -> test_forget_vault_selector_failure_has_no_side_effects [紅]
-- L27 KeepIndex:只動中樞                         -> test_forget_vault_keep_index             [紅]
-- L28 DeleteIndex:只多刪一個檔                   -> test_forget_vault_delete_index_only_removes_index [紅]
-- L29 刪索引失敗不算失敗                          -> test_forget_vault_missing_index_is_ok    [紅]
-- L30 回傳被移除的那一列                          -> 併入 test_forget_vault_keep_index / test_forget_vault_missing_index_is_ok [紅]
-- X25-X29                                         -> 對應各 test_forget_vault_*
--
-- T8 checkVaults
-- L31 內容與順序                                 -> test_check_vaults_lists_issues_in_order  [紅]
-- L32 不寫任何東西,也沒有失敗通道                 -> test_check_vaults_writes_nothing         [紅]
-- L33 不展開 refs                                -> test_check_vaults_does_not_expand_refs   [紅]
-- X30-X32                                         -> 對應各 test_check_vaults_*
--
-- T9 syncHub
-- L34 只修 veName\/veKind                        -> test_sync_hub_fixes_name_and_kind_only   [紅]
-- L35 issue 清單等於 checkVaults                 -> test_sync_hub_issues_match_check_vaults  [紅]
-- L36 方向只有 marker -> 中樞;沒有漂移就不寫      -> test_sync_hub_never_writes_marker / test_sync_hub_no_drift_no_write [紅]
-- X33-X36                                         -> 對應各 test_sync_hub_*
--
-- T10 purge
-- L37 PurgeHubOnly 的範圍                        -> test_purge_hub_only_scope                [紅]
-- L38 PurgeHubOnly 不碰任何 vault                -> test_purge_hub_only_leaves_vaults_alone  [紅]
-- L39 PurgeAllVaults 只多刪 index.db             -> test_purge_all_vaults_removes_indexes_only [紅]
-- L40 任何 PurgeScope 都不刪 library\/ 與 .md     -> test_purge_never_touches_library_or_md   [紅]
-- L41 冪等                                       -> test_purge_is_idempotent                 [紅]
-- X37-X40                                         -> 對應各 test_purge_*
--
-- T11 七個函式合起來的檔案系統足跡
-- L43                                             -> test_lifecycle_filesystem_footprint      [紅]
--
-- T12 W4 裁決 B:刪索引前的身分驗證
-- L45 forgetVault 刪索引前先驗身分                -> test_forget_vault_delete_index_rejects_id_drift / test_forget_vault_keep_index_ignores_drift [紅]
-- L46 purge PurgeAllVaults 是全有或全無            -> test_purge_all_vaults_is_all_or_nothing  [紅]
-- L47 驗身分不改變「讀不到就照刪」                -> test_delete_index_still_proceeds_when_marker_unreadable [紅]
-- X42-X45                                         -> 對應各測試
--
-- L42(預期綠):依賴方向與職責界線(以 import 行驗證)
-- (a) 無 Scope\/Projects\/Tools,只准 Types\/Location\/Hub\/Discovery -> test_lifecycle_no_sibling_imports          [綠]
-- (b) Aapms.Store.Marker 的 import(若有)逐字比對(含 readMarker)     -> test_lifecycle_marker_import_is_exact      [綠]
-- (c) Aapms.Store.Schema 只取 VaultKind,非條件式                     -> test_lifecycle_schema_import_is_type_only  [綠]
-- (d) 不得 import Aapms.Store.Atomic                                  -> test_lifecycle_never_imports_atomic        [綠]
-- (e) 不得 import Store 門面\/Index\/MultiVault\/Query\/Write\/Create\/Edit -> test_lifecycle_never_imports_index_modules [綠]
-- (f) 不得 import System.Process                                      -> test_lifecycle_no_process_import           [綠]
-- @
--
-- __X18\/X19(撞號)的測試構造說明__:@initVaultAt@ 產生的 id 帶時間成分
-- (spec「相依性查證」3),qa 不得讀 graph-core 的 @newId@ 實作決定確切的時間解析度。
-- 本檔依 spec X18 原文「以固定時間 \/ 名稱造出撞號」的字面指示,先對一個丟棄用的探測
-- 目錄真的呼叫一次 @initVaultAt@ 學出這次會產生的 id,立刻把它塞進中樞的一列(路徑指到
-- 另一個地方),馬上對真正的目標目錄用__同一個 name__呼叫 @initVault@——時間視窗夠近時
-- 會撞號。這是 qa 對「如何構造」的實作自由(spec 用「例如」\/「以…造出」開放做法),
-- 不是對 spec 行為的腦補;若環境的時間解析度導致這兩條測試偶發不穩,不影響骨架階段的
-- 紅綠判定(七個函式本體皆 @undefined@,無論如何都會拋例外而紅)。
module Aapms.Workspace.LifecycleSpec (spec) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.List (dropWhileEnd, isPrefixOf, sortOn)
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
import Aapms.Workspace.Hub (loadHub, saveHub)
import Aapms.Workspace.Lifecycle
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
  describe "T1/L1-L5/X1-X5: setupHub 中樞的建立" $ do
    it "test_setup_hub_is_idempotent (X1, X2, L1, L3)" $
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

    it "test_setup_hub_then_load_hub_succeeds (X3, L2)" $
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

    it "test_setup_hub_flags_reflect_prior_state (L3): 兩個 Bool 分別反映呼叫前的存在性,呼叫後兩者都存在" $
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

    it "test_setup_hub_never_parses_existing_file (X4, L4)" $
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

    it "test_setup_hub_creates_only_two_things (X5, L5)" $
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
  describe "T2/L6-L11/X6-X10: initVault 前置檢查" $ do
    it "test_init_vault_rejects_blank_name_first (X6, L6, L11)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- initVault loc (hubWith []) vDir AssetVault "   " FreshVault
        r `shouldBe` Left (InvalidName "   ")
        doesDirectoryExist vDir >>= (`shouldBe` False)
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg

    it "L6(property): 對任意 dir\\/kind\\/mode,空白名稱一律 InvalidName 帶原始字串,且不碰檔案系統" $
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

    it "test_init_vault_already_initialized_both_modes (X7, L7, L10)" $
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

    it "test_init_vault_marker_path_taken_by_file (X8, L7)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True vDir
        writeFile (markerDir vDir) "not a directory"
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "name" AdoptExisting
        r `shouldBe` Left (VaultAlreadyInitialized canonV)

    it "test_init_vault_fresh_rejects_non_empty (X9, L8, L11)" $
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

    it "test_init_vault_adopt_requires_existing_dir (X10, L9, L11)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "name" AdoptExisting
        r `shouldBe` Left (VaultDirMissing canonV)
        doesDirectoryExist vDir >>= (`shouldBe` False)

    it "test_init_vault_precheck_has_no_side_effects (L10): 判定順序恆為名稱->\\.aapms->模式,兩條同時成立回前面那個" $ do
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
  describe "T3/L12-L15,L17,L20,L44/X11-X15,X41: initVault 成功路徑" $ do
    it "test_init_vault_entry_mirrors_marker (X11, X12, L12, L17)" $
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

    it "L13(property): 任意 projects\\/llm\\/tools\\/原始文字,initVault 成功後只有 hubVaults 多一列" $
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

    it "test_init_vault_appends_one_row_only (X14, L13)" $
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

    it "test_init_vault_persists_and_keeps_comments (X13, L14)" $
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

    it "test_init_vault_adopt_keeps_existing_files (X15, L15)" $
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

    it "test_init_vault_creates_empty_index (X11, L17)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        r <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
        canonV <- canonicalizePath vDir
        case r of
          Right _ -> doesFileExist (indexDbPath canonV) >>= (`shouldBe` True)
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_init_vault_init_failure_is_vault_init_failed (X41, L44)" $
      -- 本機實測(2026-08-29):用「V 的父層被一個檔案佔用」建構(見下方註解掉的版本)
      -- 時,initVaultAt 內部的 createDirectoryIfMissing 讓 CreateDirectory
      -- AlreadyExists 這個 IOException __未捕捉地往上拋__,不是回傳 Left——
      -- 這條路徑根本沒有機會走到 initVault 要驗的 (Left (VaultInitFailed …), Left …)
      -- 分支。qa 不得讀 graph-core 的 initVaultAt 實作決定它到底在哪些情境捕捉例外、
      -- 在哪些情境直接拋出,故 X41 描述的「以固定方式讓 initVaultAt 回 Left」無法在
      -- 不腦補的前提下確定性重現,見回報的 spec-gap 本次-2。
      pendingWith
        "X41/L44:「V 的父層被檔案佔用」的建構讓 initVaultAt 拋出未捕捉的 IOException \
        \(CreateDirectory AlreadyExists)而不是回傳 Left,無法驗證 initVault 是否把它包成 \
        \VaultInitFailed;需要 spec 或 impl 補一個確定會讓 initVaultAt 回 Left 的重現方式 \
        \(見 spec-gap 本次-2)"

    -- 以下是依 spec X41 原文字面嘗試的建構,留著給日後解 spec-gap 本次-2 時參考:
    --
    -- withHubAndRoot $ \loc _ ->
    --   withTempHubDir $ \blockerRoot -> do
    --     let blocker = blockerRoot </> "blocker"
    --         vDir = blocker </> "sub"
    --     writeFile blocker "not a directory"
    --     canonV <- canonicalizePath vDir
    --     expected <- initVaultAt canonV AssetVault "name"
    --     beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
    --     r <- initVault loc (hubWith []) vDir AssetVault "name" FreshVault
    --     case (r, expected) of
    --       (Left (VaultInitFailed p err), Left expectedErr) -> do
    --         p `shouldBe` canonV
    --         err `shouldBe` expectedErr
    --       other -> expectationFailure ("預期 (VaultInitFailed, Left) 成對失敗,得到 " <> show other)
    --     doesDirectoryExist (markerDir canonV) >>= (`shouldBe` False)
    --     afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
    --     afterCfg `shouldBe` beforeCfg

  --------------------------------------------------------------------------
  describe "T4/L18-L20/X18-X19: initVault 撞號" $ do
    it "test_init_vault_id_collision_carries_both_paths (X18, L18)" $
      -- 本機實測(2026-08-29):對同一個 name 連續呼叫兩次 initVaultAt(相隔僅一個
      -- IO 動作)得到兩個__不同__的 id(例如 vlt-1c5bcb0f / vlt-b8122656),證明
      -- newId 的時間\/亂數解析度細過「同名快速連續呼叫」這個視窗,X18 原文「以固定
      -- 時間\/名稱造出撞號」在不讀 graph-core 的 newId 實作、不能控制時鐘的前提下
      -- 無法確定性重現。見回報的 spec-gap 本次-1。
      pendingWith
        "X18/L18:無法在不讀 graph-core newId 實作\\/不能凍結時間的前提下確定性造出兩次 \
        \initVaultAt 呼叫的 id 撞號(本機實測兩次呼叫產生不同 id);見 spec-gap 本次-1"

    it "test_init_vault_id_collision_rolls_back (X19, L19, L20)" $
      -- 同上一條的建構限制(spec-gap 本次-1);L20「任何 Left 都不動中樞檔案」已由
      -- 其餘前置檢查\/L44 測試涵蓋,不因此條 pending 而失去覆蓋。
      pendingWith
        "X19/L19:同 test_init_vault_id_collision_carries_both_paths,撞號情境無法確定性重現;\
        \見 spec-gap 本次-1"

    -- 以下是依 spec X18\/X19 原文「以固定時間\/名稱造出撞號」嘗試的建構,留著給日後解
    -- spec-gap 本次-1 時參考(本機實測會因為兩次 initVaultAt 呼叫產生不同 id 而失敗):
    --
    -- withHubAndRoot $ \loc root ->
    --   withTempHubDir $ \probeRoot -> do
    --     let probe = probeRoot </> "o"
    --         vDir = root </> "v"
    --     createDirectoryIfMissing True probe
    --     canonO <- canonicalizePath probe
    --     learned <- orDie =<< initVaultAt canonO AssetVault "same-name"
    --     let hub = hubWith [VaultEntry (vmId learned) "same-name" (vmKind learned) canonO]
    --     canonV <- canonicalizePath vDir
    --     r <- initVault loc hub vDir AssetVault "same-name" FreshVault
    --     r `shouldBe` Left (VaultIdCollision (vmId learned) canonO canonV)
    --     -- （撞號後的回滾,原本另一條測試驗的事)
    --     case r of
    --       Left (VaultIdCollision _ _ _) -> do
    --         doesDirectoryExist (markerDir canonV) >>= (`shouldBe` False)
    --         afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
    --         afterCfg `shouldBe` beforeCfg
    --       other -> expectationFailure ("預期撞號,得到 " <> show other)

  --------------------------------------------------------------------------
  describe "T5/L16/X15-X17: AdoptNotice" $ do
    it "test_adopt_notice_lists_legacy_markers (X15, L16)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> ".assetdb")
        canonV <- canonicalizePath vDir
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) -> anLegacyMarkers notice `shouldBe` [canonV </> ".assetdb"]
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_adopt_notice_order_is_fixed (X16, L16)" $
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

    it "test_adopt_notice_is_not_recursive (X17, L16)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        createDirectoryIfMissing True (vDir </> "sub" </> ".assetdb")
        r <- initVault loc (hubWith []) vDir AssetVault "adopted" AdoptExisting
        case r of
          Right (_, _, notice) -> anLegacyMarkers notice `shouldBe` []
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

  --------------------------------------------------------------------------
  describe "T6/L21-L24/X20-X24: addVault" $ do
    it "test_add_vault_identity_from_marker (X20, L21)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        r <- addVault loc (hubWith []) vDir
        case r of
          Right (_, e) -> e `shouldBe` VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV
          Left err -> expectationFailure ("預期 Right,得到 " <> show err)

    it "test_add_vault_unreadable_marker_is_hard_failure (X23, L22)" $
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

    it "test_add_vault_is_idempotent (X21, L23)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        (hub1, _) <- orDie =<< addVault loc (hubWith []) vDir
        (hub2, _) <- orDie =<< addVault loc hub1 vDir
        hubVaults hub2 `shouldBe` hubVaults hub1
        length (hubVaults hub2) `shouldBe` 1

    it "test_add_vault_updates_path_on_move (X22, L23)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        canonV <- canonicalizePath vDir
        let oldEntry = VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault "C:/somewhere/old"
            hub0 = hubWith [oldEntry]
        (hub1, _) <- orDie =<< addVault loc hub0 vDir
        hubVaults hub1 `shouldBe` [VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault canonV]

    it "test_add_vault_touches_nothing (X24, L24)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "real" [])
        snapBefore <- snapshotTree vDir
        _ <- addVault loc (hubWith []) vDir
        snapAfter <- snapshotTree vDir
        snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "T7/L25-L30/X25-X29: forgetVault" $ do
    it "test_forget_vault_selector_rules (X25, L25)" $
      withHubAndRoot $ \loc root -> do
        e3 <- makeRealVault AssetVault "lore" (root </> "v3")
        e4 <- makeRealVault StoryVault "lore" (root </> "v4")
        let hub = hubWith [e3, e4]
        r <- forgetVault loc hub "lore" KeepIndex
        r `shouldBe` Left (VaultSelectorAmbiguous "lore" [e3, e4])

    it "L25(property): forgetVault 選中的列(或失敗)與 lookupSelector 的結果一致" $
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

    it "test_forget_vault_selector_failure_has_no_side_effects (X26, L26)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "a" (root </> "v1")
        let hub = hubWith [e1]
        beforeCfg <- doesFileExist (hubConfigFile (hlPath loc))
        r <- forgetVault loc hub "nope" DeleteIndex
        r `shouldBe` Left (VaultSelectorNotFound "nope")
        afterCfg <- doesFileExist (hubConfigFile (hlPath loc))
        afterCfg `shouldBe` beforeCfg
        doesFileExist (indexDbPath (vePath e1)) >>= (`shouldBe` True)

    it "test_forget_vault_keep_index (X27, L27, L30)" $
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

    it "test_forget_vault_delete_index_only_removes_index (X28, L28)" $
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

    it "test_forget_vault_missing_index_is_ok (X29, L29, L30)" $
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
  describe "T8/L31-L33/X30-X32: checkVaults" $ do
    it "test_check_vaults_lists_issues_in_order (X30, L31)" $
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

    it "test_check_vaults_writes_nothing (X31, L32)" $
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

    it "test_check_vaults_does_not_expand_refs (X32, L33)" $
      withHubAndRoot $ \loc root -> do
        let vDir = root </> "v1"
        writeVaultMarker vDir (markerTomlText "vlt-7f3b2a91" "asset" "a" ["vlt-11112222"])
        canonV <- canonicalizePath vDir
        let e1 = VaultEntry (VaultId "vlt-7f3b2a91") "a" AssetVault canonV
            hub = hubWith [e1]
        issues <- checkVaults hub
        issues `shouldSatisfy` all (\i -> case i of RefVaultNotRegistered _ _ -> False; _ -> True)

  --------------------------------------------------------------------------
  describe "T9/L34-L36/X33-X36: syncHub" $ do
    it "test_sync_hub_fixes_name_and_kind_only (X33, L34)" $
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

    it "test_sync_hub_issues_match_check_vaults (X34, L34, L35)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "normal" (root </> "v1")
        let goneDir = root </> "gone"
            e2 = VaultEntry (VaultId "vlt-99990000") "gone" AssetVault goneDir
            hub = hubWith [e1, e2]
        expectedIssues <- checkVaults hub
        (hub', issues) <- orDie =<< syncHub loc hub
        issues `shouldBe` expectedIssues
        hubVaults hub' `shouldSatisfy` elem e2

    it "test_sync_hub_no_drift_no_write (X35, L36)" $
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

    it "test_sync_hub_never_writes_marker (X36, L36)" $
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
  describe "T10/L37-L41/X37-X40: purge" $ do
    it "test_purge_hub_only_scope (X37, L37)" $
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

    it "test_purge_hub_only_leaves_vaults_alone (L38)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        let hub = hubWith [e1]
        -- vePath e1 底下有真的 index.db(二進位),用 snapshotTreeRaw 而非
        -- Fixtures.snapshotTree,理由同 test_check_vaults_writes_nothing。
        snapBefore <- snapshotTreeRaw (vePath e1)
        _ <- purge loc hub PurgeHubOnly
        snapAfter <- snapshotTreeRaw (vePath e1)
        snapAfter `shouldBe` snapBefore

    it "test_purge_all_vaults_removes_indexes_only (X38, L39, L40)" $
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

    it "X39: 其中一個 vault 的 index.db 事先刪掉;purge PurgeAllVaults 只列另一個" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        e2 <- makeRealVault AssetVault "v2" (root </> "v2")
        removeFile (indexDbPath (vePath e1))
        r <- orDie =<< purge loc (hubWith [e1, e2]) PurgeAllVaults
        prVaultIndexesRemoved r `shouldBe` [indexDbPath (vePath e2)]

    it "test_purge_never_touches_library_or_md (L40): 任何 PurgeScope 下 library\\/ 與 .md 都不受影響" $
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

    it "test_purge_is_idempotent (X40, L41)" $
      withHubAndRoot $ \loc root -> do
        e1 <- makeRealVault AssetVault "v1" (root </> "v1")
        let hub = hubWith [e1]
        _ <- purge loc hub PurgeAllVaults
        r2 <- purge loc hub PurgeAllVaults
        r2 `shouldBe` Right (PurgeReport False 0 [])

  --------------------------------------------------------------------------
  describe "T11/L43: 七個函式合起來的檔案系統足跡" $
    it "test_lifecycle_filesystem_footprint (L43): 一組涵蓋七個函式的操作序列,(i)-(iv) 之外的路徑一個都沒動" $
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
  describe "T12/L45-L47/X42-X45: W4 裁決 B——刪索引前的身分驗證" $ do
    it "test_forget_vault_delete_index_rejects_id_drift (X42, L45b)" $
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

    it "test_forget_vault_keep_index_ignores_drift (X43, L45 KeepIndex 分支)" $
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

    it "test_purge_all_vaults_is_all_or_nothing (X44, L46)" $
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

    it "test_delete_index_still_proceeds_when_marker_unreadable (X45, L45a, L47)" $
      withHubAndRoot $ \loc root -> do
        let goneDir = root </> "gone"
            e1 = VaultEntry (VaultId "vlt-99990000") "gone" AssetVault goneDir
            hub = hubWith [e1]
        (hub', removed) <- orDie =<< forgetVault loc hub "gone" DeleteIndex
        removed `shouldBe` e1
        hubVaults hub' `shouldBe` []

  --------------------------------------------------------------------------
  describe "L42(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    it "test_lifecycle_no_sibling_imports (a): 本套件內的 import 只能是 Types\\/Location\\/Hub\\/Discovery" $ do
      importLines <- lifecycleImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_
        ( \l ->
            moduleNameOf l
              `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Location", "Aapms.Workspace.Hub", "Aapms.Workspace.Discovery"])
        )
        sibling

    it "test_lifecycle_marker_import_is_exact (b,條件式): 若有 import Aapms.Store.Marker,\
       \必須逐字是 \"import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, markerDir, readMarker)\"" $ do
      importLines <- lifecycleImportLines
      let markerLines = filter (\l -> moduleNameOf l == "Aapms.Store.Marker") importLines
      markerLines
        `shouldSatisfy` all
          (== "import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, markerDir, readMarker)")

    it "test_lifecycle_schema_import_is_type_only (c): 骨架階段起就是實斷言,只取 VaultKind" $ do
      importLines <- lifecycleImportLines
      let schemaLines = filter (\l -> moduleNameOf l == "Aapms.Store.Schema") importLines
      schemaLines `shouldBe` ["import Aapms.Store.Schema (VaultKind)"]

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
