module Main (main) where

import qualified StoryFlow.Api.ApiSpec
import qualified StoryFlow.Api.CabalSpec
import qualified StoryFlow.Api.HttpDataSpec
import qualified StoryFlow.Api.OpenApiSpec
import qualified StoryFlow.Api.SchemaSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    -- 依 service-and-interfaces/F003 的 TodoList 順序
    StoryFlow.Api.CabalSpec.spec
    StoryFlow.Api.HttpDataSpec.spec
    StoryFlow.Api.SchemaSpec.spec
    StoryFlow.Api.ApiSpec.spec
    StoryFlow.Api.OpenApiSpec.spec
