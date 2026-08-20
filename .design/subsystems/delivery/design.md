---
id: delivery
type: subsystem
title: delivery
description: 系統對人的四個入口:CLI、HTTP API、Web 前端與專案產出
status: active
created: 2026-08-19
updated: 2026-08-20
parent: system
related-adr: [ADR-001]
---

# Delivery 子系統架構

## 定位與範圍

delivery 是 AssetDB **對人的邊界**。catalog / ingest / ai-tagging 三個子系統只對彼此
與資料庫說話,而 delivery 是唯一會被人類直接觸碰的一層:終端機打的指令、瀏覽器打的
HTTP 請求、瀏覽器上看得見的網格、以及最後落在遊戲專案目錄裡的檔案。

因此這個子系統的公開契約不是「給其他模組呼叫的函式」,而是**四組人看得見的介面**:

| 入口 | 套件 | 介面形式 | 使用者 |
|---|---|---|---|
| 命令列 | `cli` | 子指令 + 旗標 + 結束碼 + 終端機輸出 | 工作室成員、腳本、AI agent |
| HTTP 服務 | `server` | Servant 端點 + JSON DTO + PNG | 瀏覽器前端(未來也可能是其他客戶端) |
| Web 前端 | `web` | 畫面互動 | 挑素材的人 |
| 專案產出 | `project` | 產生出來的目錄樹、`manifest.json`、`Assets.hs` | 遊戲專案與其開發者 |

**在範圍內**

- 指令與參數的文法、預設值與互斥規則;資料庫路徑的解析策略
- HTTP 路由、查詢參數、回應 DTO、狀態碼與快取標頭
- 後端 → 前端的 TypeScript 型別契約與它的防漂移機制
- 前端的查詢狀態、分頁載入策略、facet 呈現與放大檢視
- 專案樣板、素材單筆解壓、manifest 與 `Assets.hs` 產生、授權閘門的執行
- 既有專案的增量同步:與登記紀錄和磁碟對帳、只增不刪、重新產生 manifest 與 `Assets.hs`

**明確不做**

- **不做掃描、雜湊、縮圖產生、格式解碼、叢集推論**:那些是 ingest 的職責,delivery 只
  呼叫它們並把進度印出來。**「不做」指的是不自行實作**——`project` 的同步對帳呼叫
  ingest 的 `sha256File` 是允許的,自己寫一份摘要演算法則不允許。
- **不做 LLM 推論**:`assetdb ai …` 只是 ai-tagging 的命令列外殼。
- **不定義領域型別、資料庫 schema 或查詢語意**:全部來自 catalog。HTTP 的查詢參數是
  `AssetDB.Store.Search.SearchQuery` 的一層薄映射,不是第二套查詢語言。
- **`server` 刻意只依賴 `core` + `store`**。它不依賴 `archive`、`ingest`、`ai`、`project`
  —— 這讓伺服器不會把 JuicyPixels、zip、7-Zip sidecar 與 LLM 客戶端拖進一個長時間常駐、
  對外開埠的行程。縮圖是**讀快取檔案**而不是即時產生,正是這個限制的直接後果;
  真正依賴全部套件的組合根是 `cli`。
- **不做身分驗證、多使用者、權限模型**:單機工具,預設只綁 `127.0.0.1`。
- **不做寫入型 HTTP 端點**:所有會改動資料庫的動作都只有 CLI 入口。
- **不做多模板專案產出**:目前是單模板系統(`haskell-raylib-2d`)。

## 對外契約(Public Interface & DTOs)

### 1. HTTP 端點

共用查詢參數(`/api/search` 與 `/api/facets` 完全相同):

| 參數 | 型別 | 語意 |
|---|---|---|
| `q` | 選填字串 | 全文查詢。中英文皆可,由 catalog 決定走 trigram 或 CJK bigram |
| `kind` | 可重複 | 資源類型 |
| `pack` | 可重複 | 素材包 slug |
| `vendor` | 可重複 | 廠商 |
| `author` | 可重複 | 作者 |
| `category` | 可重複 | 分類路徑,如 `icon` 或 `icon/potion` |
| `named` | 旗標 | 只要已指定邏輯名稱的 |
| `reference` | 旗標 | 納入參考資料(預設排除) |
| `excluded` | 旗標 | 納入被判定為非素材的項目 |

旗標是 servant 的 `QueryFlag`:認的是**參數存在與否**,不是值。

| 端點 | 額外參數 | 回應 | 說明 |
|---|---|---|---|
| `GET /api/search` | `limit`、`offset` | `SearchResponse` | `limit` 省略時取 `defaultSearchLimit = 60`,超過 `maxSearchLimit = 500` 夾制到 500;負的 `offset` 夾制到 0 |
| `GET /api/facets` | — | `Facets`(JSON 物件) | 刻意**不吃** `limit` / `offset`:facet 計數描述的是整個結果集 |
| `GET /api/packs` | — | `PackSummary[]` | 素材包與其授權狀態,依名稱排序 |
| `GET /api/health` | — | `Health` | 筆數概況與索引是否過期 |
| `GET /thumb/:sha/:size` | — | `image/png` | 內容定址縮圖 |
| `GET /*`(Raw) | — | 靜態檔案 | 前端。放在路由最後,`index.html` 為索引檔 |

回應 DTO(欄位名即前端契約,全部手寫 `ToJSON`,不靠 Generic 的前綴剝除規則):

- `SearchResponse` = `{ total: number, items: SearchItem[] }`。`total` 不是可有可無的
  ——虛擬化網格要先知道總筆數才畫得出正確高度的捲動條。
- `SearchItem` = `{ ulid, name, original, kind, pack, author, path, sha }`,其中
  `name` / `pack` / `author` / `sha` 可為 `null`。`ulid` 是對外唯一識別(ADR-003),
  資料庫的整數主鍵不外洩。
- `Facets` = `{ kinds, vendors, authors, packs, categories }`,每項為
  `FacetValue[]`,`FacetValue` = `{ value: string, count: number }`。
- `PackSummary` = `{ slug, name, vendor, author, license, status, ai, count }`。
- `Health` = `{ assets, packs, named, thumbs, indexStale }`。

縮圖端點的三條規則:

1. **`sha` 形狀驗證**:必須是剛好 64 位十六進位字元,否則回 `400`。`sha` 直接參與檔案
   路徑組合,而 servant 的 `Capture` 會把 `%2F` 解碼回 `/`。
2. **路徑規則不自己寫**:走 catalog 的 `AssetDB.PathText.thumbPath`,與 ingest 的產生端
   共用同一份規則。`size >= 512` 取 512px,否則 128px。
3. **快取標頭**:成功回應必帶 `Cache-Control: public, max-age=31536000, immutable`。
   內容定址(ADR-002)保證同一個 URL 的位元組永不改變。檔案不存在回 `404` 而非 `400`。

錯誤回應本體一律以 UTF-8 位元組編碼(訊息是中文)。

### 2. 伺服器執行檔命令列

```text
assetdb-server <db 路徑> [port] [--host 位址] [--init]
assetdb-server --emit-types <輸出檔>
assetdb-server --help | -h
```

