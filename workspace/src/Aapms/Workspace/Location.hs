-- | 中樞根目錄的解析與中樞目錄內的衍生路徑(design.md「內部模組劃分」的 Location)。
--
-- 擁有的事實(唯一真相來源):__中樞在哪__、中樞目錄的內部佈局
-- (@config.toml@、@cache\/thumbs\/@)。
--
-- 本模組只回答「路徑是什麼」,__不建立任何目錄或檔案__(那是 F004 的
-- @setupHub@),也不判斷路徑存不存在。除 'hubLocation' 讀環境變數與平台預設外,
-- 其餘三個函式都是純函式。
module Aapms.Workspace.Location
  ( hubLocation
  , configPath
  , thumbCacheDir
  , thumbCachePath
  ) where

import qualified Data.Text as T

import Aapms.Core.Asset (Sha256 (..))
import Aapms.Workspace.Types (HubLocation (..), HubSource (..))
import System.Directory (XdgDirectory (XdgConfig), getXdgDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

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

-- | 中樞註冊表檔案:@\<hlPath\>\/config.toml@。
--
-- 'Aapms.Workspace.Hub' 靠本函式取得檔案位置,__自己不解析中樞位置__
-- (design.md「模組間公開介面」的 @Hub → Location@)。
configPath :: HubLocation -> FilePath
configPath loc = hlPath loc </> "config.toml"

-- | 縮圖快取根目錄:@\<hlPath\>\/cache\/thumbs@(ADR-017 決策七,內容定址、跨
-- vault 共用)。
thumbCacheDir :: HubLocation -> FilePath
thumbCacheDir loc = hlPath loc </> "cache" </> "thumbs"

-- | 單一縮圖的路徑:@\<hlPath\>\/cache\/thumbs\/\<h 的前 2 個字元\>\/\<h\>.png@。
--
-- 分片是前兩碼、副檔名固定 @.png@;@h@ 是 64 位小寫十六進位。結果恒以
-- 'thumbCacheDir' 為前綴。
thumbCachePath :: HubLocation -> Sha256 -> FilePath
thumbCachePath loc (Sha256 h) =
  thumbCacheDir loc </> T.unpack (T.take 2 h) </> (T.unpack h <> ".png")
