---
id: G-E001
type: enhance
title: split-service-and-interfaces
description: service-and-interfaces 橫跨依賴順序兩端,子系統層級的循環偵測因此失真;拆成契約層與介面包裝層兩個子系統
status: open
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-011, ADR-006]
related-feature: []
subsystems: [service-and-interfaces, conflict-detection, llm-workshop-mcp]
---

# G-E001: 把 `service-and-interfaces` 拆成契約層與介面包裝層

## 現況分析

2026-08-23 以 knot(`codegraph.json`,1,768 節點 / 8,054 邊)跑 dev-flow 的
`/arch-audit system`,四份 `design.md` 補上 `code-paths` 後對映 72 / 72 個檔案,
`scan-graph.mjs` 回報**一組循環依賴**:

```
[環 1] llm-workshop-mcp ⇄ conflict-detection ⇄ service-and-interfaces
  service-and-interfaces → conflict-detection   88 條   api/src/StoryFlow/Api.hs:L86-92
  service-and-interfaces → llm-workshop-mcp     75 條   api/src/StoryFlow/Api.hs:L112、Api/Instances.hs:L72
  conflict-detection → llm-workshop-mcp         25 條   conflict/src/StoryFlow/Conflict/Judge.hs:L67
  conflict-detection → service-and-interfaces   34 條   conflict/src/StoryFlow/Conflict/Judge.hs:L68
  llm-workshop-mcp → service-and-interfaces     66 條   llm/src/StoryFlow/Llm/Config.hs:L32
```

五條邊的 `檔案:行號` 都打開確認過,引用真的存在。但**它不是層級倒轉**——`system.md`
「通訊拓撲」與 ADR-011 早就寫明:`service-and-interfaces` 這個子系統**橫跨依賴順序的兩端**,
`storyflow-service`(契約層)在所有人下面,`storyflow-api` / `-server` / `-cli`(介面包裝層)
在所有人上面。環上「進入 service-and-interfaces」的邊全部指向 `storyflow-service`
(`Judge.hs:L68`、`Llm/Config.hs:L32` 都是 `import StoryFlow.Service`),「離開」的邊全部
來自 `storyflow-api`(`Api.hs`)——同一個子系統的兩個不同端。

真正的契約在 module 層成立:以 knot 查 `StoryFlow.Service` 的遞移依賴(34 個 module),
**沒有任何一個**落在 `Conflict` / `Llm` / `Workshop` / `Api` / `Cli` / `Server` / `Mcp`;
`CabalSpec` 也以完整清單釘住了同一件事。

**問題在於偵測工具看的是子系統粒度**:只要契約層與包裝層同屬一個子系統,
`scan-graph.mjs` 的強連通分量就永遠會報這組環,而且是**每次都報**——真的層級倒轉
(例如 `storyflow-service` 哪天 import 了 `storyflow-conflict`)會被淹在這個已知的假陽性裡。
ADR-011 選擇「文字講清楚」而不是「改結構」,代價就是架構檢測失去這一項能力。

## Scope(涵蓋範圍)

**動**(只動 `.design/`,不動程式碼、不動 cabal 套件):

- `system.md` `subsystems` 清單:`service-and-interfaces` → `service-contract` + `interface-layer`
  (ADR-011 的表格本來就是這樣分的)
- `subsystems/service-contract/design.md`:`storyflow-service`,`code-paths: [service/src]`
- `subsystems/interface-layer/design.md`:`storyflow-api` / `-server` / `-cli`,
  `code-paths: [api/src, server/src, cli/src, cli/app, server/app]`;定位寫明
  「全面下游:依賴每一個被暴露的子系統」(ADR-011 第二條)
- `storyflow-mcp` 的歸屬要在此一併決定:目前在 `llm-workshop-mcp`(`mcp/src`),但它的
  職責是「REST 契約的 stdio 包裝」,依 ADR-011 的定義屬介面包裝層。兩個都說得通,
  要選一個寫下來
- 既有 feature 文檔(service-and-interfaces 的 F001–F003)搬到對應的新目錄,id 不變;
  `related-feature` 的跨子系統引用跟著改路徑
