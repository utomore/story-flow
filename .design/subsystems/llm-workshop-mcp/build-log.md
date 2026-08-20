---
id: llm-workshop-mcp-build
type: build-log
title: llm-workshop-mcp-build
description: 委派展開階段一的 OpenAI 相容 LLM 端點抽象
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: llm-workshop-mcp
---

# LLM 與工作坊 委派展開紀錄

## 排程

依「功能規劃」的依賴欄建圖:`#1 → #2 → #3 → #4`,`#5` 只依賴 `service-and-interfaces`(已全數 done),
無環。階段是硬邊界,本次**只跑階段一**。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 | W1 | #1 llm-endpoint (F001) | **done** |
| 階段二 | W2 | #2 workshop-stages (F002) | 本次不跑 |
| 階段二 | W3 | #3 workshop-emit (F003) | 本次不跑 |
| 階段二 | W4 | #4 workshop-interface (F004) | 本次不跑 |
| 階段三 | W5 | #5 mcp-adapter (F005) | 本次不跑 |

階段二的三項是一條依賴鏈,**每波只有一個 feature**——#3 的設計要看 #2 的產出,無平行空間。

### 跨子系統依賴的處理決定

本子系統的依賴端(`service-and-interfaces` 的 F001–F003)全數 `done`,無等待。

反過來,**本子系統的 `#1 llm-endpoint` 是別人的前置**:`conflict-detection #5 conflict-llm`
(第 3 層語意判斷)要 import `storyflow-llm` 的 `LlmClient` / `chat`,而該套件目前不存在
——`conflict-detection` 的階段二因此停在 4/6。開發者決定:**本次只跑階段一**,做完就回頭把
`conflict-detection` 收尾,之後再回來跑工作坊與 MCP。這與 `design.md`「跨子系統的排程提醒」
寫的順序一致。

## 委派決策記錄

批次澄清的「執行取向 / 排程類」結論。契約類的四項已回寫 `design.md`,不在此重複。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 本次跑到哪一階段 | 只跑階段一(F001)。做完解鎖 `conflict-detection` 階段二 | F002–F005 不展開 |
| D2 | 沒有真的 LLM 端點時怎麼測(`chat` 是真的 HTTP 呼叫) | **測試裡用 warp 起一個本機 stub 的 OpenAI 相容端點,打真的 HTTP**。理由:逾時、重試、連線拒絕、回了但格式不對這四種正是 `LlmError` 要區分的,注入假 runner 測不到真正的 `http-client` 行為;`warp` 在 `server` 套件已經在用,不是新相依 | F001 |
| D3 | 程式碼 commit 到哪 | 新開 `feat/llm-endpoint-0012`,編排者在波次與實作完成時做 checkpoint commit;閘門後走 `/branch-pr` | F001 |

## 跨子系統契約變更(本次批次澄清的結果)

| # | 變更 | 決策理由 | 誰來實作 |
|---|---|---|---|
| S1 | `storyflow-store` 的佔位 `newtype LlmConfig = LlmConfig {llmTable :: TOML.Table}` **改名**為 `LlmSection`(或同義名),職責明確為「原樣捧著 `[llm]` 那張表」 | Level 2 契約的 `LlmConfig` 是四欄結構,與 store 的佔位撞名。store 那行註解本來就寫著「現在替它定義欄位,等於在 P1 就凍結 P5 還沒想清楚的設定形狀」——現在正是 P5,形狀由 `storyflow-llm` 定,store 維持不解讀。**改名屬 Level 3**:`LlmConfig` / `VaultConfig` 不出現在任何 design 文檔,是契約線以下的實作細節 | F001 |
| S2 | `StoryFlow.Service` 新增內嵌出口,讓消費者取得 Vault 的 `[llm]` 設定(建議 `vaultConfig :: ServiceM VaultConfig`,並在既有的「沿用 `store` 的定義(不重造)」那一組 re-export `VaultConfig (..)` / `LlmSection (..)`) | `Service.Monad` 目前只 re-export 不透明的 `Vault`,`vaultCfg` 存取子拿不到,`storyflow-llm` 讀不到設定。走 service 的內嵌出口而非直接依賴 `storyflow-store`,與 `conflict-detection`「所有讀取經 `ServiceM`」同一條紀律。**只開內嵌出口,不接 CLI 與 REST** | F001 |

## 配號表

fan out 前預先分配,subagent 不得自行配號。

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| llm-endpoint | F001 | F001-llm-endpoint.md | 繼承 | 繼承 | **impl-done**(10/10 Todo,commit f2fec1e) |
| workshop-stages | F002 | (保留,階段二) | — | — | 未展開 |
| workshop-emit | F003 | (保留,階段二) | — | — | 未展開 |
| workshop-interface | F004 | (保留,階段二) | — | — | 未展開 |
| mcp-adapter | F005 | (保留,階段三) | — | — | 未展開 |

**F001 兩者都不降級**:它是新套件、帶新的外部相依(`http-client`),而且是
`conflict-detection` 階段二與整個工作坊的共同上游——契約卡的樣子正是「依賴鏈長、後面還有
feature 疊在上面」那一列。F002–F005 先保留號碼,回來跑接續模式時沿用。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | `lcTimeout :: Int` 的**單位**契約沒寫 | 毫秒,TOML 鍵名 `timeout_ms`,預設 60000 | 待裁決 |
| F001 A2 | `design.md` 把「沒有 `[llm]` 段回錯誤」歸給 `newLlmClient`,但 `LlmConfig -> IO LlmClient` 沒有錯誤通道 | 錯誤由 `Llm.Config` 的**載入階段**產生,`newLlmClient` 維持契約簽名且為全函式 | **編排者已處理**:那句話是編排者在批次澄清時寫的,歸屬寫錯了。已回寫 `design.md` 改成「設定載入階段回錯誤」。閘門請確認 |
| F001 A3 | `LlmError` 是否只准「連不上」與「格式不對」兩類 | 另加 `LlmHttpStatus` 與兩個設定類建構子——401 與「形狀不對」的下一步不同 | 待裁決 |
| F001 A4 | `[llm]` 的鍵名與未知鍵怎麼處理 | snake_case 五鍵;未知鍵**視為錯誤**(沿用 `Types.Loader` 的立場) | 待裁決 |
| F001 A5 | 預設值 | `timeout_ms = 60000`、`retries = 1` | 待裁決 |
| F001 A6 | `llmConfig` 回 `Either` 還是丟 `ServiceError` | 回 `ServiceM (Either LlmError LlmConfig)`,不讓下層錯誤型別認識上層 | 待裁決 |
| F001 A7 | 設定錯誤訊息要不要帶絕對路徑 | 只寫相對的 `.storyflow/config.toml`(`vaultConfig` 拿不到 `vaultRoot`) | 待裁決 |
| F001 A8 | 改名後的存取子名 | `LlmSection` / `llmSectionTable`(不沿用 `llmTable`) | 待裁決 |
| F001 A9 | `chatEndpoint :: LlmConfig -> String` 是「新增的介面」清單外的公開名字,且穿透門面 | 住在 `Llm.Config`:它有兩個呼叫端(`parseLlmConfig` 驗證 `base_url`、`chat` 組請求),放進 `Llm.Client` 會讓 Config 反向 import Client;Haskell 無法「只給同套件看」,要藏只能兩邊各寫一份 URL 規則 | 待裁決 |

## 階段結果

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