- `port` 預設 `defaultPort = 8787`,與 `web/vite.config.ts` 的 dev proxy 互相指涉
  (兩邊沒有共用設定來源,改一邊要同步另一邊)。非數字或超出 `1..65535` 是錯誤。
- `--host` 預設 `defaultHost = "127.0.0.1"`。開放非回送介面時啟動訊息會印警告
  ——本服務沒有任何身分驗證。`--host` 的值長得像旗標或為空字串時**拒絕**,不照收。
- `--init` 才允許對不存在的路徑建立新資料庫。不加時找不到檔案就是錯誤:打錯路徑建出來的
  空庫,查詢會誠實回 0 筆,前端顯示成「素材庫是空的」。
- `--help` 的比對優先於「第一個參數是 db 路徑」,否則想看用法的人會得到一個掛住的終端機。
- 快取與前端根目錄由 db 路徑推導:縮圖取 `<db 的上層目錄>/cache/thumbs`,靜態前端取
  `<db 的上上層目錄>/web`。

### 3. `assetdb` 命令列

全域選項 `--db PATH`(預設 `./.assetdb/assetdb.sqlite`,並會逐層往上尋找)。

| 指令 | 用途 | 子系統 |
|---|---|---|
| `scan` | 掃描素材庫、內容定址、建索引 | ingest |
| `tools` | 檢查 7-Zip sidecar 是否可用 | ingest |
| `doctor` | 資料庫狀態與待辦 | catalog |
| `pack list` / `pack apply` | 素材包授權與作者中繼資料 | ingest |
| `reorganize` | 一次性結構搬遷(`--dry-run` / `--apply` / `--undo` / `--list-batches`) | ingest |
| `cluster list` / `rule` / `apply` | 檔名叢集與命名規則 | ingest |
| `search` | 全文 + facet 搜尋 | catalog |
| `index` | 重建全文索引 | catalog |
| `thumbs` | 產生縮圖 | ingest |
| `new-project` | 建立遊戲專案並放入選定素材 | delivery(`project`) |
| `project sync` | 把符合條件的素材增量加入已登記的專案(預設預覽,`--confirm` 才寫入) | delivery(`project`) |
| `note import` / `note list` / `link` | 知識建檔與關聯圖譜 | ingest |
| `ai ping` / `classify` / `vision` / `suggest list` / `suggest confirm` / `suggest reject` / `apply` / `query` / `status` | 本機 LLM | ai-tagging |

三條跨指令的契約:

- **資料庫路徑有兩種語意,而且分開表示**。查詢類指令要求資料庫**必須已存在**,找不到就以
  非 0 結束碼結束並印出「用 `--db` 指定」與「先跑 `scan`」的指引;只有 `scan` 是初始化語意,
  允許在找不到時開新庫。合成一個函式並預設後者,會讓在錯誤工作目錄下的任何查詢都靜默建出空庫。
- **會改動狀態的動作預設只預覽**。`cluster rule`、`ai suggest confirm/reject`、`ai apply`、
  `project sync` 都要 `--confirm` 才真的寫入;`reorganize` 的模式旗標互斥且**沒有預設值**,
  而可回退的階段 A 與不可回退的階段 B 需要兩個旗標。
- **授權閘門預設是開的**。`new-project` 與 `project sync` 要 `--allow-non-commercial` 才會關掉。

### 4. 前端與後端的型別契約

`web/src/api/types.ts` 是**產生物**,不是手寫檔:

```text
cabal run assetdb-server -- --emit-types web/src/api/types.ts
```

它同時受兩道測試保護,兩道都跑在 `cabal test all` 裡:

- 產生器宣告的欄位與 `Api.hs` 的 `ToJSON` 實際輸出的欄位必須一致(逐型別比對鍵集合)。
- 磁碟上 checked-in 的 `types.ts` 必須等於產生器當下的輸出(比對時忽略 CR,行尾政策不算漂移)。

這是「產生器 + 一致性測試」取代 `servant-openapi3 → openapi-typescript` 的關鍵:少了整套
OpenAPI 工具鏈,但沒有少掉它要解決的問題。

### 5. 專案產出物

`assetdb new-project --name <NAME> --path <PATH> [--pack SLUG]… [--match Q] [--allow-non-commercial]`
產生的目錄樹契約:

- 目標目錄必須不存在或為空,否則不動任何檔案並回報。
- `assets/<kind 預設目錄>/<邏輯名稱><副檔名>`:**單筆解壓**,永遠不整包解開壓縮檔。
- `assets/manifest.json`:catalog 的 `Manifest` schema(schema 版本、專案名、時間戳、
  素材清單、素材包與授權中繼資料)。
- `assets/Assets.hs`:每個素材一個 `AssetKey` 常數。查表打錯從執行期黑畫面變成編譯錯誤(ADR-004)。
- `<NAME>.cabal` 與樣板檔案(`SKILL.md`、`README.md`、提案書、技術文檔、ADR-0001、
  `.gitattributes`、`.gitignore`、`assets/theme/theme.json`)。
- **授權閘門**:不可商用、以及**授權未查證(NULL)**的素材包一律擋下並逐包告知。
- 專案與其使用的素材登記進資料庫,`copied_sha256` 記錄複製當下的內容雜湊,讓「專案裡的素材
  被改過」與「來源壓縮檔更新了」可以分辨。
- 一筆素材都沒複製時以非 0 結束碼結束——空專案是失敗,不是成功。

### 6. 專案增量同步

`assetdb project sync --name <NAME> [--pack SLUG]… [--match Q] [--allow-non-commercial] [--confirm]`
對**已登記的專案**增量加入素材,契約:

- 專案以 `projects` 表登記的 `name` 定位,目錄取登記的 `path`;未登記、或目錄已不存在時
  不動任何檔案,以非 0 結束碼結束並分別說明原因。
- 選素材的條件語意與 `new-project` **完全相同**(已命名、active、有內容雜湊;`--pack` 先取包、
  `--match` 再篩名稱);授權閘門同樣預設開啟、擋法相同。
- **對帳先於寫入**。每筆候選素材歸入四類之一:

  | 類別 | 判定 | 動作 |
  |---|---|---|
  | 新增 | 未登記在 `project_assets` | `--confirm` 下複製並登記 |
  | 已存在 | 已登記,磁碟檔案雜湊 = `copied_sha256` = 來源 `sha256` | 跳過 |
  | 來源已更新 | 已登記,磁碟檔案雜湊 = `copied_sha256`,但來源 `sha256` 不同 | 只回報,不覆蓋 |
  | 本地已修改 | 已登記,磁碟檔案雜湊 ≠ `copied_sha256`(含檔案已不在) | 只回報,不覆蓋 |

  「磁碟檔案雜湊」是 SHA-256,取自 ingest 的內容雜湊介面 —— delivery 不自行實作雜湊,
  也不得改用其他摘要;內容識別在全系統只有一種定義(ADR-002)。

