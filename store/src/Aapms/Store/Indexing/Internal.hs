{-# LANGUAGE DataKinds #-}

-- | P-001-index-rebuild 的觀察點:兩個純解譯器串起來跑到底。
--
-- 只有 law 用得到它,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Indexing.Internal
  ( simulate
  , clashesEarlier
  ) where

import Effectful (Eff)

import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs)
import Aapms.Core.Id (VaultId)
import Aapms.Core.Registry (TypeRegistry)
import Aapms.Store.Types (IndexState, VaultFiles)

-- | 觀察:'Aapms.Store.Effect.VaultFs.runVaultFsPure' 與
-- 'Aapms.Store.Effect.Index.runIndexPure' 串起來跑到底,回結果與最終索引。
simulate :: VaultFiles -> IndexState -> Eff '[VaultFs, Index] a -> (a, IndexState)
simulate _vf _ix _act = error "P-001#simulate stub"

-- | 觀察:這個檔某個已命名 asset 的邏輯名稱,已被路徑字母序更前、純核心成功的
-- 檔用掉——撞名回滾的判準(P-001-index-rebuild REV-1)。
clashesEarlier :: TypeRegistry -> VaultId -> VaultFiles -> FilePath -> Bool
clashesEarlier _reg _vid _vf _p = error "P-001#clashesEarlier stub"
