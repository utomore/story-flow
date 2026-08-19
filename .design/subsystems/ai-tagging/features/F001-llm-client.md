---
id: F001
type: feature
title: llm-client
description: 本機 llama.cpp OpenAI 相容端點客戶端與分層失敗語意
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-007, ADR-001]
---

# F001: 本機推論端點客戶端與分層失敗語意

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

與本機 llama.cpp 的 OpenAI 相容端點之間的傳輸層。這一層**刻意不知道素材是什麼**:對外
只有一個接縫 `Endpoint -> Value -> IO (Either LlmError Value)`,所有有趣的邏輯(續跑、
失敗分類、詞彙約束)都活在上層,因此都能在沒有 GPU、沒有推論服務的情況下測完。

功能上要解決兩個反直覺的現實:

1. **這是推理模型。** 思考走 `message.reasoning_content`,而 `message.content` 在推理結束前
   是**空字串**。能不能關掉 thinking 取決於模型的 chat template,實測兩顆模型結果相反,
   所以它是設定(`lcThinking`)而不是寫死的假設,預設關閉。
2. **推理內容不可以當成回答。** 若在 `content` 為空時回頭讀 reasoning,等於把不受 grammar
   約束的散文餵進 JSON parser,再把產生的垃圾標籤寫進 `asset_tags`——而且看起來會像是
   成功了。所以「content 是空的」是一個**有型別的錯誤**,不是一個待補的空值。

另外提供**分層失敗語意**:`isTransient` 把錯誤分成「服務的問題」與「模型輸出的問題」,
上層驅動器據此決定「整批中止」還是「跳過這一筆」。這個區別攸關一個十小時批次在服務
中途死掉之後,工作佇列還在不在(ADR-007)。

## 落地位置

- `ai/src/AssetDB/AI/Llm.hs` —— 唯一實作。
- `ai/assetdb-ai.cabal` —— `http-client` / `http-types` 的相依只出現在這裡的需求上。

模組 export 分為六組:設定(`LlmConfig`、`defaultLlmConfig`)、控制代碼(`Llm`、`Endpoint`、
`newLlm`、`withLlm`、`fakeLlm`)、訊息(`Role`、`Part`、`Message`、`systemMsg`、`userText`、
`userTextImage`、`encodeMessage`)、請求與回應(`ChatRequest`、`defaultChatRequest`、
`encodeRequest`、`ChatReply`、`Usage`、`parseReply`、`replyPayload`)、呼叫(`chat`、
`chatJson`、`ping`)、錯誤(`LlmError`、`isTransient`、`renderLlmError`)。

## 對外行為

- `newLlm` 建一個 http-client 後端的控制代碼,**Manager 全程共用**——每次請求都建新的會漏
  socket 而且失去 keep-alive,在 6,238 次呼叫的量級上那不是微優化。
- `fakeLlm` 替換掉唯一的 I/O 接縫,是正式的測試契約。
- 預設值都是實測值而不是猜的:`lcMaxTokens = 1600`(實測下限 1200,留 33% 餘裕)、
  `lcTimeoutSecs = 120`(實測含圖 5.8 秒,20 倍餘裕,避免冷啟動被誤判成失敗)、
  `lcTemperature = 0.2`、`lcRetries = 2`、`lcThinking = False`。
- `replyPayload` 是「content 為空」這條不變量的唯一守門人:有內容就回內容;
  `finish_reason == "length"` → `LlmTruncated`(附已產生 token 數);其餘 → `LlmEmptyContent`
  (附 reasoning 前綴供診斷)。
- 傳輸層**只重試 `isTransient` 的錯誤**,退避是 `lcRetryBaseMs` 的 2 的次方倍。模型輸出
  問題在傳輸層重試等於再送一次一模一樣的請求,那些必須由上層改變請求之後才有意義。
- 非 2xx 以回應而不是例外的形式回來(`LlmHttpStatus`),分類乾淨得多。`HttpException` 粗分
  類即可,但**逾時必須與連線被拒分開**,因為前者可能只是模型還在載入。
- `encodeMessage` 在單一文字段落時輸出字串形式的 `content`,含圖時輸出 parts 陣列。兩種
  形式伺服器都收,維持字串形式是為了讓純文字請求的位元組與當初做效能量測時完全一致。
- `renderLlmError` 保證單行輸出,可直接存進 `blobs.ai_error`。
- `ping` 打 `GET /v1/models`,回傳第一個 model id。

## 驗收依據

測試檔:`ai/test/AssetDB/AI/LlmSpec.hs`(純單元測試,不需要推論服務)。

- `describe "replyPayload"`
  - 「有 content 就用 content」
  - 「content 空且 finish=length -> LlmTruncated」——這是這顆模型實際會發生的失敗。
  - 「content 空且 finish=stop -> LlmEmptyContent,並帶著推理片段」
  - 「**絕不**把 reasoning_content 當成回答」——餵入一段「推理裡剛好長得像 JSON 的東西」,
    斷言仍然是 `LlmEmptyContent`。這是本模組最重要的一條不變量。
  - 「只有空白的 content 也算空」
- `describe "isTransient"`
  - 「服務沒開與逾時是暫時性的」(`LlmUnavailable` / `LlmTimeout` / 5xx)
  - 「模型自己的輸出問題不是暫時性的」(`LlmTruncated` / `LlmEmptyContent` / `LlmBadJson` /
    4xx)——分錯的話,服務中途掛掉會讓剩下幾千筆全被標成 failed。
- `describe "parseReply"`
  - 「缺 reasoning_content 欄位不是錯誤」
  - 「choices 是空陣列 -> LlmBadEnvelope」
- `describe "encodeMessage"`
  - 「單一文字段落輸出字串形式的 content」
  - 「含圖時輸出 parts 陣列」
- `describe "fakeLlm"`
  - 「讓整條呼叫路徑不需要真的推論服務」——同一個 fake 同時服務 `ping` 與 `chat`。
- `describe "renderLlmError"`
  - 「壓成單行,可以直接存進 ai_error」

真實環境驗證(記錄於 ADR-007):指向死掉的 port 跑三筆,結果是 **0 筆被標成失敗**——
兩層失敗語意在真機上成立。
