-- | 中樞根目錄的解析與中樞目錄內的衍生路徑(design.md「內部模組劃分」的 Location)。
--
-- 擁有的事實(唯一真相來源):__中樞在哪__、中樞目錄的內部佈局
-- (@config.toml@、@cache\/thumbs\/@)。
--
-- 本模組只回答「路徑是什麼」,__不建立任何目錄或檔案__(那是 F004 的
-- @setupHub@),也不判斷路徑存不存在。三個函式__全部是純函式__:讀環境變數與
-- 平台預設的 'Aapms.Workspace.Hub.File.hubLocation' 住 "Aapms.Workspace.Hub.File",
-- 本模組因此不 import 任何 IO 模組。
module Aapms.Workspace.Location
  ( configPath
  , thumbCacheDir
  , thumbCachePath
  ) where

import qualified Data.Text as T

import Aapms.Core.Asset (Sha256 (..))
import Aapms.Workspace.Types (HubLocation (..), hubConfigPath)
import System.FilePath ((</>))

-- | 中樞註冊表檔案:@\<hlPath\>\/config.toml@。
--
-- 'Aapms.Workspace.Hub' 靠本函式取得檔案位置,__自己不解析中樞位置__
-- (design.md「模組間公開介面」的 @Hub → Location@)。
--
-- P-004-vault-scope REV-3 起這個事實由觀察點
-- 'Aapms.Workspace.Types.hubConfigPath' 擁有(它得住 types 層才能寫進 law),
-- 本函式是它的別名,現有呼叫端因此不必跟著搬。
configPath :: HubLocation -> FilePath
configPath = hubConfigPath

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
