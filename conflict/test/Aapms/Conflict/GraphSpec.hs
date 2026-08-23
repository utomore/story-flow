-- | F002:衝突偵測第 1 層(圖遍歷)。
--
-- 圖一律用 core 的 @buildGraph@ 從 'Meta' 蓋出來,不自己 @M.fromList@:
-- 本 test-suite 刻意不加 @containers@ 相依,而反向索引的鍵可以從桶裡的
-- @linkTarget@ 復原(見 'revBuckets'),@Set@ 的成員檢查走 'toList' 就夠。
module Aapms.Conflict.GraphSpec (spec) where

import Data.Foldable (toList)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Conflict.Fixtures (idOf, metaOf, refOf)
import Aapms.Conflict.Graph
import Aapms.Conflict.Types
import Aapms.Core.Graph (LinkGraph, buildGraph, supersededSet)
import Aapms.Core.Id (Id, Ref (..), localRef)
import Aapms.Core.Link (Link (..), LinkKind (..), coreLinkKinds)
import Aapms.Core.Meta (Meta (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "T1 revIndex:反向索引只認未限定 vault 的目標" $ do
    it "跨 Vault 的目標不進索引,本地的進" $ do
      let rix = revIndex mixedG
      map fst (revBuckets rix) `shouldBe` [idOf "ent-b2"]

    it "同一目標被多個來源指到時全部收齊,且依來源保序" $ do
      let rix = revIndex sharedTargetG
      map fst (bucketOf rix (idOf "ent-b2"))
        `shouldBe` [idOf "ent-a1", idOf "ent-d4"]

    it "桶裡放的是關聯原文,不是翻轉後的方向" $ do
      let rix = revIndex sharedTargetG
      map (linkTarget . snd) (bucketOf rix (idOf "ent-b2"))
        `shouldBe` [localRef (idOf "ent-b2"), localRef (idOf "ent-b2")]

  describe "T2 contradictionFindings:矛盾雙向各命中一次" $ do
    it "正向:起點 a1 命中 b2,證據是關聯原文" $ do
      contradictionFindings contraG (revIndex contraG) (idOf "ent-a1")
        `shouldBe` [ GraphFinding
                       { gfStart = idOf "ent-a1"
                       , gfTarget = idOf "ent-b2"
                       , gfEvidence =
                           GraphEvidence (idOf "ent-a1") Contradicts (localRef (idOf "ent-b2"))
                       , gfHops = 1
                       , gfTruncated = False
                       , gfNote = Just "對雙親死因的敘述不一致"
                       }
                   ]

    it "反向:起點 b2 也命中 a1,證據不翻轉方向" $ do
      contradictionFindings contraG (revIndex contraG) (idOf "ent-b2")
        `shouldBe` [ GraphFinding
                       { gfStart = idOf "ent-b2"
                       , gfTarget = idOf "ent-a1"
                       , gfEvidence =
                           GraphEvidence (idOf "ent-a1") Contradicts (localRef (idOf "ent-b2"))
                       , gfHops = 1
                       , gfTruncated = False
                       , gfNote = Just "對雙親死因的敘述不一致"
                       }
                   ]

    it "兩個方向的 gfHops 都是 1、都沒有截斷" $ do
      let fs =
            contradictionFindings contraG (revIndex contraG) (idOf "ent-a1")
              ++ contradictionFindings contraG (revIndex contraG) (idOf "ent-b2")
      map gfHops fs `shouldBe` [1, 1]
      map gfTruncated fs `shouldBe` [False, False]

    it "自我關聯不產出命中" $
      contradictionFindings contraG (revIndex contraG) (idOf "ent-c3") `shouldBe` []

    it "跨 Vault 目標的 geTo 保留 refVault" $ do
      let fs = contradictionFindings contraG (revIndex contraG) (idOf "ent-d4")
      map (geTo . gfEvidence) fs
        `shouldBe` [Ref (Just "shared-lore") (idOf "ent-e5")]
      map gfTarget fs `shouldBe` [idOf "ent-e5"]

    it "supersedes 不會混進矛盾命中" $
      contradictionFindings chainG (revIndex chainG) (idOf "ent-c3") `shouldBe` []

  describe "T3 supersessionFindings:取代鏈只回末端" $ do
    it "depth = 2 時起點 c3 只回鏈末端 a1,gfHops = 2、附註不合併" $
      supersessionFindings 2 (revIndex chainG) (idOf "ent-c3")
        `shouldBe` [ GraphFinding
                       { gfStart = idOf "ent-c3"
                       , gfTarget = idOf "ent-a1"
                       , gfEvidence =
                           GraphEvidence (idOf "ent-a1") Supersedes (localRef (idOf "ent-c3"))
                       , gfHops = 2
                       , gfTruncated = False
                       , gfNote = Nothing
                       }
                   ]

    it "depth = 1 時停在 b2 並標 gfTruncated,單跳保留 linkNote" $
      supersessionFindings 1 (revIndex chainG) (idOf "ent-c3")
        `shouldBe` [ GraphFinding
                       { gfStart = idOf "ent-c3"
                       , gfTarget = idOf "ent-b2"
                       , gfEvidence =
                           GraphEvidence (idOf "ent-b2") Supersedes (localRef (idOf "ent-c3"))
                       , gfHops = 1
                       , gfTruncated = True
                       , gfNote = Just "第二版設定"
                       }
                   ]

    it "depth = 0 不產出任何命中" $
      supersessionFindings 0 (revIndex chainG) (idOf "ent-c3") `shouldBe` []

    it "沒有人取代它時回空" $
      supersessionFindings 5 (revIndex chainG) (idOf "ent-a1") `shouldBe` []

    it "成環不無窮迴圈,起點自己不進結果" $ do
      let fs = supersessionFindings 5 (revIndex cycleG) (idOf "ent-a1")
      map gfTarget fs `shouldBe` [idOf "ent-b2"]
      map gfHops fs `shouldBe` [1]

    it "交叉驗證:回報的被取代端全部落在 core 的 supersededSet 內" $ do
      let superseded = toList (supersededSet chainG)
          fs =
            concatMap
              (supersessionFindings 5 (revIndex chainG))
              [idOf "ent-a1", idOf "ent-b2", idOf "ent-c3"]
      fs `shouldNotBe` []
      mapM_ (\f -> (geTo (gfEvidence f) `elem` superseded) `shouldBe` True) fs

    it "交叉驗證(反向):沒被取代的 a1 不在 supersededSet 內,本層也不回報它" $ do
      let superseded = toList (supersededSet chainG)
      (localRef (idOf "ent-a1") `elem` superseded) `shouldBe` False
      supersessionFindings 5 (revIndex chainG) (idOf "ent-a1") `shouldBe` []

  describe "T4 renderGraphReason:五種句型" $ do
    it "矛盾(無附註)" $
      renderGraphReason (contraF Nothing)
        `shouldBe` "你引用的 ent-7f3c 與 ent-91cc 已標記矛盾"

    it "矛盾(有附註)" $
      renderGraphReason (contraF (Just "對雙親死因的敘述不一致"))
        `shouldBe` "你引用的 ent-7f3c 與 ent-91cc 已標記矛盾:對雙親死因的敘述不一致"

    it "取代(一跳)" $
      renderGraphReason (supersedeF 1 False)
        `shouldBe` "你引用的 ent-91cc 已被 ent-7f3c 取代"

    it "取代(多跳)" $
      renderGraphReason (supersedeF 2 False)
        `shouldBe` "你引用的 ent-91cc 已被 ent-7f3c 取代(經 2 跳)"

    it "取代(截斷)" $
      renderGraphReason (supersedeF 2 True)
        `shouldBe` "你引用的 ent-91cc 已被 ent-7f3c 取代(已達深度上限 2,可能還有更新的版本)"

    it "跨 Vault 目標顯示成 vault:id" $
      renderGraphReason
        (contraF Nothing) {gfEvidence = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "shared-lore:ent-91cc")}
        `shouldBe` "你引用的 ent-7f3c 與 shared-lore:ent-91cc 已標記矛盾"

    it "反向的矛盾命中讀起來與正向對稱" $
      renderGraphReason
        (contraF Nothing) {gfStart = idOf "ent-91cc", gfTarget = idOf "ent-7f3c"}
        `shouldBe` "你引用的 ent-91cc 與 ent-7f3c 已標記矛盾"

  describe "T5 dedupeFindings / sortFindings:去重與排序是確定的" $ do
    it "同一條證據由兩個起點抵達只留一筆,取最小跳數" $ do
      let far = mkF "ent-a1" "ent-a1" Contradicts "ent-b2" 3
          near = mkF "ent-c3" "ent-a1" Contradicts "ent-b2" 1
      dedupeFindings [far, near] `shouldBe` [near]
      dedupeFindings [near, far] `shouldBe` [near]

    it "同跳數時取起點 id 字典序較小者" $ do
      let late = mkF "ent-c3" "ent-a1" Contradicts "ent-b2" 1
          early = mkF "ent-a1" "ent-a1" Contradicts "ent-b2" 1
      dedupeFindings [late, early] `shouldBe` [early]
      dedupeFindings [early, late] `shouldBe` [early]

    it "同一 target 的矛盾與取代是兩件事,兩筆都留下" $ do
      let c = mkF "ent-a1" "ent-b2" Contradicts "ent-b2" 1
          s = mkF "ent-a1" "ent-b2" Supersedes "ent-b2" 1
      length (dedupeFindings [c, s]) `shouldBe` 2

    it "LinkKind 的 derived Ord 就是詞彙表順序(排序第二鍵的假設)" $ do
      sort coreLinkKinds `shouldBe` coreLinkKinds
      compare Contradicts Supersedes `shouldBe` LT

    it "排序鍵:跳數 → Contradicts 先於 Supersedes → id 字典序" $ do
      let fA = mkF "ent-a1" "ent-a1" Contradicts "ent-a1" 2
          fB = mkF "ent-a1" "ent-b2" Supersedes "ent-b2" 1
          fC = mkF "ent-a1" "ent-c3" Contradicts "ent-e5" 1
          fD = mkF "ent-a1" "ent-d4" Contradicts "ent-c3" 1
      sortFindings [fA, fB, fC, fD] `shouldBe` [fD, fC, fB, fA]
      sortFindings [fD, fC, fB, fA] `shouldBe` [fD, fC, fB, fA]
      sortFindings [fC, fA, fD, fB] `shouldBe` [fD, fC, fB, fA]

    it "打亂起點順序後 graphHits 的輸出不變" $ do
      let starts = [idOf "ent-a1", idOf "ent-b2", idOf "ent-c3", idOf "ent-d4"]
      graphHits defaultConflictOpts bigG (reverse starts)
        `shouldBe` graphHits defaultConflictOpts bigG starts

  describe "T6 graphHits / unlinkedRefs:門面的輸出契約" $ do
    it "每一筆 chLayer 都是 ByGraph、chSnippet 恆為 Nothing、chReason 非空" $ do
      let hits = graphHits defaultConflictOpts bigG [idOf "ent-a1", idOf "ent-c3"]
      hits `shouldNotBe` []
      mapM_ (\h -> isByGraph (chLayer h) `shouldBe` True) hits
      map chSnippet hits `shouldBe` map (const Nothing) hits
      mapM_ (\h -> T.null (chReason h) `shouldBe` False) hits

    it "重複的起點只算一次" $
      graphHits defaultConflictOpts bigG [idOf "ent-a1", idOf "ent-a1", idOf "ent-c3"]
        `shouldBe` graphHits defaultConflictOpts bigG [idOf "ent-a1", idOf "ent-c3"]

    it "空圖或空起點都回空清單" $ do
      graphHits defaultConflictOpts (buildGraph []) [idOf "ent-a1"] `shouldBe` []
      graphHits defaultConflictOpts bigG [] `shouldBe` []

    it "coGraphDepth 只關掉取代命中,矛盾命中照樣出來" $ do
      let noDepth = defaultConflictOpts {coGraphDepth = 0}
          kinds hs = [k | ByGraph e <- map chLayer hs, let k = geKind e]
      kinds (graphHits noDepth bigG [idOf "ent-a1", idOf "ent-c3"])
        `shouldBe` [Contradicts]
      kinds (graphHits defaultConflictOpts bigG [idOf "ent-a1", idOf "ent-c3"])
        `shouldBe` [Contradicts, Supersedes]

    it "unlinkedRefs 只列零關聯的起點,保序去重" $
      unlinkedRefs
        mixedG
        [ idOf "ent-c3" -- 是鍵,但關聯清單是空的
        , idOf "ent-a1" -- 有出向關聯
        , idOf "ent-f6" -- 根本不在圖上
        , idOf "ent-c3" -- 重複
        , idOf "ent-b2" -- 有入向關聯
        , idOf "ent-d4" -- 有出向(跨 Vault)關聯
        , idOf "ent-e5" -- 只被跨 Vault 參照指到,不算本地入向
        ]
        `shouldBe` [idOf "ent-c3", idOf "ent-f6", idOf "ent-e5"]

    it "空起點清單回空清單" $
      unlinkedRefs mixedG [] `shouldBe` []

-- ── 圖 fixture ────────────────────────────────────────────────────────────────

-- | 一個片段,關聯直接掛在 'metaLinks' 上;圖由 core 的 @buildGraph@ 蓋出來。
node :: Text -> [Link] -> Meta
node i ls = (metaOf i i) {metaLinks = ls}

con, sup :: Text -> Maybe Text -> Link
con t n = Link Contradicts (refOf t) n
sup t n = Link Supersedes (refOf t) n

-- | 本地目標 + 跨 Vault 目標 + 一個是鍵但沒有任何關聯的片段。
mixedG :: LinkGraph
mixedG =
  buildGraph
    [ node "ent-a1" [con "ent-b2" Nothing]
    , node "ent-c3" []
    , node "ent-d4" [con "shared-lore:ent-e5" Nothing]
    ]

-- | 同一個目標被兩個來源指到。
sharedTargetG :: LinkGraph
sharedTargetG =
  buildGraph
    [ node "ent-a1" [con "ent-b2" Nothing]
    , node "ent-d4" [con "ent-b2" Nothing]
    ]

-- | 矛盾用的圖:一條正常標註、一條自我關聯、一條跨 Vault。
contraG :: LinkGraph
contraG =
  buildGraph
    [ node "ent-a1" [con "ent-b2" (Just "對雙親死因的敘述不一致")]
    , node "ent-c3" [con "ent-c3" Nothing]
    , node "ent-d4" [con "shared-lore:ent-e5" Nothing]
    ]

-- | 取代鏈:a1 取代 b2、b2 取代 c3。
chainG :: LinkGraph
chainG =
  buildGraph
    [ node "ent-a1" [sup "ent-b2" (Just "改寫了結局")]
    , node "ent-b2" [sup "ent-c3" (Just "第二版設定")]
    , node "ent-c3" []
    ]

-- | 成環的取代標註,兩邊互相取代。
cycleG :: LinkGraph
cycleG =
  buildGraph
    [ node "ent-a1" [sup "ent-b2" Nothing]
    , node "ent-b2" [sup "ent-a1" Nothing]
    ]

-- | 同時有矛盾與取代的圖,門面測試用。
bigG :: LinkGraph
bigG =
  buildGraph
    [ node "ent-a1" [con "ent-b2" (Just "設定對不上")]
    , node "ent-d4" [sup "ent-c3" Nothing]
    ]

-- ── GraphFinding fixture ─────────────────────────────────────────────────────

mkF :: Text -> Text -> LinkKind -> Text -> Int -> GraphFinding
mkF start from k target hops =
  GraphFinding
    { gfStart = idOf start
    , gfTarget = idOf target
    , gfEvidence = GraphEvidence (idOf from) k (refOf target)
    , gfHops = hops
    , gfTruncated = False
    , gfNote = Nothing
    }

-- | 文案表的矛盾那兩列:起點就是證據的來源端(正向命中)。
contraF :: Maybe Text -> GraphFinding
contraF n =
  GraphFinding
    { gfStart = idOf "ent-7f3c"
    , gfTarget = idOf "ent-91cc"
    , gfEvidence = GraphEvidence (idOf "ent-7f3c") Contradicts (refOf "ent-91cc")
    , gfHops = 1
    , gfTruncated = False
    , gfNote = n
    }

-- | 文案表的取代那三列:起點是被取代的那一端。
supersedeF :: Int -> Bool -> GraphFinding
supersedeF hops cut =
  GraphFinding
    { gfStart = idOf "ent-91cc"
    , gfTarget = idOf "ent-7f3c"
    , gfEvidence = GraphEvidence (idOf "ent-7f3c") Supersedes (refOf "ent-91cc")
    , gfHops = hops
    , gfTruncated = cut
    , gfNote = Nothing
    }

-- ── 不靠 containers 的觀測輔助 ────────────────────────────────────────────────

-- | 反向索引的桶,附上它的鍵。
--
-- 鍵不必從 @M.keys@ 拿:桶裡每一筆的 @linkTarget@ 指的就是那個鍵,而
-- 'RevIndex' 只收 @refVault == Nothing@ 的目標,所以 @refId@ 一定等於鍵。
-- 'toList' 走的是 'Data.Map' 的 'Foldable' 實例,鍵序遞增。
revBuckets :: RevIndex -> [(Id, [(Id, Link)])]
revBuckets rix =
  [(refId (linkTarget l), b) | b@((_, l) : _) <- toList rix]

bucketOf :: RevIndex -> Id -> [(Id, Link)]
bucketOf rix k = concat [b | (k', b) <- revBuckets rix, k' == k]

isByGraph :: HitLayer -> Bool
isByGraph = \case
  ByGraph _ -> True
  _ -> False
