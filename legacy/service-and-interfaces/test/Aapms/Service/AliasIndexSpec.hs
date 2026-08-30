-- | conflict-detection/F003 T3:'aliasIndex' ——片段 id → 它的標題與 aliases。
--
-- 這個出口只給衝突偵測第 2 層做「既有名稱有沒有出現在草稿裡」的反向比對用,
-- __不接 CLI、不接 REST__。它建在 'listEntities' 之上,所以 @EntityFilter@ 的
-- 全套過濾詞彙原樣可用——第 2 層因此不必自己發明一組過濾參數。
module Aapms.Service.AliasIndexSpec (spec) where

import Data.List (sort)
import Aapms.Core.Id (renderId)
import Aapms.Core.Meta (Status (Canon, Draft))
import Aapms.Service
import Aapms.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "aliasIndex" $ do
  it "回 title 與 aliases,且 title 排第一" $
    withServiceEnv $ \env -> do
      _ <-
        runS env $
          createEntity
            (newEntity "character" "琳達" "第七織手") {nerAliases = ["小琳", "第七織手"]}
      idx <- runS env (aliasIndex emptyFilter)
      map snd idx `shouldBe` [["琳達", "小琳", "第七織手"]]

  it "吃得到 EntityFilter:efStatus = Canon 時 draft 片段不出現" $
    withServiceEnv $ \env -> do
      _ <- runS env (createEntity (newEntity "item" "織紋刀" "刀身鑄有織紋"))
      _ <-
        runS env $
          createEntity (newEntity "lore" "織紋的來歷" "織紋的由來") {nerStatus = Draft}

      everything <- runS env (aliasIndex emptyFilter)
      sort (concatMap snd everything) `shouldBe` sort ["織紋刀", "織紋的來歷"]

      canonOnly <- runS env (aliasIndex emptyFilter {efStatus = Just Canon})
      concatMap snd canonOnly `shouldBe` ["織紋刀"]

  it "空字串的 alias 被濾掉" $
    withServiceEnv $ \env -> do
      -- metaAliases 允許使用者寫空項,而 T.isInfixOf "" 對任何草稿都成立
      -- ——留著會讓每個片段都變成關鍵詞命中。
      _ <-
        runS env $
          createEntity (newEntity "character" "琳達" "第七織手") {nerAliases = ["", "  ", "小琳"]}
      idx <- runS env (aliasIndex emptyFilter)
      map snd idx `shouldBe` [["琳達", "小琳"]]

  it "輸出依 id 排序,重跑兩次結果相同" $
    withServiceEnv $ \env -> do
      mapM_
        (\(t, s) -> runS env (createEntity (newEntity "item" t s)))
        [("織紋刀", "刀"), ("斷紋鎖", "鎖"), ("第七織梭", "梭")]
      first <- runS env (aliasIndex emptyFilter)
      again <- runS env (aliasIndex emptyFilter)
      again `shouldBe` first
      map (renderId . fst) first `shouldBe` sort (map (renderId . fst) first)
      length first `shouldBe` 3
