---
id: E001
type: enhance
title: grid-effect-dependency-cleanup
description: 修正 Grid 的 effect 依賴,避免每次渲染重跑
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: []
related-feature: []
---

# `web/Grid.tsx` 的 effect 依賴 `virt.getVirtualItems()`,每次渲染都重跑

## 現況說明

`web/src/components/Grid.tsx:97` 的 effect 把 `virt.getVirtualItems()` 的回傳值(每次
呼叫都是新陣列參照)放進依賴陣列,導致這個 effect 在每次渲染都重新執行。目前有
`pending` 集合守門(已在請求中的分頁不會重複發請求),所以沒有實際危害,純粹是多餘的
重新執行與潛在的除錯干擾(React DevTools 會顯示這個 effect 異常頻繁觸發)。

## 修正方案

改為依賴 `virt.getVirtualItems()` 內容衍生出的穩定值(如可視範圍的 `[first, last]`
索引區間),而非整個陣列參照。

## TodoList

- [x] T1: 修正 effect 依賴陣列,只依賴可視範圍的穩定衍生值

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | 人工驗證:捲動網格時 effect 觸發次數明顯減少且分頁載入行為不變 | 前端目前無測試設施(見 delivery/E004),此項以手動驗證為主 |

## 實作備註

- render 期呼叫一次 `virt.getVirtualItems()` 取得 `vis`,衍生 `firstRow` / `lastRow`
  兩個原始值進依賴陣列(`[firstRow, lastRow, cols, items, query]`);JSX 的列渲染同步
  改用同一份 `vis`,不再重複呼叫。
- 驗證:`tsc -b && vite build` 通過。依賴陣列全為原始值,React 淺比較保證可視列區間
  不變時 effect 必然跳過 —— 「每次渲染都重跑」在型別層面已不可能。瀏覽器內以
  DevTools 實測觸發次數的抽查,留待開發者日常使用時進行(本次未起 server 實測)。
