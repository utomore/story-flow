---
id: service-and-interfaces
type: subsystem
title: service-and-interfaces
description: 業務契約層與它的三種薄包裝:CLI、REST API 與伺服器
status: active
created: 2026-08-18
updated: 2026-08-23
code-paths: [service/src, api/src, server/src, cli/src, cli/app, server/app]
parent: system
related-adr: [ADR-002, ADR-005, ADR-006, ADR-008, ADR-009]
---

# 業務契約與介面 子系統架構

## 定位與範圍

主架構「子系統劃分」的第二節。這個子系統是 ADR-006 的實體化:**所有業務操作只定義一次**,
CLI、REST server 與未來的 MCP adapter 全部是同一份契約的薄包裝。

涵蓋 `storyflow-service`、`storyflow-api`、`storyflow-server`、`storyflow-cli` 四個元件。

**明確不做**:落地細節(那是 `entity-graph-core`)、衝突偵測(`conflict-detection`)、LLM 與工作坊
(`llm-workshop-mcp`)。`service` 不 import `conflict` 也不 import `llm` ——後兩者是**它的消費者**,
不是它的相依。

**這一層存在的價值不是「多一層」**,而是讓三種介面的行為由型別強制一致:邏輯只有一份,
不可能悄悄長歪。

## 需求說明

主架構的核心功能清單第 4 項是「API 優先:REST/JSON 是唯一的業務契約,CLI 與 MCP adapter
都是薄客戶端」。要讓這句話成立而不是口號,需要:

1. **一個業務層**,把「型別驗證有人呼叫」「Connection / Vault / 註冊表收進 Env」
   「錯誤講業務語彙」「組合操作有歸屬」四件 `store` 沒做的事補上
2. **樂觀鎖在兩種模式下都生效**——遠端模式恰恰是多客戶端並發真的會發生的那一種,所以
   `expected revision` 是必填,不留逃生口
3. **錯誤語彙三邊一致**:同一個失敗在 CLI 的 `--json`、REST 的 body、未來 MCP 的回報裡
   必須是同一個 code 與同一句訊息,否則 AI Agent 要為每個介面各學一次
4. **CLI 的兩種模式輸出完全相同**,而且是結構上成立,不是靠對照測試碰運氣

## 內部模組劃分(Internal Modules)

| 元件 | 職責 | 關鍵約束 |
|---|---|---|
| `storyflow-service` | `ServiceM = ReaderT Env (ExceptT ServiceError IO)`;28 個業務操作(其中 `linkGraph` / `aliasIndex` / `vaultConfig` / `vaultRoot` / `locateVault` 只有內嵌出口);`ServiceError` 與 `errorCode` / `renderServiceError`;View 與請求型別;集中的 aeson 實例 | 不含 HTTP 與終端輸出,`build-depends` 就是那條界線的證明 |
| `storyflow-api` | **只有** servant API 型別、`FromHttpApiData` / `ToHttpApiData`、`ToSchema`、`storyFlowOpenApi` | 不含 `servant-server` / `servant-client` / `warp` ——它是兩個消費端共用的契約 |
| `storyflow-server` | servant handler(每個一行)、`MVar Env` 序列化、Bearer token middleware、warp 啟動;執行檔 `story-flow-serve` | 不 import `storyflow-store`;handler 內無業務判斷 |
| `storyflow-cli` | optparse 指令樹、`Backend` 抽象(內嵌 / 遠端)、渲染器、統一信封;執行檔 `story-flow` | 不 import `storyflow-store`、`storyflow-server` 與 `warp` |

**為什麼 API 型別要獨立成套件**:`cli --remote` 需要 API 型別去產生 `servant-client`。型別若
住在 server 裡,CLI 就得依賴 server,連帶把整套 HTTP 伺服器拖進一個預設根本不開伺服器的
執行檔。這也是為什麼 `story-flow serve` 最後做成**獨立執行檔 `story-flow-serve`** 而不是
CLI 的子指令(F003 實作備註 1)。

## 對外契約(Public Interface & DTOs)

三個出入口,對應三種使用者。

**內嵌(供本專案其他子系統與測試)**

