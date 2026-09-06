-- | 結構條件的純判定(P-002-search)。
--
-- 與 SQL 側的 @WHERE@ 子句是同一組規則的兩個實作:prefix、type、status、
-- tags 全部命中、owner('inOwner')、license、只要已命名、reference
-- ('fiReference')預設不列。吃節點所在的檔與索引節點,因為 owner 與
-- reference 都不是 'Aapms.Core.AnyNode.AnyNode' 自己知道的事(P-002 REV-1)。
module Aapms.Store.Filter
  ( passesFilter
  ) where

import Aapms.Store.Types (FileIndex, IndexedNode, NodeFilter)

-- | 這個索引節點在它所在的檔裡過不過得了結構條件。
passesFilter :: NodeFilter -> FileIndex -> IndexedNode -> Bool
passesFilter _nf _fi _n = error "P-002#passesFilter stub"
