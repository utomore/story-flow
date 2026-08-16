---
id: architecture
type: architecture
title: story-flow
description: 以 Entity 片段圖譜管理故事設定並偵測劇情衝突的工具
status: active
created: 2026-08-16
updated: 2026-08-16
---

## story-flow 系統架構

> 本專案以 `design-studio`(Python/FastAPI 的 AI 引導式設計工作坊)為範本重新構思,但**不是**
> 它的改寫版本:資料模型從「模組 → 一份設計報告」換成「Entity 片段圖譜 + Level 場景樹」,
> 語言從 Python 換成 Haskell,介面從網頁優先換成 API 優先。`design-studio` 保留在
> `alchbees-dev/design-studio/` 並存不動(提示詞工房仍可使用),不做資料遷移。

### 需求說明

design-studio 解決了「和 LLM 一問一答沒有結構」的問題,但產出的粒度是**整份設計文件**。
一旦世界觀累積到幾十份文件,真正的痛點浮現:

- 要跟 AI 討論新劇情時,無法回答「這段設定和過去寫過的東西有沒有衝突」——文件層級太粗,
  衝突發生在文件**內部的某一段描述**,不是整份文件
- 設定與設定之間的關係(誰取代誰、哪兩段矛盾、這個道具出現在哪個場景)只存在於作者腦中
- 場景/演出的組織(誰出場、鏡頭怎麼走、哪句對話接哪句)沒有地方放,寫在文件裡就散了
- 設計資料只有網頁與 CLI 兩個人用的介面,AI Agent(claude code、codex)要接進來沒有契約

story-flow 是**故事設定的片段圖譜與場景樹管理工具**。核心主張:**能被關聯的最小單位是「片段」,
不是「文件」**。「世界觀:歷史」不是一個 Entity;歷史裡「描述埃提亞這個地區在崩塌前的樣貌」
那一段才是一個 Entity。片段夠細,關聯才有意義,衝突偵測才可能精準。

核心功能清單(依優先順序):

1. **Entity 片段圖譜**——建立/查詢/修改片段,片段之間以**有方向性**的關聯連結。世界觀、角色、
   道具、故事、對話全部都是 Entity;一個角色由多個 Entity 組成(外貌、動機、與某人的過節……),
   一份世界觀也由多個 Entity 組織而成
2. **Level 場景樹**——集中的場景結構,由 Node 樹狀無限展開。Node 負責「這個場景的第幾步、
   接下來接什麼、鏡頭怎麼走」的**結構與演出**;內容一律關聯到 Entity
3. **衝突偵測**——給一段新劇情草稿,回答「和既有設定有沒有矛盾」,並指出是哪幾個片段
4. **API 優先**——REST/JSON 是唯一的業務契約,CLI(`story-flow`)與 MCP adapter 都是薄客戶端,
   claude code / codex 能直接接
5. **雙 LLM 路徑**——地端模型(llama.cpp 等 OpenAI 相容端點)做階段式引導工作坊;外部 AI Agent
   透過 API/MCP 對談。兩條路徑寫進同一個圖譜
6. **多 Vault**——一個 Vault = 一個世界/作品,設定可跨 Vault 引用(共用美術風格、通用道具)

使用者:單人工作室(alchbees)。story-flow 與 `assetdb` 平行——`assetdb` 管「已經存在的素材」,
story-flow 管「故事設定與敘事結構」。兩者無程式化相依。

明確**不在**本專案範圍內的:遊戲執行期的對話播放引擎、多人協作與權限、Web UI(P6 才評估)。

### 架構規劃(含垂直切片說明)

依「純核心 → 落地 → 業務 → 介面」四層切,依賴單向向下,核心不知道介面存在:

