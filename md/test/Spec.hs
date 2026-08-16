module Main (main) where

import qualified StoryFlow.MdSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec StoryFlow.MdSpec.spec
