module Main (main) where

import qualified Aapms.Md.AppendSectionSpec
import qualified Aapms.Md.DocKindLawSpec
import qualified Aapms.Md.DocKindSpec
import qualified Aapms.Md.DocumentSpec
import qualified Aapms.Md.EditSpec
import qualified Aapms.Md.EditLawsSpec
import qualified Aapms.Md.ErrorSpec
import qualified Aapms.Md.HeadingSpec
import qualified Aapms.Md.InheritSpec
import qualified Aapms.Md.InsertSectionSpec
import qualified Aapms.Md.LexerSpec
import qualified Aapms.Md.NewSectionLawsSpec
import qualified Aapms.Md.ParseEntitySpec
import qualified Aapms.Md.ParseLevelSpec
import qualified Aapms.Md.ParseLicenseSpec
import qualified Aapms.Md.ParsePackSpec
import qualified Aapms.Md.RegressionLawsSpec
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
    describe "graph-core/F004 docKind(L22/Example 10)" Aapms.Md.DocKindSpec.spec
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
    describe "graph-core/F004 Laws: 單節編輯/meta 區塊(L2-L12)" Aapms.Md.EditLawsSpec.spec
    describe "graph-core/F004 Laws: NewSectionPayload/appendSection/mkSection(L13-L18,L21)" Aapms.Md.NewSectionLawsSpec.spec
    describe "graph-core/F004 Laws: docKind(L22)" Aapms.Md.DocKindLawSpec.spec
    describe "graph-core/F004 Laws: 回歸(L1,L19,L20,L23-L31)" Aapms.Md.RegressionLawsSpec.spec
    describe "graph-core/F004(2026-08-25) insertSection(L32-L39,E11-E22)" Aapms.Md.InsertSectionSpec.spec
