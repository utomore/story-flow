---
id: report-2026-08-11-console-encoding-and-db-path
type: report
title: console-encoding-and-db-path
description: 主控台亂碼與資料庫路徑錯誤的現場診斷
status: done
created: 2026-08-11
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# AssetDB 診斷報告 — 2026-08-11

> **2026-08-16 更新**:本報告原本以 `診斷報告-2026-08-11.md` 放在 alchbees-dev 工作區根目錄,
> 未納入版本控制;現依 dev-flow 慣例移入本專案的 `docs/analysis/`。內文維持原樣,
> 作為當時現場實測的完整記錄,不再更新。
>
> 問題 B 的兩項程式修正已轉為 `docs/bugfix/bug-0001`(CLI `resolveDbPath` 靜默建庫)與
> `bug-0002`(Server 靜默建檔),修正進度以那兩份文件為準——本報告只記錄當時的診斷過程。

兩個症狀,兩個獨立的原因。都已經在這台機器上實測確認,不是推測。

| # | 症狀 | 根本原因 | 嚴重度 |
|---|---|---|---|
| A | 所有指令輸出都是亂碼 | 程式輸出 UTF-8,但主控台的 output code page 是 **950 (Big5)** | 顯示層,資料沒壞 |
| B | 前端「0 筆 / 共 0」 | 指令在**原始碼目錄**執行,`resolveDbPath` 靜靜地開了一個全新的空資料庫 | 高 —— 靜默失敗 |

---

## 問題 A:亂碼

### 現象

```
?S?C 蟒 W ?璁 ?? ?\?o
   鞈 ?                     0
   ?臭 ?? 批 捆(blobs)       0
```

### 真正的輸出

同一個指令,把 stdout 導到檔案再以 UTF-8 解碼:

```
── 索引概況 ──
  資源                     0
  唯一內容(blobs)          0
```

**位元組是對的。壞掉的只有終端機的解碼。**

### 原因

`cli/app/Main.hs:22` 與 `server/app/Main.hs:13`:

```haskell
hSetEncoding stdout utf8
```

這一行做的事情是「把 Haskell `String` 編成 UTF-8 位元組」。它**沒有**、也**不能**告訴
Windows 主控台要用 UTF-8 去解讀那些位元組。

在 Windows 上,寫進 console handle 的位元組由 **console output code page** 決定怎麼顯示。
這台機器實測:

```
> getConsoleOutputCP()   →  950
> [System.Text.Encoding]::Default.WebName  →  big5
```

於是:

```
「資」  U+8CC7
  程式寫出 UTF-8:  E8 B3 87
  conhost 以 Big5 解讀: (E8 B3) → 「鞈」, (87 ..) → 對不上 → 「?」
  螢幕上:            鞈?
```

三個位元組的中文字被當成一個半 Big5 字,所以亂碼裡永遠是「一個奇怪的中文字 + 一個問號」
交替出現 —— 螢幕截圖裡的 `鞈 ?`、`?臭 ?? 批 捆` 完全符合這個模式。

`── 索引概況 ──` 的框線字元 U+2500 也是三位元組,同樣被切碎,所以連分隔線都花掉了。

### 原始碼裡的註解是錯的

```haskell
-- GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。素材路徑與素材包名稱
-- 大量含有中文,不設這個的話輸出全是亂碼 —— 而且重導向到檔案時同樣壞掉,
-- 所以不是終端機顯示問題,是真的寫錯位元組。
```

前半正確:不設 `hSetEncoding` 的話,寫檔真的會壞(Big5 存不下所有字,還會噴
`invalid character` 例外)。但結論下反了 —— 加上 `hSetEncoding` 之後,**寫檔正確了,
螢幕反而壞了**,因為這行只解決了「產生位元組」,沒解決「解讀位元組」。
兩件事都要做。

### 修正 1 — 立刻可用,不用重編譯

在 PowerShell 裡先切 code page:

```bash
chcp 65001
```

要每次都生效就寫進 profile(`notepad $PROFILE`):

```powershell
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```

