-- | F002:五個寫中樞操作('Aapms.Service.Machine.vaultInit' \/ 'vaultAdd' \/
-- 'vaultForget' \/ 'projectRegister' \/ 'projectForget')與
-- 'Aapms.Service.Machine.projectList'。
--
-- __spec 對照__(「1-to-1 測試對照表」——全部紅:本體皆 @undefined@):
--
-- @
-- L14,L15,X13,X13b  vaultInit 寫後可見 + 回傳的那一筆 + AdoptNotice 原樣  -> prop_vault_init_visible_after, prop_vault_init_adopt_notice, test_vault_init_fresh_example, test_vault_init_adopt_with_legacy_example
-- L14,L15           vaultAdd 寫後可見 + 回傳的那一筆                      -> test_vault_add_example
-- L14,L16,X14       vaultForget 寫後可見 + 回傳被移除的那一筆              -> prop_vault_forget_removed_row, test_vault_forget_example
-- L17,X15           失敗即原樣包、什麼都不動                              -> prop_write_ops_failure_passthrough, test_vault_forget_unknown_selector_example
-- L18,L19,X16,X17   projectList 逐列對應 + register/forget 回的那一筆     -> prop_project_list_matches_hub, test_project_round_trip_example, test_project_path_missing_example
-- @
module Aapms.Service.MachineWriteOpsSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesDirectoryExist
  , removeDirectoryRecursive
  )
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Types
  ( ProjectEntry (..)
  , WorkspaceError (VaultSelectorNotFound)
  , hubProjects
  )

import Aapms.Service.Fixtures
import Aapms.Service.Machine
  ( AdoptNotice (..)
  , DeleteIndex (..)
  , InitMode (..)
  , ProjectView (..)
  , VaultView (..)
  , projectForget
  , projectList
  , projectRegister
  , vaultAdd
  , vaultForget
  , vaultInit
  , vaultList
  )
import Aapms.Service.Monad (askHub, runService)
import Aapms.Service.Types (ServiceError (WorkspaceFailed))

--------------------------------------------------------------------------------
-- 佈局

-- | @<tmp>\/vc@ 一個空目錄,可選再放幾個 legacy marker 子目錄。
withFreshVaultDirLayout :: [String] -> (FixedLayout -> FilePath -> IO a) -> IO a
withFreshVaultDirLayout legacyDirs act = withFixedLayout $ \fl -> do
  let dir = flRoot fl </> "vc"
  createDirectoryIfMissing True dir
  mapM_ (\d -> createDirectoryIfMissing True (dir </> d)) legacyDirs
  act fl dir

-- | @<tmp>\/ve@ 已經是一個 vault(有合法 marker),但__不在__中樞裡。
withUnaddedVaultDirLayout :: (FixedLayout -> VaultId -> FilePath -> IO a) -> IO a
withUnaddedVaultDirLayout act = withFixedLayout $ \fl -> do
  let vid = VaultId "vlt-add00001"
      path = flRoot fl </> "ve"
  writeVaultMarkerAt path (markerTomlText vid vbKindText "fifth" [])
  act fl vid path

