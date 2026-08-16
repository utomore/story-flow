-- | T10:查詢與關聯。
module StoryFlow.Store.QuerySpec (spec) where

import Data.List (sort)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Graph (supersededSet)
import StoryFlow.Core.Id (Id, Ref (..), localRef, parseId, renderId, renderRef)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (..))
import StoryFlow.Core.Link (Link (..), LinkKind (..))
import StoryFlow.Core.Meta (Meta (..), Status (..), Timeline (..))
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Store.Fixtures
import StoryFlow.Store.Query
import Test.Hspec

spec :: Spec
spec = describe "T10 查詢" $ do
  it "lookupEntity 回傳含 body 的完整 Entity(body 來自回讀檔案)" $
    withSampleIndex $ \_ conn -> do
      Just e <- lookupEntity conn (idOf "ent-7f3b")
      metaTitle (entMeta e) `shouldBe` "外貌"
      metaSummary (entMeta e) `shouldBe` "銀灰短髮,左眼下方有織紋刺青"
      entBody e `shouldBe` "銀灰短髮剪到耳際……"
      -- 節層繼承檔案層:vault / type 之外的 status 也繼承
      metaStatus (entMeta e) `shouldBe` Canon
      metaTags (entMeta e) `shouldBe` ["外觀"]

  it "lookupEntity 對檔案層主體回傳主體與它的 preamble" $
    withSampleIndex $ \_ conn -> do
      Just e <- lookupEntity conn (idOf "ent-7f3a")
      metaTitle (entMeta e) `shouldBe` "琳達"
      metaAliases (entMeta e) `shouldBe` ["小琳", "第七織手"]
      entBody e `shouldSatisfy` T.isInfixOf "角色主體的概述"

  it "lookupEntity 對不存在的 id 回 Nothing" $
    withSampleIndex $ \_ conn ->
      lookupEntity conn (idOf "ent-0000") `shouldReturn` Nothing

  it "listEntities 不含 body,且依 type / status / tag 過濾" $
    withSampleIndex $ \_ conn -> do
      allMetas <- listEntities conn emptyFilter
      length allMetas `shouldBe` 8

      byType <- listEntities conn emptyFilter {efType = Just "character-fragment"}
      map (renderId . metaId) byType `shouldBe` ["ent-7f3b", "ent-7f3c"]

      -- 片段層覆寫了 status,只有它是 draft
      byStatus <- listEntities conn emptyFilter {efStatus = Just Draft}
      map (renderId . metaId) byStatus `shouldBe` ["ent-c41f"]

      byTag <- listEntities conn emptyFilter {efTag = Just "外觀"}
      map (renderId . metaId) byTag `shouldBe` ["ent-1002", "ent-7f3b"]

      limited <- listEntities conn emptyFilter {efLimit = Just 3}
      length limited `shouldBe` 3

  it "listEntities 把 tags / aliases / links 一起帶回來" $
    withSampleIndex $ \_ conn -> do
      [m] <- listEntities conn emptyFilter {efType = Just "character"}
      metaAliases m `shouldBe` ["小琳", "第七織手"]
      metaLinks m `shouldBe` []
      [f] <- listEntities conn emptyFilter {efTag = Just "動機"}
      map (renderLink) (metaLinks f)
        `shouldBe` ["partOf→ent-7f3a", "occursIn→ent-c41d", "contradicts→ent-91cc"]
      metaTimeline f `shouldBe` Timeline (Just "埃提亞崩塌前") Nothing

  it "linksFrom 取得來源端的關聯" $
    withSampleIndex $ \_ conn -> do
      ls <- linksFrom conn (idOf "ent-7f3c")
      map renderLink ls
        `shouldBe` ["partOf→ent-7f3a", "occursIn→ent-c41d", "contradicts→ent-91cc"]

  -- 反向查詢是索引存在的主要理由之一:關聯只存在來源端,檔案裡查不到誰指向我
  it "linksTo 取得反向關聯" $
    withSampleIndex $ \_ conn -> do
      back <- linksTo conn (localRef (idOf "ent-7f3a"))
      sort (map (renderId . fst) back) `shouldBe` ["ent-7f3b", "ent-7f3c", "ent-c41f", "nod-0002", "nod-0100"]
      -- 跨 Vault 參照與本地參照不會互相汙染
      linksTo conn (Ref (Just "shared-lore") (idOf "ent-7f3a")) `shouldReturn` []

  it "loadLinkGraph 餵給 core 的 supersededSet 得到正確的過時集合" $
    withSampleIndex $ \_ conn -> do
      g <- loadLinkGraph conn
      supersededSet g `shouldBe` S.singleton (localRef (idOf "ent-91cc"))

  it "lookupLevel 取得 Level 與它的全部 Node" $
    withSampleIndex $ \_ conn -> do
      Just (lvl, nodes) <- lookupLevel conn (idOf "lvl-3a01")
      metaTitle (lvlMeta lvl) `shouldBe` "教室"
      lvlRoot lvl `shouldBe` idOf "nod-0001"
      map (renderId . metaId . nodMeta) nodes
        `shouldBe` ["nod-0001", "nod-0002", "nod-0004", "nod-0003"]
      map nodKind nodes `shouldBe` [KScene, KCast, KInteraction, KCamera]
      -- 標題階層即樹
      map (fmap renderId . nodParent) nodes
        `shouldBe` [Nothing, Just "nod-0001", Just "nod-0002", Just "nod-0001"]
      map nodOrder nodes `shouldBe` [1, 1, 1, 2]
      -- Node 指向的 Entity 由 involves / references 推導
      map (map renderRef . nodEntities) nodes
        `shouldBe` [["ent-c41d"], ["ent-7f3a", "ent-8b20"], [], []]

  it "lookupLevel 對不存在的 id 回 Nothing" $
    withSampleIndex $ \_ conn ->
      lookupLevel conn (idOf "lvl-0000") `shouldReturn` Nothing

renderLink :: Link -> Text
renderLink Link {..} = kindText linkKind <> "→" <> renderRef linkTarget
  where
    kindText = \case
      PartOf -> "partOf"
      OccursIn -> "occursIn"
      Contradicts -> "contradicts"
      Supersedes -> "supersedes"
      References -> "references"
      Involves -> "involves"
      DerivedFrom -> "derivedFrom"
      ConvergesTo -> "convergesTo"
      Custom t -> t

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("測試裡的 id 不合法:" <> show e)
