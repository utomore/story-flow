---
id: F004
type: feature
title: node-write
description: 建立 / 片段 / 改寫 / 刪除、樂觀鎖、五條業務驗證
status: planned
stage: S3
modules: [Write, Validate]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F003]
related-adr: []
related-feature: []
code-paths: []
---

# F004: node-write

## 契約

- **階段**:階段二
- **負責模組**:Write、Validate
- **實作的 Level 2 介面**:契約 E 的 `createEntity` / `addFragment` / `updateMeta` / `setBody` /
  `deleteNode` / `addLink` / `removeLink` / `DeleteReport` 與請求型別;契約 F 的 `ValidationFailed` /
  `UnknownType` / `DanglingLinkTarget` / `LinkTargetOutOfScope` / `LevelTreeInvalid` /
  `RevisionConflict`;模組間公開介面的 `validateForWrite`
- **資料流管線段落**:寫入管線自 `Scope.withWrite` 之後到新 `revision` 投影回 `NodeView` 為止
- **驗收標準**:
  - 沒有 `--vault` 且從 cwd 向上找不到 `.aapms/` 時,任一寫入操作都回
    `WorkspaceFailed NoWriteTarget`,且**沒有任何檔案被建立或修改** — 觀察點:契約 E 的寫入組、
    契約 F 的 `WorkspaceFailed`
  - 寫入只落在 `wsTarget` 一個 vault:讀取範圍內其他 vault 的檔案與索引位元組不變 — 觀察點:
    契約 E 的寫入組、契約 C 的 `vaultInfo`(節點數不變)
  - 給出的 `revision` 不等於目標當前值時回 `RevisionConflict` 並同時列出期望與實際,且檔案未動 —
    觀察點:契約 F 的 `RevisionConflict`
  - 成功寫入後回的 `nvMeta` 的 `metaRevision` 恰好是原值 +1 — 觀察點:契約 B 的 `nvMeta`
  - 建立時給註冊表沒有的型別回 `UnknownType`;必填欄位缺漏回 `ValidationFailed` 並帶那些警告,
    而**非必填類的警告不擋**、只出現在成功結果的 `nvWarnings` — 觀察點:契約 F 的兩個建構子、
    契約 B 的 `nvWarnings`
  - 關聯目標的 vault 在讀取範圍內但節點不存在 → `DanglingLinkTarget`;目標 vault 不在讀取範圍內
    → `LinkTargetOutOfScope`,且訊息含「加進 `refs`」或「用 `--vault` 展開」的下一步 — 觀察點:
    契約 F 的兩個建構子與 `renderServiceError`
  - 任一驗證失敗時**檔案與索引都未被修改**(先驗證後落地) — 觀察點:契約 E 的寫入組
- **明確不做**:不碰 asset 專屬欄位與命名(service/F005-asset-naming);不碰 Level / Node(service/F006-level-and-node);不自己實作位元組保留的
  寫回與樂觀鎖比對(那是 graph-core,本層只傳 `Revision` 並翻譯失敗)
