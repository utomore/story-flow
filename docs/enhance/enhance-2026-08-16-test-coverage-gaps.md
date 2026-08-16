---
id: enhance-2026-08-16-test-coverage-gaps
type: enhance
title: test-coverage-gaps
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
---

# 測試覆蓋缺口:cli 零測試、server 僅一個、web 零測試

## 現況說明

| 套件 | Spec 檔數 | 觀察 |
|---|---|---|
| core | 3 | Naming 有 QuickCheck 性質測試,輸入取自真實素材庫 |
| store | 5 | Schema 測到種子資料筆數;FTS 有中文雙字詞回歸測試 |
| ingest | 8 | Handler(WAV chunk 走訪)、ClusterDb(撞名攔截)皆有測試 |
| archive | 3 | Sidecar 的 `-slt` 解析、zip/7z 目錄判定差異有測試 |
| reorg | 3 | Execute 冪等性、Plan 刪除閘門有測試 |
| ai | 4 | SuggestSpec 是「扇出」驗收點,選對了測試標的 |
| project | 2 | TemplateSpec 薄;授權閘門邏輯在 `Create.hs` 未見直接測試 |
| **server** | **1**(僅 TsTypesSpec) | search/facets/health handler 無測試;`mkQuery` 的 limit 夾制無測試 |
| **cli** | **0** | 參數解析、`resolveDbPath`(見 [bug-0001](../bugfix/bug-0001-resolve-db-path-silent-empty-db.md))、`doctor` 全裸奔 |
| **web** | **0** | 無任何測試設施 |

## 優先順序(依風險排序)

1. **`resolveDbPath`**:已在 bug-0001 的 TodoList 中一併補測試,不重複列在此文件。
2. **server handler**:至少覆蓋 `health`(最基本的存活檢查)與 `search`/`facets` 的
   `limit` 夾制邏輯(直接關聯 enhance-2026-08-16-pagination-constants-consolidation
   的分頁常數問題)。
3. **`project/Create.hs` 的 `nonCommercialPacks`**:NULL 授權也視為非商用的語意是
   法律風險防線(見 `docs/architecture.md` 授權閘門相關描述),值得一條直接的測試
   鎖住這個行為,防止未來重構時被意外改壞。
4. **web 的測試投資報酬率較低**,可暫緩(前端邏輯相對薄,主要風險在型別契約,已由
   enhance-2026-08-16-ts-types-drift-check 的漂移檢查覆蓋)。

## TodoList

- [ ] T1: 補 `server` 的 `health` handler 測試
- [ ] T2: 補 `server` 的 `search`/`facets` limit 夾制測試
- [ ] T3: 補 `project/Create.hs` 的 `nonCommercialPacks` 測試(NULL 授權視為非商用)
- [ ] T4: 補 `cli` 的參數解析基本測試(至少涵蓋 `--help`、常見指令的參數組合)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AppSpec.health 回傳 200 與正確 JSON 結構` | 基本存活檢查 |
| T2 | `AppSpec.search 對超過上限的 limit 正確夾制到最大值` | 鎖住 enhance-2026-08-16-pagination-constants-consolidation 的夾制邏輯 |
| T3 | `CreateSpec.nonCommercialPacks 對 license_id 為 NULL 的素材包視為非商用並擋下` | 法律風險防線的直接測試 |
| T4 | `CliSpec.主要指令的參數解析對合法輸入正確產生對應設定值` | 至少涵蓋 search/scan/new-project |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
