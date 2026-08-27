-- | T4:HsYAML → aeson 'Value' → core 的 @FromJSON@。
module Aapms.Md.YamlSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Ref (..))
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

-- | 琳達第二節的 meta 區塊內容(不含 fence)。
lindaFragmentYaml :: Text
lindaFragmentYaml =
  T.unlines
    [ "type: character-fragment"
    , "summary: 十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"
    , "tags: [動機, 仇恨]"
    , "timeline: 埃提亞崩塌前"
    , "links:"
    , "  - {kind: partOf, target: ent-7f3a}"
    , "  - {kind: occursIn, target: ent-c41d}"
    , "  - {kind: contradicts, target: ent-91cc, note: 對雙親死因的敘述不一致}"
    ]

decoded :: MetaOverride
decoded = case decodeMeta lindaFragmentYaml of
  Right ov -> ov
  Left e -> error (T.unpack e)

spec :: Spec
spec = do
  describe "meta 區塊的解析" $ do
    it "type / summary / tags 逐欄正確" $ do
      moType decoded `shouldBe` Just (typeOf "character-fragment")
      moSummary decoded `shouldBe` Just "十四歲時因塔主徵召失去雙親,自此對議會抱持敵意"
      moTags decoded `shouldBe` Just ["動機", "仇恨"]

    it "timeline 的純字串簡寫解成 label(entity-graph-core/F003 實作備註 1)" $
      moTimeline decoded `shouldBe` Just (Timeline (Just "埃提亞崩塌前") Nothing)

    it "timeline 的物件形式一樣收" $
      fmap moTimeline (decodeMeta "timeline: {label: 崩塌後, order: 3}\n")
        `shouldBe` Right (Just (Timeline (Just "崩塌後") (Just 3)))

    it "三筆 links 的 kind / target / note 都對" $
      moLinks decoded
        `shouldBe` Just
          [ Link PartOf (refOf "ent-7f3a") Nothing
          , Link OccursIn (refOf "ent-c41d") Nothing
          , Link Contradicts (refOf "ent-91cc") (Just "對雙親死因的敘述不一致")
          ]

    it "未寫的欄位是 Nothing,交給繼承規則" $ do
      moVault decoded `shouldBe` Nothing
      moStatus decoded `shouldBe` Nothing
      moRevision decoded `shouldBe` Nothing

    it "未知欄位被忽略不報錯" $
      fmap moSummary (decodeMeta "summary: 一句話\n未來才有的欄位: 值\n")
        `shouldBe` Right (Just "一句話")

    it "target 為 vlt-a0c4e1f8:ent-1234 時解析為跨 Vault Ref(vault 段落須為合法 vlt- id,ADR-014)" $ do
      let ov = decodeMeta "links:\n  - {kind: references, target: vlt-a0c4e1f8:ent-1234}\n"
      fmap (fmap (map linkTarget) . moLinks) ov
        `shouldBe` Right (Just [Ref (Just (vaultOf "vlt-a0c4e1f8")) (idOf "ent-1234")])

    it "未知的關聯字串成為 Custom,不報錯" $
      fmap (fmap (map linkKind) . moLinks) (decodeMeta "links:\n  - {kind: 師承於, target: ent-0001}\n")
        `shouldBe` Right (Just [Custom "師承於"])

    it "kind 欄位(Level 檔的節)可解出 NodeKind" $
      fmap moKind (decodeMeta "kind: dialogue\n") `shouldSatisfy` \r -> case r of
        Right (Just _) -> True
        _ -> False

    it "空的 meta 區塊視為所有欄位未寫" $
      decodeMeta "" `shouldBe` Right emptyOverride

    it "只有註解的 meta 區塊也視為所有欄位未寫" $
      decodeMeta "# 這裡什麼都還沒寫\n" `shouldBe` Right emptyOverride

  describe "frontmatter 的解析" $ do
    it "琳達檔案層的 Meta 逐欄正確" $ do
      let doc = docOf lindaMd
      case decodeFrontmatter (docFrontRaw doc) of
        Left e -> expectationFailure (T.unpack e)
        Right m -> do
          metaId m `shouldBe` idOf "ent-7f3a"
          metaVault m `shouldBe` vaultOf "liftgame"
          metaType m `shouldBe` typeOf "character"
          metaTitle m `shouldBe` "琳達"
          metaStatus m `shouldBe` Canon
          metaAliases m `shouldBe` ["小琳", "第七織手"]
          metaSource m `shouldBe` Human
          metaRevision m `shouldBe` Revision 3
          metaCreated m `shouldBe` day0
          metaUpdated m `shouldBe` day0

    it "YAML 註解與縮排風格不影響解析結果" $ do
      let withComments = "\n# 這是註解\nid: ent-0001   # 行末註解\nvault: v\ntype: t\ntitle: T\ncreated: 2026-08-16\nupdated: 2026-08-16\n"
      fmap metaId (decodeFrontmatter withComments) `shouldBe` Right (idOf "ent-0001")

  describe "YAML 語法錯誤" $
    it "節的 YAML 壞掉 → SectionYaml,帶該節 id 與 HsYAML 的訊息" $ do
      let src =
            T.unlines
              [ "---"
              , "id: ent-0001"
              , "vault: v"
              , "type: t"
              , "title: T"
              , "created: 2026-08-16"
              , "updated: 2026-08-16"
              , "---"
              , ""
              , "## 一節 {#ent-000a}"
              , ""
              , "```meta"
              , "summary: 一"
              , "  壞掉的縮排: 值"
              , "```"
              ]
          doc = docOf src
      case toTopic doc of
        Right _ -> expectationFailure "這份檔案的 meta 區塊應該解析失敗"
        Left e -> case errKind e of
          SectionYaml i msg -> do
            i `shouldBe` idOf "ent-000a"
            msg `shouldSatisfy` (not . T.null)
          other -> expectationFailure ("預期一筆 SectionYaml,實得:" <> show other)
