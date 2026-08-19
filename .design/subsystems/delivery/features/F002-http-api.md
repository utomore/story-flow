---
id: F002
type: feature
title: http-api
description: Servant API(search/facets/packs/health)與縮圖靜態服務
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-001, ADR-002, ADR-003]
---

# F002: HTTP 服務

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

`assetdb-server` 提供瀏覽器前端所需的一切:四個 JSON 端點、一個內容定址的縮圖端點、
以及前端靜態檔案的服務。

三個決定形塑了它的樣子:

1. **只依賴 `core` + `store`。** 伺服器是長時間常駐、對外開埠的行程,不該把
   JuicyPixels、zip、7-Zip sidecar 與 LLM 客戶端拖進來。縮圖因此是**讀快取檔案**而不是
   即時產生;產生端在 ingest。
2. **只讀不寫。** 所有會改動資料庫的動作都只有 CLI 入口,HTTP 面沒有任何寫入型端點。
3. **JSON 欄位名是前端的合約,所以手寫 `ToJSON`。** 交給 Generic 的前綴剝除規則決定,
   會在有人重新命名 Haskell 欄位時無聲改掉 API。

參數解析刻意放在 library 而不是 `app/Main.hs`:那是最容易讓使用者踩到的一段程式,
而放在執行檔裡的東西測不到。同理,`serverSettings` / `resolveServerDb` / `startupBanner`
都抽成獨立函式,因為 `runServer` 之後會阻塞在 Warp 上,測不動。

## 落地位置

- `server/src/AssetDB/Server/Api.hs` —— 路由型別、四個回應 DTO 與手寫 `ToJSON`、
  `PNG` 內容型別、帶 `Cache-Control` 標頭的縮圖回應型別
- `server/src/AssetDB/Server/App.hs` —— handler 實作、`ServerConfig`、
  `defaultSearchLimit` / `maxSearchLimit` / `defaultHost`、`resolveServerDb`、
  `startupBanner`、`isThumbSha`、`thumbCacheControl`、靜態檔案服務
- `server/src/AssetDB/Server/Cli.hs` —— `parseArgs` / `parsePort` / `extractHost` /
  `defaultPort` / `usageText`,以及由 db 路徑推導快取與前端根目錄
- `server/app/Main.hs` —— 主控台編碼、`parseArgs` 的三個分支
- `web/vite.config.ts` —— dev proxy 把 `/api` 與 `/thumb` 轉給 8787(與 `defaultPort`
  互相指涉,兩邊沒有共用設定來源)

## 對外行為

### 端點

| 端點 | 回應 | 要點 |
|---|---|---|
| `GET /api/search` | `{ total, items }` | `limit` 省略時 60,超過 500 夾制到 500,負 `offset` 夾制到 0;`total` 不受 `limit` 影響 |
| `GET /api/facets` | 五組 `{ value, count }` 陣列 | 刻意不吃 `limit` / `offset` |
| `GET /api/packs` | `PackSummary[]` | 素材包與授權狀態,依名稱排序 |
| `GET /api/health` | `{ assets, packs, named, thumbs, indexStale }` | 給前端顯示總量與「索引過期」提示 |
| `GET /thumb/:sha/:size` | `image/png` | 見下 |
| `GET /*`(Raw) | 靜態檔案 | 放在路由最後,`index.html` 為索引檔 |

`/api/search` 與 `/api/facets` 共用同一組查詢參數:`q`、可重複的
`kind` / `pack` / `vendor` / `author` / `category`,以及 `named` / `reference` / `excluded`
三個 `QueryFlag`(認參數存在與否,不是值)。它們被映射成 catalog 的 `SearchQuery`,
HTTP 面不定義第二套查詢語言。對外識別一律是 ULID,整數主鍵不外洩。

### 縮圖

- `sha` 必須是剛好 64 位十六進位字元,否則 400。`sha` 直接參與檔案路徑組合,而 servant 的
  `Capture` 會把 `%2F` 解碼回 `/`——「呼叫端只會傳合法 sha」是呼叫端的紀律,不是伺服器的保證。
- 路徑規則走 catalog 的 `AssetDB.PathText.thumbPath`,與 ingest 的產生端共用同一份規則;
  規則分家的症狀是縮圖找不到卻不報錯。`size >= 512` 取 512px,否則 128px。
- 命中回 `Cache-Control: public, max-age=31536000, immutable`(內容定址保證位元組永不改變);
  未命中回 404,不是 400。

### 執行檔

```text
assetdb-server <db 路徑> [port] [--host 位址] [--init]
assetdb-server --emit-types <輸出檔>
assetdb-server --help | -h
```

