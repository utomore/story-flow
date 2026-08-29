-- | F005:'Aapms.Workspace.Projects' 的配號('allocateProjectId',L1-L3/X1-X5)、
-- 註冊('registerProject',L4-L10/X6-X18,X28-X30)、撤除('forgetProject',
-- L11-L14/X19-X27,X31)與依賴方向的 import 清單檢查(L17,__預期綠__——見 spec
-- 「紅綠預期」)。
--
-- __spec 對照__(@.design/subsystems/workspace/features/F005-project-registry.md@):
--
-- @
-- T1 allocateProjectId(純函式配號)
-- L1  形狀恒為 prj- + 8 位小寫十六進位          -> test_allocate_project_id_shape_is_prj_plus_8_hex
-- L2  不撞既有,撞號時 salt 遞增重試             -> test_allocate_project_id_no_collision_uses_salt_zero / _retries_on_collision / _retries_twice
-- L3  純函式,只看 peId                          -> test_allocate_project_id_ignores_other_fields
-- X1-X5                                          -> 對應各 test_allocate_project_id_*
--
-- T2 registerProject 前置檢查
-- L6  空名 -> InvalidName,什麼都不做            -> test_register_project_blank_name_is_invalid_name / _empty_name_is_invalid_name
-- L7  路徑不是既存目錄 -> ProjectPathMissing     -> test_register_project_missing_path / _file_path_is_missing
-- L9  同一個路徑不得註冊兩次                     -> test_register_project_same_path_twice_is_already_registered / _detects_other_spelling / _does_not_renormalize_existing_rows / test_render_already_registered_has_id_and_path
-- L15 專案目錄完全未動(失敗路徑)                -> test_register_project_failure_writes_nothing 等
-- L16 中樞只在成功路徑改變                       -> test_register_project_failure_writes_nothing 等
-- X9-X13, X17, X28-X30                           -> 對應各 test_register_project_*
--
-- T3 registerProject 主線
-- L4  成功時四個事實                             -> test_register_project_success_fields / _appends_at_end / _stores_trimmed_name / _normalizes_path
-- L5  只動 [[projects]]                          -> test_register_project_success_fields
-- L8  寫出去的中樞讀得回來(完整定義域)          -> test_register_project_roundtrips_through_load_hub / _preserves_comments_and_vaults / _roundtrips_with_control_char_names
-- L10 saveHub 失敗即失敗                         -> test_register_project_save_failure_is_forwarded
-- X6-X8, X14-X16, X18                            -> 對應各 test_register_project_*
--
-- T4 forgetProject selector
-- L11 兩階段,id 絕對優先                         -> test_forget_project_id_beats_name
-- L12(b)(c) 命中集合 -> 結果                     -> test_forget_project_ambiguous_name_lists_all / _ambiguous_id_lists_all / _ambiguous_removes_nothing / _not_found
-- L13 逐字精確比對                                -> test_forget_project_is_case_sensitive / _does_not_trim / _never_matches_without_exact_equality
-- L14 只看 [[projects]]                           -> test_forget_project_ignores_other_sections
-- X19, X21-X25, X31                               -> 對應各 test_forget_project_*
--
-- T5 forgetProject 主線
-- L12(a) 命中恰好一列 -> 結果                     -> test_forget_project_removes_only_that_row
-- L15 專案目錄完全未動                            -> test_forget_project_leaves_project_dir_untouched
-- L16 中樞只在成功路徑改變(承 L10)               -> test_forget_project_save_failure_is_forwarded
-- X20, X26, X27                                   -> 對應各 test_forget_project_*
--
-- L17(預期綠) 依賴方向與職責界線(以 import 行驗證)
-- (a) 本套件內只准 Types/Hub                      -> test_projects_no_sibling_or_vault_imports
-- (b) 完全不得 import Aapms.Store 開頭的行         -> test_projects_never_imports_store
-- (c) Aapms.Core.Id 匯入清單只能是配號四項的子集   -> test_projects_core_id_import_is_allocation_only
-- (d) 不得 import System.Process                   -> test_projects_no_process_import
-- (e) 除 Aapms.Core.Id 外不得 import Aapms.Core.*、不得 import Data.Aeson -> test_projects_never_reads_manifests
--
-- __紅綠預期__(spec「紅綠預期」段):L17 五條子斷言 (a)-(e) 全部預期__綠__(骨架
-- 自身的 import 行,不經過 undefined);其餘每一條 law 與 example 預期__紅__(三個
-- 函式的本體全是 undefined)。L8 的完整定義域(含控制字元)__依賴 F001 的
-- @quoteText@ 修好__——在那之前,'test_register_project_roundtrips_with_control_char_names'
-- 紅的歸因是 "Aapms.Workspace.Hub" 的序列化器,不是本模組(spec「兩個先決條件」第 2 點)。
-- 兩個新建構子('ProjectAlreadyRegistered'、'ProjectSelectorAmbiguous')不存在時本檔
-- __連編譯都過不了__(spec「兩個先決條件」第 1 點)。
module Aapms.Workspace.ProjectsSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.List (dropWhileEnd, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day (ModifiedJulianDay), UTCTime (..), secondsToDiffTime)
import Hedgehog (Gen, annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (Id, IdPrefix (PPrj), newId, parseId, renderId)
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Hub (loadHub, saveHub)
import Aapms.Workspace.Projects (allocateProjectId, forgetProject, registerProject)
import Aapms.Workspace.Types

import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))

