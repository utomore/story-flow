{-# LANGUAGE DataKinds #-}

-- | P-029-scope-resolve 的觀察點:把純解譯器跑到底,以及三個參考實作。
--
-- 這些簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Workspace.Resolve" 自己與測試
-- 准 import。
module Aapms.Workspace.Resolve.Internal
  ( -- * 純解譯器跑到底
    simulateScope

    -- * 參考實作
  , readableIds
  , reachable
  , nearestRoot
  ) where

import Effectful (Eff)

import Aapms.Core.Id (VaultId)
import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Types (Hub, MarkerWorld)

-- | 觀察:純解譯器跑到底。
simulateScope :: MarkerWorld -> Eff '[Markers] a -> a
simulateScope _w _act = error "P-029#simulateScope stub"

-- | 觀察:中樞順序下 marker 讀得到且 id 相符的列。
readableIds :: MarkerWorld -> Hub -> [VaultId]
readableIds _w _h = error "P-029#readableIds stub"

-- | 觀察:參考實作,自種子沿 @refs@ 的 BFS 可達集合(首次入隊序,種子第一,
-- 不可達的不展開)。
reachable :: MarkerWorld -> Hub -> VaultId -> [VaultId]
reachable _w _h _seed = error "P-029#reachable stub"

-- | 觀察:參考實作,起點往上第一層有 @.aapms@ 目錄的。
nearestRoot :: MarkerWorld -> FilePath -> Maybe FilePath
nearestRoot _w _d = error "P-029#nearestRoot stub"
