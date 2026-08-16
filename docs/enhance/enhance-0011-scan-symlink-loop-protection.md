---
id: enhance-0011
type: enhance
title: scan-symlink-loop-protection
description: 為目錄掃描加上符號連結迴圈防護
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
---

# `discover` 不防符號連結迴圈,Windows Junction 可造成無窮遞迴

## 現況說明

`ingest/src/AssetDB/Ingest/Scan.hs:117-121` 的 `discover` 遞迴走訪目錄樹時,沒有偵測
符號連結(或 Windows junction)造成的目錄迴圈。若素材庫目錄結構中出現指向自身祖先的
junction(目前素材庫尚未發生,但使用者手動建立捷徑/junction 時可能誤觸),掃描會無窮
遞迴。

## 修正方案

`discover` 走訪時記錄已訪問過的目錄(用 canonical path 或裝置號+inode 組合),
偵測到重複時跳過並記錄警告,而非遞迴進入。

## TodoList

- [ ] T1: `discover` 加入已訪問目錄集合,偵測迴圈時跳過並警告

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ScanSpec.discover 對含自我指涉 junction 的目錄樹不無窮遞迴` | 建立測試用的迴圈連結,驗證正常結束並記錄警告 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
