-- | 端到端的掃描測試。
--
-- fixture 在測試中即時建立,不依賴任何外部素材庫。
-- 內容刻意重現真實素材庫的特徵:一個壓縮檔加散檔、跨包重複的內容、
-- 中文檔名、名稱含 @&@ 與空格。
module AssetDB.Ingest.ScanSpec (spec) where

import AssetDB.Archive (discoverTools)
import AssetDB.Ingest
import AssetDB.Store
import Codec.Archive.Zip qualified as Z
import Codec.Picture qualified as P
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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

count :: Store -> Text -> IO Int
count st what = do
  rows <- query_ (storeConn st) (Query ("SELECT COUNT(*) FROM " <> what))
  pure (case rows of (Only n : _) -> n; _ -> -1)
