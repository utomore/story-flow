---
id: F005
type: feature
title: http-server
description: handler、`AppState`、token middleware 與啟動閘門、`code` → 狀態碼、warp、`--openapi`
status: planned
stage: S3
modules: [Server.Handlers, Server.State, Server.Auth, Server.Status]
created: 2026-09-04
updated: 2026-09-04
depends-on: [shell/F001]
related-adr: []
related-feature: []
code-paths: []
---

# F005: http-server

## 契約

- **階段**:階段二
- **負責模組**:Server.Handlers、Server.State、Server.Auth、Server.Status
- **實作的 Level 2 介面**:契約 C 的狀態碼對照表與錯誤 body;`system.md` 對外介面第 2 節的繫結與
  認證規則;使用 shell/F001-api-types-and-openapi 的路由型別(無新增)
- **資料流管線段落**:HTTP 管線全段
- **驗收標準**:
  - 每個 handler 只做一件事:收解碼後的請求型別、呼叫**一個** `service` 操作、回傳。
    handler 內**沒有** `if` / `case` 的業務分支 — 觀察點:Server.Handlers 的模組介面
  - 綁非回送位址且未設 token 時**拒絕啟動**(行程以非零碼結束並印出原因),不是印警告後照跑 —
    觀察點:Server.Auth、`system.md` 對外介面第 2 節
  - loopback 模式未設 token 時可用;設了 token 後,錯誤的 token 一律 401,而比較耗時**不隨
    正確前綴長度變化** — 觀察點:Server.Auth
  - 狀態碼由 `code` 字串分派:對照表裡的每個 `code` 都對到表列狀態碼,表外的 `code` 一律 500 —
    觀察點:契約 C 的狀態碼表、Server.Status
  - 錯誤 body 與 CLI 信封的 `error` 同形,且 `code` / `message` 逐字相同 — 觀察點:契約 A 的
    `ErrorBody`、契約 C 的錯誤 body
  - 在**沒有**目前 vault 的目錄裡啟動,`GET /vaults` 仍可服務 — 觀察點:Server.State、
    `service` 契約 A 的「`openEnv` 不開任何索引」
  - `/thumb/{sha256}` 命中時回檔案並帶 `immutable` 快取標頭、未命中回 404,**任何情況都不解碼影像** —
    觀察點:契約 C 的 `/thumb/{sha256}`
  - `aapms-server` 的 `build-depends` 不含 `aapms-archive` / `aapms-ingest` / `aapms-reorg` /
    `aapms-store` / `aapms-workspace` / `JuicyPixels` — 觀察點:`CabalSpec`(硬規則 3)
- **明確不做**:不暴露契約 C「不暴露的」那一組;不做任何業務判斷;不自己包一層 `MVar`
  (互斥在 `service` 的 `Env`)
