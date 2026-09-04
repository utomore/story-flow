---
id: F008
type: feature
title: index-ops
description: `reindex` / `refreshIndex` / `IndexReport`
status: planned
stage: S3
modules: [Machine, Scope]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F003]
related-adr: []
related-feature: []
code-paths: []
---

# F008: index-ops

## 契約

- **階段**:階段三
- **負責模組**:Machine、Scope
- **實作的 Level 2 介面**:契約 E 的 `reindex` / `refreshIndex` / `IndexReport`;模組間公開介面的
  `withPipeline`;使用 service/F001-service-env-and-scope 的 `Env`(無新增)
- **資料流管線段落**:管線範圍那一支(`resolvePipeline` → 對每個 vault 各跑一次 → 各自的
  `IndexReport`)
- **驗收標準**:
  - `reindex` 對範圍內**每個** vault 各回一筆 `IndexReport`,`irVault` 兩兩相異 — 觀察點:
    契約 E 的 `IndexReport`
  - 刪掉某個 vault 的 `index.db` 後 `reindex`,該 vault 的 `listNodes` 結果與刪除前逐欄相等
    (ADR-013:索引可丟) — 觀察點:契約 E 的 `reindex`、契約 D 的 `listNodes`
  - 單一 vault 的解析失敗只讓該檔進 `irIssues`,**不中止整批**:其餘檔案仍被索引 — 觀察點:
    契約 E 的 `IndexReport`
  - 某個 vault 不可達時,它不出現在 `IndexReport` 清單裡,而其餘 vault 照跑 — 觀察點:契約 E 的
    `reindex`、契約 C 的 `vaultCheck`
  - `refreshIndex` 對沒有變動的 vault 回 `irFiles == 0` — 觀察點:契約 E 的 `IndexReport`
- **明確不做**:不實作索引 schema 與重建邏輯(graph-core);不掃壓縮檔(`asset-ingest`);
  管線範圍不接受「沒有寫入目標」以外的降級——`resolvePipeline` 回什麼就跑什麼
