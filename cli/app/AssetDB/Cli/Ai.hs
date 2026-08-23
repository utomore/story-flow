-- | @assetdb ai …@ —— 離線 LLM 分類與標註的命令列入口。
--
-- == 閘門只有一道,而且在 apply
--
-- @classify@ 與 @vision@ 不需要 @--confirm@:寫進 @ai_suggestions@ **本身
-- 就是預覽**,那正是暫存表存在的理由。在一個十小時的批次上再加一道閘門,
-- 等於要嘛跑兩次、要嘛把結果丟掉。閘門放在唯一會碰到 @tags@ /
-- @asset_tags@ / @asset_categories@ 的那一步。
module AssetDB.Cli.Ai
  ( AiConn (..)
  , AiClassifyArgs (..)
  , AiVisionArgs (..)
  , AiListArgs (..)
  , AiImportArgs (..)
  , AiDecideArgs (..)
  , AiApplyArgs (..)
  , AiQueryArgs (..)
  , llmConfigOf
  , runAiPing
  , runAiClassify
  , runAiVision
  , runAiSuggestList
  , runAiSuggestImport
  , runAiDecide
  , runAiApply
  , runAiQuery
  , runAiStatus
  ) where

import AssetDB.AI.Classify
import AssetDB.AI.Import
import AssetDB.AI.Llm
import AssetDB.AI.Query
import AssetDB.AI.Run (Progress (..), renderProgress)
import AssetDB.AI.Suggest
import AssetDB.AI.Vision
import AssetDB.Guard (guardedTry)
import AssetDB.Ingest.Cluster (Cluster (..), clusterKeyOf, clusterKeyText)
import AssetDB.Ingest.ClusterDb (PackRef (..), listPacks, packClusters)
import AssetDB.Store
import AssetDB.Store.Errors (renderUnexpected)
import AssetDB.Store.Index (reindexFts)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))

--------------------------------------------------------------------------------
-- 參數

data AiConn = AiConn
  { acUrl :: Maybe Text
  , acModel :: Maybe Text
  , acThinking :: Bool
  }

llmConfigOf :: AiConn -> LlmConfig
llmConfigOf AiConn {..} =
  defaultLlmConfig
    { lcBaseUrl = maybe (lcBaseUrl defaultLlmConfig) id acUrl
    , lcModel = maybe (lcModel defaultLlmConfig) id acModel
    , lcThinking = acThinking
    }

data AiClassifyArgs = AiClassifyArgs
  { caPack :: Maybe Text
  , caMinMembers :: Int
  , caLimit :: Maybe Int
  , caForce :: Bool
  }

data AiVisionArgs = AiVisionArgs
  { vaPack :: Maybe Text
  , vaLimit :: Maybe Int
  , vaForce :: Bool
  , vaRetryFailed :: Bool
  , vaSmall :: Bool
  }

data AiListArgs = AiListArgs
  { laStatus :: Maybe Text
  , laTarget :: Maybe Text
  , laField :: Maybe Text
  , laMinConfidence :: Maybe Double
  , laLimit :: Int
  }

data AiDecideArgs = AiDecideArgs
  { daIds :: [Int]
  , daAllPending :: Bool
  , daMinConfidence :: Maybe Double
  , daDecision :: Text
  , daConfirm :: Bool
  }

data AiApplyArgs = AiApplyArgs
  { aaConfirm :: Bool
  }

data AiQueryArgs = AiQueryArgs
  { qaText :: Text
  }

data AiImportArgs = AiImportArgs
  { iaFile :: FilePath
  , iaDryRun :: Bool
  }

--------------------------------------------------------------------------------

tshow :: Show a => a -> Text
tshow = T.pack . show

withAi :: FilePath -> (Connection -> IO a) -> IO a
withAi dbPath f = withStore dbPath $ \st -> do
  _ <- initSchema st
  f (storeConn st)

--------------------------------------------------------------------------------
-- ping

runAiPing :: FilePath -> AiConn -> IO ()
runAiPing _ conn = do
  let cfg = llmConfigOf conn
  llm <- newLlm cfg
  r <- ping llm
  case r of
    Left e -> do
      TIO.putStrLn ("✗ " <> lcBaseUrl cfg <> " —— " <> renderLlmError e)
      TIO.putStrLn "  推論服務沒開的話,先啟動 llama.cpp。"
      exitFailure
    Right m -> do
      TIO.putStrLn ("✓ " <> lcBaseUrl cfg)
      TIO.putStrLn ("  模型 " <> m)

--------------------------------------------------------------------------------
-- classify

