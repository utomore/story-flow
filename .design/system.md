---
id: system
type: system
title: assetdb
description: 工作室素材庫的索引、檢索與專案素材配置系統
status: active
created: 2026-08-16
updated: 2026-08-23
subsystems: [workspace, catalog, ingest, ai-tagging, delivery]
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
- **把任意資料夾納管成 vault,並在一次查詢裡看遍所有 vault**

使用者:單人工作室(目前),schema 已為多人協作預留欄位但不實作即時協作。

### 為什麼需要「全局工具」(2026-08-23 修訂)

初版把整個系統設計成**單一素材庫**的工具:狀態只存在於素材庫內的 `.assetdb/`,
指令從當前目錄逐層往上找它 —— 這是 git 的 `.git` 探測模式。

那個模式在 git 成立,是因為 git 的每個操作都是「對我 cd 進去的那個 repo」。但素材庫的
核心用途是「**在所有素材裡**找一張書本風格的 GUI 框」—— 借來的模式把「局部視角就夠了」
這個假設一起帶了進來,而它在這裡不成立。第二個素材庫一出現,工具就沒有任何辦法同時看到兩邊。

因此本次修訂把狀態分成兩層:**全局中樞**(認得有哪些 vault 與專案)與**嵌入式 vault**
(每個素材庫自帶完整索引)。見 ADR-011、ADR-012。

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

系統有四個對外邊界,全部由 `delivery` 子系統守門;其中 CLI 的**生命週期指令群**
由 `workspace` 提供實作。

### 0. 全局狀態與生命週期(workspace)

