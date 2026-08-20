-- | conflict-detection/F003 T5 \/ T6 \/ T7 \/ T10:第 2 層的純函式部件。
--
-- 這一檔__不碰 Vault__:關鍵詞抽取、分數回退、候選合併、timeline 過濾與理由文案
-- 全部是純函式,能在沒有索引的情況下逐條驗。需要真的跑 SQL 的部分在
-- "StoryFlow.Conflict.RetrievalEnvSpec"。
module StoryFlow.Conflict.RetrievalSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Conflict.Fixtures
import StoryFlow.Conflict.Retrieval
import StoryFlow.Conflict.Types
import StoryFlow.Core.Id (Id, renderId)
import StoryFlow.Core.Link (LinkKind (OccursIn, PartOf))
import StoryFlow.Core.Meta (Meta (..), Timeline (..), emptyTimeline)
import Test.Hspec

spec :: Spec
spec = do
  describe "T5 關鍵詞兩路併用" $ do
    describe "matchedNames" $ do
      it "名稱出現在草稿才收" $
        matchedNames sampleIndex "琳達握著織紋刀走進廢墟"
          `shouldBe` ["琳達", "織紋刀"]

      it "單字名稱與空字串不收" $ do
        -- 一個字的名稱在任何一段中文裡都幾乎必然命中,收進來等於雜訊;
        -- 而 T.isInfixOf "" 對任何草稿都成立 —— 那會讓每個片段都變成命中。
        matchedNames [(idOf "ent-1001", ["刀", ""])] "她握著刀" `shouldBe` []
        matchedNames [(idOf "ent-1001", ["刀", "", "織紋刀"])] "她握著織紋刀"
          `shouldBe` ["織紋刀"]

      it "同一個名稱掛在兩個 id 上時只收一次" $
        matchedNames
          [ (idOf "ent-1001", ["織紋刀"])
          , (idOf "ent-1002", ["織紋刀"])
          ]
          "織紋刀還在"
          `shouldBe` ["織紋刀"]

      it "順序沿用 aliasIndex(id 字典序),同一輸入永遠同一輸出" $
        matchedNames sampleIndex "埃提亞崩塌之後,琳達握著織紋刀"
          `shouldBe` ["琳達", "織紋刀", "埃提亞崩塌"]

    describe "segmentDraft" $ do
      it "中文標點與英文空白都是切點" $ do
        segmentDraft "琳達,握著織紋刀。" `shouldBe` ["琳達", "握著織紋刀"]
        segmentDraft "the woven blade" `shouldBe` ["the", "woven", "blade"]

      it "單字片段丟掉" $
        segmentDraft "她 走 了" `shouldBe` []

      it "超長無標點中文切成 4 字塊" $
        segmentDraft "琳達在埃提亞崩塌之後失去雙親"
          `shouldBe` ["琳達在埃", "提亞崩塌", "之後失去", "雙親"]

      it "切完尾巴不足 2 字的丟掉" $
        -- 「琳達在埃提亞崩塌了」是 9 字:切成 4/4/1,最後那個字丟掉
        segmentDraft "琳達在埃提亞崩塌了" `shouldBe` ["琳達在埃", "提亞崩塌"]

      it "恰好 8 字不切,9 字才切" $ do
        segmentDraft "琳達在埃提亞崩塌" `shouldBe` ["琳達在埃提亞崩塌"]
        length (segmentDraft "琳達在埃提亞崩塌後") `shouldBe` 2

      it "去重保序" $
        segmentDraft "織紋 埃提亞 織紋" `shouldBe` ["織紋", "埃提亞"]

    describe "defaultKeywordStrategy" $ do
      it "名稱在前、切詞在後,重複的只留一次" $
        run defaultKeywordStrategy sampleIndex "琳達,握著織紋刀。"
          -- 「琳達」兩路都產得出來,但只出現一次,而且在名稱那一輪的位置
          `shouldBe` ["琳達", "織紋刀", "握著織紋刀"]

      it "總數不超過 maxKeywords" $ do
        let many_ = [(idOf i, [n]) | (i, n) <- zip manyIds manyNames]
            draft = T.concat [n <> "," | n <- manyNames]
            kws = run defaultKeywordStrategy many_ draft
        length manyNames `shouldSatisfy` (> maxKeywords)
        length kws `shouldBe` maxKeywords

  describe "T6 分數取用與候選合併" $ do
    describe "rankFallbackScore" $ do
      it "k = 0 給 0.5,之後遞減" $ do
        rankFallbackScore 0 `shouldBe` 0.5
        map rankFallbackScore [0 .. 4] `shouldSatisfy` strictlyDecreasing

      it "恆 <= 0.5:名次不是相關度,不該壓過真實的 bm25 高分" $
        map rankFallbackScore [0 .. 20] `shouldSatisfy` all (<= 0.5)

    describe "mergeCandidates" $ do
      it "同 id 取最高分,並保留該筆的 snippet 與 origin" $ do
        let merged = mergeCandidates [cand "ent-1001" 0.2 "低分片段" "甲", high]
        merged `shouldBe` [high]

      it "分數相同時取先出現者" $ do
        let first_ = cand "ent-1001" 0.4 "先" "甲"
            second_ = cand "ent-1001" 0.4 "後" "乙"
        mergeCandidates [first_, second_] `shouldBe` [first_]

      it "不同 id 全部保留,且維持第一次出現的順序" $ do
        let a = cand "ent-1003" 0.1 "丙" "丙"
            b = cand "ent-1001" 0.9 "甲" "甲"
            c = cand "ent-1002" 0.5 "乙" "乙"
        map ident (mergeCandidates [a, b, c]) `shouldBe` ["ent-1003", "ent-1001", "ent-1002"]

      it "同 id 的最高分那筆晚出現時,位置仍是第一次出現的位置" $ do
        let a = cand "ent-1003" 0.1 "丙" "丙"
            lowFirst = cand "ent-1001" 0.1 "低" "甲"
        map ident (mergeCandidates [lowFirst, a, high]) `shouldBe` ["ent-1001", "ent-1003"]
        map caScore (mergeCandidates [lowFirst, a, high]) `shouldBe` [0.9, 0.1]

    describe "overFetchLimit" $
      it "撈 topN 的四倍,下限 1" $ do
        overFetchLimit 20 `shouldBe` 80
        overFetchLimit 0 `shouldBe` 1
        overFetchLimit (-5) `shouldBe` 1

  describe "T7 timeline 過濾的四條保留規則" $ do
    it "window = Nothing 時全保留" $
      map (withinWindow Nothing [10]) [timed 10, timed 99, untimed] `shouldBe` [True, True, True]

    it "基準點為空時全保留(不是全部剔除)" $
      -- 沒有基準就不過濾:全部剔除會讓一個沒填 timeline 的 Vault 在使用者加了
      -- --timeline-window 之後靜默回空清單
      map (withinWindow (Just 2) []) [timed 10, timed 99, untimed] `shouldBe` [True, True, True]

    it "候選沒有 tlOrder 時保留(tlLabel 算不出距離)" $
      withinWindow (Just 2) [10] untimed `shouldBe` True

    it "window = 2 且基準 10 時,12 保留、13 剔除" $ do
      withinWindow (Just 2) [10] (timed 12) `shouldBe` True
      withinWindow (Just 2) [10] (timed 8) `shouldBe` True
      withinWindow (Just 2) [10] (timed 13) `shouldBe` False
      withinWindow (Just 2) [10] (timed 7) `shouldBe` False

    it "多個基準點:任一符合即保留" $ do
      withinWindow (Just 1) [10, 40] (timed 41) `shouldBe` True
      withinWindow (Just 1) [10, 40] (timed 25) `shouldBe` False

  describe "conflict-detection/F004 T2 metaSnippet" $ do
    it "summary 非空就取 summary" $
      metaSnippet (summarised "埃提亞的第七織手") `shouldBe` "埃提亞的第七織手"

    it "summary 全為空白時退回 title" $ do
      metaSnippet (summarised "") `shouldBe` "琳達"
      metaSnippet (summarised "   ") `shouldBe` "琳達"
      metaSnippet (summarised "\n\t ") `shouldBe` "琳達"

    it "summary 與 title 皆空時回空字串" $
      metaSnippet ((summarised "") {metaTitle = ""}) `shouldBe` ""

