---
id: G-E003
type: enhance
title: error-boundary-convergence
description: 資料庫錯誤與檔案系統例外不再穿越子系統邊界
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [ingest/E006, G-B001]
related-adr: [ADR-001, ADR-008, ADR-009]
related-feature: [catalog/F001, catalog/F004, catalog/F006, ingest/F002, ingest/F003, ingest/F004, ingest/F005, ingest/F006, ingest/F007, ai-tagging/F003, ai-tagging/F004, delivery/F001, delivery/F002, delivery/F006]
subsystems: [catalog, ingest, ai-tagging, delivery]
---

# G-E003: 錯誤邊界收斂

## 現況分析

`system.md` 的全域錯誤處理策略第 1 條(2026-08-21 修訂)寫:

> 邊界一律回 `Either`/`Maybe`,**不讓例外穿越子系統邊界**;訊息以繁體中文寫給使用者看。
> 這條涵蓋的不只是自己定義的錯誤——**資料庫錯誤與檔案系統例外同樣不得穿越邊界**,
> 它們是最容易被遺漏的一類,因為型別簽名上看不出來。

**好消息先講**:傳統的 partial function 在 library 原始碼裡是零命中——`error`、`undefined`、
`head`、`fromJust`、`read`、`Map.!` 全部沒有,也沒有不完整的 pattern match。所有 `fail`
都在 aeson / toml 的 `Parser` monad 裡(等同回 `Left`)。**這個專案自己定義的錯誤處理得很好。**

問題全部集中在「**別人定義的失敗**」:`SQLError` 來自 `sqlite-simple`、`IOException`
來自 `base`,兩者都不是任何子系統「自己的」錯誤型別,於是四條策略沒有一條想到它們,
而型別簽名上也看不出來。

### 讀原始碼之後的關鍵發現:多數地方**已經有錯誤通道,只是沒接上**

這是本次方案能比預期小很多的原因。逐處確認:

| 位置 | 已存在的錯誤通道 | 現況 |
|---|---|---|
| `ingest/Scan.hs` 的 `discover`(`:138` `listDirectory`) | `srProblems` | 未接:無權限目錄直接拋 |
| `ingest/Scan.hs` 的 `ensureRoot`(`:437-447`) | `srAborted`(E006 加的) | 未接:`INSERT OR IGNORE` 撞 CHECK 後 `SELECT` 回空 → `ioError` |
| `ingest/Notes.hs` 的 `importNotes`(`:91` `listDirectory`、`:95` `BS.readFile`) | 無(回 `[(標題, 來源)]`) | 未接:同檔的 `linkEntities` 註解明寫「打錯不該是例外或崩潰」並回 `Either`,同一個檔案裡的 I/O 卻沒比照 |
| `ingest/ThumbRun.hs` 的寫檔(`:80-81` `BS.writeFile`) | `trFailed` | 未接:6,000+ 次迴圈裡最可能因磁碟滿失敗的一步,失敗時 `trFailed` 拿不到東西 |
| `reorg/Execute.hs`(`:190` `:209` `:242-243` `:273`) | `arErrors` | 未接:同檔的 `moveFile`、`runDeletes`、`undoBatch` **都有** `try` —— 這三處是遺漏 |
| `project/Sync.hs`(`:266` `sha256File`) | `SyncLocallyModified` 分類 | 未接:契約 §6 明寫「本地已修改……**含檔案已不在**」,但檔案在對帳途中消失時是拋例外,而 `syncProject` 的簽名是 `IO (Either SyncError SyncResult)` |
| `ingest/ClusterDb.hs` 的 `applyNames`(`:158` 寫入) | `anFailed` / `anCollisions` | 未接:撞名檢查只在**單一素材包內**建表,跨包撞名會撞 `logical_name UNIQUE` |
| `ingest/Catalogue.hs` 的 `applyCatalogue`(`:117`) | `arMissingArchive` / `arMissingLicense` | 未接:`peAi` / `peKind` 是未驗證的自由文字,直接進帶 `CHECK` 的 `UPDATE` |

**八處裡有七處只是把既有的桶子接上。** 這與「18 處全部改簽名」是完全不同量級的工作。

### 真正需要新東西的三塊

**一、兩個執行檔都沒有頂層例外處理**

