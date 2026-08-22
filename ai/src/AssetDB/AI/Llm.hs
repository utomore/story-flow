-- | 與本機 OpenAI 相容端點(llama.cpp)之間的傳輸層。
--
-- == 這個模組刻意不知道素材是什麼
--
-- 對外的接縫只有一個:@'Endpoint' -> 'Value' -> IO (Either 'LlmError' 'Value')@。
-- 所有有趣的邏輯 —— 續跑、失敗分類、詞彙約束 —— 都活在上層,因此都能在
-- 沒有 GPU、沒有推論服務的情況下測完。
--
-- == 這顆模型會做的兩件反直覺的事
--
-- 1. **它們是推理模型。** 思考過程走 @message.reasoning_content@,而
--    @message.content@ 在推理結束前是**空字串**。
--
--    能不能關掉 thinking **取決於模型的 chat template**,實測過兩顆結果相反:
--
--    * @Gemma-4-E4B-Uncensored@:@enable_thinking:false@ 與
--      @reasoning_budget:0@ 都無效,只能把 @max_tokens@ 開夠大(下限 1200)。
--    * @gemma-4-12b-it@:@enable_thinking:false@ **有效**,而且差 24 倍 ——
--      4.8 秒 826 字推理 → 0.2 秒 0 字推理,答案一樣。
--
--    所以這是設定('lcThinking'),不是寫死的假設。預設關閉:對支援的模型
--    是巨大的加速,對不支援的模型只是一個被忽略的欄位,沒有副作用。
--
--    @reasoning_format:"none"@ 則**不要用**:實測它會把未經 grammar 約束的
--    思考文字直接倒進 @content@,比留著 reasoning 更糟。
--
-- 2. **推理內容不可以當成回答。** 'clReasoning' 只用於診斷。若在 content
--    為空時回頭去讀 reasoning,等於把不受 grammar 約束的散文餵進 JSON
--    parser,再把產生的垃圾標籤寫進 @asset_tags@。所以「content 是空的」
--    是一個**有型別的錯誤**('LlmEmptyContent'),不是一個待補的空值。
module AssetDB.AI.Llm
  ( -- * 設定
    LlmConfig (..)
  , defaultLlmConfig

    -- * 控制代碼
  , Llm (..)
  , Endpoint (..)
  , newLlm
  , withLlm
  , fakeLlm

    -- * 訊息
  , Role (..)
  , Part (..)
  , Message (..)
  , systemMsg
  , userText
  , userTextImage
  , encodeMessage

    -- * 請求與回應
  , ChatRequest (..)
  , defaultChatRequest
  , encodeRequest
  , ChatReply (..)
  , Usage (..)
  , parseReply
  , replyPayload

    -- * 呼叫
  , chat
  , chatJson
  , ping

    -- * 錯誤
  , LlmError (..)
  , isTransient
  , renderLlmError
  ) where

import Control.Concurrent (threadDelay)
import AssetDB.Guard (guardedTry)
import Control.Exception (Exception, SomeException, try)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client
import Network.HTTP.Types.Status (statusCode)

--------------------------------------------------------------------------------
-- 設定

data LlmConfig = LlmConfig
  { lcBaseUrl :: Text
  -- ^ 例 @http:\/\/localhost:8080@,不含尾斜線。
  , lcModel :: Text
  , lcApiKey :: Maybe Text
  , lcMaxTokens :: Int
  , lcTemperature :: Double
  , lcTimeoutSecs :: Int
  , lcRetries :: Int
  -- ^ 只重試傳輸層失敗。見 'isTransient'。
  , lcRetryBaseMs :: Int
  , lcThinking :: Bool
  -- ^ 是否允許模型產生推理段落。預設 'False'。
  --
  -- 送出的是 @chat_template_kwargs.enable_thinking@ —— 模型的 chat template
  -- 不認得就會被忽略,所以開著這個預設值對任何模型都不會壞。
  }
  deriving stock (Eq, Show)

defaultLlmConfig :: LlmConfig
defaultLlmConfig =
  LlmConfig
    { lcBaseUrl = "http://localhost:8080"
    , lcModel = "gemma"
    , lcApiKey = Nothing
    , -- 1200 是實測的**下限**(推理剛好跑得完)。坐在下限上,任何稍長一點的
      -- 思考鏈都會變成一次 LlmTruncated,所以留 33% 餘裕。
      lcMaxTokens = 1600
    , lcTemperature = 0.2
    , -- 實測含圖 5.8 秒。120 秒是 20 倍餘裕 —— 模型冷啟動或系統換頁不該被
      -- 誤判成失敗,因為驅動器對連續的傳輸失敗會中止整批。
      lcTimeoutSecs = 120
    , lcRetries = 2
    , lcRetryBaseMs = 500
    , -- 關閉。支援的模型快 24 倍(實測 gemma-4-12b-it:4.8s → 0.2s),
      -- 不支援的模型會忽略這個欄位。要求模型思考的部分改由 schema 裡的
      -- analysis 欄位承擔 —— 那一段受 grammar 約束,而 reasoning_content
      -- 不受約束也讀不得。
      lcThinking = False
    }

