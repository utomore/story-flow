---
id: system
type: system
title: assetdb
description: 工作室素材庫的索引、檢索與專案素材配置系統
status: active
created: 2026-08-16
updated: 2026-08-21
subsystems: [catalog, ingest, ai-tagging, delivery]
---

# AssetDB(Alchbees Asset & Project Management System)系統主架構

> 本文取代舊版 `docs/architecture.md`(2026-08-19 遷移至 dev-flow 0.7.0 的 `.design/` 三層結構)。
> 更早的 `docs/DESIGN.md`、`docs/AI.md`、`docs/PACKS.md` 與兩份分析報告保留在 `docs/_archive/`;
> 素材包盤點資料見 `docs/_archive/PACKS.md` 與機器可讀的 `data/packs.toml`。AI 功能的操作手冊
> 已於 2026-08-20 併入根目錄 `README.md`「日常操作 7」,`docs/_archive/AI.md` 只是歷史快照。
> 給 AI agent 的入口是根目錄 `CLAUDE.md`。

## 需求說明

Alchbees Studio 的資源管理原本是純手工資料夾:5,721 個檔案 / 3.42 GB,命名繼承自各廠商,
至少五種互不相容的風格並存。沒有資料庫、沒有 script、沒有 manifest。三個具體問題驅動了本專案:

1. **找不到東西。** 例如「書本風格的 GUI 框」只能靠記憶翻資料夾。
2. **建專案很慢。** 手動從素材庫挑選、複製、重新命名的成本過高。
3. **授權風險。** 商用 / 非商用素材的分流只存在於目錄結構,沒有機制阻止非商用素材被用進商業專案。

外加掃描後才發現的問題:**散檔與壓縮檔同時存在**,同一份資料存兩遍,且雲端備份要同步數千個小檔。

核心功能清單:

- 掃描壓縮檔與散檔、建立內容定址索引(SHA-256 去重)
- 全文 + facet 搜尋(含中日韓文字支援)
- 依廠商叢集自動推論命名規則,大量降低人工決策次數
- 建立新遊戲專案時,從素材庫挑選並正規化複製,產生型別安全的 `Assets.hs`
- 授權閘門:非商用素材無法進入商業專案
- 離線 AI 分類與標註(本機 LLM),把中文標籤寫進索引供純 SQLite 查詢

使用者:單人工作室(目前),schema 已為多人協作預留欄位但不實作即時協作。

## 技術棧與環境

- **後端**:Haskell(GHC 9.14.1 / cabal 3.16.1.0),HTTP 層 `servant-server`,
  儲存層 `sqlite-simple`(需 FTS5,見 ADR-006),壓縮檔原生讀取 `zip` 與 sidecar 呼叫
  `typed-process`(兩者構成 ADR-005 的雙路徑)
- **前端**:Node 24.11.1、Vite、React、TypeScript、TanStack Virtual(數千張縮圖的虛擬化渲染)
- **儲存**:SQLite 單檔(`journal_mode=WAL`、`foreign_keys=ON`),全文索引支援中日韓
  (索引與 tokenizer 的選型屬 catalog Level 2)
- **外部 sidecar**:7-Zip(rar/7z 解壓,使用者自行安裝)、llama.cpp(本機 LLM,OpenAI 相容端點)
- **架構模式**:垂直切片 + 依賴單向收斂。九個 cabal 套件依「資源生命週期」分層,分組成四個子系統;
  跨套件共用的純函數集中在 `catalog` 的共用工具模組

**只列影響架構的關鍵依賴**(框架、儲存引擎、通訊協定實作);影像解碼、TOML 解析、命令列
解析、測試框架等基礎函式庫由各 `.cabal` 與 `web/package.json` 宣告,各子系統的
`design.md`「使用的技術」節有詳述。

## 系統對外介面(External I/O Contract)

系統有四個對外邊界,全部由 `delivery` 子系統守門。

### 1. CLI(主要入口)

`assetdb <指令> [選項]`,指令群:`scan`、`tools`、`pack`、`reorganize`、`cluster`、`search`、
`index`、`thumbs`、`new-project`、`project`(`sync`)、`note`、`link`、`doctor`、
`ai`(`ping` / `classify` / `vision` / `suggest`(`list` / `confirm` / `reject`)/ `apply` /
`query` / `status`)。子指令的完整文法見 `delivery/design.md` 的指令表。

契約原則:

