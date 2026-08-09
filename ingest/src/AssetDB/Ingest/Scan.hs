-- | 掃描器。
--
-- 走訪一個素材庫根目錄,把找到的壓縮檔與散檔全部索引進資料庫,
-- 並為**每一筆內容**計算 SHA-256。
--
-- == 為什麼掃描必須先於重構
--
-- 重構要搬動 3.42 GB 並刪除 5,424 個散檔。唯一可接受的刪除依據是
-- 「這個散檔的 SHA-256 確實存在於某個保留下來的壓縮檔內」。
-- 先掃描才有那份雜湊清單;先搬再掃就永遠無法證明搬移過程沒弄丟東西。
module AssetDB.Ingest.Scan
  ( ScanOptions (..)
  , defaultScanOptions
  , ScanEvent (..)
  , ScanReport (..)
  , emptyReport
  , scanRoot
  ) where

import AssetDB.Archive
import AssetDB.Id (newULID, unULID)
import AssetDB.Ingest.Handler
import AssetDB.Ingest.Hash
import AssetDB.Store
import AssetDB.Types
import Control.Exception (SomeException, try)
import Control.Monad (foldM, forM)
import Data.Aeson (Value, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Int (Int64)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory
import System.FilePath
import System.IO.Temp (withSystemTempDirectory)

--------------------------------------------------------------------------------

data ScanOptions = ScanOptions
  { soRootPath :: FilePath
  , soRootLabel :: Text
  , soRootKind :: Text
  -- ^ @packs@ / @reference@ / @studio@
  , soRehash :: Bool
  -- ^ 忽略「壓縮檔雜湊未變就跳過」的最佳化,強制重掃全部。
  , soOnEvent :: ScanEvent -> IO ()
  }

defaultScanOptions :: FilePath -> ScanOptions
defaultScanOptions path =
  ScanOptions
    { soRootPath = path
    , soRootLabel = T.pack (takeFileName (dropTrailingPathSeparator path))
    , soRootKind = "packs"
    , soRehash = False
    , soOnEvent = const (pure ())
    }

data ScanEvent
  = EvDiscovered Int Int
  | EvArchiveStart FilePath Int Int
  | EvArchiveDone FilePath Int
  | EvArchiveSkipped FilePath
  | EvLooseStart Int
  | EvLooseDone Int
  | EvProblem Text
  deriving stock (Eq, Show)

data ScanReport = ScanReport
  { srArchives :: Int
  , srArchivesSkipped :: Int
  , srEntries :: Int
  , srEntriesUnread :: Int
  -- ^ 列得出來但讀不到內容的項目。沒有 SHA-256 就不能當刪除依據,
  -- 所以這個數字必須是零才敢執行重構。
  , srLooseFiles :: Int
  , srBytesHashed :: Integer
  , srProblems :: [Text]
  }
  deriving stock (Eq, Show)

emptyReport :: ScanReport
emptyReport = ScanReport 0 0 0 0 0 0 []

--------------------------------------------------------------------------------

scanRoot :: Store -> ArchiveTools -> ScanOptions -> IO ScanReport
scanRoot st tools opts@ScanOptions {..} = do
  absRoot <- makeAbsolute soRootPath
  rootId <- ensureRoot st absRoot soRootLabel soRootKind

  (archivePaths, loosePaths) <- discover absRoot
  soOnEvent (EvDiscovered (length archivePaths) (length loosePaths))

  r1 <-
    foldM
      (\acc (i, p) -> scanArchive st tools opts rootId absRoot (i, length archivePaths) p acc)
      emptyReport
      (zip [1 ..] archivePaths)

  soOnEvent (EvLooseStart (length loosePaths))
  r2 <- scanLoose st rootId absRoot loosePaths r1
  soOnEvent (EvLooseDone (length loosePaths))
  pure r2

-- | 把根目錄底下的檔案分成壓縮檔與散檔。
--
-- 開頭是點號的目錄一律跳過:@.assetdb@ 是我們自己的資料庫與快取,
-- @.git@ 之類的東西索引進去只會製造噪音。
discover :: FilePath -> IO ([FilePath], [FilePath])
discover root = go root ([], [])
  where
    go dir acc = do
      names <- sort <$> listDirectory dir
      foldM step acc [dir </> n | n <- names, not ("." `isPrefixOf` n)]

    step acc@(as, ls) p = do
      isDir <- doesDirectoryExist p
      if isDir
        then go p acc
        else
          pure $ case detectFormat p of
            Just _ -> (p : as, ls)
            Nothing -> (as, p : ls)

--------------------------------------------------------------------------------
-- 壓縮檔

scanArchive
  :: Store
  -> ArchiveTools
  -> ScanOptions
  -> Int
  -> FilePath
  -> (Int, Int)
  -> FilePath
  -> ScanReport
  -> IO ScanReport
scanArchive st tools ScanOptions {..} rootId absRoot (idx, total) path acc = do
  soOnEvent (EvArchiveStart path idx total)
  archiveSha <- sha256File path
  size <- getFileSize path

  -- 壓縮檔內容不可變,所以雜湊沒變就代表裡面每一筆項目都沒變。
  -- 重掃因此幾乎免費 —— 只付 27 次檔案雜湊的成本。
  known <- archiveKnown st archiveSha
  if known && not soRehash
    then do
      soOnEvent (EvArchiveSkipped path)
      pure acc {srArchivesSkipped = srArchivesSkipped acc + 1}
    else
      listEntries tools path >>= \case
        Left err -> problem (renderArchiveError err)
        Right entries -> do
          contents <- fetchContents tools path entries
          let unread = length [() | (_, Nothing) <- contents]
          r <- try (writeArchive st rootId absRoot path archiveSha size entries contents)
          case r of
            Left (e :: SomeException) ->
              problem (T.pack (takeFileName path) <> ":寫入失敗 " <> compact e)
            Right hashedBytes -> do
              soOnEvent (EvArchiveDone path (length entries))
              pure
                acc
                  { srArchives = srArchives acc + 1
                  , srEntries = srEntries acc + length entries
                  , srEntriesUnread = srEntriesUnread acc + unread
                  , srBytesHashed = srBytesHashed acc + hashedBytes
                  }
  where
    problem msg = do
      soOnEvent (EvProblem msg)
      pure acc {srProblems = srProblems acc <> [msg]}

-- | 取得每一筆項目的內容。
--
-- ZIP 逐筆讀(每次只是一次 seek);rar 與 7z 整包解到暫存目錄再讀,
-- 因為它們是 solid 壓縮 —— 逐筆抽取會變成 O(n²) 的解壓量。
-- 暫存目錄在算完雜湊後立刻消失。
fetchContents
  :: ArchiveTools -> FilePath -> [ArchiveEntry] -> IO [(ArchiveEntry, Maybe BS.ByteString)]
fetchContents tools path entries
  | maybe False prefersBulkExtraction (detectFormat path) =
      withSystemTempDirectory "assetdb-scan" $ \tmp ->
        extractAllTo tools path tmp >>= \case
          Left _ -> pure [(e, Nothing) | e <- entries]
          Right () -> forM entries $ \e -> do
            let f = tmp </> nativePath (aePath e)
            ok <- doesFileExist f
            if ok then (,) e . Just <$> BS.readFile f else pure (e, Nothing)
  | otherwise = forM entries $ \e -> do
      r <- readEntry tools path (aePath e)
      pure (e, either (const Nothing) Just r)
  where
    nativePath = joinPath . map T.unpack . T.splitOn "/"

writeArchive
  :: Store
  -> Int
  -> FilePath
  -> FilePath
  -> Sha256
  -> Integer
  -> [ArchiveEntry]
  -> [(ArchiveEntry, Maybe BS.ByteString)]
  -> IO Integer
writeArchive st rootId absRoot path archiveSha size entries contents = do
  let conn = storeConn st
      relPath = T.pack (makeRelativeTo absRoot path)
  now <- nowText
  packId <- ensurePack st rootId relPath path now

  withTransaction conn $ do
    -- 先清掉這個壓縮檔既有的項目。因為只有雜湊變過的壓縮檔會走到這裡,
    -- 「刪掉重建」比逐筆 upsert 簡單,而且不會留下上一版的殘留項目。
    execute
      conn
      "DELETE FROM assets WHERE archive_id IN (SELECT id FROM archives WHERE pack_id = ? AND rel_path = ?)"
      (packId, relPath)
    execute conn "DELETE FROM archives WHERE pack_id = ? AND rel_path = ?" (packId, relPath)

    aUlid <- unULID <$> newULID
    execute
      conn
      "INSERT INTO archives (ulid,pack_id,rel_path,format,sha256,bytes,entry_count,indexed_at) \
      \VALUES (?,?,?,?,?,?,?,?)"
      ( aUlid
      , packId
      , relPath
      , maybe "zip" toTextEnum (detectFormat path)
      , unSha256 archiveSha
      , size
      , length entries
      , now
      )
    archiveId <- lastInsertRowId conn
    foldM (insertEntry conn archiveId packId now) 0 contents

insertEntry
  :: Connection
  -> Int64
  -> Int
  -> Text
  -> Integer
  -> (ArchiveEntry, Maybe BS.ByteString)
  -> IO Integer
insertEntry conn archiveId packId now acc (e, mContent) = do
  let entryPath = aePath e
      leaf = leafOf entryPath
      kind = kindForPath entryPath
  case mContent of
    -- 讀不到內容的項目仍然入庫。丟棄會讓「這包有幾個檔案」對不上,
    -- 之後查帳時無從解釋差額 —— 缺少 sha256 是一個看得見的缺口,
    -- 而 srEntriesUnread 會把它算出來。
    Nothing -> do
      insertAsset conn archiveId packId now entryPath leaf kind Nothing Nothing
      pure acc
    Just content -> do
      let sha = sha256Bytes content
          meta = probeContent entryPath content
      upsertBlob conn sha (BS.length content) kind meta now
      insertAsset conn archiveId packId now entryPath leaf kind (Just sha) meta
      pure (acc + fromIntegral (BS.length content))

insertAsset
  :: Connection
  -> Int64
  -> Int
  -> Text
  -> Text
  -> Text
  -> AssetKind
  -> Maybe Sha256
  -> Maybe Value
  -> IO ()
insertAsset conn archiveId packId now entryPath leaf kind mSha meta = do
  u <- unULID <$> newULID
  execute
    conn
    "INSERT INTO assets \
    \ (ulid,kind,archive_id,entry_path,original_name,ext,sha256,pack_id,meta_json,created_at,updated_at) \
    \VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    -- 11 個佔位符。sqlite-simple 的 ToRow 對 tuple 只到 10 個元素,
    -- 所以用 [SQLData];這也讓 NULL 與型別一目了然。
    [ SQLText u
    , SQLText (toTextEnum kind)
    , SQLInteger archiveId
    , SQLText entryPath
    , SQLText leaf
    , SQLText (extensionOf entryPath)
    , maybe SQLNull (SQLText . unSha256) mSha
    , SQLInteger (fromIntegral packId)
    , maybe SQLNull SQLText (encodeMeta meta)
    , SQLText now
    , SQLText now
    ]

--------------------------------------------------------------------------------
-- 散檔

scanLoose :: Store -> Int -> FilePath -> [FilePath] -> ScanReport -> IO ScanReport
scanLoose st rootId absRoot paths acc = do
  let conn = storeConn st
  now <- nowText
  total <- withTransaction conn (foldM (one conn now) 0 paths)
  pure acc {srLooseFiles = length paths, srBytesHashed = srBytesHashed acc + total}
  where
    one conn now bytes p = do
      let relPath = T.pack (makeRelativeTo absRoot p)
          leaf = T.pack (takeFileName p)
          kind = kindForPath relPath
      content <- BS.readFile p
      let sha = sha256Bytes content
          meta = probeContent relPath content
      upsertBlob conn sha (BS.length content) kind meta now
      execute conn "DELETE FROM assets WHERE root_id = ? AND rel_path = ?" (rootId, relPath)
      u <- unULID <$> newULID
      execute
        conn
        "INSERT INTO assets \
        \ (ulid,kind,root_id,rel_path,original_name,ext,sha256,meta_json,created_at,updated_at) \
        \VALUES (?,?,?,?,?,?,?,?,?,?)"
        [ SQLText u
        , SQLText (toTextEnum kind)
        , SQLInteger (fromIntegral rootId)
        , SQLText relPath
        , SQLText leaf
        , SQLText (extensionOf relPath)
        , SQLText (unSha256 sha)
        , maybe SQLNull SQLText (encodeMeta meta)
        , SQLText now
        , SQLText now
        ]
      pure (bytes + fromIntegral (BS.length content))

--------------------------------------------------------------------------------
-- 資料庫小工具

-- | 同一份內容跨素材包只算一次。多家廠商常常附上同一份免費字型或授權文字。
upsertBlob :: Connection -> Sha256 -> Int -> AssetKind -> Maybe Value -> Text -> IO ()
upsertBlob conn sha bytes kind meta now =
  execute
    conn
    "INSERT OR IGNORE INTO blobs (sha256,bytes,kind,meta_json,first_seen) VALUES (?,?,?,?,?)"
    [ SQLText (unSha256 sha)
    , SQLInteger (fromIntegral bytes)
    , SQLText (toTextEnum kind)
    , maybe SQLNull SQLText (encodeMeta meta)
    , SQLText now
    ]

ensureRoot :: Store -> FilePath -> Text -> Text -> IO Int
ensureRoot st path label kind = do
  let conn = storeConn st
  execute
    conn
    "INSERT OR IGNORE INTO roots (path,label,kind) VALUES (?,?,?)"
    (T.pack path, label, kind)
  rows <- query conn "SELECT id FROM roots WHERE path = ?" (Only (T.pack path))
  case rows of
    (Only i : _) -> pure i
    [] -> ioError (userError ("ensureRoot:剛插入的 root 找不到 " <> path))

-- | 目前的素材庫還是舊的混亂結構,所以「一個壓縮檔 = 一個素材包」是
-- 唯一能自動推導又不會猜錯的規則。重構之後 pack 由 @pack.toml@ 定義,
-- 這裡的推導只是過渡期的橋樑。
--
-- 一律建成 @draft@:授權與作者無法從檔名推導,而猜錯的授權比沒有授權更危險。
ensurePack :: Store -> Int -> Text -> FilePath -> Text -> IO Int
ensurePack st rootId relPath path now = do
  let conn = storeConn st
      relDir = T.pack (takeDirectory (T.unpack relPath))
      name = T.pack (takeBaseName path)
      slug = slugify name
      key = relDir <> "/" <> slug
  rows <- query conn "SELECT id FROM packs WHERE root_id = ? AND rel_dir = ?" (rootId, key)
  case rows of
    (Only i : _) -> pure i
    [] -> do
      u <- unULID <$> newULID
      execute
        conn
        "INSERT INTO packs (ulid,slug,name,root_id,rel_dir,status,created_at,updated_at) \
        \VALUES (?,?,?,?,?,'draft',?,?)"
        (u, slug, name, rootId, key, now, now)
      fromIntegral <$> lastInsertRowId conn

-- | 素材包名稱含空格、方括號、@&@、撇號。slug 只留下路徑安全的字元。
slugify :: Text -> Text
slugify =
  T.intercalate "-"
    . filter (not . T.null)
    . T.splitOn "-"
    . T.map safeChar
    . T.toLower
  where
    safeChar c
      | c `elem` ("abcdefghijklmnopqrstuvwxyz0123456789" :: String) = c
      | otherwise = '-'

archiveKnown :: Store -> Sha256 -> IO Bool
archiveKnown st sha = do
  rows <-
    query (storeConn st) "SELECT 1 FROM archives WHERE sha256 = ? LIMIT 1" (Only (unSha256 sha))
      :: IO [Only Int]
  pure (not (null rows))

encodeMeta :: Maybe Value -> Maybe Text
encodeMeta = fmap (decodeUtf8Lenient . BL.toStrict . encode)

nowText :: IO Text
nowText = T.pack . iso8601Show <$> getCurrentTime

leafOf :: Text -> Text
leafOf p = last ("" : T.splitOn "/" p)

makeRelativeTo :: FilePath -> FilePath -> FilePath
makeRelativeTo root p = map toSlash (makeRelative root p)
  where
    toSlash c = if c == '\\' then '/' else c

compact :: SomeException -> Text
compact = T.unwords . T.words . T.pack . show
