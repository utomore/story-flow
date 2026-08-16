-- | 批次執行的共用機制:記帳、續跑、中斷語意。
--
-- 這個模組存在,是因為叢集分類與視覺標註若各自帶一份「逐筆提交、分類
-- 失敗、別吞掉 Ctrl-C、更新 run 列」的邏輯,那正好是最不該有兩個版本的
-- 那部分程式。
module AssetDB.AI.Run
  ( RunId (..)
  , beginRun
  , bumpRun
  , finishRun
  , abortRun
  , guardedTry
  , StepOutcome (..)
  , outcomeOf
  , Progress (..)
  , renderProgress
  , driveItems
  ) where

import AssetDB.AI.Llm
import AssetDB.Id (newULID, renderULID)
import Control.Exception (AsyncException, SomeException, fromException, throwIO, try)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple

newtype RunId = RunId Int
  deriving stock (Eq, Show)

nowText :: IO Text
nowText = T.pack . iso8601Show <$> getCurrentTime

beginRun :: Connection -> Text -> LlmConfig -> Text -> Text -> Int -> IO RunId
beginRun conn kind cfg promptVer params total = do
  u <- renderULID <$> newULID
  ts <- nowText
  execute
    conn
    "INSERT INTO ai_runs (ulid, kind, model, prompt_ver, params_json, status, total, started_at) \
    \VALUES (?,?,?,?,?, 'running', ?, ?)"
    (u, kind, lcModel cfg, promptVer, params, total, ts)
  RunId . fromIntegral <$> lastInsertRowId conn

bumpRun :: Connection -> RunId -> Int -> Int -> IO ()
bumpRun conn (RunId i) done failed =
  execute conn "UPDATE ai_runs SET done = ?, failed = ? WHERE id = ?" (done, failed, i)

finishRun :: Connection -> RunId -> Int -> Int -> IO ()
finishRun conn (RunId i) done failed = do
  ts <- nowText
  execute
    conn
    "UPDATE ai_runs SET status = 'done', done = ?, failed = ?, ended_at = ? WHERE id = ?"
    (done, failed, ts, i)

abortRun :: Connection -> RunId -> Text -> Int -> Int -> IO ()
abortRun conn (RunId i) why done failed = do
  ts <- nowText
  execute
    conn
    "UPDATE ai_runs SET status = 'aborted', done = ?, failed = ?, note = ?, ended_at = ? \
    \WHERE id = ?"
    (done, failed, why, ts, i)

--------------------------------------------------------------------------------

-- | 逐筆的 try,但**不吞掉 Ctrl-C**。
--
-- @ThumbRun.hs@ 用裸的 try 是安全的,因為那裡每筆只花毫秒,中斷訊號幾乎
-- 不可能落在工作內部。這裡每筆 5.8 秒,中斷訊號落在 LLM 呼叫裡的機率接近
-- 100% —— 被 SomeException 接住之後迴圈會繼續跑下一筆,使用者按 6,238 次
-- Ctrl-C 也停不下來。
guardedTry :: IO a -> IO (Either SomeException a)
guardedTry act =
  try act >>= \case
    Left e | Just (ae :: AsyncException) <- fromException e -> throwIO ae
    r -> pure r

-- | 單筆的結果。
data StepOutcome
  = -- | 成功,產生了幾筆建議。
    StepOk Int
  | -- | 這一筆做不了(如沒有縮圖),但不是錯誤。
    StepSkipped Text
  | -- | **這一筆**的問題。寫進狀態欄,重跑時跳過。
    StepFailed Text
  | -- | **不是這一筆**的問題(推論服務掛了)。整批停下,佇列保持 pending。
    StepAbort Text
  deriving stock (Eq, Show)

