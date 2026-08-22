---
id: F005
type: feature
title: mcp-adapter
description: MCP stdio adapter,把 REST 的全部 operation 依 operationId 映射成 tools
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [service-and-interfaces/F003, F004]
related-adr: [ADR-006, ADR-011]
related-feature: []
---

# F005: mcp-adapter

## 功能概述

新增套件 `storyflow-mcp`(目錄 `mcp/`),提供一個 stdio 上的 JSON-RPC 2.0 伺服器(執行檔
`story-flow-mcp`),把 `service-and-interfaces` 的 REST 契約(`StoryFlowAPI`/`storyFlowOpenApi`,
目前 19 條路徑、28 個 operation)整批暴露成 MCP tools。adapter 本身**沒有業務邏輯**:
`tools/call` 收到的每一次呼叫都原樣轉成一次 HTTP 請求打 `story-flow-serve`,回應(成功或
REST 的 `{"error":{"code":…,"message":…}}`)原樣轉成 MCP tool result。

驗收標準(逐字取自契約卡):每一個 REST operation 都有對應的 MCP tool 且參數形狀來自同一份
API 型別——可測形式是 **tools 數 == OpenAPI operation 數**;tool 名字由 `operationId` 推導,
不手維護對照表;連線走 `--url` 或 `STORYFLOW_URL`/`STORYFLOW_TOKEN`(旗標優先),沒設定或
連不上就在 `initialize` 回錯誤並指出下一步;錯誤沿用 REST 的 `code` 與訊息;claude code 掛上
後不必再讀 API 文件就能建/查片段與關聯。

明確不做:不含任何業務邏輯;不 import `storyflow-service`(只打 HTTP);不自行擴充 REST 沒有
的操作;不自己拉背景 server(ADR-006 已否決)。

## 相依性

- **service-and-interfaces/F003**(`servant-api-server`,已完成):`storyflow-mcp` 直接消費它
  擁有的 `StoryFlow.Api` 模組——`StoryFlowAPI`(型別)、`storyFlowAPI`(Proxy)、
  `storyFlowOpenApi`(靜態的 `OpenApi` 值)。**MCP 的 tool 清單完全由 `storyFlowOpenApi` 這個
  編譯期就決定的值反推,不打任何 HTTP 就能算出 28 個 tools**——`tools/list` 因此不需要連線
  就能回答(連線只在 `initialize` 的探測與 `tools/call` 的實際呼叫才需要)
- **F004**(`workshop-interface`,已完成):把工作坊的三條路由(`POST /workshop`、
  `POST /workshop/:id/step`、`POST /workshop/:id/commit`)併入了 `StoryFlowAPI`,是「28 個
  operation」這個數字裡最後補上的三個。`storyflow-mcp` 不 import `storyflow-workshop`,
  但它依賴 F004 已經把這三條路由**焊進** `storyFlowAPI`/`storyFlowOpenApi` 這個既有事實
