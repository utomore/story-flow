{-# LANGUAGE DataKinds #-}

-- | P-002-search 的觀察點:純解譯器跑到底,與兩組逐 vault 的參考量。
--
-- 只有 law 用得到它們,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Search.Internal
  ( simulateVaults
  , hitsPerVault
  , structuralKeys
  ) where

import Data.Map.Strict (Map)
import Effectful (Eff)

import Aapms.Core.Id (Id, VaultId)
import Aapms.Store.Effect.Vaults (Vaults)
import Aapms.Store.Types (IndexState, NodeFilter, SearchHit, SearchQuery)

-- | 觀察:'Aapms.Store.Effect.Vaults.runVaultsPure' 跑到底。
simulateVaults :: Map VaultId IndexState -> Eff '[Vaults] a -> a
simulateVaults _m _act = error "P-002#simulateVaults stub"

-- | 觀察:逐 vault 各跑一次 'Aapms.Store.Search.searchVault',把 hits 串接。
hitsPerVault :: Map VaultId IndexState -> SearchQuery -> [SearchHit]
hitsPerVault _m _q = error "P-002#hitsPerVault stub"

-- | 觀察:逐 vault 用 'Aapms.Store.Filter.passesFilter' 篩出的 (vault, id)。
structuralKeys :: Map VaultId IndexState -> NodeFilter -> [(VaultId, Id)]
structuralKeys _m _nf = error "P-002#structuralKeys stub"
