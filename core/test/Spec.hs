module Main (main) where

import qualified Aapms.Core.EntitySpec
import qualified Aapms.Core.GraphSpec
import qualified Aapms.Core.IdSpec
import qualified Aapms.Core.JsonSpec
import qualified Aapms.Core.LinkSpec
import qualified Aapms.Core.MetaSpec
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
    describe "T4 Aapms.Core.Entity / .Level" Aapms.Core.EntitySpec.spec
    describe "T5+T6 Aapms.Core.Tree" Aapms.Core.TreeSpec.spec
    describe "T7 Aapms.Core.Graph" Aapms.Core.GraphSpec.spec
    describe "T8 Aapms.Core.Registry" Aapms.Core.RegistrySpec.spec
    describe "T9 Aapms.Core.Json" Aapms.Core.JsonSpec.spec
    describe "entity-graph-core/F001 T6 輸出編碼" Aapms.CoreSpec.spec
