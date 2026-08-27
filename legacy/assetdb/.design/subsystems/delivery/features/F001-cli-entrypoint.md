---
id: F001
type: feature
title: cli-entrypoint
description: 指令與參數解析、資料庫路徑解析、各子命令的組合根
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-001]
---

# F001: 命令列入口

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

`assetdb` 執行檔是整個系統的無頭入口:前端出現之前它是唯一的入口,之後也仍然是腳本與
AI agent 的入口。它同時是唯一依賴全部套件的組合根——catalog、ingest、ai-tagging、
以及 delivery 自己的 `project` 都在這裡被接上。

這個功能包含三件事:

1. **指令文法**:以 `optparse-applicative` 定義的頂層指令、子指令、旗標與預設值,
   全部收斂成一個 `Command` 代數型別。
2. **資料庫路徑解析**:「找到既有資料庫」與「決定新資料庫要建在哪」是兩件不同的事,
   刻意用兩個函式表示。合成一個並預設後者的話,在錯誤工作目錄下的任何查詢都會靜默建出空庫,
   使用者看到的是「查無結果」而不是「你的路徑錯了」。
3. **dispatch**:唯一的 `case` 把 `Command` 接到對應的 runner,並在此處決定該用哪一種
   路徑語意——只有 `scan` 是初始化語意。

指令實作放在 library、只有 `main` 留在 executable:executable 裡的模組測不到,
而路徑解析與參數解析正是最需要測試的部分。

## 落地位置

- `cli/app/AssetDB/Cli/Options.hs` —— 完整指令文法、`Command` / `Invocation` / `GlobalArgs`、
  `ReorgMode`、`findDbUpwards` / `resolveDbPathForQuery` / `resolveDbPathForInit` 與錯誤訊息
- `cli/app/AssetDB/Cli/{Scan,Doctor,Pack,Reorg,Cluster,Search,Thumbs,Project,Notes,Ai}.hs`
  —— 每個指令族一個模組,各自定義自己的 args 型別
- `cli/main/Main.hs` —— 主控台 UTF-8 設定、路徑語意選擇、`Command` → runner 的 dispatch
- `cli/assetdb-cli.cabal` —— library / executable 的切分,以及對全部套件的相依宣告

## 對外行為

- 全域選項 `--db PATH`(預設 `./.assetdb/assetdb.sqlite`,並會從工作目錄逐層往上尋找
  `.assetdb/assetdb.sqlite`,一路找到檔案系統根為止)。
- 頂層指令:`scan`、`tools`、`doctor`、`pack`、`reorganize`、`cluster`、`search`、`index`、
  `thumbs`、`new-project`、`note`、`link`、`ai`。
- 查詢類指令要求資料庫必須已存在,找不到就以非 0 結束碼結束,訊息同時給出兩條出路
  (`--db <路徑>` 與 `assetdb scan --root <素材庫路徑>`),而且**不建立任何檔案**。
- `scan` 是唯一的初始化語意:先往上找既有資料庫,找不到才在工作目錄下開新的——避免從
  子目錄執行時建出第二個資料庫。
- 會改動狀態的動作預設只預覽:`cluster rule`、`ai suggest confirm/reject`、`ai apply`
  需要 `--confirm`;`reorganize` 的四種模式互斥且沒有預設值,可回退的階段 A 與不可回退的
  階段 B 需要兩個旗標。
- `--llm-url` / `--llm-model` / `--thinking` 只掛在需要模型的 `ai` 子指令上,不做成全域選項。
- `search --limit` 預設 20(一個終端機畫面放得下的量);各入口的分頁預設刻意不同——
  server 60 / 上限 500、web 一頁 120、store 層函式庫預設 50。
- 啟動時先設定主控台 UTF-8:素材路徑與素材包名大量含中文,只設定輸出編碼的話檔案是對的、
  螢幕是亂碼。

## 驗收依據

`cli/test/`(hspec,以 `hspec-discover` 收集;`cabal test all` 全綠):

- **`cli/test/AssetDB/Cli/OptionsSpec.hs`** —— 路徑解析
  - `findDbUpwards`:「從子目錄能找到上層的 .assetdb」、「資料庫就在當層時也找得到」、
    「到檔案系統根都找不到時回 Nothing,不拋例外」、「目錄裡有 .assetdb 但沒有資料庫檔時不算命中」
  - `resolveDbPathForInit`:「找不到既有資料庫時,回傳 cwd 底下的新路徑」、
    「從子目錄執行時沿用上層既有的資料庫,不開第二個」、「--db 指定時直接採用,並轉成絕對路徑」
  - `resolveDbPathForQuery`:「找得到既有資料庫時回傳它的絕對路徑」
  - 錯誤訊息:「找不到資料庫時提示 --db 與 scan」、「--db 指到不存在的檔案時把路徑印出來」
- **`cli/test/AssetDB/Cli/ParserSpec.hs`** —— 指令文法(以 `execParserPure` 餵參數列,
  不會被 `execParser` 登出)
  - `--help`:「以「成功」結束,而不是被當成解析錯誤」、「說明裡列出所有頂層指令」、
    「子指令也有自己的說明」
  - 全域選項:「--db 收得到,而且是全域的(位置在子指令之前)」、
    「沒給 --db 時是 Nothing,不是某個預設路徑字串」
  - `scan`:「--root 是必填,漏掉就解析失敗」、「只給 --root 時其餘欄位採預設值」、
    「旗標與選項一起給時全部收得到」
  - `search`:「-q 與 --text 是同一個選項」、「沒有任何條件時也是合法呼叫」、
    「可重複的選項累積成清單,順序保留」、「--limit 預設 20」、
    「--limit 收非數字時解析失敗,而不是靜靜地用預設值」、「各個布林旗標互不影響」
  - `new-project`:「--name 與 --path 都是必填」、「授權閘門預設是開的」、
    「--allow-non-commercial 要明講才會關掉閘門」
  - `reorganize`:「沒有給模式旗標時解析失敗」、「--dry-run 不需要其他旗標」、
    「--apply 的不可回退部分要另外明講」、「--delete-covered 單獨給不算指定模式」、
    「--source 與 --target 是必填,即使已經給了模式」
  - 未知輸入:「不存在的指令解析失敗」、「不存在的旗標解析失敗,不會被當成位置參數吞掉」
- **`cli/test/AssetDB/Cli/EndToEndSpec.hs`** —— 以 `build-tool-depends` 掛上真實
  `assetdb` 執行檔跑的端到端測試,`assetdb search`(錯誤的工作目錄):
  「以非 0 結束碼失敗,而不是回報查無結果」、「印出的訊息告訴使用者可以用 --db 指定路徑」、
  「不會在工作目錄下靜默建出空資料庫」
