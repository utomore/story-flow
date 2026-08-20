---
id: system
type: system
title: assetdb
description: 工作室素材庫的索引、檢索與專案素材配置系統
status: active
created: 2026-08-16
updated: 2026-08-20
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

- **後端**:Haskell(GHC 9.14.1 / cabal 3.16.1.0),`servant-server`、`sqlite-simple`、`aeson`、
  `zip`(ZIP 原生)、`toml-parser`、`JuicyPixels` / `JuicyPixels-extra`、`crypton`(SHA-256)、
  `typed-process`(sidecar 呼叫)、`wai-app-static`、`optparse-applicative`、`hspec` / `QuickCheck`
- **前端**:Node 24.11.1、Vite、React、TypeScript、TanStack Virtual(數千張縮圖的虛擬化渲染)
- **儲存**:SQLite(`journal_mode=WAL`、`foreign_keys=ON`),FTS5 雙索引(trigram + CJK unicode61 bigram)
- **外部 sidecar**:7-Zip(rar/7z 解壓,使用者自行安裝)、llama.cpp(本機 LLM,OpenAI 相容端點)、
  ImageMagick(選配,TIFF/PSD/HEIC 縮圖)
- **架構模式**:垂直切片 + 依賴單向收斂。九個 cabal 套件依「資源生命週期」分層,分組成四個子系統;
  跨套件共用的純函數集中在 `catalog` 的共用工具模組

架構關鍵依賴以外的基礎函式庫不在此羅列,由各 `.cabal` 與 `web/package.json` 宣告。

## 系統對外介面(External I/O Contract)

系統有四個對外邊界,全部由 `delivery` 子系統守門。

### 1. CLI(主要入口)

`assetdb <指令> [選項]`,指令群:`scan`、`pack`、`reorganize`、`cluster`、`search`、`index`、
`thumbs`、`new-project`、`project`(`sync`)、`note`、`link`、`ai`(`ping`/`classify`/`vision`/
`suggest`/`decide`/`apply`/`query`/`status`)、`doctor`。

契約原則:破壞性操作一律**先預覽再 `--confirm`**;找不到資料庫時**拒絕自動建檔**(要 `--init`
明確要求),避免打錯路徑產生一個查詢全回 0 筆的空庫;參數解析失敗回人看得懂的訊息而非例外。

### 2. HTTP API + 靜態前端

`assetdb-server <db 路徑> [port] [--host 位址] [--init]`,預設綁 `127.0.0.1:8787`
(本服務**沒有身分驗證**,開放區網是使用者明講的決定,啟動時會印警告)。

| 端點 | 用途 | 回應 |
|---|---|---|
| `GET /api/search` | 全文 + facet 條件查詢,支援 `limit`/`offset` | `{ total, items[] }` |
| `GET /api/facets` | 各 facet 的計數(不受 limit 影響) | `{ kinds, vendors, authors, packs, categories }` |
| `GET /api/packs` | 素材包清單與授權摘要 | `PackSummary[]` |
| `GET /api/health` | 存活與索引新鮮度 | `{ assets, packs, named, thumbs, indexStale }` |
| `GET /thumb/:sha/:size` | 縮圖(內容定址,`immutable` 快取) | PNG bytes |
| `GET /*` | 靜態前端 | `web/dist` |

`limit` 由伺服器端夾制(預設 60 / 上限 500),防止單一請求把整個素材庫序列化出去。
回應 DTO 的 TypeScript 型別由 `--emit-types` 產生到 `web/src/api/types.ts`,並有漂移檢查
保證磁碟上的型別檔是最新產物。

### 3. 檔案系統契約

工作室根目錄佈局(根目錄無空格,原因見 ADR-005 的實測記錄):

