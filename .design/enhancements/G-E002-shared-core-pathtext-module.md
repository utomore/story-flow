---
id: G-E002
type: enhance
title: shared-core-pathtext-module
description: 在 core 收斂五處重複的小工具函式
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: [ADR-002, ADR-005]
related-feature: []
subsystems: [catalog, ingest, ai-tagging, delivery]
---

# 在 `core` 新增共用純函數模組,收斂五處重複的小工具函式

## 現況說明

跨套件重複的小型純函數,全部適合收進 `core`(`core` 已是所有套件的共同依賴,不會引入
新的耦合):

| 重複的知識 | 出現位置 |
|---|---|
| `leafOf`(取路徑最後一段) | `ingest/Scan.hs:443`、`ingest/Cluster.hs:236`、`reorg/Execute.hs:405`、`reorg/PackToml.hs:81`、`project/Create.hs:286`(5 份) |
| 副檔名抽取(小寫含點) | `ingest/Handler.hs:81-86`、`ingest/Cluster.hs:242-247`、`project/Create.hs:285-290`(3 份,邏輯微異) |
| `slugify` | `ingest/Scan.hs:418-428`、`reorg/Plan.hs:196-206`(2 份,實作幾乎逐字相同) |
| 縮圖快取路徑規則 | `ingest/Thumb.hs:44`、`ai/Image.hs:35`、`server/App.hs:110`(3 份) |
| `ThumbSize` 列舉 | `ingest/Thumb.hs:31`、`ai/Image.hs:22`(2 份重複定義) |
| 壓縮格式副檔名清單 | `archive/Types.hs:46-49`(權威版)、`ingest/Handler.hs:213`(多了 `.tar/.gz`,不一致)、`reorg/Execute.hs:291`(又一份) |

其中 `slugify` 與縮圖路徑規則是**會咬人的重複**:兩份 `slugify` 若有一份日後修改
(例如保留數字開頭的處理方式),pack 目錄名與掃描 slug 會分家;縮圖路徑規則變動
(例如改兩層分桶)需要同時記得三處,遺漏任何一處會造成縮圖找不到卻不報錯的靜默失敗。

## 修正方案

1. 在 `core` 新增模組(建議命名 `AssetDB.PathText`),收容 `leafOf`、`extensionOf`、
   `slugify`、`thumbPath`、`ThumbSize`。
2. 逐一替換五處呼叫點為 `core` 的共用實作,刪除重複定義。
3. 壓縮格式副檔名清單統一以 `archive/Types.hs` 的 `formatExtensions` 為權威來源,
   `ingest/Handler.hs` 與 `reorg/Execute.hs` 改為引用它,順手修正 `.tar/.gz` 的不一致
   (`archiveHandler` 目前會把 tar.gz 標為 `KArchive`,但 `detectFormat` 不認得,
   掃描時被當散檔雜湊 —— 行為不一致但目前無害,一併收斂)。

## TodoList

- [x] T1: 新增 `AssetDB.PathText` 模組,實作 `leafOf`/`extensionOf`/`slugify`
- [x] T2: 將 `thumbPath`/`ThumbSize` 移入 `core`,`ingest/Thumb.hs`、`ai/Image.hs`、
      `server/App.hs` 改為引用
- [x] T3: `ingest/Handler.hs`、`reorg/Execute.hs` 的壓縮格式副檔名清單改為引用
      `archive/Types.hs` 的 `formatExtensions`(reorg 經 ingest 取得,見實作備註)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `PathTextSpec` 的 `leafOf`/`extensionOf`/`slugify` 各組案例 | 合併各套件原本的測試案例與實際使用情境,確保行為不變 |
| T2 | `PathTextSpec` 的 `thumbPath`/`ThumbSize` 案例 + `ThumbSpec` 既有 `thumbPath` 測試(經 re-export 呼叫 core 版本)通過 | 迴歸測試;ai 套件並無 `ImageSpec`(文檔筆誤),由前兩者覆蓋 |
| T3 | `HandlerSpec.archiveExtensions 與 archive 套件的 formatExtensions 一致`、`HandlerSpec.detectFormat 不認得的 tar/gz 不再被標為 KArchive` | 驗證不一致已消除 |

## 實作備註

- **T1/T2**:`core` 新增 `AssetDB.PathText`(`leafOf`、`extensionOf`、`slugify`、
  `ThumbSize`、`thumbSizes`、`thumbSizePx`、`thumbSizeTag`、`thumbPath`),core 因此
  新增輕量 `filepath` 相依。替換的呼叫端:`ingest/Scan.hs`(leafOf、slugify)、
  `ingest/Cluster.hs`(leafOf、extOf→extensionOf)、`ingest/Handler.hs`(extensionOf)、
  `ingest/Thumb.hs` 與 `ai/Image.hs`(ThumbSize/thumbPath 改 re-export,既有 API 不變)、
  `server/App.hs`(thumbH 改用 thumbPath)、`reorg/Plan.hs`(slugify re-export、leafOf)、
  `reorg/Execute.hs`、`reorg/PackToml.hs`(leafOf)、`project/Create.hs`(extOf 委派
  extensionOf)。
- **T3 的路徑偏離**:`reorg` 原本不相依 `archive`,直接引用會新增依賴邊並動到
  architecture.md 的依賴圖;改由 `ingest/Handler.hs` 匯出自 `formatExtensions` 導出的
  `archiveExtensions`,`reorg`(已相依 ingest)由此取得 —— 權威來源仍是 archive,
  依賴圖不變。
- **行為變更(文檔明定的收斂)**:`.tar`/`.gz` 不再被 `archiveHandler` 標為
  `KArchive`(`detectFormat` 本來就不認得),改歸 `KSource`,與 archive 套件一致。
- **統一 `extensionOf` 的邊角差異**:採最嚴格語意(點號後無內容視為無副檔名)。
  舊 `Cluster.extOf`/`Create.extOf` 對 `name.` 這種尾點檔名會回 `"."`,新版回 `""`
  —— Windows 建不出這種檔名,實務無影響;叢集 shape key 對正常檔名逐字不變。
- 量化:`leafOf` 5 份→1、`extensionOf` 3 份→1、`slugify` 2 份→1、`thumbPath` 3 份→1、
  `ThumbSize` 2 份→1、壓縮副檔名清單 3 份→1(權威在 archive)。
  `cabal test all` 全綠(core 101、ingest 116、server 58,合計 558 examples,
  0 failures)。
