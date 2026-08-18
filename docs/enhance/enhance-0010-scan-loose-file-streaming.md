---
id: enhance-0010
type: enhance
title: scan-loose-file-streaming
description: 散檔掃描改為串流讀取,不再整檔載入記憶體
status: done
created: 2026-08-16
updated: 2026-08-18
related-adr: [adr-0002]
related-spec: []
---

## 散檔掃描整檔載入記憶體,與串流讀取的自我要求矛盾

### 現況說明

`ingest/src/AssetDB/Ingest/Scan.hs:329` 的 `scanLoose` 用 `BS.readFile p` 整檔讀進記憶體
計算雜湊,而 `ingest/src/AssetDB/Ingest/Hash.hs:39-44` 的 `sha256File` 明確以串流方式
(`hashlazy`/`BL.readFile`)處理壓縮檔內項目,註解寫明「1 GB 參考壓縮檔不該整檔進記憶體」。
兩處對同一件事(計算檔案雜湊)採用不一致的記憶體策略。

目前散檔多為小圖示(幾百 bytes 到數十 KB),尚未實際造成記憶體問題,但
`library/studio/` 與 `library/reference/` 根目錄下的散檔沒有大小上限保證 ——
`reference/` 過去曾放過上百 MB 的 HEIC 相片。

### 修正方案

`scanLoose` 改用與 `Hash.hs` 一致的串流讀取方式計算 SHA-256,不整檔載入記憶體。

### TodoList

- [x] T1: `scanLoose` 非媒體散檔改走串流雜湊;媒體散檔維持整檔讀(探測需要),
      不再重複讀取(部分偏離,見實作備註)

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ScanSpec.串流路徑(非媒體 kind)的雜湊與大小和整檔讀取一致` | 驗證串流路徑的雜湊與 `sha256File` 一致、blobs.bytes 與檔案實際大小一致 |
| T1 | `ScanSpec.媒體路徑(整檔讀供探測)的雜湊與 sha256File 一致` | 迴歸測試,確保兩路對同一內容結果相同 |

### 實作備註

- **部分偏離原方案**:「全部改串流」做不到 —— 圖片與音效的中繼資料探測本來就
  需要整份內容(PNG 完整解碼數色、WAV 走 chunk),串流雜湊後再讀一次反而讓
  最大宗的 PNG(佔素材庫 91%)掃描 IO 翻倍。改為**分兩路**:
  - `KImage` / `KAudio`(探測需要內容):維持整檔讀,雜湊直接重用同一份位元組
    —— 與改動前的記憶體行為相同,零額外成本;
  - 其餘 kind(所有 `hProbe = const Nothing` 的處理器與無處理器的副檔名):
    改走 `sha256File` 串流 + `getFileSize`,完全不載入內容。
- 量化:文檔點名的風險情境(`reference/` 上百 MB 的 HEIC 相片、`psd` 等原始檔)
  全部落在串流路徑,記憶體峰值由 O(檔案大小) 降為串流常數;媒體檔行為與
  改動前完全一致。
- 測試:`cabal test all` 全綠(assetdb-ingest-test 113 examples, 0 failures)。
