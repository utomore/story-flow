---
id: workspace-spec-gaps
type: spec-gaps
title: workspace-spec-gaps
description: workspace 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: open
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
- **狀態**:open
