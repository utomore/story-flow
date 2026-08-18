---
id: subarch-0004
type: subarch
title: llm-workshop-mcp
description: 地端 LLM 端點、階段式引導工作坊與 MCP adapter
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0003, adr-0005, adr-0006]
---

# LLM 與工作坊 子系統架構

## 定位與範圍

主架構「子系統劃分」的第四節,對應 **P5**。這個子系統把**「和 AI 對談」變成寫進圖譜的片段**。

涵蓋 `storyflow-llm`、`storyflow-workshop`、`storyflow-mcp` 三個套件,對應主架構核心功能
清單的第 5 項「雙 LLM 路徑」:地端模型做階段式引導工作坊,外部 AI Agent 透過 API/MCP 對談,
**兩條路徑寫進同一個圖譜**。

**明確不做**:

- 不自己定義業務操作。工作坊產出片段時走 `subarch-0002` 的 `service`,與 CLI 用的是同一組函式
- 不做衝突偵測。`subarch-0003` 是本子系統 LLM 端點的**消費者**,不是相依
- 不引入重量級 LLM SDK。`http-client` + `aeson` 直接打 OpenAI 相容端點

**`storyflow-mcp` 為什麼在這裡**:架構上它是 `subarch-0002` 的 REST API 的薄客戶端,與 LLM
無關。歸在這一組是因為它與工作坊同屬 P5、同樣服務「外部 AI Agent 接進來」這件事。真的長大到
值得單獨設計時再拆成獨立子系統 —— 這個張力在主架構的對應小節也記著。

## 需求說明

主架構的需求說明第一段指出 design-studio 的問題:「產出的粒度是**整份設計文件**」。工作坊要
解決的正是這件事 —— 它繼承 design-studio 最成功的設計(宣告式模組註冊表,已被 8 個模組驗證),
但**每階段定案後產出的是多個片段 Entity,不是一份文件**。

三條需求:

1. **地端優先**:「不依賴外部服務也能用」是本專案明確的需求(ADR-0007 的替代方案分析也
   以此為由否決了「判斷完全交給外部 Agent」)。所以 LLM 端點要能指向 llama.cpp 等地端服務
2. **階段由註冊表驅動**:每個 Entity 型別的 `stages` 已經寫在 `types/registry/*.toml` 裡
   (例如 `character-fragment` 是「定位 / 外貌與舉止 / 動機與過往 / 關係網」)。工作坊照著跑,
   **新增型別不改工作坊的程式**——這是垂直切片 1 延伸到 P5
3. **MCP 讓 claude code 直接操作**:主架構的資料流 A 已經以 REST 描述完整,MCP 只是換一層
   傳輸

## 架構規劃

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

## 對外介面

```haskell
-- storyflow-llm:subarch-0003 第 3 層與工作坊共用
data LlmClient
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text        -- 地端 http://127.0.0.1:8080/v1 或雲端
  , lcModel   :: Text
  , lcApiKey  :: Maybe Text
  , lcTimeout :: Int
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

`LlmError` 要能區分「連不上地端服務」與「模型回了但格式不對」,理由與 CLI 的
`remote_unavailable` / `remote_bad_response` 相同:兩者的下一步完全不同。

## 使用的技術

- **`http-client` + `aeson` 直接打 OpenAI 相容端點**,不引入重量級 SDK(主架構的技術選型)。
  地端 llama.cpp / Ollama 與雲端 OpenAI 共用同一組 JSON 形狀,抽象成本很低
- **MCP 走 stdio**:claude code / codex 的標準接法,而且不必再開一個 port。它打的是
  `subarch-0002` 的 REST API,所以 MCP adapter 本身**沒有業務邏輯**
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
            │        subarch-0003 conflict ─────────────┘
            │                                           │
            └───────────────────┬───────────────────────┘
                                ▼
                   subarch-0002 的 ServiceM(寫進圖譜)
                                ▲
                                │ REST
                   ┌────────────┴─────────────┐
                   │     storyflow-mcp        │  薄層:無業務邏輯
                   │  MCP tools ← 23 個操作    │
                   └────────────┬─────────────┘
                                │ stdio
                        claude code / codex
```

## 資料結構的框架格式

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
——與 ADR-0007 第 3 層同一個理由,優先送總結而非全文。

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

對應主架構的 **P5**。內部三個里程碑,注意 **#1 會比 `subarch-0003` 的階段二先做**
——衝突偵測第 3 層依賴它。

## 功能規劃

### 階段一:LLM 存取

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | llm-endpoint | OpenAI 相容端點抽象(地端 / 雲端同一介面)、設定、逾時與錯誤語彙 | subarch-0002 | - |

### 階段二:工作坊

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 2 | workshop-stages | 依型別註冊表 `stages` 驅動的階段式狀態機與 session 快照 | #1 | - |
| 3 | workshop-emit | 每階段定案 → 產出多個片段 Entity 並經 service 寫進圖譜 | #2 | - |
| 4 | workshop-interface | 工作坊的 CLI 子指令與 REST 路由 | #3 | - |

### 階段三:MCP

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 5 | mcp-adapter | MCP stdio adapter,把 REST 的 23 個操作暴露成 MCP tools | subarch-0002 | - |

小結:共 **5 個 features、3 個階段**。全部完成即達成主架構 P5 的完成標準「地端模型能引導
產出片段;claude code 以 MCP 直接操作」。

**跨子系統的排程提醒**:`#1 llm-endpoint` 是 `subarch-0003 #5 conflict-llm` 的前置。實際
開發順序會是 `subarch-0003` 階段一 → 本子系統 `#1` → `subarch-0003` 階段二 → 本子系統
階段二、三。
