-- | 逐 blob 的視覺標註 —— 送縮圖給模型,取回內容標籤。
--
-- 這是讓中文搜尋真的能用的那一步:素材庫裡 27 個商業素材包的檔名、包名、
-- 作者全是英文,語料裡一個中文字都沒有。CJK 索引本身是好的(搜「金門」
-- 搜得到中文命名的參考包),缺的只是中文文本。這裡把它補上。
--
-- == 工作單位是 blob,不是 asset
--
-- 內容定址。6,397 筆資源指向 6,238 份唯一內容,同一份免費字型被三個廠商
-- 各附一次也只算一次 —— 與 @ThumbRun.hs@ 同一個道理。
--
-- == 不變量:絕不跨 LLM 呼叫持有 transaction
--
-- 每筆呼叫約 5.8 秒,而 @busy_timeout@ 是 5 秒(@Store.hs@)。握著寫鎖跨過
-- 一次推論,同時在跑的伺服器就會寫入失敗。LLM 呼叫一律在 transaction 之外。
module AssetDB.AI.Vision
  ( VisionOptions (..)
  , defaultVisionOptions
  , VisionReport (..)
  , VisionJob (..)
  , selectJobs
  , visionTagBlobs
  ) where

import AssetDB.AI.Image
import AssetDB.AI.Llm
import AssetDB.AI.Prompt
import AssetDB.AI.Run
import AssetDB.AI.Suggest
import AssetDB.AI.Vocab
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple

data VisionOptions = VisionOptions
  { voCacheRoot :: FilePath
  , voPackSlug :: Maybe Text
  , voLarge :: Bool
  , voForce :: Bool
  , voRetryFailed :: Bool
  , voLimit :: Maybe Int
  , voOnProgress :: Progress -> IO ()
  }

defaultVisionOptions :: FilePath -> VisionOptions
defaultVisionOptions cache =
  VisionOptions
    { voCacheRoot = cache
    , voPackSlug = Nothing
    , voLarge = True
    , voForce = False
    , voRetryFailed = False
    , voLimit = Nothing
    , voOnProgress = \_ -> pure ()
    }

data VisionReport = VisionReport
  { vrTagged :: Int
  , vrSkipped :: Int
  , vrSuggested :: Int
  , vrFailed :: [(Text, Text)]
  , vrAborted :: Maybe Text
  }
  deriving stock (Eq, Show)

data VisionJob = VisionJob
  { vjSha :: Text
  , vjOriginal :: Text
  , vjPath :: Text
  , vjPackName :: Text
  }
  deriving stock (Eq, Show)

instance FromRow VisionJob where
  fromRow = VisionJob <$> field <*> field <*> field <*> field

-- | 工作選取。一次查完,與 @ThumbRun.hs:44@ 同一個形狀。
--
-- @ORDER BY b.sha256@ 是刻意的:續跑後的順序完全一致,所以出問題時可以
-- 二分搜尋定位。
selectJobs :: Connection -> VisionOptions -> IO [VisionJob]
selectJobs conn VisionOptions {..} =
  fmap (maybe id take voLimit) $
    queryNamed
      conn
      "SELECT b.sha256, a.original_name, COALESCE(a.entry_path, a.rel_path, ''), \
      \       COALESCE(p.name, '') \
      \FROM blobs b \
      \JOIN assets a ON a.sha256 = b.sha256 \
      \LEFT JOIN packs p ON p.id = a.pack_id \
      \WHERE b.kind = 'image' \
      \  AND b.thumb_status = 'ok' \
      \  AND a.status = 'active' \
      \  AND COALESCE(p.kind,'packs') = 'packs' \
      \  AND (:slug IS NULL OR p.slug = :slug) \
      \  AND (:force OR b.ai_status = 'pending' \
      \       OR (:retry AND b.ai_status = 'failed')) \
      \GROUP BY b.sha256 \
      \ORDER BY b.sha256"
      [":slug" := voPackSlug, ":force" := voForce, ":retry" := voRetryFailed]

