{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 中樞 @config.toml@ 與中樞目錄下那些檔的讀寫,寫成 effectful 的__效果描述__
-- (ADR-023)。
--
-- 中樞的__位置__、檔案的存在與否、全文的讀、原子的寫回、縮圖快取目錄的建立與
-- 清除,都是這個效果的操作;TOML 的解析與渲染是純的,住
-- "Aapms.Workspace.Hub"(P-028-hub-config)。
--
-- 純解譯器 'runHubFilePure' 跑在 'Aapms.Workspace.Types.HubWorld' 上:一個固定的
-- 中樞位置,加上「有沒有一份中樞文字」。真解譯器住
-- "Aapms.Workspace.Effect.HubFile.IO"。
module Aapms.Workspace.Effect.HubFile
  ( -- * 效果描述
    HubFile (..)

    -- * 操作(P-004-vault-scope、P-005-vault-lifecycle)
  , hubPath
  , readHub
  , hubExists
  , writeHub
  , ensureCacheDir
  , purgeHubFiles

    -- * 純解譯器(觀察點)
  , runHubFilePure
  ) where

import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Workspace.Types (HubLocation, HubWorld, WorkspaceError)

-- | 中樞檔的六個操作。
data HubFile :: Effect where
  HubPath :: HubFile m HubLocation
  ReadHub :: FilePath -> HubFile m (Either WorkspaceError Text)
  HubExists :: HubFile m Bool
  WriteHub :: Text -> HubFile m (Either WorkspaceError ())
  EnsureCacheDir :: HubFile m Bool
  PurgeHubFiles :: HubFile m (Bool, Int)

makeEffect_ ''HubFile

-- | @AAPMS_HOME@ 或平台預設,記下來源。
hubPath :: HubFile :> es => Eff es HubLocation

-- | 讀中樞檔全文;不存在回 'Aapms.Workspace.Types.HubNotFound'。
readHub :: HubFile :> es => FilePath -> Eff es (Either WorkspaceError Text)

-- | @config.toml@ 存不存在(@setup@ 不解析既有檔)。
hubExists :: HubFile :> es => Eff es Bool

-- | 原子寫回 @config.toml@。
writeHub :: HubFile :> es => Text -> Eff es (Either WorkspaceError ())

-- | 建 @cache\/thumbs@,回有沒有真的建。
ensureCacheDir :: HubFile :> es => Eff es Bool

-- | 刪 @config.toml@ 與縮圖快取,回刪了沒、刪幾張。
purgeHubFiles :: HubFile :> es => Eff es (Bool, Int)

-- | 觀察:'HubFile' 的純解譯器(固定位置、一份或沒有的中樞文字)。
runHubFilePure :: HubWorld -> Eff (HubFile : es) a -> Eff es a
runHubFilePure _hw _act = error "P-004#runHubFilePure stub"
