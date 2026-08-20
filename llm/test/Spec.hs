module Main (main) where

import qualified StoryFlow.Llm.CabalSpec
import qualified StoryFlow.Llm.ClientSpec
import qualified StoryFlow.Llm.ConfigSpec
import qualified StoryFlow.Llm.ErrorClassSpec
import qualified StoryFlow.Llm.ErrorSpec
import qualified StoryFlow.Llm.RetrySpec
import qualified StoryFlow.Llm.StubSpec
import qualified StoryFlow.LlmSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 門面 StoryFlow.Llm" StoryFlow.LlmSpec.spec
    describe "T2 LlmError 與兩個渲染器" StoryFlow.Llm.ErrorSpec.spec
    describe "T5 LlmConfig 與 [llm] 段的解析" StoryFlow.Llm.ConfigSpec.spec
    describe "T6 chat 的成功路徑與送出去的請求" StoryFlow.Llm.ClientSpec.spec
    describe "T7 chat 的錯誤分類" StoryFlow.Llm.ErrorClassSpec.spec
    describe "T8 重試" StoryFlow.Llm.RetrySpec.spec
    describe "T9 測試底稿自己的契約" StoryFlow.Llm.StubSpec.spec
    describe "T10 套件邊界" StoryFlow.Llm.CabalSpec.spec
