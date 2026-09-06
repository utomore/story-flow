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
-- 'Aapms.Workspace.Types.HubWorld' 直接捧著它的文字。@ReadHub@ 讀哪一個檔__由效果
-- 綁的資源決定__,呼叫端不傳路徑(P-004-vault-scope REV-3);兩個解譯器讀的實體與
-- 錯誤裡印的標籤都是 'Aapms.Workspace.Types.hubConfigPath' 算出的那一個
-- @config.toml@,「檔在不在、讀不讀得到、內容是什麼、錯誤印哪一個路徑」因此逐字
-- 相同。
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
import Aapms.Workspace.Location (thumbCacheDir)
import Aapms.Workspace.Types (HubLocation, WorkspaceError (..), hubConfigPath)

-- | 以真的檔案系統跑 'HubFile'。
--
-- 六個操作逐一對照舊碼("Aapms.Workspace.Hub.File" 與
-- @Aapms.Workspace.Lifecycle@ 的 @setupHub@ \/ @purge@):
--
-- * @HubPath@ → 資源參數原樣捧出;位置的解析在進入點只做一次,本層不再查環境變數
-- * @ReadHub@ → 讀 @'Aapms.Workspace.Types.hubConfigPath' loc@;檔案不在回
--   'Aapms.Workspace.Types.HubNotFound',讀不進來回
--   'Aapms.Workspace.Types.HubUnreadable'(訊息委派
--   'Aapms.Store.Error.renderStoreError',這一層不翻譯);__解析不在這裡__,
--   那是 "Aapms.Workspace.Hub" 的純函式
-- * @HubExists@ → 'System.Directory.doesFileExist',__不解析既有檔__
-- * @WriteHub@ → 先把中樞根目錄建出來(對照舊 @setupHub@:第一次 setup 時那個
--   目錄還不存在,少了這一步連暫存檔都開不起來),再
--   'Aapms.Store.Atomic.atomicWriteText'(暫存檔 + rename)
-- * @EnsureCacheDir@ → 回 @Right@「__本來不在才建__」,與純解譯器同一個 'Bool';
--   建不出來回 'Aapms.Workspace.Types.HubWriteFailed'(對照舊 @setupHub@ 的包法),
--   __例外不逸出__(P-005-vault-lifecycle REV-3)
-- * @PurgeHubFiles@ → 先數快取樹底下的檔案數,再刪 @config.toml@ 與__整棵__
--   @cache\/thumbs@(對照舊 @purge@ 的 @removePathForcibly@);
--   @library\/@ 與任何 @.md@ 一律不碰
runHubFileIO :: IOE :> es => HubLocation -> Eff (HubFile : es) a -> Eff es a
runHubFileIO loc = interpret $ \_ op -> liftIO $ case op of
  HubPath -> pure loc
  ReadHub -> readHubFile
  HubExists -> doesFileExist hubFile
  WriteHub txt -> writeHubFile txt
  EnsureCacheDir -> ensureCache
  PurgeHubFiles -> purgeFiles
  where
    hubFile = hubConfigPath loc
    thumbsDir = thumbCacheDir loc

    -- 讀的實體與錯誤裡印的路徑都是 'hubConfigPath'(舊碼
    -- @Aapms.Workspace.Hub.File.loadHub@ 的兩個建構子)。
    readHubFile :: IO (Either WorkspaceError Text)
    readHubFile = do
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

    ensureCache :: IO (Either WorkspaceError Bool)
    ensureCache = do
      existed <- doesDirectoryExist thumbsDir
      if existed
        then pure (Right False)
        else do
          mk <- try (createDirectoryIfMissing True thumbsDir)
          pure $ case mk :: Either IOException () of
            Left e -> Left (HubWriteFailed thumbsDir (T.pack (show e)))
            Right () -> Right True

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
