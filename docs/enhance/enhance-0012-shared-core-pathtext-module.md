---
id: enhance-0012
type: enhance
title: shared-core-pathtext-module
description: 在 core 收斂五處重複的小工具函式
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0002, adr-0005]
related-spec: []
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

- [ ] T1: 新增 `AssetDB.PathText` 模組,實作 `leafOf`/`extensionOf`/`slugify`
- [ ] T2: 將 `thumbPath`/`ThumbSize` 移入 `core`,`ingest/Thumb.hs`、`ai/Image.hs`、
      `server/App.hs` 改為引用
- [ ] T3: `ingest/Handler.hs`、`reorg/Execute.hs` 的壓縮格式副檔名清單改為引用
      `archive/Types.hs` 的 `formatExtensions`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `PathTextSpec.leafOf/extensionOf/slugify 各自的既有測試案例全數通過` | 把五處原本各自的測試案例合併驗證,確保行為不變 |
| T2 | `ThumbSpec` 與 `ImageSpec` 對 `thumbPath` 的既有測試案例通過(改為呼叫 core 版本) | 迴歸測試 |
| T3 | `HandlerSpec.archiveHandler 使用 formatExtensions 判定,tar.gz 行為與 archive 套件一致` | 驗證不一致已消除 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
