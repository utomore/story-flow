-- | LLM 存取層的錯誤語彙。
--
-- __為什麼是獨立的一個模組__:"Aapms.Llm.Client" 與 "Aapms.Llm.Config"
-- __都要用它__ ——設定載不起來與端點連不上是同一個消費者要處理的同一件事
-- (「這次拿不到模型的回覆」),放在任一邊都會讓另一邊反向 import。
--
-- __風格與 'Aapms.Service.Error.ServiceError' 一致但型別獨立__:system.md 的
-- 全域錯誤處理策略是「每一層有自己的錯誤型別,上層不重寫下層的訊息」。
-- 'LlmError' 因此__不進__ @ServiceError@,也不被 @errorCode@ 認領;之後
-- workshop 與 conflict 第 3 層要把它端到 CLI \/ REST 時,由那一層決定怎麼翻譯。
module Aapms.Llm.Error
  ( LlmError (..)
  , renderLlmError
  , llmErrorCode
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | 一次 LLM 存取可能的失敗。
--
-- 分類的依據是__下一步不同__,不是「錯在哪一層」:401 要去改 @api_key@、
-- 200-但-形狀不對要去改 @base_url@ 指向的層級、連不上要去把地端服務叫起來,
-- 三件事對使用者是三個完全不同的動作。
--
-- __只有 'LlmUnavailable' 會被重試__(見 "Aapms.Llm.Client" 的 @chat@):
-- 模型回了但格式不對,重試也不會變對;非 2xx 通常是設定問題,重試只是把同一個
-- 錯誤做四遍。
data LlmError
  = -- | 連不上服務:連線被拒、DNS 解不出、逾時、傳輸中斷。__可重試__。
    --
    -- 帶 'Text' 而不是 @SomeException@:@SomeException@ 沒有 'Eq',而測試要
    -- @shouldBe@ 得動。內容是 @HttpExceptionContent@ 的 @show@。
    LlmUnavailable Text
  | -- | 服務回了,但狀態碼不是 2xx。狀態碼 + 回應內文(截斷)。
    LlmHttpStatus Int Text
  | -- | 回了 2xx,但 JSON 不是 OpenAI 相容的形狀。__重試不會變對__。
    LlmBadResponse Text
  | -- | Vault 的 @config.toml@ 沒有 @[llm]@ 段。
    LlmConfigMissing
  | -- | @[llm]@ 段在,但鍵缺漏 \/ 型別不對 \/ 認不得。
    LlmConfigInvalid Text
  deriving stock (Show, Eq)

-- | 繁中訊息,__每一則都說出下一步__。
--
-- 「不猜地端預設值」這條裁定的價值全在 'LlmConfigMissing' 這一則:給一組預設值
-- 看似方便,但連不上時使用者看到的是「連線失敗」而不是「你還沒設定」,那是兩個
-- 完全不同的下一步。
renderLlmError :: LlmError -> Text
renderLlmError = \case
  LlmUnavailable detail ->
    "連不上 LLM 端點:"
      <> detail
      <> ";請確認地端服務有沒有在跑,或把 `.storyflow/config.toml` 的 `[llm]` 段的 "
      <> "`base_url` 改成正確的位址"
  LlmHttpStatus code body ->
    "LLM 端點回了 HTTP "
      <> T.pack (show code)
      <> ":"
      <> body
      <> ";401 / 403 請檢查 `[llm]` 的 `api_key`,404 請檢查 `base_url` 的路徑"
  LlmBadResponse detail ->
    "LLM 端點回了 200 但內容不是 OpenAI 相容的 chat completion:"
      <> detail
      <> ";請確認 `base_url` 指向的是 `/v1` 這一層"
  LlmConfigMissing ->
    "這個 Vault 的 `.storyflow/config.toml` 沒有 `[llm]` 段;"
      <> "請加上 `[llm]` 並至少填 `base_url` 與 `model`"
  LlmConfigInvalid detail ->
    "`.storyflow/config.toml` 的 `[llm]` 段不合法:" <> detail

-- | snake_case 的穩定識別碼。給上層(CLI \/ REST)翻譯用,不隨訊息文字改動。
llmErrorCode :: LlmError -> Text
llmErrorCode = \case
  LlmUnavailable _ -> "llm_unavailable"
  LlmHttpStatus _ _ -> "llm_http_status"
  LlmBadResponse _ -> "llm_bad_response"
  LlmConfigMissing -> "llm_config_missing"
  LlmConfigInvalid _ -> "llm_config_invalid"