runAiClassify :: FilePath -> AiConn -> AiClassifyArgs -> IO ()
runAiClassify dbPath conn AiClassifyArgs {..} =
  withStore dbPath $ \st -> do
    _ <- initSchema st
    -- 叢集是即時算出來的,不是資料表裡的列 —— 所以在這裡算好再遞進去。
    -- assetdb-ai 因此不必相依 assetdb-ingest(見 AssetDB.AI.Classify 的說明)。
    packs <- listPacks st caPack
    targets <- concat <$> forM packs (clusterTargets st)
    TIO.putStrLn ("共 " <> tshow (length targets) <> " 個叢集待處理")
    llm <- newLlm (llmConfigOf conn)
    r <-
      classifyClusters
        (storeConn st)
        llm
        defaultClassifyOptions
          { coForce = caForce
          , coMinMembers = caMinMembers
          , coLimit = caLimit
          , coOnProgress = \p -> when (pgIndex p `mod` 5 == 0 || pgIndex p == pgTotal p) (TIO.putStrLn (renderProgress p))
          }
        targets
    TIO.putStrLn ""
    TIO.putStrLn ("完成 " <> tshow (crDone r) <> ",略過 " <> tshow (crSkipped r))
    reportFailures (crFailed r)
    reportAbort (crAborted r)
    TIO.putStrLn "建議已存入待確認。用 assetdb ai suggest list 檢視。"

clusterTargets :: Store -> PackRef -> IO [ClusterTarget]
clusterTargets st pk = do
  cs <- packClusters st (pkId pk)
  pure
    [ ClusterTarget
        { ctPackSlug = pkSlug pk
        , ctPackName = pkName pk
        , ctShape = clusterKeyText (clKey c)
        , ctCount = clCount c
        , ctSamples = clSamples c
        }
    | c <- cs
    ]

--------------------------------------------------------------------------------
-- vision

runAiVision :: FilePath -> AiConn -> AiVisionArgs -> IO ()
runAiVision dbPath conn AiVisionArgs {..} = do
  -- 縮圖快取與資料庫同層,與 assetdb thumbs 的推導方式一致。
  let cache = takeDirectory dbPath </> "cache" </> "thumbs"
  withAi dbPath $ \c -> do
    llm <- newLlm (llmConfigOf conn)
    let opts =
          (defaultVisionOptions cache)
            { voPackSlug = vaPack
            , voLimit = vaLimit
            , voForce = vaForce
            , voRetryFailed = vaRetryFailed
            , voLarge = not vaSmall
            , voOnProgress = \p ->
                when (pgIndex p `mod` 20 == 0 || pgIndex p == pgTotal p) (TIO.putStrLn (renderProgress p))
            }
    todo <- selectJobs c opts
    TIO.putStrLn ("共 " <> tshow (length todo) <> " 份唯一內容待標註")
    when (null todo) $ TIO.putStrLn "  沒有待辦。縮圖還沒產生的話,先跑 assetdb thumbs。"
    r <- visionTagBlobs c llm opts
    TIO.putStrLn ""
    TIO.putStrLn ("標註 " <> tshow (vrTagged r) <> ",略過 " <> tshow (vrSkipped r) <> "(缺縮圖)")
    reportFailures (vrFailed r)
    reportAbort (vrAborted r)

--------------------------------------------------------------------------------
-- suggest list / decide

runAiSuggestList :: FilePath -> AiListArgs -> IO ()
runAiSuggestList dbPath AiListArgs {..} = withAi dbPath $ \c -> do
  rows <-
    listSuggestions
      c
      emptyFilter
        { sfStatus = laStatus
        , sfTargetType = laTarget
        , sfField = laField
        , sfMinConfidence = laMinConfidence
        , sfLimit = laLimit
        }
  forM_ rows $ \s ->
    TIO.putStrLn
      ( pad 7 (tshow (ssId s))
          <> pad 9 (ssStatus s)
          <> pad 9 (ssField s)
          <> pad 5 (ssLang s)
          <> pad 6 (maybe "—" id (ssFacet s))
          <> pad 10 (maybe "" conf (ssConfidence s))
          <> ssValue s
          <> "   ← "
          <> T.take 40 (ssTargetKey s)
      )
  TIO.putStrLn ""
  TIO.putStrLn ("顯示 " <> tshow (length rows) <> " 筆")
  counts <- countSuggestions c
  forM_ counts $ \(st, n) -> TIO.putStrLn ("  " <> pad 12 st <> tshow n)
  where
    conf d = T.pack (show (fromIntegral (round (d * 100) :: Int) / 100 :: Double))

