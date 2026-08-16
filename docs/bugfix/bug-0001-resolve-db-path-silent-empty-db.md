---
id: bug-0001
type: bug
title: resolve-db-path-silent-empty-db
description: CLI resolveDbPath 在錯誤目錄執行時靜默建立空資料庫,查詢回報 0 筆而非路徑錯誤
status: open
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
`診斷報告-2026-08-11.md` 記錄的「前端顯示 0 筆」事故的根因之一。

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

- [ ] T1: 實作 `findDbUpwards`,向上搜尋 `.assetdb/assetdb.sqlite`
- [ ] T2: 一般查詢指令改用 `findDbUpwards`,找不到時 `die` 並印出清楚訊息
- [ ] T3: 新增 `resolveDbPathForInit`,只給 `scan`/`new-project` 等初始化指令使用
- [ ] T4: 清理事故殘留檔案(`--help*`、誤建的空庫)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `OptionsSpec.findDbUpwards 從子目錄能找到上層的 .assetdb` | 建立暫存目錄樹,子目錄執行應找到根目錄的資料庫 |
| T1 | `OptionsSpec.findDbUpwards 到檔案系統根都找不到回 Nothing` | 空目錄樹,確認回傳 `Nothing` 而非拋例外 |
| T2 | `CliSpec.search 在錯誤目錄執行時以非 0 結束碼失敗並印出訊息` | 端對端驗證不再靜默建空庫 |
| T3 | `OptionsSpec.resolveDbPathForInit 找不到時在 cwd 建立新路徑` | 確認初始化指令的行為未被誤改 |
| T4 | 手動驗證:重新執行一次乾淨的 `scan` 後 `assetdb\--help*` 與誤建空庫已不存在 | 非自動化測試,人工確認一次即可 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
