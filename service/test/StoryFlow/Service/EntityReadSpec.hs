-- | T11:Entity 的讀取。
--
-- 'EntityView' 的價值全在那三個「檔案裡沒有」的欄位:路徑、錨點、警告。
-- 少了它們,CLI 與 API 就答不出「去改哪個檔案的哪一段」。
module StoryFlow.Service.EntityReadSpec (spec) where

import Data.List (isPrefixOf, sort)
import qualified Data.Text as T
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Meta (Meta (..), Status (Canon, Draft))
import StoryFlow.Service
import StoryFlow.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "Entity 讀取" $ do
  it "主體的 anchor 是 Nothing,片段是 Just" $
    withServiceEnv $ \env -> do
      main <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      let i = metaId (entMeta (evEntity main))
      frag <- runS env (addFragment i (newFragment "外貌" "銀灰短髮"))
      evAnchor main `shouldBe` Nothing
      evAnchor frag `shouldSatisfy` (/= Nothing)

  it "evPath 是 Vault 相對路徑,而且落在註冊表宣告的目錄下" $
    withServiceEnv $ \env -> do
      v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      evPath v `shouldSatisfy` isPrefixOf "characters/"

  it "找不到的 id 回 EntityNotFound" $
    withServiceEnv $ \env -> do
      r <- runE env (getEntity (idOf "ent-0000"))
      fmap (const ()) r `shouldFailWith` "entity_not_found"

  it "listEntities 的四個過濾條件各自生效" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      _ <- runS env (createEntity (newEntity "item" "織紋刀" "第七織手的佩刀") {nerTags = ["道具"]})
      _ <- runS env (createEntity (newEntity "lore" "埃提亞崩塌" "崩塌前後") {nerStatus = Draft})

      byType <- runS env (listEntities emptyFilter {efType = Just "item"})
      map metaTitle byType `shouldBe` ["織紋刀"]

      byStatus <- runS env (listEntities emptyFilter {efStatus = Just Draft})
      map metaTitle byStatus `shouldBe` ["埃提亞崩塌"]

      byTag <- runS env (listEntities emptyFilter {efTag = Just "道具"})
      map metaTitle byTag `shouldBe` ["織紋刀"]

      limited <- runS env (listEntities emptyFilter {efLimit = Just 2})
      length limited `shouldBe` 2

      allOfThem <- runS env (listEntities emptyFilter)
      sort (map metaTitle allOfThem) `shouldBe` sort ["琳達", "織紋刀", "埃提亞崩塌"]

  it "searchEntity 命中時帶出片段文字" $
    withServiceEnv $ \env -> do
      _ <-
        runS env $
          createEntity
            (newEntity "item" "織紋刀" "第七織手的佩刀,刀身鑄有織紋")
              {nerBody = "這把刀的織紋在埃提亞崩塌之後就沒有人能再鑄出來了。"}
      hits <- runS env (searchEntity "織紋刀" emptyFilter)
      map (metaTitle . shMeta) hits `shouldBe` ["織紋刀"]
      map shSnippet hits `shouldSatisfy` all (not . T.null)

  it "searchEntity 的過濾條件與 listEntities 同一組" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "item" "織紋刀" "刀身鑄有織紋"))
      _ <- runS env (createEntity (newEntity "lore" "織紋的來歷" "織紋的由來") {nerStatus = Draft})
      hits <- runS env (searchEntity "織紋" emptyFilter {efStatus = Just Canon})
      map (metaTitle . shMeta) hits `shouldBe` ["織紋刀"]
