-- | T10:token 驗證與定時比較。
module Aapms.Server.AuthSpec (spec) where

import Data.Either (isRight)
import Aapms.Server.Auth (constantTimeEq)
import Aapms.Server.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "認證" $ do
  describe "constantTimeEq" $ do
    it "相同字串回 True" $ constantTimeEq "s3cr3t" "s3cr3t" `shouldBe` True
    it "等長但不同回 False" $ constantTimeEq "s3cr3t" "s3cr3T" `shouldBe` False
    it "不等長回 False" $ do
      constantTimeEq "s3cr3t" "s3cr3" `shouldBe` False
      constantTimeEq "s3cr3" "s3cr3t" `shouldBe` False
    it "前綴相同也不算通過(這正是短路比較會洩漏的東西)" $
      constantTimeEq "s3cr3t" "s3" `shouldBe` False
    it "空字串" $ do
      constantTimeEq "" "" `shouldBe` True
      constantTimeEq "" "x" `shouldBe` False
    it "非 ASCII 的 token 也比得對" $ do
      constantTimeEq "祕密鑰匙" "祕密鑰匙" `shouldBe` True
      constantTimeEq "祕密鑰匙" "祕密鑰是" `shouldBe` False

  describe "server 端" $ do
    it "未設 token 時,不送 header 也放行" $
      withServerToken Nothing Nothing $ \env ->
        runE env (cListVaults api) `shouldReturnSatisfying` isRight

    it "設了 token、送對的 → 通過" $
      withServerToken (Just "s3cr3t") (Just "s3cr3t") $ \env ->
        runE env (cListVaults api) `shouldReturnSatisfying` isRight

    it "設了 token、不送 header → 401" $
      withServerToken (Just "s3cr3t") Nothing $ \env -> do
        r <- runE env (cListVaults api)
        statusOf r `shouldBe` Just 401

    it "設了 token、送錯的 → 401" $
      withServerToken (Just "s3cr3t") (Just "wr0ng!") $ \env -> do
        r <- runE env (cListVaults api)
        statusOf r `shouldBe` Just 401

    it "送對的前綴也不行" $
      withServerToken (Just "s3cr3t") (Just "s3") $ \env -> do
        r <- runE env (cListVaults api)
        statusOf r `shouldBe` Just 401

    it "401 擋在所有路由前面,不只 /vaults" $
      withServerToken (Just "s3cr3t") Nothing $ \env -> do
        r <- runE env (cTypes api)
        statusOf r `shouldBe` Just 401

    -- 這一條擋的是一個真的發生過的 bug:401 的 body 原本寫成 ByteString 字面值,
    -- 而 OverloadedStrings 給 ByteString 的實例會把繁中逐字元截成 8 bit。body
    -- 因此不是合法 UTF-8、解不出 JSON,客戶端就把「token 錯了」誤報成
    -- 「對面不是 aapms 伺服器」。
    it "401 的 body 是合法信封,code 是 unauthorized" $
      withServerToken (Just "s3cr3t") (Just "wr0ng!") $ \env -> do
        r <- runE env (cListVaults api)
        codeOf r `shouldBe` Just "unauthorized"

shouldReturnSatisfying :: (Show a) => IO a -> (a -> Bool) -> Expectation
shouldReturnSatisfying act p = act >>= (`shouldSatisfy` p)
