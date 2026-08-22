-- | T2:'StoryFlow.Mcp.Protocol' 的訊息編解碼。
module StoryFlow.Mcp.ProtocolSpec (spec) where

import Data.Aeson (Value (..), decodeStrict, object, (.=))
import qualified Data.ByteString.Char8 as BS8
import StoryFlow.Mcp.Protocol (RpcMessage (..), encodeError, encodeResult, parseLine)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseLine——請求(有 id)" $
    it "解出 RpcRequest,method/params/id 都對" $ do
      parseLine "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}"
        `shouldBe` Right (RpcRequest (Number 1) "tools/list" (Object mempty))

  describe "parseLine——通知(沒有 id)" $
    it "解出 RpcNotify" $ do
      parseLine "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}"
        `shouldBe` Right (RpcNotify "notifications/initialized" (Object mempty))

  describe "parseLine——params 缺席" $
    it "退回 Null,不是解析失敗" $ do
      parseLine "{\"id\":5,\"method\":\"tools/list\"}"
        `shouldBe` Right (RpcRequest (Number 5) "tools/list" Null)

  describe "parseLine——整行不是合法 JSON" $ do
    it "id 是數字時,搶救得回那個 id" $ do
      case parseLine "{\"id\":42,\"method\":\"tools/list\", broken" of
        Left (Just (Number 42), _) -> pure ()
        other -> expectationFailure ("expected salvaged id 42, got " <> show other)

    it "id 是字串時,搶救得回那個 id" $ do
      case parseLine "{\"id\":\"abc\",\"method\": broken !!" of
        Left (Just (String "abc"), _) -> pure ()
        other -> expectationFailure ("expected salvaged id \"abc\", got " <> show other)

    it "完全找不到 id 時,回 Nothing" $ do
      case parseLine "not json at all" of
        Left (Nothing, _) -> pure ()
        other -> expectationFailure ("expected Nothing id, got " <> show other)

  describe "parseLine——合法 JSON 但沒有合法的 method" $
    it "回 Left,盡量帶上 id" $ do
      case parseLine "{\"id\":7,\"params\":{}}" of
        Left (Just (Number 7), _) -> pure ()
        other -> expectationFailure ("expected Left with id 7, got " <> show other)

  describe "encodeResult / encodeError" $ do
    it "encodeResult 往返:jsonrpc/id/result 都在" $ do
      let bytes = encodeResult (Number 1) (object ["ok" .= True])
      (decodeStrict bytes :: Maybe Value)
        `shouldBe` Just
          (object ["jsonrpc" .= ("2.0" :: String), "id" .= (1 :: Int), "result" .= object ["ok" .= True]])

    it "encodeError 沒有 data 時,error 物件只有 code/message" $ do
      let bytes = encodeError (Number 1) (-32601) "Method not found" Nothing
      (decodeStrict bytes :: Maybe Value)
        `shouldBe` Just
          ( object
              [ "jsonrpc" .= ("2.0" :: String)
              , "id" .= (1 :: Int)
              , "error" .= object ["code" .= (-32601 :: Int), "message" .= ("Method not found" :: String)]
              ]
          )

    it "encodeError 有 data 時,一併帶出去" $ do
      let bytes = encodeError (Number 1) (-32001) "boom" (Just (object ["code" .= ("remote_unavailable" :: String)]))
      (decodeStrict bytes :: Maybe Value)
        `shouldBe` Just
          ( object
              [ "jsonrpc" .= ("2.0" :: String)
              , "id" .= (1 :: Int)
              , "error" .=
                  object
                    [ "code" .= (-32001 :: Int)
                    , "message" .= ("boom" :: String)
                    , "data" .= object ["code" .= ("remote_unavailable" :: String)]
                    ]
              ]
          )

    it "每則訊息一行:encodeResult/encodeError 的輸出裡沒有換行字元" $ do
      let r = encodeResult (Number 1) (object ["ok" .= True])
          e = encodeError (Number 1) (-32601) "x" Nothing
      BS8.elem '\n' r `shouldBe` False
      BS8.elem '\n' e `shouldBe` False
