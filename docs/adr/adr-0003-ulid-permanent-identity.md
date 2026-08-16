---
id: adr-0003
type: adr
title: ulid-permanent-identity
description: 以 ULID 作永久識別碼,名稱與路徑皆可自由變更
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0003: 用 ULID 作永久識別碼,邏輯名稱與檔案路徑皆可自由變更

## 狀態(Status)

Accepted。實作於 `core/src/AssetDB/Id.hs`,48-bit 時間戳 + 80-bit 亂數,Crockford Base32
(排除易混淆的 I/L/O/U)。

## 背景(Context)

命名策略決定「不改廠商原檔名」,但系統內部需要正規化命名(`logical_name`)給人看與給
遊戲載入器當 key。若用 `logical_name` 或檔案路徑本身當主鍵,任何改名或搬移都會連鎖打斷
專案 manifest、收藏集、分類等所有引用它的地方。

## 決策(Decision)

- 每個資源(`assets`)、壓縮檔(`archives`)、素材包(`packs`)都有一個 `ulid` 欄位作為
  **永久識別碼**。專案 manifest、`links` 關聯圖、收藏集全部引用 ULID,不引用名稱或路徑。
- `logical_name` 是另一個獨立欄位,給人看的正規化名稱,可為 NULL(未命名前),改名不影響
  任何既有引用。
- 選 ULID 而非自增整數 ID 或 UUID v4:時間戳前綴讓 ID 依建立順序可排序(除錯與稽核時
  方便按時間瀏覽),且產生不需要中央協調(離線批次匯入友善),字母表排除易混淆字元
  降低人工抄寫出錯率。

## 考慮過的替代方案(Alternatives Considered)

- **自增整數 ID 對外曝露**:内部 `assets.id INTEGER PRIMARY KEY` 仍存在(SQLite 效能考量),
  但明確約定「對外一律 ULID」——已知有一處違反此約定(`ingest/Notes.hs` 的 `entityLinks`
  把內部整數 id 直接 `show` 回傳,見 `docs/enhance/`),屬於待修正的邊界洩漏,不是設計本身。
- **UUID v4**:不具時間排序性,且沒有 Crockford Base32 的抄寫容錯,已放棄。
- **檔案路徑作為主鍵**:被明確排除 —— 重構(ADR-0002)本身就會大量搬移路徑,若路徑是
  主鍵,重構會變成一場全庫外鍵重寫。

## 影響(Consequences)

- 所有跨表關聯與外部引用(專案 manifest、`Assets.hs` 產生的常數)都以 ULID 或由 ULID
  推導的穩定 key 為準,改名、搬移、重新分類都不會造成引用斷裂。
- ULID 對人不友善(不像 slug 一樣可讀),因此每個實體同時需要維護一個人類可讀的
  `logical_name`/`slug`,兩者需要保持同步且不可混用做主鍵,這是複雜度的來源之一,
  但被視為必要的權衡。
