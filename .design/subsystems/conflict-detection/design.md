---
id: conflict-detection
type: subsystem
title: conflict-detection
description: 三層衝突偵測:圖遍歷、FTS5 候選撈取與 LLM 判斷
status: active
created: 2026-08-18
updated: 2026-08-20
parent: system
related-adr: [ADR-002, ADR-003, ADR-005, ADR-007]
---

# 衝突偵測 子系統架構

## 定位與範圍

主架構「子系統劃分」的第三節,對應 **P4**。這是主架構所說「真正解決痛點的那一刀」:
給一段新劇情草稿,回答**它和既有設定有沒有矛盾、矛盾在哪幾個片段**。

涵蓋 `storyflow-conflict` 一個套件。設計完全依 ADR-007。

**明確不做**:

- **永不自動修改資料**。衝突報告只是報告,是否成立由作者判斷。第 3 層的品質完全取決於模型,
  地端小模型可能誤判 —— 自動改資料的風險與收益完全不成比例
- 不自己碰檔案與索引。所有讀取經 `service-and-interfaces` 的 `service`
- 不實作 LLM 端點。那是 `llm-workshop-mcp` 的 `llm-endpoint`,本子系統只消費它的介面

## 需求說明

主架構的需求說明第一條:「要跟 AI 討論新劇情時,無法回答『這段設定和過去寫過的東西有沒有
衝突』——文件層級太粗,衝突發生在文件**內部的某一段描述**」。

ADR-007 分析過兩個直覺解法都不可行:把整個世界觀丟給 LLM,在片段幾百個之後 context 塞不下、
成本線性上升、召回率很差;只看關聯圖則只能找到**已經被標註過**的矛盾 —— 但作者要是知道有
矛盾,早就標了。

因此分三層,**每層職責不同、成本遞增、輸出遞減**:大部分查詢在前兩層就結束,只有真正需要
語意判斷的少數對才燒 token。

還有一條同等重要的需求:**外部 Agent 常常只需要精準的 context,不需要 story-flow 代它判斷**。
claude code 自己有很強的判斷能力。所以前兩層要能單獨出口。

## 內部模組劃分(Internal Modules)

| 元件 | 職責 | 確定性 | 成本 |
|---|---|---|---|
| `Conflict.Types` | `Draft` / `ConflictOpts` / `GraphEvidence` / `HitLayer` / `ConflictHit` / `ContextHit` / `ConflictReport` | — | — |
| `Conflict.Json` | 上述型別的 aeson 實例,集中一處(同 `Core.Json` 的理由) | — | — |
| `Conflict.Graph`(第 1 層) | 順著草稿已引用片段的 `contradicts` / `supersedes` 遍歷,找已知矛盾與已被取代的設定 | 完全確定性、可重現 | 零 |
| `Conflict.Retrieval`(第 2 層) | 以關鍵詞 + `aliases` 用 FTS5 撈 top-N 候選;`canon` 過濾、`timeline` 過濾、關聯圖一跳擴充 | 確定性 | 每個關鍵詞一次 SQL(上限可調) |
| `Conflict.Judge`(第 3 層) | 草稿 × 候選逐對送 LLM 問「是否矛盾、矛盾在哪」 | 非確定性 | 每對一次呼叫 |
| `Conflict.Pipeline` | 三層合流、去重、依命中層級排序 | — | — |

**第 2 層的候選撈取策略刻意設計成可替換**。ADR-007 決定先不做 embedding 語意檢索
(多一個模型相依、多一套索引、換模型要重算),但把介面留成「策略」——未來要加只是多一個
策略並在排序時合併,不必動其他兩層。

## 對外契約(Public Interface & DTOs)

兩個出口,對應兩種使用者。

```haskell
-- 完整三層。judge 為 Nothing 時退化成只跑前兩層。
checkConflict
  :: Maybe LlmClient        -- llm-workshop-mcp 的端點;Nothing = 不跑第 3 層
  -> ConflictOpts           -- topN、是否展開 body、timeline 容忍範圍
  -> Draft                  -- 草稿文字 + 已引用的片段 id
  -> ServiceM ConflictReport

-- 只跑前兩層,把相關片段撈出來就交還(ADR-007 的 context 指令)。
gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]
```

對應的對外形式:

