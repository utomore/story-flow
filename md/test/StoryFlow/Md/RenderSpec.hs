-- | T8:逐字寫回。位元組相等是結構上的保證(ADR-0010),
-- 這裡拿風格各異的十份檔案把它釘死。
module StoryFlow.Md.RenderSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import Test.Hspec

-- | frontmatter 有註解、縮排 4 空白、正文含程式碼區塊的檔案。
commentedMd :: Text
commentedMd =
  T.unlines
    [ "---"
    , "# 這份檔案的 frontmatter 有註解"
    , "id: ent-0001"
    , "vault: liftgame     # 行末註解"
    , "type: lore"
    , "title: 埃提亞崩塌"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "崩塌的概述。"
    , ""
    , "## 崩塌前 {#ent-000a}"
    , ""
    , "```meta"
    , "summary: 崩塌前的埃提亞"
    , "links:"
    , "    - {kind: partOf, target: ent-0001}"
    , "    - {kind: occursIn, target: ent-c41d}"
    , "```"
    , ""
    , "那時候的埃提亞……"
    , ""
    , "```haskell"
    , "-- 正文裡的程式碼區塊,不是 meta"
    , "main = pure ()"
    , "```"
    , ""
    ]

-- | preamble 為空(frontmatter 之後直接是第一個節)。
noPreambleMd :: Text
noPreambleMd =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 無序言"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , "## 第一節 {#ent-000a}"
    , ""
    , "```meta"
    , "summary: 緊接在 frontmatter 之後"
    , "```"
    ]

-- | 只有 frontmatter,沒有任何節。
frontOnlyMd :: Text
frontOnlyMd =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 還沒開始寫"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    ]

-- | 混合行尾:frontmatter 用 LF,正文用 CRLF。
mixedEndingMd :: Text
mixedEndingMd =
  T.intercalate
    "\n"
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: lore"
    , "title: 跨平台編輯過的檔案"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    ]
    <> "\n"
    <> crlf "\n## 一節 {#ent-000a}\n\n```meta\nsummary: 這一段是 CRLF\n```\n\n正文第一段。\n\n正文第二段。\n"

-- | 十份風格各異的測試檔。
samples :: [(String, Text)]
samples =
  [ ("琳達範例檔(LF、檔尾有換行)", lindaMd)
  , ("琳達範例檔(CRLF)", crlf lindaMd)
  , ("琳達範例檔(檔尾無換行)", dropFinalNL lindaMd)
  , ("教室 Level 檔(LF)", classroomMd)
  , ("教室 Level 檔(CRLF)", crlf classroomMd)
  , ("YAML 含註解、縮排 4 空白、正文含程式碼區塊", commentedMd)
  , ("同上的 CRLF 版", crlf commentedMd)
  , ("preamble 為空", noPreambleMd)
  , ("僅 frontmatter 無節", frontOnlyMd)
  , ("混合行尾(frontmatter LF、正文 CRLF)", mixedEndingMd)
  ]

spec :: Spec
spec = do
  describe "renderDocument . parseDocument == id(位元組相等)" $
    mapM_
      ( \(name, src) ->
          it name $
            renderDocument (docOf "sample.md" src) `shouldBe` src
      )
      samples

  describe "再解析一次仍相等(解析 → 寫回 → 再解析不失真)" $
    mapM_
      ( \(name, src) ->
          it name $
            renderDocument (docOf "sample.md" (renderDocument (docOf "sample.md" src)))
              `shouldBe` src
      )
      samples

  describe "切片的組成" $ do
    it "renderSection 是三段原始切片接起來" $ do
      let s = firstSection (docOf "characters/琳達.md" lindaMd)
      renderSection s
        `shouldBe` (secHeadingRaw s <> maybe "" id (secMetaRaw s) <> secBodyRaw s)

    it "docFinalNL 反映原檔是否以換行結尾" $ do
      docFinalNL (docOf "x.md" lindaMd) `shouldBe` True
      docFinalNL (docOf "x.md" (dropFinalNL lindaMd)) `shouldBe` False

    it "混合行尾檔的 docEnding 取多數,但寫回仍逐字保留兩種行尾" $ do
      let d = docOf "x.md" mixedEndingMd
      docEnding d `shouldBe` CRLF
      renderDocument d `shouldSatisfy` T.isInfixOf "updated: 2026-08-16\n---\n"
      renderDocument d `shouldSatisfy` T.isInfixOf "這一段是 CRLF\r\n"
