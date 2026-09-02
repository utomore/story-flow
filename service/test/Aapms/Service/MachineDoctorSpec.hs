-- | F002:'Aapms.Service.Machine.workspaceDoctor' \/ 'Aapms.Service.Types.DoctorView'
-- 與 'Aapms.Service.Machine.workspaceTools'。
--
-- __spec 對照__(「1-to-1 測試對照表」——全部紅:兩者本體皆 @undefined@):
--
-- @
-- LAW-5,EX-5-EX-8    六欄的來源(逐欄對應 askHubLocation\/askRegistrySource\/vaultCheck\/workspaceTools\/hubLlm) -> prop_doctor_six_fields_match
-- LAW-6,EX-5,EX-6    dvVaults 含 vaultList 全部,其後至多一筆                                                  -> prop_doctor_dvVaults_prefix, test_doctor_outside_example
-- LAW-7,EX-5,EX-6    未註冊那一筆的存在條件(iff)                                                              -> prop_doctor_unregistered_row_iff, test_doctor_unregistered_va_example
-- LAW-8,EX-7,EX-8    [llm] 內容不外洩,只反映存不存在                                                          -> prop_llm_not_leaked, test_llm_configured_sentinel_example, test_llm_absent_example
-- LAW-9,EX-9       唯讀:doctor/check 前後位元組不變                                                         -> prop_doctor_check_readonly, test_doctor_and_check_readonly_example
-- LAW-10,EX-10     workspaceTools 單筆、無失敗通道、等於 detectSevenZip (hubTools hub)                       -> prop_workspace_tools_matches_detect, test_workspace_tools_not_found_example
-- @
module Aapms.Service.MachineDoctorSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Workspace.Lifecycle (checkVaults)
import Aapms.Workspace.Tools (detectSevenZip)
import Aapms.Workspace.Types (HubLocation (..), hubLlm, hubTools)

import Aapms.Service.Fixtures
import Aapms.Service.Machine
  ( DoctorView (..)
  , ToolOrigin (..)
  , ToolStatus (..)
  , VaultView (..)
  , vaultCheck
  , vaultList
  , workspaceDoctor
  , workspaceTools
  )
import Aapms.Service.Monad (askHub, askHubLocation, askRegistrySource, runService)

--------------------------------------------------------------------------------
-- 佈局變化

-- | 從中樞刪掉 VA 那一列(@va\/.aapms\/@ 保留)。
withUnregisteredVaLayout :: (FixedLayout -> IO a) -> IO a
withUnregisteredVaLayout act = withFixedLayout $ \fl -> do
  writeHubConfigAt (flHubDir fl) (hubConfigText [(flVbId fl, "assets", vbKindText, flVbPath fl)])
  act fl