| 出口 | CLI | REST |
|---|---|---|
| 完整偵測 | `story-flow conflict check --draft <檔案\|-> [--top-n] [--no-llm]` | `POST /conflict/check` |
| 只撈 context | `story-flow context --for <檔案\|->` | `POST /conflict/context` |

**輸出契約**:report 的每一筆都帶 **(候選片段 id, 命中層級, 理由)**。命中層級必須標示出來
—— 第 1 層的結果是**事實**,第 3 層的結果是**判斷**,使用者需要知道差別。CLI 的人類模式
以不同前綴區分,`--json` 走 `service-and-interfaces` 的統一信封。

## 資料流管線(Data Flow Pipeline)

一條管線、兩個出口;成本沿著管線遞增,前面的層先把問題解掉的部分不必再燒 token。

```text
Draft(草稿文字 + 已引用的片段 id)
  → 第 1 層 Conflict.Graph:以 drRefs 為起點,順 contradicts / supersedes 遍歷
      → 已知矛盾 / 已被取代(確定性、零成本,證據帶 GraphEvidence)
  → 第 2 層 Conflict.Retrieval:草稿關鍵詞 + aliases → service 的 searchEntity → top-N
      → status = canon 過濾 → timeline 過濾 → 候選的 partOf / occursIn 一跳擴充
  → 出口 A(gatherContext):候選轉 [ContextHit] 直接回傳,到此為止
  → 第 3 層 Conflict.Judge:草稿 × 候選逐對送 LlmClient,優先送 summary,必要才展開 body
  → Conflict.Pipeline:三層合流、去重、依命中層級與分數排序
  → 出口 B(checkConflict):ConflictReport(每筆帶候選 id、命中層級、理由)
```

所有讀取都經 `service-and-interfaces` 的 `ServiceM`,本子系統不直接碰 `store` 與檔案;
`judge` 為 `Nothing` 時管線在第 2 層之後直接進合流,退化成完全確定性的兩層。

## 使用的技術

沿用主架構,無新的重量級相依。三個子系統特有的決定:

- **第 1 層沿用 core 的 `LinkGraph`,但反向遍歷寫在本子系統**:圖結構不另造,直接吃
  `StoryFlow.Core.Graph` 的 `LinkGraph`。走訪則自己來——core 的 `follow` /
  `supersededSet` / `contradictionPairs` 回的是正規化過的集合,說不出「誰取代的」、
  「幾跳」、「哪一條關聯」,而那三樣正是命中要交出去的證據。`supersededSet` 保留為
  測試 oracle(F002)
- **第 2 層直接用 `service` 的 `searchEntity`**:FTS5 的 trigram 與兩字詞改走 `LIKE` 的處理
  都在 `entity-graph-core`,本子系統不重複那個判斷
- **第 3 層優先送 `summary` 而非全文**,必要時才展開 `body` —— 這是控制 token 成本的主要手段

## 架構圖

```text
        草稿(Draft:文字 + 已引用的片段 id)
                    │
    ┌───────────────┴────────────────────────────────────┐
    │              storyflow-conflict                     │
    │                                                     │
    │  ┌──────────────────────────────────────────────┐   │
    │  │ 第 1 層 Conflict.Graph        確定性・零成本  │   │
    │  │  順 contradicts / supersedes 遍歷            │   │
    │  │  「你正在引用一個已經被推翻的設定」            │   │
    │  └───────────────────┬──────────────────────────┘   │
    │                      │ 已知矛盾 / 已被取代            │
    │  ┌───────────────────┴──────────────────────────┐   │
    │  │ 第 2 層 Conflict.Retrieval  確定性・每詞一次 SQL│   │
    │  │  FTS5(關鍵詞 + aliases)→ top-N              │   │
    │  │  過濾:status=canon / timeline               │   │
    │  │  擴充:候選的 partOf / occursIn 一跳          │   │
    │  │  ◄── 策略可替換(未來 embedding 從這裡進)     │   │
    │  └───────────────────┬──────────────────────────┘   │
    │                      │ 候選片段                      │
    │         ┌────────────┴─────────────┐                │
    │         │                          │                │
    │    context 出口               ┌────┴──────────────┐  │
    │    (只到這裡)                │ 第 3 層 Judge     │  │
    │         │                    │  逐對送 LLM       │──┼──► llm-workshop-mcp
    │         │                    │  優先送 summary   │  │    llm-endpoint
    │         │                    └────┬──────────────┘  │
    │         │                         │ 語意判斷        │
    │         │    ┌────────────────────┴──────────────┐  │
    │         │    │ Conflict.Pipeline 合流・去重・排序 │  │
    │         │    └────────────────┬──────────────────┘  │
    └─────────┼─────────────────────┼─────────────────────┘
              ▼                     ▼
        [ContextHit]          ConflictReport
     story-flow context     story-flow conflict check
     POST /conflict/context POST /conflict/check
```

