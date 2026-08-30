-- | F001:'Aapms.Service.Scope'——'withRead' \/ 'withWrite' \/ 'withPipeline'。
--
-- __spec 對照__(@.design\/subsystems\/service\/features\/F001-service-env-and-scope.md@,
-- 「1-to-1 測試對照表」——全部紅:三個函式的本體全是 @undefined@):
--
-- @
-- L13,X14     讀取範圍與裁決一致             -> prop_with_read_matches_scope_resolution, test_with_read_all_registered_example
-- L14,X15,X16 ScopeIssue 不中止 / 空範圍      -> prop_with_read_scope_issue_does_not_abort, test_with_read_broken_vault_excluded_example, test_with_read_empty_hub_example
-- L15         VaultSet 關掉、handle 不關       -> prop_with_read_closes_vault_set_not_handles
-- L16,X17     沒有寫入目標即失敗              -> prop_with_write_no_target_fails, test_with_write_outside_no_selector_example
-- L17,X18     寫入目標唯一                   -> prop_with_write_target_matches_resolve, test_with_write_selector_story_example
-- L18,X19,X20 管線只給符合 kind 的            -> prop_with_pipeline_filters_by_kind, test_with_pipeline_asset_example, test_with_pipeline_story_empty_example
-- @
module Aapms.Service.ScopeSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort)
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import System.Directory (canonicalizePath)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (vmId, vmKind))
import Aapms.Store.MultiVault (vaultSetIds)
import Aapms.Store.Schema (VaultKind (..))
import Aapms.Workspace.Scope (resolveRead, resolveWrite)
import Aapms.Workspace.Types
  ( ReadScope (..)
  , VaultRef (..)
  , WorkspaceError (..)
  , WriteScope (..)
  )

import Aapms.Service.Fixtures
import Aapms.Service.Monad (askHub, runService)
import Aapms.Service.Scope (withPipeline, withRead, withWrite)
import Aapms.Service.Types (ServiceError (..))

--------------------------------------------------------------------------------
-- 本檔專用 layout(擴充固定佈局:多一個路徑不存在的第三個 vault,或清空 vaults)

-- | 中樞多一列指向不存在路徑的 vault(產生 'Aapms.Workspace.Types.VaultPathMissing')。
withBrokenVaultLayout :: (FixedLayout -> IO a) -> IO a
withBrokenVaultLayout act = withFixedLayout $ \fl -> do
  let brokenId = VaultId "vlt-99990000"
      brokenPath = flRoot fl ++ "/broken"
  writeHubConfigAt
    (flHubDir fl)
    ( hubConfigText
        [ (flVaId fl, "story", "story", flVaPath fl)
        , (flVbId fl, "assets", "asset", flVbPath fl)
        , (brokenId, "broken", "asset", brokenPath)
        ]
    )
  act fl

-- | 中樞的 @[[vaults]]@ 清空。
withEmptyHubLayout :: (FixedLayout -> IO a) -> IO a
withEmptyHubLayout act = withFixedLayout $ \fl -> do
  writeHubConfigAt (flHubDir fl) (hubConfigText [])
  act fl

-- | 中樞只剩 VB(asset)一列(給 X20 用)。
withOnlyVbLayout :: (FixedLayout -> IO a) -> IO a
withOnlyVbLayout act = withFixedLayout $ \fl -> do
  writeHubConfigAt (flHubDir fl) (hubConfigText [(flVbId fl, "assets", "asset", flVbPath fl)])
  act fl

vmidsOfRefs :: [VaultRef] -> [VaultId]
vmidsOfRefs = map (vmId . vrMarker)

vmidOfHandle :: VaultHandle -> VaultId
vmidOfHandle = vmId . vhMarker

