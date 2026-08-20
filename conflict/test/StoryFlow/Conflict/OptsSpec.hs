-- | T2:輸入型別。
module StoryFlow.Conflict.OptsSpec (spec) where

import StoryFlow.Conflict.Fixtures (idOf)
import StoryFlow.Conflict.Types
import Test.Hspec

spec :: Spec
spec = describe "預設值對應 ADR-007 的約束" $ do
  it "defaultConflictOpts 的五個欄位是 20 / 5 / False / Nothing / 2" $ do
    coTopN defaultConflictOpts `shouldBe` 20
    coJudgeN defaultConflictOpts `shouldBe` 5
    coExpandBody defaultConflictOpts `shouldBe` False
    coTimelineWindow defaultConflictOpts `shouldBe` Nothing
    coGraphDepth defaultConflictOpts `shouldBe` 2

  -- conflict-detection/F005 T1:coJudgeN 是獨立於 coTopN 的第 3 層候選預算旋鈕,
  -- 兩個旋鈕不是同一個值,調其中一個不動另一個。
  it "coJudgeN 是獨立於 coTopN 的預算旋鈕" $ do
    coJudgeN defaultConflictOpts `shouldNotBe` coTopN defaultConflictOpts
    let o = defaultConflictOpts {coJudgeN = 2}
    coJudgeN o `shouldBe` 2
    coTopN o `shouldBe` coTopN defaultConflictOpts

  -- 空清單不是「忘了填」而是合法輸入:沒有已知引用時仍然跑得了第 2、3 層。
  it "Draft 的 drRefs 允許空清單,那是合法輸入" $ do
    let d = Draft "琳達在崩塌後回到埃提亞" []
    drRefs d `shouldBe` []
    drText d `shouldBe` "琳達在崩塌後回到埃提亞"

  it "drRefs 有值時原樣保留" $ do
    drRefs (Draft "草稿" [idOf "ent-7f3a", idOf "ent-8b20"])
      `shouldBe` [idOf "ent-7f3a", idOf "ent-8b20"]
