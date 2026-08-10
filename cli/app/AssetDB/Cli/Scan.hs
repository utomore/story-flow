module AssetDB.Cli.Scan (runScan) where

import AssetDB.Archive (describeTools, discoverTools)
import AssetDB.Cli.Options
import AssetDB.Ingest
import AssetDB.Store
import Data.IORef
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Exit (exitFailure)

runScan :: FilePath -> ScanArgs -> IO ()
runScan dbPath ScanArgs {..} = do
  tools <- discoverTools
  TIO.putStrLn (describeTools tools)
  TIO.putStrLn ""

  started <- getCurrentTime
  withStore dbPath $ \st -> do
    applied <- initSchema st
    case applied of
      [] -> pure ()
      ms -> TIO.putStrLn ("套用 " <> tshow (length ms) <> " 個 migration")

    -- 進度不是裝飾。掃描 3.4 GB 要跑幾分鐘,沒有進度輸出時
    -- 使用者無從判斷程式是在跑還是卡住了。
    lastLine <- newIORef ""
    let onEvent ev =
          case renderEvent ev of
            Nothing -> pure ()
            Just line
              | saQuiet && not (isProblem ev) -> pure ()
              | otherwise -> do
                  writeIORef lastLine line
                  TIO.putStrLn line

    report <-
      scanRoot
        st
        tools
        (defaultScanOptions saRoot)
          { soRootKind = saKind
          , soRootLabel = maybe (soRootLabel (defaultScanOptions saRoot)) id saLabel
          , soRehash = saRehash
          , soOnEvent = onEvent
          }

    -- 掃描改變了被索引的內容,所以索引一定要跟著重建。
    -- 留給使用者記得下另一個指令,就是在製造「搜尋結果不完整而且沒人知道」。
    n <- reindexFts (storeConn st)
    TIO.putStrLn ("\n全文索引已重建:" <> tshow n <> " 筆")

    finished <- getCurrentTime
    TIO.putStrLn (renderReport report)
    TIO.putStrLn ("耗時 " <> tshow (round (diffUTCTime finished started) :: Int) <> " 秒")

    -- 有問題就以非零狀態結束。腳本與 CI 需要能靠 exit code 判斷,
    -- 而不是去 grep 輸出文字。
    if null (srProblems report) then pure () else exitFailure

isProblem :: ScanEvent -> Bool
isProblem = \case EvProblem _ -> True; _ -> False

tshow :: Show a => a -> T.Text
tshow = T.pack . show