-- | 中樞加一段 @[llm]@(內容不拘,'Aapms.Workspace.Types.LlmSection' 只是任意
-- TOML 表)。
withLlmLayout :: Text -> (FixedLayout -> IO a) -> IO a
withLlmLayout apiKey act = withFixedLayout $ \fl -> do
  let base =
        hubConfigText
          [ (flVaId fl, "story", vaKindText, flVaPath fl)
          , (flVbId fl, "assets", vbKindText, flVbPath fl)
          ]
      llm = "[llm]\napi_key = \"" <> apiKey <> "\"\n"
  writeHubConfigAt (flHubDir fl) (base <> llm)
  act fl

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: workspaceDoctor / workspaceTools" $ do
  --------------------------------------------------------------------------
  describe "LAW-5,EX-5-EX-8: DoctorView 六欄的來源" $
    it "prop_doctor_six_fields_match (LAW-5): 對任意起點,doctor 的六欄逐一等於各自的來源" $
      hedgehog $ do
        cwdRel <- forAll (Gen.element ["va", "vb", "outside"])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flRoot fl </> cwdRel) $ \env -> do
            hubR <- runService env askHub
            locR <- runService env askHubLocation
            regR <- runService env askRegistrySource
            toolsR <- runService env workspaceTools
            docR <- runService env workspaceDoctor
            checkR <- either (const (pure Nothing)) (fmap Just . checkVaults) hubR
            pure (hubR, locR, regR, toolsR, docR, checkR)
        case outcome of
          (Right hub, Right loc, Right reg, Right tools, Right doc, Just issues) -> do
            dvHubPath doc === hlPath loc
            dvHubSource doc === hlSource loc
            dvRegistry doc === reg
            dvTools doc === tools
            dvScopeIssues doc === issues
            dvLlmConfigured doc === maybe False (const True) (hubLlm hub)
          _ -> do
            let (_, _, _, _, docR, _) = outcome
            annotate (describeServiceResult docR) >> failure

  --------------------------------------------------------------------------
  describe "LAW-6,EX-5,EX-6: dvVaults 含 vaultList 全部,其後至多一筆" $ do
    it "prop_doctor_dvVaults_prefix (LAW-6): 對任意起點,dvVaults 的前 n 筆逐欄等於 vaultList,其後至多一筆" $
      hedgehog $ do
        cwdRel <- forAll (Gen.element ["va", "vb", "outside"])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flRoot fl </> cwdRel) $ \env -> do
            listR <- runService env vaultList
            docR <- runService env workspaceDoctor
            pure (listR, docR)
        case outcome of
          (Right vs, Right doc) -> do
            let n = length vs
                (prefix, rest) = splitAt n (dvVaults doc)
            prefix === vs
            (length rest <= 1) === True
            case rest of
              [] -> pure ()
              [r] -> vvRegistered r === False
              _ -> failure
          (listR, docR) ->
            annotate (describeServiceResult listR <> " / " <> describeServiceResult docR) >> failure

    it "test_doctor_outside_example (EX-6): 起點在 outside/ 之下,dvVaults 逐欄等於 vaultList,沒有 vvRegistered==False 的項目" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          listR <- runService env vaultList
          docR <- runService env workspaceDoctor
          case (listR, docR) of
            (Right vs, Right doc) -> dvVaults doc `shouldBe` vs
            _ -> expectationFailure (describeServiceResult listR <> " / " <> describeServiceResult docR)

  --------------------------------------------------------------------------
  describe "LAW-7,EX-5,EX-6: 未註冊那一筆的存在條件" $ do
    it "prop_doctor_unregistered_row_iff (LAW-7): 起點在未註冊 vault 根目錄時恰多一筆,起點在 outside 時沒有" $
      hedgehog $ do
        useUnregistered <- forAll Gen.bool
        outcome <-
          liftIO $
            if useUnregistered
              then withUnregisteredVaLayout $ \fl ->
                withOpenEnv Nothing (flVaPath fl) $ \env -> do
                  docR <- runService env workspaceDoctor
                  pure (docR, Just (flVaId fl))
              else withFixedLayout $ \fl ->
                withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
                  docR <- runService env workspaceDoctor
                  pure (docR, Nothing)
        case outcome of
          (Right doc, Just vid) -> do
            let unregistered = [v | v <- dvVaults doc, not (vvRegistered v)]
            case unregistered of
              [row] -> do
                vvId row === vid
                vvReachable row === True
              _ -> failure
          (Right doc, Nothing) ->
            [v | v <- dvVaults doc, not (vvRegistered v)] === []
          (docR, _) -> annotate (describeServiceResult docR) >> failure

    it "test_doctor_unregistered_va_example (EX-5): 未註冊那一筆是 VA,vvPath 是 <tmp>/va 的正規化路徑" $
      withUnregisteredVaLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          canon <- canonicalizePath (flVaPath fl)
          result <- runService env workspaceDoctor
          case result of
            Right doc -> case dvVaults doc of
              [first, second] -> do
                vvId first `shouldBe` flVbId fl
                vvRegistered first `shouldBe` True
                vvId second `shouldBe` flVaId fl
                vvRegistered second `shouldBe` False
                vvReachable second `shouldBe` True
                vvPath second `shouldBe` canon
              other -> expectationFailure ("預期恰兩筆," <> show (length other))
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "LAW-8,EX-7,EX-8: [llm] 內容不外洩" $ do
    it "prop_llm_not_leaked (LAW-8): 對任意 [llm] 內容,show doctorView 不含它的子字串,dvLlmConfigured==True" $
      hedgehog $ do
        apiKey <- forAll (Gen.text (Range.linear 5 20) Gen.alphaNum)
        outcome <- liftIO $ withLlmLayout apiKey $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> runService env workspaceDoctor
        case outcome of
          Right doc -> do
            T.isInfixOf apiKey (T.pack (show doc)) === False
            dvLlmConfigured doc === True
          Left e -> annotate (show e) >> failure

    it "test_llm_configured_sentinel_example (EX-7): api_key 是特徵字串,show 整份報告不含它也不含 \"api_key\"" $
      withLlmLayout "SENTINEL-7f3b9c" $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env workspaceDoctor
          case result of
            Right doc -> do
              dvLlmConfigured doc `shouldBe` True
              let rendered = show doc
              rendered `shouldNotContain` "SENTINEL"
              rendered `shouldNotContain` "api_key"
            Left e -> expectationFailure (show e)

    it "test_llm_absent_example (EX-8): 無 [llm] 段時 dvLlmConfigured == False" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env workspaceDoctor
          fmap dvLlmConfigured result `shouldBe` Right False

  --------------------------------------------------------------------------
  describe "LAW-9,EX-9: 唯讀" $ do
    it "prop_doctor_check_readonly (LAW-9): 對任意起點,doctor 與 check 執行前後,中樞與各 vault 的 .aapms/ 位元組不變" $
      hedgehog $ do
        cwdRel <- forAll (Gen.element ["va", "vb", "outside"])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flRoot fl </> cwdRel) $ \env -> do
            let dirs = [flHubDir fl, flVaPath fl </> ".aapms", flVbPath fl </> ".aapms"]
            snapBefore <- concat <$> mapM snapshotTree dirs
            _ <- runService env workspaceDoctor
            _ <- runService env vaultCheck
            snapAfter <- concat <$> mapM snapshotTree dirs
            pure (snapBefore, snapAfter)
        let (snapBefore, snapAfter) = outcome
        snapAfter === snapBefore

    it "test_doctor_and_check_readonly_example (EX-9): 對 hub/、va/.aapms/、vb/.aapms/ 取兩次快照,doctor 與 check 之間位元組不變" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          let dirs = [flHubDir fl, flVaPath fl </> ".aapms", flVbPath fl </> ".aapms"]
          snapBefore <- concat <$> mapM snapshotTree dirs
          _ <- runService env workspaceDoctor
          _ <- runService env vaultCheck
          snapAfter <- concat <$> mapM snapshotTree dirs
          snapAfter `shouldBe` snapBefore

  --------------------------------------------------------------------------
  describe "LAW-10,EX-10: workspaceTools 單筆、無失敗通道" $ do
    it "prop_workspace_tools_matches_detect (LAW-10): workspaceTools 恆回長度 1 的清單,該筆等於 detectSevenZip (hubTools hub)" $
      hedgehog $ do
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            hubR <- runService env askHub
            toolsR <- runService env workspaceTools
            direct <- either (const (pure Nothing)) (fmap Just . detectSevenZip . hubTools) hubR
            pure (toolsR, direct)
        case outcome of
          (Right [t], Just direct) -> t === direct
          (toolsR, _) -> annotate (describeServiceResult toolsR) >> failure

    it "test_workspace_tools_not_found_example (EX-10): [tools] 未設、PATH 清空後,回長度 1 的清單,三層(PATH、[tools]、內建安裝路徑)都嘗試過" $
      withFixedLayout $ \fl ->
        withEnvVars [("PATH", "")] $
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            result <- runService env workspaceTools
            case result of
              Right [t] -> do
                tsName t `shouldBe` "7-Zip"
                tsSearched t `shouldNotBe` []
              other -> expectationFailure ("預期 Right 恰一筆," <> show other)