kindOfHandle :: VaultHandle -> VaultKind
kindOfHandle = vmKind . vhMarker

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F001 Aapms.Service.Scope" $ do
  --------------------------------------------------------------------------
  describe "L13/X14: withRead 的讀取範圍與 resolveRead 的裁決一致" $ do
    it "prop_with_read_matches_scope_resolution (L13): 對成功解析的 sel,withRead 兩個回傳與 resolveRead 的 rsVaults 三者的 vmId 清單相同" $
      hedgehog $ do
        sel <- forAll (Gen.element [Nothing, Just "story", Just "assets"])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv sel (flOutsidePath fl) $ \env -> do
            hubR <- runService env askHub
            r <- runService env (withRead (\vs refs -> pure (vaultSetIds vs, vmidsOfRefs refs)))
            directR <- case hubR of
              Right hub -> Just <$> resolveRead hub sel
              Left _ -> pure Nothing
            pure (r, directR)
        case outcome of
          (Right (idsA, idsB), Just (Right rs)) -> do
            idsA === idsB
            idsA === vmidsOfRefs (rsVaults rs)
          other -> annotate (show other) >> failure

    it "test_with_read_all_registered_example (X14): sel == Nothing 時兩個清單都等於中樞順序 [VA, VB]" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (withRead (\vs refs -> pure (vaultSetIds vs, vmidsOfRefs refs)))
          case result of
            Right (idsFromSet, idsFromRefs) -> do
              idsFromSet `shouldBe` [flVaId fl, flVbId fl]
              idsFromRefs `shouldBe` [flVaId fl, flVbId fl]
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L14/X15/X16: ScopeIssue 不中止 withRead" $ do
    it "prop_with_read_scope_issue_does_not_abort (L14): 中樞多一個路徑不存在的 vault 時,withRead 仍回 Right,壞的那個被排除" $
      hedgehog $ do
        outcome <- liftIO $ withBrokenVaultLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            r <- runService env (withRead (\vs _ -> pure (vaultSetIds vs)))
            pure (r, [flVaId fl, flVbId fl])
        case outcome of
          (Right ids, expected) -> sort ids === sort expected
          (Left e, _) -> annotate (show e) >> failure

    it "test_with_read_broken_vault_excluded_example (X15): 壞的 vault 被排除,vaultSetIds 只剩 [VA, VB]" $
      withBrokenVaultLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (withRead (\vs _ -> pure (vaultSetIds vs)))
          case result of
            Right ids -> sort ids `shouldBe` sort [flVaId fl, flVbId fl]
            Left e -> expectationFailure (show e)

    it "test_with_read_empty_hub_example (X16): 中樞沒有任何 vault 時仍回 Right [],k 有被呼叫" $
      withEmptyHubLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          called <- newIORef False
          result <-
            runService
              env
              (withRead (\vs _ -> liftIO (writeIORef called True) >> pure (vaultSetIds vs)))
          result `shouldBe` Right []
          readIORef called `shouldReturn` True

  --------------------------------------------------------------------------
  describe "L15: withRead 結束後 VaultSet 被關、handle 仍在快取" $
    it "prop_with_read_closes_vault_set_not_handles (L15): withRead 結束後同一個 env 再跑一次 withRead 仍成功" $
      hedgehog $ do
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            r1 <- runService env (withRead (\_ _ -> pure ()))
            r2 <- runService env (withRead (\_ _ -> pure ()))
            pure (r1, r2)
        let (r1, r2) = outcome
        annotate (show (r1, r2))
        r1 === Right ()
        r2 === Right ()

  --------------------------------------------------------------------------
  describe "L16/X17: 沒有寫入目標即失敗" $ do
    it "prop_with_write_no_target_fails (L16): 起點在 outside/ 之下、sel == Nothing 時,withWrite 回 Left (WorkspaceFailed (NoWriteTarget _)),k 不被呼叫" $
      hedgehog $ do
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            calledRef <- newIORef False
            r <- runService env (withWrite (\_ _ -> liftIO (writeIORef calledRef True)))
            called <- readIORef calledRef
            pure (r, called)
        case outcome of
          (Left (WorkspaceFailed (NoWriteTarget _)), False) -> pure ()
          other -> annotate (show other) >> failure

    it "test_with_write_outside_no_selector_example (X17): NoWriteTarget 帶正規化後的起點,k 一次都沒被呼叫" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          canon <- canonicalizePath (flOutsidePath fl)
          flag <- newIORef False
          result <- runService env (withWrite (\_ _ -> liftIO (writeIORef flag True)))
          result `shouldBe` Left (WorkspaceFailed (NoWriteTarget canon))
          readIORef flag `shouldReturn` False

  --------------------------------------------------------------------------
  describe "L17/X18: 寫入目標唯一" $ do
    it "prop_with_write_target_matches_resolve (L17): sel 解得到時,withWrite 交出去的目標 vmId 恆等於 resolveWrite 的 wsTarget,讀取範圍等於 wsRead" $
      hedgehog $ do
        sel <- forAll (Gen.element ["story", "assets"])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv (Just sel) (flOutsidePath fl) $ \env -> do
            hubR <- runService env askHub
            r <- runService env (withWrite (\h vs -> pure (vmidOfHandle h, vaultSetIds vs)))
            directR <- case hubR of
              Right hub -> Just <$> resolveWrite hub (Just sel) (flOutsidePath fl)
              Left _ -> pure Nothing
            pure (r, directR)
        case outcome of
          (Right (targetId, readIds), Just (Right ws)) -> do
            targetId === vmId (vrMarker (wsTarget ws))
            readIds === vmidsOfRefs (wsRead ws)
          other -> annotate (show other) >> failure

    it "test_with_write_selector_story_example (X18): withWrite 交出 (VA, [VA])" $
      withFixedLayout $ \fl ->
        withOpenEnv (Just "story") (flVaPath fl) $ \env -> do
          result <- runService env (withWrite (\h vs -> pure (vmidOfHandle h, vaultSetIds vs)))
          result `shouldBe` Right (flVaId fl, [flVaId fl])

  --------------------------------------------------------------------------
  describe "L18/X19/X20: withPipeline 只給符合 kind 的" $ do
    it "prop_with_pipeline_filters_by_kind (L18): 每個交給 k 的 handle 都符合要求的 kind" $
      hedgehog $ do
        kind <- forAll (Gen.element [AssetVault, StoryVault])
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env ->
            runService env (withPipeline kind (\hs -> pure (map kindOfHandle hs)))
        case outcome of
          Right kinds -> all (== kind) kinds === True
          Left e -> annotate (show e) >> failure

    it "test_with_pipeline_asset_example (X19): AssetVault + sel Nothing 只剩 VB" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (withPipeline AssetVault (\hs -> pure (map vmidOfHandle hs)))
          result `shouldBe` Right [flVbId fl]

    it "test_with_pipeline_story_empty_example (X20): 中樞只剩 VB 時 StoryVault 回空清單,k 仍被呼叫" $
      withOnlyVbLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          called <- newIORef False
          result <-
            runService
              env
              (withPipeline StoryVault (\hs -> liftIO (writeIORef called True) >> pure (length hs)))
          result `shouldBe` Right 0
          readIORef called `shouldReturn` True
