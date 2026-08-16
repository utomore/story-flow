-- | T9:單節編輯與 meta 區塊序列化。
--
-- 這一組測試守住 ADR-0010 的第二條保證:__改一個欄位,git diff 只顯示那一行__。
module StoryFlow.Md.EditSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Level (NodeKind (KCamera))
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf "characters/琳達.md" lindaMd

-- | 兩份文字逐行比對,回傳不同的 (原行, 新行)。
diffLines :: Text -> Text -> [(Text, Text)]
diffLines a b = [p | p@(x, y) <- zip (T.lines a) (T.lines b), x /= y]

edited :: Text
edited = case updateSection (idOf "ent-7f3b") (\ov -> ov {moSummary = Just "銀灰短髮,左眼下方有新的織紋刺青"}) doc of
  Right d -> renderDocument d
  Left e -> error (T.unpack (renderMdError e))

fullOverride :: MetaOverride
fullOverride =
  emptyOverride
    { moKind = Just KCamera
    , moType = Just "character-fragment"
    , moVault = Just "liftgame"
    , moSummary = Just "一句話"
    , moTags = Just ["外觀", "主線"]
    , moStatus = Just Canon
    , moTimeline = Just (Timeline (Just "崩塌前") Nothing)
    , moAliases = Just ["小琳"]
    , moSource = Just (Agent "claude-code")
    , moRevision = Just 3
    , moCreated = Just day0
    , moUpdated = Just day0
    , moLinks = Just [Link PartOf (refOf "ent-7f3a") (Just "屬於琳達")]
    }

