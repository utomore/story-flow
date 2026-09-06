{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | vault marker 的讀取與路徑探測,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 只有四個操作:讀一個 vault 根目錄的 marker、問路徑是不是既存目錄、正規化、
-- 從起點向上找最近一層有 @.aapms\/@ 的。P-029-scope-resolve 的裁決是這個效果的
-- 程式,純解譯器 'runMarkersPure' 跑在一張「路徑 → marker 讀數」的表上
-- ('Aapms.Workspace.Types.MarkerWorld'),qa 因此不必碰磁碟。
--
-- __它不開索引、不寫任何檔__:真解譯器住 "Aapms.Workspace.Effect.Markers.IO",
-- 這一層只有描述。
module Aapms.Workspace.Effect.Markers
  ( -- * 效果描述
    Markers (..)

    -- * 操作(P-029-scope-resolve、P-005-vault-lifecycle、P-006-workspace-doctor)
  , readMarkerAt
  , dirExists
  , canonicalPath
  , detectRoot

    -- * 純解譯器(觀察點)
  , runMarkersPure
  ) where

import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Store.Types (StoreError, VaultMarker)
import Aapms.Workspace.Types (MarkerWorld)

-- | marker 的四個操作。
data Markers :: Effect where
  ReadMarkerAt :: FilePath -> Markers m (Either StoreError VaultMarker)
  DirExists :: FilePath -> Markers m Bool
  CanonicalPath :: FilePath -> Markers m FilePath
  DetectRoot :: FilePath -> Markers m (Maybe FilePath)

makeEffect_ ''Markers

-- | 讀一個 vault 根目錄的 marker。
readMarkerAt :: Markers :> es => FilePath -> Eff es (Either StoreError VaultMarker)

-- | 路徑是不是既存目錄。
dirExists :: Markers :> es => FilePath -> Eff es Bool

-- | 正規化(解 symlink、Windows 短檔名)。
canonicalPath :: Markers :> es => FilePath -> Eff es FilePath

-- | 從起點向上找最近一層有 @.aapms\/@ 目錄的;到根都沒有回 @Nothing@。
detectRoot :: Markers :> es => FilePath -> Eff es (Maybe FilePath)

-- | 觀察:'Markers' 的純解譯器,跑在記憶體的路徑表上,正規化是恆等。
runMarkersPure :: MarkerWorld -> Eff (Markers : es) a -> Eff es a
runMarkersPure _w _act = error "P-029#runMarkersPure stub"
