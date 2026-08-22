-- | T5:'StoryFlow.Workshop.Session' 的 JSON round-trip。
module StoryFlow.Workshop.SessionJsonSpec (spec) where

import Data.Aeson (decode, eitherDecode, encode)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.List (isInfixOf)
import Data.Text (Text)
import StoryFlow.Core.Id (Id, parseId)
import StoryFlow.Core.Meta (Timeline (..))
import StoryFlow.Llm (Message (..), Role (..))
import StoryFlow.Workshop.Session (Session (..), StageDraft (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "Session" $ do
    it "encode -> decode round-trip 相等,wsOwner = Nothing 時 owner 鍵不出現" $ do
      let s = baseSession {wsOwner = Nothing}
          bytes = encode s
      bytes `containsKey` "owner" `shouldBe` False
      decode bytes `shouldBe` Just s

    it "wsOwner = Just _ 時 owner 鍵出現,round-trip 相等" $ do
      let s = baseSession {wsOwner = Just (idOf "ent-11111111")}
          bytes = encode s
      bytes `containsKey` "owner" `shouldBe` True
      decode bytes `shouldBe` Just s

    it "wsHistory 的三種 Role 都能正確編解碼且互不混淆" $ do
      let s =
            baseSession
              { wsHistory =
                  [ Message System "系統提示"
                  , Message User "使用者輸入"
                  , Message Assistant "模型回覆"
                  ]
              }
      decode (encode s) `shouldBe` Just s

  describe "StageDraft" $ do
    it "sdTimeline = Nothing 時 encode 不含 timeline 鍵,round-trip 仍是 Nothing" $ do
      let d = baseDraft {sdTimeline = Nothing}
          bytes = encode d
      bytes `containsKey` "timeline" `shouldBe` False
      decode bytes `shouldBe` Just d

    it "sdTimeline 兩鍵皆有值時 timeline 鍵出現且內容正確,round-trip 相等" $ do
      let d = baseDraft {sdTimeline = Just (Timeline (Just "崩塌前後") (Just 3))}
          bytes = encode d
      bytes `containsKey` "timeline" `shouldBe` True
      decode bytes `shouldBe` Just d
      case eitherDecode bytes :: Either String StageDraft of
        Right parsed -> sdTimeline parsed `shouldBe` Just (Timeline (Just "崩塌前後") (Just 3))
        Left err -> expectationFailure err

    it "sdTimeline 只有 order 時 round-trip 相等,佐證沿用 Core.Json 的 Timeline 實例" $ do
      let d = baseDraft {sdTimeline = Just (Timeline Nothing (Just 3))}
      decode (encode d) `shouldBe` Just d

-- fixture --------------------------------------------------------------------

baseSession :: Session
baseSession =
  Session
    { wsId = "wksp-00000001"
    , wsType = "character"
    , wsConstraints = [idOf "ent-abcdef01"]
    , wsStages = ["定位", "外貌與舉止"]
    , wsCurrent = 0
    , wsHistory = []
    , wsOwner = Nothing
    , wsPending = [baseDraft]
    , wsCommitted = []
    }

baseDraft :: StageDraft
baseDraft =
  StageDraft
    { sdTitle = "外貌"
    , sdSummary = "..."
    , sdBody = "..."
    , sdTags = ["外觀"]
    , sdTimeline = Nothing
    }

idOf :: Text -> Id
idOf s = case parseId s of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

-- | 檢查編碼後的 JSON 是否含有某個鍵(用引號界定,避免 "ownerId" 之類的字首命中)。
containsKey :: LBS.ByteString -> String -> Bool
containsKey bytes key = ("\"" <> key <> "\":") `isInfixOf` LBS8.unpack bytes