`cli/main/Main.hs` 與 `server/app/Main.hs` 從頭到尾沒有任何 `catch`。任何逃逸的例外印的是
GHC 的英文 `show`,直接違反「訊息以繁體中文寫給使用者看」。而 `runMigrations`
(`store/Migrate.hs:101`)的 `DatabaseNewerThanCode` 是**真實會發生的情境**——PATH 上的
舊執行檔開新 schema 的資料庫就會撞到,使用者看到的是:

```text
assetdb.exe: Uncaught exception … MigrationError:
DatabaseNewerThanCode 4 3
HasCallStack backtrace: …
```

**二、`server` 的四個 handler 全是裸 `liftIO`**

`server/App.hs:174-215` 的 `searchH` / `facetsH` / `packsH` / `healthH` 都只有 `liftIO`,
沒有任何錯誤處理。`store/Search.hs:178,192,214` 的 `search` / `searchCount` / `facetCounts`
回的是裸值,`SQLITE_BUSY` 超過 `busy_timeout = 5000` 就拋——而 `Store.hs:36` 的註解正好在
推銷「前端在背景掃描進行中仍然可以搜尋」這個場景。例外逃到 Warp 之後變成**空 body 的
500**,前端只看到一個沒有訊息的錯誤。

`thumbH`(`:217-229`)對「sha 格式錯」與「找不到」都很正確地回繁中的 `err400` / `err404`,
唯獨讀檔失敗漏掉。

**三、`guardedTry` 有兩份,而本次要加第三個呼叫點**

`ai/Run.hs:76-80` 與 `ingest/Scan.hs:139-143`(E006 加的)逐字相同。它的正確性很微妙
——忘了重拋 `AsyncException` 就沒人會發現,而後果是使用者按幾次 Ctrl-C 都停不下來。
本次納入的 `ThumbRun.hs:70` 需要第三個。

### 附帶查證

- `cli/Pack.hs:45-50` 用**嚴格** `decodeUtf8` 讀 `data/packs.toml`(全 repo 其他地方一律
  `decodeUtf8Lenient`)。繁中 Windows 使用者把檔案存成 CP950 就拋 `UnicodeException`
  ——而該行上方的註解正是在解釋為什麼要避開會拋的解碼函式。
- `cabal.project:49,52` 讓 `assetdb-server` 與 `assetdb-project` 少了
  `-Wincomplete-uni-patterns` 與 `-Wincomplete-record-updates`,其餘七個套件有。不對稱,
  而 `project/` 正是做檔案複製與 manifest 產生的地方。

## Scope(涵蓋範圍)

與開發者確認定案。

**收斂的形狀:頂層攔截 + 針對性 Either**(不是全面改簽名)。理由見上面的關鍵發現:
八處裡七處已經有錯誤通道,把失敗接進既有的桶子就好;`search` / `facetCounts` 這種
「呼叫端除了回報錯誤也做不了別的事」的位置改成 `Either` 只會變冗長,由 handler 層攔截
更誠實。

**動**(四個子系統):

| 子系統 | 動到的位置 |
|---|---|
| catalog | `core` 新增 `guardedTry`;`store` 新增錯誤渲染模組 |
| ingest | `Scan.hs`(`discover` / `ensureRoot`)、`Notes.hs`、`ThumbRun.hs`、`ClusterDb.hs`、`Catalogue.hs`、`Reorg/Execute.hs` |
| ai-tagging | `Vision.hs` / `Classify.hs` 的 `loadVocab` / `selectJobs` / `beginRun` 納入保護範圍;`Run.hs` 的 `guardedTry` 改為 re-export core |
| delivery | 兩個 `main` 的頂層 handler、`server/App.hs` 五個 handler、`cli/Pack.hs` 的解碼、`project/Sync.hs` 的 TOCTOU |

**明確不動**:

- **不改 `search` / `searchCount` / `facetCounts` / `openStore` / `runMigrations` 的簽名**。
  它們維持拋例外,由 handler 層與頂層攔截;`MigrationError` 改為有繁中渲染。
  改簽名要動 17 個 CLI 指令、server、與全部測試,換到的只是把同一則訊息換個地方印。
- **不做故障注入測試套組**(唯讀資料庫、磁碟滿、CP950 各跑一遍全部入口)。工作量會超過
  修復本身;針對性測試已涵蓋每個改動點。
- 不碰 `archive/` 的 sidecar 錯誤處理(已完整,`arch-audit` 確認過)。
- 不改 `cabal.project` 的警告旗標不對稱(**記錄於此,建議另開**——它是建置設定,與錯誤
  邊界是不同的題目)。

**對外契約**:

