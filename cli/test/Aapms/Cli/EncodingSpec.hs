-- | service-and-interfaces/B002:給人看的輸出被導向檔案或管線時,要是 UTF-8。
--
-- 2026-08-22 實測:@aapms vault init … > out.txt@ 在 Windows 得到 CP950 位元組
-- ——任何 UTF-8 工具讀它都是亂碼。@--json@ 那條路徑是對的('jsonLine' 自己編 UTF-8),
-- 壞的只有人類模式。
--
-- __為什麼 1435 條測試抓不到__:'Aapms.Cli.Fixtures.withTempHandle' 對每個測試
-- handle 都先 @hSetEncoding utf8@,把真實世界的條件遮掉了。本檔刻意__不__用那個
-- fixture:開一個只有 locale 預設編碼的 handle,等於「導向檔案」的實際情況。
--
-- 在 UTF-8 locale 的機器上(多數 Linux / macOS)這條測試修復前也會綠——那是平台
-- 湊巧對,不是程式對;Windows 上它修復前一定紅。
module Aapms.Cli.EncodingSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Cli (CliIO (..), runCliWith)
import System.Exit (ExitCode (..))
import System.IO (SeekMode (AbsoluteSeek), hFlush, hSeek)
import System.IO.Temp (withSystemTempFile)
import Test.Hspec

spec :: Spec
spec = describe "人類模式的輸出編碼(B002)" $
  it "導向非終端機的 handle 時是 UTF-8,不是 locale 的 code page" $
    withSystemTempFile "aapms-raw-out" $ \_ hOut ->
      withSystemTempFile "aapms-raw-err" $ \_ hErr ->
        withSystemTempFile "aapms-raw-in" $ \_ hIn -> do
          -- 三個 handle 都維持 locale 預設編碼,不碰 hSetEncoding
          code <- runCliWith (CliIO hOut hErr hIn) ["--help"]
          code `shouldBe` ExitSuccess
          hFlush hOut
          hSeek hOut AbsoluteSeek 0
          bytes <- BS.hGetContents hOut
          case TE.decodeUtf8' bytes of
            Left e -> expectationFailure ("stdout 不是合法 UTF-8:" <> show e)
            Right t -> t `shouldSatisfy` T.isInfixOf "故事設定"
