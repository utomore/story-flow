-- | STEP-9(舊編號,沿用):單節編輯與 meta 區塊序列化;STEP-2:'renderFrontmatter' /
-- 'renderMetaBlock' 印出的純量文字不是 newtype 的 derived 'Show'
-- (graph-core/F004)。
--
-- graph-core/F004__重跑__(GAP-2):'renderMetaBlock' 從 2 參數(@MetaOverride ->
-- LineEnding -> Text@)改成 3 參數(多吃一個 'MetaExtras')——本檔既有呼叫點
-- 一律補上 @(MetaExtras [])@(既有測試只關心 'Meta' 那一半,不影響原本的
-- 斷言)。新增 Example 1\/6\/7\/8(spec 對照見檔尾),都是純 hspec、不需要
-- hedgehog,因為 Example 是具體輸入輸出,不是全稱量詞。
--
-- 這一組測試守住 ADR-010 的第二條保證:__改一個欄位,git diff 只顯示那一行__,
-- 以及 GAP-2 修復後的新保證:__改 Meta 那一半,型別專屬那一半一個位元組都不動__。
module Aapms.Md.EditSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Asset (Asset (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Level (NodeKind (KCamera))
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf lindaMd

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
    , moType = Just (typeOf "character-fragment")
    , moVault = Just (vaultOf "liftgame")
    , moSummary = Just "一句話"
    , moTags = Just ["外觀", "主線"]
    , moStatus = Just Canon
    , moTimeline = Just (Timeline (Just "崩塌前") Nothing)
    , moAliases = Just ["小琳"]
    , moSource = Just (Agent "claude-code")
    , moRevision = Just (Revision 3)
    , moCreated = Just day0
    , moUpdated = Just day0
    , moLinks = Just [Link PartOf (refOf "ent-7f3a") (Just "屬於琳達")]
    }

-- Example 1(spec-gaps GAP-2 的直接回歸例)---------------------------------------
--
-- 逐字取自 F004 spec:pack.md 的 asset 節含 sha256 / entry,只改 summary,
-- 那兩行(與 toPack 讀回的值)必須不變。這是已重現缺陷(GAP-2)的否證。
e1PackMd :: Text
e1PackMd =
  T.unlines
    [ "---"
    , "id: pck-00000001"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: EX-1 pack"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "## a.png {#ast-00000001}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "sha256: deadbeef1234"
    , "entry: PNG/a.png"
    , "```"
    ]

-- Example 6:未知欄位(型別註冊表宣告的自訂欄位)也要保留 -----------------
e6Md :: Text
e6Md =
  T.unlines
    [ "---"
    , "id: ent-0001"
    , "vault: liftgame"
    , "type: character"
    , "title: EX-6"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "## 片段 {#ent-000a}"
    , ""
    , "```meta"
    , "summary: 一句話"
    , "battle_power: 9000"
    , "```"
    ]

-- Example 7:型別專屬半邊的編輯路徑(updateSectionExtras) -------------------
e7PackMd :: Text
e7PackMd =
  T.unlines
    [ "---"
    , "id: pck-00000002"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: EX-7 pack"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "## b.png {#ast-00000002}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "sha256: cafebabe0001"
    , "entry: PNG/b.png"
    , "license: lic-00000001"
    , "```"
    ]

-- Example 8:區塊風格巢狀值(meta: + 兩行縮排)------------------------------
e8Md :: Text
e8Md =
  T.unlines
    [ "---"
    , "id: pck-00000003"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: EX-8 pack"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    , ""
    , "## c.png {#ast-00000003}"
    , ""
    , "```meta"
    , "type: asset-image"
    , "sha256: 00112233"
    , "entry: PNG/c.png"
    , "meta:"
    , "  width: 256"
    , "  height: 192"
    , "```"
    ]

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
      let (_, frags) = topicOf (docOf edited)
      metaSummary (entMeta (frags !! 0)) `shouldBe` "銀灰短髮,左眼下方有新的織紋刺青"

    it "另一節完全沒被碰到" $ do
      let (_, frags) = topicOf (docOf edited)
      metaSummary (entMeta (frags !! 1)) `shouldBe` "十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"

    it "操作不存在的 id 回 Left" $
      case updateSection (idOf "ent-9999") id doc of
        Left e -> errKind e `shouldBe` UnknownSectionId (idOf "ent-9999")
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
          d = docOf src
      case updateSection (idOf "ent-000a") (\ov -> ov {moSummary = Just "補上的總結"}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "```meta\nsummary: 補上的總結\n```"
          out `shouldSatisfy` T.isInfixOf "正文。"
          -- 補完之後仍是合法文件
          fmap (length . docSections) (parseDocument out) `shouldBe` Right 1

    -- spec 對照:Example 1(spec-gaps GAP-2 的回歸例,務必逐字翻譯,不弱化)
    it "Example 1:pack.md asset 節改 summary 後,sha256/entry 兩行逐字保留、toPack 讀回不變" $ do
      let aid = idOf "ast-00000001"
          d = docOf e1PackMd
      case updateSection aid (\o -> o {moSummary = Just "after"}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "sha256: deadbeef1234"
          out `shouldSatisfy` T.isInfixOf "entry: PNG/a.png"
          let (_, assets) = packOf (docOf out)
          map astSha256 assets `shouldBe` [Sha256 "deadbeef1234"]
          map astEntry assets `shouldBe` ["PNG/a.png"]
          map (metaSummary . astMeta) assets `shouldBe` ["after"]

    -- spec 對照:Example 6(未知欄位也要保留,不只型別專屬那幾個)
    it "Example 6:註冊表自訂欄位 battle_power 在 updateSection 之後逐字保留" $ do
      let d = docOf e6Md
      case updateSection (idOf "ent-000a") (\o -> o {moStatus = Just Canon}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isInfixOf "battle_power: 9000"

    -- spec 對照:Example 8(多行頂層條目整段保留、順序不變)
    it "Example 8:區塊風格巢狀值(meta: + 兩行縮排)在 updateSection 之後逐字保留、順序不變" $ do
      let d = docOf e8Md
      case updateSection (idOf "ast-00000003") (\o -> o {moSummary = Just "x"}) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d'
            `shouldSatisfy` T.isInfixOf "meta:\n  width: 256\n  height: 192\n"

  -- graph-core/F004 重跑:型別專屬半邊的編輯路徑
  describe "updateSectionExtras" $ do
    -- spec 對照:Example 7
    it "Example 7:只換 license,sha256/entry 逐字不變,overrideAt 與正文/標題不受影響" $ do
      let aid = idOf "ast-00000002"
          d = docOf e7PackMd
          -- naKindMeta 借用「這份 fixture 本來就沒有 meta 欄位」時 toPack 解出的
          -- astKindMeta(等於「不寫這一欄」的值),不憑空杜撰 Data.Aeson.Value
          -- 的字面建構子——test-suite 目前沒有 aeson 相依(見回報)
          origKindMeta = case snd (packOf d) of
            (a : _) -> astKindMeta a
            [] -> error "e7PackMd 應該恰有一個 asset"
          na' =
            NewAsset
              { naName = Nothing
              , naSha256 = Sha256 "cafebabe0001"
              , naEntry = "PNG/b.png"
              , naExt = Nothing
              , naKindMeta = origKindMeta
              , naLicense = Just (refOf "lic-00000002")
              , naAuthor = Nothing
              }
          beforeOverride = overrideAt aid d
      case updateSectionExtras aid (mergeExtras (payloadExtras (NSAsset emptyOverride na'))) d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "sha256: cafebabe0001"
          out `shouldSatisfy` T.isInfixOf "entry: PNG/b.png"
          out `shouldSatisfy` T.isInfixOf "license: lic-00000002"
          out `shouldSatisfy` (not . T.isInfixOf "license: lic-00000001")
          overrideAt aid d' `shouldBe` beforeOverride
          let old = firstSection d
              new = firstSection d'
          secHeadingRaw new `shouldBe` secHeadingRaw old
          secBodyRaw new `shouldBe` secBodyRaw old

    it "操作不存在的 id 回 Left" $
      case updateSectionExtras (idOf "ast-99999999") id doc of
        Left e -> errKind e `shouldBe` UnknownSectionId (idOf "ast-99999999")
        Right _ -> expectationFailure "應該回 Left"

  describe "renderMetaBlock" $ do
    it "欄位順序固定,且與 system.md 的範例一致" $
      T.lines (renderMetaBlock fullOverride (MetaExtras []) LF)
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

    -- STEP-2:type / vault / revision 印出的是純量文字,不是 TypeKey / VaultId / Revision 的 derived Show
    it "type / vault / revision 是純量文字,不是 newtype 的 derived Show" $ do
      let ls = T.lines (renderMetaBlock fullOverride (MetaExtras []) LF)
      ls `shouldContain` ["type: character-fragment"]
      ls `shouldContain` ["vault: liftgame"]
      ls `shouldContain` ["revision: 3"]
      ls `shouldSatisfy` all (not . T.isInfixOf "TypeKey")
      ls `shouldSatisfy` all (not . T.isInfixOf "VaultId")
      ls `shouldSatisfy` all (not . T.isInfixOf "Revision ")

    it "值為 Nothing 的欄位不輸出" $
      T.lines (renderMetaBlock (emptyOverride {moSummary = Just "只有這一欄"}) (MetaExtras []) LF)
        `shouldBe` ["```meta", "summary: 只有這一欄", "```"]

    it "同一份資料連續序列化兩次結果相同" $
      renderMetaBlock fullOverride (MetaExtras []) LF `shouldBe` renderMetaBlock fullOverride (MetaExtras []) LF

    it "CRLF 文件產生 CRLF 的區塊" $
      renderMetaBlock (emptyOverride {moSummary = Just "x"}) (MetaExtras []) CRLF
        `shouldBe` "```meta\r\nsummary: x\r\n```\r\n"

    it "需要跳脫的字串才加引號" $ do
      T.lines (renderMetaBlock (emptyOverride {moSummary = Just "冒號: 後面有空白"}) (MetaExtras []) LF)
        `shouldBe` ["```meta", "summary: \"冒號: 後面有空白\"", "```"]
      T.lines (renderMetaBlock (emptyOverride {moType = Just (typeOf "true")}) (MetaExtras []) LF)
        `shouldBe` ["```meta", "type: \"true\"", "```"]

    it "流式上下文裡的逗號會被引號保護" $
      T.lines (renderMetaBlock (emptyOverride {moTags = Just ["a,b"]}) (MetaExtras []) LF)
        `shouldBe` ["```meta", "tags: [\"a,b\"]", "```"]

    it "序列化後再解析回來,欄位一致(round-trip)" $
      decodeMeta (T.unlines (init (drop 1 (T.lines (renderMetaBlock fullOverride (MetaExtras []) LF)))))
        `shouldBe` Right fullOverride

    -- graph-core/F004 重跑,GAP-2:型別專屬條目逐字接在 Meta 欄位之後
    it "MetaExtras 非空時,逐字接在 Meta 欄位之後、fence 之前" $
      T.lines (renderMetaBlock (emptyOverride {moSummary = Just "只有這一欄"}) (MetaExtras ["battle_power: 9000"]) LF)
        `shouldBe` ["```meta", "summary: 只有這一欄", "battle_power: 9000", "```"]

  describe "removeSection" $ do
    it "移除節連同它的 meta 區塊與正文" $
      case removeSection (idOf "ent-7f3b") doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` (not . T.isInfixOf "外貌")
          out `shouldSatisfy` (not . T.isInfixOf "銀灰短髮")
          out `shouldSatisfy` T.isInfixOf "與塔主的過節"
          map secTitle (docSections (docOf out)) `shouldBe` ["與塔主的過節"]

    it "移除不存在的 id 回 Left" $
      case removeSection (idOf "ent-9999") doc of
        Left e -> errKind e `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

  -- entity-graph-core/F005 STEP-2:updateFrontmatter 改標題後節層位元組不變
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
          let (main, frags) = topicOf (docOf (renderDocument d'))
          metaTitle (entMeta main) `shouldBe` "小琳"
          -- 片段的 title 來自節標題,不受檔案層改名影響
          map (metaTitle . entMeta) frags `shouldBe` ["外貌", "與塔主的過節"]

    it "id 也改得動 —— 這正是 MetaOverride 表達不了、非用 Meta -> Meta 不可的欄位" $
      case updateFrontmatter (\m -> m {metaId = idOf "ent-abcd"}) doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isInfixOf "id: ent-abcd"

    -- graph-core/F004:parseDocument 本身就要求 frontmatter YAML 可解(算 docKind
    -- 用),所以壞掉的 frontmatter 走不到 docOf 這一關——這裡直接用記錄更新造一份
    -- docFrontRaw 壞掉的 Document,單獨測 updateFrontmatter 自己的 Left 分支
    it "frontmatter YAML 壞掉時回 Left,不覆寫、d 本身不受影響(純函式)" $ do
      let brokenFront = T.replace "summary: 埃提亞" "summary: [沒收尾的流式序列" (docFrontRaw doc)
          d = doc {docFrontRaw = brokenFront}
      case updateFrontmatter (\m -> m {metaTitle = "不該被寫進去"}) d of
        Right _ -> expectationFailure "YAML 壞掉時應該回 Left"
        Left e -> case errKind e of
          FrontmatterYaml _ -> docFrontRaw d `shouldBe` brokenFront
          other -> expectationFailure ("預期 FrontmatterYaml,得到 " <> show other)

    it "CRLF 檔改寫後仍是 CRLF" $
      case updateFrontmatter (\m -> m {metaTitle = "小琳"}) (docOf (crlf lindaMd)) of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          out `shouldSatisfy` T.isInfixOf "---\r\nid: ent-7f3a\r\n"
          out `shouldSatisfy` T.isInfixOf "title: 小琳\r\n"

  -- entity-graph-core/F005 STEP-3、graph-core/F004 STEP-13:updateSectionBody(改名自 replaceSectionBody)
  describe "updateSectionBody" $ do
    it "目標節的 secBodyRaw 換掉,secHeadingRaw 與 secMetaRaw 逐字不變" $
      case updateSectionBody (idOf "ent-7f3b") "\n改過的正文。\n" doc of
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
      case updateSectionBody (idOf "ent-7f3b") "\n沒有結尾換行" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          renderDocument d' `shouldSatisfy` T.isInfixOf "沒有結尾換行\n## 與塔主的過節"
          map secTitle (docSections (docOf (renderDocument d')))
            `shouldBe` ["外貌", "與塔主的過節"]

    it "最後一節不補 —— 檔尾本來就可以沒有換行" $
      case updateSectionBody (idOf "ent-7f3c") "\n檔尾" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isSuffixOf "檔尾"

    it "改完仍可再被解析,entBody 是新值" $
      case updateSectionBody (idOf "ent-7f3b") "\n她把頭髮剪短了。\n" doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let (_, frags) = topicOf (docOf (renderDocument d'))
          map entBody frags
            `shouldBe` ["她把頭髮剪短了。", "那年她十四歲……"]

    it "指定不存在的 id 回 Left" $
      case updateSectionBody (idOf "ent-9999") "x" doc of
        Left e -> errKind e `shouldBe` UnknownSectionId (idOf "ent-9999")
        Right _ -> expectationFailure "應該回 Left"

  describe "replacePreamble" $ do
    it "只換主體正文,節一個位元組都沒動" $ do
      let d' = replacePreamble "# 琳達\n\n改過的概述。" doc
      docSections d' `shouldBe` docSections doc
      let (main, _) = topicOf (docOf (renderDocument d'))
      entBody main `shouldBe` "# 琳達\n\n改過的概述。"

    it "結尾界線的行尾被保留 —— 否則 --- 會與正文黏成一行" $ do
      let out = renderDocument (replacePreamble "新的概述。" doc)
      out `shouldSatisfy` T.isInfixOf "updated: 2026-08-16\n---\n\n新的概述。\n\n## 外貌"

    it "後面沒有節時不補多餘的空行" $ do
      let d = docOf (T.unlines ["---", "id: ent-0001", "vault: v", "type: lore", "title: T", "created: 2026-08-16", "updated: 2026-08-16", "---", "", "舊的。"])
      renderDocument (replacePreamble "新的。" d) `shouldSatisfy` T.isSuffixOf "---\n\n新的。\n"

    it "空正文時 preamble 只剩界線的行尾與一行空白" $ do
      let out = renderDocument (replacePreamble "" doc)
      out `shouldSatisfy` T.isInfixOf "---\n\n## 外貌 {#ent-7f3b}"

    it "CRLF 檔換完仍是 CRLF" $ do
      let out = renderDocument (replacePreamble "新的概述。" (docOf (crlf lindaMd)))
      out `shouldSatisfy` T.isInfixOf "---\r\n\r\n新的概述。\r\n\r\n## 外貌"

-- | 一節的三段原始切片。用來斷言「這一節一個位元組都沒動」。
slices :: Section -> (Text, Maybe Text, Text)
slices s = (secHeadingRaw s, secMetaRaw s, secBodyRaw s)

-- spec 對照(F004 重跑)-------------------------------------------------------
-- LAW-2  updateSection 保留未觸及節/其他節的位元組       -> Aapms.Md.EditLawsSpec(hedgehog,未接線)
-- LAW-3  updateSectionExtras 同 LAW-2 的保留條件             -> Aapms.Md.EditLawsSpec
-- LAW-8  updateSection 冪等                               -> Aapms.Md.EditLawsSpec
-- EX-1  pack.md asset 節改 summary,sha256/entry 不變     -> "Example 1" it
-- EX-6  未知欄位保留                                      -> "Example 6" it
-- EX-7  updateSectionExtras 型別專屬半邊編輯路徑          -> "Example 7" it
-- EX-8  多行頂層條目(meta: 巢狀值)整段保留               -> "Example 8" it
