-- | T7:每個 'StoryFlow.Service.ServiceError' 都對到規格表的狀態碼。
--
-- 分派鍵是 'StoryFlow.Service.errorCode' 的字串,不是 @StoreError@ 的建構子
-- (理由見 "StoryFlow.Server.Error")。代價是新增建構子時這裡不會編譯失敗,
-- 所以有最後那一條測試:拿 service 真的產得出來的代碼去比對 'knownCodes',
-- 少一個就代表有代碼會靜靜地落到預設的 500。
module StoryFlow.Server.ErrorMapSpec (spec) where

import Data.Aeson (Value (Object, String), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (nub, sort)
import Data.Text (Text)
import Servant (ServerError (..))
import StoryFlow.Core.Id (Ref, parseRef)
import StoryFlow.Core.Registry (EntityWarning (MissingRequiredField))
import StoryFlow.Server.Error (errorBody, knownCodes, statusForCode, toServerError)
import StoryFlow.Service
import Test.Hspec

spec :: Spec
spec = describe "ServiceError → HTTP" $ do
  describe "規格的對照表" $ do
    it "404:資源不存在" $ mapM_ (`mapsTo` 404) ["entity_not_found", "vault_not_found"]

    it "409:目前狀態不允許,客戶端調整後可重試" $
      mapM_ (`mapsTo` 409) ["stale_revision", "referenced_by", "vault_already_exists", "file_already_exists"]

    it "422:語法對、語意不成立" $
      mapM_ (`mapsTo` 422) ["validation_failed", "dangling_link_target"]

    it "400:請求本身就錯" $
      mapM_
        (`mapsTo` 400)
        ["unknown_type", "not_a_file_main", "not_a_fragment", "cannot_remove_root_node", "node_depth_exceeded"]

    it "501:不是錯誤,是還沒做" $ "cross_vault_unsupported" `mapsTo` 501

    it "500:Vault 裡的資料壞了,或伺服器的環境問題" $
      mapM_
        (`mapsTo` 500)
        ["parse_failed", "level_tree_invalid", "tree_invalid", "registry_unavailable", "registry_load_failed", "sqlite_error"]

    -- 檔案已經寫成功了,只有索引沒跟上。回 2xx 會讓客戶端繼續用過時的索引查詢。
    it "500:index_update_failed(檔案寫成功了,索引沒跟上)" $
      "index_update_failed" `mapsTo` 500

    it "認不得的代碼落到 500,不是 400" $ "某個還沒對照的代碼" `mapsTo` 500

  describe "錯誤 body" $ do
    it "形狀是 {\"error\":{\"code\":…,\"message\":…}}" $ do
      let e = UnknownType "沒這種型別"
          body = decode (errBody (toServerError e)) :: Maybe Value
      (body >>= dig ["error", "code"]) `shouldBe` Just (String (errorCode e))
      (body >>= dig ["error", "message"]) `shouldBe` Just (String (renderServiceError e))

    it "code 就是 service 的 errorCode,message 就是 renderServiceError" $
      mapM_ carriesServiceStrings sampleErrors

    it "Content-Type 是 UTF-8 的 JSON" $
      lookup "Content-Type" (errHeaders (toServerError (UnknownType "x")))
        `shouldBe` Just "application/json;charset=utf-8"

    it "errorBody 本身就是那個形狀" $
      dig ["error", "code"] (errorBody "c" "m") `shouldBe` Just (String "c")

  describe "對照表的完整性" $ do
    it "沒有重複的代碼" $ knownCodes `shouldBe` nub knownCodes

    it "service 真的產得出來的代碼全都在表上" $ do
      let produced = sort (nub (map errorCode sampleErrors))
          missing = [c | c <- produced, c `notElem` knownCodes]
      missing `shouldBe` []

-- | 這一層構造得出來的 'ServiceError'。
--
-- @StoreFailed@ 的那些構造不出來——@StoreError@ 的建構子在 @storyflow-store@ 裡,
-- 而這個測試套件與被測的 library 一樣不依賴它(T6)。那些代碼改以字串直接驗
-- (上面的對照表),涵蓋範圍是一樣的:'toServerError' 走的本來就只有字串。
sampleErrors :: [ServiceError]
sampleErrors =
  [ UnknownType "沒這種型別"
  , DanglingLinkTarget (refOf "ent-7f3a")
  , CrossVaultUnsupported (refOf "other:ent-7f3a")
  , RegistryUnavailable "找過 types/registry/"
  , ValidationFailed Nothing [MissingRequiredField "lore-fragment" "timeline"]
  ]

mapsTo :: Text -> Int -> Expectation
mapsTo code want = (code, errHTTPCode (statusForCode code)) `shouldBe` (code, want)

carriesServiceStrings :: ServiceError -> Expectation
carriesServiceStrings e = do
  let body = decode (errBody (toServerError e)) :: Maybe Value
  (errorCode e, body >>= dig ["error", "code"])
    `shouldBe` (errorCode e, Just (String (errorCode e)))
  (errorCode e, body >>= dig ["error", "message"])
    `shouldBe` (errorCode e, Just (String (renderServiceError e)))

dig :: [Text] -> Value -> Maybe Value
dig [] v = Just v
dig (k : ks) (Object o) = KM.lookup (K.fromText k) o >>= dig ks
dig _ _ = Nothing

refOf :: Text -> Ref
refOf t = either (error . show) id (parseRef t)