- **預設只預覽**:列出四類的筆數與清單,不寫磁碟、不寫資料庫;`--confirm` 才執行「新增」類。
- **只增不刪、不覆蓋**:專案裡既有的檔案、手寫程式碼與 `project_assets` 既有列一律不動。
  「更新到來源新版本」與「還原本地修改」是另外的指令,不在本契約內。
- `--confirm` 時以**登記的全集**(既有 + 新增)重新產生 `assets/manifest.json` 與
  `assets/Assets.hs`;其餘樣板檔案(`SKILL.md`、`README.md`、`<NAME>.cabal`、`docs/`)不重寫;
  `projects.updated_at` 更新。
- **授權閘門只擋新增,不回溯既有**。既有登記素材的素材包後來授權降級或被改回未查證時,
  它仍留在磁碟上、仍列入重新產生的 `manifest.json` 與 `Assets.hs`(否則 manifest 與磁碟
  不一致,而遊戲端已經引用的 `AssetKey` 常數會靜默消失),但**必須在回報中逐包列出並警告
  發行前要處理**(`spWarnedPacks`)。一個無關的新增不因舊的授權問題被卡死;授權問題也不
  因此被靜靜吞掉。
  **警告的涵蓋範圍是登記的全集,不是本次候選**——重寫的 manifest 涵蓋全集,警告就必須
  跟著全集;只查本次 `--pack` / `--match` 命中的那些,等於讓不在篩選條件內的授權問題
  靜靜通過。
- **兩個產物必須用同一個集合**。`manifest.json` 與 `Assets.hs` 從同一份登記全集產生,
  任何一筆被排除(邏輯名稱缺漏、ULID 或名稱驗證失敗)就**兩邊一起排除**,而且要經
  `soOnEvent` 出聲。兩邊集合不同會產生「`Assets.hs` 有這個 `AssetKey` 常數,但 manifest
  查不到」的組合——編譯得過、執行期查表落空,正是這套型別安全設計要消滅的失敗模式。
- **0 筆新增不是失敗**(與 `new-project` 相反):「沒有東西要加」是正常結果,結束碼 0。
  只有專案定位失敗、或 `--confirm` 下所有新增項都讀取失敗時才以非 0 結束。

## 內部模組劃分(Internal Modules)

| 套件 | 模組 | 職責 | 不做 |
|---|---|---|---|
| `server` | `AssetDB.Server.Api` | 路由型別、DTO 與手寫 `ToJSON`、PNG 內容型別 | 不碰資料庫、不做 IO |
| `server` | `AssetDB.Server.App` | handler 實作、`ServerConfig`、分頁夾制常數、啟動流程、db 路徑檢查、靜態服務 | 不解析命令列 |
| `server` | `AssetDB.Server.Cli` | 執行檔的參數解析與用法文字 | 不啟動 Warp |
| `server` | `AssetDB.Server.TsTypes` | TypeScript 型別宣告表與渲染 | 不寫檔(由執行檔負責) |
| `cli` | `AssetDB.Cli.Options` | 完整指令文法(`optparse-applicative`)、`Command` 代數型別、資料庫路徑解析 | 不執行任何指令 |
| `cli` | `AssetDB.Cli.{Scan,Doctor,Pack,Reorg,Cluster,Search,Thumbs,Project,Notes,Ai}` | 每個指令族一個模組:把 args 翻成下游子系統的 options、印進度、決定結束碼 | 不實作領域邏輯 |
| `cli` | `main/Main.hs` | 唯一的 dispatch 點:主控台編碼設定 + 路徑語意選擇 + `Command` → runner | 不含任何可測邏輯 |
| `project` | `AssetDB.Project.Template` | 樣板是**資料**(路徑 → 內容):目錄清單、初始檔案、致謝區塊 | 不碰檔案系統 |
| `project` | `AssetDB.Project.Assets` | 邏輯名稱 → Haskell 識別字、`Assets.hs` 渲染 | 不碰檔案系統 |
| `project` | `AssetDB.Project.Create` | 編排:選素材 → 授權閘門 → 寫樣板 → 單筆解壓 → 寫 manifest/`Assets.hs`/cabal → 登記專案 | 不定義 Manifest schema |
| `project` | `AssetDB.Project.Sync` | 編排:定位已登記專案 → 選素材(同 Create 的條件)→ 與 `project_assets` 及磁碟對帳分四類 → 授權閘門 → (確認後)單筆解壓新增項 → 登記 → 以全集重寫 manifest/`Assets.hs` | 不重寫樣板、不刪除、不覆蓋既有檔案 |
| `project` | `AssetDB.Project.Internal` | `Create` 與 `Sync` 共用的取材 SQL、落點算法、單筆解壓、manifest 組件與 UTF-8 寫檔(`other-modules`,套件外不可見) | 不編排、不定義契約 |
| `web` | `src/api/types.ts` | 後端 DTO 的 TypeScript 映射(**產生物,禁止手改**) | — |
| `web` | `src/api/client.ts` | `Query` 型別、query string 組裝、四個端點的取用函式、縮圖 URL | 不持有畫面狀態 |
| `web` | `src/App.tsx` | 查詢狀態的唯一擁有者、輸入去抖、facet 與 health 取用、版面組合 | 不做分頁 |
| `web` | `src/components/Facets.tsx` | facet 側欄:已選條件、分組收合、分類階層重排、廠商/作者依資料合併 | 不發搜尋請求 |
| `web` | `src/components/Grid.tsx` | 虛擬化網格:欄數量測、依需求分頁載入、選取與放大檢視索引 | 不決定查詢條件 |
| `web` | `src/components/Lightbox.tsx` | 放大檢視:portal、鍵盤操作、前後筆 | 不抓資料 |
| `web` | `src/components/Detail.tsx` | 選中素材的欄位細節與 512px 預覽 | 不抓資料 |

## 資料流管線(Data Flow Pipeline)

### P1 前端查詢管線

```text
使用者輸入 / 點 facet
  → App 持有唯一的 Query 狀態(文字輸入去抖 200ms)
  → client.ts 把 Query 序列化成 query string(可重複參數 append、旗標只放鍵)
  → GET /api/facets(整個結果集的計數)  ‖  GET /api/search?limit&offset(一頁)
  → Server.App 把查詢參數映射成 catalog 的 SearchQuery,套用分頁夾制
  → catalog 執行 FTS5 + facet 查詢,回 SearchHit / FacetCounts
  → Server.Api 的 DTO 序列化成 JSON
  → Grid 以 total 配置稀疏陣列並算出總列數,只渲染可視列
  → 捲動 / 放大檢視翻頁時補抓缺頁(同一頁不重複發、換查詢時整批放棄)
```

兩個關鍵性質:查詢改變時**不保留舊資料**(顯示上一次查詢的結果比空白更糟),而
in-flight 請求以 `AbortController` 取消。

### P2 縮圖取用管線

```text
SearchItem.sha → client.ts 組出 /thumb/<sha>/<128|512>
  → server 驗證 sha 是 64 位 hex(否則 400)
  → 以 catalog 的 thumbPath 規則在快取根目錄定位檔案
  → 命中回 PNG + Cache-Control: immutable;未命中回 404
  → 瀏覽器之後不再 revalidate
```

