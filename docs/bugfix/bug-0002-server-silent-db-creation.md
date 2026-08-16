---
id: bug-0002
type: bug
title: server-silent-db-creation
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# Server 對不存在的資料庫路徑直接建檔灌 Schema,啟動時不印出實際路徑與筆數

## 問題描述

`server` 啟動時若指定的 db 路徑不存在,`withStore` 會直接建立一個空檔案並套用 schema,
伺服器正常啟動並回應查詢(全部 0 筆),前端因此顯示「素材庫是空的」而非「伺服器連錯資料庫」。
`診斷報告-2026-08-11.md` 已提出修正方案(拒絕建立 + 啟動時印出實際路徑與筆數),但尚未套用。

## 重現方式 / 現況證據

`server/src/AssetDB/Server/App.hs:32-37`:

```haskell
runServer cfg = withStore (scDbPath cfg) $ \st -> do
  _ <- initSchema st
  putStrLn (...)          -- 訊息裡沒有印出實際 db 路徑或記錄筆數
  Warp.run (scPort cfg) (...)
```

`withStore` → `initSchema` 對不存在的路徑一律視為「新資料庫」處理,沒有區分
「這是第一次啟動」與「使用者打錯路徑」。

## 根本原因

與 [bug-0001](./bug-0001-resolve-db-path-silent-empty-db.md) 同一個模式:把「資料庫不存在」預設當成
「請幫我建一個新的」,而不是先假設使用者可能打錯路徑。伺服器啟動訊息也沒有印出足夠資訊
讓使用者自行發現問題(路徑、資源筆數)。

## 影響範圍

- `server/src/AssetDB/Server/App.hs`(`runServer`)

## 修正方案

1. 啟動時若 `scDbPath cfg` 指向的檔案不存在,拒絕自動建立,印出明確錯誤並以非 0 結束碼結束
   (提供 `--init` 或類似旗標讓使用者明確表達「這是第一次啟動,請建立新庫」)。
2. 啟動成功後印出實際連線的 db 絕對路徑與 `assets` 表的記錄筆數,讓「連到空資料庫」在
   啟動當下就可見,不必等到前端查詢才發現。

## TodoList

- [ ] T1: `runServer` 對不存在的路徑拒絕自動建立,提供明確錯誤訊息
- [ ] T2: 新增 `--init` 旗標(或等效機制)供刻意建立新庫的情境使用
- [ ] T3: 啟動成功訊息印出 db 絕對路徑與 `assets` 記錄筆數

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AppSpec.runServer 對不存在的路徑且未帶 --init 時失敗並回報明確錯誤` | 確認不再靜默建檔 |
| T2 | `AppSpec.runServer 帶 --init 對不存在的路徑會建立新庫並成功啟動` | 確認合法的初始化路徑未被誤擋 |
| T3 | `AppSpec.runServer 啟動訊息包含 db 絕對路徑與 assets 筆數` | 對已有資料的資料庫驗證輸出內容 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
