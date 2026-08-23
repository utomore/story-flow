module Main (main) where

import qualified Aapms.Md.AppendSectionSpec
import qualified Aapms.Md.DocumentSpec
import qualified Aapms.Md.EditSpec
import qualified Aapms.Md.ErrorSpec
import qualified Aapms.Md.HeadingSpec
import qualified Aapms.Md.InheritSpec
import qualified Aapms.Md.LexerSpec
import qualified Aapms.Md.ParseEntitySpec
import qualified Aapms.Md.ParseLevelSpec
import qualified Aapms.Md.ParseLicenseSpec
import qualified Aapms.Md.ParsePackSpec
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
    describe "T2 Aapms.Md.Lexer / T5 單一錯誤契約" Aapms.Md.LexerSpec.spec
    describe "T3 節標題 {#id}" Aapms.Md.HeadingSpec.spec
    describe "T4 Aapms.Md.Yaml" Aapms.Md.YamlSpec.spec
    describe "T1/T3 Aapms.Md.Inherit" Aapms.Md.InheritSpec.spec
    describe "T8 toTopic" Aapms.Md.ParseEntitySpec.spec
    describe "T8 toLevel" Aapms.Md.ParseLevelSpec.spec
    describe "T9 toPack" Aapms.Md.ParsePackSpec.spec
    describe "T10 toLicenses" Aapms.Md.ParseLicenseSpec.spec
    describe "T2/T7/T15 renderDocument" Aapms.Md.RenderSpec.spec
    describe "T13 updateSection / updateSectionBody / removeSection" Aapms.Md.EditSpec.spec
    describe "T12 appendSection" Aapms.Md.AppendSectionSpec.spec
    describe "T4/T11 Aapms.Md.Error" Aapms.Md.ErrorSpec.spec
    describe "entity-graph-core/F001 T6 輸出編碼" Aapms.MdSpec.spec
