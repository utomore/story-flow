---
id: E004
type: enhance
title: test-coverage-gaps
description: 補齊 cli、server、web 的測試覆蓋缺口
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: []
related-feature: []
---

# 測試覆蓋缺口:cli 零測試、server 僅一個、web 零測試

## 現況說明

> **2026-08-18 更新。** 本節原本寫於 2026-08-16,當時 cli 是零測試、server 只有
> TsTypesSpec。delivery/B001 至 delivery/B005 的修復已經補進 `server/AppSpec.hs`、
> `server/CliSpec.hs`、`cli/OptionsSpec.hs`、`cli/EndToEndSpec.hs`,所以下表已更新為
> 動工當下的實際狀態。逐項核對後,T1–T4 的四個標的**仍然全部未被覆蓋**,TodoList
> 因此原樣有效。

| 套件 | Spec 檔數 | 觀察 |
|---|---|---|
| core | 3 | Naming 有 QuickCheck 性質測試,輸入取自真實素材庫 |
| store | 5 | Schema 測到種子資料筆數;FTS 有中文雙字詞回歸測試 |
| ingest | 8 | Handler(WAV chunk 走訪)、ClusterDb(撞名攔截)皆有測試 |
| archive | 3 | Sidecar 的 `-slt` 解析、zip/7z 目錄判定差異有測試 |
| reorg | 3 | Execute 冪等性、Plan 刪除閘門有測試 |
| ai | 4 | SuggestSpec 是「扇出」驗收點,選對了測試標的 |
| project | 2 | TemplateSpec 薄;授權閘門邏輯在 `Create.hs` 未見直接測試 |
| **server** | **3** | AppSpec 覆蓋 db 路徑、綁定位址與 thumb(delivery/B002/0004/0005);health、search/facets 的 `mkQuery` limit 夾制仍無測試 |
| **cli** | **2** | OptionsSpec 覆蓋 `resolveDbPath`、EndToEndSpec 覆蓋組合根接線(delivery/B001);**參數解析本身仍無測試** |
| **web** | **0** | 無任何測試設施 |

## 優先順序(依風險排序)

1. **`resolveDbPath`**:已在 delivery/B001 的 TodoList 中一併補測試,不重複列在此文件。
2. **server handler**:至少覆蓋 `health`(最基本的存活檢查)與 `search`/`facets` 的
   `limit` 夾制邏輯(直接關聯 G-E001
   的分頁常數問題)。
3. **`project/Create.hs` 的 `nonCommercialPacks`**:NULL 授權也視為非商用的語意是
   法律風險防線(見 `.design/system.md` 授權閘門相關描述),值得一條直接的測試
   鎖住這個行為,防止未來重構時被意外改壞。
4. **web 的測試投資報酬率較低**,可暫緩(前端邏輯相對薄,主要風險在型別契約,已由
   delivery/E005 的漂移檢查覆蓋)。

## TodoList

