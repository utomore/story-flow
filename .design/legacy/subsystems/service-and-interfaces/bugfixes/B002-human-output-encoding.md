---
id: B002
type: bugfix
title: human-output-encoding
description: 人類模式的輸出導向檔案或管線時是 Windows 的 code page,不是 UTF-8
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [F002]
---

# B002: 給人看的輸出在 Windows 導向時是 CP950

## 症狀

Windows 上 `story-flow vault init . --name 測試世界 > out.txt`,`out.txt` 的位元組是
CP950(`A4 77 AB D8 …` = Big5 的「已建」),任何 UTF-8 工具讀它都是亂碼;`--help`、所有錯誤
訊息、`entity show` 的人類格式全部一樣。`--json` 那條路徑**是對的**(`Cli.hs` 的 `jsonLine`
自己 `encodeUtf8`)。

影響:給人看的輸出只要不是直接印在 cp950 主控台上(導向檔案、經管線給別的程式、在
claude code 的 Bash 裡跑),繁中就壞。而這個工具的全部人類輸出都是繁中。

## 重現步驟

```
story-flow --help > h.txt
file h.txt          # ISO-8859 text(修復前)/ UTF-8 text(修復後)
```

最小重現碼(已成回歸測試 `cli/test/StoryFlow/Cli/EncodingSpec.hs`):開三個**不設編碼**的
臨時檔 handle,`runCliWith (CliIO hOut hErr hIn) ["--help"]`,讀回位元組 `decodeUtf8'` 要成功
且含「故事設定」。修復前在 cp950 locale 的機器上 `decodeUtf8'` 失敗。

## 根因分析

`cli/src/StoryFlow/Cli.hs:320`:

```haskell
line :: Handle -> Text -> IO ()
line = TIO.hPutStrLn
```

`hPutStrLn` 用 handle 的編碼,GHC 預設是 locale 編碼,Windows 上就是系統 ANSI code page。
同檔的 `jsonLine` 有一段註解解釋為什麼 `--json` 要繞過 handle 自己編 UTF-8,而 `line` 的註解
寫的是**刻意**走 handle 編碼 —— 「Windows 主控台是 cp950 時,繁中要交給它的 codec 才顯示
得出來」。這個理由對**終端機**成立,但它被套到了所有 handle 上,包括檔案與管線。

**為什麼 1435 條測試抓不到**:`cli/test/StoryFlow/Cli/Fixtures.hs` 的 `withTempHandle` 對每個
測試 handle 都先 `hSetEncoding h utf8`。測試環境把真實條件遮掉了 —— 這不是測試寫錯,是
fixture 的便利設定剛好蓋住了這個 bug 會出現的唯一條件。

## 修復方向

區分終端機與非終端機:`runCliWith` 一開始對 `cliOut` / `cliErr` 各做一次
`hIsTerminalDevice`,**不是終端機就 `hSetEncoding utf8`,是終端機就不動**。

- 終端機:保留原本的設計意圖,主控台 codec 負責顯示
- 非終端機:接收端是另一個程式,沒有「顯示」這回事,共同語言是 UTF-8

放在 `runCliWith` 而不是 `runCli`:測試走的是 `runCliWith`,放在 `runCli` 測試就碰不到修法。
`--json` 路徑不受影響,它本來就自己編。

**不採用**的替代方案:無條件 `hSetEncoding stdout utf8`。那會讓 cp950 主控台上的繁中變成亂碼
—— 修一個壞另一個。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗;用不設編碼的 handle)  `dep: -`
- [x] T2: `runCliWith` 開頭對 out / err 做 `utf8UnlessTerminal`  `dep: T1`
- [x] T3: 更新 `line` 的註解,說明編碼在哪裡被定  `dep: T2`

## 驗證方式

- `cabal test storyflow-cli`:T1 由紅轉綠
- 實跑(**要 `cabal build exe:story-flow`,`cabal test` 不會重 link 執行檔**):
  `story-flow --help > h.txt` 後 `file h.txt` 是 UTF-8;昨天那條 `vault init … > out.txt` 也是

## 修復紀錄

照「修復方向」修完,無偏差。`cli-test` 249 → 250。

一個實作時的小坑:`cabal test` 通過後實跑執行檔還是 cp950,查了一陣才發現 `cabal test` 只重建
library 與 test 元件,執行檔要另外 `cabal build exe:story-flow`。記在「驗證方式」裡。

**建議另開的事**(不在本 bug 範圍):`doctor` 的人類輸出刻意用 ASCII 前綴(`[ok]` / `[!!]`)
就是為了這個 bug;修好之後那個取捨仍然合理(終端機上 cp950 碰到 `✓` 還是會壞),不改回來。