> 註:PowerShell 5.1 + conhost 在 65001 下,中文字型要靠 fallback,行編輯偶爾會有
> 游標位置的小瑕疵。用 **Windows Terminal** 跑同一個 PowerShell 就沒有這個問題,
> 建議直接換過去。

### 修正 2 — 從程式端解決(建議)

程式自己把 code page 設好,使用者不必記得 `chcp`。`Win32` 是 GHC boot package,
這台機器上是 `Win32-2.14.2.1`,已經有了,不必安裝任何東西(我已實測編譯通過)。

**新增 `core/src/AssetDB/Console.hs`:**

```haskell
{-# LANGUAGE CPP #-}

-- | 終端機輸出的位元組層設定。
module AssetDB.Console (setupConsole) where

import System.IO
#ifdef mingw32_HOST_OS
import Control.Exception (SomeException, try)
import System.Win32.Console (setConsoleCP, setConsoleOutputCP)
#endif

-- | 讓 stdout\/stderr 以 UTF-8 輸出,**而且讓終端機以 UTF-8 解讀**。
--
-- 只設 'hSetEncoding' 是不夠的:GHC 會把 UTF-8 位元組原封不動寫進 console
-- handle,而 conhost 仍用 console output code page(繁中 Windows 預設 950\/Big5)
-- 去解碼 —— 三位元組的中文字被當成一個半 Big5 字,就變成「鞈?」這種亂碼。
-- 產生位元組與解讀位元組是兩件事,兩件都要設。
setupConsole :: IO ()
setupConsole = do
#ifdef mingw32_HOST_OS
  -- 沒有主控台時(輸出被導向管線、或當成服務跑)這兩個呼叫會失敗。
  -- 那是正常情況,不該讓程式死掉 —— 而且那種情況下 code page 本來就無關。
  _ <- try @SomeException (setConsoleOutputCP 65001)
  _ <- try @SomeException (setConsoleCP 65001)
  pure ()
#endif
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  hSetBuffering stdout LineBuffering
```

`try @SomeException` 需要 `TypeApplications`(GHC2021 已內建,不用額外開)。

**`core/assetdb-core.cabal`** —— 在 library 的 `exposed-modules` 加一行,並補條件相依:

```cabal
    exposed-modules:
        ...
        AssetDB.Console

    if os(windows)
        build-depends: Win32 >=2.13
```

**`cli/app/Main.hs`** —— 用它取代那三行:

```haskell
import AssetDB.Console (setupConsole)
-- 刪掉 import System.IO

main :: IO ()
main = do
  setupConsole
  Invocation global cmd <- parseInvocation
  ...
```

**`server/app/Main.hs`** —— 同樣把 `hSetEncoding stdout utf8` / `hSetEncoding stderr utf8`
換成 `setupConsole`。

#### 副作用,先講清楚

`setConsoleOutputCP` 改的是**整個主控台視窗**的狀態,程式結束後不會自己變回去。
對一個互動式 CLI 來說這通常正是你要的。如果希望離開時還原:

```haskell
withUtf8Console :: IO a -> IO a
withUtf8Console act =
  bracket (getConsoleOutputCP <* setConsoleOutputCP 65001) setConsoleOutputCP (const act)
```

我的建議是**不要還原**。這個工具的輸出本來就是 UTF-8,把終端機留在 65001 是正確狀態,
還原反而會讓「跑完 assetdb 之後再看剛剛的 scrollback」變成亂碼。

---

## 問題 B:前端什麼都沒有

### 現象

前端渲染正常,但右上角是 `0 筆 / 共 0`,左側 facet 欄只剩三個 checkbox。

### 這代表 API 是通的

`web/src/App.tsx:60` 的 `{health && ' / 共 ...'}` 是條件渲染 —— 「共 0」能顯示出來,
表示 `/api/health` **成功回傳了 `assets: 0`**。

`web/src/components/Facets.tsx:36` 的 `values.length > 0 &&` 同理 —— facet 分組全部消失,
表示後端回傳的四個 facet 陣列都是空的。

