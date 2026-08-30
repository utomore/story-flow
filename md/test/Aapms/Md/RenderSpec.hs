-- | STEP-8(舊編號,沿用):逐字寫回。位元組相等是結構上的保證(ADR-010),這裡拿
-- 風格各異的檔案把它釘死;STEP-2:純量欄位印出的是文字不是 newtype 的 derived
-- 'Show';STEP-7:'newDocument'(取代 @mkDocument@);STEP-15:四種文件的完整 roundtrip
-- (graph-core/F004)。
module Aapms.Md.RenderSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

-- | entity-graph-core/F005 STEP-1 的樣本:每一欄都有值的完整 'Meta'。
fullMeta :: Meta
fullMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = vaultOf "liftgame"
    , metaType = typeOf "character"
    , metaTitle = "琳達"
    , metaSummary = "埃提亞的第七織手"
    , metaTags = ["主角", "織手"]
    , metaStatus = Canon
    , metaTimeline = Just (Timeline (Just "埃提亞崩塌前") Nothing)
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks = [Link PartOf (refOf "ent-c41d") (Just "屬於埃提亞")]
    , metaSource = Human
    , metaRevision = Revision 3
    , metaCreated = day0
    , metaUpdated = day0
    }

-- | 空值也照樣輸出的樣本;metaTimeline 用 Nothing 代表完全沒有時間軸概念。
emptyishMeta :: Meta
emptyishMeta =
  fullMeta
    { metaSummary = ""
    , metaTags = []
    , metaTimeline = Nothing
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

-- | STEP-15:四種文件各一份風格各異的樣本 + 兩份原有的邊界情形。
samples :: [(String, Text)]
samples =
  [ ("琳達範例檔(LF、檔尾有換行,主題檔)", lindaMd)
  , ("琳達範例檔(CRLF)", crlf lindaMd)
  , ("琳達範例檔(檔尾無換行)", dropFinalNL lindaMd)
  , ("教室 Level 檔(LF)", classroomMd)
  , ("教室 Level 檔(CRLF)", crlf classroomMd)
  , ("pack.md(LF)", packMd)
  , ("pack.md(CRLF)", crlf packMd)
  , ("licenses.md(LF)", licensesMd)
  , ("licenses.md(CRLF)", crlf licensesMd)
  , ("YAML 含註解、縮排 4 空白、正文含程式碼區塊", commentedMd)
  , ("同上的 CRLF 版", crlf commentedMd)
  , ("preamble 為空", noPreambleMd)
  , ("僅 frontmatter 無節", frontOnlyMd)
  , ("混合行尾(frontmatter LF、正文 CRLF)", mixedEndingMd)
  ]

spec :: Spec
spec = do
  describe "STEP-15:renderDocument . parseDocument == id(位元組相等,四種文件)" $
    mapM_
      ( \(name, src) ->
          it name $
            renderDocument (docOf src) `shouldBe` src
      )
      samples

  describe "再解析一次仍相等(解析 → 寫回 → 再解析不失真)" $
    mapM_
      ( \(name, src) ->
          it name $
            renderDocument (docOf (renderDocument (docOf src)))
              `shouldBe` src
      )
      samples

  describe "切片的組成" $ do
    it "renderSection 是三段原始切片接起來" $ do
      let s = firstSection (docOf lindaMd)
      renderSection s
        `shouldBe` (secHeadingRaw s <> maybe "" id (secMetaRaw s) <> secBodyRaw s)

    it "docFinalNL 反映原檔是否以換行結尾" $ do
      docFinalNL (docOf lindaMd) `shouldBe` True
      docFinalNL (docOf (dropFinalNL lindaMd)) `shouldBe` False

    it "混合行尾檔的 docEnding 取多數,但寫回仍逐字保留兩種行尾" $ do
      let d = docOf mixedEndingMd
      docEnding d `shouldBe` CRLF
      renderDocument d `shouldSatisfy` T.isInfixOf "updated: 2026-08-16\n---\n"
      renderDocument d `shouldSatisfy` T.isInfixOf "這一段是 CRLF\r\n"

  -- entity-graph-core/F005 STEP-1:renderFrontmatter 依固定順序輸出且 newDocument 可被 parseDocument 讀回
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
      ls `shouldContain` ["timeline: null"]
      length ls `shouldBe` length frontmatterFieldOrder

    -- STEP-2:type / vault / revision 是純量文字,不是 TypeKey / VaultId / Revision 的 derived Show
    it "type / vault / revision 是純量文字,不是 newtype 的 derived Show" $ do
      let ls = T.lines (renderFrontmatter fullMeta LF)
      ls `shouldContain` ["type: character"]
      ls `shouldContain` ["vault: liftgame"]
      ls `shouldContain` ["revision: 3"]
      ls `shouldSatisfy` all (not . T.isInfixOf "TypeKey")
      ls `shouldSatisfy` all (not . T.isInfixOf "VaultId")
      ls `shouldSatisfy` all (not . T.isInfixOf "Revision ")

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

  -- STEP-7:newDocument(取代 mkDocument)
  describe "newDocument" $ do
    it "產出的文字經 parseDocument → toTopic 後 Meta 與輸入相等" $ do
      let out = renderDocument (newDocument TopicDoc fullMeta "# 琳達\n\n角色主體的概述。\n")
          (main, _) = topicOf (docOf out)
      entMeta main `shouldBe` fullMeta
      entBody main `shouldBe` "# 琳達\n\n角色主體的概述。"

    it "空值的 Meta 也 round-trip 得回來" $ do
      let out = renderDocument (newDocument TopicDoc emptyishMeta "正文。\n")
          (main, _) = topicOf (docOf out)
      entMeta main `shouldBe` emptyishMeta

    it "newDocument PackDoc meta body 建出的 Document,docKind 立即回 PackDoc" $
      docKind (newDocument PackDoc fullMeta "") `shouldBe` PackDoc

    it "renderDocument 產物能再被 parseDocument 解回、docKind 仍是 PackDoc" $ do
      let out = renderDocument (newDocument PackDoc fullMeta {metaType = typeOf "asset-pack"} "")
      docKind (docOf out) `shouldBe` PackDoc

    it "型別是 level 時 docKind 判為 LevelDoc" $ do
      let out = renderDocument (newDocument LevelDoc fullMeta {metaType = typeOf "level"} "")
      docKind (docOf out) `shouldBe` LevelDoc

    it "三段切片依 renderDocument 的重組規則填" $ do
      let d = newDocument TopicDoc emptyishMeta "正文。\n"
      docSections d `shouldBe` []
      renderDocument d `shouldSatisfy` T.isPrefixOf "---\nid: ent-7f3a\n"
      renderDocument d `shouldSatisfy` T.isSuffixOf "---\n\n正文。\n"

    it "一律固定用 LF,不受呼叫端影響(design.md:CRLF 情境走 updateFrontmatter/updateSection 編輯路徑)" $ do
      let d = newDocument TopicDoc emptyishMeta "正文。\n"
      docEnding d `shouldBe` LF
      renderDocument d `shouldSatisfy` T.isInfixOf "id: ent-7f3a\n"
      -- roundtrip 穩定
      let out = renderDocument d
      renderDocument (docOf out) `shouldBe` out
