-- | T5(llm-workshop-mcp/F004):每個 'WorkshopError' 都對到規格表的狀態碼。
--
-- 仿 "Aapms.Server.ErrorMapSpec" 的表格式斷言,分派鍵同樣是字串
-- ('Aapms.Workshop.workshopErrorCode' 的回傳值),不 pattern match
-- 'WorkshopError' 的建構子。12 個 code = 7 個工作坊自己的 + 5 個
-- 'WsLlmFailed' 原樣沿用的 @llmErrorCode@ ——後者第一次跨過 HTTP,狀態碼由本
-- feature(F004)決定。
module Aapms.Server.WorkshopErrorMapSpec (spec) where

import Data.Aeson (Value (Object, String), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub, sort)
import Data.Text (Text)
import Servant (ServerError (..))
import Aapms.Llm (LlmError (..))
import Aapms.Server.Error
  ( errorBody
  , knownWorkshopCodes
  , statusForWorkshopCode
  , toWorkshopServerError
  )
import Aapms.Workshop (WorkshopError (..), renderWorkshopError, workshopErrorCode)
import Test.Hspec

spec :: Spec
spec = describe "WorkshopError → HTTP" $ do
  describe "規格的對照表" $ do
    it "404:資源不存在" $ "workshop_session_not_found" `mapsTo` 404

    it "409:目前狀態不允許這個操作,客戶端調整後可重試" $
      mapM_ (`mapsTo` 409) ["workshop_stages_exhausted", "workshop_nothing_to_commit"]

    it "422:語法對、語意不成立" $
      mapM_
        (`mapsTo` 422)
        [ "workshop_no_stages"
        , "workshop_missing_required_field"
        , "llm_config_missing"
        , "llm_config_invalid"
        ]

    it "500:Vault 裡的資料壞了,或伺服器的環境問題" $
      mapM_ (`mapsTo` 500) ["workshop_snapshot_corrupt", "workshop_snapshot_write_failed"]

    it "502:上游(LLM 端點)回了錯誤狀態碼,或回了 2xx 但形狀不對" $
      mapM_ (`mapsTo` 502) ["llm_http_status", "llm_bad_response"]

    it "503:連不上,可重試" $ "llm_unavailable" `mapsTo` 503

    it "認不得的代碼落到 500,不是 400" $ "某個還沒對照的代碼" `mapsTo` 500

  describe "錯誤 body" $ do
    it "形狀是 {\"error\":{\"code\":…,\"message\":…}}" $ do
      let e = WsSessionNotFound "wksp-00000000"
          body = decode (errBody (toWorkshopServerError e)) :: Maybe Value
      (body >>= dig ["error", "code"]) `shouldBe` Just (String (workshopErrorCode e))
      (body >>= dig ["error", "message"]) `shouldBe` Just (String (renderWorkshopError e))

    it "code 就是 workshopErrorCode,message 就是 renderWorkshopError(涵蓋全部 12 個 code)" $
      mapM_ carriesWorkshopStrings sampleWorkshopErrors

    it "Content-Type 是 UTF-8 的 JSON" $
      lookup "Content-Type" (errHeaders (toWorkshopServerError (WsSessionNotFound "x")))
        `shouldBe` Just "application/json;charset=utf-8"

    it "errorBody 本身就是那個形狀" $
      dig ["error", "code"] (errorBody "c" "m") `shouldBe` Just (String "c")

  describe "對照表的完整性" $ do
    it "沒有重複的代碼" $ knownWorkshopCodes `shouldBe` nub knownWorkshopCodes

    it "12 個 code" $ length knownWorkshopCodes `shouldBe` 12

    it "真的產得出來的代碼全都在表上" $ do
      let produced = sort (nub (map workshopErrorCode sampleWorkshopErrors))
          missing = [c | c <- produced, c `notElem` knownWorkshopCodes]
      missing `shouldBe` []

-- | 這一層構造得出來的全部 12 個 code:7 個工作坊自己的建構子,加上
-- 'WsLlmFailed' 包住的 5 個 'LlmError' 建構子各一個樣本。
sampleWorkshopErrors :: [WorkshopError]
sampleWorkshopErrors =
  [ WsSessionNotFound "wksp-00000000"
  , WsSnapshotCorrupt "/tmp/wksp-00000000.json" "壞掉的 JSON"
  , WsSnapshotWriteFailed "/tmp/wksp-00000000.json" "磁碟滿了"
  , WsNoStages "character-fragment"
  , WsStagesExhausted "wksp-00000000"
  , WsNothingToCommit "wksp-00000000"
  , WsMissingRequiredField "lore-fragment" ["timeline"]
  , WsLlmFailed (LlmUnavailable "連線被拒")
  , WsLlmFailed (LlmHttpStatus 401 "unauthorized")
  , WsLlmFailed (LlmBadResponse "不是合法的 chat completion")
  , WsLlmFailed LlmConfigMissing
  , WsLlmFailed (LlmConfigInvalid "缺少 base_url")
  ]

mapsTo :: Text -> Int -> Expectation
mapsTo code want = (code, errHTTPCode (statusForWorkshopCode code)) `shouldBe` (code, want)

carriesWorkshopStrings :: WorkshopError -> Expectation
carriesWorkshopStrings e = do
  let body = decode (errBody (toWorkshopServerError e)) :: Maybe Value
  (workshopErrorCode e, body >>= dig ["error", "code"])
    `shouldBe` (workshopErrorCode e, Just (String (workshopErrorCode e)))
  (workshopErrorCode e, body >>= dig ["error", "message"])
    `shouldBe` (workshopErrorCode e, Just (String (renderWorkshopError e)))

dig :: [Text] -> Value -> Maybe Value
dig [] v = Just v
dig (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= dig ks
dig _ _ = Nothing
