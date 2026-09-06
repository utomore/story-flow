{-# LANGUAGE DataKinds #-}

-- | 一次執行的開場(P-004-vault-scope)。
--
-- 擁有的事實(唯一真相來源):__開場的順序與失敗語彙__——中樞位置 → 讀 → 解析 →
-- 註冊表三層定位 → 讀 → 解析 → 驗證 → 'Session';三種設定錯誤(中樞載不起來、
-- 註冊表定位不到、註冊表不合規)都是硬錯,__不退回預設值__(system.md 全域錯誤
-- 策略第 3 條)。
--
-- 整條是 "Aapms.Workspace.Effect.HubFile" 與 "Aapms.Types.Effect.RegistryFs" 兩個
-- 效果的程式,__本模組一行 IO 都沒有__;'Aapms.Service.Monad.Env' 的可變部分
-- (handle 快取、鎖)是 shell 的事。
--
-- __selector 在這一層不解讀__,原樣交給 P-029-scope-resolve;裁決點只有一個,
-- 在 @aapms-workspace@。
module Aapms.Service.Session
  ( -- * 每次操作的裁決
    scopeOf

    -- * 純的整條
  , openSession
  ) where

import Data.Text (Text)
import Effectful (Eff, (:>))

import Aapms.Core.Registry (buildRegistry)
import Aapms.Service.Types (ServiceError (..), Session (..))
import Aapms.Types.Effect.RegistryFs (RegistryFs, locateRegistryDir, readRegistryFiles)
import Aapms.Types.Parse (aggregate, parseRegistryFiles)
import Aapms.Workspace.Effect.HubFile (HubFile, hubPath, readHub)
import Aapms.Workspace.Effect.Markers (Markers)
import Aapms.Workspace.Hub (parseHubText)
import Aapms.Workspace.Resolve (resolveScope)
import Aapms.Workspace.Types (HubLocation (hlPath), Scope, ScopeKind)

-- | 用 'Session' 的快照跑 P-029-scope-resolve 的裁決,
-- 'Aapms.Workspace.Types.WorkspaceError' 原樣包成
-- 'Aapms.Service.Types.WorkspaceFailed'。
scopeOf :: Markers :> es => Session -> ScopeKind -> Eff es (Either ServiceError Scope)
scopeOf s k =
  fmap (either (Left . WorkspaceFailed) Right) $
    resolveScope (sessionHub s) k (sessionSelector s) (sessionCwd s)

-- | 純的整條:中樞位置 → 讀中樞 → 解析成 'Aapms.Workspace.Types.Hub' → 註冊表
-- 三層定位 → 讀全部 TOML → 解析 → 驗證成註冊表 → 'Session'。
--
-- 任一步失敗即失敗:中樞的兩種錯誤原樣包成
-- 'Aapms.Service.Types.WorkspaceFailed';註冊表定位不到是
-- 'Aapms.Service.Types.RegistryUnavailable',其餘註冊表失敗是
-- 'Aapms.Service.Types.RegistryLoadFailed'。
openSession
  :: (HubFile :> es, RegistryFs :> es)
  => Maybe Text
  -> FilePath
  -> Eff es (Either ServiceError Session)
openSession sel cwd = do
  loc <- hubPath
  textResult <- readHub
  case textResult of
    Left err -> pure (Left (WorkspaceFailed err))
    Right txt -> case parseHubText (hlPath loc) txt of
      Left err -> pure (Left (WorkspaceFailed err))
      Right hub -> do
        located <- locateRegistryDir
        case located of
          Left err -> pure (Left (RegistryUnavailable err))
          Right (dir, src) -> do
            filesResult <- readRegistryFiles dir
            pure $ case filesResult of
              Left err -> Left (RegistryLoadFailed err)
              Right files -> case parseRegistryFiles files of
                Left err -> Left (RegistryLoadFailed err)
                Right (decls, vocab) -> case buildRegistry decls of
                  Left errs -> Left (RegistryLoadFailed (aggregate errs))
                  Right registry ->
                    Right
                      Session
                        { sessionHub = hub
                        , sessionLocation = loc
                        , sessionRegistry = registry
                        , sessionNaming = vocab
                        , sessionSource = src
                        , sessionSelector = sel
                        , sessionCwd = cwd
                        }
