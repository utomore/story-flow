{-# LANGUAGE DataKinds #-}

-- | P-005-vault-lifecycle 的觀察點:四個純解譯器一起跑到底,以及 @checkVaults@
-- 的參考實作。
--
-- 這些簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Workspace.Lifecycle" 自己與
-- 測試准 import。
module Aapms.Workspace.Lifecycle.Internal
  ( -- * 純解譯器跑到底
    simulateLifecycle

    -- * 參考實作
  , checkVaultsOf
  ) where

import Data.Time (UTCTime)
import Effectful (Eff)

import Aapms.Store.Effect.Clock (Clock)
import Aapms.Workspace.Effect.HubFile (HubFile)
import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Effect.VaultDir (VaultDir)
import Aapms.Workspace.Types (Hub, HubWorld, LifecycleRun, ScopeIssue, VaultWorld)

-- | 觀察:四個純解譯器跑到底,回結果、最終中樞文字、最終目錄樹。
simulateLifecycle
  :: UTCTime
  -> HubWorld
  -> VaultWorld
  -> Hub
  -> Eff '[HubFile, VaultDir, Markers, Clock] a
  -> LifecycleRun a
simulateLifecycle _t _hw _vw _h _act = error "P-005#simulateLifecycle stub"

-- | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單。
checkVaultsOf :: VaultWorld -> Hub -> [ScopeIssue]
checkVaultsOf _vw _h = error "P-005#checkVaultsOf stub"
