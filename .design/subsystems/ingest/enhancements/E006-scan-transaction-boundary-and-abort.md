---
id: E006
type: enhance
title: scan-transaction-boundary-and-abort
description: 掃描的長時間工作移出寫交易,並補上整批中止層
status: open
created: 2026-08-21
updated: 2026-08-21
depends-on: [B001]
related-adr: [ADR-009]
related-feature: [F002]
---

# E006: 掃描的交易邊界與整批中止層

## 現況分析

以下全部從 `ingest/src/AssetDB/Ingest/Scan.hs` 讀出,行號為 2026-08-21 的現況。

### 1. 散檔掃描:單一交易包住整個根目錄的檔案 IO

`scanLoose:375-419`:

```haskell
total <- withTransaction conn (foldM (one conn now) 0 paths)
```

交易內每一筆做的事(`one:382-419`):

| 步驟 | 位置 | 性質 |
|---|---|---|
| `BS.readFile p`(圖片/音效整檔讀) | `:394` | 檔案 IO |
| `hProbe h content`(PNG 完整解碼數色) | `:395` | CPU 重運算 |
| `sha256File p`(串流雜湊) | `:397` | 檔案 IO |
| `getFileSize p` | `:398` | 檔案 IO |
| `upsertBlob` + `DELETE` + `INSERT` | `:400-418` | SQL |

**寫鎖會被持有到整個根目錄掃完為止。** `library/studio/` 與 `library/reference/`
都是散檔路徑,數千個檔案 = 數分鐘到數小時。`busy_timeout` 是 5000ms。

### 2. 壓縮檔寫入:雜湊與解碼在交易內

`writeArchive:281-311` 的 `withTransaction conn $ ... foldM (insertEntry ...)`,
而 `insertEntry:332-337`:

```haskell
let sha = sha256Bytes content
    meta = probeContent entryPath content
```

一個 1,693 筆的素材包 = 1,693 次 SHA-256 加上 1,693 次 PNG 完整解碼,全部在同一個
寫交易內(PNG 佔素材庫 91%)。

**正面確認**:`fetchContents:251-269` 的整包解壓與 7-Zip 子程序在交易**之外**完成
(`scanArchive:200`),那一段是對的。問題只在雜湊與探測。

### 3. 沒有「整批中止」這一層

`scanArchive:207-210`:

```haskell
r <- try (writeArchive ...)
case r of
  Left (e :: SomeException) -> problem (... <> ":寫入失敗 " <> compact e)
```

磁碟寫滿或資料庫損毀時,**剩下的每一個壓縮檔都會累積一則同樣的「寫入失敗」**,
掃描跑完並回報數千則問題,而不是停下來。`ScanReport` 有 `srArchivesFailed`(B001 加的)
但沒有 `srAborted`;`ScanEvent` 同樣沒有 `EvAborted`。兩者都已寫進 Level 2 契約,
實作尚未跟上。

### 4. 裸 `try` 吞掉 `AsyncException`

同一段 `:207` 的 `try @SomeException` 會接住 `AsyncException`,於是**掃描途中按 Ctrl-C
會被記成一則「寫入失敗」然後繼續掃下一個壓縮檔**。

這件事在本專案裡已經有正確版本:`ai/src/AssetDB/AI/Run.hs:76-80` 的 `guardedTry`
重新拋出 `AsyncException`,而它的註解本身就寫著判準:

> `ThumbRun.hs` 用裸的 try 是安全的,因為那裡每筆只花毫秒,中斷訊號幾乎不可能落在
> 工作內部。

`writeArchive` 包住的是數千次 insert 加上數千次 PNG 解碼,遠不只毫秒——**判準已經在
專案裡了,只是沒有套到掃描上**。

### 5. 散檔完全沒有錯誤處理

