{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | "Aapms.Workspace.Effect.ToolProbe" 的__真解譯器__(shell)。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',效果真的
-- 發生在這裡。效果的__描述__與純解譯器
-- ('Aapms.Workspace.Effect.ToolProbe.runToolProbePure')住 effects 層,兩者不共用
-- 模組(ADR-023-effectful-effects-layer)。
--
-- __不執行找到的檔案__:不查版本、不測試解壓能力,所以本模組一個外部行程都不啟動;
-- 也__不建立、不修改、不刪除任何檔案或目錄__(P-006-workspace-doctor 的「診斷唯讀」)。
module Aapms.Workspace.Effect.ToolProbe.IO
  ( runToolProbeIO
  ) where

import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory (doesFileExist, executable, getPermissions)
import System.Environment (lookupEnv)
import System.FilePath (splitSearchPath)

import Aapms.Workspace.Effect.ToolProbe (ToolProbe (..))

-- | 以真的檔案系統與真的 @PATH@ 跑 'ToolProbe'。
--
-- 兩個操作逐一對照舊碼(@Aapms.Workspace.Tools@):
--
-- * @IsExecutable@ → 舊碼的 @qualifies@:先問
--   'System.Directory.doesFileExist',為真才問
--   'System.Directory.getPermissions' 的 'System.Directory.executable'。
--   __順序不可調換__——@getPermissions@ 對不存在的路徑會拋例外,而這個 op 沒有
--   失敗通道。目錄不算:@doesFileExist@ 對目錄就是 @False@。平台差異(Windows
--   看副檔名、POSIX 看 @access@ 的 x 位元)__委給 @directory@__,本模組不自己判
--   副檔名、不讀 ACL
-- * @PathDirs@ → @PATH@ 環境變數經 'System.FilePath.splitSearchPath' 拆開,
--   __保序__;該變數未設時是空清單(不是失敗)
runToolProbeIO :: IOE :> es => Eff (ToolProbe : es) a -> Eff es a
runToolProbeIO = interpret $ \_ op -> liftIO $ case op of
  IsExecutable p -> qualifies p
  PathDirs -> maybe [] splitSearchPath <$> lookupEnv "PATH"

-- | 私有:「存在且可執行」判準(舊碼 @Aapms.Workspace.Tools.qualifies@)。
qualifies :: FilePath -> IO Bool
qualifies p = do
  exists <- doesFileExist p
  if exists then executable <$> getPermissions p else pure False
