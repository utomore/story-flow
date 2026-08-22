-- | 叢集層分類 —— 純文字,不看圖。
--
-- 6,393 筆資源塌縮成 132 個叢集,所以這一輪的成本是 132 次呼叫(約七分鐘),
-- 而不是 6,238 次(約十小時)。先跑這個,人只要看 132 列就能判斷詞彙表與
-- 提示詞好不好用。
--
-- == 為什麼叢集清單是**輸入**而不是自己查
--
-- 叢集是 @AssetDB.Ingest.Cluster@ 即時算出來的,不是資料表裡的列
-- (@name_clusters@ 只存已確認的**命名規則**,整個資料庫目前 6 列)。
-- 若在這裡自己算,assetdb-ai 就得相依 assetdb-ingest,而伺服器相依
-- assetdb-ai —— JuicyPixels、zip、assetdb-archive 會一路被拖進伺服器。
-- 讓呼叫端(CLI,它本來就相依 ingest)把清單遞進來,這個接縫就消失了。
module AssetDB.AI.Classify
  ( ClusterTarget (..)
  , ClassifyOptions (..)
  , defaultClassifyOptions
  , ClassifyReport (..)
  , classifyClusters
  ) where

import AssetDB.AI.Llm
import AssetDB.AI.Prompt
import AssetDB.AI.Run
import AssetDB.AI.Suggest
import AssetDB.AI.Vocab
import AssetDB.Store.Errors (renderUnexpected)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.SQLite.Simple

data ClusterTarget = ClusterTarget
  { ctPackSlug :: Text
  , ctPackName :: Text
  , ctShape :: Text
  , ctCount :: Int
  , ctSamples :: [Text]
  }
  deriving stock (Eq, Show)

-- | @ai_suggestions.target_key@ 的編碼。與 'AssetDB.AI.Suggest.resolveTargets'
-- 的 cluster 分支必須用同一套。
targetKey :: ClusterTarget -> Text
targetKey ct = ctPackSlug ct <> "|" <> ctShape ct

data ClassifyOptions = ClassifyOptions
  { coForce :: Bool
  -- ^ 重跑已經有建議的叢集。
  , coMinMembers :: Int
  , coLimit :: Maybe Int
  , coOnProgress :: Progress -> IO ()
  }

defaultClassifyOptions :: ClassifyOptions
defaultClassifyOptions =
  ClassifyOptions {coForce = False, coMinMembers = 1, coLimit = Nothing, coOnProgress = \_ -> pure ()}

data ClassifyReport = ClassifyReport
  { crDone :: Int
  , crSkipped :: Int
  , crSuggested :: Int
  , crFailed :: [(Text, Text)]
  , crAborted :: Maybe Text
  }
  deriving stock (Eq, Show)