`scanLoose` 的 `one:382` 從頭到尾沒有任何 `try`。一個權限不足、或掃到一半被移走的
檔案,`BS.readFile` / `sha256File` 的 `IOException` 會直接飛出 `scanRoot`,**整次掃描
崩掉且沒有任何報告**。壓縮檔那一側至少有 `try`(雖然吞了 Ctrl-C),散檔這一側連那個
都沒有——標準不一致,是遺漏不是設計。

### 與架構文件的落差

`ingest/design.md` 的橫向約束第 3、4 條與管線 A 的交易邊界、`ADR-009` 的寫鎖界線,
都在 2026-08-21 寫定,**現況全部不符**。該文件的「開發階段」節已列出這三條缺口並
標為本文檔的路線。

## Scope(涵蓋範圍)

與開發者確認定案。

**動**:

- `ingest/src/AssetDB/Ingest/Scan.hs` —— 交易邊界、整批中止層、`guardedTry`、
  散檔逐檔出口
- `ingest/src/AssetDB/Ingest/Report.hs` —— 渲染新增的事件與報告欄位

**明確不動**:

- **`ThumbRun.hs:70` 的裸 `try`**。它包住 `readEntry`,而 `readEntry` 對 `.7z` 會叫起
  7-Zip 子程序——`guardedTry` 註解裡「ThumbRun 每筆只花毫秒」的假設在 solid 壓縮檔上
  並不成立。但改它要連帶設計縮圖批次自己的中止語意(磁碟滿、快取寫不進去),是另一個
  題目。**已排除,建議另開 `/enhance-design`。**
- **`SQLError` / `IOException` 穿越邊界的全域收斂**(`applyCatalogue`、`importNotes`、
  `runMigrations`、`openStore` 等 12 處)。本次只處理 `Scan.hs` 內的部分,其餘留給全域
  `G-E003`。
- `discover` 的走訪 IO(`listDirectory` 對無權限目錄拋例外)—— 同上,屬 `G-E003`。
- `Catalogue.hs:121`、`ClusterDb.hs:166`、`Notes.hs:224` 的交易:已查證交易內**只有
  SQL**,不違反 ADR-009,不動。

**對外契約**:`ScanEvent` 與 `ScanReport` 的新成員(`EvAborted`、`srAborted`)**已經在
Level 2 契約裡**,本次是實作跟上,不需要再改 `design.md`。

**一項契約措辭需要收斂**(見「介面變動」末段):`ingest/design.md` 橫向約束第 3 條把
「外部工具消失」列為整批中止的條件,與 `archive-access` 契約的「沒有 7-Zip 不是錯誤,
是能力縮減」以及 B001 的「壓縮檔讀不開 = 單筆失敗」互相牴觸。開發者裁決為
**只有寫入端失效算中止**,該句需要跟著改。

## 改善目標

1. **結構(主驗收)**:計算與寫入分成兩個階段,**寫入階段的輸入型別裡不含任何需要讀檔
   或重運算的東西**——沒有 `FilePath`、沒有內容 `ByteString`。型別本身保證交易內不可能
   有 IO,而不是靠人記得。這是 ADR-009「可稽核」的具體形式。
2. **時間(數量級回歸網)**:一批準備好的散檔資料(200 筆)寫入的單次交易持有時間
   **< 100ms**。上限刻意寬鬆——它要抓的是「有人把 IO 搬回交易裡」這種數量級回歸,
   不是微調效能。
3. **中止語意**:寫入端失效時 `srAborted = Just 原因`,剩餘的壓縮檔與整個散檔階段都不
   再處理,已完成的部分留在資料庫;報告明確標示為中止而非跑完。
4. **Ctrl-C 可中斷**:掃描途中按一次 Ctrl-C 就停,不會被記成一則問題然後繼續。
5. **散檔逐檔容錯**:單一檔案讀不到不再讓整次掃描崩掉,記進 `srProblems` 後繼續。
6. **冪等不變**:中斷後重跑,最終索引與一次跑完相同,且不產生重複資源。

## 相依性