所有讀取都經 `service-and-interfaces` 的 `ServiceM`,本子系統不直接碰 `store`。

## 模組間公開介面與資料結構

模組之間的調用沿著管線單向前進,型別是唯一的耦合:

| 呼叫方向 | 介面 |
|---|---|
| `Conflict.Graph` / `Retrieval` / `Judge` → `Conflict.Types` | 三層都只吐 `ConflictHit` / `ContextHit`,證據放進 `HitLayer` |
| `Conflict.Pipeline` → 三層 | 依 `ConflictOpts` 決定跑到哪一層,合流時只看 `HitLayer` 排序 |
| `Conflict.Retrieval` → `service-and-interfaces` | 經 `ServiceM` 呼叫 `searchEntity`,不自己開索引連線 |
| `Conflict.Judge` → `llm-workshop-mcp` | 消費 `LlmClient` 的 `chat`,不實作端點 |

型別定義:

```haskell
-- 草稿:文字加上作者/Agent 已經知道它引用了哪些片段
data Draft = Draft { drText :: Text, drRefs :: [Id] }

-- 命中層級。第 1 層是事實,第 3 層是判斷 —— 這個區分必須出現在輸出裡。
data HitLayer
  = ByGraph GraphEvidence   -- contradicts / supersedes,附上那條關聯
  | ByRetrieval Double      -- FTS5 的相關度分數
  | ByJudge Double          -- LLM 的信心 0–1(不在型別層壓成三級)

-- 第 1 層的證據。形狀對齊 Core.Graph 的 contradictionPairs :: LinkGraph -> [(Id, Ref)]
-- ——geTo 是 Ref 而非 Id,跨 Vault 的命中才表達得出來。
data GraphEvidence = GraphEvidence
  { geFrom :: Id
  , geKind :: LinkKind
  , geTo   :: Ref
  }

data ConflictHit = ConflictHit
  { chTarget  :: Id         -- 候選片段
  , chLayer   :: HitLayer
  , chReason  :: Text       -- 第 1 層是關聯敘述,第 3 層是模型給的理由
  , chSnippet :: Maybe Text -- 命中的那一段
  }

-- context 指令回的素材:直接帶 Meta,省掉一輪往返。
-- 與 ConflictHit 是兩種東西:那個是「矛盾」的判斷,這個是「相關」的素材。
data ContextHit = ContextHit
  { xhMeta    :: Meta
  , xhSnippet :: Text
  , xhVia     :: HitLayer
  }

data ConflictReport = ConflictReport
  { crHits    :: [ConflictHit]   -- 依層級與分數排序
  , crScanned :: Int             -- 掃過幾個候選,讓使用者判斷 top-N 夠不夠
  , crLlmUsed :: Bool            -- 有沒有跑第 3 層
  }
```

`ConflictOpts` 的 `topN` **可調且預設保守** ——成本與延遲隨候選數量上升。

## 使用到的套件

沿用既有:`base` / `text` / `containers` / `aeson` / `mtl` / `storyflow-core` /
`storyflow-service`,加上 `llm-workshop-mcp` 的 `storyflow-llm`。**沒有新的外部相依**
——三層用的東西前面的子系統都已經提供。

## 開發階段

對應主架構的 **P4**。內部分兩個里程碑:

1. **前兩層可交付**:完全確定性、可寫測試、可在沒有任何模型的環境跑。`context` 指令此時就能
   給外部 Agent 用
2. **三層完整**:需要 `llm-workshop-mcp` 的 `llm-endpoint` 先到位

## 功能規劃

### 階段一:確定性的兩層(不需要模型)

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 1 | conflict-types | 衝突報告的型別、命中層級證據與序列化 | entity-graph-core/F002 | F001 |
| 2 | conflict-graph | 第 1 層:順 `contradicts` / `supersedes` 遍歷找確定性命中 | #1 | F002 |
| 3 | conflict-retrieval | 第 2 層:FTS5 候選撈取,含 `canon` / `timeline` 過濾與一跳擴充,策略可替換 | #1 | F003 |
| 4 | context-command | `story-flow context --for` 與 `POST /conflict/context`,只跑前兩層 | #2, #3 | F004 |