-- | 外部建議匯入(F007)。跟 @classify@ 一樣不需要 @--confirm@:寫進暫存表本身就是預覽。
--
-- 檔案在這裡讀成位元組,解碼與驗證交給 ai-tagging —— 輸入格式是它的契約,不是 CLI 的。
runAiSuggestImport :: FilePath -> AiImportArgs -> IO ()
runAiSuggestImport dbPath AiImportArgs {..} = do
  -- 讀不到檔案是使用者打錯路徑,不該變成頂層的 IOException(G-E003)。
  bytes <-
    guardedTry (BS.readFile iaFile) >>= \case
      Left e -> TIO.putStrLn ("✗ 讀不到匯入檔 —— " <> renderUnexpected e) >> exitFailure
      Right b -> pure b
  withAi dbPath $ \c -> do
    r <- importSuggestions c defaultImportOptions {ioDryRun = iaDryRun} bytes
    case irProblems r of
      [] ->
        if iaDryRun
          then TIO.putStrLn ("驗證通過,將寫入 " <> tshow (irLines r) <> " 筆(--dry-run,未寫入)")
          else do
            TIO.putStrLn ("已寫入 " <> tshow (irWritten r) <> " 筆(pending),下一步:assetdb ai suggest list")
            counts <- countSuggestions c
            forM_ counts $ \(st, n) -> TIO.putStrLn ("  " <> pad 12 st <> tshow n)
      problems -> do
        forM_ problems $ \(n, why) ->
          TIO.putStrLn (if n == 0 then "檔案:" <> why else "第 " <> tshow n <> " 行:" <> why)
        TIO.putStrLn ("✗ 共 " <> tshow (length problems) <> " 個問題,一筆都沒寫入(全有全無)")
        exitFailure

runAiDecide :: FilePath -> AiDecideArgs -> IO ()
runAiDecide dbPath AiDecideArgs {..} = withAi dbPath $ \c -> do
  ids <-
    if daAllPending
      then do
        rows <-
          listSuggestions
            c
            emptyFilter {sfStatus = Just "pending", sfMinConfidence = daMinConfidence, sfLimit = 100000}
        pure (map ssId rows)
      else pure daIds
  if null ids
    then TIO.putStrLn "沒有符合條件的建議。"
    else
      if not daConfirm
        then do
          TIO.putStrLn (tshow (length ids) <> " 筆建議會被標為 " <> daDecision <> "。")
          TIO.putStrLn "這是預覽。加上 --confirm 才會寫入。"
        else do
          n <- decideSuggestions c ids daDecision "cli"
          TIO.putStrLn ("已標記 " <> tshow n <> " 筆為 " <> daDecision <> "。")

--------------------------------------------------------------------------------
-- apply

runAiApply :: FilePath -> AiApplyArgs -> IO ()
runAiApply dbPath AiApplyArgs {..} = withStore dbPath $ \st -> do
  _ <- initSchema st
  let c = storeConn st
  r <-
    applySuggestions
      c
      ApplyOptions
        { aoDryRun = not aaConfirm
        , aoResolveCluster = resolveCluster st
        }
  TIO.putStrLn ("標籤 " <> tshow (arTags r) <> " 筆,分類 " <> tshow (arCategories r) <> " 筆")
  when (arUnresolved r > 0) $
    TIO.putStrLn ("  ⚠ 有 " <> tshow (arUnresolved r) <> " 筆建議的目標找不到對應素材,已略過")
  if not aaConfirm
    then TIO.putStrLn "這是預覽。加上 --confirm 才會寫入。"
    else do
      -- 少了這一步,上面全部照樣「成功」,而中文搜尋照樣零筆。
      -- runClusterApply 也是這樣收尾的。
      n <- reindexFts c
      TIO.putStrLn ("已寫入,並重建全文索引(" <> tshow n <> " 筆)。")

-- | @"<pack_slug>|<shape>"@ → 這一群的 asset id。
--
-- 分群與反查必須是**同一段程式碼**('clusterKeyOf'),否則規則會套到
-- 錯的檔案上 —— 這是 @AssetDB.Ingest.Cluster@ 已經寫在註解裡的教訓。
-- 形狀比對因此留在 Haskell,不下放 SQL;重複掃描的問題由
-- 'applySuggestions' 的目標快取解決(ai-tagging/E001)。
--
-- 只看 @entry_path@:分群本身('packClusters')就只吃 entry_path,
-- 散檔在同一包裡也不會是任何叢集的成員。
resolveCluster :: Store -> Text -> IO [Int]
resolveCluster st key = do
  let (slug, rest) = T.breakOn "|" key
      shape = T.drop 1 rest
  rows <-
    query
      (storeConn st)
      "SELECT a.id, a.entry_path \
      \FROM assets a JOIN packs p ON p.id = a.pack_id \
      \WHERE p.slug = ? AND a.status = 'active' AND a.entry_path IS NOT NULL"
      (Only slug) ::
      IO [(Int, Text)]
  pure [i | (i, p) <- rows, clusterKeyText (clusterKeyOf p) == shape]