縮圖**只讀不產生**——產生端在 ingest(`assetdb thumbs`)。這是 `server` 只依賴
`core` + `store` 的直接後果。

### P3 CLI 指令管線

```text
argv
  → Options 的指令文法解析成 Invocation(GlobalArgs + Command)
  → Main 依 Command 選擇路徑語意:
       scan → 初始化語意(往上找,找不到才在 cwd 下開新庫)
       其餘 → 查詢語意(必須已存在,否則非 0 結束碼 + 指引訊息)
  → 對應子命令模組把 args 翻成下游子系統的 options,並掛上進度回呼
  → 下游子系統(catalog / ingest / ai-tagging / project)執行
  → 摘要輸出 + 結束碼
```

參數解析與路徑解析刻意放在 library 而非 executable:executable 裡的模組測不到,
而這兩段正是使用者最容易踩到的部分。

### P4 型別契約管線

```text
Api.hs 的 DTO 與手寫 ToJSON
  ↕ (逐型別比對鍵集合的一致性測試)
TsTypes 的型別宣告表
  → --emit-types 以 UTF-8 位元組寫出
  → web/src/api/types.ts(checked-in)
  ↕ (漂移測試:磁碟內容 == 產生器輸出)
前端編譯期型別檢查
```

### P5 專案產出管線

```text
assetdb new-project --name --path [--pack]… [--match]
  → 目標目錄必須不存在或為空
  → 依素材包/名稱條件選出「已命名且 active 且有內容雜湊」的素材
  → 授權閘門:不可商用與授權未查證的素材包整包擋下並告知
  → 建目錄樹 + 寫樣板檔案(含依實際素材包產生的致謝區塊)
  → 逐筆自壓縮檔取出單一項目寫進 assets/<kind>/<邏輯名稱><副檔名>
  → 寫 assets/manifest.json(catalog 的 Manifest schema)
  → 寫 assets/Assets.hs(識別字撞名時去重)
  → 寫 <NAME>.cabal
  → 登記 projects / project_assets(含 copied_sha256)
  → 回報複製筆數、讀取失敗筆數、被擋下的素材包;0 筆為失敗
```

### P6 專案增量同步管線

```text
assetdb project sync --name [--pack]… [--match] [--allow-non-commercial] [--confirm]
  → 以 name 查 projects 取得登記的 path;未登記 / 目錄不存在 → 非 0 結束,不動任何檔案
  → 依與 P5 相同的條件選出候選素材
  → 對帳:候選 × project_assets 既有列 × 磁碟檔案雜湊
       → 新增 / 已存在 / 來源已更新 / 本地已修改
  → 授權閘門(同 P5,但只作用在「新增」類 —— 必須先分類才知道誰是新增)
       → 另對登記全集的素材包查授權,產出 spWarnedPacks
  → 輸出對帳摘要與各類清單(預設到此為止,不寫磁碟、不寫資料庫)
  → --confirm:逐筆自壓縮檔取出「新增」項寫進 assets/<kind>/<邏輯名稱><副檔名>
  → 登記新增列(含 copied_sha256)、更新 projects.updated_at
  → 重讀登記全集,據以重寫 assets/manifest.json 與 assets/Assets.hs
       (先登記再重讀,新增項才會出現在產物裡;兩個產物必須用同一個集合)
  → 回報四類筆數與讀取失敗筆數;0 筆新增不是失敗
```

對帳與寫入刻意分成兩個入口:對帳是純查詢,可以對著真實登記資料直接測;寫入需要
壓縮檔與 `ArchiveTools`,與 P5 共用同一套單筆解壓語意。

## 模組間公開介面(Module Interfaces)

### `server`

```haskell
-- AssetDB.Server.Api
type Api                                   -- 見「對外契約」的端點表
api             :: Proxy Api
data SearchResponse = SearchResponse { srTotal :: Int, srItems :: [SearchItem] }
data SearchItem     = SearchItem { siUlid :: Text, siName :: Maybe Text, siOriginal :: Text
                                 , siKind :: Text, siPack :: Maybe Text, siAuthor :: Maybe Text
                                 , siPath :: Text, siSha :: Maybe Text }
data PackSummary    = PackSummary { psSlug, psName :: Text
                                  , psVendor, psAuthor, psLicense :: Maybe Text
                                  , psStatus, psAi :: Text, psCount :: Int }
data Health         = Health { hAssets, hPacks, hNamed, hThumbs :: Int, hIndexStale :: Bool }
data PNG                                   -- image/png 內容型別
type ThumbResponse = Headers '[Header "Cache-Control" Text] ByteString

-- AssetDB.Server.App
data ServerConfig = ServerConfig { scDbPath, scCacheRoot, scWebRoot :: FilePath
                                 , scHost :: String, scPort :: Int, scInit :: Bool }
runServer         :: ServerConfig -> IO ()
application       :: ServerConfig -> Store -> Application
serverSettings    :: ServerConfig -> Warp.Settings
resolveServerDb   :: ServerConfig -> IO (Either String FilePath)
dbMissingMessage  :: FilePath -> String
startupBanner     :: String -> Int -> FilePath -> Int -> String
countAssets       :: Store -> IO Int
isThumbSha        :: Text -> Bool
isLoopbackHost    :: String -> Bool
thumbCacheControl :: Text                  -- "public, max-age=31536000, immutable"
defaultHost       :: String                -- "127.0.0.1"
defaultSearchLimit, maxSearchLimit :: Int   -- 60 / 500

-- AssetDB.Server.Cli
data CliCommand = ShowUsage | EmitTypes FilePath | RunServer ServerConfig
parseArgs   :: [String] -> Either String CliCommand
parsePort   :: [String] -> Either String Int
extractHost :: [String] -> Either String (Maybe String, [String])
defaultPort :: Int                          -- 8787
usageText   :: String

-- AssetDB.Server.TsTypes
data TsField = TsField { tfName :: Text, tfType :: Text }
data TsType  = TsType  { ttName :: Text, ttFields :: [TsField] }
tsDefinitions :: Text
tsFieldsOf    :: Text -> [Text]
```

`serverSettings`、`resolveServerDb`、`startupBanner`、`isThumbSha`、`parseArgs` 之所以
是公開的,是為了讓「預設綁在哪」「拒絕自動建檔」「sha 形狀」「參數解析」可被測試 ——
`runServer` 之後會阻塞在 Warp 上,測不動。

**消費的 catalog 介面**:`AssetDB.Store`(`Store` / `withStore` / `initSchema` /
`storeConn`)、`AssetDB.Store.Search`(`SearchQuery` / `emptyQuery` / `search` /
`searchCount` / `FacetCounts` / `facetCounts`)、`AssetDB.Store.Index`(`ftsStale`)、
`AssetDB.PathText`(`ThumbSize` / `thumbPath`)。

### `cli`

