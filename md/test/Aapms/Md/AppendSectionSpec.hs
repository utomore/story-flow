-- | T12:'appendSection'(取代 @insertSection@)—— 插在最後一節之後,沒有節時
-- 插在最前面;1,693 節文件末尾追加一節時前面位元組不變(D4:測試內產生器合成)。
module Aapms.Md.AppendSectionSpec (spec) where

import qualified Data.Text as T
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
    , nsMeta = emptyOverride {moSummary = Just "她不信議會"}
    , nsBody = "\n她從不主動靠近議會。\n"
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
          new = NewSection (idOf "ent-000a") 2 "序" emptyOverride "\n開頭。\n"
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> map secTitle (docSections (docOf (renderDocument d'))) `shouldBe` ["序"]

    it "重複 id 回 DuplicateSectionId" $
      case appendSection newTopicSection {nsId = idOf "ent-7f3b"} doc of
        Left e -> errKind e `shouldBe` DuplicateSectionId (idOf "ent-7f3b")
        Right _ -> expectationFailure "應該回 Left"

    it "原檔尾沒有換行時會補到剛好隔一個空行,新節不會黏在最後一行後面" $ do
      let d = docOf (dropFinalNL lindaMd)
          new = newTopicSection {nsTitle = "尾聲", nsMeta = emptyOverride, nsBody = ""}
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' ->
          renderDocument d' `shouldSatisfy` T.isInfixOf "那年她十四歲……\n\n## 尾聲 {#ent-7f3d}"

  -- D4:1,693 節文件末尾追加一節,前面 1,693 節位元組不變(測試內產生器合成)
  describe "appendSection 對 1,693 節文件" $ do
    let src = synthPackMd 1693
        d = docOf src
        new =
          NewSection
            { nsId = idOf "ast-0000270f" -- 9999 十進位 = 0x270f,避開既有 1..1693 的 id
            , nsLevel = 2
            , nsTitle = "新增的 asset"
            , nsMeta = emptyOverride {moType = Just (typeOf "asset-image")}
            , nsBody = ""
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
    -- type,沒給 asset 專屬的 sha256/entry(那兩個不在 MetaOverride 能表達的
    -- 欄位裡),所以只驗證__結構__能再被 parseDocument 解回,不驗證 toPack
    it "結果能再被 parseDocument 解回,docKind 與節數正確" $
      case appendSection new d of
        Left e -> expectationFailure (T.unpack (renderMdError e))
        Right d' -> case parseDocument (renderDocument d') of
          Left e -> expectationFailure (T.unpack (renderMdError e))
          Right d'' -> do
            docKind d'' `shouldBe` PackDoc
            length (docSections d'') `shouldBe` 1694
