-- | stdio 讀取迴圈、JSON-RPC 方法分派、@initialize@\/@tools\/list@\/@tools\/call@
-- 三個方法的接線(llm-workshop-mcp/F005 T8)。
--
-- __絕對不在 stdout 印任何非 JSON-RPC 的東西__:stdio 是協定通道,一行雜訊就會讓
-- claude code 那邊解析失敗。這個模組除了 'runServer' 迴圈裡寫出去的 JSON-RPC
-- 訊息之外,不對 stdout 做任何其他輸出。
--
-- __'processLine' 對外開放__(T8\/T15 的測試邊界):它是「一行輸入 → 最多一行
-- 輸出」這個轉換的完整邏輯,不碰 stdin\/stdout 本身。'runServer' 只是在它外面
-- 包一層讀一行、把結果寫出去、flush 的迴圈——測試因此不需要真的 spawn 子行程,
-- 直接呼叫 'processLine' 逐行核對輸出位元組就夠了。
module Aapms.Mcp.Server
  ( runServer
  , processLine
  ) where

import Data.Aeson
  ( Value (..)
  , encode
  , object
  , (.=)
  )
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Aapms.Api (aapmsOpenApi)
import Aapms.Mcp.Client (invoke, probe)
import Aapms.Mcp.Config (Config (..))
import Aapms.Mcp.Protocol (RpcMessage (..), encodeError, encodeResult, parseLine)
import Aapms.Mcp.Tools (Tool (..), lookupTool, toolsFromOpenApi)
import System.IO
  ( BufferMode (LineBuffering)
  , hFlush
  , hSetBinaryMode
  , hSetBuffering
  , isEOF
  , stdin
  , stdout
  )

-- | 進入 stdio 讀取迴圈。@cfgResult@ 是 'Aapms.Mcp.Config.resolveConfig' 的
-- 結果——沒設定連線設定__不__讓行程立刻退出(design.md「連線設定」段),那個
-- 'Left' 一路帶著,直到 @initialize@\/@tools\/call@ 才折成 JSON-RPC 回應。
runServer :: Either Text Config -> IO ()
runServer cfgResult = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout LineBuffering
  let tools = toolsFromOpenApi aapmsOpenApi
  loop tools
  where
    loop tools = do
      eof <- isEOF
      if eof
        then pure ()
        else do
          line <- BS8.hGetLine stdin
          mOut <- processLine cfgResult tools line
          maybe (pure ()) emit mOut
          loop tools

-- | __唯一__被允許寫到 stdout 的地方。每則訊息一行,寫完立刻 flush——stdio
-- 是同步協定,客戶端在等這一行。
emit :: BS.ByteString -> IO ()
emit msg = do
  BS.hPut stdout msg
  BS.hPut stdout "\n"
  hFlush stdout

-- 分派 -------------------------------------------------------------------------

-- | 一行輸入 → 最多一行輸出(不含結尾換行)。通知與「連 id 都搶救不到的壞行」
-- 回 'Nothing'——JSON-RPC 2.0 對這兩種情況本來就沒有回應。
processLine :: Either Text Config -> [Tool] -> BS.ByteString -> IO (Maybe BS.ByteString)
processLine cfgResult tools raw = case parseLine raw of
  Left (Just idv, err) -> pure (Just (encodeError idv (-32700) ("Parse error: " <> err) Nothing))
  Left (Nothing, _) -> pure Nothing
  Right (RpcNotify _ _) -> pure Nothing
  Right (RpcRequest idv method_ params) -> Just <$> dispatch cfgResult tools idv method_ params

dispatch :: Either Text Config -> [Tool] -> Value -> Text -> Value -> IO BS.ByteString
dispatch cfgResult tools idv method_ params = case method_ of
  "initialize" -> handleInitialize cfgResult idv params
  "tools/list" -> pure (encodeResult idv (toolsListResult tools))
  "tools/call" -> handleToolsCall cfgResult tools idv params
  _ -> pure (encodeError idv (-32601) ("Method not found: " <> method_) Nothing)

-- initialize ---------------------------------------------------------------------

-- | 用連線設定跑一次探測(見 'probe')。沒設定連線設定,或探測連不上\/回錯誤,
-- 都回同一種形狀的 JSON-RPC error(@-32001@),訊息說出下一步。
handleInitialize :: Either Text Config -> Value -> Value -> IO BS.ByteString
handleInitialize cfgResult idv params = case cfgResult of
  Left notSetMsg ->
    pure (initErrorResponse idv "story_flow_url_missing" notSetMsg)
  Right cfg -> do
    result <- probe cfg
    pure $ case result of
      Left (code, msg) -> initErrorResponse idv code (connectFailMessage cfg msg)
      Right () -> encodeResult idv (initializeResult (protocolVersionOf params))