所以不是 CORS、不是 proxy、不是 404。**是資料庫真的空的。**

### 原因:三個資料庫,你連到了錯的那個

```
C:\Users\User\Documents\
├── alchbees-assets\.assetdb\assetdb.sqlite        10.3 MB   ← ✅ 正牌
│                                                    6397 資源 / 27 包 / 5320 縮圖
├── alchbees-dev\.assetdb\assetdb.sqlite           11.7 MB   ← ⚠️ 重構前的舊庫
│                                                    11822 資源,FTS 索引不同步
└── alchbees-dev\assetdb\.assetdb\assetdb.sqlite    364 KB   ← ❌ 今天早上剛生出來的空庫
                                                     0 資源  (建立時間 08:04:57)
```

第三個是空的、只有 schema、今天 08:04:57 才建立 —— 正好是你開後端的時間。

原因在 `cli/app/AssetDB/Cli/Options.hs:328`:

```haskell
resolveDbPath GlobalArgs {..} =
  case gaDbPath of
    Just p -> pure p
    Nothing -> do
      cwd <- getCurrentDirectory
      pure (cwd </> ".assetdb" </> "assetdb.sqlite")   -- ← 只看 cwd,不往上找
```

以及 `server/src/AssetDB/Server/App.hs:34`:

```haskell
runServer cfg =
  withStore (scDbPath cfg) $ \st -> do
    _ <- initSchema st                                 -- ← 檔案不存在就直接建一個
```

你的截圖裡提示字元是 `PS C:\Users\User\Documents\alchbees-dev\assetdb>` ——
那是**原始碼倉庫**,不是素材庫根目錄。於是:

1. `assetdb-server .assetdb/assetdb.sqlite` → 路徑不存在 → `withStore` 建檔 →
   `initSchema` 灌 schema → 364 KB 的空庫。
2. `assetdb doctor` → 同一個 cwd → 同一個空庫 → 全部 0。
3. 前端連上去 → `/api/health` 回 `assets: 0` → 「0 筆 / 共 0」。

**全程沒有任何一個錯誤訊息。** 這是這個 bug 最糟的地方。

### 驗證

我把伺服器指到正牌資料庫(port 8799)實測:

```
GET /api/health
{"assets":6397,"indexStale":false,"named":1653,"packs":27,"thumbs":5320}

GET /api/search?limit=2
{"items":[{"name":"atlas_gui_holo-book-animated-spritesheet-info_01a",
           "pack":"Complete UI Book Styles Pack",
           "author":"Crusenho Agus Hennihuno", ...}]}

GET /                                     200 text/html
```

**後端、前端、縮圖、搜尋、facet 全部正常。程式沒有壞,只是指錯了資料庫。**

### 修正 1 — 立刻可用

```bash
cd C:\Users\User\Documents\alchbees-assets
```

```bash
assetdb-server .assetdb\assetdb.sqlite
```

瀏覽器開 <http://localhost:8787>。`alchbees-assets\web\` 已經有建好的前端了。

不想切目錄就每次都帶 `--db`:

```bash
assetdb --db C:\Users\User\Documents\alchbees-assets\.assetdb\assetdb.sqlite doctor
```

### 修正 2 — 讓它不可能再發生

#### (a) `resolveDbPath` 往上找,找不到就**報錯**

`cli/app/AssetDB/Cli/Options.hs`:

