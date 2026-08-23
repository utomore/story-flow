module Main (main) where

import qualified Aapms.Conflict.CabalSpec
import qualified Aapms.Conflict.CheckEnvSpec
import qualified Aapms.Conflict.CheckSpec
import qualified Aapms.Conflict.EvidenceSpec
import qualified Aapms.Conflict.GraphSpec
import qualified Aapms.Conflict.JsonSpec
import qualified Aapms.Conflict.JudgeEnvSpec
import qualified Aapms.Conflict.JudgeSpec
import qualified Aapms.Conflict.MergeSpec
import qualified Aapms.Conflict.OptsSpec
import qualified Aapms.Conflict.PipelineSpec
import qualified Aapms.Conflict.ReportSpec
import qualified Aapms.Conflict.RetrievalEnvSpec
import qualified Aapms.Conflict.RetrievalSpec
import qualified Aapms.Conflict.SortSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 套件邊界" Aapms.Conflict.CabalSpec.spec
    describe "T2 Draft / ConflictOpts" Aapms.Conflict.OptsSpec.spec
    describe "T3 GraphEvidence / HitLayer" Aapms.Conflict.EvidenceSpec.spec
    describe "T4 ConflictHit / ContextHit / ConflictReport" Aapms.Conflict.ReportSpec.spec
    describe "T5 layerTag / sortHits" Aapms.Conflict.SortSpec.spec
    describe "T6 Aapms.Conflict.Json" Aapms.Conflict.JsonSpec.spec
    describe "F002 Aapms.Conflict.Graph" Aapms.Conflict.GraphSpec.spec
    describe "F003 Aapms.Conflict.Retrieval(純函式)" Aapms.Conflict.RetrievalSpec.spec
    describe "F003 Aapms.Conflict.Retrieval(整合)" Aapms.Conflict.RetrievalEnvSpec.spec
    describe "F004 Aapms.Conflict.Pipeline(合流,純函式)" Aapms.Conflict.MergeSpec.spec
    describe "F004 Aapms.Conflict.Pipeline(整合)" Aapms.Conflict.PipelineSpec.spec
    describe "F005 Aapms.Conflict.Judge(純函式)" Aapms.Conflict.JudgeSpec.spec
    describe "F005 Aapms.Conflict.Judge(整合)" Aapms.Conflict.JudgeEnvSpec.spec
    describe "F006 Aapms.Conflict.Pipeline(check,純函式)" Aapms.Conflict.CheckSpec.spec
    describe "F006 Aapms.Conflict.Pipeline(check,整合)" Aapms.Conflict.CheckEnvSpec.spec
