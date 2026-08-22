-- | T8:'StoryFlow.Workshop.Stages.startWorkshop'。
module StoryFlow.Workshop.StartSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, parseId)
import StoryFlow.Core.Registry (EntityTypeSpec (..))
import StoryFlow.Service
import StoryFlow.Workshop.Error (WorkshopError (..))
import StoryFlow.Workshop.Fixtures (runS, withCustomVault, withWorkshopVault)
import StoryFlow.Workshop.Session (Session (..))
import StoryFlow.Workshop.Stages (startWorkshop)
import Test.Hspec

spec :: Spec
spec = do
  it "對真實型別(character-fragment,stages 非空)成功建立 session" $
    withWorkshopVault $ \env -> do
      result <- runService env (startWorkshop "character-fragment" [])
      case result of
        Right (Right session) -> do
          specs <- runS env listEntityTypes
          case [s | s <- specs, etsKey s == "character-fragment"] of
            [spec_] -> do
              wsStages session `shouldBe` etsStages spec_
              wsCurrent session `shouldBe` 0
              wsHistory session `shouldBe` []
              wsPending session `shouldBe` []
              wsCommitted session `shouldBe` []
            other -> expectationFailure ("預期恰一筆 character-fragment 宣告,拿到 " <> show (length other))
        other -> expectationFailure ("預期外層 Right (Right _),拿到 " <> show other)

  it "型別不存在時外層回 Left (UnknownType _)" $
    withWorkshopVault $ \env -> do
      result <- runService env (startWorkshop "does-not-exist" [])
      case result of
        Left (UnknownType t) -> t `shouldBe` "does-not-exist"
        other -> expectationFailure ("預期 Left (UnknownType _),拿到 " <> show other)

  it "硬約束 id 不存在時外層回 Left (StoreFailed _),errorCode 為 entity_not_found" $
    withWorkshopVault $ \env -> do
      result <- runService env (startWorkshop "character-fragment" [missingId])
      case result of
        Left e@(StoreFailed _) -> errorCode e `shouldBe` "entity_not_found"
        other -> expectationFailure ("預期 Left (StoreFailed _),拿到 " <> show other)

  it "型別存在但 etsStages 為空時內層回 Left (WsNoStages _)" $
    withCustomVault emptyStageTypeToml $ \env -> do
      result <- runService env (startWorkshop "empty-stage-type" [])
      case result of
        Right (Left (WsNoStages ty)) -> ty `shouldBe` "empty-stage-type"
        other -> expectationFailure ("預期 Right (Left (WsNoStages _)),拿到 " <> show other)

missingId :: Id
missingId = case parseId "ent-ffffffff" of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

emptyStageTypeToml :: Text
emptyStageTypeToml =
  T.unlines
    [ "key  = \"empty-stage-type\""
    , "name = \"空階段型別\""
    , "dir  = \"characters\""
    , ""
    , "[[fields]]"
    , "name = \"summary\""
    , "required = false"
    , "hint = \"測試用\""
    ]
