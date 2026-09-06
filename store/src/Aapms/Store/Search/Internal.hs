{-# LANGUAGE DataKinds #-}

-- | P-002-search 的觀察點:純解譯器跑到底,與兩組逐 vault 的參考量。
--
-- 只有 law 用得到它們,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Search.Internal
  ( simulateVaults
  , hitsPerVault
  , structuralKeys
  , visibleNodes
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Effectful (Eff, runPureEff)

import Aapms.Core.AnyNode (AnyNode, anyMeta)
import Aapms.Core.Id (Id, VaultId)
import Aapms.Core.Meta (Meta (..))
import Aapms.Store.Effect.Vaults (Vaults)
import Aapms.Store.Filter (passesFilter)
import Aapms.Store.Search (searchVault)
import Aapms.Store.Simulate (runIndexPure, runVaultsPure)
import Aapms.Store.Types
  ( FileIndex (..)
  , IndexState (..)
  , IndexedNode (..)
  , NodeFilter
  , SearchHit
  , SearchQuery
  , SearchResult (..)
  )

-- | 觀察:'Aapms.Store.Simulate.runVaultsPure' 跑到底。
simulateVaults :: Map VaultId IndexState -> Eff '[Vaults] a -> a
simulateVaults m act = runPureEff (runVaultsPure m act)

-- | 觀察:逐 vault 各跑一次 'Aapms.Store.Search.searchVault',把 hits 串接。
hitsPerVault :: Map VaultId IndexState -> SearchQuery -> [SearchHit]
hitsPerVault m q =
  concat
    [ srHits (fst (runPureEff (runIndexPure ix (searchVault v q))))
    | (v, ix) <- Map.toList m
    ]

-- | 觀察:逐 vault 用 'Aapms.Store.Filter.passesFilter' 篩出的 (vault, id)。
structuralKeys :: Map VaultId IndexState -> NodeFilter -> [(VaultId, Id)]
structuralKeys m nf = [(v, metaId (anyMeta n)) | (v, n) <- visibleNodes nf m]

-- | 觀察:記憶體索引集合裡逐檔逐節點以 'Aapms.Store.Filter.passesFilter'
-- 判定後留下的節點(含 owner 與 reference 條件)。
--
-- 與 'Aapms.Store.Simulate.runIndexPure' 一樣,同一個 vault 內一個 id
-- 只算一列(真索引的 @nodes.id@ 是主鍵),否則同一個節點被兩個檔記到時
-- 這個參考量會比命中多出一筆。
visibleNodes :: NodeFilter -> Map VaultId IndexState -> [(VaultId, AnyNode)]
visibleNodes nf m =
  [ (v, inNode n)
  | (v, IndexState files) <- Map.toList m
  , (fi, n) <- dedupById [(fi, n) | fi <- Map.elems files, n <- fiNodes fi]
  , passesFilter nf fi n
  ]

dedupById :: [(FileIndex, IndexedNode)] -> [(FileIndex, IndexedNode)]
dedupById = go Set.empty
  where
    go _ [] = []
    go seen (row@(_, n) : rest)
      | i `Set.member` seen = go seen rest
      | otherwise = row : go (Set.insert i seen) rest
      where
        i = metaId (anyMeta (inNode n))
