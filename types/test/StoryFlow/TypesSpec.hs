module StoryFlow.TypesSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Core (coreVersion)
import StoryFlow.Types (typesVersion)
import Test.Hspec

spec :: Spec
spec = describe "storyflow-types 骨架" $ do
  it "typesVersion 非空" $
    T.null typesVersion `shouldBe` False

  it "可 import storyflow-core,證明 types → core 的依賴方向已接上" $
    coreVersion `shouldBe` typesVersion
