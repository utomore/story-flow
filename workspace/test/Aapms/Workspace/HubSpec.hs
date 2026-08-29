-- | F001:'Aapms.Workspace.Hub' 的 'loadHub' \/ 'saveHub'(L4-L10\/X4-X17\/X27)與
-- 四個純增刪 'upsertVault' \/ 'removeVault' \/ 'upsertProject' \/ 'removeProject'
-- (L11-L13\/X18)。'mkHub' 與五個 selector 互逆的 L16 在
-- "Aapms.Workspace.TypesSpec" 測(那是 'Aapms.Workspace.Types' 的骨架事實)。
--
-- __spec 對照__(@.design\/subsystems\/workspace\/features\/F001-hub-registry.md@):
--
-- @
-- L4  中樞檔案不存在即失敗,不退回空中樞                    -> test_load_hub_not_found
-- L5  TOML 壞掉 vs 欄位不合規                                -> test_load_hub_unreadable_on_bad_toml / test_load_hub_malformed_*
-- L6  四段缺席是合法的空中樞                                 -> test_load_hub_all_sections_absent
-- L7  hubLlm 三態可區分                                      -> test_hub_llm_three_states
-- L8  saveHub 對未修改的 Hub 是位元組恆等                     -> test_save_hub_byte_identical_when_unmodified
-- L9  roundtrip 逐欄相等                                     -> test_load_save_load_field_equal
-- L10 改動後仍保留註解與空白行                                -> test_save_hub_preserves_comments_after_upsert
-- L11 upsertVault 的語意                                     -> test_upsert_vault_appends / test_upsert_vault_replaces_in_place
-- L12 removeVault 的語意                                     -> test_remove_vault_preserves_order / test_remove_vault_absent_is_noop
-- L13 upsertProject / removeProject 對稱於 L11 / L12         -> test_project_ops_mirror_vault_ops
-- X4-X10 loadHub 的錯誤分流                                  -> test_load_hub_*
-- X11 完整樣本的載入結果                                     -> test_load_hub_full_sample
-- X12/X13 四段缺席 / [llm] 空段                              -> test_load_hub_all_sections_absent / test_hub_llm_three_states
-- X14/X15 byte-identical + reload                            -> test_save_hub_byte_identical_when_unmodified / test_load_save_load_field_equal
-- X16/X17 upsert/remove 後仍保留其餘內容                      -> test_save_hub_preserves_comments_after_upsert / test_save_hub_preserves_other_sections_after_remove
-- X18 removeVault 對不存在的 id 是 no-op                      -> test_remove_vault_absent_is_noop
-- X27 saveHub 父目錄不存在                                   -> test_save_hub_does_not_create_directory
-- @
module Aapms.Workspace.HubSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.List (isSubsequenceOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Fixtures
import Aapms.Workspace.Hub
import Aapms.Workspace.Types

import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))

-- | 寫入內容、呼叫 'loadHub',期望 'HubMalformed',且訊息含全部關鍵字、
-- 'renderWorkspaceError' 含檔案路徑。
expectMalformed :: FilePath -> Text -> [Text] -> IO ()
expectMalformed dir content keywords = do
  writeHubConfig dir content
  r <- loadHub (locAt dir)
  case r of
    Left e@(HubMalformed fp msg) -> do
      fp `shouldBe` hubConfigFile dir
      mapM_ (\kw -> msg `shouldSatisfy` T.isInfixOf kw) keywords
      renderWorkspaceError e `shouldSatisfy` T.isInfixOf (T.pack fp)
    other -> expectationFailure ("預期 HubMalformed,得到 " <> show other)

-- | 寫入內容、呼叫 'loadHub',期望 'HubUnreadable',且 'renderWorkspaceError' 含
-- 檔案路徑。
expectUnreadable :: FilePath -> Text -> IO ()
expectUnreadable dir content = do
  writeHubConfig dir content
  r <- loadHub (locAt dir)
  case r of
    Left e@(HubUnreadable fp _) -> do
      fp `shouldBe` hubConfigFile dir
      renderWorkspaceError e `shouldSatisfy` T.isInfixOf (T.pack fp)
    other -> expectationFailure ("預期 HubUnreadable,得到 " <> show other)

