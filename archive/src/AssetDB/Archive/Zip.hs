-- | ZIP 的原生實作。
--
-- 27 個壓縮檔裡有 19 個是 ZIP,所以最常走的這條路不該依賴外部程式。
-- @zip@ 套件直接讀 central directory,不觸碰壓縮資料本身。
module AssetDB.Archive.Zip
  ( listZipEntries
  , readZipEntry
  ) where

import AssetDB.Archive.Types
import Codec.Archive.Zip qualified as Z
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (splitDirectories)

-- | 只讀 central directory。不解壓任何內容。
--
-- @zip@ 套件的 @getEntries@ 不含目錄項目,所以 'aeIsDir' 一律是 'False'。
-- 這與 7-Zip 的行為不同(它會列出目錄),差異在 "AssetDB.Archive" 的
-- 呼叫端統一 —— 兩邊都會過濾掉目錄。
listZipEntries :: FilePath -> IO (Either ArchiveError [ArchiveEntry])
listZipEntries path = do
  r <- try (Z.withArchive path Z.getEntries)
  pure $ case r of
    Left e -> Left (MalformedArchive path (compactException e))
    Right m -> Right (map toEntry (M.toList m))
  where
    toEntry (sel, d) =
      ArchiveEntry
        { aePath = selectorPath sel
        , aeSize = fromIntegral (Z.edUncompressedSize d)
        , aePackedSize = Just (fromIntegral (Z.edCompressedSize d))
        , aeCrc32 = Just (Z.edCRC32 d)
        , aeModified = Just (Z.edModTime d)
        , aeIsDir = False
        }

-- | 解壓單筆項目到記憶體。
--
-- 回傳嚴格 'ByteString':壓縮檔內的單筆項目都是圖片或文字,最大不過數 MB。
-- 真正大的是壓縮檔本身,而那個從來不會被整份載入。
readZipEntry :: FilePath -> Text -> IO (Either ArchiveError ByteString)
readZipEntry path entry = do
  r <- try $ Z.withArchive path $ do
    sel <- Z.mkEntrySelector (T.unpack (normalizeEntryPath entry))
    Z.getEntry sel
  pure $ case r of
    Right bs -> Right bs
    Left e ->
      let msg = compactException e
       in -- @zip@ 對「項目不存在」與「壓縮檔壞掉」丟的都是例外,
          -- 但呼叫端要能分辨:前者是使用者打錯名字,後者是檔案有問題。
          if "EntryDoesNotExist" `T.isInfixOf` msg || "does not exist" `T.isInfixOf` msg
            then Left (EntryNotFound path entry)
            else Left (MalformedArchive path msg)

--------------------------------------------------------------------------------

-- | @unEntrySelector@ 回傳平台原生的 'FilePath',在 Windows 上是反斜線。
-- 資料庫只存一種形式,所以拆再接回來。
selectorPath :: Z.EntrySelector -> Text
selectorPath =
  normalizeEntryPath . T.intercalate "/" . map T.pack . splitDirectories . Z.unEntrySelector

-- | 例外的 'show' 常常是多行的,塞進錯誤訊息會很難讀。
compactException :: SomeException -> Text
compactException = T.unwords . T.words . T.pack . show
