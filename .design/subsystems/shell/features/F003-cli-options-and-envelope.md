---
id: F003
type: feature
title: cli-options-and-envelope
description: optparse 指令樹與全域旗標互斥、統一信封、exit code、輸出編碼
status: planned
stage: S3
modules: [Cli.Options, Cli.Envelope, Cli.Encoding]
created: 2026-09-04
updated: 2026-09-04
depends-on: [shell/F002]
related-adr: []
related-feature: []
code-paths: []
---

# F003: cli-options-and-envelope

## 契約

- **階段**:階段二
- **負責模組**:Cli.Options、Cli.Envelope、Cli.Encoding
- **實作的 Level 2 介面**:契約 A 全部(`Envelope` / `ErrorBody` / `ExitKind` 與兩張表);
  契約 B 全部(四個全域旗標);使用 shell/F002-backend-dispatch 的 `runOp`(無新增)
- **資料流管線段落**:CLI 管線自 argv 到 exit code,渲染那一格除外
- **驗收標準**:
  - `--json` 模式的 stdout **恰好是一行合法 JSON**,且成功時有 `data` 無 `error`、失敗時有 `error`
    無 `data` — 觀察點:契約 A 的信封表
  - `--json` 模式下**沒有任何**非 JSON 的行(含作用中 vault 的提示行) — 觀察點:契約 A、契約 B 的
    `--json`
  - exit code 三分正確:成功 `0`;`ServiceError` 或 `TransportError` → `1`;參數解析失敗、
    `--vault` 與 `--remote` 同時給、`Remote` 下的重管線指令 → `2` — 觀察點:契約 A 的 exit code 表
  - `error.code` 對業務失敗逐字等於 `service` 的 `errorCode`;用法錯誤固定 `usage_error` —
    觀察點:契約 A 的信封表
  - 指令樹的葉子子指令集合等於 `service` 契約裡標了 CLI 出口的操作集合(雙向無遺漏),且這個
    數字**有測試釘住** — 觀察點:契約 B、`service` 契約 C / D / E 的出口欄
  - 含中日文的輸出在 Windows 主控台不出現替換字元:設定編碼後寫出一段中文再讀回,位元組可還原 —
    觀察點:Cli.Encoding
  - `aapms-cli` 的 `build-depends` 不含 `aapms-store` / `aapms-workspace` / `aapms-server` / `warp` —
    觀察點:`CabalSpec`
- **明確不做**:不實作人類可讀的版面(shell/F004-cli-render);不含任何業務分支——旗標互斥是語法規則,不是業務
