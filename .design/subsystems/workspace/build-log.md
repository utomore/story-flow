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
| 階段一 | W2 | vault-discovery | `5b8e104` | **OK**(6 條路徑:spec 文檔 1 / impl 白名單 1 / qa 測試檔 2 / 編排者單線 2) | done(測試 125/0;G2 已 resolved) |
| 階段一 | W3 | scope-resolution | `86053f6` | **OK**(3 條路徑:impl 白名單 1 / qa 測試檔 2) | done(測試 165/0;無新增 gap) |
| 階段二 | W4 | vault-lifecycle, project-registry, machine-tools | `901764f` | **OK**(8 條路徑:3 impl 白名單 / 3 qa 測試檔 / 1 spec 文檔 / 1 編排者單線。**未追蹤那一行是空的**——無人自建 private helper 模組) | done(測試 310/0/3 pending;未結 gap G3/G4/G5) |

**跨子系統依賴**:`workspace` 只依賴 `graph-core`,而 graph-core 九個 feature 全數 `done`
(`readMarker` / `initVaultAt` / `markerDir` / `configPath` / `indexDbPath` / `atomicWriteText`
都已交付且在 2026-08-29 的 B2 對帳補進對外契約)。沒有需要「等」或「照介面約定先做」的項目。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 工作樹不乾淨且在 `main` 上,怎麼起跑 | 開分支 `feat/2026-08-29-subsys-workspace`,先把三份 design 的產出 commit 成一顆 | 全部波次的 checkpoint |
| D2 | 四個共用檔案(`aapms-workspace.cabal` / `cabal.project` / `test/Spec.hs` / `Types.hs`)怎麼安排,W4 才平行得安全 | 前三個由**編排者單線維護**,不進任何 feature 的寫入白名單(同 graph-core W6「骨架併入 cabal」的做法);`Types.hs` 在 W1 一次寫齊契約 A–F 的全部型別與 `WorkspaceError` 的建構子(W1 當下十六個;W3 閘門新增 `WriteTargetIdDrift` 成十七個),W2 之後沒人再碰它。另外**不設門面模組** `Aapms.Workspace`,界線由 `.cabal` 的 `exposed-modules` 守 | W1(Types 範圍擴大)、W4(平行安全的前提) |
| D3 | 閘門密度 | **標準**:議程為空時降級為非阻塞呈報,有任一條爭議點照常停 | 3c 波次閘門 |
| D4 | 這次跑到哪裡 | 兩個階段都跑完 | W1–W4 |
| D5 | 測試框架 | 沿用專案既有的 `hspec` + `hedgehog` + `hspec-hedgehog`(`store/aapms-store.cabal` 已在用),**不新引入依賴** | 全部 qa 委派 |

D2 的回寫已套進 `design.md`:「內部模組劃分」補上「Types 一次寫齊」與「不設門面模組」兩段,
`hub-registry` 契約卡的負責模組、實作介面、驗收標準與明確不做四欄同步更新。

## 配號表

| feature | id | 檔名 | 骨架檔案 | spec 模型 | qa 模型 | impl 模型 | 狀態 |
|---|---|---|---|---|---|---|---|
| hub-registry | F001 | F001-hub-registry.md | `workspace/src/Aapms/Workspace/Types.hs`<br>`workspace/src/Aapms/Workspace/Location.hs`<br>`workspace/src/Aapms/Workspace/Hub.hs` | opus | sonnet | sonnet | **impl-done**(80/0) |
| vault-discovery | F002 | F002-vault-discovery.md | `workspace/src/Aapms/Workspace/Discovery.hs` | opus | sonnet | sonnet | **impl-done**(125/0) |
| scope-resolution | F003 | F003-scope-resolution.md | `workspace/src/Aapms/Workspace/Scope.hs` | opus | sonnet | sonnet | **impl-done**(165/0) |
| vault-lifecycle | F004 | F004-vault-lifecycle.md | `workspace/src/Aapms/Workspace/Lifecycle.hs` | opus | sonnet | sonnet | **impl-done** |
| project-registry | F005 | F005-project-registry.md | `workspace/src/Aapms/Workspace/Projects.hs` | opus | sonnet | sonnet | **impl-done** |
| machine-tools | F006 | F006-machine-tools.md | `workspace/src/Aapms/Workspace/Tools.hs` | opus | sonnet | sonnet | **impl-done** |

