---
id: P-017
description: 素材經 GBNF 約束的地端 LLM 分類與標註,建議進暫存表,confirm 才寫入圖譜
status: draft
updated: 2026-09-06
---
# P-017-ai-classify:素材經 GBNF 約束的地端 LLM 分類與標註,建議進暫存表,confirm 才寫入圖譜

## Brief
O-3 的 M-9,原 assetdb 的 ai 與 story-flow 的 llm 合一。input 是素材(縮圖或檔名與既有標籤)與註冊表宣告的分類詞彙;output 是分類與標籤的建議,進暫存表,`confirm` 才寫回圖譜。流向:選出待標註的 asset → 組 prompt(JSON Schema 編譯成 GBNF 文法約束輸出)→ 打中樞 `[llm]` 指的 OpenAI 相容端點 → 解析輸出成建議 → 暫存;`confirm` / `reject` 走 P-008-graph-write 或丟棄;`suggest` / `status` / `query` 是同一組暫存的讀取。prompt 組裝、GBNF 編譯、輸出解析、建議合併是純函數;端點呼叫是 `Llm` 效果(與 P-016 共用同一個門面,一份客戶端);純解譯器回固定回應。Stages 與 laws 待 lawful:pipeline 設計時寫;願望模組 `Aapms.Ai.Classify`、`Aapms.Llm.Client`、`Aapms.Llm.Gbnf`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **一份 LLM 客戶端,conflict 第 3 層與兩種標註共用。** 否決:各自一份。理由:system.md 核心功能 8
- **建議走暫存表加人工閘門,confirm 才寫入;寫入的 source 是 ai:<model>。** 否決:直接寫。理由:決定建議是否採納是人的事
- **GBNF 由 JSON Schema 編譯,約束分類輸出;地端端點,per-machine 設定在中樞 `[llm]`。** 否決:自由文字再 parse。理由:ADR-021
- **`[llm]` 的鍵與語意屬本子系統,workspace 只原樣捧著。** 否決:workspace 解讀。理由:system.md 對外介面 6

## 修訂記錄
無
