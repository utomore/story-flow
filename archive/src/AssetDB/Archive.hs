-- | 壓縮檔存取的公開介面。
--
-- 兩個操作,兩者都**不解壓到磁碟**:
--
-- * 'listEntries' —— 列出內容。ZIP 只讀 central directory,不碰壓縮資料。
-- * 'readEntry' —— 讀取單筆項目到記憶體。建專案時只對選中的素材做這件事。
--
-- 格式派送對呼叫端透明。ZIP 走純 Haskell,rar 與 7z 走 7-Zip。
module AssetDB.Archive
  ( -- * 工具探索
    ArchiveTools (..)
  , discoverTools
  , supportedFormats
  , describeTools

    -- * 操作
  , listEntries
  , readEntry

    -- * 重新匯出
  , module AssetDB.Archive.Types
  ) where

import AssetDB.Archive.Sidecar
import AssetDB.Archive.Types
import AssetDB.Archive.Zip
import AssetDB.Types (TextEnum (..))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T

-- | 一次探索、重複使用。每次操作都去找 7-Zip 會白白付出檔案系統成本,
-- 而且會讓「工具中途消失」變成一種可能的狀態。
newtype ArchiveTools = ArchiveTools
  { atSevenZip :: Maybe SevenZip
  }
  deriving stock (Eq, Show)

discoverTools :: IO ArchiveTools
discoverTools = ArchiveTools <$> findSevenZip

-- | 目前這台機器實際處理得了的格式。
--
-- 沒有 7-Zip 時只剩 ZIP。這不會讓 rar 素材包無法**索引**
-- —— 索引失敗會如實記錄成錯誤,而不是靜靜跳過。
supportedFormats :: ArchiveTools -> [ArchiveFormat]
supportedFormats tools =
  [f | f <- [minBound .. maxBound], not (needsSidecar f) || hasSidecar]
  where
    hasSidecar = atSevenZip tools /= Nothing

-- | 給 @assetdb doctor@ 用的人類可讀摘要。
describeTools :: ArchiveTools -> Text
describeTools tools =
  case atSevenZip tools of
    Just (SevenZip p) -> "7-Zip: " <> T.pack p <> "\n" <> supported
    Nothing ->
      "7-Zip: 未安裝 —— rar 與 7z 無法處理。\n"
        <> "  安裝方式:winget install 7zip.7zip\n"
        <> supported
  where
    supported =
      "可處理的格式:" <> T.intercalate " / " (map toTextEnum (supportedFormats tools))

--------------------------------------------------------------------------------

-- | 列出壓縮檔內容。**目錄項目會被過濾掉** ——
-- 兩條實作路徑對目錄的處理不同(@zip@ 不列、7-Zip 會列),
-- 在這裡統一,上層才不必知道資料是哪來的。
listEntries :: ArchiveTools -> FilePath -> IO (Either ArchiveError [ArchiveEntry])
listEntries tools path =
  case detectFormat path of
    Nothing -> pure (Left (UnsupportedExtension path))
    Just FmtZip -> do
      native <- listZipEntries path
      case native of
        Right es -> pure (Right (filter (not . aeIsDir) es))
        -- ZIP 有一些少見的壓縮方法(如 LZMA、PPMd)@zip@ 套件不支援。
        -- 既然 7-Zip 已經是 rar/7z 的相依,拿它當後備是免費的 ——
        -- 比起讓一整個素材包無法索引,多花一次 process 啟動很划算。
        Left err -> fallbackToSidecar tools path err
    Just fmt -> viaSidecar tools fmt path

fallbackToSidecar
  :: ArchiveTools -> FilePath -> ArchiveError -> IO (Either ArchiveError [ArchiveEntry])
fallbackToSidecar tools path nativeErr =
  case atSevenZip tools of
    Nothing -> pure (Left nativeErr)
    Just sz -> do
      r <- listViaSidecar sz path
      pure $ case r of
        -- sidecar 也失敗時回報**原始**錯誤:那個比較貼近真正的問題,
        -- 「7-Zip 也讀不了」只是二次症狀。
        Left _ -> Left nativeErr
        Right es -> Right (filter (not . aeIsDir) es)

viaSidecar
  :: ArchiveTools -> ArchiveFormat -> FilePath -> IO (Either ArchiveError [ArchiveEntry])
viaSidecar tools fmt path =
  case atSevenZip tools of
    Nothing -> pure (Left (SidecarNotFound fmt sevenZipCandidates))
    Just sz -> fmap (filter (not . aeIsDir)) <$> listViaSidecar sz path

-- | 解壓單筆項目到記憶體。
--
-- 這是整個系統唯一會真正解壓的地方,而且一次只解一個項目。
-- 建專案時對選中的素材各呼叫一次,永遠不會整包解開。
readEntry :: ArchiveTools -> FilePath -> Text -> IO (Either ArchiveError ByteString)
readEntry tools path entry =
  case detectFormat path of
    Nothing -> pure (Left (UnsupportedExtension path))
    Just FmtZip -> do
      r <- readZipEntry path entry
      case r of
        Right bs -> pure (Right bs)
        Left e@(EntryNotFound _ _) -> pure (Left e)
        Left e -> case atSevenZip tools of
          Nothing -> pure (Left e)
          Just sz -> readViaSidecar sz path entry
    Just fmt -> case atSevenZip tools of
      Nothing -> pure (Left (SidecarNotFound fmt sevenZipCandidates))
      Just sz -> readViaSidecar sz path entry