- `ApplyResult` 新增一個 bucket(`ingest/design.md` 的對外契約)
- `importNotes` 的回傳形狀改變(同上)
- `ThumbReport` / `ApplyReport`(reorg)/ `ApplyNames` 的既有 bucket **語意不變**,只是
  真的會被填進去了
- `core` 新增 `guardedTry`、`store` 新增錯誤渲染模組(兩者都是 catalog 的對外契約)

**`system.md` 第 1 條已於 2026-08-22 配合改寫**(開發者裁決):原本寫「邊界**一律**回
`Either`/`Maybe`」,與本文檔選的形狀字面不符。改寫成兩層——呼叫端能做不同處置的位置必須
回 `Either`;其餘可以拋,但**執行檔與 HTTP handler 層必須攔截並翻成繁中,沒有頂層攔截
就不算滿足**。不改的話這條契約永遠是達不到的,而達不到的契約等於沒有契約,下一次
`arch-audit system` 還是會把同樣幾處再標一次。

四份 `design.md` 的對外契約(`ApplyResult` 的新 bucket、`importNotes` 的回傳形狀、
`core` 與 `store` 的新模組)**於實作時同步**——`importNotes` 的確切形狀屬實作自主權,
現在寫死等於提前具體化。

## 改善目標

**可數的結構指標**(每一項都能用 grep 或編譯器驗證,下一次 `arch-audit` 不必重新數):

| # | 指標 | 現況 | 目標 |
|---|---|---|---|
| 1 | 不重拋 `AsyncException` 的裸 `try @SomeException` | 4 處(`ThumbRun`、`Reorg/Execute` ×3) | **0** |
| 2 | `guardedTry` 的實作份數 | 2(即將 3) | **1**(在 `core`) |
| 3 | `server` 有錯誤處理的 handler | 1/5(只有 `thumbH` 的部分路徑) | **5/5** |
| 4 | 有頂層例外處理的執行檔 | 0/2 | **2/2** |
| 5 | 已有錯誤 bucket 但未接上的公開入口 | 8 | **0** |

**行為目標**:

6. **使用者永遠看得到繁體中文與可行動的指引**。特別是 `DatabaseNewerThanCode`——它現在
   印英文 `show` 加 backtrace,應該印「這個資料庫是較新版本的工具建立的,請重新安裝」。
7. **伺服器在資料庫忙碌或損毀時回帶訊息的 5xx**,不是空 body 的 500。`SQLITE_BUSY` 回
   503(可重試),其餘回 500。
8. **`exitFailure` 與 Ctrl-C 不被頂層 handler 吞掉**。這條是陷阱:Haskell 的 `ExitCode`
   本身就是例外,天真的 `catch @SomeException` 會把刻意的非零結束碼變成別的東西。

## 相依性

`depends-on: [ingest/E006, G-B001]`,兩者都已 `done`,無阻塞:

- **`ingest/E006`** 在 `Scan.hs` 建立了 `guardedTry` 與中止層,本文檔要在那個基礎上把
  `discover` 與 `ensureRoot` 接進去;E006 的「相依性」段也已寫明「本文檔先做,`G-E003`
  之後在此基礎上收斂其餘 11 處」。
- **`G-B001`** 改過 `applyNames` 的簽名(加了確認參數),而本文檔要動的是同一個函式的
  撞名處理路徑。

`related-feature` 涵蓋 14 份 feature 文檔——本次動到的每一處都屬於某個既有 feature 的
實作,對外行為契約除了新增的錯誤 bucket 外維持不變。

**可否平行開發**:與其他進行中的任務無衝突,但**內部有順序**:`T1`(core 的 `guardedTry`)
與 `T2`(store 的渲染)是其餘所有項目的前置,必須先做。之後 `T3`–`T10` 彼此獨立,可平行。

## 改善方案

### A. `core` 收進唯一一份 `guardedTry`(T1)

新模組 `AssetDB.Guard`。它是純 `base`(`try` / `fromException` / `throwIO` /
`AsyncException`),`core` 完全背得起——不像錯誤渲染需要 `sqlite-simple`。

`ai/Run.hs` 與 `ingest/Scan.hs` 改為 **re-export**,兩者現有的對外契約不變(`Run.hs` 的
匯出清單、`Scan.hs` 為測試匯出的那一份都照舊)。

### B. `store` 新增錯誤渲染(T2)

新模組 `AssetDB.Store.Errors`:

