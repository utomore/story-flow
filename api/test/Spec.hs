module Main (main) where

import qualified Aapms.Api.ApiSpec
import qualified Aapms.Api.CabalSpec
import qualified Aapms.Api.HttpDataSpec
import qualified Aapms.Api.OpenApiSpec
import qualified Aapms.Api.SchemaSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    -- 依 service-and-interfaces/F003 的 TodoList 順序
    Aapms.Api.CabalSpec.spec
    Aapms.Api.HttpDataSpec.spec
    Aapms.Api.SchemaSpec.spec
    Aapms.Api.ApiSpec.spec
    Aapms.Api.OpenApiSpec.spec
