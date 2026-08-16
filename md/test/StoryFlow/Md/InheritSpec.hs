-- | T5:節層繼承檔案層的欄位規則。
module StoryFlow.Md.InheritSpec (spec) where

import Data.Time (fromGregorian)
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import StoryFlow.Md
import StoryFlow.Md.Fixtures
import Test.Hspec

-- | 檔案層:每一欄都填了不同的值,才看得出哪些有繼承、哪些沒有。
fileMeta :: Meta
fileMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = "liftgame"
    , metaType = "character"
    , metaTitle = "琳達"
    , metaSummary = "埃提亞的第七織手"
    , metaTags = ["角色", "主線"]
    , metaStatus = Canon
    , metaTimeline = Timeline (Just "崩塌前") (Just 2)
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks = [Link PartOf (refOf "ent-0001") Nothing]
    , metaSource = Agent "claude-code"
    , metaRevision = 7
    , metaCreated = fromGregorian 2026 1 1
    , metaUpdated = fromGregorian 2026 2 2
    }

-- | 只寫了 summary 的節。
bare :: MetaOverride
bare = emptyOverride {moSummary = Just "銀灰短髮"}

inherited :: Meta
inherited = fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare)

spec :: Spec
spec = do
  describe "繼承的欄位" $
    it "vault / type / status / timeline / source / created / updated 全部繼承檔案層" $ do
      metaVault inherited `shouldBe` "liftgame"
      metaType inherited `shouldBe` "character"
      metaStatus inherited `shouldBe` Canon
      metaTimeline inherited `shouldBe` Timeline (Just "崩塌前") (Just 2)
      metaSource inherited `shouldBe` Agent "claude-code"
      metaCreated inherited `shouldBe` fromGregorian 2026 1 1
      metaUpdated inherited `shouldBe` fromGregorian 2026 2 2

  describe "覆寫" $
    it "節層寫了就以節層為準" $ do
      let ov =
            bare
              { moVault = Just "shared-lore"
              , moType = Just "character-fragment"
              , moStatus = Just Draft
              , moTimeline = Just (Timeline (Just "崩塌後") Nothing)
              , moSource = Just Human
              , moCreated = Just day0
              , moUpdated = Just day0
              }
          m = fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" ov)
      metaVault m `shouldBe` "shared-lore"
      metaType m `shouldBe` "character-fragment"
      metaStatus m `shouldBe` Draft
      metaTimeline m `shouldBe` Timeline (Just "崩塌後") Nothing
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
      metaRevision inherited `shouldBe` 1

    it "revision 節層寫了就用節層的" $
      metaRevision (fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare {moRevision = Just 5}))
        `shouldBe` 5

  describe "tags 聯集去重" $ do
    it "檔案層與節層的標籤合併" $
      metaTags (fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare {moTags = Just ["外觀"]}))
        `shouldBe` ["角色", "主線", "外觀"]

    it "重複的標籤只留一份" $
      metaTags (fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare {moTags = Just ["主線", "外觀"]}))
        `shouldBe` ["角色", "主線", "外觀"]

    it "節層沒寫時就是檔案層的標籤" $
      metaTags inherited `shouldBe` ["角色", "主線"]

  describe "summary 與警告" $ do
    it "summary 不繼承" $
      metaSummary (fst (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" emptyOverride))
        `shouldBe` ""

    it "節層未寫 summary → MissingSummary 警告" $
      snd (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" emptyOverride)
        `shouldBe` [MissingSummary (idOf "ent-7f3b")]

    it "節層寫了 summary 就沒有警告" $
      snd (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare) `shouldBe` []

    it "空字串的 summary 也算沒寫" $
      snd (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare {moSummary = Just ""})
        `shouldBe` [MissingSummary (idOf "ent-7f3b")]

    it "自訂關聯 → CustomLinkKind 警告" $
      snd (inheritMeta fileMeta (idOf "ent-7f3b") "外貌" bare {moLinks = Just [Link (Custom "師承於") (refOf "ent-0001") Nothing]})
        `shouldBe` [CustomLinkKind (idOf "ent-7f3b") "師承於"]
