---
id: workspace-build
type: build-log
title: workspace-build
description: workspace 六個 feature 的委派展開:中樞、探測、裁決、生命週期、專案、工具
status: in-progress
created: 2026-08-29
updated: 2026-08-29
parent: workspace
---

# 全局中樞(workspace)委派展開紀錄

## 排程

依賴圖 `1→{2,5,6}`、`2→{3,4}`,階段是硬邊界,所以階段一是三個單 feature 的序列波次,
平行只出現在階段二。

| 階段 | 波次 | features | 骨架快照 | 白名單對帳 | 狀態 |
|---|---|---|---|---|---|
| 階段一 | W1 | hub-registry | — | — | pending |
| 階段一 | W2 | vault-discovery | — | — | pending |
| 階段一 | W3 | scope-resolution | — | — | pending |
| 階段二 | W4 | vault-lifecycle, project-registry, machine-tools | — | — | pending |

**跨子系統依賴**:`workspace` 只依賴 `graph-core`,而 graph-core 九個 feature 全數 `done`
(`readMarker` / `initVaultAt` / `markerDir` / `configPath` / `indexDbPath` / `atomicWriteText`
都已交付且在 2026-08-29 的 B2 對帳補進對外契約)。沒有需要「等」或「照介面約定先做」的項目。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 工作樹不乾淨且在 `main` 上,怎麼起跑 | 開分支 `feat/2026-08-29-subsys-workspace`,先把三份 design 的產出 commit 成一顆 | 全部波次的 checkpoint |
| D2 | 四個共用檔案(`aapms-workspace.cabal` / `cabal.project` / `test/Spec.hs` / `Types.hs`)怎麼安排,W4 才平行得安全 | 前三個由**編排者單線維護**,不進任何 feature 的寫入白名單(同 graph-core W6「骨架併入 cabal」的做法);`Types.hs` 在 W1 一次寫齊契約 A–F 的全部型別與 `WorkspaceError` 的十六個建構子,W2 之後沒人再碰它。另外**不設門面模組** `Aapms.Workspace`,界線由 `.cabal` 的 `exposed-modules` 守 | W1(Types 範圍擴大)、W4(平行安全的前提) |
| D3 | 閘門密度 | **標準**:議程為空時降級為非阻塞呈報,有任一條爭議點照常停 | 3c 波次閘門 |
| D4 | 這次跑到哪裡 | 兩個階段都跑完 | W1–W4 |
| D5 | 測試框架 | 沿用專案既有的 `hspec` + `hedgehog` + `hspec-hedgehog`(`store/aapms-store.cabal` 已在用),**不新引入依賴** | 全部 qa 委派 |

D2 的回寫已套進 `design.md`:「內部模組劃分」補上「Types 一次寫齊」與「不設門面模組」兩段,
`hub-registry` 契約卡的負責模組、實作介面、驗收標準與明確不做四欄同步更新。

## 配號表

| feature | id | 檔名 | 骨架檔案 | spec 模型 | qa 模型 | impl 模型 | 狀態 |
|---|---|---|---|---|---|---|---|
| hub-registry | F001 | F001-hub-registry.md | `workspace/src/Aapms/Workspace/Types.hs`<br>`workspace/src/Aapms/Workspace/Location.hs`<br>`workspace/src/Aapms/Workspace/Hub.hs` | opus | sonnet | sonnet | pending |
| vault-discovery | F002 | F002-vault-discovery.md | `workspace/src/Aapms/Workspace/Discovery.hs` | opus | sonnet | sonnet | pending |
| scope-resolution | F003 | F003-scope-resolution.md | `workspace/src/Aapms/Workspace/Scope.hs` | opus | sonnet | sonnet | pending |
| vault-lifecycle | F004 | F004-vault-lifecycle.md | `workspace/src/Aapms/Workspace/Lifecycle.hs` | opus | sonnet | sonnet | pending |
| project-registry | F005 | F005-project-registry.md | `workspace/src/Aapms/Workspace/Projects.hs` | opus | sonnet | sonnet | pending |
| machine-tools | F006 | F006-machine-tools.md | `workspace/src/Aapms/Workspace/Tools.hs` | opus | sonnet | sonnet | pending |

**編排者單線維護、不進任何白名單的檔案**:`cabal.project`、`workspace/aapms-workspace.cabal`、
`workspace/test/Spec.hs`。

## 待確認假設彙總

| 來源 | 類型 | 契約錨點 | 波及 feature | 假設 / 決定 | 可逆性 | 閘門裁決 | 回寫位置 |
|---|---|---|---|---|---|---|---|
| (尚無) | | | | | | | |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| (尚無) | | | | | |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| (尚無) | | | | | |

## 階段結果

### 階段一
(待跑)

### 階段二
(待跑)
