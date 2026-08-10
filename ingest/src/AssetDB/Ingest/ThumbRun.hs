-- | 縮圖批次產生:從壓縮檔取出內容、產生縮圖、更新 @blobs.thumb_status@。
module AssetDB.Ingest.ThumbRun
  ( ThumbOptions (..)
  , defaultThumbOptions
  , ThumbReport (..)
  , generateThumbs
  ) where

import AssetDB.Archive
import AssetDB.Ingest.Thumb
import AssetDB.Store
import Control.Exception (SomeException, try)
import Control.Monad (foldM, forM_)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)

data ThumbOptions = ThumbOptions
  { toCacheRoot :: FilePath
  , toLibraryRoot :: FilePath
  , toForce :: Bool
  , toOnProgress :: Int -> Int -> Text -> IO ()
  }

defaultThumbOptions :: FilePath -> FilePath -> ThumbOptions
defaultThumbOptions cache lib = ThumbOptions cache lib False (\_ _ _ -> pure ())

data ThumbReport = ThumbReport
  { trMade :: Int
  , trSkipped :: Int
  , trFailed :: [(Text, Text)]
  }
  deriving stock (Eq, Show)

-- | 為每一份**唯一內容**產生縮圖,不是為每一筆資源。
--
-- 6,393 筆資源只指向 6,234 份唯一內容;而且同一份內容跨素材包重複出現時
-- (廠商附的同一份免費字型)只需要一張縮圖。
generateThumbs :: Store -> ArchiveTools -> ThumbOptions -> IO ThumbReport
generateThumbs st tools ThumbOptions {..} = do
  todo <-
    query_
      (storeConn st)
      ( Query
          ( "SELECT b.sha256, ar.rel_path, a.entry_path \
            \FROM blobs b \
            \JOIN assets a ON a.sha256 = b.sha256 \
            \JOIN archives ar ON ar.id = a.archive_id \
            \WHERE b.kind = 'image' "
              <> (if toForce then "" else "AND b.thumb_status = 'pending' ")
              <> "GROUP BY b.sha256"
          )
      ) ::
      IO [(Text, Text, Text)]

  let total = length todo
  foldM (step total) (ThumbReport 0 0 []) (zip [1 ..] todo)
  where
    step total acc (i, (sha, archiveRel, entry)) = do
      toOnProgress i total sha
      existing <- mapM (doesFileExist . thumbPath toCacheRoot sha) thumbSizes
      if and existing && not toForce
        then do
          markOk sha
          pure acc {trSkipped = trSkipped acc + 1}
        else do
          r <- try (readEntry tools (toLibraryRoot <> "/" <> T.unpack archiveRel) entry)
          case r of
            Left (e :: SomeException) -> failWith acc sha (compact e)
            Right (Left err) -> failWith acc sha (renderArchiveError err)
            Right (Right content) ->
              case mapM (`makeThumb` content) thumbSizes of
                Left err -> failWith acc sha err
                Right imgs -> do
                  forM_ (zip thumbSizes imgs) $ \(size, png) -> do
                    let p = thumbPath toCacheRoot sha size
                    createDirectoryIfMissing True (takeDirectory p)
                    BS.writeFile p png
                  markOk sha
                  pure acc {trMade = trMade acc + 1}

    failWith acc sha msg = do
      -- 失敗要記在資料庫裡,否則每次重跑都會再試一次同一批壞檔案。
      execute
        (storeConn st)
        "UPDATE blobs SET thumb_status = 'failed', thumb_error = ? WHERE sha256 = ?"
        (msg, sha)
      pure acc {trFailed = trFailed acc <> [(sha, msg)]}

    markOk sha =
      execute
        (storeConn st)
        "UPDATE blobs SET thumb_status = 'ok', thumb_error = NULL WHERE sha256 = ?"
        (Only sha)

    compact :: SomeException -> Text
    compact = T.unwords . T.words . T.pack . show