- **資料庫路徑有兩種語意,而且分開表示**。查詢類指令要求資料庫**必須已存在**,找不到就以
  非 0 結束碼結束並指引使用 `--db` 或先跑 `scan`;**只有 `scan` 是初始化語意**,允許在
  找不到時開新庫。合成一個函式並預設後者,會讓在錯誤工作目錄下的任何查詢靜默建出空庫。
- **會改動狀態的動作預設只預覽**——適用清單與理由見「通訊拓撲與原則」的全域錯誤處理策略第 3 條。
- 參數解析失敗回人看得懂的繁體中文訊息而非例外。

### 2. HTTP API + 靜態前端

`assetdb-server <db 路徑> [port] [--host 位址] [--init]`,另有 `--emit-types <輸出檔>` 與
`--help`。預設綁 `127.0.0.1:8787`(本服務**沒有身分驗證**,開放區網是使用者明講的決定,
啟動時會印警告)。

**找不到資料庫時拒絕自動建檔**,要 `--init` 明確要求 —— 避免打錯路徑產生一個查詢全回
0 筆的空庫。(`--init` 只存在於伺服器;`assetdb` CLI 的對應機制見 §1 的路徑語意。)

| 端點 | 用途 | 回應 |
|---|---|---|
| `GET /api/search` | 全文 + facet 條件查詢,支援 `limit`/`offset` | `{ total, items[] }` |
| `GET /api/facets` | 各 facet 的計數(不受 limit 影響) | `{ kinds, vendors, authors, packs, categories }` |
| `GET /api/packs` | 素材包清單與授權摘要 | `PackSummary[]` |
| `GET /api/health` | 存活與索引新鮮度 | `{ assets, packs, named, thumbs, indexStale }` |
| `GET /thumb/:sha/:size` | 縮圖(內容定址,`immutable` 快取) | PNG bytes |
| `GET /*` | 靜態前端 | `<studio-root>/web/`(已建置的前端產物) |

`limit` 由伺服器端夾制,防止單一請求把整個素材庫序列化出去(預設值與上限屬實作參數,
見 `delivery/design.md`)。
回應 DTO 的 TypeScript 型別由 `--emit-types` 產生到 `web/src/api/types.ts`,並有漂移檢查
保證磁碟上的型別檔是最新產物。

### 3. 檔案系統契約

工作室根目錄佈局(根目錄無空格,原因見 ADR-005 的實測記錄):

```text
<studio-root>/
├── library/
│   ├── packs/<vendor>/<pack-slug>/        ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml                      ← 中繼資料快照,人可編輯、git 可追蹤
│   │   └── <廠商原始檔名>.zip              ← 不可變,唯一真相
│   ├── reference/<topic-slug>/            ← 參考資料,非遊戲素材,預設不進搜尋
│   └── studio/                            ← 自製素材,散檔 + git(唯一不走壓縮檔的例外)
├── projects/
├── knowledge/
├── marketing/
├── web/                                   ← 已建置的前端產物,由伺服器靜態服務
└── .assetdb/
    ├── assetdb.sqlite
    └── cache/                             ← 內容定址的衍生物,可重建(分片規則屬 catalog Level 2)
```

`pack.toml` 是每個包的**中繼資料快照**:由結構搬遷產生,人可編輯、git 可追蹤,
讓一個素材包目錄離開資料庫也自述得清楚(slug、名稱、廠商、作者、來源、版本、
壓縮檔雜湊與項目數、授權名稱、AI 揭露、狀態)。

> **目前是單向匯出。** 系統會寫出 `pack.toml`,但**沒有讀取端**——重新建立索引走的是
> 掃描壓縮檔加上集中式的 `data/packs.toml` 目錄檔(`pack apply` 讀它)。「從每包的
> `pack.toml` 反向重建資料庫」目前**未實作**,兩邊的格式也還不相容。要讓這個往返閉合
> 需要一個獨立的 feature。
>
> 授權閘門讀的是**資料庫 `licenses` 表的 `commercial` 欄位**,不是 `pack.toml`——
> `pack.toml` 只引用授權名稱,因為同一份授權常涵蓋多個素材包。

`config.toml`、`backups/`、每包的 `LICENSE.txt` 曾出現在早期規劃中,目前**都沒有實作**,
已從本佈局移除,避免契約描述一個不存在的檔案。

### 4. 專案產出契約

`new-project` 產出物:`assets/`(正規化命名的素材副本)、`assets/manifest.json`(schema 版本化)、
`assets/Assets.hs`(型別安全的素材常數,供遊戲專案編譯期引用)、`<name>.cabal`。
遊戲本體只依賴 `catalog` 的領域型別套件來解析 manifest。

