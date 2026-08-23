---
id: F005
type: feature
title: suggestion-store-apply
description: 建議暫存表的讀寫、人工確認與套用扇出到索引
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-007, ADR-002]
---

# F005: 建議暫存、人工確認與套用扇出

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

`ai_suggestions` 的讀寫,以及**套用**這一步。推論輸出一律先進暫存表待人工確認,確認後才
寫入 `tags` / `asset_tags` / `asset_categories`——與命名規則的確認閘門同一個模式。

這個模組**沒有 HTTP 相依,而且是刻意的**:確認與套用必須在推論服務關掉的情況下照常運作。
昨天跑出來的建議,今天不該因為模型沒開就看不了。

### 套用這一步是整個功能的收斂點

全文索引是靠 `asset_tags` 的 `GROUP_CONCAT` 餵養的,而它**以 asset_id 連接**。視覺標註產生
的建議卻是以 sha256 為鍵(內容定址,一份內容只算一次)。中間這道扇出如果漏掉,
`assets_fts.tags` 會維持空字串——於是「功能正常」與「靜默地什麼都沒做」在外觀上完全一樣。
套用的測試因此是整個 AI 功能的驗收點。

## 落地位置

- `ai/src/AssetDB/AI/Suggest.hs` —— 唯一實作。export 分三組:
  - 型別與 smart constructor:`Suggestion`、`StoredSuggestion`、`SuggestFilter`、
    `emptyFilter`、`tagSuggestion`、`categorySuggestion`、`subjectSuggestion`
  - 讀寫與決定:`upsertSuggestions`、`listSuggestions`、`countSuggestions`、
    `decideSuggestions`、`hasSuggestionsFor`
  - 套用:`ApplyOptions`、`defaultApplyOptions`、`ApplyReport`、`applySuggestions`
- 資料庫:`ai_suggestions`(讀寫)、`tags` / `asset_tags` / `asset_categories`(僅套用時寫)、
  `assets` / `packs` / `categories`(唯讀)。

`ai_suggestions` 的唯一鍵是 `(target_type, target_key, field, value, lang)`;
`target_key` 的編碼:`blob` → sha256、`cluster` → `"<pack_slug>|<shape>"`、
`asset` → `assets.ulid`、`pack` → `packs.slug`。

## 對外行為

### 寫入

- `upsertSuggestions :: Connection -> Maybe Int -> [Suggestion] -> IO Int`。重跑是**更新**而
  不是堆疊。已經被人決定過的列(`confirmed` / `rejected` / `applied`)不會被覆蓋回
  `pending`——那會把人的判斷洗掉。
- 回傳的是**實際寫入的筆數**(新增或更新),不是輸入清單的長度。被上述條件擋下的列不算。
  呼叫端把這個數字報給使用者,使用者拿它判斷要不要重跑,所以它必須誠實(enhance-0001)。
- `hasSuggestionsFor` 是叢集層續跑的唯一依據:叢集是即時算出來的,沒有可以標記狀態的
  資料列。
- `field='tag'` 時 `facet` 必填,其餘必須是 `Nothing`——資料庫有 CHECK 把關,三個 smart
  constructor 保證這件事不必由呼叫端記得。

### 讀取與決定

- `listSuggestions` 支援狀態 / 目標類型 / 欄位 / 最低信心值的過濾與分頁,排序穩定
  (`target_type, target_key, field, value`)。
- `countSuggestions` 回傳各狀態的計數。
- `decideSuggestions :: Connection -> [Int] -> Text -> Text -> IO Int` 確認或退回,回傳實際
  更動的列數;只有 `pending` 的列會被更動。

### 套用

- `applySuggestions :: Connection -> ApplyOptions -> IO ApplyReport`,只讀 `status='confirmed'`
  的列。
- **`aoResolveCluster :: Text -> IO [Int]` 是注入點,也是本子系統邊界最關鍵的設計。**
  輸入 `"<pack_slug>|<shape>"`,輸出這一群的 asset id。由呼叫端注入,因為叢集是 ingest 即時
  算出來的,而讓 `assetdb-ai` 相依 `assetdb-ingest` 會把 JuicyPixels 與 zip 一路拖進伺服器。
  `defaultApplyOptions` 的解析器回傳空清單,那些建議因此被計入 `arUnresolved` 而**不是靜靜
  消失**。
