-- | 中樞的落地層:中樞根目錄在哪(環境變數與平台預設),以及 @config.toml@ 的
-- 讀進來與原子寫回去。
--
-- 這是 "Aapms.Workspace.Hub" 與 "Aapms.Workspace.Location" 裡__唯一碰 IO__ 的
-- 那三個函式的家。那兩個模組因此是純的:前者只做「文字 ↔ 'Hub' 值」
-- ('Aapms.Workspace.Hub.parseHubText' \/ 'Aapms.Workspace.Hub.renderHub'),
-- 後者只做「路徑是什麼」('Aapms.Workspace.Location.configPath' \/
-- 'Aapms.Workspace.Location.thumbCacheDir' \/
-- 'Aapms.Workspace.Location.thumbCachePath')。
--
-- 本模組__不 re-export 任何純函式__:要解析或序列化的呼叫端直接 import
-- "Aapms.Workspace.Hub",要衍生路徑的直接 import "Aapms.Workspace.Location"。
--
-- __不建立任何目錄或檔案__:'saveHub' 只覆寫既有位置的 @config.toml@,中樞目錄
-- 與 @cache\/@ 的建立是 F004 的 @setupHub@。
module Aapms.Workspace.Hub.File
  ( -- * 中樞在哪
    hubLocation

    -- * 載入與寫回
  , loadHub
  , saveHub
  ) where

import qualified Data.Text as T

import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (renderStoreError)
import Aapms.Workspace.Hub (parseHubText, renderHub)
import Aapms.Workspace.Location (configPath)
import Aapms.Workspace.Types
  ( Hub
  , HubLocation (..)
  , HubSource (..)
  , WorkspaceError (..)
  )
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory, makeAbsolute)
import System.Environment (lookupEnv)

-- 中樞在哪 -------------------------------------------------------------------

-- | 解析中樞根目錄,順序固定兩層,__沒有第三層、不搜尋、不猜__:
--
-- 1. 環境變數 @AAPMS_HOME@ 已設且非空 → 用它(絕對化),
--    @'Aapms.Workspace.Types.hlSource' == 'Aapms.Workspace.Types.FromEnv'@
-- 2. 否則平台預設(Windows @%APPDATA%\\aapms@;其他平台 XDG
--    @$XDG_CONFIG_HOME\/aapms@,該變數未設時 @~\/.config\/aapms@),
--    @hlSource == 'Aapms.Workspace.Types.FromPlatformDefault'@
--
-- @AAPMS_HOME@ 設為__空字串__視同未設,走第 2 層。
hubLocation :: IO HubLocation
hubLocation = do
  mEnv <- lookupEnv "AAPMS_HOME"
  case mEnv of
    Just raw | not (T.null (T.strip (T.pack raw))) -> do
      abs' <- makeAbsolute raw
      pure (HubLocation abs' FromEnv)
    _ -> do
      dir <- getXdgDirectory XdgConfig "aapms"
      pure (HubLocation dir FromPlatformDefault)

-- 讀 -----------------------------------------------------------------------

-- | 讀 @\<hlPath\>\/config.toml@ 並解析四段。
--
-- * 檔案不存在 → @Left ('Aapms.Workspace.Types.HubNotFound' fp)@,
--   __不回空中樞__(system.md 全域錯誤策略第 3 條)
-- * 讀不進來或 TOML 解不開 → @Left ('Aapms.Workspace.Types.HubUnreadable' fp _)@
-- * 解得開但欄位不合規 → @Left ('Aapms.Workspace.Types.HubMalformed' fp _)@
--
-- 成功時 'Aapms.Workspace.Types.hubSourceText' 帶著這次讀到的原始檔案文字,
-- 'saveHub' 靠它保住註解與空白行。
loadHub :: HubLocation -> IO (Either WorkspaceError Hub)
loadHub loc = do
  let fp = configPath loc
  exists <- doesFileExist fp
  if not exists
    then pure (Left (HubNotFound fp))
    else do
      txtR <- readTextFile fp
      case txtR of
        Left e -> pure (Left (HubUnreadable fp (renderStoreError e)))
        Right txt -> pure (parseHubText fp txt)

-- 寫 -----------------------------------------------------------------------

-- | 把 'Hub' 原子寫回 @\<hlPath\>\/config.toml@(沿用
-- 'Aapms.Store.Atomic.atomicWriteText',__不另寫一份__)。
--
-- __既有列的相對順序、使用者寫的註解與空白行原樣保留__(ADR-017 決策二的
-- 「可手寫」):序列化由 'Aapms.Workspace.Hub.renderHub' 負責,本函式只把它的
-- 結果落地。寫入失敗回 @Left ('Aapms.Workspace.Types.HubWriteFailed' fp _)@。
saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())
saveHub loc hub = do
  let fp = configPath loc
  r <- atomicWriteText fp (renderHub hub)
  pure $ case r of
    Left e -> Left (HubWriteFailed fp (renderStoreError e))
    Right () -> Right ()
