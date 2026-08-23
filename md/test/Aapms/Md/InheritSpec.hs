-- | T1:'MetaOverride' 型別修正後往返不失真;T3:'inheritMeta' 的
-- @typeInherits@ 旗標與節層繼承檔案層的欄位規則(graph-core/F004,MdWarning
-- 通道已移除)。
module Aapms.Md.InheritSpec (spec) where

import Data.Time (fromGregorian)
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

-- | 檔案層:每一欄都填了不同的值,才看得出哪些有繼承、哪些沒有。
fileMeta :: Meta
fileMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = vaultOf "liftgame"
    , metaType = typeOf "character"
    , metaTitle = "琳達"
    , metaSummary = "埃提亞的第七織手"
    , metaTags = ["角色", "主線"]
    , metaStatus = Canon
    , metaTimeline = Just (Timeline (Just "崩塌前") (Just 2))
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks = [Link PartOf (refOf "ent-0001") Nothing]
    , metaSource = Agent "claude-code"
    , metaRevision = Revision 7
    , metaCreated = fromGregorian 2026 1 1
    , metaUpdated = fromGregorian 2026 2 2
    }

-- | 只寫了 summary 的節。
bare :: MetaOverride
bare = emptyOverride {moSummary = Just "銀灰短髮"}

-- | 節層繼承 @type@ 時(主題檔 / Level 檔 / licenses.md)的結果。
inherited :: Meta
inherited = either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" bare)

spec :: Spec
spec = do
  describe "T1:MetaOverride 型別修正後往返不失真" $ do
    it "overrideOf 展開的 moType / moVault / moRevision 型別正確且值相符" $ do
      let ov = overrideOf fileMeta
      moType ov `shouldBe` Just (typeOf "character")
      moVault ov `shouldBe` Just (vaultOf "liftgame")
      moRevision ov `shouldBe` Just (Revision 7)

    it "applyOverride 疊回去後與原本的 Meta 相等(overrideOf . applyOverride 是 id)" $
      applyOverride (overrideOf fileMeta) fileMeta `shouldBe` fileMeta

    it "applyOverride 只覆蓋有給的欄位,type/vault/revision 型別正確" $ do
      let m = applyOverride (emptyOverride {moType = Just (typeOf "lore"), moVault = Just (vaultOf "shared"), moRevision = Just (Revision 9)}) fileMeta
      metaType m `shouldBe` typeOf "lore"
      metaVault m `shouldBe` vaultOf "shared"
      metaRevision m `shouldBe` Revision 9
      -- 沒給的欄位維持原值
      metaSummary m `shouldBe` metaSummary fileMeta

  describe "T3:type 是否繼承" $ do
    it "typeInherits = True 且節層未寫 type 時繼承檔案層" $
      metaType inherited `shouldBe` typeOf "character"

    it "typeInherits = True 且節層寫了 type 時以節層為準" $
      metaType (either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" bare {moType = Just (typeOf "character-fragment")}))
        `shouldBe` typeOf "character-fragment"

    it "typeInherits = False 且節層未寫 type → Left (SectionFieldMissing i \"type\")" $
      inheritMeta False fileMeta (idOf "ast-0001") "封面" bare
        `shouldBe` Left (SectionFieldMissing (idOf "ast-0001") "type")

    it "typeInherits = False 且節層寫了 type 時正常成功" $
      fmap metaType (inheritMeta False fileMeta (idOf "ast-0001") "封面" bare {moType = Just (typeOf "asset-image")})
        `shouldBe` Right (typeOf "asset-image")

  describe "toTopic / toLevel 不再有警告通道" $
    it "toTopic 的回傳型別是 Either MdError (Entity, [Entity]),編譯期即保證沒有警告位置" $ do
      let (_, frags) = topicOf (docOf lindaMd)
      length frags `shouldBe` 2

  describe "繼承的欄位" $
    it "vault / status / timeline / source / created / updated 全部繼承檔案層" $ do
      metaVault inherited `shouldBe` vaultOf "liftgame"
      metaStatus inherited `shouldBe` Canon
      metaTimeline inherited `shouldBe` Just (Timeline (Just "崩塌前") (Just 2))
      metaSource inherited `shouldBe` Agent "claude-code"
      metaCreated inherited `shouldBe` fromGregorian 2026 1 1
      metaUpdated inherited `shouldBe` fromGregorian 2026 2 2

  describe "覆寫" $
    it "節層寫了就以節層為準" $ do
      let ov =
            bare
              { moVault = Just (vaultOf "shared-lore")
              , moType = Just (typeOf "character-fragment")
              , moStatus = Just Draft
              , moTimeline = Just (Timeline (Just "崩塌後") Nothing)
              , moSource = Just Human
              , moCreated = Just day0
              , moUpdated = Just day0
              }
          m = either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" ov)
      metaVault m `shouldBe` vaultOf "shared-lore"
      metaType m `shouldBe` typeOf "character-fragment"
      metaStatus m `shouldBe` Draft
      metaTimeline m `shouldBe` Just (Timeline (Just "崩塌後") Nothing)
      metaSource m `shouldBe` Human
      metaCreated m `shouldBe` day0

  describe "不繼承的欄位" $ do
    it "id 與 title 來自節標題" $ do
      metaId inherited `shouldBe` idOf "ent-7f3b"
      metaTitle inherited `shouldBe` "外貌"

    it "aliases 不繼承,節層未寫即空" $
      metaAliases inherited `shouldBe` []

    it "links 不繼承,節層未寫即空" $
      metaLinks inherited `shouldBe` []

    it "revision 不繼承,未寫時為 1 而非檔案層的 7" $
      metaRevision inherited `shouldBe` Revision 1

    it "revision 節層寫了就用節層的" $
      metaRevision (either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" bare {moRevision = Just (Revision 5)}))
        `shouldBe` Revision 5

  describe "tags 聯集去重" $ do
    it "檔案層與節層的標籤合併" $
      metaTags (either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" bare {moTags = Just ["外觀"]}))
        `shouldBe` ["角色", "主線", "外觀"]

    it "重複的標籤只留一份" $
      metaTags (either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" bare {moTags = Just ["主線", "外觀"]}))
        `shouldBe` ["角色", "主線", "外觀"]

    it "節層沒寫時就是檔案層的標籤" $
      metaTags inherited `shouldBe` ["角色", "主線"]

  describe "summary(不繼承,MdWarning 通道已移除)" $ do
    it "summary 不繼承" $
      metaSummary (either (error . show) id (inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" emptyOverride))
        `shouldBe` ""

    it "節層未寫 summary 時不再是錯誤,只是空字串(警告改由 checkMeta 負責)" $
      inheritMeta True fileMeta (idOf "ent-7f3b") "外貌" emptyOverride
        `shouldSatisfy` \r -> case r of
          Right m -> metaSummary m == ""
          Left _ -> False
