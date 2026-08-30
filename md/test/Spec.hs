module Main (main) where

import qualified Aapms.Md.AppendSectionSpec
import qualified Aapms.Md.DocKindLawSpec
import qualified Aapms.Md.DocKindSpec
import qualified Aapms.Md.DocumentSpec
import qualified Aapms.Md.EditSpec
import qualified Aapms.Md.EditLawsSpec
import qualified Aapms.Md.ErrorSpec
import qualified Aapms.Md.FrontExtrasSpec
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
    describe "graph-core/F004 docKind(LAW-22/Example 10)" Aapms.Md.DocKindSpec.spec
    describe "STEP-1 Aapms.Md.Document" Aapms.Md.DocumentSpec.spec
    describe "STEP-2 Aapms.Md.Lexer / STEP-5 單一錯誤契約" Aapms.Md.LexerSpec.spec
    describe "STEP-3 節標題 {#id}" Aapms.Md.HeadingSpec.spec
    describe "STEP-4 Aapms.Md.Yaml" Aapms.Md.YamlSpec.spec
    describe "STEP-1/STEP-3 Aapms.Md.Inherit" Aapms.Md.InheritSpec.spec
    describe "STEP-8 toTopic" Aapms.Md.ParseEntitySpec.spec
    describe "STEP-8 toLevel" Aapms.Md.ParseLevelSpec.spec
    describe "STEP-9 toPack" Aapms.Md.ParsePackSpec.spec
    describe "STEP-10 toLicenses" Aapms.Md.ParseLicenseSpec.spec
    describe "STEP-2/STEP-7/STEP-15 renderDocument" Aapms.Md.RenderSpec.spec
    describe "STEP-13 updateSection / updateSectionBody / removeSection" Aapms.Md.EditSpec.spec
    describe "STEP-12 appendSection" Aapms.Md.AppendSectionSpec.spec
    describe "STEP-4/STEP-11 Aapms.Md.Error" Aapms.Md.ErrorSpec.spec
    describe "entity-graph-core/F001 STEP-6 輸出編碼" Aapms.MdSpec.spec
    describe "graph-core/F004 Laws: 單節編輯/meta 區塊(LAW-2-LAW-12)" Aapms.Md.EditLawsSpec.spec
    describe "graph-core/F004 Laws: NewSectionPayload/appendSection/mkSection(LAW-13-LAW-18,LAW-21)" Aapms.Md.NewSectionLawsSpec.spec
    describe "graph-core/F004 Laws: docKind(LAW-22)" Aapms.Md.DocKindLawSpec.spec
    describe "graph-core/F004 Laws: 回歸(LAW-1,LAW-19,LAW-20,LAW-23-LAW-31)" Aapms.Md.RegressionLawsSpec.spec
    describe "graph-core/F004(2026-08-25) insertSection(LAW-32-LAW-39,EX-11-EX-22)" Aapms.Md.InsertSectionSpec.spec
    describe "graph-core/F004(2026-08-25 第三輪,GAP-17) 檔案層 extras(LAW-40-LAW-49,EX-23-EX-29)" Aapms.Md.FrontExtrasSpec.spec
