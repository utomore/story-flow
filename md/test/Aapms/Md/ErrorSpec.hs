-- | STEP-4:'MdError' 拿掉 'errPath',輸出改成「第 N 行:訊息」;STEP-11:
-- 'SectionFieldMissing' 的訊息(graph-core/F004)。
module Aapms.Md.ErrorSpec (spec) where

import qualified Data.Text as T
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "renderMdError 的格式(STEP-4:不含檔名)" $ do
    it "輸出「第 N 行:訊息」" $
      renderMdError (mdError 12 (MissingNodeKind (idOf "nod-0001")))
        `shouldSatisfy` T.isPrefixOf "第 12 行:"

    it "訊息不含冒號後路徑那種格式(不再有檔名可印)" $
      renderMdError (mdError 5 NoFrontmatter)
        `shouldBe` "第 5 行:檔案開頭缺少 --- frontmatter 界線"

    it "每一種錯誤都有非空訊息" $
      map
        (T.length . renderMdError . mdError 1)
        [ NoFrontmatter
        , UnterminatedFrontmatter
        , FrontmatterYaml "壞了"
        , SectionYaml (idOf "ent-0001") "壞了"
        , HeadingWithoutId "標題"
        , DuplicateSectionId (idOf "ent-0001")
        , IdPrefixMismatch (idOf "nod-0001") "ent"
        , HeadingSkip 2 4
        , HeadingAboveRoot 2 1
        , UnterminatedMetaBlock
        , MissingNodeKind (idOf "nod-0001")
        , RootMismatch (idOf "nod-0009") (idOf "nod-0001")
        , RequiredFieldMissing "title"
        , SectionFieldMissing (idOf "lic-0000000a") "commercial"
        , UnknownSectionId (idOf "ent-0001")
        ]
        `shouldSatisfy` all (> 8)

    it "跳級的訊息說得出是哪兩個層級" $
      renderMdError (mdError 3 (HeadingSkip 2 4))
        `shouldSatisfy` \t -> T.isInfixOf "##" t && T.isInfixOf "####" t

  -- STEP-11:SectionFieldMissing 的訊息帶節 id 與行號
  describe "SectionFieldMissing" $ do
    it "renderMdError 印出行號與節 id" $ do
      let msg = renderMdError (mdError 42 (SectionFieldMissing (idOf "lic-0000000a") "commercial"))
      msg `shouldSatisfy` T.isPrefixOf "第 42 行:"
      msg `shouldSatisfy` T.isInfixOf "lic-0000000a"
      msg `shouldSatisfy` T.isInfixOf "commercial"

    it "訊息說得出缺的是哪個欄位" $
      renderMdError (mdError 1 (SectionFieldMissing (idOf "ast-00000001") "type"))
        `shouldSatisfy` T.isInfixOf "type"

  describe "frontmatter 層級的錯誤只回一筆(不產生次生錯誤)" $ do
    it "沒有 frontmatter 時只回一筆" $
      leftKind (parseDocument "## 一 {#ent-000a}\n\n```meta\n壞: [\n```\n")
        `shouldBe` Just NoFrontmatter

    it "frontmatter 的 YAML 壞掉時只回一筆" $ do
      let src = T.unlines ["---", "id: ent-0001", "  壞掉的縮排: 值", "---", "", "## 一 {#ent-000a}"]
      case parseDocument src of
        Right _ -> expectationFailure "應該失敗"
        Left e -> case errKind e of
          FrontmatterYaml _ -> pure ()
          other -> expectationFailure ("預期 FrontmatterYaml,得到 " <> show other)

  describe "檔案層缺多個必填欄位時只回報第一個" $
    it "id 之外全缺時回報 vault(requiredFrontFields 的第一個)" $ do
      let src = T.unlines ["---", "id: ent-0001", "---", "", "## 一 {#ent-000a}", "", "```meta", "summary: 一", "```"]
      leftKind (toTopic (docOf src))
        `shouldBe` Just (RequiredFieldMissing "vault")