- **不算進 `depends-on` 的一筆事實**:`conflict-detection` 的 `POST /conflict/context` /
  `POST /conflict/check` 兩條路由也在 28 個 operation 之內,但它們是在 F003 之後、由
  `conflict-detection` 的 feature 併入同一份 `StoryFlowAPI` 的(那段歷史記在
  `api/test/StoryFlow/Api/ApiSpec.hs` 的註解裡)。`storyflow-mcp` 消費的是**現在的**
  `storyFlowOpenApi` 這個值,不在乎它是被哪幾個 feature 分批填滿的——所以不列
  `conflict-detection` 的任何 feature 進 `depends-on`,道理與 F004 排除 `conflict-detection`
  的 `acquireJudge` 抄寫對象相同(引用事實,不是相依）
- **另一筆不算進 `depends-on` 的引用**:「使用到的既有串接介面」表引用了
  `service-and-interfaces/B001` 定義的 `service/test/StoryFlow/Service/CabalSpec.hs` 守衛
  測試(查證結果 8)。這是**查證事實的出處**——證明「`storyflow-service` 不認得
  `storyflow-mcp`」這條硬性邊界已經有程式碼守著,本 feature 不需要為此新增任何東西——不是
  `storyflow-mcp` 呼叫或依賴 B001 引入的任何介面。`storyflow-mcp` 的套件邊界完全由它自己的
  `StoryFlow.Mcp.CabalSpec`(T10)守,與 B001 那份測試各自獨立、互不呼叫,B001 存不存在都
  不影響本 feature 能不能動工,因此不列進 `depends-on`,與上一條排除 `conflict-detection`
  引用同一個道理

**可否平行開發**:不可與尚未完成的 `service-and-interfaces`/`llm-workshop-mcp` 其他 REST 相關
feature 平行——`storyflow-mcp` 的 tool 清單斷言(`tools 數 == 28`)會隨 `StoryFlowAPI` 每次新
增路由而改變,若有新路由的 feature 同時在動工,`storyflow-mcp` 這邊的測試會頻繁改動基準值。
與本文檔查證時點(2026-08-22)的程式碼比對:`service-and-interfaces/F003` 與 `F004` 均已完成
(`status: done`),所以本 feature **現在**是可以立即動工的,不是被卡住。

## 對應的 Level 2 契約

實作 `.design/subsystems/llm-workshop-mcp/design.md` 的:

- 「對外契約」對外形式表 MCP 那一列:stdio 傳輸,tools 由 `service-and-interfaces` REST 的
  全部 operation 映射,數量不寫死
- 「模組間公開介面與資料結構」的 `Mcp.Server` → `service-and-interfaces`:「打 REST 的
  operation,不 import `storyflow-service`」
- 「MCP adapter 的連線與 tool 命名」整段(逐字):`--url`/`STORYFLOW_URL`/`STORYFLOW_TOKEN`
  旗標優先;沒設定或連不上在 `initialize` 回錯誤並說出下一步;tool 命名由 `operationId`
  推導,不手維護對照表,可測形式是 tools 數 == operation 數
- 「使用的技術」段落:MCP 走 stdio,協定層自己實作(JSON-RPC 2.0 over stdio),不引 MCP 套件
  (D5,已在 design.md 定案,本文檔不重新評估)
- 「使用到的套件」表 MCP 那一列的敘述,一字不改地落實為本文檔的實作方式

未超出 Level 2 範圍:本 feature 沒有新增業務操作,新增的公開面全部是「介面包裝層」對外的
MCP 協定訊息(JSON-RPC 的三個方法),而 REST 契約本身完全沒有變動(`StoryFlowAPI` 的型別
不因本 feature 而改動一個位元)。

## 相依性查證結果(機械性,逐條打開原始碼)

### 1. `api/src/StoryFlow/Api.hs`:`StoryFlowAPI` 的完整組成與 `storyFlowOpenApi`

`StoryFlowAPI = VaultAPI :<|> EntityAPI :<|> LinkAPI :<|> LevelAPI :<|> NodeAPI :<|> MiscAPI :<|>
ConflictAPI :<|> WorkshopAPI`(`api/src/StoryFlow/Api.hs:531-539`)。逐一數路徑與 operation(對照
`api/test/StoryFlow/Api/OpenApiSpec.hs:41-44` 與 `ApiSpec.hs:44-93` 的既有斷言,兩邊已經釘住
**19 條路徑、28 個 operation**,查證結果一致):

| 子 API | 路徑數 | operation 數 |
|---|---|---|
| `VaultAPI` | 4(`/vaults`、`/vault`、`/vault/index/rebuild`、`/vault/index/refresh`) | 5 |
| `EntityAPI` | 4(`/entities`、`/entities/{id}`、`/entities/{id}/body`、`/entities/{id}/fragments`) | 7 |
| `LinkAPI` | 1(`/entities/{id}/links`) | 3 |
| `LevelAPI` | 2(`/levels`、`/levels/{id}`) | 4 |
| `NodeAPI` | 1(`/nodes/{id}`) | 2 |
| `MiscAPI` | 2(`/types`、`/search`) | 2 |
| `ConflictAPI` | 2(`/conflict/context`、`/conflict/check`) | 2 |
| `WorkshopAPI` | 3(`/workshop`、`/workshop/{id}/step`、`/workshop/{id}/commit`) | 3 |
| **合計** | **19** | **28** |

`storyFlowOpenApi`(`api/src/StoryFlow/Api.hs:550-566`)由 `Servant.OpenApi.toOpenApi storyFlowAPI`
推導,再用 `applyTagsFor` 依八個子 API 各打一個 tag。**這是一個純值**(`OpenApi`,無 `IO`),
`storyflow-mcp` 只要 `import StoryFlow.Api (storyFlowOpenApi)` 就能在不連線的情況下拿到全部 28
個 operation 的完整描述(路徑模板、方法、`Summary`、參數、`requestBody`、回應 schema 的 `$ref`)。

`applyTagsFor` 的鏈式寫法(566 行前後)是本文檔「operationId 該怎麼加」的直接範本——見下段。

### 2. `operationId` 到底存不存在:**確認不存在,且 servant-openapi3 不會產生它**

這是本 feature 最關鍵的查證,結論明確,不是待確認假設。

**查證方法**:`cabal.project` 沒有 `freeze` 檔,版本由 `dist-newstyle/cache/plan.json` 的既有建置
計畫取得:`openapi3-3.2.5`、`servant-openapi3-2.0.2.0`。兩者的原始碼 tarball 就在本機 cabal 快取
(`C:\cabal\packages\hackage.haskell.org\{openapi3,servant-openapi3}\...`),解壓後直接讀原始碼:

- `openapi3-3.2.5`:`Data.OpenApi.Internal` 的 `Operation` record 有欄位
  `_operationOperationId :: Maybe Text`(`src/Data/OpenApi/Internal.hs:271`),註解寫著
  「Unique string used to identify the operation」。`instance Monoid Operation` 用
  `genericMempty`(`Internal.hs:1084-1085`),對 `Maybe` 欄位的 `mempty` 是 `Nothing`——這是
  `toOpenApi` 組出每個 `Operation` 時的起點值
- `servant-openapi3-2.0.2.0`:對整個套件原始碼(`src/`、`test/`)全文搜尋 `operationId` /
  `OperationId` / `_operationOperationId`,**零筆命中**。也就是說,它的 `HasOpenApi` 系列實例
  (`Verb`、`Capture`、`QueryParam`、`ReqBody` 等)只會設定 `summary`(來自 `Summary` combinator)、
  `description`、`parameters`、`requestBody`、`responses`,**完全不碰 `operationId` 這個欄位**

**結論**:`storyFlowOpenApi` 目前每一個 operation 的 `_operationOperationId` 都是 `Nothing`。
「tool 名字由 operationId 推導」若照字面實作(直接讀那個欄位),28 個 tool 會全部拿到
`Nothing`,推導不出任何名字。

**採取的作法**(design.md 明寫「查不出來就明確寫進待確認假設,並提出你要採取的作法」,見下
「待確認假設 A1」的完整推導規則):在 `api/src/StoryFlow/Api.hs` 的 `storyFlowOpenApi` 追加一段
**與現有 `applyTagsFor` 鏈同一種寫法**的 operationId 賦值,對全部 28 個 operation 設定
`_operationOperationId`,規則是**從路徑模板 + HTTP method 機械推導**(不是手寫 28 個字串)。
`storyflow-mcp` 的 tool 名稱**直接讀這個欄位**(`op ^. operationId`),不在 `Mcp.Tools` 裡另外
重算一次——這樣「tool 名字由 operationId 推導」在程式碼裡是逐字成立的,而且 `story-flow-serve
--openapi` 產出的文件也會**真的帶著** operationId,對外部工具(不只 claude code)一樣有意義。
這個改動落在 `api/`(`service-and-interfaces` 擁有的套件),但只是幫既有的 28 個 operation
補一個欄位,不新增/不修改任何路由或 DTO,屬於 ADR-011「介面包裝層是全面下游」允許且已有
F004 先例(F004 也改了 `api/src/StoryFlow/Api.hs`)的正常成長。

### 3. `api/src/StoryFlow/Api/Instances.hs`:DTO 的 schema 實例

`ToSchema` 與 `ToJSON` 逐欄對齊(模組頂端註解,`Instances.hs:12-14`),每個具名型別(`Id`、
`Ref`、`Status`……到 `Session`/`StageDraft`/`Message`/`Role`/四個 `Workshop*Req/Resp`)都在
`storyFlowOpenApi` 的 `components.schemas` 裡有一筆具名 schema(`OpenApiSpec.hs` 的
`expectedSchemas` 清單逐一列出,`Api.Instances.hs:139-155` 的 `objSchema`/`named` 是產生具名
schema 的共用小工具)。`tools/call` 的 `inputSchema` 因此**不需要重新推導欄位**——直接引用
`op ^. requestBody`(內含指向 `#/components/schemas/<TypeName>` 的 `$ref`)與
`op ^. parameters`(path/query 參數各自帶 inline 的 `Schema`,來源是
`ToParamSchema`/`ToSchema` 實例,例如 `Id`/`Status`/`LinkKind`/`NodeKind` 在
`Instances.hs:159-177`)。**這條路徑是純粹的資料傳遞,`storyflow-mcp` 完全不需要認得
`NewEntityReq`/`EntityPatch`……這些型別本身**,只需要能操作 `Data.OpenApi` 的 `Operation`/
`Param`/`Referenced Schema` 這些型別(`openapi3` 套件)。

### 4. `cli/src/StoryFlow/Cli/Backend.hs`:遠端模式的範本,以及一個必須偏離範本的地方

`Backend` 的 `Remote ClientEnv` 建構子(`Backend.hs:134-139`)、`managerWith`(認證 header,
171-179 行)、`classify :: ClientError -> RemoteError`(203-224 行)是 token 傳遞與 HTTP 錯誤
分類的既有範本,`storyflow-mcp` 的連線層照抄這個形狀(見下「連線設定」)。

**但 `client (Proxy :: Proxy StoryFlowAPI)`(`Backend.hs:229-276`)那種寫法不能照抄。** 那 28 個
`cXxx :: … -> ClientM …` 函式與最後那組 `(cListVaults :<|> …) = client …` 的巨大模式比對,是
一份**手寫的、逐一命名 28 個操作**的對照表——`storyflow-cli` 可以這樣做,因為它的驗收標準本來
就是「CLI 兩種模式輸出完全相同」,新增一個業務操作本來就需要 CLI 加一個新指令,一起手寫是
合理的。但 `storyflow-mcp` 的驗收標準明講「不手維護對照表」:如果照抄 `client` 這種寫法,
`StoryFlowAPI` 新增一條路由時,`storyflow-mcp` 若忘記加對應的 `cXxx`,**不會有任何測試變紅**
——`tools/list` 依然會回報「27 個 tool」而不是 28 個(因為新路由的 `cXxx` 沒被呼叫、根本沒被
串進 tool 清單),這正是契約卡點名的「手寫對照表漏一列不會紅」的原始情境。

**因此 `storyflow-mcp` 對 REST 的實際呼叫不使用 `servant-client` 的 `client` 函式**,改成直接用
`http-client` 依 `storyFlowOpenApi` 反推出來的**路徑模板 + HTTP method**組一個原生 HTTP 請求
（見「新增的介面」段的 `StoryFlow.Mcp.Client`)。這是本 feature 與 CLI 遠端模式**唯一**的實作
分歧點,原因記在待確認假設不需要——這是驗收標準本身要求的,不是不確定的判斷。