```haskell
import Control.Monad (unless)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))

-- | 從 cwd 逐層往上找 @.assetdb\/assetdb.sqlite@。
--
-- 只看 cwd 是不夠的:在素材庫的子目錄、或在原始碼倉庫裡下指令都是常態。
findDbUpwards :: FilePath -> IO (Maybe FilePath)
findDbUpwards dir = do
  let candidate = dir </> ".assetdb" </> "assetdb.sqlite"
  ok <- doesFileExist candidate
  if ok
    then pure (Just candidate)
    else
      let up = takeDirectory dir
       in if up == dir then pure Nothing else findDbUpwards up

-- | 一般指令用。**找不到就死掉,絕不無中生有。**
--
-- 「找不到就在這裡開一個新的空資料庫」是最糟的失敗模式:它不報錯,
-- 只是讓之後每一個查詢都誠實地回答 0 筆。使用者會去查前端、查 proxy、
-- 查 CORS —— 唯獨不會想到資料庫是空的。
resolveDbPath :: GlobalArgs -> IO FilePath
resolveDbPath GlobalArgs {..} =
  case gaDbPath of
    Just p -> pure p
    Nothing -> do
      cwd <- getCurrentDirectory
      findDbUpwards cwd >>= \case
        Just p -> pure p
        Nothing ->
          die . unlines $
            [ "找不到資料庫。"
            , "  已從 " <> cwd
            , "  逐層往上找 .assetdb\\assetdb.sqlite,都沒有。"
            , ""
            , "  切到素材庫根目錄再執行,或用 --db <路徑> 指定。"
            , "  第一次建庫:assetdb scan --root <素材庫根>"
            ]

-- | @scan@ 是唯一可以無中生有的指令 —— 它就是「第一次建庫」。
--   但如果上層已經有一個,還是用那個,不要在子目錄裡開第二個。
resolveDbPathForInit :: GlobalArgs -> IO FilePath
resolveDbPathForInit GlobalArgs {..} =
  case gaDbPath of
    Just p -> pure p
    Nothing -> do
      cwd <- getCurrentDirectory
      maybe (cwd </> ".assetdb" </> "assetdb.sqlite") id <$> findDbUpwards cwd
```

匯出清單加上 `resolveDbPathForInit`,然後 `cli/app/Main.hs:29` 改成:

```haskell
    CmdScan args -> resolveDbPathForInit global >>= \db -> runScan db args
```

其餘 14 個 `resolveDbPath` 呼叫不用動。

#### (b) 伺服器不准建資料庫

`server/app/Main.hs`:

```haskell
import Control.Monad (unless)
import System.Directory (doesFileExist)
import System.Exit (die)

    (db : rest) -> do
      dbOk <- doesFileExist db
      unless dbOk . die $
        db <> " 不存在。\n\
        \伺服器不會替你建一個空資料庫 —— 那只會讓前端顯示「0 筆」而不報錯。\n\
        \先確認路徑,或在素材庫根目錄執行 assetdb scan --root <素材庫根>。"

      let assetdbDir = takeDirectory db
          webRoot = takeDirectory assetdbDir </> "web"
          port = case rest of
            (p : _) -> maybe (error ("port 不是數字:" <> p)) id (readMaybe p)
            _ -> 8787

      -- 靜態前端缺席不該是致命的(純 API 用法合法),但一定要講。
      webOk <- doesFileExist (webRoot </> "index.html")
      unless webOk $
        hPutStrLn stderr $
          "⚠ 找不到 " <> webRoot <> "\\index.html\n"
            <> "  API 會正常運作,但瀏覽器開 / 會是空白。\n"
            <> "  修正:在 web/ 執行 npm run build,把 web/dist/ 的內容複製到上面那個目錄。"

      runServer ServerConfig {..}
```

`port` 那行順手修掉 `read p` —— 現在打錯 port 會噴一個沒有上下文的
`Prelude.read: no parse`。

#### (c) 啟動時把實際位置印出來

`server/src/AssetDB/Server/App.hs` 的 `runServer`,在 `Warp.run` 之前多印兩行。
「我到底連到哪個檔案」不該需要靠猜:

```haskell
runServer cfg =
  withStore (scDbPath cfg) $ \st -> do
    _ <- initSchema st
    n <- query_ (storeConn st) "SELECT COUNT(*) FROM assets" :: IO [Only Int]
    putStrLn ("資料庫  " <> scDbPath cfg <> "  (" <> show (maybe 0 fromOnly (listToMaybe n)) <> " 筆資源)")
    putStrLn ("前端    " <> scWebRoot cfg)
    putStrLn ("assetdb-server  http://localhost:" <> show (scPort cfg))
    Warp.run (scPort cfg) (application cfg st)
```

