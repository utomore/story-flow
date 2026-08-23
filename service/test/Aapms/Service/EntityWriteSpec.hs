-- | T12 / T13:Entity 的建立、修改與刪除。
--
-- 兩條紅線在這裡守:__宣告式目錄__(新檔案落在註冊表說的地方,不是硬編的)與
-- __樂觀鎖__(revision 不符就一個位元組都不寫)。
module Aapms.Service.EntityWriteSpec (spec) where

import Data.List (isPrefixOf)
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (localRef)
import Aapms.Core.Link (Link (..), LinkKind (PartOf))
import Aapms.Core.Meta (Meta (..), Status (Deprecated))
import Aapms.Service
import Aapms.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "createEntity / addFragment" $ do
    it "落在註冊表宣告的目錄,不是硬編的" $
      withServiceEnv $ \env -> do
        c <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        evPath c `shouldSatisfy` isPrefixOf "characters/"
        i <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀"))
        evPath i `shouldSatisfy` isPrefixOf "items/"

  describe "addFragment" $ do
    it "片段與主體在同一份檔案,而且主體的 revision +1" $
      withServiceEnv $ \env -> do
        main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity main))
        metaRevision (entMeta (evEntity main)) `shouldBe` 1
        frag <- runS env (addFragment i (newFragment "外貌" "銀灰短髮"))
        evPath frag `shouldBe` evPath main
        later <- runS env (getEntity i)
        metaRevision (entMeta (evEntity later)) `shouldBe` 2

    it "片段繼承主體的 vault 與 status,但 summary 是自己的" $
      withServiceEnv $ \env -> do
        main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity main))
        frag <- runS env (addFragment i (newFragment "外貌" "銀灰短髮"))
        let fm = entMeta (evEntity frag)
        metaVault fm `shouldBe` metaVault (entMeta (evEntity main))
        metaStatus fm `shouldBe` metaStatus (entMeta (evEntity main))
        metaSummary fm `shouldBe` "銀灰短髮"

    it "對片段加片段 → NotAFileMain" $
      withServiceEnv $ \env -> do
        main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity main))
        frag <- runS env (addFragment i (newFragment "外貌" "銀灰短髮"))
        r <- runE env (addFragment (metaId (entMeta (evEntity frag))) (newFragment "再一層" "不行"))
        fmap (const ()) r `shouldFailWith` "not_a_file_main"

  describe "updateEntity" $ do
    it "revision 不符 → StaleRevision,而且檔案沒被改到" $
      withServiceEnv $ \env -> do
        v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity v))
        r <- runE env (updateEntity i 99 emptyPatch {epSummary = Just "被改掉的總結"})
        fmap (const ()) r `shouldFailWith` "stale_revision"
        later <- runS env (getEntity i)
        metaSummary (entMeta (evEntity later)) `shouldBe` "第七織手"
        metaRevision (entMeta (evEntity later)) `shouldBe` 1

    it "只給 summary 時其餘欄位不動" $
      withServiceEnv $ \env -> do
        v <-
          runS env $
            createEntity (newEntity "character" "琳達" "第七織手") {nerTags = ["主角"]}
        let i = metaId (entMeta (evEntity v))
        later <- runS env (updateEntity i 1 emptyPatch {epSummary = Just "新的總結"})
        let m = entMeta (evEntity later)
        metaSummary m `shouldBe` "新的總結"
        metaTags m `shouldBe` ["主角"]
        metaTitle m `shouldBe` "琳達"
        metaRevision m `shouldBe` 2

    it "改得動狀態與標籤" $
      withServiceEnv $ \env -> do
        v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity v))
        later <-
          runS env $
            updateEntity i 1 emptyPatch {epStatus = Just Deprecated, epTags = Just ["棄用"]}
        metaStatus (entMeta (evEntity later)) `shouldBe` Deprecated
        metaTags (entMeta (evEntity later)) `shouldBe` ["棄用"]

    it "改得動檔案層主體的標題" $
      withServiceEnv $ \env -> do
        v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity v))
        later <- runS env (updateEntity i 1 emptyPatch {epTitle = Just "琳達・第七織手"})
        metaTitle (entMeta (evEntity later)) `shouldBe` "琳達・第七織手"

    it "改得動片段的標題(標題在標題行,不在 meta 區塊)" $
      withServiceEnv $ \env -> do
        main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        frag <-
          runS env $
            addFragment (metaId (entMeta (evEntity main))) (newFragment "外貌" "銀灰短髮")
        let fi = metaId (entMeta (evEntity frag))
        later <- runS env (updateEntity fi 1 emptyPatch {epTitle = Just "外貌與舉止"})
        metaTitle (entMeta (evEntity later)) `shouldBe` "外貌與舉止"
        -- 同一次寫入,revision 只跳一號
        metaRevision (entMeta (evEntity later)) `shouldBe` 2

    it "標題與其他欄位一起改是一次寫入" $
      withServiceEnv $ \env -> do
        v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity v))
        later <-
          runS env $
            updateEntity i 1 emptyPatch {epTitle = Just "新名字", epSummary = Just "新總結"}
        let m = entMeta (evEntity later)
        metaTitle m `shouldBe` "新名字"
        metaSummary m `shouldBe` "新總結"
        metaRevision m `shouldBe` 2

  describe "setEntityBody" $ do
    it "換正文一樣遞增 revision" $
      withServiceEnv $ \env -> do
        v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity v))
        later <- runS env (setEntityBody i 1 "角色主體的概述寫在這裡。")
        entBody (evEntity later) `shouldSatisfy` (/= "")
        metaRevision (entMeta (evEntity later)) `shouldBe` 2

  describe "deleteEntity" $ do
    it "刪主體會連同檔內的片段一起刪掉" $
      withServiceEnv $ \env -> do
        main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let i = metaId (entMeta (evEntity main))
        _ <- runS env (addFragment i (newFragment "外貌" "銀灰短髮"))
        r <- runS env (deleteEntity i 2 False)
        length (delRemoved r) `shouldBe` 2
        rest <- runS env (listEntities emptyFilter)
        rest `shouldBe` []

    it "還有人指向時,非強制刪除被擋下來" $
      withServiceEnv $ \env -> do
        target <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let ti = metaId (entMeta (evEntity target))
        _ <-
          runS env $
            createEntity
              (newEntity "lore" "埃提亞崩塌" "崩塌前後")
                {nerLinks = [Link PartOf (localRef ti) Nothing]}
        r <- runE env (deleteEntity ti 1 False)
        fmap (const ()) r `shouldFailWith` "referenced_by"
        -- 擋下來就代表沒刪:讀得回來
        still <- runS env (getEntity ti)
        metaTitle (entMeta (evEntity still)) `shouldBe` "琳達"

    it "強制刪除會照刪,並回報被打斷的關聯" $
      withServiceEnv $ \env -> do
        target <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
        let ti = metaId (entMeta (evEntity target))
        _ <-
          runS env $
            createEntity
              (newEntity "lore" "埃提亞崩塌" "崩塌前後")
                {nerLinks = [Link PartOf (localRef ti) Nothing]}
        r <- runS env (deleteEntity ti 1 True)
        delBrokenLinks r `shouldSatisfy` not . null
