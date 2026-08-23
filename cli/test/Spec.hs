module Main (main) where

import qualified StoryFlow.Cli.CabalSpec
import qualified StoryFlow.Cli.ContextCmdSpec
import qualified StoryFlow.Cli.EndToEndSpec
import qualified StoryFlow.Cli.EntityNewSpec
import qualified StoryFlow.Cli.EntityReadSpec
import qualified StoryFlow.Cli.EntityWriteSpec
import qualified StoryFlow.Cli.EnvelopeSpec
import qualified StoryFlow.Cli.LevelCmdSpec
import qualified StoryFlow.Cli.LinkCmdSpec
import qualified StoryFlow.Cli.NodeCmdSpec
import qualified StoryFlow.Cli.OptionsSpec
import qualified StoryFlow.Cli.ParitySpec
import qualified StoryFlow.Cli.RemoteCmdSpec
import qualified StoryFlow.Cli.RemoteOptSpec
import qualified StoryFlow.Cli.RemoteResolveSpec
import qualified StoryFlow.Cli.RenderSpec
import qualified StoryFlow.Cli.ResolveSpec
import qualified StoryFlow.Cli.RunCliSpec
import qualified StoryFlow.Cli.TreeSpec
import qualified StoryFlow.Cli.VaultCmdSpec
import qualified StoryFlow.Cli.DoctorSpec
import qualified StoryFlow.Cli.ReleaseScriptSpec
import qualified StoryFlow.Cli.WorkshopCmdSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    -- 依 service-and-interfaces/F002 的 TodoList 順序:純函式在前,開 Vault 的在後
    StoryFlow.Cli.CabalSpec.spec
    StoryFlow.Cli.OptionsSpec.spec
    StoryFlow.Cli.EnvelopeSpec.spec
    StoryFlow.Cli.RenderSpec.spec
    StoryFlow.Cli.TreeSpec.spec
    StoryFlow.Cli.ResolveSpec.spec
    StoryFlow.Cli.RunCliSpec.spec
    StoryFlow.Cli.VaultCmdSpec.spec
    StoryFlow.Cli.EntityNewSpec.spec
    StoryFlow.Cli.EntityReadSpec.spec
    StoryFlow.Cli.EntityWriteSpec.spec
    StoryFlow.Cli.LinkCmdSpec.spec
    StoryFlow.Cli.LevelCmdSpec.spec
    StoryFlow.Cli.NodeCmdSpec.spec
    StoryFlow.Cli.EndToEndSpec.spec
    -- service-and-interfaces/F003:遠端模式
    StoryFlow.Cli.RemoteOptSpec.spec
    StoryFlow.Cli.RemoteResolveSpec.spec
    StoryFlow.Cli.RemoteCmdSpec.spec
    StoryFlow.Cli.ParitySpec.spec
    -- conflict-detection/F004:context 出口(內嵌與遠端兩條路徑都在這一檔)
    StoryFlow.Cli.ContextCmdSpec.spec
    -- llm-workshop-mcp/F004:workshop 三指令(內嵌路徑;遠端與對照分別併進
    -- RemoteCmdSpec / ParitySpec)
    StoryFlow.Cli.WorkshopCmdSpec.spec
    -- G-E002:doctor 本機診斷
    StoryFlow.Cli.DoctorSpec.spec
    StoryFlow.Cli.ReleaseScriptSpec.spec
