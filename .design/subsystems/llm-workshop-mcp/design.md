---
id: llm-workshop-mcp
type: subsystem
title: llm-workshop-mcp
description: 地端 LLM 端點、階段式引導工作坊與 MCP adapter
status: active
created: 2026-08-18
updated: 2026-08-22
parent: system
related-adr: [ADR-003, ADR-005, ADR-006]
---

# LLM 與工作坊 子系統架構

## 定位與範圍

主架構「子系統劃分」的第四節,對應 **P5**。這個子系統把**「和 AI 對談」變成寫進圖譜的片段**。

涵蓋 `storyflow-llm`、`storyflow-workshop`、`storyflow-mcp` 三個套件,對應主架構核心功能
清單的第 5 項「雙 LLM 路徑」:地端模型做階段式引導工作坊,外部 AI Agent 透過 API/MCP 對談,
**兩條路徑寫進同一個圖譜**。

**明確不做**:

- 不自己定義業務操作。工作坊產出片段時走 `service-and-interfaces` 的 `service`,與 CLI 用的是同一組函式
- 不做衝突偵測。`conflict-detection` 是本子系統 LLM 端點的**消費者**,不是相依
- 不引入重量級 LLM SDK。`http-client` + `aeson` 直接打 OpenAI 相容端點

**`storyflow-mcp` 為什麼在這裡**:架構上它是 `service-and-interfaces` 的 REST API 的薄客戶端,與 LLM
無關。歸在這一組是因為它與工作坊同屬 P5、同樣服務「外部 AI Agent 接進來」這件事。真的長大到
值得單獨設計時再拆成獨立子系統 —— 這個張力在主架構的對應小節也記著。

## 需求說明

主架構的需求說明第一段指出 design-studio 的問題:「產出的粒度是**整份設計文件**」。工作坊要
解決的正是這件事 —— 它繼承 design-studio 最成功的設計(宣告式模組註冊表,已被 8 個模組驗證),
但**每階段定案後產出的是多個片段 Entity,不是一份文件**。

三條需求:

1. **地端優先**:「不依賴外部服務也能用」是本專案明確的需求(ADR-007 的替代方案分析也
   以此為由否決了「判斷完全交給外部 Agent」)。所以 LLM 端點要能指向 llama.cpp 等地端服務
2. **階段由註冊表驅動**:每個 Entity 型別的 `stages` 已經寫在 `types/registry/*.toml` 裡
   (例如 `character-fragment` 是「定位 / 外貌與舉止 / 動機與過往 / 關係網」)。工作坊照著跑,
   **新增型別不改工作坊的程式**——這是垂直切片 1 延伸到 P5
3. **MCP 讓 claude code 直接操作**:主架構的資料流 A 已經以 REST 描述完整,MCP 只是換一層
   傳輸

## 內部模組劃分(Internal Modules)

| 套件 | 元件 | 職責 |
|---|---|---|
| `storyflow-llm` | `Llm.Client` | OpenAI 相容端點的抽象:chat completion、逾時、重試 |
| | `Llm.Config` | 後端選擇與模型參數,讀 Vault 的 `.storyflow/config.toml` |
| | `Llm.Error` | `LlmError` 的五類分類與它的兩個輸出。獨立成葉子模組是為了避免 `Client` ↔ `Config` 互相 import(2026-08-22 補列:階段一的 arch-audit A-3 記過這一格漏列) |
| `storyflow-workshop` | `Workshop.Session` | 一次工作坊的狀態:型別、已選的硬約束 Entity、目前階段、各階段的定案 |
| | `Workshop.Stages` | 依註冊表的 `stages` 驅動的狀態機:進入 / 對話 / 定案 / 下一階段 |
| | `Workshop.Emit` | 定案 → 多個 `NewEntityReq` / `NewFragmentReq`,經 service 寫進圖譜 |
| | `Workshop.Error` | `WorkshopError` 的八個建構子與它的兩個輸出。與 `Llm.Error` 同一個切法、同一個理由(2026-08-22 補列) |
| `storyflow-mcp` | `Mcp.Server` | MCP stdio 伺服器,把 REST 的 24 個操作暴露成 MCP tools |

**工作坊的狀態存在哪裡**:記憶體 + 一份可序列化的 session 快照。工作坊是**互動流程**,
中途的對話不是「故事設定」,不該寫進 Vault 汙染圖譜;只有**定案的片段**才寫進去。

