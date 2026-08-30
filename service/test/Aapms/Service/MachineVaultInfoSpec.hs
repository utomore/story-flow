-- | F002:'Aapms.Service.Machine.vaultInfo' \/ 'Aapms.Service.Types.VaultInfoView'。
--
-- __spec 對照__(「1-to-1 測試對照表」——全部紅:'vaultInfo' 本體是 @undefined@):
--
-- @
-- L20,X20      viVault 與 selector;selector 解不開時原樣包            -> prop_vault_info_vault_matches_selector, test_vault_info_unknown_selector_example
-- L21,X18,X19  viCounts:鍵\/排序\/零值不出現;不受 --vault 範圍影響    -> prop_vault_info_counts_independent_of_scope, test_vault_info_empty_example, test_vault_info_indexed_example
-- L22,X18,X19b viIssues 等於該 vault 第一次開啟時的 indexIssuesFor    -> prop_vault_info_issues_matches_index_issues_for, test_vault_info_ignores_vault_scope_example
-- @
module Aapms.Service.MachineVaultInfoSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Store.Index (indexFile)
import Aapms.Store.Marker (closeVault, openVault)
import Aapms.Types.Loader (loadRegistry)
import Aapms.Workspace.Types (WorkspaceError (VaultSelectorNotFound))

import Aapms.Service.Fixtures
import Aapms.Service.Machine (VaultInfoView (..), VaultView (..), vaultInfo, vaultList)
import Aapms.Service.Monad (indexIssuesFor, runService)
import Aapms.Service.Types (ServiceError (WorkspaceFailed))

--------------------------------------------------------------------------------
-- 佈局:在 vb(assets)裡放一份合法的 pack.md,含一個 pck 節點與一個 ast 節點

packRelPath :: FilePath
packRelPath = "library" </> "packs" </> "test-vendor" </> "test-pack" </> "pack.md"

packMdWithOneAsset :: T.Text
packMdWithOneAsset =
  T.unlines
    [ "---"
    , "id: pck-00000001"
    , "vault: assets"
    , "type: asset-pack"
    , "title: 測試 Pack"
    , "vendor: test-vendor"
    , "license: lic-0000000a"
    , "status: canon"
    , "source: scan"
    , "revision: 1"
    , "created: 2026-08-30"
    , "updated: 2026-08-30"
    , "---"
    , ""
    , "Pack 說明。"
    , ""
    , "## panel.png {#ast-00000001}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "name: ui_gui_panel_001"
    , "entry: PNG/panel.png"
    , "sha256: \"1111111111111111111111111111111111111111111111111111111111111111\""
    , "tags: [gui]"
    , "```"
    ]

