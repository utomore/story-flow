{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | "Aapms.Workspace.Effect.HubFile" 的__真解譯器__(shell)。
--
-- 中樞位置由 'Aapms.Workspace.Types.HubLocation' 傳進來(@AAPMS_HOME@ 或平台
-- 預設在進入點解析一次,見 'Aapms.Workspace.Hub.File.hubLocation'),檔案的讀寫走
-- @directory@ 與原子寫入。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',效果真的
-- 發生在這裡。效果的__描述__與純解譯器
-- ('Aapms.Workspace.Effect.HubFile.runHubFilePure')住 effects 層,兩者不共用模組
-- (ADR-023-effectful-effects-layer)。
--
-- __與純解譯器的分工__:純世界裡「中樞檔」只有一份,
-- 'Aapms.Workspace.Types.HubWorld' 直接捧著它的文字,@ReadHub@ 的路徑參數因此只是
-- __錯誤訊息的標籤__(純解譯器把它原樣放進
-- 'Aapms.Workspace.Types.HubNotFound')。本模組的實體與標籤__都__是這個位置底下的
-- @config.toml@('Aapms.Workspace.Location.configPath'):
-- 'Aapms.Service.Session.openSession' 傳進來的是 'Aapms.Workspace.Types.hlPath',
-- 而在真實世界那是中樞__根目錄__,拿它當錯誤訊息會叫使用者去看一個目錄。
-- 兩邊因此在「錯誤裡印哪一個路徑」上有一格差(見回報的 GAP-1);「檔在不在、
-- 讀不讀得到、內容是什麼」的語意完全相同。
module Aapms.Workspace.Effect.HubFile.IO
  ( runHubFileIO
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath (takeDirectory, (</>))

import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (renderStoreError)
import Aapms.Workspace.Effect.HubFile (HubFile (..))
import Aapms.Workspace.Location (configPath, thumbCacheDir)
import Aapms.Workspace.Types (HubLocation, WorkspaceError (..))

-- | 以真的檔案系統跑 'HubFile'。
--
-- 六個操作逐一對照舊碼("Aapms.Workspace.Hub.File" 與
-- @Aapms.Workspace.Lifecycle@ 的 @setupHub@ \/ @purge@):
--
-- * @HubPath@ → 資源參數原樣捧出;位置的解析在進入點只做一次,本層不再查環境變數
-- * @ReadHub@ → 檔案不在回 'Aapms.Workspace.Types.HubNotFound',讀不進來回
--   'Aapms.Workspace.Types.HubUnreadable'(訊息委派
--   'Aapms.Store.Error.renderStoreError',這一層不翻譯);__解析不在這裡__,
--   那是 "Aapms.Workspace.Hub" 的純函式
-- * @HubExists@ → 'System.Directory.doesFileExist',__不解析既有檔__
-- * @WriteHub@ → 先把中樞根目錄建出來(對照舊 @setupHub@:第一次 setup 時那個
--   目錄還不存在,少了這一步連暫存檔都開不起來),再
--   'Aapms.Store.Atomic.atomicWriteText'(暫存檔 + rename)
-- * @EnsureCacheDir@ → 回「__本來不在才建__」,與純解譯器同一個 'Bool'
-- * @PurgeHubFiles@ → 先數快取樹底下的檔案數,再刪 @config.toml@ 與__整棵__
--   @cache\/thumbs@(對照舊 @purge@ 的 @removePathForcibly@);
--   @library\/@ 與任何 @.md@ 一律不碰
runHubFileIO :: IOE :> es => HubLocation -> Eff (HubFile : es) a -> Eff es a
runHubFileIO loc = interpret $ \_ op -> liftIO $ case op of
  HubPath -> pure loc
  ReadHub p -> readHubFile p
  HubExists -> doesFileExist hubFile
  WriteHub txt -> writeHubFile txt
  EnsureCacheDir -> ensureCache
  PurgeHubFiles -> purgeFiles
  where
    hubFile = configPath loc
    thumbsDir = thumbCacheDir loc

    -- 路徑參數只用來確認呼叫端問的是「這個位置的中樞檔」;錯誤裡印的是
    -- 真的那一個檔(舊碼 @Aapms.Workspace.Hub.File.loadHub@ 的兩個建構子)。
    readHubFile :: FilePath -> IO (Either WorkspaceError Text)
    readHubFile _p = do
      exists <- doesFileExist hubFile
      if not exists
        then pure (Left (HubNotFound hubFile))
        else do
          r <- readTextFile hubFile
          pure $ case r of
            Left e -> Left (HubUnreadable hubFile (renderStoreError e))
            Right txt -> Right txt

    writeHubFile :: Text -> IO (Either WorkspaceError ())
    writeHubFile txt = do
      mk <- try (createDirectoryIfMissing True (takeDirectory hubFile))
      case mk :: Either IOException () of
        Left e -> pure (Left (HubWriteFailed hubFile (T.pack (show e))))
        Right () -> do
          r <- atomicWriteText hubFile txt
          pure $ case r of
            Left e -> Left (HubWriteFailed hubFile (renderStoreError e))
            Right () -> Right ()

    ensureCache :: IO Bool
    ensureCache = do
      existed <- doesDirectoryExist thumbsDir
      if existed
        then pure False
        else do
          createDirectoryIfMissing True thumbsDir
          pure True

    purgeFiles :: IO (Bool, Int)
    purgeFiles = do
      hubExisted <- doesFileExist hubFile
      thumbCount <- countFiles thumbsDir
      if hubExisted then removeFile hubFile else pure ()
      removePathForcibly thumbsDir
      pure (hubExisted, thumbCount)

-- | 私有:遞迴數某個目錄樹底下的檔案總數(不含目錄本身);目錄不存在回 @0@。
-- 語意逐字沿用舊碼 @Aapms.Workspace.Lifecycle@ 的 @countFiles@。
countFiles :: FilePath -> IO Int
countFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure 0
    else do
      names <- listDirectory dir
      sum <$> mapM countEntry names
  where
    countEntry name = do
      let p = dir </> name
      isDir <- doesDirectoryExist p
      if isDir then countFiles p else pure 1
