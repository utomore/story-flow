---
id: B001
type: bugfix
title: archive-extract-failure-swallowed
description: 整包取內容失敗被吞成成功,項目以空雜湊入庫且回報索引完成
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: []
related-feature: [F002]
---

# B001: 整包取內容失敗被吞成成功

## 症狀

掃描一個**列得出內容、但取不出內容**的壓縮檔(損毀、有密碼、暫存空間不足、7-Zip 中途
死掉)時:

| | 預期 | 實際 |
|---|---|---|
| 該壓縮檔的項目 | 不入庫,或入庫但明確標示不可信 | **每一筆都以 `sha256` 為 NULL 入庫** |
| 事件 | 失敗事件並帶出原因 | `EvArchiveDone`,與成功完全相同 |
| 報告 | 計入失敗 | `srArchives + 1`,計入**成功**的壓縮檔數 |
| 錯誤原因 | 出現在報告裡 | **完全消失**,一個字都沒有 |

使用者看到的是「掃描完成,27 個壓縮檔」。唯一的線索是 `srEntriesUnread` 的數字偏大,
而那個欄位的既有語意是「個別項目讀不到」,不是「整包都沒讀到」。

**影響範圍**:內容定址失效。沒有 SHA-256 就沒有去重、沒有縮圖、專案取不出素材,而且
重構的刪除閘門會把這些項目視為「無法證明已被壓縮檔覆蓋」——後果一路擴散,但起點被
靜靜吞掉了。

**這一條屬於「把失敗吞成成功」**,比把失敗誤判成另一種失敗更嚴重:後續每一個判斷都
建立在一個假的成功上,而且沒有任何訊號會讓人回頭懷疑索引本身。

## 重現步驟

需要一個 `listEntries` 成功、`extractAllTo` 失敗的壓縮檔。最小重現(需要 7-Zip):

1. 用 `Store`(不壓縮)建一個含數個項目的 ZIP,**改名為 `.7z`** —— 副檔名決定
   `prefersBulkExtraction`,7-Zip 會依內容自動辨識所以列得出來
2. 破壞檔案中段的位元組(項目資料區,不動結尾的 central directory)
3. 對它跑 `scanRoot`

`7z l` 讀結尾的 central directory,列出項目成功;`7z x` 校驗 CRC 失敗,非零結束碼 →
`extractAllTo` 回 `Left` → 進入缺陷路徑。

沒有 7-Zip 的環境改用一個內容是垃圾的 `.rar`:`listEntries` 就會失敗,走的是另一條
路徑但同樣違反契約(整包讀不開卻只留下一則泛用 problem,不計入失敗數)。

## 根因分析

`ingest/src/AssetDB/Ingest/Scan.hs` 的 `fetchContents`:

```haskell
extractAllTo tools path tmp >>= \case
  Left _ -> pure [(e, Nothing) | e <- entries]   -- ArchiveError 整個丟棄
  Right () -> ...
```

`Left _` 把 `ArchiveError` 丟掉,並回傳一個**與「每一筆項目都個別讀不到」完全同形**的
結果。呼叫端 `scanArchive` 收到的是 `[(entry, Nothing)]`,型別上分辨不出這是
「整包解不開」還是「每一筆剛好都讀不到」,於是照常走成功路徑:

```haskell
contents <- fetchContents tools path entries
let unread = length [() | (_, Nothing) <- contents]
...
soOnEvent (EvArchiveDone path (length entries))
pure acc { srArchives = srArchives acc + 1, ... }
```

**根因是型別把兩種不同的事壓成了同一種形狀。** `fetchContents` 的回傳型別
`IO [(ArchiveEntry, Maybe ByteString)]` 沒有表達「整批失敗」這個可能性,所以呼叫端
沒有機會處理它——編譯器也不會提醒。

次要問題:`listEntries` 失敗時走的是泛用的 `problem`,只留下一則 `srProblems` 文字,
沒有計入任何失敗計數。「整包讀不開」與「符號連結迴圈」在報告裡長得一樣。

違反 `.design/subsystems/ingest/design.md` 橫向約束:

- **第 2 條**「每一種失敗都必須有出口,不得靜默丟棄……把失敗吞成成功比把失敗誤判成
  另一種失敗更糟」
- 管線 A 的 `EvArchiveFailed` / `srArchivesFailed` 契約

## 修復方向

**讓型別表達得出「整批失敗」,使吞噬在結構上不可能發生。**

1. `fetchContents` 的回傳型別改為 `IO (Either ArchiveError [(ArchiveEntry, Maybe ByteString)])`。
   整包解壓失敗回 `Left err`,呼叫端**必須**處理——這是本次修復的核心,其餘都是它的後果。
2. `ScanEvent` 新增 `EvArchiveFailed FilePath Text`;`ScanReport` 新增 `srArchivesFailed :: Int`。
   (兩者都已在 Level 2 契約中,本次是實作跟上。)
3. `scanArchive` 的兩條「整包讀不開」路徑——`listEntries` 失敗與 `fetchContents` 失敗——
   一律走新的失敗出口:計入 `srArchivesFailed`、發出 `EvArchiveFailed` 並帶原因、
   **不寫入任何項目**、不計入 `srArchives`。
4. `Report.hs` 顯眼呈現失敗數與原因,與「個別項目讀不到」(`srEntriesUnread`)分開陳述。