`depends-on: [B001]`。本次擴充的 `ScanEvent` / `ScanReport` 正是 B001 剛加過
`EvArchiveFailed` / `srArchivesFailed` 的那兩個型別,而 `scanArchive` 的失敗出口
(`archiveFailed`)也是 B001 建立的——中止層要接在它旁邊。B001 已 `done`,無阻塞。

`related-feature: [F002]`(content-addressed-scan):本次改的是該 feature 的實作結構,
其對外行為契約除了新增的中止語意外維持不變。

**可否平行開發**:與全域 `G-E003` 有**輕微重疊**——兩者都會碰 `Scan.hs` 的錯誤處理。
本文檔先做,`G-E003` 之後在此基礎上收斂其餘 11 處;反過來做會讓 `G-E003` 動到一個
即將被重構的迴圈。與 ingest 其他任務無相依,可與 delivery / catalog 的工作平行。

## 改善方案

### A. 兩階段化:準備(交易外)→ 寫入(交易內)

核心是把每一筆的「算」與「寫」拆開,中間以一個**只含已算好的值**的中介型別相連。
該型別是 `Scan.hs` 的內部細節,不進 Level 2 契約。

**壓縮檔路徑**:

```text
fetchContents(已在交易外)
  → 【交易外】逐筆算 sha256Bytes + probeContent,產生準備好的清單
  → 【交易內】只有 DELETE / INSERT archives / INSERT assets / INSERT OR IGNORE blobs
```

副作用是好的:準備階段算完 sha 與 meta 之後,**內容位元組就可以丟棄**,不必像現在這樣
整包 content 留在記憶體裡直到交易結束。

提交邊界維持「一個壓縮檔」(`design.md` 管線 A 已定):一包要麼完整進去要麼沒進去。

**散檔路徑**:

```text
把 paths 切成批(建議 200 筆)
  對每一批:
    【交易外】逐檔算 sha / size / meta(圖片音效整檔讀,其餘串流)
    【交易內】只有 DELETE / INSERT
```

批次大小 200 是建議值:每批交易內約 400 次 `execute`(毫秒級),而準備階段同時在記憶體
裡的只有一批的中繼資料。實作可依量測調整,但**不得回到「一個交易包住全部」**。

### B. 整批中止層

新增(契約已定義):

- `ScanEvent` 的 `EvAborted Text`
- `ScanReport` 的 `srAborted :: Maybe Text`

**判定:只有寫入端失效算中止。**

| 情況 | 判定 | 理由 |
|---|---|---|
| 交易寫入拋 `SQLError`(磁碟滿、db 損毀、寫鎖搶不到) | **中止** | 不是「這一筆」的問題,繼續跑只會累積數千則同樣的錯誤 |
| 壓縮檔讀不開(損毀、密碼) | 單筆失敗 | B001 已定 |
| sidecar 缺席 | 單筆失敗 | `archive-access` 契約:沒有 7-Zip 是**能力縮減**不是錯誤 |
| 單一散檔讀不到(權限、檔案消失) | 單筆失敗 | 掃描期間檔案被動過是常態 |
| `AsyncException`(Ctrl-C) | **重新拋出** | 既不是中止也不是失敗,是使用者要求停止 |

中止之後:`scanRoot` 不再處理剩餘的壓縮檔,**也不進入散檔階段**;已完成的部分留在
資料庫(重跑冪等收斂);`srAborted` 帶得出原因;報告明確標示為中止。

`scanRoot:111-120` 的兩個 `foldM` 需要能提前結束——已中止就跳過剩餘項目。

### C. 不吞掉 Ctrl-C

`Scan.hs` 需要自己的 `guardedTry`(**不能**從 `ai/Run.hs` 匯入:ai-tagging 與 ingest
互不相依,而且方向上 ingest 也不該依賴 ai)。行為與 `Run.hs:76-80` 相同:接住例外,
但 `AsyncException` 重新拋出。

套用位置:壓縮檔的批次寫入、散檔的每批寫入、散檔的逐檔準備。

### D. 散檔逐檔出口

