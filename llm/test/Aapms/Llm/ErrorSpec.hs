-- | T2:'LlmError' 的兩個渲染器。
--
-- 「訊息說出下一步」是設計上的要求,而要求要__測得到__才守得住:對
-- 'LlmConfigMissing' 而言,可測的形式就是訊息裡同時出現「哪個檔案」與
-- 「加什麼段」。
module Aapms.Llm.ErrorSpec (spec) where

import Data.Char (isLower)
import Data.List (nub)
import qualified Data.Text as T
import Aapms.Llm.Error
import Test.Hspec

spec :: Spec
spec = do
  describe "llmErrorCode" $ do
    it "五個建構子的代碼互不重複" $ do
      let codes = map llmErrorCode samples
      length (nub codes) `shouldBe` length samples

    it "全部是 snake_case" $
      mapM_
        (\e -> (llmErrorCode e, T.all snakeChar (llmErrorCode e)) `shouldBe` (llmErrorCode e, True))
        samples

    it "代碼逐字釘住(上層要拿它做翻譯,不能隨訊息文字改動)" $
      map llmErrorCode samples
        `shouldBe` [ "llm_unavailable"
                   , "llm_http_status"
                   , "llm_bad_response"
                   , "llm_config_missing"
                   , "llm_config_invalid"
                   ]

  describe "renderLlmError" $ do
    it "每一則都非空" $
      mapM_
        (\e -> (llmErrorCode e, T.null (renderLlmError e)) `shouldBe` (llmErrorCode e, False))
        samples

    -- 「不猜地端預設值」這條裁定的價值全在這一則訊息上:使用者要看得出
    -- 「你還沒設定」,而不是「連線失敗」。
    it "LlmConfigMissing 說得出檔案與要加的段" $ do
      let msg = renderLlmError LlmConfigMissing
      msg `shouldSatisfy` T.isInfixOf ".storyflow/config.toml"
      msg `shouldSatisfy` T.isInfixOf "[llm]"

    it "LlmUnavailable 的訊息帶得出細節,並指向 base_url" $ do
      let msg = renderLlmError (LlmUnavailable "ConnectionFailure")
      msg `shouldSatisfy` T.isInfixOf "ConnectionFailure"
      msg `shouldSatisfy` T.isInfixOf "base_url"

    it "LlmHttpStatus 帶得出狀態碼" $
      renderLlmError (LlmHttpStatus 401 "unauthorized") `shouldSatisfy` T.isInfixOf "401"

    it "LlmBadResponse 指向 /v1 那一層(那才是這個錯的下一步)" $
      renderLlmError (LlmBadResponse "key not found") `shouldSatisfy` T.isInfixOf "/v1"

samples :: [LlmError]
samples =
  [ LlmUnavailable "連線被拒"
  , LlmHttpStatus 500 "boom"
  , LlmBadResponse "形狀不對"
  , LlmConfigMissing
  , LlmConfigInvalid "缺少必填鍵 `model`"
  ]

snakeChar :: Char -> Bool
snakeChar c = isLower c || c == '_'