```text
<studio-root>/
├── library/
│   ├── packs/<vendor>/<pack-slug>/        ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml                      ← 中繼資料,人可編輯、git 可追蹤
│   │   ├── <廠商原始檔名>.zip              ← 不可變,唯一真相
│   │   └── LICENSE.txt
│   ├── reference/<topic-slug>/            ← 參考資料,非遊戲素材,預設不進搜尋
│   └── studio/                            ← 自製素材,散檔 + git(唯一不走壓縮檔的例外)
├── projects/
├── knowledge/
├── marketing/
└── .assetdb/
    ├── assetdb.sqlite
    ├── config.toml
    ├── cache/thumbs/<sha256 前兩碼>/       ← 內容定址,跨包自動去重
    └── backups/
```

`pack.toml` 讓每個包自述,資料庫可從磁碟完全重建:

```toml
schema = 1
slug   = "complete-ui-book-styles"
name   = "Complete UI Book Styles Pack"
vendor = "Crusenho"
[archive]
file = "Complete_UI_Book_Styles_Pack_Full.7z"
sha256 = "…"
[license]
name = "itch.io Commercial"
commercial = true            # 建專案時的授權閘門讀這個欄位
[content]
categories = ["gui", "book"]
[[content.rule]]             # 結構規則,由上而下,最先命中者勝
match = "Preview/**"
action = "exclude"
```

### 4. 專案產出契約

`new-project` 產出物:`assets/`(正規化命名的素材副本)、`assets/manifest.json`(schema 版本化)、
`assets/Assets.hs`(型別安全的素材常數,供遊戲專案編譯期引用)、`<name>.cabal`。
遊戲本體只依賴 `catalog` 的領域型別套件來解析 manifest。

**命名文法**(全系統穩定的對外契約,見 ADR-004):
`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,規則 `^[a-z0-9]+(_[a-z0-9-]+)*$`,
最長 64 字元、全域唯一、純 ASCII。`kind` 是封閉列舉;`domain` 是開放詞彙,不比對任何詞彙表;
`variant` / `state` 屬於文法本身,跟著程式碼版本走而非執行期可改。

## 子系統劃分(Subsystems & Bounded Contexts)

四個子系統,依「資料的生命週期位置」而非技術層次切分。

### catalog

- **slug**:`catalog`(`core` + `store` 套件)
- **單一職責**:定義領域語彙並持有索引真相 —— 領域型別與列舉、ULID 永久識別、命名文法、
  Manifest schema、SQLite schema 與版本化 migration、FTS5 雙索引、條件查詢與 facet 計數
- **邊界(不做什麼)**:不碰檔案系統、不解壓、不解碼圖片、不呼叫外部服務;不知道「掃描」
  或「AI」的存在
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
- **邊界(不做什麼)**:**不在查詢路徑呼叫 LLM**(離線批次寫入,查詢是純 SQLite);
  **刻意不依賴 ingest**(見 ADR-007:會把 JuicyPixels 與 zip 一路拖進伺服器),
  叢集反查由呼叫端以函式注入
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
- **`delivery` 是唯一的組合根**:跨子系統的協作在此組裝(例如 AI 套用時把 ingest 的叢集
  反查以函式注入 ai-tagging,讓兩者互不相依)。
- **前端 ↔ 後端**:HTTP/JSON,型別契約由後端產生器單向輸出到前端,並以漂移檢查鎖住。
- **外部 sidecar**:7-Zip 走子程序(`typed-process`),llama.cpp 走 HTTP(OpenAI 相容端點);
  兩者皆為選配,缺少時對應功能優雅降級而非整體失敗。
- **全域錯誤處理策略**:
  1. 邊界一律回 `Either`/`Maybe`,**不讓例外穿越子系統邊界**;訊息以繁體中文寫給使用者看
  2. 批次作業的失敗分兩層:**單筆失敗**(記錄後續跑)vs **整批中止**(外部服務掛掉,
     佇列保留原狀)—— 把服務中斷誤判成逐筆失敗會破壞工作佇列
  3. 破壞性操作預設 dry-run,`--confirm` 才寫入;不可逆操作(刪除)需要獨立旗標
  4. 長時間外部呼叫**絕不跨資料庫交易持有寫鎖**(見 ADR-007)

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
│ 注入 ──────┼───────┘  (兩者互不相依,見 ADR-007)
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

外部 sidecar:7-Zip(子程序,ingest)、llama.cpp(HTTP,ai-tagging)、ImageMagick(選配)
```

