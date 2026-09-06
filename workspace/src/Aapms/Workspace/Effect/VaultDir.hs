{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | vault 目錄本身的建立、探測與清除,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 與 "Aapms.Workspace.Effect.Markers" 的分工:@Markers@ 只__讀__身分(裁決要
-- 的事實),@VaultDir@ 是 P-005-vault-lifecycle 用來__改變__目錄樹的那一組
-- (建 marker 與空索引、撞號時回滾、刪 @index.db@)。目錄第一層的列舉放在這裡
-- 而不是 @Markers@:空目錄判定與舊 marker 探測都只有生命週期用得到。
--
-- 純解譯器 'runVaultDirPure' 跑在 'Aapms.Workspace.Types.VaultWorld' 上並__回傳
-- 最終的目錄樹__——「零副作用」「只多刪 index.db」這些 law 靠它比對。真解譯器住
-- "Aapms.Workspace.Effect.VaultDir.IO"。
module Aapms.Workspace.Effect.VaultDir
  ( -- * 效果描述
    VaultDir (..)

    -- * 操作(P-005-vault-lifecycle)
  , listEntries
  , markerDirExists
  , initMarker
  , removeMarkerDir
  , removeIndexDb

    -- * 純解譯器(觀察點)
  , runVaultDirPure
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Store.Types (StoreError, VaultKind, VaultMarker)
import Aapms.Workspace.Types (VaultWorld)

-- | vault 目錄的五個操作。
data VaultDir :: Effect where
  ListEntries :: FilePath -> VaultDir m [FilePath]
  MarkerDirExists :: FilePath -> VaultDir m Bool
  InitMarker :: FilePath -> VaultKind -> Text -> UTCTime -> VaultDir m (Either StoreError VaultMarker)
  RemoveMarkerDir :: FilePath -> VaultDir m ()
  RemoveIndexDb :: FilePath -> VaultDir m Bool

makeEffect_ ''VaultDir

-- | 目錄第一層的名字(空目錄判定、舊 marker 探測都只看這一層)。
listEntries :: VaultDir :> es => FilePath -> Eff es [FilePath]

-- | @.aapms@ 這個路徑存不存在(目錄或檔案都算佔用)。
markerDirExists :: VaultDir :> es => FilePath -> Eff es Bool

-- | 建 @.aapms\/config.toml@ 與空索引(graph-core 的 @initVaultAtWith@)。
initMarker :: VaultDir :> es => FilePath -> VaultKind -> Text -> UTCTime -> Eff es (Either StoreError VaultMarker)

-- | 撞號回滾:刪掉剛建的 @.aapms\/@。
removeMarkerDir :: VaultDir :> es => FilePath -> Eff es ()

-- | 刪 @index.db@,本來就沒有回 @False@ 不算失敗。
removeIndexDb :: VaultDir :> es => FilePath -> Eff es Bool

-- | 觀察:'VaultDir' 的純解譯器,回最終目錄樹。
runVaultDirPure :: VaultWorld -> Eff (VaultDir : es) a -> Eff es (a, VaultWorld)
runVaultDirPure _vw _act = error "P-005#runVaultDirPure stub"
