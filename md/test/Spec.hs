module Main (main) where

import qualified Aapms.Md.DocumentSpec
import qualified Aapms.Md.EditSpec
import qualified Aapms.Md.ErrorSpec
import qualified Aapms.Md.HeadingSpec
import qualified Aapms.Md.InheritSpec
import qualified Aapms.Md.LexerSpec
import qualified Aapms.Md.ParseEntitySpec
import qualified Aapms.Md.ParseLevelSpec
import qualified Aapms.Md.RenderSpec
import qualified Aapms.Md.YamlSpec
import qualified Aapms.MdSpec
import System.IO
import Test.Hspec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec $ do
    describe "T1 Aapms.Md.Document" Aapms.Md.DocumentSpec.spec
    describe "T2 Aapms.Md.Lexer" Aapms.Md.LexerSpec.spec
    describe "T3 節標題 {#id}" Aapms.Md.HeadingSpec.spec
    describe "T4 Aapms.Md.Yaml" Aapms.Md.YamlSpec.spec
    describe "T5 Aapms.Md.Inherit" Aapms.Md.InheritSpec.spec
    describe "T6 parseEntityFile" Aapms.Md.ParseEntitySpec.spec
    describe "T7 parseLevelFile" Aapms.Md.ParseLevelSpec.spec
    describe "T8 renderDocument" Aapms.Md.RenderSpec.spec
    describe "T9 updateSection / insertSection / removeSection" Aapms.Md.EditSpec.spec
    describe "T10 Aapms.Md.Error" Aapms.Md.ErrorSpec.spec
    describe "entity-graph-core/F001 T6 輸出編碼" Aapms.MdSpec.spec
