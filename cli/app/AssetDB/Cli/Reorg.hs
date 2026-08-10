module AssetDB.Cli.Reorg (runReorg) where

import AssetDB.Cli.Options
import AssetDB.Id (newULID, unULID)
import AssetDB.Reorg.Execute
import AssetDB.Reorg.Plan
import AssetDB.Reorg.Render
import AssetDB.Reorg.Snapshot
import AssetDB.Store
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)

runReorg :: FilePath -> ReorgArgs -> IO ()
runReorg dbPath ReorgArgs {..} = do
  src <- makeAbsolute raSource
  dst <- makeAbsolute raTarget
  withStore dbPath $ \st -> do
    _ <- initSchema st
    case raMode of
      ModeListBatches -> listBatchesCmd st
      ModeUndo batch -> undoCmd st src dst batch
      ModeDryRun out verbose -> withPlan st src dst (dryRun out verbose)
      ModeApply del -> withPlan st src dst (apply st del)

--------------------------------------------------------------------------------

withPlan :: Store -> FilePath -> FilePath -> (Snapshot -> Plan -> IO ()) -> IO ()
withPlan st src dst k = do
  snap <- loadSnapshot st
  if null (snPacks snap) && null (snLoose snap)
    then do
      TIO.putStrLn
        "資料庫是空的。先執行 assetdb scan --root <素材庫路徑>,\n\
        \否則計畫會是空的 —— 那不代表沒事要做,只代表還不知道有什麼。"
      exitFailure
    else k snap (buildPlan (T.pack src) (T.pack dst) snap)

dryRun :: Maybe FilePath -> Bool -> Snapshot -> Plan -> IO ()
dryRun out verbose _ plan = do
  let report = renderPlan (if verbose then Verbose else Summary) plan
  case out of
    Nothing -> TIO.putStr report
    Just f -> do
      createDirectoryIfMissing True (takeDirectory f)
      -- 一律以 UTF-8 位元組寫檔。TIO.writeFile 用 locale 編碼,
      -- Windows 上編不出計畫裡的 ⚠ 符號。
      BS.writeFile f (encodeUtf8 report)
      TIO.putStr (renderSummary plan)
      TIO.putStrLn ("完整計畫已寫入 " <> T.pack f)

apply :: Store -> Bool -> Snapshot -> Plan -> IO ()
apply st deleteCovered snap plan = do
  batch <- unULID <$> newULID
  let st' = planStats plan

  TIO.putStrLn ("批次 " <> batch)
  TIO.putStrLn ""
  TIO.putStr (renderSummary plan)

  if deleteCovered
    then
      TIO.putStrLn
        ( "\n⚠ --delete-covered 已開啟。階段 B 會刪除 "
            <> tshow (psDelete st')
            <> " 個散檔,**這部分無法回退**。\n"
        )
    else TIO.putStrLn "\n只執行階段 A。階段 B(刪除)需要 --delete-covered。\n"

  report <-
    applyPlan
      st
      snap
      (defaultApplyOptions batch)
        { aoDeleteCovered = deleteCovered
        , aoOnEvent = say
        }
      plan

  TIO.putStrLn ""
  TIO.putStrLn "── 結果 ──"
  TIO.putStrLn ("  建立目錄    " <> tshow (arDirsCreated report))
  TIO.putStrLn ("  搬移        " <> tshow (arMoved report) <> "  (" <> humanBytes (arBytesMoved report) <> ")")
  TIO.putStrLn ("  寫入        " <> tshow (arWritten report))
  TIO.putStrLn ("  對帳通過    " <> tshow (arReconciled report))
  TIO.putStrLn ("  刪除        " <> tshow (arDeleted report))

  if null (arErrors report)
    then do
      TIO.putStrLn ""
      TIO.putStrLn "接下來:資料庫裡的路徑還是舊的。重新索引新結構:"
      TIO.putStrLn "  assetdb scan --root <新的根目錄>"
      TIO.putStrLn "  assetdb pack apply --catalogue data/packs.toml"
      TIO.putStrLn ""
      TIO.putStrLn ("要回退這個批次:assetdb reorganize --undo " <> batch <> " --source … --target …")
    else do
      TIO.putStrLn ""
      TIO.putStrLn ("⚠ " <> tshow (length (arErrors report)) <> " 個問題:")
      mapM_ (\e -> TIO.putStrLn ("    " <> e)) (take 20 (arErrors report))
      exitFailure

say :: ApplyEvent -> IO ()
say = \case
  EvPreflight m -> TIO.putStrLn ("  前置檢查:" <> m)
  EvPhase m -> TIO.putStrLn ("\n▸ " <> m)
  EvProgress i n what ->
    TIO.putStrLn ("  [" <> tshow i <> "/" <> tshow n <> "] " <> shorten what)
  EvNote m -> TIO.putStrLn ("  " <> m)
  EvFailure m -> TIO.putStrLn ("  ✗ " <> m)

--------------------------------------------------------------------------------

undoCmd :: Store -> FilePath -> FilePath -> Text -> IO ()
undoCmd st src dst batch = do
  (ok, errs) <- undoBatch st src dst batch TIO.putStrLn
  TIO.putStrLn ("回退 " <> tshow ok <> " 筆")
  if null errs
    then pure ()
    else do
      TIO.putStrLn ("⚠ " <> tshow (length errs) <> " 筆無法回退:")
      mapM_ (\e -> TIO.putStrLn ("    " <> e)) (take 20 errs)

listBatchesCmd :: Store -> IO ()
listBatchesCmd st = do
  bs <- listBatches st
  if null bs
    then TIO.putStrLn "沒有已執行的批次。"
    else mapM_ (\(b, n, ts) -> TIO.putStrLn (b <> "  " <> tshow n <> " 筆  " <> ts)) bs

shorten :: Text -> Text
shorten t = if T.length t <= 78 then t else "…" <> T.takeEnd 77 t

tshow :: Show a => a -> Text
tshow = T.pack . show
