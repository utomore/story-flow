---
id: F006
type: feature
title: nl-query-planning
description: 自然語句查詢規劃,推論服務離線時降級為字面搜尋
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002]
related-adr: [ADR-007]
---

# F006: 自然語句查詢規劃與離線降級

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

把一句自然語言翻成素材庫的搜尋條件:關鍵字清單(中英混合)+ 最相關的主分類 + 一句理解
說明。

**這是備援,不是主力。** 中文搜尋的主力是離線寫進索引的中文標籤(F004):那條路零延遲、
零 LLM,推論服務關掉也照樣運作(ADR-007)。這裡處理的是主力路徑處理不好的東西——整句
自然語言,例如「我想要藍色的魔法藥水圖示」,其中「我想要」不該進全文搜尋。

每次呼叫約 3 秒,所以這**不能**綁在打字上,只能是一個明確的動作。

## 落地位置

- `ai/src/AssetDB/AI/Query.hs` —— `QueryPlan`、`planQuery`。整個模組只有這兩個 export,
  是本子系統最小的一個。
- 提示詞與 schema 在 `ai/src/AssetDB/AI/Prompt.hs`(`querySystem` / `queryUser` /
  `querySchema` / `QueryVerdict`,見 F002)。
- 資料庫:只讀 `categories`(載入詞彙表)。**不寫任何表**——連 `ai_runs` 都不寫。

## 對外行為

- `planQuery :: Connection -> Llm -> Text -> IO (Either LlmError QueryPlan)`。
- 空白輸入直接回傳空計畫(`Right (QueryPlan [] Nothing "")`),**不打推論服務**。
- 關鍵字去除空白項並取上限 8。
- `category == "unknown"` 轉成 `Nothing`,而不是把字串 `"unknown"` 傳下去——呼叫端不必知道
  哨兵值。
- `qpExplain` 帶回模型對這句查詢的理解說明,供介面顯示。
- **回傳 `Left` 時呼叫端應該降級成字面搜尋,而不是顯示錯誤。** 既有的全文搜尋本來就能處理
  中文(CJK 索引),把它呈現成失敗是錯的。CLI 的實作就是這樣:印一行警告,然後說明「降級
  為字面搜尋:<原句>」。
- 送給模型的提示詞明確要求:使用者說中文時**中英文關鍵字都要給**(素材的原始檔名是英文,
  但庫裡也有 AI 產生的中文標籤,兩邊都要搜),而且不要把「我想要」「幫我找」這種話寫進
  關鍵字。
- 本功能**不執行搜尋**,只產生條件;搜尋由 catalog 的檢索介面負責。

## 驗收依據

本功能沒有專屬的 spec 檔——`ai/test/` 下四個測試模組是 `LlmSpec`、`SchemaSpec`、
`PromptSpec`、`SuggestSpec`。查詢規劃的驗收由以下兩部分構成:

- **`ai/test/AssetDB/AI/PromptSpec.hs`**
  - `describe "查詢翻譯"` 的「要求中英文都給」——直接對 `querySystem` 的輸出做字串斷言,
    註解寫明理由:「檔名是英文,AI 標籤是中文,兩邊都要搜才會完整」。這是本功能唯一的
    專屬測試案例。
  - `describe "vocab 與 schema 同源"` 三條——`querySchema` 的 `category` 列舉與提示詞同樣
    出自同一個 `Vocab`,所以漂移不可能發生。
- **`ai/test/AssetDB/AI/LlmSpec.hs`**
  - `describe "fakeLlm"` 的「讓整條呼叫路徑不需要真的推論服務」——同一個 fake 回傳
    `Left (LlmUnavailable ...)`,正是本功能降級路徑的觸發條件。
  - `describe "isTransient"` 的「服務沒開與逾時是暫時性的」與 `describe "renderLlmError"`
    的「壓成單行」——呼叫端據此印出降級警告。

`ai_runs.kind` 的 CHECK 含 `'query'`(catalog schema),但本功能目前不寫 run 列;那是保留給
日後要記錄查詢用量時用的。
