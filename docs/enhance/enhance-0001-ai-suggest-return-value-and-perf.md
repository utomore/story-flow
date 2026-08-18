---
id: enhance-0001
type: enhance
title: ai-suggest-return-value-and-perf
description: 修正建議回報值並消除叢集目標的全表掃描
status: done
created: 2026-08-16
updated: 2026-08-18
related-adr: [adr-0007]
related-spec: []
---

## `upsertSuggestions` 回報值不誠實;`applySuggestions`/`resolveCluster` 對叢集目標全表掃描

### 現況說明

兩個獨立問題,同屬 `ai` 建議管線的既有瑕疵,合併在此文件一併處理:

1. **回報值不誠實**(`ai/src/AssetDB/AI/Suggest.hs:124-128`,`upsertSuggestions`):
   函式回傳 `length sgs`,但 SQL 的 `ON CONFLICT … WHERE status='pending'` 可能實際上
   一筆都沒寫入(該筆已被人工決定過)。呼叫端顯示「產生 N 筆建議」會高估實際寫入數。
2. **O(建議數 × 包大小)的效能寫法**(`ai/Suggest.hs:269-282` 的 `applySuggestions`、
   `cli/app/AssetDB/Cli/Ai.hs:286-298` 的 `resolveCluster`):對每筆建議呼叫
   `resolveTargets`,cluster 分支把整包 assets 撈回來在 Haskell 端過濾。同一叢集有
   8 筆建議就掃 8 次。目前資料量(約 6 千筆)無感,但寫法上不隨規模成長而擴展。

### 為什麼現在做

回報值問題會誤導使用者對批次執行結果的判斷(見 `docs/_archive/AI.md` 的操作手冊,
使用者依賴這些數字判斷是否需要重跑)。效能問題目前無感但屬於已知技術債,趁邏輯還在
記憶中一併修正成本較低。

### 修正方案

1. `upsertSuggestions` 改為回傳實際受影響(寫入)的筆數,可用 SQLite 的
   `changes()` 或改寫 SQL 讓 `RETURNING` 反映實際寫入列。
2. `resolveCluster` 改為直接以 SQL 查詢叢集內的 asset id(讓資料庫做過濾),取代
   「整包撈回 Haskell 端再過濾」。

### TodoList

- [x] T1: `upsertSuggestions` 回傳實際寫入筆數而非輸入清單長度
- [x] T2: 消除「同一叢集 N 筆建議掃 N 次」的重複掃描(方案偏離,見實作備註)

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `SuggestSpec.對已存在 pending 記錄的建議回傳實際寫入數而非輸入數` | 先插入部分已決定的建議,驗證回報數與實際寫入數一致 |
| T2 | `SuggestSpec.同一目標的多筆建議只解析一次,結果與逐筆解析一致` | 以 IORef 計數解析器呼叫次數,並驗證套用結果不變 |

### 實作備註

- T1:以 sqlite-simple 的 `changes` 在交易內逐筆加總,回傳實際寫入(新增或更新)數;
  被 `WHERE status='pending'` 擋下的列不計入。
- T2 **偏離原方案(經開發者確認)**:「改為 SQL 端過濾」不可行 —— 叢集形狀由
  `clusterKeyOf` 在 Haskell 計算,且 `Cluster.hs` 明定「分群與反查必須是同一段程式碼」,
  把形狀邏輯複製進 SQL 會違反這條教訓。改為在 `applySuggestions` 內以 `Map` 快取每個
  `(target_type, target_key)` 的解析結果:同一目標 k 筆建議由 k 次掃描降為 1 次,
  複雜度從 O(建議數 × 目標大小) 降為 O(相異目標數 × 目標大小)。快取安全的前提是
  套用只寫 tags / asset_tags / asset_categories、不動 assets,已寫進程式註解。
  另將 `resolveCluster` 的 SQL 縮小為 `entry_path IS NOT NULL` 並只取 `entry_path`
  (分群本就只吃 entry_path,散檔不可能是叢集成員),反查與分群的輸入域一致。
- 測試:`cabal test all` 全綠(assetdb-ai-test 42 examples, 0 failures)。
