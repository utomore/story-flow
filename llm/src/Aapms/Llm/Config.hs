-- | LLM 端點的設定:五個欄位,以及怎麼從 Vault 的 @[llm]@ 段把它們讀出來。
--
-- __設定的唯一來源是 @ServiceM@__:'llmConfig' 走
-- 'Aapms.Service.vaultConfig' 這個內嵌出口拿 @VaultConfig@,本套件
-- __不直接依賴 @aapms-store@__ ——與 @aapms-conflict@「所有讀取經
-- @ServiceM@」是同一條紀律,由 @Aapms.Llm.CabalSpec@ 釘住。
--
-- __地端與雲端只差兩個值__:'lcBaseUrl' 與 'lcApiKey'。除此之外
-- 'Aapms.Llm.Client.newLlmClient' 與 'Aapms.Llm.Client.chat' 的程式路徑
-- 完全一致,這正是契約卡驗收標準 1 說的「同一組型別與呼叫路徑」。
module Aapms.Llm.Config
  ( -- * 設定
    LlmConfig (..)

    -- * 預設值
  , defaultLlmTimeoutMs
  , defaultLlmRetries

    -- * 載入
  , parseLlmConfig
  , llmConfig

    -- * 端點推導
  , chatEndpoint
  ) where

import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client (Request, parseRequest)
import Aapms.Llm.Error (LlmError (..))
import Aapms.Service (LlmSection (..), ServiceM, VaultConfig (..), vaultConfig)
import qualified TOML

-- | 一個 OpenAI 相容端點要知道的全部。
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text
  -- ^ 例:@http:\/\/127.0.0.1:8080\/v1@(地端)或 @https:\/\/api.openai.com\/v1@。
  -- 指向的是 @\/v1@ 那一層,@\/chat\/completions@ 由 'chatEndpoint' 接上去
  , lcModel :: Text
  , lcApiKey :: Maybe Text
  -- ^ 地端通常不用。'Nothing' 時請求__不帶__ @Authorization@ header
  , lcTimeout :: Int
  -- ^ __毫秒__。鍵名 @timeout_ms@ 把單位寫在名字裡
  , lcRetries :: Int
  -- ^ 「額外」嘗試次數;總嘗試 = @1 + lcRetries@。@0@ 代表不重試,是合法設定
  }
  deriving stock (Show, Eq)

-- | 60 秒。地端 7B 模型答一段話常常十幾秒,留了餘裕。
defaultLlmTimeoutMs :: Int
defaultLlmTimeoutMs = 60000

-- | 重試 1 次。足以吃掉「服務剛好在重啟」這種瞬時失敗,又不會把一個確定的
-- 失敗拖成四倍時間。
defaultLlmRetries :: Int
defaultLlmRetries = 1

-- | 真正會被 POST 的網址:去掉 'lcBaseUrl' 尾端的 @\/@ 再接
-- @\/chat\/completions@。
--
-- 回 'String' 而不是 'Text' 是因為它唯一的用途是餵給
-- 'Network.HTTP.Client.parseRequest'。
--
-- __住在 Config 而不是 Client__:'parseLlmConfig' 要用它做 @base_url@ 的純驗證
-- (見下),而 Client 要用它組請求。放在 Client 會讓 Config 反向 import Client,
-- 與 'Aapms.Llm.Error' 被拆出來是同一個理由。
chatEndpoint :: LlmConfig -> String
chatEndpoint cfg =
  T.unpack (T.dropWhileEnd (== '/') (lcBaseUrl cfg)) <> "/chat/completions"

