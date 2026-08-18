-- | T14:關聯的目標檢查、跨 Vault 的擋法,以及雙向查詢。
--
-- 目標存在性檢查是 __service 才做得到__的驗證:@store@ 的單檔操作看不到別的
-- 檔案。指不到目標的關聯不會壞掉任何東西,但衝突偵測會安靜地少一條路徑
-- ——那種漏掉最難查。
module StoryFlow.Service.LinkSpec (spec) where

import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, Ref (..), localRef)
import StoryFlow.Core.Level (Level (..), NodeKind (KScene))
import StoryFlow.Core.Link (Link (..), LinkKind (Involves, PartOf))
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Service
import StoryFlow.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "Link" $ do
  it "目標不存在 → DanglingLinkTarget,而且不寫檔" $
    withServiceEnv $ \env -> do
      v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      let i = metaId (entMeta (evEntity v))
      r <- runE env (addLink i 1 (Link PartOf (refOf "ent-0000") Nothing))
      fmap (const ()) r `shouldFailWith` "dangling_link_target"
      later <- runS env (getEntity i)
      metaLinks (entMeta (evEntity later)) `shouldBe` []
      metaRevision (entMeta (evEntity later)) `shouldBe` 1

  it "跨 Vault 的目標 → CrossVaultUnsupported" $
    withServiceEnv $ \env -> do
      v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      let i = metaId (entMeta (evEntity v))
      r <- runE env (addLink i 1 (Link PartOf (refOf "shared-lore:ent-7f3a") Nothing))
      fmap (const ()) r `shouldFailWith` "cross_vault_unsupported"

  it "明寫本 Vault 名稱的 Ref 不算跨 Vault" $
    withServiceEnv $ \env -> do
      a <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      b <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀"))
      let ai = metaId (entMeta (evEntity a))
          bi = metaId (entMeta (evEntity b))
      later <- runS env (addLink ai 1 (Link Involves (Ref (Just "liftgame") bi) Nothing))
      length (metaLinks (entMeta (evEntity later))) `shouldBe` 1

  it "指向 Node 的關聯算合法目標(convergesTo 指的就是 Node)" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let root = lvlRootId lv
      e <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      let i = metaId (entMeta (evEntity e))
      later <- runS env (addLink i 1 (Link Involves (localRef root) Nothing))
      length (metaLinks (entMeta (evEntity later))) `shouldBe` 1

  it "A→B 之後,A 的正向與 B 的反向各看得到一筆" $
    withServiceEnv $ \env -> do
      a <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      b <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀"))
      let ai = metaId (entMeta (evEntity a))
          bi = metaId (entMeta (evEntity b))
      _ <- runS env (addLink ai 1 (Link Involves (localRef bi) Nothing))
      outA <- runS env (linksOf ai)
      inB <- runS env (linksOf bi)
      map linkKind (lrOutgoing outA) `shouldBe` [Involves]
      lrIncoming outA `shouldBe` []
      lrOutgoing inB `shouldBe` []
      map fst (lrIncoming inB) `shouldBe` [ai]

  it "removeLink 刪得掉,刪不到時回 LinkNotFound" $
    withServiceEnv $ \env -> do
      a <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      b <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀"))
      let ai = metaId (entMeta (evEntity a))
          bi = metaId (entMeta (evEntity b))
      _ <- runS env (addLink ai 1 (Link Involves (localRef bi) Nothing))
      later <- runS env (removeLink ai 2 Involves (localRef bi))
      metaLinks (entMeta (evEntity later)) `shouldBe` []
      r <- runE env (removeLink ai 3 Involves (localRef bi))
      fmap (const ()) r `shouldFailWith` "link_not_found"

-- | Level 的根 Node id。
lvlRootId :: LevelView -> Id
lvlRootId = lvlRoot . lvLevel
