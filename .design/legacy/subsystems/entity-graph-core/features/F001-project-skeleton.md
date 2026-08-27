---
id: F001
type: feature
title: project-skeleton
description: 建立 cabal 多套件骨架與本機建置測試腳本
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: [ADR-001, ADR-002]
related-feature: [F002, F003, F004]
---

# F001: P0 專案骨架

## 功能概述

story-flow 目前只有 `docs/`,沒有任何程式碼。本規格建立可建置、可測試的最小骨架:
`cabal.project` 多套件配置、P1 所需的 4 個套件(`core` / `types` / `md` / `store`)、
每個套件一個佔位模組與一個會被執行到的 hspec 測試套件,以及本機一鍵建置測試腳本。

這一階段**不寫任何業務邏輯**。它要證明的只有一件事:GHC 9.14.1 + cabal 3.16.x 的工具鏈在
這台機器(Windows 11)上跑得起來,而且 `direct-sqlite` 的 `+fulltextsearch` flag 確實
生效(FTS5 與 trigram tokenizer 可用)——這是整個專案的地基,踩雷要在寫任何邏輯前踩到。

**功能邊界**

做:`cabal.project`、4 個 `.cabal` 檔、佔位模組、hspec 骨架、UTF-8 輸出設定、
`scripts/check.ps1` 與 `scripts/check.sh`、README 建置章節。

不做:任何型別定義(F002)、任何解析(F003)、任何檔案或資料庫操作
(F004)、CI(見下)、`service` / `conflict` / `llm` / `workshop` / `server` / `cli` /
`mcp` 七個套件的骨架(各自階段再建)。

**對應的開發階段**:system.md 的 P0。

**與 system.md 的兩處偏差**(已與開發者確認,將回寫 system.md):

1. P0 完成標準原寫「CI」。實際決定**不建 GitHub Actions**,改為本機 `scripts/check`
   一鍵建置測試。參考專案 `assetdb` 同樣沒有 CI,單人工作室沒有協作觸發 CI 的需求。
2. 套件清單新增 `storyflow-types`(型別註冊表的 TOML 載入層)。`storyflow-core` 必須維持
   零 IO,而讀 `types/*.toml` 是 IO,兩者必須拆開。

**驗收標準**

- `cabal build all` 綠燈,無 warning(各套件已開 `-Wall -Wcompat`)
- `cabal test all` 綠燈,4 個測試套件全部被執行到
- store 的 smoke test 能開啟 SQLite 記憶體資料庫、建立一張 FTS5 trigram 表並成功查詢
  ——證明 `+fulltextsearch` flag 生效
- `scripts/check.ps1`(Windows)與 `scripts/check.sh`(POSIX)執行後 exit code 0
- 測試輸出的繁體中文描述在 Windows 終端不亂碼

## 相依性

`depends-on: []` —— 本規格是所有後續工作的前提,沒有任何前置依賴,可立即開工。

F002 / F003 / F004 全部依賴本規格產出的套件骨架,因此**本規格必須先完成**,
不能與它們平行。完成後 F002 隨即可開工。

## 對應的 Level 2 契約

對應 `design.md` 契約卡 `project-skeleton`。本規格**不實作**任何「對外契約」或「模組間
公開介面」的條目,只建立它們之後要住進去的四個套件與測試骨架,因此沒有超出契約的風險;
驗收全部落在建置與工具鏈層面。

## 實作方式

### 目錄結構(本規格產出的全部檔案)

```
story-flow/
├── cabal.project
├── core/
│   ├── storyflow-core.cabal
│   ├── src/StoryFlow/Core.hs
│   └── test/Spec.hs
│       test/StoryFlow/CoreSpec.hs
├── types/
│   ├── storyflow-types.cabal
│   ├── src/StoryFlow/Types.hs
│   └── test/Spec.hs
│       test/StoryFlow/TypesSpec.hs
├── md/
│   ├── storyflow-md.cabal
│   ├── src/StoryFlow/Md.hs
│   └── test/Spec.hs
│       test/StoryFlow/MdSpec.hs
├── store/
│   ├── storyflow-store.cabal
│   ├── src/StoryFlow/Store.hs
│   └── test/Spec.hs
│       test/StoryFlow/StoreSpec.hs
└── scripts/
    ├── check.ps1
    └── check.sh
```

注意 `types/` 這個目錄名同時是 system.md 裡「型別註冊表 TOML 放置處」的名稱。
為避免混淆,**TOML 註冊表檔案放在 `types/registry/*.toml`**,Haskell 套件原始碼放
`types/src/`。這一點在 F002 建立實際 TOML 檔時會用到。

### cabal.project