classifyClusters :: Connection -> Llm -> ClassifyOptions -> [ClusterTarget] -> IO ClassifyReport
classifyClusters conn llm ClassifyOptions {..} targets0 = do
  -- 與 'AssetDB.AI.Vision.visionTagBlobs' 同一個理由:前置的讀詞彙表、
  -- 篩佇列、開 run 列都碰資料庫,炸掉會讓 @ai_runs@ 留下停在 @'running'@
  -- 的孤兒列(G-E003)。
  prep <- guardedTry $ do
    vocab <- loadVocab conn visionScopes
    -- 成員多的先做。五分鐘後喊停時,已經涵蓋的是佔最多素材的那些叢集。
    let bySize = sortDesc [t | t <- targets0, ctCount t >= coMinMembers]
    todo <-
      if coForce
        then pure (limit bySize)
        else limit <$> filterM' (fmap not . hasSuggestionsFor conn "cluster" . targetKey) bySize
    runId <-
      beginRun
        conn
        "cluster"
        (llmConfig llm)
        promptVersion
        (TE.decodeUtf8 (BL.toStrict (encode (map ctPackSlug todo))))
        (length todo)
    pure (vocab, todo, runId)
  case prep of
    Left e -> pure (abortedReport (renderUnexpected e))
    Right (vocab, todo, runId) -> do
      r <- guardedTry (driveItems conn runId coOnProgress label (step vocab runId) todo)
      case r of
        Left e -> do
          let why = renderUnexpected e
          _ <- guardedTry (abortRun conn runId why 0 0)
          pure (abortedReport why)
        Right (ok, skipped, failed, aborted) -> do
          let n = ok
          case aborted of
            Just why -> abortRun conn runId why n (length failed)
            Nothing -> finishRun conn runId n (length failed)
          pure
            ClassifyReport
              { crDone = ok
              , crSkipped = skipped
              , crSuggested = ok
              , crFailed = failed
              , crAborted = aborted
              }
  where
    abortedReport why = ClassifyReport 0 0 0 [] (Just why)

    limit = maybe id take coLimit
    label ct = ctPackSlug ct <> " │ " <> ctShape ct
    sortDesc = foldr ins []
      where
        ins x [] = [x]
        ins x (y : ys) | ctCount x >= ctCount y = x : y : ys | otherwise = y : ins x ys
    filterM' p = go
      where
        go [] = pure []
        go (x : xs) = do
          keep <- p x
          rest <- go xs
          pure (if keep then x : rest else rest)

    step vocab runId ct = do
      let info =
            ClusterInfo
              { ciPackName = ctPackName ct
              , ciPackSlug = ctPackSlug ct
              , ciShape = ctShape ct
              , ciCount = ctCount ct
              , ciSamples = ctSamples ct
              }
          req =
            (defaultChatRequest [systemMsg (clusterSystem vocab), userText (clusterUser info)])
              { crResponseFormat = Just (clusterSchema vocab)
              }
      r <- chatJson llm req
      case r of
        Left e -> retryOrFail vocab runId ct req e
        Right v -> commit vocab runId ct v

    -- 推理吃光預算是**改變請求**才有機會解決的,所以重試發生在這一層,
    -- 而不是傳輸層 —— 傳輸層重送一模一樣的請求只會得到一模一樣的結果。
    retryOrFail vocab runId ct req e = case e of
      LlmTruncated _ -> again
      LlmEmptyContent _ -> again
      _ -> pure (outcomeOf e)
      where
        again = do
          let bigger = req {crMaxTokens = Just (2 * lcMaxTokens (llmConfig llm))}
          r2 <- chatJson llm bigger
          case r2 of
            Left e2 -> pure (outcomeOf e2)
            Right v -> commit vocab runId ct v

    commit vocab runId ct v = do
      let key = targetKey ct
          conf = clamp01 (cvConfidence v)
          cat = cvCategory v
          subOk = isChildOf vocab cat (cvSubcategory v)
          -- 子分類對不上父分類時,保留粗的、丟掉細的。一個錯誤的葉節點
          -- 不該賠掉一個正確的頂層。
          why =
            if subOk || cvSubcategory v == "unknown"
              then Just (cvAnalysis v)
              else Just (cvAnalysis v <> "(子分類 " <> cvSubcategory v <> " 不屬於 " <> cat <> ",已捨棄)")
          cats =
            [categorySuggestion "cluster" key cat (Just conf) why | cat /= "unknown"]
              <> [ categorySuggestion "cluster" key (cvSubcategory v) (Just conf) why
                 | subOk
                 ]
          tags =
            concat
              [ tagsFor key "style" "en" (cvStyleEn v) conf
              , tagsFor key "style" "zh" (cvStyleZh v) conf
              , tagsFor key "theme" "en" (cvThemeEn v) conf
              , tagsFor key "theme" "zh" (cvThemeZh v) conf
              ]
      n <- upsertSuggestions conn (Just (unRunId runId)) (cats <> tags)
      pure (StepOk n)

    tagsFor key facet lang vs conf =
      [ tagSuggestion "cluster" key facet lang t (Just conf)
      | t <- take 4 (filter (not . T.null) (map T.strip vs))
      ]

    unRunId (RunId i) = i

-- | GBNF 對 JSON Schema 的 @minimum@ \/ @maximum@ 約束並不可靠,所以在
-- Haskell 這一側夾範圍。不要把信心門檻建立在一個沒被驗證過的數字上。
clamp01 :: Double -> Double
clamp01 d
  | isNaN d = 0
  | d < 0 = 0
  | d > 1 = 1
  | otherwise = d
