---
id: E002
type: enhance
title: port-8787-consolidation
description: 收斂硬編碼於三處的預設埠號 8787
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: [ADR-001]
related-feature: []
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

- [x] T1: `defaultPort` 具名常數與 usage 引用(已由 delivery/B003 重構順手完成,本次補測試)
- [x] T2: `vite.config.ts` 與 `Cli.hs` 互相加上指涉註解

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `CliSpec.usageText 包含的預設 port 與 defaultPort 常數一致` | 防止兩者再次漂移 |
| T2 | 人工 code review 確認註解已補上 | 純文件性修改,vite.config.ts 無測試設施 |

## 實作備註

- **現況漂移(良性)**:動工時發現 T1 實質上已完成 —— delivery/B003 修復把參數解析抽到
  `server/src/AssetDB/Server/Cli.hs` 時,`defaultPort` 常數已建立且 `usageText` 直接引用
  `show defaultPort`,`app/Main.hs` 已無任何 8787 字面值。本次補上 CliSpec 的一致性
  測試(常數改值或 usage 改回字面值時會紅)。
- T2:`Cli.hs` 的 `defaultPort` 註解與 `web/vite.config.ts` 的 proxy 註解互相指涉,
  皆註明兩邊沒有共用設定來源、改一邊要同步另一邊。
- 測試:`cabal test all` 全綠(assetdb-server-test 56 examples, 0 failures)。
