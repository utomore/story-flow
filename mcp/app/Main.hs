-- | @story-flow-mcp@ ——MCP stdio adapter 的執行檔。
--
-- 只有一個選項(@--url@),手寫掃描 'argv' 即可,不需要
-- @optparse-applicative@ 那整套指令解析框架(design.md 待確認假設 A7)。
module Main (main) where

import qualified Data.Text as T
import StoryFlow.Mcp (resolveConfig, runServer)
import System.Environment (getArgs)

main :: IO ()
main = do
  argv <- map T.pack <$> getArgs
  cfgResult <- resolveConfig argv
  runServer cfgResult
