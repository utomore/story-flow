---
id: F004
type: feature
title: vision-tagging
description: 逐份內容的視覺標註批次,以縮圖產生中英文搜尋標籤
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002, F005]
related-adr: [ADR-007, ADR-002]
---

# F004: 逐份內容視覺標註批次

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

送縮圖給模型,取回內容標籤。**這是讓中文搜尋真的能用的那一步**:素材庫裡 27 個商業素材包
的檔名、包名、作者全是英文,語料裡一個中文字都沒有。CJK 索引本身是好的(搜「金門」搜得到
中文命名的參考包),缺的只是中文文本——這裡把它補上。

產出四種東西:主分類、子分類、`subject`(這張圖畫的是什麼,中英各一句名詞詞組)、
搜尋標籤(中英各最多 4 個)。

### 工作單位是 blob,不是 asset

內容定址(ADR-002)。6,397 筆資源指向 6,238 份唯一內容,同一份免費字型被三個廠商各附一次
也只算一次。

### 不變量:絕不跨 LLM 呼叫持有 transaction

每筆呼叫約 5.8 秒,而 `busy_timeout` 是 5 秒。握著寫鎖跨過一次推論,同時在跑的伺服器就會
寫入失敗。LLM 呼叫一律在 transaction 之外;每筆的建議寫入與狀態更新在呼叫**之後**、在
同一個 transaction 內提交,資料庫本身就是斷點續跑的檢查點。

## 落地位置

- `ai/src/AssetDB/AI/Vision.hs` —— `VisionOptions`、`defaultVisionOptions`、`VisionJob`、
  `VisionReport`、`selectJobs`、`visionTagBlobs`。
- `ai/src/AssetDB/AI/Image.hs` —— `dataUrl`、`loadThumbDataUrl`,並 re-export catalog
  `AssetDB.PathText` 的 `ThumbSize` / `thumbPath`。
- `ai/src/AssetDB/AI/Run.hs` —— 共用的批次驅動機制(見 F003)。
- 資料庫:讀 `blobs` / `assets` / `packs` / `categories`,寫 `ai_runs`(`kind='vision'`)、
  `ai_suggestions`(`target_type='blob'`,key 是 sha256)、`blobs.ai_status` / `ai_error` /
  `ai_seen_at`。

`ThumbSize` 與 `thumbPath` 的**唯一實作在 catalog**(enhance-0012)——與 ingest(縮圖產生
端)、server(讀取端)共用同一套定址規則,不再各寫一份。`AssetDB.AI.Image` 只 re-export
以維持既有 API;core 本來就是 ai 的相依,不會把 JuicyPixels 或 zip 拖進來。

## 對外行為

- `selectJobs :: Connection -> VisionOptions -> IO [VisionJob]` 對外公開,理由是呼叫端要能
  先報「共 N 份唯一內容待標註」再開跑,而那必須與批次實際會做的那一批完全一致——所以是
  同一個函式,不是一個平行的計數查詢。
- 工作選取條件:`blobs.kind='image'` ∧ `thumb_status='ok'` ∧ 素材 `status='active'` ∧
  素材包 `kind='packs'`,並依 `voForce` / `voRetryFailed` 決定重跑範圍(預設只做
  `ai_status='pending'`)。`GROUP BY sha256` 保證一份內容只做一次;
  **`ORDER BY sha256` 是刻意的**:續跑後的順序完全一致,所以出問題時可以二分搜尋定位。
- 縮圖尺寸由 `voLarge` 決定(`Thumb512` / `Thumb128`),路徑由 catalog 的定址規則導出。
- **找不到縮圖不是錯誤,是還沒做**:`blobs.ai_status='skipped'` 加上理由,回報
  `StepSkipped`,並由呼叫端提示先跑縮圖產生指令。這與 `thumb_status` 的 `na`(永遠不會有
  縮圖)是不同的意思,所以用不同的字。
- 成功時:值域收斂(信心值夾 0–1、子分類驗父子、每語言標籤上限 4 個並去空白、`subject`
  空字串不產生建議)→ 寫入建議 → `blobs.ai_status='ok'`。
- 標籤上限 4 個是為了壓住同義詞爆炸:`tags` 的唯一鍵是 `(facet, name)`,「藥水」「魔藥」
  「藥劑」會變成三列。三列都能命中不是壞事,但索引會被灌水,所以在這裡收斂。
- 失敗處理:
  - `LlmTruncated` / `LlmEmptyContent` → 加大 token 預算重送一次。
  - 非 transient → `blobs.ai_status='failed'` + 單行錯誤訊息(存進 `ai_error`)。
  - transient → **完全不動狀態欄**。這一筆保持 pending,佇列才留得住,重跑就是續跑。
- `dataUrl` 全程走 strict `ByteString` / `Text`,不經過 `String`:512px PNG 約 40–120 KB,
  base64 後 55–160 KB,中途經過 `String` 是每張約兩百萬個 cons cell,乘以 6,238 次呼叫。
  只有一個實作,就不會有人不小心寫出第二種。
- 視覺提示詞交代「**以圖為準**,檔名經常是無意義的流水號」,並明示中文標籤是中文搜尋
  唯一的入口。送給模型的分類列舉不含 `audio` / `level` / `reference`(見 F002)。

## 驗收依據

本功能沒有專屬的 spec 檔——`ai/test/` 下四個測試模組是 `LlmSpec`、`SchemaSpec`、
`PromptSpec`、`SuggestSpec`。視覺標註的驗收由以下三部分共同構成:

- **`ai/test/AssetDB/AI/LlmSpec.hs`**
  - `describe "encodeMessage"` 的「含圖時輸出 parts 陣列」——這是本功能唯一會用到的訊息
    形狀(`userTextImage` + `data:` URL),斷言 parts 陣列剛好兩個元素。
  - `describe "isTransient"` 兩條,支撐「中止時不動狀態欄」與「失敗時標 failed」的分岔。
  - `describe "replyPayload"` 的「**絕不**把 reasoning_content 當成回答」——若破功,不受
    grammar 約束的散文會被解析成標籤寫進 `asset_tags`,而且看起來像是成功了。
- **`ai/test/AssetDB/AI/PromptSpec.hs`**
  - `describe "vocab 與 schema 同源"` 的「視覺標註的列舉裡沒有 audio / level / reference」
    與「prompt 裡出現的每個頂層分類都在 schema 的列舉裡」——後者的註解記下了實測後果:
    只給列舉、沒給定義時,一張牛排圖示被分類成 audio。
  - `describe "gui 與 icon 的分野"` 的「兩邊的定義都寫了指向對方的反例」——1,693 筆介面
    外框對上約一千筆物品圖示,是這個素材庫裡模型最容易混淆的一對。
  - `describe "isChildOf"` 兩條,支撐子分類不符時的優雅降級。
- **`ai/test/AssetDB/AI/SuggestSpec.hs`** —— 本功能產出的建議一律以 sha256 為鍵,而
  `describe "applySuggestions"` 的「以 sha256 為鍵的建議會扇出到所有指向該內容的素材」
  正是這種建議能真的進到索引的保證;`describe "驗收:中文標籤讓中文搜尋活起來"` 的
  「套用 + reindexFts 之後搜得到」是**整個 AI 功能的驗收點**(見 F005)。

真實環境驗證(記錄於 ADR-007):對真實素材庫執行逐份視覺標註,約 **8 小時**批次,
5,315 份內容產生約六萬筆建議。
