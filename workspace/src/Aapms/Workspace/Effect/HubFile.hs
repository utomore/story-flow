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

import Data.Maybe (isJust)
import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (gets, modify, runState)
import Effectful.TH (makeEffect_)

import Aapms.Workspace.Types
  ( HubLocation
  , HubWorld (..)
  , WorkspaceError (HubNotFound)
  , hubConfigPath
  )

-- | 中樞檔的六個操作。
data HubFile :: Effect where
  HubPath :: HubFile m HubLocation
  ReadHub :: HubFile m (Either WorkspaceError Text)
  HubExists :: HubFile m Bool
  WriteHub :: Text -> HubFile m (Either WorkspaceError ())
  EnsureCacheDir :: HubFile m (Either WorkspaceError Bool)
  PurgeHubFiles :: HubFile m (Bool, Int)

makeEffect_ ''HubFile

-- | @AAPMS_HOME@ 或平台預設,記下來源。
hubPath :: HubFile :> es => Eff es HubLocation

-- | 讀__這個效果所綁的__中樞檔全文;不存在回
-- 'Aapms.Workspace.Types.HubNotFound',路徑是
-- 'Aapms.Workspace.Types.hubConfigPath' 算出的 @config.toml@
-- (P-004-vault-scope REV-3:讀哪一個檔由效果的資源決定,不由呼叫端傳)。
readHub :: HubFile :> es => Eff es (Either WorkspaceError Text)

-- | @config.toml@ 存不存在(@setup@ 不解析既有檔)。
hubExists :: HubFile :> es => Eff es Bool

-- | 原子寫回 @config.toml@。
writeHub :: HubFile :> es => Text -> Eff es (Either WorkspaceError ())

-- | 建 @cache\/thumbs@,回有沒有真的建;建不出來回
-- 'Aapms.Workspace.Types.HubWriteFailed'(真解譯器),純解譯器恆 @Right@
-- (P-005-vault-lifecycle REV-3)。
ensureCacheDir :: HubFile :> es => Eff es (Either WorkspaceError Bool)

-- | 刪 @config.toml@ 與縮圖快取,回刪了沒、刪幾張。
purgeHubFiles :: HubFile :> es => Eff es (Bool, Int)

-- | 觀察:'HubFile' 的純解譯器(固定位置、一份或沒有的中樞文字),__回最終的
-- 中樞世界__(P-004-vault-scope REV-1;與 'Aapms.Workspace.Effect.VaultDir.runVaultDirPure'
-- 同形)。
--
-- 六個操作的純語意都跑在 'Aapms.Workspace.Types.HubWorld' 上:
--
-- * @HubPath@ 是世界裡那個固定位置,不查環境變數。
-- * @ReadHub@ 有文字就是它,沒有就是
--   'Aapms.Workspace.Types.HubNotFound'——路徑是
--   @'Aapms.Workspace.Types.hubConfigPath' ('Aapms.Workspace.Types.hubLocationIn' hw)@,
--   與真解譯器讀不到 @config.toml@ 時同一個建構子__且同一個字串__
--   (P-004-vault-scope REV-3、LAW-1)。
-- * @HubExists@ 就是「有沒有那份文字」。
-- * @WriteHub@ 原子覆寫:世界的文字換成新的,永遠成功(純世界沒有磁碟會滿)。
-- * @EnsureCacheDir@ 回 @Right@「__本來不在才建__」
--   ('Aapms.Workspace.Types.cacheDirIn' 的否定),之後世界的
--   'Aapms.Workspace.Types.cacheDirIn' 是 @True@——所以它是冪等的
--   (P-004-vault-scope REV-2;P-005-vault-lifecycle LAW-1 的第二次 setup 兩個
--   Bool 都要是 @False@)。__純世界永遠 @Right@__(沒有磁碟會滿),失敗通道只在
--   真解譯器上發生(P-005-vault-lifecycle REV-3)。
-- * @PurgeHubFiles@ 刪中樞文字與__整棵__縮圖快取,回「原本有沒有那份檔」與
--   'Aapms.Workspace.Types.thumbsIn' 的長度;之後世界的 'Aapms.Workspace.Types.hubTextIn'
--   是 @Nothing@、'Aapms.Workspace.Types.thumbsIn' 是空的、
--   'Aapms.Workspace.Types.cacheDirIn' 是 @False@(快取目錄本身一起拿掉,與舊碼
--   @Aapms.Workspace.Lifecycle.purge@ 的 @removeTreeForcibly@ 同語意)。再跑一次
--   因此是 @(False, 0)@(P-005-vault-lifecycle LAW-13)。
runHubFilePure :: HubWorld -> Eff (HubFile : es) a -> Eff es (a, HubWorld)
runHubFilePure hw0 = reinterpret (runState hw0) $ \_ op -> case op of
  HubPath -> gets hubLocationIn
  ReadHub -> gets readIn
  HubExists -> gets (isJust . hubTextIn)
  WriteHub t -> do
    modify (\w -> w {hubTextIn = Just t})
    pure (Right ())
  EnsureCacheDir -> do
    made <- gets (not . cacheDirIn)
    modify (\w -> w {cacheDirIn = True})
    pure (Right made)
  PurgeHubFiles -> do
    had <- gets (isJust . hubTextIn)
    n <- gets (length . thumbsIn)
    modify (\w -> w {hubTextIn = Nothing, cacheDirIn = False, thumbsIn = []})
    pure (had, n)
  where
    readIn w =
      maybe (Left (HubNotFound (hubConfigPath (hubLocationIn w)))) Right (hubTextIn w)
