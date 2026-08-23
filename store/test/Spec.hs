module Main (main) where

import qualified Aapms.Store.AtomicSpec
import qualified Aapms.Store.CreateSpec
import qualified Aapms.Store.DeleteSpec
import qualified Aapms.Store.EndToEndSpec
import qualified Aapms.Store.ErrorSpec
import qualified Aapms.Store.IndexSpec
import qualified Aapms.Store.InitSpec
import qualified Aapms.Store.NodeSpec
import qualified Aapms.Store.QuerySpec
import qualified Aapms.Store.RebuildSpec
import qualified Aapms.Store.SchemaSpec
import qualified Aapms.Store.SearchSpec
import qualified Aapms.Store.StaleSpec
import qualified Aapms.Store.VaultSpec
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
    Aapms.Store.VaultSpec.spec
    Aapms.Store.InitSpec.spec
    Aapms.Store.AtomicSpec.spec
    Aapms.Store.SchemaSpec.spec
    Aapms.Store.IndexSpec.spec
    Aapms.Store.RebuildSpec.spec
    Aapms.Store.StaleSpec.spec
    Aapms.Store.WriteSpec.spec
    Aapms.Store.CreateSpec.spec
    Aapms.Store.DeleteSpec.spec
    Aapms.Store.NodeSpec.spec
    Aapms.Store.ErrorSpec.spec
    Aapms.Store.QuerySpec.spec
    Aapms.Store.SearchSpec.spec
    Aapms.Store.EndToEndSpec.spec