```haskell
renderSqlError :: SQLError -> Text        -- 依 SQLite 的 error code 給不同的指引
renderIoError  :: IOException -> Text
renderUnexpected :: SomeException -> Text -- 兜底:認得的先認,其餘壓成單行
isBusy :: SQLError -> Bool                -- SQLITE_BUSY / SQLITE_LOCKED,呼叫端據此決定重試或 503
```

**為什麼在 `store` 而不是 `core`**:渲染需要 `SQLError`,而它來自 `sqlite-simple`。
`core` 是**遊戲本體唯一依賴的套件**,刻意保持零重量級依賴(ADR-001);把 sqlite-simple
拉進去會讓每個用 `AssetDB.Manifest` 的遊戲專案都背上一個資料庫驅動。`store` 已經依賴它,
而四個子系統都依賴 `store`。

### C. 兩個執行檔的頂層 handler(T3)

```text
main = topLevel $ do … 原本的內容 …
```

`topLevel` 的三條規則,順序不能錯:

1. **`ExitCode` 必須重拋**。Haskell 的 `exitFailure` / `exitSuccess` 是**用例外實作的**,
   天真的 `catch @SomeException` 會把「這個指令刻意以非 0 結束」變成「頂層印了一則錯誤」
   ——結束碼與訊息雙雙錯掉,而且測試不容易發現。
2. **`AsyncException` 印「已中斷」並以非 0 結束**,不當成錯誤。使用者按 Ctrl-C 不是程式
   出錯,但也不該無聲無息。
3. 其餘經 `renderUnexpected` 印到 stderr,非 0 結束。

### D. `server` 的五個 handler(T4)

四個查詢 handler 各包一層:`SQLError` 且 `isBusy` → `err503`(附「資料庫正忙,通常是背景
掃描進行中,稍後重試」);其餘 `SQLError` → `err500` 附繁中訊息;`IOException` 同理。
`thumbH` 補上讀檔失敗的處理(現有的 400/404 邏輯不動)。

body 一律 UTF-8 位元組(與既有的錯誤回應一致)。

### E. 把既有的錯誤通道接上(T5–T7、T10)

逐處把失敗導進已經存在的桶子,**不新增通道**:

| 位置 | 導進 |
|---|---|
| `Scan.hs` 的 `discover` | `srProblems`(該目錄跳過,繼續走訪) |
| `Scan.hs` 的 `ensureRoot` | `srAborted`(寫入端失效 → 整批中止,E006 的判定) |
| `Notes.hs` 的 `importNotes` | 逐檔跳過並回報(回傳形狀要能帶失敗,見「介面變動」) |
| `ThumbRun.hs` 的寫檔 | `trFailed`,並改用 `guardedTry` |
| `Reorg/Execute.hs` 三處 | `arErrors`(與同檔既有的三處寫法一致) |
| `Sync.hs` 的 `sha256File` | 歸類為 `SyncLocallyModified` —— **契約 §6 早就寫了「含檔案已不在」**,只是實作沒接 |
| `ClusterDb.hs` 的 `applyNames` | 跨包撞名導進 `anFailed`(不是崩潰) |

### F. `applyCatalogue` 改為先驗證再寫入(T7)

`peAi` / `peKind` 是使用者在 `data/packs.toml` 手寫的自由文字,直接進帶 `CHECK` 的
`UPDATE`。改成**寫入前先驗證**:值不在封閉列舉內就進新的 `arRejected` bucket 並跳過該包,
其餘照常套用。這樣使用者得到的是「`ai` 欄位只接受 unknown / none / assisted / generated,
第 3 包寫的是 `AI-generated`」,而不是一個 SQLite 的 constraint 錯誤。

驗證用 catalog 既有的 `parseTextEnum`(ADR-008 的穩定文字表示),不自己寫一份對照表。

### G. `ai` 的三個未保護呼叫(T8)

`Vision.hs:104` / `Classify.hs:69` 的 `loadVocab` / `selectJobs` / `beginRun` 都在
`driveItems` 的 `guardedTry` **之外**。中途拋出時 `ai_runs.status` 永遠停在 `'running'`,
而 `runAiStatus` 靠它報進度。把三者納入保護,失敗時走 `abortRun`。

### H. `cli/Pack.hs` 的解碼(T9)

