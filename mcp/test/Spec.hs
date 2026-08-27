module Main (main) where

import qualified Aapms.Mcp.CabalSpec
import qualified Aapms.Mcp.ClientSpec
import qualified Aapms.Mcp.ConfigSpec
import qualified Aapms.Mcp.ProtocolSpec
import qualified Aapms.Mcp.ServerSpec
import qualified Aapms.Mcp.ToolsSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T10 套件骨架與邊界" Aapms.Mcp.CabalSpec.spec
    describe "T2 Aapms.Mcp.Protocol" Aapms.Mcp.ProtocolSpec.spec
    describe "T6 Aapms.Mcp.Config" Aapms.Mcp.ConfigSpec.spec
    describe "T5 Aapms.Mcp.Tools" Aapms.Mcp.ToolsSpec.spec
    describe "T7 Aapms.Mcp.Client" Aapms.Mcp.ClientSpec.spec
    describe "T8 Aapms.Mcp.Server" Aapms.Mcp.ServerSpec.spec
