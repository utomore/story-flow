---
id: graph-core-spec-gaps
type: spec-gaps
title: graph-core-spec-gaps
description: graph-core 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: in-progress
created: 2026-08-24
updated: 2026-08-24
parent: graph-core
---

# graph-core spec 缺口

## G1(F004 / impl → F008 / spec)

- **模糊點**:契約 E 的 `NewSection` 只有 `nsMeta :: MetaOverride` 一個管道寫節層欄位,而
  `MetaOverride`(`md/src/Aapms/Md/Inherit.hs:46-58`,13 個欄位)**沒有** asset 的 `sha256` /
  `entry` / `ext` / `meta` / `license` / `author`,也沒有 license 的八個授權維度
- **卡住的項目**:`appendSection` 與契約 E 的 `addSection` / `createPackFile` 寫不出能通過
  `toPack` / `toLicenses` 驗證的完整新節;F008 的驗收標準「`createPackFile` 在指定目錄寫出 `pack.md`,
  節的順序與給定順序相同」因此做不下去
- **需要 spec 回答什麼**:節層的型別專屬欄位要走哪個管道?
- **狀態**:**resolved**(2026-08-24 開發者裁決)——`NewSection` 改成對節點種類做 sum
  (`NewSectionPayload` = `NSFragment` / `NSAsset` / `NSLicense` / `NSNode`,封閉建構子),
  `addSection` 維持單一入口依 payload 分派。已回寫 `design.md` 契約 D;
  `createPackFile` 第三參數連帶由 `[NewAsset]` 改為 `[NewSection]`(契約 E)

## G2(F008 / spec)—— 已重現的資料遺失缺陷

- **模糊點**:不是 spec 模糊,是**已交付的程式碼有缺陷**。`Aapms.Md.Render.reserialize`
  (`md/src/Aapms/Md/Render.hs:98`)在 `updateSection` 時用 `renderMetaBlock`
  (`:384`)**整塊重寫** ` ```meta ` 區塊,而 `renderMetaBlock` 只認得 `MetaOverride` 的 13 個欄位
  (`field` 的 catch-all 是 `_ -> []`)。`AssetFields` / `LicenseFields`(`Parse.hs:216` / `:281`)
  從同一個區塊解出來,卻不在 `MetaOverride` 裡
- **後果**:對 pack.md 的 asset 節或 licenses.md 的 license 節做**任何** `updateSection`,都會
  **靜默刪掉** `sha256` / `entry` / `ext` / `meta` / `license` / `author` 與八個授權維度。
  依 ADR-013,`pack.md` 是素材中繼資料的**真相**——這等於永久破壞「這個節點指向壓縮檔的哪個條目」
  與內容雜湊
- **編排者實測重現**(2026-08-24,GHCi 對 `c9f6fe4` 的程式碼):對一個含
  `sha256: deadbeef1234` / `entry: PNG/a.png` 的 asset 節呼叫
  `updateSection aid (\o -> o { moSummary = Just "after" })`,寫回後那兩行消失
- **為什麼沒被測到**:`md/test/` 沒有任何測試把 `updateSection` 與 `sha256` 放在一起
- **狀態**:**open** → 由 **F004 重跑**修復(2026-08-24 開發者裁決),與 G1 同一個根
  (`MetaOverride` 是唯一管道),一併處理:`Render` 要支援 payload 專屬欄位的序列化,
  並新增 payload 保留的編輯路徑讓 `updateSection` 不再吃掉節專屬欄位
