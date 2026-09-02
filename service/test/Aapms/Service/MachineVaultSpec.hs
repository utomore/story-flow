-- | F002:'Aapms.Service.Machine.vaultList' \/ 'Aapms.Service.Types.VaultView' 與
-- 'Aapms.Service.Machine.vaultCheck'。
--
-- __spec 對照__(@.design\/subsystems\/service\/features\/F002-workspace-facade.md@,
-- 「1-to-1 測試對照表」——全部紅:'vaultList' \/ 'vaultCheck' 本體皆 @undefined@):
--
-- @
-- LAW-1,EX-1      vaultList 逐列對應 hubVaults;空中樞回 Right []        -> prop_vault_list_matches_hub, test_vault_list_full_layout_example, test_vault_list_empty_hub_example
-- LAW-2         vvRegistered 恒真                                      -> prop_vault_list_registered_always_true
-- LAW-3,EX-2      vvReachable 恰等於 PathMissing\/MarkerBroken 的集合     -> prop_vault_reachable_matches_scope_issues, test_vault_list_unreachable_example
-- LAW-3,EX-3      VaultIdDrift 不影響 vvReachable                         -> test_vault_id_drift_still_reachable_example
-- LAW-4,EX-2,EX-3   vaultCheck 原樣轉出 checkVaults(逐項、順序相同)         -> prop_vault_check_matches_checkVaults, test_vault_check_path_missing_example, test_vault_check_id_drift_example
-- @
module Aapms.Service.MachineVaultSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Lifecycle (checkVaults)
import Aapms.Workspace.Types
  ( ScopeIssue (..)
  , VaultEntry (..)
  , hubVaults
  )

import Aapms.Service.Fixtures
import Aapms.Service.Machine (VaultView (..), vaultCheck, vaultList)
import Aapms.Service.Monad (askHub, runService)

--------------------------------------------------------------------------------
-- 佈局:base VA\/VB 之外再加 n 個額外 vault(0..3),各自 marker 合法、可達

extraVaultId :: Int -> VaultId
extraVaultId i = VaultId (T.pack ("vlt-e000000" <> show i))

extraVaultKindText :: Int -> Text
extraVaultKindText i = if even i then vaKindText else vbKindText

mkExtraVaultAt :: FixedLayout -> Int -> IO (VaultId, Text, Text, FilePath)
mkExtraVaultAt fl i = do
  let vid = extraVaultId i
      path = flRoot fl </> ("extra" <> show i)
      kind = extraVaultKindText i
      name = T.pack ("extra" <> show i)
  writeVaultMarkerAt path (markerTomlText vid kind name [])
  pure (vid, name, kind, path)

withExtraVaultsLayout :: Int -> (FixedLayout -> IO a) -> IO a
withExtraVaultsLayout n act = withFixedLayout $ \fl -> do
  extras <- mapM (mkExtraVaultAt fl) [0 .. n - 1]
  writeHubConfigAt
    (flHubDir fl)
    ( hubConfigText
        ( [ (flVaId fl, "story", vaKindText, flVaPath fl)
          , (flVbId fl, "assets", vbKindText, flVbPath fl)
          ]
            <> extras
        )
    )
  act fl

-- | 中樞多一列指向不存在路徑的 vault(產生 'VaultPathMissing',EX-2)。
withPathMissingLayout :: (FixedLayout -> VaultId -> IO a) -> IO a
withPathMissingLayout act = withFixedLayout $ \fl -> do
  let brokenId = VaultId "vlt-99990000"
      brokenPath = flRoot fl </> "broken"
  writeHubConfigAt
    (flHubDir fl)
    ( hubConfigText
        [ (flVaId fl, "story", vaKindText, flVaPath fl)
        , (flVbId fl, "assets", vbKindText, flVbPath fl)
        , (brokenId, "broken", vbKindText, brokenPath)
        ]
    )
  act fl brokenId

withChosenLayout :: Bool -> (FixedLayout -> IO a) -> IO a
withChosenLayout useBroken act
  | useBroken = withPathMissingLayout (\fl _ -> act fl)
  | otherwise = withFixedLayout act

