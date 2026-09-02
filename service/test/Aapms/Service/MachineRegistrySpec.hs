-- | F002:'Aapms.Service.Machine.listTypes' \/ 'showType' \/ 'thumbPath',與
-- 'Aapms.Service.Types.UnknownType' 的 'Aapms.Service.Types.errorCode' \/
-- 'Aapms.Service.Types.renderServiceError' 兩個分支。
--
-- __spec 對照__(「1-to-1 測試對照表」——'listTypes'\/'showType'\/'thumbPath' 全紅;
-- __L27\/EX-27 是骨架承載,預期綠__,不得因為綠就退回或改寫):
--
-- @
-- LAW-23,EX-21     listTypes 逐項轉出                                    -> prop_list_types_matches_registry, test_list_types_matches_registry_example
-- LAW-24,EX-22,EX-23 showType 的兩條路(命中\/未命中)                        -> prop_show_type_two_paths, test_show_type_hit_example, test_show_type_miss_example
-- LAW-25,EX-24     thumbPath 位置由 workspace 算,本層只判存在                -> prop_thumb_path_existence_and_content, test_thumb_path_miss_then_hit_example
-- LAW-27,EX-27     UnknownType 的 errorCode\/renderServiceError(__骨架承載,預期綠__) -> prop_unknown_type_error_code_and_message, test_unknown_type_error_code_and_message_example
-- @
module Aapms.Service.MachineRegistrySpec (spec) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import Hedgehog (annotate, failure, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Asset (Sha256 (..))
import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Registry (tdKey)
import qualified Aapms.Core.Registry as Registry
import Aapms.Types.Loader (loadRegistry)
import Aapms.Workspace.Location (thumbCachePath)

import Aapms.Service.Fixtures
import Aapms.Service.Machine (listTypes, showType, thumbPath)
import Aapms.Service.Monad (askHubLocation, runService)
import Aapms.Service.Types (ServiceError (UnknownType), errorCode, renderServiceError)

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F002 Aapms.Service.Machine: listTypes / showType / thumbPath" $ do
  --------------------------------------------------------------------------
  describe "LAW-23,EX-21: listTypes 逐項轉出" $ do
    it "prop_list_types_matches_registry (LAW-23): listTypes 與 Aapms.Core.Registry.listTypes(同一份 askRegistry)逐項相同" $
      hedgehog $ do
        outcome <- liftIO $ withFixedLayout $ \fl -> do
          reg <- registryDir
          direct <- loadRegistry reg
          case direct of
            Left e -> pure (Left (Left e))
            Right (typeRegistry, _naming) ->
              withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
                r <- runService env listTypes
                pure (either (Left . Right) (\ds -> Right (ds, Registry.listTypes typeRegistry)) r)
        case outcome of
          Right (ds, expected) -> ds === expected
          Left _ -> annotate "測試前置作業失敗(loadRegistry 或 listTypes)" >> failure

    it "test_list_types_matches_registry_example (EX-21): 兩份清單逐項相同、順序相同,長度 > 0" $
      withFixedLayout $ \fl -> do
        reg <- registryDir
        direct <- loadRegistry reg
        case direct of
          Right (typeRegistry, _naming) ->
            withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
              result <- runService env listTypes
              case result of
                Right decls -> do
                  decls `shouldBe` Registry.listTypes typeRegistry
                  length decls `shouldSatisfy` (> 0)
                Left e -> expectationFailure (show e)
          Left e -> expectationFailure ("loadRegistry 失敗:" <> show e)

  --------------------------------------------------------------------------
  describe "LAW-24,EX-22,EX-23: showType 的兩條路" $ do
    it "prop_show_type_two_paths (LAW-24): 命中回 Right d(逐欄相同);未命中回 Left (UnknownType t),t 就是那個鍵" $
      hedgehog $ do
        useKnown <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            listR <- runService env listTypes
            case listR of
              Right (d : _) -> do
                let key = if useKnown then tdKey d else TypeKey "no-such-type-xyz-999"
                r <- runService env (showType key)
                pure (Just (r, if useKnown then Just d else Nothing, key))
              _ -> pure Nothing
        case outcome of
          Just (Right d, Just expected, _) -> d === expected
          Just (Left (UnknownType t), Nothing, TypeKey k) -> t === k
          _ -> annotate "測試前置作業失敗(listTypes 沒有任何型別,或 showType 結果與預期分支不符)" >> failure

    it "test_show_type_hit_example (EX-22): showType (tdKey d) 回 Right d" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          listR <- runService env listTypes
          case listR of
            Right (d : _) -> do
              result <- runService env (showType (tdKey d))
              result `shouldBe` Right d
            _ -> expectationFailure "註冊表沒有任何型別"

    it "test_show_type_miss_example (EX-23): showType (TypeKey \"no-such-type-xyz\") 回 Left (UnknownType \"no-such-type-xyz\")" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          result <- runService env (showType (TypeKey "no-such-type-xyz"))
          result `shouldBe` Left (UnknownType "no-such-type-xyz")

  --------------------------------------------------------------------------
  describe "LAW-25,EX-24: thumbPath 位置由 workspace 算,本層只判存在" $ do
    it "prop_thumb_path_existence_and_content (LAW-25): 快取檔存在時回 Just p 且 p 逐字等於 thumbCachePath loc h,不存在時回 Nothing" $
      hedgehog $ do
        shouldCreate <- forAll Gen.bool
        outcome <- liftIO $ withFixedLayout $ \fl ->
          withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
            locR <- runService env askHubLocation
            case locR of
              Left e -> pure (Left e)
              Right loc -> do
                let h = Sha256 "deadbeefcafef00d"
                    p = thumbCachePath loc h
                if shouldCreate
                  then do
                    createDirectoryIfMissing True (takeDirectory p)
                    writeFile p "PNGDATA"
                  else pure ()
                r <- runService env (thumbPath h)
                pure (Right (r, p))
        case outcome of
          Right (Right Nothing, _) -> shouldCreate === False
          Right (Right (Just p'), p) -> do
            shouldCreate === True
            p' === p
          _ -> annotate "測試前置作業失敗(askHubLocation)" >> failure

    it "test_thumb_path_miss_then_hit_example (EX-24): 第一次 Right Nothing;手動建出快取檔後第二次 Right (Just p),p 讀得到剛寫入的位元組" $
      withFixedLayout $ \fl ->
        withOpenEnv Nothing (flOutsidePath fl) $ \env -> do
          locR <- runService env askHubLocation
          case locR of
            Right loc -> do
              let h = Sha256 "cafebabe1234"
                  p = thumbCachePath loc h
              r1 <- runService env (thumbPath h)
              r1 `shouldBe` Right Nothing
              createDirectoryIfMissing True (takeDirectory p)
              writeFile p "PNGDATA"
              r2 <- runService env (thumbPath h)
              r2 `shouldBe` Right (Just p)
              case r2 of
                Right (Just p') -> do
                  content <- readFile p'
                  content `shouldBe` "PNGDATA"
                _ -> expectationFailure "預期 Just"
            Left e -> expectationFailure (show e)

  --------------------------------------------------------------------------
  describe "LAW-27,EX-27: UnknownType 的 errorCode/renderServiceError(骨架承載,預期綠)" $ do
    it "prop_unknown_type_error_code_and_message (LAW-27): 對任意 t,code 逐字 unknown_type;訊息非空、含 t、含 \"type list\"" $
      hedgehog $ do
        t <- forAll (Gen.text (Range.linear 1 20) Gen.alphaNum)
        errorCode (UnknownType t) === "unknown_type"
        let msg = renderServiceError (UnknownType t)
        T.null msg === False
        T.isInfixOf t msg === True
        T.isInfixOf "type list" msg === True

    it "test_unknown_type_error_code_and_message_example (EX-27)" $ do
      errorCode (UnknownType "no-such-type-xyz") `shouldBe` "unknown_type"
      let msg = renderServiceError (UnknownType "no-such-type-xyz")
      msg `shouldSatisfy` (not . T.null)
      msg `shouldSatisfy` T.isInfixOf "no-such-type-xyz"
      msg `shouldSatisfy` T.isInfixOf "type list"