-- | @[llm]@ 那張表 → 五欄設定。
--
-- __'Nothing'(沒有 @[llm]@ 段)一律 'LlmConfigMissing',不猜預設值__:給一組
-- 地端預設值看似方便,但連不上時使用者看到的是「連線失敗」而不是「你還沒設定」
-- ——那是兩個完全不同的下一步。
--
-- __未知鍵一律是錯__,理由與 'Aapms.Types.Loader' 的「不容忍未知鍵」同一條:
-- 打錯的 @timeou_ms@ 若被默默忽略,使用者會以為自己設過了。@store@ 的
-- @parseConfig@ 對最上層寬鬆,那是因為那一層__根本不解讀__;這一層解讀了,就要
-- 負責講錯字。
--
-- __@base_url@ 在解析時就驗__:'Network.HTTP.Client.parseRequest' 的
-- @MonadThrow@ 跑得動 'Maybe',所以這裡不必碰 IO 就能確認那個字串真的組得出
-- 請求。設定錯誤要在__載入時__爆掉,不是等到第一次 @chat@ 才爆。
parseLlmConfig :: Maybe LlmSection -> Either LlmError LlmConfig
parseLlmConfig Nothing = Left LlmConfigMissing
parseLlmConfig (Just (LlmSection tbl)) = do
  rejectUnknown
  baseUrl <- reqString "base_url"
  model <- reqString "model"
  apiKey <- optString "api_key"
  timeout <- optPositiveInt "timeout_ms" defaultLlmTimeoutMs
  retries <- optNonNegativeInt "retries" defaultLlmRetries
  let cfg = LlmConfig baseUrl model apiKey timeout retries
  case parseRequest (chatEndpoint cfg) :: Maybe Request of
    Nothing ->
      invalid $
        "`base_url` 不是合法的網址:「"
          <> baseUrl
          <> "」;請填成類似 `http://127.0.0.1:8080/v1` 的形式"
    Just _ -> Right cfg
  where
    invalid = Left . LlmConfigInvalid

    rejectUnknown =
      case filter (`notElem` allowedKeys) (M.keys tbl) of
        [] -> Right ()
        ks ->
          invalid $
            "認不得的鍵 "
              <> T.intercalate "、" (map tick ks)
              <> ";允許的鍵只有 "
              <> T.intercalate "、" (map tick allowedKeys)

    reqString k = case M.lookup k tbl of
      Just (TOML.String s) -> Right s
      Just _ -> invalid ("鍵 " <> tick k <> " 必須是字串")
      Nothing -> invalid ("缺少必填鍵 " <> tick k)

    optString k = case M.lookup k tbl of
      Nothing -> Right Nothing
      Just (TOML.String s) -> Right (Just s)
      Just _ -> invalid ("鍵 " <> tick k <> " 必須是字串")

    optInt k def = case M.lookup k tbl of
      Nothing -> Right def
      Just (TOML.Integer n) -> Right (fromInteger n)
      Just _ -> invalid ("鍵 " <> tick k <> " 必須是整數")

    optPositiveInt k def = do
      n <- optInt k def
      if n > 0
        then Right n
        else invalid ("鍵 " <> tick k <> " 必須大於 0")

    -- retries = 0 合法,代表「不重試」;負數不是。
    optNonNegativeInt k def = do
      n <- optInt k def
      if n >= 0
        then Right n
        else invalid ("鍵 " <> tick k <> " 不能是負數")

    tick k = "`" <> k <> "`"

-- | @[llm]@ 段允許的鍵。鍵名對齊欄位名的 snake_case,與註冊表 TOML 的
-- @allowed_links@ \/ @owner_type@ 同一種風格。
allowedKeys :: [Text]
allowedKeys = ["base_url", "model", "api_key", "timeout_ms", "retries"]

-- | 從目前 Vault 的 @.storyflow\/config.toml@ 讀出設定。
--
-- __回 @Either LlmError@ 而不是丟 @ServiceError@__:system.md 的「每一層有自己的
-- 錯誤型別,上層不重寫下層的訊息」——@aapms-llm@ 在 @service@ __之上__,
-- 往 @ServiceError@ 加建構子等於讓下層認識上層,而 @errorCode@ 也會跟著多出
-- 一批不屬於它的代碼。
llmConfig :: ServiceM (Either LlmError LlmConfig)
llmConfig = parseLlmConfig . cfgLlm <$> vaultConfig