-- | 在 vb 寫入 'packMdWithOneAsset' 並用 graph-core 的 @indexFile@ 建索引。
-- 在 __開任何 'Aapms.Service.Monad.Env' 之前__呼叫——用的是 @aapms-store@
-- 自己的 'openVault'\/'closeVault',與 'Aapms.Service.Monad.handleFor' 的 handle
-- 快取無關;索引寫進磁碟上的 @index.db@,之後任何一次開啟都看得到。
indexOneAssetPack :: FixedLayout -> IO ()
indexOneAssetPack fl = do
  reg <- registryDir
  loaded <- loadRegistry reg
  case loaded of
    Left e -> fail ("測試前置:loadRegistry 失敗:" <> show e)
    Right (typeRegistry, _naming) -> do
      let fullPath = flVbPath fl </> packRelPath
      createDirectoryIfMissing True (takeDirectory fullPath)
      writeUtf8NoTranslate fullPath packMdWithOneAsset
      openR <- openVault typeRegistry (flVbPath fl)
      case openR of
        Left e -> fail ("測試前置:openVault 失敗:" <> show e)
        Right (vh, _issues) -> do
          idxR <- indexFile vh packRelPath
          closeVault vh
          case idxR of
            Left e -> fail ("測試前置:indexFile 失敗:" <> show e)
            Right _ -> pure ()

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: vaultInfo" $ do
  --------------------------------------------------------------------------
  describe "L20,X20: viVault 與 selector" $ do
    it "prop_vault_info_vault_matches_selector (L20): 對 VA/VB 任一,viVault 逐欄等於 vaultList 裡對應的那一筆" $
      hedgehog $ do
        useVa <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let sel = if useVa then "story" else "assets"
              vid = if useVa then flVaId fl else flVbId fl
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            infoR <- runService env (vaultInfo sel)
            listR <- runService env vaultList
            pure (infoR, listR, vid)
        let (infoR, listR, vid) = outcome
        case (infoR, listR) of
          (Right info, Right vs) -> case [v | v <- vs, vvId v == vid] of
            [expected] -> viVault info === expected
            _ -> failure
          _ -> annotate (describeServiceResult infoR <> " / " <> describeServiceResult listR) >> failure

    it "test_vault_info_unknown_selector_example (X20): Left (WorkspaceFailed (VaultSelectorNotFound _))" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultInfo "沒有這個")
          result `shouldBe` Left (WorkspaceFailed (VaultSelectorNotFound "沒有這個"))

  --------------------------------------------------------------------------
  describe "L21,X18,X19: viCounts" $ do
    it "prop_vault_info_counts_independent_of_scope (L21/A4): 對任一 --vault selector(含 Nothing),已索引 vault 的 viCounts 都相同" $
      hedgehog $ do
        envSel <- forAll (Gen.element [Nothing, Just "story", Just "assets"])
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          indexOneAssetPack fl
          withOpenEnv envSel (flRoot fl) $ \env -> runService env (vaultInfo "assets")
        case outcome of
          Right info -> viCounts info === [("ast", 1), ("pck", 1)]
          Left e -> annotate (show e) >> failure

    it "test_vault_info_empty_example (X18): 空 vault,viCounts == []" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultInfo "assets")
          case result of
            Right info -> viCounts info `shouldBe` []
            Left e -> expectationFailure (show e)

    it "test_vault_info_indexed_example (X19): 已索引一個 pck + 一個 ast,viCounts == [(\"ast\",1),(\"pck\",1)]" $
      withFixedLayout $ \fl -> do
        indexOneAssetPack fl
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (vaultInfo "assets")
          case result of
            Right info -> viCounts info `shouldBe` [("ast", 1), ("pck", 1)]
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L22,X18,X19b: viIssues" $ do
    it "prop_vault_info_issues_matches_index_issues_for (L22): 對 VA/VB 任一,viIssues 逐項等於同一個 env 的 indexIssuesFor" $
      hedgehog $ do
        useVa <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let (sel, vid) = if useVa then ("story", flVaId fl) else ("assets", flVbId fl)
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            infoR <- runService env (vaultInfo sel)
            issuesR <- runService env (indexIssuesFor vid)
            pure (infoR, issuesR)
        let (infoR, issuesR) = outcome
        case (infoR, issuesR) of
          (Right info, Right issues) -> viIssues info === issues
          _ -> annotate (describeServiceResult infoR <> " / " <> describeServiceResult issuesR) >> failure

    it "test_vault_info_ignores_vault_scope_example (X19b): --vault story 之下 vaultInfo \"assets\" 仍算得出節點數,viIssues 與同一 env 的 indexIssuesFor 逐項相等" $
      withFixedLayout $ \fl -> do
        indexOneAssetPack fl
        withOpenEnv (Just "story") (flRoot fl) $ \env -> do
          result <- runService env (vaultInfo "assets")
          issuesR <- runService env (indexIssuesFor (flVbId fl))
          case (result, issuesR) of
            (Right info, Right issues) -> do
              viCounts info `shouldBe` [("ast", 1), ("pck", 1)]
              viIssues info `shouldBe` issues
            (Left e, _) -> expectationFailure (show e)
            (_, Left e) -> expectationFailure (show e)