--------------------------------------------------------------------------------
-- 控制代碼

data Endpoint = ChatCompletions | Models
  deriving stock (Eq, Show)

endpointPath :: Endpoint -> String
endpointPath = \case
  ChatCompletions -> "/v1/chat/completions"
  Models -> "/v1/models"

-- | @llmSend@ 是整個套件唯一的 I/O 接縫。測試以 'fakeLlm' 換掉它,
-- 就能對著 in-memory 資料庫在毫秒內跑完十小時驅動器的每一條路徑。
data Llm = Llm
  { llmConfig :: LlmConfig
  , llmSend :: Endpoint -> Value -> IO (Either LlmError Value)
  }

-- | 建一個 http-client 後端的控制代碼。
--
-- Manager 全程共用。每次請求都建新的會漏 socket 而且失去 keep-alive ——
-- 在 6,238 次呼叫的量級上那不是微優化。
newLlm :: LlmConfig -> IO Llm
newLlm cfg = do
  mgr <-
    newManager
      defaultManagerSettings
        { managerResponseTimeout = responseTimeoutMicro (lcTimeoutSecs cfg * 1000000)
        }
  pure Llm {llmConfig = cfg, llmSend = sendWithRetry cfg mgr}

withLlm :: LlmConfig -> (Llm -> IO a) -> IO a
withLlm cfg f = newLlm cfg >>= f

-- | 測試用。行為完全由傳入的函式決定。
fakeLlm :: LlmConfig -> (Endpoint -> Value -> IO (Either LlmError Value)) -> Llm
fakeLlm cfg f = Llm {llmConfig = cfg, llmSend = f}

--------------------------------------------------------------------------------
-- 訊息

data Role = System | User | Assistant
  deriving stock (Eq, Show)

roleText :: Role -> Text
roleText = \case
  System -> "system"
  User -> "user"
  Assistant -> "assistant"

data Part
  = TextPart Text
  | -- | 完整的 @data:@ URL,由 "AssetDB.AI.Image" 產生。
    ImagePart Text
  deriving stock (Eq, Show)

data Message = Message {msgRole :: Role, msgParts :: [Part]}
  deriving stock (Eq, Show)

systemMsg :: Text -> Message
systemMsg t = Message System [TextPart t]

userText :: Text -> Message
userText t = Message User [TextPart t]

userTextImage :: Text -> Text -> Message
userTextImage t url = Message User [TextPart t, ImagePart url]

-- | 單一 'TextPart' 時輸出字串形式的 @content@,否則輸出 parts 陣列。
--
-- 兩種形式伺服器都收,但純文字請求維持字串形式,可以讓它與當初做效能量測
-- 時送出的位元組完全一致 —— 那裡出現迴歸會是程式改動造成的,不會是
-- 序列化格式悄悄換了。
encodeMessage :: Message -> Value
encodeMessage (Message r ps) =
  object ["role" .= roleText r, "content" .= content]
  where
    content = case ps of
      [TextPart t] -> toJSON t
      _ -> toJSON (map part ps)
    part = \case
      TextPart t -> object ["type" .= ("text" :: Text), "text" .= t]
      ImagePart u ->
        object
          [ "type" .= ("image_url" :: Text)
          , "image_url" .= object ["url" .= u]
          ]

--------------------------------------------------------------------------------
-- 請求與回應

data ChatRequest = ChatRequest
  { crMessages :: [Message]
  , crResponseFormat :: Maybe Value
  -- ^ 由 "AssetDB.AI.Schema" 產生的 @response_format@。
  , crMaxTokens :: Maybe Int
  , crTemperature :: Maybe Double
  }

defaultChatRequest :: [Message] -> ChatRequest
defaultChatRequest ms =
  ChatRequest
    { crMessages = ms
    , crResponseFormat = Nothing
    , crMaxTokens = Nothing
    , crTemperature = Nothing
    }

