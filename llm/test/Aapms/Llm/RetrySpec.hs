-- | T8:重試__只發生在 'LlmUnavailable'__。
--
-- 斷言看的是 stub 的請求計數,不是耗時——「重試了幾次」這件事只有被呼叫端數得
-- 出來,而計時斷言在慢機器上必然變成偶發失敗。
module Aapms.Llm.RetrySpec (spec) where

import Aapms.Llm
import Aapms.Llm.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  -- (a) 逾時是可重試的:總嘗試 = 1 + lcRetries。
  it "逾時 + lcRetries = 1 → LlmUnavailable,且 stub 收到 2 個請求" $
    withStub okStub {stubDelayMs = 800} $ \h -> do
      client <- newLlmClient (stubConfig (stubPort h)) {lcTimeout = 150, lcRetries = 1}
      r <- chat client [Message User "嗨"]
      r `shouldSatisfy` isUnavailable
      stubRequests h `shouldReturn` 2

  -- (b) 格式錯不重試:模型回了但形狀不對,重試也不會變對。lcRetries 開到 3
  -- 就是要讓「有重試」與「沒重試」的計數差得夠明顯(4 vs 1)。
  it "壞 JSON + lcRetries = 3 → LlmBadResponse,且 stub 只收到 1 個請求" $
    withStub okStub {stubBody = "{\"ok\":true}"} $ \h -> do
      client <- newLlmClient (stubConfig (stubPort h)) {lcRetries = 3}
      r <- chat client [Message User "嗨"]
      r `shouldSatisfy` isBadResponse
      stubRequests h `shouldReturn` 1

  -- (c) lcRetries = 0 是合法設定,意思是「不重試」。
  it "逾時 + lcRetries = 0 → stub 只收到 1 個請求" $
    withStub okStub {stubDelayMs = 800} $ \h -> do
      client <- newLlmClient (stubConfig (stubPort h)) {lcTimeout = 150, lcRetries = 0}
      r <- chat client [Message User "嗨"]
      r `shouldSatisfy` isUnavailable
      stubRequests h `shouldReturn` 1

  -- 非 2xx 通常是設定問題(401 是 api_key、404 是 base_url),重試只是把同一個
  -- 錯誤做四遍。
  it "401 + lcRetries = 2 → stub 只收到 1 個請求" $
    withStub okStub {stubStatus = 401, stubBody = "unauthorized"} $ \h -> do
      client <- newLlmClient (stubConfig (stubPort h)) {lcRetries = 2}
      _ <- chat client [Message User "嗨"]
      stubRequests h `shouldReturn` 1

  -- 成功就停:重試迴圈不該把一次成功的呼叫多送幾遍。
  it "成功時只送 1 個請求" $
    withStub okStub {stubBody = chatCompletion "好"} $ \h -> do
      client <- newLlmClient (stubConfig (stubPort h)) {lcRetries = 2}
      chat client [Message User "嗨"] `shouldReturn` Right "好"
      stubRequests h `shouldReturn` 1

isUnavailable :: Either LlmError t -> Bool
isUnavailable = \case
  Left (LlmUnavailable _) -> True
  _ -> False

isBadResponse :: Either LlmError t -> Bool
isBadResponse = \case
  Left (LlmBadResponse _) -> True
  _ -> False
