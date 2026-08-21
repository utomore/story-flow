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
| 階段一 | W2 | #4 context-command (F004) | **done** |
| 階段二 | W3 | #5 conflict-llm (F005) | **done**(1208 examples 全綠,編排者獨立複跑驗證) |
| 階段二 | W4 | #6 conflict-check (F006) | **done**(1266 examples 全綠,編排者獨立複跑驗證) |

**W1 的不對稱**:#2 已有 Level 3 設計文檔(F002,`status: open`、7 個 Todo 全未勾),只需委派**實作**;
#3 需要委派**設計 + 實作**。因此 W1 的設計 fan out 只有一個 subagent。

**階段內實作序列**:F002 → F003 → F004(同一個套件、同一批檔案,平行會互蓋)。

### 階段二的排程(2026-08-20 第二次展開)

`#5 → #6` 是一條鏈,**每波只有一個 feature**——#6 的設計要看 #5 的產出,沒有平行空間。
設計與實作全程序列。跑完子系統即 6/6。

**階段一「等」的排程決定已解除**:`llm-workshop-mcp` 的 F001 llm-endpoint 已 `done`,
`storyflow-llm` 套件存在,匯出 `LlmClient` / `chat` / `llmConfig` / 五類 `LlmError`。

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

### 階段二的批次澄清(2026-08-20)

契約類的五項已回寫 `design.md`(對外形式表、`ConflictReport`/`ReportNote` 型別、
第 3 層候選預算、退化與部分失敗、`crNotes` 三種來源,以及兩張契約卡),不在此重複。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D4 | 本次跑到哪一階段 | **階段二跑完**(F005 + F006)。子系統達 6/6,主架構 P4 完成標準達成 | F005 / F006 |
| D5 | 模型送回的內容格式(地端小模型 JSON 不穩) | 要求 JSON;解析失敗就算**該對判斷失敗**,記進 `crNotes`,**不捏假信心值**。呼應 F003「不得捏假分數混進 `ByRetrieval`」 | F005 |
| D6 | 第 3 層怎麼測(`chat` 吃不透明的 `LlmClient`,只能由 `newLlmClient` 造) | **測試套件保持 hermetic**,`cabal test all` 不打網路;公開面照契約卡吃 `LlmClient`,內部注入可替換的 runner。真端點驗收由編排者在閘門另外跑 | F005 / F006 |
| D7 | 執行模型 | **設計繼承主 session,實作降級 `sonnet`** | F005 / F006 |
| D8 | 程式碼 commit 到哪 | 新開 `feat/conflict-stage2-0013`,每個 feature 實作完 checkpoint commit;閘門驗收後走 `/branch-pr` | F005 / F006 |

### 真端點的實測結果(2026-08-20,編排者在批次澄清時查證)

開發者已在本機起了 OpenAI 相容端點 `http://127.0.0.1:8080/v1`,模型
`unsloth/gemma-4-12b-it-GGUF:Q8_0`(llama.cpp,`n_ctx` 32768)。編排者實打了一輪
`/chat/completions`,三項結果直接寫進 F005 的契約卡:

1. **`system` role 可用**——gemma 的 chat template 在這個 serving 設定下接受它,
   `Message System` 不必折進 user 訊息
2. **回覆內容包在 ````json fence 裡,不是裸 JSON**。這是 D5 那條裁定的關鍵前提:
   若照直覺對 `message.content` 直接 `eitherDecode`,**每一對都會判斷失敗**
3. **一對約 7 秒 / 343 completion tokens**(多數是 `reasoning_content`,`storyflow-llm` 的
   `ChatChoice` 只讀 `message.content`,行為正確不必改)。這個數字正是「第 3 層要有自己的
   候選預算」的依據:`coTopN` 預設 20 全判 ≈ 140 秒

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
| context-command | F004 | F004-context-command.md | **impl-done**(14/14 Todo) |
| conflict-llm | F005 | F005-conflict-llm.md | 設計:繼承 / 實作:sonnet — **impl-done**(11/11 Todo) |
| conflict-check | F006 | F006-conflict-check.md | 設計:繼承 / 實作:sonnet — **impl-done**(12/12 Todo) |

F005 / F006 的號碼在階段一就保留了,第二次展開直接沿用(見 D7 的模型分配)。

