-- | F001:'Aapms.Service.Types.ServiceError'、'Aapms.Service.Types.errorCode'、
-- 'Aapms.Service.Types.renderServiceError'。
--
-- __spec 對照__(@.design\/subsystems\/service\/features\/F001-service-env-and-scope.md@,
-- 預期欄依「1-to-1 測試對照表」——全部紅:'errorCode' \/ 'renderServiceError' 全是
-- @undefined@):
--
-- @
-- LAW-19 code 的形狀(非空、只含 [a-z0-9_]、不帶產品前綴)          -> prop_error_code_shape [紅]
-- LAW-20 code 只看建構子、不看酬載,兩兩相異                        -> prop_error_code_by_constructor_only [紅]
-- LAW-21 訊息逐字委派(Store\/Workspace\/RegistryUnavailable\/RegistryLoadFailed) -> prop_render_delegates_store [紅]、prop_render_delegates_workspace [紅]、prop_render_delegates_registry [紅]
-- LAW-22 訊息非空                                                    -> prop_render_service_error_nonempty [紅]
-- EX-21 四個建構子的 code 表                                        -> test_error_code_table [紅]
-- EX-22 StoreFailed 訊息委派的具體例子                               -> test_render_store_failed_example [紅]
-- EX-23 兩個註冊表建構子訊息相同、code 相異                          -> test_registry_constructors_same_message_different_code [紅]
-- @
module Aapms.Service.TypesSpec (spec) where

