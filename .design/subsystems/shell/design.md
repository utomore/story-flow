---
id: shell
type: subsystem
title: shell
description: 三個殼零業務邏輯:一份 servant 契約產出 CLI、HTTP 與 MCP 的一致行為
status: active
created: 2026-08-29
updated: 2026-09-04
parent: system
related-adr: [ADR-006, ADR-015, ADR-017]
code-paths: [api/src, backend/src, cli/src, cli/app, server/src, server/app, mcp/src, mcp/app]
---

# 介面外殼(shell)子系統架構

## 定位與範圍

主架構「子系統劃分 › 外殼 › `shell`」。這個子系統唯一負責的事情是:**八個領域如何呈現成一致的
一組指令**——統一信封、exit code、`--vault` / `--remote` 的解析、錯誤格式、OpenAPI、MCP tool 映射、
輸出編碼。ADR-015 第三條把它的紀律寫成一句可稽核的話:**`shell` 裡出現「如果 … 就 …」的業務分支,
它就是放錯地方。**

涵蓋五個套件:

| 元件 | 職責 | 關鍵約束 |
|---|---|---|
| `aapms-api` | **只有** servant 路由型別、`FromHttpApiData` / `ToHttpApiData`、`ToSchema`、OpenAPI 推導 | 不含 `servant-server` / `servant-client` / `warp`——它是三個消費端共用的契約。**依賴 `aapms-service`(與有 REST 出口的領域套件)是必要的**:路由型別引用的 View 與請求型別住在那裡,這與 legacy 現況一致 |
| `aapms-backend` | `Backend` 抽象:內嵌走 `ServiceM`、遠端走 `servant-client`。指令層看不見兩個建構子 | 依賴 `aapms-api` + `aapms-service` + `servant-client`;不含 optparse、不含 warp |
| `aapms-cli` | optparse 指令樹、唯一的渲染器、統一信封、exit code、輸出編碼;執行檔 `aapms` | 不 import `aapms-store` / `aapms-workspace` / `aapms-server` / `warp` |
| `aapms-server` | servant handler(每個一行)、`AppState`、token middleware、warp 啟動、`--openapi`;執行檔 `aapms-serve` | 不 import `aapms-store` / `aapms-workspace`;**禁止**依賴 `aapms-archive` / `-ingest` / `-reorg` |
| `aapms-mcp` | stdio JSON-RPC 迴圈、tool 映射;執行檔 `aapms-mcp` | 同上的禁止清單;經 `aapms-backend` 取得雙模式 |

> **2026-08-29 裁決,`aapms-backend` 是新增的第五個套件**:ADR-015 的套件表原本給 `shell` 四個。
> 新增的直接原因是「MCP 也走雙模式」——`Backend` 需要 `servant-client` 與 `aapms-service`,住不進
> 只有型別的 `aapms-api`(它的存在理由就是不依賴任何一邊),而讓 `aapms-mcp` 依賴 `aapms-cli`
> 會把 optparse 整套與渲染器拖進一個根本不印給人看的執行檔。

**明確不做**:

- **任何業務判斷**。包含:哪些 vault 生效(`workspace`)、擋不擋一次寫入(`service`)、
  預覽還是寫入(該操作自己的模式參數)、錯誤該不該重試。`shell` 只把字串解析成型別、把型別
  印成字串
- **錯誤訊息的措辭**。`code` 與繁中 `message` 一律來自 `service` 的 `errorCode` /
  `renderServiceError`,本層**一個字都不改寫**;只有「用法錯誤」(參數解析失敗)是本層自己的
- **重管線**。`asset scan` / `asset thumbs` / `cluster apply` / `pack reorganize` 的**執行**屬
  `asset-ingest`;本層只解析它們的參數,而且**遠端模式下以用法錯誤拒絕**(伺服器不背影像解碼
  與壓縮檔函式庫,硬規則 3)
- **縮圖的解碼**。`/thumb/<sha256>` 只讀內容定址快取的檔案並掛 `immutable` 快取標頭,不現場解碼

