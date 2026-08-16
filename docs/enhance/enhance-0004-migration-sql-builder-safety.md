---
id: enhance-0004
type: enhance
title: migration-sql-builder-safety
description: 改掉 migration 以字串拼接組 SQL 的脆弱寫法
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0006]
related-spec: []
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

- [ ] T1: 為 `upd`/`sub` 加上警告註解,說明字面值限制與原因
- [ ] T2: 評估是否擴充 `Migrate.hs` 支援參數化 SQL(視開發者決定,可能標記為不做)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | 人工 code review 確認註解已加上 | 純文件性修改,無需自動化測試 |
| T2 | 視決定結果而定(若執行則需對應 `MigrateSpec` 測試;若不做則此項標記關閉) | — |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
