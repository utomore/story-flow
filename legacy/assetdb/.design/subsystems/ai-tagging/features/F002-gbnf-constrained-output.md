---
id: F002
type: feature
title: gbnf-constrained-output
description: JSON Schema 編譯成 GBNF 文法、詞彙表與 prompt 組裝
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001]
related-adr: [ADR-007, ADR-008]
---

# F002: GBNF 約束輸出、受控詞彙表與提示詞組裝

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

讓模型**物理上吐不出**詞彙表外的分類值。llama.cpp 會把 `response_format.json_schema` 編譯
成 GBNF,所以 schema 不只是驗證,而是**產生時的文法約束**。這是本子系統對抗「模型選錯
分類」最有效的一道防線,遠強過在 prompt 裡請求模型守規矩(ADR-007)。

三個模組組成一份完整的合約:

- **schema 建構積木**:封閉列舉、全欄位必填、不允許額外欄位、陣列帶上限。
- **受控詞彙表**:從 `categories` 表載入,同一列資料同時產生**給模型的列舉**與**寫進
  prompt 的定義**。
- **提示詞組裝**:prompt 與其對應 schema 放在同一個模組,因為它們是同一份合約的兩半。

### 為什麼詞彙表從資料庫載,而不是寫死在 Haskell 裡

餵給模型的列舉與寫進 prompt 的定義必須永遠一致。實測過不一致的下場:只給列舉、沒給定義
時,一張 512px 的牛排圖示被分類成 `audio`。若列舉寫在 Haskell、定義寫在 SQL 種子裡,兩者
就會漂移,而你只能寫一個漂移偵測測試去追;從同一列資料同時產生兩者,**漂移不可能發生**
——這比測試更徹底。

這個理由**不**適用於命名文法的 states / variants:那批詞決定既有名稱怎麼被解析,事後改
資料等於改變舊資料的意義,所以它留在 catalog 的命名模組裡跟著程式碼版本走。分類詞彙沒有
這個性質——改了定義只影響**之後**的推論。

## 落地位置

- `ai/src/AssetDB/AI/Schema.hs` —— `responseFormat`、`objectOf`、`stringOf`、`enumOf`、
  `arrayOf`、`numberOf`。純函式。
- `ai/src/AssetDB/AI/Vocab.hs` —— `Category`、`Vocab`、`loadVocab`、`visionScopes`、
  `topSlugs`、`leafPaths`、`childrenOf`、`isChildOf`、`lookupPath`。
- `ai/src/AssetDB/AI/Prompt.hs` —— `promptVersion`,以及三組(叢集 / 視覺 / 查詢)的
  `*System` / `*User` / `*Schema` 與對應的 `*Info` / `*Verdict`。全部純函式,沒有 IO。

資料來源是 catalog 的 `categories` 表(`path`、`name`、`slug`、`definition`、`ai_scope`、
`sort`),`path` 是物化路徑(如 `icon` 或 `icon/potion`)——**這是合約,rowid 不是**。

## 對外行為

- `objectOf` 產出的物件**全欄位必填**且 `additionalProperties = False`。刻意不提供選填欄位:
  選填讓模型可以靜靜地略過難的那一個,而略過的正好都是我們最想要的欄位。答不出來時用
  列舉裡的 `unknown` 表達——那是明示的,可以被統計、可以被過濾。
- `arrayOf` 一律帶上限。沒有它,模型會把同一個概念用五種說法各寫一遍,而每一個都會變成
  `tags` 表裡的一列。
- `numberOf` 產出 0–1 的數值,但 **GBNF 對 `minimum` / `maximum` 的約束並不可靠**,所以
  呼叫端必須在解碼後自己夾範圍。
- `visionScopes = ["any","image"]`,因此 `audio` / `level` / `reference` **不在**送給模型的
  列舉裡——錯誤答案在 GBNF 文法層無法被表達,比在 prompt 裡拜託模型不要選有效得多。
- `isChildOf` 是驅動器**優雅降級**的依據:模型答對 `category` 卻給了不屬於它的
  `subcategory` 時,保留粗的、丟掉細的,而不是整筆作廢。一個錯誤的葉節點不該賠掉一個
  正確的頂層。
- 每一份 schema 的第一欄都是 `analysis`(判斷理由),讓模型在承諾一個值之前先想過——由於
  推理內容走的是另一條不受約束的通道,這是唯一可靠的帶內思考。實際輸出順序取決於
  llama.cpp 怎麼走訪 schema,而 aeson 不保證序列化順序,所以這裡不賭順序被保留:名稱選
  `analysis` 是因為它在**字母序**與**宣告序**下都排在 `category` 之前,兩種假設下都成立。
- 三組 `*Verdict` 的 `FromJSON` 對**每一個欄位**都有預設值:缺欄位不是解析失敗,分類欄
  缺席時退回 `unknown`,清單欄缺席時退回空清單。
- `promptVersion` 存進 `ai_runs.prompt_ver`,而每一筆建議都指回它的 run——於是「這個標籤是
  哪個模型、用哪一版提示詞產生的」永遠是一次 join 的距離,不必為此加寬最熱的那張表。
  改動提示詞時手動加一。
- 提示詞內容上的兩個設計:叢集提示詞明確區分 `style_tags`(畫風與規格)與 `theme_tags`
  (題材),並交代「個別檔案畫的是什麼**不要**寫在這裡」;視覺提示詞則強調「**以圖為準**,
  檔名經常是無意義的流水號」與「中文標籤是中文搜尋唯一的入口」。

## 驗收依據

測試檔:`ai/test/AssetDB/AI/SchemaSpec.hs` 與 `ai/test/AssetDB/AI/PromptSpec.hs`
(後者以 in-memory store 的種子詞彙表為輸入)。

`SchemaSpec.hs`:

- `describe "objectOf"` — 「每個欄位都是必填」、「不允許額外欄位」(開著
  `additionalProperties` 等於允許模型自己發明欄位,而它發明的欄位不會有人讀)。
- `describe "enumOf"` — 「把列舉值原封不動放進 schema」:這串值就是 GBNF 的字面選項。
- `describe "arrayOf"` — 「帶上限」。
- `describe "responseFormat"` — 「是 llama.cpp 認得的 json_schema 形狀」。
- `describe "analysis 欄位的排序假設"` — 「analysis 在字母序上早於 category」,把那個假設
  釘住。

`PromptSpec.hs`:

- `describe "vocab 與 schema 同源"`
  - 「prompt 裡出現的每個頂層分類都在 schema 的列舉裡」——**這是整個設計最重要的不變量**,
    測試註解直接記下了不一致的實測後果(牛排圖示被分類成 audio)。
  - 「視覺標註的列舉裡沒有 audio / level / reference」
  - 「列舉一定含 unknown」
- `describe "gui 與 icon 的分野"` — 「兩邊的定義都寫了指向對方的反例」。1,693 筆介面外框
  對上約一千筆物品圖示,是這個素材庫裡模型最容易混淆的一對;定義沒寫反例,分錯的代價
  就是全庫最大的 facet 失效。
- `describe "isChildOf"` — 「認得真正的父子關係」、「擋掉張冠李戴的子分類」。
- `describe "查詢翻譯"` — 「要求中英文都給」。
- `describe "promptVersion"` — 「不是空的」。
