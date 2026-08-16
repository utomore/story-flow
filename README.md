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

## 狀態

設計階段。架構與技術決策已定案,尚未開始實作。

- [`docs/architecture.md`](./docs/architecture.md) —— 專案燈塔:需求、架構、資料結構、開發階段
- [`docs/adr/`](./docs/adr) —— 8 份架構決策紀錄

開發階段:P0 骨架 → P1 core/md/store → P2 CLI → P3 REST API → P4 衝突偵測 →
P5 MCP + 地端 LLM 工作坊 → P6(選配)Web 視覺化。

## 與其他工具的關係

story-flow 屬於 [alchbees-dev](https://github.com/utomore) 工作室工具集:

- **`assetdb`** —— 管「已經存在的素材」。與 story-flow 平行,無程式化相依
- **`design-studio`** —— story-flow 的前身概念(Python 的 AI 引導式設計工作坊)。並存不動,
  不做資料遷移;等 story-flow 走到 P4 且實際用在作品上,再決定是否封存
