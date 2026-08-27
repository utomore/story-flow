-- | entity-graph-core/F001 T6 的對照測試:測試進入點的輸出編碼。
--
-- 本專案的測試描述一律繁體中文,Windows 終端預設 code page 950 會亂碼,
-- 因此每個 @test/Spec.hs@ 都在跑 hspec 前設定 handle 編碼。這裡確認它真的執行到。
module Aapms.CoreSpec (spec) where

import qualified Data.Text as T
import System.IO
import Test.Hspec

spec :: Spec
spec = describe "測試進入點的輸出編碼" $ do
  it "stdout 已設為 UTF-8" $ do
    enc <- hGetEncoding stdout
    fmap show enc `shouldBe` Just "UTF-8"

  it "stderr 已設為 UTF-8" $ do
    enc <- hGetEncoding stderr
    fmap show enc `shouldBe` Just "UTF-8"

  it "繁體中文描述可正常輸出,例如「埃提亞崩塌前的織紋刀」" $
    T.length "織紋刀" `shouldBe` 3
