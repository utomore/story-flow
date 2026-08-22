---
id: llm-workshop-mcp-build
type: build-log
title: llm-workshop-mcp-build
description: 委派展開 LLM 端點、階段式工作坊與 MCP adapter
status: in-progress
created: 2026-08-20
updated: 2026-08-22
parent: llm-workshop-mcp
---

# LLM 與工作坊 委派展開紀錄

## 排程

依「功能規劃」的依賴欄建圖:`#1 → #2 → #3 → #4`,`#5` 只依賴 `service-and-interfaces`(已全數 done),
無環。階段是硬邊界。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 | W1 | #1 llm-endpoint (F001) | **done**(2026-08-20) |
| 階段二 | W2 | #2 workshop-stages (F002) | 本次執行 |
| 階段二 | W3 | #3 workshop-emit (F003) | 本次執行 |
| 階段二 | W4 | #4 workshop-interface (F004) | 本次執行 |
| 階段三 | W5 | #5 mcp-adapter (F005) | 本次執行 |

階段二的三項是一條依賴鏈,**每波只有一個 feature**——#3 的設計要看 #2 的產出,無平行空間。
階段三的 #5 不依賴階段二的產出,但它要映射的 REST operation 面會被 #4 的三條 workshop 路由改變,
所以排在階段二驗收之後跑,映射不會做到一半又變。

### 跨子系統依賴的處理決定

本子系統的依賴端(`service-and-interfaces` 的 F001–F003)全數 `done`,無等待。階段一做完後
`conflict-detection` 的鎖已解開並收尾(該子系統 6/6),本次沒有任何跨子系統的等待項。

本次會讓 `service-and-interfaces` 的介面面**長大**:#4 往 CLI 指令樹與 servant API 加三個工作坊
出口。那是介面包裝層,依 ADR-011 本來就是全面下游,不構成反向依賴——但 `storyflow-service` 的
`build-depends` 逐字守衛(B001)**不放行 `storyflow-workshop`**,所以工作坊的業務邏輯只能住在
`storyflow-workshop`,由 CLI / server 各自 import,不得往契約層塞。

## 委派決策記錄

批次澄清的「執行取向 / 排程類」結論。契約類的已回寫 `design.md`,不在此重複。

### 階段一(2026-08-20)

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 本次跑到哪一階段 | 只跑階段一(F001)。做完解鎖 `conflict-detection` 階段二 | F002–F005 不展開 |
| D2 | 沒有真的 LLM 端點時怎麼測(`chat` 是真的 HTTP 呼叫) | **測試裡用 warp 起一個本機 stub 的 OpenAI 相容端點,打真的 HTTP**。理由:逾時、重試、連線拒絕、回了但格式不對這四種正是 `LlmError` 要區分的,注入假 runner 測不到真正的 `http-client` 行為;`warp` 在 `server` 套件已經在用,不是新相依 | F001 |
| D3 | 程式碼 commit 到哪 | 新開 `feat/llm-endpoint-0012`,編排者在波次與實作完成時做 checkpoint commit;閘門後走 `/branch-pr` | F001 |

### 階段二 + 階段三(2026-08-22)

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D4 | 本次跑到哪一階段 | **階段二 + 階段三,一次做完**。子系統 5/5 收完,達成主架構 P5 的完成標準。兩個閘門各自驗收 | F002–F005 |
| D5 | MCP 的 Haskell 實作(`design.md` 原本列「待評估」) | **自己實作 stdio + JSON-RPC 2.0**(`initialize` / `tools/list` / `tools/call`),`aeson` 已在手上。Haskell 的 MCP 套件生態薄,引一個不穩定的外部相依換三百行程式碼不划算。已回寫 `design.md` 的「使用的技術」與套件表 | F005 |
| D6 | Session 快照的生命週期 | `.storyflow/.gitignore` 加 `workshops/`(與 `index.db` 同一個理由);**走完所有階段後快照保留,不自動刪**;本次**不做** `workshop rm` 子指令——對外形式表只有 start / step / commit 三個出口 | F002, F004 |
| D7 | 程式碼 commit 到哪 | **兩條分支,一階段一條**:`feat/workshop-0014`(階段二)、`feat/mcp-adapter-0015`(階段三)。兩個閘門各自驗收、各自發 PR,某一階段被退不會拖到另一個 | F002–F005 |
| D8 | 工作坊怎麼測 LLM 路徑 | **沿用階段一 D2 的先例**:warp 起本機 stub 的 OpenAI 相容端點打真 HTTP。`storyflow-llm` 的測試已經有這套 fixture,工作坊測的是「約定 JSON 解析成 `wsPending`」與「`LlmError` 原樣浮上來」,兩者都要真的走過 `chat` | F002 |
| D9 | 兩個新套件的邊界守衛 | 各自加一份 `CabalSpec`,照 `storyflow-llm` / `storyflow-conflict` 的先例逐字釘住內部相依。`storyflow-workshop` 不准有 `storyflow-store` / `storyflow-md` / `sqlite-simple`;`storyflow-mcp` **不准有 `storyflow-service`**(契約卡的「明確不做」只是文字,守衛才擋得住) | F002, F005 |

