module Main (main) where

import AssetDB.Archive (describeTools, discoverTools)
import AssetDB.Cli.Ai
  ( runAiApply
  , runAiClassify
  , runAiDecide
  , runAiPing
  , runAiQuery
  , runAiStatus
  , runAiSuggestList
  , runAiVision
  )
import AssetDB.Cli.Cluster (runClusterApply, runClusterList, runClusterRule)
import AssetDB.Cli.Doctor (runDoctor)
import AssetDB.Cli.Options
import AssetDB.Cli.Pack (runPackApply, runPackList)
import AssetDB.Cli.Reorg (runReorg)
import AssetDB.Cli.Scan (runScan)
import AssetDB.Cli.Search (runIndex, runSearch)
import AssetDB.Cli.Thumbs (runThumbs)
import AssetDB.Cli.Project (runNewProject, runProjectSync)
import AssetDB.Cli.Notes (runLink, runNoteImport, runNoteList)
import AssetDB.Console (setupConsole)
import Data.Text.IO qualified as TIO

main :: IO ()
main = do
  -- 素材路徑與素材包名稱大量含有中文,兩件事都要做:把字編成 UTF-8
  -- 位元組(hSetEncoding),以及讓主控台用 UTF-8 去解讀那些位元組
  -- (SetConsoleOutputCP)。只做前者的話,檔案是對的、螢幕是亂碼。
  setupConsole

  Invocation global cmd <- parseInvocation
  -- 只有 scan 是「初始化」語意,允許在找不到資料庫時開一個新的。其餘指令
  -- 都在讀既有索引,找不到資料庫就該報錯 —— 見 delivery/B001。
  let forQuery = resolveDbPathForQuery global
      forInit = resolveDbPathForInit global
  case cmd of
    CmdTools -> discoverTools >>= TIO.putStrLn . describeTools
    CmdScan args -> forInit >>= \db -> runScan db args
    CmdDoctor -> forQuery >>= runDoctor
    CmdPackList -> forQuery >>= runPackList
    CmdPackApply f -> forQuery >>= \db -> runPackApply db f
    CmdReorgPlan a -> forQuery >>= \db -> runReorg db a
    CmdClusterList s -> forQuery >>= \db -> runClusterList db s
    CmdClusterRule a -> forQuery >>= \db -> runClusterRule db a
    CmdClusterApply s -> forQuery >>= \db -> runClusterApply db s
    CmdSearch a -> forQuery >>= \db -> runSearch db a
    CmdIndex -> forQuery >>= runIndex
    CmdThumbs f -> forQuery >>= \db -> runThumbs db f
    CmdNewProject a -> forQuery >>= \db -> runNewProject db a
    CmdProjectSync a -> forQuery >>= \db -> runProjectSync db a
    CmdNoteImport a -> forQuery >>= \db -> runNoteImport db a
    CmdNoteList k -> forQuery >>= \db -> runNoteList db k
    CmdLink a -> forQuery >>= \db -> runLink db a
    CmdAiPing c -> forQuery >>= \db -> runAiPing db c
    CmdAiClassify c a -> forQuery >>= \db -> runAiClassify db c a
    CmdAiVision c a -> forQuery >>= \db -> runAiVision db c a
    CmdAiSuggestList a -> forQuery >>= \db -> runAiSuggestList db a
    CmdAiDecide a -> forQuery >>= \db -> runAiDecide db a
    CmdAiApply a -> forQuery >>= \db -> runAiApply db a
    CmdAiQuery c a -> forQuery >>= \db -> runAiQuery db c a
    CmdAiStatus -> forQuery >>= runAiStatus
