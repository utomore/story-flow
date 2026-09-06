---
id: P-016
description: 新劇情草稿經圖遍歷、FTS 候選撈取、LLM 逐對判斷,產出指到片段的衝突報告;context 是它的子流
status: draft
updated: 2026-09-06
---
# P-016-conflict-check:新劇情草稿經圖遍歷、FTS 候選撈取、LLM 逐對判斷,產出指到片段的衝突報告;context 是它的子流

## Brief
S5 的第一條里程碑,原 story-flow 的 conflict 接上統一索引。input 是新劇情草稿文字與本次讀取範圍;output 是指到片段的衝突報告。流向:圖遍歷(沿 contradicts / supersedes 找已知矛盾與被取代的設定)→ FTS 候選撈取(只以 status 為 canon 的節點為基準,經 P-002-search,候選集自然含 asset 節點)→ LLM 逐對判斷(經 P-017 的 LLM 門面)→ 報告按層排序、去重、附理由。`context` 是它的子流:前兩層不叫 LLM 的結果就是 context 命令的輸出。圖遍歷、候選合併、排序去重是純函數;LLM 呼叫是 `Llm` 效果,純解譯器回固定判斷。Stages 與 laws 待 S5 設計時寫;願望模組 `Aapms.Conflict.Check`、`Aapms.Conflict.Retrieval`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **三層依序:圖遍歷 → FTS 候選 → LLM 逐對,前兩層不叫 LLM。** 否決:全丟給 LLM。理由:ADR-007
- **候選撈取只以 canon 為基準。** 否決:draft 也比。理由:草稿不是設定
- **候選集含 asset 節點,但 S5 的判斷層只比文字;素材的視覺標註 S5 後才讀。** 否決:S5 就讀影像。理由:system.md 子系統劃分
- **ByRetrieval 的分數是 Double 不是 Maybe Double。** 否決:Maybe。理由:P-002 的分數恆正(ADR-016)

## 修訂記錄
無
