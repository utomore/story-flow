module Main (main) where

import qualified StoryFlow.Server.AuthSpec
import qualified StoryFlow.Server.CabalSpec
import qualified StoryFlow.Server.ConcurrencySpec
import qualified StoryFlow.Server.ErrorMapSpec
import qualified StoryFlow.Server.HandlerSpec
import qualified StoryFlow.Server.ServeOptsSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    StoryFlow.Server.CabalSpec.spec
    StoryFlow.Server.ErrorMapSpec.spec
    StoryFlow.Server.ServeOptsSpec.spec
    StoryFlow.Server.AuthSpec.spec
    StoryFlow.Server.HandlerSpec.spec
    StoryFlow.Server.ConcurrencySpec.spec
