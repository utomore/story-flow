-- | 'ServiceError' → HTTP 狀態碼與錯誤 body。
--
-- __分派走 'errorCode' 的字串,不是 @StoreError@ 的建構子__。
--
-- 這是 service-and-interfaces/F003 驗收標準 3(「@aapms-server@ 不 import @aapms-store@」)
-- 唯一走得通的作法:要對 @StoreFailed (StaleRevision …)@ 做 pattern match,就得把
-- @StoreError@ 的建構子拉進作用域,而那需要 @build-depends@ 加上 @aapms-store@
-- ——落地層就這樣爬進了介面層。
--
-- 'errorCode' 本來就是「__穩定的機器可讀識別碼__」,而且它對 @StoreError@ 的
-- 二十個建構子各給一個相異字串(@service@ 的 @storeErrorCode@)。以它當分派鍵,
-- 拿到的是同一份資訊、少一層相依,而且 CLI @--json@ 的 @code@ 與這裡的狀態碼從此
-- 由同一個函式決定,不可能各自漂移。
--
-- 代價是新增 @StoreError@ 建構子時,這裡不會編譯失敗而是靜靜地落到預設值。
-- 'knownCodes' 與它的測試(T7)就是為了補上那個編譯期保障。
module Aapms.Server.Error
  ( toServerError
  , statusForCode
  , errorBody
  , knownCodes

    -- * 工作坊(llm-workshop-mcp/F004)
  , toWorkshopServerError
  , statusForWorkshopCode
  , knownWorkshopCodes
  ) where

import Data.Aeson (Value, encode, object, (.=))
import Data.Text (Text)
import Servant
  ( ServerError (..)
  , err400
  , err404
  , err409
  , err422
  , err500
  , err501
  , err502
  , err503
  )
import Aapms.Service (ServiceError, errorCode, renderServiceError)
import Aapms.Workshop (WorkshopError, renderWorkshopError, workshopErrorCode)

-- | 錯誤 body 一律 @{"error":{"code":…,"message":…}}@。
--
-- 兩者都給:Agent 需要 @code@ 做判斷、需要 @message@ 決定怎麼跟作者說。
errorBody :: Text -> Text -> Value
errorBody code msg = object ["error" .= object ["code" .= code, "message" .= msg]]

toServerError :: ServiceError -> ServerError
toServerError e =
  base
    { errBody = encode (errorBody code (renderServiceError e))
    , errHeaders = [("Content-Type", "application/json;charset=utf-8")]
    }
  where
    code = errorCode e
    base = statusForCode code

-- | 代碼 → 狀態碼。規格的對照表逐條落在這裡。
--
-- 預設 500 而不是 400:認不得的代碼代表這張表沒跟上 @service@,那是伺服器的問題,
-- 不是客戶端送錯東西。
statusForCode :: Text -> ServerError
statusForCode = \case
  -- 404:資源不存在
  "entity_not_found" -> err404
  "vault_not_found" -> err404
  -- 409:目前狀態不允許,客戶端調整後可重試
  "stale_revision" -> err409 -- 樂觀鎖衝突,重讀後重試
  "referenced_by" -> err409 -- 加 force 就可以
  "vault_already_exists" -> err409
  "file_already_exists" -> err409
  "link_not_found" -> err404 -- 要刪的那筆關聯不在
  -- 422:語法對、語意不成立
  "validation_failed" -> err422
  "dangling_link_target" -> err422
  -- 400:請求本身就錯
  "unknown_type" -> err400
  "not_a_file_main" -> err400
  "not_a_fragment" -> err400
  "cannot_remove_root_node" -> err400
  "node_depth_exceeded" -> err400
  "registry_dir_unknown" -> err400
  -- 501:不是錯誤,是還沒做
  "cross_vault_unsupported" -> err501
  -- 500:Vault 裡的資料壞了,或伺服器的環境問題
  "parse_failed" -> err500
  "level_tree_invalid" -> err500
  "tree_invalid" -> err500
  "registry_unavailable" -> err500
  "registry_load_failed" -> err500
  "sqlite_error" -> err500
  "file_read_failed" -> err500
  "file_write_failed" -> err500
  "id_collision" -> err500
  "vault_config_invalid" -> err500
  -- 檔案已經寫成功了,只有索引沒跟上(ADR-002:索引是衍生物)。
  -- 回 2xx 會讓客戶端以為一切正常、繼續用過時的索引查詢;回 500 至少會讓它停下來。
  -- 「白寫了」與「寫了但索引壞了」的區分靠 code,不靠狀態碼。
  "index_update_failed" -> err500
  _ -> err500

