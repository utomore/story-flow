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

    it "原檔尾沒有換行時會先補上,新節不會黏在最後一行後面" $ do
      let d = docOf "x.md" (dropFinalNL lindaMd)
          new = mkSection LF 2 (idOf "ent-7f3d") "尾聲" Nothing ""
      case insertSection (Just (idOf "ent-7f3c")) new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d' `shouldSatisfy` T.isInfixOf "那年她十四歲……\n## 尾聲 {#ent-7f3d}"

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

-- | 取第 n 個片段的 Meta。
entMetaOf :: EntityFile -> Int -> Meta
entMetaOf ef n = entMeta (efFragments ef !! n)