```haskell
data Env  -- Vault + Connection + TypeRegistry
newtype ServiceM a
openEnv    :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))
runService :: Env -> ServiceM a -> IO (Either ServiceError a)

-- 28 個業務操作,例如:
createEntity :: NewEntityReq -> ServiceM EntityView
updateEntity :: Id -> Int -> EntityPatch -> ServiceM EntityView   -- expected revision 必填
addNode      :: Id -> Id -> Int -> NewNodeReq -> ServiceM LevelView

-- 錯誤:機器看 code、人看 message,三種介面共用
errorCode           :: ServiceError -> Text   -- snake_case 穩定識別碼
renderServiceError  :: ServiceError -> Text   -- 繁中,每則都說出下一步

-- P4 消費者(conflict-detection)需要的兩個唯讀出口。2026-08-20 由 /subsys-build 的批次澄清加入。
-- 只開內嵌出口,不開 CLI 與 REST:它們是子系統之間的查詢介面,不是作者的指令。
linkGraph  :: ServiceM LinkGraph                      -- 整張關聯圖,第 1 層圖遍歷用
aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])] -- 片段 id → title 與 aliases,第 2 層反向比對用

-- P5 消費者(llm-workshop-mcp)需要的唯讀出口。2026-08-20 由 /subsys-build 的批次澄清加入。
-- 同樣只開內嵌出口:Vault 設定不是作者用指令查的東西,是子系統之間的讀取。
-- VaultConfig / 它的 [llm] 段一併在「沿用 store 的定義(不重造)」那一組 re-export
-- ——storyflow-llm 讀得到設定,才不必繞過本層直接依賴 storyflow-store。
vaultConfig :: ServiceM VaultConfig                   -- 本 Vault 的 .storyflow/config.toml

-- 2026-08-22 由 /subsys-build 的批次澄清加入(llm-workshop-mcp/F002)。
-- 工作坊的 session 快照要寫 <root>/.storyflow/workshops/,而 storyflow-workshop
-- 與 storyflow-llm 同樣不准依賴 storyflow-store,拿不到 vaultRoot。
-- 不沿用 vaultInfo:它為了 vvEntityCount 會 listEntities 全表掃描,而快照每一
-- step 寫一次——付一次全表掃描去換一個馬上被丟掉的數字。
vaultRoot :: ServiceM FilePath                        -- 含 .storyflow/ 的那一層

-- 2026-08-23 由 /enhance-design 加入(G-E002)。CLI 的 doctor 要報告「Vault 在哪、
-- [llm] 段有沒有」但刻意不開索引——開索引會觸發過時掃描,而診斷指令不該有副作用。
-- 這是 IO 而非 ServiceM:它在 Env 存在之前就要能跑(找不到 Vault 也是它要報告的事)。
-- 同樣只開內嵌出口,不上 REST:它診斷的是這台機器,跨 HTTP 沒有意義。
locateVault :: Maybe Text -> FilePath -> IO (Either ServiceError (VaultView, VaultConfig))
```

**REST(供外部 Agent 與 `llm-workshop-mcp` 的 MCP adapter)**

16 條路徑、25 個 operation,覆蓋 `ServiceM` **對外**的每一個操作,外加 `conflict-detection` 掛進來的 `POST /conflict/context` 與 `POST /conflict/check`(`linkGraph` / `aliasIndex` / `vaultConfig` / `vaultRoot` 是 P4/P5 子系統之間的唯讀查詢,只走內嵌,不上 REST)。`revision` 是必填的 query
parameter。錯誤 body 一律 `{"error":{"code":…,"message":…}}`,`code` 就是 `errorCode`。
OpenAPI 3 文件由同一份型別推導:`story-flow-serve --openapi > openapi.json`。

**CLI(供作者)**

`story-flow [--vault <名稱>|--remote <url>] [--json] [--version] <名詞> <動詞>`,29 個葉子子指令(其中 `context` 與 `conflict check` 屬 `conflict-detection`;`workshop start` / `step` / `commit` 屬 `llm-workshop-mcp`;`doctor` 是本機診斷,不開 Vault、不上 REST)。

> 2026-08-23 更正:此處 F004 加了三個 `workshop` 子指令後漏更新(25 → 28),G-E002 再加 `doctor`(→ 29)與全域旗標 `--version`。