```haskell
-- AssetDB.Cli.Options
data GlobalArgs = GlobalArgs { gaDbPath :: Maybe FilePath }
data Invocation = Invocation GlobalArgs Command
data Command    = CmdScan ScanArgs | CmdTools | CmdDoctor | CmdPackList | CmdPackApply FilePath
                | CmdReorgPlan ReorgArgs | CmdClusterList (Maybe Text) | CmdClusterRule RuleArgs
                | CmdClusterApply (Maybe Text) | CmdSearch SearchArgs | CmdIndex | CmdThumbs Bool
                | CmdNewProject ProjectArgs | CmdProjectSync SyncArgs
                | CmdNoteImport NoteArgs | CmdNoteList (Maybe Text)
                | CmdLink LinkArgs | CmdAiPing AiConn | CmdAiClassify AiConn AiClassifyArgs
                | CmdAiVision AiConn AiVisionArgs | CmdAiSuggestList AiListArgs
                | CmdAiDecide AiDecideArgs | CmdAiApply AiApplyArgs
                | CmdAiQuery AiConn AiQueryArgs | CmdAiStatus
data ReorgMode  = ModeDryRun (Maybe FilePath) Bool | ModeApply Bool | ModeUndo Text | ModeListBatches

parseInvocation      :: IO Invocation
invocationInfo       :: ParserInfo Invocation      -- 規格本身,可用 execParserPure 測試
findDbUpwards        :: FilePath -> IO (Maybe FilePath)
resolveDbPathForQuery :: GlobalArgs -> IO FilePath  -- 必須已存在,否則結束
resolveDbPathForInit  :: GlobalArgs -> IO FilePath  -- 找不到才決定新庫位置
dbNotFoundMessage, dbMissingAtMessage :: FilePath -> String
dbDirName, dbFileName :: FilePath                  -- ".assetdb" / "assetdb.sqlite"
```

各指令族模組一律是「已解析的 db 路徑 + 該指令的 args → `IO ()`」的形狀,例如:

```haskell
runScan       :: FilePath -> ScanArgs    -> IO ()
runSearch     :: FilePath -> SearchArgs  -> IO ()
runIndex      :: FilePath                -> IO ()
runThumbs     :: FilePath -> Bool        -> IO ()
runNewProject :: FilePath -> ProjectArgs -> IO ()
runProjectSync :: FilePath -> SyncArgs   -> IO ()
syncExitCode  :: SyncArgs -> SyncResult -> ExitCode   -- 結束碼規則,單獨匯出以便直接測
runDoctor     :: FilePath                -> IO ()
runReorg      :: FilePath -> ReorgArgs   -> IO ()
```

`ScanArgs` / `SearchArgs` / `ProjectArgs` / `SyncArgs` / `ReorgArgs` / `RuleArgs` / `NoteArgs` /
`LinkArgs` / `AiConn` / `Ai*Args` 各由自己的指令族模組定義並由 `Options` 再匯出 ——
參數的形狀屬於執行它的模組,而不是屬於解析器。

### `project`

```haskell
-- AssetDB.Project.Create
data CreateOptions = CreateOptions { coName :: Text, coPath, coLibraryRoot :: FilePath
                                   , coPacks :: [Text], coQuery :: Maybe Text
                                   , coAllowNonCommercial :: Bool, coOnEvent :: Text -> IO () }
data CreateResult  = CreateResult { crCopied :: Int, crSkipped, crBlocked :: [Text] }
createProject      :: Store -> ArchiveTools -> CreateOptions -> IO CreateResult
nonCommercialPacks :: Connection -> [Text] -> IO [Text]   -- 授權閘門的判斷,單獨匯出以便直接測

-- AssetDB.Project.Sync
data SyncOptions = SyncOptions { soName :: Text, soLibraryRoot :: FilePath
                               , soPacks :: [Text], soQuery :: Maybe Text
                               , soAllowNonCommercial :: Bool, soConfirm :: Bool
                               , soOnEvent :: Text -> IO () }
data SyncClass   = SyncNew | SyncUnchanged | SyncSourceUpdated | SyncLocallyModified
data SyncEntry   = SyncEntry { seUlid :: Text, seName :: Text, seRelPath :: Text, seClass :: SyncClass }
data SyncPlan    = SyncPlan { spProjectPath :: FilePath, spEntries :: [SyncEntry]
                            , spBlocked :: [Text], spWarnedPacks :: [Text] }
data SyncResult  = SyncResult { syPlan :: SyncPlan, syCopied :: Int, sySkipped :: [Text] }
data SyncError   = ProjectNotRegistered Text | ProjectDirMissing FilePath
planSync    :: Store -> SyncOptions -> IO (Either SyncError SyncPlan)                  -- 只對帳,不寫
-- spBlocked 是「被擋下、不會加入」的素材包;spWarnedPacks 是「既有素材仍留著、但授權有問題」
-- 的素材包,兩者語意不同不可合併。spWarnedPacks 取自**登記的全集**而不是本次候選 ——
-- 重寫的 manifest 涵蓋全集,警告的涵蓋範圍就必須跟著全集,否則會靜靜吞掉授權問題。
syncProject :: Store -> ArchiveTools -> SyncOptions -> IO (Either SyncError SyncResult) -- soConfirm=False 時等同 planSync

-- AssetDB.Project.Template
data TemplateFile = TemplateFile { tfPath :: FilePath, tfContent :: Text }
templateDirs   :: [FilePath]
templateFiles  :: Text -> Text -> [TemplateFile]           -- 專案名 → 致謝區塊 → 檔案清單
creditsSection :: [(Text, Maybe Text, Bool)] -> Text       -- (素材包名, 授權名, 是否需署名)

-- AssetDB.Project.Assets
data AssetRef = AssetRef { arKey :: Text, arPath :: Text, arPack :: Maybe Text }
renderAssetsModule :: Text -> [AssetRef] -> Text
haskellIdent       :: Text -> Text
```

`nonCommercialPacks` 匯出是刻意的:它是專案裡少數帶法律後果的判斷,而從 `createProject`
走到它需要一整組真實壓縮檔與 `ArchiveTools`——那樣的測試貴到不會有人寫。

**消費的 catalog / ingest 介面**:`AssetDB.Manifest`(schema 與 `AssetKey`)、
`AssetDB.Id`、`AssetDB.Naming`、`AssetDB.Types`、`AssetDB.PathText`、`AssetDB.Store`、
`AssetDB.Archive`(`ArchiveTools` / `readEntry`)、
`AssetDB.Ingest.Hash`(`Sha256` / `unSha256` / `sha256File`,供 `Sync` 的對帳使用)。

`project` 依賴 `assetdb-ingest` 只為了取用內容雜湊這一個介面。這不違反「delivery 不做雜湊」
—— 那條的意思是不自行實作,而不是不准呼叫;依賴方向 `ingest ← delivery` 與通訊拓撲一致。

### `web`

