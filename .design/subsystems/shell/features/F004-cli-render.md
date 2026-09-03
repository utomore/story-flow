---
id: F004
type: feature
title: cli-render
description: 唯一的人類可讀渲染器:作用中 vault 的開頭行、節點 / 清單 / 樹 / 搜尋結果、警告與 `ScopeIssue`
status: planned
stage: S3
modules: [Cli.Render]
created: 2026-09-04
updated: 2026-09-04
depends-on: [shell/F003]
related-adr: []
related-feature: []
code-paths: []
---

# F004: cli-render

## 契約

- **階段**:階段二
- **負責模組**:Cli.Render
- **實作的 Level 2 介面**:契約 B 的「非 `--json` 模式第一行是作用中的 vault」;使用 `service` 的
  View 型別(無新增)
- **資料流管線段落**:CLI 管線的最後一格(View → 人類可讀文字)
- **驗收標準**:
  - 非 `--json` 模式的**第一行**指出作用中的 vault:寫入類指令印寫入目標的名稱與路徑,查詢類指令
    印涵蓋的 vault 數與名稱 — 觀察點:契約 B
  - 跨 vault 的清單與搜尋結果**每一筆**都看得出來源 vault — 觀察點:`service` 契約 B 的 `nvVault`
  - `service` 回的 `nvWarnings` 與範圍解析的 `ScopeIssue` 都被印出來,且**不影響 exit code**
    (成功仍是 `0`) — 觀察點:`service` 契約 B 的 `nvWarnings`、契約 A 的 exit code 表
  - Level 的樹以縮排呈現,層級與 `NodeTreeView` 的結構一致 — 觀察點:`service` 契約 B 的
    `NodeTreeView`
  - 渲染器是**唯一的一份**:內嵌與遠端兩條路徑的非 JSON 輸出逐字相等 — 觀察點:契約 E 的 `runOp`
  - 渲染器不呼叫任何 `service` 操作(它只吃已經拿到的 View) — 觀察點:Cli.Render 的模組介面
- **明確不做**:不決定 exit code(shell/F003-cli-options-and-envelope);不查型別註冊表決定怎麼印——要什麼欄位由 View 決定
