-- | T5:排序約定與層級名稱。
module StoryFlow.Conflict.SortSpec (spec) where

import Data.Text (Text)
import StoryFlow.Conflict.Fixtures (graphEvidence, idOf, judgeHit, retrievalHit)
import StoryFlow.Conflict.Types
import Test.Hspec

spec :: Spec
spec = describe "排序約定" $ do
  it "混合三層的清單排成 Graph → Retrieval → Judge" $ do
    let mixed = [judgeHit 0.5 "ent-5e22", retrievalHit 0.3 "ent-4d10", graphHit "ent-91cc"]
    map (layerTag . chLayer) (sortHits mixed) `shouldBe` ["graph", "retrieval", "judge"]

  it "同層依分數遞減" $ do
    let mixed =
          [ retrievalHit 0.3 "ent-0001"
          , judgeHit 0.4 "ent-0002"
          , retrievalHit 0.9 "ent-0003"
          , judgeHit 0.95 "ent-0004"
          , retrievalHit 0.6 "ent-0005"
          ]
    map chTarget (sortHits mixed)
      `shouldBe` map idOf ["ent-0003", "ent-0005", "ent-0001", "ent-0004", "ent-0002"]

  -- 第 1 層是事實不是程度,沒有分數可排;穩定排序讓它們維持傳入的順序,
  -- 而不是靠一個假分數決定誰先誰後。
  it "第 1 層的多筆命中維持傳入順序" $ do
    let hits = [graphHit "ent-0001", graphHit "ent-0002", graphHit "ent-0003"]
    map chTarget (sortHits hits) `shouldBe` map idOf ["ent-0001", "ent-0002", "ent-0003"]

  it "空清單排完還是空清單" $ sortHits [] `shouldBe` []

  it "layerTag 對三個建構子回 graph / retrieval / judge" $ do
    layerTag (ByGraph graphEvidence) `shouldBe` "graph"
    layerTag (ByRetrieval 0.82) `shouldBe` "retrieval"
    layerTag (ByJudge 0.91) `shouldBe` "judge"

-- | 第 1 層的命中,只差目標 id。
graphHit :: Text -> ConflictHit
graphHit i = ConflictHit (idOf i) (ByGraph graphEvidence) "已被標註為矛盾" Nothing