**動到 Level 2 公開介面**:`ScanEvent` 與 `ScanReport` 都是對外契約的一部分。兩者的新
欄位已於 2026-08-21 寫進 `design.md`(契約先行),本次實作是讓程式碼跟上,不需要再改契約。

**替代方案(已放棄)**:只在 `Left` 分支多發一個 `EvProblem`。改動更小,但回傳型別仍然
分辨不出兩種情況,下一個人重構時一樣會把它們混在一起——沒有解決根因。

**本次不做**(最小修復原則,已在 `design.md` 的缺口表中列為 `/enhance-design`):
`srAborted` / `EvAborted` 的「整批中止」層、交易邊界的重構、裸 `try` 吞掉 `AsyncException`。

## TodoList

- [x] T1: 撰寫重現測試:整包取不到內容時不得計入成功、不得寫入項目(修復前應失敗)  `dep: -`
- [x] T2: `fetchContents` 回傳型別改為 `Either ArchiveError [...]`  `dep: T1`
- [x] T3: `ScanEvent` 加 `EvArchiveFailed`、`ScanReport` 加 `srArchivesFailed`  `dep: T1`
- [x] T4: `scanArchive` 的兩條整包失敗路徑走新出口,不寫入任何項目  `dep: T2, T3`
- [x] T5: `Report.hs` 呈現失敗數與原因,與 `srEntriesUnread` 分開  `dep: T3`

## 驗證方式

重現測試轉綠,且既有 `cabal test all` 全綠(基準線 604 examples / 0 failures)。

重現測試分兩條:一條不依賴 7-Zip(整包列不出來),一條需要 7-Zip(列得出來但取不出來,
即本缺陷的原始路徑)。後者在沒有 7-Zip 的環境標為 `pending` 而不是假裝通過——沿用
`ScanSpec` 既有的符號連結測試作法。

## 修復紀錄

依「修復方向」完成,**無偏差**。

核心是型別:`fetchContents` 改回 `IO (Either ArchiveError [(ArchiveEntry, Maybe ByteString)])`
之後,呼叫端在型別上就再也無法忽略整包失敗——編譯器會擋下遺漏。其餘四項都是這個改動的
後果:`scanArchive` 的兩條整包失敗路徑(`listEntries` 失敗、`fetchContents` 失敗)收斂到
同一個 `archiveFailed` 出口,計入 `srArchivesFailed`、發出 `EvArchiveFailed` 並帶原因、
一筆項目都不寫入。

`Report.hs` 把失敗數獨立成一段,措辭刻意與 `srEntriesUnread` 區隔:後者說「幾個項目
讀不到內容」,前者說「幾個壓縮檔完全沒有進索引……這些素材包目前在資料庫裡不存在」。

### 重現測試

兩條,都在 `ingest/test/AssetDB/Ingest/ScanSpec.hs`:

| 測試 | 觸發路徑 | 環境需求 |
|---|---|---|
| 列不出來的壓縮檔不計入成功,也不寫入任何項目 | `listEntries` 失敗 | 無(垃圾內容的 `.rar`,有無 7-Zip 都列不出來) |
| 列得出來但取不出來時,不計入成功,也不留下沒有雜湊的項目 | `extractAllTo` 失敗 —— **本缺陷的原始路徑** | 需要 7-Zip;缺席時 `pendingWith` 而不是假裝通過 |

第二條的 fixture 是刻意構造的:用 `Store`(不壓縮)建 ZIP 後把項目資料區的位元組打壞,
再命名為 `.7z`。結尾的 central directory 完好所以 7-Zip 列得出項目;資料的 CRC 對不上
所以整包解壓以非零結束碼失敗;副檔名 `.7z` 讓 `prefersBulkExtraction` 為真而走到缺陷所在
的整包解壓路徑。

**修復前執行結果**(第二條):

```text
1) 整包取不到內容(B001) 列得出來但取不出來時,不計入成功,也不留下沒有雜湊的項目
     expected: 0
      but got: 1
```

`srArchives` 是 1 —— 一個一筆內容都沒讀到的壓縮檔,被算成了成功索引的壓縮檔。
修復後兩條皆綠,且**都不是 pending**(本機有 7-Zip,原始路徑確實被走到)。

除了計數,第二條另外斷言:失敗事件帶得出非空的原因,且**完全不發出 `EvArchiveDone`**
——後者是這個缺陷最外顯的症狀(失敗與成功發出同一個事件)。

### 驗證結果

```text
cabal build all     # 零 error、零 warning
cabal test all      # 606 examples, 0 failures(9 個 test suite 全 PASS)
```

基準線 604 → 606(+2,即本次的兩條重現測試),其餘既有測試無一變紅。

### 過程中發現、但未在本次處理的

- `Scan.hs` 的 `writeArchive` 外層是裸 `try @SomeException`,會**吞掉 `AsyncException`**
  ——掃描途中 Ctrl-C 會被記成一則「寫入失敗」然後繼續掃下一個壓縮檔。`ai/` 的批次驅動器
  對同一件事有正確的重拋。屬「整批中止」那一層,已列在 `design.md` 的缺口表中走
  `/enhance-design`,本次依最小修復原則不動。
- 個別項目讀不到內容時(`readEntry` 失敗)同樣把 `ArchiveError` 丟成 `Nothing`,原因不
  保留。這是既有的設計選擇(那些項目仍入庫並計入 `srEntriesUnread`),不是缺陷,但
  「讀不到的原因」目前完全查不到,值得日後一併改善。
