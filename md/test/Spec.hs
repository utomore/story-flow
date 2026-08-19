module Main (main) where

import qualified StoryFlow.Md.DocumentSpec
import qualified StoryFlow.Md.EditSpec
import qualified StoryFlow.Md.ErrorSpec
import qualified StoryFlow.Md.HeadingSpec
import qualified StoryFlow.Md.InheritSpec
import qualified StoryFlow.Md.LexerSpec
import qualified StoryFlow.Md.ParseEntitySpec
import qualified StoryFlow.Md.ParseLevelSpec
import qualified StoryFlow.Md.RenderSpec
import qualified StoryFlow.Md.YamlSpec
import qualified StoryFlow.MdSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 StoryFlow.Md.Document" StoryFlow.Md.DocumentSpec.spec
    describe "T2 StoryFlow.Md.Lexer" StoryFlow.Md.LexerSpec.spec
    describe "T3 節標題 {#id}" StoryFlow.Md.HeadingSpec.spec
    describe "T4 StoryFlow.Md.Yaml" StoryFlow.Md.YamlSpec.spec
    describe "T5 StoryFlow.Md.Inherit" StoryFlow.Md.InheritSpec.spec
    describe "T6 parseEntityFile" StoryFlow.Md.ParseEntitySpec.spec
    describe "T7 parseLevelFile" StoryFlow.Md.ParseLevelSpec.spec
    describe "T8 renderDocument" StoryFlow.Md.RenderSpec.spec
    describe "T9 updateSection / insertSection / removeSection" StoryFlow.Md.EditSpec.spec
    describe "T10 StoryFlow.Md.Error" StoryFlow.Md.ErrorSpec.spec
    describe "entity-graph-core/F001 T6 輸出編碼" StoryFlow.MdSpec.spec