-- | 把 'LlmError' 對應到中止與失敗。
--
-- 這是本模組最重要的一個判斷。若推論服務在第 300 筆死掉而驅動器把它
-- 當成 StepFailed,剩下的 5,938 筆會被逐一標成 failed —— 工作佇列就毀了,
-- 而且「模型真的讀不懂這張圖」與「那時候服務沒開」再也分不出來。
outcomeOf :: LlmError -> StepOutcome
outcomeOf e
  | isTransient e = StepAbort (renderLlmError e)
  | otherwise = StepFailed (renderLlmError e)

--------------------------------------------------------------------------------

data Progress = Progress
  { pgIndex :: Int
  , pgTotal :: Int
  , pgLabel :: Text
  , pgEtaSecs :: Maybe Int
  }
  deriving stock (Eq, Show)

renderProgress :: Progress -> Text
renderProgress Progress {..} =
  "  ["
    <> tshow pgIndex
    <> "/"
    <> tshow pgTotal
    <> "] "
    <> pct
    <> eta
    <> "  "
    <> T.take 60 pgLabel
  where
    tshow :: Int -> Text
    tshow = T.pack . show
    pct
      | pgTotal <= 0 = ""
      | otherwise = tshow (pgIndex * 100 `div` pgTotal) <> "%"
    eta = case pgEtaSecs of
      Nothing -> ""
      Just s
        | s >= 3600 -> "  剩約 " <> tshow (s `div` 3600) <> " 小時 " <> tshow ((s `mod` 3600) `div` 60) <> " 分"
        | s >= 60 -> "  剩約 " <> tshow (s `div` 60) <> " 分"
        | otherwise -> "  剩約 " <> tshow s <> " 秒"

-- | 逐項驅動,回傳 (成功, 略過, 失敗清單, 中止原因)。
--
-- 進度每 25 筆寫回 @ai_runs@ —— 那是伺服器唯一能看到一個**不是它啟動**
-- 的 CLI 批次跑到哪裡的方式。
driveItems
  :: Connection
  -> RunId
  -> (Progress -> IO ())
  -> (a -> Text)
  -- ^ 這一項的顯示名稱
  -> (a -> IO StepOutcome)
  -> [a]
  -> IO (Int, Int, [(Text, Text)], Maybe Text)
driveItems conn runId onProgress labelOf step items = do
  t0 <- getCurrentTime
  okRef <- newIORef (0 :: Int)
  skipRef <- newIORef (0 :: Int)
  failRef <- newIORef ([] :: [(Text, Text)])
  abortRef <- newIORef (Nothing :: Maybe Text)
  let total = length items
      go [] = pure ()
      go ((i, x) : rest) = do
        now <- getCurrentTime
        onProgress
          Progress
            { pgIndex = i
            , pgTotal = total
            , pgLabel = labelOf x
            , pgEtaSecs = etaOf t0 now i total
            }
        r <- guardedTry (step x)
        outcome <- case r of
          Left e -> pure (StepFailed (compact (show e)))
          Right o -> pure o
        case outcome of
          StepOk _ -> modifyIORef' okRef (+ 1) >> go rest
          StepSkipped _ -> modifyIORef' skipRef (+ 1) >> go rest
          StepFailed m -> modifyIORef' failRef ((labelOf x, m) :) >> go rest
          -- 短路。剩下的項目保持 pending,下次重跑就是從這裡續。
          StepAbort m -> writeIORef abortRef (Just m)
        n <- readIORef okRef
        fs <- readIORef failRef
        if i `mod` 25 == 0 then bumpRun conn runId n (length fs) else pure ()
  go (zip [1 ..] items)
  (,,,)
    <$> readIORef okRef
    <*> readIORef skipRef
    <*> (reverse <$> readIORef failRef)
    <*> readIORef abortRef
  where
    compact = T.unwords . T.words . T.pack

etaOf :: UTCTime -> UTCTime -> Int -> Int -> Maybe Int
etaOf t0 now i total
  | i <= 1 || total <= i = Nothing
  | otherwise =
      let elapsed = realToFrac (diffUTCTime now t0) :: Double
          per = elapsed / fromIntegral (i - 1)
       in Just (round (per * fromIntegral (total - i + 1)))