## 對外契約(Public Interface & DTOs)

```haskell
-- storyflow-llm:conflict-detection 第 3 層與工作坊共用
data LlmClient
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text        -- 地端 http://127.0.0.1:8080/v1 或雲端
  , lcModel   :: Text
  , lcApiKey  :: Maybe Text
  , lcTimeout :: Int
  , lcRetries :: Int         -- 2026-08-20 補:驗收標準說「逾時與重試由 LlmConfig 控制」,但原本
                             -- 沒有這一欄。預設保守,且只重試「連不上服務」類的錯誤——模型回了
                             -- 但格式不對,重試也不會變對
  }
newLlmClient :: LlmConfig -> IO LlmClient
chat :: LlmClient -> [Message] -> IO (Either LlmError Text)

-- storyflow-workshop
data WorkshopError
  = WsSessionNotFound Text              -- 沒有這個 session id 的快照
  | WsSnapshotCorrupt FilePath Text     -- 快照讀得到但解不開
  | WsSnapshotWriteFailed FilePath Text
  | WsNoStages Text                     -- 這個型別的註冊表宣告沒有 stages
  | WsStagesExhausted Text              -- 階段已走完,還想 step / commit
  | WsNothingToCommit Text              -- wsPending 是空的
  | WsMissingRequiredField Text [Text]   -- 型別鍵 + 還缺的必填欄位名
  | WsLlmFailed LlmError                -- 模型那一跳,原樣包住不攤平
renderWorkshopError :: WorkshopError -> Text
workshopErrorCode   :: WorkshopError -> Text

startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)
loadSession   :: Text -> ServiceM (Either WorkshopError Session)
stepWorkshop  :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))
commitStage   :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))
```

對外形式:

| 出口 | CLI | REST |
|---|---|---|
| 工作坊 | `story-flow workshop start --type <型別> [--constraint <id>]…` / `step` / `commit` | `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit` |
| MCP | — | stdio(`storyflow-mcp`),tools 由 REST 的**全部** operation 映射(數量由 API 型別決定,不寫死) |

**`LlmConfig` 與 `storyflow-store` 的佔位型別**(2026-08-20 批次澄清):`store` 早在 P1 就有一個
`newtype LlmConfig`,包著**未解讀的** `[llm]` TOML 表——它那行註解寫著「現在替它定義欄位,等於在
P1 就凍結 P5 還沒想清楚的設定形狀」。現在正是 P5:**形狀由本子系統定**,`store` 的佔位型別改名
(職責是「原樣捧著那張表」,不是「設定」),本子系統負責把表解析成上面四加一欄的 `LlmConfig`。
讀取路徑走 `service-and-interfaces` 新增的內嵌出口,**不直接依賴 `storyflow-store`**。

**Vault 沒有 `[llm]` 段時**(2026-08-20 批次澄清;2026-08-20 閘門前修正錯誤歸屬):**設定載入階段**
回錯誤,**不猜預設值**。訊息要說出下一步(在 `.storyflow/config.toml` 加 `[llm]` 段)。給一組地端
預設值看似方便,但連不上時使用者看到的是「連線失敗」而不是「你還沒設定」,那是兩個完全不同的下一
步。錯誤發生在**載入**而不是 `newLlmClient`——後者的簽名 `LlmConfig -> IO LlmClient` 沒有錯誤通道,
拿到 `LlmConfig` 的那一刻設定就已經是好的了。**怎麼退化是消費者的決定**——`conflict-detection` 第 3
層的契約本來就寫著「`LlmClient` 不可用時整條管線退化成前兩層」。

**`LlmError` 的分類**(2026-08-20 閘門裁定升格為契約):要能區分「連不上服務」與「模型回了但格式
不對」,理由與 CLI 的 `remote_unavailable` / `remote_bad_response` 相同:兩者的下一步完全不同。
實際落到**五類**——契約卡原本只寫兩類,但 401 與「形狀不對」的下一步同樣是兩回事,而「你還沒
設定」與「設定寫錯了」又是第三、第四回事:

