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
import AssetDB.Cli.Project (runNewProject)
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
  case cmd of
    CmdTools -> discoverTools >>= TIO.putStrLn . describeTools
    CmdScan args -> resolveDbPath global >>= \db -> runScan db args
    CmdDoctor -> resolveDbPath global >>= runDoctor
    CmdPackList -> resolveDbPath global >>= runPackList
    CmdPackApply f -> resolveDbPath global >>= \db -> runPackApply db f
    CmdReorgPlan a -> resolveDbPath global >>= \db -> runReorg db a
    CmdClusterList s -> resolveDbPath global >>= \db -> runClusterList db s
    CmdClusterRule a -> resolveDbPath global >>= \db -> runClusterRule db a
    CmdClusterApply s -> resolveDbPath global >>= \db -> runClusterApply db s
    CmdSearch a -> resolveDbPath global >>= \db -> runSearch db a
    CmdIndex -> resolveDbPath global >>= runIndex
    CmdThumbs f -> resolveDbPath global >>= \db -> runThumbs db f
    CmdNewProject a -> resolveDbPath global >>= \db -> runNewProject db a
    CmdNoteImport a -> resolveDbPath global >>= \db -> runNoteImport db a
    CmdNoteList k -> resolveDbPath global >>= \db -> runNoteList db k
    CmdLink a -> resolveDbPath global >>= \db -> runLink db a
    CmdAiPing c -> resolveDbPath global >>= \db -> runAiPing db c
    CmdAiClassify c a -> resolveDbPath global >>= \db -> runAiClassify db c a
    CmdAiVision c a -> resolveDbPath global >>= \db -> runAiVision db c a
    CmdAiSuggestList a -> resolveDbPath global >>= \db -> runAiSuggestList db a
    CmdAiDecide a -> resolveDbPath global >>= \db -> runAiDecide db a
    CmdAiApply a -> resolveDbPath global >>= \db -> runAiApply db a
    CmdAiQuery c a -> resolveDbPath global >>= \db -> runAiQuery db c a
    CmdAiStatus -> resolveDbPath global >>= runAiStatus