visionTagBlobs :: Connection -> Llm -> VisionOptions -> IO VisionReport
visionTagBlobs conn llm opts@VisionOptions {..} = do
  vocab <- loadVocab conn visionScopes
  todo <- selectJobs conn opts
  runId <- beginRun conn "vision" (llmConfig llm) promptVersion "{}" (length todo)
  (ok, skipped, failed, aborted) <-
    driveItems conn runId voOnProgress vjOriginal (step vocab runId) todo
  case aborted of
    Just why -> abortRun conn runId why ok (length failed)
    Nothing -> finishRun conn runId ok (length failed)
  pure
    VisionReport
      { vrTagged = ok
      , vrSkipped = skipped
      , vrSuggested = ok
      , vrFailed = failed
      , vrAborted = aborted
      }
  where
    size = if voLarge then Thumb512 else Thumb128

    step vocab runId job = do
      murl <- loadThumbDataUrl voCacheRoot (vjSha job) size
      case murl of
        -- 沒有縮圖不是錯誤,是還沒做。標成 skipped,提示先跑 assetdb thumbs。
        Nothing -> do
          markStatus conn (vjSha job) "skipped" (Just "找不到縮圖檔")
          pure (StepSkipped "no thumbnail")
        Just url -> do
          let info =
                VisionInfo
                  { viOriginalName = vjOriginal job
                  , viPath = vjPath job
                  , viPackName = vjPackName job
                  }
              req =
                ( defaultChatRequest
                    [ systemMsg (visionSystem vocab)
                    , userTextImage (visionUser info) url
                    ]
                )
                  { crResponseFormat = Just (visionSchema vocab)
                  }
          r <- chatJson llm req
          case r of
            Left e -> retryOrFail vocab runId job req e
            Right v -> commit vocab runId job v

    retryOrFail vocab runId job req e = case e of
      LlmTruncated _ -> again
      LlmEmptyContent _ -> again
      _ -> failOut e
      where
        again = do
          let bigger = req {crMaxTokens = Just (2 * lcMaxTokens (llmConfig llm))}
          r2 <- chatJson llm bigger
          case r2 of
            Left e2 -> failOut e2
            Right v -> commit vocab runId job v
        failOut err = do
          let o = outcomeOf err
          case o of
            -- 中止時**不要**動狀態欄。這一筆保持 pending,佇列才留得住。
            StepAbort _ -> pure ()
            _ -> markStatus conn (vjSha job) "failed" (Just (renderLlmError err))
          pure o

    commit vocab runId job v = do
      let sha = vjSha job
          conf = clamp01 (vvConfidence v)
          cat = vvCategory v
          subOk = isChildOf vocab cat (vvSubcategory v)
          why = Just (T.take 300 (vvAnalysis v))
          cats =
            [categorySuggestion "blob" sha cat (Just conf) why | cat /= "unknown"]
              <> [categorySuggestion "blob" sha (vvSubcategory v) (Just conf) why | subOk]
          subs =
            [subjectSuggestion "blob" sha "en" (vvSubjectEn v) | not (T.null (vvSubjectEn v))]
              <> [subjectSuggestion "blob" sha "zh" (vvSubjectZh v) | not (T.null (vvSubjectZh v))]
          tags =
            tagsFor sha "en" (vvTagsEn v) conf <> tagsFor sha "zh" (vvTagsZh v) conf
      -- 建議寫入與狀態更新在同一個 transaction,而且**在 LLM 呼叫之後**。
      n <- upsertSuggestions conn (Just (unRunId runId)) (cats <> subs <> tags)
      markStatus conn sha "ok" Nothing
      pure (StepOk n)

    -- 上限 4 個是為了壓住同義詞爆炸:tags 的唯一鍵是 (facet, name),
    -- 「藥水」「魔藥」「藥劑」會變成三列。三列都能命中不是壞事,但索引
    -- 會被灌水,所以在這裡收斂。
    tagsFor sha lang vs conf =
      [ tagSuggestion "blob" sha "free" lang t (Just conf)
      | t <- take 4 (filter (not . T.null) (map T.strip vs))
      ]

    unRunId (RunId i) = i

markStatus :: Connection -> Text -> Text -> Maybe Text -> IO ()
markStatus conn sha st err = do
  ts <- T.pack . iso8601Show <$> getCurrentTime
  execute
    conn
    "UPDATE blobs SET ai_status = ?, ai_error = ?, ai_seen_at = ? WHERE sha256 = ?"
    (st, err, ts, sha)

clamp01 :: Double -> Double
clamp01 d
  | isNaN d = 0
  | d < 0 = 0
  | d > 1 = 1
  | otherwise = d
