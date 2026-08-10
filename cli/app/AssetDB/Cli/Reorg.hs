module AssetDB.Cli.Reorg (runReorgPlan) where

import AssetDB.Reorg.Plan
import AssetDB.Reorg.Render
import AssetDB.Reorg.Snapshot
import AssetDB.Store
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.FilePath (takeDirectory)

runReorgPlan :: FilePath -> FilePath -> FilePath -> Maybe FilePath -> Bool -> IO ()
runReorgPlan dbPath srcRoot dstRoot mOut verbose = do
  src <- makeAbsolute srcRoot
  dst <- makeAbsolute dstRoot
  withStore dbPath $ \st -> do
    _ <- initSchema st
    snap <- loadSnapshot st

    if null (snPacks snap) && null (snLoose snap)
      then
        TIO.putStrLn
          "資料庫是空的。先執行 assetdb scan --root <素材庫路徑>,\n\
          \否則計畫會是空的 —— 那不代表沒事要做,只代表還不知道有什麼。"
      else do
        let plan = buildPlan (T.pack src) (T.pack dst) snap
            report = renderPlan (if verbose then Verbose else Summary) plan
        case mOut of
          Nothing -> TIO.putStr report
          Just out -> do
            createDirectoryIfMissing True (takeDirectory out)
            TIO.writeFile out report
            -- 寫進檔案時仍然把摘要印到終端機。使用者需要**立刻**知道
            -- 「要刪五千個檔案」,而不是自己去開檔案才發現。
            TIO.putStr (renderSummary plan)
            TIO.putStrLn ("完整計畫已寫入 " <> T.pack out)
