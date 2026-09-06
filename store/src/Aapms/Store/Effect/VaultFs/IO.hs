{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | 'Aapms.Store.Effect.VaultFs.VaultFs' 的__真解譯器__:@directory@ 與
-- 原子寫入。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',
-- 效果真的發生在這裡。效果的__描述__與純解譯器
-- ('Aapms.Store.Effect.VaultFs.runVaultFsPure')住 effects 層,兩者不共用模組
-- (ADR-023)。
--
-- __與純解譯器的分工__:記憶體 vault「就是」那份已經列好的清單,所以
-- 'Aapms.Store.Effect.VaultFs.runVaultFsPure' 的 @ListMarkdown@ 不過濾;走目錄樹、
-- 略過 @.@ 開頭目錄、只留 @.md@ 是__本模組__的責任
-- ('Aapms.Store.Walk.vaultMarkdownFiles',逐字沿用舊碼 @rebuildIndex@ 的 listing)。
module Aapms.Store.Effect.VaultFs.IO
  ( runVaultFsIO
  ) where

import Control.Exception (IOException, try)
import qualified Data.Text as T
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>), takeDirectory)

import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Effect.VaultFs (VaultFs (..))
import Aapms.Store.Types (FileStat (..), StoreError (..))
import Aapms.Store.Walk (statOf, vaultMarkdownFiles)

-- | 以 @root@ 為 vault 根目錄跑 'VaultFs'。
--
-- 每個操作收到的路徑都是 __vault 相對路徑__(@\/@ 分隔,與索引裡存的形式一致);
-- 本解譯器負責接上根目錄。六個操作逐一對照舊碼:
--
-- * @ListMarkdown@ → 'Aapms.Store.Walk.vaultMarkdownFiles'(已排序、略過 @.@
--   開頭目錄、只留 @.md@)
-- * @StatFile@ → 'Aapms.Store.Walk.statOf' 的 @(mtime, size)@,包成 'FileStat'
-- * @ReadMarkdown@ → 'Aapms.Store.Atomic.readTextFile'(一律當 UTF-8)
-- * @FileExists@ → 'System.Directory.doesFileExist'
-- * @WriteMarkdown@ → 先建出目錄再
--   'Aapms.Store.Atomic.atomicWriteText'(暫存檔 + rename;目錄不存在連暫存檔
--   都開不起來,對照舊 @Aapms.Store.Edit@ 的 @ensureDir@)
-- * @DeleteMarkdown@ → 'System.Directory.removeFile',失敗轉成
--   'Aapms.Store.Types.FileWriteFailed'(對照舊 @Aapms.Store.Edit@ 的 @dropFile@)
runVaultFsIO :: IOE :> es => FilePath -> Eff (VaultFs : es) a -> Eff es a
runVaultFsIO root = interpret $ \_ op -> liftIO $ case op of
  ListMarkdown -> vaultMarkdownFiles root
  StatFile p ->
    fmap (\(m, s) -> FileStat {fsMtime = m, fsSize = s}) <$> statOf (absOf p)
  ReadMarkdown p -> readTextFile (absOf p)
  FileExists p -> doesFileExist (absOf p)
  WriteMarkdown p txt -> do
    let target = absOf p
    mkDir <- try (createDirectoryIfMissing True (takeDirectory target))
    case mkDir :: Either IOException () of
      Left e -> pure (Left (FileWriteFailed target (T.pack (show e))))
      Right () -> atomicWriteText target txt
  DeleteMarkdown p -> do
    let target = absOf p
    removed <- try (removeFile target)
    pure $ case removed :: Either IOException () of
      Left e -> Left (FileWriteFailed target ("刪除檔案失敗 —— " <> T.pack (show e)))
      Right () -> Right ()
  where
    absOf p = root </> p
