-- | 連線探測、實際打 REST operation、傳輸失敗分類(llm-workshop-mcp/F005 T7)。
--
-- __不使用 @servant-client@__(查證結果 4):'StoryFlow.Mcp.Tools.toolsFromOpenApi'
-- 反推出來的是路徑模板 + method,不是 28 個手寫的 client 函式——照抄
-- @cli\/src\/StoryFlow\/Cli\/Backend.hs@ 的 @client (Proxy :: Proxy StoryFlowAPI)@
-- 寫法會讓「新增路由忘了補 tool」不會有任何測試變紅,違反驗收標準。改用
-- @http-client@ 依 @(路徑模板, method, arguments)@ 直接組一次原生 HTTP 請求。
module StoryFlow.Mcp.Client
  ( probe
  , invoke
  ) where

import Control.Exception (try)
import Data.Aeson (Value (..), decode, encode)
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , Response
  , defaultManagerSettings
  , httpLbs
  , newManager
  , parseRequest
  , responseBody
  , responseStatus
  , setQueryString
  )
import Network.HTTP.Types (Status, hAuthorization, hContentType, statusCode)
import Network.HTTP.Types.URI (urlEncode)
import StoryFlow.Mcp.Config (Config (..))
import StoryFlow.Mcp.Tools (Tool (..))

-- | 連線探測:打 @GET \/vaults@(唯一不需要目前 Vault 就能回應的既有端點,見
-- design.md 待確認假設 A4)。成功(2xx)回 'Right' @()@;失敗回 'Left'
-- @(code, message)@——連不上是 @remote_unavailable@,伺服器回了業務錯誤
-- (例如 401)就原樣沿用伺服器的 @code@\/@message@。
probe :: Config -> IO (Either (Text, Text) ())
probe cfg = do
  reqE <- try (parseRequest (T.unpack (cfgBaseUrl cfg <> "/vaults")))
  case reqE of
    Left e -> pure (Left (classifyException e))
    Right req0 -> do
      let req1 = addAuth (cfgToken cfg) (req0 {method = "GET"})
      respE <- try (sendRequest req1)
      pure $ case respE of
        Left e -> Left (classifyException e)
        Right resp
          | isOk (responseStatus resp) -> Right ()
          | otherwise -> Left (errorFromResponse resp)

-- | 實際打一次 @tools\/call@。依 'Tool' 的路徑模板把路徑參數代入、其餘引數組成
-- query string、@\"body\"@ 鍵(若有)當 JSON request body,送出對應 method 的
-- 請求。回傳原始回應 body(成功)或 @(code, message)@(REST 業務錯誤或傳輸
-- 錯誤,兩者在型別上不分——design.md「錯誤沿用 REST 的 code 與訊息」不分傳輸
-- 與業務兩層的字面意思)。
invoke :: Config -> Tool -> Value -> IO (Either (Text, Text) Value)
invoke cfg tool argsVal =
  case substitutePath (toolPath tool) argsObj of
    Left missingName ->
      pure (Left ("story_flow_mcp_missing_argument", "缺少路徑參數:" <> missingName))
    Right resolvedPath -> do
      reqE <- try (parseRequest (T.unpack (cfgBaseUrl cfg <> resolvedPath)))
      case reqE of
        Left e -> pure (Left (classifyException e))
        Right req0 -> do
          let pathNames = pathParamNames (toolPath tool)
              queryPairs =
                [ (TE.encodeUtf8 k, Just (TE.encodeUtf8 (valueToText v)))
                | (k, v) <- objToList argsObj
                , k `notElem` pathNames
                , k /= "body"
                , v /= Null
                ]
              bodyValue = KM.lookup "body" argsObj
              req1 = setQueryString queryPairs req0
              req2 = req1 {method = TE.encodeUtf8 (T.toUpper (toolMethod tool))}
              req3 = case bodyValue of
                Nothing -> req2
                Just b ->
                  req2
                    { requestBody = RequestBodyLBS (encode b)
                    , requestHeaders = (hContentType, "application/json") : requestHeaders req2
                    }
              req4 = addAuth (cfgToken cfg) req3
          respE <- try (sendRequest req4)
          pure $ case respE of
            Left e -> Left (classifyException e)
            Right resp
              | isOk (responseStatus resp) -> case decode (responseBody resp) of
                  Just v -> Right v
                  Nothing -> Left ("remote_bad_response", "伺服器回了 2xx,但 body 不是合法的 JSON")
              | otherwise -> Left (errorFromResponse resp)
  where
    argsObj = case argsVal of
      Object o -> o
      _ -> KM.empty

