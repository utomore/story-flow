module Main (main) where

import qualified Aapms.Service.AliasIndexSpec
import qualified Aapms.Service.CabalSpec
import qualified Aapms.Service.EndToEndSpec
import qualified Aapms.Service.EntityReadSpec
import qualified Aapms.Service.EntityWriteSpec
import qualified Aapms.Service.EnvSpec
import qualified Aapms.Service.ErrorSpec
import qualified Aapms.Service.FacadeSpec
import qualified Aapms.Service.JsonSpec
import qualified Aapms.Service.LevelSpec
import qualified Aapms.Service.LinkGraphSpec
import qualified Aapms.Service.LinkSpec
import qualified Aapms.Service.MonadSpec
import qualified Aapms.Service.TypeListSpec
import qualified Aapms.Service.TypesSpec
import qualified Aapms.Service.ValidateSpec
import qualified Aapms.Service.VaultConfigSpec
import qualified Aapms.Service.LocateSpec
import qualified Aapms.Service.VaultRootSpec
import qualified Aapms.Service.VaultSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    Aapms.Service.CabalSpec.spec
    Aapms.Service.ErrorSpec.spec
    Aapms.Service.MonadSpec.spec
    Aapms.Service.EnvSpec.spec
    Aapms.Service.TypesSpec.spec
    Aapms.Service.JsonSpec.spec
    Aapms.Service.ValidateSpec.spec
    Aapms.Service.VaultSpec.spec
    describe "llm-workshop-mcp/F001 T4 vaultConfig" Aapms.Service.VaultConfigSpec.spec
    describe "llm-workshop-mcp/F002 T2 vaultRoot" Aapms.Service.VaultRootSpec.spec
    describe "G-E002 T2/T3 registryHint 與 locateVault" Aapms.Service.LocateSpec.spec
    Aapms.Service.TypeListSpec.spec
    Aapms.Service.EntityReadSpec.spec
    Aapms.Service.AliasIndexSpec.spec
    Aapms.Service.EntityWriteSpec.spec
    Aapms.Service.LinkSpec.spec
    Aapms.Service.LinkGraphSpec.spec
    Aapms.Service.LevelSpec.spec
    Aapms.Service.FacadeSpec.spec
    Aapms.Service.EndToEndSpec.spec
