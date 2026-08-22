-- | 測試底稿:一個真的跑在本機、模擬 @story-flow-serve@ 的 stub 端點,以及一個
-- 保證__拒絕連線__的埠。與 @llm\/test\/StoryFlow\/Llm\/Fixtures.hs@、
-- @workshop\/test\/StoryFlow\/Workshop\/Fixtures.hs@ 同一個先例:「連不上服務」
-- 是這一層最常發生的失敗路徑,必須被真的測到,不能只測純函式。
module StoryFlow.Mcp.Fixtures
  ( -- * stub 端點
    Rule
  , rule
  , RecordedRequest (..)
  , StubHandle (..)
  , withStub

    -- * 連線被拒
  , withDeadPort

    -- * 設定
  , configFor
  ) where

import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (mkStatus, status200)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import StoryFlow.Mcp.Config (Config (..))

-- | 一條 stub 規則:@(method, path)@ 命中時回 @(status, body)@。
type Rule = ((BS.ByteString, Text), (Int, Value))

rule :: BS.ByteString -> Text -> Int -> Value -> Rule
rule m p status body = ((m, p), (status, body))

data RecordedRequest = RecordedRequest
  { rrMethod :: BS.ByteString
  , rrPath :: Text
  , rrQuery :: [(BS.ByteString, Maybe BS.ByteString)]
  , rrBody :: LBS.ByteString
  , rrHeaders :: [Header]
  }
  deriving stock (Show, Eq)

data StubHandle = StubHandle
  { stubPort :: Int
  , stubRequests :: IO [RecordedRequest]
  -- ^ 依到達順序。
  }

-- | 起一個依 @(method, path)@ 表分派回應的 stub。找不到規則的請求回 404 + 一個
-- @{\"error\":…}@ 形狀的 body(而不是讓 warp 對未預期的請求整個炸掉)。
withStub :: [Rule] -> (StubHandle -> IO a) -> IO a
withStub rules act = do
  ref <- newIORef []
  Warp.testWithApplication (pure (app ref)) $ \port ->
    act (StubHandle port (reverse <$> readIORef ref))
  where
    app ref req respond = do
      body <- Wai.strictRequestBody req
      let reqPath = "/" <> T.intercalate "/" (Wai.pathInfo req)
          rr =
            RecordedRequest
              { rrMethod = Wai.requestMethod req
              , rrPath = reqPath
              , rrQuery = Wai.queryString req
              , rrBody = body
              , rrHeaders = Wai.requestHeaders req
              }
      atomicModifyIORef' ref (\rs -> (rr : rs, ()))
      let (status, respBody) = fromMaybe (404, notFoundBody) (lookup (Wai.requestMethod req, reqPath) rules)
      respond $
        Wai.responseLBS
          (mkStatus status "stub")
          [("Content-Type", "application/json")]
          (encode respBody)
    notFoundBody =
      object ["error" .= object ["code" .= ("not_found_in_stub" :: Text), "message" .= ("stub 沒有這條規則" :: Text)]]

-- | 一個保證沒有人在聽的埠:起一個 stub 拿到 warp 配給的埠號、離開區塊讓它關掉,
-- 再把埠號交給呼叫端。
withDeadPort :: (Int -> IO a) -> IO a
withDeadPort act = do
  port <- Warp.testWithApplication (pure deadApp) pure
  act port
  where
    deadApp _ respond = respond (Wai.responseLBS status200 [] "")

-- | 指向本機某個埠的 'Config',沒有 token。
configFor :: Int -> Config
configFor port = Config ("http://127.0.0.1:" <> T.pack (show port)) Nothing
