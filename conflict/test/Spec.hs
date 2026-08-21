module Main (main) where

import qualified StoryFlow.Conflict.CabalSpec
import qualified StoryFlow.Conflict.CheckEnvSpec
import qualified StoryFlow.Conflict.CheckSpec
import qualified StoryFlow.Conflict.EvidenceSpec
import qualified StoryFlow.Conflict.GraphSpec
import qualified StoryFlow.Conflict.JsonSpec
import qualified StoryFlow.Conflict.JudgeEnvSpec
import qualified StoryFlow.Conflict.JudgeSpec
import qualified StoryFlow.Conflict.MergeSpec
import qualified StoryFlow.Conflict.OptsSpec
import qualified StoryFlow.Conflict.PipelineSpec
import qualified StoryFlow.Conflict.ReportSpec
import qualified StoryFlow.Conflict.RetrievalEnvSpec
import qualified StoryFlow.Conflict.RetrievalSpec
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
    describe "F002 StoryFlow.Conflict.Graph" StoryFlow.Conflict.GraphSpec.spec
    describe "F003 StoryFlow.Conflict.Retrieval(純函式)" StoryFlow.Conflict.RetrievalSpec.spec
    describe "F003 StoryFlow.Conflict.Retrieval(整合)" StoryFlow.Conflict.RetrievalEnvSpec.spec
    describe "F004 StoryFlow.Conflict.Pipeline(合流,純函式)" StoryFlow.Conflict.MergeSpec.spec
    describe "F004 StoryFlow.Conflict.Pipeline(整合)" StoryFlow.Conflict.PipelineSpec.spec
    describe "F005 StoryFlow.Conflict.Judge(純函式)" StoryFlow.Conflict.JudgeSpec.spec
    describe "F005 StoryFlow.Conflict.Judge(整合)" StoryFlow.Conflict.JudgeEnvSpec.spec
    describe "F006 StoryFlow.Conflict.Pipeline(check,純函式)" StoryFlow.Conflict.CheckSpec.spec
    describe "F006 StoryFlow.Conflict.Pipeline(check,整合)" StoryFlow.Conflict.CheckEnvSpec.spec