import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog (Gen, annotate, forAll, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Aapms.Core.Meta (TypeKey (..))
import Aapms.Core.Registry (RegistryError (..), renderRegistryError)
import Aapms.Core.Id (VaultId (..))
import Aapms.Store.Error
  ( StoreError
      ( FileReadFailed
      , FileWriteFailed
      , SqliteError
      , TooManyVaults
      , VaultMarkerInvalid
      , VaultMarkerMissing
      )
  , renderStoreError
  )
import qualified Aapms.Store.Error as SE
import Aapms.Workspace.Types (WorkspaceError (..), renderWorkspaceError)

import Aapms.Service.Types (ServiceError (..), errorCode, renderServiceError)

--------------------------------------------------------------------------------
-- 產生器(涵蓋每個下層錯誤型別的代表性子集,不求窮舉全部建構子——
-- LAW-19-LAW-22 驗的是「code/訊息怎麼從 ServiceError 的酬載推導」,不是下層型別本身的
-- 性質,下層各自的 law 已在各自子系統驗過)

genText :: Gen Text
genText = Gen.text (Range.linear 0 12) (Gen.choice [Gen.alpha, Gen.digit])

genPath :: Gen FilePath
genPath = do
  segs <- Gen.list (Range.linear 1 3) (Gen.string (Range.linear 1 6) Gen.alpha)
  pure ("/" <> concatMap (<> "/") segs <> "x")

genVaultId :: Gen VaultId
genVaultId = VaultId . ("vlt-" <>) <$> Gen.text (Range.singleton 8) (Gen.element (['0' .. '9'] ++ ['a' .. 'f']))

genStoreError :: Gen StoreError
genStoreError =
  Gen.choice
    [ VaultMarkerMissing <$> genPath
    , VaultMarkerInvalid <$> genPath <*> genText
    , SE.VaultAlreadyInitialized <$> genPath
    , FileReadFailed <$> genPath <*> genText
    , FileWriteFailed <$> genPath <*> genText
    , SqliteError <$> genText
    , TooManyVaults <$> Gen.int (Range.linear 0 20) <*> Gen.int (Range.linear 0 20)
    , SE.VaultIdCollision <$> genVaultId <*> genPath <*> genPath
    ]

genWorkspaceError :: Gen WorkspaceError
genWorkspaceError =
  Gen.choice
    [ HubNotFound <$> genPath
    , HubUnreadable <$> genPath <*> genText
    , HubMalformed <$> genPath <*> genText
    , HubWriteFailed <$> genPath <*> genText
    , VaultSelectorNotFound <$> genText
    , NoWriteTarget <$> genPath
    , VaultAlreadyInitialized <$> genPath
    , VaultDirMissing <$> genPath
    , VaultDirNotEmpty <$> genPath
    , InvalidName <$> genText
    , ProjectSelectorNotFound <$> genText
    , ProjectPathMissing <$> genText <*> genPath
    ]

genRegistryError :: Gen RegistryError
genRegistryError =
  Gen.choice
    [ pure EmptyTypeKey
    , DuplicateTypeKey . TypeKey <$> genText
    , RegistryDirMissing <$> genPath
    , NamingFileMissing <$> genPath
    , RegistryNotFound <$> Gen.list (Range.linear 1 3) genPath
    , TomlParseError <$> genPath <*> genText
    , MissingField <$> genPath <*> genText
    , UnknownKey <$> genPath <*> genText
    ]

genServiceError :: Gen ServiceError
genServiceError =
  Gen.choice
    [ StoreFailed <$> genStoreError
    , WorkspaceFailed <$> genWorkspaceError
    , RegistryUnavailable <$> genRegistryError
    , RegistryLoadFailed <$> genRegistryError
    ]

-- | 建構子的序號,__只用來判斷「是不是同一個建構子」__,不代表任何契約上的順序。
ctorTag :: ServiceError -> Int
ctorTag StoreFailed {} = 0
ctorTag WorkspaceFailed {} = 1
ctorTag RegistryUnavailable {} = 2
ctorTag RegistryLoadFailed {} = 3
ctorTag UnknownType {} = 4

--------------------------------------------------------------------------------

spec :: Spec
spec = describe "F001 Aapms.Service.Types" $ do
  --------------------------------------------------------------------------
  describe "LAW-19: errorCode 的形狀" $
    it "prop_error_code_shape: 對任意 ServiceError,code 非空、只含 [a-z0-9_]、不以 story_flow 或 aapms 開頭" $
      hedgehog $ do
        e <- forAll genServiceError
        let code = errorCode e
        annotate (T.unpack code)
        (not (T.null code)) === True
        T.all (\c -> isAsciiLower c || isDigit c || c == '_') code === True
        T.isPrefixOf "story_flow" code === False
        T.isPrefixOf "aapms" code === False

  --------------------------------------------------------------------------
  describe "LAW-20: errorCode 只看建構子,不看酬載" $
    it "prop_error_code_by_constructor_only: 兩個 ServiceError 的 code 相等 <=> 建構子相同" $
      hedgehog $ do
        e1 <- forAll genServiceError
        e2 <- forAll genServiceError
        (ctorTag e1 == ctorTag e2) === (errorCode e1 == errorCode e2)

  --------------------------------------------------------------------------
  describe "LAW-21: renderServiceError 逐字委派下層的 render*" $ do
    it "prop_render_delegates_store: renderServiceError (StoreFailed e) == renderStoreError e" $
      hedgehog $ do
        e <- forAll genStoreError
        renderServiceError (StoreFailed e) === renderStoreError e

    it "prop_render_delegates_workspace: renderServiceError (WorkspaceFailed e) == renderWorkspaceError e" $
      hedgehog $ do
        e <- forAll genWorkspaceError
        renderServiceError (WorkspaceFailed e) === renderWorkspaceError e

    it "prop_render_delegates_registry: 兩個註冊表建構子都逐字委派 renderRegistryError" $
      hedgehog $ do
        e <- forAll genRegistryError
        renderServiceError (RegistryUnavailable e) === renderRegistryError e
        renderServiceError (RegistryLoadFailed e) === renderRegistryError e

  --------------------------------------------------------------------------
  describe "LAW-22: renderServiceError 恆非空" $
    it "prop_render_service_error_nonempty" $
      hedgehog $ do
        e <- forAll genServiceError
        T.null (renderServiceError e) === False

  --------------------------------------------------------------------------
  describe "EX-21: 四個建構子的 errorCode 表(驗收標準 6)" $
    it "test_error_code_table" $ do
      let e1 = VaultMarkerMissing "/x"
          e2 = HubNotFound "/y"
          e3 = RegistryDirMissing "/z"
      map
        errorCode
        [StoreFailed e1, WorkspaceFailed e2, RegistryUnavailable e3, RegistryLoadFailed e3]
        `shouldBe` ["store_failed", "workspace_failed", "registry_unavailable", "registry_load_failed"]

  --------------------------------------------------------------------------
  describe "EX-22: StoreFailed 的訊息委派(驗收標準 7)" $
    it "test_render_store_failed_example" $ do
      let e = VaultMarkerMissing "/x/.aapms/config.toml"
      renderServiceError (StoreFailed e) `shouldBe` renderStoreError e

  --------------------------------------------------------------------------
  describe "EX-23: 兩個註冊表建構子的訊息相同,code 相異" $
    it "test_registry_constructors_same_message_different_code" $ do
      let e = RegistryDirMissing "/r"
      renderServiceError (RegistryUnavailable e) `shouldBe` renderServiceError (RegistryLoadFailed e)
      errorCode (RegistryUnavailable e) `shouldNotBe` errorCode (RegistryLoadFailed e)
