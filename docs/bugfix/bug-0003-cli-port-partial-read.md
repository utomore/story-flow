---
id: bug-0003
type: bug
title: cli-port-partial-read
description: Server CLI 的 port 參數用 partial read 解析
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
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

- [ ] T1: `Main.hs` 的 port 解析改用 `readMaybe`,失敗時印出清楚訊息並 `exitFailure`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `MainSpec.port 參數非數字時印出清楚錯誤訊息並以非 0 結束` | 用非數字字串呼叫,確認不再是 GHC runtime 例外 |
| T1 | `MainSpec.port 參數合法數字時正確解析` | 確認正常路徑未被改壞 |
| T1 | `MainSpec.port 參數缺省時使用預設值 8787` | 確認預設值行為未被改壞 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
