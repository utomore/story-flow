{-# LANGUAGE DataKinds #-}

-- | vault 與專案生命週期的__進入點__(P-005-vault-lifecycle 的 @!@ 列)。
--
-- 擁有的事實(唯一真相來源):__無__。九種生命週期請求的規則全部住純層的
-- "Aapms.Workspace.Lifecycle.Plan";本模組只做一件 shell 的事——把四個效果
-- ('Aapms.Workspace.Effect.HubFile' \/ 'Aapms.Workspace.Effect.VaultDir' \/
-- 'Aapms.Workspace.Effect.Markers' \/ 'Aapms.Store.Effect.Clock')的__真解譯器__
-- 湊齊,讓 'Aapms.Workspace.Lifecycle.Plan.applyLifecycle' 跑在真的檔案系統上。
--
-- __明確不做__:不自己碰檔案系統(每個真解譯器守自己的足跡)、不解讀請求、
-- 不投影結果(那是 @service@ 的 'Aapms.Service.Machine')。
--
-- 2026-09-06 退場:舊的直接 IO 路徑(@setupHub@ \/ @initVault@ \/ @initVaultWith@ \/
-- @addVault@ \/ @forgetVault@ \/ @purge@ \/ @checkVaults@ \/ @syncHub@)已全數移除,
-- 呼叫端一律經 'runLifecycle' 與 'Aapms.Workspace.Types.LifecycleOp'。
module Aapms.Workspace.Lifecycle
  ( -- * P-005-vault-lifecycle 的進入點
    runLifecycle
  ) where

import Effectful (runEff)

import Aapms.Store.Effect.Clock.IO (runClockIO)
import Aapms.Workspace.Effect.HubFile.IO (runHubFileIO)
import Aapms.Workspace.Effect.Markers.IO (runMarkersIO)
import Aapms.Workspace.Effect.VaultDir.IO (runVaultDirIO)
import Aapms.Workspace.Lifecycle.Plan (applyLifecycle)
import Aapms.Workspace.Types (Hub, HubLocation, LifecycleOp, LifecycleOutcome, WorkspaceError)

-- | 以中樞位置、目錄與系統時鐘跑真解譯器,把 P-005-vault-lifecycle 的純整條
-- 'Aapms.Workspace.Lifecycle.Plan.applyLifecycle' 接到檔案系統上。
--
-- 參數依序是:中樞位置、__已載入__的中樞快照、請求。回傳的
-- 'Aapms.Workspace.Types.LifecycleOutcome' 只有與該請求相關的欄位是
-- @Just@ \/ 非空;寫回中樞的請求另外由呼叫端重載快照。
runLifecycle :: HubLocation -> Hub -> LifecycleOp -> IO (Either WorkspaceError LifecycleOutcome)
runLifecycle loc hub op =
  runEff (runHubFileIO loc (runVaultDirIO (runMarkersIO (runClockIO (applyLifecycle hub op)))))
