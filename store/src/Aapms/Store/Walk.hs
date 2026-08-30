-- | Vault 目錄走訪與檔案 stat(graph-core\/E001)。內部模組,不對外承諾介面,
-- 不經 "Aapms.Store" 門面 re-export。
--
-- 這兩個函式原本住在 "Aapms.Store.Index" 的匯出清單裡,標著「內部(測試用)」
-- ——但 @Aapms.Store.Index@ 本身在門面的 re-export 清單上,所以那個標記形同虛設:
-- 它們其實是 @aapms-store@ 的公開介面,而契約 E 從來沒有登記過它們。E001 把
-- 「哪些檔算這個 vault 的 Markdown」「怎麼取 mtime 與 size」這兩件知識收進本模組,
-- 由它唯一持有,並隨模組一起關進 @other-modules@。
--
-- __行為不得改變__:兩個函式是從 "Aapms.Store.Index" 原樣搬過來的,簽名與行為
-- 一個字都不動(E001 的回歸 law REG-3 \/ REG-4 就是在釘這件事)。
module Aapms.Store.Walk
  ( -- * 走訪
    vaultMarkdownFiles

    -- * stat
  , statOf
  ) where

import Control.Exception (IOException, try)
import Data.Int (Int64)
import Data.List (isPrefixOf, sort)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory
  ( doesDirectoryExist
  , getFileSize
  , getModificationTime
  , listDirectory
  )
import System.FilePath ((</>), takeExtension)

import Aapms.Store.Error (StoreError (..))

-- 走訪 ------------------------------------------------------------------------

-- | Vault 底下全部的 Markdown 檔,回傳相對於 vault 根目錄的路徑,已排序。
--
-- 略過 @.@ 開頭的目錄(@.aapms@ \/ @.git@ …)與非 @.md@ 的檔案。
vaultMarkdownFiles :: FilePath -> IO [FilePath]
vaultMarkdownFiles root = sort <$> walk ""
  where
    walk rel = do
      let dir = if null rel then root else root </> rel
      names <- listDirectory dir
      concat <$> mapM (visit rel) (sort names)

    visit rel name
      | "." `isPrefixOf` name = pure []
      | otherwise = do
          let relChild = if null rel then name else rel <> "/" <> name
          isDir <- doesDirectoryExist (root </> relChild)
          if isDir
            then walk relChild
            else pure [relChild | takeExtension name == ".md"]

-- stat ------------------------------------------------------------------------

-- | 過時偵測的兩個依據,順序是 __@(mtime, size)@__ —— 第一個分量是修改時間,
-- 第二個才是位元組數。
--
-- __為什麼要把順序寫出來__:兩個分量都是 @Int64@,寫反了型別檢查照樣過,
-- 呼叫端也照樣編得起來,只是從此比對到錯的東西。E001 的第一版 spec 就是在這裡
-- 把順序寫反成 @(size, mtime)@(見 spec-gaps GAP-20),而簽名比對抓不出來。
--
-- __mtime 取奈秒__:同一秒內改兩次是測試與人手都做得到的事,秒級解析度會漏掉。
--
-- 讀不到檔案時回 'Aapms.Store.Error.StoreError',不拋例外。
statOf :: FilePath -> IO (Either StoreError (Int64, Int64))
statOf fp = do
  r <- try act :: IO (Either IOException (Int64, Int64))
  pure $ case r of
    Left e -> Left (FileReadFailed fp (T.pack (show e)))
    Right x -> Right x
  where
    act = do
      t <- getModificationTime fp
      s <- getFileSize fp
      pure (floor (utcTimeToPOSIXSeconds t * 1e9), fromIntegral s)
