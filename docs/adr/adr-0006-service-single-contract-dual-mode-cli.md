---
id: adr-0006
type: adr
title: service-single-contract-dual-mode-cli
description: Service 層為唯一業務契約,CLI 預設內嵌並可切換 HTTP 遠端
status: accepted
created: 2026-08-16
updated: 2026-08-16
related-spec: [func-0006, func-0007, func-0008]
---

## ADR-0006: `service` 為唯一業務契約,CLI 採內嵌/遠端雙模式

### 狀態(Status)

accepted

### 背景(Context)

需求是「後端服務變成 API 樣式呈現,讓未來更容易與 AI Skill 對接」,同時要有一個 `story-flow`
CLI。理想上 CLI 是 API 的薄客戶端,這樣兩者行為保證一致——這正是 design-studio 最成功的
架構決策之一(`server.py` 與 `cli.py` 共用同一顆 `Workflow` 引擎)。

但「CLI 是 API 的客戶端」的字面實作有個難受的後果:每次跑 `story-flow entity list` 都要先有
一個 server 在跑。對一個單人使用、大部分時間在本機編輯檔案的工具,這個代價不合理。

同時,MCP adapter 與未來可能的 Web UI 確實需要走 HTTP;Vault 也可能哪天放在另一台機器上。

### 決策(Decision)

**業務邏輯只存在於 `storyflow-service`,它是唯一的契約定義處。**

- `storyflow-service` 定義所有業務操作(Vault、Entity、Link、Level、Node、conflict、workshop)
- `storyflow-server` 的 servant handler 是 `service` 的薄包裝,不含任何業務判斷
- `storyflow-mcp` 是 HTTP 客戶端,打同一組 API

**CLI 雙模式:**

- **預設(內嵌)**——`storyflow-cli` 直接呼叫 `service` 的函式。不需要 daemon、啟動即用、
  堆疊追蹤完整、好除錯
- **`--remote <url>`**——改用 `servant-client`,依同一份 servant API 型別打遠端 server

關鍵在於 **servant 的 API 型別是單一契約**:同一個型別同時產生 server(`servant-server`)
與 client(`servant-client`)。兩條路徑無法悄悄長歪——API 型別一改,server 與 client 兩邊
都不編譯。

```text
CLI ─┬→ Service          (內嵌,預設)
     └→ servant-client ──→ HTTP ──→ servant-server ──→ Service
MCP ────────────────────→ HTTP ──→ servant-server ──→ Service
```

server 預設綁 loopback。要綁非 loopback 位址必須明確加旗標並顯示警告(直接採納 design-studio
的 enhance-0005 結論,不重蹈覆轍)。

**收緊(func-0008)**:「明確加旗標並顯示警告」在實作時被收緊為**綁非 loopback 時強制要求
token,沒設就拒絕啟動**。理由是警告會被忽略,而「整個 Vault 暴露在區域網路上」不是可以靠
使用者留意來緩解的後果。loopback 模式維持不變:token 為選配,設了(`STORYFLOW_TOKEN` 或
Vault 設定)才驗證。token 比較用定時比較,不用 `==`——短路比較會洩漏前綴長度。

### 考慮過的替代方案(Alternatives Considered)

- **CLI 一律走 HTTP(必要時自動拉起背景 daemon)**:真的只有一條路徑,不可能行為不一致。
  但每次用 CLI 都要顧服務生命週期,除錯時堆疊斷在 HTTP 邊界,單人本機工具付這個代價不划算;
  自動拉 daemon 又會帶來孤兒行程、port 衝突、多 Vault 對應哪個 daemon 等一整批新問題。
- **CLI 只內嵌,完全不支援遠端**:程式碼最少。但 Vault 移到另一台機器、或想從別處操作時
  就要重寫;而且既然 servant 的 client 幾乎是免費的(型別已經有了),放棄它沒有好處。
- **不做 service 層,servant handler 直接寫業務邏輯**:少一層。但 CLI 內嵌模式就無法共用邏輯,
  只能複製一份或強制走 HTTP——回到上面兩個方案的困境。而且 handler 混了業務邏輯就很難單元測試。

### 影響(Consequences)

**正面**

- CLI 開箱即用,不需要管服務;同時保留遠端能力
- 業務邏輯只有一份,三種介面(CLI / HTTP / MCP)行為必然一致,由型別強制
- `service` 不涉及 HTTP 與終端輸出,可以直接用 hspec 對它做完整的業務測試
- 未來要接任何新平台(其他 AI Agent、Web UI、編輯器外掛)都只是再寫一層薄的

**負面 / 成本**

- 多一層 `service`,簡單操作要多寫一次型別轉換
- 兩條路徑在**非業務**面向仍可能有差異:認證、錯誤格式、逾時。緩解方式是錯誤型別定義在
  `service`,server 與 CLI 各自只負責呈現
- 內嵌模式與遠端模式的並發語意不同(內嵌是單行程,遠端可能多客戶端)。樂觀鎖(ADR-0003 的
  `revision`)在兩種模式下都必須生效,不能只在 server 端做

**中立**

- P3 要輸出 OpenAPI 文件,讓 claude code 只靠文件就能接;這也是 MCP adapter 的生成依據
- 雙模式逼出一個套件切分:servant API 型別必須獨立成 `storyflow-api`,不能住在
  `storyflow-server` 裡。CLI 的遠端模式需要那份型別去產生 `servant-client`,但一個預設
  根本不開伺服器的執行檔不該被拖進 `warp` 與 `servant-server`(func-0008)
