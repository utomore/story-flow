module Main (main) where

import AssetDB.Archive (describeTools, discoverTools)
import AssetDB.Cli.Cluster (runClusterList)
import AssetDB.Cli.Doctor (runDoctor)
import AssetDB.Cli.Options
import AssetDB.Cli.Pack (runPackApply, runPackList)
import AssetDB.Cli.Reorg (runReorg)
import AssetDB.Cli.Scan (runScan)
import Data.Text.IO qualified as TIO
import System.IO

main :: IO ()
main = do
  -- GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。素材路徑與素材包名稱
  -- 大量含有中文,不設這個的話輸出全是亂碼 —— 而且重導向到檔案時同樣壞掉,
  -- 所以不是終端機顯示問題,是真的寫錯位元組。
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetBuffering stdout LineBuffering

  Invocation global cmd <- parseInvocation
  case cmd of
    CmdTools -> discoverTools >>= TIO.putStrLn . describeTools
    CmdScan args -> resolveDbPath global >>= \db -> runScan db args
    CmdDoctor -> resolveDbPath global >>= runDoctor
    CmdPackList -> resolveDbPath global >>= runPackList
    CmdPackApply f -> resolveDbPath global >>= \db -> runPackApply db f
    CmdReorgPlan a -> resolveDbPath global >>= \db -> runReorg db a
    CmdClusterList s -> resolveDbPath global >>= \db -> runClusterList db s
