-- | 結構條件的純判定(P-002-search)。
--
-- 與 SQL 側的 @WHERE@ 子句是同一組規則的兩個實作:prefix、type、status、
-- tags 全部命中、owner、license、只要已命名、reference 預設不列。
module Aapms.Store.Filter
  ( passesFilter
  ) where

import Aapms.Core.AnyNode (AnyNode)
import Aapms.Store.Types (NodeFilter)

-- | 這個節點過不過得了結構條件。
passesFilter :: NodeFilter -> AnyNode -> Bool
passesFilter _nf _n = error "P-002#passesFilter stub"
