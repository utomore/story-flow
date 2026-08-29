module Main (main) where

import qualified Aapms.Workspace.HubSpec
import qualified Aapms.Workspace.LocationSpec
import qualified Aapms.Workspace.TypesSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    -- workspace/F001
    Aapms.Workspace.TypesSpec.spec
    Aapms.Workspace.LocationSpec.spec
    Aapms.Workspace.HubSpec.spec
