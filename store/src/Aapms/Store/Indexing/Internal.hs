{-# LANGUAGE DataKinds #-}

-- | P-001-index-rebuild 的觀察點:兩個純解譯器串起來跑到底。
--
-- 只有 law 用得到它,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Indexing.Internal
  ( simulate
  ) where

import Effectful (Eff)

import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs)
import Aapms.Store.Types (IndexState, VaultFiles)

-- | 觀察:'Aapms.Store.Effect.VaultFs.runVaultFsPure' 與
-- 'Aapms.Store.Effect.Index.runIndexPure' 串起來跑到底,回結果與最終索引。
simulate :: VaultFiles -> IndexState -> Eff '[VaultFs, Index] a -> (a, IndexState)
simulate _vf _ix _act = error "P-001#simulate stub"
