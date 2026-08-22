-- | T11:測試底稿自己的契約(照抄 F001 的 T9)。
--
-- 'withStub' 起得來、回得出設定好的內文;'withDeadPort' 給的埠__真的__拒絕
-- 連線——透過 'chat' 間接驗證,而不是碰運氣假設「大概沒人在那個埠上」。
module StoryFlow.Workshop.StubSpec (spec) where

import StoryFlow.Llm (LlmError (..), Message (..), Role (..), chat)
import StoryFlow.Workshop.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "withStub" $ do
    it "起得來,chat 透過它拿得到設定好的內文" $
      withStub (okStub {stubBody = chatCompletion "設定好的內文"}) $ \h -> do
        client <- stubClient (stubPort h)
        result <- chat client [Message User "測試"]
        result `shouldBe` Right "設定好的內文"

    it "請求計數從 0 起算,並隨每個請求遞增" $
      withStub okStub $ \h -> do
        client <- stubClient (stubPort h)
        stubRequests h `shouldReturn` 0
        _ <- chat client [Message User "測試"]
        stubRequests h `shouldReturn` 1

    it "記得下路徑,讓路徑斷言有東西可看" $
      withStub okStub $ \h -> do
        client <- stubClient (stubPort h)
        _ <- chat client [Message User "測試"]
        last_ <- stubLast h
        fmap rrPath last_ `shouldBe` Just "/v1/chat/completions"

  describe "withDeadPort" $
    it "給的埠在區塊內透過 chat 間接驗證為連線被拒(LlmUnavailable)" $
      withDeadPort $ \port -> do
        client <- deadClient port
        result <- chat client [Message User "測試"]
        case result of
          Left (LlmUnavailable _) -> pure ()
          other -> expectationFailure ("預期 Left (LlmUnavailable _),拿到 " <> show other)
