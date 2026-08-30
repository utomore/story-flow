-- | F002:'Aapms.Service.Machine.workspaceSetup' \/ 'Aapms.Service.Types.SetupView'
-- 與 'Aapms.Service.Machine.workspacePurge' \/ 'Aapms.Service.Types.PurgeView'。
--
-- __spec 對照__(「1-to-1 測試對照表」——全部紅:兩者本體皆 @undefined@):
--
-- @
-- L11,X11,X11b workspaceSetup 是逐欄投影,兩個參數不影響結果,不開 Env  -> prop_setup_matches_setupHub_report, test_workspace_setup_first_time_then_idempotent_example, test_workspace_setup_params_do_not_matter_example
-- L12,X12      workspacePurge 是逐欄投影                              -> prop_purge_matches_purge_report, test_purge_hub_only_example
-- L13,X12      purge 不重載中樞快照                                    -> prop_purge_does_not_reload_snapshot
-- @
module Aapms.Service.MachineSetupPurgeSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Workspace.Lifecycle (purge, setupHub)
import Aapms.Workspace.Location (hubLocation)
import Aapms.Workspace.Types
  ( PurgeReport (..)
  , SetupReport (..)
  )

import Aapms.Service.Fixtures
import Aapms.Service.Machine
  ( PurgeScope (..)
  , PurgeView (..)
  , SetupView (..)
  , workspacePurge
  , workspaceSetup
  )
import Aapms.Service.Monad (askHub, runService)

--------------------------------------------------------------------------------
-- 佈局:一個空目錄當中樞位置(還沒 setup)

withEmptyHomeDir :: (FilePath -> IO a) -> IO a
withEmptyHomeDir act = withTempRoot $ \root -> do
  let home = root </> "home"
  createDirectoryIfMissing True home
  withEnvVars [(aapmsHomeVar, home)] (act home)

withTwoFreshHomes :: (FilePath -> FilePath -> IO a) -> IO a
withTwoFreshHomes act = withTempRoot $ \root -> do
  let h1 = root </> "home1"
      h2 = root </> "home2"
  createDirectoryIfMissing True h1
  createDirectoryIfMissing True h2
  act h1 h2

