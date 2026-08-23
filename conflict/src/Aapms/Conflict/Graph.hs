-- | 衝突偵測第 1 層:順關聯圖找確定性的命中。
--
-- 這一層是 ADR-007 三層中唯一__不需要模型、也不需要檢索__的一層,回答兩個問題:
--
-- * 草稿引用的片段有沒有被標記 @contradicts@(已知矛盾)
-- * 草稿引用的片段有沒有被別的片段 @supersedes@(你正在引用一個已經被推翻的設定)
--
-- 輸出是__事實__而不是判斷——作者自己標註過的關聯——所以每一筆命中的 'HitLayer'
-- 一律是 'ByGraph',並且附上造成命中的那條關聯('GraphEvidence')。
--
-- 本模組是__純函式__:吃一張 "Aapms.Core.Graph" 的 'LinkGraph' 與一組起點 id,
-- 吐 @[ConflictHit]@。不碰 @service@、不碰 @store@、不開索引連線;圖從哪裡來是
-- 呼叫端的事。
--
-- __確定性__是本層的規格而不只是實作性質:同一份輸入永遠得到逐位元組相同的輸出
-- 順序(去重鍵與三層排序鍵見 'dedupeFindings' 與 'sortFindings')。
module Aapms.Conflict.Graph
  ( -- * 門面
    graphHits
  , unlinkedRefs

    -- * 中間結果(供 Pipeline 與測試使用)
  , GraphFinding (..)
  , RevIndex
  , revIndex
  , contradictionFindings
  , supersessionFindings
  , dedupeFindings
  , sortFindings
  , renderGraphReason
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Conflict.Types
  ( ConflictHit (..)
  , ConflictOpts (..)
  , GraphEvidence (..)
  , HitLayer (ByGraph)
  )
import Aapms.Core.Graph (LinkGraph)
import Aapms.Core.Id (Id, Ref (..), localRef, renderId, renderRef)
import Aapms.Core.Link (Link (..), LinkKind (Contradicts, Supersedes))

-- | 目標 id → @[(來源 id, 那條關聯原文)]@。
--
-- 只收 @refVault == Nothing@ 的關聯:純函式不知道自己是哪個 Vault,把
-- @liftgame:ent-7f3a@ 當成本地 @ent-7f3a@ 反查,會在兩個 Vault 的 id 恰好相同時
-- 製造假命中。規則與 "Aapms.Core.Graph" 的 @follow@ 一致
-- (@isNothing (refVault r)@ 才繼續展開)。
type RevIndex = M.Map Id [(Id, Link)]

-- | 建反向索引。'LinkGraph' 只在來源端存關聯(ADR-002),而第 1 層的兩個問題
-- 「誰標記了與我矛盾」「誰取代了我」都得反著問。
--
-- __不__依 'LinkKind' 過濾:過濾是 'contradictionFindings' /
-- 'supersessionFindings' 各自的事,而 'unlinkedRefs' 要看的是「有沒有任何關聯」。
revIndex :: LinkGraph -> RevIndex
revIndex g =
  M.fromListWith
    (flip (++))
    [ (refId (linkTarget l), [(src, l)])
    | (src, ls) <- M.toList g
    , l <- ls
    , isNothing (refVault (linkTarget l))
    ]

-- | 一筆命中的完整素材。
--
-- 比 'ConflictHit' 多的三樣東西——起點、跳數、截斷旗標——是去重、排序與理由文案
-- 需要的,壓成 'ConflictHit' 之後就取不回來了。
data GraphFinding = GraphFinding
  { gfStart :: Id
  -- ^ 草稿引用的哪一個片段導出這筆命中
  , gfTarget :: Id
  -- ^ 命中的另一端,對應 'chTarget'
  , gfEvidence :: GraphEvidence
  , gfHops :: Int
  -- ^ 矛盾恆為 1;取代為鏈長
  , gfTruncated :: Bool
  -- ^ 因 @coGraphDepth@ 用盡而停在仍有取代者的節點
  , gfNote :: Maybe Text
  -- ^ 關聯原文的 'linkNote';多跳的取代為 'Nothing'
  }
  deriving stock (Show, Eq)

-- | 第 1 層的矛盾部分:正向 + 反向,固定一跳,不遞移。
--
-- @contradicts@ 語意對稱但只存在來源端,只走正向的話命中率取決於作者當初順手
-- 寫在哪一邊。反向那一半的證據__是關聯原文,不翻轉方向__——方向資訊留在
-- 'GraphEvidence' 裡,理由文案本來就對稱。
--
-- 不遞移:「A 與 B 矛盾、B 與 C 矛盾」推不出「A 與 C 矛盾」,那只會製造假衝突,
-- 因此 @coGraphDepth@ 不作用在這裡。自我關聯略過——那是資料錯誤,不是衝突。
contradictionFindings :: LinkGraph -> RevIndex -> Id -> [GraphFinding]
contradictionFindings g rix x = forward ++ backward
  where
    forward =
      [ GraphFinding
          { gfStart = x
          , gfTarget = refId (linkTarget l)
          , gfEvidence = GraphEvidence x Contradicts (linkTarget l)
          , gfHops = 1
          , gfTruncated = False
          , gfNote = linkNote l
          }
      | l <- M.findWithDefault [] x g
      , linkKind l == Contradicts
      , not (pointsAt x (linkTarget l))
      ]

    backward =
      [ GraphFinding
          { gfStart = x
          , gfTarget = src
          , gfEvidence = GraphEvidence src Contradicts (linkTarget l)
          , gfHops = 1
          , gfTruncated = False
          , gfNote = linkNote l
          }
      | (src, l) <- M.findWithDefault [] x rix
      , linkKind l == Contradicts
      , src /= x
      ]

    pointsAt i r = isNothing (refVault r) && refId r == i

-- | 第 1 層的取代部分:沿 'RevIndex' 的 @supersedes@ 邊反向 BFS,最多 @depth@ 跳。
--
-- @depth@ 的語意與 core 的 @follow@ 一致:__展開輪數__,@2@ = 最多兩跳;
-- @depth <= 0@ 回空清單。
--
-- __只回鏈末端__:@A supersedes B@、@B supersedes C@,起點 @C@ 回報的是 @A@
-- ——中途的 @B@ 自己也已經過時,把作者指向 @B@ 是錯的。深度用盡而停在一個仍有
-- 取代者的節點時該節點照樣回報,但 @gfTruncated = True@;安靜地把它當末端等於說謊。
--
-- 帶 visited 集合防環(@A supersedes B@ + @B supersedes A@ 是可能被寫出來的),
-- 起點自己永遠不進結果。
supersessionFindings :: Int -> RevIndex -> Id -> [GraphFinding]
supersessionFindings depth rix start
  | depth <= 0 = []
  | otherwise = loop 1 (S.singleton start) [start]
  where
    -- 誰取代了 n。自我關聯是資料錯誤,不是取代鏈的一環。
    supersedersOf n =
      [ (src, l)
      | (src, l) <- M.findWithDefault [] n rix
      , linkKind l == Supersedes
      , src /= n
      ]

    loop d visited frontier
      | null frontier = []
      | otherwise = reported ++ deeper
      where
        wave =
          firstPerSource
            [ p
            | n <- frontier
            , p <- supersedersOf n
            , not (S.member (fst p) visited)
            ]

        -- 用__進入本輪前__的 visited 判斷「還有沒有取代者」:同一輪發現的兩個
        -- 節點之間也可能有取代關係,拿更新過的集合去問會把非末端誤判成末端。
        stillSuperseded src =
          any (\(s, _) -> not (S.member s visited)) (supersedersOf src)

        atBudget = d >= depth

        reported =
          [ finding src l d (stillSuperseded src)
          | (src, l) <- wave
          , not (stillSuperseded src) || atBudget
          ]

        deeper
          | atBudget = []
          | otherwise =
              loop (d + 1) (foldr (S.insert . fst) visited wave) (map fst wave)

    -- 證據是壓縮後的結論:多跳時 @GraphEvidence A Supersedes (localRef start)@
    -- 並非圖上任何一條關聯原文。單跳時它剛好就是原文那條關聯——'RevIndex' 只收
    -- @refVault == Nothing@ 的目標,所以 @linkTarget l == localRef start@。
    finding src l d cut =
      GraphFinding
        { gfStart = start
        , gfTarget = src
        , gfEvidence = GraphEvidence src Supersedes (localRef start)
        , gfHops = d
        , gfTruncated = cut
        , -- 多跳時中間那幾條附註各講各的,湊在一起只會誤導。
          gfNote = if d == 1 then linkNote l else Nothing
        }

-- | 依 @(geFrom, geKind, geTo)@ 去重。
--
-- 鍵是__整條證據__而不是只看 target:同一個片段若既與草稿矛盾、又出現在取代鏈上,
-- 那是兩件事,作者兩件都要看到。同一條證據由多個起點抵達時取 'gfHops' 最小的
-- 那一筆,同跳數則取 'gfStart' 字典序較小者。
dedupeFindings :: [GraphFinding] -> [GraphFinding]
dedupeFindings fs = M.elems (M.fromListWith better [(key f, f) | f <- fs])
  where
    key f = (geFrom (gfEvidence f), geKind (gfEvidence f), geTo (gfEvidence f))
    better new old
      | (gfHops new, gfStart new) < (gfHops old, gfStart old) = new
      | otherwise = old

-- | 'gfHops' 遞增 → 'geKind' → 'gfTarget' 字典序。
--
-- 第二鍵直接用 'LinkKind' 的 derived 'Ord',建構子順序即 @system.md@ 的關聯
-- 詞彙表順序,因此 'Contradicts' 先於 'Supersedes'。這是一個__假設__,測試把它釘住。
sortFindings :: [GraphFinding] -> [GraphFinding]
sortFindings = sortOn (\f -> (gfHops f, geKind (gfEvidence f), gfTarget f))

-- | 繁中理由文案,固定句型。
--
-- id 一律走 'renderId' / 'renderRef',跨 Vault 的目標因此顯示成 @vault:id@。
-- 矛盾的句型__對稱、不區分正反向__:方向資訊在 'GraphEvidence' 裡,勉強寫進
-- 中文句子只會讓兩個方向讀起來像兩種不同的事實,而它們是同一件。
renderGraphReason :: GraphFinding -> Text
renderGraphReason f = case geKind (gfEvidence f) of
  Supersedes ->
    "你引用的 " <> me <> " 已被 " <> other <> " 取代" <> supersedeSuffix
  _ ->
    "你引用的 " <> me <> " 與 " <> other <> " 已標記矛盾" <> noteSuffix
  where
    ev = gfEvidence f
    me = renderId (gfStart f)

    -- 「另一端」是證據裡不等於起點的那一頭。正向的矛盾命中另一端在 'geTo',
    -- 它可能跨 Vault,所以走 'renderRef';反向與取代命中的另一端在 'geFrom'。
    other
      | geFrom ev == gfStart f = renderRef (geTo ev)
      | otherwise = renderId (geFrom ev)

    noteSuffix = maybe "" (":" <>) (gfNote f)

    supersedeSuffix
      | gfTruncated f =
          "(已達深度上限 " <> hops <> ",可能還有更新的版本)"
      | gfHops f > 1 = "(經 " <> hops <> " 跳)"
      | otherwise = ""

    hops = T.pack (show (gfHops f))

-- | 第 1 層門面:起點去重保序 → 兩種發現 → 去重 → 排序 → 'ConflictHit'。
--
-- 輸出恆為 'ByGraph'、'chSnippet' 恆為 'Nothing'(第 1 層命中的是一條關聯,
-- 不是某一段文字),順序完全確定:同一份輸入永遠得到同一份輸出。
graphHits :: ConflictOpts -> LinkGraph -> [Id] -> [ConflictHit]
graphHits opts g starts =
  map toHit . sortFindings . dedupeFindings $ concatMap findingsFor (nubSeq starts)
  where
    rix = revIndex g

    findingsFor x =
      contradictionFindings g rix x
        ++ supersessionFindings (coGraphDepth opts) rix x

    toHit f =
      ConflictHit
        { chTarget = gfTarget f
        , chLayer = ByGraph (gfEvidence f)
        , chReason = renderGraphReason f
        , chSnippet = Nothing
        }

-- | 在圖上一條關聯都沒有的起點——既不是 'LinkGraph' 的鍵(或鍵對應空清單)、
-- 也不是任何本地關聯的目標。第 1 層對它們完全幫不上忙。
--
-- 把「這幾個片段完全沒有標註」變成可查詢的事實,呼叫端才提醒得出來;不然
-- 「沒有發現矛盾」與「根本沒有東西可查」對外長得一模一樣。
--
-- __分辨不了「片段不存在」__:那需要索引,屬於 service。不要拿它當存在性檢查。
-- 輸出保持輸入順序並去重。
unlinkedRefs :: LinkGraph -> [Id] -> [Id]
unlinkedRefs g starts =
  [ x
  | x <- nubSeq starts
  , null (M.findWithDefault [] x g)
  , M.notMember x rix
  ]
  where
    rix = revIndex g

-- | 去重且保持首次出現的順序。
nubSeq :: [Id] -> [Id]
nubSeq = go S.empty
  where
    go _ [] = []
    go seen (x : rest)
      | S.member x seen = go seen rest
      | otherwise = x : go (S.insert x seen) rest

-- | 同一輪裡同一個來源只留第一次抵達的那條關聯。
firstPerSource :: [(Id, Link)] -> [(Id, Link)]
firstPerSource = go S.empty
  where
    go _ [] = []
    go seen (p@(i, _) : rest)
      | S.member i seen = go seen rest
      | otherwise = p : go (S.insert i seen) rest
