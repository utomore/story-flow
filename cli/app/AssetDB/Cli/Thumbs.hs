module AssetDB.Cli.Thumbs (runThumbs) where

import AssetDB.Archive (discoverTools)
import AssetDB.Ingest.ThumbRun
import AssetDB.Store
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple
import System.FilePath (takeDirectory, (</>))

runThumbs :: FilePath -> Bool -> IO ()
runThumbs dbPath force = do
  tools <- discoverTools
  -- 快取與資料庫放在一起(.assetdb/),素材庫本身是備份目標,不該被衍生物弄髒。
  let assetdbDir = takeDirectory dbPath
      cache = assetdbDir </> "cache" </> "thumbs"
      libRoot = takeDirectory assetdbDir </> "library"

  withStore dbPath $ \st -> do
    _ <- initSchema st
    r <-
      generateThumbs
        st
        tools
        (defaultThumbOptions cache libRoot)
          { toForce = force
          , toOnProgress = \i n _ ->
              if i `mod` 250 == 0 || i == n
                then TIO.putStrLn ("  " <> tshow i <> "/" <> tshow n)
                else pure ()
          }

    TIO.putStrLn ""
    TIO.putStrLn ("產生 " <> tshow (trMade r) <> ",跳過 " <> tshow (trSkipped r))

    case trFailed r of
      [] -> pure ()
      fs -> do
        TIO.putStrLn ("⚠ " <> tshow (length fs) <> " 份內容產生失敗:")
        mapM_ (\(s, e) -> TIO.putStrLn ("    " <> T.take 12 s <> "  " <> T.take 90 e)) (take 10 fs)

    counts <-
      query_
        (storeConn st)
        "SELECT thumb_status, COUNT(*) FROM blobs WHERE kind='image' GROUP BY thumb_status" ::
        IO [(T.Text, Int)]
    TIO.putStrLn ""
    mapM_ (\(s, n) -> TIO.putStrLn ("  " <> s <> "  " <> tshow n)) counts

tshow :: Show a => a -> T.Text
tshow = T.pack . show
