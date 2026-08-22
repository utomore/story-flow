-- | 縮圖批次的錯誤邊界(G-E003 T6)。
--
-- 這個迴圈跑六千多次,而寫檔是裡面最可能失敗的一步(磁碟滿、快取目錄
-- 唯讀)。原本寫檔失敗會讓例外直接飛出 'generateThumbs' —— 一個壞掉的
-- 目標路徑就毀掉整批。
module AssetDB.Ingest.ThumbRunSpec (spec) where

import AssetDB.Archive (ArchiveTools, discoverTools)
import AssetDB.Ingest
import AssetDB.Ingest.ThumbRun
import AssetDB.PathText (ThumbSize (..), thumbPath)
import AssetDB.Store
import Codec.Archive.Zip qualified as Z
import Codec.Picture qualified as P
import Control.Exception (AsyncException (..), throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "generateThumbs 的錯誤出口(G-E003)" $ do
  it "寫檔失敗記進 trFailed,批次繼續跑完其餘的" $
    withThumbFixture $ \st tools cacheRoot lib shas -> do
      case pickIsolated shas of
        Nothing -> pendingWith "這批 sha 的前兩碼撞在一起,換一組 fixture 才測得到"
        Just victim -> do
          -- 在分片目錄該在的位置放一個**檔案**:createDirectoryIfMissing
          -- 會因為同名檔案已存在而失敗。比起改 ACL,這個觸發條件在每個
          -- 平台上都一樣。
          createDirectoryIfMissing True cacheRoot
          BS.writeFile (cacheRoot </> T.unpack (T.take 2 victim)) "占位"

          rep <- generateThumbs st tools (defaultThumbOptions cacheRoot lib)

          map fst (trFailed rep) `shouldBe` [victim]
          map snd (trFailed rep) `shouldSatisfy` all (T.isInfixOf "寫入縮圖快取失敗")
          -- 批次繼續:其餘每一份內容都做出縮圖了。
          trMade rep `shouldBe` length shas - 1
          forM_ (filter (/= victim) shas) $ \sha ->
            doesFileExist (thumbPath cacheRoot sha Thumb128) `shouldReturn` True

  it "失敗記進資料庫,重跑不會再試同一批壞的" $
    withThumbFixture $ \st tools cacheRoot lib shas ->
      case pickIsolated shas of
        Nothing -> pendingWith "這批 sha 的前兩碼撞在一起,換一組 fixture 才測得到"
        Just victim -> do
          createDirectoryIfMissing True cacheRoot
          BS.writeFile (cacheRoot </> T.unpack (T.take 2 victim)) "占位"
          _ <- generateThumbs st tools (defaultThumbOptions cacheRoot lib)
          rows <-
            query
              (storeConn st)
              "SELECT thumb_status FROM blobs WHERE sha256 = ?"
              (Only victim) ::
              IO [Only Text]
          map fromOnly rows `shouldBe` ["failed"]
          -- 第二次:pending 的都做完了,壞的那筆已經是 failed,不再入選。
          rep2 <- generateThumbs st tools (defaultThumbOptions cacheRoot lib)
          trFailed rep2 `shouldBe` []
          trMade rep2 `shouldBe` 0

  it "Ctrl-C 穿透整個批次,不會被記成一則失敗" $
    withThumbFixture $ \st tools cacheRoot lib shas -> do
      seen <- newIORef (0 :: Int)
      let opts =
            (defaultThumbOptions cacheRoot lib)
              { toOnProgress = \i _ _ -> do
                  modifyIORef' seen (+ 1)
                  if i == 2 then throwIO UserInterrupt else pure ()
              }
      r <- try (void (generateThumbs st tools opts)) :: IO (Either AsyncException ())
      case r of
        Left UserInterrupt -> pure ()
        Left other -> expectationFailure ("拋出的不是 UserInterrupt:" <> show other)
        Right () -> expectationFailure "中斷被吞掉了 —— 整批應該停下來"
      -- 停在第二筆:剩下的內容一個都沒被碰過。
      readIORef seen `shouldReturn` 2
      length shas `shouldSatisfy` (> 2)

--------------------------------------------------------------------------------

-- | 挑一份「前兩碼不與其他人相同」的內容 —— 擋掉它的分片目錄才不會
-- 連帶擋到別人,否則「批次繼續」這件事就測不出來。
pickIsolated :: [Text] -> Maybe Text
pickIsolated shas =
  case [s | s <- shas, length [() | o <- shas, T.take 2 o == T.take 2 s] == 1] of
    (s : _) -> Just s
    [] -> Nothing

-- | 一個含四張不同圖片的壓縮檔,掃描完成後把每份內容的 sha 交給測試。
withThumbFixture :: (Store -> ArchiveTools -> FilePath -> FilePath -> [Text] -> IO ()) -> IO ()
withThumbFixture k =
  withSystemTempDirectory "assetdb-thumbrun" $ \dir -> do
    let root = dir </> "library"
        cacheRoot = dir </> "cache" </> "thumbs"
    createDirectoryIfMissing True root
    Z.createArchive (root </> "pics.zip") $
      forM_ (zip [1 :: Int ..] (map pngOf [11, 22, 33, 44])) $ \(i, png) -> do
        sel <- Z.mkEntrySelector ("img" <> show i <> ".png")
        Z.addEntry Z.Store png sel
    st <- openStore (dir </> "db.sqlite")
    void (initSchema st)
    tools <- discoverTools
    void (scanRoot st tools (defaultScanOptions root))
    rows <-
      query_ (storeConn st) "SELECT sha256 FROM blobs WHERE kind = 'image' ORDER BY sha256" ::
        IO [Only Text]
    let shas = nub (map fromOnly rows)
    length shas `shouldBe` 4
    k st tools cacheRoot root shas
    close (storeConn st)

-- | 真的 PNG。手工拼位元組會拼出無效的 CRC,而那個失敗是靜默的。
pngOf :: Int -> ByteString
pngOf seed =
  BL.toStrict
    ( P.encodePng
        (P.generateImage (\x y -> P.PixelRGBA8 (fromIntegral (seed + x)) (fromIntegral (seed + y)) 30 255) 8 8)
    )