spec :: Spec
spec = do
  describe "updateSection" $ do
    it "改 ent-7f3b 的 summary 後,逐行比對只有該節 meta 區塊的 summary 那一行不同" $ do
      diffLines lindaMd edited
        `shouldBe` [ ( "summary: 銀灰短髮,左眼下方有織紋刺青"
                     , "summary: 銀灰短髮,左眼下方有新的織紋刺青"
                     )
                   ]

    it "行數不變(沒有多寫或漏寫欄位)" $
      length (T.lines edited) `shouldBe` length (T.lines lindaMd)

    it "改完仍可再被 parseDocument 解析,且新值讀得回來" $ do
      let (ef, _) = entityFileOf (docOf "characters/琳達.md" edited)
      metaSummary (entMetaOf ef 0) `shouldBe` "銀灰短髮,左眼下方有新的織紋刺青"

    it "另一節完全沒被碰到" $ do
      let (ef, _) = entityFileOf (docOf "characters/琳達.md" edited)
      metaSummary (entMetaOf ef 1) `shouldBe` "十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"

    it "操作不存在的 id 回 Left" $
      case updateSection (idOf "ent-9999") id doc of
        Left (MdError _ _ k) -> k `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

    it "原本沒有 meta 區塊的節會補上一個" $ do
      let src =
            T.unlines
              [ "---"
              , "id: ent-0001"
              , "vault: liftgame"
              , "type: lore"
              , "title: T"
              , "created: 2026-08-16"
              , "updated: 2026-08-16"
              , "---"
              , ""
              , "## 一節 {#ent-000a}"
              , ""
              , "正文。"
              ]
          d = docOf "x.md" src
      case updateSection (idOf "ent-000a") (\ov -> ov {moSummary = Just "補上的總結"}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "```meta\nsummary: 補上的總結\n```"
          out `shouldSatisfy` T.isInfixOf "正文。"
          -- 補完之後仍是合法文件
          fmap (length . docSections) (parseDocument "x.md" out) `shouldBe` Right 1

  describe "renderMetaBlock" $ do
    it "欄位順序固定,且與 architecture.md 的範例一致" $
      T.lines (renderMetaBlock fullOverride LF)
        `shouldBe` [ "```meta"
                   , "kind: camera"
                   , "type: character-fragment"
                   , "vault: liftgame"
                   , "summary: 一句話"
                   , "tags: [外觀, 主線]"
                   , "status: canon"
                   , "timeline: 崩塌前"
                   , "aliases: [小琳]"
                   , "source: agent:claude-code"
                   , "revision: 3"
                   , "created: 2026-08-16"
                   , "updated: 2026-08-16"
                   , "links:"
                   , "  - {kind: partOf, target: ent-7f3a, note: 屬於琳達}"
                   , "```"
                   ]

    it "值為 Nothing 的欄位不輸出" $
      T.lines (renderMetaBlock (emptyOverride {moSummary = Just "只有這一欄"}) LF)
        `shouldBe` ["```meta", "summary: 只有這一欄", "```"]

    it "同一份資料連續序列化兩次結果相同" $
      renderMetaBlock fullOverride LF `shouldBe` renderMetaBlock fullOverride LF

    it "CRLF 文件產生 CRLF 的區塊" $
      renderMetaBlock (emptyOverride {moSummary = Just "x"}) CRLF
        `shouldBe` "```meta\r\nsummary: x\r\n```\r\n"

    it "需要跳脫的字串才加引號" $ do
      T.lines (renderMetaBlock (emptyOverride {moSummary = Just "冒號: 後面有空白"}) LF)
        `shouldBe` ["```meta", "summary: \"冒號: 後面有空白\"", "```"]
      T.lines (renderMetaBlock (emptyOverride {moType = Just "true"}) LF)
        `shouldBe` ["```meta", "type: \"true\"", "```"]

    it "流式上下文裡的逗號會被引號保護" $
      T.lines (renderMetaBlock (emptyOverride {moTags = Just ["a,b"]}) LF)
        `shouldBe` ["```meta", "tags: [\"a,b\"]", "```"]

    it "序列化後再解析回來,欄位一致(round-trip)" $
      decodeMeta (T.unlines (init (drop 1 (T.lines (renderMetaBlock fullOverride LF)))))
        `shouldBe` Right fullOverride

  describe "insertSection" $ do
    it "在指定節之後插入,插完可再被 parseDocument 解析" $ do
      let new =
            mkSection
              LF
              2
              (idOf "ent-7f3d")
              "與議會的距離"
              (Just (emptyOverride {moSummary = Just "她不信議會"}))
              "\n她從不主動靠近議會。\n"
      case insertSection (Just (idOf "ent-7f3b")) new doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          map secTitle (docSections (docOf "x.md" out))
            `shouldBe` ["外貌", "與議會的距離", "與塔主的過節"]
          out `shouldSatisfy` T.isInfixOf "## 與議會的距離 {#ent-7f3d}"

    it "Nothing 表示插在最前面" $ do
      let new = mkSection LF 2 (idOf "ent-7f3d") "序" Nothing "\n開頭。\n"
      case insertSection Nothing new doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          map secTitle (docSections (docOf "x.md" (renderDocument d')))
            `shouldBe` ["序", "外貌", "與塔主的過節"]

    it "指定不存在的 id 回 Left" $ do
      let new = mkSection LF 2 (idOf "ent-7f3d") "序" Nothing ""
      case insertSection (Just (idOf "ent-9999")) new doc of
        Left (MdError _ _ k) -> k `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

    it "原檔尾沒有換行時會補到剛好隔一個空行,新節不會黏在最後一行後面" $ do
      let d = docOf "x.md" (dropFinalNL lindaMd)
          new = mkSection LF 2 (idOf "ent-7f3d") "尾聲" Nothing ""
      case insertSection (Just (idOf "ent-7f3c")) new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d' `shouldSatisfy` T.isInfixOf "那年她十四歲……\n\n## 尾聲 {#ent-7f3d}"

    it "原檔尾已經有一個空行時不再多補" $ do
      let d = docOf "x.md" (lindaMd <> "\n")
          new = mkSection LF 2 (idOf "ent-7f3d") "尾聲" Nothing ""
      case insertSection (Just (idOf "ent-7f3c")) new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d' `shouldSatisfy` T.isInfixOf "那年她十四歲……\n\n## 尾聲 {#ent-7f3d}"

  describe "removeSection" $ do
    it "移除節連同它的 meta 區塊與正文" $
      case removeSection (idOf "ent-7f3b") doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` (not . T.isInfixOf "外貌")
          out `shouldSatisfy` (not . T.isInfixOf "銀灰短髮")
          out `shouldSatisfy` T.isInfixOf "與塔主的過節"
          map secTitle (docSections (docOf "x.md" out)) `shouldBe` ["與塔主的過節"]

    it "移除不存在的 id 回 Left" $
      case removeSection (idOf "ent-9999") doc of
        Left (MdError _ _ k) -> k `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

  -- func-0005 T2:updateFrontmatter 改標題後節層位元組不變
  describe "updateFrontmatter" $ do
    it "改 metaTitle 後,每一節的三段切片逐字不變" $
      case updateFrontmatter (\m -> m {metaTitle = "琳達(改名)"}) doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          map slices (docSections d') `shouldBe` map slices (docSections doc)
          renderDocument d' `shouldSatisfy` T.isInfixOf "title: 琳達(改名)"

    it "只有 frontmatter 那一段改變,節與 preamble 一個位元組都沒動" $
      case updateFrontmatter (\m -> m {metaSummary = "新的一句話"}) doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          docPreamble d' `shouldBe` docPreamble doc
          docSections d' `shouldBe` docSections doc
          snd (T.breakOn "# 琳達" (renderDocument d'))
            `shouldBe` snd (T.breakOn "# 琳達" lindaMd)

    it "改完仍可再被 parseDocument 解析,新值讀得回來" $
      case updateFrontmatter (\m -> m {metaTitle = "小琳"}) doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let (ef, _) = entityFileOf (docOf "characters/琳達.md" (renderDocument d'))
          metaTitle (entMeta (efMain ef)) `shouldBe` "小琳"
          -- 片段的 title 來自節標題,不受檔案層改名影響
          map (metaTitle . entMeta) (efFragments ef) `shouldBe` ["外貌", "與塔主的過節"]

    it "id 也改得動 —— 這正是 MetaOverride 表達不了、非用 Meta -> Meta 不可的欄位" $
      case updateFrontmatter (\m -> m {metaId = idOf "ent-abcd"}) doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isInfixOf "id: ent-abcd"

    it "frontmatter YAML 壞掉時回 Left,且 renderDocument 結果與原檔相同" $ do
      let broken = T.replace "summary: 埃提亞" "summary: [沒收尾的流式序列" lindaMd
          d = docOf "x.md" broken
      case updateFrontmatter (\m -> m {metaTitle = "不該被寫進去"}) d of
        Right _ -> expectationFailure "YAML 壞掉時應該回 Left"
        Left (MdError _ _ k) -> case k of
          FrontmatterYaml _ -> renderDocument d `shouldBe` broken
          other -> expectationFailure ("預期 FrontmatterYaml,得到 " <> show other)

    it "CRLF 檔改寫後仍是 CRLF" $
      case updateFrontmatter (\m -> m {metaTitle = "小琳"}) (docOf "x.md" (crlf lindaMd)) of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "---\r\nid: ent-7f3a\r\n"
          out `shouldSatisfy` T.isInfixOf "title: 小琳\r\n"

  -- func-0005 T3:replaceSectionBody 只動目標節的正文
  describe "replaceSectionBody" $ do
    it "目標節的 secBodyRaw 換掉,secHeadingRaw 與 secMetaRaw 逐字不變" $
      case replaceSectionBody (idOf "ent-7f3b") "\n改過的正文。\n" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let old = docSections doc !! 0
              new = docSections d' !! 0
          secHeadingRaw new `shouldBe` secHeadingRaw old
          secMetaRaw new `shouldBe` secMetaRaw old
          secBodyRaw new `shouldBe` "\n改過的正文。\n"
          -- 另一節整個沒被碰到
          docSections d' !! 1 `shouldBe` docSections doc !! 1

    it "新正文不以行尾結尾時自動補,下一節的標題不黏連" $
      case replaceSectionBody (idOf "ent-7f3b") "\n沒有結尾換行" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          renderDocument d' `shouldSatisfy` T.isInfixOf "沒有結尾換行\n## 與塔主的過節"
          map secTitle (docSections (docOf "x.md" (renderDocument d')))
            `shouldBe` ["外貌", "與塔主的過節"]

    it "最後一節不補 —— 檔尾本來就可以沒有換行" $
      case replaceSectionBody (idOf "ent-7f3c") "\n檔尾" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isSuffixOf "檔尾"

    it "改完仍可再被解析,entBody 是新值" $
      case replaceSectionBody (idOf "ent-7f3b") "\n她把頭髮剪短了。\n" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let (ef, _) = entityFileOf (docOf "x.md" (renderDocument d'))
          map entBody (efFragments ef)
            `shouldBe` ["她把頭髮剪短了。", "那年她十四歲……"]

    it "指定不存在的 id 回 Left" $
      case replaceSectionBody (idOf "ent-9999") "x" doc of
        Left (MdError _ _ k) -> k `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

  describe "replacePreamble" $ do
    it "只換主體正文,節一個位元組都沒動" $ do
      let d' = replacePreamble "# 琳達\n\n改過的概述。" doc
      docSections d' `shouldBe` docSections doc
      let (ef, _) = entityFileOf (docOf "x.md" (renderDocument d'))
      entBody (efMain ef) `shouldBe` "# 琳達\n\n改過的概述。"

    it "結尾界線的行尾被保留 —— 否則 --- 會與正文黏成一行" $ do
      let out = renderDocument (replacePreamble "新的概述。" doc)
      out `shouldSatisfy` T.isInfixOf "updated: 2026-08-16\n---\n\n新的概述。\n\n## 外貌"

    it "後面沒有節時不補多餘的空行" $ do
      let d = docOf "x.md" (T.unlines ["---", "id: ent-0001", "vault: v", "type: lore", "title: T", "created: 2026-08-16", "updated: 2026-08-16", "---", "", "舊的。"])
      renderDocument (replacePreamble "新的。" d) `shouldSatisfy` T.isSuffixOf "---\n\n新的。\n"

    it "空正文時 preamble 只剩界線的行尾與一行空白" $ do
      let out = renderDocument (replacePreamble "" doc)
      out `shouldSatisfy` T.isInfixOf "---\n\n## 外貌 {#ent-7f3b}"

    it "CRLF 檔換完仍是 CRLF" $ do
      let out = renderDocument (replacePreamble "新的概述。" (docOf "x.md" (crlf lindaMd)))
      out `shouldSatisfy` T.isInfixOf "---\r\n\r\n新的概述。\r\n\r\n## 外貌"

-- | 取第 n 個片段的 Meta。
entMetaOf :: EntityFile -> Int -> Meta
entMetaOf ef n = entMeta (efFragments ef !! n)

-- | 一節的三段原始切片。用來斷言「這一節一個位元組都沒動」。
slices :: Section -> (Text, Maybe Text, Text)
slices s = (secHeadingRaw s, secMetaRaw s, secBodyRaw s)
