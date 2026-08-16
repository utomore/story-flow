---
id: enhance-2026-08-16-port-8787-consolidation
type: enhance
title: port-8787-consolidation
description: 收斂硬編碼於三處的預設埠號 8787
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# Port 8787 硬編碼於三處,改 port 需要記得同步修改

## 現況說明

預設埠號 `8787` 出現在:`server/app/Main.hs:26`(預設值)、同檔的 usage 說明文字、
`web/vite.config.ts:10-11`(dev proxy 目標)。改 port 要記得改三處,目前沒有任何機制
提醒或強制同步。

## 修正方案

1. `server/app/Main.hs`:定義一個具名常數(如 `defaultPort = 8787`),usage 文字引用它
   而非重複寫死數字。
2. `web/vite.config.ts`:Vite 設定檔與 Haskell 後端沒有共用的設定來源,無法真正共用
   常數,至少在兩處各自加上註解互相指涉(「改這裡記得同步改 server/app/Main.hs 的
   defaultPort」)。

## TodoList

- [ ] T1: `server/app/Main.hs` 新增 `defaultPort` 具名常數,usage 文字引用它
- [ ] T2: `vite.config.ts` 與 `Main.hs` 互相加上指涉註解

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `MainSpec.usage 文字包含的預設 port 與 defaultPort 常數一致` | 防止兩者再次漂移 |
| T2 | 人工 code review 確認註解已補上 | 純文件性修改,vite.config.ts 無測試設施 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