### 5. `cli/src/StoryFlow/Cli/Error.hs`:遠端失敗的既有語彙,以及為什麼不能 import 它

`RemoteError`(`Error.hs:106-113`)與 `remoteErrorCode`/`renderRemoteError`(121-133 行)定義了
「連不上」(`remote_unavailable`)、「回應看不懂」(`remote_bad_response`)、「伺服器回了業務
錯誤」(`RemoteStatus` 原樣取用伺服器的 `code`/`message`)三類。`storyflow-mcp` **不 import
`storyflow-cli`**(契約卡與硬性邊界都沒有把 `storyflow-cli` 列進 `storyflow-mcp` 可依賴的套件
——`storyflow-mcp` 只能依賴 `storyflow-api`)。

**怎麼重用這套語彙**:不搬到 `storyflow-api`(那會讓一個「只有型別」的套件背上 HTTP 錯誤分類
邏輯,違反它自己的套件描述),而是在 `storyflow-mcp` 自己的 `StoryFlow.Mcp.Client` 裡**重寫一份
同樣邏輯、同樣字串**(`remote_unavailable`/`remote_bad_response` 兩個 code 逐字沿用,訊息語氣比
照)。這不是各說各話——`service-and-interfaces/design.md` 的需求說明第 3 點明講「同一個失敗在
CLI 的 `--json`、REST 的 body、未來 MCP 的回報裡必須是同一個 code 與同一句訊息」,`storyflow-mcp`
與 `storyflow-cli` 各自維護一份**用詞相同**的分類函式,正是這句話唯一能落地的形式(兩者的
`ClientError` 分類本來就要各自处理各自的 `Manager`/`ClientEnv`,型別層面沒有共用的空間)。
`RemoteStatus` 帶的伺服器 `code`/`message` 這一半**不需要重寫**,直接把 REST 錯誤 body 的
`error.code`/`error.message` 原樣轉進 MCP tool result——這才是「錯誤沿用 REST 的 code 與訊息」
的字面意思。

### 6. `server/src/StoryFlow/Server/Auth.hs`:token 語意

`bearerAuth`(`Auth.hs:33-57`)是 WAI middleware,檢查 `Authorization: Bearer <token>`;沒設
`token` 時整個 middleware 是 identity(`bearerAuth Nothing app = app`),對應「loopback 模式
token 為選配」。`storyflow-mcp` 的客戶端行為完全對稱於 `cli/src/StoryFlow/Cli/Backend.hs` 的
`managerWith`:有 `STORYFLOW_TOKEN` 就在 `Manager` 上用 `managerModifyRequest` 加
`Authorization: Bearer <token>` header,沒有就不加。token 錯誤或必要但缺席時,server 回 401
`{"error":{"code":"unauthorized","message":"缺少或錯誤的 Authorization: Bearer <token>"}}`
(`Auth.hs:53-57`)——這會被 `initialize` 的連線探測(見「連線設定」)當成「連不上」的一種,
因為對呼叫端而言兩者的下一步是同一件事:檢查有沒有設對 `STORYFLOW_TOKEN`。

### 7. `api/storyflow-api.cabal`:現有相依,確認「只有型別」的邊界仍然成立

`library` 段(44-59 行)的 `build-depends` 目前是:`aeson`、`base`、`http-api-data`、
`insert-ordered-containers`、`lens`、`openapi3`、`servant`、`servant-openapi3`、
`storyflow-conflict`、`storyflow-core`、`storyflow-llm`、`storyflow-service`、
`storyflow-workshop`、`text`、`time`——**沒有** `servant-server`/`servant-client`/`warp`
(套件註解 30-43 行明講這條界線由 F003 T1 的測試守著)。`storyflow-mcp` 依賴 `storyflow-api`
時,會**傳遞**帶進 `storyflow-conflict`/`storyflow-core`/`storyflow-llm`/`storyflow-service`/
`storyflow-workshop` 這五個套件(它們是 `storyflow-api` 的相依,不是 `storyflow-mcp` 自己
`import` 的)——這不算 `storyflow-mcp` 違反「不 import `storyflow-service`」:GHC 的
`build-depends` 傳遞不等於程式碼裡出現 `import StoryFlow.Service`,`storyflow-mcp` 的原始碼
一行都不會提到那五個模組的任何識別碼。`storyflow-mcp` 自己的 `.cabal` 只需要**直接列**
`storyflow-api`,不需要也不應該把那五個套件也寫進自己的 `build-depends`(它們對
`storyflow-mcp` 的原始碼而言是不可見的傳遞相依)。

### 8.(額外查證,契約卡沒點名但屬硬性邊界 1 的直接證據)`service/test/StoryFlow/Service/CabalSpec.hs`

`libraryInternal = ["storyflow-core", "storyflow-md", "storyflow-store", "storyflow-types"]`
(`CabalSpec.hs:88-89`)是 `storyflow-service` library 段**逐字**允許的內部相依清單,不含
`storyflow-mcp`(當然也不含 `storyflow-conflict`/`storyflow-llm`/`storyflow-workshop`)。
更直接的是 67-73 行那條測試:

```haskell
it "守衛擋得住未來才出現的 storyflow-workshop / storyflow-mcp" $
  mapM_ (...) ["storyflow-workshop", "storyflow-mcp", "storyflow-llm"]
```

**這條測試現在就存在,且已經把 `storyflow-mcp` 列進它擋的清單**——`storyflow-service` 一旦
未來被改成依賴 `storyflow-mcp`(完全不合理的方向,但測試本來就是防「不合理但可能發生」的
事),這條測試會紅。硬性邊界 1「不准 import `storyflow-service`」的**反方向**(`storyflow-service`
不准反過來認得 `storyflow-mcp`)已經有程式碼守著,本 feature 不需要為此新增任何東西——查證
結果是「已經滿足,不必動工」,記在這裡是因為契約卡明確要求去讀這條測試「看它為什麼在乎」。

### 9. `workshop/test/StoryFlow/Workshop/CabalSpec.hs` 與 `llm/test/StoryFlow/Llm/CabalSpec.hs`:D9 的 CabalSpec 範本

