module AssetDB.Cli.Cluster
  ( runClusterList
  , runClusterRule
  , runClusterApply
  , RuleArgs (..)
  ) where

import AssetDB.Ingest.Cluster
import AssetDB.Ingest.ClusterDb
import AssetDB.Naming (defaultVocab)
import AssetDB.Store
import AssetDB.Store.Index (reindexFts)
import AssetDB.Types (KindPrefix, parseTextEnum)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Exit (exitFailure)

-- | 列出每個素材包的命名叢集。
--
-- 這是階段 4 的入口:人看著這份清單決定每個叢集的規則,
-- 而不是看著 6,393 個檔名。
runClusterList :: FilePath -> Maybe Text -> IO ()
runClusterList dbPath mSlug =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    packs <- listPacks st mSlug
    totals <- mapM (one st) packs
    TIO.putStrLn ""
    TIO.putStrLn
      ( "合計 " <> tshow (sum (map fst totals)) <> " 筆資源塌縮成 "
          <> tshow (sum (map snd totals))
          <> " 個叢集"
      )
  where
    one st pk = do
      cs <- packClusters st (pkId pk)
      rules <- loadRules st (pkId pk)
      TIO.putStrLn ""
      TIO.putStrLn ("── " <> pkName pk <> "  (" <> pkSlug pk <> ")  " <> tshow (length cs) <> " 個叢集")
      mapM_ (renderCluster rules) cs
      n <- length <$> packPaths st (pkId pk)
      pure (n, length cs)

    -- ✓ 表示這個叢集已經有確認過的規則。人需要一眼看出還剩幾群要處理。
    renderCluster rules c = do
      let key = clusterKeyText (clKey c)
          mark = if Map.member key rules then "✓ " else "  "
      TIO.putStrLn ("  " <> mark <> pad 7 (tshow (clCount c)) <> key)
      mapM_ (\s -> TIO.putStrLn ("            " <> s)) (take 3 (clSamples c))

--------------------------------------------------------------------------------

data RuleArgs = RuleArgs
  { raPack :: Text
  , raShape :: Text
  , raKind :: Text
  , raDomain :: Text
  , raSubject :: Maybe Text
  , raDrop :: [Int]
  , raDirs :: Int
  , raNumeric :: Text
  , raTags :: [Text]
  , raConfirm :: Bool
  -- ^ 'False' 只預覽,不寫入。
  }

-- | 預覽或確認一個叢集的命名規則。
--
-- 預設**只預覽**。確認之前一定要看得到結果:規則的參數抽象到人腦裡難以驗證,
-- 但「這幾個檔案會變成這幾個名字」一眼就能判斷對錯。
runClusterRule :: FilePath -> RuleArgs -> IO ()
runClusterRule dbPath RuleArgs {..} =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    packs <- listPacks st (Just raPack)
    case packs of
      [] -> die ("找不到素材包 " <> raPack)
      (pk : _) -> do
        cs <- packClusters st (pkId pk)
        case find ((== raShape) . clusterKeyText . clKey) cs of
          Nothing -> do
            TIO.putStrLn ("找不到叢集 " <> raShape <> "。這一包有:")
            mapM_ (\c -> TIO.putStrLn ("  " <> clusterKeyText (clKey c))) cs
            exitFailure
          Just cl -> do
            kind <- either die pure (parseKind raKind)
            numeric <- either die pure (parseNumeric raNumeric)
            let rule =
                  NameRule
                    { nrKind = kind
                    , nrDomain = raDomain
                    , nrSubject = raSubject
                    , nrDropTokens = raDrop
                    , nrIncludeDirs = raDirs
                    , nrNumeric = numeric
                    , nrTags = raTags
                    }

            paths <- packPaths st (pkId pk)
            let members = filter ((== raShape) . clusterKeyText . clusterKeyOf) paths
                previews = previewCluster defaultVocab rule (sampleOf members)

            TIO.putStrLn (raShape <> "  " <> tshow (length members) <> " 筆")
            TIO.putStrLn ""
            mapM_ renderPreview previews

            let bad = length [() | NamePreview _ (Left _) <- previews]
            TIO.putStrLn ""
            if bad > 0
              then do
                TIO.putStrLn "⚠ 樣本裡有失敗的項目,**未寫入規則**。調整參數後再試。"
                exitFailure
              else
                if raConfirm
                  then do
                    saveRule st (pkId pk) cl rule
                    TIO.putStrLn ("✓ 規則已存入。用 assetdb cluster apply --pack " <> raPack <> " 套用。")
                  else TIO.putStrLn "這是預覽。加上 --confirm 才會存入規則。"
  where
    renderPreview (NamePreview p r) = do
      TIO.putStrLn ("  " <> p)
      case r of
        Right n -> TIO.putStrLn ("    → " <> n)
        Left e -> TIO.putStrLn ("    ✗ " <> e)

    -- 頭中尾各取,不是前 N 筆 —— 前 N 筆常常長得一模一樣。
    sampleOf xs =
      let n = length xs
       in if n <= 6 then xs else [xs !! 0, xs !! 1, xs !! (n `div` 3), xs !! (n `div` 2), xs !! (n - 2), xs !! (n - 1)]

--------------------------------------------------------------------------------

runClusterApply :: FilePath -> Maybe Text -> IO ()
runClusterApply dbPath mSlug =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    packs <- listPacks st mSlug
    results <- mapM (\pk -> (,) pk <$> applyNames st defaultVocab (pkId pk)) packs

    mapM_ report results

    -- 命名改變了 logical_name,而那是全文索引的主要欄位。
    _ <- reindexFts (storeConn st)

    let named = sum [anNamed r | (_, r) <- results]
        skipped = sum [anSkipped r | (_, r) <- results]
        problems = sum [length (anFailed r) + length (anCollisions r) | (_, r) <- results]
    TIO.putStrLn ""
    TIO.putStrLn ("命名 " <> tshow named <> " 筆,跳過 " <> tshow skipped <> " 筆(叢集未確認)")
    if problems > 0 then exitFailure else pure ()
  where
    report (pk, r)
      | anNamed r == 0 && null (anFailed r) && null (anCollisions r) = pure ()
      | otherwise = do
          TIO.putStrLn ""
          TIO.putStrLn ("── " <> pkName pk)
          TIO.putStrLn ("  命名 " <> tshow (anNamed r) <> ",跳過 " <> tshow (anSkipped r))
          mapM_ (\(p, e) -> TIO.putStrLn ("  ✗ " <> p <> "\n      " <> e)) (take 10 (anFailed r))
          mapM_
            ( \(n, ps) -> do
                TIO.putStrLn ("  ✗ 撞名 " <> n)
                mapM_ (\p -> TIO.putStrLn ("      " <> p)) (take 3 ps)
            )
            (take 10 (anCollisions r))

--------------------------------------------------------------------------------

parseKind :: Text -> Either Text KindPrefix
parseKind = parseTextEnum

parseNumeric :: Text -> Either Text NumericRole
parseNumeric = \case
  "auto" -> Right NumAuto
  "variant" -> Right NumVariant
  "index" -> Right NumIndex
  other -> Left ("--numeric 只接受 auto / variant / index,收到 " <> other)

die :: Text -> IO a
die m = TIO.putStrLn ("✗ " <> m) >> exitFailure

pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - T.length t)) " "

tshow :: Show a => a -> Text
tshow = T.pack . show
