-- | T10:'Aapms.Workshop.Stages.stepWorkshop'。
module Aapms.Workshop.StepSpec (spec) where

import qualified Data.ByteString as BS
import Data.Aeson (FromJSON (..), decode, withObject, (.:))
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Meta (Timeline (..))
import Aapms.Llm (LlmError (..))
import Aapms.Service (Env, ServiceError (..), runService, vaultRoot)
import Aapms.Workshop.Error (WorkshopError (..))
import Aapms.Workshop.Fixtures
import Aapms.Workshop.Session (Session (..), StageDraft (..))
import Aapms.Workshop.Stages (startWorkshop, stepWorkshop)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  it "回覆含合法 JSON 陣列時,wsPending 等於解析結果,wsHistory 增加兩則,快照被更新" $
    withWorkshopVault $ \env -> withStub (okStub {stubBody = chatCompletion draftReply}) $ \h -> do
      session0 <- freshSession env
      client <- stubClient (stubPort h)
      result <- runService env (stepWorkshop client session0 "使用者輸入")
      case result of
        Right (Right (session1, reply)) -> do
          reply `shouldBe` draftReply
          wsPending session1 `shouldBe` expectedDrafts
          length (wsHistory session1) `shouldBe` length (wsHistory session0) + 2
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "回覆是純自然語言(無 JSON)時,wsPending 不變,wsHistory 與快照仍更新" $
    withWorkshopVault $ \env -> withStub (okStub {stubBody = chatCompletion plainReply}) $ \h -> do
      session0 <- freshSession env
      client <- stubClient (stubPort h)
      result <- runService env (stepWorkshop client session0 "使用者輸入")
      case result of
        Right (Right (session1, reply)) -> do
          reply `shouldBe` plainReply
          wsPending session1 `shouldBe` wsPending session0
          length (wsHistory session1) `shouldBe` length (wsHistory session0) + 2
        other -> expectationFailure ("預期 Right (Right _),拿到 " <> show other)

  it "withDeadPort 時外層回 Right (Left (WsLlmFailed (LlmUnavailable _))),快照不被覆寫" $
    withWorkshopVault $ \env -> withDeadPort $ \port -> do
      session0 <- freshSession env
      snapshotBefore <- readSnapshot env (wsId session0)
      client <- deadClient port
      result <- runService env (stepWorkshop client session0 "使用者輸入")
      case result of
        Right (Left (WsLlmFailed (LlmUnavailable _))) -> pure ()
        other -> expectationFailure ("預期 Right (Left (WsLlmFailed (LlmUnavailable _))),拿到 " <> show other)
      snapshotAfter <- readSnapshot env (wsId session0)
      snapshotAfter `shouldBe` snapshotBefore

  it "wsCurrent = length wsStages 時外層回 Right (Left (WsStagesExhausted _)),且不呼叫模型" $
    withWorkshopVault $ \env -> withStub okStub $ \h -> do
      session0 <- freshSession env
      let exhausted = session0 {wsCurrent = length (wsStages session0)}
      client <- stubClient (stubPort h)
      result <- runService env (stepWorkshop client exhausted "使用者輸入")
      case result of
        Right (Left (WsStagesExhausted sid)) -> sid `shouldBe` wsId exhausted
        other -> expectationFailure ("預期 Right (Left (WsStagesExhausted _)),拿到 " <> show other)
      stubRequests h `shouldReturn` 0

  it "接線測試:system message 裡找得到 etsFields 的欄位名與 hint 文字" $
    withCustomVault customToml $ \env -> withStub okStub $ \h -> do
      startResult <- runService env (startWorkshop "workshop-step-test" [])
      session0 <- case startResult of
        Right (Right s) -> pure s
        other -> fail ("預期 startWorkshop 成功,拿到 " <> show other)
      client <- stubClient (stubPort h)
      _ <- runService env (stepWorkshop client session0 "使用者輸入")
      mRR <- stubLast h
      case mRR of
        Nothing -> expectationFailure "stub 沒收到任何請求"
        Just rr -> case decode (rrBody rr) of
          Nothing -> expectationFailure "請求 body 不是合法 JSON"
          Just body -> do
            let sysTexts = [rmContent m | m <- reqMessages body, rmRole m == "system"]
                sysText = T.concat sysTexts
            sysText `shouldSatisfy` ("aliases" `T.isInfixOf`)
            sysText `shouldSatisfy` ("接線測試提示文字" `T.isInfixOf`)

  it "wsType 對應的型別在呼叫前被移除,外層回 Left (UnknownType _)" $
    withWorkshopVaultDir $ \dir -> do
      session0 <-
        withCustomRegistryDir removableTypeToml $ \reg1 ->
          withCustomRegistryEnv dir reg1 $ \env1 -> do
            startResult <- runService env1 (startWorkshop "workshop-removable-type" [])
            case startResult of
              Right (Right s) -> pure s
              other -> fail ("預期 startWorkshop 成功,拿到 " <> show other)
      withCustomRegistryDir otherTypeToml $ \reg2 ->
        withCustomRegistryEnv dir reg2 $ \env2 -> do
          client <- deadClient 1
          result <- runService env2 (stepWorkshop client session0 "使用者輸入")
          case result of
            Left (UnknownType t) -> t `shouldBe` "workshop-removable-type"
            other -> expectationFailure ("預期 Left (UnknownType _),拿到 " <> show other)

