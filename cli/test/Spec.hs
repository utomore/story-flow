module Main (main) where

import qualified Aapms.Cli.CabalSpec
import qualified Aapms.Cli.ContextCmdSpec
import qualified Aapms.Cli.EndToEndSpec
import qualified Aapms.Cli.EntityNewSpec
import qualified Aapms.Cli.EntityReadSpec
import qualified Aapms.Cli.EntityWriteSpec
import qualified Aapms.Cli.EnvelopeSpec
import qualified Aapms.Cli.LevelCmdSpec
import qualified Aapms.Cli.LinkCmdSpec
import qualified Aapms.Cli.NodeCmdSpec
import qualified Aapms.Cli.OptionsSpec
import qualified Aapms.Cli.ParitySpec
import qualified Aapms.Cli.RemoteCmdSpec
import qualified Aapms.Cli.RemoteOptSpec
import qualified Aapms.Cli.RemoteResolveSpec
import qualified Aapms.Cli.RenderSpec
import qualified Aapms.Cli.ResolveSpec
import qualified Aapms.Cli.RunCliSpec
import qualified Aapms.Cli.TreeSpec
import qualified Aapms.Cli.VaultCmdSpec
import qualified Aapms.Cli.DoctorSpec
import qualified Aapms.Cli.EncodingSpec
import qualified Aapms.Cli.ReleaseScriptSpec
import qualified Aapms.Cli.WorkshopCmdSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    -- 依 service-and-interfaces/F002 的 TodoList 順序:純函式在前,開 Vault 的在後
    Aapms.Cli.CabalSpec.spec
    Aapms.Cli.OptionsSpec.spec
    Aapms.Cli.EnvelopeSpec.spec
    Aapms.Cli.RenderSpec.spec
    Aapms.Cli.TreeSpec.spec
    Aapms.Cli.ResolveSpec.spec
    Aapms.Cli.RunCliSpec.spec
    Aapms.Cli.VaultCmdSpec.spec
    Aapms.Cli.EntityNewSpec.spec
    Aapms.Cli.EntityReadSpec.spec
    Aapms.Cli.EntityWriteSpec.spec
    Aapms.Cli.LinkCmdSpec.spec
    Aapms.Cli.LevelCmdSpec.spec
    Aapms.Cli.NodeCmdSpec.spec
    Aapms.Cli.EndToEndSpec.spec
    -- service-and-interfaces/F003:遠端模式
    Aapms.Cli.RemoteOptSpec.spec
    Aapms.Cli.RemoteResolveSpec.spec
    Aapms.Cli.RemoteCmdSpec.spec
    Aapms.Cli.ParitySpec.spec
    -- conflict-detection/F004:context 出口(內嵌與遠端兩條路徑都在這一檔)
    Aapms.Cli.ContextCmdSpec.spec
    -- llm-workshop-mcp/F004:workshop 三指令(內嵌路徑;遠端與對照分別併進
    -- RemoteCmdSpec / ParitySpec)
    Aapms.Cli.WorkshopCmdSpec.spec
    -- G-E002:doctor 本機診斷
    Aapms.Cli.DoctorSpec.spec
    Aapms.Cli.ReleaseScriptSpec.spec
    -- service-and-interfaces/B002:人類模式輸出的編碼
    Aapms.Cli.EncodingSpec.spec