兩份檔案的形狀完全一致:`libraryDeps`/`testDeps` 兩份**逐字**清單、`forbidden`(禁止的實作端
套件名單)、`cabal.project` 的 `packages 含 <dir>/`、`package storyflow-<x> 的 ghc-options 段`、
`allow-newer 仍然只開三項`四類測試。`storyflow-mcp` 的 `CabalSpec.hs` 照這個形狀寫(見「新增的
介面」與 TodoList T11),`forbidden` 清單另外要擋 `servant-client`(因為查證結果 4 已經確定
`storyflow-mcp` 不用它)與 `optparse-applicative`(mcp 只有一個 `--url` 選項,不需要完整的
指令解析框架,見待確認假設 A7)。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `StoryFlowAPI`(型別)、`storyFlowAPI :: Proxy StoryFlowAPI` | `api/src/StoryFlow/Api.hs:531-542` | service-and-interfaces/F003 | 確認 28 個 operation 的組成(查證結果 1) |
| `storyFlowOpenApi :: OpenApi` | `api/src/StoryFlow/Api.hs:550-566` | service-and-interfaces/F003 | `Mcp.Tools` 反推全部 tool 的唯一資料來源 |
| `WorkshopAPI`(三條路由併入 `StoryFlowAPI`) | `api/src/StoryFlow/Api.hs:514-529` | F004 | 確認 28 個 operation 裡最後補上的三個來源 |
| `data Operation`(`_operationOperationId :: Maybe Text` 欄位)、`instance Monoid Operation`(`mempty = genericMempty`) | `openapi3-3.2.5/src/Data/OpenApi/Internal.hs:271`、`:1084-1085` | - | 查證結果 2:確認欄位存在但預設為 `Nothing` |
| `servant-openapi3` 全部 `HasOpenApi` 實例(`src/`、`test/`) | `servant-openapi3-2.0.2.0` 全套件原始碼 | - | 查證結果 2:全文搜尋 `operationId` 零命中,確認不會被自動填入 |
| `applyTagsFor`(既有的 tag 賦值鏈,作為 operationId 賦值的寫法範本) | `api/src/StoryFlow/Api.hs:558-566` | service-and-interfaces/F003 | `deriveOperationId` 套用方式的範本 |
| `strSchema`/`enumSchema`/`objSchema`/`named`、`ToParamSchema Id`/`Status`/`LinkKind`/`NodeKind` | `api/src/StoryFlow/Api/Instances.hs:139-177` | service-and-interfaces/F003 | 確認 `inputSchema` 可直接引用既有具名 schema,不需重新推導欄位 |
| `expectedSchemas`(全部具名 schema 清單,含四個 `Workshop*` DTO 與 `Session`/`StageDraft`/`Message`/`Role`) | `api/test/StoryFlow/Api/OpenApiSpec.hs:74-117` | service-and-interfaces/F003、F004 | 確認 28 個 operation 用到的 DTO 全部有 `components.schemas` 具名項目可 `$ref` |
| `expectedRoutes`/`conflictRoutes`/`workshopRoutes`(19 路徑/28 operation 的獨立副本清單) | `api/test/StoryFlow/Api/ApiSpec.hs:66-112` | service-and-interfaces/F003、F004 | 交叉核對查證結果 1 的路徑/operation 計數 |
| `data Backend = Embedded Env \| Remote ClientEnv`、`managerWith :: Maybe Text -> ManagerSettings` | `cli/src/StoryFlow/Cli/Backend.hs:134-179` | service-and-interfaces/F003 | token header 注入的寫法範本(`STORYFLOW_TOKEN` → `Authorization: Bearer`) |
| `classify :: ClientError -> RemoteError` | `cli/src/StoryFlow/Cli/Backend.hs:203-224` | service-and-interfaces/F003 | 查證結果 4:確認 `client (Proxy :: Proxy StoryFlowAPI)` 這種手寫 28 個函式的寫法不能照抄；`StoryFlow.Mcp.Client` 改用 `http-client` 原生請求 |
| `data RemoteError = RemoteUnavailable Text \| RemoteBadResponse Text \| RemoteStatus Int Text Text`、`remoteErrorCode`、`renderRemoteError` | `cli/src/StoryFlow/Cli/Error.hs:106-133` | service-and-interfaces/F003 | 查證結果 5:`remote_unavailable`/`remote_bad_response` 兩個 code 字串在 `StoryFlow.Mcp.Client` 重寫一份同樣用詞的分類(不 import,因為不能依賴 `storyflow-cli`) |
| `bearerAuth :: Maybe Text -> Middleware`、`constantTimeEq` | `server/src/StoryFlow/Server/Auth.hs:33-75` | service-and-interfaces/F003 | 確認 server 端 token 語意(沒設 token 時放行、401 的錯誤 body 形狀),`initialize` 探測失敗時的 401 分支依此設計 |
| `storyflow-api` 的 `library` `build-depends`(`aeson`/`http-api-data`/`insert-ordered-containers`/`lens`/`openapi3`/`servant`/`servant-openapi3`/五個 `storyflow-*` 傳遞相依) | `api/storyflow-api.cabal:44-59` | service-and-interfaces/F003 | 查證結果 7:確認依賴 `storyflow-api` 不等於 `import` 那五個傳遞相依套件的任何模組 |
| `libraryInternal = ["storyflow-core","storyflow-md","storyflow-store","storyflow-types"]`、「守衛擋得住未來才出現的 `storyflow-workshop`/`storyflow-mcp`」測試 | `service/test/StoryFlow/Service/CabalSpec.hs:67-73,88-89` | service-and-interfaces/B001 | 查證結果 8:確認硬性邊界 1 的反方向(`storyflow-service` 不認得 `storyflow-mcp`)已有測試守著,本 feature 不需新增 |
| `libraryDeps`/`testDeps`/`forbidden`/四類 `describe` 區塊的形狀 | `workshop/test/StoryFlow/Workshop/CabalSpec.hs`、`llm/test/StoryFlow/Llm/CabalSpec.hs`(全檔) | - | D9 指定的 CabalSpec 範本,`StoryFlow.Mcp.CabalSpec` 逐一比照 |

## 實作方式

### 架構總覽:兩個階段,只有第二階段連線

```
啟動(story-flow-mcp --url <base> | STORYFLOW_URL | STORYFLOW_TOKEN)
  → StoryFlow.Mcp.Config:解析連線設定(旗標優先),沒設定就記下「未設定」而不是立刻失敗
      (失敗要發生在 initialize 這個 JSON-RPC 回應裡,不是行程啟動時的例外)
  → StoryFlow.Mcp.Tools:從編譯進來的 storyFlowOpenApi(靜態值,不連線)反推 28 個 Tool
      (name、description、inputSchema 三者全部是這一步的產物,見下)
  → 進入 stdio 讀取迴圈(StoryFlow.Mcp.Server),逐行讀 JSON-RPC 訊息
      ├─ initialize(必須是收到的第一個「有 id」的請求):
      │    → 用連線設定跑一次探測(GET /vaults,見「連線設定」)
      │    → 失敗:JSON-RPC error(見「新增的介面」)
      │    → 成功:JSON-RPC result(capabilities.tools = {})
      ├─ tools/list:直接回上面反推好的 28 個 Tool,不連線
      ├─ tools/call:
      │    → StoryFlow.Mcp.Tools 依 tool 名找回 (路徑模板, method, Operation)
      │    → 依 arguments 填路徑參數 / 組 query string / 取出 "body" 鍵當 JSON body
      │    → StoryFlow.Mcp.Client 用 http-client 送出真正的 HTTP 請求
      │    → 2xx:body 原樣包成 tool result(isError: false)
      │    → 4xx/5xx 且 body 是 {"error":{"code","message"}}:折成 isError: true 的 tool result,
      │        code/message 原樣沿用(不重寫)
      │    → 傳輸失敗(連不上、逾時、回應解不開):分類成 remote_unavailable /
      │        remote_bad_response(與 CLI 同樣的 code,見查證結果 5),同樣包成 isError: true
      └─ 其餘/未知 method:JSON-RPC error -32601;有 "id" 的請求一定回應,沒有 "id" 的
           通知(如 notifications/initialized)一律靜默略過(不回應——JSON-RPC 2.0 對通知本來
           就沒有回應)
```