```ts
// api/types.ts —— 產生物
export interface SearchItem { ulid, name, original, kind, pack, author, path, sha }
export interface SearchResponse { total: number; items: SearchItem[] }
export interface FacetValue { value: string; count: number }
export interface Facets { kinds, vendors, authors, packs, categories: FacetValue[] }
export interface PackSummary { slug, name, vendor, author, license, status, ai, count }
export interface Health { assets, packs, named, thumbs: number; indexStale: boolean }

// api/client.ts —— 前端內部唯一的網路邊界
export interface Query { q: string; kinds: string[]; packs: string[]; vendors: string[]
                       ; authors: string[]; categories: string[]
                       ; named: boolean; reference: boolean; excluded: boolean }
export const emptyQuery: Query
export function search(query: Query, limit: number, offset: number,
                       signal?: AbortSignal): Promise<SearchResponse>
export function facets(query: Query, signal?: AbortSignal): Promise<Facets>
export const health: () => Promise<Health>
export const packs:  () => Promise<PackSummary[]>
export const thumbUrl: (sha: string | null, size: 128 | 512) => string | null

// 元件邊界
export function App(): JSX.Element
export function Facets(props: { facets: Facets | null   // 五個 facet 分組的計數
                              , query: Query, setQuery: (q: Query) => void })
export function Grid(props: { query: Query, selected: SearchItem | null
                            , onSelect: (item: SearchItem | null) => void
                            , onTotal: (n: number) => void })
export function Lightbox(props: { item: SearchItem | undefined
                                , hasPrev: boolean, hasNext: boolean
                                , onPrev: () => void, onNext: () => void, onClose: () => void })
export function Detail(props: { item: SearchItem })
```

`Query` 與後端的 query string 一一對應,`App` 是它唯一的擁有者;`Grid` 與 `Facets` 只透過
props 讀寫,不各自持有一份查詢條件。

## 使用的技術

- **HTTP**:`servant` + `servant-server` + `warp`,靜態檔案走 `wai-app-static`
- **命令列**:`optparse-applicative`(`assetdb`);`assetdb-server` 手寫解析,只有五種輸入形狀
- **JSON**:`aeson`(手寫 instance)、`aeson-pretty`(manifest 輸出)
- **前端**:Vite 6 + React 18 + TypeScript 5 + TanStack Virtual(數千張縮圖的虛擬化)
- **測試**:`hspec`;伺服器端以 `wai` 的測試介面直接打 `application`,CLI 另有以真實執行檔
  跑的端到端測試(`build-tool-depends` 掛上自家 executable)
- **開發時的埠對接**:Vite dev server(5173)以 proxy 把 `/api` 與 `/thumb` 轉給 8787,
  讓前端程式碼裡的路徑在開發與正式環境完全相同
- **主控台編碼**:兩個執行檔啟動時都先設定 UTF-8 輸出——素材路徑與素材包名大量含中文

## 架構圖

```text
                        人
        ┌───────────────┼────────────────┐
        │               │                │
   終端機/腳本      瀏覽器            遊戲專案目錄
        │               │                     ▲
┌───────┴───────┐  ┌────┴─────┐               │
│  cli          │  │  web     │               │
│  Options      │  │  App     │               │
│  + 指令族模組  │  │  Facets  │               │
└───┬───────────┘  │  Grid    │               │
    │              │  Lightbox│               │
    │              │  Detail  │               │
    │              └────┬─────┘               │
    │            client.ts │ types.ts ◄──┐    │
    │       (/api/*, /thumb/*)           │    │
    │                   │                │    │
    │            ┌──────┴──────┐   --emit-types
    │            │  server     │         │    │
    │            │  Api / App  │─────────┘    │
    │            │  Cli/TsTypes│              │
    │            └──────┬──────┘              │
    │                   │ core + store only   │
    │         ┌─────────┘                     │
    │         │                        ┌──────┴──────┐
    │         │                        │  project    │
    │         │                        │  Create     │
    │         │                        │  Sync       │
    │         │                        │  Template   │
    │         │                        │  Assets     │
    │         │                        └──┬───┬──────┘
    │         │                           │   │
    ▼         ▼                           ▼   ▼
┌─────────────────────┐   ┌───────────┐  ┌─────────┐
│      catalog        │   │  ingest   │  │ ingest  │
│  (core + store)     │   │           │  │(archive)│
└─────────────────────┘   └───────────┘  └─────────┘
    ▲                          ▲
    │                          │
    └────── ai-tagging ────────┘
              ▲
              │
              cli(組合根:依賴全部套件)
```

`server` 的箭頭**只**指向 catalog;`cli` 是唯一往 ingest 與 ai-tagging 連線的入口;
`project` 需要 archive 是因為它做單筆解壓。

## 開發階段

| 階段 | 內容 | 狀態 |
|---|---|---|
| 2 | 命令列入口:指令與參數解析、資料庫路徑解析、各子命令的組合根 | ✅ |
| 7 | HTTP 服務:Servant API、縮圖靜態服務、`--emit-types` 型別產生器 | ✅ |
| 8 | 前端:虛擬化縮圖網格、facet 側欄、放大檢視 | ✅ |
| 9 | 專案產出:樣板、單筆解壓、manifest 與 `Assets.hs`、授權閘門 | ✅ |
| 14 | 專案增量同步:對帳、只增不刪、以全集重寫 manifest 與 `Assets.hs` | ✅ 委派展開完成(2026-08-21,F006) |

階段 2–9 的功能面都已實作完成並通過測試,對應的 feature 文檔為 2026-08 遷移到
`.design/` 時的回溯建檔。階段 14 於 2026-08-21 經 `/subsys-build` 委派展開完成(`F006`),
閘門裁決把 `syncExitCode` 與 `spWarnedPacks` 納入契約,並開出 `B006`、`B007` 兩份 bugfix,
兩份皆已 `done`。

## 功能規劃

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 1 | cli-entrypoint | 指令與參數解析、資料庫路徑解析、各子命令的組合根 | `cli`(`Options` + 指令族模組 + `main/Main.hs`) | - | F001 |
| 2 | http-api | Servant API(search/facets/packs/health)與縮圖靜態服務 | `server`(`Api` + `App` + `Cli`) | - | F002 |
| 3 | ts-type-contract | 後端型別產生器與前端 TypeScript 型別契約 | `server`(`TsTypes`)+ `web/src/api/types.ts` | #2 | F003 |
| 4 | web-grid-facets | 虛擬化縮圖網格、facet 側欄與放大檢視 | `web`(`App` + `components/*` + `api/client.ts`) | #2, #3 | F004 |
| 5 | project-scaffold | 專案樣板、單筆解壓、manifest 與 Assets.hs 產生、授權閘門 | `project`(`Template` + `Assets` + `Create`)+ `cli`(`Project`) | #1 | F005 |
| 6 | project-sync | 把符合條件的素材增量加入已登記的專案:對帳分四類、預設預覽、只增不刪 | `project`(`Sync`)+ `cli`(`Options` + `Project`) | #5 | F006 |

(小結:共 6 個 features,全數完成。#6 於 2026-08-21 經 `/subsys-build` 委派展開,
展開紀錄見 `build-log.md`)

## Feature 契約卡

### cli-entrypoint

