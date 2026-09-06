---
id: P-011
description: stdin JSON-RPC 經 tool 名映射到同一份請求型別、Backend 分派,回 stdout JSON;tools/list 由路由型別推導
status: ready
updated: 2026-09-06
---
# P-011-mcp-shell:stdin JSON-RPC 經 tool 名映射到同一份請求型別、Backend 分派,回 stdout JSON;tools/list 由路由型別推導

## Brief
`aapms-mcp` 的殼:讓 claude code / codex 直接把它當子行程 spawn 就能操作圖譜。input 是 stdin 的 JSON-RPC 訊息(`initialize`、`tools/list`、`tools/call`);output 是 stdout 的 JSON-RPC 回應。流向:解析一行 JSON-RPC → `tools/list` 由 P-010 的路由型別推導 tool 清單(名稱 snake_case、不帶產品前綴,參數 schema 與 OpenAPI 同源)→ `tools/call` 以 tool 名找到對應路由再翻成同一個 `Op`(P-009)→ `Backend` 分派(預設內嵌,`--url` 才走遠端)→ 成功回 `data` 的 JSON、失敗回 `{"code":…,"message":…}`,與 REST 同形。tool 集合 = REST 路由集合,REST 沒有的 MCP 也沒有。解析、命名、映射、回應編碼全是純函數;stdio 迴圈與 Backend 是 shell。它是 S3 的第八條里程碑,對應原 shell F006。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `parseRpc :: Text -> Either RpcError RpcRequest` | 一行 JSON-RPC 解析;壞 JSON 或缺 method 回 parse error | `Aapms.Mcp.Rpc`(願望) | pure |
| 2 | `toolName :: Route -> Text` | 路由推導穩定的 tool 名:`nodes_get`、`search`、`entities_create`…,snake_case,不帶前綴 | `Aapms.Mcp.Tools`(願望) | pure |
| 3 | `toolsOf :: [Route] -> [Tool]` | tools/list 的清單:名稱、描述、參數 schema(由 ToSchema 推導) | `Aapms.Mcp.Tools`(願望) | pure |
| 4 | `lookupTool :: [Route] -> Text -> Maybe Route` | tool 名反查路由 | `Aapms.Mcp.Tools`(願望) | pure |
| 5 | `callToOp :: Route -> Value -> Either ErrorBody Op` | tool 參數依路由翻成統一請求(與 P-010 的 routeOp 同一套參數規則) | `Aapms.Mcp.Tools`(願望) | pure |
| 6 | `routes :: [Route]` | 契約列出的全部路由 | `Aapms.Api.Routes`(願望,見 P-010-http-shell) | types |
| 7 | `encodeResult :: RpcId -> Either ErrorBody Value -> Text` | 成功回 data 的 JSON;失敗回 `{"code":…,"message":…}`;一行 | `Aapms.Mcp.Rpc`(願望) | pure |
| 8 | `backendFor :: McpOptions -> BackendMode` | 沒給 --url 是 Embedded,給了是 Remote | `Aapms.Mcp.Options`(願望) | pure |
| 9 | `runOp :: Backend -> Op -> IO (Either BackendError OpResult)` | 分派 | `Aapms.Backend`(願望,見 P-009-cli-shell) | shell |
| o | `decodeResult :: Text -> Maybe (RpcId, Either ErrorBody Value)` | 觀察:回應解回來 | `Aapms.Mcp.Rpc`(願望) | pure |
| o | `toolNames :: [Tool] -> [Text]` | 觀察:清單裡的名字 | `Aapms.Mcp.Tools`(願望) | types |
| o | `isSnakeCase :: Text -> Bool` | 觀察:只含 [a-z0-9_],非空,不以 _ 開頭 | `Aapms.Mcp.Tools`(願望) | types |
| o | `routeOp :: Route -> Either ErrorBody Op` | 觀察:P-010 的路由翻譯 | `Aapms.Api.Routes`(願望,見 P-010-http-shell) | pure |
| o | `rpcMethod :: RpcRequest -> Text` | 觀察:method | `Aapms.Mcp.Rpc`(願望) | types |
| o | `rpcId :: RpcRequest -> RpcId` | 觀察:id | `Aapms.Mcp.Rpc`(願望) | types |
| o | `mcpUrl :: McpOptions -> Maybe Text` | 觀察:--url | `Aapms.Mcp.Options`(願望) | types |
| o | `isEmbedded :: BackendMode -> Bool` | 觀察:內嵌模式 | `Aapms.Backend.Op`(願望) | types |
| o | `ebCode :: ErrorBody -> Text` | 觀察:code | `Aapms.Backend.Op`(願望,見 P-009-cli-shell) | types |
| = | `handleRpc :: [Route] -> RpcRequest -> Either BackendError OpResult -> Text` | 純的整條:依 method 分流 tools/list(3)或 tools/call(4 → 5 → 給定後端結果 → 7) | `Aapms.Mcp.Rpc`(願望) | pure |
| ! | `mcpMain :: IO ()` | 進入點:8 → 逐行 stdin 1 → 5 → 9 → handleRpc → 寫 stdout | `Aapms.Mcp.Main`(願望) | shell |

