---
id: P-022
description: 素材邏輯名稱的分段驗證、由右往左拆解與組回,詞彙表由外部注入
status: frozen
updated: 2026-09-06
---
# P-022-logical-name:素材邏輯名稱的分段驗證、由右往左拆解與組回,詞彙表由外部注入

## Brief
把 `<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]` 這條命名文法(ADR-019)變成可拆可組的資料。input 是一段候選名稱文字或一組手工建構的 `NameParts`,加上從 `naming.toml` 載入的 `NamingVocab`;output 是 `LogicalName`,或說得出哪裡不合的 `NameError`。流向:單段語法驗證 → 判斷尾段是不是三位序號 → 序號補零成分段 → 由右往左拆解成部位 → 依序拼回文字 → 對既有名稱做與型別無關的驗證 → 查詞彙表與長度上限後建成邏輯名稱。詞彙表不住程式碼:`kinds` 與 `states` 全部來自 `types/registry/naming.toml`,`domains` 刻意不比對。它是子流,P-014-name-cluster 的命名建議與 P-003-node-write 的寫入前驗證都引用它;`Segment` / `NameParts` / `NamingVocab` / `NameError` 這組純資料住 types 層的 `Aapms.Core.Name`,文法演算法住 pure 層的 `Aapms.Core.Naming`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `mkSegment :: Text -> Either NameError Segment` | 單段語法驗證,規則 `^[a-z0-9]+(-[a-z0-9]+)*$` | `Aapms.Core.Name` | types |
| 2 | `isIndexShaped :: Text -> Bool` | 尾段是不是剛好三位純數字,純語法不查表 | `Aapms.Core.Name` | types |
| 3 | `indexSegment :: Int -> Either NameError Segment` | 序號補零成三位分段 | `Aapms.Core.Name` | types |
| 4 | `parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts` | 由右往左剝:序號、state(只查 `nvStates`)、subject 與 variant | `Aapms.Core.Naming` | pure |
| 5 | `renderParts :: NameParts -> Either NameError Text` | 依序拼回 `kind_domain_subject` 加 variant、state、序號 | `Aapms.Core.Naming` | pure |
| 6 | `validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()` | 對既有名稱只做與型別無關的檢查 | `Aapms.Core.Naming` | pure |
| = | `mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName` | 純的整條:查詞彙表與長度上限後建成邏輯名稱 | `Aapms.Core.Naming` | pure |

## Laws
- LAW-1 [roundtrip] 拆解得開的名稱,依序拼回來就是原字串
  - forall v in NamingVocab, t in Text, parts in rights [parseLogicalName v t]
  - |- renderParts parts == Right t
- LAW-2 [roundtrip] 拆得開又在詞彙表內的名稱,建回去是同一個邏輯名稱
  - forall v in NamingVocab, t in Text, parts in rights [parseLogicalName v t]
  - given npKind parts in nvKinds v
  - |- mkLogicalName v parts == Right (LogicalName t)
- LAW-3 [invariant] kind 是封閉的:不在 nvKinds 內一律拒絕
  - forall v in NamingVocab, parts in NameParts
  - given notElem (npKind parts) (nvKinds v)
  - |- mkLogicalName v parts == Left (UnknownKindPrefix (segmentText (npKind parts)))
- LAW-4 [invariant] state 也是封閉的:手工建構的 state 不在 nvStates 內一律拒絕
  - forall v in NamingVocab, parts in NameParts, st in Segment
  - given npKind parts in nvKinds v and npState parts == Just st and notElem st (nvStates v)
  - |- mkLogicalName v parts == Left (UnknownState (segmentText st))
- LAW-5 [bound] 拼出來超過上限的組合一律拒絕,錯誤帶得出實際長度
  - forall v in NamingVocab, parts in NameParts, txt in rights [renderParts parts]
  - given npKind parts in nvKinds v and npState parts == Nothing and length txt > maxLogicalNameLength
  - |- mkLogicalName v parts == Left (TooLong (length txt) txt)
- LAW-6 [bound] 超過上限的輸入拆不出部位
  - forall v in NamingVocab, t in Text
  - given length t > maxLogicalNameLength
  - |- isLeft (parseLogicalName v t)
