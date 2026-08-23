module Main (main) where

import qualified Aapms.Workshop.CabalSpec
import qualified Aapms.Workshop.EmitSpec
import qualified Aapms.Workshop.ErrorSpec
import qualified Aapms.Workshop.PromptSpec
import qualified Aapms.Workshop.SessionIdSpec
import qualified Aapms.Workshop.SessionIOSpec
import qualified Aapms.Workshop.SessionJsonSpec
import qualified Aapms.Workshop.StartSpec
import qualified Aapms.Workshop.StepSpec
import qualified Aapms.Workshop.StubSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 / T12 套件骨架與邊界" Aapms.Workshop.CabalSpec.spec
    describe "T4 Aapms.Workshop.Error" Aapms.Workshop.ErrorSpec.spec
    describe "T5 Aapms.Workshop.Session(JSON)" Aapms.Workshop.SessionJsonSpec.spec
    describe "T6 Aapms.Workshop.Session(快照讀寫)" Aapms.Workshop.SessionIOSpec.spec
    describe "T7 Aapms.Workshop.Session(session id)" Aapms.Workshop.SessionIdSpec.spec
    describe "T8 Aapms.Workshop.Stages.startWorkshop" Aapms.Workshop.StartSpec.spec
    describe "T9 Aapms.Workshop.Stages(prompt 組裝)" Aapms.Workshop.PromptSpec.spec
    describe "T10 Aapms.Workshop.Stages.stepWorkshop" Aapms.Workshop.StepSpec.spec
    describe "T11 測試底稿自己的契約" Aapms.Workshop.StubSpec.spec
    describe "T2-T6 Aapms.Workshop.Emit.commitStage" Aapms.Workshop.EmitSpec.spec