## 跨子系統契約變更

### 階段一(2026-08-20)

| # | 變更 | 決策理由 | 誰來實作 |
|---|---|---|---|
| S1 | `storyflow-store` 的佔位 `newtype LlmConfig = LlmConfig {llmTable :: TOML.Table}` **改名**為 `LlmSection`(或同義名),職責明確為「原樣捧著 `[llm]` 那張表」 | Level 2 契約的 `LlmConfig` 是四欄結構,與 store 的佔位撞名。store 那行註解本來就寫著「現在替它定義欄位,等於在 P1 就凍結 P5 還沒想清楚的設定形狀」——現在正是 P5,形狀由 `storyflow-llm` 定,store 維持不解讀。**改名屬 Level 3**:`LlmConfig` / `VaultConfig` 不出現在任何 design 文檔,是契約線以下的實作細節 | F001 |
| S2 | `StoryFlow.Service` 新增內嵌出口,讓消費者取得 Vault 的 `[llm]` 設定(建議 `vaultConfig :: ServiceM VaultConfig`,並在既有的「沿用 `store` 的定義(不重造)」那一組 re-export `VaultConfig (..)` / `LlmSection (..)`) | `Service.Monad` 目前只 re-export 不透明的 `Vault`,`vaultCfg` 存取子拿不到,`storyflow-llm` 讀不到設定。走 service 的內嵌出口而非直接依賴 `storyflow-store`,與 `conflict-detection`「所有讀取經 `ServiceM`」同一條紀律。**只開內嵌出口,不接 CLI 與 REST** | F001 |

### 階段二 + 階段三(2026-08-22)

| # | 變更 | 決策理由 | 誰來實作 |
|---|---|---|---|
| S3 | `service-and-interfaces` 的 CLI 指令樹新增 `workshop start / step / commit`,servant API 新增 `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit` | 對外形式表本來就寫著這三個出口;它們是介面包裝層(ADR-011 的全面下游),不是新業務操作。`ApiSpec` 的 operation 計數斷言與 `ParitySpec` 的 CLI/REST 對照要跟著更新 | F004 |
| S4 | `storyflow-api` / `storyflow-cli` / `storyflow-server` 的 `build-depends` 加 `storyflow-workshop`;**`storyflow-cli` 與 `storyflow-server` 另加 `storyflow-llm`**(F004 設計時查出:`stepWorkshop` 吃 `LlmClient`,而建 client 的邏輯照 `conflict check` 的先例內嵌在介面層,不經 `storyflow-workshop` 間接取得);四份 `CabalSpec` 的逐字清單同步 | 工作坊的 DTO(`Session` / `StageDraft`)要進 API 型別,與 `storyflow-conflict` 進 `storyflow-api` 完全同一種性質。**`storyflow-service` 的清單一個字都不准動**(B001) | F004 |
| S5 | `.storyflow/.gitignore` 加一行 `workshops/` | 快照是本機互動狀態,不是故事設定。`store` 的 `initVault` 已經在寫那份 `.gitignore`,加一行即可 | F002 |
| S7 | `storyflow-api` 的 `storyFlowOpenApi` 補一個機械式的 `deriveOperationId`(HTTP verb + 大寫化的 path 段,`{param}` → `ByParam`),讓推導出來的 OpenAPI 文件真的帶 `operationId` | **F005 設計階段查出**:servant-openapi3 **不產生** `operationId`——subagent 從 `dist-newstyle/cache/plan.json` 取出實際解析的版本(`openapi3-3.2.5` / `servant-openapi3-2.0.2.0`),拉本機 cabal 快取的 tarball 讀原始碼確認 `_operationOperationId` 預設 `Nothing` 且 servant-openapi3 全無引用。而契約寫著「tool 名字由 `operationId` 推導」,所以要先讓它存在。這是**實作契約而非改變契約**,加在既有的 `applyTagsFor` 鏈同一處 | F005 |
| S6 | `StoryFlow.Service` 新增內嵌出口 `vaultRoot :: ServiceM FilePath`(操作數 26 → 27);**只開內嵌出口,不接 CLI 與 REST** | 快照要寫 `<root>/.storyflow/workshops/`,而 `storyflow-workshop` 與 `storyflow-llm` 同樣不准依賴 `storyflow-store`,拿不到 root。**不沿用 `vaultInfo`**:它為了 `vvEntityCount` 會 `listEntities` 全表掃描(`service/src/StoryFlow/Service.hs:146`),而快照每一 step 寫一次——付一次全表掃描換一個馬上被丟掉的數字。與 F001 新增 `vaultConfig` 完全同一種先例 | F002 |

