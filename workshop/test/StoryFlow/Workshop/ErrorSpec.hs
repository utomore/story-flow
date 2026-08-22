-- | T4:'StoryFlow.Workshop.Error' 的八個建構子與兩個渲染器。
module StoryFlow.Workshop.ErrorSpec (spec) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Llm (LlmError (..), llmErrorCode, renderLlmError)
import StoryFlow.Workshop.Error
import Test.Hspec

spec :: Spec
spec = do
  describe "workshopErrorCode" $ do
    it "八個建構子的 code 互不重複、全為 snake_case" $ do
      let codes = map workshopErrorCode allSamples
      length (nub codes) `shouldBe` length codes
      mapM_ (`shouldSatisfy` isSnakeCase) codes

    it "WsMissingRequiredField 的 code 是 workshop_missing_required_field" $
      workshopErrorCode (WsMissingRequiredField "character" ["timeline"])
        `shouldBe` "workshop_missing_required_field"

    it "WsLlmFailed 對五個 LlmError 建構子都往內取 llmErrorCode" $
      mapM_
        (\e -> workshopErrorCode (WsLlmFailed e) `shouldBe` llmErrorCode e)
        llmErrorSamples

  describe "renderWorkshopError" $ do
    it "每一則都非空" $
      mapM_ ((`shouldNotSatisfy` T.null) . renderWorkshopError) allSamples

    it "WsMissingRequiredField 的訊息同時含型別鍵與每一個缺欄位名" $ do
      let msg = renderWorkshopError (WsMissingRequiredField "character" ["timeline", "aliases"])
      msg `shouldSatisfy` ("character" `T.isInfixOf`)
      msg `shouldSatisfy` ("timeline" `T.isInfixOf`)
      msg `shouldSatisfy` ("aliases" `T.isInfixOf`)

    it "WsLlmFailed 的訊息等於 renderLlmError 的原文,對五個建構子都成立" $
      mapM_
        (\e -> renderWorkshopError (WsLlmFailed e) `shouldBe` renderLlmError e)
        llmErrorSamples

allSamples :: [WorkshopError]
allSamples =
  [ WsSessionNotFound "wksp-deadbeef"
  , WsSnapshotCorrupt "/vault/.storyflow/workshops/wksp-deadbeef.json" "unexpected token"
  , WsSnapshotWriteFailed "/vault/.storyflow/workshops/wksp-deadbeef.json" "permission denied"
  , WsNoStages "character"
  , WsStagesExhausted "wksp-deadbeef"
  , WsNothingToCommit "wksp-deadbeef"
  , WsMissingRequiredField "character" ["timeline"]
  , WsLlmFailed (LlmUnavailable "connection refused")
  ]

llmErrorSamples :: [LlmError]
llmErrorSamples =
  [ LlmUnavailable "connection refused"
  , LlmHttpStatus 401 "unauthorized"
  , LlmBadResponse "missing choices"
  , LlmConfigMissing
  , LlmConfigInvalid "base_url 缺漏"
  ]

isSnakeCase :: Text -> Bool
isSnakeCase t = not (T.null t) && T.all (\c -> c `elem` ['a' .. 'z'] || c == '_') t