`decodeUtf8` → `decodeUtf8Lenient`,與全 repo 一致。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `guardedTry :: IO a -> IO (Either SomeException a)` | `ai/src/AssetDB/AI/Run.hs:76`、`ingest/src/AssetDB/Ingest/Scan.hs:139` | `ingest/E006` | 收進 `core` 的來源;兩份逐字相同 |
| `openStore :: FilePath -> IO Store` | `store/src/AssetDB/Store.hs:34` | `catalog/F004` | 頂層 handler 的攔截對象之一(簽名不變) |
| `withStore :: FilePath -> (Store -> IO a) -> IO a` | `store/src/AssetDB/Store.hs:48` | `catalog/F004` | 同上 |
| `runMigrations :: Connection -> [Migration] -> IO [Migration]` | `store/src/AssetDB/Store/Migrate.hs:101` | `catalog/F004` | `MigrationError` 加繁中渲染(簽名不變) |
| `data MigrationError = MigrationsOutOfOrder [Int] \| DatabaseNewerThanCode Int Int \| MigrationFailed Int Text Text` | `store/src/AssetDB/Store/Migrate.hs:34-40` | `catalog/F004` | 渲染的輸入。註:`MigrationFailed` 全 repo 從未被建構 |
| `search :: Connection -> SearchQuery -> IO [SearchHit]` | `store/src/AssetDB/Store/Search.hs:178` | `catalog/F006` | server handler 的攔截對象(簽名不變) |
| `searchCount :: Connection -> SearchQuery -> IO Int` | `store/src/AssetDB/Store/Search.hs:192` | `catalog/F006` | 同上 |
| `facetCounts :: Connection -> SearchQuery -> IO FacetCounts` | `store/src/AssetDB/Store/Search.hs:214` | `catalog/F006` | 同上 |
| `applyCatalogue :: Store -> Catalogue -> IO ApplyResult` | `ingest/src/AssetDB/Ingest/Catalogue.hs:117` | `ingest/F003` | 加驗證 bucket |
| `applyNames :: Store -> NamingVocab -> Int -> Bool -> IO ApplyNames` | `ingest/src/AssetDB/Ingest/ClusterDb.hs:131` | `ingest/F005`、`G-B001` | 跨包撞名導進 `anFailed` |
| `importNotes :: Store -> NoteKind -> FilePath -> IO [(Text, Text)]` | `ingest/src/AssetDB/Ingest/Notes.hs:85` | `ingest/F007` | 逐檔失敗要能帶出來 |
| `generateThumbs :: Store -> ArchiveTools -> ThumbOptions -> IO ThumbReport` | `ingest/src/AssetDB/Ingest/ThumbRun.hs:42` | `ingest/F006` | 寫檔失敗導進 `trFailed` |
| `data ThumbReport = ThumbReport { trMade :: Int, trSkipped :: Int, trFailed :: [(Text, Text)] }` | `ingest/src/AssetDB/Ingest/ThumbRun.hs:31-34` | `ingest/F006` | 既有的錯誤通道 |
| `sha256File :: FilePath -> IO Sha256` | `ingest/src/AssetDB/Ingest/Hash.hs:43` | `ingest/F002` | TOCTOU 的三個呼叫點 |
| `scanRoot :: Store -> ArchiveTools -> ScanOptions -> IO ScanReport` | `ingest/src/AssetDB/Ingest/Scan.hs:102` | `ingest/F002`、`ingest/E006` | `discover` 與 `ensureRoot` 的失敗要進 `srProblems` / `srAborted` |
| `syncProject :: Store -> ArchiveTools -> SyncOptions -> IO (Either SyncError SyncResult)` | `project/src/AssetDB/Project/Sync.hs` | `delivery/F006` | 簽名已是 `Either`,但 `sha256File` 讓它照樣能拋 |
| `applyPlan :: Store -> Snapshot -> ApplyOptions -> Plan -> IO ApplyReport` | `reorg/src/AssetDB/Reorg/Execute.hs:84` | `ingest/F004` | 三個檔案系統動作要導進它的 `arErrors` |
| `arErrors :: [Text]`(`ApplyReport` 欄位) | `reorg/src/AssetDB/Reorg/Execute.hs:75` | `ingest/F004` | 既有的錯誤通道;同檔 `:249` 已有正確用法可比照 |
| `beginRun :: Connection -> Text -> LlmConfig -> Text -> Text -> Int -> IO RunId` | `ai/src/AssetDB/AI/Run.hs:36` | `ai-tagging/F003`、`ai-tagging/F004` | 前置步驟納入保護範圍的對象之一 |
| `abortRun :: Connection -> RunId -> Text -> Int -> Int -> IO ()` | `ai/src/AssetDB/AI/Run.hs:59` | `ai-tagging/F003`、`ai-tagging/F004` | 前置步驟失敗時把 `ai_runs.status` 從 `'running'` 收成 `'aborted'` |
| `parseTextEnum :: forall a. TextEnum a => Text -> Either Text a` | `core/src/AssetDB/Types.hs:54` | `catalog/F001`、`ADR-008` | `applyCatalogue` 的欄位驗證 |
| `decodeUtf8Lenient :: ByteString -> Text` | `text` 的 `Data.Text.Encoding` | `-` | `cli/Pack.hs` 的解碼替換 |
| `err500` / `err503` / `errBody` | `servant-server` 的 `Servant` | `-` | server handler 的錯誤回應 |
| `SQLError`(含其 `Exception` 實例) | `sqlite-simple` 的 `Database.SQLite.Simple` | `-` | 渲染與 `isBusy` 判定的輸入 |
| `ExitCode` / `AsyncException` / `try` / `catch` / `fromException` / `throwIO` | `base` 的 `Control.Exception`、`System.Exit` | `-` | 頂層 handler 的三條規則 |

