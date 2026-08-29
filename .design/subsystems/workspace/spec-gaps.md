---
id: workspace-spec-gaps
type: spec-gaps
title: workspace-spec-gaps
description: workspace 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: resolved
created: 2026-08-29
updated: 2026-08-29
parent: workspace
---

# workspace spec 缺口

## G1(F001 / qa)

- **模糊點**:F001 的 L17(c) 寫「**三個檔案**都不 import `Aapms.Store.Marker`」,但同一份 spec
  的「契約 C(只有型別宣告)」與「使用到的既有串接介面」表要求 `Types.hs` 的
  `VaultRef` 帶 `vrMarker :: VaultMarker`,而該型別**只能**從 `Aapms.Store.Marker` 取得。
  骨架 `Types.hs` 因此已經是 `import Aapms.Store.Marker (VaultMarker)`——law 與介面表在同一份
  spec 內互相矛盾。
- **卡住的項目**:L17(c) 對 `Types.hs` 那一檔的斷言。qa 只對 `Location.hs` / `Hub.hs` 兩檔翻譯了
  這條(兩者確實不 import,骨架上綠),`Types.hs` 的部分停下未測。
- **需要 spec 回答什麼**:L17(c) 的「三個檔案」是否應改成「僅 `Location.hs` / `Hub.hs`」,把
  `Types.hs` 明確排除在此限制外?(這條 law 的用意看起來是「本 feature 不做 marker 的**讀取**」,
  而 `Types.hs` 只是引用型別、不呼叫 `readMarker`——若是,law 的措辭要改成針對 `readMarker` /
  `markerDir` 這幾個**函式**,而不是針對模組 import。)
- **狀態**:resolved(2026-08-29 W1 閘門裁決:L17(c) 拆成 (c)+(d)——`Location.hs` / `Hub.hs` 完全不得 import `Aapms.Store.Marker`;`Types.hs` 的 import 行必須逐字是 `import Aapms.Store.Marker (VaultMarker)`,只拿型別、拿不到任何函式。spec 已改,qa 已補 (d) 的斷言)

## G2(F002 / impl)

- **模糊點**:F002 的 L18(b) 規定「若有對 `Aapms.Store.Marker` 的 import 行,它必須**逐字是**
  `import Aapms.Store.Marker (markerDir, readMarker)`」。但 L12(c) 的 `readVaultRef` 與 L14 的
  `readVaultRefAt` 都要從 `VaultMarker` 取出 `vmId` 做 id 漂移比對,而 `vmId` 是 record 欄位,
  只能經 `VaultMarker (..)` 取得。`Aapms.Workspace.Types` 對它的 import 是逐字 `(VaultMarker)`
  (裸型別,已由 F001 的 L17(d) 釘死),因此**沒有任何轉出管道**。
  逐字比對要求的那兩個名字**做不出**同一份 spec 其他 law 要求的行為。
- **卡住的項目**:L18(b) 的逐字比對測試。impl 為了不讓 L10–L17 的功能本體全部停擺,暫採
  `import Aapms.Store.Marker (VaultMarker (..), markerDir, readMarker)` 並如實回報;
  qa 若照 spec 字面翻譯,那條測試會紅。
- **需要 spec 回答什麼**:L18(b) 的逐字字串應該是 `(markerDir, readMarker)` 還是
  `(VaultMarker (..), markerDir, readMarker)`?
- **佐證**(編排者查證):`store/src/Aapms/Store/Marker.hs` 的匯出清單是 `VaultMarker (..)`;
  `workspace/src/Aapms/Workspace/Types.hs:65` 是 `import Aapms.Store.Marker (VaultMarker)`。
  兩者合起來確認「Types 拿不到欄位存取子、也就轉不出去」這個前提成立。