| 層 | 套件 | 職責 |
|---|---|---|
| 型別註冊表 | `types/registry/*.toml`(資料,非程式) | 宣告每個 Entity 型別的名稱、建議欄位、允許的關聯、工作坊階段、**檔案子目錄 `dir`** 與**所屬主體型別 `owner_type`**。新增型別不改程式 |
| 純核心 | `storyflow-core` | `Meta` / `Entity` / `Link` / `Level` / `Node` / `LinkKind` 型別與純函式(樹的合法性、關聯遍歷、ID 生成、註冊表驗證)。**零 IO** |
| 註冊表載入 | `storyflow-types` | 讀 `types/registry/*.toml`、解析、交給 `core` 的純驗證函式。唯一的 IO 是讀檔——`core` 零 IO 放不下這件事,因此獨立成薄套件 |
| 解析 | `storyflow-md` | Markdown 分節格式 ↔ 核心型別的雙向轉換(解析與寫回)。純函式,吃 `Text` 吐型別 |
| 落地 | `storyflow-store` | 檔案讀寫(原子寫入)、SQLite 索引建立與重建、FTS5 trigram 檢索、樂觀鎖 |
| 業務契約 | `storyflow-service` | **所有業務操作的唯一定義處**。CLI 與 server 都只是它的包裝 |
| 衝突偵測 | `storyflow-conflict` | 三層偵測:圖遍歷 → FTS5 候選撈取 → LLM 判斷 |
| LLM 存取 | `storyflow-llm` | OpenAI 相容端點抽象(地端/雲端),與 design-studio 的 `llm.py` 同一個思路 |
| 工作坊 | `storyflow-workshop` | 階段式引導對話的狀態機,產出的東西寫進圖譜。**Entity 的產生器之一,核心不依賴它** |
| API 契約 | `storyflow-api` | **只有** servant API 型別與 `ToSchema` 實例的薄套件,不含 server 也不含 client。`server` 與 `cli --remote` 各自依賴它,因此 CLI 不會被拖進 `warp`,而兩者共用的仍是同一份型別 |
| 介面 1 | `storyflow-server` | servant REST API,綁 loopback |
| 介面 2 | `storyflow-cli` | `story-flow` 指令,預設內嵌呼叫 `Service`,`--remote` 改走 servant-client |
| 介面 3 | `storyflow-mcp` | MCP adapter,薄層,打同一組 HTTP API |

**垂直切片 1(新增一個 Entity 型別)**:在 `types/registry/` 加一份 `.toml`。CLI 的 `--type` 選項、
API 的型別清單、工作坊階段、該型別允許的關聯、**新建檔案落在哪個子目錄**全部自動跟進,
`core`/`service`/`server`/`cli` 不改一行。這是直接繼承 design-studio 最成功的設計
(宣告式模組註冊表,已被 8 個模組驗證)。

`dir` 與 `owner_type` 是為了讓「新建一份主題檔要放哪裡」也是宣告式的。`owner_type` 同時補上
一個資料裡本來就有、註冊表卻沒表達的事實:檔案層主體寫 `type: character`、節層片段寫
`type: character-fragment`,前者原本不在註冊表裡,查目錄與型別驗證都會落空。宣告
`owner_type = "character"` 之後,兩個鍵都命中同一筆宣告。`level` 是保留鍵不可出現在註冊表,
Level 檔的目錄因此固定為 `levels/`。

**註冊表在執行期怎麼被找到**:`types/registry/*.toml` 隨程式碼版控,但 `cabal install` 之後的
執行檔沒有原始碼樹的相對路徑。因此 `storyflow-types` 以 cabal `data-files` 帶著它們,
執行期由 `defaultRegistryDir` 定位;環境變數 `STORYFLOW_REGISTRY` 優先——開發時指向工作目錄,
作者要自訂型別時也不必重編譯。載入失敗一律讓程序失敗,**不退回空註冊表**:空註冊表會讓每個
Entity 都被判成未知型別,把設定錯誤偽裝成資料錯誤。

**垂直切片 2(新增一個業務操作)**:在 `storyflow-service` 加一個函式 → 在 servant API 型別加
一條路由 → 在 CLI 加一個子指令。三處都是薄的,業務邏輯只有一份;MCP adapter 依 API 型別自動
取得新能力。

**垂直切片 3(新增一種衝突偵測規則)**:`storyflow-conflict` 的三層各自可獨立擴充——結構層加
一種關聯推論、檢索層調整候選策略、判斷層換 prompt,彼此不互相牽動。

### 使用的技術

- **語言/建置**:Haskell,GHC 9.14.1 / cabal 3.16.x,多套件 `cabal.project`,**不使用 stack**
  ——與 `assetdb` 完全一致的工具鏈(見 ADR-0001)
- **儲存**:Markdown 檔為真相來源 + SQLite 為可重建索引;`direct-sqlite` 開啟 `+fulltextsearch`
  以取得 FTS5 與中文搜尋所需的 trigram tokenizer(assetdb 已驗證此作法)
