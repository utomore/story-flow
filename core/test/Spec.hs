module Main (main) where

import qualified Aapms.Core.AnyNodeSpec
import qualified Aapms.Core.AssetSpec
import qualified Aapms.Core.CabalSpec
import qualified Aapms.Core.EntitySpec
import qualified Aapms.Core.IdSpec
import qualified Aapms.Core.JsonSpec
import qualified Aapms.Core.LicenseSpec
import qualified Aapms.Core.LinkSpec
import qualified Aapms.Core.ManifestSpec
import qualified Aapms.Core.MetaSpec
import qualified Aapms.Core.NamingCasesSpec
import qualified Aapms.Core.NamingSpec
import qualified Aapms.Core.PackSpec
import qualified Aapms.Core.RegistrySpec
import qualified Aapms.Core.TreeSpec
import qualified Aapms.CoreSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "STEP-1 Aapms.Core.Id" Aapms.Core.IdSpec.spec
    describe "STEP-2 Aapms.Core.Meta" Aapms.Core.MetaSpec.spec
    describe "STEP-3 Aapms.Core.Link" Aapms.Core.LinkSpec.spec
    describe "STEP-4+STEP-8 Aapms.Core.Entity / .Level / .Node" Aapms.Core.EntitySpec.spec
    describe "STEP-5 Aapms.Core.Asset" Aapms.Core.AssetSpec.spec
    describe "STEP-6 Aapms.Core.Pack" Aapms.Core.PackSpec.spec
    describe "STEP-7 Aapms.Core.License" Aapms.Core.LicenseSpec.spec
    describe "STEP-9 Aapms.Core.AnyNode" Aapms.Core.AnyNodeSpec.spec
    describe "STEP-10 Aapms.Core.Tree" Aapms.Core.TreeSpec.spec
    describe "STEP-12 Aapms.Core.Json" Aapms.Core.JsonSpec.spec
    describe "STEP-13+STEP-14 aapms-core.cabal" Aapms.Core.CabalSpec.spec
    describe "graph-core/F001 STEP-6 輸出編碼" Aapms.CoreSpec.spec
    describe "graph-core/F002 STEP-1+STEP-9 Aapms.Core.Naming" Aapms.Core.NamingSpec.spec
    describe "graph-core/F002 STEP-10 naming-cases.txt fixture" Aapms.Core.NamingCasesSpec.spec
    describe "graph-core/F002 STEP-2+STEP-3+STEP-11 Aapms.Core.Registry" Aapms.Core.RegistrySpec.spec
    describe "graph-core/F003 STEP-1~STEP-8 Aapms.Core.Manifest" Aapms.Core.ManifestSpec.spec
