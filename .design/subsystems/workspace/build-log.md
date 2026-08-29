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
| 階段一 | W1 | hub-registry | `d23f24c` | **OK**(11 條路徑全落在 impl 白名單 3 / qa 測試檔 4 / 編排者單線 4) | done(測試 80/0;未結 gap G1) |
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
| hub-registry | F001 | F001-hub-registry.md | `workspace/src/Aapms/Workspace/Types.hs`<br>`workspace/src/Aapms/Workspace/Location.hs`<br>`workspace/src/Aapms/Workspace/Hub.hs` | opus | sonnet | sonnet | **impl-done**(80/0) |
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
| F001 A1 + A2 | 待確認假設(合併) | 契約 A 的 `Hub`;契約 B 四個 getter;模組間公開介面 `Lifecycle → Hub` | F001(下游 F004 / F005) | `Hub` 不透明 + `mkHub` / `hubSourceText`;`Hub.hs` 補對稱的 `upsertProject` / `removeProject` | 有條件可逆 | **選 a**(照 spec 暫採) | design.md 契約 A + 模組間公開介面表(diff 已確認) |
| F001 A3 + S1 + S2 | 待確認假設(合併;S1 / S2 為編排者升級) | 契約 A 的 `loadHub`;契約 F 的 `HubMalformed`;契約 B 的 `veName` / `peName` / `veId` / `peId` 值域 | F001 | 對工具自己寫得出來的欄位從嚴(空 name、重複 id → `HubMalformed`),對未知鍵與未知頂層段從寬(容忍且保留) | 可逆 | **選 a**(照 spec 暫採) | design.md 契約 A 新增「`loadHub` 的合規判準」段(diff 已確認) |
| F001 依賴邊-1~3 | 新增依賴邊 | `Types → aapms-store`、`Hub → aapms-store`、`Location → aapms-core` | F001 | 三條在 design.md 散文裡都有依據,只是「模組間公開介面」表沒收 | 可逆 | **無真實第二方案,不上議程**;改為補表 | design.md 模組間公開介面表(diff 已確認) |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| F001 S1 | 未知鍵與未知頂層段的處置 | 容忍且原樣保留,不是 `HubMalformed` | `loadHub`、`HubMalformed` | 自報 → **編排者升級** | (已併入閘門裁決,照 a) |
| F001 S2 | 中樞內重複 id 的處置 | `HubMalformed`,沿用既有建構子 | `loadHub`、`HubMalformed`、`veId`、`peId` | 自報 → **編排者升級** | (已併入閘門裁決,照 a) |
| F001 S3 | `saveHub` 不建立父目錄 | 失敗原樣包成 `HubWriteFailed` | `saveHub`、`HubWriteFailed`、`atomicWriteText` | 自報(升級篩命中,但**沿用契約卡「明確不做」**,不上閘門) | |
| F001 S4 | 平台預設路徑怎麼取 | `getXdgDirectory XdgConfig "aapms"`,不寫平台分支 | `hubLocation`、`hlPath`、`FromPlatformDefault` | 自報(升級篩命中,**編排者降級**:寫不出真實的第二方案) | |
| F001 S5 | `Hub` / `WorkspaceError` 的 deriving | derive `Show` / `Eq`;`LlmSection` 走 `deriving newtype` | `Hub`、`WorkspaceError`、`LlmSection` | 自報(升級篩命中,**編排者降級**:hspec 的硬需求) | |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| F001 | 0 | 骨架快照紅綠基線(`ws-w1` @ `d23f24c`) | L1–L17 / X1–X27 全體 | **符合預期**:80 條中 5 綠(L16 的 `mkHub` 往返 + L17 的四條 import 檢查,皆為骨架自身承載的事實),其餘 75 條紅 | 無需處置,**無假綠** |
| F001 | 1 | `test_types_imports_marker_type_only`(L17(d)) | L17(d):「`Types.hs` 對 `Aapms.Store.Marker` 的 import 行必須逐字是 `import Aapms.Store.Marker (VaultMarker)`」 | **qa 誤讀**——測試沒有正規化行尾。law 講的是 import 行的**內容**,而 `\r` 是行終止符的產物;主樹的檔案是 LF、快照 worktree 是 git 全新 checkout 轉成的 CRLF,所以只在後者紅。**這不是快照假象:任何人重新 clone 到 Windows 都會紅** | 附條文原文重派 qa 改測試(五條 L17 共用同一套去 `\r` 的正規化);**不動 spec、不動實作** |

## 階段結果

### 階段一
(待跑)

### 階段二
(待跑)
