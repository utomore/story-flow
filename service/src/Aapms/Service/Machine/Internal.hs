{-# LANGUAGE DataKinds #-}

-- | P-006-workspace-doctor 的觀察點:兩個純解譯器一起跑到底,以及逐列重讀
-- marker 的參考實作。
--
-- 這些簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Service.Machine" 自己與測試
-- 准 import。
module Aapms.Service.Machine.Internal
  ( -- * 純解譯器跑到底
    simulateDoctor

    -- * 參考實作
  , markerIssues
  ) where

import Effectful (Eff)

import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Effect.ToolProbe (ToolProbe)
import Aapms.Workspace.Types (Hub, MarkerWorld, ScopeIssue, ToolWorld)

-- | 觀察:'Markers' 與 'ToolProbe' 的純解譯器跑到底。
simulateDoctor :: MarkerWorld -> ToolWorld -> Eff '[Markers, ToolProbe] a -> a
simulateDoctor _w _tw _act = error "P-006#simulateDoctor stub"

-- | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單。
markerIssues :: MarkerWorld -> Hub -> [ScopeIssue]
markerIssues _w _h = error "P-006#markerIssues stub"