## 介面變動

**新增**:

```haskell
-- core:AssetDB.Guard(新模組)
guardedTry :: IO a -> IO (Either SomeException a)

-- store:AssetDB.Store.Errors(新模組)
renderSqlError   :: SQLError -> Text
renderIoError    :: IOException -> Text
renderUnexpected :: SomeException -> Text
isBusy           :: SQLError -> Bool
```

**修改**(逐條標明是否動到 Level 2 契約):

| 介面 | 變動 | Level 2 契約 |
|---|---|---|
| `ApplyResult` | 新增 `arRejected :: [(Text, Text)]` —— (壓縮檔名, 原因) | **是**,`ingest/design.md` 對外契約 |
| `importNotes` | 回傳改為能帶逐檔失敗(形狀由實作者決定,但必須讓呼叫端分辨得出成功與失敗) | **是**,`ingest/design.md` 對外契約 |
| `MigrationError` | 新增繁中渲染(型別本身不變) | 否(新增函式,見上) |
| `ai/Run.hs` 的 `guardedTry` | 改為 re-export `core` | 否(匯出清單不變) |
| `ingest/Scan.hs` 的 `guardedTry` | 同上 | 否 |

**受影響的呼叫端**:`ApplyResult` → `cli/Pack.hs` 的輸出;`importNotes` → `cli/Notes.hs`
的輸出。兩者都只是多印一段失敗清單。

**不變**:`search` / `searchCount` / `facetCounts` / `openStore` / `withStore` /
`runMigrations` / `initSchema` / `generateThumbs` / `applyPlan` / `scanRoot` / `syncProject`
/ `applyNames` 的簽名一律不動——它們的錯誤通道要嘛已經存在,要嘛由 handler 層攔截。

## TodoList