**與 legacy 的關係**:story-flow `api` + `cli` + `server` + `mcp` 原樣移植,再吸收 assetdb
`cli` + `server` 的**呈現部分**(業務部分依 ADR-015 第五條進 `service` 或各領域)。legacy 的
`aapms-mcp` 是純 HTTP 客戶端(只認 `--url`),本次改成雙模式。

## 對外契約(Public Interface & DTOs)

本子系統的對外契約**就是** `system.md`「系統對外介面」的第 1–3 節。這裡寫的是那三節的
可測形狀;與主架構衝突以主架構為準。

### A. 統一信封與 exit code(CLI)

```haskell
data Envelope a = Ok a | Err ErrorBody
data ErrorBody  = ErrorBody { ebCode :: Text, ebMessage :: Text }
data ExitKind   = ExitOk | ExitFailure | ExitUsage
```

`--json` 模式的輸出**恰好是一個 JSON 物件、一行**:

| 形狀 | 欄位 | 值域 | 語意 |
|---|---|---|---|
| 成功 | `ok` | 恒 `true` | — |
| 成功 | `data` | 任意 JSON;**恒存在**(無資料時是 `null` 或 `[]`,不省略鍵) | 操作結果 |
| 失敗 | `ok` | 恒 `false` | — |
| 失敗 | `error.code` | snake_case,非空;**等於 `service` 的 `errorCode`**;用法錯誤時固定 `usage_error` | 機器看的 |
| 失敗 | `error.message` | 繁中,非空,**等於 `renderServiceError`** | 人看的 |

成功與失敗的物件**不共存**:`ok == true` 時沒有 `error` 鍵,反之沒有 `data` 鍵。

| exit code | 何時 | 對應 |
|---|---|---|
| `0` | 操作成功 | `ExitOk` |
| `1` | 業務失敗(`ServiceError`)或傳輸失敗(遠端模式的 HTTP / 連線錯誤) | `ExitFailure` |
| `2` | **用法錯誤**:參數解析失敗、旗標互斥、遠端模式下呼叫重管線指令 | `ExitUsage` |

`2` 只由本層產生;`1` 一律源自 `service` 或傳輸層。**兩者不得互換**——AI Agent 用 exit code
決定「要不要改寫指令」還是「要不要重試」。

### B. 全域旗標

| 旗標 | 型別 | 值域 | 語意 |
|---|---|---|---|
| `--vault <名稱\|id>` | Maybe Text | 非空字串;與 `--remote` **互斥**(同時給 → exit 2) | 原樣交給 `service`,本層**不解讀**(名稱還是 id 由 `workspace` 判) |
| `--remote <url>` | Maybe Text | 合法的 http(s) URL;與 `--vault` 互斥 | 改走 `Backend` 的遠端建構子 |
| `--json` | Bool | 預設 `False` | 切成信封輸出;為 `True` 時**不得**輸出任何非 JSON 的行(包含作用中 vault 的提示行) |
| `--version` | Bool | — | 印一行版本後結束,不進任何操作 |

非 `--json` 模式的輸出**第一行是作用中的 vault**(ADR-008 / ADR-017 的誤操作緩解):寫入類指令
印寫入目標,查詢類指令印涵蓋的 vault 數與名稱。

### C. REST 路由(與 `service` 操作一一對應)

`aapms-api` 的 servant 型別是**唯一**契約;server、CLI 遠端模式、OpenAPI 三者由它推導。

| 路徑 | method | 對應的 `service` 操作 |
|---|---|---|
| `/vaults` | GET | `vaultList` |
| `/vaults/{selector}` | GET | `vaultInfo` |
| `/projects` | GET | `projectList` |
| `/types` · `/types/{key}` | GET | `listTypes` · `showType` |
| `/nodes` | GET | `listNodes`(query 參數即 `NodeFilter`) |
| `/nodes/{ref}` | GET · PATCH · DELETE | `getNode` · `updateMeta` · `deleteNode` |
| `/nodes/{ref}/body` | PUT | `setBody` |
| `/nodes/{ref}/children` | GET | `childrenOf` |
| `/nodes/{ref}/links` | GET · POST · DELETE | `linksOf` · `addLink` · `removeLink` |
| `/entities` | POST | `createEntity` |
| `/entities/{ref}/fragments` | POST | `addFragment` |
| `/assets/{ref}/name` | PUT | `setAssetName` |
| `/assets/{ref}/fields` | PATCH | `updateAssetMeta` |
| `/licenses` | PUT | `upsertLicense` |
| `/levels` | POST | `createLevel` |
| `/levels/{ref}` | DELETE | `deleteLevel` |
| `/levels/{ref}/nodes` | POST | `addNode` |
| `/levels/{lvl}/nodes/{ref}` | DELETE | `removeNode` |
| `/search` | GET | `search` |
| `/index` | POST | `reindex` / `refreshIndex`(query 參數 `full=true\|false`) |
| `/thumb/{sha256}` | GET | 讀 `service` 給的快取路徑後回檔案 |