## 配號表

fan out 前預先分配,subagent 不得自行配號。

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| llm-endpoint | F001 | F001-llm-endpoint.md | 繼承 | 繼承 | **impl-done**(10/10 Todo,commit f2fec1e) |
| workshop-stages | F002 | F002-workshop-stages.md | sonnet | sonnet | **impl-done**(12/12 Todo,commit 3313d72;設計跑三版) |
| workshop-emit | F003 | F003-workshop-emit.md | sonnet | sonnet | **impl-done**(8/8 Todo,commit 3236561;設計跑兩版) |
| workshop-interface | F004 | F004-workshop-interface.md | sonnet | sonnet | **impl-done**(22/22 Todo,commit dac2f7f) |
| mcp-adapter | F005 | F005-mcp-adapter.md | sonnet | sonnet | 待展開 |

**F001 的兩個模型欄寫「繼承」是 0.7.x 的舊寫法**,如實留著。0.8.x 起委派模型固定
`sonnet`,F002–F005 一律照填——模型固定下來,閘門看到品質問題時就歸因得回契約卡寫得夠不夠,
不會混進模型差異。

F002–F005 的號碼在階段一就預先保留,本次接續模式沿用,不重配。

## 待確認假設彙總

### 階段二 + 階段三(2026-08-22)

**設計階段已裁決的兩組**(沒有拖到閘門,因為它們會被下游 feature 繼承,錯了會沿依賴鏈複利):

| 來源 | 假設 | 採取的判斷 | 裁決 |
|---|---|---|---|
| F002 A1 | `startWorkshop` / `loadSession` 除了 `ServiceError` 沒有錯誤通道,工作坊自己的失敗要放哪 | 往 `storyflow-service` 的 `ServiceError` 加五個 `Workshop*` 建構子 | **不接受**(2026-08-22,設計階段就裁決,未拖到閘門)。那會讓契約層的錯誤型別認識 P5,而 `StoryFlow.Service` 門面註解明寫「明確不做的:conflict(P4)、workshop(P5)、LLM」。改為 `storyflow-workshop` 自己一套 `WorkshopError`(七個建構子),四個對外操作一律回 `ServiceM (Either WorkshopError …)`;`WsLlmFailed` 原樣包住 `LlmError` 不攤平,與 `StoreFailed` 包 `StoreError` 同一個做法。已升格為 `design.md` 對外契約。**F002 設計因此重跑** |
| F002 A2 | `storyflow-workshop` 拿不到 vault root(不准依賴 `storyflow-store`) | 沿用既有的 `vaultInfo` 取 `vvRoot`,「略微增加 SQLite 查詢成本」 | **不接受**(2026-08-22)。編排者複核 `service/src/StoryFlow/Service.hs:146`:`vaultInfo` 是 `listEntities conn emptyFilter` 再 `length`,**全表掃描**,而快照每一 step 寫一次——代價被低估了。改為新增 `vaultRoot :: ServiceM FilePath`(見 S6)。**F002 設計因此重跑** |
| F003(原 A2) | 工作坊寫出的片段預設 `status` | `Draft`,依 ADR-003 的 canon-only 比對基準(subagent 另讀 `Conflict/Retrieval.hs` 的 `canonFilter` / `isCanon` 佐證) | **接受**(2026-08-22),已升格為 `design.md` 契約的一條 |
| F003 發現 | `lore-fragment` / `plot-fragment` 宣告 `timeline` 必填,`StageDraft` 沒那一欄 → 五個工作坊型別有兩個**每次定案都 `ValidationFailed`** | (回報為阻塞,不自行決定) | **確認屬實**(編排者複核 `createEntity` 寫檔前跑 `validateForWrite`)。採**宣告式補法**:prompt 的欄位要求全部來自 `etsFields`(ADR-005 本來就把 `fields` 定位成給 AI Agent 的提示來源)、`StageDraft` 加 `sdTimeline`、`WorkshopError` 加 `WsMissingRequiredField`、`commitStage` 寫入前自己對照必填清單。**F002 與 F003 兩份設計因此重跑** |