- LAW-7 [total] 任何文字丟給 parseLogicalName 都有值,不拋例外
  - forall v in NamingVocab, t in Text
  - |- total (parseLogicalName v t)
- LAW-8 [invariant] 主體不會被當成 state 剝掉,即使它剛好是一個 state 詞
  - forall v in NamingVocab, parts in NameParts, t in rights [renderParts parts], p2 in rights [parseLogicalName v t]
  - given npVariant parts == Nothing and npState parts == Nothing and npIndex parts == Nothing
  - |- npSubject p2 == npSubject parts
- LAW-9 [invariant] validateLogicalName 不看 TypeKey:型別專屬的檢查不在這裡
  - forall v in NamingVocab, k1 in TypeKey, k2 in TypeKey, nm in LogicalName
  - |- validateLogicalName v k1 nm == validateLogicalName v k2 nm
- LAW-10 [roundtrip] segmentText 是 mkSegment 的左逆函式
  - forall t in Text, s in rights [mkSegment t]
  - |- segmentText s == t
- LAW-11 [bound] 序號的定義域恰好是 0 到 999
  - forall n in Int
  - |- isRight (indexSegment n) == (n >= 0 and n <= 999)
- LAW-12 [relation] indexSegment 產出的分段一定長得像序號
  - forall n in Int, s in rights [indexSegment n]
  - |- isIndexShaped (segmentText s)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `parseLogicalName vocab "ui_gui_travel-book-frame_001"` | `npSubject` 為 `travel-book-frame`,variant 與 state 皆 `Nothing`,`npIndex` 為 `Just 1`;`renderParts` 回原字串 | LAW-1 |
| EX-2 | `parseLogicalName vocab "spr_char_hero_attack-01_up"` | `npVariant` 為 `Just "attack-01"`、`npState` 為 `Just "up"`、`npIndex` 為 `Nothing`;`mkLogicalName` 回 `Right (LogicalName "spr_char_hero_attack-01_up")` | LAW-1、LAW-2 |
| EX-3 | `parseLogicalName vocab "spr_char_up"`(單段主體剛好撞上 state 詞) | `npSubject` 為 `up`、`npState` 為 `Nothing`,而不是 `TooFewSegments` | LAW-8 |
| EX-4 | `parseLogicalName vocab "ui_gui_holo-book-alert_01a_000"`(序號的下界) | `npVariant` 為 `Just "01a"`、`npIndex` 為 `Just 0`;`renderParts` 補零回 `000` | LAW-1、LAW-11 |
| EX-5 | `parseLogicalName vocab "tex_ground_tileset-grass"`(剛好三段) | `npSubject` 為 `tileset-grass`,三個修飾部位全是 `Nothing` | LAW-1、LAW-8 |
| EX-6 | `parseLogicalName vocab "ui_gui"` | `Left (TooFewSegments 2 "ui_gui")` | LAW-7 |
| EX-7 | `parseLogicalName vocab "福岡廟宇"` | `Left (NoAsciiContent "福岡廟宇")`——不自作主張音譯 | LAW-7 |
| EX-8 | `parseLogicalName vocab` 餵 65 個 `a`(上限 64 的外一格) | `Left`;同一個字串 64 個 `a` 時錯誤不是 `TooLong` | LAW-6 |
| EX-9 | `parseLogicalName vocab "ui__gui_frame"` / `"UI_GUI_Travel-Book-Frame"` / `"ui_gui_travel book frame"` | 依序 `Left EmptySegment`、`Left (BadSegment …)`、`Left (BadSegment …)` | LAW-7 |
| EX-10 | `mkSegment "travel-book-frame"` / `mkSegment ""` / `mkSegment "-foo"` / `mkSegment "foo--bar"` | `Right`(`segmentText` 回原字串)/ `Left EmptySegment` / `Left (BadSegment "-foo")` / `Left (BadSegment "foo--bar")` | LAW-10 |
| EX-11 | 手工建構的 `NameParts`,`npKind` 為 `zzz` | `mkLogicalName` 回 `Left (UnknownKindPrefix "zzz")` | LAW-3 |
| EX-12 | 手工建構的 `NameParts`,`npKind` 為 `spr`、`npState` 為 `Just "zzz"` | `mkLogicalName` 回 `Left (UnknownState "zzz")`;換成 `Just "up"` 則 `Right` | LAW-4 |
| EX-13 | 手工建構的 `NameParts`:kind `ui`、domain `gui`、subject 為 61 個 `a`(拼出來 68 字元) | `mkLogicalName` 回 `Left (TooLong 68 …)` | LAW-5 |
| EX-14 | `indexSegment 0` / `indexSegment 999` / `indexSegment 1000` / `indexSegment (-1)` | `Right "000"` / `Right "999"` / `Left (IndexOutOfRange 1000)` / `Left (IndexOutOfRange (-1))`;前兩者 `isIndexShaped` 為 `True` | LAW-11、LAW-12 |
| EX-15 | `validateLogicalName vocab (TypeKey "asset-image") (LogicalName "ui_gui_travel-book-frame_001")`,再換成 `TypeKey "asset-audio"` | 兩次都是 `Right ()`,結果逐字相同 | LAW-9 |

