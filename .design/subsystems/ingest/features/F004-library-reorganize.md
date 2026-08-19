---
id: F004
type: feature
title: library-reorganize
description: 快照→計畫→執行→對帳→回退的素材庫結構搬遷機制
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F002, F003]
related-adr: [ADR-002]
---

# F004: 素材庫結構搬遷

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

把手工累積的素材庫重整成以來源(provenance)組織的結構:一個素材包 = 一個目錄 = 一個備份與溯源單位,目錄裡放廠商原始壓縮檔與 `pack.toml`。

```text
alchbees-assets/
├── library/
│   ├── packs/<vendor>/<slug>/     ← pack.toml + <廠商原始檔名>.zip
│   ├── reference/<slug>/
│   └── studio/
├── projects/
├── knowledge/
├── marketing/
└── .assetdb/
```

這個功能會搬動數 GB 的資料,所以整套設計都圍繞「可審核、可對帳、可回退」:

1. **快照是唯一的 IO 邊界。** 規劃所需的資料一次撈出來,之後的推導全部是純函數。「刪除清單是怎麼算出來的」因此可以在測試裡完整重現,而不是只能對著真實素材庫跑一次看結果。
2. **計畫是資料而不是動作。** 產生、檢視、審核、執行是四件事;混在一起就沒辦法在執行前看清楚。
3. **兩階段執行,兩個旗標。** 階段 A(建目錄、搬壓縮檔、寫 `pack.toml`)完全可回退,每一筆記入 `moves` 表;階段 B(刪除已證明覆蓋的散檔)不可回退,需要獨立旗標。綁在同一個指令裡等於讓可回退的部分被不可回退的部分綁架。
4. **對帳只重算壓縮檔本身的 SHA-256。** 檔案雜湊相同就代表裡面每一個位元組都相同,也就代表每一筆項目都完好——不需要重新解壓驗證。這把對帳成本從「重新解壓數 GB」降到「循序讀取數 GB」。對帳失敗就中止,而且**不執行任何刪除**。

### 散檔:一律保留

2026-08-09 的一次性搬遷已對真實素材庫執行完畢。當時的路徑規則(廠商前綴的刪除閘門、中文頂層資料夾對應)已於 enhance-0009 退役,規則本身留在 git 歷史裡。現行規劃器對散檔一律產生 `OpKeep`:再跑一次搬遷只會重組素材包,不會搬移或刪除任何散檔;即使加上刪除旗標也一樣。

