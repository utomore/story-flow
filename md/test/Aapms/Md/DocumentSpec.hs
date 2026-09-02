-- | STEP-1:'Document' / 'Section' 型別與 'sectionById'、行尾判定。
module Aapms.Md.DocumentSpec (spec) where

import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

sampleSection :: Section
sampleSection =
  Section
    { secLevel = 2
    , secHeadingRaw = "## 外貌 {#ent-7f3b}\n"
    , secTitle = "外貌"
    , secId = idOf "ent-7f3b"
    , secMetaRaw = Just "\n```meta\ntype: character-fragment\n```\n"
    , secBodyRaw = "\n銀灰短髮剪到耳際……\n"
    , secLine = 19
    }

sampleDoc :: Document
sampleDoc =
  Document
    { docFrontRaw = "\nid: ent-7f3a\n"
    , docPreamble = "\n\n# 琳達\n"
    , docSections = [sampleSection]
    , docEnding = LF
    , docFinalNL = True
    , docKind = TopicDoc
    }

spec :: Spec
spec = do
  describe "Document / Section 欄位" $ do
    it "六個 Document 欄位都可建構且可取出" $ do
      docFrontRaw sampleDoc `shouldBe` "\nid: ent-7f3a\n"
      docPreamble sampleDoc `shouldBe` "\n\n# 琳達\n"
      length (docSections sampleDoc) `shouldBe` 1
      docEnding sampleDoc `shouldBe` LF
      docFinalNL sampleDoc `shouldBe` True
      docKind sampleDoc `shouldBe` TopicDoc

    it "七個 Section 欄位都可建構且可取出" $ do
      secLevel sampleSection `shouldBe` 2
      secHeadingRaw sampleSection `shouldBe` "## 外貌 {#ent-7f3b}\n"
      secTitle sampleSection `shouldBe` "外貌"
      secId sampleSection `shouldBe` idOf "ent-7f3b"
      secMetaRaw sampleSection `shouldSatisfy` (/= Nothing)
      secBodyRaw sampleSection `shouldBe` "\n銀灰短髮剪到耳際……\n"
      secLine sampleSection `shouldBe` 19

  describe "sectionById" $ do
    it "命中時回傳該節" $
      fmap secTitle (sectionById (idOf "ent-7f3b") sampleDoc) `shouldBe` Just "外貌"

    it "未命中時回傳 Nothing" $
      sectionById (idOf "ent-9999") sampleDoc `shouldBe` Nothing

    it "對真實檔案的兩節都命中" $ do
      let doc = docOf lindaMd
      fmap secTitle (sectionById (idOf "ent-7f3c") doc) `shouldBe` Just "與塔主的過節"

  describe "detectLineEnding 取多數" $ do
    it "全 LF 檔判為 LF" $
      detectLineEnding lindaMd `shouldBe` LF

    it "全 CRLF 檔判為 CRLF" $
      detectLineEnding (crlf lindaMd) `shouldBe` CRLF

    it "混合行尾以多數決:CRLF 較多時為 CRLF" $
      detectLineEnding "a\r\nb\r\nc\n" `shouldBe` CRLF

    it "混合行尾以多數決:LF 較多時為 LF" $
      detectLineEnding "a\r\nb\nc\n" `shouldBe` LF

    it "平手時取 LF" $
      detectLineEnding "a\r\nb\n" `shouldBe` LF

    it "沒有換行的單行檔取 LF" $
      detectLineEnding "只有一行" `shouldBe` LF

  describe "docKind" $ do
    it "主題檔(非保留 type)判為 TopicDoc" $
      docKind (docOf lindaMd) `shouldBe` TopicDoc

    it "type: level 判為 LevelDoc" $
      docKind (docOf classroomMd) `shouldBe` LevelDoc

    it "type: asset-pack 判為 PackDoc" $
      docKind (docOf packMd) `shouldBe` PackDoc

    it "type: asset-license 判為 LicenseDoc" $
      docKind (docOf licensesMd) `shouldBe` LicenseDoc