- [x] T1: `core` 新增 `AssetDB.Guard` 的 `guardedTry`;`ai/Run.hs` 與 `ingest/Scan.hs` 改為 re-export  `dep: -`
- [x] T2: `store` 新增 `AssetDB.Store.Errors`(四個函式),含 `MigrationError` 的繁中渲染  `dep: -`
- [x] T3: 兩個 `main` 加頂層 handler(重拋 `ExitCode`、Ctrl-C 印「已中斷」、其餘走渲染)  `dep: T2`
- [x] T4: `server` 五個 handler 的錯誤處理(`isBusy` → 503,其餘 → 500,body 帶繁中)  `dep: T2`
- [x] T5: `ingest/Scan.hs` 的 `discover` → `srProblems`、`ensureRoot` → `srAborted`  `dep: T1`
- [x] T6: `ingest/ThumbRun.hs` 改用 `guardedTry` 並把寫檔失敗導進 `trFailed`  `dep: T1`
- [x] T7: `reorg/Execute.hs` 三處檔案系統動作導進 `arErrors`  `dep: T1`
- [x] T8: `ingest/Notes.hs` 的逐檔出口;`applyCatalogue` 先驗證再寫入(`arRejected`);`applyNames` 跨包撞名導進 `anFailed`  `dep: T1`
- [x] T9: `ai/Vision.hs` 與 `Classify.hs` 的 `loadVocab` / `selectJobs` / `beginRun` 納入保護,失敗走 `abortRun`  `dep: T1`
- [x] T10: `cli/Pack.hs` 改用 `decodeUtf8Lenient`;`project/Sync.hs` 的 `sha256File` TOCTOU 歸類為 `SyncLocallyModified`  `dep: T1`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `core` 的 `GuardSpec`:`AsyncException` 穿透、一般例外接得住;`ai` 與 `ingest` 既有的 `guardedTry` 測試維持綠燈(re-export 不改行為) | 指標 2:實作份數 2 → 1 |
| T2 | `store` 的 `ErrorsSpec`:`DatabaseNewerThanCode` 的渲染含「較新版本」與可行動指引且**不含英文 `show` 的形狀**;`isBusy` 對 `SQLITE_BUSY` 為真、對 constraint 錯誤為假 | 目標 6 |
| T3 | `cli` 的 `EndToEndSpec`:對一個**版本比程式新**的資料庫執行查詢指令,斷言 stderr 是繁中、結束碼非 0、且輸出不含 `HasCallStack`;另一條斷言**刻意的 `exitFailure` 仍以原結束碼結束**(頂層 handler 沒吞掉 `ExitCode`) | 目標 8 —— 這是最容易寫錯的一條 |
| T4 | `server` 的 `AppSpec`:資料庫被關閉後打 `/api/search`,斷言回應是 5xx **且 body 非空、含繁中**;`PRAGMA query_only` 下的忙碌情境回 503 | 目標 7;指標 3:1/5 → 5/5 |
| T5 | `ScanSpec`:無權限或消失的子目錄進 `srProblems` 且走訪繼續;`roots.kind` 給非法值時 `srAborted` 為 `Just` 而不是拋 `ioError` | 指標 5 的兩處 |
| T6 | `ThumbSpec` / `ThumbRunSpec`:縮圖寫檔失敗(唯讀快取目錄)進 `trFailed` 且批次繼續;`AsyncException` 穿透而不是被記成一則失敗 | 指標 1 的一處 + 指標 5 |
| T7 | `reorg` 的 `ExecuteSpec`:三個動作各自失敗時進 `arErrors`,且**不執行任何刪除**(既有的安全性質不受影響) | 指標 1 的三處 |
| T8 | `NotesSpec`:讀不到的檔案跳過並回報,其餘照樣匯入;`CatalogueSpec`:`ai = "AI-generated"` 進 `arRejected` 且其餘素材包照常套用;`ClusterDbSpec`:跨包撞名進 `anFailed` 而不是崩潰 | 三處各一組 |
| T9 | `ai` 的 `RunSpec`:`beginRun` 之後的前置步驟失敗時 `ai_runs.status` 為 `'aborted'` 而不是永遠停在 `'running'` | 目標 6 的一個具體後果 |
| T10 | `cli` 的 `PackSpec`:CP950 編碼的 `packs.toml` 不拋例外(壞字元以替代字元呈現);`project` 的 `SyncSpec`:對帳途中檔案消失歸類為 `SyncLocallyModified` 而不是拋例外 | 兩處各一條 |
| 全部 | **結構指標的回歸**:一條測試或建置期檢查,斷言 library 原始碼中不重拋 `AsyncException` 的裸 `try @SomeException` 為 0 | 指標 1,讓下一次不必重新數 |

## 實作備註



### 結構指標的量化結果

| # | 指標 | 改善前 | 改善後 | 怎麼驗證 |
|---|---|---|---|---|
| 1 | 不重拋 `AsyncException` 的裸 `try` | 4 處(現況分析清點)+ 實際再找到 4 處(`core/Console.hs` ×2、`archive/Zip.hs` ×2、`archive/Sidecar.hs`、`ai/Llm.hs`)= 8 | **0** | `core` 的 `GuardSpec`「library 原始碼裡一個都不剩」——掃全 repo 九個套件的 `src/`,寫成測試而不是一次性清點 |
| 2 | `guardedTry` 的實作份數 | 2 | **1**(`core:AssetDB.Guard`) | `ai/Run.hs` 與 `ingest/Scan.hs` 改為 re-export,匯出清單不變 |
| 3 | `server` 有錯誤處理的 handler | 1/5 | **5/5** | `AppSpec`「資料庫壞掉時 `/api/search` 回 5xx 且 body 是繁中」「`/api/facets` 與 `/api/health` 也一樣」 |
| 4 | 有頂層例外處理的執行檔 | 0/2 | **2/2** | `cli/main/Main.hs`、`server/app/Main.hs` 都是 `setupConsole >> withTopLevel renderUnexpected run` |
| 5 | 已有錯誤 bucket 但未接上的公開入口 | 8 | **0** | T5–T10 逐處接上,每處各有測試 |