- **API**:`servant` + `servant-server` + `warp`,API 型別即契約;`servant-client` 供 CLI 遠端模式;
  `servant-openapi3` 由同一份型別推導出 OpenAPI 3 文件(`story-flow serve --openapi`)
- **業務層**:`mtl` 的 `ReaderT` + `ExceptT` 疊成 `ServiceM`,讓多步驟的業務組合不必手工串 `Either`
- **CLI**:`optparse-applicative`,所有指令支援 `--json`,輸出為統一信封
  `{"ok":true,"data":…}` / `{"ok":false,"error":{"code":…,"message":…}}`——AI Agent 只需 parse 一種形狀
- **LLM**:`http-client` + `aeson` 直接打 OpenAI 相容端點(不引入重量級 SDK)
- **設定**:Vault 內 `.storyflow/config.toml`,全域 `~/.config/story-flow/vaults.toml`
- **測試**:`hspec`,`temporary` 建臨時 Vault 做落地層測試
- **前端**:無(P6 才評估)

### 架構圖

依賴方向(單向向下,核心不知道介面存在):

```text
                   ┌──────────────────────────┐
                   │  types/registry/*.toml   │  宣告式型別註冊表(資料,非程式)
                   └────────────┬─────────────┘
                                │ 讀檔
                   ┌────────────┴─────────────┐
                   │  storyflow-types         │  TOML 解析 + 錯誤彙整(唯一 IO 是讀檔)
                   └────────────┬─────────────┘
                                │ 交給純驗證
   ┌────────────────┐  ┌────────┴─────────────┐
   │ storyflow-md   │  │  storyflow-core      │  Meta/Entity/Link/Level/Node
   │ Markdown ↔ 型別 ├──┤  純型別 + 純函式      │  零 IO,可完全單元測試
   └────────┬───────┘  └────────┬─────────────┘
            └──────────┬─────────┘
              ┌────────┴──────────────────────┐
              │  storyflow-store              │  原子檔案寫入、SQLite 索引
              │  檔案為真相 / DB 可 rm 後重建  │  FTS5 trigram、樂觀鎖
              └────────┬──────────────────────┘
              ┌────────┴──────────────────────┐
              │  storyflow-service            │  ★ 唯一業務契約
              │  Entity/Link/Level/Node/Vault │    所有操作只在這裡定義一次
              └───┬────────┬───────────┬──────┘
      ┌───────────┘        │           └──────────┐
┌─────┴─────────┐  ┌───────┴───────┐  ┌───────────┴────┐
│storyflow-     │  │storyflow-llm  │  │storyflow-      │
│conflict       │  │OpenAI 相容端點│  │workshop        │
│圖→FTS5→LLM 三層│◄─┤地端 / 雲端    ├─►│階段式引導狀態機 │
└─────┬─────────┘  └───────────────┘  └───────────┬────┘
      └────────────────────┬───────────────────────┘
                ┌──────────┴──────────┐
                │  storyflow-api      │  ★ 唯一 API 契約
                │  servant 型別       │    只有型別:無 server、無 client、無 warp
                │  + ToSchema         │    server / cli / OpenAPI 三者由它產生
                └────────┬────────────┘
          ┌──────────────┴──────────────────┐
   ┌──────┴───────────┐            ┌────────┴──────────┐
   │storyflow-server  │            │storyflow-cli      │
   │servant REST      │            │預設內嵌 Service   │
   │綁 loopback       │            │--remote → HTTP ───┼──┐
   └──────┬───────────┘            └───────────────────┘  │
          │◄──────────────────────────────────────────────┘
   ┌──────┴───────────┐
   │storyflow-mcp     │  MCP adapter(薄層,打同一組 HTTP API)
   └──────────────────┘
          ▲
          │ stdio / HTTP
   claude code / codex
```

`storyflow-cli` 同時依賴 `storyflow-service`(內嵌模式)與 `storyflow-api`(遠端模式);
`storyflow-server` 依賴兩者。API 型別獨立成套件的理由是 **CLI 的遠端模式需要它、但不需要
`servant-server` 與 `warp`**——型別若住在 server 裡,一個預設根本不開伺服器的執行檔就得
把整套 HTTP 伺服器拖進來。