**留待階段二閘門裁決的**:

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F002 A1 | 硬約束存在性檢查的時機 | `startWorkshop` 及早驗證、`stepWorkshop` 現讀不快取 | 待閘門 |
| F002 A2 | `wsId` 產生方式 | `fnv1a64` + `wksp-` 前綴 + 檔案存在性碰撞重試,不進 `Core.Id.IdPrefix` 封閉集合 | 待閘門(編排者已複核 `fnv1a64` 確實由 `StoryFlow.Core.Id` 匯出) |
| F002 A3 | `saveSession` 與 id 產生函式要不要進套件公開面 | 暫不公開,留給 F003 以套件內部呼叫重用 | 待閘門 |
| F002 A4 | `stepWorkshop` 每次重查 `etsFields`(不快取進 `Session`);型別找不到時重用 `UnknownType` 而非新開 `WorkshopError` 建構子 | 不快取的理由是 `Session` 的九欄已被 Level 2 鎖定,快取等於偷偷加第十欄 | 待閘門 |
| F002 A5 | 欄位要求區塊的呈現格式 | 逐條「- 欄位名(必填/選填):hint」,測試只斷言子字串不鎖版面 | 待閘門 |
| F003 A1 | 主體檔的 title / summary 從哪來 | 借用首次定案第一筆 `StageDraft`,body 留空 | 待閘門 |
| F003 A3 | `wsCurrent` +1 由誰負責 | `commitStage`(與契約卡「不決定階段流程」字面有張力,文檔已展開理由) | 待閘門 |
| F003 A4 | 回傳的 `[EntityView]` 含不含主體 | 首次定案時含 | 待閘門 |
| F003 A5 | 多筆寫入非交易性 | 失敗不回滾,可能留孤兒 Entity;風險記錄但刻意不處理 | 待閘門 |
| F004 A1 | `Session` / `StageDraft` / `Message` / `Role` 的 JSON 欄位命名 | 依全系統慣例假設(F002/F003 未實作,查不到原文) | 待閘門——**實作時以 F002/F003 落地的為準**,不以 F004 文檔為準 |
| F004 A2 | `workshopErrorCode` 的七個 code 字串 | F004 提議 `workshop_session_not_found` 等 | 待閘門。**編排者指示**:F002 實作時直接採用 F004 這張表,省一次跨 feature 同步 |
| F004 A3 | `CliError` 的建構子數 | 契約卡與 `Cli/Error.hs` 模組註解都寫「四種」,程式碼實際五個(`CliInput` 是後補的) | **編排者已複核屬實**:`cli/src/StoryFlow/Cli/Error.hs:130` 有五個建構子,同檔註解只列四個。屬原始碼註解漂移,列為閘門發現 |
| F004 A4 | 四個 REST wrapper DTO 放 `storyflow-api` 而非 `storyflow-workshop` | 與既有 DTO 的歸屬一致 | 待閘門 |
| F004 A5 | `workshop step` / `commit` 的確切 CLI 旗標名 | 比照 `context` / `conflict check` 的既有慣例設計(契約卡只給了 `start`) | 待閘門 |

