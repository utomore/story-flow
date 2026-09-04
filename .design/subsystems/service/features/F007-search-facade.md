---
id: F007
type: feature
title: search-facade
description: `search` 一次回 asset 與 entity 兩種、facet、每筆帶 vault
status: planned
stage: S3
modules: [Read]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F003]
related-adr: []
related-feature: []
code-paths: []
---

# F007: search-facade

## 契約

- **階段**:階段三
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 D 的 `search` / `SearchView` / `SearchHitView`;使用 service/F003-node-read 的
  `NodeView` 投影與 service/F001-service-env-and-scope 的 `withRead`(無新增)
- **資料流管線段落**:讀取管線的 `searchAcross` 那一支,到 `SearchView` 為止
- **驗收標準**:
  - 一次查詢的命中集合**同時可能含 asset 與 entity**:在同時有兩者命中的 fixture 上,
    `svHits` 的 `nvDetail` 出現至少兩種建構子 — 觀察點:契約 D 的 `SearchView`、契約 B 的 `NodeDetail`
  - 每一筆命中都帶 `nvVault`,且跨 vault 查詢時同一個查詢字串的結果是各 vault 結果的聯集 —
    觀察點:契約 B 的 `nvVault`、契約 D 的 `search`
  - `shvScore` 恒有值(不是 `Maybe`),且結果依它由大到小排序 — 觀察點:契約 D 的 `SearchHitView`
  - 中文二字詞(如「藥水」)查得到:在含該詞的 fixture 上 `svTotal > 0` — 觀察點:契約 D 的 `search`
  - `sqFacets` 為 `False` 時 `svFacets == Nothing`,為 `True` 時各 facet 的計數總和不小於
    `svHits` 的長度 — 觀察點:契約 D 的 `SearchView`
  - `svTotal` 是符合條件的總數,不隨分頁參數改變 — 觀察點:契約 D 的 `SearchView`
- **明確不做**:不實作切詞與 bm25 合併(graph-core/F007-store-fts-dual-index 與 graph-core/F009-store-multi-vault-read 已擁有);不做自然語句查詢規劃
  (那是 `ai`)
