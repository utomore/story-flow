-- | T8:逐字寫回。位元組相等是結構上的保證(ADR-0010),
-- 這裡拿風格各異的十份檔案把它釘死。
module StoryFlow.Md.RenderSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import Test.Hspec

-- | func-0005 T1 的樣本:每一欄都有值的完整 'Meta'。
fullMeta :: Meta
fullMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = "liftgame"
    , metaType = "character"
    , metaTitle = "琳達"
    , metaSummary = "埃提亞的第七織手"
    , metaTags = ["主角", "織手"]
    , metaStatus = Canon
    , metaTimeline = Timeline (Just "埃提亞崩塌前") Nothing
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks = [Link PartOf (refOf "ent-c41d") (Just "屬於埃提亞")]
    , metaSource = Human
    , metaRevision = 3
    , metaCreated = day0
    , metaUpdated = day0
    }

-- | 空值也照樣輸出的樣本。
emptyishMeta :: Meta
emptyishMeta =
  fullMeta
    { metaSummary = ""
    , metaTags = []
    , metaTimeline = emptyTimeline
    , metaAliases = []
    , metaLinks = []
    }

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

  -- func-0005 T1:renderFrontmatter 依固定順序輸出且 mkDocument 可被 parseDocument 讀回
  describe "renderFrontmatter" $ do
    it "欄位順序等於 frontmatterFieldOrder" $
      map (T.takeWhile (/= ':')) (T.lines (renderFrontmatter emptyishMeta LF))
        `shouldBe` frontmatterFieldOrder

    it "逐行輸出與預期一致" $
      T.lines (renderFrontmatter fullMeta LF)
        `shouldBe` [ "id: ent-7f3a"
                   , "type: character"
                   , "vault: liftgame"
                   , "title: 琳達"
                   , "summary: 埃提亞的第七織手"
                   , "tags: [主角, 織手]"
                   , "status: canon"
                   , "timeline: 埃提亞崩塌前"
                   , "aliases: [小琳, 第七織手]"
                   , "source: human"
                   , "revision: 3"
                   , "created: 2026-08-16"
                   , "updated: 2026-08-16"
                   , "links:"
                   , "  - {kind: partOf, target: ent-c41d, note: 屬於埃提亞}"
                   ]

    it "metaFieldOrder 去掉 kind 之後是 frontmatterFieldOrder 的子序列" $
      filter (`elem` frontmatterFieldOrder) metaFieldOrder
        `shouldBe` filter (`elem` metaFieldOrder) frontmatterFieldOrder

    it "空值照樣輸出 —— frontmatter 要自我說明有哪些欄位" $ do
      let ls = T.lines (renderFrontmatter emptyishMeta LF)
      ls `shouldContain` ["summary: \"\""]
      ls `shouldContain` ["tags: []"]
      ls `shouldContain` ["aliases: []"]
      ls `shouldContain` ["links: []"]
      length ls `shouldBe` length frontmatterFieldOrder

    it "含冒號 / 前導 - / 數字樣貌的 title 被正確加引號" $ do
      let titleLine m = case [l | l <- T.lines (renderFrontmatter m LF), "title:" `T.isPrefixOf` l] of
            (l : _) -> l
            [] -> "沒有 title 行"
      titleLine fullMeta {metaTitle = "第一章: 崩塌"} `shouldBe` "title: \"第一章: 崩塌\""
      titleLine fullMeta {metaTitle = "- 開場"} `shouldBe` "title: \"- 開場\""
      titleLine fullMeta {metaTitle = "2026"} `shouldBe` "title: \"2026\""
      titleLine fullMeta {metaTitle = "true"} `shouldBe` "title: \"true\""

    it "CRLF 文件產生 CRLF 的 frontmatter" $
      renderFrontmatter emptyishMeta CRLF `shouldSatisfy` T.isInfixOf "id: ent-7f3a\r\n"

    it "不含 --- 界線(那兩行由 renderDocument 重生)" $
      renderFrontmatter fullMeta LF `shouldSatisfy` (not . T.isInfixOf "---")

  describe "mkDocument" $ do
    it "產出的文字經 parseDocument → parseEntityFile 後 Meta 與輸入相等" $ do
      let out = renderDocument (mkDocument LF fullMeta "# 琳達\n\n角色主體的概述。\n")
          (ef, _) = entityFileOf (docOf "characters/琳達.md" out)
      entMeta (efMain ef) `shouldBe` fullMeta
      entBody (efMain ef) `shouldBe` "# 琳達\n\n角色主體的概述。"

    it "空值的 Meta 也 round-trip 得回來" $ do
      let out = renderDocument (mkDocument LF emptyishMeta "正文。\n")
          (ef, _) = entityFileOf (docOf "x.md" out)
      entMeta (efMain ef) `shouldBe` emptyishMeta

    it "型別是 level 時 documentKind 判為 Level" $ do
      let out = renderDocument (mkDocument LF fullMeta {metaType = "level"} "")
      documentKind (docOf "levels/x.md" out) `shouldBe` Right DocLevel

    it "三段切片依 renderDocument 的重組規則填" $ do
      let d = mkDocument LF emptyishMeta "正文。\n"
      docSections d `shouldBe` []
      renderDocument d `shouldSatisfy` T.isPrefixOf "---\nid: ent-7f3a\n"
      renderDocument d `shouldSatisfy` T.isSuffixOf "---\n\n正文。\n"

    it "CRLF 版整份都是 CRLF" $ do
      let out = renderDocument (mkDocument CRLF emptyishMeta "正文。\r\n")
      out `shouldSatisfy` (not . T.isInfixOf "\n\n")
      renderDocument (docOf "x.md" out) `shouldBe` out
