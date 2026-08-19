---
id: B001
type: bugfix
title: naming-vocab-dual-source-of-truth
description: naming_vocab 表是死資料,詞彙實際由硬編碼生效
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: [ADR-004]
related-feature: []
---

# `naming_vocab` 資料表是死資料,states/variants 詞彙實際由硬編碼的 `defaultVocab` 生效

## 問題描述

`store/Schema.hs` 建立並播種了 `naming_vocab` 表,註解宣稱「`AssetDB.Naming` 的
`NamingVocab` 從這裡讀 —— 加 domain 是插一列資料,不是改程式碼」,但**全庫沒有任何程式碼
查詢 `naming_vocab`**。CLI 的 cluster 指令一律使用 `core/Naming.hs` 內硬編碼的
`defaultVocab`。這不只是死碼問題:states/variants 詞彙目前有兩份定義,一旦漂移,
命名文法的 `parse ∘ render == id` 性質會在使用者看不見的地方失效(見 ADR-004)。

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

- [x] T1: 與開發者確認方案 A 或方案 B → **選定方案 B(刪表改註解)**
- [x] T2: 依決定的方案實作(刪表改註解)
- [x] T3: 更新 `.design/system.md` 與 ADR-004 反映最終決策

## 1-to-1 測試對照表

| Todo | 測試 | 說明 | 結果 |
|------|------|------|------|
| T2(方案 B) | `SchemaSpec.migration 004 之後不再有 naming_vocab 表` | 確認表已移除 | ✅ |
| T2(方案 B) | `SchemaSpec.建出預期的表` | 期望清單移除 `naming_vocab` | ✅ |
| T2(方案 B) | `MigrateSpec`(既有,依 `schemaVersion` 動態斷言) | 遷移鏈長度與版本序列自動涵蓋 004 | ✅ |
| T3 | 人工確認 architecture.md / ADR-004 內容與實作一致 | 非自動化測試 | ✅ |

方案 A 的兩條測試不適用,已刪除。

## 選定方案與理由(T1)

選 **方案 B**。方案 A 被否決的理由不只是「工作量較大」,而是它做出來是錯的:

1. **ADR-004 的原始訴求已經達成。** `parseLogicalName` 根本不驗證 `domain`,任何合法
   `Segment` 都收 —— 「加一種素材領域不用改程式碼」是既成事實,`facet='domain'` 那批
   從來就不是把關者,只是一份沒人讀的清單。
2. **`state` / `variant` 不是設定,是文法。** 它們決定 `spr_item_potion_blue` 的 `blue`
   是變體還是主體的一部分。做成執行期可 INSERT,等於讓使用者事後改變**已經寫進**
   `assets.logical_name` 的舊名字的解析語意,直接動搖 `parse ∘ render == id`。
3. **方案 A 消不掉 `defaultVocab`。** `validateLogicalName`(`FromJSON LogicalName` 用它)
   是純函數,拿不到 `Connection`。接上載入只會把「一份真相 + 一張死表」變成
   「兩份都活著的真相」,比現況更糟。

## 修法摘要

- 新增 `store` migration 004(`DROP TABLE IF EXISTS naming_vocab`)。**不動 migration 001**
  —— 它已經在真實資料庫上跑過,ADR-006 定的規則是只加不改。代價是新庫會先建表播種再
  刪掉,換到的是 schema 歷史逐字誠實。
- `Schema.hs` 的 `naming_vocab` 建表註解與 `seeds` 註解改為說明「此表已於 004 移除、
  原註解從未成立」。
- `core/Naming.hs`:`NamingVocab` 的 haddock 改寫,說明這批詞刻意不資料化的理由;
  `npDomain` 與 `npState` 的註解改為符合實際行為。
- `ai/Vocab.hs`:補上「分類詞彙可資料化、命名文法詞彙不可」的分界,原本那段把兩者
  相提並論的註解已修正。
- `.design/system.md` 命名文法段落與 ADR-004 的「考慮過的替代方案」/「影響」同步更新。

## 實作備註

無偏差。與規格唯一的差異是測試對照表刪去方案 A 的兩條(方案未採用),並補上
`MigrateSpec` 一列 —— 該檔既有測試以 `schemaVersion` 動態斷言,新增 migration 後
自動涵蓋版本序列 `[1..4]`,不需另寫。
