---
id: F002
type: feature
title: naming-grammar
description: 檔案命名文法的建構、渲染、解析與驗證,以及廠商文字的正規化基本操作
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001]
related-adr: [ADR-004]
---

# F002: 命名文法

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

實作統一命名規範的**文法**:`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`
(如 `ui_gui_travel-book-frame_01a`、`spr_char_hero_attack-01_up`)。前綴在最前面是為了讓
字典序自動分堆;索引數字補零到三位是為了讓 `_002` 排在 `_010` 前面;全小寫純 ASCII
是 macOS / Linux / Windows 三者唯一的安全交集(ADR-004)。

同時提供給 ingest 使用的文字正規化基本操作:把任意廠商檔名壓成合法分段、依 camelCase
邊界切開、剝離結尾數字。全部是純函數,沒有 IO。

## 落地位置

- `core/src/AssetDB/Naming.hs` —— 全部型別、詞彙表、建構/解析、數字部位與正規化操作
- `core/src/AssetDB/Types.hs` —— 提供 `KindPrefix` 與 `parseTextEnum`(名稱首段的封閉列舉)
- `store/src/AssetDB/Store/Schema.hs` —— migration 004 移除 `naming_vocab` 表,
  確立 `defaultVocab` 為唯一真相
- 相關紀錄:`.design/subsystems/catalog/bugfixes/B001-naming-vocab-dual-source-of-truth.md`

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Naming` 一節:

- `Segment`(抽象,已保證 `^[a-z0-9]+(-[a-z0-9]+)*$`)與 `segmentText` / `mkSegment`。
  拿到 `Segment` 就代表已驗證過,下游無法繞過也不需要再檢查。
- `LogicalName`(抽象)與 `logicalNameText`;`FromJSON LogicalName` 走 `validateLogicalName`,
  所以不合法的名稱在 JSON 解碼當下就失敗。
- `NameParts` 的六個部位:`npKind`(封閉列舉)、`npDomain`(**開放,不比對任何詞彙表**)、
  `npSubject`、`npVariant`、`npState`、`npIndex`。
- `NameError` 九個建構子與 `renderNameError`(繁體中文訊息)。
- `NamingVocab(nvStates, nvVariants)` 與 `defaultVocab`。做成參數是為了讓測試餵自己的
  詞彙表,**不是**為了從資料庫載入 —— 這些字決定 `spr_item_potion_blue` 的 `blue` 是變體
  還是主體的一部分,是文法而非設定,該跟著程式碼版本走。
- `mkLogicalName vocab parts`:組出名稱**並檢查它解析得回來**。拒絕主體長得像修飾詞
  (`SubjectLooksLikeModifier`),否則 `spr_char_idle` 會被解析成「有 state 沒 subject」。
  長度超過 `maxLogicalNameLength`(64)回報 `TooLong`。
- `parseLogicalName vocab txt`:由右往左剝 index → state → variant,剩下的就是主體。
  各部位形狀互斥,所以缺項組合能正確處理。
- `validateLogicalName`:只檢查形狀,不拆解;給資料庫欄位驗證與 JSON 解碼用(以 `defaultVocab`)。
- `renderParts`:`NameParts` → `Text`。
- 數字部位:`variantFromNumber`(0..99,補零兩位)、`indexSegment`(0..999,補零三位)、
  `isVariantShaped`(兩位數字 + 可選單一小寫字母)、`isIndexShaped`(剛好三位數字)。
- 給 ingest 的基本操作:`normalizeSegment`(標點當分隔符,撇號**刪除**而非轉分隔符,
  非 ASCII 全部丟棄 → 純中文名稱回報 `NoAsciiContent`,刻意要求人工命名而不自作主張音譯)、
  `splitCamel`、`splitTrailingNumber`。

不變量:對所有 `mkLogicalName` 接受的組合,`parseLogicalName ∘ renderParts` 還原原值。

## 驗收依據

- `core/test/AssetDB/NamingSpec.hs`(檔頭註明:單元測試的輸入**全部取自真實素材庫**)
  - 「splitCamel」表格案例:`切開 "TravelBook"`、`切開 "UIIcon"`、`切開 "TXPlayer"`、
    `切開 "Frame01a"`(字母數字邊界刻意不切)
  - 「splitTrailingNumber」表格案例:`剝離 "Frame01a"`、`剝離 "potion10"`、
    `剝離 "rune100"`、`剝離 "00"`、`剝離 "Frames"`(結尾字母前不是數字則不算變體後綴)
  - 「normalizeSegment」:`純中文名稱回報 NoAsciiContent 而不是自作主張音譯`、
    `中英混合只保留 ASCII 部分`、`輸出永遠通過 mkSegment 的驗證`
  - 「數字部位的形狀互斥」:`variant 是兩位數字加可選字母`、`index 剛好三位數字`、
    `兩種形狀永不同時成立`、`variantFromNumber 補零到兩位,三位數拒絕`、
    `indexSegment 補零到三位`
  - 「mkLogicalName / parseLogicalName」:`組出計畫裡的實際目標名稱`、`拆得回來`、
    `缺項組合:有 state 沒 variant`、`缺項組合:有 variant 沒 state`、
    `主體含連字號時不會被誤拆`
  - 「拒絕不合法的名稱」:含 `主體長得像修飾詞時,建構就要擋下`
  - 「round-trip 性質」(QuickCheck):`任何 mkLogicalName 接受的組合都解析得回原樣`、
    `validateLogicalName 接受所有自己產生的名稱`
- `store/test/AssetDB/Store/SchemaSpec.hs`
  - 「資料表」:`migration 004 之後不再有 naming_vocab 表`(確認詞彙表單一真相)
