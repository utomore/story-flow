---
id: F006
type: feature
title: level-and-node
description: Level 與 Node 的建立 / 刪除、樹視圖
status: planned
stage: S3
modules: [Write, Read]
created: 2026-09-04
updated: 2026-09-04
depends-on: [service/F004]
related-adr: []
related-feature: []
code-paths: []
---

# F006: level-and-node

## 契約

- **階段**:階段二
- **負責模組**:Write、Read
- **實作的 Level 2 介面**:契約 E 的 `createLevel` / `deleteLevel` / `addNode` / `removeNode` 與
  `NewLevelReq` / `NewNodeReq`;契約 B 的 `NodeTreeView` / `DLevel` / `DNode`;契約 F 的
  `LevelTreeInvalid`;使用 service/F004-node-write 的驗證(無新增)
- **資料流管線段落**:寫入管線,節點種類為 Level / Node 的那一支(多一次 `buildTree` 前置驗證)
- **驗收標準**:
  - 讓樹不合法的編輯(父節點不存在、跨 Level 的父子、成環)一律回 `LevelTreeInvalid` 並帶
    graph-core 的 `TreeError` 清單,且**檔案未動** — 觀察點:契約 F 的 `LevelTreeInvalid`、
    契約 E 的 `addNode` / `removeNode`
  - `addNode` 插入後,重讀該 Level 的 `dvTree` 中新節點恰好是指定父節點的**最後一個子節點** —
    觀察點:契約 B 的 `NodeTreeView`、契約 D 的 `getNode`
  - `removeNode` 的 `drRemoved` 含被級聯刪掉的整棵子樹的 `Ref`,數量等於刪除前該子樹的節點數 —
    觀察點:契約 E 的 `DeleteReport`
  - `deleteLevel` 後該 Level 的全部 `nod-` 節點都不再出現在 `listNodes` — 觀察點:契約 E 的
    `deleteLevel`、契約 D 的 `listNodes`
  - Level 與 Node 的寫入同樣受樂觀鎖約束:`revision` 不符回 `RevisionConflict` — 觀察點:
    契約 F 的 `RevisionConflict`
- **明確不做**:不決定 Level 檔在磁碟上的分節形狀(graph-core);不做場景的業務語意(那是作者的事)