- 預設 port 8787、預設 host `127.0.0.1`。綁定非回送介面時啟動訊息附警告——本服務沒有
  任何身分驗證,開放區網是使用者明講的決定,不是預設值。
- `--host` 的值長得像旗標或為空字串時拒絕,不照收(照收會安靜地把伺服器綁到一個叫
  `--init` 的「介面」上)。
- 找不到 db 檔時**拒絕自動建檔**,要 `--init` 才接受不存在的路徑:打錯路徑建出來的空庫,
  查詢會誠實回 0 筆,前端顯示成「素材庫是空的」。
- `--help` 的比對優先於「第一個參數是 db 路徑」,否則想看用法的人會得到一個掛住的終端機。
- 啟動訊息印出實際綁定的介面、db 絕對路徑與 assets 筆數:「連到空資料庫」在啟動當下就看得見。
- 快取根目錄取 `<db 的上層目錄>/cache/thumbs`,靜態前端取 `<db 的上上層目錄>/web`。
- 錯誤訊息本體明確以 UTF-8 編碼(`errBody` 是 lazy ByteString,直接塞中文會變亂碼)。

## 驗收依據

`server/test/`(hspec;伺服器端以 `wai` 的測試介面直接打 `application`,不啟真實 Warp):

- **`server/test/AssetDB/Server/AppSpec.hs`**
  - `resolveServerDb`:「對不存在的路徑且未帶 --init 時失敗,而且不建檔」、
    「帶 --init 時接受不存在的路徑,交由 withStore 建立新庫」、「資料庫存在時回傳絕對路徑」
  - `countAssets`:「回報 assets 表的實際筆數」
  - `serverSettings`:「預設只綁定 127.0.0.1」、「明確指定 --host 0.0.0.0 時綁定所有介面」、
    「port 一併寫進 Settings」
  - `startupBanner`:「包含 host、port、db 絕對路徑與 assets 筆數」、
    「綁定非回送介面時附上警告」
  - `isThumbSha`:「接受 64 位十六進位字串」、「拒絕含路徑分隔符、長度不符或非十六進位的輸入」
  - 縮圖端點:「對含路徑分隔符的 sha 回 400」、「對長度不符的 sha 回 400」、
    「對合法 64 位 hex sha 正常回應」、「縮圖不存在時回 404,而不是 400」、
    「回應包含正確的 Cache-Control 標頭」
  - `GET /api/health`:「回 200」、「回傳前端契約上的五個欄位,一個不多一個不少」、
    「各項計數反映資料庫的實際內容」、「有資料但沒建索引時回報索引過期」、
    「空資料庫不算索引過期」
  - `GET /api/search` 的分頁夾制:「具名常數與對外行為的字面值一致」、
    「未指定 limit 時採預設值 60」、「limit 超過上限時夾制到 500,而不是照單全收」、
    「上限以內的 limit 原樣採用」、「負的 offset 回傳第一頁,而不是錯誤」、
    「total 回報符合條件的總數,不受 limit 影響」
  - `GET /api/facets` 的夾制:「facets 不吃 limit/offset,帶了也不影響結果」
- **`server/test/AssetDB/Server/CliSpec.hs`**
  - `parsePort`:「非數字時回傳清楚的錯誤訊息,而不是 read 的例外」、「合法數字時正確解析」、
    「缺省時使用預設值 8787」、「超出 1..65535 時視為錯誤」
  - `parseArgs`:「db 路徑帶非數字 port 時整體失敗,不會啟動伺服器」、
    「只給 db 路徑時用預設 port、預設 host 且不啟用 --init」、「--init 可以出現在任意位置」、
    「--help 優先於「第一個參數是 db 路徑」」、「--emit-types 帶輸出檔」、
    「無法辨識的旗標是錯誤,不會被當成 db 路徑」、
    「--host 可以覆寫預設綁定介面,且不影響 db 路徑與 port」、「--host 可以出現在 db 路徑之前」、
    「--host 後面接旗標是錯誤,不會把旗標吃掉」、「--host 的值不會被誤認成 db 路徑或 port」
  - `extractHost`:「沒有 --host 時原樣回傳其餘參數」、「抽走 --host 與它的值」、
    「重複指定時後者勝」
  - 路徑推導:「cache 與 web 路徑由 db 路徑推導」
  - `usageText`:「包含的預設 port 與 defaultPort 常數一致」、「說明 --init 的用途」、
    「說明 --host 與預設值,並點出服務沒有身分驗證」
