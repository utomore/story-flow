---
id: P-010
description: HTTP request 經 servant 路由解碼、token 檢查、service 操作、以 code 字串分派狀態碼,回 JSON body;--openapi 輸出 OpenAPI 3
status: ready
updated: 2026-09-06
---
# P-010-http-shell:HTTP request 經 servant 路由解碼、token 檢查、service 操作、以 code 字串分派狀態碼,回 JSON body;--openapi 輸出 OpenAPI 3

## Brief
`aapms-serve` 的殼:一份 servant 型別 `Api` 是唯一契約,server、CLI 遠端模式、OpenAPI 三者由它推導。input 是 HTTP request(路徑、method、query、body、Authorization);output 是狀態碼與 JSON body(成功回 View 的 JSON,失敗回 `{"error":{"code":…,"message":…}}`,與 CLI 信封的 error 同形)。流向:啟動閘門(綁非回送位址而沒設 token → 拒絕啟動,不是印警告)→ 路由解碼(失敗 400 usage_error;每個寫入 method 必填 revision)→ token 定時比較 → 路由對應到唯一的 `Op`(P-009 的統一請求)→ 跑 service → 成功回 JSON、失敗以 `code` 字串查狀態碼表(404 / 409 / 400 / 500),不 case ServiceError 的建構子。路由到 Op 的映射、狀態碼表、啟動閘門、定時比較、OpenAPI 推導全是純函數;warp 與 handler 是 shell。它是 S3 的第七條里程碑,對應原 shell F001 / F005。不暴露:workspace setup / purge、vault init / add / forget / check、project register / forget、全部重管線指令。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `startupCheck :: BindAddress -> Maybe Token -> Either StartupError ()` | 非回送位址沒 token 就拒絕啟動;回送位址 token 選配 | `Aapms.Server.Auth`(願望) | pure |
| 2 | `isLoopback :: BindAddress -> Bool` | 127.0.0.0/8 與 ::1 | `Aapms.Server.Auth`(願望) | pure |
| 3 | `constantTimeEq :: Token -> Token -> Bool` | 不依內容提早結束的比較 | `Aapms.Server.Auth`(願望) | pure |
| 4 | `authorize :: Maybe Token -> Maybe Token -> Either ErrorBody ()` | 設了 token 才驗;沒帶或不符回 unauthorized | `Aapms.Server.Auth`(願望) | pure |
| 5 | `routeOp :: Route -> Either ErrorBody Op` | 路由與參數翻成統一請求;缺 revision、壞 ref、壞 sha256 是 usage_error | `Aapms.Api.Routes`(願望) | pure |
| 6 | `opRoute :: Op -> Maybe Route` | 反向:哪些 Op 有路由(重管線與機器管理沒有) | `Aapms.Api.Routes`(願望) | pure |
| 7 | `statusFor :: Text -> Int` | code 字串 → 狀態碼:not_found 類 404、conflict 類 409、validation 類與 usage_error 400、其餘 500 | `Aapms.Server.Status`(願望) | pure |
| 8 | `errorBodyOf :: ServiceError -> ErrorBody` | code 與訊息來自 service | `Aapms.Backend.Op`(願望,見 P-009-cli-shell) | types |
| 9 | `responseOf :: Either ErrorBody Value -> (Int, Value)` | 成功 200 加 View 的 JSON;失敗狀態碼加 `{"error":{…}}` | `Aapms.Server.Status`(願望) | pure |
| 10 | `openApiOf :: Proxy Api -> OpenApi` | 由路由型別與 ToSchema 推導 OpenAPI 3 | `Aapms.Api.OpenApi`(願望) | pure |
| 11 | `runOp :: Backend -> Op -> IO (Either BackendError OpResult)` | 內嵌跑 service | `Aapms.Backend`(願望,見 P-009-cli-shell) | shell |
| o | `routes :: [Route]` | 觀察:契約列出的全部路由(路徑加 method) | `Aapms.Api.Routes`(願望) | types |
| o | `routeCodes :: [Text]` | 觀察:狀態碼表裡列名的 code | `Aapms.Server.Status`(願望) | types |
| o | `isReadOp :: Op -> Bool` | 觀察:讀取類 Op | `Aapms.Backend.Op`(願望) | types |
| o | `isPipelineOp :: Op -> Bool` | 觀察:重管線 Op | `Aapms.Backend.Op`(願望,見 P-009-cli-shell) | types |
| o | `isMachineOp :: Op -> Bool` | 觀察:管執行伺服器那台機器的 Op(setup / purge / vault init / add / forget / check / project register / forget) | `Aapms.Backend.Op`(願望) | types |
| o | `ebCode :: ErrorBody -> Text` | 觀察:code | `Aapms.Backend.Op`(願望,見 P-009-cli-shell) | types |
| o | `errorCode :: ServiceError -> Text` | 觀察:service 的 code | `Aapms.Service.Types` | types |
| o | `bodyCode :: Value -> Maybe Text` | 觀察:錯誤 body 裡的 error.code | `Aapms.Server.Status`(願望) | pure |
| o | `paths :: OpenApi -> [Text]` | 觀察:OpenAPI 文件裡的路徑 | `Aapms.Api.OpenApi`(願望) | pure |
| o | `routePath :: Route -> Text` | 觀察:路由的路徑 | `Aapms.Api.Routes`(願望) | types |
| = | `handle :: Maybe Token -> Maybe Token -> Route -> Either BackendError OpResult -> (Int, Value)` | 純的整條:4 → 5 → 給定後端結果 → 9 | `Aapms.Server.Handlers`(願望) | pure |
| ! | `serve :: ServeOptions -> IO ()` | 進入點:1 → warp 綁位址 → 每個 request 5 → 11 → handle | `Aapms.Server.Main`(願望) | shell |

