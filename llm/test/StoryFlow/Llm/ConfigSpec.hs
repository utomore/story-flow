-- | T5:@[llm]@ 段的解析,以及它在真 Vault 上的整合路徑。
--
-- 純函式那一半驗的是__規則__(必填、型別、未知鍵、@base_url@ 合法性);
-- 整合那一半驗的是__路徑__(設定真的經 @ServiceM@ 從 @.storyflow\/config.toml@
-- 讀得出來)。
module StoryFlow.Llm.ConfigSpec (spec) where

import qualified Data.Text as T
import StoryFlow.Llm.Config
import StoryFlow.Llm.Error
import StoryFlow.Llm.Fixtures
-- @LlmSection@ 沿用 @store@ 的定義,經 @storyflow-service@ 的門面取得
-- ——這裡只是為了寫得出 'minimalSection' 的型別簽名。
import StoryFlow.Service (LlmSection)
import Test.Hspec
import qualified TOML

spec :: Spec
spec = do
  describe "parseLlmConfig(純函式)" $ do
    it "完整的段解析出五欄" $
      parseLlmConfig
        ( rawSection
            [ ("base_url", TOML.String "http://127.0.0.1:8080/v1")
            , ("model", TOML.String "qwen2.5-14b-instruct")
            , ("api_key", TOML.String "sk-x")
            , ("timeout_ms", TOML.Integer 1500)
            , ("retries", TOML.Integer 3)
            ]
        )
        `shouldBe` Right
          LlmConfig
            { lcBaseUrl = "http://127.0.0.1:8080/v1"
            , lcModel = "qwen2.5-14b-instruct"
            , lcApiKey = Just "sk-x"
            , lcTimeout = 1500
            , lcRetries = 3
            }

    it "省略 api_key / timeout_ms / retries 時取 Nothing 與兩個預設常數" $
      parseLlmConfig (minimalSection [])
        `shouldBe` Right
          LlmConfig
            { lcBaseUrl = "http://127.0.0.1:8080/v1"
            , lcModel = "qwen2.5-14b-instruct"
            , lcApiKey = Nothing
            , lcTimeout = defaultLlmTimeoutMs
            , lcRetries = defaultLlmRetries
            }

    -- 沒有 [llm] 段是「你還沒設定」,不是「設定錯了」——兩者的下一步不同,
    -- 所以是兩個不同的建構子,而且__不猜預設值__。
    it "Nothing(沒有 [llm] 段)→ LlmConfigMissing" $
      parseLlmConfig Nothing `shouldBe` Left LlmConfigMissing

    it "缺 base_url → LlmConfigInvalid,訊息指名該鍵" $
      parseLlmConfig (rawSection [("model", TOML.String "m")])
        `shouldSatisfy` invalidMentioning "base_url"

    it "缺 model → LlmConfigInvalid,訊息指名該鍵" $
      parseLlmConfig (rawSection [("base_url", TOML.String "http://127.0.0.1:8080/v1")])
        `shouldSatisfy` invalidMentioning "model"

    it "timeout_ms 是字串 → LlmConfigInvalid" $
      parseLlmConfig (minimalSection [("timeout_ms", TOML.String "60000")])
        `shouldSatisfy` invalidMentioning "timeout_ms"

    it "retries = -1 → LlmConfigInvalid" $
      parseLlmConfig (minimalSection [("retries", TOML.Integer (-1))])
        `shouldSatisfy` invalidMentioning "retries"

    -- retries = 0 是「不重試」,是合法設定,不能跟著負數一起被擋掉。
    it "retries = 0 合法" $
      fmap lcRetries (parseLlmConfig (minimalSection [("retries", TOML.Integer 0)]))
        `shouldBe` Right 0

    it "timeout_ms = 0 不合法" $
      parseLlmConfig (minimalSection [("timeout_ms", TOML.Integer 0)])
        `shouldSatisfy` invalidMentioning "timeout_ms"

    -- 打錯的鍵若被默默忽略,使用者會以為自己設過了——與
    -- StoryFlow.Types.Loader 的「不容忍未知鍵」同一條立場。
    it "未知鍵 endpoint → LlmConfigInvalid,訊息列出允許的鍵" $ do
      let r = parseLlmConfig (minimalSection [("endpoint", TOML.String "http://x/v1")])
      r `shouldSatisfy` invalidMentioning "endpoint"
      r `shouldSatisfy` invalidMentioning "base_url"

    it "base_url 不是網址 → LlmConfigInvalid(設定錯在載入時就爆)" $
      parseLlmConfig
        ( rawSection
            [("base_url", TOML.String "不是網址"), ("model", TOML.String "m")]
        )
        `shouldSatisfy` invalidMentioning "base_url"

    it "base_url 尾端有沒有斜線都解析得過" $
      fmap lcBaseUrl (parseLlmConfig (sectionOf [("base_url", "http://127.0.0.1:8080/v1/"), ("model", "m")]))
        `shouldBe` Right "http://127.0.0.1:8080/v1/"

  describe "llmConfig(整合:真 Vault)" $ do
    it "有 [llm] 段的 Vault 讀得出設定" $
      withLlmVault
        [ "base_url = \"http://127.0.0.1:8080/v1\""
        , "model = \"qwen2.5-14b-instruct\""
        , "retries = 2"
        ]
        $ \env -> do
          r <- runS env llmConfig
          fmap lcModel r `shouldBe` Right "qwen2.5-14b-instruct"
          fmap lcRetries r `shouldBe` Right 2
          -- 沒寫的鍵取預設值,而不是變成解析錯誤
          fmap lcTimeout r `shouldBe` Right defaultLlmTimeoutMs

    it "沒有 [llm] 段的 Vault 回 LlmConfigMissing" $
      withLlmVault [] $ \env ->
        runS env llmConfig `shouldReturn` Left LlmConfigMissing

-- | 最小可用的段(base_url + model),再加上呼叫端要試的鍵。
minimalSection :: [(T.Text, TOML.Value)] -> Maybe LlmSection
minimalSection extra =
  rawSection $
    [ ("base_url", TOML.String "http://127.0.0.1:8080/v1")
    , ("model", TOML.String "qwen2.5-14b-instruct")
    ]
      <> extra

invalidMentioning :: T.Text -> Either LlmError LlmConfig -> Bool
invalidMentioning key = \case
  Left (LlmConfigInvalid msg) -> key `T.isInfixOf` msg
  _ -> False
