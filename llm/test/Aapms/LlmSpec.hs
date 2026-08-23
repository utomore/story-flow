-- | T1:門面。
--
-- __這個檔案只 import @Aapms.Llm@ 一個模組__(加上測試底稿)就走完
-- @parseLlmConfig@ → @newLlmClient@ → @chat@ 一輪。與
-- @Aapms.Service.FacadeSpec@ 同一種證明:__消費者不必知道套件內部分了幾個
-- 模組__ ——@aapms-workshop@ 與 @conflict-detection@ 第 3 層將來就是這樣用它。
--
-- 底稿的 'sectionOf' 存在的理由也在這裡:@LlmSection@ 來自
-- @aapms-service@,而那個 import 正是這一節要避開的。
module Aapms.LlmSpec (spec) where

import qualified Data.Text as T
import Aapms.Llm
import Aapms.Llm.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  it "只靠門面就走完 設定 → 客戶端 → 對話 一輪" $
    withStub okStub {stubBody = chatCompletion "第七織手。"} $ \h -> do
      let section =
            sectionOf
              [ ("base_url", "http://127.0.0.1:" <> T.pack (show (stubPort h)) <> "/v1")
              , ("model", "qwen2.5-14b-instruct")
              ]
      case parseLlmConfig section of
        Left e -> expectationFailure (T.unpack (renderLlmError e))
        Right cfg -> do
          client <- newLlmClient cfg
          r <- chat client [Message System "你是設定編輯助手", Message User "琳達是誰?"]
          r `shouldBe` Right "第七織手。"

  it "門面帶得出錯誤型別與它的兩個渲染器" $ do
    llmErrorCode LlmConfigMissing `shouldBe` "llm_config_missing"
    renderLlmError LlmConfigMissing `shouldSatisfy` T.isInfixOf "[llm]"

  it "門面帶得出預設常數" $ do
    defaultLlmTimeoutMs `shouldBe` 60000
    defaultLlmRetries `shouldBe` 1

  it "門面帶得出 Role 的三個建構子與 Message 的兩個欄位" $ do
    let m = Message Assistant "好"
    msgRole m `shouldBe` Assistant
    msgContent m `shouldBe` "好"
    map msgRole [Message System "a", Message User "b"] `shouldBe` [System, User]