### 階段一(2026-08-20)

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | `lcTimeout :: Int` 的**單位**契約沒寫 | 毫秒,TOML 鍵名 `timeout_ms`,預設 60000 | **接受**,已與 A4/A5 一併把 `[llm]` 的設定格式寫進 design.md 對外契約 |
| F001 A2 | `design.md` 把「沒有 `[llm]` 段回錯誤」歸給 `newLlmClient`,但 `LlmConfig -> IO LlmClient` 沒有錯誤通道 | 錯誤由 `Llm.Config` 的**載入階段**產生,`newLlmClient` 維持契約簽名且為全函式 | **編排者已處理**:那句話是編排者在批次澄清時寫的,歸屬寫錯了。已回寫 `design.md` 改成「設定載入階段回錯誤」。閘門請確認 |
| F001 A3 | `LlmError` 是否只准「連不上」與「格式不對」兩類 | 另加 `LlmHttpStatus` 與兩個設定類建構子——401 與「形狀不對」的下一步不同 | **接受**,五類已升格為 design.md 對外契約的一張表(含可否重試與下一步) |
| F001 A4 | `[llm]` 的鍵名與未知鍵怎麼處理 | snake_case 五鍵;未知鍵**視為錯誤**(沿用 `Types.Loader` 的立場) | **接受**,已寫進 design.md 對外契約 |
| F001 A5 | 預設值 | `timeout_ms = 60000`、`retries = 1` | **接受**,已寫進 design.md 對外契約 |
| F001 A6 | `llmConfig` 回 `Either` 還是丟 `ServiceError` | 回 `ServiceM (Either LlmError LlmConfig)`,不讓下層錯誤型別認識上層 | 接受 |
| F001 A7 | 設定錯誤訊息要不要帶絕對路徑 | 只寫相對的 `.storyflow/config.toml`(`vaultConfig` 拿不到 `vaultRoot`) | 接受 |
| F001 A8 | 改名後的存取子名 | `LlmSection` / `llmSectionTable`(不沿用 `llmTable`) | 接受 |
| F001 A9 | `chatEndpoint :: LlmConfig -> String` 是「新增的介面」清單外的公開名字,且穿透門面 | 住在 `Llm.Config`:它有兩個呼叫端(`parseLlmConfig` 驗證 `base_url`、`chat` 組請求),放進 `Llm.Client` 會讓 Config 反向 import Client;Haskell 無法「只給同套件看」,要藏只能兩邊各寫一份 URL 規則 | **不接受**:閘門裁定要它退出公開面。門面改為逐項列舉匯出 15 個名字,`chatEndpoint` 仍住 `Llm.Config` 供套件內部共用(URL 規則沒有變成兩份)。以 `cabal repl` 走已編譯的 package interface 實測:`import StoryFlow.Llm` 後 `chatEndpoint` 不在作用域,再 `:m + StoryFlow.Llm.Config` 就看得到 |

## 階段結果

### 階段二:工作坊

**完成的 feature**:F002 workshop-stages(12/12 Todo)、F003 workshop-emit(8/8)、
F004 workshop-interface(22/22),設計與實作模型皆 `sonnet`。子系統進度 4/5 (80%)。

**測試**:`cabal test all` **11 suites PASS,1378 examples,0 failures**(編排者在每個
checkpoint 獨立複跑驗證)。1169 →(階段一)→ 1318 → 1327 → 1378。`cabal build all` 零 error、
零 warning。新增 `storyflow-workshop-test` 56 條;`cli` 212 → 237、`server` 66 → 84、
`api` 71 → 79、`service` 99 → 102、`store` +1。

**既有測試改動全為擴充,無一放寬**(編排者與 arch-audit 各自獨立逐檔比對 `git diff`):
`ApiSpec` 的 operation 計數 25 → 28、`OpenApiSpec` 16 → 19 路徑 / 25 → 28 operation / +8 schema、
三份 `CabalSpec` 的 `required` 清單只增不減、`ParitySpec` / `OptionsSpec` / `RemoteCmdSpec` /
`RenderSpec` 只新增案例、`store/InitSpec` 擴充 `.gitignore` 斷言。

**契約層守衛完好**:`storyflow-service` 的 `.cabal` 除了測試模組表多一行 `VaultRootSpec` 之外
**零改動**,`CabalSpec` 的逐字四名單一個字沒動——ADR-011 的「契約層單向」與 B001 的守衛在這次
新增一個上游套件之後仍然成立。`cabal.project` 的 `allow-newer` 一個字沒動。

**設計階段就攔下的兩件事**(沒有拖到閘門,因為會被下游 feature 繼承):