- **狀態**:resolved(2026-08-29 W2 閘門裁決:逐字字串**收緊**成 `import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)` —— 只放行 `vmId` 一個欄位存取子,不是 `VaultMarker (..)`。這條 law 從此守的是「Discovery 只讀 id」:日後在本模組碰 `vmRefs`(#3)或 `vmKind` 會紅。spec 已改條文、紅綠預期與對照表(測試名同步改為 `test_discovery_marker_import_is_id_reader_only`);impl 已收窄 import 行;qa 已對齊期望值)

## G3(F006 / impl)

- **模糊點**:F006 的「使用到的既有串接介面」表與 **L15(f)** 都宣稱 `exeExtension :: String` 由
  `filepath` 的 `System.FilePath` 匯出;實測**它不在那裡**——本專案釘住的 `filepath-1.5.4.0` 的
  `System.FilePath` / `.Windows` / `.Posix` 三個模組都沒有它,`System.Info` 也沒有。它實際由
  **`directory-1.3.10.0` 的 `System.Directory`** 匯出,值是 `".exe"`(**含前導點**)。
- **卡住的項目**:**L15(d)**(`System.Directory` 的 import 白名單 `{doesFileExist, executable,
  getPermissions}`)與 **L15(f)**(`System.FilePath` 白名單含 `exeExtension`)。「可編譯」與
  「逐字滿足這兩條白名單」**無法同時成立**:照 L15(f) 從 `System.FilePath` import 會編譯失敗;
  從實際存在它的 `System.Directory` import(impl 採此法,已編譯通過、零警告、L1–L14 行為滿足)
  則 import 行超出 L15(d) 的字面白名單,對應的 law-test 會紅。
- **需要 spec 回答什麼**:把 `exeExtension` 從 L15(f) 的 `System.FilePath` 白名單**移到** L15(d) 的
  `System.Directory` 白名單,並同步修正「相依性查證」事實 5 與「使用到的既有串接介面」表的來源
  欄——對嗎?
- **編排者查證**(2026-08-29):`cabal exec -- ghc -e ':m System.Directory' -e 'exeExtension'`
  → `".exe"`;同一道指令對 `System.FilePath` / `.Windows` / `.Posix` / `System.Info` 皆
  `Variable not in scope`。impl 改用 `System.Directory` 之後 `cabal build aapms-workspace:lib`
  通過。
- **過程觀察**(記錄備查,非本 gap 的一部分):F006 的 spec 把這一點寫在「平台可攜性」的**實測**
  清單裡,但它沒有真的驗過那個符號的來源。`delegation.md` 第 5 條把「相依性查證:打開原始碼讀
  真實簽名」列為**委派模式下品質的唯一防線**——這次是同一波另外兩個 impl 因為共用 build target
  而在幾分鐘內從外部撞出來的,不是防線自己接住的。
- **狀態**:**resolved**(2026-08-29 W4 閘門:spec 已把 `exeExtension` 從 L15(f) 移到 L15(d);編排者三處機械驗證一致——`Tools.hs` 從 `System.Directory` import、spec 的事實 5 與串接介面表已更正、`ToolsSpec` 的白名單斷言對齊,F006 的 34 條全綠)

## G4(F004 / qa)

- **模糊點**:F004 的 X18 原文「以固定時間 / 名稱造出撞號」假設 qa 能可控地讓兩次 `initVaultAt`
  呼叫產生同一個 id;但 `newId` 的演算法屬 graph-core 的**已凍結實作**,而 qa 依角色禁區**不得讀**。
- **卡住的項目**:L18、L19、X18、X19——`initVault` **撞號分支的全部斷言**。
- **需要 spec 回答什麼**:本機對同名連續呼叫兩次 `initVaultAt` 實測得到**兩個不同 id**
  (`vlt-1c5bcb0f` / `vlt-b8122656`)。請補一個 qa 可用、不需讀 graph-core 內部實作就能
  **確定性重現撞號**的做法,或改變 X18 / X19 的觀察點。
- **狀態**:**已裁決,待 graph-core 修**(2026-08-29 階段二閘門)。裁決:把 `initVaultAt` 的時間提成明碼參數,與 graph-core 自己的 `allocateId`(G8)一致 → 追蹤於 **`graph-core/enhancements/E002-init-vault-at-explicit-time.md`**,與 B002 同一輪做。修完後本條結案、L18 / L19 / X18 / X19 從 `pendingWith` 轉正式斷言

## G5(F004 / qa)

- **模糊點**:F004 的 X41 原文假設 `initVaultAt` 對檔案系統失敗會回 `Left`;但本機實測
  「vault 根目錄的父層被一個檔案佔住」這個建構,會讓 `initVaultAt` 內部的
  `createDirectoryIfMissing` 把 `CreateDirectory AlreadyExists` 這個 `IOException`
  **未捕捉地往上拋**,不是回傳 `Left`。
- **卡住的項目**:L44、X41——**`VaultInitFailed` 的唯一驗收路徑**。
- **需要 spec 回答什麼**:兩條路二選一——(a) 補一個確定會讓 `initVaultAt` 回 `Left` 的具體重現
  方式;或 (b) 明訂 `initVault` 要把這類逸出的 `IOException` 轉成 `WorkspaceError`(那是一條新
  law,而且會讓 `VaultInitFailed` 從「幾乎測不到」變成「正常路徑」)。
- **編排者註記**:這條與 F006 的注入接縫是**同一類問題**——契約寫了一個錯誤值,但它在真實環境
  裡幾乎觸發不到,於是那條驗收標準沒有人驗得了(A9 可測性)。差別是 F006 那次能靠加一個明碼參數
  解決,這次牽涉的是 graph-core 的例外行為,選 (b) 等於在 workspace 這層補一道例外邊界。
- **狀態**:**已裁決,待 graph-core 修**(2026-08-29 階段二閘門)。裁決:**修 graph-core**,讓 `initVaultAt` 不逸出 `IOException`(型別已承諾 `Either StoreError`),不在 workspace 這層補例外邊界 → 追蹤於 **`graph-core/bugfixes/B002-init-vault-at-leaks-io-exceptions.md`**,與 E002 同一輪做。修完後本條結案、L44 / X41 從 `pendingWith` 轉正式斷言
