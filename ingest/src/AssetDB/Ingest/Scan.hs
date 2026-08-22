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

    -- * 兩階段化的兩半(匯出供測試)
    --
    -- $twoPhase
  , PreparedLoose (..)
  , prepareLoose
  , writeLoose
  , looseBatchSize
  , guardedTry
  ) where

import AssetDB.Archive
import AssetDB.Id (newULID, unULID)
import AssetDB.Ingest.Handler
import AssetDB.Ingest.Hash
import AssetDB.PathText (leafOf, slugify)
import AssetDB.Store
import AssetDB.Types
import AssetDB.Guard (guardedTry)
import Control.Exception (SomeException, fromException)
import Control.Monad (foldM, forM)
import Data.Aeson (Value, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Int (Int64)
import Data.List (isPrefixOf, sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple
import System.Directory
import System.FilePath
import System.IO.Temp (withSystemTempDirectory)

-- $twoPhase
--
-- 這四項匯出是為了讓「交易內不做任何計算」這條性質**被測到**(E006 / ADR-009)。
--
-- 它是本次優化最核心、也最容易被下一個人默默改壞的性質:把一行雜湊或探測搬回
-- 交易裡,行為完全正確、測試全綠,只有寫鎖會被多持有幾分鐘 —— 而那要在有人
-- 同時開著伺服器時才看得出來。從 'scanRoot' 外面走到交易邊界需要一整組真實素材庫
-- 與可控的失敗注入,那樣的測試貴到不會有人寫。
--
-- 同樣的理由已經用過兩次:@Archive.Sidecar@ 的 @parseListing@、
-- @Project.Create@ 的 @nonCommercialPacks@。

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
  | EvArchiveFailed FilePath Text
  -- ^ 整個壓縮檔讀不開(列不出來,或列得出來但取不出內容)。
  -- 與 'EvProblem' 分開是刻意的:這一包完全沒有可信的內容雜湊。
  | EvLooseStart Int
  | EvLooseDone Int
  | EvProblem Text
  | EvAborted Text
  -- ^ **整批中止**:寫入端失效(磁碟寫滿、資料庫損毀、搶不到寫鎖)。
  -- 與 'EvProblem' 和 'EvArchiveFailed' 都不同——那兩個是「這一筆」的問題,
  -- 這個是「環境壞了,再跑下去只會累積數千則同樣的錯誤」。
  deriving stock (Eq, Show)

data ScanReport = ScanReport
  { srArchives :: Int
  , srArchivesSkipped :: Int
  , srArchivesFailed :: Int
  -- ^ 整個讀不開的壓縮檔。**與 'srEntriesUnread' 是兩件不同的事**:
  -- 那個是「這一包裡有幾筆項目讀不到」,這個是「這一包完全沒讀到」。
  -- 非零代表索引不完整,而且不完整的範圍是整包。
  , srEntries :: Int
  , srEntriesUnread :: Int
  -- ^ 列得出來但讀不到內容的項目。沒有 SHA-256 就不能當刪除依據,
  -- 所以這個數字必須是零才敢執行重構。
  , srLooseFiles :: Int
  , srBytesHashed :: Integer
  , srProblems :: [Text]
  , srAborted :: Maybe Text
  -- ^ 'Nothing' = 跑完(可能帶著單筆失敗);@Just 原因@ = **中止**。
  -- 中止時上面每一個計數都只是「中止前完成了多少」,呼叫端不得當成完整結果。
  }
  deriving stock (Eq, Show)

emptyReport :: ScanReport
emptyReport = ScanReport 0 0 0 0 0 0 0 [] Nothing

--------------------------------------------------------------------------------

-- | 這個例外算不算「寫入端失效」。
--
-- **中止的界線劃在寫入端**:資料庫寫不進去(磁碟滿、db 損毀、搶不到寫鎖)不是
-- 「這一筆」的問題,繼續跑只會把剩下的每一項都標成同樣的失敗。
--
-- 讀取端的失敗一律是單筆失敗:壓縮檔讀不開(B001)、sidecar 缺席
-- (@archive-access@ 契約定義為**能力縮減而非錯誤**)、單一檔案權限不足或
-- 掃描期間被移走。把讀取端當成中止的話,一個沒裝 7-Zip 的合法環境會在第一個
-- rar 就停住。
writeFailure :: SomeException -> Maybe Text
writeFailure e = case fromException e :: Maybe SQLError of
  Just se -> Just (compact se)
  Nothing -> Nothing

--------------------------------------------------------------------------------

scanRoot :: Store -> ArchiveTools -> ScanOptions -> IO ScanReport
scanRoot st tools opts@ScanOptions {..} = do
  absRoot <- makeAbsolute soRootPath
  -- 登記根目錄是整次掃描的**第一個寫入**。它失敗代表資料庫根本寫不進去
  -- (唯讀、損毀、kind 值違反 CHECK),再往下跑只會把同一個失敗重複數千次
  -- —— 那正是「寫入端失效即中止」的定義(G-E003)。
  guardedTry (ensureRoot st absRoot soRootLabel soRootKind) >>= \case
    Left e -> do
      let why = "登記素材庫根目錄失敗 —— " <> maybe (compact e) id (writeFailure e)
      soOnEvent (EvAborted why)
      pure emptyReport {srAborted = Just why, srProblems = ["中止:" <> why]}
    Right rootId -> scanFrom rootId absRoot
  where
    scanFrom rootId absRoot = do
      (archivePaths, loosePaths, loopWarnings) <- discover absRoot
      soOnEvent (EvDiscovered (length archivePaths) (length loosePaths))
      mapM_ (soOnEvent . EvProblem) loopWarnings

      r1 <-
        foldM
          ( \acc (i, p) -> case srAborted acc of
              -- 已中止就不再碰剩下的壓縮檔。
              Just _ -> pure acc
              Nothing -> scanArchive st tools opts rootId absRoot (i, length archivePaths) p acc
          )
          emptyReport {srProblems = loopWarnings}
          (zip [1 ..] archivePaths)

      case srAborted r1 of
        -- 中止不進散檔階段:寫入端已經失效,再試只會再失敗一次。
        Just _ -> pure r1
        Nothing -> do
          soOnEvent (EvLooseStart (length loosePaths))
          r2 <- scanLoose st soOnEvent rootId absRoot loosePaths r1
          soOnEvent (EvLooseDone (length loosePaths))
          pure r2

-- | 把根目錄底下的檔案分成壓縮檔與散檔,並回報偵測到的目錄迴圈。
--
-- 開頭是點號的目錄一律跳過:@.assetdb@ 是我們自己的資料庫與快取,
-- @.git@ 之類的東西索引進去只會製造噪音。
--
-- 走訪時以 canonical path 記錄看過的目錄(ingest/E005):符號連結或
-- Windows junction 指回祖先時會形成迴圈,不防的話是無窮遞迴。重複出現
-- 的目錄跳過並記進第三個回傳值 —— 那同時涵蓋「兩條連結指向同一目錄」
-- 的重複索引。
discover :: FilePath -> IO ([FilePath], [FilePath], [Text])
discover root = do
  rootKey <- canonicalizePath root
  ((as, ls, ws), _) <- go (Set.singleton rootKey) root ([], [], [])
  pure (as, ls, reverse ws)
  where
    -- 列不到目錄(權限不足、走訪途中被移走)不該讓整次掃描崩掉:
    -- 記進警告、跳過這個目錄、繼續走訪(G-E003)。
    go visited dir acc@(as, ls, ws) =
      guardedTry (sort <$> listDirectory dir) >>= \case
        Left e ->
          pure ((as, ls, ("讀不到目錄,已跳過:" <> T.pack dir <> " —— " <> compact e) : ws), visited)
        Right names ->
          foldM step (acc, visited) [dir </> n | n <- names, not ("." `isPrefixOf` n)]

    step (acc@(as, ls, ws), visited) p = do
      isDir <- doesDirectoryExist p
      if isDir
        then do
          key <- canonicalizePath p
          if key `Set.member` visited
            then
              pure
                ( (as, ls, ("偵測到目錄迴圈(符號連結/junction),跳過:" <> T.pack p) : ws)
                , visited
                )
            else go (Set.insert key visited) p acc
        else
          pure
            ( if isMetadata p
                then acc
                else case detectFormat p of
                  Just _ -> (p : as, ls, ws)
                  Nothing -> (as, p : ls, ws)
            , visited
            )

-- | 系統自己產生的中繼資料檔案不是素材。
--
-- @pack.toml@ 描述它所在的素材包 —— 把它索引成資源會讓「這包有幾個檔案」
-- 多出一筆,而且它永遠不會出現在任何壓縮檔內,所以覆蓋率報告會永遠掛著
-- 一個假的「未覆蓋」項目。
isMetadata :: FilePath -> Bool
isMetadata p = takeFileName p `elem` ["pack.toml", "manifest.json"]

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
        Left err -> archiveFailed (renderArchiveError err)
        Right entries ->
          fetchContents tools path entries >>= \case
            -- 整包取不到內容:這一包一筆可信的雜湊都沒有,不能當成索引成功。
            -- 舊版在這裡回傳「每一筆都是 Nothing」,與「個別項目讀不到」同形,
            -- 於是照常走成功路徑 —— 失敗被吞成成功(B001)。
            Left err -> archiveFailed (renderArchiveError err)
            Right contents -> do
              let unread = length [() | (_, Nothing) <- contents]
                  -- 交易外算完。之後 contents 就可以被回收 —— 舊版整包內容
                  -- 留在記憶體裡直到交易結束。
                  prepared = map prepareEntry contents
              r <- guardedTry (writeArchive st rootId absRoot path archiveSha size entries prepared)
              case r of
                Left e
                  | Just why <- writeFailure e -> aborted why
                  | otherwise ->
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

    -- 寫入端失效:不是「這一包」的問題,再跑下去只會把剩下的每一包都
    -- 標成同樣的失敗。停下來,已完成的部分留在資料庫,重跑會補齊。
    aborted why = do
      soOnEvent (EvAborted why)
      pure
        acc
          { srAborted = Just why
          , srProblems = srProblems acc <> ["中止:" <> why]
          }

    -- 整包讀不開。不寫入任何項目 —— 半包沒有雜湊的資料比沒有資料更糟,
    -- 因為後續每一個判斷都會把它當成真的。
    archiveFailed why = do
      let msg = T.pack (takeFileName path) <> ":整包讀不開 —— " <> why
      soOnEvent (EvArchiveFailed path why)
      pure
        acc
          { srArchivesFailed = srArchivesFailed acc + 1
          , srProblems = srProblems acc <> [msg]
          }

-- | 取得每一筆項目的內容。
--
-- ZIP 逐筆讀(每次只是一次 seek);rar 與 7z 整包解到暫存目錄再讀,
-- 因為它們是 solid 壓縮 —— 逐筆抽取會變成 O(n²) 的解壓量。
-- 暫存目錄在算完雜湊後立刻消失。
--
-- == 回傳型別為什麼是 Either
--
-- 有兩種完全不同的失敗:**整包取不到**(解壓失敗、缺 sidecar、暫存空間不足)
-- 與**個別項目取不到**(項目在檔案裡但讀不出來)。前者代表這一包一筆可信的
-- 雜湊都沒有,後者只影響那幾筆。
--
-- 舊版兩種都回傳 @[(entry, Nothing)]@,呼叫端在型別上分辨不出來,於是把整包
-- 失敗照常算成索引成功(B001)。把整包失敗放進 'Left' 之後,呼叫端**必須**
-- 處理它 —— 編譯器會擋下遺漏。
fetchContents
  :: ArchiveTools
  -> FilePath
  -> [ArchiveEntry]
  -> IO (Either ArchiveError [(ArchiveEntry, Maybe BS.ByteString)])
fetchContents tools path entries
  | maybe False prefersBulkExtraction (detectFormat path) =
      withSystemTempDirectory "assetdb-scan" $ \tmp ->
        extractAllTo tools path tmp >>= \case
          Left err -> pure (Left err)
          Right () -> fmap Right . forM entries $ \e -> do
            let f = tmp </> nativePath (aePath e)
            ok <- doesFileExist f
            if ok then (,) e . Just <$> BS.readFile f else pure (e, Nothing)
  | otherwise = fmap Right . forM entries $ \e -> do
      r <- readEntry tools path (aePath e)
      pure (e, either (const Nothing) Just r)
  where
    nativePath = joinPath . map T.unpack . T.splitOn "/"

-- | 一筆**已經算完**的項目。
--
-- 交易內只會看到這個型別,而它裡面沒有 @FilePath@、沒有內容 @ByteString@ ——
-- 想在交易裡讀檔或重新解碼,型別上就辦不到。這是 ADR-009「寫交易內只剩已經
-- 算好的值的寫入」在 Haskell 裡的具體形式:規則由型別保證,不是靠人記得。
--
-- 欄位刻意都是已序列化的形式(@Text@ / @Integer@),不留 'Sha256' 或 'Value':
-- 那兩者的計算在惰性下會變成 thunk 飄進交易內,型別分離就白做了(見 'prepareEntry')。
data PreparedEntry = PreparedEntry
  { prpPath :: !Text
  , prpLeaf :: !Text
  , prpExt :: !Text
  , prpKind :: !AssetKind
  , prpSha :: !(Maybe Text)
  , prpMeta :: !(Maybe Text)
  , prpBytes :: !Integer
  }

-- | 交易**外**把一筆項目算完:SHA-256、kind 專屬中繼資料、序列化。
--
-- == 為什麼要顯式強制求值
--
-- 光把型別換成 @Text@ 不夠。嚴格欄位只強制到 WHNF,而 @Maybe Text@ 的 WHNF
-- 是 @Just \<thunk\>@ —— 雜湊與 PNG 解碼會安安靜靜地跟著 thunk 飄進交易內,
-- 執行時機完全沒變,只是看起來變乾淨了。'forceMaybeText' 是那道保險。
prepareEntry :: (ArchiveEntry, Maybe BS.ByteString) -> PreparedEntry
prepareEntry (e, mContent) =
  let entryPath = aePath e
      kind = kindForPath entryPath
   in case mContent of
        -- 讀不到內容的項目仍然入庫。丟棄會讓「這包有幾個檔案」對不上,
        -- 之後查帳時無從解釋差額 —— 缺少 sha256 是一個看得見的缺口,
        -- 而 srEntriesUnread 會把它算出來。
        Nothing ->
          PreparedEntry entryPath (leafOf entryPath) (extensionOf entryPath) kind Nothing Nothing 0
        Just content ->
          PreparedEntry
            entryPath
            (leafOf entryPath)
            (extensionOf entryPath)
            kind
            (forceMaybeText (Just (unSha256 (sha256Bytes content))))
            (forceMaybeText (encodeMeta (probeContent entryPath content)))
            (fromIntegral (BS.length content))

-- | 把 @Maybe Text@ 強制到「字串真的算出來了」的程度。
--
-- @Data.Text.Text@ 的 WHNF 就是完整的位元組陣列,所以碰到裡面那個 'Text'
-- 一次就夠 —— 雜湊與探測會在**這裡**發生,而這裡在交易外。
forceMaybeText :: Maybe Text -> Maybe Text
forceMaybeText Nothing = Nothing
forceMaybeText (Just t) = T.length t `seq` Just t

writeArchive
  :: Store
  -> Int
  -> FilePath
  -> FilePath
  -> Sha256
  -> Integer
  -> [ArchiveEntry]
  -> [PreparedEntry]
  -> IO Integer
writeArchive st rootId absRoot path archiveSha size entries prepared = do
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
    foldM (insertEntry conn archiveId packId now) 0 prepared

-- | 交易**內**的唯一動作:把已經算好的值寫進去。
--
-- 參數型別裡沒有任何需要讀檔或重新運算的東西 —— 這是刻意的,見 'PreparedEntry'。
insertEntry :: Connection -> Int64 -> Int -> Text -> Integer -> PreparedEntry -> IO Integer
insertEntry conn archiveId packId now acc PreparedEntry {..} = do
  case prpSha of
    Nothing -> pure ()
    Just sha -> upsertBlobText conn sha prpBytes prpKind prpMeta now
  u <- unULID <$> newULID
  execute
    conn
    "INSERT INTO assets \
    \ (ulid,kind,archive_id,entry_path,original_name,ext,sha256,pack_id,meta_json,created_at,updated_at) \
    \VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    -- 11 個佔位符。sqlite-simple 的 ToRow 對 tuple 只到 10 個元素,
    -- 所以用 [SQLData];這也讓 NULL 與型別一目了然。
    [ SQLText u
    , SQLText (toTextEnum prpKind)
    , SQLInteger archiveId
    , SQLText prpPath
    , SQLText prpLeaf
    , SQLText prpExt
    , maybe SQLNull SQLText prpSha
    , SQLInteger (fromIntegral packId)
    , maybe SQLNull SQLText prpMeta
    , SQLText now
    , SQLText now
    ]
  pure (acc + prpBytes)

--------------------------------------------------------------------------------
-- 散檔

-- | 一筆**已經算完**的散檔。與 'PreparedEntry' 同樣的道理:交易內看不到
-- @FilePath@,也就讀不了檔。
data PreparedLoose = PreparedLoose
  { plRel :: !Text
  , plLeaf :: !Text
  , plExt :: !Text
  , plKind :: !AssetKind
  , plSha :: !Text
  , plMeta :: !(Maybe Text)
  , plBytes :: !Integer
  }

-- | 每批多少筆。
--
-- 每批交易內約 400 次 @execute@(毫秒級),而準備階段同時在記憶體裡的只有
-- 一批的中繼資料。數字可以調,但**不得回到「一個交易包住整個根目錄」** ——
-- 那會讓寫鎖被持有數分鐘到數小時,遠超 @busy_timeout@(ADR-009)。
looseBatchSize :: Int
looseBatchSize = 200

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t

scanLoose :: Store -> (ScanEvent -> IO ()) -> Int -> FilePath -> [FilePath] -> ScanReport -> IO ScanReport
scanLoose st onEvent rootId absRoot paths acc0 = do
  now <- nowText
  go now acc0 (chunksOf looseBatchSize paths)
  where
    conn = storeConn st

    go _ acc [] = pure acc
    go now acc (batch : rest) = do
      -- ① 準備:交易外。每一檔各自有出口 —— 權限不足或掃到一半被移走
      --    不該讓整次掃描崩掉(這是掃描期間的常態,不是環境失效)。
      (prepared, acc') <- foldM prepareOne ([], acc) batch

      -- ② 寫入:交易內只有 execute。
      w <- guardedTry (withTransaction conn (mapM_ (writeLoose conn rootId now) (reverse prepared)))
      case w of
        Left e
          | Just why <- writeFailure e -> aborted acc' why
          | otherwise -> do
              let msg = "散檔批次寫入失敗:" <> compact e
              onEvent (EvProblem msg)
              pure acc' {srProblems = srProblems acc' <> [msg]}
        Right () -> do
          let written = length prepared
              bytes = sum (map plBytes prepared)
          go
            now
            acc'
              { srLooseFiles = srLooseFiles acc' + written
              , srBytesHashed = srBytesHashed acc' + bytes
              }
            rest

    aborted acc why = do
      onEvent (EvAborted why)
      pure acc {srAborted = Just why, srProblems = srProblems acc <> ["中止:" <> why]}

    prepareOne (done, acc) p = do
      r <- guardedTry (prepareLoose absRoot p)
      case r of
        Right pl -> pure (pl : done, acc)
        Left e -> do
          -- 掃描期間檔案被移走、權限不足 —— 是常態,不是環境失效。
          -- 記下來繼續跑;舊版這裡沒有任何 try,一個檔案就能讓整次掃描崩掉。
          let msg = T.pack (takeFileName p) <> ":讀取失敗 " <> compact e
          onEvent (EvProblem msg)
          pure (done, acc {srProblems = srProblems acc <> [msg]})

-- | 交易**外**把一筆散檔算完。
--
-- 記憶體策略分兩路(ingest/E004):圖片與音效的探測本來就需要整份內容
-- (PNG 解碼數色、WAV 走 chunk),既然要讀,雜湊就用同一份位元組,不讀第二次。
-- 其餘 kind 的 hProbe 都是 const Nothing,雜湊改走與 'sha256File' 相同的串流
-- 路徑 —— reference/ 底下的大型相片或原始檔不再整檔進記憶體。
prepareLoose :: FilePath -> FilePath -> IO PreparedLoose
prepareLoose absRoot p = do
  let relPath = T.pack (makeRelativeTo absRoot p)
      leaf = T.pack (takeFileName p)
      kind = kindForPath relPath
  (sha, size, meta) <- case handlerFor (extensionOf relPath) of
    Just h
      | hKind h `elem` [KImage, KAudio] -> do
          content <- BS.readFile p
          pure (sha256Bytes content, fromIntegral (BS.length content), hProbe h content)
    _ -> do
      sha <- sha256File p
      size <- getFileSize p
      pure (sha, size, Nothing)
  -- 與 'prepareEntry' 同樣的理由:強制到「真的算完了」,否則計算會跟著
  -- thunk 飄進下一步的交易裡。
  let shaText = unSha256 sha
      metaText = forceMaybeText (encodeMeta meta)
  shaText `seq` T.length shaText `seq` pure ()
  pure (PreparedLoose relPath leaf (extensionOf relPath) kind shaText metaText size)

-- | 交易**內**的唯一動作。參數型別裡沒有 @FilePath@,讀不了檔。
writeLoose :: Connection -> Int -> Text -> PreparedLoose -> IO ()
writeLoose conn rootId now PreparedLoose {..} = do
  upsertBlobText conn plSha plBytes plKind plMeta now
  execute conn "DELETE FROM assets WHERE root_id = ? AND rel_path = ?" (rootId, plRel)
  u <- unULID <$> newULID
  execute
    conn
    "INSERT INTO assets \
    \ (ulid,kind,root_id,rel_path,original_name,ext,sha256,meta_json,created_at,updated_at) \
    \VALUES (?,?,?,?,?,?,?,?,?,?)"
    [ SQLText u
    , SQLText (toTextEnum plKind)
    , SQLInteger (fromIntegral rootId)
    , SQLText plRel
    , SQLText plLeaf
    , SQLText plExt
    , SQLText plSha
    , maybe SQLNull SQLText plMeta
    , SQLText now
    , SQLText now
    ]

--------------------------------------------------------------------------------
-- 資料庫小工具

-- | 同一份內容跨素材包只算一次。多家廠商常常附上同一份免費字型或授權文字。
--
-- 收的是**已序列化**的雜湊與中繼資料:這個函式只在交易內被呼叫,而交易內
-- 不做任何計算(ADR-009)。
upsertBlobText :: Connection -> Text -> Integer -> AssetKind -> Maybe Text -> Text -> IO ()
upsertBlobText conn sha bytes kind meta now =
  execute
    conn
    "INSERT OR IGNORE INTO blobs (sha256,bytes,kind,meta_json,first_seen) VALUES (?,?,?,?,?)"
    [ SQLText sha
    , SQLInteger (fromIntegral bytes)
    , SQLText (toTextEnum kind)
    , maybe SQLNull SQLText meta
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
      name = T.pack (takeBaseName path)
      slug = slugify name `orElse` slugify relPath `orElse` "pack"
      -- 識別鍵用**壓縮檔的相對路徑**,不是衍生出來的 slug。
      --
      -- 這不是任意選擇:slugify 對純中文名稱會產生空字串
      -- (所有非 ASCII 字元被替換後折疊掉),於是「金門建築.rar」與
      -- 「金門地道.rar」的 slug 都是空的,兩個素材包被靜默合併成一個。
      -- 相對路徑則保證唯一。
      key = relPath
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

-- | 空字串時退回下一個候選。
--
-- 純中文的素材包名稱 slugify 之後什麼都不剩,需要有東西頂上。
-- 真正的 slug 由 @packs.toml@ 指定 —— 自動推導只要非空且不誤導即可。
orElse :: Text -> Text -> Text
orElse a b = if T.null a then b else a

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

makeRelativeTo :: FilePath -> FilePath -> FilePath
makeRelativeTo root p = map toSlash (makeRelative root p)
  where
    toSlash c = if c == '\\' then '/' else c

compact :: Show a => a -> Text
compact = T.unwords . T.words . T.pack . show