--------------------------------------------------------------------------------
-- 本檔專用 helper(不匯出)

-- | 一個骨架檔案裡,去除前導空白、去除行尾 @\\r@(CRLF checkout 的產物)之後、以
-- @import@ 起頭的行(L17 明文;做法對照 "Aapms.Workspace.DiscoverySpec.importLinesOf")。
importLinesOf :: FilePath -> IO [String]
importLinesOf rel = do
  src <- readWorkspaceSource rel
  let stripLine = dropWhile (== ' ') . dropWhileEnd (== '\r')
  pure (filter ("import" `isPrefixOf`) (map stripLine (lines (T.unpack src))))

-- | 從一行 import 取出被 import 的模組全名(不含子句清單)。
moduleNameOf :: String -> String
moduleNameOf l = takeWhile (\c -> c /= ' ' && c /= '(') (drop (length ("import " :: String)) l)

-- | 取出一行 import 的匯入清單,依「最外層」逗號切開(內層括號,例如
-- @IdPrefix (PPrj)@,不會被誤切成兩項)。
parseImportItems :: String -> [String]
parseImportItems l = map trim (splitTopLevelCommas inner)
  where
    afterParen = drop 1 (dropWhile (/= '(') l)
    inner = reverse (drop 1 (dropWhile (/= ')') (reverse afterParen)))
    trim = f . f where f = reverse . dropWhile (== ' ')
    splitTopLevelCommas = go (0 :: Int) ""
      where
        go _ cur [] = [reverse cur]
        go depth cur (c : cs)
          | c == ',' && depth == 0 = reverse cur : go depth "" cs
          | c == '(' = go (depth + 1) (c : cur) cs
          | c == ')' = go (depth - 1) (c : cur) cs
          | otherwise = go depth (c : cur) cs

projectsImportLines :: IO [String]
projectsImportLines = importLinesOf "Aapms/Workspace/Projects.hs"

-- | 一個固定的時間點,給 'allocateProjectId' 的具名 example 用。
t0 :: UTCTime
t0 = UTCTime (ModifiedJulianDay 61094) 0

-- | 任意的 'UTCTime',給 L1/L3 的通用性質測試用。
genUTCTime :: Gen UTCTime
genUTCTime = do
  d <- Gen.integral (Range.linear 60000 62000)
  s <- Gen.integral (Range.linear 0 86399)
  pure (UTCTime (ModifiedJulianDay d) (secondsToDiffTime s))

-- | 用一個已知合法的 id 字面值造 'ProjectEntry'(不必經過 'allocateProjectId'/'newId',
-- 用來擺出「中樞既有列」的固定劇本,例如 X19/X21/X31)。
mkProjEntry :: Text -> Text -> FilePath -> ProjectEntry
mkProjEntry idText nm p = ProjectEntry {peId = idOf idText, peName = nm, pePath = p}

