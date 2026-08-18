---
id: enhance-0005
type: enhance
title: notes-input-handling-robustness
description: 強化 Notes 的輸入處理健壯性
status: done
created: 2026-08-16
updated: 2026-08-18
related-adr: []
related-spec: []
---

## `ingest/Notes.hs` 輸入處理健壯性強化(JSON 編碼、partial function、邊界值)

### 現況說明

`ingest/src/AssetDB/Ingest/Notes.hs` 有三個獨立但同屬「處理使用者/檔案輸入時不夠健壯」
主題的既有問題,合併在此文件一併處理:

1. **手刻 JSON 序列化轉義不完整**(`Notes.hs:113-115` `frontJson`):只跳脫雙引號,
   front matter 值含反斜線或控制字元時,會寫進不合法的 JSON 到
   `notes.front_matter_json`。`aeson` 已是既有相依,應直接 `encode (Map.fromList kvs)`。
2. **`tableOf` 是 partial function,吃使用者輸入**(`Notes.hs:146-153`):對未知實體型別
   直接 `error` 崩潰,而 `assetdb link --from foo:xxx` 的型別字串正是使用者在 CLI 打的。
   應改回 `Either`,在 CLI 層轉成友善錯誤訊息。同模組 `entityLinks:176` 把內部整數 id
   直接 `show` 回傳給呼叫端,與全系統「對外一律 ULID」的慣例不一致(見 ADR-0003),
   一併修正。
3. **Front matter 解析的 EOF 邊界值**(`Notes.hs:53-59`):解析假設 `\n---` 後恰有一個
   字元被 `T.drop 4` 吃掉,若 `---` 後直接是檔案結尾,會有偏移錯誤。

### 為什麼現在做

三者都是真實的正確性缺陷(非單純風格問題),但目前的資料量與使用模式下尚未觸發(前端
沒有輸入含反斜線的 front matter、CLI 使用者尚未打錯型別字串)。趁還沒被使用者實際撞到前
修正成本最低。

### 修正方案

1. `frontJson` 改用 `Data.Aeson.encode` 取代手刻字串拼接。
2. `tableOf` 回傳型別改為 `Either Text EntityType`(或等效),`entityLinks` 呼叫端改為
   對外一律回傳 ULID 而非內部整數 id。
3. Front matter 解析補上「`---` 後直接 EOF」的邊界測試與對應修正。

### TodoList

- [x] T1: `frontJson` 改用 aeson 的 `encode`
- [x] T2: `tableOf` 改為回傳 `Either`,CLI 層轉友善錯誤訊息
- [x] T3: `entityLinks` 對外改回傳 ULID
- [x] T4: 修正 front matter 解析的 EOF 邊界情況(經測試確認無此缺陷,見實作備註)

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `NotesSpec.frontJson 對含反斜線與控制字元的值產生合法 JSON` | 用 `Data.Aeson.decode` 驗證輸出可解析 |
| T2 | `NotesSpec.tableOf 對未知實體型別回傳 Left 而非崩潰` | 傳入非法型別字串,確認不再 `error` |
| T3 | `NotesSpec.entityLinks 回傳的 id 皆為合法 ULID 格式` | 檢查輸出格式 |
| T4 | `NotesSpec.parseFrontMatter 對 --- 後直接 EOF 的內容正確解析` | 邊界值輸入 |

### 實作備註

- T1:`frontJson` 抽為模組層函式並匯出(`Aeson.encode . Map.fromList`),
  重複 key 後者為準,與 JSON 物件語意一致。
- T2:`tableOf` 改回傳 `Either Text Text`(表名),連帶 `linkEntities` 改
  `IO (Either Text ())`、`entityLinks` 改 `IO (Either Text [...])` —— 找不到實體也
  從 `ioError` 改為 `Left`。`Cli/Notes.hs` 的 `runLink` 以 `either die pure` 轉成
  一句話錯誤訊息。
- T3:每條邊反查一次對端 ULID(邊數為個位數,不做五表 CASE 聯集);資料列損壞
  (未知型別或懸空 id)時退回原始整數,讓問題看得見而不是靜默消失。
- T4 **確認為誤報**:先寫邊界測試(`---` 直接 EOF、`---\n` 即 EOF)後直接通過 ——
  `T.drop 4` 恰好消耗 4 字元的分隔符 `\n---`,並無偏移錯誤。不改程式,
  保留兩條測試作回歸保護。
- 測試:`cabal test all` 全綠(assetdb-ingest-test 111 examples, 0 failures)。
