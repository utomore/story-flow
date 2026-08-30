-- | conflict-detection/F004 T1:'linkGraph' ——整張關聯圖的內嵌出口。
--
-- 這個出口只給衝突偵測第 1 層用,__不接 CLI、不接 REST__(理由與 'aliasIndex'
-- 相同:整張圖序列化送出去對任何客戶端都不是它要的東西)。
--
-- 第二節那條測試是本檔的重點:它釘住的不是 'linkGraph' 自己做了什麼,而是
-- __索引寫入端已經保證的不變量__ ——指向本 Vault 的目標一律
-- @refVault = Nothing@。消費端(@Conflict.Pipeline@)因此不必、也不該再掃一遍圖
-- 做第二次正規化;而這條測試就是那個「不必」的依據。規則若哪天在
-- @Aapms.Store.Index.localize@ 那一端變了,這裡先紅。
module Aapms.Service.LinkGraphSpec (spec) where

import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Aapms.Core.Id (Id, Ref (..), localRef, renderId)
import Aapms.Core.Link (Link (..), LinkKind (Contradicts, PartOf))
import Aapms.Core.Meta (Meta (..))
import Aapms.Service
import Aapms.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "linkGraph" $ do
  it "鍵與每個桶的 linkTarget 都與寫進去的一致" $
    withServiceEnv $ \env -> do
      a <- newE env (newEntity "character" "琳達" "第七織手")
      b <- newE env (newEntity "character" "埃提亞" "崩塌前的地區")
      c <- newE env (newEntity "character" "白塔" "埃提亞的白塔")

      revA <- runS env (evRevision <$> getEntity a)
      _ <- runS env (addLink a revA (Link PartOf (localRef b) Nothing))
      revA' <- runS env (evRevision <$> getEntity a)
      _ <- runS env (addLink a revA' (Link Contradicts (localRef c) Nothing))

      g <- runS env linkGraph
      -- 關聯只存在來源端(ADR-002),所以只有 a 是鍵
      map renderId (M.keys g) `shouldBe` [renderId a]
      sort [renderId (refId (linkTarget l)) | l <- M.findWithDefault [] a g]
        `shouldBe` sort (map renderId [b, c])
      sort [linkKind l | l <- M.findWithDefault [] a g] `shouldBe` sort [PartOf, Contradicts]

  it "指向本 Vault 的目標一律 refVault = Nothing(正規化由索引寫入端做掉)" $
    withServiceEnv $ \env -> do
      -- 刻意用帶著本 Vault 前綴的 Ref 寫進去。Aapms.Store.Index 的 localize
      -- 在寫進 links 表之前就把它壓成 NULL,而 loadLinkGraph 讀的正是那張表
      -- ——所以圖裡看不到前綴。
      a <- newE env (newEntity "character" "琳達" "第七織手")
      b <- newE env (newEntity "character" "埃提亞" "崩塌前的地區")
      revA <- runS env (evRevision <$> getEntity a)
      _ <- runS env (addLink a revA (Link PartOf (Ref (Just "liftgame") b) Nothing))

      g <- runS env linkGraph
      let targets = [linkTarget l | l <- M.findWithDefault [] a g]
      map refVault targets `shouldBe` [Nothing]
      map (renderId . refId) targets `shouldBe` [renderId b]
      -- 第 1 層的反向索引只收 refVault == Nothing 的關聯:這條不變量一旦破了,
      -- unlinkedRefs 會把「只被本 Vault 前綴指到」的片段誤判成零關聯。
      all (isNothing . refVault) targets `shouldBe` True

  it "同一條關聯在建檔時就寫上,結果一樣被正規化" $
    withServiceEnv $ \env -> do
      -- addLink 不是 links 表唯一的寫入點:createEntity 的 nerLinks 也是一條。
      -- 三個寫入點全部經過 insertLinks,所以不變量對它們一體適用。
      b <- newE env (newEntity "character" "埃提亞" "崩塌前的地區")
      a <-
        newE env $
          (newEntity "character" "琳達" "第七織手")
            {nerLinks = [Link PartOf (Ref (Just "liftgame") b) Nothing]}

      g <- runS env linkGraph
      map refVault [linkTarget l | l <- M.findWithDefault [] a g] `shouldBe` [Nothing]

  it "跨 Vault 的目標保留它的前綴(只存不解析)" $
    withServiceEnv $ \env -> do
      -- 對照組:localize 只壓掉「等於本 Vault 名稱」的前綴,別的 Vault 照樣留著
      -- ——否則第 1 層會把 shared-lore:ent-xxxx 當成本地 ent-xxxx 反查,
      -- 在兩個 Vault 的 id 恰好相同時製造假命中。
      a <-
        newE env $
          (newEntity "character" "琳達" "第七織手")
            {nerLinks = [Link PartOf (refOf "shared-lore:ent-7f3a") Nothing]}

      g <- runS env linkGraph
      map refVault [linkTarget l | l <- M.findWithDefault [] a g] `shouldBe` [Just "shared-lore"]

  it "一條關聯都沒有的 Vault 回空 Map" $
    withServiceEnv $ \env -> do
      _ <- newE env (newEntity "character" "琳達" "第七織手")
      g <- runS env linkGraph
      M.null g `shouldBe` True

  it "連跑兩次結果相同,而且 revision 不變(純讀取)" $
    withServiceEnv $ \env -> do
      b <- newE env (newEntity "character" "埃提亞" "崩塌前的地區")
      _ <-
        newE env $
          (newEntity "character" "琳達" "第七織手")
            {nerLinks = [Link PartOf (localRef b) Nothing]}
      first_ <- runS env linkGraph
      again <- runS env linkGraph
      again `shouldBe` first_
      revs <- runS env (map metaRevision <$> listEntities emptyFilter)
      revs `shouldBe` [1, 1]

newE :: Env -> NewEntityReq -> IO Id
newE env req = evId <$> runS env (createEntity req)