### 階段二:語意判斷

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 5 | conflict-llm | 第 3 層:草稿 × 候選逐對判斷,優先送 `summary` | #3, llm-workshop-mcp #1 | - |
| 6 | conflict-check | 三層合流與排序、report 渲染(標示命中層級)、確認衝突後提示建立 `contradicts` 關聯 | #4, #5 | - |

小結:共 **6 個 features、2 個階段**。階段一結束即可交付 `context` 指令;兩階段都完成才算
達成主架構 P4 的完成標準「拿真實草稿測出既有設定的矛盾,且能說出是哪個片段的哪一段」。

**#6 的關聯建議提示**是 ADR-007「影響/中立」那條的實作:第 1 層的價值取決於作者是否勤於
標註,所以確認衝突後主動問「要不要建立這條關聯」,讓下次變成零成本的確定性命中。

## Feature 契約卡

六張卡。前兩張(`conflict-types`、`conflict-graph`)已有 Level 3 文檔,其餘四張是尚未展開的
委派輸入——卡上寫的就是執行者能拿到的全部前提,不足以支撐判斷的地方要回頭補本文件的契約章節。

### conflict-types

- **階段**:階段一(確定性的兩層)
- **負責模組**:`Conflict.Types`、`Conflict.Json`
- **實作的 Level 2 介面**:「模組間公開介面與資料結構」的全部型別——`Draft`、`ConflictOpts`、
  `GraphEvidence`、`HitLayer`、`ConflictHit`、`ContextHit`、`ConflictReport`,以及它們的
  aeson 實例(集中在 `Conflict.Json`)
- **資料流管線段落**:不走管線任何一段;它是管線上所有訊息的載體
- **驗收標準**:`HitLayer` 三個建構子分別帶得動關聯證據、檢索分數與模型信心;
  `GraphEvidence` 的 `geTo` 是 `Ref` 而非 `Id`(跨 Vault 命中表達得出來);JSON round-trip
  不失真;`storyflow-conflict` 的 `build-depends` 只有 `storyflow-core`
- **明確不做**:不含任何偵測邏輯;不碰 `service` / `store`;不定義 CLI 與 REST 形狀

### conflict-graph

- **階段**:階段一(確定性的兩層)
- **負責模組**:`Conflict.Graph`
- **實作的 Level 2 介面**:無新增對外契約。消費 `storyflow-core` 的 `LinkGraph`,產出
  `Conflict.Types` 的 `[ConflictHit]`(`HitLayer` 用 `ByGraph`)
- **資料流管線段落**:第 1 層——從 `Draft` 的 `drRefs` 進去,吐已知矛盾與已被取代的命中
- **驗收標準**:矛盾命中為固定一跳且雙向;取代命中反向 BFS 走到回鏈末端;結果去重且排序
  確定(同一輸入永遠同一輸出);起點為空時明確回報而不是靜默回空;純函式,不開索引連線
- **明確不做**:不撈 FTS5;不呼叫 LLM;不碰 `service` 與 `store`;不擴充
  `storyflow-conflict` 的 `build-depends`

### conflict-retrieval

- **階段**:階段一(確定性的兩層)
- **負責模組**:`Conflict.Retrieval`
- **實作的 Level 2 介面**:無新增對外契約。經 `ServiceM` 使用 `service-and-interfaces` 的
  `searchEntity`,產出 `ConflictHit` / 候選集合(`HitLayer` 用 `ByRetrieval`);
  候選撈取策略本身是本模組的內部抽象,對外只露「候選」這個結果
- **資料流管線段落**:第 2 層——從草稿文字進去,吐經過 `canon` / `timeline` 過濾與一跳擴充的
  top-N 候選
- **驗收標準**:`topN` 由 `ConflictOpts` 控制且預設保守;只有 `status = canon` 的片段成為
  比對基準;`timeline` 過濾掉時序上不可能相關的候選;候選以 `partOf` / `occursIn` 一跳擴充;
  換一種候選策略不需要改動第 1、3 層
