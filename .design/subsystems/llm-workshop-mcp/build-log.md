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
| 階段一 | W1 | #1 llm-endpoint (F001) | pending |
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
| llm-endpoint | F001 | F001-llm-endpoint.md | 繼承 | 繼承 | pending |
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
| (待 F001 回報後填入) | | | |

## 階段結果

### 階段一

(執行中)