## Laws
- LAW-1 [invariant] tool 名都是 snake_case、不帶產品前綴、兩兩相異
  - forall rs in [routes], names in [map toolName rs]
  - |- all isSnakeCase names and nub names == names and all (not . isPrefixOf "story_flow_") names and all (not . isPrefixOf "aapms_") names
- LAW-2 [roundtrip] tool 名反查回同一條路由
  - forall r in routes
  - |- lookupTool routes (toolName r) == Just r
- LAW-3 [invariant] tool 集合等於路由集合,不多不少
  - forall rs in [routes]
  - |- sort (toolNames (toolsOf rs)) == sort (map toolName rs)
- LAW-4 [equiv] tools/call 翻出的 Op 與 HTTP 對同一條路由翻出的 Op 相同(參數規則一份)
  - forall r in routes, args in Value, op in rights [callToOp r args]
  - |- either (const True) (== op) (routeOp r)
- LAW-5 [roundtrip] 回應一行 JSON,解得回 id 與結果
  - forall i in RpcId, r in Either ErrorBody Value
  - |- decodeResult (encodeResult i r) == Just (i, r)
- LAW-6 [relation] 沒給 --url 是內嵌,給了是遠端
  - forall o in McpOptions
  - |- isEmbedded (backendFor o) == isNothing (mcpUrl o)
- LAW-7 [relation] 不存在的 tool 名回錯誤,不進後端
  - forall rs in [routes], req in RpcRequest, nm in Text, res in Either BackendError OpResult
  - given rpcMethod req == "tools/call" and isNothing (lookupTool rs nm)
  - |- fmap (either ebCode (const "") . snd) (decodeResult (handleRpc rs req res)) == Just "unknown_tool"
- LAW-8 [total] 任何一行文字都解得出結果或錯誤,不拋例外
  - forall t in Text
  - |- total (parseRpc t)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `GET /nodes/{ref}`、`POST /entities`、`GET /search` | `nodes_get`、`entities_create`、`search` | LAW-1、LAW-2 |
| EX-2 | `tools/list` | 名字集合等於路由集合;沒有 `vault_init`、沒有 `asset_scan` | LAW-3 |
| EX-3 | `tools/call nodes_get {"ref":"ent-1"}` | 與 `GET /nodes/ent-1` 同一個 GetNode Op | LAW-4 |
| EX-4 | `encodeResult 7 (Right {…})`;`encodeResult 8 (Left (ErrorBody "node_not_found" "…"))` | 各一行,解得回 id 與結果 | LAW-5 |
| EX-5 | 不給 `--url`;給 `--url http://x` | Embedded;Remote | LAW-6 |
| EX-6 | `tools/call ghost_tool {}` | `{"code":"unknown_tool","message":"找不到 tool:ghost_tool"}` | LAW-7 |
| EX-7 | stdin 一行 `not json` | parse error 回應,不拋例外 | LAW-8 |

## 決定
- **tool 清單由同一份路由型別推導,不另立一套;REST 沒有的 MCP 也沒有。** 否決:手寫 tool 表。理由:AI Agent 只 parse 一種形狀(system.md 核心功能 6)
- **預設內嵌,`--url` 才遠端;與 CLI 共用同一個 Backend。** 否決:MCP 只是 HTTP client。理由:AI Agent 直接 spawn 就能用,不必先開 aapms-serve(原 2026-08-29 裁決)
- **tool 名 snake_case、不帶產品前綴。** 否決:沿用 legacy 的 `story_flow_*`。理由:產品改名了,前綴只剩歷史
- **失敗回 `{"code":…,"message":…}`,與 REST 錯誤 body 同形。** 否決:JSON-RPC error 物件。理由:同一組 code 與訊息
- **`--version` 印一行版本後結束,不進 JSON-RPC 迴圈。** 否決:當成 tool。理由:那是執行檔的事
- **`aapms-mcp` 不得依賴 aapms-cli(拖進 optparse)也不得依賴 aapms-store / aapms-workspace。** 否決:依賴 cli 共用 Backend。理由:Backend 住 aapms-backend

## 修訂記錄
無