encodeRequest :: LlmConfig -> ChatRequest -> Value
encodeRequest cfg ChatRequest {..} =
  object $
    [ "model" .= lcModel cfg
    , "messages" .= map encodeMessage crMessages
    , "max_tokens" .= maybe (lcMaxTokens cfg) id crMaxTokens
    , "temperature" .= maybe (lcTemperature cfg) id crTemperature
    , "stream" .= False
    , "chat_template_kwargs" .= object ["enable_thinking" .= lcThinking cfg]
    ]
      <> maybe [] (\rf -> ["response_format" .= rf]) crResponseFormat

data Usage = Usage {uPrompt :: Int, uCompletion :: Int, uTotal :: Int}
  deriving stock (Eq, Show)

data ChatReply = ChatReply
  { clContent :: Text
  -- ^ @message.content@。推理未結束時是空字串 —— 這是常態,不是異常。
  , clReasoning :: Text
  -- ^ @message.reasoning_content@。**只用於診斷**,絕不當成回答。
  , clFinish :: Text
  , clUsage :: Usage
  }
  deriving stock (Eq, Show)

parseReply :: Value -> Either LlmError ChatReply
parseReply v =
  case parseEither go v of
    Left e -> Left (LlmBadEnvelope (T.pack e))
    Right r -> Right r
  where
    go = withObject "chat.completion" $ \o -> do
      chs <- o .: "choices"
      ch <- case chs of
        (c : _) -> pure c
        [] -> fail "choices 是空陣列"
      m <- ch .: "message"
      content <- m .:? "content" .!= ""
      reasoning <- m .:? "reasoning_content" .!= ""
      finish <- ch .:? "finish_reason" .!= ""
      mu <- o .:? "usage"
      usage <- case mu of
        Nothing -> pure (Usage 0 0 0)
        Just u ->
          Usage
            <$> u .:? "prompt_tokens" .!= 0
            <*> u .:? "completion_tokens" .!= 0
            <*> u .:? "total_tokens" .!= 0
      pure
        ChatReply
          { clContent = content
          , clReasoning = reasoning
          , clFinish = finish
          , clUsage = usage
          }

-- | 取出可以拿去解析的內容,或說明它為什麼不存在。
--
-- 這個函式存在的唯一理由,是把實際會發生的那一種失敗 —— 推理吃光 token
-- 預算、content 是空的 —— 變成呼叫端**必須處理**的東西,而不是三層之上
-- 的一個看不出成因的 JSON parse failure。
replyPayload :: ChatReply -> Either LlmError Text
replyPayload r
  | not (T.null (T.strip (clContent r))) = Right (clContent r)
  | clFinish r == "length" = Left (LlmTruncated (uCompletion (clUsage r)))
  | otherwise = Left (LlmEmptyContent (T.take 400 (clReasoning r)))

--------------------------------------------------------------------------------
-- 錯誤

data LlmError
  = -- | 連線被拒或主機不可達 —— 服務沒開,不是這一筆的問題。
    LlmUnavailable Text
  | LlmTimeout Int
  | LlmHttpStatus Int Text
  | LlmBadEnvelope Text
  | -- | @finish_reason == "length"@,附已產生的 token 數。
    LlmTruncated Int
  | -- | content 為空,附 reasoning 前綴供診斷。
    LlmEmptyContent Text
  | -- | (解碼錯誤, 原始輸出)。受 schema 約束仍解不出來 = schema 有問題。
    LlmBadJson Text Text
  deriving stock (Eq, Show)

instance Exception LlmError

-- | 重試這個錯誤有意義嗎。
--
-- 決定驅動器是「跳過這一筆」還是「整批中止」—— 而那個區別攸關一個
-- 十小時的批次在服務中途死掉之後,佇列還在不在。
isTransient :: LlmError -> Bool
isTransient = \case
  LlmUnavailable _ -> True
  LlmTimeout _ -> True
  LlmHttpStatus s _ -> s >= 500
  _ -> False

-- | 單行,可以直接存進 @ai_error@ 欄位。
renderLlmError :: LlmError -> Text
renderLlmError =
  compact . \case
    LlmUnavailable m -> "連不上推論服務:" <> m
    LlmTimeout s -> "逾時(" <> tshow s <> " 秒)"
    LlmHttpStatus s b -> "HTTP " <> tshow s <> ":" <> T.take 200 b
    LlmBadEnvelope m -> "回應格式不是 chat completion:" <> m
    LlmTruncated n -> "輸出被截斷,推理用掉 " <> tshow n <> " tokens 而 content 仍為空"
    LlmEmptyContent r -> "content 為空,推理片段:" <> T.take 200 r
    LlmBadJson e raw -> "JSON 解析失敗(" <> e <> "):" <> T.take 200 raw
  where
    compact = T.unwords . T.words
    tshow :: Int -> Text
    tshow = T.pack . show

