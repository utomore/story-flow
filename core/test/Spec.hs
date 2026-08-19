module Main (main) where

import qualified StoryFlow.Core.EntitySpec
import qualified StoryFlow.Core.GraphSpec
import qualified StoryFlow.Core.IdSpec
import qualified StoryFlow.Core.JsonSpec
import qualified StoryFlow.Core.LinkSpec
import qualified StoryFlow.Core.MetaSpec
import qualified StoryFlow.Core.RegistrySpec
import qualified StoryFlow.Core.TreeSpec
import qualified StoryFlow.CoreSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 StoryFlow.Core.Id" StoryFlow.Core.IdSpec.spec
    describe "T2 StoryFlow.Core.Meta" StoryFlow.Core.MetaSpec.spec
    describe "T3 StoryFlow.Core.Link" StoryFlow.Core.LinkSpec.spec
    describe "T4 StoryFlow.Core.Entity / .Level" StoryFlow.Core.EntitySpec.spec
    describe "T5+T6 StoryFlow.Core.Tree" StoryFlow.Core.TreeSpec.spec
    describe "T7 StoryFlow.Core.Graph" StoryFlow.Core.GraphSpec.spec
    describe "T8 StoryFlow.Core.Registry" StoryFlow.Core.RegistrySpec.spec
    describe "T9 StoryFlow.Core.Json" StoryFlow.Core.JsonSpec.spec
    describe "entity-graph-core/F001 T6 輸出編碼" StoryFlow.CoreSpec.spec
