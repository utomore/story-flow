-- | T9(llm-workshop-mcp/F004 對照):工作坊三條路由端到端可用。
--
-- 仿 "StoryFlow.Server.HandlerSpec" T9:以 warp 起臨時伺服器 + @servant-client@,
-- 對每條路由各跑一次成功案例,外加 @workshop_session_not_found@ 的錯誤案例。
-- @step@\/@commit@ 需要一個本機的假 OpenAI 相容端點:測試自建 warp 假伺服器,
-- 把臨時 Vault 的 @.storyflow\/config.toml@ 指過去(見
-- "StoryFlow.Server.Fixtures" 的 'withServerDir' 註解——'Env' 延遲取得,第一個
-- 請求送出前寫檔就來得及)。
module StoryFlow.Server.WorkshopHandlerSpec (spec) where

import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types.Status (status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Servant.Client (ClientEnv)
import StoryFlow.Api (WorkshopCommitResp (..), WorkshopStartReq (..), WorkshopStepReq (..), WorkshopStepResp (..))
import StoryFlow.Server.Fixtures
import StoryFlow.Workshop (Session (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "workshop 的每條路由" $ do
  it "POST /workshop 開一個新工作坊,stages 來自型別註冊表" $ withServer $ \env -> do
    s <- runC env (cWorkshopStart api (WorkshopStartReq "character-fragment" []))
    wsType s `shouldBe` "character-fragment"
    wsStages s `shouldBe` ["定位", "外貌與舉止", "動機與過往", "關係網"]
    wsCurrent s `shouldBe` 0

  it "POST /workshop/:id/step 把回覆解析成 pending,並回給人看的那段文字" $
    withWorkshopServer draftReply $ \env -> do
      s0 <- runC env (cWorkshopStart api (WorkshopStartReq "character-fragment" []))
      r <- runC env (cWorkshopStep api (wsId s0) (WorkshopStepReq "使用者輸入"))
      wssReply r `shouldBe` draftReply
      wsPending (wssSession r) `shouldSatisfy` (not . null)
      length (wsHistory (wssSession r)) `shouldBe` 2

  it "POST /workshop/:id/commit 把 pending 寫進圖譜,回主體 + 片段" $
    withWorkshopServer draftReply $ \env -> do
      s0 <- runC env (cWorkshopStart api (WorkshopStartReq "character-fragment" []))
      stepped <- runC env (cWorkshopStep api (wsId s0) (WorkshopStepReq "使用者輸入"))
      r <- runC env (cWorkshopCommit api (wsId (wssSession stepped)))
      wcrEntities r `shouldSatisfy` (not . null)
      wsOwner (wcrSession r) `shouldSatisfy` isJust
      wsCurrent (wcrSession r) `shouldBe` 1
      wsPending (wcrSession r) `shouldBe` []

  describe "狀態碼" $
    it "不存在的 session id → 404 workshop_session_not_found" $ withServer $ \env -> do
      r <- runE env (cWorkshopStep api "wksp-00000000" (WorkshopStepReq "x"))
      statusOf r `shouldBe` Just 404
      codeOf r `shouldBe` Just "workshop_session_not_found"

-- 底稿 -------------------------------------------------------------------------

-- | 模型的回覆(給人看)+ 一段合法的 @StageDraft@ JSON——與
-- @workshop\/test\/StoryFlow\/Workshop\/StepSpec.hs@ 的 @draftReply@ 同一種寫法。
draftReply :: Text
draftReply =
  T.unlines
    [ "以下是這個階段可以定案的草稿。"
    , "```json"
    , "[{\"title\":\"外貌\",\"summary\":\"銀灰短髮\",\"body\":\"銀灰短髮剪到耳際……\",\"tags\":[\"外觀\"]}]"
    , "```"
    ]

-- | 起一個本機的假 OpenAI 相容端點,再起伺服器並把它的 @[llm]@ 段指過去。
withWorkshopServer :: Text -> (ClientEnv -> IO a) -> IO a
withWorkshopServer reply act =
  withLlmStub reply $ \port ->
    withServerDir $ \dir env -> do
      appendLlmConfig dir port
      act env

withLlmStub :: Text -> (Int -> IO a) -> IO a
withLlmStub reply act = Warp.testWithApplication (pure (stubApp reply)) act

stubApp :: Text -> Wai.Application
stubApp reply _req respond =
  respond $
    Wai.responseLBS status200 [("Content-Type", "application/json")] (chatCompletion reply)

chatCompletion :: Text -> LBS.ByteString
chatCompletion content =
  encode $
    object
      [ "id" .= ("chatcmpl-stub" :: Text)
      , "object" .= ("chat.completion" :: Text)
      , "created" .= (1755648000 :: Int)
      , "model" .= ("qwen2.5-14b-instruct" :: Text)
      , "choices"
          .= [ object
                 [ "index" .= (0 :: Int)
                 , "finish_reason" .= ("stop" :: Text)
                 , "message" .= object ["role" .= ("assistant" :: Text), "content" .= content]
                 ]
             ]
      ]

-- | 把一段 @[llm]@ 附到臨時 Vault 的 @.storyflow\/config.toml@ 後面,指向本機
-- stub 的埠。與 @llm\/test\/StoryFlow\/Llm\/Fixtures.hs@ 的 @appendConfig@
-- 同一份寫法(本測試套件不依賴 @storyflow-store@,路徑用字面組)。
appendLlmConfig :: FilePath -> Int -> IO ()
appendLlmConfig dir port = do
  let fp = dir </> ".storyflow" </> "config.toml"
  old <- TE.decodeUtf8 <$> BS.readFile fp
  BS.writeFile
    fp
    ( TE.encodeUtf8
        ( old
            <> T.unlines
              [ ""
              , "[llm]"
              , "base_url = \"http://127.0.0.1:" <> T.pack (show port) <> "/v1\""
              , "model = \"qwen2.5-14b-instruct\""
              ]
        )
    )
