module Main (main) where

import qualified StoryFlow.StoreSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec StoryFlow.StoreSpec.spec