資料流 A(AI Agent 討論新劇情,含衝突偵測):

```text
Agent 提出新劇情草稿
  → POST /conflict/check {draft, scope}
  → conflict 第 1 層:圖遍歷。順著 contradicts / supersedes 找草稿已引用片段的已知矛盾與被取代關係
  → conflict 第 2 層:FTS5 trigram 以草稿關鍵詞 + aliases 撈出 top-N 候選片段
      (只取 status = canon 的片段當比對基準;draft 不參與,timeline 用來過濾時序不可能相關的)
  → conflict 第 3 層:逐對送地端/雲端 LLM 判斷「這兩段是否矛盾、矛盾在哪」
  → 回傳 conflict report:每筆含 (候選片段 id, 命中層級, 理由)
  → Agent 修訂草稿 → POST /entities 寫入(status=draft, source=agent:claude-code)
  → 作者確認後 status 改 canon,並補上 contradicts / supersedes 關聯
```

資料流 B(地端 LLM 階段式工作坊,承襲 design-studio):

```text
選型別(如 character)+ 勾選要當硬約束的既有 Entity + 選後端模型 + 起始概念
  → workshop 依型別註冊表的階段清單逐階段對話
  → 每階段定案 → 產出多個片段 Entity(不是一份文件)
  → 寫入 Markdown 檔(一主題一檔、檔內分節)→ store 更新 SQLite 索引
```

資料流 C(索引重建,證明檔案才是真相來源):

```text
rm .storyflow/index.db
  → story-flow index rebuild
  → 掃描 Vault 全部 .md → storyflow-md 解析 → 重建 entities/links/nodes/FTS5
  → 結果與刪除前等價
```

### 資料結構的框架格式

#### 目錄結構

```text
alchbees-dev/story-flow/            ← 程式碼,獨立 git repo
├── cabal.project
├── types/                          ← storyflow-types 套件
│   ├── storyflow-types.cabal
│   ├── src/                        ← 載入器原始碼
│   └── registry/                   ← 宣告式型別註冊表(隨程式碼一起版控)
│       ├── character-fragment.toml
│       ├── lore-fragment.toml
│       ├── item-fragment.toml
│       ├── dialogue.toml
│       └── plot-fragment.toml
├── core/  md/  store/  service/    ← 各套件(每個一份 *.cabal)
├── conflict/  llm/  workshop/
├── api/                            ← servant API 型別(只有型別)
├── server/  cli/  mcp/
├── scripts/                        ← check.ps1 / check.sh(本機建置測試)
└── docs/

~/story-vaults/liftgame/            ← 資料 Vault,自己的 git repo
├── .storyflow/
│   ├── config.toml                 ← Vault 設定(名稱、引用的其他 Vault、LLM 後端)
│   └── index.db                     ← SQLite 索引,gitignored,可 rm 後重建
├── characters/琳達.md
├── lore/埃提亞崩塌.md
├── items/織紋刀.md
├── dialogues/琳達-塔主-第一次對峙.md
└── levels/教室.md

~/.config/story-flow/vaults.toml    ← 全域 Vault 註冊表(名稱 → 路徑)
```

Vault 定位規則:從目前工作目錄**向上搜尋** `.storyflow/`(與 git 同一個心智模型);找不到時
或明確指定 `--vault <名稱>` 時,查全域註冊表。這也讓跨 Vault 引用與遠端指定共用同一套解析。

#### 統一 Meta(Entity / Level / Node 共用同一組欄位)