-- 「一跳擴充候選的 caSnippet 與 metaSnippet 逐字相同」這一半在
-- "StoryFlow.Conflict.RetrievalEnvSpec" 驗:expandOneHop 是私有的,而拿真的候選
-- 去比才證明得了「規則只有一份」,在這裡另外組一個假候選只會證明假候選長什麼樣。

  describe "T10 理由文案與兩種輸出轉換" $ do
    it "關鍵詞句型含 renderId 的 id 與加了引號的關鍵詞" $ do
      let r = renderRetrievalReason (cand "ent-1001" 0.8 "……織紋刀……" "織紋刀")
      r `shouldBe` "草稿與 ent-1001 共同出現「織紋刀」"

    it "擴充句型含母候選 id 與 renderLinkKind 的關聯名" $ do
      renderRetrievalReason (expanded "ent-1002" "ent-1001" PartOf)
        `shouldBe` "ent-1002 經 ent-1001 的 partOf 關聯一跳帶入"
      renderRetrievalReason (expanded "ent-1002" "ent-1001" OccursIn)
        `shouldBe` "ent-1002 經 ent-1001 的 occursIn 關聯一跳帶入"

    it "兩種句型都不含「矛盾」" $ do
      -- 第 2 層交出來的是「相關」,不是判斷。把候選講成矛盾,HitLayer 分三層的
      -- 意義就沒了。
      let rs =
            [ renderRetrievalReason (cand "ent-1001" 0.8 "片段" "織紋刀")
            , renderRetrievalReason (expanded "ent-1002" "ent-1001" PartOf)
            ]
      rs `shouldSatisfy` all (not . T.isInfixOf "矛盾")

    it "candidateContextHit 原樣帶出 Meta,xhVia 是 ByRetrieval caScore" $ do
      let c = cand "ent-1001" 0.75 "……織紋刀……" "織紋刀"
          h = candidateContextHit c
      xhMeta h `shouldBe` caMeta c
      xhSnippet h `shouldBe` "……織紋刀……"
      xhVia h `shouldBe` ByRetrieval 0.75

    it "candidateConflictHit 的 chTarget 是 metaId,chSnippet 恆為 Just" $ do
      let c = cand "ent-1001" 0.75 "……織紋刀……" "織紋刀"
          h = candidateConflictHit c
      chTarget h `shouldBe` idOf "ent-1001"
      chLayer h `shouldBe` ByRetrieval 0.75
      chSnippet h `shouldBe` Just "……織紋刀……"
      chReason h `shouldBe` renderRetrievalReason c

