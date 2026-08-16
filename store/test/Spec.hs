module Main (main) where

import qualified StoryFlow.Store.AtomicSpec
import qualified StoryFlow.Store.IndexSpec
import qualified StoryFlow.Store.InitSpec
import qualified StoryFlow.Store.QuerySpec
import qualified StoryFlow.Store.RebuildSpec
import qualified StoryFlow.Store.SchemaSpec
import qualified StoryFlow.Store.SearchSpec
import qualified StoryFlow.Store.StaleSpec
import qualified StoryFlow.Store.VaultSpec
import qualified StoryFlow.Store.WriteSpec
import qualified StoryFlow.StoreSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    StoryFlow.StoreSpec.spec
    StoryFlow.Store.VaultSpec.spec
    StoryFlow.Store.InitSpec.spec
    StoryFlow.Store.AtomicSpec.spec
    StoryFlow.Store.SchemaSpec.spec
    StoryFlow.Store.IndexSpec.spec
    StoryFlow.Store.RebuildSpec.spec
    StoryFlow.Store.StaleSpec.spec
    StoryFlow.Store.WriteSpec.spec
    StoryFlow.Store.QuerySpec.spec
    StoryFlow.Store.SearchSpec.spec