工具是**全局的**,不隸屬於任何一個資料夾。它在使用者層級有一個設定目錄
(Windows `%APPDATA%\assetdb\`,其他平台依 XDG),內容:

```text
<全局設定目錄>/
├── config.toml          ← 中樞:全局設定 + vault 與專案的註冊表(人可讀可編輯)
└── cache/thumbs/        ← 全局縮圖快取,內容定址,跨 vault 共用
```

`config.toml` 記的是 **ULID → 目前路徑** 的對映,不是以路徑為鍵:

- **vault 的身分是它自己索引裡的 ULID,路徑只是「它現在在哪」。** 搬動 vault 只要重新指
  路徑,身分不變、索引不失聯。以路徑為身分會讓「東西一搬就變成另一個東西」,那正是本次
  一併修掉的缺陷(見 `ingest` 的 pack 身分)。
- 專案同樣以 ULID 註冊(ADR-003 的「對外識別一律 ULID」在這裡一路貫穿到中樞)。

生命週期指令:

| 指令 | 作用 |
|---|---|
| `setup` | 建立/檢查全局設定目錄與 `config.toml`;冪等,可重複執行 |
| `vault init <目錄>` | 在該目錄建 `.assetdb/`、產生 vault ULID、註冊進中樞 |
| `vault add <目錄>` | 把**既有**的 `.assetdb/` 註冊進中樞(既有素材庫的遷移路徑) |
| `vault list` | 列出已註冊的 vault 與其目前狀態 |
| `vault forget <vault>` | 從註冊表移除;`.assetdb/` **原封不動**,可再 `add` 回來 |
| `vault forget --delete-index` | 連同該 vault 的 `.assetdb/` 一起刪除 |
| `project add / forget / list` | 專案註冊表的對應動作 |
| `purge` | 移除全局設定目錄與全局快取 |
| `purge --all-vaults` | 另外清掉每個已註冊 vault 的 `.assetdb/` |

**撤除的分層依據**:`.assetdb/` 裡的東西**全部是衍生物**(索引與縮圖),重跑 `scan` 就回得來;
素材本體在 `library/`。因此刪索引是可回復的、刪素材是不可回復的 —— 而
`purge --all-vaults` 與 `--delete-index` **在任何情況下都不碰 `library/`**。
不可逆的那一層需要獨立旗標,符合全域錯誤處理策略第 3 條。

### 1. CLI(主要入口)

`assetdb <指令> [選項]`,指令群:`scan`、`tools`、`pack`、`reorganize`、`cluster`、`search`、
`index`、`thumbs`、`new-project`、`project`(`sync`)、`note`、`link`、`doctor`、
`ai`(`ping` / `classify` / `vision` / `suggest`(`list` / `import` / `confirm` / `reject`)/
`apply` / `query` / `status`),以及 §0 的生命週期指令群(`setup`、`vault`、`project`、`purge`)。
子指令的完整文法見 `delivery/design.md` 的指令表。

契約原則:

- **讀跨全部 vault,寫只進一個 vault。** 查詢類(`search`、`doctor`、`tree`、facet 計數)
  預設涵蓋所有已註冊的 vault,結果帶著它來自哪個 vault;會寫入的動作
  (`scan`、`cluster rule` / `apply`、`ai apply`、`note import`)**必須以 `--vault` 指定落點**,
  程式不替使用者猜。理由:邏輯名稱是全域唯一的對外契約、素材帶授權後果,猜錯的代價高(ADR-012)。
  `scan` 不給 `--vault` 時對**每個** vault 各跑一次 —— 每一次仍只寫它自己的索引,
  「寫只進一個 vault」沒有被破壞。
- **資料庫路徑有兩種語意,而且分開表示**。查詢類指令要求索引**必須已存在**,找不到就以
  非 0 結束碼結束並指引先跑 `vault init` 或 `vault add`;**只有 `scan` 是初始化語意**。
  合成一個函式並預設後者,會讓在錯誤工作目錄下的任何查詢靜默建出空庫。
- **`--db` 仍然存在,但只是「繞過中樞、直接指定單一索引」的逃生口**,供腳本與除錯使用;
  日常路徑是中樞註冊表。
- **會改動狀態的動作預設只預覽**——適用清單與理由見「通訊拓撲與原則」的全域錯誤處理策略第 3 條。
- 參數解析失敗回人看得懂的繁體中文訊息而非例外。
- `assetdb --version` 印 `assetdb <版本>`;版本號的唯一來源是 `.cabal` 的 `version` 欄位,
  由使用者指定,程式碼不另存一份。

### 2. HTTP API + 靜態前端

`assetdb-server <db 路徑> [port] [--host 位址] [--init]`,另有 `--emit-types <輸出檔>`、
`--version` 與 `--help`。預設綁 `127.0.0.1:8787`(本服務**沒有身分驗證**,開放區網是使用者明講的決定,
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

**一個 vault = 一個被納管的資料夾。** 下面是 vault 的內部佈局(根目錄無空格,原因見
ADR-005 的實測記錄);同一台機器上可以有任意多個,彼此獨立,由中樞的註冊表串起來。
`library/` 以外的子目錄是這個工作室 vault 的慣例,不是 vault 的必要條件 ——
vault 的唯一必要條件是它有一個 `.assetdb/`。

```text
<vault-root>/
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
└── .assetdb/                              ← 這個目錄的存在 = 它是一個 vault
    └── assetdb.sqlite                     ← 本 vault 的完整索引,含它自己的 vault ULID
```

**索引是嵌入式而且自足的**:vault 帶著 `.assetdb/` 整個搬到另一台機器,`vault add` 一下就能
繼續用,不需要中樞裡的任何東西。中樞只回答「這台電腦上有哪些 vault、它們現在在哪」——
它是索引,不是真相。中樞壞掉的修法是重新 `vault add`,不是重建素材。

**縮圖快取已移到全局**(§0):它是內容定址的,同一份內容在兩個 vault 裡本來就該只算一次。
`.assetdb/` 因此只剩索引一個檔案。

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

**專案獨立於 vault**(2026-08-23 修訂)。專案不再登記在某個 vault 的索引裡,而是由兩樣東西
共同描述:中樞註冊表的一列(專案 ULID → 目前路徑),加上專案目錄內既有的
`assets/manifest.json`。理由是專案本來就會離開素材庫獨立存在(它是一個 git repo),把它的
真相放在某個 vault 的索引裡,等於讓專案的存在依賴一個它不該依賴的東西。

這使 `manifest.json` 成為專案的**自述檔**,而它目前少三樣東西,因此
**schema 版本由 1 升到 2**:專案 ULID、每筆素材的**來源 vault ULID**(多 vault 之後才有的
溯源需求)、樣板名稱。`FromJSON` 對版本不符是直接失敗(catalog 契約),所以既有專案需要
重新產生 manifest —— 遷移路徑寫在 ADR-011。

「這個素材被哪些專案用了」這個反向查詢因此改為**掃過已註冊專案的 manifest**,
而不是查 vault 索引裡的關聯表。

**命名文法**(全系統穩定的對外契約,見 ADR-004):
`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,形狀近似
`^[a-z0-9]+(_[a-z0-9-]+)*$`,最長 64 字元、全域唯一、純 ASCII。`kind` 是封閉列舉;
`domain` 是開放詞彙,不比對任何詞彙表;`variant` / `state` 屬於文法本身,跟著程式碼版本走
而非執行期可改。

上面的正則是**形狀摘要而非權威定義**:實際驗證另外要求至少三段、第一段必須是 `kind` 列舉
的成員、分段內不得有開頭/結尾/連續的連字號,權威實作在 catalog 的命名文法模組。

## 子系統劃分(Subsystems & Bounded Contexts)

五個子系統。`catalog` / `ingest` / `ai-tagging` / `delivery` 依「資料的生命週期位置」切分;
`workspace` 切在另一個維度上 —— 它管的不是素材,是**工具自己**。

> 初版只有四個,而四個都在講「素材怎麼被處理」,沒有人負責「工具怎麼被安裝、設定、移除」。
> 這是為什麼那一整塊功能整個不見了,而 `/arch-audit` 一路綠燈 —— 它檢查的是「規劃的做完沒」,
> 不是「規劃完整嗎」。

### workspace

- **slug**:`workspace`(`workspace` 套件)
- **單一職責**:工具自身的狀態與生命週期 —— 全局設定目錄、`config.toml` 中樞、vault 與
  專案的註冊表(ULID → 路徑)、`setup` / `vault` / `project` / `purge` 的語意、
  以及「這次指令要對哪些 vault 生效」的解析
- **邊界(不做什麼)**:不碰素材、不掃描、不解壓、不查詢索引內容;只回答「有哪些 vault /
  專案、它們在哪、這次要用哪些」。**刻意保持輕量**(只依賴 catalog 與一個 TOML 解析器),
  因為 `server` 也要依賴它 —— 重量級相依進到這裡等於進到伺服器
- **對外契約摘要**:全局設定目錄的解析、`config.toml` 的讀寫、vault/專案的註冊與撤除、
  vault 集合的解析(`--vault` 或全部)、purge 的範圍計算
- **設計文檔**:尚未建立(下一步 `/subsys-design workspace`)

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
- **邊界(不做什麼)**:不放業務規則(規則屬於下游子系統);`server` 套件**只依賴
  catalog 與 workspace**,把重量級相依(影像解碼、zip、LLM)留在 CLI 側,伺服器保持精瘦。
  多一個 workspace 是因為伺服器要讀中樞才知道該服務哪些 vault —— 這條放寬的前提是
  workspace 本身輕量,規則的精神(伺服器不背重量級相依)沒有變
- **對外契約摘要**:即「系統對外介面」那四節 —— CLI 指令群、HTTP 端點與回應 DTO、
  檔案系統佈局、專案產出物
- **設計文檔**:`.design/subsystems/delivery/design.md`

## 通訊拓撲與原則(Communication Topology)

- **子系統之間:同進程直接函式呼叫**(單一 binary 群,無網路躍點)。依賴方向嚴格單向:
  `catalog ← ingest`、`catalog ← ai-tagging`、`catalog ← delivery`、`ingest ← delivery`、
  `ai-tagging ← delivery`、`catalog ← workspace`、`workspace ← delivery`。
  **無循環依賴**,由各 `.cabal` 的 `build-depends` 保證。`workspace` 不依賴 ingest / ai-tagging
  —— 它只認得「有哪些 vault」,不認得 vault 裡面是什麼。
- **組合根位於 `delivery`**:跨子系統的協作在此組裝(例如 AI 套用時把 ingest 的叢集
  反查以函式注入 ai-tagging,讓兩者互不相依)。真正依賴全部套件的是 `cli`;`project`
  另外獨立組合 catalog 與 ingest 的解壓契約。
- **前端 ↔ 後端**:HTTP/JSON,型別契約由後端產生器單向輸出到前端,並以漂移檢查鎖住。
- **中樞是設定,不是通道。** `config.toml` 由 `workspace` 在指令啟動時讀一次,決定這次要
  開哪些索引;它**不是**行程間傳遞資料的媒介,也不在批次進行中被輪詢。中樞不見了不會讓
  任何既有 vault 失效 —— 重新 `vault add` 即可。
- **跨 vault 查詢以 SQLite 的 `ATTACH` 實作**(ADR-012):一個連線掛上多個 vault 的索引再
  UNION。這之所以乾淨,是因為對外識別一律是 ULID(ADR-003),跨 vault 合併不會撞鍵 ——
  「整數主鍵不出模組邊界」那條規則在這裡付現。
- **行程之間:共用 SQLite 檔(WAL)**(見 ADR-009)。`assetdb`(CLI 批次)與
  `assetdb-server`(常駐查詢)是**兩個獨立行程**,彼此不通訊,只透過各 vault 的
  `.assetdb/assetdb.sqlite` 交會。伺服器可能同時掛著多個 vault 的索引,而 CLI 一次只寫其中
  一個 —— 下面的規則**逐一適用於每個索引檔**,不因為掛了多個而改變:
  - **同時只能有一個寫入者**;WAL 模式下讀取者不被寫入者阻塞,反之亦然
  - 取得寫鎖的等待上限是 `busy_timeout=5000`,**超過就是寫入失敗**,不是排隊
  - **服務保證:CLI 的長時間批次進行中,伺服器必須仍然可以查詢,且 CLI 自己的每一筆
    進度都要落盤**(批次因此可以中斷續跑,資料庫就是檢查點)
- **外部 sidecar**:7-Zip 走子程序(`typed-process`),llama.cpp 走 HTTP(OpenAI 相容端點);
  兩者皆為選配,缺少時對應功能優雅降級而非整體失敗。
- **全域錯誤處理策略**:
  1. **失敗必須是使用者看得懂的繁體中文,而不是逃逸的例外。** 這條分兩層,兩層都要做到:
     - **呼叫端能做不同處置的位置,邊界回 `Either`/`Maybe`**——例如「這一筆壞了但其他還能跑」
       (批次報告的失敗清單)、「這個值不合法所以跳過這一包」、「檔案不在所以歸類成另一種狀態」。
       這種地方拋例外等於把決定權從呼叫端拿走。
     - **其餘位置可以拋,但執行檔與 HTTP handler 層必須攔截並翻成繁體中文**。
       `search` / `openStore` / `runMigrations` 這類「呼叫端除了回報也做不了別的事」的入口
       屬於這一層:硬要它們回 `Either` 只會讓每個呼叫點多一次無意義的轉發。
       **沒有頂層攔截就不算滿足這一條**——空白的 500 與 GHC 的英文 `show` 都是違規。
     - 這條涵蓋的不只是自己定義的錯誤:**資料庫錯誤與檔案系統例外同樣不得逸出**,
       它們是最容易被遺漏的一類,因為型別簽名上看不出來(收斂見 `G-E003`)。
  2. 批次作業的失敗分兩層:**單筆失敗**(記錄後續跑)vs **整批中止**(外部服務掛掉或
     環境失效,佇列保留原狀)—— 把服務中斷誤判成逐筆失敗會破壞工作佇列。反過來
     **把失敗誤判成成功更糟**:批次的每一種失敗都必須有出口,不得靜默丟棄。
  3. **會改動狀態的動作預設只預覽**,`--confirm` 才寫入;不可逆操作(刪除)需要獨立旗標。
     適用於:寫入全域唯一命名的動作(`cluster rule`、`cluster apply`)、寫入索引的動作
     (`ai suggest confirm`/`reject`、`ai apply`)、改動既有專案的動作(`project sync`)、
     搬移或刪除檔案的動作(`reorganize`,模式旗標互斥且無預設值,不可回退的階段另需獨立旗標)。
     **不適用**於輸入本身就是版控檔案的動作(`pack apply` 讀 `data/packs.toml`、
     `note import` 讀 Markdown 目錄)、只建立新目錄的動作(`new-project`,目標目錄必須
     不存在或為空),以及**只寫暫存表**的動作(`ai classify` / `vision` / `suggest import`
     —— 暫存表後面還有 `suggest confirm` 與 `ai apply` 兩道閘門,寫進去的東西碰不到索引)。
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
  ┌───────────────────────┐        ┌──────────────────────────┐
  │       catalog         │◀───────│       workspace          │
  │    core  +  store     │        │ 全局設定 · 註冊表 · 生命週期 │
  └───────────────────────┘        └────────────┬─────────────┘
            │                                   │ 讀一次,決定這次開哪些索引
            │                                   ▼
            │              <全局設定目錄>/config.toml   ← 中樞(ULID → 路徑)
            │              <全局設定目錄>/cache/thumbs/ ← 全局縮圖快取(跨 vault 共用)
            ▼
  ┌─────────────────────────────────────────────────────────┐
  │  vault A/            vault B/            vault C/        │
  │   .assetdb/…sqlite    .assetdb/…sqlite    .assetdb/…sqlite│  ← 各自完整、可攜
  │   library/            library/            library/        │  ← 壓縮檔為唯一真相
  └─────────────────────────────────────────────────────────┘
        查詢時由 workspace 決定集合,以 SQLite ATTACH 跨 vault UNION(ADR-012)

外部 sidecar:7-Zip(子程序,ingest)、llama.cpp(HTTP,ai-tagging)

兩個行程(assetdb CLI / assetdb-server)彼此不通訊,只透過各 vault 的 .assetdb/assetdb.sqlite
交會;寫入一次只進一個 vault,查詢可以同時看全部
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
| 15 | 全局工具化:中樞註冊表、vault 生命週期、跨 vault 查詢、專案脫離 vault | workspace + delivery + catalog |

**本表只回答「這個專案分哪些階段、每個階段屬於誰」。** 各階段的完成狀態與對應的 Level 3
文檔 id 記在各子系統 `design.md` 的「開發階段」節,整體進度由 `/arch-audit status` 從
frontmatter 掃出來 —— 新增一份 feature 或 bugfix **不應該**回頭改動本文件。

新功能請走 `/feature-design`(或 `/subsys-build` 委派展開);新增的**階段**才在此表補一列。
新的缺陷走 `/bugfix`、優化走 `/enhance-design`。尚未納入規劃的缺口列在 `README.md`
「尚未實作」。