-- | 用一個明碼 'Id' 造 'ProjectEntry'(給配號測試的「既有列」用,'Id' 值已經是
-- 'newId' 算出來的,不必再經 'idOf')。
mkProjEntry' :: Id -> Text -> FilePath -> ProjectEntry
mkProjEntry' i nm p = ProjectEntry {peId = i, peName = nm, pePath = p}

-- | 空的中樞快照:沒有任何 vault/project/llm,tools 也是空的。
emptyHub :: Hub
emptyHub = mkHub [] [] Nothing (ToolsConfig Nothing) ""

-- | 建好一個中樞目錄(還沒有 @config.toml@)與一個既存的專案目錄,交給動作跑。
withRegistryEnv :: (HubLocation -> FilePath -> IO a) -> IO a
withRegistryEnv act = withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> act (locAt hubDir) projDir

-- | spec「數據」節「測試素材」的手寫底稿:一段註解 + 一列 @[[vaults]]@,
-- 沒有 @[[projects]]@/@[llm]@/@[tools]@(X16 用)。
commentedHubText :: Text
commentedHubText =
  T.unlines
    [ "# 我的中樞設定 —— 手寫,請勿用工具整檔重寫"
    , ""
    , "[[vaults]]"
    , "id   = \"vlt-7f3b2a91\""
    , "name = \"alchbees-assets\""
    , "kind = \"asset\""
    , "path = \"C:/Users/User/Documents/alchbees-assets\""
    ]

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F005 Aapms.Workspace.Projects" $ do
  --------------------------------------------------------------------------
  describe "T1/L1-L3/X1-X5: allocateProjectId 純函式配號" $ do
    it "test_allocate_project_id_no_collision_uses_salt_zero (X1, L1, L2): 沒撞就是 salt 0" $ do
      let result = allocateProjectId [] "Circle" t0
      result `shouldBe` newId PPrj "Circle" t0 0

    it "test_allocate_project_id_retries_on_collision (X2, L2): 撞號跳到 salt 1,不是照發 salt 0" $
      hedgehog $ do
        nm <- forAll genName
        t <- forAll genUTCTime
        let salt0 = newId PPrj nm t 0
            existing = [mkProjEntry' salt0 "x" "C:/x"]
        allocateProjectId existing nm t === newId PPrj nm t 1

    it "test_allocate_project_id_retries_twice (X3, L2): salt 0/1 都撞了,得到 salt 2" $
      hedgehog $ do
        nm <- forAll genName
        t <- forAll genUTCTime
        let salt0 = newId PPrj nm t 0
            salt1 = newId PPrj nm t 1
            existing = [mkProjEntry' salt0 "x" "C:/x", mkProjEntry' salt1 "y" "C:/y"]
        allocateProjectId existing nm t === newId PPrj nm t 2

    it "test_allocate_project_id_ignores_other_fields (X4, L3): peName/pePath 換成任何值,結果不變" $
      hedgehog $ do
        nm <- forAll genName
        t <- forAll genUTCTime
        otherName1 <- forAll genName
        otherName2 <- forAll genName
        otherPath1 <- forAll genAbsPath
        otherPath2 <- forAll genAbsPath
        let salt0 = newId PPrj nm t 0
            existing1 = [mkProjEntry' salt0 otherName1 otherPath1]
            existing2 = [mkProjEntry' salt0 otherName2 otherPath2]
        allocateProjectId existing1 nm t === allocateProjectId existing2 nm t

    it "test_allocate_project_id_shape_is_prj_plus_8_hex (X5, L1): 對任意 existing/nm/t 恒成立" $
      hedgehog $ do
        nm <- forAll genName
        t <- forAll genUTCTime
        existing <- forAll (Gen.list (Range.linear 0 5) genProjectEntry)
        let i = allocateProjectId existing nm t
            rendered = renderId i
        T.length rendered === 12
        T.take 4 rendered === "prj-"
        T.all (`elem` ("0123456789abcdef" :: String)) (T.drop 4 rendered) === True
        case parseId rendered of
          Right (prefix, i') -> do
            prefix === PPrj
            i' === i
          Left _ -> do
            annotate "parseId 應該能剖析 allocateProjectId 自己產生的字串"
            failure
  --------------------------------------------------------------------------
  describe "T2/L6,L7,L9,L15,L16/X9-X13,X17,X28-X30: registerProject 前置檢查" $ do
    it "test_register_project_blank_name_is_invalid_name (X9, L6, L15, L16): 全空白名稱" $
      withRegistryEnv $ \loc projDir -> do
        snapBefore <- snapshotTree projDir
        result <- registerProject loc emptyHub projDir "   "
        snapAfter <- snapshotTree projDir
        result `shouldBe` Left (InvalidName "   ")
        snapAfter `shouldBe` snapBefore
        hubExists <- doesFileExist (hubConfigFile (hlPath loc))
        hubExists `shouldBe` False

    it "test_register_project_empty_name_is_invalid_name (X10, L6): 空字串" $
      withRegistryEnv $ \loc projDir -> do
        result <- registerProject loc emptyHub projDir ""
        result `shouldBe` Left (InvalidName "")

    it "test_register_project_missing_path (X11, L7): 路徑不存在" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            missingDir = hubDir </> "no-such-dir"
        canon <- canonicalizePath missingDir
        result <- registerProject loc emptyHub missingDir "Circle"
        result `shouldBe` Left (ProjectPathMissing "Circle" canon)
        let msg = renderWorkspaceError (ProjectPathMissing "Circle" canon)
        msg `shouldSatisfy` T.isInfixOf "Circle"
        msg `shouldSatisfy` T.isInfixOf (T.pack canon)

    it "test_register_project_file_path_is_missing (X12, L7): 路徑是普通檔案,不是目錄" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \parent -> do
        let loc = locAt hubDir
            filePath = parent </> "just-a-file.txt"
        writeFile filePath "not a directory"
        canon <- canonicalizePath filePath
        result <- registerProject loc emptyHub filePath "Circle"
        result `shouldBe` Left (ProjectPathMissing "Circle" canon)

    it "test_register_project_name_checked_before_path (X13, L6): 名稱與路徑都錯,回 InvalidName" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            missingDir = hubDir </> "nope"
        result <- registerProject loc emptyHub missingDir "  "
        result `shouldBe` Left (InvalidName "  ")

    it "test_register_project_failure_writes_nothing (L15, L16): 三種前置檢查失敗都不寫任何檔案" $ do
      withRegistryEnv $ \loc projDir -> do
        snapBefore <- snapshotTree projDir
        _ <- registerProject loc emptyHub projDir "   "
        snapAfter <- snapshotTree projDir
        snapAfter `shouldBe` snapBefore
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            missingDir = hubDir </> "nope"
        result <- registerProject loc emptyHub missingDir "Circle"
        case result of
          Left (ProjectPathMissing _ _) -> pure ()
          _ -> expectationFailure "expected ProjectPathMissing"
        hubExists <- doesFileExist (hubConfigFile hubDir)
        hubExists `shouldBe` False
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (hub1, e1) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        beforeCfg <- readHubConfigText hubDir
        result2 <- registerProject loc hub1 projDir "Circle2"
        result2 `shouldBe` Left (ProjectAlreadyRegistered (peId e1) (pePath e1))
        afterCfg <- readHubConfigText hubDir
        afterCfg `shouldBe` beforeCfg

    it "test_register_project_same_path_twice_is_already_registered (X17, L9, L16)" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (hub1, e1) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        cfgAfterFirst <- readHubConfigText hubDir
        result2 <- registerProject loc hub1 projDir "Circle2"
        result2 `shouldBe` Left (ProjectAlreadyRegistered (peId e1) (pePath e1))
        hubProjects hub1 `shouldBe` [e1]
        cfgAfterSecond <- readHubConfigText hubDir
        cfgAfterSecond `shouldBe` cfgAfterFirst

    it "test_register_project_already_registered_detects_other_spelling (X28, L9): 兩種寫法正規化成同一個字串" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (hub1, e1) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        result2 <- registerProject loc hub1 (projDir </> "a" </> "..") "Circle2"
        result2 `shouldBe` Left (ProjectAlreadyRegistered (peId e1) (pePath e1))

    it "test_register_project_does_not_renormalize_existing_rows (X29, L9): 手寫未正規化路徑擋不住重複" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
            handwrittenPath = projDir </> "sub" </> ".." -- 語意上與 projDir 相同,但字串未正規化
            e0 = mkProjEntry "prj-00000000" "Existing" handwrittenPath
            hub = mkHub [] [e0] Nothing (ToolsConfig Nothing) ""
        result <- registerProject loc hub projDir "Circle"
        case result of
          Right (hub', e) -> hubProjects hub' `shouldBe` [e0, e]
          Left _ -> expectationFailure "expected Right(擋不住,中樞出現第二列)"

    it "test_render_already_registered_has_id_and_path (X30, L9): 訊息同時含 id 與路徑" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (_, e1) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        let msg = renderWorkspaceError (ProjectAlreadyRegistered (peId e1) (pePath e1))
        T.null msg `shouldBe` False
        msg `shouldSatisfy` T.isInfixOf (renderId (peId e1))
        msg `shouldSatisfy` T.isInfixOf (T.pack (pePath e1))
  --------------------------------------------------------------------------
  describe "T3/L4,L5,L8,L10/X6-X8,X14-X16,X18: registerProject 主線" $ do
    it "test_register_project_success_fields (X6, L4, L5): 成功時四個欄位與其餘三段不變" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        canon <- canonicalizePath projDir
        (hub', e) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        peName e `shouldBe` "Circle"
        pePath e `shouldBe` canon
        hubProjects hub' `shouldBe` [e]
        hubVaults hub' `shouldBe` hubVaults emptyHub
        hubLlm hub' `shouldBe` hubLlm emptyHub
        hubTools hub' `shouldBe` hubTools emptyHub
        case parseId (renderId (peId e)) of
          Right (prefix, i') -> do
            prefix `shouldBe` PPrj
            i' `shouldBe` peId e
          Left _ -> expectationFailure "renderId (peId e) 應該能被 parseId 剖析回來"

    it "test_register_project_appends_at_end (X7, L4d): 追加到既有列的末尾,既有列原樣" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> withTempHubDir $ \otherDir -> do
        let loc = locAt hubDir
        otherDir' <- canonicalizePath otherDir
        let e0 = mkProjEntry "prj-00000001" "Other" otherDir'
            hub = mkHub [] [e0] Nothing (ToolsConfig Nothing) ""
        (hub', e) <- orDie =<< registerProject loc hub projDir "Circle"
        hubProjects hub' `shouldBe` [e0, e]

    it "test_register_project_stores_trimmed_name (X8, L4b): 存進去的是去空白後的名稱" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (_, e) <- orDie =<< registerProject loc emptyHub projDir "  Circle  "
        peName e `shouldBe` "Circle"

    it "test_register_project_normalizes_path (X14, L4c): . / .. 被正規化,存進去的是絕對路徑" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
            weirdPath = projDir </> "a" </> ".." </> "."
        canon <- canonicalizePath projDir
        (_, e) <- orDie =<< registerProject loc emptyHub weirdPath "Circle"
        pePath e `shouldBe` canon

    it "test_register_project_roundtrips_through_load_hub (X15, L8): 成功後 loadHub 讀得回同一份 projects" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        let loc = locAt hubDir
        (hub', _) <- orDie =<< registerProject loc emptyHub projDir "Circle"
        hub'' <- orDie =<< loadHub loc
        hubProjects hub'' `shouldBe` hubProjects hub'

    it "test_register_project_roundtrips_with_control_char_names (L8): 完整定義域,含換行/tab/其他控制字元" $
      hedgehog $ do
        nm <- forAll genNameWithControlChars
        outcome <- liftIO $ withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
          let loc = locAt hubDir
          r <- registerProject loc emptyHub projDir nm
          case r of
            Left err -> pure (Left err)
            Right (hub', _) -> do
              lr <- loadHub loc
              pure $ case lr of
                Left lerr -> Left lerr
                Right hub'' -> Right (hubProjects hub' == hubProjects hub'')
        case outcome of
          Left _ -> do
            annotate "L8 紅綠預期:F001 quoteText 修正前,控制字元段落預期紅,歸因是 Hub 的序列化器,不是本模組"
            failure
          Right same -> same === True

    it "test_register_project_preserves_comments_and_vaults (X16, L5, L8): 手寫的註解與 [[vaults]] 逐字保留" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        writeHubConfig hubDir commentedHubText
        let loc = locAt hubDir
        hub0 <- orDie =<< loadHub loc
        _ <- orDie =<< registerProject loc hub0 projDir "Circle"
        finalText <- readHubConfigText hubDir
        finalText `shouldSatisfy` T.isInfixOf "# 我的中樞設定"
        finalText `shouldSatisfy` T.isInfixOf "[[vaults]]"
        finalText `shouldSatisfy` T.isInfixOf "[[projects]]"

    it "test_register_project_save_failure_is_forwarded (X18, L10, L16): 中樞目錄不存在,原樣轉發 HubWriteFailed" $
      withTempHubDir $ \parent -> withTempHubDir $ \projDir -> do
        let missingHubDir = parent </> "missing-hub"
            loc = locAt missingHubDir
        registerResult <- registerProject loc emptyHub projDir "Circle"
        case registerResult of
          Left err1 -> do
            directResult <- saveHub loc emptyHub
            case directResult of
              Left err2 -> err1 `shouldBe` err2
              Right () -> expectationFailure "預期 saveHub 也失敗"
          Right _ -> expectationFailure "預期中樞目錄不存在時 registerProject 回 Left"
        dirCreated <- doesDirectoryExist missingHubDir
        dirCreated `shouldBe` False
  --------------------------------------------------------------------------
  describe "T4/L11,L12(b)(c),L13,L14/X19,X21-X25,X31: forgetProject selector" $ do
    it "test_forget_project_id_beats_name (X19, L11): id 命中時 name 完全不參與" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e1 = mkProjEntry "prj-91c0aa12" "Circle" "C:/a"
            e2 = mkProjEntry "prj-00000000" "prj-91c0aa12" "C:/b"
            hub = mkHub [] [e1, e2] Nothing (ToolsConfig Nothing) ""
        (hub', hit) <- orDie =<< forgetProject loc hub "prj-91c0aa12"
        hit `shouldBe` e1
        hubProjects hub' `shouldBe` [e2]

    it "test_forget_project_ambiguous_name_lists_all (X21, L12b): 撞名回 Ambiguous,列出全部" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e3 = mkProjEntry "prj-11111111" "Circle" "C:/c3"
            e4 = mkProjEntry "prj-22222222" "Circle" "C:/c4"
            hub = mkHub [] [e3, e4] Nothing (ToolsConfig Nothing) ""
        _ <- orDie =<< saveHub loc hub
        cfgBefore <- readHubConfigText hubDir
        result <- forgetProject loc hub "Circle"
        result `shouldBe` Left (ProjectSelectorAmbiguous "Circle" [e3, e4])
        cfgAfter <- readHubConfigText hubDir
        cfgAfter `shouldBe` cfgBefore

    it "test_forget_project_ambiguous_id_lists_all (X31, L12b): mkHub 造出的重複 peId,兩階段同一套規則" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e1 = mkProjEntry "prj-91c0aa12" "Circle" "C:/c1"
            e2 = mkProjEntry "prj-91c0aa12" "Other" "C:/c2"
            hub = mkHub [] [e1, e2] Nothing (ToolsConfig Nothing) ""
        result <- forgetProject loc hub "prj-91c0aa12"
        result `shouldBe` Left (ProjectSelectorAmbiguous "prj-91c0aa12" [e1, e2])

    it "test_forget_project_ambiguous_removes_nothing (X21, L12b): 撞名時中樞一列都沒少" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e3 = mkProjEntry "prj-11111111" "Circle" "C:/c3"
            e4 = mkProjEntry "prj-22222222" "Circle" "C:/c4"
            hub = mkHub [] [e3, e4] Nothing (ToolsConfig Nothing) ""
        _ <- orDie =<< saveHub loc hub
        result <- forgetProject loc hub "Circle"
        case result of
          Left (ProjectSelectorAmbiguous _ es) -> es `shouldBe` [e3, e4]
          _ -> expectationFailure "expected ProjectSelectorAmbiguous"
        hub'' <- orDie =<< loadHub loc
        hubProjects hub'' `shouldBe` [e3, e4]

    it "test_forget_project_not_found (X22, L12c): 兩階段都沒命中" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
        result <- forgetProject loc emptyHub "nope"
        result `shouldBe` Left (ProjectSelectorNotFound "nope")

    it "test_forget_project_is_case_sensitive (X23, L13): 大小寫不同視為不命中" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e = mkProjEntry "prj-91c0aa12" "Circle" "C:/c"
            hub = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
        result <- forgetProject loc hub "CIRCLE"
        result `shouldBe` Left (ProjectSelectorNotFound "CIRCLE")

    it "test_forget_project_does_not_trim (X24, L13): 前後空白視為不命中" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e = mkProjEntry "prj-91c0aa12" "Circle" "C:/c"
            hub = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
        result <- forgetProject loc hub " Circle "
        result `shouldBe` Left (ProjectSelectorNotFound " Circle ")

    it "test_forget_project_never_matches_without_exact_equality (L13): 任意不逐字相等的 selector 都不命中" $
      hedgehog $ do
        e <- forAll genProjectEntry
        suffix <- forAll (Gen.element ("!?_" :: String))
        let s = peName e <> T.singleton suffix
        if s == renderId (peId e) || s == peName e
          then pure () -- 極端情況下(理論上不會發生)跳過,避免斷言前提不成立
          else do
            result <- liftIO $ withTempHubDir $ \hubDir -> do
              let loc = locAt hubDir
                  hub = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
              forgetProject loc hub s
            result === Left (ProjectSelectorNotFound s)

    it "test_forget_project_ignores_other_sections (X25, L14): 回傳的 ProjectEntry 只由 [[projects]] 與 selector 決定" $
      hedgehog $ do
        v <- forAll genVaultEntry
        llm <- forAll (Gen.maybe genLlmSection)
        tools <- forAll genToolsConfig
        srcText <- forAll genHubSourceText
        (hitA, hitB) <- liftIO $ do
          let e = mkProjEntry "prj-91c0aa12" "Circle" "C:/c"
              hubA = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
              hubB = mkHub [v] [e] llm tools srcText
          hitA <- withTempHubDir $ \hubDir -> do
            (_, hit) <- orDie =<< forgetProject (locAt hubDir) hubA "Circle"
            pure hit
          hitB <- withTempHubDir $ \hubDir -> do
            (_, hit) <- orDie =<< forgetProject (locAt hubDir) hubB "Circle"
            pure hit
          pure (hitA, hitB)
        hitA === hitB
  --------------------------------------------------------------------------
  describe "T5/L12(a),L15,L16/X20,X26,X27: forgetProject 主線" $ do
    it "test_forget_project_removes_only_that_row (X20, L12a): 只刪那一列,其餘三段不變" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e1 = mkProjEntry "prj-91c0aa12" "Circle" "C:/c1"
            e2 = mkProjEntry "prj-22222222" "Other" "C:/c2"
            hub = mkHub [] [e1, e2] Nothing (ToolsConfig Nothing) ""
        (hub', hit) <- orDie =<< forgetProject loc hub "prj-91c0aa12"
        hit `shouldBe` e1
        hubProjects hub' `shouldBe` [e2]
        hubVaults hub' `shouldBe` hubVaults hub
        hubLlm hub' `shouldBe` hubLlm hub
        hubTools hub' `shouldBe` hubTools hub

    it "test_forget_project_leaves_project_dir_untouched (X20, L15): 專案目錄完全未動" $
      withTempHubDir $ \hubDir -> withTempHubDir $ \projDir -> do
        writeFile (projDir </> "keep.txt") "hello"
        canonP <- canonicalizePath projDir
        let loc = locAt hubDir
            e = mkProjEntry "prj-91c0aa12" "Circle" canonP
            hub = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
        snapBefore <- snapshotTree projDir
        _ <- orDie =<< forgetProject loc hub "prj-91c0aa12"
        snapAfter <- snapshotTree projDir
        snapAfter `shouldBe` snapBefore

    it "test_forget_project_roundtrips_through_load_hub (X26, L12a, L8): 成功後 loadHub 讀得回剩下那一列" $
      withTempHubDir $ \hubDir -> do
        let loc = locAt hubDir
            e1 = mkProjEntry "prj-91c0aa12" "Circle" "C:/c1"
            e2 = mkProjEntry "prj-22222222" "Other" "C:/c2"
            hub = mkHub [] [e1, e2] Nothing (ToolsConfig Nothing) ""
        _ <- orDie =<< forgetProject loc hub "prj-91c0aa12"
        hub'' <- orDie =<< loadHub loc
        hubProjects hub'' `shouldBe` [e2]

    it "test_forget_project_save_failure_is_forwarded (X27, L10): 中樞目錄不存在,原樣轉發且沒有落地" $
      withTempHubDir $ \parent -> do
        let missingHubDir = parent </> "missing-hub"
            loc = locAt missingHubDir
            e = mkProjEntry "prj-91c0aa12" "Circle" "C:/c1"
            hub = mkHub [] [e] Nothing (ToolsConfig Nothing) ""
        result <- forgetProject loc hub "prj-91c0aa12"
        case result of
          Left (HubWriteFailed _ _) -> pure ()
          Left _ -> expectationFailure "expected HubWriteFailed"
          Right _ -> expectationFailure "expected Left when hub dir missing"
        stillMissing <- doesDirectoryExist missingHubDir
        stillMissing `shouldBe` False
  --------------------------------------------------------------------------
  describe "L17(預期綠): 依賴方向與職責界線,以 import 行驗證" $ do
    it "test_projects_no_sibling_or_vault_imports(a): 本套件內的 import 只能是 \
       \Aapms.Workspace.Types 或 Aapms.Workspace.Hub" $ do
      importLines <- projectsImportLines
      let sibling = filter (\l -> "Aapms.Workspace." `isPrefixOf` moduleNameOf l) importLines
      mapM_ (\l -> moduleNameOf l `shouldSatisfy` (`elem` ["Aapms.Workspace.Types", "Aapms.Workspace.Hub"])) sibling

    it "test_projects_never_imports_store(b): 完全不得出現任何 import Aapms.Store 開頭的行" $ do
      importLines <- projectsImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotSatisfy` isPrefixOf "Aapms.Store") importLines

    it "test_projects_core_id_import_is_allocation_only(c): 若有 import Aapms.Core.Id,\
       \匯入清單只能是 {Id, IdPrefix (PPrj), newId, renderId} 的子集" $ do
      importLines <- projectsImportLines
      let coreIdLines = filter (\l -> moduleNameOf l == "Aapms.Core.Id") importLines
          allowed = ["Id", "IdPrefix (PPrj)", "newId", "renderId"]
      mapM_ (\l -> parseImportItems l `shouldSatisfy` all (`elem` allowed)) coreIdLines

    it "test_projects_no_process_import(d): 完全不得 import System.Process" $ do
      importLines <- projectsImportLines
      mapM_ (\l -> moduleNameOf l `shouldNotBe` "System.Process") importLines

    it "test_projects_never_reads_manifests(e): 除 Aapms.Core.Id 外不得 import 任何 \
       \Aapms.Core. 開頭的行,也不得 import Data.Aeson" $ do
      importLines <- projectsImportLines
      let coreLines = filter (\l -> "Aapms.Core." `isPrefixOf` moduleNameOf l) importLines
      mapM_ (\l -> moduleNameOf l `shouldBe` "Aapms.Core.Id") coreLines
      mapM_ (\l -> moduleNameOf l `shouldNotSatisfy` isPrefixOf "Data.Aeson") importLines