-- fixture ----------------------------------------------------------------------

freshSession :: Env -> IO Session
freshSession env = do
  result <- runService env (startWorkshop "character-fragment" [])
  case result of
    Right (Right s) -> pure s
    other -> fail ("建立測試用 session 失敗:" <> show other)

readSnapshot :: Env -> Text -> IO BS.ByteString
readSnapshot env sid = do
  root <- orDie =<< runService env vaultRoot
  BS.readFile (root </> ".storyflow" </> "workshops" </> (T.unpack sid <> ".json"))

draftReply :: Text
draftReply =
  T.unlines
    [ "以下是這個階段可以定案的草稿。"
    , "```json"
    , "[{\"title\":\"外貌\",\"summary\":\"...\",\"body\":\"...\",\"tags\":[\"外觀\"],"
        <> "\"timeline\":{\"label\":\"崩塌前後\",\"order\":3}},"
        <> "{\"title\":\"舉止\",\"summary\":\"...\",\"body\":\"...\",\"tags\":[]}]"
    , "```"
    ]

expectedDrafts :: [StageDraft]
expectedDrafts =
  [ StageDraft "外貌" "..." "..." ["外觀"] (Just (Timeline (Just "崩塌前後") (Just 3)))
  , StageDraft "舉止" "..." "..." [] Nothing
  ]

plainReply :: Text
plainReply = "這一輪只是聊聊,還沒有想清楚,沒有附任何 JSON。"

customToml :: Text
customToml =
  T.unlines
    [ "key    = \"workshop-step-test\""
    , "name   = \"工作坊接線測試型別\""
    , "dir    = \"characters\""
    , "stages = [\"階段一\"]"
    , ""
    , "[[fields]]"
    , "name = \"aliases\""
    , "required = true"
    , "hint = \"接線測試提示文字\""
    ]

removableTypeToml :: Text
removableTypeToml =
  T.unlines
    [ "key    = \"workshop-removable-type\""
    , "name   = \"可移除型別\""
    , "dir    = \"characters\""
    , "stages = [\"階段一\"]"
    ]

otherTypeToml :: Text
otherTypeToml =
  T.unlines
    [ "key    = \"workshop-other-type\""
    , "name   = \"其他型別\""
    , "dir    = \"characters\""
    , "stages = [\"階段一\"]"
    ]

-- 請求 body 的最小解碼型別 -----------------------------------------------------

newtype ReqBody = ReqBody {reqMessages :: [ReqMessage]}

data ReqMessage = ReqMessage {rmRole :: Text, rmContent :: Text}

instance FromJSON ReqBody where
  parseJSON = withObject "body" $ \o -> ReqBody <$> o .: "messages"

instance FromJSON ReqMessage where
  parseJSON = withObject "message" $ \o -> ReqMessage <$> o .: "role" <*> o .: "content"
