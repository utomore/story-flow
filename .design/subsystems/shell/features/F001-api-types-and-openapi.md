---
id: F001
type: feature
title: api-types-and-openapi
description: servant 路由型別、`HttpApiData`、`ToSchema`、OpenAPI 3 輸出、`ToJSON` ↔ `ToSchema` 逐欄對齊
status: planned
stage: S3
modules: [Api.Routes, Api.Instances, Api.OpenApi]
created: 2026-09-04
updated: 2026-09-04
depends-on: []
related-adr: []
related-feature: []
code-paths: []
---

# F001: api-types-and-openapi

## 契約

- **階段**:階段一
- **負責模組**:Api.Routes、Api.Instances、Api.OpenApi
- **實作的 Level 2 介面**:契約 C 的路由表全部條目與四個參數(`{ref}` / `{selector}` /
  `revision` / `mode` / `{sha256}`);契約 C 的錯誤 body 形狀;使用 `service` 契約 B / C / D / E 的
  View 與請求型別(無新增)
- **資料流管線段落**:HTTP 管線的「servant 依 `Api.Routes` 解碼」那一段,以及 CLI 遠端路徑與
  MCP tool 映射共用的型別來源
- **驗收標準**:
  - 路由表的**每一條**都對應到 `service` 的一個操作,且 `service` 契約 C / D / E 裡標了 REST 出口的
    操作**每一個**都有路由(雙向無遺漏) — 觀察點:契約 C 的路由表
  - 每個寫入 method 的 `revision` 是**必填** query 參數:缺它時 servant 解碼失敗而不是進 handler —
    觀察點:契約 C 的 `revision`
  - `{ref}` 的 `FromHttpApiData` 對 `<id>` 與 `<vault>:<id>` 都解得開,對其他形狀回解碼失敗;
    `ToHttpApiData` 與它互為反函數 — 觀察點:契約 C 的 `{ref}`
  - 對每個 View 型別,`ToJSON` 樣本值的鍵集合等於 `ToSchema` 的 `properties` 鍵集合 — 觀察點:
    Api.Instances
  - `--openapi` 產出的文件可被通用 OpenAPI 3 驗證器接受,且 `paths` 的數量等於路由表的條目數 —
    觀察點:Api.OpenApi
  - `aapms-api` 的 `build-depends` **不含** `servant-server` / `servant-client` / `warp` /
    `aapms-store` / `aapms-workspace`;**含** `aapms-service`(View 與請求型別住在那裡,路由型別
    必須引用它) — 觀察點:`CabalSpec`
- **明確不做**:不含任何 handler 實作、不含 client 函式、不決定狀態碼(shell/F005-http-server)
