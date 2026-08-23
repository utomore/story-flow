module Main (main) where

import qualified Aapms.Store.AtomicSpec
import qualified Aapms.Store.ErrorSpec
import qualified Aapms.Store.MarkerSpec
import qualified Aapms.Store.SchemaSpec
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
