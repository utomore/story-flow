-- | T3:'ServiceError' 的兩種輸出。
--
-- 錯誤碼要__兩兩相異__:壓成同一個代碼的兩種失敗,對 Agent 來說就是「不知道
-- 該怎麼重試」。訊息要非空,而 'StoreFailed' 的訊息必須包含 @store@ 那一則
-- 原文——委派而不是重寫,是為了讓兩份訊息不會漂移。
module StoryFlow.Service.ErrorSpec (spec) where

import Data.Char (isLower)
import Data.List (nub)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, IdPrefix (PEnt))
import StoryFlow.Core.Link (Link (..), LinkKind (Contradicts, PartOf))
import StoryFlow.Core.Registry (EntityWarning (..))
import StoryFlow.Core.Tree (TreeError (NoRoot))
import StoryFlow.Md (MdError (..), MdErrorKind (NoFrontmatter))
import StoryFlow.Service
import StoryFlow.Service.Fixtures (idOf, refOf)
import StoryFlow.Store (StoreError (..), renderStoreError)
import StoryFlow.Types.Loader (LoadError (RegistryDirMissing))
import Test.Hspec

spec :: Spec
spec = describe "ServiceError" $ do
  it "每一種錯誤都有非空的繁中訊息" $
    mapM_ (\e -> (e, T.null (renderServiceError e)) `shouldBe` (e, False)) allErrors

  it "errorCode 兩兩相異,而且都是 snake_case" $ do
    let codes = map errorCode allErrors
    length (nub codes) `shouldBe` length codes
    mapM_ (\c -> (c, T.all (\ch -> isLower ch || ch == '_') c) `shouldBe` (c, True)) codes

  it "StoreFailed 往內取 StoreError 的建構子名" $ do
    errorCode (StoreFailed (StaleRevision (idOf "ent-7f3a") 3 4)) `shouldBe` "stale_revision"
    errorCode (StoreFailed (EntityNotFound (idOf "ent-7f3a"))) `shouldBe` "entity_not_found"

  it "StoreFailed 的訊息委派給 renderStoreError,不重寫一遍" $ do
    let e = StaleRevision (idOf "ent-7f3a") 3 4
    renderServiceError (StoreFailed e) `shouldBe` renderStoreError e

  it "ValidationFailed 分得出「新建的實體」與具名的那一個" $ do
    let ws = [MissingRequiredField "character-fragment" "summary"]
    renderServiceError (ValidationFailed Nothing ws)
      `shouldSatisfy` T.isInfixOf "新建的實體"
    renderServiceError (ValidationFailed (Just anId) ws)
      `shouldSatisfy` T.isInfixOf "ent-7f3a"

  it "型別警告三種都有訊息" $
    mapM_
      (\w -> (w, T.null (renderEntityWarning w)) `shouldBe` (w, False))
      [ MissingRequiredField "character-fragment" "summary"
      , LinkNotAllowed "character-fragment" "師承於"
      , UnknownEntityType "character"
      ]

-- | 每個建構子各一個代表值。新增建構子時這裡不補,唯一性測試就會漏掉它
-- ——但編譯器擋不住,所以順序照 'ServiceError' 的宣告排,好對照。
allErrors :: [ServiceError]
allErrors =
  map StoreFailed allStoreErrors
    ++ [ RegistryUnavailable "環境變數指向的目錄不存在"
       , RegistryLoadFailed [RegistryDirMissing "types/registry"]
       , ValidationFailed Nothing [MissingRequiredField "character-fragment" "summary"]
       , UnknownType "不存在的型別"
       , DanglingLinkTarget (refOf "ent-0000")
       , CrossVaultUnsupported (refOf "shared-lore:ent-0000")
       , LevelTreeInvalid (idOf "lvl-3a01") [NoRoot]
       ]

allStoreErrors :: [StoreError]
allStoreErrors =
  [ VaultNotFound ""
  , VaultConfigInvalid "cfg" "壞了"
  , VaultAlreadyExists "root"
  , EntityNotFound anId
  , StaleRevision anId 3 4
  , IdCollision PEnt
  , FileReadFailed "f" "壞了"
  , FileWriteFailed "f" "壞了"
  , IndexUpdateFailed "f" "壞了"
  , ParseFailed "f" [MdError "f" 1 NoFrontmatter]
  , ReferencedBy anId [(anId, Link PartOf (refOf "ent-7f3a") Nothing)]
  , NotAFileMain anId
  , NotAFragment anId
  , NodeDepthExceeded anId 7
  , CannotRemoveRootNode anId
  , LinkNotFound anId Contradicts (refOf "ent-7f3a")
  , FileAlreadyExists "f"
  , TreeInvalid "f" [NoRoot]
  , RegistryDirUnknown "sketch"
  , SqliteError "壞了"
  ]

anId :: Id
anId = idOf "ent-7f3a"