**編排者單線維護、不進任何白名單的檔案**:`cabal.project`、`workspace/aapms-workspace.cabal`、
`workspace/test/Spec.hs`。

## 待確認假設彙總

| 來源 | 類型 | 契約錨點 | 波及 feature | 假設 / 決定 | 可逆性 | 閘門裁決 | 回寫位置 |
|---|---|---|---|---|---|---|---|
| F001 A1 + A2 | 待確認假設(合併) | 契約 A 的 `Hub`;契約 B 四個 getter;模組間公開介面 `Lifecycle → Hub` | F001(下游 F004 / F005) | `Hub` 不透明 + `mkHub` / `hubSourceText`;`Hub.hs` 補對稱的 `upsertProject` / `removeProject` | 有條件可逆 | **選 a**(照 spec 暫採) | design.md 契約 A + 模組間公開介面表(diff 已確認) |
| F001 A3 + S1 + S2 | 待確認假設(合併;S1 / S2 為編排者升級) | 契約 A 的 `loadHub`;契約 F 的 `HubMalformed`;契約 B 的 `veName` / `peName` / `veId` / `peId` 值域 | F001 | 對工具自己寫得出來的欄位從嚴(空 name、重複 id → `HubMalformed`),對未知鍵與未知頂層段從寬(容忍且保留) | 可逆 | **選 a**(照 spec 暫採) | design.md 契約 A 新增「`loadHub` 的合規判準」段(diff 已確認) |
| F001 依賴邊-1~3 | 新增依賴邊 | `Types → aapms-store`、`Hub → aapms-store`、`Location → aapms-core` | F001 | 三條在 design.md 散文裡都有依據,只是「模組間公開介面」表沒收 | 可逆 | **無真實第二方案,不上議程**;改為補表 | design.md 模組間公開介面表(diff 已確認) |
| F002 A1 | 待確認假設 | 模組間公開介面表的 `Scope → Discovery`;契約 C 的 `ScopeIssue` / `VaultRef.vrEntry`;契約 F 的 `MarkerUnreadable` | F002(下游 F003) | `readVaultRef` 拆成兩個:`VaultEntry ->`(已註冊,失敗是降級)與 `readVaultRefAt :: Hub ->`(探測到的,失敗是硬錯)。原簽名的 `Maybe VaultEntry` 在 `Nothing` 分支表達不出失敗——`ScopeIssue` 三個建構子都要求一列 `VaultEntry` | 有條件可逆 | **選 a**(照 spec 暫採) | design.md 模組間公開介面表 + 新增一段理由(diff 已確認) |
| F002 A2 + S3 + S8 + S1 | 待確認假設(合併;S1 / S3 / S8 為編排者升級) | 契約 C 的 `lookupSelector` 與 `vrPath` 值域欄;`detectVault` | F002(下游 F003 / F004 都寫「比對規則同 `lookupSelector`」) | `lookupSelector` 兩階段逐字精確比對(不 trim、不忽略大小寫),id 撞號與 name 撞名同一套處置;「已正規化」釘死成 `canonicalizePath`(否決 `makeAbsolute`);`detectVault` 起點不先驗存在性 | 可逆 | **選 a**(照 spec 暫採) | design.md 契約 C 的 `vrPath` 值域 + 新增「`lookupSelector` 的比對規則」段(diff 已確認) |
| F002 依賴邊-1 | 新增依賴邊 | `Discovery → aapms-store` | F002 | 表只列 `readMarker`,實際還用 `markerDir`(`.aapms` 目錄名的唯一真相在 graph-core) | 可逆 | **無真實第二方案,不上議程**;改為補表 | design.md 模組間公開介面表(diff 已確認) |
| F003 A1 | 待確認假設 | 契約 C 的 `resolveWrite` / `WriteScope.wsTarget`;契約 F 的 `NoWriteTarget` / `MarkerUnreadable`;契約 C 的 `ScopeIssue.VaultIdDrift` | F003(下游 F004 的 `syncHub`、`service` 的 `errorCode` 對照表) | 寫入目標 id 漂移時回什麼。spec 先證明「兩條來路的失敗型別」問題會自己消失(selector 那條也走 `readVaultRefAt`),**真正剩下的只有 id 漂移一格** | 可逆但有保存期限 | **選 c(非暫採的 a)**:契約 F 新增 `WriteTargetIdDrift VaultId FilePath VaultId`。採納 spec 的論證——W3 是單 feature 波次,此刻無並發對象,D2 的前提要到 W4 才生效,現在解凍 `Types.hs` 比 W4 之後便宜一個數量級;兩案函式簽名相同,改動只有五處、無 law 重寫、骨架不動 | design.md 契約 F(+1 建構子 +1 段語意說明);`Types.hs`(F001 impl);`TypesSpec.hs`(F001 qa);F003 spec 的 L13(b) / X19 / 資料流 |
| F003 S2 + S4 + S5 + S9 | 待確認假設(合併;四條**全部是編排者升級**) | 契約 C 的「refs 遞移展開」性質 3 / `rsVaults` 的保序去重 / `RefVaultNotRegistered` / `resolvePipeline` | F003 | 不可達節點**不展開**它自己的 `refs`(三種一視同仁,**含 marker 讀得到的 id 漂移**);BFS 種子優先;重複的未註冊目標只報一則;`resolvePipeline (Just X)` 且 X 不可達 → 空清單 + issue,不回 `VaultKindMismatch` | 可逆 | **選 a**(照 spec 暫採) | design.md 契約 C 新增「展開的走訪規則」四條;F003 spec 的 L7 / L19 / L20 / L21 / L22 升格為條文明文 + 新增 X36 |
| W4 缺陷-1 | 已交付程式碼的缺陷 | `Hub.hs` 的 `quoteText`;契約 A 的 `saveHub` / `loadHub` | F001(F004 / F005 的名稱都走同一個序列化器) | `quoteText` 只逸出 `"` 與 `\`,不逸出控制字元 → 含換行的名稱會讓 `saveHub` 寫出非法 TOML,`loadHub` 回 `HubUnreadable`:**工具寫出一份自己讀不回來的中樞**。由 F005 撞出(它只能縮小自己 L8 的定義域來迴避——spec 遷就 bug) | 可逆 | **現在修,當成 W4 的一部分** | `Hub.hs`(F001 impl,完整 TOML 逸出);F001 新增 **L18 + X28/X29** 回歸 law;F005 的 L8 定義域放寬回完整 |
| F005 A1 | 待確認假設 | 契約 D 的 `registerProject`;契約 B 的 `pePath` 值域 | F005 | 同一路徑註冊兩次的語意(契約卡刻意留的二選一) | 可逆 | **選 b:回明確錯誤**,新增 `ProjectAlreadyRegistered` | design.md 契約 F;F005 的 L9 / X17 / 資料流 |
| F004 A6 + F005 A2 + F005 A1 + F004 A8 | 待確認假設(合併:`Types.hs` 的第二次解凍) | 契約 F 的建構子清單 | F004、F005 | 四個建構子一起補。**共同判準**:借用既有建構子會讓訊息**說出一件假的事**——與 W3 新增 `WriteTargetIdDrift` 同一條 | 難逆(對外錯誤語彙) | **四個一起補**:`ProjectSelectorAmbiguous` / `ProjectAlreadyRegistered` / `VaultInitFailed` / `DeleteTargetIdDrift`。契約 F 從 17 → **21** | design.md 契約 F(+4 建構子 +1 對照表);`Types.hs` 與 `renderWorkspaceError`(F001 impl);`TypesSpec.hs`(F001 qa);F004 / F005 兩份 spec |
| F004 A5(推翻) | 待確認假設 | 契約 D 的 `forgetVault` / `purge`;契約 B 的 `vePath`(快取);契約 C 性質 1 | F004 | 刪 `index.db` 前要不要驗身分。spec 暫採「只依 `vePath` 刪」**被推翻** | 可逆 | **讀得到且 id 對不上就拒絕**;讀不到照刪(那是 forget 最常見的理由) | design.md 契約 D 新增「刪索引前先驗身分」段;F004 的 L45–L47 / X41–X45 |
| F005 A5 + F006 A1 | 待確認假設(合併:可測性缺口) | 契約 D 的 `registerProject`;契約 E 的 `detectSevenZip` | F005、F006 | 兩條驗收標準在現行簽名下**驗不到**(時間內部取樣造不出碰撞;候選清單寫死而本機 7-Zip 實際存在) | 可逆 | **兩個都加**:`allocateProjectId` / `ToolSearchPlan` + `detectSevenZipIn`,原簽名一字不動。先例:graph-core `allocateId` 的 G8 裁決 | design.md 契約 D / E;F005 / F006 兩份 spec |
| F005 A6 | 待確認假設 | 契約 F 的 `ProjectAlreadyRegistered` 的觸發條件;契約 B 的 `pePath` 值域 | F005 | 「同一個路徑」怎麼算 | 可逆 | **編排者裁定照暫採 a**(比對正規化後的新路徑 vs 既有列原文)。另兩案各有致命缺陷:對既有列重新正規化會讓「擋不擋得住」取決於**別的專案目錄還在不在**;把正規化升進 `loadHub` 要拿 ADR-017 的「可手寫」去換且對既有手寫中樞是破壞性的。已知缺口(手寫未正規化路徑擋不住)由 **X29 明文斷言**,不靜默 | F005 的 A6 裁決欄 |
| F004 A1/A2/A3/A4/A7 · F005 A3/A4 · F006 A2/A3/A4/A5 | 待確認假設(**編排者降級 11 條**) | 各自的契約條目 | F004 / F005 / F006 | 沿用既有裁決或無真實第二方案 | — | **不上議程**。其中 F004 A2 + F005 A4(名稱 trim)的**決定性理由不在任何一份 spec 裡**:W2 已裁 `lookupSelector` 逐字精確比對,存未 trim 的名稱會讓它**永遠選不到**——trim 是被前一條裁決逼出來的 | 三份 spec 的裁決欄 |
| F004 依賴邊-1~2 · F005 依賴邊-1 | 新增依賴邊 | `Lifecycle → aapms-store`(+`markerDir` / `readMarker` / `vm*` 存取子)、**新增** `Lifecycle → Location`、`Projects → Hub`(+`hubProjects`) | F004、F005 | 表沒列全 | 可逆 | **無真實第二方案,不上議程**;補表 | design.md 模組間公開介面表 |
| F003 依賴邊-1~2 | 新增依賴邊 | `Scope → aapms-store`、`Scope → Discovery` | F003 | 前者是 `vmId` / `vmKind` / `vmRefs` 三個欄位存取子 + `VaultKind` 型別(`Types.hs` 裸型別 import 轉不出存取子,`VaultKind` 也不在 Types 的匯出清單);後者是表漏列 `lookupSelector` | 可逆 | **無真實第二方案,不上議程**;改為補表 | design.md 模組間公開介面表(diff 已確認) |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| F001 S1 | 未知鍵與未知頂層段的處置 | 容忍且原樣保留,不是 `HubMalformed` | `loadHub`、`HubMalformed` | 自報 → **編排者升級** | (已併入閘門裁決,照 a) |
| F001 S2 | 中樞內重複 id 的處置 | `HubMalformed`,沿用既有建構子 | `loadHub`、`HubMalformed`、`veId`、`peId` | 自報 → **編排者升級** | (已併入閘門裁決,照 a) |
| F001 S3 | `saveHub` 不建立父目錄 | 失敗原樣包成 `HubWriteFailed` | `saveHub`、`HubWriteFailed`、`atomicWriteText` | 自報(升級篩命中,但**沿用契約卡「明確不做」**,不上閘門) | |
| F001 S4 | 平台預設路徑怎麼取 | `getXdgDirectory XdgConfig "aapms"`,不寫平台分支 | `hubLocation`、`hlPath`、`FromPlatformDefault` | 自報(升級篩命中,**編排者降級**:寫不出真實的第二方案) | |
| F001 S5 | `Hub` / `WorkspaceError` 的 deriving | derive `Show` / `Eq`;`LlmSection` 走 `deriving newtype` | `Hub`、`WorkspaceError`、`LlmSection` | 自報(升級篩命中,**編排者降級**:hspec 的硬需求) | |
| F002 S1 | `detectVault` 起點不先驗存在性 | 不存在也照樣往上走 | `detectVault` | 自報 → **編排者升級** | (已併入閘門裁決) |
| F002 S2 | 向上探測的終止條件 | `takeDirectory p == p`(不動點),不寫平台分支 | `detectVault`、`takeDirectory` | 自報(升級篩命中,**編排者降級**:無真實第二方案) | |
| F002 S3 | 三種降級的判定順序與帶哪個路徑 | 依「路徑 → marker → id」;`VaultPathMissing` 帶正規化後的路徑 | `readVaultRef`、`VaultPathMissing`、`VaultMarkerBroken`、`VaultIdDrift`、`vrPath` | 自報 → **編排者升級** | (已併入閘門裁決) |
| F002 S4 | `readVaultRefAt` 不先 `doesDirectoryExist` | 路徑不存在時 `readMarker` 本來就回 `VaultMarkerMissing` | `readVaultRefAt`、`MarkerUnreadable`、`readMarker` | 自報(升級篩命中,**編排者降級**:契約 F 這一路只給了一個建構子,無第二方案) | |
| F002 S5 | `Discovery` 的匯出清單 | 只有四個函式,不轉出任何型別 | `VaultRef`、`ScopeIssue`、`VaultEntry`、`Hub`、`WorkspaceError` | 自報(升級篩命中,**編排者降級**:W1 已立「型別一律去 Types 找」的慣例) | |
| F002 S6 | `.aapms` 目錄名從哪來 | 用 graph-core 的 `markerDir`,不自己寫字面值 | `markerDir` | 自報(升級篩命中,**沿用** B2 對帳的知識歸屬裁決) | |
| F002 S7 | 骨架不寫「只有本體才用得到」的 import | 維持 `-Wall` 零警告;L18(b) 因此寫成條件式 | `markerDir`、`readMarker`、`hubVaults`、`VaultId` | 自報(升級篩命中,**編排者降級**:無真實第二方案) | |
| F002 S8 | 「正規化」的定義 | 全篇釘死 `canonicalizePath`,不是 `makeAbsolute` | `detectVault`、`readVaultRef`、`readVaultRefAt`、`vrPath` | 自報 → **編排者升級** | (已併入閘門裁決) |
| F003 S1 | `NoWriteTarget` 帶哪個起點 | `canonicalizePath start`,不是原樣的第三參數 | `resolveWrite`、`NoWriteTarget`、`canonicalizePath` | 自報(升級篩命中,**沿用** W2 釘死的 `canonicalizePath`) | |
| F003 S3 | 擋環用的 visited 鍵 | 「走到它時用的 `VaultId`」,`Data.Set` | `vmId`、`vmRefs`、`veId`、`VaultId` | 自報(邊界 不會,**維持自裁**) | |
| F003 S6 | 無 selector 時 kind 不符的處置 | 靜默排除,不產生 `ScopeIssue` | `psRuns`、`psIssues`、`vmKind` | 自報(升級篩命中,**沿用契約卡驗收標準原文**「無 selector 時 `psRuns` 只含 `vmKind` 相符者」) | |
| F003 S7 | `resolvePipeline` 要不要展開 `refs` | 兩條路都不展開 | `resolvePipeline`、`psRuns`、`vmRefs` | 自報(升級篩命中,**沿用 ADR-017**:`refs` 是收窄時的**讀取**集合,pipeline 是「各跑一次、每次只寫自己的索引」) | |
| F003 S8 | `VaultKindMismatch` 第一個值取哪個 id | `vmId`(marker),不是 `veId` | `VaultKindMismatch`、`vmId`、`veId` | 自報(升級篩命中,**沿用契約 C 性質 1**「marker 是真相」) | |
| F003 S10 | 保序去重的鍵與保留哪一次 | 以 `vmId`、保留**首次**出現位置 | `rsVaults`、`wsRead`、`psRuns`、`vmId` | 自報(升級篩命中,**沿用契約卡原文**「順序是第一次出現的位置」) | |
| F003 S11 | 模組匯出清單 | 只有三個函式,不轉出型別 | `resolveRead`、`resolveWrite`、`resolvePipeline` | 自報(升級篩命中,**沿用** W1/W2 的慣例) | |
| F003 S12 | 骨架不寫「只有本體才用得到」的 import | L25(b)/(f) 因此寫成條件式 | `readVaultRef`、`readVaultRefAt`、`detectVault`、`lookupSelector`、`hubVaults`、`vmId`、`vmKind`、`vmRefs`、`canonicalizePath` | 自報(升級篩命中,**沿用** F002 S7 的同一裁決) | |
| W4 升級篩統計 | (編排者記錄)**門檻收緊生效**:三份 spec 交出 **17 條假設全部正確歸位、12 條自裁全部兩問皆否,升級篩零命中** | 對照 W3:12 條自裁裡九條的層級自答自己寫著「邊界:會」,升級率 52% | — | 編排者升級篩 | **差別就是三份 prompt 帶的那一句規則**。自裁 12 條全部維持自裁,理由逐條:F004 S1/S2/S3/S5 與 F006 S1/S2 是「兩種寫法結果相同、對外不可觀察」;F005 S1/S2 沿用 graph-core `allocateId` 的既有先例;F004 S4 觸及符號為「無」;F005 S3 / F004 S11 沿用 W1–W3 的匯出清單慣例;F005 S6 是檢查順序,由危害論述決定 |
| F003 升級篩統計 | (編排者記錄)spec 的 12 條自裁裡,**S1 / S2 / S4 / S5 / S6 / S7 / S8 / S9 / S10 九條的層級自答自己寫著「邊界:會」** | 依 `boundary-rules.md`「任一為是即契約層級」,它們本來就不該進自裁清單 | — | 編排者升級篩 | **spec 的層級門檻偏鬆**,W4 的委派 prompt 要求「邊界:會」一律寫進待確認假設,不得放進自裁記錄 |
| F002 impl-1 | (協議偏離,記錄備查)L18(b) 與 L12(c)/L14 矛盾時 impl **沒有停下該項**,而是暫採 `VaultMarker (..)` 並如實回報 | — | `vmId`、`VaultMarker` | 編排者記錄 | **可接受**:該 law 管的是 import 行本身,不寫某個 import 就編不出來,實務上沒有「停下」這個選項;impl 有完整回報,未隱瞞 |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| F001 | 0 | 骨架快照紅綠基線(`ws-w1` @ `d23f24c`) | L1–L17 / X1–X27 全體 | **符合預期**:80 條中 5 綠(L16 的 `mkHub` 往返 + L17 的四條 import 檢查,皆為骨架自身承載的事實),其餘 75 條紅 | 無需處置,**無假綠** |
| F002 | 0 | 骨架快照紅綠基線(`ws-w1` @ `5b8e104`) | L1–L18 / X1–X24 全體 | **符合預期**:125 條中 86 綠(W1 的 81 條 + F002 的 L18 五條 import law),F002 的其餘 39 條全紅 | 無需處置,**無假綠** |
| F002 | 1 | `test_discovery_marker_import_is_id_reader_only`(L18(b)) | L18(b) 的逐字 import 字串,與 L12(c) / L14 的 `vmId` 比對 | **spec bug**——同一份 spec 內部矛盾:(b) 的白名單只有 `markerDir` / `readMarker`,但 L12(c) / L14 要用 `vmId`,而 `Types.hs` 是裸型別 import、轉不出欄位存取子。**qa 與 impl 互相不可見,卻各自從相反方向撞到同一條**(impl:照 spec 寫編不出來;qa:照 spec 寫恆紅) | 停下回報開發者 → 裁決收緊成 `VaultMarker (vmId)` → spec 改條文、impl 收窄 import、qa 對齊期望值 |
| F003 | 0 | 骨架快照紅綠基線(`ws-w1` @ `86053f6`) | L1–L25 / X1–X36 全體 | **符合預期**:165 條中 133 綠(W1/W2 的 127 條 + F003 的 L25 六條 import law),F003 其餘 32 條全紅 | 無需處置,**無假綠**;本 feature 零仲裁輪次 |
| F001 | 1 | `test_types_imports_marker_type_only`(L17(d)) | L17(d):「`Types.hs` 對 `Aapms.Store.Marker` 的 import 行必須逐字是 `import Aapms.Store.Marker (VaultMarker)`」 | **qa 誤讀**——測試沒有正規化行尾。law 講的是 import 行的**內容**,而 `\r` 是行終止符的產物;主樹的檔案是 LF、快照 worktree 是 git 全新 checkout 轉成的 CRLF,所以只在後者紅。**這不是快照假象:任何人重新 clone 到 Windows 都會紅** | 附條文原文重派 qa 改測試(五條 L17 共用同一套去 `\r` 的正規化);**不動 spec、不動實作** |

## 階段結果

### 階段一(2026-08-29 完成)

**完成**:F001 / F002 / F003 三個 feature,介面 18/18 落地(11 + 4 + 3),零警告。
測試 **165 examples / 0 failures**;全專案 **1043 examples / 0 failures**。

**qa 紅綠基線**(三波各在骨架快照的獨立 worktree 上驗過,**零未驗證**):

| 波次 | 快照 | 綠 / 紅 | 是否符合 spec 預期 |
|---|---|---|---|
| W1 | `d23f24c` | 6 / 75 | ✅ 綠的正是 L16 + L17 五條 import law |
| W2 | `5b8e104` | 86 / 39 | ✅ F002 那 44 條是 5 綠(L18 a–e)/ 39 紅 |
| W3 | `86053f6` | 133 / 32 | ✅ F003 那 38 條是 6 綠(L25 a–f)/ 32 紅 |

**白名單對帳**:三波全 `OK`,零違規。

**仲裁**:2 輪(W1 一輪歸因 qa 誤讀、W2 一輪歸因 spec bug),W3 零輪。

**spec-gaps**:G1 / G2 皆 resolved,**無未結條目**。

**契約裁決**:不可逆決定 0 條(新增);新增依賴邊 6 條(全部「散文有、表沒有」,無真實第二方案,
補表);契約層級假設 6 組(合併前 20 條)。**契約 F 從十六個建構子成長為十七個**
(`WriteTargetIdDrift`,W3 閘門)。

**自裁清單**:25 條。其中**編排者升級 13 條**、降級 9 條、沿用既有裁決 3 條。
升級比例偏高(52%),原因明確:F003 的 spec 有九條自裁的層級自答自己寫著「邊界:會」——
依 `boundary-rules.md` 那就是契約層級。**W4 的委派 prompt 已收緊這條門檻**。

**arch-audit subsys 發現**(依嚴重度):

1. **[中] `workspace` 消費了三個不在 graph-core 對外契約裡的符號**:`readTextFile`
   (`Aapms.Store.Atomic`)、`renderVaultKind` / `parseVaultKind`(`Aapms.Store.Schema`)。
   與 2026-08-29 B2 對帳補進去的那四個同一類:程式碼有、散文有,契約章節沒有。
   建議比照處理,補進 graph-core 契約 E(純文檔)
2. **[低] L25 的 import 白名單可能開太緊**:F003 的 impl 為了不 import `Aapms.Core.Id`,
   刻意讓內部 `loop` helper **不寫顯式型別簽名**,靠型別推導取得 `VaultId`。編得過、law 也綠,
   但「靠省略簽名滿足 import 白名單」是訊號——`VaultId` 是正當需求
3. **[低,既有] graph-core 的 `md` / `store` / `core` 測試套件有 `-Wmissing-home-modules` 警告**,
   與 workspace 無關;`aapms-workspace-test` 已補乾淨
4. **[資訊] 程式碼知識圖覆蓋率 17%**(70/407):成因是測試目錄刻意不列進 `code-paths`、
   四個尚未設計的子系統、以及 `legacy/`。依賴矩陣的結論只在 graph-core / workspace /
   service / shell 之間可信

**方向與循環**:圖已重繪至 `27d2499`。**無子系統層級循環依賴**;`workspace → graph-core`
92 條、方向單一、反向零。套件內模組方向 `Types ← Location ← Hub ← Discovery ← Scope`
**逐條符合 design.md**,無回頭邊。

**抽象邊界**:`design.md` 全文零私有 helper 名(逐一掃過 `walkAll` / `expandRefs` / `nubOn` /
`resolveWriteTarget` / `importLinesOf` 等九個,全部 0 命中)。契約卡的負責模組與實際落地檔案
逐一相符。

### 階段二
(待跑)

### 階段二
(待跑)