- **階段**:階段 2:命令列入口
- **負責模組**:`cli` 的 `AssetDB.Cli.Options`、`AssetDB.Cli.{Scan,Doctor,Pack,Reorg,Cluster,Search,Thumbs,Project,Notes,Ai}`、`cli/main/Main.hs`
- **實作的 Level 2 介面**:對外契約 §3「`assetdb` 命令列」(指令表與三條跨指令契約);
  模組間公開介面 `cli` 的 `GlobalArgs` / `Invocation` / `Command` / `ReorgMode` /
  `parseInvocation` / `invocationInfo` / `findDbUpwards` / `resolveDbPathForQuery` /
  `resolveDbPathForInit` / `dbNotFoundMessage` / `dbMissingAtMessage` / `dbDirName` /
  `dbFileName`,以及「已解析的 db 路徑 + args → `IO ()`」的指令族形狀
- **資料流管線段落**:P3 CLI 指令管線(全段)
- **驗收標準**:
  - `--help` 以成功結束並列出所有頂層指令;子指令各有自己的說明
  - `--db` 是全域選項,未給時是「沒有指定」而不是某個預設路徑字串
  - 從子目錄執行時沿用上層既有資料庫,不開第二個;`--db` 指到不存在的檔案時把路徑印出來
  - 查詢類指令在錯誤的工作目錄下以非 0 結束碼失敗,訊息提示 `--db` 與 `scan`,
    且**不會**在工作目錄下建出空資料庫
  - 必填選項漏掉即解析失敗;可重複選項累積成清單並保留順序;`--limit` 收到非數字時失敗
    而不是靜靜採用預設值
  - `reorganize` 沒有模式旗標時解析失敗;`--delete-covered` 單獨給不算指定模式
  - `new-project` 的授權閘門預設是開的
- **明確不做**:不實作任何領域邏輯(掃描、查詢、推論、搬遷都在下游子系統);
  不在 executable 裡放可測邏輯;不提供互動式 REPL 或 shell 補全。

### http-api

- **階段**:階段 7:HTTP 服務
- **負責模組**:`server` 的 `AssetDB.Server.Api`、`AssetDB.Server.App`、`AssetDB.Server.Cli`、`server/app/Main.hs`
- **實作的 Level 2 介面**:對外契約 §1「HTTP 端點」(共用查詢參數表、六條路由、
  `SearchResponse` / `SearchItem` / `Facets` / `FacetValue` / `PackSummary` / `Health`
  四個 DTO、縮圖端點三條規則)與 §2「伺服器執行檔命令列」;模組間公開介面 `server` 的
  `Api` / `api` / `PNG` / `ThumbResponse` / `ServerConfig` / `runServer` / `application` /
  `serverSettings` / `resolveServerDb` / `dbMissingMessage` / `startupBanner` /
  `countAssets` / `isThumbSha` / `isLoopbackHost` / `thumbCacheControl` / `defaultHost` /
  `defaultSearchLimit` / `maxSearchLimit` / `CliCommand` / `parseArgs` / `parsePort` /
  `extractHost` / `defaultPort` / `usageText`
- **資料流管線段落**:P1 的後半段(query string → `SearchQuery` → DTO → JSON)、
  P2 縮圖取用管線(全段)
- **驗收標準**:
  - `/api/health` 回 200,且回傳的欄位與前端契約一字不差(一個不多一個不少),各項計數
    反映資料庫實際內容;有資料但未建索引時回報索引過期,空資料庫不算過期
  - `/api/search` 未帶 `limit` 時回 60 筆;`limit` 超過 500 時夾制到 500;上限以內原樣採用;
    負的 `offset` 回第一頁而不是錯誤;`total` 不受 `limit` 影響
  - `/api/facets` 帶了 `limit` / `offset` 也不影響結果
  - `/thumb/:sha/:size` 對含路徑分隔符或長度不符的 sha 回 400;合法 sha 但檔案不存在回 404
    (不是 400);成功回應帶正確的 `Cache-Control`
  - 預設綁定 `127.0.0.1`,`--host 0.0.0.0` 才綁所有介面;綁非回送介面時啟動訊息附警告
  - 對不存在的路徑且未帶 `--init` 時啟動失敗且**不建檔**;帶 `--init` 才接受
  - `--help` 優先於「第一個參數是 db 路徑」;`--host` 後面接旗標是錯誤;用法文字裡的預設
    port 與 `defaultPort` 一致
- **明確不做**:不提供任何寫入型端點;不做身分驗證、CORS 或速率限制;不即時產生縮圖;
  不依賴 `archive` / `ingest` / `ai` / `project` 任何套件。

### ts-type-contract

- **階段**:階段 7:HTTP 服務
- **負責模組**:`server` 的 `AssetDB.Server.TsTypes`、`server/app/Main.hs` 的 `--emit-types` 分支、產物 `web/src/api/types.ts`
- **實作的 Level 2 介面**:對外契約 §4「前端與後端的型別契約」與 §2 的 `--emit-types`;
  模組間公開介面 `server` 的 `TsField` / `TsType` / `tsDefinitions` / `tsFieldsOf`、
  `CliCommand` 的 `EmitTypes` 建構子,以及 `web` 的 `api/types.ts` 全部 interface
- **資料流管線段落**:P4 型別契約管線(全段)
- **驗收標準**:
  - 產生的定義含全部六個 interface,並標明「請勿手動編輯」
  - 每個 DTO 的 TypeScript 欄位集合與 `Api.hs` 的 `ToJSON` 實際輸出鍵集合完全相同
  - `Maybe` 欄位在 TS 側是可為 null 的型別,非 `Maybe` 欄位不是
  - checked-in 的 `web/src/api/types.ts` 與產生器輸出一致(忽略 CR),不一致時測試失敗並
    給出重新產生的指令;比對機制本身也被驗證(多一個位元組必須不相等)
  - `--emit-types` 以 UTF-8 位元組寫檔
- **明確不做**:不引入 OpenAPI / JSON Schema 工具鏈;不產生執行期驗證器(型別只在編譯期
  生效);不描述查詢參數(那由 `client.ts` 的 `Query` 手動維持對應)。

### web-grid-facets

- **階段**:階段 8:前端
- **負責模組**:`web` 的 `src/App.tsx`、`src/api/client.ts`、`src/components/{Facets,Grid,Lightbox,Detail}.tsx`
- **實作的 Level 2 介面**:模組間公開介面 `web` 的 `Query` / `emptyQuery` / `search` /
  `facets` / `health` / `packs` / `thumbUrl` 與 `App` / `Facets` / `Grid` / `Lightbox` /
  `Detail` 的 props;消費對外契約 §1 的全部端點與 §4 的 `types.ts`
- **資料流管線段落**:P1 前端查詢管線(全段)、P2 的客戶端側
- **驗收標準**:
  - 六千筆規模下畫面可用:只渲染可視列,總捲動高度由 `total` 決定而非等圖片載入
  - 捲到未載入的區間會補抓該頁,同一頁不重複發送;放大檢視用方向鍵走到可視範圍外時
    也會補抓,不會停在永遠「載入中」的空格
  - 查詢改變時清空舊結果、回捲到頂、關閉放大檢視,並取消 in-flight 請求
  - 文字輸入去抖後才發查詢
  - facet 側欄把已選條件放在最上面並可逐項移除與一次清除;分類以階層縮排呈現且父分類
    不在結果集時的孤兒仍會顯示;廠商只在「同一廠商底下有多位作者」時才成為獨立分組
  - 索引過期時畫面上出現提示與修復指令
  - 網格格子可用鍵盤走訪與開啟;放大檢視支援 Esc / ← / →
  - 沒有縮圖的項目不留破圖
