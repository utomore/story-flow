module Main (main) where

import qualified Aapms.Workspace.DiscoverySpec
import qualified Aapms.Workspace.HubSpec
import qualified Aapms.Workspace.LifecycleSpec
import qualified Aapms.Workspace.LocationSpec
import qualified Aapms.Workspace.ProjectsSpec
import qualified Aapms.Workspace.ScopeSpec
import qualified Aapms.Workspace.TypesSpec
import qualified Aapms.Workspace.ToolsSpec
import qualified Aapms.Lawful.P029Spec
import qualified Aapms.Lawful.P005Spec
import qualified Aapms.Lawful.P028Spec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "lawful P029" Aapms.Lawful.P029Spec.spec
    describe "lawful P005" Aapms.Lawful.P005Spec.spec
    describe "lawful P028" Aapms.Lawful.P028Spec.spec
    -- workspace/F001
    Aapms.Workspace.TypesSpec.spec
    Aapms.Workspace.LocationSpec.spec
    Aapms.Workspace.HubSpec.spec
    Aapms.Workspace.DiscoverySpec.spec
    Aapms.Workspace.ScopeSpec.spec
    Aapms.Workspace.LifecycleSpec.spec
    Aapms.Workspace.ProjectsSpec.spec
    Aapms.Workspace.ToolsSpec.spec
