---
id: bug-0004
type: bug
title: server-binds-all-interfaces
description: Server 預設綁定所有網路介面,同區網任何機器皆可存取且無驗證機制
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# Server 預設綁定所有網路介面,同區網任何機器皆可存取,無驗證機制

## 問題描述

`Warp.run` 預設 host 是 `*`(所有介面),同一區網內的任何機器都能搜尋素材、拉縮圖、
讀取 packs 清單,沒有任何身份驗證。單人本機工具目前可以接受無驗證,但不應該預設對
整個區網開放。

## 重現方式 / 現況證據

`server/src/AssetDB/Server/App.hs:37`:直接呼叫 `Warp.run (scPort cfg) app`,未指定 host,
Warp 預設綁定所有介面。

## 根本原因

初始實作沒有考慮「這台機器可能同時在區網環境」的情境,預設值選擇了 Warp 的預設行為
而非最小暴露面。

## 影響範圍

- `server/src/AssetDB/Server/App.hs`(`runServer`)

## 修正方案

改用 `Warp.runSettings` + `setHost "127.0.0.1"` 作為預設值,只綁定本機回送介面。若使用者
確實需要區網存取,提供明確的 `--host` 旗標讓使用者自行選擇並承擔風險,而非預設開放。

## TodoList

- [ ] T1: `runServer` 改用 `Warp.runSettings`,預設 `setHost "127.0.0.1"`
- [ ] T2: 新增 `--host` CLI 旗標,允許使用者明確指定要綁定的介面

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AppSpec.runServer 預設只綁定 127.0.0.1` | 檢查 `Settings` 物件的 host 設定值 |
| T2 | `AppSpec.runServer 帶 --host 0.0.0.0 時綁定所有介面` | 確認明確旗標可覆寫預設值 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