| 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `{ref}` | Text | `<id>` 或 `<vault>:<id>`;由 `FromHttpApiData` 解成 `Ref` | 定址 |
| `{selector}` | Text | vault 的名稱或 id | 與 `--vault` 同一種字串 |
| `revision` | query,Int | **每個寫入 method 都必填**;缺少 → 400 `usage_error` | 樂觀鎖 |
| `mode` | query,Text | `safe`(預設)/ `force`,對應 `DeleteMode` | 刪除模式 |
| `{sha256}` | Text | 64 位小寫十六進位;不合格式 → 400 | 縮圖內容位址 |

**不暴露的**:`workspace setup` / `purge`、`vault init` / `add` / `forget` / `check`、
`project register` / `forget`,以及全部重管線指令。前者管的是**執行伺服器的那台機器**,
後者是相依隔離的必然結果。

錯誤 body 一律 `{"error":{"code":…,"message":…}}`,與 CLI 信封的 `error` **同形**。
狀態碼由 `code` 字串分派,**不 case 到 `ServiceError` 的建構子**:

| `code` | 狀態碼 |
|---|---|
| `node_not_found` / `project_selector_not_found` / `vault_selector_not_found` | 404 |
| `revision_conflict` / `logical_name_taken` | 409 |
| `validation_failed` / `unknown_type` / `dangling_link_target` / `link_target_out_of_scope` / `level_tree_invalid` / `ambiguous_ref` | 400 |
| `usage_error` | 400 |
| 其餘 | 500 |

「以 `code` 字串分派」是刻意的:狀態碼表是**呈現**,而建構子是業務;把 `ServiceError` 攤開
case 會讓 `service` 每加一個建構子就編不過,而那個編譯錯誤該出現在 `service` 的訊息表,不是這裡。

### D. MCP

stdio JSON-RPC;tool 清單由**同一份 servant 型別**映射,不另立一套。

| 面向 | 契約 |
|---|---|
| tool 命名 | 由路由推導的穩定字串(`nodes_get` / `search` / `entities_create` …),snake_case;**不帶產品前綴**(legacy 的 `story_flow_*` 退場) |
| 參數 schema | 由 `ToSchema` 推導,與 OpenAPI 同源 |
| 回傳 | 成功回 `data` 的 JSON;失敗回 `{"code":…,"message":…}`,與 REST 同形 |
| 傳輸 | **雙模式**:預設內嵌(`Backend` 的 Embedded);給 `--url` 才走遠端 |
| `--version` | 印一行版本後結束,不進 JSON-RPC 迴圈 |

**不暴露的**與 REST 相同——tool 清單是 REST 路由的映射,REST 沒有的 MCP 也沒有。

### E. `Backend` 抽象

```haskell
data Backend = Embedded Env | Remote ClientEnv
data BackendError = BusinessError ErrorBody | TransportError Text | PipelineNotRemote Text

runOp :: Backend -> Op a -> IO (Either BackendError a)
```

| 欄位 / 參數 | 型別 | 值域 | 語意 |
|---|---|---|---|
| `Op a` | — | 每個 `service` 操作一個分派函式,**三行**:一行 `Embedded`、一行 `Remote`、一行收斂 | 分派落在**操作**層,指令層看不見兩個建構子 |
| `BusinessError` | ErrorBody | `code` / `message` 原樣 | 內嵌時來自 `errorCode` / `renderServiceError`;遠端時來自 HTTP body |
| `TransportError` | Text | 只在 `Remote` 出現 | 連線失敗 / 非預期狀態碼;對應 exit `1` |
| `PipelineNotRemote` | Text | 只在 `Remote` 出現,帶指令名 | 重管線指令在遠端模式下的拒絕;對應 exit `2` |

