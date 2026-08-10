module AssetDB.Cli.Cluster (runClusterList) where

import AssetDB.Ingest.Cluster
import AssetDB.Store
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple

-- | 列出每個素材包的命名叢集。
--
-- 這是階段 4 的入口:人看著這份清單決定每個叢集的規則,
-- 而不是看著 6,393 個檔名。
runClusterList :: FilePath -> Maybe Text -> IO ()
runClusterList dbPath mSlug =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    packs <-
      query
        (storeConn st)
        "SELECT id, slug, name FROM packs WHERE (? IS NULL OR slug = ?) ORDER BY slug"
        (mSlug, mSlug) ::
        IO [(Int, Text, Text)]

    totals <-
      mapM
        ( \(pid, slug, name) -> do
            paths <-
              query
                (storeConn st)
                "SELECT entry_path FROM assets WHERE pack_id = ? AND entry_path IS NOT NULL ORDER BY entry_path"
                (Only pid)
            let cs = clusterBy (map fromOnly paths)
            report slug name cs
            pure (length paths, length cs)
        )
        packs

    TIO.putStrLn ""
    TIO.putStrLn
      ( "合計 " <> tshow (sum (map fst totals)) <> " 筆資源塌縮成 "
          <> tshow (sum (map snd totals))
          <> " 個叢集"
      )

report :: Text -> Text -> [Cluster] -> IO ()
report slug name cs = do
  TIO.putStrLn ""
  TIO.putStrLn ("── " <> name <> "  (" <> slug <> ")  " <> tshow (length cs) <> " 個叢集")
  mapM_ one cs
  where
    one c = do
      TIO.putStrLn
        ( "  " <> pad 7 (tshow (clCount c))
            <> pad 34 (clusterKeyText (clKey c))
        )
      mapM_ (\s -> TIO.putStrLn ("            " <> s)) (take 3 (clSamples c))

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - T.length t)) " "

tshow :: Show a => a -> Text
tshow = T.pack . show