- 扇出規則:
  - `blob` → 所有 `sha256` 相同且 active 的素材。**內容定址的後果**:同一份內容可能被多筆
    asset 指向(不同素材包裡的同一個檔案),全部都要拿到標籤。這一步漏掉,索引就餵不飽。
  - `asset` → `assets.ulid`;`pack` → `packs.slug`;`cluster` → 注入的解析器。
- 同一個 `(target_type, target_key)` 在單次套用內**只解析一次**(結果快取)。一個叢集標
  8 個標籤很常見,而套用只寫 `tags` / `asset_tags` / `asset_categories`、不動 `assets`,所以
  解析結果在單次套用內不會變,不需要 `O(建議數 × 目標大小)` 的重複掃描(enhance-0001)。
- 寫入語意:`field='tag'` 補 `tags(name, facet)` 再寫 `asset_tags`;`field='category'` 寫
  `asset_categories`;`field='subject'` **不進 `asset_tags`**——它是一句描述,不是搜尋詞,
  留在暫存表裡供人參考與日後命名使用。
- 一律 `source='inferred'` + `INSERT OR IGNORE`。來源強弱是 `manual > rule > inferred`,
  所以重跑永遠不會覆蓋人工修正過的標籤。**絕不用 `REPLACE`。**
- `aoDryRun = True` 時計數照算但不寫入,也不把建議推進 `applied`。
- `arUnresolved` 記錄目標解析不到任何素材的建議數——不是錯誤,但要講出來。
- **呼叫端在這之後必須跑 `reindexFts`**,否則全文索引不會知道有新標籤。本模組不重建索引,
  因為它不擁有索引。

## 驗收依據

測試檔:`ai/test/AssetDB/AI/SuggestSpec.hs`。測試種子刻意讓**兩筆 asset 指向同一份內容**
(`magic-potions` 與 `rpg-icons` 兩包裡的同一個 `potion01.png`)——那正是扇出必須存在的理由。
檔頭註解直接寫明:這個檔案裡有一個測試是整個 AI 功能的驗收點,因為失敗的樣子與成功的樣子
在外觀上一模一樣。

- `describe "upsertSuggestions"`
  - 「寫入後看得到」
  - 「重跑是更新而不是堆疊」
  - 「對已存在 pending 記錄的建議回傳實際寫入數而非輸入數」(enhance-0001 T1)——先送 2 筆
    得 2,把其中一筆決定成 `rejected` 之後再送 3 筆,得 2 而不是 3。
  - 「不會把已決定的建議洗回 pending」
- `describe "hasSuggestionsFor"`
  - 「叢集層續跑靠它判斷做過沒有」
- `describe "applySuggestions"`
  - 「只套用 confirmed 的」
  - 「以 sha256 為鍵的建議會扇出到所有指向該內容的素材」——`arTags` 是 2,不是 1。
  - 「dry-run 不寫入」
  - 「重跑不會覆蓋人工標籤」——預先塞一筆 `source='manual'`,套用後 source 仍是 `manual`。
  - 「分類寫進 asset_categories」
  - 「同一目標的多筆建議只解析一次,結果與逐筆解析一致」(enhance-0001 T2)——注入一個會
    計次的解析器,兩筆同叢集建議只讓它被呼叫 **1 次**,而 `arTags` 仍是 2。
  - 「叢集目標需要呼叫端注入解析器」——未注入時 `arUnresolved` 是 1,注入後 `arTags` 是 1。
- `describe "驗收:中文標籤讓中文搜尋活起來"`
  - 「套用前搜不到」——這是這個素材庫今天的處境:CJK 索引是好的,但語料裡沒有中文。
  - **「套用 + reindexFts 之後搜得到」——這一條是整個 AI 功能的驗收點。** 註解寫明:
    `reindexFts` 這一步漏掉的話,上面全部照樣「成功」,而搜尋照樣零筆。斷言兩筆
    `potion01.png` 都被命中(扇出 + 索引 + 搜尋三段全通)。
  - 「英文標籤同樣進得了索引」

`docs/enhance/enhance-0001-ai-suggest-return-value-and-perf.md` 記錄:`cabal test all` 全綠
(`assetdb-ai-test` 42 examples, 0 failures)。
