-- | @story-flow@ 執行檔。
--
-- 只有三個動作:拿引數、跑、用回來的 'ExitCode' 收尾。全部的邏輯在
-- @storyflow-cli@ 的 library 裡,測試因此不必 @readProcess@ 就能跑完整個指令。
module Main (main) where

import StoryFlow.Cli (runCli)
import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main = getArgs >>= runCli >>= exitWith