--------------------------------------------------------------------------------
-- 呼叫

chat :: Llm -> ChatRequest -> IO (Either LlmError ChatReply)
chat llm req = do
  r <- llmSend llm ChatCompletions (encodeRequest (llmConfig llm) req)
  pure (r >>= parseReply)

-- | 送出並把 @content@ 解成 @a@。搭配 "AssetDB.AI.Schema" 的
-- @response_format@ 使用時,失敗代表 schema 本身有問題,不是模型不聽話。
chatJson :: FromJSON a => Llm -> ChatRequest -> IO (Either LlmError a)
chatJson llm req = do
  r <- chat llm req
  pure $ do
    reply <- r
    raw <- replyPayload reply
    case eitherDecodeStrict (TE.encodeUtf8 raw) of
      Left e -> Left (LlmBadJson (T.pack e) raw)
      Right a -> Right a

-- | @GET \/v1\/models@。回傳第一個 model id。
ping :: Llm -> IO (Either LlmError Text)
ping llm = do
  r <- llmSend llm Models Null
  pure $ do
    v <- r
    ds <- envelope (withObject "models" (.: "data")) v
    case ds of
      [] -> Left (LlmBadEnvelope "models 清單是空的")
      (d : _) -> envelope (withObject "model" (.: "id")) d
  where
    envelope p x = case parseEither p x of
      Left e -> Left (LlmBadEnvelope (T.pack e))
      Right a -> Right a

--------------------------------------------------------------------------------
-- http-client 後端

sendWithRetry :: LlmConfig -> Manager -> Endpoint -> Value -> IO (Either LlmError Value)
sendWithRetry cfg mgr ep body = go 0
  where
    go n = do
      r <- sendOnce cfg mgr ep body
      case r of
        -- 只重試傳輸層失敗。LlmTruncated / LlmEmptyContent / LlmBadJson
        -- 在這裡重試等於再送一次一模一樣的請求,結果也會一模一樣 ——
        -- 那些要由驅動器改變請求(加大 token 預算)之後才有意義。
        Left e | isTransient e && n < lcRetries cfg -> do
          threadDelay (lcRetryBaseMs cfg * 1000 * (2 ^ n))
          go (n + 1)
        _ -> pure r

sendOnce :: LlmConfig -> Manager -> Endpoint -> Value -> IO (Either LlmError Value)
sendOnce cfg mgr ep body = do
  ereq <- guardedTry (parseRequest (T.unpack (lcBaseUrl cfg) <> endpointPath ep))
  case ereq of
    Left (e :: SomeException) -> pure (Left (LlmUnavailable (compact (show e))))
    Right req0 -> do
      let req =
            req0
              { method = case ep of Models -> "GET"; ChatCompletions -> "POST"
              , requestHeaders =
                  [("Content-Type", "application/json")]
                    <> maybe
                      []
                      (\k -> [("Authorization", TE.encodeUtf8 ("Bearer " <> k))])
                      (lcApiKey cfg)
              , requestBody = case ep of
                  Models -> RequestBodyLBS ""
                  ChatCompletions -> RequestBodyLBS (encode body)
              , -- 讓非 2xx 以回應而不是例外的形式回來。分類乾淨得多。
                checkResponse = \_ _ -> pure ()
              }
      er <- tryHttp (httpLbs req mgr)
      pure $ case er of
        Left e -> Left e
        Right resp ->
          let code = statusCode (responseStatus resp)
              raw = responseBody resp
           in if code < 200 || code >= 300
                then Left (LlmHttpStatus code (T.take 400 (TE.decodeUtf8Lenient (BL.toStrict raw))))
                else case eitherDecode raw of
                  Left e -> Left (LlmBadEnvelope (T.pack e))
                  Right v -> Right v
  where
    compact = T.unwords . T.words . T.pack

    -- HttpException 的分類。呼叫端唯一要做的決定是「稍後重試」還是
    -- 「告訴使用者服務沒開」,所以粗分類就夠了 —— 但逾時必須與連線被拒
    -- 分開,因為前者可能只是模型還在載入。
    tryHttp act = do
      r <- try @HttpException act
      pure $ case r of
        Right x -> Right x
        Left e -> case e of
          HttpExceptionRequest _ ResponseTimeout -> Left (LlmTimeout (lcTimeoutSecs cfg))
          HttpExceptionRequest _ ConnectionTimeout -> Left (LlmTimeout (lcTimeoutSecs cfg))
          HttpExceptionRequest _ (ConnectionFailure ce) -> Left (LlmUnavailable (compact (show ce)))
          _ -> Left (LlmUnavailable (compact (show e)))
