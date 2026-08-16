---
id: enhance-2026-08-16-pagination-constants-consolidation
type: enhance
title: pagination-constants-consolidation
description: 收斂四處各自為政的分頁常數
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
---

# 四個各自為政的分頁常數,server 端未具名

## 現況說明

分頁大小/上限目前有四處各自獨立定義:

| 位置 | 值 | 狀態 |
|---|---|---|
| `server/App.hs:62` | `maybe 60 (min 500) lim` | ⚠ 無名字無註解 |
| `store/Search.hs:68` | `sqLimit = 50` | 有名字 |
| `web/Grid.tsx:8` | `PAGE = 120` | 有名字,無註解說明由來 |
| `cli/Search.hs` | `--limit 20`(預設) | 分散在 CLI 參數定義 |

四個值彼此不一致且沒有共同的設計依據紀錄,不確定是否為刻意分工(如 server 預設頁較大
因為前端一次抓多筆、CLI 預設較小因為終端機螢幕有限)還是純粹各自為政的歷史結果。

## 修正方案

1. 至少為 `server/App.hs` 的 60/500 加上具名常數與註解(說明為何是這兩個值)。
2. 與開發者確認四個值是否應該統一,或維持刻意分工但補上跨檔案的註解互相指涉
   (例如 `store/Search.hs` 的 `sqLimit` 註解裡提到 server/cli/web 端點各自的預設值)。

## TodoList

- [ ] T1: `server/App.hs` 的 60/500 改為具名常數
- [ ] T2: 與開發者確認四值是否統一或維持分工,並在各處補上互相指涉的註解

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AppSpec.search 端點預設 limit 與上限值符合具名常數` | 迴歸測試,確認改名沒改變行為 |
| T2 | 人工 code review 確認四處註解已補上 | 純文件性修改 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
