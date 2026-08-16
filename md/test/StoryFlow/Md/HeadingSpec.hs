-- | T3:節標題 @{#id}@ 屬性語法。
module StoryFlow.Md.HeadingSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import StoryFlow.Md.Lexer (Heading (..), parseHeadingLine)
import Test.Hspec

kindsOf :: Either [MdError] a -> [MdErrorKind]
kindsOf = either (map errKind) (const [])

-- | 兩個節,第二個節的標題由呼叫端決定。
twoSections :: Text -> Text -> Text
twoSections first second =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: character"
    , "title: 測試"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , first
    , ""
    , "```meta"
    , "summary: 一"
    , "```"
    , ""
    , second
    , ""
    , "```meta"
    , "summary: 二"
    , "```"
    ]

spec :: Spec
spec = do
  describe "parseHeadingLine" $ do
    it "## 外貌 {#ent-7f3b} 得層級 2、標題「外貌」與 id ent-7f3b" $
      parseHeadingLine "## 外貌 {#ent-7f3b}\n"
        `shouldBe` Just (Heading 2 "外貌" (Just "ent-7f3b"))

    it "沒有 {#id} 的標題仍是標題,只是沒有 id" $
      parseHeadingLine "# 琳達\n" `shouldBe` Just (Heading 1 "琳達" Nothing)

    it "標題文字含 # 字元時不誤切" $
      parseHeadingLine "### C# 與 F# 的差異 {#ent-0001}\n"
        `shouldBe` Just (Heading 3 "C# 與 F# 的差異" (Just "ent-0001"))

    it "六級標題可辨識,七個 # 不是標題" $ do
      fmap hLevel (parseHeadingLine "###### 深 {#nod-0007}\n") `shouldBe` Just 6
      parseHeadingLine "####### 太深\n" `shouldBe` Nothing

    it "# 後面沒有空白不是標題" $
      parseHeadingLine "#標籤\n" `shouldBe` Nothing

    it "id 中間有空白時不當成 id" $
      parseHeadingLine "## 標題 {#ent 0001}\n"
        `shouldBe` Just (Heading 2 "標題 {#ent 0001}" Nothing)

  describe "id 的錯誤" $ do
    it "第一個節之後的標題缺 {#id} → HeadingWithoutId" $
      kindsOf (parseDocument "x.md" (twoSections "## 一 {#ent-000a}" "## 二"))
        `shouldBe` [HeadingWithoutId "二"]

    it "{#id} 不是合法 ID 時同樣是 HeadingWithoutId" $
      kindsOf (parseDocument "x.md" (twoSections "## 一 {#ent-000a}" "## 二 {#zzz-0001}"))
        `shouldBe` [HeadingWithoutId "二"]

    it "同一份檔案兩節同 id → DuplicateSectionId" $
      kindsOf (parseDocument "x.md" (twoSections "## 一 {#ent-000a}" "## 二 {#ent-000a}"))
        `shouldBe` [DuplicateSectionId (idOf "ent-000a")]

    it "Entity 檔的節用 {#nod-0001} → IdPrefixMismatch" $ do
      let doc = docOf "x.md" (twoSections "## 一 {#ent-000a}" "## 二 {#nod-0001}")
      kindsOf (parseEntityFile doc)
        `shouldBe` [IdPrefixMismatch (idOf "nod-0001") "ent"]

    it "Level 檔的節用 {#ent-0001} → IdPrefixMismatch" $ do
      let bad = T.replace "{#nod-0003}" "{#ent-0003}" classroomMd
          doc = docOf "levels/教室.md" bad
      kindsOf (parseLevelFile doc)
        `shouldBe` [IdPrefixMismatch (idOf "ent-0003") "nod"]

  describe "琳達範例檔的 id" $
    it "兩節的 id 分別是 ent-7f3b 與 ent-7f3c" $
      map secId (docSections (docOf "characters/琳達.md" lindaMd))
        `shouldBe` [idOf "ent-7f3b", idOf "ent-7f3c"]
