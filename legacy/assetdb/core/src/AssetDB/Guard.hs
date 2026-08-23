-- | 例外的守衛。
--
-- 這個模組只有一個函式,而它存在的理由是:**裸的 @try \@SomeException@ 會接住
-- Ctrl-C**。批次迴圈用裸 try 包住每一項時,使用者按 Ctrl-C 會被記成「這一項失敗」
-- 然後迴圈繼續跑下一項 —— 按幾次都停不下來。
--
-- 判準是每一項花多久:只花毫秒的工作,中斷訊號幾乎不可能落在裡面;而掃描一個
-- 素材包是數千次 insert、標註一張圖是 5.8 秒的 LLM 呼叫,落在裡面的機率接近 100%。
--
-- 收在 @core@ 是因為它是純 @base@。全系統只有這一份實作 —— 這條規則的正確性很微妙
-- (忘了重拋就沒人會發現),不該有第二份可以各自演進(G-E003)。
module AssetDB.Guard
  ( guardedTry
  , withTopLevel
  ) where

import Control.Exception (AsyncException, SomeException, catch, fromException, throwIO, try)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..), exitWith)
import System.IO (hSetEncoding, stderr, utf8)

-- | 逐項的 try,但**不吞掉 Ctrl-C**。
--
-- 'AsyncException' 重新拋出 —— 它不是「這一項的錯誤」,是使用者要求停止。
guardedTry :: IO a -> IO (Either SomeException a)
guardedTry act =
  try act >>= \case
    Left e | Just (ae :: AsyncException) <- fromException e -> throwIO ae
    r -> pure r

-- | 執行檔的頂層例外處理:逃到這裡的東西一律翻成使用者看得懂的訊息。
--
-- 渲染函式由呼叫端提供 —— 它需要認得 @SQLError@,而那來自 sqlite-simple,
-- @core@ 不能依賴(ADR-001)。這裡只擁有**判斷的順序**,而那正是容易寫錯的部分。
--
-- == 三條規則,順序不能錯
--
-- 1. **'ExitCode' 必須重拋。** Haskell 的 @exitFailure@ / @exitSuccess@ 是用例外
--    實作的,天真的 @catch \@SomeException@ 會把「這個指令刻意以非 0 結束」變成
--    「頂層印了一則錯誤」—— 結束碼與訊息雙雙錯掉,而且測試不容易發現。
-- 2. **'AsyncException' 印「已中斷」並以非 0 結束。** 使用者按 Ctrl-C 不是程式出錯,
--    但也不該無聲無息。
-- 3. 其餘經渲染函式印到 stderr,以非 0 結束。
withTopLevel :: (SomeException -> Text) -> IO () -> IO ()
withTopLevel render act = act `catch` handler
  where
    handler e
      | Just (ec :: ExitCode) <- fromException e = throwIO ec
      | Just (_ :: AsyncException) <- fromException e = bail "已中斷。"
      | otherwise = bail (render e)

    bail msg = do
      -- stderr 也要 UTF-8:setupConsole 設的是 stdout,而錯誤走的是另一個 handle。
      hSetEncoding stderr utf8
      TIO.hPutStrLn stderr msg
      exitWith (ExitFailure 1)
