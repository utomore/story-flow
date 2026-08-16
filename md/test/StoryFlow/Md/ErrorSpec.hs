-- | T10:錯誤與警告的渲染,以及「一次回報全部」的收集機制。
module StoryFlow.Md.ErrorSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import Test.Hspec

-- | 三個節的 meta 區塊各自壞掉,而且是彼此獨立的錯誤。
threeBadSections :: Text
threeBadSections =
  T.unlines
    [ "---" --  1
    , "id: ent-0001" --  2
    , "vault: liftgame" --  3
    , "type: lore" --  4
    , "title: 三個壞掉的節" --  5
    , "created: 2026-08-16" --  6
    , "updated: 2026-08-16" --  7
    , "---" --  8
    , "" --  9
    , "## 一 {#ent-000a}" -- 10
    , "" -- 11
    , "```meta" -- 12
    , "summary: 一" -- 13
    , "  壞掉的縮排: 值" -- 14
    , "```" -- 15
    , "" -- 16
    , "## 二 {#ent-000b}" -- 17
    , "" -- 18
    , "```meta" -- 19
    , "tags: [未關閉" -- 20
    , "```" -- 21
    , "" -- 22
    , "## 三 {#ent-000c}" -- 23
    , "" -- 24
    , "```meta" -- 25
    , "links: {kind: partOf" -- 26
    , "```" -- 27
    ]

spec :: Spec
spec = do
  describe "renderMdError 的格式" $ do
    it "輸出 檔案:行號: 訊息" $
      renderMdError (MdError "characters/琳達.md" 12 (MissingNodeKind (idOf "nod-0001")))
        `shouldSatisfy` T.isPrefixOf "characters/琳達.md:12: "

    it "每一種錯誤都有非空訊息" $
      map
        (T.length . renderMdError . MdError "x.md" 1)
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
        , UnknownSectionId (idOf "ent-0001")
        ]
        `shouldSatisfy` all (> 8)

    it "跳級的訊息說得出是哪兩個層級" $
      renderMdError (MdError "x.md" 3 (HeadingSkip 2 4))
        `shouldSatisfy` \t -> T.isInfixOf "##" t && T.isInfixOf "####" t

  describe "多錯誤一次回報" $ do
    it "三個獨立的節錯誤一次回報三筆" $
      case parseEntityFile (docOf "x.md" threeBadSections) of
        Right _ -> expectationFailure "這份檔案應該解析失敗"
        Left es -> length es `shouldBe` 3

    it "三筆錯誤的節 id 各自正確" $
      case parseEntityFile (docOf "x.md" threeBadSections) of
        Right _ -> expectationFailure "這份檔案應該解析失敗"
        Left es ->
          [i | MdError _ _ (SectionYaml i _) <- es]
            `shouldBe` map idOf ["ent-000a", "ent-000b", "ent-000c"]

    it "三筆錯誤的行號各自落在自己的 meta 區塊內" $
      case parseEntityFile (docOf "x.md" threeBadSections) of
        Right _ -> expectationFailure "這份檔案應該解析失敗"
        Left es -> do
          let ls = map errLine es
          zip ls [(13, 15), (20, 21), (26, 27)]
            `shouldSatisfy` all (\(l, (lo, hi)) -> l >= lo && l <= hi)

    it "檔案層缺多個必填欄位時一次列完" $ do
      let src = T.unlines ["---", "id: ent-0001", "---", "", "內文"]
      case parseEntityFile (docOf "x.md" src) of
        Right _ -> expectationFailure "應該回報缺欄位"
        Left es ->
          [f | MdError _ _ (RequiredFieldMissing f) <- es]
            `shouldBe` ["vault", "type", "title", "created", "updated"]

  describe "frontmatter 層級的錯誤中止解析" $ do
    it "沒有 frontmatter 時只回一筆,不產生次生錯誤" $
      case parseDocument "x.md" "## 一 {#ent-000a}\n\n```meta\n壞: [\n```\n" of
        Right _ -> expectationFailure "應該失敗"
        Left es -> map errKind es `shouldBe` [NoFrontmatter]

    it "frontmatter 的 YAML 壞掉時只回一筆" $ do
      let src = T.unlines ["---", "id: ent-0001", "  壞掉的縮排: 值", "---", "", "## 一 {#ent-000a}"]
      case parseEntityFile (docOf "x.md" src) of
        Right _ -> expectationFailure "應該失敗"
        Left es -> length es `shouldBe` 1

  describe "警告" $ do
    it "CustomLinkKind 帶 suggestCoreKind 的建議" $ do
      let w = renderMdWarning (CustomLinkKind (idOf "ent-0001") "矛盾於")
      w `shouldSatisfy` T.isInfixOf "矛盾於"
      w `shouldSatisfy` T.isInfixOf "contradicts"

    it "沒有相似核心關聯時就不給建議" $
      renderMdWarning (CustomLinkKind (idOf "ent-0001") "宿敵")
        `shouldSatisfy` (not . T.isInfixOf "是否想寫")

    it "MissingSummary 與 EmptyBody 的訊息都指出是哪一節" $ do
      renderMdWarning (MissingSummary (idOf "ent-0001")) `shouldSatisfy` T.isInfixOf "ent-0001"
      renderMdWarning (EmptyBody (idOf "ent-0001")) `shouldSatisfy` T.isInfixOf "ent-0001"

    it "缺 summary 與空正文的節會產生兩筆警告" $ do
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
              , "## 一 {#ent-000a}"
              , ""
              , "```meta"
              , "tags: [x]"
              , "```"
              ]
      snd (entityFileOf (docOf "x.md" src))
        `shouldBe` [MissingSummary (idOf "ent-000a"), EmptyBody (idOf "ent-000a")]

    it "自訂關聯在真實解析流程中也會產生警告" $ do
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
              , "## 一 {#ent-000a}"
              , ""
              , "```meta"
              , "summary: 有寫"
              , "links:"
              , "  - {kind: 師承於, target: ent-0002}"
              , "```"
              , ""
              , "正文"
              ]
      snd (entityFileOf (docOf "x.md" src))
        `shouldBe` [CustomLinkKind (idOf "ent-000a") "師承於"]