| 建構子 | 什麼情況 | 可重試 | 下一步 |
|---|---|---|---|
| `LlmUnavailable` | 連線被拒、DNS 解不出、逾時、傳輸中斷 | **是** | 檢查地端服務有沒有起來 |
| `LlmHttpStatus` | 服務回了,但狀態碼不是 2xx(帶狀態碼與截斷的內文) | 否 | 看狀態碼:401 是金鑰、404 是路徑 |
| `LlmBadResponse` | 回了 2xx,但 JSON 不是 OpenAI 相容的形狀 | 否 | 換端點或換模型 |
| `LlmConfigMissing` | Vault 的 `config.toml` 沒有 `[llm]` 段 | 否 | 去加那一段 |
| `LlmConfigInvalid` | `[llm]` 在,但鍵缺漏 / 型別不對 / 認不得 | 否 | 照訊息改那一個鍵 |

**只有 `LlmUnavailable` 會被 `lcRetries` 重試**——其餘四類重試幾次都不會變對。

**`[llm]` 段的設定格式**(2026-08-20 閘門裁定升格為契約):這是使用者要手寫的東西,屬對外行為。

```toml
[llm]
base_url   = "http://127.0.0.1:8080/v1"  # 必填。指到 /v1 那一層,/chat/completions 由實作接上
model      = "..."                       # 必填
api_key    = "..."                       # 選填。地端通常不用;沒有時請求不帶 Authorization
timeout_ms = 60000                       # 選填,預設 60000。單位寫在鍵名裡
retries    = 1                           # 選填,預設 1。只作用於 LlmUnavailable
```

**未知鍵視為錯誤**(`LlmConfigInvalid`),與型別註冊表載入器同一立場:設定檔裡拼錯的鍵被默默
忽略,使用者會以為自己設定好了。

**Session 快照的落地位置**(2026-08-22 批次澄清):快照寫 Vault 的
`.storyflow/workshops/<session-id>.json`。**這不違反「中途對話不寫進 Vault」**——那句話講的是
「不進圖譜」,而 `.storyflow/` 底下的東西本來就不進圖譜:`store` 的索引掃描略過所有以 `.` 開頭
的名字,所以快照不會被索引、不會出現在 `list` / `search`、也不會被衝突偵測撈到。

Vault root 經 `service-and-interfaces` 於 2026-08-22 新增的內嵌出口 `vaultRoot :: ServiceM FilePath`
取得(**不**沿用 `vaultInfo`:它為了 `vvEntityCount` 會 `listEntities` 全表掃描,而快照每一 step
寫一次)。`storyflow-workshop` 與 `storyflow-llm` 同樣不准依賴 `storyflow-store`。

放 Vault 內而不是家目錄,是因為 `wsConstraints` 指的是**這個 Vault 裡的 Entity id**——快照跟著
Vault 走,換 Vault 就換一組工作坊;放家目錄則會出現「跨 Vault 拿到壞參照」。`.storyflow/.gitignore`
加一行 `workshops/`(與 `index.db` 同一個理由:未定案的對話是本機互動狀態,不是故事設定)。
**走完所有階段後快照保留,不自動刪除**;對外形式表只有 `start` / `step` / `commit` 三個出口,
清理由使用者自己刪檔。

**誰負責寫快照**:`startWorkshop`、`stepWorkshop`、`commitStage` 三者在**成功之後各自寫出**新的
快照,介面層只需要 `loadSession`。把存檔時機交給介面層,CLI 與 REST 兩邊就會各有一份判斷,
而那正是「session id 在兩種介面裡是同一個東西」最容易破的地方。

**工作坊的錯誤語彙**(2026-08-22 批次澄清;F002 的 A1 裁決):`storyflow-workshop` **自己一套
`WorkshopError`**,四個對外操作一律回 `ServiceM (Either WorkshopError …)`。

**不往 `storyflow-service` 的 `ServiceError` 加 `Workshop*` 建構子**:那會讓契約層的錯誤型別
認識 P5 的概念,而 `StoryFlow.Service` 的門面註解明寫著「明確不做的:conflict(P4)、
workshop(P5)、LLM」。`storyflow-llm` 的 `LlmError` 與 `storyflow-conflict` 的 `ReportNote`
已經是同一種形狀——**下層的錯誤型別不認識上層**,呈現一律交給介面層。

`WsLlmFailed` **包住 `LlmError` 而不攤平**,理由與 `ServiceError` 的 `StoreFailed` 原樣包住
`StoreError` 一模一樣:`renderLlmError` 的每一則訊息都已經寫成「說出下一步」的形式,重寫一遍
只會讓兩份訊息隨時間漂移。`LlmError` 的五類分類(見上)因此在工作坊路徑上完整可用——「你還沒
設定」與「地端服務沒起來」的下一步不同。

