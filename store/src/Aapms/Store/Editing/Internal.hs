{-# LANGUAGE DataKinds #-}

-- | P-003-node-write 的觀察點:三個純解譯器串起來跑到底,與連續配號。
--
-- 只有 law 用得到它們,沒有 production 消費者,所以住 @*.Internal@
-- (rules\/boundary.md「測試與邊界」)。
module Aapms.Store.Editing.Internal
  ( simulateWrite
  , allocateN
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful (Eff)

import Aapms.Core.Id (Id, IdPrefix)
import Aapms.Store.Effect.Clock (Clock)
import Aapms.Store.Effect.Index (Index)
import Aapms.Store.Effect.VaultFs (VaultFs)
import Aapms.Store.Types (IndexState, VaultFiles, WriteRun)

-- | 觀察:三個純解譯器串起來跑到底,回結果、最終檔案表、最終索引。
simulateWrite :: UTCTime -> VaultFiles -> IndexState -> Eff '[VaultFs, Index, Clock] a -> WriteRun a
simulateWrite _t _vf _ix _act = error "P-003#simulateWrite stub"

-- | 觀察:同一個 t 連續配 n 次、每次寫進索引後拿到的 id。
allocateN :: Int -> IdPrefix -> Text -> UTCTime -> IndexState -> [Id]
allocateN _n _pre _c _t _ix = error "P-003#allocateN stub"
