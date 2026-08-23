module Main (main) where

import qualified Aapms.Llm.CabalSpec
import qualified Aapms.Llm.ClientSpec
import qualified Aapms.Llm.ConfigSpec
import qualified Aapms.Llm.ErrorClassSpec
import qualified Aapms.Llm.ErrorSpec
import qualified Aapms.Llm.RetrySpec
import qualified Aapms.Llm.StubSpec
import qualified Aapms.LlmSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 門面 Aapms.Llm" Aapms.LlmSpec.spec
    describe "T2 LlmError 與兩個渲染器" Aapms.Llm.ErrorSpec.spec
    describe "T5 LlmConfig 與 [llm] 段的解析" Aapms.Llm.ConfigSpec.spec
    describe "T6 chat 的成功路徑與送出去的請求" Aapms.Llm.ClientSpec.spec
    describe "T7 chat 的錯誤分類" Aapms.Llm.ErrorClassSpec.spec
    describe "T8 重試" Aapms.Llm.RetrySpec.spec
    describe "T9 測試底稿自己的契約" Aapms.Llm.StubSpec.spec
    describe "T10 套件邊界" Aapms.Llm.CabalSpec.spec
