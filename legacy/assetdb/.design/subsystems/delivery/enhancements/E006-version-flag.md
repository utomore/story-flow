---
id: E006
type: enhance
title: version-flag
description: 兩個執行檔加上 --version,版本號以 .cabal 為唯一來源
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: []
related-feature: [F001, F002]
---

# E006: `--version` 旗標

## 現況說明

`assetdb` 與 `assetdb-server` 都沒有辦法查版本。PATH 上的 `cabal install` 副本與 repo 裡
`cabal run` 的版本常常不同(CLAUDE.md 的已知陷阱),而使用者唯一的判斷方式是「跑一個新指令
看會不會 `Invalid argument`」。

九個 `.cabal` 的 `version` 欄位都是 `0.1.0.0`(由使用者指定),但沒有任何程式碼讀它。

## 修正方案

- 版本號**只有一個來源**:各套件 `.cabal` 的 `version` 欄位。程式碼透過 cabal 自動產生的
  `Paths_assetdb_cli` / `Paths_assetdb_server` 模組的 `version :: Data.Version.Version` 讀取,
  不在 Haskell 裡另寫一份字串。
- `assetdb --version` → 印 `assetdb 0.1.0.0`,結束碼 0。走 optparse-applicative 的 `infoOption`,
  與 `--help` 同一類(印完即結束),放在全域選項層級,不需要子指令。
- `assetdb-server --version` → 印 `assetdb-server 0.1.0.0`,結束碼 0。`parseArgs` 新增
  `ShowVersion` 建構子;比對順序與 `--help` 相同,**優先於「第一個參數是 db 路徑」**。
- `usageText` 與 `--help` 輸出列出 `--version`。
- 版本號本身由使用者指定;本次維持 `0.1.0.0`,不動任何 `.cabal` 的 `version` 欄位。

介面變動(Level 2):`delivery/design.md` §2 伺服器命令列多一行 `assetdb-server --version`、
§3 全域選項多 `--version`;`system.md` §1、§2 同步。不碰其他子系統。

## TodoList

- [x] T1: `cli`:`Options.hs` 全域層加 `infoOption`,版本字串來自 `Paths_assetdb_cli`;`.cabal` 登記 autogen 模組  `dep: -`
- [x] T2: `server`:`Cli.hs` 加 `ShowVersion`、`parseArgs` 比對 `--version`、`usageText` 列出;`Main.hs` 印出;版本來自 `Paths_assetdb_server`  `dep: -`
- [x] T3: 文檔同步:`delivery/design.md` §2 §3、`system.md` §1 §2、README 安裝節  `dep: T1, T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ParserSpec "--version 以成功結束,輸出含 0.1.0.0"`、`"--help 列出 --version"` | optparse 的 `infoOption` 走 `Failure` 路徑但 exit 0,與 `--help` 同 |
| T2 | `CliSpec "--version 優先於「第一個參數是 db 路徑」"`、`"usageText 列出 --version"`、`"versionText 含 .cabal 的版本號"` | 位置不限,與 `--help` 同規則 |
| T3 | (文檔,無測試) | — |

## 實作備註

- `Paths_assetdb_cli` / `Paths_assetdb_server` 以 `other-modules` + `autogen-modules` 登記在各自的 library;
  `--version` 實測兩個執行檔都印 `0.1.0.0`、exit 0,`assetdb-server db.sqlite --version` 也是。
- 測試:`ParserSpec` +3、`CliSpec` +3;`cabal test all` 689 examples, 0 failures。
