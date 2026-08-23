-- | T8:型別警告依種類分流。
--
-- 這是 service-and-interfaces/F001 唯一一處「引擎替作者擋下東西」的地方,所以界線要很清楚:
-- 擋下來的只有作者自己在 TOML 裡宣告成 @required@ 的欄位;其餘一律照寫並附上
-- 警告,讓人與 Agent 自己決定。
module Aapms.Service.ValidateSpec (spec) where

import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Link (Link (..), LinkKind (Custom))
import Aapms.Core.Meta (Meta (..))
import Aapms.Service
import Aapms.Service.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "寫入前的型別驗證" $ do
  it "缺必填欄位 → ValidationFailed,而且一個位元組都沒寫" $
    withServiceEnv $ \env -> do
      -- character-fragment 的 summary 是 required = true
      r <- runE env (createEntity (newEntity "character-fragment" "外貌" ""))
      fmap (const ()) r `shouldFailWith` "validation_failed"
      metas <- runS env (listEntities emptyFilter)
      metas `shouldBe` []

  it "自訂關聯 → 成功,但帶警告" $
    withServiceEnv $ \env -> do
      let req =
            (newEntity "character-fragment" "與塔主的過節" "十四歲時失去雙親")
              { nerLinks = [Link (Custom "師承於") (refOf "ent-7f3a") Nothing]
              }
      v <- runS env (createEntity req)
      evWarnings v `shouldSatisfy` not . null

  it "型別不在註冊表但由 owner_type 認領 → 成功,附未知型別警告" $
    withServiceEnv $ \env -> do
      -- character 本身不是註冊表的 key,是 character-fragment 宣告的 owner_type
      v <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      metaType (entMeta (evEntity v)) `shouldBe` "character"
      evWarnings v `shouldSatisfy` not . null

  it "註冊表完全不認得的型別 → UnknownType,不寫檔" $
    withServiceEnv $ \env -> do
      r <- runE env (createEntity (newEntity "不存在的型別" "隨便" "隨便"))
      fmap (const ()) r `shouldFailWith` "unknown_type"
      metas <- runS env (listEntities emptyFilter)
      metas `shouldBe` []

  it "把必填欄位改成空字串也是寫入,一樣擋下來且檔案不變" $
    withServiceEnv $ \env -> do
      v <- runS env (createEntity (newEntity "character-fragment" "外貌" "銀灰短髮"))
      let i = metaId (entMeta (evEntity v))
      r <- runE env (updateEntity i 1 emptyPatch {epSummary = Just ""})
      fmap (const ()) r `shouldFailWith` "validation_failed"
      again <- runS env (getEntity i)
      metaSummary (entMeta (evEntity again)) `shouldBe` "銀灰短髮"