**為什麼實作降級而設計不降**:兩張卡的契約在批次澄清後都已寫死到「照表操課」的程度
——F005 的回應格式、fence 剝除、退化語意、預算旋鈕全部在卡上;F006 的 `crNotes` 三種來源、
CLI 旗標面、client 建立位置也全部在卡上。而 1-to-1 測試接得住實作錯誤,設計錯了則整條鏈重跑。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F003 A1 | `searchEntities` 的簽名寫在 `entity-graph-core/design.md`,S2 只回寫了 `service-and-interfaces`,漏了資料真正的產出端 | 設計照 S2 寫完,不自行改 design.md,交編排者 | **編排者已處理**:依 S2 的既有決定回寫 `entity-graph-core/design.md` 第 79 行為 `IO [(Meta, Text, Maybe Double)]`,並補一段說明 LIKE 路徑為何一律 `Nothing`。閘門請確認 |
| F003 A2 | S3 的「傳輸量小得多」理由只對 REST 成立,而 `aliasIndex` 不開 REST | `aliasIndex` 建在既有 `listEntities` 之上,不新增 store 查詢,少改一個子系統的契約 | 接受 |
| F003 A3 | `design.md` 把第 2 層成本寫成「一次 SQL」,但 `searchEntity` 一次只吃一個關鍵詞,D2 要求兩路併用 | 每個關鍵詞一次 SQL,`maxKeywords = 16` 封頂 | **編排者已回寫**:成本欄改為「每個關鍵詞一次 SQL(上限可調)」——這是 D2 的事實後果,不是新決定。閘門請確認 |
| F003 A4 | `coTimelineWindow` 是「`tlOrder` 的容許距離」,但 `Draft` 沒有 timeline 欄位,契約沒說基準點是誰 | 以 `drRefs` 對應片段的 `tlOrder` 為基準;基準為空時**不過濾**而非全剔除 | **接受**,已回寫 conflict-retrieval 契約卡(含「沒有 `--ref` 的草稿等於關掉 timeline 過濾」這個代價) |
| F003 A5 | 一跳擴充的候選沒有檢索分數,卻要與關鍵詞候選一起排序、一起受 `topN` 約束 | 分數 = 母候選 × `expansionDecay 0.5`;`topN` 約束合併後的最終清單 | **接受**,已與 F004 A5 一併寫進 design.md 對外契約章節 |
| F003 A6 | ADR-007 沒說一跳擴充要不要含反向關聯 | 只取正向 `lrOutgoing` | 接受 |
| F002 A1 | 取代的三種理由文案都沒接 `linkNote`(只有矛盾兩列有) | 照文檔五列表格逐字實作,`gfNote` 仍保留在 `GraphFinding` | 接受 |
| F002 A2 | 截斷文案「已達深度上限 N」的 N 該取哪個值 | 用 `gfHops`(截斷時恆等於 `coGraphDepth`) | 接受 |
| F002 A3 | 只被**跨 Vault** 參照指到的本地 id,會被 `unlinkedRefs` 列為「零關聯」 | 照文檔「不是任何**本地**關聯的目標」字面實作 | **已解決**:F004 設計查證發現正規化上游早就做完了——`Store/Index.hs` 的 `insertLinks` 在寫 `links` 表前套 `localize`,三個寫入點無例外,而 `loadLinkGraph` 讀的正是那張表。編排者已複核 `localize` / `insertLinks` / `loadLinkGraph` 三處原始碼。F004 只需釘住這個不變量,不再掃一遍 |
| F002 A4 | test-suite 不加 `containers` 相依(硬性邊界),但測試要觀測 `Map`/`Set` | 改用 core 的 `buildGraph` 蓋圖 + `Data.Foldable.toList` 觀測 | 接受 |
| F003 A7 | 一跳擴充帶進來的候選是否也受 timeline 過濾 | 照文檔管線順序(過濾在擴充之前),擴充候選**不**受過濾;但「已見過」集合用掃過的全部,被時序剔除者不會從擴充回來 | 接受 |
| F003 A8 | `ContextHit.xhSnippet` 非 `Maybe`,而擴充候選沒有 FTS5 snippet | 用 `metaSummary`,為空退回 `metaTitle` | 接受 |
| F004 A1 | 契約卡的 CLI 只有 `--for`,**沒有帶 `drRefs` 的旗標——第 1 層在 CLI 上因此永遠不會啟動** | 加 `--ref`(可重複)與 `--top-n` / `--timeline-window` / `--graph-depth`;`coExpandBody` 不開(第 3 層才用) | **接受**,並已回寫 design.md 的對外形式表與對外契約章節 |
| F004 A2 | F002 的 `unlinkedRefs` 在 `[ContextHit]` 的回傳型別裡沒有位置 | 本 feature **不接**——遠端模式拿不到 `ServiceM`,只在內嵌模式多印警告會違反「CLI 與 REST 回同一批結果」;提示留給 F006 | 接受 |
| F004 A3 | 第 1 層命中的 snippet 沒有契約規定(它命中的是一條關聯,不是一段文字) | 用 `metaSnippet`(summary → title),與 F003 一跳擴充同一規則 | 接受 |
| F004 A4 | 兩層命中同一片段時怎麼合併 | `xhVia` 取層級較前者(graph),`xhSnippet` 取 `ByRetrieval` 那一筆 | 接受 |
| F004 A5 | `coTopN` 是否截斷合流後的總清單 | **不截**;它是第 2 層的候選上限 | **接受**,已回寫 design.md:`coTopN` 是第 2 層候選上限,跨層合流後不截斷 |
| F004 A6 | `storyflow-api` 與 `storyflow-server` 會各長出 `storyflow-conflict` 相依 | 照做;`system.md` 的依賴圖與兩個 `CabalSpec` 的禁用清單都允許 | 接受 |
| F004 A7 | 路徑數 / operation 數 / 子指令數會變(14/23/21 → 15/24/22) | 程式碼與測試照新數字改,架構文檔由編排者回寫 | **已處理**:實測為 REST 15/24、CLI **24**(文檔的 21 是既有漂移,`context` 加入前實際已 23)。編排者已回寫 `system.md` 與 `service-and-interfaces/design.md` |
| F004 A8 | `ContextReq` 定義在 `StoryFlow.Api`,而 `Api` 是 `Api.Instances` 的下游,六個 `ToSchema` 全放 `Instances` 會成模組環 | 五個孤兒實例照 T8 放 `Instances`,`ContextReq` 的三個實例留在 `Api.hs`(與 `NewVaultReq` / `BodyReq` 同一種放法) | 接受 |
| F004 A9 | 為了讓 `GraphEvidence` 的欄位型別契約(`to` 是 `Ref` 不是 `Id`)出現在 OpenAPI 文件,把它登記進 `components.schemas`,但沒有任何 `$ref` 指向它 | 呼叫 `declareSchemaRef` 強制登記,代價是 components 裡多一個孤兒 schema | **不接受**:閘門裁定拿掉。components 只裝真正被引用的型別 |
| F004 A10 | T2 後半「一跳擴充候選的 `caSnippet` 與 `metaSnippet` 逐字相同」在純函式測試檔裡只能組假候選,證明不了「規則只有一份」 | 移到 `RetrievalEnvSpec`(真的走 `ServiceM`);`metaSnippet` 自己的三條分支仍在 `RetrievalSpec` | 接受 |
| F004 A11 | `ApiSpec.expectedRoutes` 是 service-and-interfaces 業務操作清單的獨立副本,混進別的子系統的出口會讓「對不上時有東西可比」失效 | 拆成兩張表:既有 23 條不動,新增獨立的 `conflictRoutes` | 接受 |

