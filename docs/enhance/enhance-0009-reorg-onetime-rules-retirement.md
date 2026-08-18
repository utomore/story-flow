---
id: enhance-0009
type: enhance
title: reorg-onetime-rules-retirement
description: 退役已完成搬遷的一次性路徑規則
status: done
created: 2026-08-16
updated: 2026-08-18
related-adr: [adr-0002]
related-spec: []
---

## 一次性重構規則活在函式庫層,重構已完成、規則已成死碼加誤觸風險

### 現況說明

以下規則是針對 2026-08-09 那一次舊資料夾結構搬遷(見 `docs/architecture.md` 開發階段 3)
寫死的路徑判斷,重構已執行完畢:

- `reorg/Plan.hs:154`:`isVendorAsset = "Game Assets itchio/" \`T.isPrefixOf\``
- `reorg/Plan.hs:186-192`:`mapTopLevel` 的三條中文資料夾對應
  (`GameProjects/`→`projects/`、`Papers/`→`knowledge/papers/`、`行銷/`→`marketing/`)
- `reorg/Execute.hs:302`:`pruneEmptyDirs (src </> "Game Assets itchio")`

這些規則如今是死碼,而且存在誤觸風險:若未來有人不慎再跑一次 `reorganize --apply`,
程式會去找已經不存在的舊路徑(`Game Assets itchio/`),行為結果未定義(可能是安全的
no-op,也可能因為假設不成立而出錯 —— 未見對應的防禦性測試)。

### 修正方案

二選一,由開發者決定:

- **方案 A(抽成遷移設定)**:把這些規則抽成一份獨立的「遷移設定」資料(如
  `migrations/2026-08-09-initial-reorg.toml`),`reorg` 套件本身不再硬編碼任何特定遷移
  的路徑規則,改為讀取傳入的設定檔。未來若有第二次結構性重構,新增一份設定檔即可,
  不需要改 `reorg` 套件程式碼。
- **方案 B(直接刪除)**:確認不會再需要重跑這次特定的重構後,直接刪除這些規則,
  在 git 歷史中保留記錄即可,`docs/architecture.md` 開發階段 3 的描述已足夠說明
  這次遷移做了什麼。

### TodoList

- [x] T1: 與開發者確認方案 A 或方案 B —— **決定:方案 B**(2026-08-18)
- [x] T2: 依決定的方案實作
- [x] T3: 方案 A 專用項目不適用;等效的防誤觸測試已補(散檔一律 OpKeep、
      `--delete-covered` 也不刪,見實作備註)

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T2(方案 A) | `PlanSpec.reorganize 讀取外部遷移設定檔產生計畫` | 驗證規則已抽離,行為不變 |
| T2(方案 B) | `PlanSpec` 移除對應的舊測試案例後其餘測試仍通過 | 確認刪除未影響其他邏輯 |
| T3 | `PlanSpec.reorganize 未傳入遷移設定時不套用任何特定路徑規則` | 防止誤觸 |

### 實作備註

- **開發者決策:方案 B(直接刪除),2026-08-18。** 規則本身保留在 git 歷史;
  遷移做了什麼由 `docs/architecture.md` 開發階段 3 記載。
- 刪除的內容:`Plan.hs` 的 `isVendorAsset` 前綴判斷與散檔 `OpDelete`/`OpMove`
  產生邏輯、`mapTopLevel` 三條頂層對應(整個函式移除並自匯出清單拿掉)、
  `Execute.hs` 的 `pruneEmptyDirs`(含 `runDeletes` 裡指向 `Game Assets itchio/`
  的呼叫)。
- 保留的內容:`Op` 型別的 `OpDelete` 建構子、`runDeletes` 執行器、`undoBatch`
  對刪除的拒絕 —— 它們對 `Plan` 是通用機制,測試改以手組 Plan 驗證。
- 行為變化:`buildPlan` 對散檔**一律**產生 `OpKeep`;`reorganize --apply`
  (含 `--delete-covered`)只會重組素材包,不會搬移或刪除任何散檔,
  誤觸風險歸零。
- 測試連動:`PlanSpec` 移除「頂層資料夾對應」與「刪除閘門」兩組舊規則測試,
  新增「散檔一律 OpKeep,不產生任何搬移或刪除」;`ExecuteSpec` 期望值同步
  (arMoved 2→1、階段 B 改為驗證**不刪**、回退測試以手組含 OpDelete 的 Plan
  驗證拒絕訊息)。`cabal test all` 全綠(assetdb-reorg-test 32 examples,
  0 failures)。