## Laws
- LAW-1 [relation] 綁非回送位址而沒設 token 一律拒絕啟動;回送位址 token 選配
  - forall addr in BindAddress, tok in Maybe Token
  - |- (isRight (startupCheck addr tok)) == (isLoopback addr or isJust tok)
- LAW-2 [equiv] 定時比較與逐字比較結果相同
  - forall a in Token, b in Token
  - |- constantTimeEq a b == (a == b)
- LAW-3 [relation] 設了 token 才驗:沒設一律放行;設了則沒帶或不符都是 unauthorized
  - forall want in Maybe Token, got in Maybe Token
  - |- isRight (authorize want got) == (isNothing want or want == got)
- LAW-4 [roundtrip] 每條路由對應恰一個 Op,Op 反查回同一條路由;沒有路由的 Op 是重管線或機器管理
  - forall r in routes, op in rights [routeOp r]
  - |- opRoute op == Just r and not (isPipelineOp op) and not (isMachineOp op)
- LAW-5 [relation] 狀態碼由 code 字串決定:表上有的照表,表上沒有的 500
  - forall c in Text
  - given notElem c routeCodes
  - |- statusFor c == 500
- LAW-6 [relation] 錯誤回應的 body 帶同一個 code,狀態碼等於 statusFor 該 code
  - forall e in ErrorBody
  - |- fst (responseOf (Left e)) == statusFor (ebCode e) and bodyCode (snd (responseOf (Left e))) == Just (ebCode e)
- LAW-7 [relation] 成功回 200 且 body 就是 View 的 JSON
  - forall v in Value
  - |- responseOf (Right v) == (200, v)
- LAW-8 [relation] 服務錯誤的 code 與 CLI 相同來源:body 的 code 等於 errorCode
  - forall e in ServiceError
  - |- bodyCode (snd (responseOf (Left (errorBodyOf e)))) == Just (errorCode e)
- LAW-9 [relation] token 不符時整條回 401,不進 service
  - forall want in Token, got in Maybe Token, r in Route, res in Either BackendError OpResult
  - given got /= Just want
  - |- fst (handle (Just want) got r res) == 401
- LAW-10 [invariant] OpenAPI 的路徑集合等於路由的路徑集合
  - forall p in Proxy Api
  - |- sort (nub (paths (openApiOf p))) == sort (nub (map routePath routes))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 綁 `0.0.0.0:8787` 無 token;綁 `127.0.0.1:8787` 無 token | 前者拒絕啟動;後者啟動 | LAW-1 |
| EX-2 | `constantTimeEq "abc" "abd"`;`"abc" "abc"` | False;True | LAW-2 |
| EX-3 | 設 token `t`,request 帶 `t`、帶 `u`、不帶 | 放行、401、401 | LAW-3、LAW-9 |
| EX-4 | `GET /nodes/ent-1`、`PATCH /nodes/ent-1?revision=3`、`PATCH /nodes/ent-1`(缺 revision) | GetNode、UpdateMeta、`usage_error` 400 | LAW-4、LAW-5 |
| EX-5 | code `node_not_found`、`revision_conflict`、`validation_failed`、`store_failed` | 404、409、400、500 | LAW-5、LAW-6 |
| EX-6 | service 回 `UnknownType "ghost"` | 400,body `{"error":{"code":"unknown_type","message":"…"}}` | LAW-6、LAW-8 |
| EX-7 | 成功的 `vaultList` | 200,body 是 VaultView 陣列 | LAW-7 |
| EX-8 | `--openapi` | 路徑集合等於 routes 的路徑集合,含 `/search`、`/thumb/{sha256}`,不含 `/vaults/init` | LAW-10 |
| EX-9 | `POST /index?full=true` | 對應 P-001 的重建 Op(非重管線) | LAW-4 |

## 決定
- **一份 servant 型別是唯一契約;server、CLI 遠端、OpenAPI、MCP tool 清單全由它推導。** 否決:手寫路由表。理由:三個消費端一份型別,漂移編不過(ADR-006)
- **`aapms-api` 只有型別與 ToSchema,不得依賴 servant-server / servant-client / warp。** 否決:api 帶 server。理由:CLI 遠端模式與 MCP 只要型別
- **綁非回送位址沒 token 就拒絕啟動,不是印警告。** 否決:印警告。理由:警告會被忽略,整個 vault 暴露在區域網路不是靠使用者留意就能緩解(ADR-006 收緊條款)
- **狀態碼以 code 字串分派,不 case ServiceError 的建構子。** 否決:攤開建構子。理由:service 每加一個建構子這裡就編不過,而那個編譯錯誤該出現在 service 的訊息表
- **不暴露重管線與機器管理:asset scan / thumbs / cluster apply / pack reorganize、workspace setup / purge、vault init / add / forget / check、project register / forget。** 否決:全暴露。理由:重管線是相依隔離的必然結果(server 不背影像與壓縮函式庫);機器管理管的是執行伺服器那台機器
- **錯誤 body 與 CLI 信封的 error 同形,同一組 code 與訊息。** 否決:HTTP 自己的錯誤格式。理由:AI Agent 只 parse 一種形狀
- **`/thumb/{sha256}` 讀內容定址快取回檔案,immutable 快取標頭,不現場解碼。** 否決:server 端解碼。理由:server 不背 JuicyPixels(硬規則 3)
- **`aapms-server` 不得直接依賴 aapms-store 或 aapms-workspace,一律經 service。** 否決:抄捷徑。理由:「殼零業務邏輯」否則只剩口號;由 contract 套件的 CabalSpec 釘住

## 修訂記錄
無
