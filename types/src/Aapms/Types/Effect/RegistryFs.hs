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
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.TH (makeEffect_)

import Aapms.Core.Registry (RegistryError (RegistryNotFound))
import Aapms.Types.Source (RegistrySource, RegistryWorld, registryDirIn, registryFilesIn)

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
--
-- 兩個操作的純語意:
--
-- * @LocateRegistryDir@ 直接看 'Aapms.Types.Source.registryDirIn':有就是「第一個
--   存在的那一層」,@Nothing@ = 三層都定位不到,回
--   'Aapms.Core.Registry.RegistryNotFound'(與真解譯器同一個建構子;純世界沒有
--   候選路徑可列,清單是空的)。
-- * @ReadRegistryFiles@ 回 'Aapms.Types.Source.registryFilesIn',__保序__。世界
--   只有一個註冊表目錄,所以參數不影響結果:讀誰由上一步決定,這一步只把
--   位元組交出去,一個都不解讀。
runRegistryFsPure :: RegistryWorld -> Eff (RegistryFs : es) a -> Eff es a
runRegistryFsPure rw = interpret $ \_ op -> case op of
  LocateRegistryDir -> pure (maybe (Left (RegistryNotFound [])) Right (registryDirIn rw))
  ReadRegistryFiles _dir -> pure (Right (registryFilesIn rw))
