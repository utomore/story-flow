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

import Data.Text (Text)
import Effectful (Eff, (:>))

import Aapms.Core.Id (Id, VaultId)
import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.Vaults (Vaults)
import Aapms.Store.Types
  ( FacetCounts
  , NodeFilter
  , SearchHit
  , SearchQuery
  , SearchResult
  )

-- | 兩張表都命中時取分數較大者,去重。
mergeScores :: [(Id, Double)] -> [(Id, Double)] -> [(Id, Double)]
mergeScores _a _b = error "P-002#mergeScores stub"

-- | 從該節點 @fts_tri@ 六欄原文取窗:先找整串、再找個別詞、都沒有取第一個
-- 非空欄開頭。
--
-- 取代 "Aapms.Store.Query" 私有的 @snippetOf@;舊的那一份留著不動,由 shell 的
-- 真解譯器接手時再退場。
snippetFrom :: Text -> [Text] -> Text
snippetFrom _q _cols = error "P-002#snippetFrom stub"

-- | 分數遞減、同分 id 遞增、再同 vault 遞增。
rankHits :: [SearchHit] -> [SearchHit]
rankHits _hits = error "P-002#rankHits stub"

-- | 依 @nfOffset@ \/ @nfLimit@ 對整體切窗。
pageHits :: NodeFilter -> [SearchHit] -> [SearchHit]
pageHits _nf _hits = error "P-002#pageHits stub"

-- | 跨 vault 同值求和、濾掉計數 0、計數遞減同計數值遞增。
--
-- 取代 "Aapms.Store.MultiVault" 私有的 @mergeFacets@。
mergeFacetCounts :: [FacetCounts] -> FacetCounts
mergeFacetCounts _fcs = error "P-002#mergeFacetCounts stub"

-- | 單 vault 的五維 facet,每一維排除自己的條件、保留其餘條件與文字條件。
facetsIn :: Index :> es => VaultId -> SearchQuery -> Eff es FacetCounts
facetsIn _vid _q = error "P-002#facetsIn stub"

-- | 單 vault 整條:路由 → 查 FTS 與結構條件 → 合併 → 片段 → 排序 → 切窗。
searchVault :: Index :> es => VaultId -> SearchQuery -> Eff es SearchResult
searchVault _vid _q = error "P-002#searchVault stub"

-- | 純的整條:列 vault → 對每個 vault 跑 'searchVault' → 合併 hits → 排序 →
-- 切窗;@srTotal@ 加總;facet 走 'mergeFacetCounts'。
searchVaults :: Vaults :> es => SearchQuery -> Eff es SearchResult
searchVaults _q = error "P-002#searchVaults stub"
