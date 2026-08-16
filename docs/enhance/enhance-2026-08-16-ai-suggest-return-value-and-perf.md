---
id: enhance-2026-08-16-ai-suggest-return-value-and-perf
type: enhance
title: ai-suggest-return-value-and-perf
description: 修正建議回報值並消除叢集目標的全表掃描
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0007]
related-spec: []
---

# `upsertSuggestions` 回報值不誠實;`applySuggestions`/`resolveCluster` 對叢集目標全表掃描

## 現況說明

兩個獨立問題,同屬 `ai` 建議管線的既有瑕疵,合併在此文件一併處理:

1. **回報值不誠實**(`ai/src/AssetDB/AI/Suggest.hs:124-128`,`upsertSuggestions`):
   函式回傳 `length sgs`,但 SQL 的 `ON CONFLICT … WHERE status='pending'` 可能實際上
   一筆都沒寫入(該筆已被人工決定過)。呼叫端顯示「產生 N 筆建議」會高估實際寫入數。
2. **O(建議數 × 包大小)的效能寫法**(`ai/Suggest.hs:269-282` 的 `applySuggestions`、
   `cli/app/AssetDB/Cli/Ai.hs:286-298` 的 `resolveCluster`):對每筆建議呼叫
   `resolveTargets`,cluster 分支把整包 assets 撈回來在 Haskell 端過濾。同一叢集有
   8 筆建議就掃 8 次。目前資料量(約 6 千筆)無感,但寫法上不隨規模成長而擴展。

## 為什麼現在做

回報值問題會誤導使用者對批次執行結果的判斷(見 `docs/_archive/AI.md` 的操作手冊,
使用者依賴這些數字判斷是否需要重跑)。效能問題目前無感但屬於已知技術債,趁邏輯還在
記憶中一併修正成本較低。

## 修正方案

1. `upsertSuggestions` 改為回傳實際受影響(寫入)的筆數,可用 SQLite 的
   `changes()` 或改寫 SQL 讓 `RETURNING` 反映實際寫入列。
2. `resolveCluster` 改為直接以 SQL 查詢叢集內的 asset id(讓資料庫做過濾),取代
   「整包撈回 Haskell 端再過濾」。

## TodoList

- [ ] T1: `upsertSuggestions` 回傳實際寫入筆數而非輸入清單長度
- [ ] T2: `resolveCluster` 改為 SQL 端過濾,移除整包掃描

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `SuggestSpec.upsertSuggestions 對已存在 pending 記錄的建議回傳實際寫入數而非輸入數` | 先插入部分已決定的建議,驗證回報數與實際寫入數一致 |
| T2 | `AiSpec.resolveCluster 回傳結果與整包掃描版本一致` | 迴歸測試,確保改動不改變查詢結果 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
