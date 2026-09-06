{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 型別註冊表目錄的定位與讀取,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 只有兩個操作:三層定位(環境變數 → 執行檔旁 → cabal @data-files@,取第一個
-- 存在的)與「把那個目錄下全部 TOML 讀進來」。__解析是純的__,住
-- "Aapms.Types.Parse";本模組不解讀任何一個位元組。
--
-- 純解譯器 'runRegistryFsPure' 跑在 'Aapms.Types.Source.RegistryWorld' 上,
-- P-004-vault-scope 的開場因此在測試裡不必碰環境變數與磁碟。
module Aapms.Types.Effect.RegistryFs
  ( -- * 效果描述
    RegistryFs (..)

    -- * 操作(P-004-vault-scope)
  , locateRegistryDir
  , readRegistryFiles

    -- * 純解譯器(觀察點)
  , runRegistryFsPure
  ) where

import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Core.Registry (RegistryError)
import Aapms.Types.Source (RegistrySource, RegistryWorld)

-- | 註冊表目錄的兩個操作。
data RegistryFs :: Effect where
  LocateRegistryDir :: RegistryFs m (Either RegistryError (FilePath, RegistrySource))
  ReadRegistryFiles :: FilePath -> RegistryFs m (Either RegistryError [(FilePath, Text)])

makeEffect_ ''RegistryFs

-- | 環境變數 → 執行檔旁 → cabal @data-files@,取第一個存在的。
locateRegistryDir :: RegistryFs :> es => Eff es (Either RegistryError (FilePath, RegistrySource))

-- | 讀目錄下全部 TOML(含 @naming.toml@)。
readRegistryFiles :: RegistryFs :> es => FilePath -> Eff es (Either RegistryError [(FilePath, Text)])

-- | 觀察:'RegistryFs' 的純解譯器(三層各自有沒有、目錄裡的檔)。
runRegistryFsPure :: RegistryWorld -> Eff (RegistryFs : es) a -> Eff es a
runRegistryFsPure _rw _act = error "P-004#runRegistryFsPure stub"
