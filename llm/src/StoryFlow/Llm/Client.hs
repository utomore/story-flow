-- | OpenAI 相容 @\/chat\/completions@ 端點的客戶端。
--
-- 這一層的職責只有一件事:__把 @[Message]@ 送出去、把回覆或錯誤帶回來__。
--
-- 明確__不做__的三件事(契約卡的硬邊界):
--
-- * __不組 prompt__。'chat' 收到什麼 @[Message]@ 就送什麼;階段說明、硬約束片段
--   的 summary 怎麼排,是 @storyflow-workshop@ 與 @storyflow-conflict@ 第 3 層
--   各自的事
-- * __不做串流__。請求裡明寫 @\"stream\": false@ ——有些端點的預設值不是 false
-- * __不引入重量級 LLM SDK__。只有 @http-client@ + @http-client-tls@ + @aeson@
module StoryFlow.Llm.Client
  ( -- * 訊息
    Role (..)
  , Message (..)

    -- * 客戶端
  , LlmClient
  , newLlmClient
  , chat
  ) where

import Control.Exception (try)
import Data.Aeson (FromJSON (..), Value, eitherDecode, encode, object, withObject, (.:), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client
  ( HttpException (..)
  , Manager
  , Request (..)
  , RequestBody (RequestBodyLBS)
  , Response
  , httpLbs
  , managerResponseTimeout
  , parseRequest
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import StoryFlow.Llm.Config (LlmConfig (..), chatEndpoint)
import StoryFlow.Llm.Error (LlmError (..))

-- 訊息 -------------------------------------------------------------------------

-- | 一則訊息的角色。線上的編碼是小寫字串(見 'roleWire'),與 Haskell 建構子的
-- 大小寫不同,所以__不用 generic 推導__。
data Role = System | User | Assistant
  deriving stock (Show, Eq)

-- | 一則訊息。
--
-- __住在 @storyflow-llm@ 而不是 @storyflow-workshop@__:'chat' 的簽名要用它,
-- 而依賴方向是 @workshop → llm@。型別若住在 workshop,llm 就得反過來依賴
-- workshop,@conflict-detection@ 第 3 層也會被迫把整個工作坊拖進來。
-- @design.md@ 把它們寫在工作坊那一節是__敘事上的分組__,不是套件歸屬。
data Message = Message
  { msgRole :: Role
  , msgContent :: Text
  }
  deriving stock (Show, Eq)

-- 客戶端 -----------------------------------------------------------------------

-- | 不透明:內部是一個 @Manager@ 加上它的設定。
--
-- __Manager 建一次、隨 'LlmClient' 一起被消費者持有並重用__ ——@http-client@ 的
-- 連線池就在它裡面,每次呼叫都新建一個等於每次都重新握手。
data LlmClient = LlmClient
  { clientCfg :: LlmConfig
  , clientManager :: Manager
  }

-- | 建立客戶端。__全函式__:契約簽名 @LlmConfig -> IO LlmClient@ 沒有錯誤通道,
-- 而拿得到 'LlmConfig' 的那一刻設定就已經是好的了——@[llm]@ 段缺漏、鍵打錯、
-- @base_url@ 不合法,全部在 'StoryFlow.Llm.Config.parseLlmConfig' 那一步就爆掉。
--
-- __用 @http-client-tls@ 的 manager 而不是 @defaultManagerSettings@__:同一個
-- manager 要同時吃地端的 @http:\/\/127.0.0.1:8080@ 與雲端的 @https:\/\/…@,
-- 這正是驗收標準 1 說的「地端與雲端共用同一組呼叫路徑」。
newLlmClient :: LlmConfig -> IO LlmClient
newLlmClient cfg =
  LlmClient cfg
    <$> newTlsManagerWith
      tlsManagerSettings
        { managerResponseTimeout = responseTimeoutMicro (lcTimeout cfg * 1000)
        }

-- | 送出一輪對話,拿回模型的回覆。
--
-- __重試__:總嘗試次數是 @1 + 'lcRetries'@,而且__只有這一次的結果是
-- 'LlmUnavailable' 時才會有下一次__。模型回了但格式不對,重試也不會變對;
-- 非 2xx 通常是設定問題(401 是 @api_key@、404 是 @base_url@),重試只是把
-- 同一個錯誤做四遍。
--
-- __不做退避睡眠__:連線被拒是立刻失敗的,而逾時已經等過 'lcTimeout' 了,
-- 再加睡眠只會讓一個本來就慢的失敗更慢。
--
-- 回傳的是__最後一次__的錯誤而不是第一次:最後一次才反映當下的狀態。
chat :: LlmClient -> [Message] -> IO (Either LlmError Text)
chat client msgs = go (lcRetries (clientCfg client))
  where
    go remaining =
      attempt client msgs >>= \case
        Left e@(LlmUnavailable _)
          | remaining > 0 -> go (remaining - 1)
          | otherwise -> pure (Left e)
        r -> pure r

-- | 一次嘗試:組請求 → 送出 → 分類結果。
attempt :: LlmClient -> [Message] -> IO (Either LlmError Text)
attempt LlmClient {..} msgs = do
  r <- try (parseRequest (chatEndpoint clientCfg) >>= \req -> httpLbs (prepare req) clientManager)
  pure $ case r of
    Left e -> Left (classify e)
    Right resp -> readResponse resp
  where
    prepare req =
      req
        { method = "POST"
        , requestHeaders =
            ("Content-Type", "application/json")
              : maybe
                []
                (\k -> [("Authorization", "Bearer " <> TE.encodeUtf8 k)])
                (lcApiKey clientCfg)
        , requestBody = RequestBodyLBS (encode (chatPayload clientCfg msgs))
        , -- request 上也設一次,讓 'LlmConfig' 是逾時的唯一權威來源,
          -- 不受 manager 是否被共用影響
          responseTimeout = responseTimeoutMicro (lcTimeout clientCfg * 1000)
        }

-- 錯誤分類 ---------------------------------------------------------------------

-- | 傳輸層的例外 → 'LlmError'。
--
-- @HttpExceptionRequest@ 底下的每一個 @HttpExceptionContent@ 都是
-- 'LlmUnavailable':連線被拒、DNS 解不出、逾時、傳輸中斷,對使用者都是同一個
-- 下一步(「把服務叫起來,或把 @base_url@ 改對」),而且都是__可重試__的。
-- 保守地把沒列舉到的也歸在這裡,代價只是多試一次。
--
-- @InvalidUrlException@ 是唯一的例外:那是設定錯,重試一百次也一樣。理論上
-- 'StoryFlow.Llm.Config.parseLlmConfig' 已經擋掉了,這裡是兜底。
classify :: HttpException -> LlmError
classify = \case
  InvalidUrlException url reason ->
    LlmConfigInvalid ("`base_url` 組出的網址不合法:" <> T.pack url <> "(" <> T.pack reason <> ")")
  HttpExceptionRequest _ content -> LlmUnavailable (T.pack (show content))

-- | 回應 → 內容或錯誤。
--
-- __非 2xx 要自己看狀態碼__:'parseRequest' 產生的 @Request@ 其 @checkResponse@
-- 是 no-op,所以非 2xx __不會__丟 @StatusCodeException@,而是正常回一個
-- @Response@。
readResponse :: Response LBS.ByteString -> Either LlmError Text
readResponse resp
  | code < 200 || code > 299 = Left (LlmHttpStatus code (truncateText (bodyText resp)))
  | otherwise = case eitherDecode (responseBody resp) of
      Left err -> Left (LlmBadResponse (T.pack err))
      Right (ChatResponse []) ->
        -- 合法 JSON 但沒有任何回覆:消費者拿不到 Text,這是形狀不對而不是空回覆
        Left (LlmBadResponse "`choices` 是空陣列,端點沒有回任何內容")
      -- content 是空字串則是 Right "":空回覆是模型的合法輸出,不是格式錯誤
      Right (ChatResponse (ChatChoice c : _)) -> Right c
  where
    code = statusCode (responseStatus resp)

bodyText :: Response LBS.ByteString -> Text
bodyText = TE.decodeUtf8Lenient . LBS.toStrict . responseBody

-- | 錯誤訊息裡的回應內文要截斷:端點回 500 時常常附一整頁 HTML,原樣塞進
-- 錯誤訊息會把終端機洗掉。
truncateText :: Text -> Text
truncateText t
  | T.length t <= limit = t
  | otherwise = T.take limit t <> "…(已截斷)"
  where
    limit = 500

-- OpenAI 的線上形狀(私有)---------------------------------------------------------
--
-- 這不是本子系統的 DTO:沒有任何消費者需要看見它,所以__刻意不定義
-- ToJSON \/ FromJSON 實例在公開型別上__ ——實例藏不住,一旦替 'Message' 定義
-- 'Data.Aeson.ToJSON',OpenAI 的線上形狀就變成本套件的公開介面了。

-- | 請求體。@stream@ __明寫 false__:不做串流是硬邊界,而有些端點的預設值
-- 不是 false。
chatPayload :: LlmConfig -> [Message] -> Value
chatPayload cfg msgs =
  object
    [ "model" .= lcModel cfg
    , "messages" .= map messageJson msgs
    , "stream" .= False
    ]

messageJson :: Message -> Value
messageJson Message {..} = object ["role" .= roleWire msgRole, "content" .= msgContent]

-- | OpenAI 的角色字串。
roleWire :: Role -> Text
roleWire = \case
  System -> "system"
  User -> "user"
  Assistant -> "assistant"

-- | 回應體:只取得到 @choices@ 就夠,其餘欄位(@usage@ / @id@ / @created@…)
-- 一律忽略——端點之間差異最大的正是那些欄位,認得它們只會讓相容性變窄。
newtype ChatResponse = ChatResponse [ChatChoice]

instance FromJSON ChatResponse where
  parseJSON = withObject "chat completion" $ \o -> ChatResponse <$> o .: "choices"

newtype ChatChoice = ChatChoice Text

instance FromJSON ChatChoice where
  parseJSON = withObject "choice" $ \o ->
    o .: "message" >>= Aeson.withObject "message" (fmap ChatChoice . (.: "content"))
