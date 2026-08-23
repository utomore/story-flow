-- | JSON-RPC 2.0 訊息的型別與編解碼(llm-workshop-mcp/F005 T2)。
--
-- __一行一則訊息__:MCP 的 stdio 傳輸慣例,不是 LSP 的 @Content-Length@ 框架
-- (design.md「其餘 JSON-RPC 訊息」段)。這個模組只管單一行的位元組怎麼變成
-- 'RpcMessage'、怎麼把結果 / 錯誤變回位元組,不碰 stdin\/stdout 本身
-- ('Aapms.Mcp.Server' 的職責)。
module Aapms.Mcp.Protocol
  ( RpcMessage (..)
  , parseLine
  , encodeResult
  , encodeError
  ) where

import Data.Aeson
  ( Value (..)
  , decodeStrict
  , eitherDecodeStrict
  , encode
  , object
  , (.=)
  )
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | 一則收進來的 JSON-RPC 訊息。有 @\"id\"@ 鍵的是請求(一定要回應);沒有的是
-- 通知(一律不回應,例如 @notifications\/initialized@)。
data RpcMessage
  = RpcRequest {rmId :: Value, rmMethod :: Text, rmParams :: Value}
  | RpcNotify {rmMethod :: Text, rmParams :: Value}
  deriving stock (Show, Eq)

-- | 解析一行輸入。
--
-- 失敗有兩種:__整行不是合法 JSON__,或__是合法 JSON 但不是一個有 @\"method\"@
-- 欄位的物件__——兩者對呼叫端而言是同一件事(這一行送不出一個合法的 JSON-RPC
-- 訊息),所以共用同一個 'Left' 通道,由 'Aapms.Mcp.Server' 一律折成
-- @-32700 Parse error@。
--
-- 兩種情況都會__盡量搶救一個 @\"id\"@ 欄位__:搶救得到就讓錯誤回應帶著那個 id
-- (客戶端才知道是哪一通失敗了),搶救不到就回 'Nothing'(整行略過不回應,
-- 因為連要回給誰都不知道)。
parseLine :: BS.ByteString -> Either (Maybe Value, Text) RpcMessage
parseLine raw = case eitherDecodeStrict raw :: Either String Value of
  Left err -> Left (extractId raw, T.pack err)
  Right (Object o) -> case KM.lookup "method" o of
    Just (String m) ->
      let params = fromMaybe Null (KM.lookup "params" o)
       in case KM.lookup "id" o of
            Just i -> Right (RpcRequest i m params)
            Nothing -> Right (RpcNotify m params)
    _ -> Left (KM.lookup "id" o, "缺少合法的 \"method\" 欄位")
  Right _ -> Left (Nothing, "頂層 JSON-RPC 訊息必須是一個物件")

-- | 成功回應:@{\"jsonrpc\":\"2.0\",\"id\":…,\"result\":…}@。
encodeResult :: Value -> Value -> BS.ByteString
encodeResult idv result =
  strict $ encode (object ["jsonrpc" .= jsonrpcVersion, "id" .= idv, "result" .= result])

-- | 錯誤回應:@{\"jsonrpc\":\"2.0\",\"id\":…,\"error\":{\"code\":…,\"message\":…}}@,
-- @data@ 有值才附上。
encodeError :: Value -> Int -> Text -> Maybe Value -> BS.ByteString
encodeError idv code msg mdata =
  strict $ encode (object ["jsonrpc" .= jsonrpcVersion, "id" .= idv, "error" .= errObj])
  where
    errObj = object (["code" .= code, "message" .= msg] <> maybe [] (\d -> ["data" .= d]) mdata)

jsonrpcVersion :: Text
jsonrpcVersion = "2.0"

strict :: LBS.ByteString -> BS.ByteString
strict = LBS.toStrict

-- | 從一段__解不開的__ JSON 位元組裡,盡力搶救出一個 @\"id\"@ 欄位的值。
--
-- 作法:在原始文字裡找 @\"id\"@ 這把鑰匙,跳過空白與冒號,取下一個 JSON
-- 純量 token(字串 \/ 數字 \/ @null@),交回 aeson 解碼。任何一步失敗就回
-- 'Nothing'——這是盡力而為的搶救,不是完整的容錯解析器。
extractId :: BS.ByteString -> Maybe Value
extractId raw = do
  txt <- either (const Nothing) Just (TE.decodeUtf8' raw)
  afterKey <- dropIdKey txt
  afterColon <- dropColon afterKey
  tok <- scalarToken afterColon
  decodeStrict' (TE.encodeUtf8 tok)
  where
    decodeStrict' :: BS.ByteString -> Maybe Value
    decodeStrict' = decodeStrict

dropIdKey :: Text -> Maybe Text
dropIdKey t =
  let (_, rest) = T.breakOn "\"id\"" t
   in if T.null rest then Nothing else Just (T.drop (T.length ("\"id\"" :: Text)) rest)

dropColon :: Text -> Maybe Text
dropColon t =
  let t' = T.dropWhile isSpaceChar t
   in if T.isPrefixOf ":" t'
        then Just (T.dropWhile isSpaceChar (T.drop 1 t'))
        else Nothing

isSpaceChar :: Char -> Bool
isSpaceChar c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- | 取下一個 JSON 純量 token:一個帶引號的字串(還原跳脫的引號),或是一段
-- 直到下一個結構字元 \/ 空白為止的裸 token(數字 \/ @true@ \/ @false@ \/ @null@)。
scalarToken :: Text -> Maybe Text
scalarToken t
  | T.isPrefixOf "\"" t = ("\"" <>) <$> stringBody (T.drop 1 t)
  | otherwise =
      let tok = T.takeWhile (`notElem` (",}] \t\n\r" :: String)) t
       in if T.null tok then Nothing else Just tok
  where
    stringBody rest = case T.uncons rest of
      Nothing -> Nothing
      Just ('\\', rest') -> case T.uncons rest' of
        Just (c, rest'') -> (T.pack ['\\', c] <>) <$> stringBody rest''
        Nothing -> Nothing
      Just ('"', _) -> Just "\""
      Just (c, rest') -> (T.singleton c <>) <$> stringBody rest'
