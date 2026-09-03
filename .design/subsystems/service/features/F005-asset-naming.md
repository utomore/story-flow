---
id: F005
type: feature
title: asset-naming
description: `setAssetName` 的全域唯一、`updateAssetMeta`、`upsertLicense`
status: planned
stage: S3
modules: [Write, Validate]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F004]
related-adr: []
related-feature: []
code-paths: []
---

# F005: asset-naming

## 契約

- **階段**:階段二
- **負責模組**:Write、Validate
- **實作的 Level 2 介面**:契約 E 的 `setAssetName` / `updateAssetMeta` / `upsertLicense`;
  契約 F 的 `LogicalNameTaken`;使用 service/F001-service-env-and-scope 的 `withRead` 取「全部已註冊」範圍(無新增)
- **資料流管線段落**:寫入管線的驗證段多一條分支(`setAssetName` 另取全部已註冊範圍查
  `lookupByName`),之後併回同一條落地路徑
- **驗收標準**:
  - 在 vault A 已有邏輯名稱 `N` 的情況下,於 vault B 用 `--vault B` 收窄執行 `setAssetName ... N`
    **仍然**回 `LogicalNameTaken`,且錯誤帶 A 那筆的 `<vault>:<id>` — 觀察點:契約 E 的
    `setAssetName`、契約 F 的 `LogicalNameTaken`
  - 上述檢查涵蓋**全部已註冊 vault**,與本次 `--vault` / `refs` 的範圍無關:把 B 的 `refs` 清空後
    重跑,結果不變 — 觀察點:契約 E 的 `setAssetName`
  - 名稱不合命名文法(第一段不在該型別的 `name_kinds`、或分段規則不符)時回 `ValidationFailed`,
    訊息來自 graph-core 的 `NameError` 而非本層自寫 — 觀察點:契約 F 的 `ValidationFailed` 與
    `renderServiceError`
  - `updateAssetMeta` 改寫 asset 專屬欄位後,同一節的**其他型別專屬條目與正文位元組不變**
    (graph-core 的 `MetaExtras` 機制沒有被繞過) — 觀察點:契約 E 的 `updateAssetMeta`、
    契約 B 的 `nvDetail`
  - `upsertLicense` 對已存在的 `lic-` 節點是更新而非新增:節點數不變、`revision` +1 — 觀察點:
    契約 E 的 `upsertLicense`、契約 C 的 `vaultInfo`
  - 唯一性檢查失敗時檔案未動 — 觀察點:契約 E 的 `setAssetName`
- **明確不做**:不推論名稱(叢集規則屬 `asset-ingest`);不判斷授權(閘門屬 `project`);
  不定義命名文法本身(graph-core)
