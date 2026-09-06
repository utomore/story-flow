---
id: ADR-014
type: adr
title: single-short-id-scheme
description: 全系統一律 <prefix>-<8 hex> 短 id,取代 assetdb 的 ULID
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-014: 全系統單一短 id

## 狀態(Status)

accepted。supersedes assetdb ADR-003(ULID 永久身分)。

## 背景(Context)

| | assetdb | story-flow |
|---|---|---|
| 格式 | ULID,26 字元 Crockford base32 | `<prefix>-<8 hex>` |
| 產生 | 時間 + 亂數,不需查資料庫 | FNV-1a 64-bit 取低 32 位,store 以 salt 遞增重試保證唯一 |
| 例 | `01JD8XQ2M7K9E3R5T6Y8W0ABCD` | `ent-7f3b2a91` |

統一 `Meta`(ADR-012)之後 `id` 只能有一種格式。決定性的因素不是遷移成本,是**檔案是真相**
(ADR-002、ADR-013)的前提:id 出現在 Markdown 的標題屬性裡,`## 外貌 {#ent-7f3b2a91}`,作者要
看得懂、要能手寫、要能在編輯器裡搜尋。`## panel_book.png {#01JD8XQ2M7K9E3R5T6Y8W0ABCD}` 做不到
這三件事。

ULID 在 assetdb 的對外契約份量比報告估的小:遊戲端的 `Assets.hs` 以**邏輯名稱**為 key
(`AssetKey "ui_gui_travel-book-frame_001"`),完全看不到 ULID;ULID 只出現在 `manifest.json` 的
一個欄位,而 manifest 本來就要升 schema 2(S6)重新產生。

## 決策(Decision)

**一、全系統一律 `<prefix>-<8 hex>`。** prefix 表節點種類:`ent` / `ast` / `pck` / `lvl` / `nod` /
`vlt` / `prj`。產生方式沿用 story-flow:FNV-1a 64-bit 對「內容 + 時間 + salt」雜湊取低 32 位;
`core` 零 IO,時間由呼叫端提供;唯一性由持有索引的 `store` 以 salt 遞增重試保證。

**二、唯一性範圍是 vault。** 跨 vault 以 `<vault-id>:<id>` 定址。跨 vault `ATTACH` 查詢不會撞鍵,
因為結果每筆帶 vault 欄位(ADR-017)。

**三、asset 的對外身分仍是邏輯名稱。** `name` 全域唯一(命名文法,ADR-019;原 assetdb ADR-004)、是
`Assets.hs` 的 key;`ast-` id 是圖譜內部的節點身分,兩者並存、職責不同:`name` 可能在命名決策
改變時更動,`id` 從掃描進來那一刻起不變。

**四、S2 匯出時重發 id。** 舊 ULID 不保留為欄位——它沒有任何讀者。對帳舊 manifest 以 `sha256` +
`name`,不以 ULID。

## 考慮過的替代方案(Alternatives Considered)

- **全面 ULID**:產生時不需查資料庫(短 id 要靠 store 重試,是一條 IO 相依);時間可排序。
  放棄的理由見背景——可手寫、可讀是真相載體的硬需求,26 字元塞進標題不合格;story 側五份格式
  文件與測試都要改。
- **短 id 為主、ULID 留成 legacy 欄位**:對帳舊資料多一個依據。放棄的理由是它會永久多一個沒人讀
  的欄位,而 `sha256` + `name` 已經足夠對帳。
- **短 id 但 asset 用 12 hex**:降低 6,783 筆同 vault 的碰撞機率。放棄的理由是 32 位空間對萬級
  節點的碰撞由 salt 重試處理,不需要破壞格式一致性;真的撞到重試一次就過。

## 影響(Consequences)

**正面**

- 一種 id、一份產生器、一份驗證器;Markdown 標題在兩種 vault 裡長得一樣
- `Assets.hs` 與遊戲端零影響

**負面 / 成本**

- 6,783 筆資源、27 個 pack 一次性重編號(隨 S2 匯出一起發生,不另付成本)
- 舊 `manifest.json` 的 `id` 欄位作廢;已產出的專案在 S6 升 schema 2 時重新產生
- 短 id 的產生需要索引在場(重試保證唯一);`core` 提供純函式、`store` 負責重試,這個分工已在
  story-flow 運作
- assetdb ADR-012 選 `ATTACH` 的理由之一「ULID 跨 vault 不撞鍵」失效,改由「結果帶 vault 欄位」
  承擔(ADR-017)