-- | VA 的 marker id 被改成別的值(產生 'VaultIdDrift',EX-3)。
withIdDriftLayout :: (FixedLayout -> IO a) -> IO a
withIdDriftLayout act = withFixedLayout $ \fl -> do
  writeVaultMarkerAt (flVaPath fl) (markerTomlText (VaultId "vlt-d0000000") vaKindText "story" [])
  act fl

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: vaultList / vaultCheck" $ do
  --------------------------------------------------------------------------
  describe "LAW-1/EX-1/EX-4: vaultList 逐列對應 hubVaults" $ do
    it "prop_vault_list_matches_hub (LAW-1): 對 0..3 個額外 vault,vaultList 的長度、順序、四欄逐項等於 askHub 的 hubVaults" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 3))
        outcome <- liftIO $ withExtraVaultsLayout n $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            hubR <- runService env askHub
            listR <- runService env vaultList
            pure (hubR, listR)
        case outcome of
          (Right hub, Right vs) -> do
            let entries = hubVaults hub
            length vs === length entries
            [(vvId v, vvName v, vvKind v, vvPath v) | v <- vs]
              === [(veId e, veName e, veKind e, vePath e) | e <- entries]
          (hubR, listR) ->
            annotate (describeServiceResult hubR <> " / " <> describeServiceResult listR) >> failure

    it "test_vault_list_full_layout_example (EX-1): 兩筆,vvId 依序 [VA,VB],name/kind 相符,兩筆皆 registered/reachable" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env vaultList
          case result of
            Right vs -> do
              map vvId vs `shouldBe` [flVaId fl, flVbId fl]
              map vvName vs `shouldBe` ["story", "assets"]
              map vvKind vs `shouldBe` [StoryVault, AssetVault]
              map vvRegistered vs `shouldBe` [True, True]
              map vvReachable vs `shouldBe` [True, True]
            Left e -> expectationFailure (show e)

    it "test_vault_list_empty_hub_example (EX-4): 中樞沒有 vault 時回 Right []" $
      withFixedLayout $ \fl -> do
        writeHubConfigAt (flHubDir fl) (hubConfigText [])
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env vaultList
          result `shouldBe` Right []

  --------------------------------------------------------------------------
  describe "LAW-2: vvRegistered 恒真" $
    it "prop_vault_list_registered_always_true (LAW-2): 對 0..3 個額外 vault,vaultList 每一筆 vvRegistered == True" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 0 3))
        outcome <- liftIO $ withExtraVaultsLayout n $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> runService env vaultList
        case outcome of
          Right vs -> all vvRegistered vs === True
          Left e -> annotate (show e) >> failure

  --------------------------------------------------------------------------
  describe "LAW-3/EX-2/EX-3: vvReachable 的判準(恰等於 VaultPathMissing/VaultMarkerBroken 的集合)" $ do
    it "prop_vault_reachable_matches_scope_issues (LAW-3): 不可達的 vvId 集合恰等於 PathMissing/MarkerBroken 那些 veId 的集合" $
      hedgehog $ do
        useBroken <- forAll Gen.bool
        outcome <- liftIO $ withChosenLayout useBroken $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            listR <- runService env vaultList
            checkR <- runService env vaultCheck
            pure (listR, checkR)
        case outcome of
          (Right vs, Right issues) -> do
            let unreachable = [vvId v | v <- vs, not (vvReachable v)]
                expected =
                  [veId e | VaultPathMissing e _ <- issues]
                    <> [veId e | VaultMarkerBroken e _ <- issues]
            sort unreachable === sort expected
          (listR, checkR) ->
            annotate (describeServiceResult listR <> " / " <> describeServiceResult checkR) >> failure

    it "test_vault_list_unreachable_example (EX-2): VC 那筆 vvReachable == False,其餘 True;vaultCheck 恰含一則 VaultPathMissing 且 veId 是 VC" $
      withPathMissingLayout $ \fl brokenId ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          listResult <- runService env vaultList
          checkResult <- runService env vaultCheck
          case (listResult, checkResult) of
            (Right vs, Right issues) -> do
              length vs `shouldBe` 3
              [vvReachable v | v <- vs, vvId v == brokenId] `shouldBe` [False]
              [vvReachable v | v <- vs, vvId v /= brokenId] `shouldBe` [True, True]
              length issues `shouldBe` 1
              [() | VaultPathMissing e _ <- issues, veId e == brokenId] `shouldBe` [()]
            other -> expectationFailure (show other)

    it "test_vault_id_drift_still_reachable_example (EX-3): VaultIdDrift 出現在 vaultCheck,而 vvReachable 仍為 True" $
      withIdDriftLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          listResult <- runService env vaultList
          checkResult <- runService env vaultCheck
          case (listResult, checkResult) of
            (Right vs, Right issues) -> do
              all vvReachable vs `shouldBe` True
              [() | VaultIdDrift {} <- issues] `shouldNotBe` []
            other -> expectationFailure (show other)

  --------------------------------------------------------------------------
  describe "LAW-4: vaultCheck 原樣轉出 checkVaults" $ do
    it "prop_vault_check_matches_checkVaults (LAW-4): vaultCheck 與同一份中樞快照上直接呼叫 checkVaults 逐項相同" $
      hedgehog $ do
        useBroken <- forAll Gen.bool
        outcome <- liftIO $ withChosenLayout useBroken $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            hubR <- runService env askHub
            checkR <- runService env vaultCheck
            direct <- either (const (pure Nothing)) (fmap Just . checkVaults) hubR
            pure (checkR, direct)
        case outcome of
          (Right issues, Just direct) -> issues === direct
          (checkR, _) -> annotate (describeServiceResult checkR) >> failure

    it "test_vault_check_path_missing_example (EX-2): vaultCheck 恰含一則 VaultPathMissing" $
      withPathMissingLayout $ \fl _ ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          checkResult <- runService env vaultCheck
          case checkResult of
            Right [VaultPathMissing _ _] -> pure ()
            other -> expectationFailure ("預期恰一則 VaultPathMissing,得到 " <> show other)

    it "test_vault_check_id_drift_example (EX-3): vaultCheck 恰含一則 VaultIdDrift" $
      withIdDriftLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          checkResult <- runService env vaultCheck
          case checkResult of
            Right [VaultIdDrift _ _] -> pure ()
            other -> expectationFailure ("預期恰一則 VaultIdDrift,得到 " <> show other)
