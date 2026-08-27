-- | conflict-detection/F004 T4:合流的兩個純函式。
--
-- 這一檔__不碰 Vault__ ——去重、合併與排序全部是純函式,能在沒有索引的情況下
-- 逐條驗。需要真的開 Vault 的部分在 "Aapms.Conflict.PipelineSpec"。
module Aapms.Conflict.MergeSpec (spec) where

import Data.Text (Text)
import Aapms.Conflict.Fixtures
import Aapms.Conflict.Pipeline
import Aapms.Conflict.Types
import Aapms.Core.Id (renderId)
import Aapms.Core.Meta (Meta (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "mergeContextHits 依 metaId 去重" $ do
    it "同一個片段兩層都命中時合成一筆" $
      -- 「既被作者標了 contradicts、又被關鍵詞撈到」對使用者來說是一筆事實的
      -- 兩個側面,不是兩筆待辦。
      length (mergeContextHits [graphHit "ent-1001", retrHit "ent-1001" 0.8 "命中的那一段"])
        `shouldBe` 1

    it "xhVia 取層級較前的那一筆(graph 勝 retrieval),兩種輸入順序都一樣" $ do
      let merged = mergeContextHits [graphHit "ent-1001", retrHit "ent-1001" 0.8 "片段"]
          flipped = mergeContextHits [retrHit "ent-1001" 0.8 "片段", graphHit "ent-1001"]
      map xhVia merged `shouldBe` [ByGraph graphEvidence]
      map xhVia flipped `shouldBe` [ByGraph graphEvidence]

    it "xhSnippet 取來自 ByRetrieval 的那一筆(FTS5 真正命中的那一段)" $ do
      -- 第 1 層的 snippet 是退化成 summary 的,第 2 層的才是命中的原文。
      let merged = mergeContextHits [graphHit "ent-1001", retrHit "ent-1001" 0.8 "……織紋……"]
          flipped = mergeContextHits [retrHit "ent-1001" 0.8 "……織紋……", graphHit "ent-1001"]
      map xhSnippet merged `shouldBe` ["……織紋……"]
      map xhSnippet flipped `shouldBe` ["……織紋……"]

    it "兩筆都不是 retrieval 時保留既有的 snippet" $
      map xhSnippet (mergeContextHits [graphHit "ent-1001", graphHit "ent-1001"])
        `shouldBe` ["總結"]

    it "不同 id 不合併" $
      map ident (mergeContextHits [graphHit "ent-1001", retrHit "ent-1002" 0.8 "片段"])
        `shouldBe` ["ent-1001", "ent-1002"]

  describe "sortContextHits 的三段鍵" $ do
    it "graph 全部排在 retrieval 之前(第 1 層是事實)" $
      map layerOf (sortContextHits [retrHit "ent-1002" 0.99 "s", graphHit "ent-1001"])
        `shouldBe` ["graph", "retrieval"]

    it "同層依分數遞減" $
      map ident
        ( sortContextHits
            [retrHit "ent-1001" 0.3 "s", retrHit "ent-1002" 0.9 "s", retrHit "ent-1003" 0.6 "s"]
        )
        `shouldBe` ["ent-1002", "ent-1003", "ent-1001"]

    it "同分依 id 字典序(第三鍵讓輸出成為全序)" $
      map ident
        ( sortContextHits
            [retrHit "ent-1003" 0.5 "s", retrHit "ent-1001" 0.5 "s", retrHit "ent-1002" 0.5 "s"]
        )
        `shouldBe` ["ent-1001", "ent-1002", "ent-1003"]

    it "ByGraph 之間也是全序:分數一律取 0,由 id 決勝" $
      -- ByGraph 沒有分數(它是事實,不是程度),所以第二鍵對它恆等,
      -- 全序完全靠第三鍵撐住。
      map ident (sortContextHits [graphHit "ent-1003", graphHit "ent-1001", graphHit "ent-1002"])
        `shouldBe` ["ent-1001", "ent-1002", "ent-1003"]

  describe "全序:打亂輸入不改變輸出" $
    it "六種排列的 mergeContextHits 結果逐筆相同" $ do
      let base =
            [ graphHit "ent-2001"
            , retrHit "ent-1001" 0.9 "甲"
            , retrHit "ent-1002" 0.9 "乙"
            ]
          expected = mergeContextHits base
      mapM_ (\p -> mergeContextHits p `shouldBe` expected) (permutations3 base)

  describe "空輸入" $
    it "空清單回空清單" $
      mergeContextHits [] `shouldBe` []

-- 樣本 -------------------------------------------------------------------------

-- | 第 1 層的命中:snippet 已經退化成 summary('metaOf' 的 summary 就是標題)。
graphHit :: Text -> ContextHit
graphHit i = ContextHit (metaOf i "總結") "總結" (ByGraph graphEvidence)

retrHit :: Text -> Double -> Text -> ContextHit
retrHit i s snip = ContextHit (metaOf i "總結") snip (ByRetrieval s)

ident :: ContextHit -> Text
ident = renderId . metaId . xhMeta

layerOf :: ContextHit -> Text
layerOf = layerTag . xhVia

-- | 三元素的全部排列。自己寫一份而不是拉 @Data.List.permutations@:
-- 那個函式的輸出順序不是字典序,測試失敗時看不出是哪一種排列出的問題。
permutations3 :: [a] -> [[a]]
permutations3 [a, b, c] = [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
permutations3 xs = [xs]
