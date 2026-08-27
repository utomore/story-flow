---
id: E005
type: enhance
title: scan-symlink-loop-protection
description: 為目錄掃描加上符號連結迴圈防護
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: []
related-feature: []
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

- [x] T1: `discover` 加入已訪問目錄集合,偵測迴圈時跳過並警告

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ScanSpec.discover 對含自我指涉 junction 的目錄樹不無窮遞迴` | 建立測試用的迴圈連結,驗證正常結束並記錄警告 |

## 實作備註

- `discover` 以 `canonicalizePath` 為鍵維護已訪問目錄的 `Set`(根目錄先入集合),
  重複出現即跳過並產生警告;簽名改為第三個回傳值帶警告清單,`scanRoot` 把它們
  逐條發成 `EvProblem` 並記入 `srProblems`。同一機制順帶防住「兩條連結指向
  同一目錄」造成的重複索引,不只自我指涉迴圈。
- 測試:Windows 上建目錄符號連結需要開發者模式/管理員權限,首版測試只能
  pending;改以 junction(`mklink /J`,不需權限)作後備後,防護在本機**實際
  執行並通過**(掃描正常結束、警告含「迴圈」字樣、迴圈內檔案只入庫一次)。
  POSIX 環境則直接用 `createDirectoryLink`。
- 量化:改動前對含迴圈 junction 的目錄樹是無窮遞迴(掛死);改動後正常完成
  且警告可見。`cabal test all` 全綠(assetdb-ingest-test 116 examples,
  0 failures,0 pending)。
