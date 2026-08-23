-- | T2:逐行切塊。
module Aapms.Md.LexerSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

-- | 取出解析錯誤的種類,方便斷言。
kindsOf :: Either [MdError] a -> [MdErrorKind]
kindsOf = either (map errKind) (const [])

linesOf :: Either [MdError] a -> [Int]
linesOf = either (map errLine) (const [])

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
    let doc = docOf "characters/琳達.md" lindaMd

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
      kindsOf (parseDocument "x.md" "# 標題\n內文\n") `shouldBe` [NoFrontmatter]

    it "空檔 → NoFrontmatter" $
      kindsOf (parseDocument "x.md" "") `shouldBe` [NoFrontmatter]

    it "只有開頭 --- → UnterminatedFrontmatter" $
      kindsOf (parseDocument "x.md" "---\nid: ent-0001\n") `shouldBe` [UnterminatedFrontmatter]

    it "frontmatter 層級的錯誤只回一筆,行號為 1" $
      linesOf (parseDocument "x.md" "---\nid: ent-0001\n") `shouldBe` [1]

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
      kindsOf (parseDocument "x.md" src) `shouldBe` [UnterminatedMetaBlock]
      linesOf (parseDocument "x.md" src) `shouldBe` [12]

    it "正文中的程式碼區塊不被誤判為 meta 區塊,也不被誤判為標題" $ do
      let doc = docOf "x.md" fencedBodyMd
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
      map secMetaRaw (docSections (docOf "x.md" src)) `shouldBe` [Nothing]