準備階段的每一檔包 `guardedTry`:失敗時記進 `srProblems`(帶檔名與原因)並跳過該檔,
不中止、不讓例外逃出 `scanRoot`。這條與 B001 的「每一種失敗都必須有出口」同源。

### E. 報告

`Report.hs` 需要:

- `renderEvent` 加 `EvAborted` 的呈現
- `renderReport` 在 `srAborted` 為 `Just` 時,把標題從「掃描完成」改成**明確的中止字樣**
  並附原因,同時說明「已完成的部分已經寫入,重跑會從缺的地方補齊」——使用者看到中止時
  最需要知道的是「我現在該做什麼」

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `sha256Bytes :: ByteString -> Sha256` | `ingest/src/AssetDB/Ingest/Hash.hs:36` | `F002` | 交易外預算壓縮檔項目與媒體散檔的內容雜湊 |
| `sha256File :: FilePath -> IO Sha256` | `ingest/src/AssetDB/Ingest/Hash.hs:43` | `F002` | 交易外預算非媒體散檔的串流雜湊 |
| `unSha256 :: Sha256 -> Text` | `ingest/src/AssetDB/Ingest/Hash.hs:33` | `F002` | 寫入時轉成資料庫形式 |
| `probeContent :: Text -> ByteString -> Maybe Value` | `ingest/src/AssetDB/Ingest/Handler.hs:77` | `F002` | 交易外抽取 kind 專屬中繼資料 |
| `handlerFor :: Text -> Maybe Handler` | `ingest/src/AssetDB/Ingest/Handler.hs:67` | `F002` | 決定散檔走整檔讀或串流雜湊 |
| `hProbe :: ByteString -> Maybe Value`(`Handler` 欄位) | `ingest/src/AssetDB/Ingest/Handler.hs:46` | `F002` | 圖片/音效的探測 |
| `kindForPath :: Text -> AssetKind` | `ingest/src/AssetDB/Ingest/Handler.hs:74` | `F002` | kind 判定 |
| `withTransaction :: Connection -> IO a -> IO a` | `sqlite-simple` 的 `Database.SQLite.Simple` | `-` | 每批寫入的交易邊界 |
| `SQLError`(含其 `Exception` 實例) | `sqlite-simple` 的 `Database.SQLite.Simple` | `-` | 中止判定:寫入端失效。專案已在 `store/test/AssetDB/Store/SchemaSpec.hs:284` 用過此型別 |
| `try` / `fromException` / `throwIO` / `AsyncException` | `base` 的 `Control.Exception` | `-` | `guardedTry`:接住例外但重拋 Ctrl-C |

`guardedTry` 本身**不列為串接介面**:`ai/Run.hs` 的那一份在 ai-tagging 內,ingest 依
依賴方向不可引用,本次是各自持有(見改善方案 C)。

## 介面變動

**新增**(兩者都已在 `ingest/design.md` 的對外契約中,本次是實作跟上):

```haskell
data ScanEvent = … | EvAborted Text          -- 整批中止與原因
data ScanReport = ScanReport { … , srAborted :: Maybe Text }
```

`srAborted` 為 `Just` 時,**所有計數都只是中止前的進度**,呼叫端不得當成完整結果——
這一條已寫在 `design.md` 的模組間介面表。

**受影響的呼叫端**:

| 呼叫端 | 影響 |
|---|---|
| `ingest/src/AssetDB/Ingest/Report.hs` | `renderEvent` 需處理新建構子(`-Wincomplete-patterns` 會擋);`renderReport` 需呈現中止 |
| `cli/app/AssetDB/Cli/Scan.hs` | 透過 `renderReport` / `renderEvent` 取用,**不需修改**;但若掃描中止,結束碼應為非 0(實作時確認現況) |
| `ingest/test/AssetDB/Ingest/ScanSpec.hs` | `emptyReport` 的欄位數變動;既有斷言不受影響 |

**內部型別**(準備階段的中介型別)屬 Level 3 實作自主權,不進契約。

**建議的契約措辭修訂**(`ingest/design.md` 橫向約束第 3 條):目前寫

