---
id: F003
type: feature
title: node-read
description: `getNode` / `listNodes` / `childrenOf` / `linksOf`;`AnyNode → NodeView` 投影、每筆帶 vault
status: planned
stage: S3
modules: [Read]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F001]
related-adr: []
related-feature: []
code-paths: []
---

# F003: node-read

## 契約

- **階段**:階段二
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 B 全部(`NodeView` / `NodeDetail` / `NodeTreeView`);契約 D 的
  `getNode` / `listNodes` / `childrenOf` / `linksOf` / `Page` / `LinkReport`;契約 F 的
  `NodeNotFound` / `AmbiguousRef`;使用 service/F001-service-env-and-scope 的 `withRead`(無新增)
- **資料流管線段落**:讀取管線自 `Scope.withRead` 之後到 `NodeView` 投影為止
- **驗收標準**:
  - 對讀取範圍內任一節點,`getNode` 回的 `nvVault` 等於它實際所在的 vault;跨 vault 查詢時
    `listNodes` 的**每一筆**都有 `nvVault` — 觀察點:契約 B 的 `nvVault`、契約 D 的 `listNodes`
  - `nvMeta` 與 graph-core 讀回的 `anyMeta` 逐欄相等(本層不改寫任何 `Meta` 欄位) — 觀察點:
    契約 B 的 `NodeView`
  - `nvDetail` 的建構子恒對應節點的 `IdPrefix`(`ast-` ⟺ `DAsset`,依此類推) — 觀察點:契約 B 的
    `NodeDetail`
  - `getNode` 第二參數為 `False` 時 Level 的 `dvTree == Nothing`;為 `True` 時 `dvTree` 的樹與
    graph-core 的 `buildTree` 結果同構 — 觀察點:契約 D 的 `getNode`、契約 B 的 `dvTree`
  - 不帶 vault 的 `Ref` 在讀取範圍內命中多個 vault 時回 `AmbiguousRef` 並列出全部候選;
    一個都沒有時回 `NodeNotFound` — 觀察點:契約 F 的兩個建構子
  - `listNodes` 的 `pgTotal` 是符合條件的**總數**而非本頁筆數:對任意 `limit`,
    `pgTotal` 不隨 `limit` 改變 — 觀察點:契約 D 的 `Page`
  - `linksOf` 的 `lrOut` 對解不到的目標回 `Nothing` 而**不是錯誤**(讀取不擋懸空) — 觀察點:
    契約 D 的 `LinkReport`
  - 範圍解析產生 `ScopeIssue` 時讀取操作仍成功 — 觀察點:契約 D 的四個讀取操作
- **明確不做**:不做任何寫入;不擋懸空關聯(那是寫入路徑的事);不做全文檢索(service/F007-search-facade)