工作坊**沒有** `conflict-detection` 第 3 層那種「退化成前兩層」的逃生口:模型連不上,這一步就是
做不下去,所以錯誤要原樣浮到使用者面前,而不是被折成一個泛用的失敗。

`ServiceM` 本身的 `ServiceError` 通道仍然在用——`commitStage` 寫圖譜時的落地失敗(樂觀鎖過時、
必填欄位缺漏)是**業務層的失敗**,本來就該講 `ServiceError` 那套話。`WorkshopError` 只講工作坊
自己的失敗。

**階段定案的來源:結構化草稿**(2026-08-22 批次澄清):`commitStage` 的簽名**沒有** `LlmClient`,
所以定案時不再問一次模型。「把一段對話切成多個片段」發生在 `stepWorkshop`:它的 system prompt
要求模型在回覆裡附上約定的 JSON,解析成功就存進 `wsPending`。這與 `conflict-detection` 第 3 層
`Conflict.Judge` 是同一套做法(剝 code fence → decode,失敗**不捏假資料**)。

`stepWorkshop` 回傳的 `Text` 仍是**給人看的那段回覆**;結構化結果另存在 `Session` 裡。解析失敗時
`wsPending` 維持上一次成功的值,回覆照樣給人看——使用者可以再講一輪,不必重開工作坊。
`wsPending` 是空的時候 `commitStage` 回錯誤,**不寫出空片段**。

**一次工作坊 = 一份主題檔**(2026-08-22 批次澄清):

- 首次 `commitStage` 用 `createEntity` 建**主題檔**,`type` 取該型別在註冊表宣告的 `owner_type`
  (沒宣告就用型別鍵本身)。這對應既有的資料模型:檔案層主體寫 `type: character`、節層片段寫
  `type: character-fragment`,而 `owner_type` 這一欄存在的理由正是讓兩個鍵命中同一筆宣告
- 之後每個階段用 `addFragment` 往**同一份**主題檔加節
- 每個片段建 `partOf` 指向主體;`source` 一律 `workshop:<型別>`
- **`status` 一律 `draft`**(2026-08-22 裁決):ADR-003 定了「只有 `canon` 參與衝突偵測的比對
  基準」,理由是「草稿不該被拿來當『過去的設定』比對,否則每個未定案的想法都會製造假衝突」。
  剛跟模型談出來、作者還沒過目的片段正是那種東西。作者看過之後用
  `story-flow entity set --status canon` 敲定
- 主體 id 記在 `wsOwner`,快照帶著它,所以中斷後接回去仍寫進同一份檔案

**必填欄位由型別註冊表驅動**(2026-08-22;F003 設計階段查出的缺口):型別註冊表可以把任意
`Meta` 欄位宣告成必填(`fields` 的 `required = true`)。現況是 `lore-fragment` 與
`plot-fragment` 都宣告 `timeline` 必填,而 `createEntity` 在寫檔前跑驗證,缺必填欄位就
`ValidationFailed` 且**一個位元組都不寫**——若工作坊給不出那一欄,五個型別裡有兩個會**每次
定案都失敗**。

兩件事一起做,而且都**由註冊表驅動,不寫死欄位名**:

1. **`Workshop.Stages` 組 prompt 時把該型別的 `etsFields` 一併送進 system message**——欄位名、
   `fsRequired`、`fsHint` 三者都給。ADR-005 明寫 `fields` 與 `allowed_links`「同時是給作者與
   AI Agent 的提示來源」,這條路本來就在設計裡,只是還沒有人走。這也讓「**新增型別不改工作坊的
   程式**」這條驗收標準延伸到必填欄位:改 TOML 就改得動模型被要求填什麼
2. **`StageDraft` 帶 `sdTimeline`**,模型在約定 JSON 裡填。`commitStage` 在寫入前對照該型別的
   必填清單自己檢查,缺了就回 `WsMissingRequiredField`(帶型別鍵與缺的欄位名),**不讓
   `ValidationFailed` 直接噴到使用者面前**——後者講的是「寫入被拒絕」,而使用者要聽的是
   「再講一輪,把時間軸講出來」

`StageDraft` 仍然刻意**不**帶 `status` / `links` / `source`:那三者由 `commitStage` 依契約填,
不讓模型決定(見上一段)。`timeline` 不同——它是**內容**,只有讀過草稿的模型答得出來。