> 2026-08-20 更正:此處原記 21,與程式碼長期不符(`Cli.Options` 的 `Command` 建構子在 `context`
> 加入前已有 23 個)。沒有任何測試釘住這個數字,所以它一路漂著;現已由 `OptionsSpec` 涵蓋。
exit code:`0` 成功、`1` 業務或傳輸失敗、`2` 用法錯誤。

## 資料流管線(Data Flow Pipeline)

三種介面在最外層分流,進入 `ServiceM` 之後只有一條路——這正是「行為由型別保證一致」的來源。

```text
CLI 參數(optparse)/ REST 請求 body(servant)
  → 介面層解碼成請求型別:NewEntityReq / EntityPatch / NewNodeReq / EntityFilter …
  → Backend 分派(僅 CLI):Embedded 直接進 ServiceM;Remote 以 servant-client 打 HTTP,
    在伺服器端回到同一條路
  → ServiceM:自 Env 取出 Vault / Connection / TypeRegistry
  → 業務驗證:型別註冊表檢查、關聯目標存在性、樹的合法性、expected revision 比對
  → 委派 entity-graph-core 的 storyflow-store 落地(先寫檔、再更新索引)
  → 組成 View 型別:EntityView / LevelView / NodeView …
  → 出口渲染:CLI 統一信封 {"ok":true,"data":…} / REST JSON body
```

任一段失敗都短路成 `ServiceError`,由 `errorCode`(機器)與 `renderServiceError`(人)產出
三種介面共用的同一組 code 與訊息;`storyflow-server` 只用 code 字串分派 HTTP 狀態碼。

## 使用的技術

沿用主架構。子系統特有的三個決定:

- **`mtl` 的 `ReaderT` + `ExceptT`**:業務操作是**組合**的,手工串 `Either` 會讓每個函式的
  主體被 `case` 淹沒,而錯誤處理正是最不該被淹沒的部分
- **`MVar Env` 而非連線池**:`sqlite-simple` 的 `Connection` 不保證多執行緒安全,而 warp 是
  多執行緒的。單一連線加互斥鎖讓「先寫檔、再更新索引」在**請求之間**也是原子的;代價是
  吞吐量,而單人工作室的吞吐量不是瓶頸
- **認證是 WAI middleware,不在路由型別裡**:`AuthProtect` 會讓 `servant-client` 多一層
  `AuthenticatedRequest` 包裝、OpenAPI 多一個安全定義。middleware 讓路由型別完全不知道有
  認證這回事,client 只要在 Manager 上加一個 header

## 架構圖

```text
                    entity-graph-core 的 storyflow-store / storyflow-core
                                        │
                         ┌──────────────┴───────────────┐
                         │  storyflow-service           │  ★ 唯一業務契約
                         │                              │
                         │  ServiceM = ReaderT Env      │  Env = Vault+Conn+Registry
                         │             (ExceptT Err IO) │
                         │  28 個業務操作                │  型別驗證在這裡被呼叫
                         │  ServiceError / errorCode    │  錯誤語彙的唯一來源
                         └───┬──────────────────────┬───┘
                             │                      │
                   ┌─────────┘                      └─────────┐
                   │                                          │
       ┌───────────┴────────────┐              ┌──────────────┴──────────┐
       │  storyflow-api         │              │  storyflow-cli          │
       │  servant 型別(只有型別)│              │                         │
       │  ToSchema / HttpApiData│              │  Options(optparse)      │
       │  storyFlowOpenApi      │              │  Backend ─┬─ Embedded ───┼──► service
       └───┬────────────────┬───┘              │           └─ Remote ────┼──┐
           │                └──────────────────┼──► servant-client       │  │
           │                                   │  Render(唯一的渲染器)   │  │
   ┌───────┴──────────────┐                    └─────────────────────────┘  │
   │  storyflow-server    │                         exe: story-flow         │
   │                      │                                                 │
   │  handler(每個一行)  │◄────────────────────── HTTP ────────────────────┘
   │  MVar Env(序列化)   │
   │  bearerAuth(middleware)│
   │  toServerError       │  code 字串分派狀態碼,不碰 StoreError 建構子
   └──────────────────────┘
        exe: story-flow-serve                    對外:REST + OpenAPI
```