- **關鍵詞抽取**(2026-08-20 補):兩路併用後合併去重——(a)**反向比對**既有 canon 片段的
  `metaTitle` / `metaAliases`,看哪些既有名稱出現在草稿裡(ADR-007「比對到的 aliases」的字面
  意思,精準且零誤判);(b)**切詞**:依標點與空白切草稿,取足夠長的片段補召回。只做其中一路
  都不合格:只切詞則中文沒有空白、品質全看標點;只比對 alias 則作者沒寫 alias 的片段完全撈不到,
  等於把 ADR-007 的緩解措施當成唯一手段
- **`timeline` 過濾與 `topN` 的先後**(2026-08-20 補):`EntityFilter` 沒有 timeline 欄位,
  過濾只能發生在 SQL 之後。因此**過度撈取再截斷**:SQL 撈 `topN` 的數倍,過濾掉時序上不可能
  相關的之後再截到 `topN`。`crScanned` 記的是**實際掃過的候選數(含被過濾掉的)**,使用者才
  判斷得出 `topN` 夠不夠。先撈 `topN` 再過濾會讓開了 timeline window 之後候選憑空少一截,而
  調大 `topN` 也未必補得回來
- **相關度分數的來源**(2026-08-20 補):消費 `service-and-interfaces` 新增的
  `shScore :: Maybe Double`。`Nothing`(中文兩字詞走的 `LIKE` 路徑沒有相關度可言)時回退到
  依名次推導,不得捏一個假分數混進 `ByRetrieval`
- **明確不做**:不做語意判斷;不引入 embedding 模型與第二套索引;不重複 FTS5 的兩字詞處理
  (那在 `entity-graph-core`)

### context-command

- **階段**:階段一(確定性的兩層)
- **負責模組**:`Conflict.Pipeline` 的 context 出口,以及 `service-and-interfaces` 的 CLI /
  REST 接線
- **實作的 Level 2 介面**:「對外契約」的 `gatherContext :: ConflictOpts -> Draft ->
  ServiceM [ContextHit]`,對應 `story-flow context --for <檔案|->` 與 `POST /conflict/context`
- **資料流管線段落**:第 1 層 + 第 2 層 → 出口 A
- **驗收標準**:在完全沒有模型的環境跑得完;每筆 `ContextHit` 帶 `Meta` 與命中片段的 snippet
  (外部 Agent 不必再往返一次);`--json` 走 `service-and-interfaces` 的統一信封;
  CLI 與 REST 兩種形式回同一批結果
- **明確不做**:不跑第 3 層;不回傳「矛盾」的判斷(那是 `conflict-check`);不改任何資料

### conflict-llm

- **階段**:階段二(語意判斷)
- **負責模組**:`Conflict.Judge`
- **實作的 Level 2 介面**:無新增對外契約。消費 `llm-workshop-mcp` 的 `LlmClient` 與 `chat`,
  產出 `HitLayer` 為 `ByJudge` 的 `ConflictHit`
- **資料流管線段落**:第 3 層——吃第 2 層的候選,逐對輸出語意判斷
- **驗收標準**:預設只送 `summary`,必要時才展開 `body`;模型信心以 0–1 的浮點進 `ByJudge`,
  不在型別層壓成三級;`LlmClient` 不可用時整條管線退化成前兩層而不是整個失敗;
  每筆命中都帶模型給的理由
- **明確不做**:不實作 LLM 端點(那是 `llm-workshop-mcp` 的 `llm-endpoint`);
  **永不自動修改資料**;不決定命中是否成立(那是作者的判斷)

### conflict-check

- **階段**:階段二(語意判斷)
- **負責模組**:`Conflict.Pipeline`,以及 `service-and-interfaces` 的 CLI / REST 接線
- **實作的 Level 2 介面**:「對外契約」的 `checkConflict :: Maybe LlmClient -> ConflictOpts ->
  Draft -> ServiceM ConflictReport`,對應
  `story-flow conflict check --draft <檔案|-> [--top-n] [--no-llm]` 與 `POST /conflict/check`
- **資料流管線段落**:三層合流、去重、排序 → 出口 B
- **驗收標準**:report 每一筆都標示命中層級(第 1 層是事實、第 3 層是判斷,使用者看得出差別);
  `crScanned` 讓使用者判斷 top-N 夠不夠、`crLlmUsed` 說明有沒有跑第 3 層;`--no-llm` 與
  未設定端點都退化成兩層;確認衝突後提示作者建立 `contradicts` 關聯(下次就是零成本命中)
- **明確不做**:不自動寫入關聯,只提示;不修改任何片段;不在 CLI 層重做排序邏輯