**MCP adapter 的連線與 tool 命名**(2026-08-22 批次澄清):

- **連線**:`story-flow-mcp --url <base>`,或 `STORYFLOW_URL` / `STORYFLOW_TOKEN` 兩個環境變數
  (旗標優先)。**沒設定或連不上就在 `initialize` 回錯誤並說出下一步**(「先跑 `story-flow serve`」)
  ——與 F001「沒有 `[llm]` 段就說你還沒設定,不猜預設值」同一個立場。adapter **不自己拉背景
  server**:ADR-006 已經為了孤兒行程、port 衝突、多 Vault 對應哪個 daemon 這三件事否決過那條路
- **tool 命名**:由 OpenAPI 的 `operationId` 推導,**不手維護對照表**。「claude code 掛上後不必再讀
  API 文件」的可測形式是 **MCP tools 數 == OpenAPI operation 數**,而那條斷言只有在名字同源時才
  守得住。手寫對照表漏一列不會紅——契約卡上 `24` 這個過期的計數就是這樣來的

## 資料流管線(Data Flow Pipeline)

兩條互不相干的管線,共用 `service-and-interfaces` 的業務契約當出口——這是「兩條路徑寫進同一個
圖譜」在資料流上的意思。

**工作坊(地端模型 → 片段 Entity)**

```text
選型別 + 勾選要當硬約束的既有 Entity + 起始概念
  → startWorkshop:讀型別註冊表的 stages 建立 Session(型別、硬約束、目前階段)
  → stepWorkshop:組 prompt(階段說明 + 硬約束片段的 summary + 使用者輸入)→ LlmClient.chat
      → 回覆與對話留在 Session(記憶體 + 可序列化快照),**不寫 Vault**
  → commitStage:該階段定案 → 多個 NewEntityReq → service 寫進圖譜 → [EntityView]
  → 進入下一階段,直到 stages 走完
```

**MCP(外部 Agent → 圖譜)**

```text
claude code / codex 的 tool call(stdio)
  → Mcp.Server 依 tool 名稱映射到 service-and-interfaces 的 REST operation
  → HTTP 請求 → 同一組業務契約 → JSON 回應原樣轉成 tool result
```

MCP adapter 沒有業務邏輯,錯誤語彙直接沿用 REST 的 `code` 與訊息;工作坊寫入圖譜時走的是
CLI 用的同一組 `ServiceM` 操作,不另開後門。

## 使用的技術

- **`http-client` + `aeson` 直接打 OpenAI 相容端點**,不引入重量級 SDK(主架構的技術選型)。
  地端 llama.cpp / Ollama 與雲端 OpenAI 共用同一組 JSON 形狀,抽象成本很低
- **MCP 走 stdio**:claude code / codex 的標準接法,而且不必再開一個 port。它打的是
  `service-and-interfaces` 的 REST API,所以 MCP adapter 本身**沒有業務邏輯**。協定層自己實作
  (JSON-RPC 2.0 over stdio),不引 MCP 套件
- **工作坊不引入額外的狀態儲存**:session 是記憶體物件 + 可序列化快照。中途對話不進 Vault

## 架構圖

```text
                        types/registry/*.toml
                        (每個型別的 stages)
                                 │ 讀 stages
   ┌─────────────────────────────┴──────────────────────────────┐
   │                    storyflow-workshop                       │
   │                                                             │
   │   Workshop.Session ──► Workshop.Stages ──► Workshop.Emit    │
   │   型別/硬約束/階段      進入·對話·定案·下一階段   定案→片段    │
   │        │                      │                    │        │
   └────────┼──────────────────────┼────────────────────┼────────┘
            │                      │ chat               │ NewEntityReq
            │                      ▼                    │
            │        ┌──────────────────────────┐       │
            │        │      storyflow-llm       │       │
            │        │  Llm.Client / Llm.Config │       │
            │        │  OpenAI 相容 chat        │       │
            │        └──────────┬───────────────┘       │
            │                   │ HTTP                  │
            │        ┌──────────┴───────────┐           │
            │        │ 地端 llama.cpp       │           │
            │        │ 或雲端 OpenAI 相容    │           │
            │        └──────────────────────┘           │
            │                   ▲                       │
            │                   │ 第 3 層逐對判斷        │
            │        conflict-detection conflict ─────────────┘
            │                                           │
            └───────────────────┬───────────────────────┘
                                ▼
                   service-and-interfaces 的 ServiceM(寫進圖譜)
                                ▲
                                │ REST
                   ┌────────────┴─────────────┐
                   │     storyflow-mcp        │  薄層:無業務邏輯
                   │  MCP tools ← 24 個操作    │
                   └────────────┬─────────────┘
                                │ stdio
                        claude code / codex
```

