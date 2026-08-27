---
id: F006
type: feature
title: search-and-facets
description: 以可逐項組裝的條件做全文與 facet 篩選查詢,並計算 facet 分佈
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F004, F005]
related-adr: [ADR-001]
---

# F006: 檢索與 Facet 計數

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

把一份宣告式的查詢條件(`SearchQuery`)組裝成 SQL,交付結果列(`SearchHit`)、
總筆數與 facet 分佈(`FacetCounts`)。查詢含中日韓字元時**兩條全文路徑都走**再取聯集 ——
「金門建築」在 trigram 索引找得到,「金門」只有 bigram 索引找得到,而使用者不該需要
知道這件事。

facet 計數的關鍵在於:算某個 facet 的分佈時要**排除該 facet 自己的條件**。否則
已經選了「作者 = Crusenho」之後,作者側欄只會剩下 Crusenho 一筆,使用者就沒辦法改選別人。
這也是條件必須做成可逐項組裝的資料、而不是一整段字串的理由。

## 落地位置

- `store/src/AssetDB/Store/Search.hs` —— `SearchQuery` / `SearchHit` / `FacetCounts` 三個 DTO,
  以及 `emptyQuery` / `search` / `searchCount` / `facetCounts`
- 依賴:`store/src/AssetDB/Store/Tokenize.hs`(查詢側展開與 FTS5 跳脫,F005)、
  `store/src/AssetDB/Store/Schema.hs`(`assets` / `packs` / `authors` / `licenses` /
  `asset_categories` / `categories` 與兩張 FTS5 表,F004)
- 下游消費者(不屬本 feature):delivery 的 server API 與 CLI `search`
- 相關紀錄:`.design/enhancements/G-E001-pagination-constants-consolidation.md`
  (各入口的分頁常數)

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Store.Search` 一節:

- `SearchQuery` 的欄位:
  - `sqText`:全文條件。空白或全空白視為無條件。
  - `sqKinds` / `sqPacks`(素材包 slug)/ `sqAuthors` / `sqVendors`:多值取 `IN`。
  - `sqCategories`:分類路徑(如 `icon` 或 `icon/potion`)。**精確比對,不做前綴展開** ——
    分類器對每一筆素材同時寫入頂層與子分類兩列,所以選 `icon` 本來就涵蓋子分類。
  - `sqCommercialOnly`、`sqNamedOnly`(只要已指定邏輯名稱的)。
  - `sqIncludeExcluded`:是否納入被規則判定為非素材的項目(宣傳圖等)。**預設不納入。**
  - `sqIncludeReference`:是否納入參考資料。**預設不納入** —— 找 GUI 框時不該跳出廟宇照片。
  - `sqLimit` / `sqOffset`。
- `emptyQuery`:全部條件為空、`sqLimit = 50`。這只是函式庫層的保守預設,
  各入口刻意不同並自行覆寫(G-E001)。
- `SearchHit`:`hitUlid` / `hitLogical` / `hitOriginal` / `hitKind` / `hitPack` /
  `hitAuthor` / `hitPath` / `hitSha`,附 `FromRow`。
- `search`:多個條件之間是交集。排序為「已命名的優先 → 邏輯名稱 → 原始檔名」——
  未命名的還沒有穩定排序依據,用原始檔名至少是可預測的。
- `searchCount`:套用同一組條件的總筆數(不受 limit/offset 影響)。
- `FacetCounts`:`fcKinds` / `fcPacks` / `fcAuthors` / `fcVendors` / `fcCategories`,
  各為 `[(值, 筆數)]`,依筆數遞減、同筆數依值排序。
- `facetCounts`:每個 facet 各跑一次查詢,**先移除該 facet 自己的條件**。分類的計數走
  獨立查詢並以 `COUNT(DISTINCT)` 去重(一筆素材同時掛在 `icon` 與 `icon/potion` 底下)。

## 驗收依據

- `store/test/AssetDB/Store/SearchSpec.hs`(檔頭註明:fixture 重現真實素材庫的三種情況 ——
  英文素材、中文參考資料、被排除的宣傳圖;兩條全文路徑必須各自驗證)
  - 「全文」:`以邏輯名稱搜尋`、`以廠商原始檔名搜尋`、`以作者搜尋`、
    `ASCII 子字串 —— trigram 索引的價值所在`、`查詢裡的減號不會被當成 NOT 運算子`、
    `搜不到就是空,不是全部`
  - 「中文全文」:`兩字詞走 bigram 索引`、`長詞同樣找得到`、
    `參考資料預設不出現 —— 找 GUI 框時不該跳出廟宇照片`
  - 「facet 篩選」:`依廠商`、`依素材包`、`多個條件是交集`、`只要已命名的`、
    `被排除的項目預設不出現`
  - 「facet 計數」:`算某個 facet 時排除該 facet 自己的條件`、
    `其他 facet 仍受目前條件約束`
  - 「索引維護」:`重建後筆數與資源相符`、`只有含中日韓字元的資源才進 bigram 索引`、
    `偵測得出索引落後`(此三項同時是 F005 的驗收依據 —— 檢索與索引在同一個 fixture 上驗)
- `store/test/AssetDB/Store/FtsSpec.hs` —— 兩條全文路徑在原始 SQL 層的行為基準
  (見 F005),`Search` 的全文條件建立在其上
