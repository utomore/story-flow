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
    describe "T1 Aapms.Core.Id" Aapms.Core.IdSpec.spec
    describe "T2 Aapms.Core.Meta" Aapms.Core.MetaSpec.spec
    describe "T3 Aapms.Core.Link" Aapms.Core.LinkSpec.spec
    describe "T4+T8 Aapms.Core.Entity / .Level / .Node" Aapms.Core.EntitySpec.spec
    describe "T5 Aapms.Core.Asset" Aapms.Core.AssetSpec.spec
    describe "T6 Aapms.Core.Pack" Aapms.Core.PackSpec.spec
    describe "T7 Aapms.Core.License" Aapms.Core.LicenseSpec.spec
    describe "T9 Aapms.Core.AnyNode" Aapms.Core.AnyNodeSpec.spec
    describe "T10 Aapms.Core.Tree" Aapms.Core.TreeSpec.spec
    describe "T12 Aapms.Core.Json" Aapms.Core.JsonSpec.spec
    describe "T13+T14 aapms-core.cabal" Aapms.Core.CabalSpec.spec
    describe "graph-core/F001 T6 輸出編碼" Aapms.CoreSpec.spec
    describe "graph-core/F002 T1+T9 Aapms.Core.Naming" Aapms.Core.NamingSpec.spec
    describe "graph-core/F002 T10 naming-cases.txt fixture" Aapms.Core.NamingCasesSpec.spec
    describe "graph-core/F002 T2+T3+T11 Aapms.Core.Registry" Aapms.Core.RegistrySpec.spec
    describe "graph-core/F003 T1~T8 Aapms.Core.Manifest" Aapms.Core.ManifestSpec.spec