### 為什麼 `tools/list` 不連線

`storyFlowOpenApi` 是 `storyflow-api` 匯出的**純值**,由 `StoryFlowAPI` 這個 Haskell 型別在
編譯期用 `Servant.OpenApi.toOpenApi` 推導出來——不是伺服器執行期反射自己的路由表。
`storyflow-mcp` 執行檔在連結時就已經帶著這份完整的 28-operation 描述。這也是「新增路由不用手
維護對照表」在**編譯期**就成立的原因:`StoryFlowAPI` 一改,`storyFlowOpenApi` 的值自動跟著變
(重新編譯後),`storyflow-mcp` 的 tool 清單不需要任何人工同步。

## 新增的介面

### 模組劃分(套件 `storyflow-mcp`,目錄 `mcp/`,契約卡點名的負責模組 `Mcp.Server` 對應
下面的 `StoryFlow.Mcp.Server`,其餘為它的內部協作模組——命名分割屬 Level 3 實作自主權,
比照 `storyflow-llm`/`storyflow-workshop` 已經採用的「門面 + Client/Config/Error 式切分」)

| 模組 | 職責 |
|---|---|
| `StoryFlow.Mcp` | 門面,re-export `runServer`/`Config` 等執行檔需要的最小介面 |
| `StoryFlow.Mcp.Protocol` | JSON-RPC 2.0 訊息的型別與編解碼(Request/Notification/Response/ErrorObj) |
| `StoryFlow.Mcp.Tools` | 從 `storyFlowOpenApi` 反推 `[Tool]`(name/description/inputSchema/路徑模板/method);依 tool 名反查回 operation |
| `StoryFlow.Mcp.Config` | `--url`/`STORYFLOW_URL`/`STORYFLOW_TOKEN` 的旗標優先解析 |
| `StoryFlow.Mcp.Client` | 連線探測、把 `(路徑模板, method, arguments)` 組成一次 HTTP 請求、REST 錯誤與傳輸錯誤的分類(查證結果 5 的重寫版) |
| `StoryFlow.Mcp.Server` | stdio 讀取迴圈、JSON-RPC 方法分派、initialize/tools 三個方法的接線 |

### operationId 推導規則(新增到 `storyflow-api` 的 `storyFlowOpenApi`,`api/src/StoryFlow/Api.hs`)

```haskell
-- | 從 HTTP method(小寫)與 OpenAPI 路徑模板(如 "/entities/{id}/links")機械推導
-- operationId,不手寫任何一筆對照。規則:
--   1. 依 '/' 切成片段,去掉空字串
--   2. 片段形如 "{name}" → "By" <> 首字大寫(name)
--   3. 其餘片段 → 首字大寫(片段本身,全部已是純小寫英文單字)
--   4. method(小寫)接上全部轉換後片段依序串接
-- 例:("post", "/entities/{id}/links") -> "postEntitiesByIdLinks"
--     ("get",  "/vault/index/rebuild") 不存在(rebuild 是 post);
--     ("post", "/vault/index/rebuild") -> "postVaultIndexRebuild"
deriveOperationId :: Text -> Text -> Text
```

套用方式與既有 `applyTagsFor` 鏈同一種寫法(`storyFlowOpenApi` 的 `tagged = applyTagsFor … .
applyTagsFor …`),新增一段對 `doc ^. paths` 的每個 `PathItem` 的每個非 `Nothing` 動詞
(`get`/`post`/`patch`/`put`/`delete`)呼叫 `operationId ?~ deriveOperationId verb path`。

### `StoryFlow.Mcp.Tools`

```haskell
data Tool = Tool
  { toolName        :: Text          -- 逐字取自 op ^. operationId(上面新增的欄位)
  , toolDescription :: Text          -- 逐字取自 op ^. summary(OpenApiSpec 已保證非空)
  , toolPath        :: Text          -- 路徑模板,如 "/entities/{id}/links"
  , toolMethod      :: Text          -- "get" | "post" | "patch" | "put" | "delete"
  , toolInputSchema :: Value         -- 見下
  }

-- | 從靜態的 storyFlowOpenApi 反推全部 28 個 Tool,不連線、不需要 IO。
toolsFromOpenApi :: OpenApi -> [Tool]

-- | tools/call 用 tool 名字反查 Tool。名字不存在時回 Nothing
-- (StoryFlow.Mcp.Server 據此決定回 JSON-RPC error -32602,而不是硬湊一個假 Tool)。
lookupTool :: Text -> [Tool] -> Maybe Tool
```

**`inputSchema` 的組成規則**(機械化,零手寫欄位):

- `properties` 裡,`op ^. parameters` 的每一筆(path 或 query 參數)貢獻一個同名鍵,值是該
  參數的 `_paramSchema`(原樣複製,可能是 inline schema 也可能是 `$ref`)
- 若 `op ^. requestBody` 存在,額外貢獻一個鍵 `"body"`,值是該 requestBody 的 JSON 內容型別
  schema(`$ref` 到 `#/components/schemas/<DTO 名字>`,例如 `postWorkshop` 的 `"body"` 指向
  `WorkshopStartReq`)
- `required` = 全部 `_paramRequired == Just True` 的參數名,加上(若有 requestBody)`"body"`
  這個鍵——REST 的 `ReqBody` 在 servant 裡本來就是必填的(沒有 `Maybe` 包裝的用法出現在
  `StoryFlowAPI` 裡),`required` 因此永遠納入 `"body"`

**為什麼 `body` 用巢狀而不是把 DTO 的欄位攤平到最外層**:攤平需要判斷 `requestBody` 的 schema
一定是 `type: object` 才能把它的 `properties` 併入外層(目前 28 個裡全部符合,但這是一個要
額外驗證的前提,以後任何一個新 DTO 若不是 object——理論上 servant 允許 `ReqBody` 包一個裸
陣列或字串——攤平就會出錯);更重要的是攤平會有欄位名衝突風險(path/query 參數名與 DTO
欄位名恰好相同時,先寫的會被蓋掉)。巢狀完全迴避這兩個問題,而且是機械化程度更高的映射
(`inputSchema.properties.body = op ^. requestBody 的 schema`,不需要「攤平物件」這個額外步驟)。
查證這 28 個 operation 目前**沒有**任何一個路徑/query 參數名與其 DTO 頂層欄位名相同(例如
`/nodes/{id}` 的參數是 `id`/`levelId`/`revision`,`NewNodeReq` 的欄位是
`title`/`kind`/`summary`/`body`/`links`——沒有交集),但這只是現狀,不是巢狀設計依賴的前提;
巢狀設計本身不需要這個前提也成立。

### `StoryFlow.Mcp.Config`

```haskell
data Config = Config
  { cfgBaseUrl :: Text          -- 已解析的 base URL(不含結尾斜線)
  , cfgToken   :: Maybe Text    -- STORYFLOW_TOKEN,可為空字串(視同沒設,同 CLI managerWith)
  }

-- | --url 旗標 → 沒有就讀 STORYFLOW_URL → 都沒有回 Left(給 initialize 用)。
-- STORYFLOW_TOKEN 永遠只走環境變數(與 cli 的 Backend.hs 對稱,沒有對應的 --token 旗標)。
resolveConfig :: [Text] {- argv -} -> IO (Either Text Config)
```