--------------------------------------------------------------------------------
-- query

runAiQuery :: FilePath -> AiConn -> AiQueryArgs -> IO ()
runAiQuery dbPath conn AiQueryArgs {..} = withAi dbPath $ \c -> do
  llm <- newLlm (llmConfigOf conn)
  r <- planQuery c llm qaText
  case r of
    Left e -> do
      -- 降級,不是失敗。既有的全文搜尋本來就處理得了中文(assets_cjk),
      -- 把它呈現成錯誤是不對的。
      TIO.putStrLn ("⚠ " <> renderLlmError e)
      TIO.putStrLn ("  降級為字面搜尋:" <> qaText)
    Right p -> do
      TIO.putStrLn ("關鍵字:" <> T.intercalate " " (qpKeywords p))
      forM_ (qpCategory p) $ \cat -> TIO.putStrLn ("分類:" <> cat)
      unless (T.null (qpExplain p)) $ TIO.putStrLn ("理由:" <> qpExplain p)

--------------------------------------------------------------------------------
-- status

runAiStatus :: FilePath -> IO ()
runAiStatus dbPath = withAi dbPath $ \c -> do
  TIO.putStrLn "── 建議 ──"
  counts <- countSuggestions c
  if null counts
    then TIO.putStrLn "  還沒有任何建議。先跑 assetdb ai classify。"
    else forM_ counts $ \(st, n) -> TIO.putStrLn ("  " <> pad 12 st <> tshow n)

  TIO.putStrLn ""
  TIO.putStrLn "── 視覺標註進度 ──"
  bs <- query_ c "SELECT ai_status, COUNT(*) FROM blobs WHERE kind='image' GROUP BY ai_status" :: IO [(Text, Int)]
  forM_ bs $ \(s, n) -> TIO.putStrLn ("  " <> pad 12 s <> tshow n)
  noThumb <-
    query_ c "SELECT COUNT(*) FROM blobs WHERE kind='image' AND thumb_status <> 'ok'" :: IO [Only Int]
  case noThumb of
    (Only n : _)
      | n > 0 ->
          -- 講出來。不然這批會變成一個沒有解釋的缺口。
          TIO.putStrLn ("  ⚠ 有 " <> tshow n <> " 份內容還沒有縮圖,無法標註 —— 先跑 assetdb thumbs")
    _ -> pure ()

  TIO.putStrLn ""
  TIO.putStrLn "── 批次紀錄 ──"
  rs <-
    query_
      c
      "SELECT kind, status, total, done, failed, started_at FROM ai_runs ORDER BY id DESC LIMIT 8" ::
      IO [(Text, Text, Int, Int, Int, Text)]
  if null rs
    then TIO.putStrLn "  無"
    else forM_ rs $ \(k, s, t, d, fl, ts) ->
      TIO.putStrLn
        ("  " <> pad 9 k <> pad 9 s <> pad 16 (tshow d <> "/" <> tshow t) <> pad 8 ("失敗 " <> tshow fl) <> T.take 19 ts)

--------------------------------------------------------------------------------

reportFailures :: [(Text, Text)] -> IO ()
reportFailures [] = pure ()
reportFailures fs = do
  TIO.putStrLn ("失敗 " <> tshow (length fs) <> " 筆:")
  forM_ (take 10 fs) $ \(k, m) -> TIO.putStrLn ("  " <> T.take 40 k <> "  " <> T.take 90 m)
  when (length fs > 10) $ TIO.putStrLn ("  …還有 " <> tshow (length fs - 10) <> " 筆")

-- | 中止與失敗不一樣:中止時佇列還在,重跑就是續跑。這件事要講清楚,
-- 否則使用者會以為九小時的成果沒了。
reportAbort :: Maybe Text -> IO ()
reportAbort Nothing = pure ()
reportAbort (Just why) = do
  TIO.putStrLn ""
  TIO.putStrLn ("✗ 批次中止:" <> why)
  TIO.putStrLn "  未處理的項目仍是 pending,修好之後重跑同一個指令即可續跑。"
  exitFailure

-- | 中日韓字元佔兩欄。與 Notes.hs / Cluster.hs 的 pad 同一套規則。
pad :: Int -> Text -> Text
pad n t = t <> T.replicate (max 1 (n - width t)) " "
  where
    width = sum . map (\ch -> if ch > '\x2000' then 2 else 1) . T.unpack
