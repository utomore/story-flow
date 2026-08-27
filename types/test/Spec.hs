module Main (main) where

import qualified Aapms.Types.LoaderSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $
    describe "graph-core/F002 T12+T13 Aapms.Types.Loader" Aapms.Types.LoaderSpec.spec