## 階段結果

### 階段一:確定性的兩層(不需要模型)

**完成的 features**:F002 conflict-graph(7/7 Todo)、F003 conflict-retrieval(11/11)、F004 context-command(14/14)。
連同展開前既有的 F001,階段一四項全數 `done`,子系統進度 4/6 (67%)。

**測試**:`cabal test all` 9/9 suites PASS,**1103 examples, 0 failures**(編排者獨立複跑驗證,非採信回報)。
起點 974 → 收工 1103,淨增 129 條。`cabal build all` 零 error、零 warning。

| suite | 起點 | W1 後 | W2 後 |
|---|---|---|---|
| types / core / md / store(store 見註) | 29 / 166 / 189 / 162 | — / — / — / 166 | 不變 |
| api | 51 | 51 | 62 |
| conflict | 26 | 109 | 139 |
| service | 83 | 88 | 94 |
| server | 60 | 60 | 63 |
| cli | 172 | 172 | 195 |
| **合計** | **938** | **1030** | **1103** |

**新增的程式碼**:`Conflict.Graph`(第 1 層純函式)、`Conflict.Retrieval`(第 2 層)、
`Conflict.Pipeline`(合流與 context 出口);`Service.linkGraph` / `Service.aliasIndex`;
`SearchHit.shScore`;`store` 的 `searchEntities` 三元組;`POST /conflict/context`;
`story-flow context` 子指令。

**實際的對外面**:REST 15 條路徑 / 24 個 operation;CLI 24 個葉子子指令;
`story-flow context` 支援 `--for`(必填)、`--ref`(可重複)、`--top-n`、`--timeline-window`、
`--graph-depth`,`--expand-body` 刻意不開(第 3 層才用)。

### 階段一 arch-audit 發現(依嚴重度)

**中 / 1 條**

- **A-1 Level 1 的通訊拓撲敘述已與現實不符**:`system.md` 說依賴「單向向下,編號小的不知道
  編號大的存在」,但 `storyflow-api` / `storyflow-server` / `storyflow-cli`(三者都屬
  `service-and-interfaces`)現在都 `build-depends` 了 `storyflow-conflict`。**不是循環相依**
  (conflict 不依賴這三個,`storyflow-service` 本身也仍然乾淨),但敘述需要把「契約層單向」與
  「介面包裝層必然是所有子系統的下游」分開講。階段二的 F006 接 `conflict check` 時會再擴大一次。
  **屬 Level 1,本 skill 不自行修改**——建議走 `/system-design` 更新模式

