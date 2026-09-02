-- | STEP-12:'appendSection'(取代 @insertSection@)—— 插在最後一節之後,沒有節時
-- 插在最前面;1,693 節文件末尾追加一節時前面位元組不變(DEC-4:測試內產生器合成)。
--
-- graph-core/F004__重跑__(GAP-1):'NewSection' 的 @nsMeta :: MetaOverride@ 改成
-- @nsPayload :: NewSectionPayload@(對節點種類做 sum,'NSFragment' \/ 'NSAsset'
-- \/ 'NSLicense' \/ 'NSNode'),欄位順序也變成
-- @nsId nsLevel nsTitle nsBody nsPayload@——本檔既有的建構呼叫點一律改寫,
-- 主題檔片段一律包一層 'NSFragment'。新增 Example 2(spec 對照見檔尾)。
module Aapms.Md.AppendSectionSpec (spec) where

import qualified Data.Text as T
import Aapms.Core.Asset (Sha256 (..))
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf lindaMd

newTopicSection :: NewSection
newTopicSection =
  NewSection
    { nsId = idOf "ent-7f3d"
    , nsLevel = 2
    , nsTitle = "與議會的距離"
    , nsBody = "\n她從不主動靠近議會。\n"
    , nsPayload = NSFragment (emptyOverride {moSummary = Just "她不信議會"})
    }

-- Example 2:空 pack.md 追加一個 asset 節 -------------------------------------
e2PackMd :: T.Text
e2PackMd =
  T.unlines
    [ "---"
    , "id: pck-0000000e"
    , "vault: liftgame-assets"
    , "type: asset-pack"
    , "title: EX-2 pack"
    , "created: 2026-08-16"
    , "updated: 2026-08-16"
    , "---"
    ]

e2Asset :: NewAsset
e2Asset =
  NewAsset
    { naName = Nothing
    , naSha256 = Sha256 "11223344"
    , naEntry = "PNG/icon.png"
    , naExt = Nothing
    , -- 「不寫這一欄」的 Value,借 Aapms.Md.Yaml.decodeValue(已由 Aapms.Md 匯出)
      -- 產生,不憑空杜撰 Data.Aeson.Value 的字面建構子——test-suite 目前沒有
      -- aeson 相依(見回報)
      naKindMeta = either (error . show) id (decodeValue "null")
    , naLicense = Nothing
    , naAuthor = Nothing
    }

e2NewSection :: NewSection
e2NewSection =
  NewSection
    { nsId = idOf "ast-0000000f"
    , nsLevel = 2
    , nsTitle = "圖示"
    , nsBody = ""
    , nsPayload = NSAsset (emptyOverride {moType = Just (typeOf "asset-image")}) e2Asset
    }

spec :: Spec
spec = do
  describe "appendSection 一般情形" $ do
    it "插在最後一節之後,插完可再被 parseDocument 解析" $
      case appendSection newTopicSection doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          let out = renderDocument d'
          map secTitle (docSections (docOf out))
            `shouldBe` ["外貌", "與塔主的過節", "與議會的距離"]
          out `shouldSatisfy` T.isInfixOf "## 與議會的距離 {#ent-7f3d}"

    it "前面既有的節逐字不變" $
      case appendSection newTopicSection doc of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> docSections d' !! 0 `shouldBe` docSections doc !! 0

    it "沒有任何節時插在最前面(preamble 之後)" $ do
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
              , "只有 preamble,還沒有任何節。"
              ]
          d = docOf src
          new = NewSection (idOf "ent-000a") 2 "序" "\n開頭。\n" (NSFragment emptyOverride)
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> map secTitle (docSections (docOf (renderDocument d'))) `shouldBe` ["序"]

    it "重複 id 回 DuplicateSectionId" $
      case appendSection newTopicSection {nsId = idOf "ent-7f3b"} doc of
        Left e -> errKind e `shouldBe` DuplicateSectionId (idOf "ent-7f3b")
        Right _ -> expectationFailure "應該回 Left"

    it "原檔尾沒有換行時會補到剛好隔一個空行,新節不會黏在最後一行後面" $ do
      let d = docOf (dropFinalNL lindaMd)
          new = newTopicSection {nsTitle = "尾聲", nsBody = "", nsPayload = NSFragment emptyOverride}
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d' `shouldSatisfy` T.isInfixOf "那年她十四歲……\n\n## 尾聲 {#ent-7f3d}"

    -- spec 對照:Example 2
    it "Example 2:空 pack.md 追加一個 asset 節,能再被 toPack 解回,長度為 1" $ do
      let d = docOf e2PackMd
      case appendSection e2NewSection d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          length (docSections d') `shouldBe` 1
          case parseDocument (renderDocument d') >>= toPack of
            Left e -> expectationFailure (T.unpack (renderMdError e))
            Right (_, assets) -> length assets `shouldBe` 1

  -- DEC-4:1,693 節文件末尾追加一節,前面 1,693 節位元組不變(測試內產生器合成)
  describe "appendSection 對 1,693 節文件" $ do
    let src = synthPackMd 1693
        d = docOf src
        new =
          NewSection
            { nsId = idOf "ast-0000270f" -- 9999 十進位 = 0x270f,避開既有 1..1693 的 id
            , nsLevel = 2
            , nsTitle = "新增的 asset"
            , nsBody = ""
            , nsPayload = NSFragment (emptyOverride {moType = Just (typeOf "asset-image")})
            }

    it "docSections 數量從 1,693 變成 1,694" $
      length (docSections d) `shouldBe` 1693

    it "追加後前面 1,693 節逐位元組不變、新節在最後" $
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> do
          length (docSections d') `shouldBe` 1694
          -- synthPackMd 每節後已隔兩個空行,appendSection 的 blankTail 補齊
          -- 分隔空行時是 no-op,前面 1,693 節因此逐位元組(含 secBodyRaw)不變
          take 1693 (docSections d') `shouldBe` docSections d
          secTitle (docSections d' !! 1693) `shouldBe` "新增的 asset"

    it "前面文字位元組完全不變(原文件文字整段是結果的前綴)" $
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> renderDocument d' `shouldSatisfy` T.isPrefixOf src

    -- appendSection 不驗證節的業務欄位是否齊全(見 Render.hs 的 haddock:
    -- 樹狀/欄位合法性是呼叫端與 aapms-core 的事);這裡的 NewSection 只給了
    -- type,沒給 asset 專屬的 sha256/entry(那兩個現在走 NSAsset 才有,
    -- NSFragment 沒有),所以只驗證__結構__能再被 parseDocument 解回,不驗證 toPack
    it "結果能再被 parseDocument 解回,docKind 與節數正確" $
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> case parseDocument (renderDocument d') of
          Left e -> expectationFailure (T.unpack (renderMdError e))
          Right d'' -> do
            docKind d'' `shouldBe` PackDoc
            length (docSections d'') `shouldBe` 1694

-- spec 對照(F004 重跑)-------------------------------------------------------
-- LAW-17 appendSection 保留既有節位元組、新節排最後      -> Aapms.Md.NewSectionLawsSpec(hedgehog,未接線)
-- LAW-18 appendSection 撞號回 DuplicateSectionId         -> "重複 id 回 DuplicateSectionId" it(既有,已涵蓋)
-- EX-2  空 pack.md 追加 asset 節                        -> "Example 2" it
-- EX-5  1,693 節文件追加第 1,694 節                     -> "appendSection 對 1,693 節文件" describe(既有)
-- EX-9  nsId 撞號                                       -> "重複 id 回 DuplicateSectionId" it(既有)