**兩種模式輸出相同是結構上成立的**,不是靠對照測試碰運氣:分派落在操作層、渲染器只有一份、
遠端路徑由 `servant-client` 依同一份 API 型別解回同一批 View 型別。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 | 套件 | 擁有的事實 |
|---|---|---|---|
| Api.Routes | servant 路由型別 | `aapms-api` | **REST 的形狀**(路徑、method、參數位置) |
| Api.Instances | `FromHttpApiData` / `ToHttpApiData` / `ToSchema` | `aapms-api` | **線上型別與 HTTP 表示的對應** |
| Api.OpenApi | OpenAPI 3 文件推導 | `aapms-api` | — |
| Backend | 內嵌 / 遠端分派 | `aapms-backend` | **兩種模式的等價性** |
| Cli.Options | optparse 指令樹、全域旗標、互斥規則 | `aapms-cli` | **CLI 的表面語法** |
| Cli.Render | 唯一的人類可讀渲染器 | `aapms-cli` | **人類可讀輸出長什麼樣** |
| Cli.Envelope | 統一信封、exit code 對應 | `aapms-cli` | **信封形狀與 exit code 的語意** |
| Cli.Encoding | `hSetEncoding` + Windows console code page | `aapms-cli` | **輸出編碼** |
| Server.Handlers | servant handler,每個一行 | `aapms-server` | — |
| Server.State | `AppState`(只有一個 `Env`) | `aapms-server` | — |
| Server.Auth | token middleware、非回送位址的啟動閘門 | `aapms-server` | **什麼情況拒絕啟動** |
| Server.Status | `code` → HTTP 狀態碼 | `aapms-server` | **狀態碼對照表** |
| Mcp.Tools | 路由 → tool 的映射與命名 | `aapms-mcp` | **tool 名稱** |
| Mcp.Rpc | stdio JSON-RPC 迴圈 | `aapms-mcp` | — |

**`AppState` 只剩一個 `Env`**(legacy 是 `MVar (Maybe Env)`):互斥與 handle 快取已隨
`Env` 搬進 `service`(見 service 契約 A 的裁決),殼再包一層 `MVar` 只會多一個沒人守的不變量。
`Env` 的延遲開索引也由 `service` 負責——`openEnv` 本來就不開任何索引,所以「在沒有目前 vault 的
目錄裡也能服務 `GET /vaults`」這條 legacy 行為自動成立。

## 資料流管線(Data Flow Pipeline)

三條在最外層分流,進入 `service` 之後只有一條路——這正是「行為由型別保證一致」的來源。

**CLI**

```text
argv → Cli.Encoding 設好輸出編碼 → Cli.Options 解析(失敗 → exit 2)
  → 全域旗標互斥檢查(--vault 與 --remote 同時給 → exit 2)
  → 解碼成請求型別(NewEntityReq / NodeFilter / SearchQuery …)
  → Backend.runOp:Embedded 進 ServiceM;Remote 以 servant-client 打 HTTP,
    在伺服器端回到同一條路;重管線指令在 Remote 下 → PipelineNotRemote → exit 2
  → View 型別
  → --json:Cli.Envelope 包成一行 JSON;否則 Cli.Render(第一行印作用中的 vault)
  → exit code:0 / 1 / 2
```

**HTTP**

```text
request → servant 依 Api.Routes 解碼(失敗 → 400 usage_error)
  → Server.Auth:非回送位址無 token 時在**啟動階段**就已拒絕;有 token 設定則定時比較
  → Server.Handlers:一行 —— run1 st (someServiceOperation args)
  → ServiceM → View → ToJSON
  → 失敗:ServiceError → errorCode + renderServiceError → Server.Status 依 code 字串分派
```

**MCP**

```text
stdin 的 JSON-RPC → Mcp.Rpc 解析 → tool 名 → 同一份請求型別
  → Backend.runOp(預設 Embedded;有 --url 則 Remote)
  → View → JSON 寫 stdout;失敗回 {"code":…,"message":…}
  → tools/list 由 Api.Routes + ToSchema 推導,不手寫
```