**低 / 3 條**

- **A-2 文檔漂移**:`conflict-detection/design.md`「模組間公開介面與資料結構」表列了
  `Conflict.Retrieval → service-and-interfaces`,但漏了 `Conflict.Pipeline → service-and-interfaces`
  ——Pipeline 現在直接呼叫 `linkGraph` 與 `getEntity`
- **A-3 匯出面大於契約卡承諾**:契約卡說「候選撈取策略本身是本模組的內部抽象,對外只露『候選』
  這個結果」,但 `Conflict.Retrieval` 公開匯出 13 個純函式部件與 6 個調校常數
  (`segMinLen` / `chunkLen` / `maxKeywordLen` / `maxKeywords` / `overFetchFactor` / `expansionDecay`)。
  目前只有測試與 Pipeline(用 `metaSnippet`)消費,但常數一旦被外部引用,
  「換一種候選策略不需要改動第 1、3 層」就會悄悄失效
- **A-4 死碼**:`unlinkedRefs` 沒有任何生產程式碼消費者(F004 的 A2 決定不接)。有測試、有文檔,
  但要到 F006 才有出口

**通過的檢查**(逐項查證,非採信回報):

- 資料流管線一致性:`gatherContext` = 第 1 層 → 第 2 層 → 合流 → 出口 A,與 design.md 逐段相符
- SRP:五個模組的職責與「內部模組劃分」表逐一對應,無模組長出第二職責
- 邊界外洩:`cli` / `server` / `api` 只消費 `gatherContext` + `Conflict.Types` 的 DTO +
  `Conflict.Json` 的實例,**無人 import `Conflict.Graph` / `Conflict.Retrieval` 的內部**
- 子系統界線:`storyflow-conflict` 的 `build-depends` 為
  `aeson / base / containers / mtl / storyflow-core / storyflow-service / text`
  ——`storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple` 一個都沒有;
  `storyflow-service` 不依賴 `storyflow-conflict`(方向正確,無環)
- **「永不自動修改資料」**:grep 全部 14 個 service 寫入操作名,`conflict/src` 零呼叫
- 契約卡對帳:四張已完成的卡,負責模組與實際落地位置逐一相符

### 階段一閘門結論(2026-08-20)

開發者裁決:**接受,就此停下**。17 條待確認假設全部裁定,零條懸而未決:

- **F004 A1**(`--ref`)、**F003 A4**(timeline 基準點)、**F003 A5 + F004 A5**(兩個 `topN` 語意)
  → 接受,並**升格為契約**寫進 `design.md`(對外形式表、對外契約章節、conflict-retrieval 契約卡)。
  這三條原本都是「文檔沒寫、執行者只好自己判斷」的洞;F006 做三層合流時會再問到 `topN` 的作用範圍,
  現在它有答案
- **F004 A9**(OpenAPI 的孤兒 schema)→ **不接受**,已委派移除(commit `349f6a6`)。
  移除後複驗:`cabal run story-flow-serve -- --openapi` dump 出的文件裡 `GraphEvidence` 出現 0 次,
  `HitLayer` 不受影響;1103 examples 仍全綠
- **F002 A3** → 裁定為**已解決**(正規化在索引寫入端早已完成)
- 其餘 12 條接受,留在本檔備查

**契約有無變更**:有,見下表。階段二(F005 conflict-llm、F006 conflict-check)未展開,
卡在 `llm-workshop-mcp` 的 `storyflow-llm` 套件尚不存在。

### 編排者在本階段對架構文檔做的回寫(閘門已確認)

| 檔案 | 改了什麼 | 依據 |
|---|---|---|
| `conflict-detection/design.md` | conflict-retrieval 契約卡補四條;第 2 層成本欄「一次 SQL」→「每個關鍵詞一次 SQL」;回填 #3 #4 的 `doc` 欄 | D2 / C5 / S2 與 A3 的後果 |
| `service-and-interfaces/design.md` | 新增 `linkGraph` / `aliasIndex`;`SearchHit` 加 `shScore`;操作數 23→25;REST 14/23→15/24;子指令 21→**24**(既有漂移的修正,不只 +1) | S1 / S2 / S3 與 F004 實測 |
| `entity-graph-core/design.md` | `searchEntities` → `IO [(Meta, Text, Maybe Double)]` 並補說明 | S2 的產出端 |
| **`system.md`** | **只改 REST 的路徑/operation 數(14/23 → 15/24)**;拓撲敘述**未動** | F004 實測。⚠️ 這是 Level 1,本 skill 原則上不該碰,屬事實同步;不接受可直接回退 |
