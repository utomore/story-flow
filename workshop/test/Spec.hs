module Main (main) where

import qualified StoryFlow.Workshop.CabalSpec
import qualified StoryFlow.Workshop.ErrorSpec
import qualified StoryFlow.Workshop.PromptSpec
import qualified StoryFlow.Workshop.SessionIdSpec
import qualified StoryFlow.Workshop.SessionIOSpec
import qualified StoryFlow.Workshop.SessionJsonSpec
import qualified StoryFlow.Workshop.StartSpec
import qualified StoryFlow.Workshop.StepSpec
import qualified StoryFlow.Workshop.StubSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 / T12 套件骨架與邊界" StoryFlow.Workshop.CabalSpec.spec
    describe "T4 StoryFlow.Workshop.Error" StoryFlow.Workshop.ErrorSpec.spec
    describe "T5 StoryFlow.Workshop.Session(JSON)" StoryFlow.Workshop.SessionJsonSpec.spec
    describe "T6 StoryFlow.Workshop.Session(快照讀寫)" StoryFlow.Workshop.SessionIOSpec.spec
    describe "T7 StoryFlow.Workshop.Session(session id)" StoryFlow.Workshop.SessionIdSpec.spec
    describe "T8 StoryFlow.Workshop.Stages.startWorkshop" StoryFlow.Workshop.StartSpec.spec
    describe "T9 StoryFlow.Workshop.Stages(prompt 組裝)" StoryFlow.Workshop.PromptSpec.spec
    describe "T10 StoryFlow.Workshop.Stages.stepWorkshop" StoryFlow.Workshop.StepSpec.spec
    describe "T11 測試底稿自己的契約" StoryFlow.Workshop.StubSpec.spec