- [x] T1: 補 `server` 的 `health` handler 測試
- [x] T2: 補 `server` 的 `search`/`facets` limit 夾制測試
- [x] T3: 補 `project/Create.hs` 的 `nonCommercialPacks` 測試(NULL 授權視為非商用)
- [x] T4: 補 `cli` 的參數解析基本測試(至少涵蓋 `--help`、常見指令的參數組合)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AppSpec.GET /api/health 回 200` | 基本存活檢查 |
| T1 | `AppSpec.GET /api/health 回傳前端契約上的五個欄位,一個不多一個不少` | 欄位名是前端合約,改名等於前端健康列變空白 |
| T1 | `AppSpec.GET /api/health 各項計數反映資料庫的實際內容` | 固定資料刻意讓四個計數兩兩不相等,接錯線就測得出來 |
| T1 | `AppSpec.GET /api/health 有資料但沒建索引時回報索引過期` / `空資料庫不算索引過期` | `ftsStale` 的兩個方向 |
| T2 | `AppSpec.GET /api/search 的分頁夾制 limit 超過上限時夾制到 500,而不是照單全收` | 鎖住 `mkQuery` 的夾制;已用變異測試確認會失敗 |
| T2 | `AppSpec.… 未指定 limit 時採預設值 60` / `上限以內的 limit 原樣採用` | 預設值與非夾制路徑 |
| T2 | `AppSpec.… total 回報符合條件的總數,不受 limit 影響` | 虛擬化網格靠 total 算捲動條高度 |
| T2 | `AppSpec.… 負的 offset 回傳第一頁,而不是錯誤` | 端點契約(非夾制本身,理由見實作備註) |
| T2 | `AppSpec.GET /api/facets 的夾制 facets 不吃 limit/offset,帶了也不影響結果` | facets 走同一個 `mkQuery` 但續體裡沒有分頁參數 |
| T3 | `CreateSpec.nonCommercialPacks 擋下 license_id 為 NULL 的素材包` | 法律風險防線的直接測試 |
| T3 | `CreateSpec.… 擋下明確標記不可商用的素材包` / `放行可商用的素材包` / `混合輸入時只回傳擋下的那些` | 三種授權狀態各一條 |
| T3 | `CreateSpec.… NULL 與 0 在閘門這一側等價` | 三值邏輯最容易寫錯的地方 |
| T3 | `CreateSpec.… 空清單直接回空,不查資料庫` / `重複的 slug 不會…改變語意` | 邊界輸入 |
| T4 | `ParserSpec.--help 以「成功」結束` / `說明裡列出所有頂層指令` / `子指令也有自己的說明` | `--help` 在 optparse 裡是 Failure,結束碼必須是 `ExitSuccess` |
| T4 | `ParserSpec.scan / search / new-project` 共十一條 | 必填欄位、預設值、可重複選項、布林旗標互不影響 |
| T4 | `ParserSpec.reorganize 沒有給模式旗標時解析失敗` 等五條 | 鎖住「沒有預設模式」這個刻意設計 —— 其中一個模式會刪五千個檔案 |
| T4 | `ParserSpec.全域選項` / `未知輸入` 共四條 | `--db` 的位置與作用域;未知指令/旗標不被吞掉 |

## 實作備註

**為了測試而做的兩處匯出(這是與原規格唯一的偏差)。**

- `AssetDB.Project.Create` 匯出 `nonCommercialPacks`。從 `createProject` 走到它需要
  一整組真實壓縮檔與 `ArchiveTools`,那樣的測試貴到不會有人寫 —— 於是這條帶法律
  後果的防線一直沒有測試。匯出處附了 Haddock 說明這個理由。
- `AssetDB.Cli.Options` 把參數規格拆成 `invocationInfo :: ParserInfo Invocation`,
  `parseInvocation` 改為 `execParser invocationInfo`。`execParser` 讀 `getArgs`
  而且在 `--help` 或解析失敗時直接結束行程,測不動;留成一個值之後測試就能用
  `execParserPure` 餵任意參數列。行為完全不變。

其餘皆為新增測試,未改動任何產品程式碼的行為。

**新測試檔**:`cli/test/AssetDB/Cli/ParserSpec.hs`、`project/test/AssetDB/Project/CreateSpec.hs`
(兩者的 cabal `other-modules` 與 `build-depends` 一併補上);T1/T2 併入既有的
`server/test/AssetDB/Server/AppSpec.hs`。

**AppSpec 的驅動器擴充。** 原本的 `runGet` 只取得狀態碼與標頭,JSON 端點測不了。
新增 `runGetFull`(帶查詢字串、以 `responseToStream` 收回應主體),`runGet` 改為它的
薄包裝。仍然沒有拉進 `wai-extra` —— 維持原檔案「為了這十幾行不值得多一個相依」的判斷。

**變異測試:確認新測試不是空轉。** 三處刻意改壞產品程式碼後重跑:

| 改壞的地方 | 結果 |
|---|---|
| `mkQuery` 的 `min 500` 拿掉 | 1 條失敗 ✅ |
| `mkQuery` 的 `max 0` 拿掉 | **0 條失敗** ⚠ |
| `nonCommercialPacks` 拿掉 `l.commercial IS NULL` 分支 | 3 條失敗 ✅ |

`max 0` 那條測不出來是**真的測不出來**,不是測試寫得不好:SQLite 自己就把負的
`OFFSET` 當 0,所以夾制與不夾制在 HTTP 這一側的行為完全相同。對應的測試因此改名為
「負的 offset 回傳第一頁,而不是錯誤」,誠實反映它鎖的是端點契約而不是那個夾制。

**尚未處理(不在本次 TodoList 內)**:

- `web` 的測試設施 —— 原文件已判定投資報酬率低,主要風險在型別契約,由 delivery/E005 覆蓋。
- `cli` 的各指令實作(`Doctor.hs`、`Scan.hs` 等)仍只有參數解析層有測試。
- `project/Create.hs` 除授權閘門外的部分(`selectAssets`、`registerProject`、
  `copyAssets`)仍無測試。

**量化結果**:

| 套件 | 改善前 | 改善後 |
|---|---|---|
| store | 102 | 109(+7,來自 catalog/E001) |
| server | 43 | 54(+11) |
| project | 17 | 24(+7) |
| cli | 13 | 37(+24) |
| **全專案合計** | **485** | **534(+49)** |

九個 test suite 全數通過,無失敗。