- 通訊拓撲圖:五個子系統、箭頭只剩單向向下——`interface-layer` 指向其餘四個,
  `conflict-detection` → `llm-workshop-mcp` → `service-contract` → `entity-graph-core`

**明確不動**:任何原始碼、`.cabal`、`CabalSpec`(契約本身沒有問題);ADR-011 不廢,
加一段「2026-08-23 起改以結構表達」的後記。

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| `scan-graph.mjs .design` 循環依賴 | 1 組(假陽性,每次必報) | **0 組**;依賴矩陣為單向:`interface-layer` → 四者、`conflict` → `llm`、`llm` → `service-contract`、三者 → `entity-graph-core` |
| 子系統對映覆蓋 | 72 / 72 | 72 / 72 不變 |
| 真的層級倒轉(例:`service/src` 某檔 import `StoryFlow.Conflict.*`)能否被檢測抓到 | 不能(淹在假陽性裡) | 能:會以新的一組環出現 |
| `/arch-audit status` | 0 不一致 | 0 不一致(搬檔後 `subsystems` 清單與資料夾雙向對得上、`depends-on` 可解析) |

## 相依性

`depends-on: []`。純文檔重組,與任何進行中任務無關;可在任一 PR 前後做。

## 改善方案

1. `/subsys-design` 建 `service-contract` 與 `interface-layer` 兩份 `design.md`:內容從
   現有 `service-and-interfaces/design.md` 按套件切開(契約卡 `service-contract` 歸前者,
   `cli-embedded`、`servant-api-server` 歸後者),各自補 `code-paths`
2. `system.md`:`subsystems` 清單改為五個;「子系統劃分」一節對應拆成兩小節;
   通訊拓撲圖改畫;`/arch-audit status` 確認雙向一致
3. ADR-011 加後記;本文檔 `status: done`
4. 決定 `storyflow-mcp` 歸屬(建議:`interface-layer`,理由同 ADR-011——它是 REST 契約的
   另一種薄包裝,與 `cli` 同性質;`llm-workshop-mcp` 保留 `llm` 與 `workshop`,名字可順勢
   改回 `llm-workshop`)

## 使用到的既有串接介面

| 介面 | 來源 | 用途 |
|---|---|---|
| `storyflow-service` 的 `ServiceM` 契約(`service/src/StoryFlow/Service.hs`,37 個匯出) | service-and-interfaces/F001 | 契約層的邊界,拆分後不變 |
| `CabalSpec`(`service/test/StoryFlow/Service/CabalSpec.hs`) | service-and-interfaces/B001 | 契約層單向的程式化守門,拆分後不變 |
| dev-flow `scan-graph.mjs` 的 `code-paths` 對映 | dev-flow `_shared/codegraph.md` | 驗收工具 |

## 介面變動

無程式介面變動。架構文檔層級:`system.md` 的 `subsystems` 權威清單 4 → 5。

## TodoList

- [ ] T1: 決定 `storyflow-mcp` 歸屬  `dep: -`
- [ ] T2: `/subsys-design` 建 `service-contract`、`interface-layer`,搬 feature 文檔與契約卡  `dep: T1`
- [ ] T3: `system.md` 清單、子系統劃分、拓撲圖;ADR-011 後記  `dep: T2`
- [ ] T4: `knot extract . && scan-graph.mjs .design` 驗收 0 組環;`/arch-audit status` 0 不一致  `dep: T3`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | — | 決策記在本文檔「實作備註」 |
| T2 | `/arch-audit status` | `subsystems` 清單與資料夾雙向一致、contract 卡 n/n |
| T3 | `/arch-audit status` | `depends-on` / `related-feature` 跨子系統引用皆可解析 |
| T4 | `scan-graph.mjs .design` | 循環依賴 0 組;依賴矩陣八條邊變五條單向邊;覆蓋 72 / 72 |

## 實作備註

(撰寫時留空。立案依據:2026-08-23 knot `codegraph.json` @ `b5e31ac`,`scan-graph.mjs`
輸出與五條邊的原始碼複查;`StoryFlow.Service` 遞移依賴 34 個 module 無一越界。)
