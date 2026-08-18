-- | T11:綁非 loopback 且無 token 時拒絕啟動。
--
-- 這一條擋的是「整個 Vault 暴露在區域網路上」。ADR-0006 只要求印警告,本 spec
-- 收得更緊——警告會被忽略,而這件事不是可以靠使用者留意來緩解的。
--
-- 驗的是 'validateServeOpts' 這個純函式而不是 'runServer':後者成功時不會回來
-- (warp 一直跑到行程結束),而要驗的判斷完全在前者。
module StoryFlow.Server.ServeOptsSpec (spec) where

import Data.Either (isLeft, isRight)
import qualified Data.Text as T
import StoryFlow.Server
import Test.Hspec

spec :: Spec
spec = describe "啟動選項" $ do
  describe "isLoopback" $ do
    it "回到本機的位址都算" $
      mapM_ (\b -> (b, isLoopback b) `shouldBe` (b, True)) ["127.0.0.1", "127.0.0.53", "localhost", "::1", "[::1]"]

    it "萬用字元不算 —— 那正是要擋的東西" $
      mapM_ (\b -> (b, isLoopback b) `shouldBe` (b, False)) ["0.0.0.0", "*", "*4", "*6", "192.168.1.10", "::"]

  describe "validateServeOpts" $ do
    it "預設(綁 loopback、沒 token)可以啟動" $
      validateServeOpts defaultServeOpts `shouldSatisfy` isRight

    it "綁 loopback 時有沒有 token 都行" $
      validateServeOpts defaultServeOpts {soToken = Just "abc"} `shouldSatisfy` isRight

    it "綁 0.0.0.0 且沒有 token → 拒絕,而且說得出要怎麼辦" $ do
      let r = validateServeOpts defaultServeOpts {soBind = "0.0.0.0"}
      r `shouldSatisfy` isLeft
      either (`shouldContainT` "STORYFLOW_TOKEN") (const (expectationFailure "預期 Left")) r
      either (`shouldContainT` "127.0.0.1") (const (expectationFailure "預期 Left")) r

    it "綁 0.0.0.0 但有 token → 可以啟動" $
      validateServeOpts defaultServeOpts {soBind = "0.0.0.0", soToken = Just "夠長的隨機字串"}
        `shouldSatisfy` isRight

    it "空字串的 token 不算有設" $
      validateServeOpts defaultServeOpts {soBind = "0.0.0.0", soToken = Just ""}
        `shouldSatisfy` isLeft

    it "區網位址與 0.0.0.0 一視同仁" $
      validateServeOpts defaultServeOpts {soBind = "192.168.1.10"} `shouldSatisfy` isLeft

  describe "預設值" $
    it "127.0.0.1:8787、不驗證 token" $ do
      soPort defaultServeOpts `shouldBe` 8787
      soBind defaultServeOpts `shouldBe` "127.0.0.1"
      soToken defaultServeOpts `shouldBe` Nothing

shouldContainT :: T.Text -> T.Text -> Expectation
shouldContainT hay needle
  | needle `T.isInfixOf` hay = pure ()
  | otherwise = expectationFailure ("訊息裡找不到「" <> T.unpack needle <> "」:" <> T.unpack hay)
