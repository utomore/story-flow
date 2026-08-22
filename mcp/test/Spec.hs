module Main (main) where

import qualified StoryFlow.Mcp.CabalSpec
import qualified StoryFlow.Mcp.ClientSpec
import qualified StoryFlow.Mcp.ConfigSpec
import qualified StoryFlow.Mcp.ProtocolSpec
import qualified StoryFlow.Mcp.ServerSpec
import qualified StoryFlow.Mcp.ToolsSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T10 套件骨架與邊界" StoryFlow.Mcp.CabalSpec.spec
    describe "T2 StoryFlow.Mcp.Protocol" StoryFlow.Mcp.ProtocolSpec.spec
    describe "T6 StoryFlow.Mcp.Config" StoryFlow.Mcp.ConfigSpec.spec
    describe "T5 StoryFlow.Mcp.Tools" StoryFlow.Mcp.ToolsSpec.spec
    describe "T7 StoryFlow.Mcp.Client" StoryFlow.Mcp.ClientSpec.spec
    describe "T8 StoryFlow.Mcp.Server" StoryFlow.Mcp.ServerSpec.spec
