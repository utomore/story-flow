-- | @story-flow-mcp@ ——MCP stdio adapter 的執行檔。
--
-- 只有一個選項(@--url@),手寫掃描 'argv' 即可,不需要
-- @optparse-applicative@ 那整套指令解析框架(design.md 待確認假設 A7)。
module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import StoryFlow.Mcp (mcpVersion, resolveConfig, runServer, wantsVersion)
import System.Environment (getArgs)

main :: IO ()
main = do
  argv <- map T.pack <$> getArgs
  -- --version 是 CLI 式呼叫,不是 session:印一行就結束,不進 JSON-RPC 迴圈(G-E002)
  if wantsVersion argv
    then TIO.putStrLn mcpVersion
    else do
      cfgResult <- resolveConfig argv
      runServer cfgResult