-- | 這張表認得的全部代碼。
--
-- 測試拿它與 @service@ 實際產得出來的代碼比對——少一個就代表 @service@ 新增了
-- 建構子而這裡沒跟上,那個代碼會靜靜地變成 500。
knownCodes :: [Text]
knownCodes =
  [ "entity_not_found"
  , "vault_not_found"
  , "stale_revision"
  , "referenced_by"
  , "vault_already_exists"
  , "file_already_exists"
  , "link_not_found"
  , "validation_failed"
  , "dangling_link_target"
  , "unknown_type"
  , "not_a_file_main"
  , "not_a_fragment"
  , "cannot_remove_root_node"
  , "node_depth_exceeded"
  , "registry_dir_unknown"
  , "cross_vault_unsupported"
  , "parse_failed"
  , "level_tree_invalid"
  , "tree_invalid"
  , "registry_unavailable"
  , "registry_load_failed"
  , "sqlite_error"
  , "file_read_failed"
  , "file_write_failed"
  , "id_collision"
  , "vault_config_invalid"
  , "index_update_failed"
  ]

-- 工作坊(llm-workshop-mcp/F004) -------------------------------------------------

-- | 'WorkshopError' → HTTP 狀態碼與錯誤 body。與 'toServerError' 同一個形狀,
-- 分派同樣走字串(見 'statusForWorkshopCode'),不 pattern match 'WorkshopError'
-- 的建構子——server 因此不需要認得它的建構子集合會不會增減。
toWorkshopServerError :: WorkshopError -> ServerError
toWorkshopServerError e =
  base
    { errBody = encode (errorBody code (renderWorkshopError e))
    , errHeaders = [("Content-Type", "application/json;charset=utf-8")]
    }
  where
    code = workshopErrorCode e
    base = statusForWorkshopCode code

-- | 代碼 → 狀態碼。七個工作坊自己的代碼,加上 'WsLlmFailed' 原樣沿用的五個
-- @llmErrorCode@ ——後者第一次跨過 HTTP,狀態碼由本 feature(F004)決定。
statusForWorkshopCode :: Text -> ServerError
statusForWorkshopCode = \case
  -- 404:資源不存在
  "workshop_session_not_found" -> err404
  -- 409:目前狀態不允許這個操作,客戶端調整後可重試
  "workshop_stages_exhausted" -> err409
  "workshop_nothing_to_commit" -> err409
  -- 422:語法對、語意不成立
  "workshop_no_stages" -> err422
  "workshop_missing_required_field" -> err422
  "llm_config_missing" -> err422
  "llm_config_invalid" -> err422
  -- 500:Vault 裡的資料壞了,或伺服器的環境問題
  "workshop_snapshot_corrupt" -> err500
  "workshop_snapshot_write_failed" -> err500
  -- 502:上游(LLM 端點)回了一個錯誤狀態碼,或回了 2xx 但形狀不對——本服務是
  -- 那個上游的閘道
  "llm_http_status" -> err502
  "llm_bad_response" -> err502
  -- 503:連不上,可重試
  "llm_unavailable" -> err503
  _ -> err500

-- | 這張表認得的全部代碼,'Aapms.Server.WorkshopErrorMapSpec' 拿它與真的
-- 產得出來的代碼比對。
knownWorkshopCodes :: [Text]
knownWorkshopCodes =
  [ "workshop_session_not_found"
  , "workshop_snapshot_corrupt"
  , "workshop_snapshot_write_failed"
  , "workshop_no_stages"
  , "workshop_stages_exhausted"
  , "workshop_nothing_to_commit"
  , "workshop_missing_required_field"
  , "llm_unavailable"
  , "llm_http_status"
  , "llm_bad_response"
  , "llm_config_missing"
  , "llm_config_invalid"
  ]