**命名文法**(全系統穩定的對外契約,見 ADR-004):
`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,形狀近似
`^[a-z0-9]+(_[a-z0-9-]+)*$`,最長 64 字元、全域唯一、純 ASCII。`kind` 是封閉列舉;
`domain` 是開放詞彙,不比對任何詞彙表;`variant` / `state` 屬於文法本身,跟著程式碼版本走
而非執行期可改。

上面的正則是**形狀摘要而非權威定義**:實際驗證另外要求至少三段、第一段必須是 `kind` 列舉
的成員、分段內不得有開頭/結尾/連續的連字號,權威實作在 catalog 的命名文法模組。

## 子系統劃分(Subsystems & Bounded Contexts)

四個子系統,依「資料的生命週期位置」而非技術層次切分。

### catalog

- **slug**:`catalog`(`core` + `store` 套件)
- **單一職責**:定義領域語彙並持有索引真相 —— 領域型別與列舉、ULID 永久識別、命名文法、
  Manifest schema、SQLite schema 與版本化 migration、FTS5 雙索引、條件查詢與 facet 計數
- **邊界(不做什麼)**:不碰檔案系統、不解壓、不解碼圖片、不呼叫外部服務;**不持有任何
  子系統的行為** —— 集中持有全系統 DDL(含掃描與 AI 用到的資料表)是刻意設計(ADR-006
  的正向 migration 需要單一權威來源),但各子系統的資料表讀寫 SQL 由該子系統自己持有,
  catalog 只交付 `Store` handle 與通用檢索查詢
- **對外契約摘要**:領域型別與 `TextEnum` 文字表示、ULID 產生/解析、`LogicalName` 驗證、
  Manifest 序列化、`Store` handle 與 schema 初始化、`SearchQuery`/`SearchHit`/facet 計數、
  全文索引重建、跨套件共用的路徑與文字工具
- **設計文檔**:`.design/subsystems/catalog/design.md`

### ingest

- **slug**:`ingest`(`archive` + `ingest` + `reorg` 套件)
- **單一職責**:把磁碟上的現實變成索引 —— 壓縮檔列表與串流讀取、目錄走訪與內容定址雜湊、
  格式處理器與中繼資料抽取、`pack.toml` 中繼資料、檔名叢集推論、縮圖產生、Markdown 筆記與
  關聯圖、一次性結構搬遷
- **邊界(不做什麼)**:不定義 schema(用 catalog 的)、不做語意判斷(那是 ai-tagging)、
  不提供使用者介面
- **對外契約摘要**:壓縮檔格式偵測/列表/單筆讀取、掃描入口與 `ScanReport`、叢集鍵與命名規則
  套用、縮圖產生與快取定址、筆記匯入與關聯建立、搬遷計畫的產生與執行
- **設計文檔**:`.design/subsystems/ingest/design.md`

### ai-tagging

- **slug**:`ai-tagging`(`ai` 套件)
- **單一職責**:為索引補上中文語意標籤 —— 本機 LLM 客戶端、GBNF 約束輸出、叢集層分類、
  逐份視覺標註、建議暫存與套用扇出、自然語句查詢規劃
- **邊界(不做什麼)**:**不在查詢路徑呼叫 LLM**(離線批次寫入,查詢是純 SQLite,見 ADR-007);
  **刻意不依賴 ingest** —— 相依上去會把影像解碼與壓縮檔函式庫沿著相依鏈一路帶進任何
  引用 ai-tagging 的地方,叢集反查因此由呼叫端以函式注入
- **對外契約摘要**:LLM 設定與連線檢查、分類/標註批次入口與進度事件、建議的讀寫與確認、
  套用選項(含叢集解析注入點)與 `ApplyReport`、自然語句查詢規劃
- **設計文檔**:`.design/subsystems/ai-tagging/design.md`

### delivery

- **slug**:`delivery`(`server` + `web` + `cli` + `project` 套件)
- **單一職責**:系統對人的所有邊界 —— CLI 組合根與參數解析、HTTP API 與縮圖服務、
  TypeScript 型別契約產生、React 虛擬化前端、專案產出與授權閘門
- **邊界(不做什麼)**:不放業務規則(規則屬於下游子系統);`server` 套件**刻意只依賴
  catalog**,把重量級相依(影像解碼、zip、LLM)留在 CLI 側,伺服器保持精瘦
- **對外契約摘要**:即「系統對外介面」那四節 —— CLI 指令群、HTTP 端點與回應 DTO、
  檔案系統佈局、專案產出物
- **設計文檔**:`.design/subsystems/delivery/design.md`

## 通訊拓撲與原則(Communication Topology)

- **子系統之間:同進程直接函式呼叫**(單一 binary 群,無網路躍點)。依賴方向嚴格單向:
  `catalog ← ingest`、`catalog ← ai-tagging`、`catalog ← delivery`、`ingest ← delivery`、
  `ai-tagging ← delivery`。**無循環依賴**,由各 `.cabal` 的 `build-depends` 保證。
- **組合根位於 `delivery`**:跨子系統的協作在此組裝(例如 AI 套用時把 ingest 的叢集
  反查以函式注入 ai-tagging,讓兩者互不相依)。真正依賴全部套件的是 `cli`;`project`
  另外獨立組合 catalog 與 ingest 的解壓契約。
- **前端 ↔ 後端**:HTTP/JSON,型別契約由後端產生器單向輸出到前端,並以漂移檢查鎖住。
- **行程之間:共用同一個 SQLite 檔(WAL)**(見 ADR-009)。`assetdb`(CLI 批次)與
  `assetdb-server`(常駐查詢)是**兩個獨立行程**,彼此不通訊,只透過
  `.assetdb/assetdb.sqlite` 交會。這條通道的規則:
  - **同時只能有一個寫入者**;WAL 模式下讀取者不被寫入者阻塞,反之亦然
  - 取得寫鎖的等待上限是 `busy_timeout=5000`,**超過就是寫入失敗**,不是排隊
  - **服務保證:CLI 的長時間批次進行中,伺服器必須仍然可以查詢,且 CLI 自己的每一筆
    進度都要落盤**(批次因此可以中斷續跑,資料庫就是檢查點)
- **外部 sidecar**:7-Zip 走子程序(`typed-process`),llama.cpp 走 HTTP(OpenAI 相容端點);
  兩者皆為選配,缺少時對應功能優雅降級而非整體失敗。
- **全域錯誤處理策略**:
  1. 邊界一律回 `Either`/`Maybe`,**不讓例外穿越子系統邊界**;訊息以繁體中文寫給使用者看。
     這條涵蓋的不只是自己定義的錯誤——**資料庫錯誤與檔案系統例外同樣不得穿越邊界**,
     它們是最容易被遺漏的一類,因為型別簽名上看不出來。
  2. 批次作業的失敗分兩層:**單筆失敗**(記錄後續跑)vs **整批中止**(外部服務掛掉或
     環境失效,佇列保留原狀)—— 把服務中斷誤判成逐筆失敗會破壞工作佇列。反過來
     **把失敗誤判成成功更糟**:批次的每一種失敗都必須有出口,不得靜默丟棄。
  3. **會改動狀態的動作預設只預覽**,`--confirm` 才寫入;不可逆操作(刪除)需要獨立旗標。
     適用於:寫入全域唯一命名的動作(`cluster rule`、`cluster apply`)、寫入索引的動作
     (`ai suggest confirm`/`reject`、`ai apply`)、改動既有專案的動作(`project sync`)、
     搬移或刪除檔案的動作(`reorganize`,模式旗標互斥且無預設值,不可回退的階段另需獨立旗標)。
     **不適用**於輸入本身就是版控檔案的動作(`pack apply` 讀 `data/packs.toml`、
     `note import` 讀 Markdown 目錄)與只建立新目錄的動作(`new-project`,目標目錄必須
     不存在或為空)。
  4. **寫交易的持有時間必須以毫秒計。** 任何檔案讀寫、影像解碼、雜湊計算、子程序呼叫與
     網路請求**一律在交易之外完成**,交易內只剩已經算好的值的寫入。這條規則是可稽核的:
     看一眼交易區塊內有沒有 IO 或重運算就知道違不違規,不必判斷「算不算長時間」。
     它存在的理由是上面那條共用 SQLite 通道的服務保證——持有寫鎖超過 `busy_timeout`
     就會讓同時運行的伺服器寫入失敗。ADR-007 的「LLM 呼叫嚴格在交易之外」是本條在
     ai-tagging 的個案,不是本條的全部範圍。完整脈絡見 ADR-009。

## 架構圖

```text
                    外部使用者 / 遊戲專案
                             │
   ┌─────────────────────────┼──────────────────────────┐
   │  delivery               │                          │
   │   ┌──────┐  ┌────────┐  │  ┌─────┐   ┌──────────┐  │
   │   │ cli  │  │ server │◀─HTTP─│ web │   │ project  │  │
   │   └──┬───┘  └───┬────┘     └─────┘   └────┬─────┘  │
   └──────┼──────────┼──────────────────────────┼────────┘
          │          │                          │
          │          │  (server 只依賴 catalog)  │
   ┌──────┼──────────┼──────────────┬───────────┘
   │      │          │              │
   ▼      ▼          │              ▼
