---
id: F002
type: feature
title: backend-dispatch
description: `Backend` 的兩個建構子與 `runOp`、`BackendError` 三分、重管線指令的遠端拒絕
status: planned
stage: S3
modules: [Backend]
created: 2026-09-04
updated: 2026-09-04
depends-on: [shell/F001]
related-adr: []
related-feature: []
code-paths: []
---

# F002: backend-dispatch

## 契約

- **階段**:階段一
- **負責模組**:Backend
- **實作的 Level 2 介面**:契約 E 全部(`Backend` / `BackendError` / `runOp` / `Op`)
- **資料流管線段落**:CLI 與 MCP 管線的「`Backend.runOp` → 分派」那一段
- **驗收標準**:
  - 對每一個有 CLI 出口的 `service` 操作,`Embedded` 與 `Remote` 兩條路徑回傳的 View **逐欄相等**
    (以同一個 vault 起一個本機伺服器對照) — 觀察點:契約 E 的 `runOp`
  - 業務失敗時兩條路徑的 `BusinessError` 的 `code` 與 `message` **逐字相等** — 觀察點:契約 E 的
    `BusinessError`、契約 A 的 `ErrorBody`
  - `Remote` 下呼叫任一重管線指令回 `PipelineNotRemote` 並帶指令名,**不發出任何 HTTP 請求** —
    觀察點:契約 E 的 `PipelineNotRemote`
  - 連線失敗與非預期狀態碼回 `TransportError`,**不會**被誤包成 `BusinessError` — 觀察點:
    契約 E 的 `BackendError`
  - 指令層的型別看不見 `Embedded` / `Remote`:`Op` 的使用端不需要 case 兩個建構子 — 觀察點:
    契約 E 的 `Op`
  - `aapms-backend` 的 `build-depends` 不含 `optparse-applicative` / `warp` / `aapms-store` /
    `aapms-workspace` — 觀察點:`CabalSpec`
- **明確不做**:不解析參數(shell/F003-cli-options-and-envelope);不渲染(shell/F004-cli-render);不決定 exit code(shell/F003-cli-options-and-envelope)
