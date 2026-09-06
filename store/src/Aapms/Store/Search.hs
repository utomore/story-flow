-- | 搜尋的 stage 本體(P-002-search)。
--
-- 本模組住 pure 層:合併、片段、排序、分頁、facet 合併是純函數,
-- 'facetsIn' \/ 'searchVault' \/ 'searchVaults' 是只帶效果__描述__的 @Eff@ 程式。
-- 真解譯器(sqlite 的 @MATCH@ 與 @bm25()@、@ATTACH@ 多個索引)住 shell,
-- "Aapms.Store.MultiVault" 的 @searchAcross@ 是進入點。
module Aapms.Store.Search
  ( -- * 純的組合
    mergeScores
  , snippetFrom
  , rankHits
  , pageHits
  , mergeFacetCounts

    -- * 效果程式
  , facetsIn
  , searchVault
  , searchVaults
  ) where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (Eff, (:>))

import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..))
import Aapms.Core.Id (Id, Ref, VaultId (..), renderId, renderRef)
import Aapms.Core.Meta (Meta (..), TypeKey (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Store.Effect.Index (Index, filterNodes, ftsMatch)
import Aapms.Store.Effect.Vaults (Vaults, inVault, vaultIds)
import Aapms.Store.Tokenize (FtsText (..), rawFtsText, routeOf)
import Aapms.Store.Types
  ( FacetCounts (..)
  , IndexedNode (..)
  , NodeFilter (..)
  , SearchHit (..)
  , SearchQuery (..)
  , SearchResult (..)
  , SearchRoute (..)
  , usesCjk
  , usesTrigram
  , wide
  )

--------------------------------------------------------------------------------
-- 純的組合

-- | 兩張表都命中時取分數較大者,去重。
--
-- 結果依 id 遞增('Map' 的鍵序),排序真正的權威是 'rankHits'。
mergeScores :: [(Id, Double)] -> [(Id, Double)] -> [(Id, Double)]
mergeScores a b = Map.toList (Map.fromListWith max (a ++ b))

-- | 從該節點 @fts_tri@ 六欄原文取窗:先找整串、再找個別詞、都沒有取第一個
-- 非空欄開頭。
--
-- 取代 "Aapms.Store.Query" 私有的 @snippetOf@;舊的那一份留著不動,由 shell 的
-- 真解譯器接手時再退場。裁掉的地方補一個省略號 @…@;視窗長度('snippetContext')
-- 與挑選順序是實作層級的選擇。
snippetFrom :: Text -> [Text] -> Text
snippetFrom q cols = case wholeQuery of
  Just s -> s
  Nothing -> case singleWord of
    Just s -> s
    Nothing -> case filter (not . T.null) cols of
      (c : _) -> truncateFront c
      [] -> ""
  where
    s0 = T.strip q

    wholeQuery = windowFor s0
    singleWord = listToMaybe (mapMaybe windowFor (T.words s0))

    windowFor needle
      | T.null needle = Nothing
      | otherwise =
          listToMaybe
            [ truncateBack before <> needle <> truncateFront after
            | c <- cols
            , not (T.null c)
            , let (before, rest) = T.breakOn needle c
            , not (T.null rest)
            , let after = T.drop (T.length needle) rest
            ]

    truncateBack t
      | T.length t > snippetContext = "\x2026" <> T.takeEnd snippetContext t
      | otherwise = t

    truncateFront t
      | T.length t > snippetContext = T.take snippetContext t <> "\x2026"
      | otherwise = t

-- | 片段視窗一側取多少字元(不含省略號),實作層級的選擇。
snippetContext :: Int
snippetContext = 24

-- | 分數遞減、同分 id 遞增、再同 vault 遞增。
rankHits :: [SearchHit] -> [SearchHit]
rankHits = sortBy cmp
  where
    cmp x y =
      compare (Down (shScore x)) (Down (shScore y))
        <> compare (metaId (shMeta x)) (metaId (shMeta y))
        <> compare (shVault x) (shVault y)

-- | 依 @nfOffset@ \/ @nfLimit@ 對整體切窗。
pageHits :: NodeFilter -> [SearchHit] -> [SearchHit]
pageHits nf = take (nfLimit nf) . drop (nfOffset nf)

-- | 跨 vault 同值求和、濾掉計數 0、計數遞減同計數值遞增。
--
-- 取代 "Aapms.Store.MultiVault" 私有的 @mergeFacets@。
mergeFacetCounts :: [FacetCounts] -> FacetCounts
mergeFacetCounts fcs =
  FacetCounts
    { fcTypes = mergeDim (map fcTypes fcs)
    , fcVaults = mergeDim (map fcVaults fcs)
    , fcTags = mergeDim (map fcTags fcs)
    , fcOwners = mergeDim (map fcOwners fcs)
    , fcLicenses = mergeDim (map fcLicenses fcs)
    }
  where
    mergeDim dims = tallyOf (Map.toList (Map.fromListWith (+) (concat dims)))

-- | (值, 次數) → 計數遞減、同計數以值遞增,計數 0 的不出現。
tallyOf :: [(Text, Int)] -> [(Text, Int)]
tallyOf =
  sortBy (\(v1, c1) (v2, c2) -> compare (Down c1) (Down c2) <> compare v1 v2)
    . filter ((> 0) . snd)

-- | 一串值 → 分面計數。
tally :: [Text] -> [(Text, Int)]
tally xs = tallyOf (Map.toList (Map.fromListWith (+) [(x, 1 :: Int) | x <- xs]))

--------------------------------------------------------------------------------
-- 效果程式

-- | 單 vault 的五維 facet,每一維排除自己的條件、保留其餘條件與文字條件。
--
-- 「排除自己的條件」是 P-002-search 的決定:選了一個 tag 之後側欄還要看得到
-- 其他 tag,否則使用者換不掉(LAW-11 \/ LAW-12)。@fcVaults@ 是唯一套用
-- __完整__條件的維度——它就是這個 vault 的總數,加總起來要等於 @srTotal@
-- (LAW-10)。
--
-- @fcOwners@ 的值是 owner 的 id 文字('inOwner' 經 'renderId'),對照 SQL 側
-- 拿 @n.owner@ 這一欄分組;沒有 owner 的節點不計(SQL 側是 NULL 不計)。
facetsIn :: Index :> es => VaultId -> SearchQuery -> Eff es FacetCounts
facetsIn vid q = do
  let nf = sqFilter q
      textM = normalizeText (sqText q)
  full <- candidateNodes textM nf
  typeNs <- candidateNodes textM nf {nfTypes = []}
  tagNs <- candidateNodes textM nf {nfTags = []}
  ownerNs <- candidateNodes textM nf {nfOwner = Nothing}
  licNs <- candidateNodes textM nf {nfLicense = Nothing}
  let VaultId vidText = vid
  pure
    FacetCounts
      { fcTypes = tally [t | n <- typeNs, let TypeKey t = metaType (anyMeta (inNode n))]
      , fcVaults = tallyOf [(vidText, length full)]
      , fcTags = tally (concatMap (metaTags . anyMeta . inNode) tagNs)
      , fcOwners = tally [renderId o | n <- ownerNs, Just o <- [inOwner n]]
      , fcLicenses = tally [renderRef r | n <- licNs, Just r <- [licenseRefOf (inNode n)]]
      }

-- | 單 vault 整條:路由 → 查 FTS 與結構條件 → 合併 → 片段 → 排序 → 切窗。
--
-- @srTotal@ 是__分頁前__的命中數;'shMeta' 的 @metaVault@ 一律換成 @vid@,
-- 與 sqlite 側 @rowToMeta@ 拿 marker 的 id 覆寫同一個作法(不信檔案自己寫的
-- vault 欄,P-001-index-rebuild#LAW-7)。
searchVault :: Index :> es => VaultId -> SearchQuery -> Eff es SearchResult
searchVault vid q = do
  let nf = sqFilter q
      textM = normalizeText (sqText q)
  matched <- matchedNodes textM nf
  let hits =
        [ SearchHit
            { shVault = vid
            , shMeta = (anyMeta (inNode n)) {metaVault = vid}
            , shSnippet = maybe "" (\t -> snippetFrom t (ftsColumns (inNode n))) textM
            , shScore = score
            }
        | (n, score) <- matched
        ]
  facets <-
    if sqFacets q
      then Just <$> facetsIn vid q
      else pure Nothing
  pure
    SearchResult
      { srHits = pageHits nf (rankHits hits)
      , srTotal = length hits
      , srFacets = facets
      }

-- | 純的整條:列 vault → 對每個 vault 跑 'searchVault' → 合併 hits → 排序 →
-- 切窗;@srTotal@ 加總;facet 走 'mergeFacetCounts'。
--
-- 每個 vault 拿到的是 'wide' 過的查詢:分頁必須對__合併後的整體__切窗
-- (LAW-7),各 vault 各切再接會漏掉跨過 vault 邊界的視窗。
searchVaults :: Vaults :> es => SearchQuery -> Eff es SearchResult
searchVaults q = do
  vs <- vaultIds
  perVault <- mapM (\v -> inVault v (searchVault v (wide q))) vs
  let results = catMaybes perVault
      ranked = rankHits (concatMap srHits results)
      facets
        | sqFacets q = Just (mergeFacetCounts (mapMaybe srFacets results))
        | otherwise = Nothing
  pure
    SearchResult
      { srHits = pageHits (sqFilter q) ranked
      , srTotal = sum (map srTotal results)
      , srFacets = facets
      }

--------------------------------------------------------------------------------
-- 私有

-- | 去頭尾空白後為空的文字條件視同沒有文字條件(契約 F 的 'sqText' 說明)。
normalizeText :: Maybe Text -> Maybe Text
normalizeText mt = case T.strip <$> mt of
  Just s | not (T.null s) -> Just s
  _ -> Nothing

-- | 一個 vault 內套用全部條件的命中與分數。
--
-- 沒有文字條件時退化成結構查詢,分數 0(契約 F:'shScore' 的 0 保留給這種
-- 情形);有文字條件時依路由對用得到的 FTS 表各查一次,兩邊以 'mergeScores'
-- 取大去重(P-002-search 的決定:不相加)。@ftsMatch@ 只回 @(Id, 分數)@,
-- 'Meta' 與片段原文要另外拿——結構條件已經套在 @ftsMatch@ 上,命中必定是
-- 'filterNodes' 的子集。
matchedNodes :: Index :> es => Maybe Text -> NodeFilter -> Eff es [(IndexedNode, Double)]
matchedNodes Nothing nf = do
  ns <- filterNodes nf
  pure [(n, 0) | n <- ns]
matchedNodes (Just t) nf = do
  let route = routeOf t
  tri <- if usesTrigram route then ftsMatch TrigramOnly t nf else pure []
  cjk <- if usesCjk route then ftsMatch CjkOnly t nf else pure []
  ns <- filterNodes nf
  let byId = Map.fromList [(metaId (anyMeta (inNode n)), n) | n <- ns]
  pure [(n, score) | (i, score) <- mergeScores tri cjk, Just n <- [Map.lookup i byId]]

-- | 'matchedNodes' 只要節點:facet 的候選集。
candidateNodes :: Index :> es => Maybe Text -> NodeFilter -> Eff es [IndexedNode]
candidateNodes textM nf = map fst <$> matchedNodes textM nf

-- | 一個節點在 @fts_tri@ 的六欄原文,順序同
-- 'Aapms.Store.Tokenize.FtsText' 的欄位(片段一律取自這裡,與命中來自哪張表
-- 無關)。
ftsColumns :: AnyNode -> [Text]
ftsColumns n = [ftTitle ft, ftSummary ft, ftBody ft, ftAliases ft, ftTags ft, ftName ft]
  where
    ft = rawFtsText n

-- | 節點的 license:只有 asset 與 pack 有這一欄(對照 SQL 的
-- @COALESCE(a.license, p.license)@)。
licenseRefOf :: AnyNode -> Maybe Ref
licenseRefOf (NAsset a) = astLicense a
licenseRefOf (NPack p) = pckLicense p
licenseRefOf _ = Nothing
