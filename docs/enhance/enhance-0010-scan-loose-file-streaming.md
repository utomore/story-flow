---
id: enhance-0010
type: enhance
title: scan-loose-file-streaming
description: 散檔掃描改為串流讀取,不再整檔載入記憶體
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0002]
related-spec: []
---

# 散檔掃描整檔載入記憶體,與串流讀取的自我要求矛盾

## 現況說明

`ingest/src/AssetDB/Ingest/Scan.hs:329` 的 `scanLoose` 用 `BS.readFile p` 整檔讀進記憶體
計算雜湊,而 `ingest/src/AssetDB/Ingest/Hash.hs:39-44` 的 `sha256File` 明確以串流方式
(`hashlazy`/`BL.readFile`)處理壓縮檔內項目,註解寫明「1 GB 參考壓縮檔不該整檔進記憶體」。
兩處對同一件事(計算檔案雜湊)採用不一致的記憶體策略。

目前散檔多為小圖示(幾百 bytes 到數十 KB),尚未實際造成記憶體問題,但
`library/studio/` 與 `library/reference/` 根目錄下的散檔沒有大小上限保證 ——
`reference/` 過去曾放過上百 MB 的 HEIC 相片。

## 修正方案

`scanLoose` 改用與 `Hash.hs` 一致的串流讀取方式計算 SHA-256,不整檔載入記憶體。

## TodoList

- [ ] T1: `scanLoose` 改用串流方式讀取檔案計算雜湊,移除 `BS.readFile` 整檔載入

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ScanSpec.scanLoose 對大檔案不整檔載入記憶體` | 用大型測試檔驗證峰值記憶體用量,或至少驗證雜湊結果與整檔讀取一致 |
| T1 | `ScanSpec.scanLoose 計算結果與 sha256File 對同一檔案結果一致` | 迴歸測試,確保改動不改變雜湊結果 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
