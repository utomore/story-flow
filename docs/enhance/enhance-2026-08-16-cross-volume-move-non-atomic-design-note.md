---
id: enhance-2026-08-16-cross-volume-move-non-atomic-design-note
type: enhance
title: cross-volume-move-non-atomic-design-note
description: 記錄跨磁碟搬移為非原子操作的評估結論
status: closed
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0002]
related-spec: []
---

# 記錄:跨磁碟搬移為 copy+delete,非原子操作(已評估為可接受的設計)

## 現況說明

`reorg/src/AssetDB/Reorg/Execute.hs:225` 的跨磁碟搬移 fallback 是 copy+delete,不是
檔案系統原子操作。若在複製完成、刪除原檔前中斷,理論上會短暫出現「兩邊都有」的狀態。

## 評估結論

**這是自洽的設計,不需要修改。** Preflight 檢查會在「兩邊都存在」時拒絕繼續執行,
逼使用者先手動處理再重跑,而不是靜默選一邊刪除造成資料遺失。中斷後的復原路徑是
「重新執行同一個 reorg 批次」,`moves` 表的稽核記錄能明確反映哪些檔案卡在中間狀態。

此文件記錄評估結論本身,狀態標記為 `closed`(已確認不需要動作),供未來若有人重新
質疑這個設計時查閱評估依據,不必重新分析一次。

## TodoList

- [x] T1: 評估是否需要改為原子操作 — 結論:不需要,preflight 檢查已提供足夠安全網

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | 既有 `ExecuteSpec` 的冪等性測試已涵蓋中斷後重跑的行為 | 無需新增測試,引用既有覆蓋 |

## 實作備註

無實作,純評估記錄。