所有實體共用同一份 `Meta`,只有少數欄位是各自專屬的。統一的用意是抽象與管理成本只付一次:
索引表、API 序列化、CLI 輸出、衝突偵測全部對同一組欄位工作。

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | Text | 全域唯一。`<prefix>-<8 hex>`,prefix 為 `ent`/`lvl`/`nod`/`vlt`。以 FNV-1a 64-bit 對「內容 + 時間 + salt」雜湊後取低 32 位;`core` 零 IO 故時間由呼叫端提供,唯一性由持有索引的 `store` 以 salt 遞增重試保證。人類可讀性交給 `title` |
| `vault` | Text | 所屬 Vault 名稱。跨 Vault 引用時用 `<vault>:<id>` 定址 |
| `type` | Text | 型別註冊表中的鍵。core 只當它是字串,語意由註冊表決定 |
| `title` | Text | 人類可讀標題 |
| `summary` | Text | **一句話總結**。衝突偵測與 AI 撈 context 時優先用它,避免把全文塞進 prompt |
| `tags` | [Text] | 自由標籤,輔助檢索與分組 |
| `status` | Enum | `draft` / `canon` / `deprecated`。**只有 canon 參與衝突偵測的比對基準** |
| `timeline` | Maybe Text + Maybe Int | 故事內時間點。字串可模糊(「崩塌前後」),選配的整數 `order` 供排序與時序過濾 |
| `aliases` | [Text] | 別名。角色化名、地名舊稱——不建立的話 FTS5 撈不到 |
| `links` | [Link] | **有方向性**的關聯,存在來源端。每筆 `{kind, target, note}` |
| `source` | Text | `human` / `agent:claude-code` / `agent:codex` / `workshop:<型別>`。追溯是誰寫的 |
| `revision` | Int | 單調遞增。寫入時比對,不符即拒絕(樂觀鎖,防 AI Agent 與作者同時寫入互相覆蓋) |
| `created` / `updated` | Date | `YYYY-MM-DD` |

專屬欄位:

- **Entity**:`body`(正文 Markdown,不在 frontmatter 內,是節的內文)
- **Level**:`root`(根 Node 的 id)
- **Node**:`level`(所屬 Level)、`parent`(Maybe,根節點為 Nothing)、`order`(同層兄弟排序)、
  `kind`(`scene` / `cast` / `camera` / `interaction` / `dialogue` / `branch`)、
  `entities`([Text],關聯到的 Entity,允許多個但建議一個)

#### 核心關聯詞彙(`LinkKind`)

引擎認得下列關聯並據以推論;其餘可用自訂字串(如「師承於」「宿敵」),引擎當純標註儲存、
可查詢、但**不驅動邏輯**。

| 關聯 | 方向語意 | 引擎行為 |
|---|---|---|
| `contradicts` | A 與 B 矛盾 | 衝突偵測第 1 層的確定性命中 |
| `supersedes` | A 取代 B | B 自動視為過時,不再當比對基準 |
| `derivedFrom` | A 衍生自 B | 改動 B 時提示 A 需複查 |
| `partOf` | A 是 B 的一部分 | 組合關係:片段 → 角色 / 世界觀 |
| `involves` | A 牽涉到 B | 場景/劇情 → 角色、道具 |
| `occursIn` | A 發生在 B | 事件 → 地點 / 時期 |
| `references` | A 提到 B | 弱關聯,擴充檢索範圍 |
| `convergesTo` | Node A 合流到 Node B | Level 樹的分支合流標註(見下) |

#### Markdown 分節格式(檔案為真相來源)

一個主題一份 `.md`,檔內以分節切出片段。檔案層 frontmatter 描述主體,節層以標題屬性帶 id、
緊接一個 ` ```meta ` 區塊帶該片段的 Meta。節層未寫的欄位**繼承檔案層**(`vault`/`type`/
`timeline`/`status` 等),減少手寫負擔。

````markdown
---
id: ent-7f3a
vault: liftgame
type: character
title: 琳達
summary: 埃提亞的第七織手,因塔主徵召失去雙親而敵視議會
status: canon
aliases: [小琳, 第七織手]
source: human
revision: 3
created: 2026-08-16
updated: 2026-08-16
---

# 琳達

角色主體的概述寫在這裡。

## 外貌 {#ent-7f3b}

```meta
type: character-fragment
summary: 銀灰短髮,左眼下方有織紋刺青
tags: [外觀]
links:
  - {kind: partOf, target: ent-7f3a}
```

銀灰短髮剪到耳際……

## 與塔主的過節 {#ent-7f3c}

```meta
type: character-fragment
summary: 十四歲時因塔主徵召失去雙親,自此對議會抱持敵意
tags: [動機, 仇恨]
timeline: 埃提亞崩塌前
links:
  - {kind: partOf, target: ent-7f3a}
  - {kind: occursIn, target: ent-c41d}
  - {kind: contradicts, target: ent-91cc, note: 對雙親死因的敘述不一致}
