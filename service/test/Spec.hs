module Main (main) where

import qualified StoryFlow.Service.AliasIndexSpec
import qualified StoryFlow.Service.CabalSpec
import qualified StoryFlow.Service.EndToEndSpec
import qualified StoryFlow.Service.EntityReadSpec
import qualified StoryFlow.Service.EntityWriteSpec
import qualified StoryFlow.Service.EnvSpec
import qualified StoryFlow.Service.ErrorSpec
import qualified StoryFlow.Service.FacadeSpec
import qualified StoryFlow.Service.JsonSpec
import qualified StoryFlow.Service.LevelSpec
import qualified StoryFlow.Service.LinkGraphSpec
import qualified StoryFlow.Service.LinkSpec
import qualified StoryFlow.Service.MonadSpec
import qualified StoryFlow.Service.TypeListSpec
import qualified StoryFlow.Service.TypesSpec
import qualified StoryFlow.Service.ValidateSpec
import qualified StoryFlow.Service.VaultConfigSpec
import qualified StoryFlow.Service.VaultSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    StoryFlow.Service.CabalSpec.spec
    StoryFlow.Service.ErrorSpec.spec
    StoryFlow.Service.MonadSpec.spec
    StoryFlow.Service.EnvSpec.spec
    StoryFlow.Service.TypesSpec.spec
    StoryFlow.Service.JsonSpec.spec
    StoryFlow.Service.ValidateSpec.spec
    StoryFlow.Service.VaultSpec.spec
    describe "llm-workshop-mcp/F001 T4 vaultConfig" StoryFlow.Service.VaultConfigSpec.spec
    StoryFlow.Service.TypeListSpec.spec
    StoryFlow.Service.EntityReadSpec.spec
    StoryFlow.Service.AliasIndexSpec.spec
    StoryFlow.Service.EntityWriteSpec.spec
    StoryFlow.Service.LinkSpec.spec
    StoryFlow.Service.LinkGraphSpec.spec
    StoryFlow.Service.LevelSpec.spec
    StoryFlow.Service.FacadeSpec.spec
    StoryFlow.Service.EndToEndSpec.spec
