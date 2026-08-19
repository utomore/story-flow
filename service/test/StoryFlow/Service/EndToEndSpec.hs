-- | T17:純 service 從零建出琳達與教室。
--
-- 這是 service-and-interfaces/F001 的驗收面:__全程只呼叫 'ServiceM' 的函式__,不經過 CLI 也不
-- 經過 HTTP。跑得完就代表 P2 的業務能力齊了,service-and-interfaces/F002 的 CLI 只剩「把引數轉
-- 成請求」這一件事。
--
-- 建出來的形狀對照 system.md 的教室範例:一個 scene 根、底下 cast 與
-- camera,cast 底下再一層 interaction。
module StoryFlow.Service.EndToEndSpec (spec) where

import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Core.Id (Id, localRef)
import StoryFlow.Core.Level (Node (..), NodeKind (KCamera, KCast, KInteraction, KScene))
import StoryFlow.Core.Link (Link (..), LinkKind (Involves, PartOf))
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Core.Tree (preorder)
import StoryFlow.Service
import StoryFlow.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "端到端(只走 service)" $
  it "從零建出琳達與教室,reindex 之後結果不變" $
    withServiceEnv $ \env -> do
      -- 1. 琳達:主體 + 兩個片段
      linda <- runS env (createEntity (newEntity "character" "琳達" "埃提亞的第七織手"))
      let li = evId linda
      look <- runS env (addFragment li (newFragment "外貌" "銀灰短髮,左眼下方有織紋刺青"))
      grudge <-
        runS env $
          addFragment
            li
            (newFragment "與塔主的過節" "十四歲時因塔主徵召失去雙親")
              {nfrLinks = [Link PartOf (localRef li) Nothing]}

      -- 2. 世界觀:兩個片段要指的地點
      lore <- runS env (createEntity (newEntity "lore" "埃提亞崩塌" "埃提亞在崩塌前後的樣貌"))

      -- 3. 片段掛上 occursIn(先讀再寫:revision 從 View 拿)
      cur <- runS env (getEntity (evId grudge))
      _ <- runS env (addLink (evId cur) (evRevision cur) (Link Involves (localRef (evId lore)) Nothing))

      -- 4. 教室 Level:根 scene → cast → interaction,以及一個 camera
      lv0 <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      lv1 <- runS env (addNode (lvId lv0) (rootOf lv0) (lvRevision lv0) (newNode "出場人物" KCast))
      let cast = firstChildId (lvTree lv1)
      lv2 <- runS env (addNode (lvId lv1) cast (lvRevision lv1) (newNode "琳達走向講台" KInteraction))
      lv3 <- runS env (addNode (lvId lv2) (rootOf lv2) (lvRevision lv2) (newNode "鏡頭" KCamera))

      -- 形狀:四個 Node,前序是 scene → cast → interaction → camera
      map nodKind (preorder (lvTree lv3)) `shouldBe` [KScene, KCast, KInteraction, KCamera]

      -- 5. 查詢的結果
      metas <- runS env (listEntities emptyFilter)
      sort (map metaTitle metas)
        `shouldBe` sort ["琳達", "外貌", "與塔主的過節", "埃提亞崩塌"]

      links <- runS env (linksOf li)
      -- 琳達的主體被「與塔主的過節」指著(partOf)
      map fst (lrIncoming links) `shouldBe` [evId grudge]

      hits <- runS env (searchEntity "織紋刺青" emptyFilter)
      map (metaTitle . shMeta) hits `shouldBe` ["外貌"]

      -- 6. 索引是衍生物:全量重建之後每一項查詢的結果都要一樣
      earlier <- snapshot env (lvId lv3) li
      r <- runS env reindex
      -- 三份檔案:琳達、埃提亞崩塌、教室。
      -- irIssues 這裡__不是空的__也正常:片段沒寫正文、Node 沒寫 summary 都會
      -- 產生品質警告,而 IndexReport 把錯誤與警告放在同一個清單裡
      irFiles r `shouldBe` 3
      later <- snapshot env (lvId lv3) li
      later `shouldBe` earlier

      -- 檔案落在註冊表宣告的目錄
      evPath look `shouldBe` evPath linda

-- | 一份可比對的快照:重建索引前後必須完全相同。
snapshot :: Env -> Id -> Id -> IO ([Text], [NodeKind], [Text])
snapshot env lvlId entId = do
  metas <- runS env (listEntities emptyFilter)
  lv <- runS env (getLevel lvlId)
  ls <- runS env (linksOf entId)
  pure
    ( sort (map metaTitle metas)
    , map nodKind (preorder (lvTree lv))
    , sort (map (renderLinkKindOf . snd) (lrIncoming ls))
    )
  where
    renderLinkKindOf = tshow . linkKind
    tshow = T.pack . show