┌────────────┐  ┌────┼─────┐   ┌──────────┐
│ ai-tagging │  │  ingest  │   │(project 用 ingest 的解壓契約)
│  (ai)      │  │ archive  │   └──────────┘
│            │  │ ingest   │
│ 叢集反查由  │  │ reorg    │
│ delivery   │  └────┬─────┘
│ 注入 ──────┼───────┘  (兩者互不相依,叢集反查以函式注入)
└─────┬──────┘        │
      │               │
      ▼               ▼
  ┌───────────────────────┐
  │       catalog         │  領域型別、ULID、命名文法、Manifest、
  │    core  +  store     │  SQLite schema/migration、FTS5、查詢
  └───────────────────────┘
            │
            ▼
    .assetdb/assetdb.sqlite  +  library/(壓縮檔為唯一真相)

外部 sidecar:7-Zip(子程序,ingest)、llama.cpp(HTTP,ai-tagging)

兩個行程(assetdb CLI / assetdb-server)彼此不通訊,只透過 .assetdb/assetdb.sqlite 交會
```

交付的執行檔是 `assetdb`(CLI)與 `assetdb-server`(HTTP 服務)。`archive` 套件另有一個
診斷用執行檔,供開發時單獨檢查壓縮檔存取,**不屬於對外契約**。

日常匯入的資料流(跨子系統):

```text
前端拖入 pack.zip                                    [delivery]
  → 存進 library/packs/<vendor>/<slug>/               [delivery]
  → 讀 central directory,不解壓,一項一列進索引        [ingest → catalog]
  → 串流計算每筆 SHA-256,登記內容(內容定址去重)      [ingest → catalog]
  → 解碼圖片產生縮圖(僅進快取,可重建)                [ingest]
  → 檔名叢集推論 → 前端呈現 3-5 個叢集請人確認         [ingest → delivery]
  → 寫回 pack.toml                                    [ingest]
