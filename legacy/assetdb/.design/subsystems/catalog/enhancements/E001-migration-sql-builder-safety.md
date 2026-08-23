---
id: E001
type: enhance
title: migration-sql-builder-safety
description: 改掉 migration 以字串拼接組 SQL 的脆弱寫法
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: [ADR-006]
related-feature: []
---

# `migration003` 以字串拼接組 SQL,無注入風險但寫法脆弱

## 現況說明

`store/src/AssetDB/Store/Schema.hs:698-727` 的 `upd`/`sub` 輔助函式以字串拼接方式組出
`ALTER TABLE` 等 SQL 陳述式。所有值都是編譯期字面值,**沒有 SQL 注入風險**,但任何人
日後在定義文字裡加一個單引號,migration 會在使用者機器上執行期才炸掉 —— 而 migration
的執行器(`store/Migrate.hs`)目前只支援 `execute_`(不支援參數化查詢),這是採用字串
拼接寫法的結構性原因。

## 修正方案

至少在 `upd`/`sub` 的定義處加上明確註解,警告未來修改者「這裡的值必須是不含單引號的
編譯期字面值」,並列出若要改用參數化查詢需要先擴充 migration 執行器支援
`execute`(帶參數版本)。是否值得為此擴充執行器由開發者權衡(目前只有 migration003
使用這個模式,規模小)。

## TodoList

- [x] T1: 為 `upd`/`sub` 加上警告註解,說明字面值限制與原因
- [x] T2: 評估是否擴充 `Migrate.hs` 支援參數化 SQL(視開發者決定,可能標記為不做)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `MigrateSpec.lit` 四條(包成字面值、單引號加倍、空字串、不動中文與換行) | 從「註解警告」改為可執行的跳脫函式,所以有了真正的測試標的 |
| T1 | `MigrateSpec.lit 含單引號的值真的能跑完一個 migration 並原樣讀回` | 端對端:值經過 `lit` 後跑完整個 `runMigrations` 再讀回 |
| T1 | `MigrateSpec.lit 同一個值直接拼進 SQL 則會失敗` | 反向斷言:鎖住這個函式擋掉的正是哪一種失敗 |
| T2 | `MigrateSpec.num 整數不經過字串形式` | 排序值改以 `Int` 傳遞的對應測試 |
| T2 | 執行器維持只支援 `execute_`,不改 `Migration` 型別 | 決定為不做,理由見實作備註 |

## 實作備註

**與原規格的偏差(經開發者確認)。** 原方案的 T1 是「加警告註解」,實作改為**加跳脫
輔助函式**:

- `AssetDB.Store.Migrate` 新增並匯出 `lit :: Text -> Query`(單引號加倍後包上引號)
  與 `num :: Int -> Query`。
- `Schema.hs` 的 `upd`/`sub` 改為經由這兩個函式組裝;`sub` 的最後一個參數從一段
  預先手寫好的 SQL `VALUES` 片段,改成 `[(Text, Text, Text, Int)]` 結構化資料,
  由 `sub` 自己組出 `VALUES` 子句。
- 排序值的型別從 `Text`(`"10"`)改為 `Int`(`10`)。

改用函式而非註解的理由:註解攔不住任何東西。原本的失敗模式是「有人在中文定義裡打了
一個單引號 → SQL 語法錯誤 → 要等 migration 在使用者機器上跑起來才炸」,跳脫之後這一
整類錯誤不可能發生,寫定義的人也不必記得任何規則。

`lit`/`num` 放在 `Migrate.hs` 而非 `Schema.hs`:它們屬於「撰寫 migration 的工具」,
與執行器同一層;放在這裡也讓 `MigrateSpec` 能直接測到,而不必為了測試把 `Schema.hs`
的內部函式匯出去。

**T2 的結論:不擴充執行器。** 加上 `lit` 之後,擴充 `Migration` 型別去支援參數化 SQL
的唯一剩餘好處只是形式上的整齊 —— 而代價是所有 migration 的型別、`Migrate.hs` 與
`MigrateSpec` 都要跟著動,並讓 `Schema.hs` 從「一疊可以直接讀成 SQL 的敘述」變成
「查詢 + 參數列的配對」,可讀性明顯變差。ADR-006 的「執行器刻意做得很小」維持不變,
理由已寫進 `Migrate.hs` 的「組裝 migration SQL」段落。

**驗證改寫沒有動到種子資料。** 這次改寫逐字重打了 70 列第二層分類的中英文定義,而
`SchemaSpec` 只斷言「定義非空」「葉節點 ≥ 60」等性質,不會抓到錯字。所以另外做了一次
逐位元組比對:分別以改寫前後的 `Schema.hs` 建庫,dump
`SELECT path, name, slug, definition, ai_scope, sort FROM categories ORDER BY path`
(81 列 = 11 個頂層 + 70 個葉節點),兩份輸出**完全相同**。

**量化結果**:

| | 改善前 | 改善後 |
|---|---|---|
| 需要人工遵守「不得含單引號」的字面值 | 約 290 個(9 個 `upd` × 3 + 70 列 × 3 + 參數) | 0 |
| `migration003` 組裝處的自動化測試 | 0 條 | 7 條(`MigrateSpec` 的 `lit` / `num`) |
| 產出的 SQL 語意 | — | 與改寫前逐位元組相同(81 列 dump 比對) |