-- 內部 -------------------------------------------------------------------------

sendRequest :: Request -> IO (Response LBS.ByteString)
sendRequest req = do
  mgr <- newManager defaultManagerSettings
  httpLbs req mgr

isOk :: Status -> Bool
isOk st = let c = statusCode st in c >= 200 && c < 300

addAuth :: Maybe Text -> Request -> Request
addAuth Nothing req = req
addAuth (Just t) req =
  req {requestHeaders = (hAuthorization, "Bearer " <> TE.encodeUtf8 t) : requestHeaders req}

errorFromResponse :: Response LBS.ByteString -> (Text, Text)
errorFromResponse resp = case errorFields (responseBody resp) of
  Just ce -> ce
  Nothing ->
    ( "remote_bad_response"
    , "伺服器回 HTTP "
        <> T.pack (show (statusCode (responseStatus resp)))
        <> ",但 body 不是預期的 {\"error\":{\"code\",\"message\"}} 形狀"
    )

errorFields :: LBS.ByteString -> Maybe (Text, Text)
errorFields body = do
  Object o <- decode body
  Object eo <- KM.lookup "error" o
  String c <- KM.lookup "code" eo
  String m <- KM.lookup "message" eo
  pure (c, m)

-- | @http-client@ 的傳輸層失敗分類,兩個 code 字串逐字沿用
-- @cli\/src\/StoryFlow\/Cli\/Error.hs@ 的 @RemoteUnavailable@\/@RemoteBadResponse@
-- 版本(查證結果 5)。
classifyException :: HttpException -> (Text, Text)
classifyException (InvalidUrlException url reason) =
  ("remote_unavailable", "網址不合法:" <> T.pack url <> "(" <> T.pack reason <> ")")
classifyException (HttpExceptionRequest _ content_) = case content_ of
  ConnectionFailure e -> ("remote_unavailable", "連不上遠端伺服器:" <> T.pack (show e))
  ResponseTimeout -> ("remote_unavailable", "連線逾時")
  ConnectionTimeout -> ("remote_unavailable", "連線逾時")
  other -> ("remote_bad_response", "傳輸失敗:" <> T.pack (show other))

-- | 路徑模板裡的大括號名字,依原始順序。
pathParamNames :: Text -> [Text]
pathParamNames = mapMaybe braceName . T.splitOn "/"
  where
    braceName seg = T.stripPrefix "{" seg >>= T.stripSuffix "}"

-- | 把路徑模板的每個 @{name}@ 換成 @arguments[name]@ 的文字形式(URL 編碼過)。
-- 缺一個就回 'Left' 那個名字。
substitutePath :: Text -> KM.KeyMap Value -> Either Text Text
substitutePath tmpl args = T.intercalate "/" <$> traverse resolveSeg (T.splitOn "/" tmpl)
  where
    resolveSeg seg = case T.stripPrefix "{" seg >>= T.stripSuffix "}" of
      Nothing -> Right seg
      Just nm -> case KM.lookup (AK.fromText nm) args of
        Nothing -> Left nm
        Just v -> Right (urlEncodeSegment (valueToText v))

urlEncodeSegment :: Text -> Text
urlEncodeSegment = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

objToList :: KM.KeyMap Value -> [(Text, Value)]
objToList = map (\(k, v) -> (AK.toText k, v)) . KM.toList

valueToText :: Value -> Text
valueToText (String t) = t
valueToText (Number n) = case floatingOrInteger n of
  Right i -> T.pack (show (i :: Integer))
  Left d -> T.pack (show (d :: Double))
valueToText (Bool b) = if b then "true" else "false"
valueToText Null = ""
valueToText v = TE.decodeUtf8 (LBS.toStrict (encode v))
