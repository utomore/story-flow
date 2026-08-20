---
id: conflict-detection-build
type: build-log
title: conflict-detection-build
description: 委派展開衝突偵測階段一的確定性兩層與 context 出口
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: conflict-detection
---

# 衝突偵測 委派展開紀錄

## 排程

依 `design.md`「功能規劃」的依賴欄建圖:`#1 → {#2, #3} → #4 → #6`、`{#3, llm-workshop-mcp #1} → #5 → #6`,無環。
階段是硬邊界,本次**只跑階段一**。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 | W0 | #1 conflict-types (F001) | done(本次展開前已完成) |
| 階段一 | W1 | #2 conflict-graph (F002)、#3 conflict-retrieval (F003) | pending |
| 階段一 | W2 | #4 context-command (F004) | pending |
| 階段二 | W3 | #5 conflict-llm (F005) | 本次不跑 |
| 階段二 | W4 | #6 conflict-check (F006) | 本次不跑 |

**W1 的不對稱**:#2 已有 Level 3 設計文檔(F002,`status: open`、7 個 Todo 全未勾),只需委派**實作**;
#3 需要委派**設計 + 實作**。因此 W1 的設計 fan out 只有一個 subagent。

**階段內實作序列**:F002 → F003 → F004(同一個套件、同一批檔案,平行會互蓋)。

### 跨子系統依賴的處理決定

`#5 conflict-llm` 依賴 `llm-workshop-mcp #1 (llm-endpoint)`。查證結果:`llm/` 套件目錄不存在
(專案目前只有 `api cli conflict core md server service store types`),`llm-workshop-mcp` 進度 0/5。
`Conflict.Judge` 必須 import `storyflow-llm` 的 `LlmClient` / `chat`,**編譯不過**,不是「照介面約定先做」
能繞過的。開發者決定:**等**——本次只跑階段一,`llm-workshop-mcp` 展開後再回來跑接續模式。

## 委派決策記錄

批次澄清的「執行取向 / 排程類」結論。契約類的四項已回寫 `design.md`,不在此重複。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 本次跑到哪一階段(階段二卡在不存在的 `storyflow-llm` 套件) | 只跑階段一 | F005 / F006 不展開;`build-log` 保持 `in-progress` |
| D2 | 草稿關鍵詞的抽取策略(契約卡完全沒寫,ADR-007 只說「關鍵詞 + 比對到的 aliases」) | alias/title 反向比對 **與** 切詞**併用**,候選合併去重 | F003 |
| D3 | 程式碼 commit 到哪 | 新開 `feat/conflict-stage1-0011`,每個 feature 實作完 commit 一次;閘門驗收後走 `/branch-pr` | F002 / F003 / F004 |

## 跨子系統契約變更(本次批次澄清的結果)

三項都動到 `service-and-interfaces` 的 Level 2 契約,由編排者回寫該子系統的 `design.md`:

| # | 變更 | 決策理由 | 誰來實作 |
|---|---|---|---|
| S1 | `StoryFlow.Service` 新增 `linkGraph :: ServiceM LinkGraph` | 第 1 層需要整張圖,`loadLinkGraph` 只在 `storyflow-store`,而 conflict 不得直接依賴 store(F001/F002 的 `CabalSpec` 釘住)。只開內嵌出口,不開 CLI / REST | F004 |
| S2 | `SearchHit` 新增 `shScore :: Maybe Double` | `HitLayer` 的 `ByRetrieval Double` 需要相關度,但 `searchEntities` 只回 `(Meta, Text)`。FTS5 路徑帶正規化後的 bm25(0–1,越大越相關),**LIKE 路徑(中文兩字詞,`ORDER BY e.id`)給 `Nothing`**——那條路徑上根本沒有相關度,給假分數是說謊 | F003 |
| S3 | `StoryFlow.Service` 新增 `aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]` | D2 的反向比對需要「既有片段的 title 與 aliases」。走專用出口而非 `listEntities` 全撈 `Meta`:只傳字串,傳輸量小得多。吃 `EntityFilter` 而非自訂參數,沿用既有詞彙(呼叫端傳 `efStatus = Just Canon`) | F003 |

**S2 的連帶影響**:`SearchHit` 是 DTO,`shScore` 會出現在 REST 的回應 body 與 CLI 的 `--json`。
依 `StoryFlow.Core.Json` 既有約定「`Maybe` 沒值時整個鍵不出現」,舊客戶端不會壞;但 service / server / cli
三個套件既有的 `SearchHit` 建構與 JSON 斷言都要跟著更新。

## 配號表

fan out 前預先分配,subagent 不得自行掃描配號。

| feature | id | 檔名 | 狀態 |
|---|---|---|---|
| conflict-types | F001 | F001-conflict-types.md | done(展開前既有) |
| conflict-graph | F002 | F002-conflict-graph.md | design-done(展開前既有),待實作 |
| conflict-retrieval | F003 | F003-conflict-retrieval.md | pending |
| context-command | F004 | F004-context-command.md | pending |
| conflict-llm | F005 | (保留,階段二) | 未展開 |
| conflict-check | F006 | (保留,階段二) | 未展開 |

F005 / F006 先保留號碼:階段二回來跑接續模式時直接沿用,避免屆時重新掃描配到別的號。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| (待各 feature 回報後填入) | | | |

## 階段結果

### 階段一

(執行中)
