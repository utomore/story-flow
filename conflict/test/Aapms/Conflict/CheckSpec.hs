-- | conflict-detection/F006 T2 \/ T3:三層合流的去重與排序,以及 crNotes 三種
-- 純函式來源。
--
-- 這一檔__不碰 Vault__ ——去重、排序、三個 note 建構子全部是純函式
-- ("Aapms.Conflict.MergeSpec" 對 @mergeContextHits@ \/ @sortContextHits@ 是
-- 同一種做法)。需要真的開 Vault 的部分在 "Aapms.Conflict.CheckEnvSpec"。
module Aapms.Conflict.CheckSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Conflict.Fixtures
import Aapms.Conflict.Pipeline
import Aapms.Conflict.Types
import Aapms.Core.Id (renderId)
import Aapms.Core.Link (LinkKind (Contradicts, Supersedes))
import Test.Hspec

spec :: Spec
spec = do
  describe "合流的去重與排序" $ do
    it "同一個 target 的兩條 graph 證據(contradicts + supersedes)不被合併" $ do
      let a = graphHitOn "ent-91cc" Contradicts
          b = graphHitOn "ent-91cc" Supersedes
      length (mergeConflictHits [a, b]) `shouldBe` 2

    it "同一個 target 的 retrieval + judge 合併成一筆且留下 judge(reason 是模型原話、snippet 是 judge 那一筆)" $ do
      let r = retrievalHit 0.8 "ent-1001"
          j = judgeHit 0.9 "ent-1001"
      mergeConflictHits [r, j] `shouldBe` [j]
      mergeConflictHits [j, r] `shouldBe` [j]

    it "排序結果逐筆等於 [graph…, retrieval 高分, retrieval 低分, judge…]" $ do
      let g = graphHitOn "ent-3000" Contradicts
          r1 = retrievalHit 0.9 "ent-1001"
          r2 = retrievalHit 0.3 "ent-1002"
          j = judgeHit 0.5 "ent-2000"
      mergeConflictHits [r2, j, g, r1] `shouldBe` [g, r1, r2, j]

    it "同分同層時依 chTarget 字典序" $ do
      let r1 = retrievalHit 0.5 "ent-1003"
          r2 = retrievalHit 0.5 "ent-1001"
          r3 = retrievalHit 0.5 "ent-1002"
      map chTarget (mergeConflictHits [r1, r2, r3])
        `shouldBe` [idOf "ent-1001", idOf "ent-1002", idOf "ent-1003"]

    it "打亂輸入順序跑兩次,輸出逐筆相同(全序)" $ do
      let base =
            [ graphHitOn "ent-3000" Contradicts
            , retrievalHit 0.9 "ent-1001"
            , retrievalHit 0.9 "ent-1002"
            , judgeHit 0.4 "ent-2000"
            ]
          expected = mergeConflictHits base
      mapM_ (\p -> mergeConflictHits p `shouldBe` expected) (permutations4 base)

  describe "crNotes 的三種來源" $ do
    it "unlinkedNote [] == Nothing" $
      unlinkedNote [] `shouldBe` Nothing

    it "unlinkedNote 非空時 rnCode == graph_unlinked_refs,rnDetail 含兩個 renderId" $
      case unlinkedNote [idOf "ent-a001", idOf "ent-a002"] of
        Just (ReportNote code detail) -> do
          code `shouldBe` "graph_unlinked_refs"
          detail `shouldSatisfy` T.isInfixOf (renderId (idOf "ent-a001"))
          detail `shouldSatisfy` T.isInfixOf (renderId (idOf "ent-a002"))
        Nothing -> expectationFailure "預期 Just,實際 Nothing"

    it "budgetNote 在候選 <= coJudgeN 或 coJudgeN <= 0 時是 Nothing" $ do
      budgetNote defaultConflictOpts {coJudgeN = 5} 5 `shouldBe` Nothing
      budgetNote defaultConflictOpts {coJudgeN = 5} 3 `shouldBe` Nothing
      budgetNote defaultConflictOpts {coJudgeN = 0} 12 `shouldBe` Nothing

    it "budgetNote 超過時 rnCode == judge_budget,detail 說得出「不是判定為沒有矛盾」" $
      case budgetNote defaultConflictOpts {coJudgeN = 5} 12 of
        Just (ReportNote code detail) -> do
          code `shouldBe` "judge_budget"
          detail `shouldSatisfy` T.isInfixOf "不是判定為沒有矛盾"
        Nothing -> expectationFailure "預期 Just,實際 Nothing"

    it "suggestionNote 對只有 graph / 只有 retrieval 的命中回 Nothing" $ do
      suggestionNote [graphHitOn "ent-1001" Contradicts] `shouldBe` Nothing
      suggestionNote [retrievalHit 0.8 "ent-1001"] `shouldBe` Nothing

    it "suggestionNote 對有 judge 命中的回 link_suggested,detail 含 contradicts 與該 target 的 id" $
      case suggestionNote [judgeHit 0.9 "ent-8b20"] of
        Just (ReportNote code detail) -> do
          code `shouldBe` "link_suggested"
          detail `shouldSatisfy` T.isInfixOf "contradicts"
          detail `shouldSatisfy` T.isInfixOf (renderId (idOf "ent-8b20"))
        Nothing -> expectationFailure "預期 Just,實際 Nothing"

    it "已經有 graph 命中的 target 不出現在建議裡" $ do
      let hits = [graphHitOn "ent-8b20" Contradicts, judgeHit 0.9 "ent-8b20", judgeHit 0.9 "ent-9999"]
      case suggestionNote hits of
        Just (ReportNote _ detail) -> do
          detail `shouldSatisfy` T.isInfixOf (renderId (idOf "ent-9999"))
          detail `shouldSatisfy` (not . T.isInfixOf (renderId (idOf "ent-8b20")))
        Nothing -> expectationFailure "預期 Just,實際 Nothing"

-- 樣本 -------------------------------------------------------------------------

graphHitOn :: Text -> LinkKind -> ConflictHit
graphHitOn target kind =
  ConflictHit
    { chTarget = idOf target
    , chLayer = ByGraph (GraphEvidence (idOf "ent-5c00") kind (refOf target))
    , chReason = "你引用的 ent-5c00 與 " <> target <> " 已標記矛盾"
    , chSnippet = Nothing
    }

-- | 全部排列。自己寫一份而不是拉 'Data.List.permutations':那個函式的輸出順序
-- 不是字典序,測試失敗時看不出是哪一種排列出的問題;這裡改用「挑一個當開頭,
-- 遞迴排列剩下的」這個直接了當的定義。
permutations4 :: [a] -> [[a]]
permutations4 [] = [[]]
permutations4 xs = [x : rest | (x, xs') <- picks xs, rest <- permutations4 xs']
  where
    picks [] = []
    picks (y : ys) = (y, ys) : [(z, y : zs) | (z, zs) <- picks ys]
