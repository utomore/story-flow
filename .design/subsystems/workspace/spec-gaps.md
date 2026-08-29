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
