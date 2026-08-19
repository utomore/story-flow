-- | T2:輸入型別。
module StoryFlow.Conflict.OptsSpec (spec) where

import StoryFlow.Conflict.Fixtures (idOf)
import StoryFlow.Conflict.Types
import Test.Hspec

spec :: Spec
spec = describe "預設值對應 ADR-007 的約束" $ do
  it "defaultConflictOpts 的四個欄位是 20 / False / Nothing / 2" $ do
    coTopN defaultConflictOpts `shouldBe` 20
    coExpandBody defaultConflictOpts `shouldBe` False
    coTimelineWindow defaultConflictOpts `shouldBe` Nothing
    coGraphDepth defaultConflictOpts `shouldBe` 2

  -- 空清單不是「忘了填」而是合法輸入:沒有已知引用時仍然跑得了第 2、3 層。
  it "Draft 的 drRefs 允許空清單,那是合法輸入" $ do
    let d = Draft "琳達在崩塌後回到埃提亞" []
    drRefs d `shouldBe` []
    drText d `shouldBe` "琳達在崩塌後回到埃提亞"

  it "drRefs 有值時原樣保留" $ do
    drRefs (Draft "草稿" [idOf "ent-7f3a", idOf "ent-8b20"])
      `shouldBe` [idOf "ent-7f3a", idOf "ent-8b20"]