```

那年她十四歲……
````

`{#id}` 是標準 Markdown 標題屬性語法(pandoc/kramdown 相容),編輯器與一般 Markdown 檢視器
都不會顯示異常;` ```meta ` 是 YAML,不認得它的檢視器會當程式碼區塊原樣顯示,不會壞版。

**分節從哪裡開始**:全檔**第一個帶 `{#id}` 的標題**才開始分節,在它之前的標題(上例的
`# 琳達`)屬於主體的正文。第一個節之後的標題一律要帶 `{#id}`,因此片段正文裡不再使用
Markdown 子標題——一個節就是一個片段。

**`timeline` 的兩種寫法**:只有時間點標籤時直接寫 `timeline: 埃提亞崩塌前`;需要排序用的
整數時寫 `timeline: {label: 埃提亞崩塌前, order: 3}`。兩種都解析成同一個 `Timeline`,
寫回時沒有 `order` 就用簡寫。

**節層繼承檔案層的精確規則**(「等」的定義,見 func-0003):

| 欄位 | 規則 | 理由 |
|---|---|---|
| `id` / `title` | **不繼承**,來自節標題與其 `{#id}` | 每個片段必須有自己的身分 |
| `vault` / `type` / `status` / `timeline` / `source` | 繼承 | 同檔片段幾乎總是同一個 vault/型別/狀態 |
| `created` / `updated` | 繼承 | 作者不會想每節寫一次日期 |
| `tags` | **聯集去重**(檔案層 + 節層) | 檔案層放共通標籤、節層放專屬標籤 |
| `summary` | **不繼承**,缺漏產生警告 | 繼承主體的總結等於餵給衝突偵測假資訊 |
| `aliases` / `links` | **不繼承** | 別名與關聯屬於各自的實體,繼承會讓每個片段莫名帶上主體的全部關聯 |
| `revision` | **不繼承**,未寫時為 `1` | 繼承會讓多個片段共用同一個 revision,樂觀鎖就失去意義 |

**寫回策略**:未經修改的區塊逐字保留原始位元組,只有被修改的 `meta` 區塊重新序列化
(ADR-0010)。作者的空行、YAML 註解、縮排風格不會被工具改掉。

**檔案層 frontmatter 是例外**:它是一整塊 YAML,沒有像節那樣「只有 `meta` 區塊要換」的細界線
可切,因此改它是**整段重新序列化**(`updateFrontmatter :: (Meta -> Meta) -> Document ->
Either MdError Document`),寫在 frontmatter 裡的 YAML 註解會被抹掉。節層的位元組保留不受
影響,而那才是 ADR-0010 真正在保護的東西——片段是被工具高頻改寫的那一種。簽名吃完整的 `Meta`
而不是每欄 `Maybe` 的 `MetaOverride`:frontmatter 一定有 `id` 與 `title`,而改標題正是檔案層
主體最常見的修改(func-0005)。

#### Level 場景樹

Level 是**嚴格樹**:每個 Node 單一父節點、不成環,可無限展開。分支合流不改變樹結構,而是以
`convergesTo` 關聯標註——結構的邊界因此永遠清楚,遍歷與渲染不需處理多路徑與防環。

以「教室」場景為例(實線為樹,虛線為關聯):

```text
lvl-3a01 教室
└─ nod-0001 kind=scene       「午後的教室,窗外是崩塌後的天際線」
   │                          └╌involves╌→ ent-c41d(教室場地描述 Entity)
   ├─ nod-0002 kind=cast      出場人物
   │  │                       ├╌involves╌→ ent-7f3a(琳達)
   │  │                       └╌involves╌→ ent-8b20(塔主)
   │  └─ nod-0004 kind=interaction  人物互動:琳達走向講台
   │     └─ nod-0005 kind=dialogue  A-to-B 對話
   │        │                 └╌references╌→ ent-d902(對話內容 Entity)
   │        ├─ nod-0007 kind=branch  琳達選擇動手
   │        │  └─ nod-0009 ╌╌convergesTo╌╌┐
   │        └─ nod-0008 kind=branch  琳達選擇退讓
   │           └─ nod-0010 ←╌╌╌╌╌╌╌╌╌╌╌╌╌┘(合流:兩條分支都走到這)
   └─ nod-0003 kind=camera    鏡頭:自窗外緩推至講台,焦段 35mm
```

Node 只承載結構與演出(順序、分支、鏡頭如何移動);「這句對話寫什麼」「這個角色是誰」一律
是 Entity。同一段對話 Entity 因此能被多個場景重用,而衝突偵測也只需要面對 Entity 一種東西
(見 ADR-0003)。

**Level 檔的 Markdown 格式:標題階層即樹**(ADR-0009)。作者永遠不必手寫 `parent` 與 `order`
——這兩個最易錯的欄位由標題層級與文件順序推導:

````markdown
---
id: lvl-3a01
vault: liftgame
type: level
title: 教室
summary: 崩塌後的午後教室,琳達與塔主的第一次對峙
status: canon
---

場景整體的說明寫在這裡(對應 Level 的 body,不進 Node)。

## 午後的教室 {#nod-0001}

```meta
kind: scene
summary: 午後的教室,窗外是崩塌後的天際線
links:
  - {kind: involves, target: ent-c41d}
```

### 出場人物 {#nod-0002}

```meta
kind: cast
links:
  - {kind: involves, target: ent-7f3a}
  - {kind: involves, target: ent-8b20}
```

#### 琳達走向講台 {#nod-0004}

```meta
kind: interaction
```

### 鏡頭 {#nod-0003}

```meta
kind: camera
summary: 自窗外緩推至講台,焦段 35mm
```
````

規則:全檔最淺的標題層級是根 Node;層級 +1 即子節點;同一父節點下的第 n 個子節點
`order = n`;`kind` 必填;Node 指向的 Entity 由 `involves` / `references` 關聯推導,
不另設欄位;跳級(`##` 後直接 `####`)是錯誤;`convergesTo` 只是一筆 `links`,不影響結構。
檔案層 frontmatter 的 `type: level` 是 Entity 檔與 Level 檔的判別依據,`level` 因此是
保留型別鍵,不可出現在 `types/registry/`。

限制:Markdown 只有六級標題,根用 `##` 時最深五層。真的不夠時把子樹拆成另一個 Level
以關聯串接(見 ADR-0009 的影響)。

#### SQLite 索引結構(可重建,不是真相來源)

```text
meta_info(key PK, value)                                -- schema_version、vault_root、vault_name
files(path PK, mtime, size)                             -- 外部改動的過時偵測
entities(id PK, vault, type, title, summary, status, timeline, timeline_order,
         source, revision, created, updated, file_path, section_anchor)
entity_aliases(entity_id, alias)
entity_tags(entity_id, tag)                             -- efTag 過濾;與 aliases 對稱
links(src, dst_vault, dst, kind, note, file_path)       -- 有方向,src → dst
levels(id PK, vault, title, summary, root, ...)
nodes(id PK, level_id, parent_id, order_idx, kind, title, summary, ...)
node_entities(node_id, entity_id)
entities_fts(title, summary, body, aliases, tags)        -- FTS5, trigram
fts_map(rowid PK, entity_id)                             -- FTS5 的整數 rowid ↔ 字串 id
```

`entities_fts` **不是 contentless**:contentless 的 FTS5 表既不支援 `snippet()`(檢索要回傳
命中片段),也不支援刪除單列(單檔重新索引要能整批換掉舊記錄)。代價是 body 在索引裡多存
一份副本——索引本來就是可丟棄的,這個代價划算(func-0004 實作備註 1)。

`links` 的 `file_path` 讓單檔重新索引變成一次外鍵級聯:關聯的來源可能是 Entity / Level /
Node 任一種,靠 `src` 反查要三個子查詢。`meta_info` 記著 Vault 根目錄,讓「只拿到一個索引
連線」的查詢函式也能回讀檔案取得 body。

中文檢索的 trigram 以三字元為索引單位,**二字詞(角色名、道具名)`MATCH` 一定不命中**;
`searchEntities` 對兩字元以下的查詢改走 `LIKE` 掃描(func-0004 實作備註 4)。

`file_path` + `section_anchor` 讓索引能回指原始檔案的哪一節,CLI/API 回傳結果時可直接給出
「去改哪個檔案的哪一段」。

`files` 表存 mtime 與 size:作者用編輯器直接改檔案後,查詢前比對即可偵測過時並重讀該檔,
不必手動 `index rebuild`(ADR-0002 要求 P1 就處理)。它同時讓「這個檔案的所有記錄」
以外鍵級聯刪除,單檔重新索引就是整檔替換而非逐筆 diff。

`body` 進 FTS 但**不進 `entities` 表**——正文只有檔案有,索引只需要能搜到它。
schema 變更時不寫遷移程式,`schema_version` 不符即自動全量重建。

### 使用到的套件

| 套件 | 用途 |
|---|---|
| `base` / `text` / `bytestring` / `containers` | 基礎 |
| `aeson` | JSON 序列化(API、CLI `--json`、`meta` 區塊) |
| `sqlite-simple` + `direct-sqlite` (`+fulltextsearch`) | SQLite 與 FTS5 trigram |
| `servant` / `servant-server` / `warp` | REST API,API 型別即契約 |
| `servant-client` / `http-client` | CLI 遠端模式、LLM 端點呼叫 |
| `servant-openapi3` + `openapi3` | 由 API 型別自動推導 OpenAPI 3 文件,讓 Agent 只靠文件就能接 |
| `mtl` | `ServiceM = ReaderT Env (ExceptT ServiceError IO)`,業務層的組合 |
| `optparse-applicative` | CLI 指令解析 |
| `directory` / `filepath` / `temporary` | 檔案落地、mtime/size 過時偵測、測試用臨時 Vault |
| `toml-reader` | 型別註冊表與 Vault 設定的 TOML 解析(純 Haskell、無 C 相依) |
| `HsYAML` + `HsYAML-aeson` | Markdown frontmatter 與 ` ```meta ` 區塊的 YAML 解析(轉成 aeson `Value` 後套用 `core` 的 `FromJSON`,編碼規則全系統一份) |
| `Win32`(僅 Windows,GHC boot package) | 原子寫入的 rename 覆蓋既有檔案 |
| `hspec` | 測試 |

YAML **只用於解析方向**;寫回時的 `meta` 區塊序列化自己寫(固定欄位順序),見 ADR-0010。

前端無相依(P6 才評估)。

### 開發階段

| 階段 | 內容 | 完成標準 |
|---|---|---|
| P0 | 骨架:`cabal.project` 多套件(P1 所需的 `core` / `types` / `md` / `store` 四個,其餘各階段再加)、GHC 9.14.1、`-Wall` 設定、hspec 測試骨架、`scripts/check.ps1` 與 `check.sh` | `cabal build all` / `cabal test all` 綠燈;FTS5 trigram smoke test 通過(證明 `+fulltextsearch` 生效);`scripts/check` exit 0 |
| P1 | `core` + `types` + `md` + `store`:統一 Meta 與五個核心型別、型別註冊表載入與驗證、Markdown 分節雙向解析、原子寫入、SQLite 索引與 FTS5、樂觀鎖 | `index rebuild` 後與重建前等價;round-trip 測試(解析→寫回→再解析)不失真 |
| P2 | `store` 寫入能力補齊(建檔、增節、改寫、刪除、Level 節點——P1 只做出了改既有節的 meta)+ `service` + `cli`:Vault init/註冊、Entity 與 Link 的增刪查改、Level 樹編輯、全指令 `--json`、內嵌模式 | 能純用 CLI 把「教室」場景與琳達的片段從零建起來 |
| P3 | `api` + `server`:servant API 型別獨立成套件、REST 覆蓋 `service` 全部操作、綁 loopback、OpenAPI 輸出;CLI `--remote` | claude code 只靠 API 文件就能建/查片段與關聯 |
| P4 | `conflict`:圖遍歷、FTS5 候選撈取、LLM 判斷三層,以及 `context` 指令(只撈相關片段不判斷) | 拿真實草稿測出既有設定的矛盾,且能說出是哪個片段的哪一段 |
| P5 | `llm` + `workshop` + `mcp`:地端 OpenAI 相容端點、階段式引導工作坊、MCP adapter | 地端模型能引導產出片段;claude code 以 MCP 直接操作 |
| P6 | (選配)Web:Entity 關聯圖與 Level 樹視覺化 | 資料模型穩定後再評估是否值得做 |

每個階段都是端到端可驗證的垂直切片。P2 結束時已能手動用 CLI 寫故事;P3 結束時 AI Agent 就能
接進來;P4 才是真正解決痛點的那一刀。

**與 design-studio 的關係**:並存,不搬資料。design-studio 不再開發新功能,提示詞工房仍可使用;
等 story-flow 走到 P4 且實際用在作品上,再決定 design-studio 是否封存。