**兩種模式輸出相同是結構上成立的**:`Backend` 的分派落在「操作」層(23 個三行的分派函式),
指令層完全看不見兩個建構子,而渲染器只有一份。遠端路徑由 `servant-client` 依同一份 API
型別解碼回同一批 View 型別。

## 模組間公開介面與資料結構

模組之間的調用只有三條,方向單一:

| 呼叫方向 | 介面 |
|---|---|
| `storyflow-server` → `storyflow-service` | handler 收到解碼後的請求型別,呼叫對應的 `ServiceM` 操作;錯誤只看 `errorCode` 的字串 |
| `storyflow-cli` → `storyflow-service` / `storyflow-api` | `Backend` 的兩個建構子:`Embedded` 走 `ServiceM`、`Remote` 走由 `storyflow-api` 型別產生的 `servant-client` |
| `storyflow-server` / `storyflow-cli` → `storyflow-api` | 共用同一份 servant 路由型別與 `ToSchema`;OpenAPI 由它推導 |

線上資料格式:

本子系統不擁有落地格式(那是 `entity-graph-core`),它擁有**線上格式**:

- **View 型別**:`EntityView`(Entity + 路徑 + 錨點 + 警告)、`LevelView`(Level + 樹 + 路徑)、
  `VaultView` / `SearchHit` / `LinkReport` / `IndexReport` / `DeleteReport`
  ——`SearchHit` 自 2026-08-20 起帶 `shScore :: Maybe Double`(0–1,越大越相關):`conflict-detection`
  第 2 層的 `ByRetrieval` 需要相關度,而那個數字只有這一層拿得到。**FTS5 路徑帶正規化後的 bm25,
  中文兩字詞走的 `LIKE` 路徑給 `Nothing`** ——那條查詢是 `ORDER BY e.id`,根本沒有相關度可言,
  給一個合成分數會讓兩種完全不同的東西在型別上長得一模一樣。依既有的「`Maybe` 沒值時整個鍵不
  出現」約定,舊客戶端不受影響
- **請求型別**:`NewEntityReq` / `NewFragmentReq` / `NewLevelReq` / `NewNodeReq` / `EntityPatch`
- **CLI 的統一信封**:`{"ok":true,"data":…}` / `{"ok":false,"error":{"code":…,"message":…}}`
  ——AI Agent 只需 parse 一種形狀
- **REST 的錯誤 body**:`{"error":{"code":…,"message":…}}`,與信封的 `error` 同形

`ToSchema` 與 `ToJSON` **逐欄對齊**,有測試拿樣本值的 JSON 鍵集合比對 schema 的 `properties`
——兩者分開手寫是 OpenAPI 文件說謊最常見的來源。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `mtl` | `ServiceM` 的 `ReaderT` + `ExceptT` |
| `servant` | API 型別即契約 |
| `servant-server` + `warp` + `wai` + `http-types` | REST 伺服器(只有 `storyflow-server`) |
| `servant-client` + `http-client` | CLI 的遠端模式(只有 `storyflow-cli`) |
| `servant-openapi3` + `openapi3` + `insert-ordered-containers` + `lens` | OpenAPI 3 推導 |
| `optparse-applicative` | CLI 指令解析 |
| `aeson` | 全部 body 的編解碼(沿用 core 的規則) |
| `hspec` / `temporary` / `async` | 測試、臨時 Vault、並發測試 |

## 開發階段

對應主架構的 **P2 與 P3**,已全部完成。

## 功能規劃

### 階段一:P2 業務契約與內嵌 CLI

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 1 | service-contract | 以 `ServiceM` 定義五種實體的唯一業務契約 | entity-graph-core 全部 | F001 |
| 2 | cli-embedded | `story-flow` 指令的內嵌模式,全指令支援統一信封的 `--json` | #1 | F002 |

### 階段二:P3 API 契約、伺服器與遠端 CLI

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 3 | servant-api-server | servant REST API、OpenAPI 文件與 CLI 的遠端模式 | #1, #2 | F003 |

小結:共 **3 個 features、2 個階段**,全部已完成(`F001` ~ `F003` 皆 done)。
子系統可交付:P2 的「純 CLI 從零建出教室與琳達」與 P3 的「Agent 只靠 API 文件就能建/查
片段與關聯」兩條驗收標準都通過。

