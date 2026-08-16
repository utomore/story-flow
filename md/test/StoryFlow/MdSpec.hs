module StoryFlow.MdSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Core.Id (IdPrefix (PEnt), renderIdPrefix)
import StoryFlow.Md (mdVersion)
import Test.Hspec

spec :: Spec
spec = describe "storyflow-md 骨架" $ do
  it "mdVersion 非空" $
    T.null mdVersion `shouldBe` False

  -- func-0001 T4:依賴方向的驗證。改用 core 的實際模組(func-0002 已把
  -- StoryFlow.Core 佔位模組移除),意義不變——連結得起來就是接上了。
  it "可 import storyflow-core,證明 md → core 的依賴方向已接上" $
    renderIdPrefix PEnt `shouldBe` "ent"