## 模組間公開介面與資料結構

模組之間的調用只有三條,`storyflow-llm` 對 `storyflow-workshop` 是可替換的相依:

| 呼叫方向 | 介面 |
|---|---|
| `Workshop.Stages` → `Llm.Client` | 只用 `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)`,不知道後端是地端還是雲端 |
| `Workshop.Stages` → `Workshop.Session` | 讀寫 `Session`(型別、硬約束、目前階段、各階段定案),狀態只在這裡變動 |
| `Workshop.Emit` → `service-and-interfaces` | 經 `ServiceM` 以 `NewEntityReq` 寫入,與 CLI 用同一組操作 |
| `Mcp.Server` → `service-and-interfaces` | 打 REST 的 24 個 operation,不 import `storyflow-service` |

資料結構:

```haskell
-- 一次工作坊。可序列化成快照,中斷後接得回來。
data Session = Session
  { wsId          :: Text
  , wsType        :: Text          -- 型別註冊表的鍵,決定 stages
  , wsConstraints :: [Id]          -- 勾選為硬約束的既有片段
  , wsStages      :: [Text]        -- 從註冊表讀來的階段清單
  , wsCurrent     :: Int           -- 目前在第幾階段
  , wsHistory     :: [Message]     -- 對話歷程(不進圖譜,隨快照落在 .storyflow/)
  , wsOwner       :: Maybe Id      -- 這次工作坊的主題檔;首次 commitStage 之後才有值
  , wsPending     :: [StageDraft]  -- 目前階段最後一次解析成功的片段草稿
  , wsCommitted   :: [Id]          -- 已定案寫出去的片段
  }

-- 一個還沒寫進圖譜的片段草稿。commitStage 的輸入形狀,由 stepWorkshop 從模型
-- 回覆的約定 JSON 解析而來。
--
-- 刻意比 NewFragmentReq 小:status / timeline / links / source 由 commitStage
-- 依契約自己填(source 一律 workshop:<型別>、partOf 指向 wsOwner),不讓模型決定
-- ——那幾欄的值錯了會直接汙染衝突偵測的比對基準(ADR-003:只有 canon 參與比對)。
data StageDraft = StageDraft
  { sdTitle    :: Text
  , sdSummary  :: Text
  , sdBody     :: Text
  , sdTags     :: [Text]
  , sdTimeline :: Maybe Timeline  -- 型別把 timeline 宣告為必填時,模型要在約定 JSON 裡給
  }

data Message = Message { msgRole :: Role, msgContent :: Text }
data Role = System | User | Assistant
```

**硬約束怎麼進 prompt**:`wsConstraints` 指到的片段以 `summary` 進 system message
——與 ADR-007 第 3 層同一個理由,優先送總結而非全文。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `http-client` + `http-client-tls` | 打 OpenAI 相容端點 |
| `aeson` | 請求與回應的編解碼(沿用全系統的規則) |
| `text` / `bytestring` / `containers` | 基礎 |
| `toml-reader` | 讀 Vault 的 LLM 後端設定 |
| `storyflow-core` / `storyflow-service` | 型別與業務操作 |
| MCP 的 Haskell 實作 | **自己實作**(2026-08-22 批次澄清)—— stdio 上的 JSON-RPC 2.0 加 `initialize` / `tools/list` / `tools/call` 三個方法,`aeson` 已在手上。Haskell 的 MCP 套件生態薄,引一個不穩定的外部相依換三百行程式碼不划算 |

## 開發階段

對應主架構的 **P5**。內部三個里程碑,注意 **#1 會比 `conflict-detection` 的階段二先做**
——衝突偵測第 3 層依賴它。

## 功能規劃

### 階段一:LLM 存取

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 1 | llm-endpoint | OpenAI 相容端點抽象(地端 / 雲端同一介面)、設定、逾時與錯誤語彙 | service-and-interfaces | F001 |

