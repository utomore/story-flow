---
id: F003
type: feature
title: cluster-classification
description: 叢集層批次分類,產生分類與標籤建議
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002, F005]
related-adr: [ADR-007]
---

# F003: 叢集層批次分類

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

以**叢集**為單位做純文字分類(不看圖)。一個叢集是同一個素材包裡檔名結構相同的一群檔案,
整群共用同一個分類。6,393 筆資源塌縮成 132 個叢集,所以這一輪的成本是 132 次呼叫
(約七到八分鐘),而不是 6,238 次(約十小時)。**先跑這個**:人只要看 132 列就能判斷詞彙表
與提示詞好不好用,再決定要不要投入十小時的逐張標註。

同時提供整個子系統共用的**批次驅動機制**:記帳(`ai_runs`)、續跑、中斷語意、進度與 ETA。
這部分抽成獨立模組,是因為叢集分類與視覺標註若各自帶一份「逐筆提交、分類失敗、別吞掉
Ctrl-C、更新 run 列」的邏輯,那正好是最不該有兩個版本的那部分程式。

### 為什麼叢集清單是輸入而不是自己查

叢集是 ingest 即時算出來的,不是資料表裡的列(`name_clusters` 只存已確認的**命名規則**,
整個資料庫目前 6 列)。若在這裡自己算,`assetdb-ai` 就得相依 `assetdb-ingest`,而伺服器
相依 `assetdb-ai`——JuicyPixels、zip、`assetdb-archive` 會一路被拖進伺服器。讓呼叫端
(CLI,它本來就相依 ingest)把清單遞進來,這個接縫就消失了(ADR-007)。

## 落地位置

- `ai/src/AssetDB/AI/Classify.hs` —— `ClusterTarget`、`ClassifyOptions`、
  `defaultClassifyOptions`、`ClassifyReport`、`classifyClusters`。
- `ai/src/AssetDB/AI/Run.hs` —— `RunId`、`beginRun`、`bumpRun`、`finishRun`、`abortRun`、
  `guardedTry`、`StepOutcome`、`outcomeOf`、`Progress`、`renderProgress`、`driveItems`。
- 資料庫:寫 `ai_runs`(`kind='cluster'`)與 `ai_suggestions`(`target_type='cluster'`),
  讀 `categories`。

`ai_suggestions.target_key` 的編碼是 `"<pack_slug>|<shape>"`,與 F005 的 cluster 反查分支
必須用同一套。

## 對外行為

- `classifyClusters :: Connection -> Llm -> ClassifyOptions -> [ClusterTarget] -> IO ClassifyReport`。
- 工作選取:先濾掉成員數 `< coMinMembers` 的叢集,再**依成員數遞減排序**——五分鐘後喊停
  時,已涵蓋的是佔最多素材的那些叢集。非 `coForce` 時跳過已經有建議的
  `(pack_slug, shape)`(叢集沒有狀態欄,續跑靠 `hasSuggestionsFor`)。最後套 `coLimit`。
- 每批寫一列 `ai_runs`,帶 model 與 `promptVersion`,結束時是 `done` 或 `aborted`;進度每
  25 筆寫回,所以別的行程看得到一個**不是它啟動**的批次跑到哪裡。
- 值域收斂:信心值夾 0–1(NaN → 0);`category == "unknown"` 不產生分類建議;子分類以
  `isChildOf` 驗父子關係,不符時**保留父分類、丟棄子分類**並在理由欄註明被捨棄的值;每個
  facet × 語言的標籤取上限 4 個並去除空白項。
- 產出的建議形狀:`category`(父,以及通過驗證的子)× 1–2 筆,加上 `style`/`theme` ×
  `en`/`zh` 四組標籤。
- 失敗處理分三層:
  - `LlmTruncated` / `LlmEmptyContent` → **加大 token 預算重送一次**。推理吃光預算是改變
    請求才有機會解決的,所以重試發生在這一層,而不是傳輸層。
  - transient(服務掛了)→ `StepAbort`,整批短路,剩餘項目保持 pending,重跑就是續跑。
  - 其他 → `StepFailed`,只有這一筆算失敗。
- `guardedTry` 不吞掉 Ctrl-C:每筆 5.8 秒,中斷訊號落在 LLM 呼叫裡的機率接近 100%,被
  `SomeException` 接住之後迴圈會繼續跑下一筆,使用者按 6,238 次 Ctrl-C 也停不下來。
- `crSuggested` 反映 `upsertSuggestions` 回報的實際寫入筆數。
- `coOnProgress` 每一筆都被呼叫,取樣頻率由呼叫端決定;`renderProgress` 提供百分比與
  ETA(小時 / 分 / 秒三段)。

## 驗收依據

本功能沒有專屬的 spec 檔——`ai/test/` 下四個測試模組是 `LlmSpec`、`SchemaSpec`、
`PromptSpec`、`SuggestSpec`。叢集分類的驗收由以下三部分共同構成:

- **`ai/test/AssetDB/AI/LlmSpec.hs`** 覆蓋驅動器的失敗分類基礎:
  - `describe "isTransient"` 的「模型自己的輸出問題不是暫時性的」——測試註解直接指出這個
    區別決定驅動器是「跳過這一筆」還是「整批中止」,分錯的話服務中途掛掉會讓剩下幾千筆
    全被標成 failed,工作佇列就毀了。`outcomeOf` 就是這個判斷的唯一消費者。
  - `describe "fakeLlm"` 的「讓整條呼叫路徑不需要真的推論服務」——測試註解寫明這個接縫的
    存在意義是「十小時驅動器的每一條路徑都能在毫秒內測完」。
- **`ai/test/AssetDB/AI/PromptSpec.hs`** 覆蓋值域收斂的依據:
  - `describe "isChildOf"` 的「擋掉張冠李戴的子分類」——測試註解寫明「驅動器靠它做優雅
    降級:保留正確的粗分類,丟掉錯誤的細分類,而不是整筆作廢」。
  - `describe "vocab 與 schema 同源"` 三條,保證送進叢集 schema 的列舉不會漂移。
- **`ai/test/AssetDB/AI/SuggestSpec.hs`** 覆蓋寫入端:
  - `describe "hasSuggestionsFor"` 的「叢集層續跑靠它判斷做過沒有」——直接以
    `("cluster", "p|shape")` 為鍵驗證,也就是本功能的續跑條件。
  - `describe "upsertSuggestions"` 的「重跑是更新而不是堆疊」與「對已存在 pending 記錄的
    建議回傳實際寫入數而非輸入數」。

真實環境驗證(記錄於 ADR-007):對真實素材庫執行叢集層分類,**8 分鐘、零失敗**。