1. **F002 A1 / A2 被推翻**:subagent 提議往契約層的 `ServiceError` 加五個 `Workshop*` 建構子,
   並用 `vaultInfo` 取 vault root。前者會讓契約層認識 P5;後者複核發現 `vaultInfo` 是
   `listEntities` 全表掃描,而快照每一 step 寫一次。改為 `WorkshopError` 自成一套 +
   新增 `vaultRoot :: ServiceM FilePath`。**F002 設計重跑**
2. **F003 查出必填欄位缺口**:`lore-fragment` / `plot-fragment` 都宣告 `timeline` 必填而
   `StageDraft` 沒那一欄,五個工作坊型別有兩個會**每次定案都 `ValidationFailed`**。順著查下去
   還發現 F002 組 prompt 時完全沒用 `etsFields`,而 ADR-005 明寫那一欄是「給 AI Agent 的提示
   來源」。採宣告式補法(prompt 讀 `etsFields` + `StageDraft` 加 `sdTimeline` +
   `WsMissingRequiredField`)。**F002 與 F003 兩份設計都重跑**

### 階段二 arch-audit 發現(依嚴重度)

**中 1 條、低 3 條,無高**。編排者逐條打開原始碼複核,三條屬實:

- **F1(中)`commitStage` 推進 `wsCurrent`,與契約卡「明確不做」字面牴觸**
  (`workshop/src/StoryFlow/Workshop/Emit.hs:66`)。`workshop-emit` 的契約卡寫著「不決定階段
  流程(那是 `workshop-stages`)」,但「前進到下一階段」落在 `commitStage` 裡。這不是實作者
  自作主張——F003 A3 已完整記錄這個張力(F002 的三個操作都不改 `wsCurrent`,不做的話工作坊
  會卡死在同一階段;`design.md` 的資料流管線文字本來就把「進入下一階段」緊接在 `commitStage`
  之後)。**待閘門裁決**
- **F2(低)`design.md`「內部模組劃分」表漏列 `Workshop.Error`**(全文零命中),`workshop-stages`
  契約卡的「負責模組」欄同樣沒有。**與階段一的 A-3(`Llm.Error`)是同一個子系統內同一類問題
  再犯一次**
- **F3(低)`cli/src/StoryFlow/Cli/Error.hs` 的模組註解仍寫「四種失敗」,實際已六種**
  (`CliService` / `CliRemote` / `CliResolve` / `CliInput` / `CliUsage` / `CliWorkshop`)。
  F004 A3 記過舊有的「四 vs 五」漂移,本次又加了 `CliWorkshop` 沒同步,漂移擴大而非收斂
- **F4(低)階段一遺留兩條未處理**:A-1(`entity-graph-core/F004` 仍寫 `Maybe LlmConfig`)、
  A-2(`system.md` 漏列 `http-client-tls`)。非本次委派造成,如實提醒

**通過的檢查**(arch-audit 逐項查證,非採信回報):

- **門面 `StoryFlow.Workshop` 的匯出與 Level 2 契約一個不多一個不少**——逐項列舉而非
  `module X` 整包 re-export,**沒有重犯 F001 `chatEndpoint` 穿透門面那一類問題**
- **四個簽名與 `design.md` 逐字相符**;`Session` 九欄、`StageDraft` 五欄、`WorkshopError`
  八個建構子逐一比對相符
- **邊界外洩**:`storyflow-workshop` 的 `build-depends` 無 `storyflow-store` / `storyflow-md` /
  `sqlite-simple` / `direct-sqlite` / `servant` / `warp`,且自己的 `CabalSpec` 逐字釘住並帶
  mutation test;`cli` / `server` 的 workshop 路徑只做接線(不驗證階段、不組 prompt)
- **SRP**:`Workshop.Stages` 是唯一呼叫 `chat` 的模組且不 import `createEntity` / `addFragment`;
  `Workshop.Emit` 沒有 `LlmClient` 參數,不重問模型
- **必填欄位真的由註冊表驅動**:`fieldsBlock` / `requiredFieldNames` 都逐一取自 `etsFields` /
  `fsRequired`,沒有寫死欄位名當業務規則
- **測試品質**:`Warp.testWithApplication` 動態配埠、無寫死埠號、無固定長 sleep;
  `ErrorSpec` 對八個建構子逐一斷言 code 與 message,不是空殼

### 階段二閘門結論(2026-08-22)

開發者裁決:**接受,進階段三**。