### 階段二:工作坊

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 2 | workshop-stages | 依型別註冊表 `stages` 驅動的階段式狀態機與 session 快照 | #1 | F002 |
| 3 | workshop-emit | 每階段定案 → 產出多個片段 Entity 並經 service 寫進圖譜 | #2 | F003 |
| 4 | workshop-interface | 工作坊的 CLI 子指令與 REST 路由 | #3 | F004 |

### 階段三:MCP

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 5 | mcp-adapter | MCP stdio adapter,把 REST 的 24 個操作暴露成 MCP tools | service-and-interfaces | - |

小結:共 **5 個 features、3 個階段**。全部完成即達成主架構 P5 的完成標準「地端模型能引導
產出片段;claude code 以 MCP 直接操作」。

**跨子系統的排程提醒**:`#1 llm-endpoint` 是 `conflict-detection #5 conflict-llm` 的前置。實際
開發順序會是 `conflict-detection` 階段一 → 本子系統 `#1` → `conflict-detection` 階段二 → 本子系統
階段二、三。

## Feature 契約卡

五張卡。`llm-endpoint` 已展開(F001),其餘四張待展開。卡上寫的就是執行者能拿到的全部前提——`llm-endpoint` 是
`conflict-detection` 階段二的前置,它的介面一旦動到就要回頭改本文件的「對外契約」。

### llm-endpoint

- **階段**:階段一(LLM 存取)
- **負責模組**:`Llm.Client`、`Llm.Config`
- **實作的 Level 2 介面**:「對外契約」的 `LlmConfig`、`newLlmClient`、
  `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)`,以及 `LlmError` 的分類
- **資料流管線段落**:工作坊管線的模型呼叫那一跳(`stepWorkshop` → `chat`);
  同一個介面也供 `conflict-detection` 第 3 層使用
- **驗收標準**:地端(llama.cpp / Ollama 等 OpenAI 相容端點)與雲端共用同一組型別與呼叫路徑;
  逾時與重試由 `LlmConfig` 控制;`LlmError` 能區分「連不上服務」與「模型回了但格式不對」
  (兩者的下一步不同);設定讀 Vault 的 `.storyflow/config.toml`
- **明確不做**:不引入重量級 LLM SDK(只用 `http-client` + `aeson`);不組 prompt
  (那是消費者的事);不做串流

### workshop-stages

- **階段**:階段二(工作坊)
- **負責模組**:`Workshop.Session`、`Workshop.Stages`、`Workshop.Error`
- **實作的 Level 2 介面**:「對外契約」的 `WorkshopError` / `renderWorkshopError` /
  `workshopErrorCode`、`startWorkshop`、`loadSession` 與 `stepWorkshop`(四者的簽名見契約,
  一律 `ServiceM (Either WorkshopError …)`);
  「模組間公開介面與資料結構」的 `Session` / `StageDraft`,以及
  `Workshop.Stages` → `Llm.Client`、→ `Workshop.Session` 兩條
- **資料流管線段落**:工作坊管線的 `startWorkshop` → `stepWorkshop` 段(定案之前)
- **驗收標準**:階段清單完全來自型別註冊表的 `stages`,**而 prompt 裡的欄位要求完全來自
  `etsFields`(名稱 / `fsRequired` / `fsHint`)**——**新增一個型別、或改它的必填欄位,都不改
  工作坊的程式**;硬約束片段以 `summary` 進 prompt;`Session` 是可序列化的快照,落在
  `.storyflow/workshops/<id>.json`,中斷後 `loadSession` 接得回去(三個寫入操作各自在成功後
  寫出快照);對話歷程不進圖譜;`stepWorkshop` 從模型回覆解析約定 JSON 存進 `wsPending`,
  解析失敗時保留上一次成功的值、回覆照樣給人看;`LlmError` 由 `WsLlmFailed` 原樣包住浮上來,
  不攤平也不折成泛用失敗;vault root 走 `vaultRoot`,**不碰 `storyflow-store`**
- **明確不做**:不寫圖譜(那是 `workshop-emit`);不定義 CLI 與 REST 形狀;不自己實作端點;
  **不往 `storyflow-service` 的 `ServiceError` 加建構子**

### workshop-emit

- **階段**:階段二(工作坊)
- **負責模組**:`Workshop.Emit`
- **實作的 Level 2 介面**:「對外契約」的
  `commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))`;
  「模組間公開介面」的 `Workshop.Emit` → `service-and-interfaces`