行為目標:

- **目標 6(繁中且可行動)**:`DatabaseNewerThanCode` 從 `DatabaseNewerThanCode 4 3` +
  backtrace 變成三行繁中(現況版本、程式認得的版本、重新安裝指令)。`store/ErrorsSpec`
  斷言訊息含「較新版本」與 `cabal install`,且**不含**建構子名稱與 `CallStack`;
  `cli/EndToEndSpec` 對一個真的被灌成 v999 的資料庫跑 `search`,斷言 stderr 含 `v999`
  與 `cabal install`、不含 `HasCallStack`。
- **目標 7(5xx 帶訊息)**:忙碌 503、其餘 500,body 一律非空的 UTF-8 繁中。
  `statusFor` 的映射與端點的實際行為分兩層測。
- **目標 8(不吞 `ExitCode` 與 Ctrl-C)**:`withTopLevel` 先判 `ExitCode` 再判
  `AsyncException`,順序寫進 haddock。`EndToEndSpec` 斷言刻意的 `exitFailure` 之後
  stderr 仍是原本的提示,**不含** `ExitFailure` 也不含「未預期」。
  Ctrl-C 的穿透另有三條:`GuardSpec`(型別層 + 迴圈真的停下來)、`ScanSpec`(既有)、
  `ThumbRunSpec`(整批中斷,第二筆之後一個都沒被碰)。

### 測試

`cabal test all`:**667 examples, 0 failures**(實作前 624),零警告。新增 43 條,
分佈為 core +6、store +9、ingest +12、reorg +3、ai +4、server +4、cli +3、project +1、
以及既有測試因回傳形狀改變而調整的 1 條(`NotesSpec`)。

### 與設計的偏差

1. **指標 1 的實際數量是 8 而不是 4。** 現況分析只清點了「批次迴圈裡的」裸 `try`。
   把檢查寫成測試之後,`core/Console.hs`、`archive/Zip.hs`、`archive/Sidecar.hs`、
   `ai/Llm.hs` 也被抓出來。前三處確實該用 `guardedTry`(7-Zip 子程序與整包解壓都是
   長時間動作);`ai/Llm.hs` 的 `tryHttp` 只接 `HttpException`,本來就不吞 Ctrl-C,
   改成明寫 `try @HttpException` —— 這同時成為一條**寫法約定**:要用 `try` 就得把
   型別寫出來,否則改用 `guardedTry`。`GuardSpec` 的檢查依此判定。
2. **T10 的 CP950 測試放在 `cli/EndToEndSpec` 而不是新開 `PackSpec`。** 測試對照表寫
   「`cli` 的 `PackSpec`」,但 `runPackApply` 會 `exitFailure`,在同行程的 hspec 裡
   會殺掉整個測試套件。`EndToEndSpec` 已經有跑子行程的基礎設施,而且測到的是**真的
   被安裝的那條路徑**,比抽出一個純函數再測更接近使用者會遇到的情況。
3. **`statusFor` 從 `server` 匯出。** 原本是私有的。匯出的理由是「忙碌 → 503」這條
   映射本身就是契約(前端據此決定要不要重試),而透過端點間接測它需要製造真的
   `SQLITE_BUSY` —— 在 WAL 模式下讀取者不會被寫入者擋住,做不出穩定的觸發條件。
4. **`ingest/Notes.hs` 的 `importNotes` 回 `([(Text, Text)], [Text])`。** 文檔把形狀
   留給實作者決定,只要求呼叫端分辨得出成功與失敗。選 tuple 而不是 `[Either]` 是因為
   呼叫端(`cli/Notes.hs`)本來就分兩段印:成功清單、失敗清單。
5. **`GuardSpec` 的結構檢查排除註解行與 import 行。** 它們提到 `try` 不代表呼叫了它。
   `AssetDB.Guard` 自己的檔案整份排除 —— 全系統唯一合法的裸 `try` 在那裡。

### 順手清掉的既有問題(同源、各一行)

- `ingest/ClusterDbSpec.hs:55` 的 `head (anCollisions r)`(`-Wx-partial`,G-B001 時記錄過)。
- `ai/LlmSpec.hs:71,75` 的 `let Object o = …`(`-Wincomplete-uni-patterns`)。

兩者都是測試碼裡的 partial function,與本次「不讓失敗以例外的形式離開」同源。
