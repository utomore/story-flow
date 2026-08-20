-- | T7:四種失敗情境各自落到__不同__的建構子。
--
-- 這是契約卡驗收標準 3 的全部內容:'LlmError' 要能區分「連不上服務」與「模型回了
-- 但格式不對」。四條測試打的都是真的 HTTP ——「連不上服務」這件事沒辦法用純函式
-- 假裝出來,而它正是地端優先場景最常發生的那一個錯誤。
module StoryFlow.Llm.ErrorClassSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Llm
import StoryFlow.Llm.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  -- (a) 連線被拒。withDeadPort 的前提由 StubSpec 釘住,不是「大概沒人在那個埠上」。
  describe "(a) 連線被拒" $
    it "→ LlmUnavailable" $
      withDeadPort $ \port -> do
        client <- newLlmClient (stubConfig port)
        r <- chat client [Message User "嗨"]
        r `shouldSatisfy` isUnavailable

  -- (b) 逾時。lcTimeout 150 ms vs stub 睡 800 ms:差距夠大,慢機器上也不會偶發地
  -- 「剛好沒逾時」,而測試實際只花 150 ms。
  describe "(b) 逾時" $
    it "→ LlmUnavailable" $
      withStub okStub {stubDelayMs = 800} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h)) {lcTimeout = 150, lcRetries = 0}
        r <- chat client [Message User "嗨"]
        r `shouldSatisfy` isUnavailable

  -- (c) 非 2xx。parseRequest 產生的 Request 其 checkResponse 是 no-op,所以這裡
  -- 不會有例外,狀態碼是客戶端自己看出來的。
  describe "(c) 非 2xx" $ do
    it "500 → LlmHttpStatus 500" $
      withStub okStub {stubStatus = 500, stubBody = "boom"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        chat client [Message User "嗨"] >>= \case
          Left (LlmHttpStatus code _) -> code `shouldBe` 500
          other -> expectationFailure ("預期 LlmHttpStatus 500,得到 " <> show other)

    it "401 → LlmHttpStatus 401,並帶得出回應內文" $
      withStub okStub {stubStatus = 401, stubBody = "unauthorized"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        chat client [Message User "嗨"] >>= \case
          Left (LlmHttpStatus code body) -> do
            code `shouldBe` 401
            body `shouldSatisfy` T.isInfixOf "unauthorized"
          other -> expectationFailure ("預期 LlmHttpStatus 401,得到 " <> show other)

  -- (d) 2xx 但形狀不對。重試不會讓它變對,所以它與 (a)(b) 必須是不同的建構子。
  describe "(d) 200 但形狀不對" $ do
    it "body 是 {\"ok\":true} → LlmBadResponse" $
      withStub okStub {stubBody = "{\"ok\":true}"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        r <- chat client [Message User "嗨"]
        r `shouldSatisfy` isBadResponse

    -- 合法 JSON、合法欄位,但沒有任何回覆:消費者拿不到 Text。
    it "body 是 {\"choices\":[]} → LlmBadResponse" $
      withStub okStub {stubBody = "{\"choices\":[]}"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        r <- chat client [Message User "嗨"]
        r `shouldSatisfy` isBadResponse

    it "body 根本不是 JSON → LlmBadResponse" $
      withStub okStub {stubBody = "<html>502 Bad Gateway</html>"} $ \h -> do
        client <- newLlmClient (stubConfig (stubPort h))
        r <- chat client [Message User "嗨"]
        r `shouldSatisfy` isBadResponse

isUnavailable :: Either LlmError T.Text -> Bool
isUnavailable = \case
  Left (LlmUnavailable _) -> True
  _ -> False

isBadResponse :: Either LlmError T.Text -> Bool
isBadResponse = \case
  Left (LlmBadResponse _) -> True
  _ -> False
