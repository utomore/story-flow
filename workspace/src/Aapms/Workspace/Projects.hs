-- | 中樞 @[[projects]]@ 的 @prj-@ 配號。
--
-- 擁有的事實(唯一真相來源):__無__。專案列的註冊與撤除規則(前置檢查、
-- 「同一個路徑不得註冊兩次」、selector 的兩階段逐字比對)在
-- 2026-09-06 的退場波之後全部住純層的 "Aapms.Workspace.Lifecycle.Plan"
-- (P-005-vault-lifecycle 的 @RegisterProject@ \/ @ForgetProject@ 兩種請求),
-- 進入點是 'Aapms.Workspace.Lifecycle.runLifecycle';本模組只把配號那個純函式
-- 原地 re-export,讓既有消費端不必改 import。
--
-- __明確不做__:@assets\/manifest.json@ 與 @story\/manifest.json@ 是 @project@
-- 子系統的真相,本模組__不讀、不產生、不同步、不驗證__它們;專案__不需要
-- marker__,所以本模組與 @.aapms\/@ \/ @readMarker@ \/ 索引完全無關。
module Aapms.Workspace.Projects
  ( -- * 配號(純函式,時間由呼叫端給;定義住
    -- "Aapms.Workspace.Lifecycle.Plan",此處原地 re-export)
    allocateProjectId
  ) where

import Aapms.Workspace.Lifecycle.Plan (allocateProjectId)
