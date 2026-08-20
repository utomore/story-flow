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
| 階段一 | W1 | #2 conflict-graph (F002)、#3 conflict-retrieval (F003) | **done**(1030 examples 全綠,編排者獨立複跑驗證) |
| 階段一 | W2 | #4 context-command (F004) | 設計中 |
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
| conflict-graph | F002 | F002-conflict-graph.md | **impl-done**(7/7 Todo,commit 20a7dcf) |
| conflict-retrieval | F003 | F003-conflict-retrieval.md | **impl-done**(11/11 Todo,commit 12a5d7f + 7b101b9) |
| context-command | F004 | F004-context-command.md | pending |
| conflict-llm | F005 | (保留,階段二) | 未展開 |
| conflict-check | F006 | (保留,階段二) | 未展開 |

F005 / F006 先保留號碼:階段二回來跑接續模式時直接沿用,避免屆時重新掃描配到別的號。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F003 A1 | `searchEntities` 的簽名寫在 `entity-graph-core/design.md`,S2 只回寫了 `service-and-interfaces`,漏了資料真正的產出端 | 設計照 S2 寫完,不自行改 design.md,交編排者 | **編排者已處理**:依 S2 的既有決定回寫 `entity-graph-core/design.md` 第 79 行為 `IO [(Meta, Text, Maybe Double)]`,並補一段說明 LIKE 路徑為何一律 `Nothing`。閘門請確認 |
| F003 A2 | S3 的「傳輸量小得多」理由只對 REST 成立,而 `aliasIndex` 不開 REST | `aliasIndex` 建在既有 `listEntities` 之上,不新增 store 查詢,少改一個子系統的契約 | 待裁決 |
| F003 A3 | `design.md` 把第 2 層成本寫成「一次 SQL」,但 `searchEntity` 一次只吃一個關鍵詞,D2 要求兩路併用 | 每個關鍵詞一次 SQL,`maxKeywords = 16` 封頂 | **編排者已回寫**:成本欄改為「每個關鍵詞一次 SQL(上限可調)」——這是 D2 的事實後果,不是新決定。閘門請確認 |
| F003 A4 | `coTimelineWindow` 是「`tlOrder` 的容許距離」,但 `Draft` 沒有 timeline 欄位,契約沒說基準點是誰 | 以 `drRefs` 對應片段的 `tlOrder` 為基準;基準為空時**不過濾**而非全剔除 | 待裁決 |
| F003 A5 | 一跳擴充的候選沒有檢索分數,卻要與關鍵詞候選一起排序、一起受 `topN` 約束 | 分數 = 母候選 × `expansionDecay 0.5`;`topN` 約束合併後的最終清單 | 待裁決 |
| F003 A6 | ADR-007 沒說一跳擴充要不要含反向關聯 | 只取正向 `lrOutgoing` | 待裁決 |
| F002 A1 | 取代的三種理由文案都沒接 `linkNote`(只有矛盾兩列有) | 照文檔五列表格逐字實作,`gfNote` 仍保留在 `GraphFinding` | 待裁決 |
| F002 A2 | 截斷文案「已達深度上限 N」的 N 該取哪個值 | 用 `gfHops`(截斷時恆等於 `coGraphDepth`) | 待裁決 |
| F002 A3 | 只被**跨 Vault** 參照指到的本地 id,會被 `unlinkedRefs` 列為「零關聯」 | 照文檔「不是任何**本地**關聯的目標」字面實作 | 待裁決(F004 接線做 `Ref` 正規化後自動變正確) |
| F002 A4 | test-suite 不加 `containers` 相依(硬性邊界),但測試要觀測 `Map`/`Set` | 改用 core 的 `buildGraph` 蓋圖 + `Data.Foldable.toList` 觀測 | 待裁決 |
| F003 A7 | 一跳擴充帶進來的候選是否也受 timeline 過濾 | 照文檔管線順序(過濾在擴充之前),擴充候選**不**受過濾;但「已見過」集合用掃過的全部,被時序剔除者不會從擴充回來 | 待裁決 |
| F003 A8 | `ContextHit.xhSnippet` 非 `Maybe`,而擴充候選沒有 FTS5 snippet | 用 `metaSummary`,為空退回 `metaTitle` | 待裁決 |

## 階段結果

### 階段一

(執行中)