**已知的後續工作**(不構成新 feature,記在這裡免得被忘記):跨 Vault 的讀寫目前一律回
`501 cross_vault_unsupported`;要做的話會是本子系統的新 feature,而不是 `entity-graph-core` 的。

## Feature 契約卡

三個 feature 都已實作完成,卡片依既有實作回填,作用是把「這個 feature 守的是哪條線」
固定下來——本子系統之後的新 feature(例如跨 Vault 讀寫)也照同一格式加卡。

### service-contract

- **階段**:階段一(P2 業務契約與內嵌 CLI)
- **負責模組**:`storyflow-service`
- **實作的 Level 2 介面**:「對外契約」的內嵌那一組——`Env`、`ServiceM`、`openEnv`、
  `runService`、28 個業務操作(`createEntity` / `updateEntity` / `addNode` …)、
  `errorCode` / `renderServiceError`,以及 View 與請求型別
- **資料流管線段落**:管線中段——「自 Env 取出相依 → 業務驗證 → 委派 store 落地 → 組 View」,
  兩端的解碼與渲染不屬於本項
- **驗收標準**:23 個操作全部只在此定義一次;`expected revision` 是必填參數、不留逃生口;
  每個 `ServiceError` 都有 snake_case 的 `errorCode` 與說出下一步的繁中訊息;
  `build-depends` 不含 HTTP 與終端輸出相關套件(界線由套件描述檔證明)
- **明確不做**:不含 HTTP 與終端輸出;不 import `storyflow-conflict` 與 `storyflow-llm`
  (兩者是它的消費者);不碰落地細節

### cli-embedded

- **階段**:階段一(P2 業務契約與內嵌 CLI)
- **負責模組**:`storyflow-cli`(指令樹、`Backend` 抽象、渲染器)
- **實作的 Level 2 介面**:「對外契約」的 CLI 那一組——`story-flow [--vault] [--json] <名詞>
  <動詞>` 與 exit code 約定;消費 `ServiceM` 的 23 個操作,不新增業務介面;
  「模組間公開介面」的 `storyflow-cli` → `storyflow-service`(`Backend` 的 `Embedded` 建構子)
- **資料流管線段落**:管線兩端——「CLI 參數解碼」與「統一信封渲染」,中段委派 `ServiceM`
- **驗收標準**:全部子指令支援 `--json` 且輸出統一信封;exit code `0`/`1`/`2` 依成功、
  業務或傳輸失敗、用法錯誤區分;能純用 CLI 從零建出「教室」場景與琳達的片段
- **明確不做**:不 import `storyflow-store`、`storyflow-server` 與 `warp`;
  指令層不做任何業務判斷;不定義 REST 形狀

### servant-api-server

- **階段**:階段二(P3 API 契約、伺服器與遠端 CLI)
- **負責模組**:`storyflow-api`、`storyflow-server`,以及 `storyflow-cli` 的 `Remote` 分派
- **實作的 Level 2 介面**:「對外契約」的 REST 那一組——本卡涵蓋 14 條路徑 / 23 個 operation(第 15 條 `POST /conflict/context` 屬 `conflict-detection/F004`,第 16 條 `POST /conflict/check` 屬 `conflict-detection/F006`)、
  `revision` 必填 query parameter、`{"error":{"code":…,"message":…}}` 錯誤 body、
  `storyFlowOpenApi`;「模組間公開介面」的 server → service、cli → api 兩條
- **資料流管線段落**:管線兩端的 REST 半邊——「請求解碼 → handler」與「View → JSON」,
  以及遠端 CLI 從 `Backend` 分出去再回到同一條路的那一跳
- **驗收標準**:REST 覆蓋 `ServiceM` 的每一個操作;`story-flow-serve --openapi` 產出可用的
  OpenAPI 3 文件;CLI 兩種模式輸出完全相同(結構上成立:分派在操作層、渲染器只有一份);
  `MVar Env` 讓「先寫檔、再更新索引」在請求之間也是原子的;伺服器綁 loopback
- **明確不做**:handler 內不放業務判斷;`storyflow-api` 不含 `servant-server` /
  `servant-client` / `warp`;認證不進路由型別(走 WAI middleware)