`OpDelete` 型別與其執行器**保留為通用機制**——它對計畫是通用的,只是現行規劃器不會產生它。這也是為什麼刪除相關的行為(證據欄位、不可回退的警告、`moves` 記錄)仍然完整存在並受測。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Reorg.Snapshot` | `reorg/src/AssetDB/Reorg/Snapshot.hs` | 規劃所需資料的唯一 IO 邊界 |
| `AssetDB.Reorg.Plan` | `reorg/src/AssetDB/Reorg/Plan.hs` | 由快照推導計畫(純函數) |
| `AssetDB.Reorg.Render` | `reorg/src/AssetDB/Reorg/Render.hs` | 計畫的報告渲染(摘要 / 完整兩種詳盡度) |
| `AssetDB.Reorg.Execute` | `reorg/src/AssetDB/Reorg/Execute.hs` | 前置檢查、兩階段執行、雜湊對帳、批次稽核與回退 |
| 套件定義 | `reorg/assetdb-reorg.cabal` | exposed-modules;對 `assetdb-ingest` 的最小依賴 |

`reorg` 沒有繖形模組,呼叫端直接匯入各模組。對 `ingest` 的依賴刻意最小:雜湊入口(對帳)與壓縮副檔名清單(判斷哪些搬移需要對帳,enhance-0012)。`pack.toml` 的產生見 F003。

## 對外行為

- `loadSnapshot :: Store -> IO Snapshot` — 一次讀出素材包列、散檔列、與**內容覆蓋表**(項目 SHA-256 → 壓縮檔相對路徑)。覆蓋表存的是路徑而非布林:計畫要能說「這個檔案可以刪,因為它的內容存在於 X 壓縮檔裡」,只存一個集合的話計畫只能說「可以刪」,說不出憑什麼。同一份內容出現在多個壓縮檔時取字典序最小的那個——選哪一個不重要,重要的是**確定性**,否則審核過的計畫與實際執行的計畫可能不同。
- `buildPlan :: Text -> Text -> Snapshot -> Plan` — 純函數。輸出:目錄先建齊(執行器因此可以照順序跑而不必自己推導父目錄)、每個素材包一筆搬移 + 一筆 `pack.toml` 寫入、散檔一律 `OpKeep`,加上警告(仍是 `draft` 的素材包、沒有 vendor 的素材包)。
- `targetDirFor :: PackRow -> Text` — 商業素材包依 vendor 分組(vendor 永遠不變,而分類是多值且會被重新歸類的,那些屬於資料庫不屬於資料夾);參考資料與工作室自有各有自己的頂層目錄。vendor 缺失或 slug 化後為空時退回 `unknown`,不會產生空目錄名。**同一個函式**同時決定規劃時的目標路徑與執行時 `pack.toml` 的歸屬。
- `Op` 的五個建構子:建目錄、搬移(帶位元組數與理由)、寫入(帶理由)、刪除(帶 SHA-256 與**證據**壓縮檔)、保留(帶待決定的理由)。`OpKeep` 是計畫裡最重要的一類——沒有 `OpKeep` 的計畫代表工具自以為什麼都懂。
- `planStats` / `PlanStats` — 各類動作的筆數、搬移位元組數、釋出位元組數。
- `renderSummary` / `renderPlan Verbosity` — 摘要只有統計、警告與待人工決定的項目;完整版另有各節明細。統計數字取自**完整計畫**而非過濾後的子集:使用者必須立刻看到規模,而不是自己去開檔案才發現。大量刪除依「被哪個壓縮檔涵蓋」分組,只顯示數量與代表性樣本,完整清單留給 verbose。
- `applyPlan :: Store -> Snapshot -> ApplyOptions -> Plan -> IO ApplyReport`
  - **前置檢查**逐筆檢查搬移的四種狀態:來源在/目標不在 = 還沒做;來源不在/目標在 = 已做過,跳過;兩邊都不在 = 計畫過期或檔案遺失,**拒絕動作**;兩邊都在 = 曖昧狀態(可能上次中斷),**拒絕動作**。檢查對象是每一筆搬移的狀態而不是目錄的空滿,因為兩階段設計要求 apply 是冪等的——第二次跑時目標目錄當然非空,那是第一次跑的成果。
  - 搬移先試 rename(同磁碟區時是原子操作且瞬間完成),跨磁碟區失敗時退回複製。
  - 只有壓縮檔的搬移需要對帳(工作室自有檔案沒有雜湊紀錄,也不會觸發任何刪除)。
  - `aoDeleteCovered` 預設 `False`;對帳通過但未給旗標時明確告知「這個批次目前完全可回退」。
- `ApplyEvent` / `ApplyReport` — 事件是回呼,報告帶各類計數與 `arErrors`。
- `undoBatch :: Store -> FilePath -> FilePath -> Text -> (Text -> IO ()) -> IO (Int, [Text])` — 依 `moves` 表反序倒回搬移與寫入;含刪除的批次會明講刪除無法回退,其餘搬移仍會倒回去。
- `listBatches :: Store -> IO [(Text, Int, Text)]` — 尚未回退的批次、筆數與最早時間。

自行產生的檔案一律以 UTF-8 位元組寫出:走 locale 編碼會在 Windows 上**寫壞我們自己產生的檔案**,而 `pack.toml` 是要進版控、要被別的工具讀的。

## 驗收依據

- `reorg/test/AssetDB/Reorg/PlanSpec.hs`(純函數,對手造快照)
  - 目標路徑:「商業素材包依 vendor 分組」「沒有 vendor 時落在 unknown/,而不是散在頂層」「vendor 名稱會 slug 化」「vendor 全是非 ASCII 時退回 unknown,不是空目錄名」「參考資料不進 packs/」
  - 散檔:「一律 OpKeep,不產生任何搬移或刪除」
  - 素材包搬移:「壓縮檔保留廠商原始檔名」
  - 警告:「draft 的素材包會被點名」「全部就緒時沒有警告」
  - 統計:「刪除的位元組數是釋出空間」
- `reorg/test/AssetDB/Reorg/ExecuteSpec.hs`(對真實臨時目錄與真實 SQLite)
  - 階段 A:「壓縮檔搬到 library/packs/<vendor>/<slug>/」「寫出 pack.toml」「散檔(含工作室自有檔案)原地保留,不搬移」「**散檔原封不動**」「對帳通過:壓縮檔搬移後雜湊不變」
  - 階段 B:「即使加了 --delete-covered 也不再刪散檔 —— 刪除規則已退役」
  - 冪等性:「階段 A 跑過之後,再跑一次會跳過已完成的搬移」
  - 前置檢查:「來源與目標都找不到時拒絕動作(計畫過期)」「來源與目標同時存在時拒絕動作(上次中斷)」
  - 回退:「把搬移倒回原位」「刪除無法回退,而且會明講」「批次列得出來」