- **F1(中)→ 接受現狀,改寫契約卡**:`commitStage` 推進 `wsCurrent` 保留。理由是推進游標是
  「定案」這個動作本身的一部分,不是流程決策——判斷「還有沒有下一階段」的守衛
  (`WsStagesExhausted`)仍然住在 `Workshop.Stages`。`design.md` 的 `workshop-emit` 契約卡
  「明確不做」已改寫成「不判斷 stages 是否耗盡、不組 prompt、不決定階段的內容;但定案成功後
  負責把 `wsCurrent` 推進一格」,字面矛盾消除。**程式碼一行未動**
- **F2(低)→ 修**:`design.md` 的「內部模組劃分」表補列 `Workshop.Error`,`workshop-stages`
  契約卡的「負責模組」欄同步。**順帶補列 `Llm.Error`**——同一張表、同一類問題,階段一的
  arch-audit A-3 就記過,不補的話下次 arch-audit 還會再抱怨一次(編排者判斷,已如實記下)
- **F3(低)→ 修**:`cli/src/StoryFlow/Cli/Error.hs` 的模組註解由「四種失敗」改為「六種」,
  補上 `CliInput` 與 `CliWorkshop` 兩行,並加一句「這段清單漏過兩次」的提醒。純註解
- **F4(低)→ 不在本次處理**:階段一遺留的 A-1 / A-2 屬跨子系統與 Level 1 文檔
- **13 條待確認假設 → 整批接受**,記在上面的表裡備查。它們都落在實作自主權範圍內,
  無一與 Level 2 契約牴觸;arch-audit 另外逐條查過 F003 A5 的失敗路徑與 F004 A4 的 DTO 位置,
  與記錄一致。F004 A1 / A2(JSON 欄位命名、`workshopErrorCode` 字串)已被落地程式碼核對而
  自動失效——兩者與假設完全一致

**契約有無變更**:有一處,`workshop-emit` 契約卡的「明確不做」改寫(見 F1)。Level 2 的四個
簽名、`Session` / `StageDraft` / `WorkshopError` 的形狀一個字都沒動。**`system.md` 本次一個字
都沒改。**

### 階段一:LLM 存取

**完成的 feature**:F001 llm-endpoint(10/10 Todo,設計與實作模型皆**未降級**)。
子系統進度 1/5 (20%)。**`conflict-detection` 階段二的鎖已解開**——`storyflow-llm` 的
`LlmClient` / `chat` 現在存在了。

**測試**:`cabal test all` **10/10 suites PASS,1169 examples, 0 failures**(編排者獨立複跑驗證)。
1103 → 1169,淨增 66 條;新增 `storyflow-llm-test` 62 條,`store` +1、`service` +3,其餘七個不變。
`cabal build all` 零 error、零 warning。

**既有測試只改兩處**,都是改名的必然波及,無一放寬語意;其中 `store/VaultSpec.hs` 另加一條
「原始碼裡 `LlmConfig` 字串不再出現」的斷言(**加嚴**——改名若只加不減、留個 deprecated 別名,
行為測試看不出來)。

**風險項的結果**:`http-client-tls-0.3.6.4` 連同 `tls` / `crypton-connection` / `crypton-x509`
在 GHC 9.14.1 + **未放寬的** `allow-newer` 下全部裝得起來。`cabal.project` 的 `allow-newer`
一個字沒動(編排者複核 diff 確認:只多了 `packages: llm/` 與一組 ghc-options),
並另加一條 `CabalSpec` 斷言把「沒有為了它放寬」釘住。

### 階段一 arch-audit 發現(依嚴重度)

**低 / 5 條**——沒有中或高。契約符合度、邊界與測試都乾淨:

- **A-1 文檔漂移(跨子系統)**:`entity-graph-core/features/F004` 第 134 / 172 行仍寫
  `Maybe LlmConfig`,而型別已改名為 `LlmSection`。那份文檔 `status: done`,不動它;
  建議加一行註記指向本次改名
- **A-2 Level 1 缺一個套件**:`system.md` 第 215 / 627 行的技術選型與套件表只寫 `http-client`,
  沒有 `http-client-tls`(子系統 `design.md` 有列)。屬 Level 1,本 skill 不自行修改
- **A-3 模組表與現況有落差**:`design.md`「內部模組劃分」把「錯誤語彙」歸給 `Llm.Client`,
  實作放在獨立的葉子模組 `Llm.Error`(避免 `Client` ↔ `Config` 互相 import),另有門面
  `StoryFlow.Llm`。屬 Level 3 的模組切分自主權,但表格可補列
