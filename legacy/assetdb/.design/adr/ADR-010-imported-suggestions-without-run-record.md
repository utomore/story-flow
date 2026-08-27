---
id: ADR-010
type: adr
title: imported-suggestions-without-run-record
description: 外部匯入的 AI 建議不寫 ai_runs 批次紀錄,run_id 為 NULL
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-010: 外部匯入的建議不留批次紀錄,`run_id` 為 NULL

## 狀態(Status)

Accepted(2026-08-23)。由 ai-tagging 的「建議匯入」feature(`assetdb ai suggest import`)
的設計討論促成。

## 背景(Context)

`ai_suggestions` 原本只有一種來源:本機 LLM 的 `ai classify` / `ai vision` 批次。每次批次在
`ai_runs` 寫一列(哪一種批次、哪個模型、哪個 prompt 版本、處理幾筆、失敗幾筆、有沒有中止),
每筆建議的 `run_id` 指回它。`ai status` 的「批次紀錄」段印的就是這張表。

「建議匯入」開了第二個來源:任何外部程序(Claude Code 在終端機裡看檔名與縮圖、一支腳本、
人手寫的檔案)把 JSONL 餵進暫存表,之後走同一條 `suggest confirm → ai apply` 閘門。

要不要也為匯入寫一列 `ai_runs`,看起來是個小問題,實際上卡在 schema:

- `ai_runs.kind` 的 `CHECK (kind IN ('cluster','vision','query'))` 寫在表定義裡。SQLite 改
  CHECK 只能**整張表重建**。
- `ai_suggestions.run_id` 對 `ai_runs` 有 `ON DELETE SET NULL` 外鍵。`foreign_keys=ON` 下
  `DROP TABLE ai_runs` 會先隱式 DELETE,外鍵動作跟著觸發 —— **現有 1,397 筆建議的
  `run_id` 會被洗成 NULL**,為了記錄新來源把舊來源弄丟。
- 正規解法是 SQLite 文件的 12 步重建:交易外 `PRAGMA foreign_keys=OFF` → 重建 →
  `foreign_key_check` → 開回來。但 catalog 的 migration 執行器是「每個 migration 各自包在
  一個交易裡」,PRAGMA 進不了交易 —— 執行器得多一個「這個 migration 要關外鍵」的開關,
  那是 catalog Level 2 契約(`Migration` DTO)的變動。

一個「多准一種 kind」的需求,會變成跨 catalog / ai-tagging / delivery 的工程。

## 決策(Decision)

**匯入的建議不寫 `ai_runs`,`run_id` 為 NULL。** schema 一個字不動。

代價講清楚:

- `ai status` 的「批次紀錄」看不到匯入。
- 事後分不出一筆建議是本機模型給的、還是外部匯入的。建議本身、確認、套用、進索引,
  全部照常。

接受這個代價的理由:目前是單人工作室、建議只有兩個來源,「這個標籤是誰給的」要到很久以後
才會成為真正的問題;而 `rationale` 欄本來就會留下措辭線索。

## 考慮過的替代方案(Alternatives Considered)

- **加 migration 005 重建 `ai_runs`,`kind` 多准 `'import'`**:正規做法。放棄的理由見背景 ——
  得先擴充 migration 執行器支援交易外關外鍵,scope 從一個 feature 膨脹成三個子系統。
- **原地改 migration 003 的 CHECK + 對唯一的實體資料庫做一次性手術**:程式碼只改一行、
  schema 版本不變,測試用的新庫自然拿到新形狀;現實中那顆唯一的 `assetdb.sqlite` 由人手動
  做「關外鍵 → 重建 → 檢查 → 開回」。**這是目前最便宜的可行路徑**,沒採用只是因為決定了
  連紀錄都不留。它的前提是「世界上只有一顆資料庫且碰得到」;有第二顆就失效。
- **把來源塞進 `rationale` 前綴**(如 `[import:claude-code] …`):零 schema 變動就能溯源。
  放棄的理由是把結構化資訊藏進自由文字,`ai status` 仍然看不到,而且會跟模型真正的理由混在
  同一欄。

## 影響(Consequences)

- `ai-tagging/design.md` 對外契約 §5 的匯入介面,其 `run_id` 語意明寫為 NULL;契約卡的
  「明確不做」包含「不寫 `ai_runs`」。
- **未來要補上溯源時的路徑**(任一種,依當時有幾顆資料庫決定):
  1. **仍只有一顆庫**:原地改 `migration003` 的 `ai_runs.kind` CHECK 加 `'import'`;對實體庫
     先備份,再以 `PRAGMA foreign_keys=OFF` 重建 `ai_runs`(建新表 → `INSERT … SELECT` →
     `DROP` 舊表 → `ALTER … RENAME` → 重建 `ai_runs_kind_idx` → `PRAGMA foreign_key_check`
     必須為空)→ `foreign_keys=ON`。然後讓匯入寫一列 `kind='import'`、`model` 記來源標籤。
  2. **已有多顆庫**:catalog 的 `Migration` DTO 加「交易外關外鍵」開關(執行器在交易前後
     切 PRAGMA、交易內最後跑 `foreign_key_check`),以 migration 005 做上述重建。這是跨
     子系統的優化,走 `G-E` 文檔。
- 無論哪條路,`ai_suggestions.run_id` 已經允許 NULL(`ON DELETE SET NULL` 本來就需要),
  既有的匯入建議不必回填。
