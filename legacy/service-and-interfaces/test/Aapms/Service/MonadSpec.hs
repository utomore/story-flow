-- | T4:'ServiceM' 的錯誤傳播。
--
-- 這一層唯一的行為就是「失敗會停下來、而且原樣傳到最外面」。組合操作的正確性
-- 全部靠它——中途失敗卻繼續跑下去,寫到一半的資料沒有人會發現。
module Aapms.Service.MonadSpec (spec) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Aapms.Service
import Aapms.Service.Fixtures
import Aapms.Store (StoreError (EntityNotFound))
import Test.Hspec

spec :: Spec
spec = describe "ServiceM" $ do
  it "成功路徑回 Right" $
    withServiceEnv $ \env ->
      runService env (pure (42 :: Int)) `shouldReturn` Right 42

  it "throwError 的值原樣出現在 Left" $
    withServiceEnv $ \env -> do
      let e = UnknownType "不存在的型別"
      r <- runService env (throwError e :: ServiceM ())
      r `shouldBe` Left e

  it "liftStore 把 StoreError 包成 StoreFailed" $
    withServiceEnv $ \env -> do
      let e = EntityNotFound (idOf "ent-7f3a")
      r <- runService env (liftStore (pure (Left e)) :: ServiceM ())
      r `shouldBe` Left (StoreFailed e)

  it "失敗之後的動作不再執行" $
    withServiceEnv $ \env -> do
      ref <- newIORef (0 :: Int)
      let bump = liftIO (modifyIORef' ref (+ 1))
      r <-
        runService env $ do
          bump
          _ <- liftStore (pure (Left (EntityNotFound (idOf "ent-7f3a")))) :: ServiceM ()
          bump
      r `shouldBe` Left (StoreFailed (EntityNotFound (idOf "ent-7f3a")))
      readIORef ref `shouldReturn` 1