initErrorResponse :: Value -> Text -> Text -> BS.ByteString
initErrorResponse idv code msg = encodeError idv (-32001) msg (Just (object ["code" .= code]))

connectFailMessage :: Config -> Text -> Text
connectFailMessage cfg msg =
  "連不上 aapms 伺服器("
    <> cfgBaseUrl cfg
    <> "):"
    <> msg
    <> "\n請先跑 aapms-serve,或以 --url / STORYFLOW_URL 指到正確的位址"

-- | echo 回客戶端送來的 @protocolVersion@(design.md 待確認假設 A2),完全沒帶
-- 時退回一個保守預設值。
protocolVersionOf :: Value -> Text
protocolVersionOf (Object o) = case KM.lookup "protocolVersion" o of
  Just (String v) -> v
  _ -> defaultProtocolVersion
protocolVersionOf _ = defaultProtocolVersion

defaultProtocolVersion :: Text
defaultProtocolVersion = "2026-06-18"

initializeResult :: Text -> Value
initializeResult pv =
  object
    [ "protocolVersion" .= pv
    , "capabilities" .= object ["tools" .= object []]
    , "serverInfo" .= object ["name" .= ("aapms-mcp" :: Text), "version" .= ("0.1.0" :: Text)]
    ]

-- tools/list -----------------------------------------------------------------------

toolsListResult :: [Tool] -> Value
toolsListResult tools = object ["tools" .= map toolJson tools]

toolJson :: Tool -> Value
toolJson t =
  object
    [ "name" .= toolName t
    , "description" .= toolDescription t
    , "inputSchema" .= toolInputSchema t
    ]

-- tools/call -----------------------------------------------------------------------

-- | 未知 method\/tool 名\/缺必填參數是__協定層錯誤__(客戶端送出的不是一個合法的
-- @tools\/call@),用 JSON-RPC error。連線設定沒配好、REST 業務錯誤、傳輸失敗
-- 則是__一次工具執行的結果__,一律回 JSON-RPC 成功回應、@result.isError = true@
-- (design.md「設計取捨」段)——呼叫端的模型才看得到並能反應。
handleToolsCall :: Either Text Config -> [Tool] -> Value -> Value -> IO BS.ByteString
handleToolsCall cfgResult tools idv params = case params of
  Object o -> case KM.lookup "name" o of
    Just (String toolNm) -> case lookupTool toolNm tools of
      Nothing -> pure (encodeError idv (-32602) ("unknown tool: " <> toolNm) Nothing)
      Just tool ->
        let args = fromMaybe (object []) (KM.lookup "arguments" o)
         in case missingRequired tool args of
              Just missingName ->
                pure (encodeError idv (-32602) ("missing required argument: " <> missingName) Nothing)
              Nothing -> case cfgResult of
                Left notSetMsg ->
                  pure (encodeResult idv (toolErrorResultJson "story_flow_url_missing" notSetMsg))
                Right cfg -> do
                  result <- invoke cfg tool args
                  pure (encodeResult idv (toolResultJson result))
    _ -> pure (encodeError idv (-32602) "params.name 缺少或不是字串" Nothing)
  _ -> pure (encodeError idv (-32602) "params 必須是一個物件" Nothing)

-- | 對照 'toolInputSchema' 的 @required@ 清單,回傳第一個沒出現在 @arguments@
-- 裡的鍵名(沒有缺漏就回 'Nothing')。
missingRequired :: Tool -> Value -> Maybe Text
missingRequired tool args = case toolInputSchema tool of
  Object schemaObj -> case KM.lookup "required" schemaObj of
    Just (Array reqs) -> listToMaybe [n | n <- requiredNames, n `notElem` haveKeys]
      where
        requiredNames = [n | String n <- toList reqs]
        haveKeys = case args of
          Object o -> map AK.toText (KM.keys o)
          _ -> []
    _ -> Nothing
  _ -> Nothing

toolResultJson :: Either (Text, Text) Value -> Value
toolResultJson (Right v) =
  object
    [ "content" .= [contentText (renderValue v)]
    , "isError" .= False
    ]
toolResultJson (Left (code, msg)) = toolErrorResultJson code msg

toolErrorResultJson :: Text -> Text -> Value
toolErrorResultJson code msg =
  object
    [ "content" .= [contentText msg]
    , "isError" .= True
    , "structuredContent" .= object ["code" .= code, "message" .= msg]
    ]

contentText :: Text -> Value
contentText t = object ["type" .= ("text" :: Text), "text" .= t]

renderValue :: Value -> Text
renderValue (String t) = t
renderValue v = TE.decodeUtf8 (LBS.toStrict (encode v))
