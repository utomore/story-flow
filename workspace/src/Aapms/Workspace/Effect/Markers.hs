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
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.TH (makeEffect_)
import System.FilePath (equalFilePath, takeDirectory, (</>))

import Aapms.Store.Types (StoreError (..), VaultMarker)
import Aapms.Workspace.Types (MarkerWorld, worldDirs, worldMarker)

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
--
-- 四個操作的純語意:
--
-- * @ReadMarkerAt@ 直接查 'Aapms.Workspace.Types.worldMarker';路徑不在表上 =
--   那裡沒有 marker 檔,回 'Aapms.Store.Types.VaultMarkerMissing',與真解譯器
--   讀不到 @.aapms\/config.toml@ 時同一個建構子。
-- * @DirExists@ 查 'Aapms.Workspace.Types.worldDirs'。比對走
--   'System.FilePath.equalFilePath' 而不是逐字相等:世界的目錄清單是字面字串,
--   而本模組自己拼 @.aapms@ 時會用平台的分隔符,兩種寫法要指到同一個目錄。
-- * @CanonicalPath@ 是__恆等__:純世界裡沒有 symlink 也沒有短檔名。
-- * @DetectRoot@ 逐層 'System.FilePath.takeDirectory' 往上,回第一層有
--   @.aapms@ 目錄的;走到不動點(@up == d@)就是 @Nothing@。起點自己那一層
--   也算命中,所以它是冪等的。
runMarkersPure :: MarkerWorld -> Eff (Markers : es) a -> Eff es a
runMarkersPure w = interpret $ \_ op -> case op of
  ReadMarkerAt p -> pure (markerIn p)
  DirExists p -> pure (dirIn p)
  CanonicalPath p -> pure p
  DetectRoot p -> pure (climb p)
  where
    markerIn p = case worldMarker w p of
      Just r -> r
      Nothing -> Left (VaultMarkerMissing (p </> ".aapms" </> "config.toml"))

    dirIn p = any (equalFilePath p) (worldDirs w)

    climb d
      | dirIn (d </> ".aapms") = Just d
      | up == d = Nothing
      | otherwise = climb up
      where
        up = takeDirectory d
