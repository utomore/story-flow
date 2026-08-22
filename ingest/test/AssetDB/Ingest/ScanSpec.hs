-- | 端到端的掃描測試。
--
-- fixture 在測試中即時建立,不依賴任何外部素材庫。
-- 內容刻意重現真實素材庫的特徵:一個壓縮檔加散檔、跨包重複的內容、
-- 中文檔名、名稱含 @&@ 與空格。
module AssetDB.Ingest.ScanSpec (spec) where

import AssetDB.Archive (discoverTools, listEntries)
import AssetDB.Ingest
import AssetDB.Store
import Codec.Archive.Zip qualified as Z
import Codec.Picture qualified as P
import Control.Exception (AsyncException (..), SomeException, throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, createDirectoryLink, getFileSize, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callCommand)
import Test.Hspec

spec :: Spec
spec = around withScanned $ do
  describe "索引結果" $ do
    it "壓縮檔與散檔都進了資料庫" $ \(st, _) -> do
      count st "archives" `shouldReturn` 1
      count st "assets WHERE archive_id IS NOT NULL" `shouldReturn` 3
      count st "assets WHERE root_id IS NOT NULL" `shouldReturn` 2

    it "每一筆都有 SHA-256" $ \(st, _) ->
      -- 沒有雜湊的項目不能作為重構刪除閘門的依據,所以這必須是零。
      count st "assets WHERE sha256 IS NULL" `shouldReturn` 0

    it "相同內容跨來源只算一份 blob" $ \(st, _) -> do
      -- shared.png 同時存在於壓縮檔內與散檔。5 筆資源指向 4 份唯一內容。
      count st "assets" `shouldReturn` 5
      count st "blobs" `shouldReturn` 4

    it "目錄不會被當成資源" $ \(st, _) ->
      count st "assets WHERE entry_path LIKE '%/'" `shouldReturn` 0

    it "素材包一律建成 draft" $ \(st, _) -> do
      -- 授權與作者無法從檔名推導,而猜錯的授權比沒有授權更危險。
      count st "packs" `shouldReturn` 1
      count st "packs WHERE status = 'draft'" `shouldReturn` 1

    it "路徑一律以 / 分隔" $ \(st, _) -> do
      rows <- query_ (storeConn st) "SELECT entry_path FROM assets WHERE entry_path IS NOT NULL"
      filter (T.isInfixOf "\\") (map fromOnly rows) `shouldBe` ([] :: [Text])

    it "中文檔名完整保留" $ \(st, _) -> do
      rows <- query_ (storeConn st) "SELECT rel_path FROM assets WHERE rel_path LIKE '%金門%'"
      map fromOnly rows `shouldBe` (["docs/金門建築.txt"] :: [Text])

    it "PNG 的中繼資料有抽出來" $ \(st, _) -> do
      rows <-
        query_
          (storeConn st)
          "SELECT meta_json FROM assets WHERE original_name = 'sprite.png'" ::
          IO [Only (Maybe Text)]
      case rows of
        (Only (Just m) : _) -> m `shouldSatisfy` T.isInfixOf "\"width\""
        (Only Nothing : _) -> expectationFailure "sprite.png 的 meta_json 是 NULL"
        [] -> expectationFailure "找不到 sprite.png"

  describe "冪等性" $ do
    it "重掃時壓縮檔雜湊未變就跳過" $ \(st, opts) -> do
      tools <- discoverTools
      r <- scanRoot st tools opts
      srArchives r `shouldBe` 0
      srArchivesSkipped r `shouldBe` 1

    it "重掃不會產生重複資源" $ \(st, opts) -> do
      tools <- discoverTools
      void (scanRoot st tools opts)
      count st "assets" `shouldReturn` 5

    it "--rehash 會強制重算" $ \(st, opts) -> do
      tools <- discoverTools
      r <- scanRoot st tools opts {soRehash = True}
      srArchives r `shouldBe` 1
      srArchivesSkipped r `shouldBe` 0
      -- 重算之後筆數仍然一樣 —— 舊項目被刪掉重建,沒有殘留
      count st "assets" `shouldReturn` 5

  -- ingest/E004:散檔雜湊分兩路 —— 圖片/音效整檔讀(探測本來就需要
  -- 全部位元組),其餘 kind 走 sha256File 的串流路徑。兩路對同一份
  -- 內容的結果都必須與串流雜湊一致,大小也必須正確。
  describe "散檔雜湊策略" $ do
    it "串流路徑(非媒體 kind)的雜湊與大小和整檔讀取一致" $ \(st, opts) -> do
      -- .txt 的處理器不探測內容,走串流路徑。
      let path = soRootPath opts </> "docs" </> "金門建築.txt"
      expected <- unSha256 <$> sha256File path
      rows <-
        query_ (storeConn st) "SELECT sha256 FROM assets WHERE rel_path = 'docs/金門建築.txt'" ::
          IO [Only Text]
      map fromOnly rows `shouldBe` [expected]
      size <- getFileSize path
      brows <-
        query (storeConn st) "SELECT bytes FROM blobs WHERE sha256 = ?" (Only expected) ::
          IO [Only Integer]
      map fromOnly brows `shouldBe` [size]

    it "媒體路徑(整檔讀供探測)的雜湊與 sha256File 一致" $ \(st, opts) -> do
      expected <- unSha256 <$> sha256File (soRootPath opts </> "extracted" </> "shared.png")
      rows <-
        query_ (storeConn st) "SELECT sha256 FROM assets WHERE rel_path = 'extracted/shared.png'" ::
          IO [Only Text]
      map fromOnly rows `shouldBe` [expected]

  -- ingest/E005:junction / 符號連結指回祖先時,不防的話是無窮遞迴。
  -- B001:整包取不到內容時不得被當成索引成功。
  --
  -- 「整個壓縮檔讀不開」與「壓縮檔讀得開、但其中某些項目讀不到內容」是兩件
  -- 不同的事:前者代表這一包完全沒有可信的內容雜湊,而內容雜湊是去重、縮圖、
  -- 專案取材與重構刪除閘門的共同基礎。
  describe "整包取不到內容(B001)" $ do
    it "列不出來的壓縮檔不計入成功,也不寫入任何項目" $ \(_, _) ->
      withSystemTempDirectory "assetdb-unreadable-archive" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True root
        -- 內容是垃圾:有 7-Zip 時 7z l 失敗,沒有時 SidecarNotFound,兩種都列不出來。
        BC.writeFile (root </> "broken.rar") "this is not a rar archive at all"
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        tools <- discoverTools
        rep <- scanRoot st tools (defaultScanOptions root)
        srArchives rep `shouldBe` 0
        srArchivesFailed rep `shouldBe` 1
        count st "assets" `shouldReturn` 0
        srProblems rep `shouldSatisfy` (not . null)
        close (storeConn st)

    it "列得出來但取不出來時,不計入成功,也不留下沒有雜湊的項目" $ \(_, _) ->
      withSystemTempDirectory "assetdb-corrupt-solid" $ \dir -> do
        let root = dir </> "library"
            path = root </> "corrupt.7z"
        createDirectoryIfMissing True root
        makeListableUnextractable path
        tools <- discoverTools
        listEntries tools path >>= \case
          Left _ ->
            -- 列不出來就測不到「列得出但取不出」那條路徑 —— 標為 pending
            -- 而不是假裝通過(沿用本檔符號連結測試的作法)。
            pendingWith "此環境列不出這個 fixture(多半是沒有 7-Zip),跳過"
          Right entries -> do
            length entries `shouldSatisfy` (> 0)
            st <- openStore (dir </> "db.sqlite")
            void (initSchema st)
            events <- newIORef []
            let opts =
                  (defaultScanOptions root)
                    { soOnEvent = \e -> modifyIORef' events (e :)
                    }
            rep <- scanRoot st tools opts
            -- 修復前:srArchives = 1、assets = 3(每一筆 sha256 都是 NULL)
            srArchives rep `shouldBe` 0
            srArchivesFailed rep `shouldBe` 1
            count st "assets" `shouldReturn` 0
            count st "assets WHERE sha256 IS NULL" `shouldReturn` 0
            -- 失敗必須帶得出原因,而且不能偽裝成完成事件
            seen <- readIORef events
            seen `shouldSatisfy` any (\case EvArchiveFailed _ why -> not (T.null why); _ -> False)
            seen `shouldSatisfy` not . any (\case EvArchiveDone _ _ -> True; _ -> False)
            close (storeConn st)

  -- E006 的回歸網:分批提交不得改變任何一筆的結果。
  describe "散檔批次(E006 回歸)" $
    it "超過一批的散檔全部入庫,每筆的雜湊與大小都正確" $ \(_, _) ->
      withSystemTempDirectory "assetdb-loose-batch" $ \dir -> do
        let root = dir </> "library"
            n = 250 :: Int
        createDirectoryIfMissing True root
        forM_ [1 .. n] $ \i ->
          BC.writeFile (root </> ("f" <> show i <> ".txt")) (BC.pack ("content " <> show i))
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        tools <- discoverTools
        rep <- scanRoot st tools (defaultScanOptions root)
        srLooseFiles rep `shouldBe` n
        count st "assets" `shouldReturn` n
        count st "assets WHERE sha256 IS NULL" `shouldReturn` 0
        -- 每一筆的雜湊都要是它自己內容的雜湊,不是別筆的
        expected <- pure (unSha256 (sha256Bytes (BC.pack "content 7")))
        shaOf st "f7.txt" `shouldReturn` Just expected
        close (storeConn st)

  -- E006 / ADR-009:寫交易的持有時間必須以毫秒計。任何檔案 IO、解碼、雜湊
  -- 都要在交易之外算完 —— 因為 assetdb-server 可能正在同一個資料庫上服務查詢,
  -- 寫鎖持有超過 busy_timeout 會讓它寫入失敗。
  describe "交易邊界(E006)" $ do
    it "寫入階段的輸入裡沒有檔案路徑,只有已經算完的值" $ \(_, _) ->
      withSystemTempDirectory "assetdb-prepared" $ \dir -> do
        let f = dir </> "x.txt"
        BC.writeFile f "hello"
        pl <- prepareLoose dir f
        -- 型別本身保證交易內讀不了檔:PreparedLoose 沒有 FilePath 欄位。
        -- 這裡驗證的是它確實**已經算完** —— 雜湊是真的雜湊,不是 thunk。
        plSha pl `shouldBe` unSha256 (sha256Bytes (BC.pack "hello"))
        plBytes pl `shouldBe` 5
        plRel pl `shouldBe` "x.txt"

    it "一批寫入的單次交易持有時間以毫秒計" $ \(_, _) ->
      withSystemTempDirectory "assetdb-txn-time" $ \dir -> do
        let n = looseBatchSize
        forM_ [1 .. n] $ \i ->
          BC.writeFile (dir </> ("b" <> show i <> ".txt")) (BC.pack ("body " <> show i))
        prepared <-
          mapM (\i -> prepareLoose dir (dir </> ("b" <> show i <> ".txt"))) [1 .. n]
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        let conn = storeConn st
        execute_ conn "INSERT INTO roots (id,path,label,kind) VALUES (1,'/r','r','packs')"
        t0 <- getCurrentTime
        withTransaction conn (mapM_ (writeLoose conn 1 "t") prepared)
        t1 <- getCurrentTime
        -- 上限刻意寬鬆:抓的是「有人把 IO 搬回交易裡」這種數量級回歸,
        -- 不是微調效能。
        realToFrac (diffUTCTime t1 t0) `shouldSatisfy` (< (0.1 :: Double))
        close conn

    it "Ctrl-C 不會被當成一則問題吞掉" $ \(_, _) -> do
      -- 裸 try @SomeException 會接住 AsyncException,於是掃描迴圈繼續跑
      -- 下一項 —— 使用者按幾次 Ctrl-C 都停不下來(ai/Run.hs 的 guardedTry
      -- 註解記載了同一個教訓)。
      caught <- try (guardedTry (throwIO UserInterrupt)) :: IO (Either AsyncException (Either SomeException ()))
      case caught of
        Left UserInterrupt -> pure ()
        Left other -> expectationFailure ("預期 UserInterrupt,得到 " <> show other)
        Right _ -> expectationFailure "AsyncException 被吞掉了,應該要穿透"

    it "一般例外仍然接得住" $ \(_, _) -> do
      r <- guardedTry (throwIO (userError "boom")) :: IO (Either SomeException ())
      r `shouldSatisfy` isLeft

  -- E006:批次失敗兩層。界線劃在寫入端 vs 讀取端。
  describe "整批中止(E006)" $ do
    it "正常跑完時 srAborted 是 Nothing" $ \(st, opts) -> do
      srAborted emptyReport `shouldBe` Nothing
      tools <- discoverTools
      rep <- scanRoot st tools opts {soRehash = True}
      srAborted rep `shouldBe` Nothing
      srArchives rep `shouldBe` 1

    it "寫入端失效即中止,剩下的壓縮檔不再處理" $ \(_, _) ->
      withSystemTempDirectory "assetdb-write-abort" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True root
        forM_ ["one.zip", "two.zip"] $ \nm ->
          Z.createArchive (root </> nm) $ do
            sel <- Z.mkEntrySelector "a.txt"
            Z.addEntry Z.Deflate (BC.pack nm) sel
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        let conn = storeConn st
        events <- newIORef []
        tools <- discoverTools
        -- 走訪完成之後才把資料庫切成唯讀:寫入必定拋 SQLError,讀取照常。
        -- (切在更早會連 ensureRoot 都寫不進去,而那條裸寫入屬 G-E003 的範圍,
        --  不在 E006 的 scope 內。)
        rep <-
          scanRoot st tools (defaultScanOptions root)
            { soOnEvent = \e -> do
                modifyIORef' events (e :)
                case e of
                  EvDiscovered _ _ -> execute_ conn "PRAGMA query_only = 1"
                  _ -> pure ()
            }
        srAborted rep `shouldSatisfy` isJust
        srArchives rep `shouldBe` 0
        seen <- readIORef events
        -- 只有第一個壓縮檔被碰過 —— 中止之後不再往下跑
        length [() | EvArchiveStart {} <- seen] `shouldBe` 1
        length [() | EvAborted _ <- seen] `shouldBe` 1
        execute_ (storeConn st) "PRAGMA query_only = 0"
        close (storeConn st)

    it "中止後已完成的部分留在資料庫,重跑補齊且不重複" $ \(_, _) ->
      withSystemTempDirectory "assetdb-abort-resume" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True root
        forM_ ["one.zip", "two.zip"] $ \nm ->
          Z.createArchive (root </> nm) $ do
            sel <- Z.mkEntrySelector "a.txt"
            Z.addEntry Z.Deflate (BC.pack nm) sel
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        let conn = storeConn st
        tools <- discoverTools
        -- 第一個壓縮檔寫完之後才切唯讀 → 第二個中止
        rep1 <-
          scanRoot st tools (defaultScanOptions root)
            { soOnEvent = \case
                EvArchiveDone _ _ -> execute_ conn "PRAGMA query_only = 1"
                _ -> pure ()
            }
        srAborted rep1 `shouldSatisfy` isJust
        execute_ conn "PRAGMA query_only = 0"
        -- 已完成的那一包還在
        count st "assets" `shouldReturn` 1
        -- 重跑補齊,而且不產生重複
        rep2 <- scanRoot st tools (defaultScanOptions root)
        srAborted rep2 `shouldBe` Nothing
        count st "assets" `shouldReturn` 2
        count st "archives" `shouldReturn` 2
        close conn

    it "中止的報告說得出原因,也說得出該做什麼" $ \(_, _) -> do
      let t = renderReport emptyReport {srAborted = Just "磁碟已滿", srArchives = 3}
      t `shouldSatisfy` T.isInfixOf "中止"
      t `shouldSatisfy` T.isInfixOf "磁碟已滿"
      t `shouldSatisfy` T.isInfixOf "重跑"
      t `shouldNotSatisfy` T.isInfixOf "掃描完成"
      renderEvent (EvAborted "壞了") `shouldSatisfy` maybe False (T.isInfixOf "壞了")
      -- 沒有中止時維持原本的措辭
      renderReport emptyReport `shouldSatisfy` T.isInfixOf "掃描完成"

    it "讀取端失敗不中止,其餘壓縮檔照樣索引" $ \(_, _) ->
      withSystemTempDirectory "assetdb-read-failure" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True root
        -- 一個讀不開的,一個正常的
        BC.writeFile (root </> "broken.rar") "not an archive"
        Z.createArchive (root </> "good.zip") $ do
          sel <- Z.mkEntrySelector "a.txt"
          Z.addEntry Z.Deflate "content" sel
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        tools <- discoverTools
        rep <- scanRoot st tools (defaultScanOptions root)
        srAborted rep `shouldBe` Nothing
        srArchivesFailed rep `shouldBe` 1
        srArchives rep `shouldBe` 1
        count st "assets" `shouldReturn` 1
        close (storeConn st)

    it "散檔讀不到時記下來繼續跑,不讓整次掃描崩掉" $ \(_, _) ->
      withSystemTempDirectory "assetdb-loose-failure" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True root
        BC.writeFile (root </> "ok1.txt") "one"
        BC.writeFile (root </> "gone.txt") "two"
        BC.writeFile (root </> "ok2.txt") "three"
        st <- openStore (dir </> "db.sqlite")
        void (initSchema st)
        tools <- discoverTools
        -- 在走訪之後、準備之前把檔案抽走:模擬掃描期間被移動的檔案。
        -- 用事件回呼卡住時序 —— EvLooseStart 在準備階段之前發出。
        let opts =
              (defaultScanOptions root)
                { soOnEvent = \case
                    EvLooseStart _ -> removeFile (root </> "gone.txt")
                    _ -> pure ()
                }
        rep <- scanRoot st tools opts
        -- 沒有崩掉,而且是「單筆失敗」不是「整批中止」
        srAborted rep `shouldBe` Nothing
        srProblems rep `shouldSatisfy` any (T.isInfixOf "gone.txt")
        count st "assets" `shouldReturn` 2
        close (storeConn st)

  describe "符號連結迴圈防護" $
    it "對含自我指涉連結的目錄樹不無窮遞迴,且記錄警告" $ \(_, _) ->
      withSystemTempDirectory "assetdb-symlink-loop" $ \dir -> do
        let root = dir </> "library"
        createDirectoryIfMissing True (root </> "sub")
        BC.writeFile (root </> "sub" </> "a.txt") "loop fixture"
        made <- makeDirLoop root (root </> "sub" </> "loop")
        if not made
          then
            -- 建不出迴圈就測不到迴圈 —— 標為 pending 而不是假裝通過。
            pendingWith "此環境無法建立目錄連結(符號連結與 junction 都失敗),跳過"
          else do
            st <- openStore (dir </> "db.sqlite")
            void (initSchema st)
            tools <- discoverTools
            rep <- scanRoot st tools (defaultScanOptions root)
            srProblems rep `shouldSatisfy` any (T.isInfixOf "迴圈")
            -- 迴圈內的檔案只被索引一次,不會經由連結重複入庫
            count st "assets WHERE rel_path LIKE '%a.txt'" `shouldReturn` 1
            close (storeConn st)