三條的錯誤出口是**同一組 `code` 與同一句訊息**;唯一由本層新增的是 `usage_error`。

## 模組間公開介面(Module Interfaces)

| 呼叫方向 | 介面 |
|---|---|
| Backend → `aapms-service` | `runService` + 各業務操作;錯誤只取 `errorCode` / `renderServiceError` 的**結果字串**,不 case 建構子 |
| Backend → `aapms-api` | 由路由型別產生的 `servant-client` 函式 |
| Cli.Options → Backend | `runOp :: Backend -> Op a -> IO (Either BackendError a)`;指令層拿到的是 `Op`,看不見建構子 |
| Cli.Envelope ← Cli.Render | 兩者對同一批 View 型別工作;`--json` 走前者、否則走後者,**同一個結果只經其中一個** |
| Server.Handlers → `aapms-service` | 同 Backend 的 Embedded 那一半;handler 不自己組合兩個操作 |
| Server.Handlers → Server.Status | `statusFor :: Text -> Status`(吃 `code` 字串) |
| Mcp.Tools → `aapms-api` | 路由型別 + `ToSchema` → tool 清單與參數 schema |
| Mcp.Rpc → Backend | 同 CLI 的 `runOp` |

**方向是線性的**:`Api → Backend → {Cli, Mcp}`、`Api → Server`。`aapms-api` 不認識任何一個
下游;`Backend` 不認識 optparse 與 JSON-RPC。

## 使用的技術

沿用主架構。子系統特有的四個決定:

- **API 型別獨立成套件**:`cli --remote` 需要型別去產 `servant-client`。型別若住在 server 裡,
  CLI 就要依賴整套 HTTP 伺服器——這也是 `serve` 做成獨立執行檔 `aapms-serve` 而不是 CLI 子指令
  的同一個理由(沿用 legacy)
- **`Backend` 獨立成套件**:見「定位與範圍」的裁決
- **認證是 WAI middleware,不在路由型別裡**:`AuthProtect` 會讓 `servant-client` 多一層包裝、
  OpenAPI 多一個安全定義;middleware 讓路由型別完全不知道有認證這回事(沿用 legacy)
- **MCP 的參數解析手寫**:只有一個 `--url` 與一個 `--version`,不值得拖 optparse 進來

`ToSchema` 與 `ToJSON` **逐欄對齊**,有測試拿樣本值的 JSON 鍵集合比對 schema 的 `properties`
——兩者分開手寫是 OpenAPI 文件說謊最常見的來源(沿用 legacy)。

## 架構圖

```text
   argv                     HTTP request                 stdin(JSON-RPC)
     │                            │                             │
     ▼                            ▼                             ▼
┌──────────────┐          ┌──────────────┐             ┌──────────────┐
│  aapms-cli   │          │ aapms-server │             │  aapms-mcp   │
│ Options      │          │ Auth(mw)     │             │ Rpc          │
│ Render(唯一) │          │ Handlers 一行 │             │ Tools(映射)  │
│ Envelope     │          │ Status(code) │             │              │
│ Encoding     │          │ AppState=Env │             │              │
└──────┬───────┘          └──────┬───────┘             └──────┬───────┘
       │                         │                            │
       └────────┬────────────────┼────────────────────────────┘
                ▼                │
        ┌───────────────┐        │
        │ aapms-backend │        │      ┌─────────────────────────────┐
        │ Embedded ─────┼────────┼─────►│         aapms-api           │
        │ Remote ───────┼─ HTTP ─┘      │ Routes · Instances · OpenApi│
        └───────┬───────┘               │      (只有型別)              │
                │                       └─────────────────────────────┘
                ▼
         aapms-service(唯一業務契約)

  出口:aapms(CLI)· aapms-serve(:8787)· aapms-mcp(stdio)
  三者共用:同一組 code、同一句繁中訊息、同一批 View 型別
```

## 開發階段

對應主架構 **S3「骨幹」**,與 `workspace`、`service` 同期,是三者中的**最下游**:`service` 的
階段一(骨幹)是它的前提。S3 的交付判準有三條要在這裡才驗得到——「兩種 vault 都能經統一外殼
CRUD」「`--remote` 行為一致」「OpenAPI 輸出」。

