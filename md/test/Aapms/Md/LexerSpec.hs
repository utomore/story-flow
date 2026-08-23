-- | T2:逐行切塊;T5:'parseDocument' 只回報第一個錯誤(graph-core/F004)。
module Aapms.Md.LexerSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

metaRawOf :: Section -> Text
metaRawOf s = maybe (error "這一節應該要有 meta 區塊") id (secMetaRaw s)

-- | 正文裡有一段 Markdown 程式碼區塊,裡面同時放了假標題與假的 meta 圍籬。
fencedBodyMd :: Text
fencedBodyMd =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 測試"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "## 一節 {#ent-000a}"
    , ""
    , "```meta"
    , "summary: 真的 meta 區塊"
    , "```"
    , ""
    , "格式說明:"
    , ""
    , "````markdown"
    , "## 假標題 {#ent-000b}"
    , ""
    , "```meta"
    , "summary: 這只是範例"
    , "```"
    , "````"
    , ""
    , "結束"
    ]

spec :: Spec
spec = do
  describe "琳達範例檔的切塊" $ do
    let doc = docOf lindaMd

    it "frontmatter 切出 11 行內容(不含兩條 --- 界線)" $
      length (filter (not . T.null) (T.lines (docFrontRaw doc))) `shouldBe` 11

    it "preamble 收下 # 琳達 與它的概述(第一個帶 {#id} 的標題才開始分節)" $ do
      docPreamble doc `shouldSatisfy` T.isInfixOf "# 琳達"
      docPreamble doc `shouldSatisfy` T.isInfixOf "角色主體的概述寫在這裡。"

    it "切出 2 個 Section" $
      map secTitle (docSections doc) `shouldBe` ["外貌", "與塔主的過節"]

    it "secLine 是標題行在原檔的行號" $
      map secLine (docSections doc) `shouldBe` [19, 31]

    it "secMetaRaw 含前後 fence 行" $ do
      let raw = metaRawOf (firstSection doc)
      raw `shouldSatisfy` T.isInfixOf "```meta"
      T.count "```" raw `shouldBe` 2

    it "secBodyRaw 是 meta 區塊之後到下一個標題之前" $
      secBodyRaw (firstSection doc) `shouldSatisfy` T.isInfixOf "銀灰短髮剪到耳際"

  describe "frontmatter 的錯誤" $ do
    it "沒有 frontmatter → NoFrontmatter" $
      leftKind (parseDocument "# 標題\n內文\n") `shouldBe` Just NoFrontmatter

    it "空檔 → NoFrontmatter" $
      leftKind (parseDocument "") `shouldBe` Just NoFrontmatter

    it "只有開頭 --- → UnterminatedFrontmatter" $
      leftKind (parseDocument "---\nid: ent-0001\n") `shouldBe` Just UnterminatedFrontmatter

    it "frontmatter 層級的錯誤行號為 1" $
      leftLine (parseDocument "---\nid: ent-0001\n") `shouldBe` Just 1

  describe "meta 區塊" $ do
    it "```meta 未關閉 → UnterminatedMetaBlock,行號指向開頭 fence" $ do
      let src =
            T.unlines
              [ "---"
              , "id: ent-0001"
              , "vault: v"
              , "type: t"
              , "title: T"
              , "created: 2026-08-16"
              , "updated: 2026-08-16"
              , "---"
              , ""
              , "## 一節 {#ent-000a}"
              , ""
              , "```meta"
              , "summary: 沒有結尾"
              ]
      leftKind (parseDocument src) `shouldBe` Just UnterminatedMetaBlock
      leftLine (parseDocument src) `shouldBe` Just 12

    it "正文中的程式碼區塊不被誤判為 meta 區塊,也不被誤判為標題" $ do
      let doc = docOf fencedBodyMd
      map secTitle (docSections doc) `shouldBe` ["一節"]
      let raw = metaRawOf (firstSection doc)
      raw `shouldSatisfy` T.isInfixOf "真的 meta 區塊"
      raw `shouldSatisfy` (not . T.isInfixOf "這只是範例")
      secBodyRaw (firstSection doc) `shouldSatisfy` T.isInfixOf "假標題"

    it "沒有 meta 區塊的節,secMetaRaw 為 Nothing" $ do
      let src =
            T.unlines
              [ "---"
              , "id: ent-0001"
              , "vault: v"
              , "type: t"
              , "title: T"
              , "created: 2026-08-16"
              , "updated: 2026-08-16"
              , "---"
              , ""
              , "## 一節 {#ent-000a}"
              , ""
              , "只有正文"
              ]
      map secMetaRaw (docSections (docOf src)) `shouldBe` [Nothing]

  -- T5:兩個獨立的結構錯誤時,parseDocument 只回報行號最小的一個
  describe "單一錯誤契約" $ do
    it "標題缺 {#id}(第 5 行)與重複 id(第 10 行)同時存在時,回報第 5 行的那個" $ do
      let src =
            T.unlines
              [ "---" --  1
              , "id: ent-0001" --  2
              , "vault: liftgame" --  3
              , "type: lore" --  4
              , "title: T" --  5(frontmatter 尚未結束,行號只是註記用)
              , "created: 2026-08-16"
              , "updated: 2026-08-16"
              , "---" --  8
              , "" --  9
              , "## 一 {#ent-000a}" -- 10
              , "" -- 11
              , "```meta" -- 12
              , "summary: 一" -- 13
              , "```" -- 14
              , "" -- 15
              , "## 二" -- 16(缺 {#id})
              , "" -- 17
              , "```meta" -- 18
              , "summary: 二" -- 19
              , "```" -- 20
              , "" -- 21
              , "## 三 {#ent-000a}" -- 22(與第一節重複 id,晚於缺 id 的第 16 行)
              , "" -- 23
              , "```meta" -- 24
              , "summary: 三" -- 25
              , "```" -- 26
              ]
      leftKind (parseDocument src) `shouldBe` Just (HeadingWithoutId "二")
      leftLine (parseDocument src) `shouldBe` Just 16

    it "沒有 frontmatter 時只回一筆,不產生次生錯誤" $
      leftKind (parseDocument "## 一 {#ent-000a}\n\n```meta\n壞: [\n```\n")
        `shouldBe` Just NoFrontmatter

    it "frontmatter 的 YAML 壞掉時只回一筆" $ do
      let src = T.unlines ["---", "id: ent-0001", "  壞掉的縮排: 值", "---", "", "## 一 {#ent-000a}"]
      case parseDocument src of
        Right _ -> expectationFailure "應該失敗"
        Left e -> case errKind e of
          FrontmatterYaml _ -> pure ()
          other -> expectationFailure ("預期 FrontmatterYaml,得到 " <> show other)
