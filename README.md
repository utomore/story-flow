# story-flow

故事設定的**片段圖譜**與**場景樹**管理工具,以 Haskell 撰寫,API 優先。

核心主張:**能被關聯的最小單位是「片段」,不是「文件」**。
「世界觀:歷史」不是一個 Entity;歷史裡「描述埃提亞這個地區在崩塌前的樣貌」那一段才是。
片段夠細,關聯才有意義,「這段新劇情和過去的故事有沒有衝突」才可能精準回答。

## 它解決什麼

世界觀累積到幾十份設計文件之後會出現的問題:

- 要跟 AI 討論新劇情時,無法回答「這段設定和過去寫過的東西有沒有衝突」——衝突發生在文件
  **內部的某一段**,不是整份文件
- 設定之間的關係(誰取代誰、哪兩段矛盾、這個道具出現在哪個場景)只存在於作者腦中
- 場景與演出(誰出場、鏡頭怎麼走、哪句對話接哪句)沒有地方放
- 設計資料沒有給 AI Agent 的契約

## 怎麼組成

| 概念 | 是什麼 |
|---|---|
| **Entity** | 內容的最小單位。世界觀片段、角色片段、道具、對話、劇情片段,彼此以**有方向性**的關聯連結 |
| **Level / Node** | 場景的結構。Node 樹狀無限展開,承載順序、分支、鏡頭;內容一律關聯到 Entity |
| **Vault** | 一個世界/作品 = 一個資料夾 = 一個 git repo。可跨 Vault 引用共用設定 |
| **統一 Meta** | Entity / Level / Node 共用同一組 metadata(唯一編號、總結、關聯、狀態、時間軸、別名……) |

儲存採 **Markdown 檔為真相來源**(一主題一檔、檔內分節為片段,可 `git diff`、AI Agent 可直接
讀)+ **SQLite 為可重建索引**(關聯查詢與 FTS5 中文全文檢索)。

## 介面

```
       ┌─ story-flow CLI ─┐   預設內嵌,--remote 走 HTTP
Agent ─┼─ MCP adapter ────┼─→ REST API ─→ service ─→ storage
       └─ 直接打 API ─────┘
```

業務邏輯只存在於 `service`,三種介面行為由型別保證一致。
地端模型(llama.cpp 等 OpenAI 相容端點)與外部 AI Agent(claude code、codex)兩條路徑
寫進同一個圖譜。

## 建置與測試

需求:GHC 9.14.1、cabal 3.16.x(不使用 stack)。

```
git clone <repo> && cd story-flow
cabal build all
cabal test all --test-show-details=direct
```

一鍵版本(建置 + 測試,exit code 0 表示全綠):

```
./scripts/check.ps1     # Windows
./scripts/check.sh      # POSIX / WSL
```

`check.ps1` 會先切到 UTF-8 code page,測試描述的繁體中文才不會在 Windows 終端亂碼。
本專案**不使用 CI**,`scripts/check` 就是它的替代品——推送前跑一次。

`direct-sqlite` 在 `cabal.project` 開啟 `+fulltextsearch`,以取得中文搜尋所需的
FTS5 trigram tokenizer;`storyflow-store` 的測試會直接驗證這個 flag 有生效。

## 狀態

開發中。**P0–P3 完成**:八個套件(`core` / `types` / `md` / `store` / `service` / `api` /
`server` / `cli`)、912 條測試全綠。純用 `story-flow` 指令就能從零建出片段圖譜與場景樹;
`story-flow-serve` 提供 REST API 與 OpenAPI 文件,CLI 的 `--remote` 走同一份契約。

下一步是 **P4 衝突偵測**。

- [`.design/system.md`](./.design/system.md) —— 專案燈塔:需求、對外介面、子系統劃分、通訊拓撲、資料結構、開發階段
- [`.design/subsystems/`](./.design/subsystems) —— 四份子系統架構(各含功能規劃與 Feature 契約卡):
  [片段圖譜核心](./.design/subsystems/entity-graph-core/design.md)(5/5)、
  [業務契約與介面](./.design/subsystems/service-and-interfaces/design.md)(3/3)、
  [衝突偵測](./.design/subsystems/conflict-detection/design.md)(1/6)、
  [LLM 與工作坊](./.design/subsystems/llm-workshop-mcp/design.md)(0/5)
- [`.design/adr/`](./.design/adr) —— 10 份架構決策紀錄
- [`.design/subsystems/<slug>/features/`](./.design/subsystems) —— 功能設計文檔,含 TodoList 與 1-to-1 測試對照表
- [`types/registry/`](./types/registry) —— 宣告式 Entity 型別註冊表(加一份 `.toml` 就是新增一個型別)

開發階段:~~P0 骨架~~ → ~~P1 core/md/store~~ → ~~P2 CLI~~ → ~~P3 REST API~~ → **P4 衝突偵測** →
P5 MCP + 地端 LLM 工作坊 → P6(選配)Web 視覺化。

## 與其他工具的關係

story-flow 屬於 [alchbees-dev](https://github.com/utomore) 工作室工具集:

- **`assetdb`** —— 管「已經存在的素材」。與 story-flow 平行,無程式化相依
- **`design-studio`** —— story-flow 的前身概念(Python 的 AI 引導式設計工作坊)。並存不動,
  不做資料遷移;等 story-flow 走到 P4 且實際用在作品上,再決定是否封存
