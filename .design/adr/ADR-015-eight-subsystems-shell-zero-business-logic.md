---
id: ADR-015
type: adr
title: eight-subsystems-shell-zero-business-logic
description: 合併後切八個子系統,契約層獨立、介面外殼零業務邏輯
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-015: 八個子系統,契約層獨立、外殼零業務邏輯

## 狀態(Status)

accepted。**supersedes ADR-011**(契約層單向、介面包裝層全面下游);G-E001 隨之結案。

## 背景(Context)

ADR-011 拒絕把 `api` / `server` / `cli` 拆出 `service-and-interfaces`,理由是「業務邏輯只有一份」
靠的正是包裝與它所包的契約住在同一個子系統裡。那個理由的前提是**只有一個業務契約層**。

合併後這個前提不成立:

- 業務領域從一個變成四個(`asset-ingest` / `conflict` / `ai` / `project`),不會有單一 god service
  包住全部
- assetdb 沒有契約層,它的 `cli` 就是組合根——`Ai.hs`(420 行)、`Cluster.hs`(215)、`Doctor.hs`(187)、
  `Project.hs`(174)混了編排與呈現。這 ~1,200 行要進任何「薄殼」模型都必須先拆
- G-E001(2026-08-23)已經用 codegraph 量出 `service-and-interfaces` 橫跨依賴順序兩端造成的
  循環偵測失真,並提議拆成契約層與介面包裝層

此時 `shell` 存在的理由不再是「讓依賴敘述好看」,而是**只有一個地方負責「四個領域如何呈現成
一致的一組指令」**:統一信封、exit code、`--vault` 解析、錯誤格式。沒有 `shell` 就沒人負責這件事,
每個領域會各長一套。

## 決策(Decision)

**一、八個子系統,四層**:

| 層 | 子系統 | 套件 |
|---|---|---|
| 地基 | `graph-core` | `aapms-core` / `-types` / `-md` / `-store` |
| 地基 | `workspace` | `aapms-workspace` |
| 契約 | `service` | `aapms-service` |
| 領域 | `asset-ingest` | `aapms-archive` / `-ingest` / `-reorg` |
| 領域 | `conflict` | `aapms-conflict` |
| 領域 | `ai` | `aapms-llm` / `-ai` / `-workshop` |
| 領域 | `project` | `aapms-project` |
| 外殼 | `shell` | `aapms-api` / `-cli` / `-server` / `-mcp` |

21 個套件收成 17 個:兩份 `core`、兩份 `store`、兩份 `server`、兩份 `cli`、兩份 LLM 客戶端合一。

**二、`service` 是獨立子系統,單向向下。** 它不 import 任何領域子系統;它是 `ServiceM`、錯誤語彙、
樂觀鎖執行點的唯一定義處。ADR-006「業務邏輯只存在於 `storyflow-service`」改寫為「**業務邏輯存在於
`service` 與各領域子系統的對外契約,`shell` 零業務邏輯**」。

**三、`shell` 零業務邏輯**,判準可稽核:`shell` 裡出現「如果 … 就 …」的業務分支,它就是放錯地方。
`shell` 的職責是參數解析、信封、exit code、`--vault` / `--remote` 解析、OpenAPI、MCP 映射、輸出編碼。

**四、依賴方向由 `CabalSpec` 逐字清單釘住**,四條規則見 system.md「通訊拓撲」。黑名單只涵蓋想得到
的名字;story-flow 的 service-and-interfaces/B001 已經證明 cabal 擋得住循環、擋不住「不成環但方向
倒轉」。

**五、拆 assetdb 的 CLI**:`Options.hs`(純參數解析)進 `shell`;`Ai` / `Cluster` / `Doctor` /
`Project` 的編排進 `service` 或各領域的對外契約,呈現進 `shell`。這是整個移植最大的單項工作,
沒有捷徑。

## 考慮過的替代方案(Alternatives Considered)

- **七個:`service` 併進 `graph-core`**:少一層概念。放棄的理由是 story-flow 已經為「契約與地基住
  一起」付過代價——G-E001 記載的循環偵測失真就是這樣來的。
- **七個:按報告原案 `catalog` / `assetdb` / `storydb` / …**:保留舊產品名當子系統 slug。放棄的理由
  是圖譜統一(ADR-012)後 `assetdb` 與 `storydb` 兩個領域不存在了——只剩「素材怎麼落地」
  (`asset-ingest`)這一個素材專屬的領域;拿舊產品名當 slug 會讓讀者以為還是兩張圖。
- **維持 ADR-011,`shell` 留在 `service` 子系統裡**:不動現狀。放棄的理由見背景——前提已經失效。
- **每個領域自帶 CLI 子指令模組,`shell` 只做路由**:領域自治。放棄的理由是信封、exit code、
  `--vault` 語意會在四個地方各長一版,AI Agent 就不再只需 parse 一種形狀。

## 影響(Consequences)

**正面**

- 子系統以線性順序排得出來,codegraph 的循環偵測有效
- 「三個殼一份契約」有明確歸屬;新增一個業務操作仍是「service 加函式 → api 加路由 → cli 加子指令」
  三處薄的
- assetdb 原本散在 CLI 裡的業務邏輯第一次有了可測試的家

**負面 / 成本**

- 拆 assetdb CLI 的 ~1,200 行是 P3 最大的工作量
- 八個子系統八份 `design.md`,舊四份要重建;`/arch-audit status` 在重建完成前會一直列出缺口
- `shell` 零業務邏輯需要 code review 紀律,`CabalSpec` 擋得住相依方向,擋不住一個 `if`
