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
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
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