完整沿用 assetdb 的配置(ADR-001),只換套件清單:

```
-- story-flow — 故事設定的片段圖譜與場景樹管理工具
-- GHC 9.14.1 / cabal 3.16.x,不使用 stack。

packages:
  core/
  types/
  md/
  store/

-- GHC 9.14 (base-4.22) 仍是新版本,部分套件的 base 上界尚未放寬。
-- 只對確定安全的套件開放,不要全域 allow-newer。
allow-newer:
  , *:base
  , *:template-haskell
  , *:ghc-prim

tests: True

package storyflow-core
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns

package storyflow-types
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns

package storyflow-md
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns

package storyflow-store
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns

-- direct-sqlite 預設不編入 FTS5。全文檢索是衝突偵測第 2 層的基礎,
-- 而且 trigram tokenizer(中文搜尋所需)只存在於 FTS5。
package direct-sqlite
  flags: +fulltextsearch
```

`service` 等七個套件在各自階段的文檔裡加入 `packages:` 清單。

### 各套件 .cabal 的共同設定

```
cabal-version:      3.4
version:            0.1.0.0
license:            BSD-3-Clause
author:             Alchbees Studio
maintainer:         lhm.stu@gmail.com
build-type:         Simple
default-language:   GHC2021
default-extensions:
    DerivingStrategies
    LambdaCase
    OverloadedStrings
    RecordWildCards
    StrictData
```

`common warnings` 區塊 `ghc-options: -Wall -Wcompat`,library 與 test-suite 都 `import: warnings`。

各套件 P0 階段的 `build-depends`(僅骨架所需,後續文檔 再擴充):

| 套件 | build-depends |
|---|---|
| `storyflow-core` | `base`, `text`, `containers`, `time` |
| `storyflow-types` | `base`, `text`, `containers`, `storyflow-core` |
| `storyflow-md` | `base`, `text`, `storyflow-core` |
| `storyflow-store` | `base`, `text`, `bytestring`, `sqlite-simple`, `direct-sqlite`, `storyflow-core` |

依賴方向由此固定:`core` 誰都不依賴;`types` / `md` / `store` 只依賴 `core`。
編譯器從第一天就在守這條線(ADR-001)。

### 佔位模組

每個套件一個模組,只暴露一個版本常數,後續文檔 會把真正的模組加進 `exposed-modules`:

```haskell
-- core/src/StoryFlow/Core.hs
module StoryFlow.Core (coreVersion) where

import Data.Text (Text)

-- | 套件骨架的佔位常數,F002 建立真正的型別模組後可移除。
coreVersion :: Text
coreVersion = "0.1.0.0"
```

`types` / `md` / `store` 同型(`typesVersion` / `mdVersion` / `storeVersion`)。

### 測試進入點與 UTF-8 輸出

本專案的測試描述一律繁體中文,Windows 終端預設 code page 950 會亂碼。兩層都要處理:

1. **程式端**:每個 `test/Spec.hs` 在跑 hspec 前設定 handle 編碼。
   這是測試碼,不影響 `core` 零 IO 的約束。

```haskell
-- core/test/Spec.hs
module Main (main) where

import System.IO
import Test.Hspec
import qualified StoryFlow.CoreSpec

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hspec StoryFlow.CoreSpec.spec
```

2. **終端端**:`hSetEncoding` 只管程式產生什麼位元組,管不到終端機怎麼解讀。
   `scripts/check.ps1` 進入時設 `chcp 65001` 與
   `[Console]::OutputEncoding = [Text.Encoding]::UTF8`(assetdb 踩過同一個坑)。

### store 的 FTS5 驗證測試

這是 P0 唯一有實質內容的測試,目的是讓 `+fulltextsearch` flag 沒生效時**立刻**失敗,
而不是等到 P1 寫檢索時才發現:

```haskell
-- store/test/StoryFlow/StoreSpec.hs
spec :: Spec
spec = describe "SQLite 建置環境" $
  it "direct-sqlite 已編入 FTS5 且支援 trigram tokenizer" $
    withConnection ":memory:" $ \conn -> do
      execute_ conn
        "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='trigram')"
      execute_ conn "INSERT INTO t(body) VALUES ('埃提亞崩塌前的織紋刀')"
      rows <- query_ conn "SELECT body FROM t WHERE t MATCH '織紋'"
                :: IO [Only Text]
      rows `shouldBe` [Only "埃提亞崩塌前的織紋刀"]
```

這條測試同時驗證了三件事:FTS5 有編進去、trigram tokenizer 存在、中文子字串檢索行得通。

### 本機建置測試腳本

`scripts/check.ps1`(Windows 主要開發環境):

