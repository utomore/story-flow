---
id: llm-workshop-mcp
type: subsystem
title: llm-workshop-mcp
description: 地端 LLM 端點、階段式引導工作坊與 MCP adapter
status: active
created: 2026-08-18
updated: 2026-08-20
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
| `storyflow-llm` | `Llm.Client` | OpenAI 相容端點的抽象:chat completion、逾時、重試、錯誤語彙 |
| | `Llm.Config` | 後端選擇與模型參數,讀 Vault 的 `.storyflow/config.toml` |
| `storyflow-workshop` | `Workshop.Session` | 一次工作坊的狀態:型別、已選的硬約束 Entity、目前階段、各階段的定案 |
| | `Workshop.Stages` | 依註冊表的 `stages` 驅動的狀態機:進入 / 對話 / 定案 / 下一階段 |
| | `Workshop.Emit` | 定案 → 多個 `NewEntityReq` / `NewFragmentReq`,經 service 寫進圖譜 |
| `storyflow-mcp` | `Mcp.Server` | MCP stdio 伺服器,把 REST 的 23 個操作暴露成 MCP tools |

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
startWorkshop  :: Text -> [Id] -> ServiceM Session   -- 型別 + 硬約束片段
stepWorkshop   :: LlmClient -> Session -> Text -> ServiceM (Session, Text)
commitStage    :: Session -> ServiceM (Session, [EntityView])   -- 定案該階段,寫進圖譜
```

對外形式:

| 出口 | CLI | REST |
|---|---|---|
| 工作坊 | `story-flow workshop start --type <型別> [--constraint <id>]…` / `step` / `commit` | `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit` |
| MCP | — | stdio(`storyflow-mcp`),tools 由 REST 的 23 個操作映射 |

**`LlmConfig` 與 `storyflow-store` 的佔位型別**(2026-08-20 批次澄清):`store` 早在 P1 就有一個
`newtype LlmConfig`,包著**未解讀的** `[llm]` TOML 表——它那行註解寫著「現在替它定義欄位,等於在
P1 就凍結 P5 還沒想清楚的設定形狀」。現在正是 P5:**形狀由本子系統定**,`store` 的佔位型別改名
(職責是「原樣捧著那張表」,不是「設定」),本子系統負責把表解析成上面四加一欄的 `LlmConfig`。
讀取路徑走 `service-and-interfaces` 新增的內嵌出口,**不直接依賴 `storyflow-store`**。

**Vault 沒有 `[llm]` 段時**(2026-08-20 批次澄清):`newLlmClient` **回錯誤,不猜預設值**。訊息要
說出下一步(在 `.storyflow/config.toml` 加 `[llm]` 段)。給一組地端預設值看似方便,但連不上時使用
者看到的是「連線失敗」而不是「你還沒設定」,那是兩個完全不同的下一步。**怎麼退化是消費者的決定**
——`conflict-detection` 第 3 層的契約本來就寫著「`LlmClient` 不可用時整條管線退化成前兩層」。

`LlmError` 要能區分「連不上地端服務」與「模型回了但格式不對」,理由與 CLI 的
`remote_unavailable` / `remote_bad_response` 相同:兩者的下一步完全不同。

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
  `service-and-interfaces` 的 REST API,所以 MCP adapter 本身**沒有業務邏輯**
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
                   │  MCP tools ← 23 個操作    │
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
| `Mcp.Server` → `service-and-interfaces` | 打 REST 的 23 個 operation,不 import `storyflow-service` |

資料結構:

```haskell
-- 一次工作坊。可序列化成快照,中斷後接得回來。
data Session = Session
  { wsId          :: Text
  , wsType        :: Text          -- 型別註冊表的鍵,決定 stages
  , wsConstraints :: [Id]          -- 勾選為硬約束的既有片段
  , wsStages      :: [Text]        -- 從註冊表讀來的階段清單
  , wsCurrent     :: Int           -- 目前在第幾階段
  , wsHistory     :: [Message]     -- 對話歷程(不寫進 Vault)
  , wsCommitted   :: [Id]          -- 已定案寫出去的片段
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
| MCP 的 Haskell 實作 | **待評估** —— 生態不成熟時以 stdio + JSON-RPC 自己實作,那不複雜 |

## 開發階段

對應主架構的 **P5**。內部三個里程碑,注意 **#1 會比 `conflict-detection` 的階段二先做**
——衝突偵測第 3 層依賴它。

## 功能規劃

### 階段一:LLM 存取

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 1 | llm-endpoint | OpenAI 相容端點抽象(地端 / 雲端同一介面)、設定、逾時與錯誤語彙 | service-and-interfaces | - |

### 階段二:工作坊

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 2 | workshop-stages | 依型別註冊表 `stages` 驅動的階段式狀態機與 session 快照 | #1 | - |
| 3 | workshop-emit | 每階段定案 → 產出多個片段 Entity 並經 service 寫進圖譜 | #2 | - |
| 4 | workshop-interface | 工作坊的 CLI 子指令與 REST 路由 | #3 | - |

### 階段三:MCP

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 5 | mcp-adapter | MCP stdio adapter,把 REST 的 23 個操作暴露成 MCP tools | service-and-interfaces | - |

小結:共 **5 個 features、3 個階段**。全部完成即達成主架構 P5 的完成標準「地端模型能引導
產出片段;claude code 以 MCP 直接操作」。

**跨子系統的排程提醒**:`#1 llm-endpoint` 是 `conflict-detection #5 conflict-llm` 的前置。實際
開發順序會是 `conflict-detection` 階段一 → 本子系統 `#1` → `conflict-detection` 階段二 → 本子系統
階段二、三。

## Feature 契約卡

五張卡,全部尚未展開。卡上寫的就是執行者能拿到的全部前提——`llm-endpoint` 是
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
- **負責模組**:`Workshop.Session`、`Workshop.Stages`
- **實作的 Level 2 介面**:「對外契約」的 `startWorkshop :: Text -> [Id] -> ServiceM Session`
  與 `stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Session, Text)`;
  「模組間公開介面」的 `Workshop.Stages` → `Llm.Client`、→ `Workshop.Session` 兩條
- **資料流管線段落**:工作坊管線的 `startWorkshop` → `stepWorkshop` 段(定案之前)
- **驗收標準**:階段清單完全來自型別註冊表的 `stages`——**新增一個型別不改工作坊的程式**;
  硬約束片段以 `summary` 進 prompt;`Session` 是可序列化的快照,中斷後接得回去;
  中途對話不寫進 Vault
- **明確不做**:不寫圖譜(那是 `workshop-emit`);不定義 CLI 與 REST 形狀;不自己實作端點

### workshop-emit

- **階段**:階段二(工作坊)
- **負責模組**:`Workshop.Emit`
- **實作的 Level 2 介面**:「對外契約」的
  `commitStage :: Session -> ServiceM (Session, [EntityView])`;
  「模組間公開介面」的 `Workshop.Emit` → `service-and-interfaces`
- **資料流管線段落**:工作坊管線的「定案 → `NewEntityReq` → service 寫入 → `[EntityView]`」
- **驗收標準**:一次定案產出**多個片段 Entity**,不是一份文件(這是相對 design-studio 的
  關鍵差異);寫入的 `source` 標成 `workshop:<型別>`;片段之間該有的 `partOf` 關聯一併建立;
  寫入走與 CLI 相同的 `ServiceM` 操作
- **明確不做**:不直接碰 `storyflow-store`;不決定階段流程(那是 `workshop-stages`);
  不在寫入失敗時自行重試改寫

### workshop-interface

- **階段**:階段二(工作坊)
- **負責模組**:`service-and-interfaces` 的 CLI 指令樹與 REST 路由(工作坊的三個出口)
- **實作的 Level 2 介面**:「對外契約」對外形式表的工作坊那一列——
  `story-flow workshop start --type <型別> [--constraint <id>]…` / `step` / `commit`,
  以及 `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit`
- **資料流管線段落**:工作坊管線的外部入口(參數/請求 → Session 操作 → 渲染回應)
- **驗收標準**:CLI 與 REST 行為一致;`--json` 走統一信封;錯誤沿用 `errorCode` 與
  `renderServiceError`;session id 在兩種介面裡是同一個東西
- **明確不做**:不含工作坊邏輯(薄包裝);不新增業務操作;不為工作坊另立一套錯誤語彙

### mcp-adapter

- **階段**:階段三(MCP)
- **負責模組**:`Mcp.Server`
- **實作的 Level 2 介面**:「對外契約」對外形式表的 MCP 那一列——stdio 傳輸,tools 由
  `service-and-interfaces` REST 的 23 個 operation 映射;「模組間公開介面」的
  `Mcp.Server` → `service-and-interfaces`
- **資料流管線段落**:MCP 管線全段(tool call → REST → tool result)
- **驗收標準**:23 個操作都有對應的 MCP tool 且參數形狀來自同一份 API 型別;錯誤沿用 REST 的
  `code` 與訊息;claude code 掛上後不必再讀 API 文件就能建/查片段與關聯
- **明確不做**:不含任何業務邏輯;不 import `storyflow-service`(只打 HTTP);
  不自行擴充 REST 沒有的操作
