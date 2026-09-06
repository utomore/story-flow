-- | 本機外部工具三層探測的__純規劃__(P-006-workspace-doctor)。
--
-- 擁有的事實(唯一真相來源):三層候選清單怎麼排(覆寫 → @PATH@ 每個目錄的
-- @7z@ 與 @7zz@ → 內建候選;跨層去重保序、名稱外層目錄內層),以及「命中即停、
-- @tsSearched@ 是走過的前綴」這條掃描紀律。
--
-- 「這個路徑存不存在、可不可執行」是
-- "Aapms.Workspace.Effect.ToolProbe" 的操作,__本模組一行 IO 都沒有__。
--
-- __7-Zip 缺席不是錯誤__:'Aapms.Workspace.Types.NotFound' 是正常結果,本模組
-- 沒有失敗通道。
module Aapms.Workspace.Tools.Plan
  ( probes
  , detectTool
  ) where

import Effectful (Eff, (:>))

import Aapms.Workspace.Effect.ToolProbe (ToolProbe)
import Aapms.Workspace.Types (ToolSearchPlan, ToolStatus, ToolsConfig)

-- | 三層候選清單:覆寫、@PATH@ 每個目錄的 @7z@ 與 @7zz@、內建候選;跨層去重保序。
probes :: ToolSearchPlan -> ToolsConfig -> [FilePath]
probes _plan _cfg = error "P-006#probes stub"

-- | 依 'probes' 的順序逐一問 'Aapms.Workspace.Effect.ToolProbe.isExecutable',
-- 第一個命中就停;@tsSearched@ 是走過的前綴。
detectTool :: ToolProbe :> es => ToolSearchPlan -> ToolsConfig -> Eff es ToolStatus
detectTool _plan _cfg = error "P-006#detectTool stub"