```powershell
# story-flow 一鍵建置與測試。CI 的替代品(見 F001)。
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

Write-Host '== cabal build all =='
cabal build all
if (-not $?) { exit 1 }

Write-Host '== cabal test all =='
cabal test all --test-show-details=direct
if (-not $?) { exit 1 }

Write-Host '== OK =='
```

`scripts/check.sh` 是等價的 POSIX 版(`set -euo pipefail` + 同兩道指令),供未來在
Linux 上或 WSL 內執行。兩份腳本的指令內容必須一致——不一致就會出現「本機過、另一台不過」。

### 錯誤處理

P0 沒有執行期錯誤處理可談。建置期的已知風險與對策:

- **GHC 9.14 的 base 上界**:某個相依套件不接受 `base-4.22` 時,`cabal.project` 的
  `allow-newer` 已對 `*:base` 開放,通常即可解決;若某套件是實質不相容(不只是上界問題),
  記錄在「實作備註」並考慮換套件。**不要全域開 `allow-newer: all`**。
- **`direct-sqlite` 的 `+fulltextsearch` 沒生效**:T5 的測試會直接失敗並顯示
  `no such tokenizer: trigram` 或 `no such module: fts5`。對策是確認 `cabal.project`
  的 `package direct-sqlite` 區塊有被讀到(`cabal build --dry-run -v2` 可看解析結果)。
- **Windows 路徑與長檔名**:`dist-newstyle` 巢狀很深,遇到路徑長度上限時在
  `cabal.project.local`(已 gitignored)設較短的 `builddir`。

## 使用到的既有串接介面

本專案第一份規格,程式碼庫為空,**沒有既有的內部介面**。

外部工具鏈介面(既有、不由本專案定義):

| 介面 | 來源 | 用途 |
|---|---|---|
| `cabal build all` / `cabal test all` | cabal 3.16.x | 建置與測試進入點 |
| `Test.Hspec.hspec :: Spec -> IO ()` | `hspec` | 測試執行器 |
| `Database.SQLite.Simple.withConnection :: String -> (Connection -> IO a) -> IO a` | `sqlite-simple` | 開啟連線 |
| `Database.SQLite.Simple.execute_ :: Connection -> Query -> IO ()` | `sqlite-simple` | 執行 DDL/DML |
| `Database.SQLite.Simple.query_ :: FromRow r => Connection -> Query -> IO [r]` | `sqlite-simple` | 查詢 |
| `System.IO.hSetEncoding :: Handle -> TextEncoding -> IO ()` | `base` | 輸出編碼 |

## 新增的介面

P0 只產出佔位介面,實質內容由後續規格填入:

| 模組 | 介面 | 說明 |
|---|---|---|
| `StoryFlow.Core` | `coreVersion :: Text` | 佔位常數,F002 後可移除 |
| `StoryFlow.Types` | `typesVersion :: Text` | 佔位常數,F002 後可移除 |
| `StoryFlow.Md` | `mdVersion :: Text` | 佔位常數,F003 後可移除 |
| `StoryFlow.Store` | `storeVersion :: Text` | 佔位常數,F004 後可移除 |

真正新增的「介面」是**建置契約**:

- `cabal.project` 宣告的 4 個套件與其依賴方向(`core` ← `types` / `md` / `store`)
- `scripts/check.ps1` / `scripts/check.sh`:exit 0 表示建置與測試全綠

## TodoList

