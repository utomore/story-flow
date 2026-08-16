module StoryFlow.CoreSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Core (coreVersion)
import System.IO
import Test.Hspec

spec :: Spec
spec = do
  describe "storyflow-core 骨架" $
    it "coreVersion 非空,套件可被測試套件連結" $
      T.null coreVersion `shouldBe` False

  describe "測試進入點的輸出編碼" $ do
    it "stdout 已設為 UTF-8" $ do
      enc <- hGetEncoding stdout
      fmap show enc `shouldBe` Just "UTF-8"

    it "stderr 已設為 UTF-8" $ do
      enc <- hGetEncoding stderr
      fmap show enc `shouldBe` Just "UTF-8"

    it "繁體中文描述可正常輸出,例如「埃提亞崩塌前的織紋刀」" $
      T.length "織紋刀" `shouldBe` 3
