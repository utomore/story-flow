{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | "Aapms.Workspace.Effect.Markers" 的__真解譯器__(shell)。
--
-- 效果的描述是純資料,住 effects 層;__執行__它的這一個住 shell:@directory@ 的
-- @canonicalizePath@ \/ @doesDirectoryExist@ 與 graph-core 的 @readMarker@。
--
-- __不動檔案系統__:不建 @.aapms@、不開 @index.db@、不修補 marker、不寫中樞
-- (P-029 的決定,由 shell 的內部測試守)。四個操作全部是查詢,本模組沒有任何
-- 建立、修改或刪除。
module Aapms.Workspace.Effect.Markers.IO
  ( runMarkersIO
  ) where

import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.FilePath (takeDirectory)

import Aapms.Store.Marker (markerDir, readMarker)
import Aapms.Workspace.Effect.Markers (Markers (..))

-- | 以真的檔案系統跑 'Markers'。
--
-- 四個操作逐一對照舊碼("Aapms.Workspace.Discovery"):
--
-- * @ReadMarkerAt@ → 'Aapms.Store.Marker.readMarker'(@.aapms\/config.toml@;
--   讀不到與解不開都是 'Aapms.Store.Types.StoreError' 的原件,這一層不翻譯)
-- * @DirExists@ → 'System.Directory.doesDirectoryExist'(__目錄__才算;同名的
--   普通檔案不算)
-- * @CanonicalPath@ → 'System.Directory.canonicalizePath'(解 symlink、Windows
--   短檔名);路徑不存在時它仍然給得出絕對路徑,不拋
-- * @DetectRoot@ → 舊碼 @detectVault@:起點先正規化再逐層
--   'System.FilePath.takeDirectory' 往上,回__第一個__含 @.aapms\/@ __目錄__的
--   那一層(已正規化的絕對路徑);走到不動點都沒有就是 @Nothing@。起點自己那
--   一層也算命中
runMarkersIO :: IOE :> es => Eff (Markers : es) a -> Eff es a
runMarkersIO = interpret $ \_ op -> liftIO $ case op of
  ReadMarkerAt p -> readMarker p
  DirExists p -> doesDirectoryExist p
  CanonicalPath p -> canonicalizePath p
  DetectRoot p -> canonicalizePath p >>= climb

-- | 私有:自一個__已正規化__的目錄逐層往上找 @.aapms\/@。
climb :: FilePath -> IO (Maybe FilePath)
climb d = do
  hit <- doesDirectoryExist (markerDir d)
  if hit
    then pure (Just d)
    else
      let up = takeDirectory d
      in if up == d then pure Nothing else climb up
