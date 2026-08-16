---
id: adr-0004
type: adr
title: file-naming-grammar
description: 統一檔案命名文法,並以檔名叢集推論輔助命名
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

## ADR-0004: 統一命名文法 + 檔名叢集推論降低人工決策量

### 狀態(Status)

Accepted。已實作並通過 89 個測試,含 `parse ∘ render == id` 的 QuickCheck 性質測試
(`core/src/AssetDB/Naming.hs`),輸入取自真實素材庫。

### 背景(Context)

素材庫命名完全繼承自各廠商,至少五種互不相容的風格並存(`UI_TravelBook_Frame01a.png` /
`Blue Potion 2.png` / `idle_down.png` / `potion10.png` / `00.png`)。若靠人工逐檔命名,
5,211 個檔案的決策量不可行;若靠自動音譯或猜測,會產生沒人查得到的名稱。

同一包內的檔名一定內部一致 —— 這是可以利用的結構。

### 決策(Decision)

- **命名文法**:`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,規則
  `^[a-z0-9]+(_[a-z0-9-]+)*$`,最長 64 字元(`maxLogicalNameLength`,見架構文件資料結構章節)、
  全域唯一、純 ASCII。`kind` 是封閉列舉(驅動格式處理器與資料夾),`domain` 是開放受控詞彙
  ——每加一種素材領域不應該要求改程式碼。
- **四層命名規則解析,最具體者勝**:① `pack.toml` 包內宣告(人工,每包一次)→
  ② 結構啟發式(認得 `Sprites/`/`Preview/`/`Aseprite/` 等通用資料夾慣例,免費)→
  ③ **檔名叢集推論**(核心機制,見下)→ ④ 人工覆寫(`source='manual'`,永遠最優先)。
- **檔名叢集推論**:把檔名 tokenize 成「形狀」(如 `WORD_CamelWord_CamelWord{NN}{a}`)後分群,
  一包 300 個檔案通常塌縮成 3–5 個叢集,系統對每個叢集提出一次解析方案並即時預覽,人按
  一次確認即套用整群。實測 **5,211 個檔案的決策量降到約 100 次確認**(6 次確認命名 1,653 筆)。
  DB 存的是「確認過的規則」而非結果,廠商出更新版時自動重套。
- **拒絕音譯**:純中文檔名(如 `福岡廟宇.HEIC`)一律拒絕自動命名,要求人工命名
  (`NoAsciiContent` 錯誤)—— 自動音譯出來的名稱沒人查得到,不如當場攔下。

### 考慮過的替代方案(Alternatives Considered)

- **逐檔人工命名**:5,211 個檔案不可行,已放棄。
- **自動音譯/翻譯中文檔名**:會產生語意正確但沒人搜得到的英文名稱,已放棄,改為要求
  人工命名。
- **`domain` 詞彙表寫死封閉列舉**:違反「加一種素材領域不用改程式碼」的原則,已放棄。
  最終做法比「受控詞彙表」更徹底:`parseLogicalName` **根本不比對 domain**,任何合法分段
  都收,所以加一種素材領域連資料都不必動。
- **把 `state` / `variant` 詞彙表資料化(`naming_vocab` 資料表)**:已放棄,該表於 store
  migration 004 移除。它自 migration 001 起就存在並播了種,但從未被任何程式碼查詢,實際
  生效的一直是 `core/Naming.hs` 的 `defaultVocab`。放棄的理由不是「沒做完」,而是做完是
  錯的:這批詞決定 `spr_item_potion_blue` 的 `blue` 是變體還是主體,也就是決定
  `parse ∘ render == id` 的結果。事後 INSERT 一個新 state,會改變**已經寫進**
  `assets.logical_name` 的舊名字的解析語意 —— 文法該跟著程式碼版本走。另外
  `validateLogicalName` 是純函數(`FromJSON LogicalName` 用它),拿不到 `Connection`,
  接上載入也消不掉 `defaultVocab`,只會讓兩份真相都活著。詳見 `docs/bugfix/bug-0006-*`。

### 影響(Consequences)

- 命名文法是全系統穩定的公開介面(遊戲專案的 `Assets.hs` 常數命名依賴它),任何文法變更
  都需要走 migration 等級的相容性評估,不能隨意調整正則規則。
- 叢集推論的品質取決於「同包內檔名內部一致」這個假設,若廠商刻意混用多種命名風格於
  同一包,叢集會碎片化,退化為接近逐檔確認 —— 目前素材庫尚未遇到此情況。
- `state` / `variant` 詞彙的增修是**程式碼變更**(`core/Naming.hs` 的 `defaultVocab`),
  需要重新編譯,而且必須連帶評估既有 `logical_name` 的解析結果是否改變。這是刻意付出的
  代價,換到的是「同一個名字在任何時候都解析成同一組部位」。
