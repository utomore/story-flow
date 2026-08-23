-- | ZIP 原生路徑的測試。
--
-- fixture 在測試中即時建立,不依賴任何外部檔案 —— 測試不該綁在某台機器的
-- 素材庫上。fixture 的內容刻意重現素材庫裡真實出現過的難處:
-- 巢狀同名目錄、中文檔名、名稱含 @&@ 與空格。
module AssetDB.Archive.ZipSpec (spec) where

import AssetDB.Archive
import Codec.Archive.Zip qualified as Z
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = around withFixture $ do
  describe "listEntries" $ do
    it "列出所有項目" $ \(tools, zipPath) -> do
      r <- listEntries tools zipPath
      fmap (sort . map aePath) r `shouldBe` Right (sort (map fst fixtureFiles))

    it "路徑一律以 / 分隔" $ \(tools, zipPath) -> do
      Right es <- listEntries tools zipPath
      filter (T.isInfixOf "\\") (map aePath es) `shouldBe` []

    it "大小正確" $ \(tools, zipPath) -> do
      Right es <- listEntries tools zipPath
      let sizeOf p = [aeSize e | e <- es, aePath e == p]
      forM_ fixtureFiles $ \(p, content) ->
        sizeOf p `shouldBe` [fromIntegral (BC.length content)]

    it "CRC32 從 central directory 免費取得" $ \(tools, zipPath) -> do
      -- 這是 SHA-256 之前的廉價前濾:CRC 不同就一定不是同一份內容。
      Right es <- listEntries tools zipPath
      all (/= Nothing) (map aeCrc32 es) `shouldBe` True

    it "巢狀同名目錄不會混淆" $ \(tools, zipPath) -> do
      -- Kibyra 的 food-icons 真的長這樣:food-icons/Foods/Foods/
      Right es <- listEntries tools zipPath
      map aePath es `shouldSatisfy` elem "icons/Foods/Foods/food1.png"

    it "不存在的壓縮檔回報 MalformedArchive" $ \(tools, _) -> do
      r <- listEntries tools "no-such-file.zip"
      case r of
        Left (MalformedArchive _ _) -> pure ()
        other -> expectationFailure ("預期 MalformedArchive,收到 " <> show (fmap (const ()) other))

    it "不認得的副檔名回報 UnsupportedExtension" $ \(tools, _) -> do
      r <- listEntries tools "a.tar.gz"
      r `shouldSatisfy` isUnsupported

  describe "readEntry" $ do
    it "讀出的內容與寫入時一致" $ \(tools, zipPath) ->
      forM_ fixtureFiles $ \(p, content) -> do
        r <- readEntry tools zipPath p
        r `shouldBe` Right content

    it "中文檔名讀得到" $ \(tools, zipPath) -> do
      r <- readEntry tools zipPath "docs/金門建築.txt"
      r `shouldBe` Right (lookupFixture "docs/金門建築.txt")

    it "檔名含 & 與空格讀得到" $ \(tools, zipPath) -> do
      -- 素材庫裡有 herbs&medicinal-plants.zip 與 "Blue Potion 2.png"
      r <- readEntry tools zipPath "icons/herbs&medicinal plants.png"
      r `shouldBe` Right (lookupFixture "icons/herbs&medicinal plants.png")

    it "不存在的項目回報 EntryNotFound 而不是空內容" $ \(tools, zipPath) -> do
      r <- readEntry tools zipPath "icons/nope.png"
      case r of
        Left (EntryNotFound _ e) -> e `shouldBe` "icons/nope.png"
        other -> expectationFailure ("預期 EntryNotFound,收到 " <> show (fmap BC.length other))

    it "傳入反斜線路徑也找得到" $ \(tools, zipPath) -> do
      -- 呼叫端可能從 7-Zip 那條路徑拿到反斜線形式的路徑
      r <- readEntry tools zipPath "icons\\Foods\\Foods\\food1.png"
      r `shouldBe` Right (lookupFixture "icons/Foods/Foods/food1.png")

--------------------------------------------------------------------------------

-- | 重現素材庫裡真實出現過的難處。
fixtureFiles :: [(Text, ByteString)]
fixtureFiles =
  [ ("icons/Foods/Foods/food1.png", pngLike "food1")
  , ("icons/herbs&medicinal plants.png", pngLike "herbs")
  , ("docs/金門建築.txt", "1990 年代金門建築參考")
  , ("License.txt", "Credit is not needed but appreciated.")
  ]

-- | 假的 PNG:前八個位元組是真的 magic,足以驗證二進位內容沒被文字編碼弄壞。
pngLike :: ByteString -> ByteString
pngLike tag = BC.pack "\137PNG\r\n\26\n" <> tag

lookupFixture :: Text -> ByteString
lookupFixture p = maybe (error ("fixture 沒有 " <> T.unpack p)) id (lookup p fixtureFiles)

withFixture :: ((ArchiveTools, FilePath) -> IO ()) -> IO ()
withFixture f =
  withSystemTempDirectory "assetdb-archive" $ \dir -> do
    let zipPath = dir </> "fixture.zip"
    Z.createArchive zipPath $
      forM_ fixtureFiles $ \(p, content) -> do
        sel <- Z.mkEntrySelector (T.unpack p)
        Z.addEntry Z.Deflate content sel
    tools <- discoverTools
    f (tools, zipPath)

isUnsupported :: Either ArchiveError a -> Bool
isUnsupported (Left (UnsupportedExtension _)) = True
isUnsupported _ = False
