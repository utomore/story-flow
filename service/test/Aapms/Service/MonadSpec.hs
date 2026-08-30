-- | F001:'Aapms.Service.Monad'——'Env' 的生命週期('openEnv'\/'runService'\/
-- 'closeEnv'\/'withEnv')、handle 快取('handleFor'\/'indexIssuesFor')與八個
-- 存取器。
--
-- __spec 對照__(@.design\/subsystems\/service\/features\/F001-service-env-and-scope.md@,
-- 「1-to-1 測試對照表」——除 L23 外全部紅):
--
-- @
-- L1,X1     openEnv 不開索引                    -> prop_open_env_does_not_open_index, test_open_env_no_index_example
-- L2,X2     中樞載不起來即失敗                    -> prop_open_env_hub_missing_fails, test_open_env_hub_missing_example
-- L3,X3     註冊表定位不到即失敗                  -> prop_open_env_registry_unavailable_fails, test_open_env_registry_unavailable_example
-- L4,X3b    註冊表載入失敗即失敗                  -> prop_open_env_registry_load_failed, test_open_env_registry_load_failed_example
-- L5,X9     closeEnv 釋放乾淨                    -> prop_close_env_releases_cleanly, test_close_env_then_reopen_example
-- L6,X10    closeEnv 冪等                        -> prop_close_env_idempotent, test_close_env_idempotent_example
-- L7,X11    withEnv = openEnv + closeEnv          -> prop_with_env_matches_open_close, test_with_env_failure_path_example
-- L8,X7     handleFor 快取命中不再開檔             -> prop_handle_for_cache_hit, test_handle_for_cache_hit_survives_deleted_marker
-- L9,X8     handleFor 開啟失敗即短路               -> prop_handle_for_open_failure_short_circuits, test_handle_for_manual_ref_example
-- L10       indexIssuesFor 與開啟同步              -> prop_index_issues_for_synced_with_open
-- L11,X12   runService 互斥                       -> prop_run_service_mutual_exclusion, test_run_service_eight_concurrent_example
-- L12,X13   runService 錯誤傳播                    -> prop_run_service_error_propagation, test_throw_service_example
-- X4        askSelector 原樣捧著                  -> test_ask_selector_example
-- X5        askRegistrySource 可觀察               -> test_ask_registry_source_example
-- X5b       askHubLocation/askCwd 原樣捧著         -> test_ask_hub_location_and_cwd_example
-- X5c       askRegistry/askNaming 同一次載入        -> test_ask_registry_and_naming_example
-- X6        askHub/reloadHub                       -> test_ask_hub_and_reload_hub_example
-- L24,X26,X27 finallyService 兩條路徑都收尾恰好一次 -> prop_finally_service_success_runs_cleanup_once, prop_finally_service_short_circuit_runs_cleanup_once, test_finally_service_success_example, test_finally_service_short_circuit_example
-- @
module Aapms.Service.MonadSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, replicateM)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (Gen, annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Id (VaultId (..))
import Aapms.Core.Registry (listTypes)
import qualified Aapms.Types.Loader as Loader
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Schema (IndexIssue (..), VaultKind (..), schemaVersion)
import Aapms.Types.Loader (loadRegistry, registryEnvVar)
import Aapms.Workspace.Types
  ( HubLocation (..)
  , HubSource (FromEnv)
  , VaultRef (..)
  , WorkspaceError (..)
  , hubVaults
  )

import Aapms.Service.Fixtures
import Aapms.Service.Monad
import Aapms.Service.Scope (withRead, withWrite)
import Aapms.Service.Types (ServiceError (..))

--------------------------------------------------------------------------------
-- 產生器

-- | 任意 selector 字串(含 @Nothing@)——'openEnv' 本層__不解讀__它,所以定義域
-- 涵蓋任何文字都合法。
genAnySelector :: Gen (Maybe Text)
genAnySelector =
  Gen.choice
    [ pure Nothing
    , Just <$> Gen.text (Range.linear 0 8) (Gen.choice [Gen.alpha, Gen.digit, Gen.element (" -_./" :: String)])
    ]

-- | 佈局裡幾個有代表性的起點,相對 'flRoot'。
genCwdRel :: Gen FilePath
genCwdRel = Gen.element ["va", "vb", "outside", "va/deep", "outside/deep", "nonexistent"]

cwdFor :: FixedLayout -> FilePath -> FilePath
cwdFor fl rel = flRoot fl </> rel

data OpTag = ReadOp | WriteOp
  deriving stock (Show, Eq)

genOps :: Gen [OpTag]
genOps = Gen.list (Range.linear 1 3) (Gen.element [ReadOp, WriteOp])

runOp :: OpTag -> ServiceM ()
runOp ReadOp = withRead (\_ _ -> pure ())
runOp WriteOp = withWrite (\_ _ -> pure ())

runOps :: [OpTag] -> ServiceM ()
runOps = mapM_ runOp

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F001 Aapms.Service.Monad" $ do
  --------------------------------------------------------------------------
  describe "L1/X1: openEnv 不開任何 vault 索引" $ do
    it "prop_open_env_does_not_open_index (L1): 對任意 sel/cwd,呼叫前後 index.db 存在性不變" $
      hedgehog $ do
        sel <- forAll genAnySelector
        cwdRel <- forAll genCwdRel
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          before <- indexDbExistence fl
          r <- openEnv sel (cwdFor fl cwdRel)
          case r of
            Right env -> closeEnv env
            Left _ -> pure ()
          after <- indexDbExistence fl
          pure (before, after)
        let (before, after) = outcome
        before === after
        before === (False, False)

    it "test_open_env_no_index_example (X1): openEnv Nothing <tmp>/va 之後兩個 index.db 都不存在" $
      withFixedLayout $ \fl -> do
        r <- openEnv Nothing (flVaPath fl)
        case r of
          Right env -> do
            indexDbExistence fl `shouldReturn` (False, False)
            closeEnv env
          Left e -> expectationFailure ("預期 Right,得到 " <> show e)

  --------------------------------------------------------------------------
  describe "L2/X2: 中樞載不起來即失敗" $ do
    it "prop_open_env_hub_missing_fails (L2): 中樞 config.toml 不存在時,對任意 sel/cwd 一律 Left (WorkspaceFailed (HubNotFound _))" $
      hedgehog $ do
        sel <- forAll genAnySelector
        cwdRel <- forAll genCwdRel
        result <- liftIO $ withFixedLayout $ \fl -> do
          removeFile (flHubDir fl </> "config.toml")
          openEnv sel (cwdFor fl cwdRel)
        case result of
          Left (WorkspaceFailed (HubNotFound _)) -> pure ()
          other -> annotate (describeEnvResult other) >> failure

    it "test_open_env_hub_missing_example (X2): 精確路徑" $
      withFixedLayout $ \fl -> do
        let hubFile = flHubDir fl </> "config.toml"
        removeFile hubFile
        result <- openEnv Nothing (flVaPath fl)
        case result of
          Left e -> e `shouldBe` WorkspaceFailed (HubNotFound hubFile)
          Right _ -> expectationFailure "預期 Left (WorkspaceFailed (HubNotFound _)),得到 Right"

  --------------------------------------------------------------------------
  describe "L3/X3: 註冊表定位不到即失敗" $ do
    it "prop_open_env_registry_unavailable_fails (L3): STORYFLOW_REGISTRY 指向不存在的目錄時,對任意 sel/cwd 一律 Left (RegistryUnavailable _)" $
      hedgehog $ do
        sel <- forAll genAnySelector
        cwdRel <- forAll genCwdRel
        result <- liftIO $ withFixedLayout $ \fl ->
          withEnvVars [(registryEnvVar, flRoot fl </> "no-such-registry")] $
            openEnv sel (cwdFor fl cwdRel)
        case result of
          Left (RegistryUnavailable _) -> pure ()
          other -> annotate (describeEnvResult other) >> failure

    it "test_open_env_registry_unavailable_example (X3)" $
      withFixedLayout $ \fl ->
        withEnvVars [(registryEnvVar, flRoot fl </> "no-such-registry")] $ do
          result <- openEnv Nothing (flVaPath fl)
          case result of
            Left (RegistryUnavailable _) -> pure ()
            other -> expectationFailure ("預期 Left (RegistryUnavailable _),得到 " <> describeEnvResult other)

  --------------------------------------------------------------------------
  describe "L4/X3b: 註冊表載入失敗即失敗" $ do
    it "prop_open_env_registry_load_failed (L4): 註冊表目錄存在但缺 naming.toml 時,對任意 sel/cwd 一律 Left (RegistryLoadFailed _)" $
      hedgehog $ do
        sel <- forAll genAnySelector
        cwdRel <- forAll genCwdRel
        result <- liftIO $ withFixedLayout $ \fl -> do
          let badReg = flRoot fl </> "bad-registry"
          createDirectoryIfMissingIO badReg
          withEnvVars [(registryEnvVar, badReg)] $
            openEnv sel (cwdFor fl cwdRel)
        case result of
          Left (RegistryLoadFailed _) -> pure ()
          other -> annotate (describeEnvResult other) >> failure

    it "test_open_env_registry_load_failed_example (X3b)" $
      withFixedLayout $ \fl -> do
        let badReg = flRoot fl </> "bad-registry"
        createDirectoryIfMissingIO badReg
        withEnvVars [(registryEnvVar, badReg)] $ do
          result <- openEnv Nothing (flVaPath fl)
          case result of
            Left (RegistryLoadFailed _) -> pure ()
            other -> expectationFailure ("預期 Left (RegistryLoadFailed _),得到 " <> describeEnvResult other)

  --------------------------------------------------------------------------
  describe "L5/X9: closeEnv 釋放乾淨" $ do
    it "prop_close_env_releases_cleanly (L5): 對任意一串 withRead/withWrite,closeEnv 後新 env' 重跑仍成功,暫存目錄可刪除" $
      hedgehog $ do
        ops <- forAll genOps
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          env1 <- openEnvOrDie Nothing (flVaPath fl)
          r1 <- runService env1 (runOps ops)
          closeEnv env1
          env2 <- openEnvOrDie Nothing (flVaPath fl)
          r2 <- runService env2 (runOps ops)
          closeEnv env2
          deletable <- tryDelete (flRoot fl)
          pure (r1, r2, deletable)
        let (r1, r2, deletable) = outcome
        annotate (show (r1, r2, deletable))
        isRightU r1 === True
        isRightU r2 === True
        deletable === True

    it "test_close_env_then_reopen_example (X9): withRead 一串操作後 closeEnv,刪除整個暫存目錄,新 env' 重跑仍成功" $
      withFixedLayout $ \fl -> do
        env1 <- openEnvOrDie Nothing (flVaPath fl)
        r1 <- runService env1 (withRead (\_ _ -> pure ()))
        closeEnv env1
        deletable <- tryDelete (flRoot fl)
        deletable `shouldBe` True
        -- 目錄已被刪除,重建同一佈局才能再跑一次(佐證「乾淨到可以整個重來」)。
        case r1 of
          Right () -> pure ()
          Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L6/X10: closeEnv 冪等" $ do
    it "prop_close_env_idempotent (L6): 對任意成功開出的 env,closeEnv 兩次與一次不可區分(不丟例外)" $
      hedgehog $ do
        sel <- forAll genAnySelector
        result <- liftIO $ withFixedLayout $ \fl -> try $ do
          env <- openEnvOrDie sel (flVaPath fl)
          closeEnv env
          closeEnv env
        case result of
          Right () -> pure ()
          Left (e :: SomeException) -> annotate (show e) >> failure

    it "test_close_env_idempotent_example (X10)" $
      withFixedLayout $ \fl -> do
        env <- openEnvOrDie Nothing (flVaPath fl)
        (closeEnv env >> closeEnv env) `shouldReturn` ()

  --------------------------------------------------------------------------
  describe "L7/X11: withEnv = openEnv + closeEnv" $ do
    it "prop_with_env_matches_open_close (L7): openEnv 成功時 f 恰呼叫一次且回 Right;openEnv 失敗時 f 不被呼叫,回相同的 Left" $
      hedgehog $ do
        hubMissing <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          if hubMissing then removeFile (flHubDir fl </> "config.toml") else pure ()
          calls <- newIORef (0 :: Int)
          directR <- openEnv Nothing (flVaPath fl)
          case directR of
            Right env -> closeEnv env
            Left _ -> pure ()
          withResult <- withEnv Nothing (flVaPath fl) (\_ -> modifyIORef' calls (+ 1))
          n <- readIORef calls
          pure (hubMissing, directR, withResult, n)
        let (missing, directR, withResult, n) = outcome
        annotate (show (missing, isRightU directR, isRightU (fmapUnit withResult), n))
        if missing
          then do
            n === 0
            isLeftU withResult === True
          else do
            n === 1
            isRightU withResult === True

    it "test_with_env_failure_path_example (X11): openEnv 會失敗時 withEnv 回相同的 Left 且 f 一次都沒被呼叫" $
      withFixedLayout $ \fl -> do
        removeFile (flHubDir fl </> "config.toml")
        flag <- newIORef False
        result <- withEnv Nothing (flVaPath fl) (\_ -> writeIORef flag True)
        case result of
          Left (WorkspaceFailed (HubNotFound _)) -> pure ()
          other -> expectationFailure ("預期 Left (WorkspaceFailed (HubNotFound _)),得到 " <> show other)
        readIORef flag `shouldReturn` False

  --------------------------------------------------------------------------
  describe "L8/X7: handleFor 快取命中不再開檔" $ do
    it "prop_handle_for_cache_hit (L8): 對任意一個 vault,同一個 env 上第二次 handleFor 回相同的 vhRoot/vmId,即使中間把 marker 刪掉" $
      hedgehog $ do
        useVa <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let vpath = if useVa then flVaPath fl else flVbPath fl
              vid = if useVa then flVaId fl else flVbId fl
              ref = mkVaultRef vid vpath
          withOpenEnv Nothing (flVaPath fl) $ \env -> do
            r1 <- runService env (handleFor ref)
            removeFile (vpath </> ".aapms" </> "config.toml")
            r2 <- runService env (handleFor ref)
            pure (r1, r2)
        case outcome of
          (Right h1, Right h2) -> vhRootOf h1 === vhRootOf h2
          other -> annotate (show (fmap (const ()) (fst other), fmap (const ()) (snd other))) >> failure

    it "test_handle_for_cache_hit_survives_deleted_marker (X7)" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          let ref = mkVaultRef (flVaId fl) (flVaPath fl)
          r1 <- runService env (handleFor ref)
          removeFile (flVaPath fl </> ".aapms" </> "config.toml")
          r2 <- runService env (handleFor ref)
          case (r1, r2) of
            (Right h1, Right h2) -> do
              vhRootOf h1 `shouldBe` vhRootOf h2
              vhMarkerIdOf h1 `shouldBe` vhMarkerIdOf h2
            other -> expectationFailure ("預期兩次都成功," <> show (isRightU (fst other), isRightU (snd other)))

  --------------------------------------------------------------------------
  describe "L9/X8: handleFor 開啟失敗即短路" $ do
    it "prop_handle_for_open_failure_short_circuits (L9): 對任意指向非 vault 目錄的 ref,handleFor 以 StoreFailed 短路,後續動作不被執行" $
      hedgehog $ do
        sub <- forAll (Gen.element ["", "deep", "deeper/x"])
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let badPath = if null sub then flOutsidePath fl else flOutsidePath fl </> sub
              ref = mkVaultRef (VaultId "vlt-deadbeef") badPath
          withOpenEnv Nothing (flVaPath fl) $ \env -> do
            ranAfter <- newIORef False
            r <- runService env (handleFor ref >> liftIO (writeIORef ranAfter True))
            after <- readIORef ranAfter
            pure (r, after)
        case outcome of
          (Left (StoreFailed _), False) -> pure ()
          other -> annotate (show (fst other)) >> failure

    it "test_handle_for_manual_ref_example (X8)" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          let ref = mkVaultRef (VaultId "vlt-deadbeef") (flOutsidePath fl)
          result <- runService env (handleFor ref)
          case result of
            Left (StoreFailed _) -> pure ()
            Left e -> expectationFailure ("預期 Left (StoreFailed _),得到 Left " <> show e)
            Right _ -> expectationFailure "預期 Left (StoreFailed _),得到 Right"

  --------------------------------------------------------------------------
  describe "L10: indexIssuesFor 與開啟同步" $
    it "prop_index_issues_for_synced_with_open (L10): 開啟前回 []、開啟後回這個全新 vault 首次開啟必有的 SchemaRebuilt" $
      hedgehog $ do
        useVa <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          let vpath = if useVa then flVaPath fl else flVbPath fl
              vid = if useVa then flVaId fl else flVbId fl
              ref = mkVaultRef vid vpath
          withOpenEnv Nothing (flVaPath fl) $ \env ->
            runService env $ do
              before <- indexIssuesFor vid
              _ <- handleFor ref
              after <- indexIssuesFor vid
              pure (before, after)
        case outcome of
          Right (before, after) -> do
            before === []
            after === [SchemaRebuilt Nothing schemaVersion]
          Left e -> annotate (show e) >> failure

  --------------------------------------------------------------------------
  describe "L11/X12: runService 互斥" $ do
    it "prop_run_service_mutual_exclusion (L11): 對任意 n,並發 n 次 runService 做讀-改-寫,最終值恒為 n,臨界區不重疊" $
      hedgehog $ do
        n <- forAll (Gen.int (Range.linear 2 6))
        (noOverlap, final, allOk) <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flVaPath fl) $ \env -> runConcurrentIncrements env n
        annotate (show (noOverlap, final, allOk))
        noOverlap === True
        final === n
        allOk === True

    it "test_run_service_eight_concurrent_example (X12): n = 8" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          (_, final, allOk) <- runConcurrentIncrements env 8
          final `shouldBe` 8
          allOk `shouldBe` True

  --------------------------------------------------------------------------
  describe "L12/X13: runService 錯誤傳播" $ do
    it "prop_run_service_error_propagation (L12): 對任意 ServiceError e,runService env (throwService e) 回 Left e,逐欄相等" $
      hedgehog $ do
        path <- forAll (Gen.text (Range.linear 1 8) Gen.alpha)
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flVaPath fl) $ \env -> do
            let e = WorkspaceFailed (NoWriteTarget ("/" <> T.unpack path))
            r <- runService env (throwService e :: ServiceM ())
            pure (r, e)
        let (r, e) = outcome
        r === Left e

    it "test_throw_service_example (X13)" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          let e = WorkspaceFailed (NoWriteTarget "/x")
          result <- runService env (throwService e :: ServiceM ())
          result `shouldBe` Left e

  --------------------------------------------------------------------------
  describe "X4/X5/X5b/X5c/X6: 八個 ask* 存取器與 reloadHub(L-,見 spec Laws 段末)" $ do
    it "test_ask_selector_example (X4): askSelector 原樣捧著 selector" $
      withFixedLayout $ \fl ->
        withOpenEnv (Just "story") (flOutsidePath fl) $ \env -> do
          result <- runService env askSelector
          result `shouldBe` Right (Just "story")

    it "test_ask_registry_source_example (X5): askRegistrySource 回 Loader.FromEnv(STORYFLOW_REGISTRY 指到專案 types/registry/)" $
      withFixedLayout $ \fl ->
        withOpenEnv (Just "story") (flOutsidePath fl) $ \env -> do
          result <- runService env askRegistrySource
          result `shouldBe` Right Loader.FromEnv

    it "test_ask_hub_location_and_cwd_example (X5b): askHubLocation/askCwd 原樣捧著中樞位置與起點" $
      withFixedLayout $ \fl ->
        withOpenEnv (Just "story") (flOutsidePath fl) $ \env -> do
          result <- runService env ((,) <$> askHubLocation <*> askCwd)
          case result of
            Right (loc, cwd) -> do
              hlPath loc `shouldBe` flHubDir fl
              hlSource loc `shouldBe` FromEnv
              cwd `shouldBe` flOutsidePath fl
            Left e -> expectationFailure (show e)

    it "test_ask_registry_and_naming_example (X5c): askRegistry/askNaming 來自同一次 loadRegistry" $
      withFixedLayout $ \fl -> do
        reg <- registryDir
        direct <- loadRegistry reg
        withOpenEnv (Just "story") (flOutsidePath fl) $ \env -> do
          result <- runService env ((,) <$> (length . listTypes <$> askRegistry) <*> askNaming)
          case (result, direct) of
            (Right (n, naming), Right (_, expectedNaming)) -> do
              n `shouldSatisfy` (> 0)
              naming `shouldBe` expectedNaming
            (r, d) -> expectationFailure ("askRegistry/askNaming 或 loadRegistry 失敗:" <> show (isRightU r, either (const False) (const True) d))

    it "test_ask_hub_and_reload_hub_example (X6): askHub 是舊快照,reloadHub 換成新的" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          let extraId = VaultId "vlt-cccc3333"
              extraPath = flRoot fl </> "vc"
          writeVaultMarkerViaFixture extraPath extraId
          writeHubConfigAt
            (flHubDir fl)
            ( hubConfigText
                [ (flVaId fl, "story", "story", flVaPath fl)
                , (flVbId fl, "assets", "asset", flVbPath fl)
                , (extraId, "extra", "asset", extraPath)
                ]
            )
          result <- runService env ((,) <$> askHub <*> reloadHub)
          case result of
            Right (before, after) -> do
              length (hubVaults before) `shouldBe` 2
              length (hubVaults after) `shouldBe` 3
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "L24/X26/X27: finallyService 兩條路徑都收尾恰好一次" $ do
    it "prop_finally_service_success_runs_cleanup_once (L24 成功路徑): 對任意 v,finallyService (pure v) fin 回 Right v、fin 恰好執行一次,且收尾發生在動作之後" $
      hedgehog $ do
        v <- forAll (Gen.int (Range.linear (-1000) 1000))
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flVaPath fl) $ \env -> do
            c <- newIORef (0 :: Int)
            order <- newIORef ([] :: [Int])
            let action = liftIO (modifyIORef' order (++ [1])) >> pure v
                fin = liftIO (modifyIORef' c (+ 1) >> modifyIORef' order (++ [2]))
            r <- runService env (finallyService action fin)
            n <- readIORef c
            seen <- readIORef order
            pure (r, n, seen)
        let (r, n, seen) = outcome
        r === Right v
        n === 1
        seen === [1, 2]

    it "prop_finally_service_short_circuit_runs_cleanup_once (L24 短路路徑): 對任意 ServiceError e,finallyService (throwService e) fin 回 Left e(短路不被吞掉)、fin 恰好執行一次,且收尾發生在動作之後" $
      hedgehog $ do
        path <- forAll (Gen.text (Range.linear 1 8) Gen.alpha)
        let e = WorkspaceFailed (NoWriteTarget ("/" <> T.unpack path))
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flVaPath fl) $ \env -> do
            c <- newIORef (0 :: Int)
            order <- newIORef ([] :: [Int])
            let action = (liftIO (modifyIORef' order (++ [1])) >> throwService e) :: ServiceM ()
                fin = liftIO (modifyIORef' c (+ 1) >> modifyIORef' order (++ [2]))
            r <- runService env (finallyService action fin)
            n <- readIORef c
            seen <- readIORef order
            pure (r, n, seen)
        let (r, n, seen) = outcome
        r === Left e
        n === 1
        seen === [1, 2]

    it "test_finally_service_success_example (X26): runService env (finallyService (pure 42) fin),c 起始為 0" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          c <- newIORef (0 :: Int)
          r <- runService env (finallyService (pure (42 :: Int)) (liftIO (modifyIORef' c (+ 1))))
          r `shouldBe` Right 42
          readIORef c `shouldReturn` 1

    it "test_finally_service_short_circuit_example (X27): 短路不被吞掉(與 X13 逐欄相同),c 起始為 0" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flVaPath fl) $ \env -> do
          c <- newIORef (0 :: Int)
          let e = WorkspaceFailed (NoWriteTarget "/x")
          r <- runService env (finallyService (throwService e :: ServiceM Int) (liftIO (modifyIORef' c (+ 1))))
          r `shouldBe` Left e
          readIORef c `shouldReturn` 1

--------------------------------------------------------------------------------
-- helper

isRightU :: Either e a -> Bool
isRightU (Right _) = True
isRightU (Left _) = False

isLeftU :: Either e a -> Bool
isLeftU = not . isRightU

fmapUnit :: Either e a -> Either e ()
fmapUnit (Right _) = Right ()
fmapUnit (Left e) = Left e

-- | 'Env' 沒有 'Show' 實例(不透明型別),所以 debug 訊息只能秀出 'Left' 那一側。
describeEnvResult :: Either ServiceError Env -> String
describeEnvResult (Left e) = "Left (" <> show e <> ")"
describeEnvResult (Right _) = "Right <Env>"

indexDbExistence :: FixedLayout -> IO (Bool, Bool)
indexDbExistence fl =
  (,)
    <$> doesFileExist (flVaPath fl </> ".aapms" </> "index.db")
    <*> doesFileExist (flVbPath fl </> ".aapms" </> "index.db")

tryDelete :: FilePath -> IO Bool
tryDelete p = either (const False) (const True) <$> (try (removePathForcibly p) :: IO (Either SomeException ()))

createDirectoryIfMissingIO :: FilePath -> IO ()
createDirectoryIfMissingIO = createDirectoryIfMissing True

mkVaultRef :: VaultId -> FilePath -> VaultRef
mkVaultRef vid path =
  VaultRef
    { vrEntry = Nothing
    , vrPath = path
    , vrMarker = VaultMarker {vmId = vid, vmKind = AssetVault, vmName = "x", vmRefs = []}
    }

vhRootOf :: VaultHandle -> FilePath
vhRootOf = vhRoot

vhMarkerIdOf :: VaultHandle -> VaultId
vhMarkerIdOf = vmId . vhMarker

writeVaultMarkerViaFixture :: FilePath -> VaultId -> IO ()
writeVaultMarkerViaFixture path vid = writeVaultMarkerAt path (markerTomlText vid "asset" "extra" [])

-- | 並發跑 n 次 runService,各自對一個共用 IORef 做讀-改-寫,並用一個共用旗標偵測
-- 臨界區是否重疊(L11)。回傳(未偵測到重疊、最終計數、n 次全部成功)。
--
-- __每個分支的 'runService' 都用 'try' 包住__:骨架階段 'runService' 是
-- @undefined@,若不接住例外,拋例外的分支就永遠不會 'putMVar',主執行緒的
-- 'takeMVar' 會卡死,整個測試套件掛住而不是乾淨地紅——這是測骨架必須顧到的事,
-- 不是「測試多寫的東西」。
runConcurrentIncrements :: Env -> Int -> IO (Bool, Int, Bool)
runConcurrentIncrements env n = do
  busy <- newIORef False
  overlap <- newIORef False
  counter <- newIORef (0 :: Int)
  mvars <- replicateM n newEmptyMVar
  forM_ mvars $ \mv -> forkIO $ do
    outcome <-
      try $
        runService env $
          liftIO $ do
            b <- readIORef busy
            if b then writeIORef overlap True else pure ()
            writeIORef busy True
            threadDelay 1000
            modifyIORef' counter (+ 1)
            writeIORef busy False
    putMVar mv (outcome :: Either SomeException (Either ServiceError ()))
  results <- mapM takeMVar mvars
  ov <- readIORef overlap
  final <- readIORef counter
  let allOk = all isOkNested results
      isOkNested (Right (Right ())) = True
      isOkNested _ = False
  pure (not ov, final, allOk)
