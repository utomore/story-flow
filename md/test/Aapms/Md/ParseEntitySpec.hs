-- | T6:Entity 檔的解析,對照 system.md 的琳達範例。
module Aapms.Md.ParseEntitySpec (spec) where

import qualified Data.Text as T
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

doc :: Document
doc = docOf "characters/琳達.md" lindaMd

parsed :: (EntityFile, [MdWarning])
parsed = entityFileOf doc

ef :: EntityFile
ef = fst parsed

frag :: Int -> Entity
frag n = efFragments ef !! n

spec :: Spec
spec = do
  describe "檔案的判別" $
    it "type 不是 level 時走 Entity 解析" $
      documentKind doc `shouldBe` Right DocEntity

  describe "主體 Entity" $ do
    it "得 1 個主體 + 2 個片段" $
      length (efFragments ef) `shouldBe` 2

    it "主體逐欄比對 frontmatter" $ do
      let m = entMeta (efMain ef)
      metaId m `shouldBe` idOf "ent-7f3a"
      metaVault m `shouldBe` "liftgame"
      metaType m `shouldBe` "character"
      metaTitle m `shouldBe` "琳達"
      metaSummary m `shouldBe` "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
      metaStatus m `shouldBe` Canon
      metaAliases m `shouldBe` ["小琳", "第七織手"]
      metaSource m `shouldBe` Human
      metaRevision m `shouldBe` 3
      metaCreated m `shouldBe` day0

    it "主體的 body 是 preamble" $ do
      entBody (efMain ef) `shouldSatisfy` T.isInfixOf "# 琳達"
      entBody (efMain ef) `shouldSatisfy` T.isInfixOf "角色主體的概述寫在這裡。"

  describe "片段 ent-7f3b(外貌)" $ do
    it "id / title 來自節標題" $ do
      metaId (entMeta (frag 0)) `shouldBe` idOf "ent-7f3b"
      metaTitle (entMeta (frag 0)) `shouldBe` "外貌"

    it "type 被節層覆寫,vault / status / 日期繼承檔案層" $ do
      let m = entMeta (frag 0)
      metaType m `shouldBe` "character-fragment"
      metaVault m `shouldBe` "liftgame"
      metaStatus m `shouldBe` Canon
      metaCreated m `shouldBe` day0
      metaUpdated m `shouldBe` day0

    it "summary / tags / links 逐欄正確" $ do
      let m = entMeta (frag 0)
      metaSummary m `shouldBe` "銀灰短髮,左眼下方有織紋刺青"
      metaTags m `shouldBe` ["外觀"]
      metaLinks m `shouldBe` [Link PartOf (refOf "ent-7f3a") Nothing]

    it "revision 不繼承主體的 3,為 1" $
      metaRevision (entMeta (frag 0)) `shouldBe` 1

    it "aliases 不繼承" $
      metaAliases (entMeta (frag 0)) `shouldBe` []

    it "body 是該節的正文" $
      entBody (frag 0) `shouldBe` "銀灰短髮剪到耳際……"

  describe "片段 ent-7f3c(與塔主的過節)" $ do
    it "id 與 timeline 正確" $ do
      metaId (entMeta (frag 1)) `shouldBe` idOf "ent-7f3c"
      metaTimeline (entMeta (frag 1)) `shouldBe` Timeline (Just "埃提亞崩塌前") Nothing

    it "三筆 links 的 kind / target / note 都對" $
      metaLinks (entMeta (frag 1))
        `shouldBe` [ Link PartOf (refOf "ent-7f3a") Nothing
                   , Link OccursIn (refOf "ent-c41d") Nothing
                   , Link Contradicts (refOf "ent-91cc") (Just "對雙親死因的敘述不一致")
                   ]

    it "tags 為節層的兩個標籤(檔案層沒有標籤)" $
      metaTags (entMeta (frag 1)) `shouldBe` ["動機", "仇恨"]

  describe "警告" $
    it "琳達範例檔兩節都寫了 summary 與正文,沒有警告" $
      snd parsed `shouldBe` []