有這兩行的話,今天早上第一秒就會看到 `(0 筆資源)`。

---

## 順手該清掉的東西

### 1. 今天早上誤建的空資料庫

```bash
Remove-Item -Recurse -Force 'C:\Users\User\Documents\alchbees-dev\assetdb\.assetdb'
```

(已被 `.gitignore` 忽略,所以沒進版控,刪掉沒有副作用。)

### 2. 一個叫 `--help` 的資料庫

`alchbees-dev\assetdb\` 底下有 `--help`、`--help-shm`、`--help-wal`,建立時間
今天 00:31。那是舊版 `assetdb-server` 把 `--help` 當成資料庫路徑的產物 ——
**這個 bug 已經修好了**(`server/app/Main.hs:19` 的 `any (elem ["--help","-h"])`
守衛,我實測現在的執行檔會正確印出用法)。只是那三個檔案沒人清:

```bash
Remove-Item -Force -LiteralPath 'C:\Users\User\Documents\alchbees-dev\assetdb\--help','C:\Users\User\Documents\alchbees-dev\assetdb\--help-shm','C:\Users\User\Documents\alchbees-dev\assetdb\--help-wal'
```

### 3. `alchbees-dev\.assetdb\` —— 這個你自己決定

11.7 MB、11822 筆資源、27 個包,最後寫入 8/10 22:30。看起來是**重構(reorganize)
之前**的舊索引:重構後的正牌庫只有 6397 筆,因為散檔被壓縮檔覆蓋、去重掉了
(doctor 顯示 5429 散檔中有 5424 筆雜湊已存在於壓縮檔內)。

它的 FTS 索引也已經不同步(`search` 只找得到 10979 / 11822)。

如果重構已經確認成功,它就只是歷史遺跡。但**我不會替你刪** —— 那是唯一還記得
重構前檔案佈局的東西。要留就留著,或搬進 `.assetdb\backups\`。

### 4. 兩份執行檔在 PATH 上

```
C:\Users\User\.cabal\bin\assetdb.exe   8/11 00:47   ← PATH 較前,實際用到的是這個
C:\cabal\bin\assetdb.exe               8/11 01:04   ← 較新,被蓋掉了
```

現在兩份行為相同(我測過 `--help` 守衛),所以不影響今天的問題。但下次
`cabal install` 之後,你可能會以為裝好了、實際跑的還是舊的。建議把
`C:\cabal\bin` 從 PATH 拿掉,或確認 `cabal install` 的目標目錄。

---

## 一次做完的順序

```bash
chcp 65001
```

```bash
cd C:\Users\User\Documents\alchbees-assets
```

```bash
assetdb doctor
```

看到 `資源 6397` 就對了。然後:

```bash
assetdb-server .assetdb\assetdb.sqlite
```

瀏覽器開 <http://localhost:8787>。

程式碼修正(A 的修正 2、B 的修正 2)做完後重編譯:

```bash
cabal install assetdb-cli assetdb-server --overwrite-policy=always
```

---

## 附:實測記錄

| 檢查 | 結果 |
|---|---|
| `getConsoleOutputCP()`(原生程序實測) | **950** |
| `[System.Text.Encoding]::Default.WebName` | **big5** |
| `assetdb doctor` stdout 導向檔案後以 UTF-8 解碼 | 完全正確,無亂碼 |
| `Win32` 套件版本 / `setConsoleOutputCP` 編譯 | 2.14.2.1 / 通過 |
| `alchbees-assets\.assetdb\assetdb.sqlite` doctor | 6397 資源 / 27 包 |
| `alchbees-dev\assetdb\.assetdb\assetdb.sqlite` doctor | 全部 0 |
| 伺服器指向正牌庫 `/api/health` | `assets:6397, packs:27, thumbs:5320, indexStale:false` |
| 伺服器指向正牌庫 `/api/search` | 回傳真實素材 |
| 伺服器指向正牌庫 `GET /` | 200 text/html |
| `assetdb-server --help`(已安裝的執行檔) | 正確印出用法,未建檔 |
