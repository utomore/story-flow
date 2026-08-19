-- | T16:門面。
--
-- __本檔只 import 'StoryFlow.Service' 一個模組__(測試底稿除外),並跑完一輪
-- 增查改刪。ADR-006 說 CLI 與 server 是薄包裝,那它們就不該需要知道
-- @service@ 內部分了幾個模組;這一條測試就是那句話的證明。
module StoryFlow.Service.FacadeSpec (spec) where

import StoryFlow.Service
import StoryFlow.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "門面" $ do
  it "只 import StoryFlow.Service 就能走完 create → get → update → delete" $
    withServiceEnv $ \env -> do
      created <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      let i = evId created

      fetched <- runS env (getEntity i)
      evId fetched `shouldBe` i
      evRevision fetched `shouldBe` 1

      updated <- runS env (updateEntity i (evRevision fetched) emptyPatch {epSummary = Just "改過的總結"})
      evId updated `shouldBe` i
      evRevision updated `shouldBe` 2

      report <- runS env (deleteEntity i (evRevision updated) False)
      delRemoved report `shouldBe` [i]

      rest <- runS env (listEntities emptyFilter)
      rest `shouldBe` []

  it "Level 那一邊也一樣:建 → 加節點 → 刪" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" sceneKind))
      lv2 <- runS env (addNode (lvId lv) (rootOf lv) (lvRevision lv) (newNode "出場人物" castKind))
      lvRevision lv2 `shouldBe` 2
      report <- runS env (deleteLevel (lvId lv2) (lvRevision lv2) False)
      length (delRemoved report) `shouldBe` 3