S4–S6 各領域接上時,本子系統的工作都是同一種形狀:`api` 加路由 → `cli` 加子指令 → `mcp` 自動
多一個 tool,**不再改本文件的契約**。

## 功能總覽

<!-- BEGIN FEATURE INDEX:由 scan-status.mjs --write-index 產生,不要手改 -->
| id | feature | 階段 | 模組 | 狀態 |
|---|---|---|---|---|
| F001 | api-types-and-openapi | S3 | Api.Routes、Api.Instances、Api.OpenApi | planned |
| F002 | backend-dispatch | S3 | Backend | planned |
| F003 | cli-options-and-envelope | S3 | Cli.Options、Cli.Envelope、Cli.Encoding | planned |
| F004 | cli-render | S3 | Cli.Render | planned |
| F005 | http-server | S3 | Server.Handlers、Server.State、Server.Auth、Server.Status | planned |
| F006 | mcp-adapter | S3 | Mcp.Tools、Mcp.Rpc | planned |
<!-- END FEATURE INDEX -->

### 規劃註記(v1「功能規劃」小結原文搬移)

本節與各 feature 文檔內文出現的 `#n` 是 v1「功能規劃」表的列號,該表已在 v2 廢除。
**列號與 feature 編號一對一**(`#3` 即 shell/F003),照上方「功能總覽」表對回文檔全名。

小結:共 **6 個 features、2 個階段**;全部完成即主架構 S3 交付:兩種 vault 都能經統一外殼 CRUD、
`search` 一次回兩種、`--remote` 與內嵌行為一致、`aapms-serve --openapi` 輸出得了 OpenAPI 3。

## 不可逆決定

| 決定 | 被否決的替代方案與理由 |
|---|---|
| API 型別獨立成 `aapms-api` | **型別住在 `aapms-server` 裡**:少一個套件。否決理由是 CLI 的遠端模式要用它產 `servant-client`,連帶把整套 HTTP 伺服器拖進一個預設不開伺服器的執行檔(legacy 已為此把 `serve` 拆成獨立執行檔) |
| `Backend` 獨立成 `aapms-backend`(shell 五個套件) | **`Backend` 留在 `aapms-cli`,`aapms-mcp` 依賴 `aapms-cli`**:不動 ADR-015 的套件表。否決理由是會把 optparse 與整個渲染器拖進一個不印給人看的執行檔。**放進 `aapms-api`**:否決理由是 `aapms-api` 的存在理由就是不依賴 `servant-server` / `servant-client` 任何一邊 |
| MCP 雙模式,預設內嵌 | **維持 legacy 的純 HTTP 客戶端**:零改動。否決理由是 AI Agent 接 MCP 的標準做法是把它當子行程 spawn,要求使用者先開一個 `aapms-serve` 是永久的接入摩擦。**只內嵌不支援遠端**:分支最少,但「把圖譜接到另一台機器」在 MCP 這邊會永遠不存在 |
| 狀態碼由 `code` **字串**分派,不 case `ServiceError` | **對建構子做 case**:編譯器會提醒漏掉的新錯誤。否決理由是那個提醒會出現在**殼**裡,而新錯誤該做的事是進 `service` 的訊息表;殼對未知 `code` 回 500 是正確的預設,漏一個不該讓殼編不過 |
| 統一信封:`ok` + `data` / `error` 二選一 | **永遠同時帶 `data` 與 `error`(其一為 null)**:parse 更呆板。否決理由是 AI Agent 要多寫一次 null 判斷,而「哪個鍵存在」本身就是最短的判別式 |
| exit `1` 與 `2` 嚴格分工 | **失敗一律 `1`**:最簡單。否決理由是 AI Agent 用它決定「改寫指令」還是「重試」,混在一起等於逼它去 parse 訊息 |
| 綁非回送位址時**拒絕啟動**,不是印警告 | **印警告後照跑**(`system.md` 對外介面第 2 節的原文)。否決理由見 ADR-006 的收緊條款:警告會被忽略,而「整個 vault 暴露在區域網路上」不是靠使用者留意就能緩解的後果。本次已回頭校正主架構那句話 |
