---
id: P-015
description: vault 目錄快照經計畫、執行、對帳、回退搬遷 pack,不留幽靈
status: draft
updated: 2026-09-06
---
# P-015-pack-reorganize:vault 目錄快照經計畫、執行、對帳、回退搬遷 pack,不留幽靈

## Brief
O-2 的 M-7,原 assetdb 的 reorg。input 是 vault 目錄的快照(每個 pack 的位置與 sha256)與一份目標結構(廠商 / pack-slug 的正規化);output 是搬遷計畫、執行結果與對帳報告,失敗可回退。流向:快照 → 計畫(哪個壓縮檔搬去哪、pack.md 跟著走、id 不變)→ 預覽;`--confirm` 才執行 → 對帳(每個 pack 的 sha256 與 id 在新位置都對得上)→ 對不上就回退。計畫與對帳是純函數,搬檔是 `VaultDir` 效果;搬完只更新 pack.md 的 archive 欄位,經 P-001 refresh。Stages 與 laws 待 lawful:pipeline 設計時寫;願望模組 `Aapms.Reorg.Plan`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **搬遷以 sha256 對帳,id 與人給欄位不動。** 否決:搬完重掃。理由:重掃會把 name 清空(P-012 的不覆寫原則反過來成立)
- **預設只預覽,`--confirm` 才執行,不可逆的另需獨立旗標。** 否決:直接搬。理由:system.md CLI 契約
- **對帳失敗整批回退。** 否決:能搬多少算多少。理由:半搬的目錄比沒搬更難修

## 修訂記錄
無
