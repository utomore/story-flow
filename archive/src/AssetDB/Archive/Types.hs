-- | 壓縮檔存取層的共用型別。
--
-- == 為什麼這一層存在
--
-- 素材庫的真相來源是壓縮檔,不是散檔。這代表兩件事必須做得很好:
--
-- 1. **列出內容不該解壓。** ZIP 的 central directory 直接給出路徑、大小與 CRC32,
--    完全不必碰壓縮資料。5,400 個項目的索引因此是毫秒級的操作。
--
-- 2. **讀取單筆項目不該落地。** 建專案時只解壓選中的那幾個檔案,
--    而且是解到記憶體再寫進專案的 @assets\/@,中間不產生暫存檔。
module AssetDB.Archive.Types
  ( ArchiveFormat (..)
  , detectFormat
  , formatExtensions
  , needsSidecar
  , ArchiveEntry (..)
  , normalizeEntryPath
  , toNativeEntryPath
  , ArchiveError (..)
  , renderArchiveError
  ) where

import AssetDB.Types (TextEnum (..))
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Word (Word32, Word64)
import System.FilePath (takeExtension)
import System.Info (os)

--------------------------------------------------------------------------------
-- 格式

data ArchiveFormat
  = FmtZip
  | FmtRar
  | Fmt7z
  deriving stock (Eq, Ord, Enum, Bounded, Show)

instance TextEnum ArchiveFormat where
  toTextEnum = \case FmtZip -> "zip"; FmtRar -> "rar"; Fmt7z -> "7z"

formatExtensions :: ArchiveFormat -> [String]
formatExtensions = \case
  FmtZip -> [".zip"]
  FmtRar -> [".rar"]
  Fmt7z -> [".7z"]

-- | ZIP 由純 Haskell 處理。rar 與 7z 需要外部 7-Zip:
-- rar 的格式是專有的,7z 的解壓器沒有 Haskell 綁定。
--
-- 這不是妥協,是所有專業 asset pipeline 的標準作法 ——
-- 把「別人做得比你好的事」外包出去。
needsSidecar :: ArchiveFormat -> Bool
needsSidecar = \case FmtZip -> False; _ -> True

detectFormat :: FilePath -> Maybe ArchiveFormat
detectFormat path =
  let ext = map toLower (takeExtension path)
   in lookup ext [(e, f) | f <- [minBound .. maxBound], e <- formatExtensions f]

--------------------------------------------------------------------------------
-- 項目

-- | 壓縮檔內的一筆項目。欄位取自 central directory 或 @7z l -slt@,
-- 兩條路徑產生的資料形狀一致 —— 上層不需要知道它是哪來的。
data ArchiveEntry = ArchiveEntry
  { aePath :: Text
  -- ^ 壓縮檔內路徑,**一律以 @\/@ 分隔**(見 'normalizeEntryPath')。
  , aeSize :: Word64
  -- ^ 未壓縮大小。
  , aePackedSize :: Maybe Word64
  , aeCrc32 :: Maybe Word32
  -- ^ 來自 central directory 時免費取得。可當作 SHA-256 之前的廉價前濾 ——
  -- CRC32 不同就一定不是同一份內容,不必真的去解壓比對。
  , aeModified :: Maybe UTCTime
  , aeIsDir :: Bool
  }
  deriving stock (Eq, Show)

-- | 統一成 @\/@ 分隔並去掉開頭的 @.\/@。
--
-- 7-Zip 在 Windows 上輸出反斜線,ZIP 規格本身用正斜線。資料庫裡只存一種,
-- 否則同一個項目會因為來源不同而產生兩筆不同的 @entry_path@。
normalizeEntryPath :: Text -> Text
normalizeEntryPath =
  dropLeadingDot . T.replace "\\" "/"
  where
    dropLeadingDot t = maybe t dropLeadingDot (T.stripPrefix "./" t)

-- | 傳給外部工具時轉回平台慣用的分隔符。
--
-- 7-Zip 在 Windows 上比對檔名時認反斜線;丟正斜線進去會比對不到。
toNativeEntryPath :: Text -> Text
toNativeEntryPath
  | os == "mingw32" = T.replace "/" "\\"
  | otherwise = id

--------------------------------------------------------------------------------
-- 錯誤

data ArchiveError
  = -- | 副檔名不是已知的壓縮格式。
    UnsupportedExtension FilePath
  | -- | 需要 7-Zip 但找不到。附上找過哪些位置 —— 「找不到 7z」這種訊息
    -- 對使用者毫無幫助,得說清楚去哪裡裝、我們找過哪。
    SidecarNotFound ArchiveFormat [FilePath]
  | SidecarFailed FilePath Int Text
  | EntryNotFound FilePath Text
  | MalformedArchive FilePath Text
  deriving stock (Eq, Show)

renderArchiveError :: ArchiveError -> Text
renderArchiveError = \case
  UnsupportedExtension p ->
    "不認得的壓縮格式:" <> T.pack p
      <> "(支援 "
      <> T.intercalate " / " (map toTextEnum [minBound .. maxBound :: ArchiveFormat])
      <> ")"
  SidecarNotFound fmt searched ->
    "處理 " <> toTextEnum fmt <> " 需要 7-Zip,但找不到。找過:\n"
      <> T.unlines (map (("  " <>) . T.pack) searched)
      <> "請安裝 7-Zip(winget install 7zip.7zip)。"
  SidecarFailed p code err ->
    "7-Zip 處理 " <> T.pack p <> " 失敗(exit " <> T.pack (show code) <> "):" <> err
  EntryNotFound p e ->
    "壓縮檔 " <> T.pack p <> " 內找不到項目 " <> e
  MalformedArchive p why ->
    "壓縮檔 " <> T.pack p <> " 無法解析:" <> why