isRightU :: Either e a -> Bool
isRightU (Right _) = True
isRightU (Left _) = False

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: 五個寫中樞操作 / projectList" $ do
  --------------------------------------------------------------------------
  describe "L14,L15,X13,X13b: vaultInit" $ do
    it "prop_vault_init_visible_after (L14): 對任意 kind,成功後同一個 Env 的 vaultList 看得到,且與重新 openEnv 的結果逐項相同" $
      hedgehog $ do
        kind <- forAll (Gen.element [AssetVault, StoryVault])
        outcome <- liftIO $ withFreshVaultDirLayout [] $ \fl dir ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            initR <- runService env (vaultInit dir kind "third" FreshVault)
            listR <- runService env vaultList
            reopened <- withOpenEnv Nothing (flOutsidePath fl) $ \env2 -> runService env2 vaultList
            pure (initR, listR, reopened)
        case outcome of
          (Right (v, _), Right vs, Right vsReopened) -> do
            (vvId v `elem` map vvId vs) === True
            vs === vsReopened
          _ -> do
            let (initR, listR, reopened) = outcome
            annotate
              ( describeServiceResult (fmap (const ()) initR)
                  <> " / "
                  <> describeServiceResult listR
                  <> " / "
                  <> describeServiceResult reopened
              )
            failure

    it "prop_vault_init_adopt_notice (L15 第二個分量): AdoptExisting 之下,有 legacy 目錄時 AdoptNotice 非空,沒有時為空;第一個分量的欄位與參數一致" $
      hedgehog $ do
        hasLegacy <- forAll Gen.bool
        let legacyDirs = if hasLegacy then [".assetdb"] else []
        outcome <- liftIO $ withFreshVaultDirLayout legacyDirs $ \fl dir -> do
          canon <- canonicalizePath dir
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            r <- runService env (vaultInit dir AssetVault "vc" AdoptExisting)
            pure (r, canon)
        let (result, canon) = outcome
        case result of
          Right (v, notice) -> do
            vvKind v === AssetVault
            vvName v === "vc"
            vvPath v === canon
            vvRegistered v === True
            vvReachable v === True
            if hasLegacy
              then not (null (anLegacyMarkers notice)) === True
              else anLegacyMarkers notice === []
          Left e -> annotate (show e) >> failure

    it "test_vault_init_fresh_example (X13): 乾淨目錄,vvKind/vvName/vvPath 相符,vvRegistered/vvReachable 皆 True,notice 為空,vaultList 三筆含它" $
      withFreshVaultDirLayout [] $ \fl dir -> do
        canon <- canonicalizePath dir
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultInit dir AssetVault "third" FreshVault)
          case result of
            Right (v, notice) -> do
              vvKind v `shouldBe` AssetVault
              vvName v `shouldBe` "third"
              vvPath v `shouldBe` canon
              vvRegistered v `shouldBe` True
              vvReachable v `shouldBe` True
              anLegacyMarkers notice `shouldBe` []
              listR <- runService env vaultList
              case listR of
                Right vs -> do
                  length vs `shouldBe` 3
                  (vvId v `elem` map vvId vs) `shouldBe` True
                Left e -> expectationFailure (show e)
            Left e -> expectationFailure (show e)

    it "test_vault_init_adopt_with_legacy_example (X13b): .assetdb/ legacy marker 存在,notice 含它;legacy 目錄仍在" $
      withFreshVaultDirLayout [".assetdb"] $ \fl dir ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultInit dir AssetVault "fourth" AdoptExisting)
          case result of
            Right (v, notice) -> do
              vvKind v `shouldBe` AssetVault
              vvName v `shouldBe` "fourth"
              vvRegistered v `shouldBe` True
              vvReachable v `shouldBe` True
              anLegacyMarkers notice `shouldNotBe` []
              -- 只報告不刪除:legacy 目錄仍在
              stillThere <- doesDirectoryExist (dir </> ".assetdb")
              stillThere `shouldBe` True
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L14,L15: vaultAdd" $
    it "test_vault_add_example: 已是 vault 但未註冊的目錄,vaultAdd 之後 vaultList 看得到,欄位相符" $
      withUnaddedVaultDirLayout $ \fl vid path ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultAdd path)
          case result of
            Right v -> do
              vvId v `shouldBe` vid
              vvRegistered v `shouldBe` True
              vvReachable v `shouldBe` True
              listR <- runService env vaultList
              case listR of
                Right vs -> (vid `elem` map vvId vs) `shouldBe` True
                Left e -> expectationFailure (show e)
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L14,L16,X14: vaultForget" $ do
    it "prop_vault_forget_removed_row (L14+L16): 對任意一個 vault 與 DeleteIndex,forget 回被移除的那一筆,vaultList 只剩另一個" $
      hedgehog $ do
        useVa <- forAll Gen.bool
        delIdx <- forAll (Gen.element [KeepIndex, DeleteIndex])
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let (sel, expectedId, otherId) =
                if useVa then ("story", flVaId fl, flVbId fl) else ("assets", flVbId fl, flVaId fl)
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            result <- runService env (vaultForget sel delIdx)
            listR <- runService env vaultList
            pure (result, listR, expectedId, otherId)
        let (result, listR, expectedId, otherId) = outcome
        case (result, listR) of
          (Right v, Right vs) -> do
            vvId v === expectedId
            vvRegistered v === False
            map vvId vs === [otherId]
          _ -> annotate (describeServiceResult result <> " / " <> describeServiceResult listR) >> failure

    it "test_vault_forget_example (X14): forget \"story\" KeepIndex,vvId==VA、vvRegistered==False、vvReachable==True;vaultList 只剩 VB;marker 位元組不變" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          beforeBytes <- readUtf8NoTranslate (flVaPath fl </> ".aapms" </> "config.toml")
          result <- runService env (vaultForget "story" KeepIndex)
          case result of
            Right v -> do
              vvId v `shouldBe` flVaId fl
              vvRegistered v `shouldBe` False
              vvReachable v `shouldBe` True
              listR <- runService env vaultList
              case listR of
                Right vs -> map vvId vs `shouldBe` [flVbId fl]
                Left e -> expectationFailure (show e)
              afterBytes <- readUtf8NoTranslate (flVaPath fl </> ".aapms" </> "config.toml")
              afterBytes `shouldBe` beforeBytes
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L17,X15: 失敗即原樣包、什麼都不動" $ do
    it "prop_write_ops_failure_passthrough (L17): vaultForget/projectForget 對不存在的 selector,回 Left,askHub 與中樞檔位元組不變" $
      hedgehog $ do
        useProject <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            beforeHub <- runService env askHub
            beforeBytes <- readUtf8NoTranslate (flHubDir fl </> "config.toml")
            result <-
              if useProject
                then fmap (const ()) <$> runService env (projectForget "no-such-project")
                else fmap (const ()) <$> runService env (vaultForget "no-such-vault" KeepIndex)
            afterHub <- runService env askHub
            afterBytes <- readUtf8NoTranslate (flHubDir fl </> "config.toml")
            pure (result, beforeHub, afterHub, beforeBytes, afterBytes)
        let (result, beforeHub, afterHub, beforeBytes, afterBytes) = outcome
        case (result, beforeHub, afterHub) of
          (Left (WorkspaceFailed _), Right hb, Right ha) -> do
            hb === ha
            beforeBytes === afterBytes
          _ -> annotate (show result) >> failure

    it "test_vault_forget_unknown_selector_example (X15): Left (WorkspaceFailed (VaultSelectorNotFound _)),中樞檔位元組不變" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          beforeBytes <- readUtf8NoTranslate (flHubDir fl </> "config.toml")
          result <- runService env (vaultForget "沒有這個" KeepIndex)
          result `shouldBe` Left (WorkspaceFailed (VaultSelectorNotFound "沒有這個"))
          afterBytes <- readUtf8NoTranslate (flHubDir fl </> "config.toml")
          afterBytes `shouldBe` beforeBytes

  --------------------------------------------------------------------------
  describe "L18,L19,X16,X17: projectList / projectRegister / projectForget" $ do
    it "prop_project_list_matches_hub (L18): 對 0..2 個已登錄的專案(目錄皆存在),projectList 逐項等於 hubProjects,pvReachable 皆 True" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 2))
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          dirs <-
            mapM
              ( \i -> do
                  let p = flRoot fl </> ("proj" <> show (i :: Int))
                  createDirectoryIfMissing True p
                  pure p
              )
              [0 .. n - 1]
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            regs <-
              mapM
                (\(i, p) -> runService env (projectRegister p (T.pack ("p" <> show i))))
                (zip [0 :: Int ..] dirs)
            listR <- runService env projectList
            hubR <- runService env askHub
            pure (regs, listR, hubR)
        let (regs, listR, hubR) = outcome
        case (listR, hubR) of
          (Right vs, Right hub) | all isRightU regs -> do
            length vs === length (hubProjects hub)
            [(pvId v, pvName v, pvPath v) | v <- vs]
              === [(peId e, peName e, pePath e) | e <- hubProjects hub]
            all pvReachable vs === True
          _ -> failure

    it "test_project_round_trip_example (X16): register -> list -> forget -> list" $
      withFixedLayout $ \fl -> do
        let projPath = flRoot fl </> "proj"
        createDirectoryIfMissing True projPath
        canon <- canonicalizePath projPath
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          r1 <- runService env (projectRegister projPath "demo")
          case r1 of
            Right pv1 -> do
              pvName pv1 `shouldBe` "demo"
              pvPath pv1 `shouldBe` canon
              pvReachable pv1 `shouldBe` True
              r2 <- runService env projectList
              case r2 of
                Right [row] -> row `shouldBe` pv1
                other -> expectationFailure ("預期恰一筆," <> show other)
              r3 <- runService env (projectForget "demo")
              r3 `shouldBe` Right pv1
              r4 <- runService env projectList
              r4 `shouldBe` Right []
            Left e -> expectationFailure (show e)

    it "test_project_path_missing_example (X17): 專案路徑消失後 pvReachable == False,其餘三欄不變" $
      withFixedLayout $ \fl -> do
        let projPath = flRoot fl </> "proj2"
        createDirectoryIfMissing True projPath
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          r1 <- runService env (projectRegister projPath "demo2")
          case r1 of
            Right pv1 -> do
              removeDirectoryRecursive projPath
              r2 <- runService env projectList
              case r2 of
                Right [row] -> do
                  pvReachable row `shouldBe` False
                  pvId row `shouldBe` pvId pv1
                  pvName row `shouldBe` pvName pv1
                  pvPath row `shouldBe` pvPath pv1
                other -> expectationFailure ("預期恰一筆," <> show other)
            Left e -> expectationFailure (show e)
