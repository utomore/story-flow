-- | T4:命中與報告。
module StoryFlow.Conflict.ReportSpec (spec) where

import StoryFlow.Conflict.Fixtures (graphEvidence, idOf, judgeHit, metaOf, retrievalHit)
import StoryFlow.Conflict.Types
import Test.Hspec

spec :: Spec
spec = describe "三種命中與空報告" $ do
  it "三個 HitLayer 建構子各組得出一筆 ConflictHit" $ do
    let hits =
          [ ConflictHit (idOf "ent-91cc") (ByGraph graphEvidence) "已被標註為矛盾" Nothing
          , retrievalHit 0.82 "ent-4d10"
          , judgeHit 0.91 "ent-5e22"
          ]
    map (layerTag . chLayer) hits `shouldBe` ["graph", "retrieval", "judge"]
    map chTarget hits `shouldBe` [idOf "ent-91cc", idOf "ent-4d10", idOf "ent-5e22"]

  -- 第 1 層命中的是一條關聯,沒有片段可指——這正是 chSnippet 是 Maybe 的理由。
  it "第 1 層的 chSnippet 可為 Nothing,第 2 / 3 層有值" $ do
    chSnippet (ConflictHit (idOf "ent-91cc") (ByGraph graphEvidence) "已被標註為矛盾" Nothing)
      `shouldBe` Nothing
    chSnippet (retrievalHit 0.82 "ent-4d10") `shouldBe` Just "……織紋……"

  -- 撈出來的素材一定有命中的那一段,所以 xhSnippet 不是 Maybe;
  -- 而它直接帶 Meta,呼叫端不必再往返一次。
  it "ContextHit 直接帶 Meta,不只帶 id" $ do
    let h = ContextHit (metaOf "ent-4d10" "崩塌後的埃提亞") "……徵召……" (ByRetrieval 0.7)
    xhMeta h `shouldBe` metaOf "ent-4d10" "崩塌後的埃提亞"
    xhSnippet h `shouldBe` "……徵召……"
    layerTag (xhVia h) `shouldBe` "retrieval"

  it "emptyReport 是空清單、掃過 0 筆、沒跑第 3 層、crNotes 也是空清單" $ do
    crHits emptyReport `shouldBe` []
    crScanned emptyReport `shouldBe` 0
    crLlmUsed emptyReport `shouldBe` False
    crNotes emptyReport `shouldBe` []

  -- conflict-detection/F005 T1:ReportNote 的兩欄 Show / Eq 可用。
  it "ReportNote 的兩欄可比較" $ do
    let n1 = ReportNote "judge_parse_failed" "這一對沒有判斷結果"
        n2 = ReportNote "judge_parse_failed" "這一對沒有判斷結果"
        n3 = ReportNote "judge_aborted" "尚有 1 對未判斷"
    n1 `shouldBe` n2
    n1 `shouldNotBe` n3
    rnCode n1 `shouldBe` "judge_parse_failed"
    rnDetail n3 `shouldBe` "尚有 1 對未判斷"