spec :: Spec
spec = describe "F001 Aapms.Workspace.Hub" $ do
  describe "L4/X4: loadHub 對不存在的檔案" $
    it "test_load_hub_not_found: 回 HubNotFound,不是空 Hub" $
      withTempHubDir $ \dir -> do
        r <- loadHub (locAt dir)
        r `shouldBe` Left (HubNotFound (hubConfigFile dir))

  describe "L5/X5: TOML 語法錯" $
    it "test_load_hub_unreadable_on_bad_toml" $
      withTempHubDir $ \dir -> expectUnreadable dir "[[vaults\n"

  describe "L5/X6-X10: 欄位不合規" $ do
    it "test_load_hub_malformed_missing_id: 缺 id" $
      withTempHubDir $ \dir ->
        expectMalformed
          dir
          (T.unlines ["[[vaults]]", "name = \"a\"", "kind = \"asset\"", "path = \"C:/a\""])
          ["id"]

    it "test_load_hub_malformed_bad_kind: kind 不是 asset/story" $
      withTempHubDir $ \dir ->
        expectMalformed
          dir
          (T.unlines ["[[vaults]]", "id = \"vlt-7f3b2a91\"", "name = \"a\"", "kind = \"media\"", "path = \"C:/a\""])
          ["kind", "media"]

    it "test_load_hub_malformed_relative_path: path 非絕對" $
      withTempHubDir $ \dir ->
        expectMalformed
          dir
          (T.unlines ["[[vaults]]", "id = \"vlt-7f3b2a91\"", "name = \"a\"", "kind = \"asset\"", "path = \"assets/lib\""])
          ["path", "assets/lib"]

    it "test_load_hub_malformed_wrong_prefix: id 前綴不是 vlt" $
      withTempHubDir $ \dir ->
        expectMalformed
          dir
          (T.unlines ["[[vaults]]", "id = \"prj-91c0aa12\"", "name = \"a\"", "kind = \"asset\"", "path = \"C:/a\""])
          ["vlt", "prj-91c0aa12"]

    it "test_load_hub_malformed_duplicate_id: 兩列同一個 id" $
      withTempHubDir $ \dir ->
        expectMalformed
          dir
          ( T.unlines
              [ "[[vaults]]"
              , "id = \"vlt-7f3b2a91\""
              , "name = \"a\""
              , "kind = \"asset\""
              , "path = \"C:/a\""
              , ""
              , "[[vaults]]"
              , "id = \"vlt-7f3b2a91\""
              , "name = \"b\""
              , "kind = \"story\""
              , "path = \"C:/b\""
              ]
          )
          ["vlt-7f3b2a91"]

  describe "L6/X12: 四段全部缺席是合法的空中樞" $
    it "test_load_hub_all_sections_absent" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir "# 空的中樞\n"
        r <- loadHub (locAt dir)
        case r of
          Right hub -> do
            hubVaults hub `shouldBe` []
            hubProjects hub `shouldBe` []
            hubLlm hub `shouldBe` Nothing
            hubTools hub `shouldBe` ToolsConfig Nothing
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

  describe "L7/X13: hubLlm 三態可區分" $ do
    it "X13: [llm] 存在但沒有任何鍵時,hubLlm 是 Just 空表,且 /= Nothing" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir "[llm]\n"
        r <- loadHub (locAt dir)
        case r of
          Right hub -> do
            hubLlm hub `shouldBe` Just (LlmSection Map.empty)
            hubLlm hub `shouldNotBe` Nothing
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

    it "test_hub_llm_three_states: [llm] 有 n 個鍵時,size 與鍵集合逐一相符" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 5))
        let keys = map (\i -> "key" <> T.pack (show i)) [0 .. n - 1]
            content = T.unlines ("[llm]" : map (\k -> k <> " = \"v\"") keys)
        result <- liftIO $ withTempHubDir $ \dir -> do
          writeHubConfig dir content
          loadHub (locAt dir)
        case result of
          Right hub -> case hubLlm hub of
            Just (LlmSection m) -> do
              Map.size m === n
              Map.keysSet m === Set.fromList keys
            Nothing -> failure
          Left e -> annotate (show e) >> failure

  describe "X11: 「數據」節樣本檔案的載入結果" $
    it "test_load_hub_full_sample" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir sampleHubText
        r <- loadHub (locAt dir)
        case r of
          Right hub -> do
            hubVaults hub `shouldBe` [sampleVault1, sampleVault2]
            hubProjects hub `shouldBe` [sampleProject1]
            case hubLlm hub of
              Just (LlmSection m) -> Map.keysSet m `shouldBe` Set.fromList sampleLlmKeys
              Nothing -> expectationFailure "預期 hubLlm 是 Just"
            hubTools hub `shouldBe` sampleTools
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

  describe "L8/X14: saveHub 對未修改的 Hub 是位元組恆等" $
    it "test_save_hub_byte_identical_when_unmodified" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir sampleHubText
        loaded <- loadHub (locAt dir)
        case loaded of
          Left e -> expectationFailure ("前置載入失敗:" <> show e)
          Right hub -> do
            beforeText <- readHubConfigText dir
            saveResult <- saveHub (locAt dir) hub
            saveResult `shouldBe` Right ()
            afterText <- readHubConfigText dir
            afterText `shouldBe` beforeText
            afterText `shouldBe` sampleHubText

  describe "L9/X15: loadHub -> saveHub -> loadHub 逐欄相等" $
    it "test_load_save_load_field_equal" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir sampleHubText
        r0 <- loadHub (locAt dir)
        case r0 of
          Left e -> expectationFailure ("前置載入失敗:" <> show e)
          Right hub0 -> do
            s <- saveHub (locAt dir) hub0
            s `shouldBe` Right ()
            r1 <- loadHub (locAt dir)
            case r1 of
              Left e -> expectationFailure ("重讀失敗:" <> show e)
              Right hub1 -> do
                hubVaults hub1 `shouldBe` hubVaults hub0
                hubProjects hub1 `shouldBe` hubProjects hub0
                hubLlm hub1 `shouldBe` hubLlm hub0
                hubTools hub1 `shouldBe` hubTools hub0

  describe "L10/X16: 改動後仍保留原有註解與空白行,新列附加在最後" $
    it "test_save_hub_preserves_comments_after_upsert" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir sampleHubText
        r0 <- loadHub (locAt dir)
        case r0 of
          Left e -> expectationFailure ("前置載入失敗:" <> show e)
          Right hub0 -> do
            let newEntry = VaultEntry (VaultId "vlt-11112222") "shared-lore" StoryVault "E:/vaults/shared"
                hub1 = upsertVault newEntry hub0
            s <- saveHub (locAt dir) hub1
            s `shouldBe` Right ()
            newText <- readHubConfigText dir
            let origLines = T.lines sampleHubText
                markedLines = filter (\l -> T.null l || "#" `T.isPrefixOf` T.stripStart l) origLines
                newLines = T.lines newText
            markedLines `shouldSatisfy` (`isSubsequenceOf` newLines)
            r2 <- loadHub (locAt dir)
            case r2 of
              Left e -> expectationFailure ("重讀失敗:" <> show e)
              Right hub2 -> hubVaults hub2 `shouldBe` hubVaults hub0 ++ [newEntry]

  describe "X17: removeVault 後 saveHub,其餘三段與開頭註解逐字不變" $
    it "test_save_hub_preserves_other_sections_after_remove" $
      withTempHubDir $ \dir -> do
        writeHubConfig dir sampleHubText
        r0 <- loadHub (locAt dir)
        case r0 of
          Left e -> expectationFailure ("前置載入失敗:" <> show e)
          Right hub0 -> do
            let hub1 = removeVault (VaultId "vlt-a0c4e1f8") hub0
            s <- saveHub (locAt dir) hub1
            s `shouldBe` Right ()
            newText <- readHubConfigText dir
            case T.lines newText of
              (firstLine : _) -> firstLine `shouldBe` "# 我的中樞設定 —— 手寫,請勿用工具整檔重寫"
              [] -> expectationFailure "檔案不應為空"
            r2 <- loadHub (locAt dir)
            case r2 of
              Left e -> expectationFailure ("重讀失敗:" <> show e)
              Right hub2 -> do
                hubVaults hub2 `shouldBe` [sampleVault1]
                hubProjects hub2 `shouldBe` hubProjects hub0
                hubLlm hub2 `shouldBe` hubLlm hub0
                hubTools hub2 `shouldBe` hubTools hub0

  describe "X27: saveHub 到父目錄不存在的位置" $
    it "test_save_hub_does_not_create_directory" $
      withTempHubDir $ \dir -> do
        let missingDir = dir </> "missing-parent"
            loc = locAt missingDir
            hub = mkHub [] [] Nothing (ToolsConfig Nothing) ""
        r <- saveHub loc hub
        case r of
          Left (HubWriteFailed fp _) -> fp `shouldBe` hubConfigFile missingDir
          other -> expectationFailure ("預期 HubWriteFailed,得到 " <> show other)
        doesDirectoryExist missingDir `shouldReturn` False

  describe "L11: upsertVault 的語意(純函式,不碰檔案)" $ do
    it "test_upsert_vault_appends: id 不在清單中時追加到末尾,其餘三段與 hubSourceText 不變" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 5) genVaultEntry)
        ps <- forAll (Gen.list (Range.linear 0 3) genProjectEntry)
        llm <- forAll (Gen.maybe genLlmSection)
        tools <- forAll genToolsConfig
        txt <- forAll genHubSourceText
        e <- forAll (Gen.filter (\e' -> veId e' `notElem` map veId vs) genVaultEntry)
        let h = mkHub vs ps llm tools txt
            h' = upsertVault e h
        hubVaults h' === vs ++ [e]
        hubProjects h' === ps
        hubLlm h' === llm
        hubTools h' === tools
        hubSourceText h' === txt

    it "test_upsert_vault_replaces_in_place: id 已在清單中時就地取代、保序、等長" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 1 5) genVaultEntry)
        idx <- forAll (Gen.int (Range.linear 0 (length vs - 1)))
        let target = vs !! idx
        newFields <- forAll genVaultEntry
        let e = newFields {veId = veId target}
            h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
            h' = upsertVault e h
        length (hubVaults h') === length vs
        map veId (hubVaults h') === map veId vs
        (hubVaults h' !! idx) === e
        [x | (i, x) <- zip [0 :: Int ..] (hubVaults h'), i /= idx]
          === [x | (i, x) <- zip [0 :: Int ..] vs, i /= idx]

  describe "L12: removeVault 的語意(純函式,不碰檔案)" $ do
    it "test_remove_vault_preserves_order: 移除存在的 id,保序" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 1 5) genVaultEntry)
        idx <- forAll (Gen.int (Range.linear 0 (length vs - 1)))
        let target = vs !! idx
            h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
            h' = removeVault (veId target) h
        hubVaults h' === filter ((/= veId target) . veId) vs

    it "test_remove_vault_absent_is_noop / X18: 不存在的 id 回傳與輸入相等的 Hub" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 5) genVaultEntry)
        v <- forAll (Gen.filter (\vid -> vid `notElem` map veId vs) genVaultId)
        let h = mkHub vs [] Nothing (ToolsConfig Nothing) ""
        removeVault v h === h

  describe "L13: upsertProject / removeProject 對稱於 L11 / L12" $ do
    it "test_project_ops_mirror_vault_ops(upsert 追加): id 不在清單中時追加到末尾,hubVaults 不變" $
      hedgehog $ do
        vs <- forAll (Gen.list (Range.linear 0 3) genVaultEntry)
        ps <- forAll (Gen.list (Range.linear 0 5) genProjectEntry)
        p <- forAll (Gen.filter (\p' -> peId p' `notElem` map peId ps) genProjectEntry)
        let h = mkHub vs ps Nothing (ToolsConfig Nothing) ""
            h' = upsertProject p h
        hubProjects h' === ps ++ [p]
        hubVaults h' === vs

    it "test_project_ops_mirror_vault_ops(upsert 取代): id 已在清單中時就地取代、保序、等長" $
      hedgehog $ do
        ps <- forAll (Gen.list (Range.linear 1 5) genProjectEntry)
        idx <- forAll (Gen.int (Range.linear 0 (length ps - 1)))
        let target = ps !! idx
        newFields <- forAll genProjectEntry
        let p = newFields {peId = peId target}
            h = mkHub [] ps Nothing (ToolsConfig Nothing) ""
            h' = upsertProject p h
        length (hubProjects h') === length ps
        map peId (hubProjects h') === map peId ps
        (hubProjects h' !! idx) === p

    it "test_project_ops_mirror_vault_ops(remove 保序): 移除存在的 id,保序" $
      hedgehog $ do
        ps <- forAll (Gen.list (Range.linear 1 5) genProjectEntry)
        idx <- forAll (Gen.int (Range.linear 0 (length ps - 1)))
        let target = ps !! idx
            h = mkHub [] ps Nothing (ToolsConfig Nothing) ""
            h' = removeProject (peId target) h
        hubProjects h' === filter ((/= peId target) . peId) ps

    it "test_project_ops_mirror_vault_ops(remove no-op): 不存在的 id 是 no-op" $
      hedgehog $ do
        ps <- forAll (Gen.list (Range.linear 0 5) genProjectEntry)
        pid <- forAll (Gen.filter (\i -> i `notElem` map peId ps) genProjectId)
        let h = mkHub [] ps Nothing (ToolsConfig Nothing) ""
        removeProject pid h === h
