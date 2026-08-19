---
id: ADR-006
type: adr
title: versioned-migrations-no-down-migration
description: Schema 只做正向 migration,不提供反向遷移
status: accepted
created: 2026-08-16
updated: 2026-08-19
---

# ADR-006: Schema 用版本追蹤的正向 Migration,不提供 Down-Migration

## 狀態(Status)

Accepted。實作於 `store/src/AssetDB/Store/Migrate.hs`,目前 3 個 migration(初始 schema、
notes 唯一索引、AI 分類欄位/表)。

## 背景(Context)

單人工具,單一部署環境(工作室的本機機器),資料量小(數千筆),資料庫是可完整備份的
單一檔案。多數 down-migration 的價值(快速回滾生產環境)在這個部署形態下不成立 ——
回復的正確手段是還原檔案備份,而不是執行反向 SQL。

## 決策(Decision)

- 每個 migration 有遞增版本號,記錄於 `schema_migrations` 表,執行器逐一比對版本、
  只往前跑,交易邊界是「每個 migration 一個 transaction」。
- **不寫 down-migration**。復原路徑是檔案系統層級的備份還原(`.assetdb/backups/`),
  不是 SQL 層級的反向操作。
- 錯誤情境明確分類:`MigrationsOutOfOrder`(資料庫版本序與程式碼認知的序不符)、
  `DatabaseNewerThanCode`(資料庫版本比目前程式碼認得的還新,防止舊版程式碼誤改新資料庫)。
- Migration 3(AI 分類欄位/表)原以字串拼接組出 `ALTER TABLE` 等 SQL(值全是編譯期
  字面值,無注入風險,但寫法脆弱),已由 `catalog/E001` 改為型別安全的建構方式。

## 考慮過的替代方案(Alternatives Considered)

- **提供 down-migration**:被評估後放棄 —— 額外維護成本與單人單機部署的實際回滾需求
  不成比例,檔案備份已經是更可靠的復原手段(migration 若寫錯,down-migration 也可能寫錯,
  雙重風險)。
- **用成熟的 migration 框架(如 `persistent`/`squeal` 的遷移工具)**:考量到 schema 變更
  頻率低、專案規模小,手寫版本追蹤執行器的認知負擔更低,已採用手寫方案。

## 影響(Consequences)

- 任何 schema 回滾都必須靠備份還原,若備份策略(`.assetdb/backups/`)失效或未及時執行,
  錯誤的 migration 上線後沒有程式化的退路。
- `DatabaseNewerThanCode` 這類保護機制的正確性依賴版本號被誠實遞增且不重複使用 ——
  這是純靠開發紀律維持的不變量,沒有額外的自動化檢查。