- **A-4 套件表列了用不到的東西**:`design.md`「使用到的套件」寫 `storyflow-core` / `storyflow-service`,
  實際 `storyflow-llm` 只需要後者;另外實際多用了 `http-types`
- **A-5(= A9)公開面比「新增的介面」清單大**:門面 `StoryFlow.Llm` 用 `module X` 整包 re-export,
  所以 `chatEndpoint` 這個內部推導函式也進了公開面。與上一輪 `Conflict.Retrieval` 的匯出面
  是同一類問題

**通過的檢查**(逐項查證,非採信回報):

- **Level 2 契約符合度**:`newLlmClient :: LlmConfig -> IO LlmClient`、
  `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)`、`vaultConfig :: ServiceM VaultConfig`
  與契約逐字相符;`LlmConfig` 五欄到齊;`LlmClient` 是不透明型別(門面沒有 `(..)`)
- **邊界外洩**:`storyflow-llm` 的 `build-depends` 無 `storyflow-store` / `storyflow-md` / `sqlite-simple`
  ——設定經 `service` 的 `vaultConfig` 取得,與「所有讀取經 `ServiceM`」同一條紀律
- **`conflict/` 零改動**(`git status --porcelain conflict/` 回 0 行):`CabalSpec` 的 `forbidden`
  仍含 `storyflow-llm`,沒有被順手放行
- **錯誤語彙分層**:`LlmError` 自己一套 + `llmErrorCode` / `renderLlmError`,不重寫下層訊息、
  也不讓下層認識 `ServiceError`(`llmConfig` 回 `ServiceM (Either LlmError LlmConfig)`),
  符合 `system.md` 的全域錯誤處理策略
- **測試真的測到了「連不上服務」**:stub 端點打真的 HTTP,逾時、重試次數、連線被拒、
  回了但格式不對四種都有覆蓋;無固定長 sleep、無寫死埠號,全套 5.0 秒

### 編排者在本階段對架構文檔做的回寫(閘門請確認)

| 檔案 | 改了什麼 | 依據 |
|---|---|---|
| `llm-workshop-mcp/design.md` | `LlmConfig` 加 `lcRetries`;補「與 store 佔位型別的關係」與「沒有 `[llm]` 段時回錯誤」兩段;修正該錯誤的歸屬(`newLlmClient` → 設定載入階段);回填 #1 的 `doc` 欄;MCP 的 operation 計數 23 → 24 | 批次澄清 C1/C3/C4 與 F001 A2;23→24 是既有漂移 |
| `service-and-interfaces/design.md` | 新增 `vaultConfig :: ServiceM VaultConfig`(只開內嵌出口);操作數 25 → 26 | 批次澄清 S2 |

**`system.md` 本次一個字都沒改。**

### 階段一閘門結論(2026-08-20)

開發者裁決:**接受,就此停下**。9 條待確認假設全部裁定,零條懸而未決:

- **A3**(`LlmError` 五類)、**A1 / A4 / A5**(`[llm]` 的鍵名、單位、預設值、未知鍵處理)
  → 接受,並**升格為契約**寫進 `design.md` 的對外契約章節。前者是一張含「可否重試」與
  「下一步」的表,後者是一段可以照抄的 TOML 範例。理由都一樣:F002 工作坊與
  `conflict-detection` 第 3 層消費它們時不該再猜一次,而 `[llm]` 是使用者要手寫的東西,
  屬對外行為
- **A9**(`chatEndpoint` 穿透門面)→ **不接受**,已改為逐項列舉匯出並實測驗證
- **A2** → 編排者處理(錯誤歸屬是批次澄清時寫錯的,已修正 `design.md`)
- 其餘 5 條(A6 / A7 / A8 與實作細節)接受,留在本檔備查

**契約有無變更**:有,見上表與本次新增的兩節。階段二(工作坊)、階段三(MCP)未展開。

**編排者自己的兩處筆誤**(如實記下):修 A2 時多蓋掉一行,把 `LlmError` 段落的開頭吃掉了,
在寫 A3 裁決時補回;委派 F001 設計的 prompt 裡誤稱 `http-client` 不在任何套件的相依裡,
實際上 `cli/storyflow-cli.cabal:41` 早就有——subagent 查證後糾正,已核實。
