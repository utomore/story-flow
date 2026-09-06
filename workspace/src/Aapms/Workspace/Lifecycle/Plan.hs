{-# LANGUAGE DataKinds #-}

-- | vault 與專案生命週期的__純規劃__(P-005-vault-lifecycle)。
--
-- 擁有的事實(唯一真相來源):前置檢查的__順序__(名稱 → 已佔用 → 目錄狀態)、
-- 舊 marker 的探測範圍(第一層、固定順序、不遞迴)、撞號的判準、marker 投影成
-- 中樞一列的規則,以及十個生命週期操作各自的路徑。
--
-- 整條是 "Aapms.Workspace.Effect.HubFile" \/ "Aapms.Workspace.Effect.VaultDir" \/
-- "Aapms.Workspace.Effect.Markers" \/ "Aapms.Store.Effect.Clock" 四個效果的程式,
-- __本模組一行 IO 都沒有__;真解譯器與進入點住 "Aapms.Workspace.Lifecycle"。
--
-- __明確不做__:不刪 @library\/@ 與任何 @.md@;不反向修 marker(syncHub 的方向
-- 只有 marker → 中樞);不自動刪舊系統的 marker(只報告)。
module Aapms.Workspace.Lifecycle.Plan
  ( -- * 前置檢查與投影
    checkInit
  , legacyMarkers
  , collisionOf
  , entryOf
  , syncEntry

    -- * 專案
  , lookupProject
  , allocateProjectId

    -- * 純的整條
  , applyLifecycle
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful (Eff, (:>))

import Aapms.Core.Id (Id, IdPrefix (PPrj), newId)
import Aapms.Store.Effect.Clock (Clock)
import Aapms.Store.Types (VaultMarker)
import Aapms.Workspace.Effect.HubFile (HubFile)
import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Effect.VaultDir (VaultDir)
import Aapms.Workspace.Types
  ( Hub
  , InitMode
  , LifecycleOp
  , LifecycleOutcome
  , ProjectEntry (..)
  , VaultEntry
  , WorkspaceError
  )

-- | 前置檢查依序:名稱去空白非空 → @.aapms@ 未被佔用 → 'Aapms.Workspace.Types.FreshVault'
-- 要空、'Aapms.Workspace.Types.AdoptExisting' 要存在;通過回去空白後的名稱。
--
-- 三個 'Bool' \/ @['FilePath']@ 參數依序是:@.aapms@ 被佔用了嗎、目錄存在嗎、
-- 目錄第一層有什麼。
checkInit :: Text -> InitMode -> Bool -> Bool -> [FilePath] -> Either WorkspaceError Text
checkInit _name _mode _occupied _exists _entries = error "P-005#checkInit stub"

-- | 目錄第一層裡的 @.assetdb@ \/ @.storyflow@,固定順序,不遞迴。
legacyMarkers :: FilePath -> [FilePath] -> [FilePath]
legacyMarkers _dir _entries = error "P-005#legacyMarkers stub"

-- | 新 marker 的 id 撞到中樞既有列(路徑不同)就是
-- 'Aapms.Workspace.Types.VaultIdCollision' 三個值。
collisionOf :: Hub -> VaultMarker -> FilePath -> Maybe WorkspaceError
collisionOf _hub _m _dir = error "P-005#collisionOf stub"

-- | marker 投影成中樞的一列。
entryOf :: VaultMarker -> FilePath -> VaultEntry
entryOf _m _dir = error "P-005#entryOf stub"

-- | 只以 marker 修 @name@ 與 @kind@,@id@ 與 @path@ 不動。
syncEntry :: VaultEntry -> VaultMarker -> VaultEntry
syncEntry _e _m = error "P-005#syncEntry stub"

-- | 專案 selector:先 id 再 name,逐字,撞名
-- 'Aapms.Workspace.Types.ProjectSelectorAmbiguous'。
lookupProject :: Hub -> Text -> Either WorkspaceError ProjectEntry
lookupProject _hub _s = error "P-005#lookupProject stub"

-- | @prj-@ 短 id,撞既有就 salt 遞增,純函數。
--
-- (自 "Aapms.Workspace.Projects" 搬進純層,行為逐字不變;該模組原地 re-export。)
allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id
allocateProjectId existing nm t = go 0
  where
    taken = map peId existing
    go salt =
      let cand = newId PPrj nm t salt
      in if cand `elem` taken then go (salt + 1) else cand

-- | 純的整條:依請求走前置檢查 → 建 marker → 撞號比對 → 舊 marker 探測 →
-- 'Hub' 值上加減 → 渲染 → 原子寫回等路徑。
applyLifecycle
  :: (HubFile :> es, VaultDir :> es, Markers :> es, Clock :> es)
  => Hub
  -> LifecycleOp
  -> Eff es (Either WorkspaceError LifecycleOutcome)
applyLifecycle _hub _op = error "P-005#applyLifecycle stub"
