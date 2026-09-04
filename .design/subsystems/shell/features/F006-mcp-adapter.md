---
id: F006
type: feature
title: mcp-adapter
description: stdio JSON-RPC、tool 映射與命名、雙模式
status: planned
stage: S3
modules: [Mcp.Tools, Mcp.Rpc]
created: 2026-09-04
updated: 2026-09-04
depends-on: [shell/F002]
related-adr: []
related-feature: []
code-paths: []
---

# F006: mcp-adapter

## 契約

- **階段**:階段二
- **負責模組**:Mcp.Tools、Mcp.Rpc
- **實作的 Level 2 介面**:契約 D 全部;使用 shell/F001-api-types-and-openapi 的路由型別與 shell/F002-backend-dispatch 的 `runOp`(無新增)
- **資料流管線段落**:MCP 管線全段
- **驗收標準**:
  - `tools/list` 的 tool 集合由路由推導:與契約 C 路由表(扣掉「不暴露的」)**一一對應**,
    沒有手寫的額外 tool — 觀察點:契約 D 的 tool 命名、契約 C 的路由表
  - tool 名是 snake_case 且**不含產品前綴**;同一個路由在不同版本間名稱穩定 — 觀察點:契約 D
  - 每個 tool 的參數 schema 與同一路由的 OpenAPI schema **逐欄相同** — 觀察點:契約 D 的參數 schema
  - 不給 `--url` 時走內嵌:**沒有任何 HTTP 請求發出**,而且不需要有 `aapms-serve` 在跑 —
    觀察點:契約 D 的傳輸、契約 E 的 `Backend`
  - 給 `--url` 時走遠端,回傳與內嵌逐欄相等 — 觀察點:契約 E 的 `runOp`
  - 失敗回 `{"code":…,"message":…}`,與 REST 錯誤 body 的 `error` 同形且逐字相同 — 觀察點:
    契約 D 的回傳、契約 C 的錯誤 body
  - `--version` 印一行後結束,**不進 JSON-RPC 迴圈**(stdin 不被讀取) — 觀察點:契約 D 的 `--version`
  - `aapms-mcp` 的 `build-depends` 不含 `aapms-archive` / `aapms-ingest` / `aapms-reorg` /
    `optparse-applicative` — 觀察點:`CabalSpec`
- **明確不做**:不另立一套 tool 契約;不做 MCP 的資源(resources)與提示(prompts),本期只有 tools