```

建專案:搜尋 → 加入收藏集 → `new-project`,只對選中項目做單筆解壓,正規化命名後寫進 `assets/`。
**永遠不會整包解開壓縮檔。**

## 開發階段

| 階段 | 內容 | 子系統 |
|---|---|---|
| 0 | 領域型別、ULID、命名文法、Manifest schema | catalog |
| 0b | SQLite schema、migrations、全文索引與中日韓 n-gram | catalog |
| 1 | 壓縮檔存取:ZIP 原生列表與串流讀取;rar/7z sidecar | ingest |
| 2 | 掃描與索引:內容定址、SHA-256、格式處理器;CLI 入口 | ingest + delivery |
| 2b | `pack.toml` 中繼資料快照 | ingest |
| 3 | 結構搬遷:dry-run → 執行 → 對帳 → 刪散檔 → undo | ingest |
| 4 | 檔名叢集推論 | ingest |
| 5 | 全文 + facet 查詢 | catalog |
| 6 | 縮圖 pipeline(內容定址快取) | ingest |
| 7 | HTTP API + TypeScript 型別產生 | delivery |
| 8 | React 前端:虛擬化網格、facet 側欄 | delivery |
| 9 | 專案產出:樣板、單筆解壓、manifest、`Assets.hs` | delivery |
| 10 | 知識庫/行銷筆記 + 關聯圖 | ingest |
| 11 | 音效格式驗證(零核心表改動) | ingest |
| 12 | AI 離線分類與標註(本機 LLM + GBNF) | ai-tagging |
| 13 | 缺陷與技術債收斂 | 全部 |
| 14 | 專案增量同步(`project sync`):對帳分四類、只增不刪、預設預覽 | delivery |

**本表只回答「這個專案分哪些階段、每個階段屬於誰」。** 各階段的完成狀態與對應的 Level 3
文檔 id 記在各子系統 `design.md` 的「開發階段」節,整體進度由 `/arch-audit status` 從
frontmatter 掃出來 —— 新增一份 feature 或 bugfix **不應該**回頭改動本文件。

新功能請走 `/feature-design`(或 `/subsys-build` 委派展開);新增的**階段**才在此表補一列。
新的缺陷走 `/bugfix`、優化走 `/enhance-design`。尚未納入規劃的缺口列在 `README.md`
「尚未實作」。
