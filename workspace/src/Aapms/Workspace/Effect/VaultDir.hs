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

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful (Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, modify, runState)
import Effectful.TH (makeEffect_)

import Aapms.Core.Id (IdPrefix (PVlt), VaultId (..), newId, renderId)
import Aapms.Store.Types (StoreError (VaultAlreadyInitialized), VaultKind, VaultMarker (..))
import Aapms.Workspace.Types (VaultWorld (..), vwEntries, vwHasIndex, vwMarkerDir)

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
--
-- 五個操作的純語意都跑在 'Aapms.Workspace.Types.VaultWorld' 上:
--
-- * @ListEntries@ \/ @MarkerDirExists@ 是純查詢
--   ('Aapms.Workspace.Types.vwEntries' \/ 'Aapms.Workspace.Types.vwMarkerDir'),
--   不在表上的路徑分別是空清單與 @False@。
-- * @InitMarker@ 與 graph-core 的 @initVaultAtWith__逐欄同語意__:id 是
--   @'newId' 'PVlt' name t 0@、@kind@ \/ @name@ 是傳進來的、@refs@ 是空的;
--   目標目錄的第一層__追加一個 @.aapms@__(目錄本來不存在時順手建出來,同
--   @createDirectoryIfMissing True@),marker 讀得到,@index.db@ 出現。已經被
--   佔用時回 'Aapms.Store.Types.VaultAlreadyInitialized' 而不是覆寫。
-- * @RemoveMarkerDir@ 是 @InitMarker@ 的__回滾__:那一層的 @.aapms@ 名字、
--   marker 讀數、佔用旗標與 @index.db@ 一起消失(@index.db@ 住在 @.aapms\/@
--   裡面),但__目錄本身留著__——真解譯器的
--   @removePathForcibly (markerDir dir)@ 也只刪 @.aapms\/@ 那一棵。
-- * @RemoveIndexDb@ 只拿掉 @index.db@,回「本來在不在」;marker 與目錄第一層
--   都不動(P-005-vault-lifecycle LAW-10)。
--
-- 每個操作都只改自己那個路徑的那幾格,所以「其餘目錄樹不動」
-- ('Aapms.Workspace.Types.vwWithout' 的比較)在純側成立。
runVaultDirPure :: VaultWorld -> Eff (VaultDir : es) a -> Eff es (a, VaultWorld)
runVaultDirPure vw0 = reinterpret (runState vw0) $ \_ op -> case op of
  ListEntries d -> gets (`vwEntries` d)
  MarkerDirExists d -> gets (`vwMarkerDir` d)
  InitMarker d k name t -> do
    occupied <- gets (`vwMarkerDir` d)
    if occupied
      then pure (Left (VaultAlreadyInitialized d))
      else do
        let m = VaultMarker (VaultId (renderId (newId PVlt name t 0))) k name []
        modify (createMarkerAt d m)
        pure (Right m)
  RemoveMarkerDir d -> modify (dropMarkerAt d)
  RemoveIndexDb d -> do
    had <- gets (`vwHasIndex` d)
    modify (\w -> w {vwIndexDbs = Set.delete d (vwIndexDbs w)})
    pure had
  where
    createMarkerAt d m w =
      w
        { vwTree = Map.insert d (Map.findWithDefault [] d (vwTree w) ++ [markerName]) (vwTree w)
        , vwMarkers = Map.insert d (Right m) (vwMarkers w)
        , vwMarkerDirs = Set.insert d (vwMarkerDirs w)
        , vwIndexDbs = Set.insert d (vwIndexDbs w)
        }

    dropMarkerAt d w =
      w
        { vwTree = Map.adjust (filter (/= markerName)) d (vwTree w)
        , vwMarkers = Map.delete d (vwMarkers w)
        , vwMarkerDirs = Set.delete d (vwMarkerDirs w)
        , vwIndexDbs = Set.delete d (vwIndexDbs w)
        }

    markerName = ".aapms"