-- | 若 'True',先在這個位置跑過一次 'setupHub',讓它變成「中樞早就在」的狀態。
prewarm :: Bool -> FilePath -> IO ()
prewarm alreadySetUp home
  | not alreadySetUp = pure ()
  | otherwise = withEnvVars [(aapmsHomeVar, home)] $ do
      loc <- hubLocation
      _ <- setupHub loc
      pure ()

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: workspaceSetup / workspacePurge" $ do
  --------------------------------------------------------------------------
  describe "L11,X11,X11b: workspaceSetup 是逐欄投影,兩個參數不影響結果" $ do
    it "prop_setup_matches_setupHub_report (L11): 對兩個結構相同的獨立中樞位置(皆全新或皆已存在),workspaceSetup 與直接呼叫 setupHub 的兩個 *Created 欄一致" $
      hedgehog $ do
        alreadySetUp <- forAll Gen.bool
        outcome <- liftIO $ withTwoFreshHomes $ \home1 home2 -> do
          prewarm alreadySetUp home1
          prewarm alreadySetUp home2
          r1 <- withEnvVars [(aapmsHomeVar, home1)] (workspaceSetup Nothing "/unused-cwd")
          loc2 <- withEnvVars [(aapmsHomeVar, home2)] hubLocation
          r2 <- setupHub loc2
          pure (r1, r2)
        case outcome of
          (Right v, Right report) -> do
            svHubCreated v === spHubCreated report
            svCacheCreated v === spCacheCreated report
          (v, report) -> annotate (describeServiceResult v <> " / " <> show report) >> failure

    it "test_workspace_setup_first_time_then_idempotent_example (X11): 乾淨機器第一次 True/True,原封不動再跑一次 False/False,svHubPath 兩次相同" $
      withEmptyHomeDir $ \_home -> do
        r1 <- workspaceSetup Nothing "/unused-cwd"
        case r1 of
          Right v1 -> do
            svHubCreated v1 `shouldBe` True
            svCacheCreated v1 `shouldBe` True
            r2 <- workspaceSetup Nothing "/unused-cwd"
            case r2 of
              Right v2 -> do
                svHubCreated v2 `shouldBe` False
                svCacheCreated v2 `shouldBe` False
                svHubPath v2 `shouldBe` svHubPath v1
              Left e -> expectationFailure (show e)
          Left e -> expectationFailure (show e)

    it "test_workspace_setup_params_do_not_matter_example (X11b): 中樞早就在時,不同的 sel/cwd 得到逐欄相同的結果" $
      withEmptyHomeDir $ \home -> do
        _ <- workspaceSetup Nothing "/warm-up"
        r1 <- workspaceSetup Nothing (home </> "va")
        r2 <- workspaceSetup (Just "story") (home </> "outside")
        r1 `shouldBe` r2
        case r1 of
          Right v -> do
            svHubCreated v `shouldBe` False
            svCacheCreated v `shouldBe` False
          Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L12,X12: workspacePurge 是逐欄投影" $ do
    it "prop_purge_matches_purge_report (L12): 對兩個結構相同的獨立佈局,workspacePurge 與直接呼叫 purge 的三欄一致;PurgeHubOnly 時 pvVaultIndexesRemoved == []" $
      hedgehog $ do
        useAllVaults <- forAll Gen.bool
        let scope = if useAllVaults then PurgeAllVaults else PurgeHubOnly
        outcome <- liftIO $ do
          viaMachine <- withFixedLayout $ \fl1 ->
            withOpenEnv Nothing (flOutsidePath fl1) $ \env1 -> runService env1 (workspacePurge scope)
          viaDirect <- withFixedLayout $ \fl2 ->
            withOpenEnv Nothing (flOutsidePath fl2) $ \env2 -> do
              hubR <- runService env2 askHub
              case hubR of
                Right hub -> do
                  loc <- hubLocation
                  Just <$> purge loc hub scope
                Left _ -> pure Nothing
          pure (viaMachine, viaDirect)
        case outcome of
          (Right v, Just (Right report)) -> do
            pvHubRemoved v === prHubRemoved report
            pvThumbsRemoved v === prThumbsRemoved report
            length (pvVaultIndexesRemoved v) === length (prVaultIndexesRemoved report)
            if scope == PurgeHubOnly
              then pvVaultIndexesRemoved v === []
              else pure ()
          (v, _) -> annotate (describeServiceResult v) >> failure

    it "test_purge_hub_only_example (X12): pvHubRemoved==True、pvVaultIndexesRemoved==[];askHub 的 hubVaults 仍是兩筆(快照未被重載)" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          beforeR <- runService env askHub
          purgeR <- runService env (workspacePurge PurgeHubOnly)
          afterR <- runService env askHub
          case (purgeR, beforeR, afterR) of
            (Right pv, Right hubBefore, Right hubAfter) -> do
              pvHubRemoved pv `shouldBe` True
              pvVaultIndexesRemoved pv `shouldBe` []
              hubAfter `shouldBe` hubBefore
            _ ->
              expectationFailure
                (describeServiceResult purgeR <> " / " <> describeServiceResult beforeR <> " / " <> describeServiceResult afterR)

  --------------------------------------------------------------------------
  describe "L13: purge 不重載中樞快照" $
    it "prop_purge_does_not_reload_snapshot (L13): 對任意 scope,workspacePurge 成功後同一個 Env 的 askHub 與呼叫前逐欄相同" $
      hedgehog $ do
        useAllVaults <- forAll Gen.bool
        let scope = if useAllVaults then PurgeAllVaults else PurgeHubOnly
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            beforeR <- runService env askHub
            purgeR <- runService env (workspacePurge scope)
            afterR <- runService env askHub
            pure (beforeR, purgeR, afterR)
        case outcome of
          (Right hubBefore, Right _, Right hubAfter) -> hubAfter === hubBefore
          (beforeR, purgeR, afterR) ->
            annotate
              (describeServiceResult beforeR <> " / " <> describeServiceResult purgeR <> " / " <> describeServiceResult afterR)
              >> failure
