{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | "Aapms.Types.Effect.RegistryFs" 的__真解譯器__(shell)。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',效果真的
-- 發生在這裡。效果的__描述__與純解譯器
-- ('Aapms.Types.Effect.RegistryFs.runRegistryFsPure')住 effects 層,兩者不共用
-- 模組(ADR-023-effectful-effects-layer)。
--
-- __一個位元組都不解讀__:三層定位與「把 TOML 讀進來」是這裡的事,解析是純的,
-- 住 "Aapms.Types.Parse"。
module Aapms.Types.Effect.RegistryFs.IO
  ( runRegistryFsIO
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))

import Aapms.Core.Registry (RegistryError (RegistryDirMissing, TomlParseError))
import Aapms.Types.Effect.RegistryFs (RegistryFs (..))
import Aapms.Types.Loader (locateRegistry)
import Aapms.Types.Parse (aggregate)

-- | 以真的環境變數與檔案系統跑 'RegistryFs'。
--
-- 兩個操作逐一對照舊碼("Aapms.Types.Loader"):
--
-- * @LocateRegistryDir@ → 'Aapms.Types.Loader.locateRegistry' 的三層(環境變數 →
--   執行檔旁 → cabal @data-files@,取第一個__真的存在__的);三層都沒有回
--   'Aapms.Core.Registry.RegistryNotFound' 並列出查過的路徑
-- * @ReadRegistryFiles@ → 目錄下全部 @*.toml@ 的 @(路徑, 全文)@,__檔名排序__、
--   __含 @naming.toml@__(那份要不要另外對待由 'Aapms.Types.Parse.parseRegistryFiles'
--   決定,本層不分辨);目錄不在回 'Aapms.Core.Registry.RegistryDirMissing',
--   讀不進來或不是 UTF-8 回 'Aapms.Core.Registry.TomlParseError'(逐檔各一則,
--   經 'Aapms.Types.Parse.aggregate' 收成一則,與舊碼 @readSpec@ 同一套訊息)
runRegistryFsIO :: IOE :> es => Eff (RegistryFs : es) a -> Eff es a
runRegistryFsIO = interpret $ \_ op -> liftIO $ case op of
  LocateRegistryDir -> locateRegistry
  ReadRegistryFiles dir -> readTomlFiles dir

-- | 私有:一個註冊表目錄裡全部 @*.toml@ 的全文,檔名排序。
readTomlFiles :: FilePath -> IO (Either RegistryError [(FilePath, Text)])
readTomlFiles dir = do
  ok <- doesDirectoryExist dir
  if not ok
    then pure (Left (RegistryDirMissing dir))
    else do
      names <- listDirectory dir
      let files = sort [dir </> n | n <- names, takeExtension n == ".toml"]
      results <- mapM readUtf8 files
      let (errs, oks) = partitionEithers results
      pure $ if null errs then Right oks else Left (aggregate errs)

-- | 私有:把一個檔案讀成 UTF-8 全文;讀不到或解不開一律
-- 'Aapms.Core.Registry.TomlParseError'(訊息帶檔名,ADR-005)。
readUtf8 :: FilePath -> IO (Either RegistryError (FilePath, Text))
readUtf8 fp = do
  raw <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
  pure $ case raw of
    Left e -> Left (TomlParseError fp (T.pack (show e)))
    Right bytes -> case TE.decodeUtf8' bytes of
      Left e -> Left (TomlParseError fp ("檔案不是合法的 UTF-8:" <> T.pack (show e)))
      Right txt -> Right (fp, txt)