- [x] T1: 建立 `cabal.project`(4 套件、`allow-newer` 三項、`tests: True`、各套件 ghc-options、`direct-sqlite +fulltextsearch`)
- [x] T2: 建立 `storyflow-core` 套件(cabal 檔、`StoryFlow.Core` 佔位模組、test-suite)
- [x] T3: 建立 `storyflow-types` 套件(cabal 檔、`StoryFlow.Types` 佔位模組、test-suite,依賴 `storyflow-core`)
- [x] T4: 建立 `storyflow-md` 套件(cabal 檔、`StoryFlow.Md` 佔位模組、test-suite,依賴 `storyflow-core`)
- [x] T5: 建立 `storyflow-store` 套件(cabal 檔、`StoryFlow.Store` 佔位模組、test-suite,依賴 `storyflow-core` 與 sqlite)
- [x] T6: 四個 `test/Spec.hs` 統一設定 stdout/stderr UTF-8 編碼
- [x] T7: 建立 `scripts/check.ps1` 與 `scripts/check.sh`,並在 README 補「建置與測試」章節

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `scripts/check` 第 1 階段:`cabal build all` | 4 個套件全部被解析並建置成功,無 warning;驗證 `allow-newer` 與 ghc-options 生效 |
| T2 | `StoryFlow.CoreSpec` — `coreVersion` 非空 | core 套件可建置、可被測試套件連結、測試被 `cabal test all` 執行到 |
| T3 | `StoryFlow.TypesSpec` — 可 import `StoryFlow.Core` 並取得 `coreVersion` | 驗證 `types → core` 的依賴方向在 cabal 層真的接上了 |
| T4 | `StoryFlow.MdSpec` — 可 import `StoryFlow.Core` 並取得 `coreVersion` | 驗證 `md → core` 的依賴方向接上 |
| T5 | `StoryFlow.StoreSpec` — 建立 `fts5(tokenize='trigram')` 表並以「織紋刀」命中中文內容;另一條斷言「織紋」(兩字)不命中 | 一次驗證 FTS5 已編入、trigram tokenizer 存在、中文子字串檢索可行,並釘住 trigram 的三字元下限(見實作備註偏差 1) |
| T6 | `StoryFlow.CoreSpec` — 斷言 `hGetEncoding stdout` 為 UTF-8 | 確認測試進入點的編碼設定真的執行到,繁中描述不亂碼 |
| T7 | `scripts/check.ps1` 執行後 exit code 0 且輸出 4 個測試套件結果 | 一鍵腳本可用;README 步驟照做即可得到相同結果 |

## 實作備註

### 偏差 1:FTS5 trigram 的查詢字串下限是 3 個字元(重要)

本規格原本寫的 T5 測試以 `MATCH '織紋'`(兩個字)命中「埃提亞崩塌前的織紋刀」。實際執行時
**建表與寫入都成功、查詢回傳空集合**。原因不是 `+fulltextsearch` 沒生效,而是 SQLite 的
trigram tokenizer 以「連續三字元」為索引單位,查詢字串**少於 3 個字元時一律不命中**
(SQLite 官方文件明載)。測試已改為 `MATCH '織紋刀'` 並通過。

flag 本身是生效的——`CREATE VIRTUAL TABLE ... USING fts5(tokenize='trigram')` 沒有拋出
`no such module: fts5` 或 `no such tokenizer: trigram`,這就是 T5 真正要驗證的事。

同時新增一條測試把這個限制釘住:`MATCH '織紋'` 斷言回傳空集合。這樣它是一條有紀錄的
已知行為,而不是 P4 才被重新發現的意外。

**對後續階段的影響(需要在 F004 / P4 處理)**:中文的二字詞極為常見——角色名「琳達」、
「塔主」都是兩個字。若衝突偵測第 2 層直接把關鍵詞丟進 FTS5,這類詞會全部撈不到候選,
而且是**靜默**撈不到。可行的對策(留待該階段決定):

- 二字以下的詞改走 `entities` / `entity_aliases` 表的 `LIKE '%詞%'`,不走 FTS
- 或於索引時把 `title` / `aliases` 補進 FTS 欄位並在查詢端補字(如 `織紋*` 的前綴查詢)

架構文件的「FTS5 trigram 承擔中文檢索」這句話本身沒錯,但它有這個下限,建議在 P4 的規格
裡明確寫出來。

### 偏差 2:`scripts/check.ps1` 的離開碼判斷改用 `$LASTEXITCODE`

規格原文寫 `if (-not $?) { exit 1 }`。在 PowerShell 中 `$?` 對原生執行檔(cabal.exe)的
成敗判斷並不可靠——cabal 只要往 stderr 寫任何東西就可能讓 `$?` 為 `$false`,而
`$ErrorActionPreference = 'Stop'` 也管不到原生執行檔的離開碼。已改為
`if ($LASTEXITCODE -ne 0) { exit 1 }`,這是唯一能忠實反映 cabal 離開碼的寫法。
`check.sh` 以 `set -euo pipefail` 達到等價效果,兩份腳本的指令內容仍然一致。

### 其他

- 各套件的 `.cabal` 以 `common warnings` / `common lang` 兩個區塊表達共同設定,library 與
  test-suite 都 `import: warnings, lang`;`cabal.project` 的 `ghc-options` 再疊上
  `-Wincomplete-record-updates -Wincomplete-uni-patterns`。
- T6 的驗證方式:`StoryFlow.CoreSpec` 以 `hGetEncoding stdout` 斷言為 `UTF-8`,stderr 同。
- `.gitignore` 建立本規格前即已存在且涵蓋 `dist-newstyle/` 等項目,未做修改。
- 建置結果:`cabal build all` 無任何 warning;`cabal test all` 4 個測試套件全部被執行,
  共 12 個 example、0 失敗;`scripts/check.ps1` exit code 0。
