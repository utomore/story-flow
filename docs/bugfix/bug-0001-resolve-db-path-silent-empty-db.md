---
id: bug-0001
type: bug
title: resolve-db-path-silent-empty-db
description: CLI 在錯誤目錄執行時靜默建立空資料庫
status: done
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# CLI `resolveDbPath` 在錯誤目錄執行時靜默建立空資料庫

## 問題描述

CLI 任何指令都會呼叫 `resolveDbPath`,若在錯誤的工作目錄(不是專案根目錄)執行,它不會
報錯,而是在當前目錄下新建一個空的 `.assetdb/assetdb.sqlite`。之後所有查詢都誠實地回報
0 筆結果,但使用者收到的訊息是「查無結果」而非「你的資料庫路徑錯了」—— 這是
`docs/analysis/report-2026-08-11-console-encoding-and-db-path.md` 記錄的「前端顯示 0 筆」事故的根因之一。

## 重現方式 / 現況證據

- `cli/app/AssetDB/Cli/Options.hs:484-490`:`resolveDbPath` 目前實作只做
  `cwd </> ".assetdb" </> "assetdb.sqlite"`,沒有向上搜尋、沒有存在性檢查。
- `cli/app/Main.hs`:`resolveDbPath global` 被無條件套用到所有指令(含 `scan`),
  沒有區分「初始化」與「一般操作」兩種語意。
- 2026-08-11 診斷報告已針對此問題提出修正方案,但**尚未套用到程式碼**——本文件是該修正的
  正式追蹤項。

## 根本原因

`resolveDbPath` 把「找資料庫檔案」與「決定新資料庫該建在哪」兩種語意合而為一,且預設行為
是後者(建立)。一般查詢指令(`search`/`facets`/…)在錯誤目錄下應該找不到資料庫就報錯,
只有 `scan`/`new-project` 等明確的初始化指令才應該允許建立新資料庫。

## 影響範圍

- `cli/app/AssetDB/Cli/Options.hs`(`resolveDbPath`)
- `cli/app/Main.hs`(呼叫端,可能需要依指令種類分流)

## 修正方案

1. 新增 `findDbUpwards :: FilePath -> IO (Maybe FilePath)`:從 cwd 向上逐層搜尋
   `.assetdb/assetdb.sqlite`,找不到回 `Nothing`。
2. 一般查詢類指令:呼叫 `findDbUpwards`,`Nothing` 時印出清楚的錯誤訊息並 `die`
   (「找不到資料庫,確認是否在專案目錄下執行,或用 --db 指定路徑」)。
3. 初始化類指令(`scan`/`new-project` 等):保留「找不到就在 cwd 建立」的行為,但改用
   獨立的 `resolveDbPathForInit`,語意上與一般查詢分開,不共用同一個函式。
4. 清理事故殘留檔案:`assetdb\--help`、`--help-shm`、`--help-wal`(舊 bug 產物)、
   `assetdb\.assetdb\assetdb.sqlite`(2026-08-12 誤建的空庫)。

## TodoList

- [x] T1: 實作 `findDbUpwards`,向上搜尋 `.assetdb/assetdb.sqlite`
- [x] T2: 一般查詢指令改用 `findDbUpwards`,找不到時 `die` 並印出清楚訊息
- [x] T3: 新增 `resolveDbPathForInit`,只給 `scan`/`new-project` 等初始化指令使用
- [x] T4: 清理事故殘留檔案(`--help*`、誤建的空庫)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `OptionsSpec.findDbUpwards 從子目錄能找到上層的 .assetdb` | 建立暫存目錄樹,子目錄執行應找到根目錄的資料庫 |
| T1 | `OptionsSpec.findDbUpwards 到檔案系統根都找不到回 Nothing` | 空目錄樹,確認回傳 `Nothing` 而非拋例外 |
| T2 | `CliSpec.search 在錯誤目錄執行時以非 0 結束碼失敗並印出訊息` | 端對端驗證不再靜默建空庫 |
| T3 | `OptionsSpec.resolveDbPathForInit 找不到時在 cwd 建立新路徑` | 確認初始化指令的行為未被誤改 |
| T4 | 手動驗證:重新執行一次乾淨的 `scan` 後 `assetdb\--help*` 與誤建空庫已不存在 | 非自動化測試,人工確認一次即可 |

實際落點:T1 / T3 的測試在 `cli/test/AssetDB/Cli/OptionsSpec.hs`,T2 的端對端測試在
`cli/test/AssetDB/Cli/EndToEndSpec.hs`(對照表寫的 `CliSpec` 更名的理由見實作備註)。

## 根因與修法摘要

**根因**:`resolveDbPath` 把「找到既有資料庫」與「決定新資料庫建在哪」兩種語意合成一個函式,
且預設行為是後者。任何指令在錯誤的工作目錄下執行都會靜默建出空庫,查詢誠實回報 0 筆,
使用者看到的是「查無結果」而不是「路徑錯了」。

**修法**:把兩種語意拆成兩個函式,由組合根決定哪個指令用哪一個。

- `findDbUpwards`:從指定目錄逐層往上找 `.assetdb/assetdb.sqlite`,到檔案系統根為止,
  找不到回 `Nothing`,不建立任何東西。
- `resolveDbPathForQuery`:查詢類指令用,找不到就 `die`。`--db` 指到不存在的檔案時同樣報錯。
- `resolveDbPathForInit`:初始化類指令用,先往上找既有資料庫,真的沒有才決定在 cwd 開新的。
- `resolveDbPath` 已移除 —— 留著只會讓人再接錯線。
- 組合根(`cli/main/Main.hs`)只有 `CmdScan` 走 init,其餘 23 個指令一律走 query。

清理:`--help`、`--help-shm`、`--help-wal`、`.assetdb/assetdb.sqlite` 刪除前以
`assetdb doctor --db <path>` 確認四個檔案的資源筆數皆為 0,確係事故產物而非真實索引。

## 實作備註

與規格的偏差,以及規格沒寫但實作有做的部分:

1. **只有 `scan` 算初始化指令**,不含規格 T3 寫的 `new-project`。`new-project` 是從既有索引挑
   素材放進新專案,空資料庫裡沒有東西可挑;把它歸為初始化類等於讓「連錯資料庫」在建專案時
   也靜默通過。`reorganize` 同理(它本來就會在空庫時提示先跑 `scan`)。
2. **`resolveDbPathForInit` 也會先往上找**。規格只寫「找不到就在 cwd 建立」,但那會讓從子目錄
   執行 `scan` 建出第二個資料庫 —— 與本 bug 同一種病。
3. **`--db` 指到不存在的檔案時查詢類指令也報錯**。規格只講沒帶 `--db` 的情形,但打錯絕對路徑
   跟站錯目錄是同一個失敗模式,沒有理由只擋一半。
4. **`cli` 套件拆成 library + executable**,`Main.hs` 移到 `cli/main/`,其餘模組留在 `cli/app/`
   並由新的 library stanza 匯出。原本所有模組都掛在 executable 的 `other-modules` 底下,
   在那裡的程式碼測不到,T1/T3 的單元測試無從寫起。這也是 enhance-0013 的前置條件。
5. **T2 的測試模組叫 `AssetDB.Cli.EndToEndSpec` 而非對照表寫的 `CliSpec`**,避免與
   `AssetDB.Cli.*` 這個命名空間本身混淆;測試內容與對照表一致,並額外驗證了「工作目錄下
   沒有被建出 `.assetdb`」。
