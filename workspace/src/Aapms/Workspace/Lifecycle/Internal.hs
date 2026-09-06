{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

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

import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Effectful (Eff, runPureEff)
import Effectful.Dispatch.Dynamic (interpret)

import Aapms.Store.Effect.Clock (Clock (..))
import Aapms.Store.Types (StoreError (VaultMarkerMissing), VaultMarker (vmId))
import Aapms.Workspace.Effect.HubFile (HubFile, runHubFilePure)
import Aapms.Workspace.Effect.Markers (Markers, runMarkersPure)
import Aapms.Workspace.Effect.VaultDir (VaultDir, runVaultDirPure)
import Aapms.Workspace.Types
  ( Hub
  , HubWorld (..)
  , LifecycleRun (..)
  , MarkerWorld (..)
  , ScopeIssue (..)
  , VaultEntry (..)
  , VaultWorld (..)
  , hubVaults
  , vwDirExists
  , vwMarker
  )
import System.FilePath ((</>))

-- | 觀察:四個純解譯器跑到底,回結果、最終中樞文字、最終目錄樹。
--
-- 四個效果各自的世界:'HubFile' 跑在 @hw@ 上、'VaultDir' 跑在 @vw@ 上、
-- 'Aapms.Workspace.Effect.Markers.Markers' 跑在__自 @vw@ 投影出來的__
-- 'Aapms.Workspace.Types.MarkerWorld' 上(見 'markerWorldOf')、
-- 'Aapms.Store.Effect.Clock.Clock' 固定回第一個參數那個時刻——
-- @'Aapms.Store.Effect.Clock.runClockPure'@ 還是 P-003-node-write 的骨架,
-- 這裡用 effectful 的 @interpret@ 私有地解一次,不動別條 pipeline 的檔。
--
-- 第四個參數(起始 'Hub')不參與跑:@act@ 已經捧著它
-- (@applyLifecycle h op@),留在簽名上只是讓觀察點與 law 的寫法對齊。
simulateLifecycle
  :: UTCTime
  -> HubWorld
  -> VaultWorld
  -> Hub
  -> Eff '[HubFile, VaultDir, Markers, Clock] a
  -> LifecycleRun a
simulateLifecycle t hw vw _h act =
  LifecycleRun
    { lcResult = a
    , lcHubText = hubTextIn hw'
    , lcVaults = vw'
    , hubWorldAfter = hw'
    }
  where
    ((a, hw'), vw') =
      runPureEff
        . runClockAt t
        . runMarkersPure (markerWorldOf vw)
        . runVaultDirPure vw
        . runHubFilePure hw
        $ act

-- | 私有:固定時間的 'Clock' 解譯器。
runClockAt :: UTCTime -> Eff (Clock : es) a -> Eff es a
runClockAt t = interpret $ \_ op -> case op of
  Now -> pure t

-- | 私有:'Aapms.Workspace.Types.VaultWorld' 投影成
-- 'Aapms.Workspace.Types.MarkerWorld'——同一棵目錄樹的兩個視角,marker 讀數逐格
-- 沿用,「哪些路徑是既存目錄」就是目錄樹的鍵。
--
-- 兩個世界因此不會互相矛盾:@Markers@ 讀得到 marker 的路徑,@VaultDir@ 那邊
-- 也讀得到。
markerWorldOf :: VaultWorld -> MarkerWorld
markerWorldOf vw =
  MarkerWorld {mwMarkers = vwMarkers vw, worldDirs = Map.keys (vwTree vw)}

-- | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單。
--
-- 逐字複製 'Aapms.Workspace.Resolve.refOfEntry' 在純世界裡的三種降級__與它們的
-- 順序__:先問路徑是不是既存目錄、再讀 marker、最後比 id;正規化在純世界裡是
-- 恆等,所以路徑就是 'Aapms.Workspace.Types.vePath'。marker 不在表上時的
-- 'Aapms.Store.Types.VaultMarkerMissing' 也與
-- 'Aapms.Workspace.Effect.Markers.runMarkersPure' 拼同一條路徑。
--
-- 它__不展開 @refs@__,所以永遠不產生
-- 'Aapms.Workspace.Types.RefVaultNotRegistered'。
checkVaultsOf :: VaultWorld -> Hub -> [ScopeIssue]
checkVaultsOf vw h = [issue | e <- hubVaults h, Left issue <- [issueOf e]]
  where
    issueOf e
      | not (vwDirExists vw p) = Left (VaultPathMissing e p)
      | otherwise = case markerAt p of
          Left err -> Left (VaultMarkerBroken e err)
          Right m
            | vmId m /= veId e -> Left (VaultIdDrift e (vmId m))
            | otherwise -> Right ()
      where
        p = vePath e

    markerAt p = case vwMarker vw p of
      Just r -> r
      Nothing -> Left (VaultMarkerMissing (p </> ".aapms" </> "config.toml"))