> **整批中止**(環境失效——磁碟寫滿、資料庫損毀、外部工具消失)

「外部工具消失」與 `archive-access` 的「沒有 7-Zip 不是錯誤,是能力縮減」牴觸,也與
B001 定的「壓縮檔讀不開 = 單筆失敗」不一致。建議改為**只涵蓋寫入端失效**,並明講讀取端
的失敗一律是單筆失敗。此項需開發者同意後由 `/subsys-design` 更新模式處理。

## TodoList

- [ ] T1: 抽出 `guardedTry`(接住例外但重拋 `AsyncException`),並取代 `scanArchive` 現有的裸 `try`  `dep: -`
- [ ] T2: `ScanEvent` 加 `EvAborted`、`ScanReport` 加 `srAborted`;`emptyReport` 同步  `dep: -`
- [ ] T3: 壓縮檔路徑兩階段化:交易外預算 sha / meta,交易內只剩寫入  `dep: T2`
- [ ] T4: 散檔路徑兩階段化 + 分批提交,並給每一檔一個失敗出口  `dep: T2`
- [ ] T5: 中止判定與短路:寫入端 `SQLError` → `srAborted`,剩餘壓縮檔與散檔階段都不再處理  `dep: T3, T4`
- [ ] T6: `Report.hs` 呈現 `EvAborted` 與中止報告(含「重跑會補齊」的指引)  `dep: T2, T5`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ScanSpec`「Ctrl-C 不被吞掉」:對寫入路徑注入一個 `AsyncException`,斷言它**穿透** `scanRoot` 而不是被記成 `srProblems` 的一則 | 目前按 Ctrl-C 會被記成「寫入失敗」然後繼續掃 |
| T2 | `ScanSpec`「報告的預設值」:`emptyReport` 的 `srAborted` 是 `Nothing`;正常掃完的報告 `srAborted` 仍是 `Nothing` | 確保新欄位不誤報中止 |
| T3 | `ScanSpec`「壓縮檔寫入的交易內沒有 IO」:對準備好的項目清單呼叫寫入階段,其輸入型別不含 `FilePath` 或內容 `ByteString`(型別層級,編譯即驗證);另斷言掃描結果與改動前逐欄相同(回歸) | 結構驗收 + 行為不變 |
| T4 | `ScanSpec`「散檔分批與逐檔容錯」:(a) 200 筆以上的散檔 fixture 掃完後每筆都有正確的 sha 與 size(回歸);(b) 其中一個檔案在準備階段失敗時,其餘檔案照樣入庫且失敗記進 `srProblems`,例外不逃出 `scanRoot` | 分批不改變結果;單檔失敗不再讓整次掃描崩掉 |
| T4 | `ScanSpec`「單一交易的持有時間」:對 200 筆準備好的散檔資料呼叫批次寫入,量測單次交易 < 100ms | 數量級回歸網(改善目標 2) |
| T5 | `ScanSpec`「寫入端失效即中止」:令寫入拋 `SQLError`,斷言 `srAborted` 為 `Just`、剩餘壓縮檔未被處理、散檔階段未執行、已完成部分仍在資料庫 | 中止語意 |
| T5 | `ScanSpec`「讀取端失敗不中止」:一個讀不開的壓縮檔加一個正常的壓縮檔,斷言正常那個仍被索引、`srAborted` 為 `Nothing`、`srArchivesFailed` 為 1 | 判定邊界:讀取端一律單筆失敗(與 B001 一致) |
| T5 | `ScanSpec`「中斷後重跑收斂」:中止一次再完整重跑,最終索引與一次跑完相同且無重複資源 | 改善目標 6(冪等) |
| T6 | `ScanSpec`(或 `ReportSpec`)「中止的報告」:`srAborted` 為 `Just` 時輸出含中止字樣與原因,且不出現「掃描完成」;`renderEvent` 對 `EvAborted` 產生非空輸出 | 使用者看到中止時要知道該做什麼 |

## 實作備註

(實作時填寫)