- **資料流管線段落**:工作坊管線的「定案 → `NewEntityReq` → service 寫入 → `[EntityView]`」
- **驗收標準**:一次定案產出**多個片段 Entity**,不是一份文件(這是相對 design-studio 的
  關鍵差異);**一次工作坊 = 一份主題檔**——首次 `commitStage` 用 `createEntity` 建主體
  (`type` 取註冊表的 `owner_type`,沒宣告就用型別鍵本身)並記進 `wsOwner`,之後每階段用
  `addFragment` 往同一份檔案加節;每個片段建 `partOf` 指向 `wsOwner`;寫入的 `source` 一律
  `workshop:<型別>`;`status` 一律 `draft`;**寫入前對照該型別的必填欄位清單自己檢查**,缺了
  回 `WsMissingRequiredField`(帶型別鍵與缺的欄位名),不讓 `ValidationFailed` 噴給使用者;
  `wsPending` 是空的時候回 `WsNothingToCommit`,**不寫出空片段**;寫入走與
  CLI 相同的 `ServiceM` 操作,落地失敗照樣講 `ServiceError` 那套話(`WorkshopError` 只講工作坊
  自己的失敗)
- **明確不做**:不直接碰 `storyflow-store`;**不判斷 stages 是否耗盡、不組 prompt、不決定
  階段的內容**(那些是 `workshop-stages`);不在寫入失敗時自行重試改寫。
  **但定案成功後負責把 `wsCurrent` 推進一格**——推進游標是「定案」這個動作本身的一部分,
  不是流程決策:判斷「還有沒有下一階段」的守衛仍然住在 `Workshop.Stages`
  (`WsStagesExhausted`)。2026-08-22 階段二閘門裁定,原本的「不決定階段流程」字面與實作
  牴觸(F003 A3)

### workshop-interface

- **階段**:階段二(工作坊)
- **負責模組**:`service-and-interfaces` 的 CLI 指令樹與 REST 路由(工作坊的三個出口)
- **實作的 Level 2 介面**:「對外契約」對外形式表的工作坊那一列——
  `story-flow workshop start --type <型別> [--constraint <id>]…` / `step` / `commit`,
  以及 `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit`;
  兩種介面都以 `loadSession` 取回 session,**不自己管存檔時機**
- **資料流管線段落**:工作坊管線的外部入口(參數/請求 → Session 操作 → 渲染回應)
- **驗收標準**:CLI 與 REST 行為一致;`--json` 走統一信封;錯誤沿用 `errorCode` 與
  `renderServiceError`;`WorkshopError` 在這一層才被折成使用者看得懂的訊息(走
  `renderWorkshopError` / `workshopErrorCode`,而它們對 `LlmError` 又是沿用
  `renderLlmError` / `llmErrorCode` 的原文,一路不重寫下層訊息);session id 在兩種介面裡是同一個東西
  ——同一份 `.storyflow/workshops/<id>.json`,CLI 開的 session 用 REST 接得下去
- **明確不做**:不含工作坊邏輯(薄包裝);不新增業務操作;不為工作坊另立一套錯誤語彙

### mcp-adapter

- **階段**:階段三(MCP)
- **負責模組**:`Mcp.Server`
- **實作的 Level 2 介面**:「對外契約」對外形式表的 MCP 那一列——stdio 傳輸,tools 由
  `service-and-interfaces` REST 的**全部** operation 映射(**數量不寫死**,由 API 型別決定);
  「模組間公開介面」的 `Mcp.Server` → `service-and-interfaces`;以及本文件的
  「MCP adapter 的連線與 tool 命名」一節
- **資料流管線段落**:MCP 管線全段(tool call → REST → tool result)
- **驗收標準**:**每一個** REST operation 都有對應的 MCP tool 且參數形狀來自同一份 API 型別
  ——可測形式是 **tools 數 == OpenAPI operation 數**,tool 名字由 `operationId` 推導,不手維護
  對照表;連線走 `--url` 或 `STORYFLOW_URL` / `STORYFLOW_TOKEN`(旗標優先),沒設定或連不上
  就在 `initialize` 回錯誤並指出「先跑 `story-flow serve`」;錯誤沿用 REST 的 `code` 與訊息;
  claude code 掛上後不必再讀 API 文件就能建/查片段與關聯
- **明確不做**:不含任何業務邏輯;不 import `storyflow-service`(只打 HTTP);
  不自行擴充 REST 沒有的操作;**不自己拉背景 server**(ADR-006 已否決那條路)
