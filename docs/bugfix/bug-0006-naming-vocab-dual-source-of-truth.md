---
id: bug-0006
type: bug
title: naming-vocab-dual-source-of-truth
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0004]
related-spec: []
---

# `naming_vocab` 資料表是死資料,states/variants 詞彙實際由硬編碼的 `defaultVocab` 生效

## 問題描述

`store/Schema.hs` 建立並播種了 `naming_vocab` 表,註解宣稱「`AssetDB.Naming` 的
`NamingVocab` 從這裡讀 —— 加 domain 是插一列資料,不是改程式碼」,但**全庫沒有任何程式碼
查詢 `naming_vocab`**。CLI 的 cluster 指令一律使用 `core/Naming.hs` 內硬編碼的
`defaultVocab`。這不只是死碼問題:states/variants 詞彙目前有兩份定義,一旦漂移,
命名文法的 `parse ∘ render == id` 性質會在使用者看不見的地方失效(見 ADR-0004)。

## 重現方式 / 現況證據

- `store/src/AssetDB/Store/Schema.hs:277-285`:建表、播種、註解宣稱是讀取來源。
- `core/src/AssetDB/Naming.hs:202`:`defaultVocab` 是實際生效的硬編碼 Haskell `Set`。
- `cli/app/AssetDB/Cli/Cluster.hs:104,141`:cluster 指令直接使用 `defaultVocab`,
  未曾查詢資料庫。
- 對照:`ai/src/AssetDB/AI/Vocab.hs:59` 的 `loadVocab` 是「應該長成這樣」的正確模式
  ——分類詞彙表確實是從 DB 讀取的,`naming_vocab` 沒有對應實作。

## 根本原因

`naming_vocab` 表的設計意圖(讓詞彙表可用資料而非程式碼變更)從未被實作完成,註解描述的
是設計時的意圖而非目前的實際行為,兩者已經漂移。

## 影響範圍

- `store/src/AssetDB/Store/Schema.hs`
- `core/src/AssetDB/Naming.hs`
- `cli/app/AssetDB/Cli/Cluster.hs`

## 修正方案

二選一,由開發者決定:

- **方案 A(接上載入)**:仿照 `ai/Vocab.hs:59` 的 `loadVocab` 模式,新增
  `loadNamingVocab :: Connection -> IO NamingVocab`,`Naming.hs` 的呼叫端改為接受注入的
  `NamingVocab` 而非直接用 `defaultVocab`,`cli/Cluster.hs` 啟動時從 DB 載入後傳入。
- **方案 B(刪表改註解)**:若判斷詞彙表不需要做成可資料化,刪除 `naming_vocab` 表與
  其 migration 播種邏輯,並修正 `Schema.hs` 的註解使其符合實際行為(硬編碼於
  `core/Naming.hs`)。

## TodoList

- [ ] T1: 與開發者確認方案 A 或方案 B
- [ ] T2: 依決定的方案實作(接上載入 或 刪表改註解)
- [ ] T3: 更新 `docs/architecture.md` 與 ADR-0004 反映最終決策

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T2(方案 A) | `NamingSpec.loadNamingVocab 從 naming_vocab 表正確載入 states/variants` | 驗證載入邏輯 |
| T2(方案 A) | `ClusterSpec.cluster 指令使用注入的 NamingVocab 而非 defaultVocab` | 確認呼叫端真的改用載入值 |
| T2(方案 B) | `SchemaSpec.migration 不再建立 naming_vocab 表` | 確認表與播種邏輯已移除 |
| T3 | 人工確認 architecture.md / adr-0004 內容與實作一致 | 非自動化測試 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