### `StoryFlow.Mcp.Client`

```haskell
-- | 連線探測:對 cfgBaseUrl 打 GET /vaults(唯一不需要目前 Vault 就能回應的既有端點,
-- 見 api/src/StoryFlow/Api.hs 對 VaultAPI 的既有註解)。成功(2xx)回 Right ();
-- 失敗回 Left,帶著與查證結果 5 同一組 code(remote_unavailable / 由 401 產生的
-- unauthorized,原樣沿用伺服器的 error body)。
probe :: Config -> IO (Either (Text, Text) ())   -- (code, message)

-- | 實際打一次 tools/call:依 Tool 的路徑模板把 path 參數代入、query 參數組成
-- query string、"body" 鍵(若有)當 JSON request body,送出對應 method 的請求。
-- 回傳原始回應 body(成功)或 (code, message)(REST 業務錯誤或傳輸錯誤,兩者
-- 在型別上不分——tools/call 的呼叫端只需要知道「這通是不是失敗」與「code/message
-- 是什麼」,不需要在型別上區分失敗的來源,呼應 design.md「錯誤沿用 REST 的 code
-- 與訊息」不分傳輸與業務兩層的字面意思)。
invoke :: Config -> Tool -> Value {- arguments -} -> IO (Either (Text, Text) Value)
```

`invoke` 的傳輸層失敗分類(`ClientError` 的對應物,但這裡用 `http-client` 原生的
`HttpException` 而不是 `servant-client` 的 `ClientError`,因為查證結果 4 已確定不用
`servant-client`):`HttpExceptionRequest _ (ConnectionFailure _)`/`ResponseTimeout` 等歸類
`remote_unavailable`;回應解不開 JSON 或不是 `{"error":{...}}` 形狀歸類
`remote_bad_response`——兩個 code 字串逐字沿用查證結果 5 的 CLI 版本。

### `StoryFlow.Mcp.Protocol`(JSON-RPC 2.0 訊息形狀)

```haskell
data RpcMessage
  = RpcRequest  { rmId :: Value, rmMethod :: Text, rmParams :: Value }  -- 有 "id",要回應
  | RpcNotify   { rmMethod :: Text, rmParams :: Value }                 -- 沒有 "id",不回應
  deriving stock (Show, Eq)

-- | 一行一則訊息(MCP 的 stdio 傳輸慣例,不是 LSP 的 Content-Length 框架)。
-- 解析失敗時,若原始位元組看得出一個 "id" 欄位就回帶那個 id 的 JSON-RPC error
-- (-32700 Parse error);完全解不出 id 就整行略過(避免對一則根本讀不懂的輸入
-- 硬造一個可能誤導的回應)。
parseLine :: ByteString -> Either (Maybe Value, Text) RpcMessage

encodeResult :: Value {- id -} -> Value {- result -} -> ByteString
encodeError  :: Value {- id -} -> Int {- json-rpc code -} -> Text -> Maybe Value {- data -} -> ByteString
```

### 三個 JSON-RPC 方法的請求/回應形狀

**`initialize`**

請求:
```json
{"jsonrpc":"2.0","id":1,"method":"initialize",
 "params":{"protocolVersion":"2026-06-18","capabilities":{},"clientInfo":{"name":"…","version":"…"}}}
```

成功回應(echo 回客戶端送來的 `protocolVersion`,見待確認假設 A2):
```json
{"jsonrpc":"2.0","id":1,
 "result":{"protocolVersion":"2026-06-18",
           "capabilities":{"tools":{}},
           "serverInfo":{"name":"story-flow-mcp","version":"0.1.0"}}}
```

失敗回應(未設定連線,或探測連不上/回 401):
```json
{"jsonrpc":"2.0","id":1,
 "error":{"code":-32001,
          "message":"連不上 story-flow 伺服器(http://127.0.0.1:8080):Connection refused\n請先跑 story-flow-serve,或以 --url / STORYFLOW_URL 指到正確的位址",
          "data":{"code":"remote_unavailable"}}}
```
未設定連線設定時 `data.code` 是 `"story_flow_url_missing"`(新 code,mcp 自己的設定語彙,不是
REST 沿用的);訊息同樣說出下一步(用 `--url` 或 `STORYFLOW_URL`)。

**`tools/list`**

請求:`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`(不支援分頁——28 個工具一次
全部回,`params.cursor` 若出現則忽略)

回應:
```json
{"jsonrpc":"2.0","id":2,
 "result":{"tools":[
   {"name":"postWorkshop",
    "description":"開一個新工作坊,依型別的階段清單逐階段對話",
    "inputSchema":{"type":"object",
                    "properties":{"body":{"$ref":"#/components/schemas/WorkshopStartReq"}},
                    "required":["body"]}},
   … 共 28 筆 …
 ]}}
```

**`tools/call`**

請求:
```json
{"jsonrpc":"2.0","id":3,"method":"tools/call",
 "params":{"name":"postEntitiesByIdLinks",
           "arguments":{"id":"ent-7f3a","revision":3,
                        "body":{"kind":"partOf","target":"ent-91cc"}}}}
```

成功(REST 回 2xx):
```json
{"jsonrpc":"2.0","id":3,
 "result":{"content":[{"type":"text","text":"{\"id\":\"ent-7f3a\", …EntityView 的 JSON…}"}],
           "isError":false}}
```

失敗(REST 業務錯誤,或傳輸錯誤,兩者用同一個信封):
```json
{"jsonrpc":"2.0","id":3,
 "result":{"content":[{"type":"text","text":"revision 過期,請先重新讀取這筆資料"}],
           "isError":true,
           "structuredContent":{"code":"stale_revision",
                                 "message":"revision 過期,請先重新讀取這筆資料"}}}
```

工具名不存在或缺必填參數(協定層錯誤,不是業務失敗):
```json
{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"unknown tool: postFoo"}}
```

**設計取捨**(不是 assumption,是本文檔的決定,原因見上):REST 業務錯誤與 `tools/call` 期間
的傳輸失敗**都**回成功的 JSON-RPC 回應、`result.isError = true`——這是 MCP 慣例:工具「執行
失敗」要讓呼叫端(claude code 背後的模型)在對話裡看到並能反應,不能用 JSON-RPC 傳輸層錯誤
悄悄吞掉。只有「這通根本不是一個合法的 `tools/call`」(未知 method、未知 tool 名、缺必填
參數)才用 JSON-RPC error——那是客戶端的協定錯誤,不是一次工具執行的結果。

### 其餘 JSON-RPC 訊息

- 沒有 `"id"` 的訊息(通知,例如 `notifications/initialized`)一律**不回應**,方法名不比對,
  直接忽略——JSON-RPC 2.0 對通知本來就沒有回應這回事
- 有 `"id"` 但 `method` 不是上述三個之一:`-32601 Method not found`
- 整行解不成合法 JSON:`-32700 Parse error`(若能從壞掉的 JSON 裡搶救出一個 `"id"` 欄位就帶
  那個 id,否則整行略過不回應)

## 連線設定

`story-flow-mcp [--url <base>]`,環境變數 `STORYFLOW_URL`/`STORYFLOW_TOKEN`。優先序:
`--url` > `STORYFLOW_URL` > 都沒有(視為未設定連線)。`STORYFLOW_TOKEN` 只有環境變數這一條路
（與 CLI 的 `Backend.hs` 對稱,那邊也沒有 `--token` 旗標)。