--------------------------------------------------------------------------------

sharedPng :: ByteString
sharedPng = BC.pack "\137PNG\r\n\26\n" <> "shared content"

archiveFiles :: [(Text, ByteString)]
archiveFiles =
  [ ("Sprites/sprite.png", tinyPng)
  , ("Sprites/Sprites/nested.png", BC.pack "\137PNG\r\n\26\n" <> "nested")
  , ("shared.png", sharedPng)
  ]

looseFiles :: [(FilePath, ByteString)]
looseFiles =
  [ ("extracted/shared.png", sharedPng) -- 與壓縮檔內同一份內容
  , ("docs/金門建築.txt", "1990 年代參考")
  ]

-- | 真的 PNG。手工拼位元組會拼出無效的 CRC,而失敗是靜默的 ——
-- 解不出中繼資料看起來就像「這個檔案沒有中繼資料」。
tinyPng :: ByteString
tinyPng =
  BL.toStrict (P.encodePng (P.generateImage (\_ _ -> P.PixelRGBA8 10 20 30 255) 4 4))

withScanned :: ((Store, ScanOptions) -> IO ()) -> IO ()
withScanned f =
  withSystemTempDirectory "assetdb-scan-test" $ \dir -> do
    let root = dir </> "library"
    createDirectoryIfMissing True root

    Z.createArchive (root </> "demo pack & more.zip") $
      forM_ archiveFiles $ \(p, content) -> do
        sel <- Z.mkEntrySelector (T.unpack p)
        Z.addEntry Z.Deflate content sel

    forM_ looseFiles $ \(p, content) -> do
      let full = root </> p
      createDirectoryIfMissing True (takeDir full)
      writeBS full content

    st <- openStore (dir </> "db.sqlite")
    void (initSchema st)
    tools <- discoverTools
    let opts = (defaultScanOptions root) {soRootKind = "packs"}
    void (scanRoot st tools opts)
    f (st, opts)
    close (storeConn st)
  where
    takeDir = reverse . drop 1 . dropWhile (`notElem` ("/\\" :: String)) . reverse
    writeBS p c = BC.writeFile p c