日常匯入的資料流(跨子系統):

```text
前端拖入 pack.zip                                    [delivery]
  → 存進 library/packs/<vendor>/<slug>/               [delivery]
  → 讀 central directory,不解壓,一項一列進 assets    [ingest → catalog]
  → 串流計算每筆 SHA-256,寫入 blobs(內容定址去重)    [ingest → catalog]
  → 解碼圖片產生縮圖與 phash(僅進快取,可重建)        [ingest]
  → 檔名叢集推論 → 前端呈現 3-5 個叢集請人確認         [ingest → delivery]
  → 寫回 pack.toml                                    [ingest]
```

建專案:搜尋 → 加入收藏集 → `new-project`,只對選中項目做單筆解壓,正規化命名後寫進 `assets/`。
**永遠不會整包解開壓縮檔。**

## 開發階段

| 階段 | 內容 | 子系統 | 狀態 |
|---|---|---|---|
| 0 | 領域型別、ULID、命名文法、Manifest schema | catalog | ✅ |
| 0b | SQLite schema、migrations、FTS5 + 中日韓 n-gram | catalog | ✅ |
| 1 | 壓縮檔存取:ZIP 原生列表與串流讀取;rar/7z sidecar | ingest | ✅ |
| 2 | 掃描與索引:內容定址、SHA-256、blobs、格式處理器;CLI 入口 | ingest + delivery | ✅ |
| 2b | `pack.toml` 中繼資料目錄 | ingest | ✅ |
| 3 | 結構搬遷:dry-run → 執行 → 對帳 → 刪散檔 → undo | ingest | ✅ 已對真實素材庫執行(2026-08-09) |
| 4 | 檔名叢集推論 | ingest | ✅ |
| 5 | FTS5 + facet 查詢 | catalog | ✅ |
| 6 | 縮圖 pipeline(內容定址快取) | ingest | ✅ |
| 7 | HTTP API + TypeScript 型別產生 | delivery | ✅ |
| 8 | React 前端:虛擬化網格、facet 側欄 | delivery | ✅ |
| 9 | 專案產出:樣板、單筆解壓、manifest、`Assets.hs` | delivery | ✅ |
| 10 | 知識庫/行銷筆記 + `links` 關聯圖 | ingest | ✅ |
| 11 | 音效格式驗證(零核心表改動) | ingest | ✅ 已驗證(2026-08-11) |
| 12 | AI 離線分類與標註(本機 LLM + GBNF) | ai-tagging | ✅ 已對真實素材庫執行 |
| 13 | 缺陷與技術債收斂(6 bugfix + 14 enhancement) | 全部 | ✅ 全數 done/closed(2026-08-19) |
| 14 | 專案增量同步(`project sync`):對帳分四類、只增不刪、預設預覽 | delivery | ✅ 委派展開完成(2026-08-21,`delivery/F006`) |

**目前狀態**:階段 0–14 功能面已完整實作並驗證。階段 14 是第一個走
`/subsys-build` 委派展開的項目,展開紀錄見 `.design/subsystems/delivery/build-log.md`;
閘門開出的兩份 bugfix 見 `delivery/bugfixes/`。尚未納入規劃的缺口(前端匯入 / 叢集確認
UI、`ai vision` 全量執行、ImageMagick sidecar)列在 `README.md`「尚未實作」。
新功能請走 `/feature-design`(或 `/subsys-build` 委派展開),並在此表補上對應階段;
新的缺陷走 `/bugfix`、優化走 `/enhance-design`。
