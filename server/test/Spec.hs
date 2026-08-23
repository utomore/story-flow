module Main (main) where

import qualified Aapms.Server.AuthSpec
import qualified Aapms.Server.CabalSpec
import qualified Aapms.Server.ConcurrencySpec
import qualified Aapms.Server.ErrorMapSpec
import qualified Aapms.Server.HandlerSpec
import qualified Aapms.Server.ServeOptsSpec
import qualified Aapms.Server.WorkshopErrorMapSpec
import qualified Aapms.Server.WorkshopHandlerSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    Aapms.Server.CabalSpec.spec
    Aapms.Server.ErrorMapSpec.spec
    Aapms.Server.ServeOptsSpec.spec
    Aapms.Server.AuthSpec.spec
    Aapms.Server.HandlerSpec.spec
    Aapms.Server.ConcurrencySpec.spec
    -- llm-workshop-mcp/F004
    Aapms.Server.WorkshopErrorMapSpec.spec
    Aapms.Server.WorkshopHandlerSpec.spec
