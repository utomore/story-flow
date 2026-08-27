---
id: F001
type: feature
title: archive-access
description: 列出與讀取壓縮檔內容,ZIP 原生、rar/7z 交給 7-Zip
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-002, ADR-005]
---

# F001: 壓縮檔存取

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

素材庫的真相來源是廠商壓縮檔,不是解壓後的散檔。這決定了兩個硬性要求:

1. **列出內容不該解壓。** ZIP 的 central directory 直接給出路徑、大小與 CRC32,完全不必碰壓縮資料,因此數千個項目的索引是毫秒級操作。
2. **讀取單筆項目不該落地。** 建專案時只取出選中的那幾個檔案,解到記憶體後直接寫進專案,中間不產生暫存檔。

ZIP 由純 Haskell 處理(素材庫裡的多數壓縮檔是 ZIP,最常走的路徑不該依賴外部程式);rar 是專有格式、7z 的解壓器沒有 Haskell 綁定,兩者交給 7-Zip 外部程式(ADR-005)。格式派送對呼叫端完全透明——`listEntries` 與 `readEntry` 的簽名不區分格式,回傳的 `ArchiveEntry` 形狀也一致。

唯一的「整包解壓」例外是掃描時為每一筆項目算雜湊:rar 與 7z 預設使用 solid 壓縮,逐筆抽取是 O(n²) 的解壓量,整包解一次是 O(n)。呼叫端用 `prefersBulkExtraction` 決定策略,解出來的檔案算完雜湊即刪除——「不保留解壓副本」講的是儲存,不是禁止解壓。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Archive` | `archive/src/AssetDB/Archive.hs` | 工具探索、格式派送、目錄項目統一過濾 |
| `AssetDB.Archive.Types` | `archive/src/AssetDB/Archive/Types.hs` | 格式列舉、項目 DTO、錯誤型別、路徑正規化 |
| `AssetDB.Archive.Zip` | `archive/src/AssetDB/Archive/Zip.hs` | ZIP 原生實作(讀 central directory、單筆解壓) |
| `AssetDB.Archive.Sidecar` | `archive/src/AssetDB/Archive/Sidecar.hs` | 7-Zip 探索、呼叫與 `-slt` 輸出解析 |
| 診斷工具 | `archive/app/Probe.hs` | `assetdb-archive-probe`:對單一壓縮檔印出解析結果 |
| 套件定義 | `archive/assetdb-archive.cabal` | exposed-modules、`zip` / `typed-process` 相依 |

## 對外行為

- `discoverTools :: IO ArchiveTools` — 一次探索、重複使用。先查 `PATH`(`7z` / `7zz` / `7za`),再查 Windows 與 Unix 的已知安裝位置(`sevenZipCandidates`)。
- `supportedFormats :: ArchiveTools -> [ArchiveFormat]` / `describeTools :: ArchiveTools -> Text` — 沒有 7-Zip 時能力縮減為僅 ZIP,而不是錯誤;`describeTools` 給 doctor 指令用,含安裝指示。
- `listEntries :: ArchiveTools -> FilePath -> IO (Either ArchiveError [ArchiveEntry])` — 目錄項目一律過濾掉(兩條實作路徑對目錄的處理不同,差異在入口統一)。ZIP 走原生;原生失敗(如 LZMA/PPMd 壓縮方法)時若有 7-Zip 則後備,兩者都失敗時回報**原始**錯誤而非二次症狀。
- `readEntry :: ArchiveTools -> FilePath -> Text -> IO (Either ArchiveError ByteString)` — 解壓單筆項目到記憶體。`EntryNotFound` 不觸發 sidecar 後備(那是使用者打錯名字,不是實作限制)。
- `extractAllTo :: ArchiveTools -> FilePath -> FilePath -> IO (Either ArchiveError ())` / `prefersBulkExtraction :: ArchiveFormat -> Bool` — 整包解壓與策略判斷;呼叫端負責刪除目標目錄。
- `detectFormat` / `formatExtensions` / `needsSidecar` — 副檔名比對不分大小寫;`formatExtensions` 是全系統壓縮副檔名的**唯一權威來源**。
- `ArchiveEntry` — `aePath` 一律 `/` 分隔;`aeCrc32` 來自 ZIP 檔頭時免費取得,可當 SHA-256 之前的廉價前濾。
- `normalizeEntryPath` / `toNativeEntryPath` — 進資料庫前統一成 `/`、去掉開頭的 `./`(冪等);傳給外部工具時轉回平台分隔符(7-Zip 在 Windows 上認反斜線)。
- `ArchiveError` / `renderArchiveError` — 五種錯誤都是值。`SidecarNotFound` 必須列出找過哪些位置與安裝方式;`EntryNotFound` 與 `MalformedArchive` 必須可分辨。
- `AssetDB.Archive.Sidecar` 另公開 `SevenZip(..)`、`findSevenZip`、`sevenZipCandidates`,以及匯出供測試的 `parseListing`。

環境相關的兩個硬性作法:呼叫 7-Zip 一律帶 UTF-8 主控台輸出旗標(否則 Windows 上中文檔名變亂碼);讀取單筆時關閉萬用字元比對(否則檔名裡的 `*` `?` 會靜默吐出多個檔案的內容串在一起)。參數一律以陣列傳遞,不組字串。

## 驗收依據

- `archive/test/AssetDB/Archive/TypesSpec.hs`
  - 「認得三種格式」「副檔名比對不分大小寫」「路徑含空格與特殊字元不影響判斷」「不認得的副檔名回 Nothing」
  - 「只有 ZIP 不需要外部工具」
  - 「反斜線統一成正斜線」「正斜線原樣保留」「去掉開頭的 ./」「是冪等的」「中文路徑不受影響」
  - 「找不到 sidecar 時要說出找過哪裡與怎麼安裝」「不支援的格式要列出支援哪些」
- `archive/test/AssetDB/Archive/ZipSpec.hs`(以 `temporary` 建出真實 ZIP)
  - `listEntries`:「列出所有項目」「路徑一律以 / 分隔」「大小正確」「CRC32 從 central directory 免費取得」「巢狀同名目錄不會混淆」「不存在的壓縮檔回報 MalformedArchive」「不認得的副檔名回報 UnsupportedExtension」
  - `readEntry`:「讀出的內容與寫入時一致」「中文檔名讀得到」「檔名含 & 與空格讀得到」「不存在的項目回報 EntryNotFound 而不是空內容」「傳入反斜線路徑也找得到」
- `archive/test/AssetDB/Archive/SidecarSpec.hs`(以固定的 `7z l -slt` 輸出樣本驗證解析)
  - `parseListing`:「只取檔案清單,不把壓縮檔自己的屬性當成項目」「認得目錄」「反斜線路徑正規化」「讀出大小」「讀出 CRC32,空值是 Nothing 而不是 0」「讀出修改時間」「空輸入不會爆炸」
  - 「.7z 與 .zip 的輸出差異」:「7z 的目錄沒有 Folder 欄位,且 D 不在 Attributes 開頭」「只留下真正的檔案」「帶小數秒的時間戳解析得出來」
  - 邊界:「檔名裡有 ' = ' 時只切第一個」「中文路徑保持完整」「CRLF 換行」
  - `findSevenZip`:「候選位置涵蓋 Windows 的預設安裝路徑」「候選位置也涵蓋 Unix」