- **明確不做**:**沒有自動化測試設施**——`web` 的 npm scripts 只有 dev / build / preview,
  沒有測試執行器,驗收靠 `tsc -b` 的型別檢查與人工操作;不做寫入操作(命名、標籤、建專案
  都在 CLI);不做使用者帳號或偏好持久化;不自行拼接縮圖路徑規則以外的後端路徑。

### project-scaffold

- **階段**:階段 9:專案產出
- **負責模組**:`project` 的 `AssetDB.Project.Template`、`AssetDB.Project.Assets`、`AssetDB.Project.Create`;`cli` 的 `AssetDB.Cli.Project`
- **實作的 Level 2 介面**:對外契約 §5「專案產出物」與 §3 指令表的 `new-project`;
  模組間公開介面 `project` 的 `CreateOptions` / `CreateResult` / `createProject` /
  `nonCommercialPacks` / `TemplateFile` / `templateDirs` / `templateFiles` /
  `creditsSection` / `AssetRef` / `renderAssetsModule` / `haskellIdent`,以及 `cli` 的
  `ProjectArgs` / `runNewProject`
- **資料流管線段落**:P5 專案產出管線(全段)
- **驗收標準**:
  - 授權閘門擋下不可商用的素材包,**也擋下授權未查證(NULL)的**;NULL 與 0 在閘門這一側
    等價;混合輸入時只回傳被擋下的那些;重複的 slug 不改變語意;空清單不查資料庫
  - 目標目錄已存在且非空時不動任何檔案
  - 樣板產生完整目錄樹(含尚未使用的音效目錄與 ADR 目錄)與初始檔案,所有路徑都是相對的
  - 致謝區塊特別標出需署名的素材包,沒有需署名的就不加警告,沒有素材時給明確訊息而不是空表格
  - `Assets.hs` 每個素材一個 `AssetKey` 常數、標明為產生檔、識別字撞名時去重(否則模組編不過);
    邏輯名稱轉 camelCase,開頭是數字時前置底線
  - 只解壓選中的項目,不整包解開
  - 一筆都沒複製時以非 0 結束碼結束,並提示可能是條件太窄或素材尚未命名
  - 專案與素材登記進資料庫,含複製當下的內容雜湊
- **明確不做**:不做多模板(`projects.template` 欄位為未來預留,**刻意不開 `--template`
  參數**,免得出現「可以指定但沒有效果」的假選項);不做增量更新既有專案(由 #6
  `project-sync` 負責);不產生可直接
  執行的遊戲程式碼(樣板把 h-raylib / apecs 相依註解起來);不驗證產出的 cabal 專案能編譯。

### project-sync

- **階段**:階段 14:專案增量同步
- **負責模組**:`project` 的 `AssetDB.Project.Sync`(新模組)與 `AssetDB.Project.Internal`
  (新 other-module,承接 `Create` 與 `Sync` 的共用輔助);`AssetDB.Project.Create`(改為
  取用 `Internal`,行為不變);`AssetDB.Project.Template`(SKILL.md 樣板段落);`cli` 的
  `AssetDB.Cli.Options`(`project` 指令群與 `sync` 子指令)、`AssetDB.Cli.Project`(runner)
  與 `cli/main/Main.hs`(dispatch)
- **實作的 Level 2 介面**:對外契約 §3 指令表的 `project sync` 列與三條跨指令契約中對它的
  要求(預設預覽、授權閘門預設開);§6「專案增量同步」全部條目;模組間公開介面 `project` 的
  `SyncOptions` / `SyncClass` / `SyncEntry` / `SyncPlan` / `SyncResult` / `SyncError` /
  `planSync` / `syncProject`,以及 `cli` 的 `CmdProjectSync` / `SyncArgs` / `runProjectSync` /
  `syncExitCode`。
  只使用不新增:`project` 的 `nonCommercialPacks` / `AssetRef` / `renderAssetsModule`;
  catalog 的 `AssetDB.Manifest`(`Manifest` / `ManifestAsset` / `currentSchemaVersion`)、
  `AssetDB.PathText`、`AssetDB.Store`;ingest 的 `AssetDB.Archive`(`ArchiveTools` / `readEntry`)
  與 `AssetDB.Ingest.Hash`(`Sha256` / `unSha256` / `sha256File`)
- **資料流管線段落**:P6 專案增量同步管線(全段);`--confirm` 下「單筆解壓 → 寫 manifest /
  `Assets.hs` → 登記」三段與 P5 同語意
- **驗收標準**:
  - 未登記的 `--name`、以及登記了但目錄已不存在的專案,都不動任何檔案、非 0 結束,
    訊息分別指出「未登記」與「目錄不存在」
  - 預設(無 `--confirm`)不寫磁碟、不寫資料庫,但印出四類筆數與清單;連跑兩次結果一致
  - 四類判定可被直接測到:同一筆素材在「未登記」「已登記且三個雜湊相同」「來源 sha 改變」
    「磁碟檔案被改 / 被刪」四種狀態下各落入對應類別
  - `--confirm` 後只新增「新增」類:已存在的檔案一個位元組都沒變;「來源已更新」與
    「本地已修改」的檔案不被覆蓋,且仍列在回報裡
  - `--confirm` 後 `manifest.json` 與 `Assets.hs` 含既有 + 新增的全集,識別字去重規則與
    `new-project` 一致;`SKILL.md`、`README.md`、`<NAME>.cabal` 的內容不變
  - `project_assets` 新增列帶 `copied_sha256`,既有列不變;`projects.updated_at` 更新
  - 授權閘門行為與 `new-project` 完全一致(不可商用與 NULL 都擋;`--allow-non-commercial`
    才放行);被擋下的素材包逐包告知
  - 授權閘門**只擋新增不回溯既有**:既有登記素材的素材包授權降級後,該素材仍留在磁碟、
    仍列入重新產生的 manifest 與 `Assets.hs`,但回報逐包列出並警告發行前要處理
  - 0 筆新增時結束碼 0 並說明「沒有需要加入的素材」;`--confirm` 下全部新增項都讀取失敗
    時非 0
  - `assetdb project sync --help` 列出全部旗標;`new-project` 的行為與輸出不受影響
  - 樣板 `SKILL.md` 的「加入新素材」段落改為說明 `project sync` 的用法,不再寫「尚未實作」
- **明確不做**:不刪除、不覆蓋、不搬移專案內任何既有檔案;不提供「更新到來源新版本」或
  「還原本地修改」的旗標(那是另一個 feature,要先回到本文件補契約);不重寫樣板檔案;
  不改 `new-project` 的選素材語意;不新增 HTTP 端點或前端入口;不做 hardlink 複製模式
  (`copy_mode` 仍固定 `'copy'`);不把 `new-project` 改成 `project new`(既有指令名不動)。
