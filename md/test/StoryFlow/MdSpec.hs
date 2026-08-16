module StoryFlow.MdSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Core (coreVersion)
import StoryFlow.Md (mdVersion)
import Test.Hspec

spec :: Spec
spec = describe "storyflow-md 骨架" $ do
  it "mdVersion 非空" $
    T.null mdVersion `shouldBe` False

  it "可 import storyflow-core,證明 md → core 的依賴方向已接上" $
    coreVersion `shouldBe` mdVersion
