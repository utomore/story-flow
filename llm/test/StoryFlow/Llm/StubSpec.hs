-- | T9:__測試底稿自己的契約__。
--
-- 這一節存在的理由是 T7(a) 與 T8 全都建立在兩個前提上:stub 真的收得到請求並
-- 數得對,而 'withDeadPort' 給的埠__真的__拒絕連線。後者若只是「大概沒人在那個
-- 埠上」,T7(a) 就從「驗錯誤分類」退化成「碰運氣」——所以把前提本身變成一條
-- 斷言。
module StoryFlow.Llm.StubSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString.Lazy as LBS
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (ConnectionFailure)
  , defaultManagerSettings
  , httpLbs
  , newManager
  , parseRequest
  , responseBody
  )
import StoryFlow.Llm.Fixtures
import Test.Hspec

spec :: Spec
spec = do
  describe "withStub" $ do
    it "起得來,回得出設定好的內文" $
      withStub okStub {stubBody = "{\"marker\":true}"} $ \h -> do
        body <- get (stubPort h)
        body `shouldBe` "{\"marker\":true}"

    it "請求計數從 0 起算,並隨每個請求遞增" $
      withStub okStub $ \h -> do
        stubRequests h `shouldReturn` 0
        _ <- get (stubPort h)
        stubRequests h `shouldReturn` 1
        _ <- get (stubPort h)
        _ <- get (stubPort h)
        stubRequests h `shouldReturn` 3

    it "記得下路徑,讓路徑斷言有東西可看" $
      withStub okStub $ \h -> do
        _ <- get (stubPort h)
        last_ <- stubLast h
        fmap rrPath last_ `shouldBe` Just "/v1/chat/completions"

  describe "withDeadPort" $
    -- 這一條就是 T7(a) 賴以成立的前提:監聽 socket 關閉後沒有 TIME_WAIT,
    -- 連過去__立刻__是 ConnectionFailure,不必等逾時。
    it "給的埠在區塊內用 httpLbs 打會拿到 ConnectionFailure" $
      withDeadPort $ \port -> do
        mgr <- newManager defaultManagerSettings
        req <- parseRequest ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
        r <- try (httpLbs req mgr)
        case r of
          Left (HttpExceptionRequest _ (ConnectionFailure _)) -> pure () :: IO ()
          Left e -> expectationFailure ("預期 ConnectionFailure,得到 " <> show e)
          Right _ -> expectationFailure "預期連線被拒,但那個埠上有人回應"

-- | 對 stub 打一次,拿回內文。用最陽春的 manager:stub 一律是 http。
get :: Int -> IO LBS.ByteString
get port = do
  mgr <- newManager defaultManagerSettings
  req <- parseRequest ("http://127.0.0.1:" <> show port <> "/v1/chat/completions")
  responseBody <$> httpLbs req mgr
