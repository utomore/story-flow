-- | T8 / T15:三個 JSON-RPC 方法的端到端分派。
--
-- 對 'processLine'(一行輸入 → 最多一行輸出)直接呼叫,不強求真的 spawn 子行程
-- ——與 design.md TodoList T15 的字面要求一致。@tools\/call@ 打進 stub 的部分
-- 沿用 'Aapms.Mcp.Fixtures',@tools\/list@ 不連線的斷言則故意把 stub 晾在
-- 一邊、事後檢查它完全沒被打到。
module Aapms.Mcp.ServerSpec (spec) where

import Data.Aeson
  ( Value (..)
  , decodeStrict
  , encode
  , object
  , (.=)
  )
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import Aapms.Api (aapmsOpenApi)
import Aapms.Mcp.Fixtures
import Aapms.Mcp.Server (processLine)
import Aapms.Mcp.Tools (toolsFromOpenApi)
import Test.Hspec

spec :: Spec
spec = do
  let tools = toolsFromOpenApi aapmsOpenApi

  describe "initialize——沒設定連線設定" $
    it "回 -32001,data.code 是 story_flow_url_missing" $ do
      out <- processLine (Left "沒有設定 --url / STORYFLOW_URL") tools (reqLine 1 "initialize" (object []))
      code <- errorCodeOf out
      dataCode <- errorDataCodeOf out
      code `shouldBe` -32001
      dataCode `shouldBe` Just "story_flow_url_missing"

  describe "initialize——連不上" $
    it "回 -32001,data.code 是 remote_unavailable" $
      withDeadPort $ \port -> do
        out <- processLine (Right (configFor port)) tools (reqLine 1 "initialize" (object []))
        code <- errorCodeOf out
        dataCode <- errorDataCodeOf out
        code `shouldBe` -32001
        dataCode `shouldBe` Just "remote_unavailable"

  describe "initialize——成功" $
    it "echo protocolVersion,capabilities.tools 是空物件" $
      withStub [rule "GET" "/vaults" 200 (Array mempty)] $ \stub -> do
        let params = object ["protocolVersion" .= ("2026-06-18" :: String)]
        out <- processLine (Right (configFor (stubPort stub))) tools (reqLine 1 "initialize" params)
        v <- resultOf out
        v `shouldBe` Just (object ["protocolVersion" .= ("2026-06-18" :: String), "capabilities" .= object ["tools" .= object []], "serverInfo" .= object ["name" .= ("aapms-mcp" :: String), "version" .= ("0.1.0" :: String)]])

  describe "tools/list" $
    it "回 28 筆,而且完全不連線(stub 沒被打到)" $
      withStub [] $ \stub -> do
        -- cfgResult 故意用 Left:tools/list 不該去看它,更不該去看 stub。
        out <- processLine (Left "unset") tools (reqLine 1 "tools/list" (object []))
        v <- resultOf out
        case v of
          Just (Object o) -> case KM.lookup "tools" o of
            Just (Array ts) -> length ts `shouldBe` 28
            _ -> expectationFailure "result.tools 不是陣列"
          _ -> expectationFailure "沒有 result"
        reqs <- stubRequests stub
        reqs `shouldBe` []

  describe "tools/call——成功" $
    it "打中 stub,回 isError:false" $
      withStub [rule "GET" "/vaults" 200 (Array mempty)] $ \stub -> do
        let params = object ["name" .= ("getVaults" :: String), "arguments" .= object []]
        out <- processLine (Right (configFor (stubPort stub))) tools (reqLine 1 "tools/call" params)
        v <- resultOf out
        v `shouldBe` Just (object ["content" .= [object ["type" .= ("text" :: String), "text" .= ("[]" :: String)]], "isError" .= False])

  describe "tools/call——REST 業務錯誤" $
    it "折成 isError:true,code/message 原樣沿用" $
      withStub
        [rule "GET" "/vaults" 500 (object ["error" .= object ["code" .= ("boom" :: String), "message" .= ("kaboom" :: String)]])]
        $ \stub -> do
          let params = object ["name" .= ("getVaults" :: String), "arguments" .= object []]
          out <- processLine (Right (configFor (stubPort stub))) tools (reqLine 1 "tools/call" params)
          v <- resultOf out
          v
            `shouldBe` Just
              ( object
                  [ "content" .= [object ["type" .= ("text" :: String), "text" .= ("kaboom" :: String)]]
                  , "isError" .= True
                  , "structuredContent" .= object ["code" .= ("boom" :: String), "message" .= ("kaboom" :: String)]
                  ]
              )

  describe "tools/call——未知 tool 名" $
    it "回 -32602" $
      withStub [] $ \stub -> do
        let params = object ["name" .= ("noSuchTool" :: String), "arguments" .= object []]
        out <- processLine (Right (configFor (stubPort stub))) tools (reqLine 1 "tools/call" params)
        errorCodeOf out `shouldReturn` (-32602)

  describe "tools/call——缺必填參數" $
    it "回 -32602,不打 stub" $
      withStub [] $ \stub -> do
        let params = object ["name" .= ("postWorkshop" :: String), "arguments" .= object []]
        out <- processLine (Right (configFor (stubPort stub))) tools (reqLine 1 "tools/call" params)
        errorCodeOf out `shouldReturn` (-32602)
        reqs <- stubRequests stub
        reqs `shouldBe` []

  describe "未知 method" $
    it "回 -32601" $ do
      out <- processLine (Left "unset") tools (reqLine 1 "no/such/method" (object []))
      errorCodeOf out `shouldReturn` (-32601)

  describe "通知(沒有 id)" $
    it "完全不回應" $ do
      out <- processLine (Left "unset") tools (encodeToBytes (object ["jsonrpc" .= ("2.0" :: String), "method" .= ("notifications/initialized" :: String), "params" .= object []]))
      out `shouldBe` Nothing

-- 內部 -------------------------------------------------------------------------

reqLine :: Int -> String -> Value -> BS.ByteString
reqLine idv method_ params =
  encodeToBytes (object ["jsonrpc" .= ("2.0" :: String), "id" .= idv, "method" .= method_, "params" .= params])

encodeToBytes :: Value -> BS.ByteString
encodeToBytes = LBS.toStrict . encode

parseOut :: Maybe BS.ByteString -> Value
parseOut Nothing = error "expected a response line, got Nothing"
parseOut (Just bs) = case decodeStrict bs of
  Just v -> v
  Nothing -> error ("response line is not valid JSON: " <> show bs)

errorCodeOf :: Maybe BS.ByteString -> IO Int
errorCodeOf out = case parseOut out of
  Object o -> case KM.lookup "error" o of
    Just (Object eo) -> case KM.lookup "code" eo of
      Just (Number n) -> pure (round n)
      _ -> fail "error.code 缺席或不是數字"
    _ -> fail "沒有 error 物件"
  _ -> fail "回應不是物件"

errorDataCodeOf :: Maybe BS.ByteString -> IO (Maybe String)
errorDataCodeOf out = case parseOut out of
  Object o -> case KM.lookup "error" o of
    Just (Object eo) -> case KM.lookup "data" eo of
      Just (Object d) -> case KM.lookup "code" d of
        Just (String c) -> pure (Just (T.unpack c))
        _ -> pure Nothing
      _ -> pure Nothing
    _ -> fail "沒有 error 物件"
  _ -> fail "回應不是物件"

resultOf :: Maybe BS.ByteString -> IO (Maybe Value)
resultOf out = case parseOut out of
  Object o -> pure (KM.lookup "result" o)
  _ -> fail "回應不是物件"