-- | 一個**列得出來但取不出來**的壓縮檔 —— B001 的原始觸發條件。
--
-- 作法:用 @Store@(不壓縮)建一個 ZIP,再把項目資料區的位元組打壞。
-- 結尾的 central directory 完好,所以 7-Zip 列得出項目;項目資料的 CRC
-- 對不上,所以整包解壓會以非零結束碼失敗。
--
-- 副檔名用 @.7z@ 是為了讓 'prefersBulkExtraction' 為真,走整包解壓那條路徑
-- —— 那正是缺陷所在。7-Zip 依內容自動辨識格式,所以副檔名與實際格式不符
-- 不影響列出。
makeListableUnextractable :: FilePath -> IO ()
makeListableUnextractable path = do
  let build = path <> ".build"
  Z.createArchive build $
    forM_ [1 :: Int .. 3] $ \i -> do
      sel <- Z.mkEntrySelector ("data" <> show i <> ".bin")
      Z.addEntry Z.Store (BC.pack (replicate 512 'A')) sel
  raw <- BS.readFile build
  removeFile build
  -- 位移 64 起的 256 位元組落在第一個項目的資料區內(local header 約 40 位元組,
  -- 資料 512 位元組),central directory 在檔尾,不受影響。
  let (untouchedHead, rest) = BS.splitAt 64 raw
      (victim, untouchedTail) = BS.splitAt 256 rest
  BS.writeFile path (untouchedHead <> BS.map (const 0x00) victim <> untouchedTail)

-- | 建一個指回祖先的目錄迴圈。POSIX 上符號連結一定建得起來;Windows 上
-- 符號連結需要開發者模式或管理員權限,但 junction(@mklink /J@)不用 ——
-- 兩種都試,任一成功即可。
makeDirLoop :: FilePath -> FilePath -> IO Bool
makeDirLoop target link = do
  r <- try (createDirectoryLink target link) :: IO (Either SomeException ())
  case r of
    Right () -> pure True
    Left _ -> do
      r2 <-
        try (callCommand ("cmd /c mklink /J \"" <> link <> "\" \"" <> target <> "\" >NUL")) ::
          IO (Either SomeException ())
      pure (either (const False) (const True) r2)

count :: Store -> Text -> IO Int
count st what = do
  rows <- query_ (storeConn st) (Query ("SELECT COUNT(*) FROM " <> what))
  pure (case rows of (Only n : _) -> n; _ -> -1)

shaOf :: Store -> Text -> IO (Maybe Text)
shaOf st rel = do
  rows <-
    query (storeConn st) "SELECT sha256 FROM assets WHERE rel_path = ?" (Only rel)
  pure (case rows of (Only s : _) -> s; _ -> Nothing)
