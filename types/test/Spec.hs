module Main (main) where

import qualified StoryFlow.Types.LoaderSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $
    describe "T10+T11 StoryFlow.Types.Loader" StoryFlow.Types.LoaderSpec.spec
