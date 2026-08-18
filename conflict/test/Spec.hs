module Main (main) where

import qualified StoryFlow.Conflict.CabalSpec
import qualified StoryFlow.Conflict.EvidenceSpec
import qualified StoryFlow.Conflict.JsonSpec
import qualified StoryFlow.Conflict.OptsSpec
import qualified StoryFlow.Conflict.ReportSpec
import qualified StoryFlow.Conflict.SortSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 套件邊界" StoryFlow.Conflict.CabalSpec.spec
    describe "T2 Draft / ConflictOpts" StoryFlow.Conflict.OptsSpec.spec
    describe "T3 GraphEvidence / HitLayer" StoryFlow.Conflict.EvidenceSpec.spec
    describe "T4 ConflictHit / ContextHit / ConflictReport" StoryFlow.Conflict.ReportSpec.spec
    describe "T5 layerTag / sortHits" StoryFlow.Conflict.SortSpec.spec
    describe "T6 StoryFlow.Conflict.Json" StoryFlow.Conflict.JsonSpec.spec
