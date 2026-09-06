{-# LANGUAGE DataKinds #-}

-- | 「這台機器現在長什麼樣」的__純投影__(P-006-workspace-doctor)。
--
-- 擁有的事實(唯一真相來源):'Aapms.Service.Types.DoctorView' 的六欄各自從哪裡
-- 來、一個 vault 什麼時候算 @registered@ \/ @reachable__(id 漂移仍算可達),以及
-- 「起點探測到一個中樞不認識的 vault 就多一筆」這條規則。
--
-- 整條是 "Aapms.Workspace.Effect.Markers" 與 "Aapms.Workspace.Effect.ToolProbe"
-- 兩個效果的程式,__本模組一行 IO 都沒有__;真解譯器與進入點住
-- "Aapms.Service.Machine"。
--
-- __唯讀__:不建 @.aapms@、不開 @index.db@、不修補 marker、不寫中樞;漂移要
-- @syncHub@(P-005-vault-lifecycle)才回寫。@[llm]@ 只報告有沒有,鍵與值一律不進
-- 診斷輸出。
module Aapms.Service.Machine.View
  ( -- * 逐列投影
    registeredVaultView
  , discoveredVaultView
  , doctorOf

    -- * 純的整條
  , doctor
  ) where

import Data.Either (lefts)
import Data.Maybe (isJust, isNothing)
import Effectful (Eff, (:>))

import Aapms.Service.Types
  ( DoctorView (..)
  , Session (sessionCwd, sessionHub, sessionLocation, sessionSource)
  , VaultView (..)
  )
import Aapms.Store.Types (VaultMarker (vmId, vmKind, vmName))
import Aapms.Workspace.Effect.Markers (Markers, detectRoot)
import Aapms.Workspace.Effect.ToolProbe (ToolProbe, pathDirs)
import Aapms.Workspace.Resolve (refAt, refOfEntry)
import Aapms.Workspace.Tools.Plan (detectTool)
import Aapms.Workspace.Types
  ( HubLocation (hlPath, hlSource)
  , ScopeIssue
  , ToolSearchPlan (..)
  , ToolStatus
  , VaultEntry (veId, veKind, veName, vePath)
  , VaultRef (vrEntry, vrMarker, vrPath)
  , hubLlm
  , hubTools
  , hubVaults
  , unreachableIds
  )

-- | 中樞一列的投影:@registered@ 恒真,@reachable@ = 沒有
-- 'Aapms.Workspace.Types.VaultPathMissing' \/
-- 'Aapms.Workspace.Types.VaultMarkerBroken' 指到它。
-- 前四欄逐字來自中樞那一列(marker 只用來判可達,__不覆蓋顯示值__:中樞的
-- @veName@ \/ @veKind@ 是快取,而這一份投影說的是「中樞現在記著什麼」)。
registeredVaultView :: [ScopeIssue] -> VaultEntry -> VaultView
registeredVaultView issues e =
  VaultView
    { vvId = veId e
    , vvName = veName e
    , vvKind = veKind e
    , vvPath = vePath e
    , vvRegistered = True
    , vvReachable = veId e `notElem` unreachableIds issues
    }

-- | 探測到的未註冊 vault:欄位全來自 marker,@registered@ 假、@reachable@ 真。
--
-- 這一筆沒有中樞那一列可抄,身分與顯示值只能來自 marker;它是「剛剛才讀成功」
-- 的那份 marker,所以 @reachable@ 恒真。
discoveredVaultView :: VaultRef -> VaultView
discoveredVaultView ref =
  VaultView
    { vvId = vmId m
    , vvName = vmName m
    , vvKind = vmKind m
    , vvPath = vrPath ref
    , vvRegistered = False
    , vvReachable = True
    }
  where
    m = vrMarker ref

-- | 六欄投影:hub 路徑與來源、註冊表來源、vaults、issues、tools、@[llm]@ 有無。
--
-- 全部逐欄搬運,__本函數一個判斷都不做__,唯二的例外是把單一
-- 'Aapms.Workspace.Types.ToolStatus' 裝進單元素清單(目前只探測 7-Zip 一個工具),
-- 以及 @[llm]@ 收成一個 'Bool' ——鍵與值一律不進診斷輸出。
doctorOf :: Session -> [VaultView] -> [ScopeIssue] -> ToolStatus -> DoctorView
doctorOf s vs issues ts =
  DoctorView
    { dvHubPath = hlPath (sessionLocation s)
    , dvHubSource = hlSource (sessionLocation s)
    , dvRegistry = sessionSource s
    , dvVaults = vs
    , dvScopeIssues = issues
    , dvTools = [ts]
    , dvLlmConfigured = isJust (hubLlm (sessionHub s))
    }

-- | 純的整條:對中樞每一列重讀 marker 再投影;起點向上探測到未註冊的 vault 就
-- 多一筆;@PATH@ 拆開後三層探測 7-Zip;最後收成 'Aapms.Service.Types.DoctorView'。
doctor :: (Markers :> es, ToolProbe :> es) => Session -> ToolSearchPlan -> Eff es DoctorView
doctor s plan = do
  refs <- mapM refOfEntry (hubVaults hub)
  let issues = lefts refs
      registered = map (registeredVaultView issues) (hubVaults hub)
  root <- detectRoot (sessionCwd s)
  extra <- case root of
    Nothing -> pure []
    Just p -> do
      there <- refAt hub p
      pure $ case there of
        Right ref | isNothing (vrEntry ref) -> [discoveredVaultView ref]
        _ -> []
  dirs <- pathDirs
  status <- detectTool plan {tspPathDirs = dirs} (hubTools hub)
  pure (doctorOf s (registered ++ extra) issues status)
  where
    hub = sessionHub s
