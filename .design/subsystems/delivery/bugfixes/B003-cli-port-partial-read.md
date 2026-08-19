---
id: B003
type: bugfix
title: cli-port-partial-read
description: Server CLI 的 port 參數用 partial read 解析
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: []
related-feature: []
---

# Server CLI 的 Port 參數用 Partial `read`,打錯值時噴無上下文例外

## 問題描述

啟動伺服器時若 port 參數打錯(非數字),程式直接噴 `Prelude.read: no parse`,沒有任何
提示這是哪個參數出錯、應該輸入什麼格式。

## 重現方式 / 現況證據

`server/app/Main.hs:26`:

```haskell
port = case rest of (p : _) -> read p; _ -> 8787
```

`read` 是 partial function,輸入非數字字串時拋未捕捉例外。

## 根本原因

直接用 `read` 而非 `readMaybe` 做使用者輸入解析,錯誤訊息因此完全來自 GHC runtime 而非
應用層,對使用者不友善且難以判斷問題出在 CLI 參數解析。

## 影響範圍

- `server/app/Main.hs`

## 修正方案

改用 `Text.Read.readMaybe`,解析失敗時印出清楚訊息(「port 必須是數字,收到:<p>」)並以
非 0 結束碼結束,而非讓例外從 `read` 冒出來。

## TodoList

- [x] T1: `Main.hs` 的 port 解析改用 `readMaybe`,失敗時印出清楚訊息並 `exitFailure`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `MainSpec.port 參數非數字時印出清楚錯誤訊息並以非 0 結束` | 用非數字字串呼叫,確認不再是 GHC runtime 例外 |
| T1 | `MainSpec.port 參數合法數字時正確解析` | 確認正常路徑未被改壞 |
| T1 | `MainSpec.port 參數缺省時使用預設值 8787` | 確認預設值行為未被改壞 |

實際落點:三條都在 `server/test/AssetDB/Server/CliSpec.hs` 的 `parsePort` 一節
(模組更名的理由見實作備註)。

## 根因與修法摘要

**根因**:用 partial 的 `read` 解析使用者輸入,錯誤訊息因此完全來自 GHC runtime
(`Prelude.read: no parse`),看不出是哪個參數出錯。

**修法**:參數解析從 `server/app/Main.hs` 抽到 library 的新模組 `AssetDB.Server.Cli`,
`parsePort` 改用 `Text.Read.readMaybe`,解析失敗回傳 `Left "port 必須是數字,收到:<p>"`。
`Main.hs` 只負責把 `Left` 印到 stderr 並 `exitFailure`,不再自己解析任何東西。

## 實作備註

1. **參數解析搬進 library**(`server/src/AssetDB/Server/Cli.hs`)。留在 `app/Main.hs` 的程式碼
   測不到,而參數解析正是最容易讓使用者踩到的一段。測試模組因此叫 `CliSpec` 而非對照表寫的
   `MainSpec`,內容與對照表的三條一一對應。
2. **額外加了範圍檢查**:port 必須落在 1..65535。規格只要求擋非數字,但 `readMaybe` 會讓
   `0` 與 `70000` 這類值一路傳進 `Warp.run`,錯誤同樣發生在應用層之外 —— 跟本 bug 是同一件事。
3. 順帶把預設埠號收斂成 `AssetDB.Server.Cli.defaultPort`。這只解決了 server 這一側,
   `.design/subsystems/delivery/enhancements/E002-port-8787-consolidation.md` 記錄的三處硬編碼仍未全部收斂。
