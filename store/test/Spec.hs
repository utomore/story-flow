module Main (main) where

import qualified Aapms.Store.AtomicSpec
import qualified Aapms.Store.BoundarySpec
import qualified Aapms.Store.CreateSpec
import qualified Aapms.Store.EditSpec
import qualified Aapms.Store.ErrorSpec
import qualified Aapms.Store.FacetSpec
import qualified Aapms.Store.IndexSpec
import qualified Aapms.Store.MarkerSpec
import qualified Aapms.Store.MultiVaultSpec
import qualified Aapms.Store.NodeSpec
import qualified Aapms.Store.NodeSpec2
import qualified Aapms.Store.QuerySpec
import qualified Aapms.Store.RebuildSpec
import qualified Aapms.Store.RowSpec
import qualified Aapms.Store.SchemaSpec
import qualified Aapms.Store.SearchSpec
import qualified Aapms.Store.StaleSpec
import qualified Aapms.Store.StoreErrorL15Spec
import qualified Aapms.Store.TokenizeSpec
import qualified Aapms.Store.WalkSpec
import qualified Aapms.Store.WriteLockBudgetSpec
import qualified Aapms.Store.WriteSpec
import qualified Aapms.StoreSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    Aapms.StoreSpec.spec
    Aapms.Store.AtomicSpec.spec
    Aapms.Store.ErrorSpec.spec
    Aapms.Store.SchemaSpec.spec
    Aapms.Store.MarkerSpec.spec
    Aapms.Store.IndexSpec.spec
    Aapms.Store.RebuildSpec.spec
    Aapms.Store.StaleSpec.spec
    Aapms.Store.QuerySpec.spec
    Aapms.Store.NodeSpec.spec
    Aapms.Store.RowSpec.spec
    -- graph-core/F007
    Aapms.Store.TokenizeSpec.spec
    Aapms.Store.SearchSpec.spec
    Aapms.Store.FacetSpec.spec
    -- graph-core/F008(qa 委派新增)
    Aapms.Store.StoreErrorL15Spec.spec
    Aapms.Store.NodeSpec2.spec
    Aapms.Store.EditSpec.spec
    Aapms.Store.CreateSpec.spec
    Aapms.Store.WriteSpec.spec
    Aapms.Store.WriteLockBudgetSpec.spec
    -- graph-core/F009(qa 委派新增)
    Aapms.Store.MultiVaultSpec.spec
    -- graph-core/E001(qa 委派新增)
    Aapms.Store.WalkSpec.spec
    Aapms.Store.BoundarySpec.spec