-- 底稿 -------------------------------------------------------------------------

run :: KeywordStrategy -> [(Id, [Text])] -> Text -> [Text]
run = runKeywordStrategy

-- | 三筆既有名稱,依 id 字典序 —— 'StoryFlow.Service.aliasIndex' 的輸出形狀。
sampleIndex :: [(Id, [Text])]
sampleIndex =
  [ (idOf "ent-1001", ["琳達", "小琳"])
  , (idOf "ent-1002", ["織紋刀"])
  , (idOf "ent-1003", ["埃提亞崩塌"])
  ]

manyNames :: [Text]
manyNames = [T.pack ("nm" <> show n) | n <- [10 :: Int .. 29]]

manyIds :: [Text]
manyIds = [T.pack ("ent-10" <> pad n) | n <- [10 :: Int .. 29]]
  where
    pad n = let s = show n in replicate (6 - length s) '0' <> s

cand :: Text -> Double -> Text -> Text -> Candidate
cand i s snip kw = Candidate (metaOf i "片段") snip s (FromKeyword kw)

high :: Candidate
high = cand "ent-1001" 0.9 "高分片段" "乙"

expanded :: Text -> Text -> LinkKind -> Candidate
expanded i src k = Candidate (metaOf i "片段") "" 0.4 (FromExpansion (idOf src) k)

ident :: Candidate -> Text
ident = renderId . metaId . caMeta

timed :: Int -> Meta
timed n = (metaOf "ent-1001" "片段") {metaTimeline = Timeline (Just "崩塌前後") (Just n)}

untimed :: Meta
untimed = (metaOf "ent-1001" "片段") {metaTimeline = emptyTimeline}

-- | 標題固定是「琳達」,總結由呼叫端給——'metaSnippet' 的三條分支就靠它區分。
summarised :: Text -> Meta
summarised s = (metaOf "ent-1001" "琳達") {metaSummary = s}

strictlyDecreasing :: [Double] -> Bool
strictlyDecreasing xs = and (zipWith (>) xs (drop 1 xs))