**設定何時被檢查、失敗訊息長什麼樣**:啟動行程本身**不因為沒設定 `--url`/`STORYFLOW_URL` 就
直接退出**——`resolveConfig` 回 `Left`,行程照樣進入 stdio 迴圈等 `initialize`;`initialize`
收到請求時才依這個 `Left`/連線探測結果決定回成功還是回 JSON-RPC error。這樣設計是因為 MCP
的協定本來就是「先握手再談」,在 `initialize` 之前的任何行程層失敗都無法用 JSON-RPC 的形狀
回報給客戶端(客戶端此時還沒收到任何回應可以解讀)——把失敗一路延後到第一個能合法回應的
時機,才符合契約卡「沒設定或連不上就在 `initialize` 回錯誤」的字面意思(是在 `initialize`
這個回應裡回錯誤,不是行程啟動時的非零 exit code 或 stderr 訊息)。

## 資料流(對照 design.md 的「MCP(外部 Agent → 圖譜)」管線)

```
claude code / codex 的 tool call(stdio,一行一則 JSON-RPC 訊息)
  → StoryFlow.Mcp.Server 讀一行、StoryFlow.Mcp.Protocol 解碼
  → initialize:StoryFlow.Mcp.Client.probe 打 GET /vaults 驗連線 → 成功/失敗兩種 JSON-RPC 回應
  → tools/list:StoryFlow.Mcp.Tools.toolsFromOpenApi(storyFlowOpenApi)直接回 28 筆,不連線
  → tools/call:StoryFlow.Mcp.Tools.lookupTool 找 (路徑模板, method)
      → StoryFlow.Mcp.Client.invoke 依 arguments 組 HTTP 請求 → 打 story-flow-serve
      → 同一組業務契約(service-and-interfaces 的 ServiceM,經 REST)處理
      → JSON 回應(或 {"error":{"code","message"}})原樣轉成 tool result
  → StoryFlow.Mcp.Protocol 編碼、寫回 stdout 一行
```

MCP adapter 沒有業務邏輯:`tools/call` 的參數→HTTP body、HTTP 回應→tool result 兩段轉換都是
機械性的資料搬移,沒有任何一步查詢或修改業務語意。

## TodoList

- [ ] T1:`mcp/storyflow-mcp.cabal` 套件骨架(library 六個模組先建空殼、executable
      `story-flow-mcp`、test-suite 骨架);`cabal.project` 的 `packages:` 加 `mcp/`,
      新增 `package storyflow-mcp` 區塊(與現有十一個套件同一種 `ghc-options` 四旗標格式)
      `dep: -`
- [ ] T2:`StoryFlow.Mcp.Protocol`——`RpcMessage`、`parseLine`、`encodeResult`、`encodeError`
      `dep: T1`
- [ ] T3:`api/src/StoryFlow/Api.hs` 加 `deriveOperationId` 與套用它的 traverse,
      `storyFlowOpenApi` 的全部 28 個 operation 取得非空、彼此不重複的 `_operationOperationId`
      `dep: -`
- [ ] T4:`api/test/StoryFlow/Api/OpenApiSpec.hs`(或新開一個 spec 檔)加斷言:28 個 operation
      的 `_operationOperationId` 全部是 `Just`、彼此不重複、逐一等於 `deriveOperationId` 依
      T3 規則算出的值 `dep: T3`
- [ ] T5:`StoryFlow.Mcp.Tools`——`Tool`、`toolsFromOpenApi`、`lookupTool`,`inputSchema` 的
      巢狀組法(path/query 參數攤平 + `"body"` 巢狀 `$ref`) `dep: T3`
- [ ] T6:`StoryFlow.Mcp.Config`——`Config`、`resolveConfig`(`--url` > `STORYFLOW_URL`,
      `STORYFLOW_TOKEN` 只走環境變數) `dep: T1`
- [ ] T7:`StoryFlow.Mcp.Client`——`probe`(打 `GET /vaults`)、`invoke`(依 `Tool` 組 HTTP
      請求並送出)、傳輸失敗分類(`remote_unavailable`/`remote_bad_response`,逐字沿用
      `cli/src/StoryFlow/Cli/Error.hs` 的 code 字串) `dep: T5, T6`
- [ ] T8:`StoryFlow.Mcp.Server`——stdio 讀取迴圈、三個方法的分派、通知略過、未知
      method/tool/缺參數的 JSON-RPC error `dep: T2, T5, T6, T7`
- [ ] T9:`StoryFlow.Mcp`(門面)與 `mcp/app/Main.hs`(執行檔進入點,`argv` → `resolveConfig`
      → `runServer`) `dep: T8`
- [ ] T10:`mcp/test/StoryFlow/Mcp/CabalSpec.hs`(照 D9 範本):`build-depends` 逐字清單、
      `forbidden` 含 `storyflow-service`/`storyflow-store`/`storyflow-md`/`storyflow-conflict`/
      `storyflow-workshop`/`storyflow-llm`/`storyflow-core`/`servant-client`/`servant-server`/
      `warp`(僅 library 段)/`optparse-applicative`、`required` 含 `storyflow-api`;
      `cabal.project` 的 `packages 含 mcp/`、`package storyflow-mcp 的 ghc-options 段`、
      `allow-newer 仍然只開三項` `dep: T1`
- [ ] T11:`StoryFlow.Mcp.ToolsSpec`——`length (toolsFromOpenApi storyFlowOpenApi) == 28`;
      tool 名稱集合與 `map (^. operationId) (全部 28 個 Operation)` 逐一相等(順序不拘,
      內容必須相等);對 3-5 個代表性 operation(`postWorkshop`、`getEntitiesById`、
      `deleteEntitiesByIdLinks`、`postNodesById`)逐一比對 `inputSchema` 的 `properties`/
      `required` 鍵集合 `dep: T5, T4`
- [ ] T12:`StoryFlow.Mcp.ProtocolSpec`——`parseLine` 對請求/通知/壞 JSON 三種輸入的行為;
      `encodeResult`/`encodeError` 的往返 `dep: T2`
- [ ] T13:`StoryFlow.Mcp.ConfigSpec`——`--url` 蓋過 `STORYFLOW_URL`;都沒有回 `Left`;
      `STORYFLOW_TOKEN` 空字串視同沒設 `dep: T6`
- [ ] T14:`StoryFlow.Mcp.ClientSpec`(起本機 warp stub 模擬 `story-flow-serve`):`probe`
      成功/連不上兩種案例;`invoke` 對一個有 path+query+body 的 operation 成功案例、
      REST 錯誤 body 原樣轉出、stub 直接斷線時分類成 `remote_unavailable` `dep: T7`
- [ ] T15:`StoryFlow.Mcp.ServerSpec`(端到端,對 stdin/stdout 管線或直接呼叫 `handleLine`
      層級的函式,不強求真的 spawn 子行程):`initialize` 未設定連線 / 連不上 / 成功三種
      JSON-RPC 回應逐位元組比對;`tools/list` 回 28 筆且不連線(stub 伺服器沒被打到);
      `tools/call` 成功案例(對著 stub)、業務錯誤案例(`isError:true`)、未知 tool 名
      (`-32602`)、未知 method(`-32601`)、通知(無回應) `dep: T8`
