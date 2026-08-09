-- | 7-Zip 外部程式的呼叫與輸出解析。
--
-- rar 是專有格式,7z 的解壓器沒有 Haskell 綁定 —— 這兩種格式一定要外部工具。
-- 7-Zip 三種格式通吃、免費、而且支援「列出但不解壓」與「單筆項目輸出到 stdout」,
-- 正好是我們需要的兩個操作。
module AssetDB.Archive.Sidecar
  ( SevenZip (..)
  , findSevenZip
  , sevenZipCandidates
  , listViaSidecar
  , readViaSidecar

    -- * 輸出解析(匯出供測試)
  , parseListing
  ) where

import AssetDB.Archive.Types
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Word (Word32, Word64)
import Numeric (readHex)
import System.Directory (doesFileExist, findExecutable)
import System.Process.Typed

newtype SevenZip = SevenZip {sevenZipPath :: FilePath}
  deriving stock (Eq, Show)

-- | 除了 @PATH@ 之外還要找的位置。
--
-- 這不是防禦性程式設計 —— 在開發這套系統的機器上,7-Zip 裝在
-- @C:\\Program Files\\7-Zip\\7z.exe@ 但**沒有加進 PATH**。
-- 只查 PATH 的話會誤報「未安裝」,然後使用者去裝第二次。
sevenZipCandidates :: [FilePath]
sevenZipCandidates =
  [ "C:\\Program Files\\7-Zip\\7z.exe"
  , "C:\\Program Files (x86)\\7-Zip\\7z.exe"
  , "/usr/bin/7z"
  , "/usr/local/bin/7z"
  , "/opt/homebrew/bin/7z"
  , "/usr/bin/7zz"
  , "/opt/homebrew/bin/7zz"
  ]

-- | 先查 @PATH@(涵蓋各種安裝方式),再查已知位置。
findSevenZip :: IO (Maybe SevenZip)
findSevenZip = do
  onPath <- firstJustM findExecutable ["7z", "7zz", "7za"]
  case onPath of
    Just p -> pure (Just (SevenZip p))
    Nothing -> fmap SevenZip <$> firstJustM existing sevenZipCandidates
  where
    existing p = do
      ok <- doesFileExist p
      pure (if ok then Just p else Nothing)

firstJustM :: Monad m => (a -> m (Maybe b)) -> [a] -> m (Maybe b)
firstJustM _ [] = pure Nothing
firstJustM f (x : xs) = f x >>= maybe (firstJustM f xs) (pure . Just)

--------------------------------------------------------------------------------
-- 列出

-- | @7z l -slt@ 只讀檔頭與目錄結構,不解壓內容。
--
-- @-sccUTF-8@ 是關鍵:Windows 上 7-Zip 預設以主控台字碼頁輸出,
-- 中文檔名會變成亂碼。參考資料的壓縮檔內部正是中文檔名。
listViaSidecar :: SevenZip -> FilePath -> IO (Either ArchiveError [ArchiveEntry])
listViaSidecar sz path = do
  r <- runSevenZip sz ["l", "-slt", "-sccUTF-8", "--", path]
  pure $ case r of
    Left err -> Left (SidecarFailed path (fst err) (snd err))
    Right out -> Right (parseListing (decodeUtf8Lenient (BL.toStrict out)))

-- | 解析 @-slt@ 的輸出。
--
-- 格式是「@Key = Value@」的區塊,以空行分隔,前面有一行 @----------@
-- 把檔案清單與壓縮檔本身的屬性隔開。只取那條線之後的內容,
-- 否則會把壓縮檔自己的 @Path =@ 也當成一筆項目。
parseListing :: Text -> [ArchiveEntry]
parseListing raw =
  mapMaybe toEntry (blocks afterSeparator)
  where
    ls = T.lines (T.replace "\r" "" raw)
    afterSeparator = drop 1 (dropWhile (not . isSeparator) ls)
    isSeparator l = T.isPrefixOf "----------" (T.strip l)

    blocks [] = []
    blocks xs =
      let (b, rest) = break (T.null . T.strip) xs
       in (if null b then id else (b :)) (blocks (drop 1 rest))

    toEntry b = do
      let kvs = mapMaybe splitKV b
      p <- lookup "Path" kvs
      let attrs = fromMaybe "" (lookup "Attributes" kvs)
          isDir =
            lookup "Folder" kvs == Just "+"
              || T.isPrefixOf "D" attrs
      pure
        ArchiveEntry
          { aePath = normalizeEntryPath p
          , aeSize = fromMaybe 0 (lookup "Size" kvs >>= readDecimal)
          , aePackedSize = lookup "Packed Size" kvs >>= readDecimal
          , aeCrc32 = lookup "CRC" kvs >>= readCrc
          , aeModified = lookup "Modified" kvs >>= parseModified
          , aeIsDir = isDir
          }

    splitKV l =
      case T.breakOn " = " l of
        (k, v) | not (T.null v) -> Just (T.strip k, T.strip (T.drop 3 v))
        _ -> Nothing

readDecimal :: Text -> Maybe Word64
readDecimal t
  | T.null t' || not (T.all (\c -> c >= '0' && c <= '9') t') = Nothing
  | otherwise = Just (T.foldl' (\a c -> a * 10 + fromIntegral (fromEnum c - 48)) 0 t')
  where
    t' = T.strip t

readCrc :: Text -> Maybe Word32
readCrc t = case readHex (T.unpack (T.strip t)) of
  [(v, "")] -> Just v
  _ -> Nothing

parseModified :: Text -> Maybe UTCTime
parseModified t =
  parseTimeM True defaultTimeLocale "%Y-%m-%d %H:%M:%S" (T.unpack (T.strip t))

--------------------------------------------------------------------------------
-- 讀取單筆

-- | @7z x -so@ 把單一項目寫到 stdout,不落地。
--
-- @-spd@ 關閉萬用字元比對。少了它,檔名裡的 @*@ 或 @?@ 會被當成 pattern,
-- 可能一次吐出多個檔案的內容串在一起 —— 而且是靜默的。
readViaSidecar :: SevenZip -> FilePath -> Text -> IO (Either ArchiveError ByteString)
readViaSidecar sz path entry = do
  r <- runSevenZip sz ["x", "-so", "-spd", "-sccUTF-8", "--", path, T.unpack native]
  pure $ case r of
    Right out
      | BL.null out -> Left (EntryNotFound path entry)
      | otherwise -> Right (BL.toStrict out)
    Left (code, err)
      | "No files to process" `T.isInfixOf` err || code == 1 -> Left (EntryNotFound path entry)
      | otherwise -> Left (SidecarFailed path code err)
  where
    native = toNativeEntryPath (normalizeEntryPath entry)

--------------------------------------------------------------------------------

-- | 執行 7-Zip 並取回 stdout。失敗時回傳 exit code 與 stderr。
--
-- 參數以陣列傳遞,不組字串 —— 素材庫的路徑裡有空格、@&@、@#@、@'@、
-- 方括號與小括號,任何一層字串拼接都會出事。
runSevenZip :: SevenZip -> [String] -> IO (Either (Int, Text) BL.ByteString)
runSevenZip (SevenZip exe) args = do
  r <- try (readProcess (proc exe args))
  pure $ case r of
    Left e -> Left (-1, compact (e :: SomeException))
    Right (ExitSuccess, out, _) -> Right out
    Right (ExitFailure c, _, errOut) -> Left (c, tidy errOut)
  where
    compact = T.unwords . T.words . T.pack . show
    tidy = T.unwords . T.words . decodeUtf8Lenient . BL.toStrict