## 決定
- **`parseLogicalName` 帶 `NamingVocab` 參數,拆解時只查一張表(`nvStates`)。** 否決:legacy 的兩張表(`nvStates` 加十七個具名 `nvVariants`)。理由:那張 variant 表正是 legacy 誤拒 `spr_char_hero_attack-01_up` 的原因——`attack-01` 不在具名清單裡,`isVariantShaped` 也不吃帶連字號的複合詞
- **`npVariant` 開放全收、`npState` 封閉必查表,兩個欄位語意分開。** 否決:合併成位置式的 `npModifiers` 清單。理由:2026-08-23 階段一閘門裁決語意區分要保留;開放的那一半不必為了對稱而被關起來
- **kind 的合法值由外部注入的 `nvKinds` 檢查,程式碼裡不得有 `defaultVocab`。** 否決:編譯期的封閉列舉 `KindPrefix`。理由:ADR-019 講的是「kind 有一張表」,不是「表寫死在程式碼裡」;三組詞彙全部住 `naming.toml`
- **domain 完全不比對任何詞彙表。** 否決:`nvDomains` 也強制。理由:ADR-019 明說加一種素材領域連資料都不必動;`nvDomains` 留著只是為了與 `nvKinds` 對稱、供未來的 CLI 提示用
- **剝 state 時有「剝掉後至少留得下一段給 subject」的 guard。** 否決:照文法四步驟字面實作、不加 guard。理由:沒有它,`spr_char_up` 這種主體剛好撞上 state 詞的合法名稱會被誤判成 `TooFewSegments`;兩種行為都自洽,選擇讓合法名稱通過(F002 ASM-4)
- **`mkLogicalName` 不拒絕被放進 `npVariant` 的 state 詞。** 否決:加一條「`npVariant` 不可為 `nvStates` 成員」的檢查。理由:契約承諾的是拆解後拼回拿到原字串,不是「拼回去再拆解拿回原始語意標籤」;`npVariant` 開放不查表是刻意設計,呼叫端把 state 詞放進去是自找的語意漂移(F002 ASM-5)
- **`validateLogicalName` 的 `TypeKey` 參數不參與判斷。** 否決:在這裡也做型別專屬的 `name_kinds` 檢查。理由:那件事由 `checkMeta`(見 P-021-registry-build)承接且只回警告;同一件事不能一邊硬擋一邊只警告(F002 ASM-2)
- **`Segment` / `NameParts` / `NamingVocab` / `NameError` 住 types 層的 `Aapms.Core.Name`,文法演算法住 pure 層的 `Aapms.Core.Naming`。** 否決:資料與演算法同居一個模組。理由:註冊表宣告的 `tdNameKinds` 只需要那組資料,不該為此讓型別層依賴一個做推導的模組
- **名稱長度上限 64。** 否決:不設上限。理由:要留給專案端的路徑深度

## 修訂記錄
無