- [ ] T16:`mcp/storyflow-mcp.cabal` 的 test-suite `other-modules`/`Spec.hs` 補齊 T4 額外新增
      的 api spec(若拆成獨立檔案)與 T10-T15 六個 spec 模組 `dep: T10, T11, T12, T13, T14, T15`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Mcp.CabalSpec`(T10 的斷言依附在這裡) | 套件骨架、`cabal.project` 接線存在 |
| T2 | `StoryFlow.Mcp.ProtocolSpec`(T12) | JSON-RPC 訊息編解碼 |
| T3 | `StoryFlow.Api.OpenApiSpec`(T4 新增案例) | `deriveOperationId` 套用到全部 28 個 operation |
| T4 | `StoryFlow.Api.OpenApiSpec`(T4) | operationId 非空、不重複、規則相符 |
| T5 | `StoryFlow.Mcp.ToolsSpec`(T11) | **tools 數 == OpenAPI operation 數(28)**,名稱來自 operationId,`inputSchema` 形狀正確 |
| T6 | `StoryFlow.Mcp.ConfigSpec`(T13) | 旗標優先序、token 只走環境變數 |
| T7 | `StoryFlow.Mcp.ClientSpec`(T14) | 連線探測與實際呼叫的成功/失敗分類 |
| T8 | `StoryFlow.Mcp.ServerSpec`(T15) | 三個方法的端到端分派、通知略過、未知 method/tool |
| T9 | `StoryFlow.Mcp.ServerSpec`(T15,經由執行檔等效路徑間接驗證) | `Main.hs` 把 `argv` 接到 `resolveConfig`/`runServer` |
| T10 | `StoryFlow.Mcp.CabalSpec`(T10) | `build-depends` 逐字清單、`forbidden`/`required`、`cabal.project` 三項斷言 |
| T11 | `StoryFlow.Mcp.ToolsSpec`(T11) | 見上 |
| T12 | `StoryFlow.Mcp.ProtocolSpec`(T12) | 見上 |
| T13 | `StoryFlow.Mcp.ConfigSpec`(T13) | 見上 |
| T14 | `StoryFlow.Mcp.ClientSpec`(T14) | 見上 |
| T15 | `StoryFlow.Mcp.ServerSpec`(T15) | 見上 |
| T16 | 全部測試套件能編譯並跑起來(`cabal test all`) | `Spec.hs` 與 `.cabal` 的 `other-modules` 沒有漏接 |

**驗收標準的可測形式**(契約卡逐字要求)由 T11 的第一條斷言直接覆蓋:
`length (toolsFromOpenApi storyFlowOpenApi) == length (全部 operation)`,兩邊都從
`storyFlowOpenApi` 算出,任何一方新增/減少路由,另一方會同步變動,不會出現「新增 REST 路由
卻忘了補 tool」這種靜默落差——因為 tool 清單本來就是從同一份 `OpenApi` 值機械推導出來的,
不是另一份需要手動同步的清單。

## 待確認假設

- A1:`operationId` 在 `servant-openapi3-2.0.2.0` 產出的 `OpenApi` 文件裡不存在(查證結果 2,
  已有明確結論,非待確認),但**推導規則本身**(HTTP method 小寫 + 路徑片段首字大寫 + `{參數}`
  轉 `By<參數>` 的具體演算法)是本文檔提出的設計,design.md 沒有規定任何字面形式 → 採取:
  上面「operationId 推導規則」段落的演算法,理由是完全機械化(不看任何業務語意,只看
  method+path 的字串結構)且對現有 28 個 operation 逐一驗算過不重複 → 影響:若開發者對
  tool 名稱風格有別的偏好(例如全 snake_case、或不含 method 前綴),只需要改
  `deriveOperationId` 這一個函式,`StoryFlow.Mcp.Tools`/`Server` 都是原樣讀 `operationId`
  欄位,不需要跟著改
- A2:MCP 協定版本字串(`initialize` 的 `protocolVersion`)在契約卡與 design.md 都沒有指定
  → 採取:伺服器 echo 回客戶端請求裡的 `protocolVersion`(不自行宣告一個可能與 claude code
  版本不相容的字串);請求完全沒帶時退回一個保守預設值 → 影響:只影響
  `StoryFlow.Mcp.Server` 裡的一個字串常數,不影響其餘設計
- A3:`tools/call` 的參數形狀選擇「path/query 參數攤平在頂層 + `requestBody` 巢狀在 `"body"`
  鍵」,design.md 只說「參數形狀來自同一份 API 型別」沒有規定巢狀規則 → 採取:巢狀而非攤平
  合併,理由見「新增的介面」段(機械化程度更高、零欄位命名衝突風險)→ 影響:如果claude code
  實際串接時偏好完全攤平的參數,調整範圍限於 `StoryFlow.Mcp.Tools` 的 `inputSchema` 組法與
  `StoryFlow.Mcp.Client.invoke` 的參數拆解兩處,不影響 REST 呼叫或 tool 清單數量這兩個可測的
  驗收標準
- A4:`initialize` 的連線探測打哪一條 REST 路由,契約卡與 design.md 都沒有指定 → 採取:探測
  `GET /vaults`(`api/src/StoryFlow/Api.hs` 的既有註解明寫它是唯一不需要目前 Vault/Env 就能
  回應的端點,契合「純粹測連線,不該因為某個 Vault 沒開好就誤判連線失敗」的探測語意)→ 影響:
  若日後 `GET /vaults` 被賦予其他前置條件,探測端點需要跟著換,調整範圍限於
  `StoryFlow.Mcp.Client.probe` 一個函式
- A5:design.md 契約卡逐字引用的訊息是「先跑 `story-flow serve`」,但系統實際可執行檔名是
  `story-flow-serve`(`system.md` 與 `server/app/Main.hs:1,58` 明寫;design.md 這句話是舊
  措辭的殘留,兩者一個有空格一個是連字號) → 採取:錯誤訊息採用實際可執行檔名
  `story-flow-serve`(訊息才真的可操作,符合系統「每則訊息都說出下一步」的既有原則) →
  影響:若開發者希望逐字比對契約卡文字,只需要改 `StoryFlow.Mcp.Client` 裡那一個訊息字串
  常數,不影響其餘設計
- A6:`tools/call` 對 REST 業務錯誤的回報形狀(`isError`/`content`/`structuredContent` 三個
  鍵)不是 MCP 規格逐字要求的欄位命名,是本文檔依現有 MCP 工具慣例的設計選擇 → 採取:
  `content` 放給人/模型讀的訊息文字,`structuredContent` 放原始 `{code,message}` 物件供
  程式化重試邏輯讀 → 影響:如果實際串接的 claude code 版本不認得 `structuredContent`,
  拿掉那個鍵不影響其餘設計(`content` 仍帶著完整資訊)
- A7:`storyflow-mcp` 不使用 `optparse-applicative` 解析 `--url`(只有一個選項,手寫解析
  `argv` 即可,不需要完整的指令解析框架),與 `cli`/`server` 兩個既有執行檔的做法不同 →
  採取:`mcp/app/Main.hs` 手寫最小的 `argv` 掃描(找 `--url <value>` 這一組) → 影響:如果
  未來 `story-flow-mcp` 需要更多旗標(例如日誌等級),屆時再評估要不要換成
  `optparse-applicative`,現在引入它對單一選項是不成比例的相依

## 實作備註

(實作階段填)
