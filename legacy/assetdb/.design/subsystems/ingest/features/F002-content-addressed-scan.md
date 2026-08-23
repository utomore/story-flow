---
id: F002
type: feature
title: content-addressed-scan
description: 走訪素材庫、為每一筆內容算 SHA-256、抽取格式中繼資料並入庫
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001]
related-adr: [ADR-002, ADR-003, ADR-008]
---

# F002: 內容定址掃描

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

走訪一個素材庫根目錄,把找到的壓縮檔與散檔全部索引進資料庫,並為**每一筆內容**計算 SHA-256。

SHA-256 是整個系統的識別基礎:`blobs` 表以它為主鍵(同一份內容跨素材包只算一次縮圖);搬遷的刪除閘門只認它(檔名與大小相同不構成「同一份內容」的證明);專案素材與來源不一致時靠它分辨「被改過」與「來源更新了」。因此掃描必須先於搬遷——先有那份雜湊清單,才有辦法證明搬移過程沒弄丟東西。

「一個檔案是什麼、該抽出哪些中繼資料」由格式處理器註冊表決定,而註冊表是一個清單。加入一種 kind 等於往清單 append 一筆,不動 `assets`、不動 `blobs`、不寫 migration——kind 專屬中繼資料一律以 JSON 存進 `meta_json`,所以「音效的欄位與圖片不同」不會變成資料表結構的差異。音效解析(RIFF/WAVE 檔頭)就是這個設計的實證:加入時唯一改動的是註冊表裡那一筆的探測函式。

兩個效能上的分岔在這裡收斂:壓縮檔的讀取策略依 `prefersBulkExtraction` 分成逐筆與整包(F001);散檔的記憶體策略分成整檔讀與串流(圖片/音效的探測本來就需要整份內容,既然要讀,雜湊就用同一份位元組;其餘 kind 的探測都是無操作,雜湊走串流,大型參考照片與原始檔不再整檔進記憶體)。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Ingest.Scan` | `ingest/src/AssetDB/Ingest/Scan.hs` | 目錄走訪(含迴圈防護)、壓縮檔與散檔的索引寫入、冪等判斷 |
| `AssetDB.Ingest.Hash` | `ingest/src/AssetDB/Ingest/Hash.hs` | SHA-256(整份與串流)、CRC32 十六進位格式化 |
| `AssetDB.Ingest.Handler` | `ingest/src/AssetDB/Ingest/Handler.hs` | 格式處理器註冊表、kind 判定、中繼資料抽取 |
| `AssetDB.Ingest.Report` | `ingest/src/AssetDB/Ingest/Report.hs` | 掃描事件與報告的人類可讀渲染 |
| `AssetDB.Ingest` | `ingest/src/AssetDB/Ingest.hs` | 繖形模組,重新匯出上述四者 |
| 套件定義 | `ingest/assetdb-ingest.cabal` | exposed-modules、`crypton` / `JuicyPixels` / `temporary` 相依 |

引用自 catalog:`AssetDB.PathText` 的 `leafOf` / `extensionOf` / `slugify`(唯一實作在 core,enhance-0012);`AssetDB.Id` 的 ULID;`AssetDB.Types` 的 `AssetKind` 與 `TextEnum`;`AssetDB.Store` 的連線與交易。壓縮副檔名清單引用自 F001 的 `formatExtensions`。

## 對外行為

- `scanRoot :: Store -> ArchiveTools -> ScanOptions -> IO ScanReport` — 單一入口。
- `ScanOptions` / `defaultScanOptions` — 根目錄、標籤、根類型(`packs` / `reference` / `studio`)、是否強制重掃、事件回呼。回呼預設無操作,ingest 內部不做終端機輸出。
- `ScanEvent` — 七種事件(發現、壓縮檔開始/完成/跳過、散檔開始/完成、問題)。
- `ScanReport` — 壓縮檔數、跳過數、項目數、**讀不到內容的項目數**、散檔數、雜湊位元組數、問題清單。`srEntriesUnread` 非零代表搬遷的刪除閘門依據不完整,必須顯眼。
- 走訪行為:點號開頭的目錄一律跳過(`.assetdb` 是自己的資料庫與快取);系統自產的中繼檔案不被索引(否則覆蓋率報告會永遠掛著假的「未覆蓋」項目);以 canonical path 集合防護符號連結/junction 迴圈(enhance-0011),重複目錄跳過並記入警告——這同時涵蓋「兩條連結指向同一目錄」的重複索引。
- 冪等:壓縮檔內容不可變,雜湊沒變就代表裡面每一筆項目都沒變,因此重掃幾乎免費。只有雜湊變過的壓縮檔會重建其項目,採「先刪後建」而非逐筆 upsert,不留上一版殘留。
- 讀不到內容的項目**仍然入庫**(`sha256` 為 NULL)。丟棄會讓「這包有幾個檔案」對不上,查帳時無從解釋差額。
- 素材包一律建成 `draft`:授權與作者無法從檔名推導,猜錯的授權比沒有授權更危險。識別鍵用壓縮檔的相對路徑而非 slug——`slugify` 對純中文名稱會產生空字串,用 slug 當鍵會把不同素材包靜默合併。
- `Sha256` / `unSha256` / `sha256Bytes` / `sha256File` / `crc32Hex` — 兩個雜湊入口必須算出相同結果;`unSha256` 的小寫十六進位是唯一進資料庫的形式。
- `Handler` / `handlers` / `handlerFor` / `kindForPath` / `probeContent` — 註冊表順序有意義(取第一個命中);不認得的副檔名歸 `KSource` 而**不丟棄**。
- `archiveExtensions` — 由 `formatExtensions` 導出。曾各寫一份並多列了 `.tar` / `.gz`,造成「標為 `KArchive` 卻走散檔路徑」的不一致(enhance-0012)。
- `renderEvent` / `renderReport` / `humanBytes` — 回傳 `Text`,由 delivery 決定輸出位置;`renderEvent` 回 `Nothing` 表示這個事件不必顯示。

## 驗收依據

- `ingest/test/AssetDB/Ingest/ScanSpec.hs`(對真實 ZIP 與真實 SQLite 跑完整掃描)
  - 索引結果:「壓縮檔與散檔都進了資料庫」「每一筆都有 SHA-256」「相同內容跨來源只算一份 blob」「目錄不會被當成資源」「素材包一律建成 draft」「路徑一律以 / 分隔」「中文檔名完整保留」「PNG 的中繼資料有抽出來」
  - 冪等性:「重掃時壓縮檔雜湊未變就跳過」「重掃不會產生重複資源」「--rehash 會強制重算」
  - 散檔雜湊策略:「串流路徑(非媒體 kind)的雜湊與大小和整檔讀取一致」「媒體路徑(整檔讀供探測)的雜湊與 sha256File 一致」
  - 符號連結迴圈防護:「對含自我指涉連結的目錄樹不無窮遞迴,且記錄警告」
- `ingest/test/AssetDB/Ingest/HashSpec.hs`
  - `sha256Bytes`:「空輸入的標準值」「abc 的標準值」「輸出是 64 個小寫十六進位字元」「二進位內容不會被文字編碼弄壞」
  - `sha256File`:「與 sha256Bytes 一致 —— 串流路徑不能算出不同答案」
  - `crc32Hex`:「補零到八位」「最大值」
- `ingest/test/AssetDB/Ingest/HandlerSpec.hs`
  - `extensionOf`:「取小寫副檔名」「沒有副檔名回空字串」「目錄名裡的點號不算」
  - `archiveExtensions`:「與 archive 套件的 formatExtensions 一致」「detectFormat 不認得的 tar/gz 不再被標為 KArchive」
  - `kindForPath`:「依副檔名分類」「不認得的副檔名歸為 KSource 而不是丟棄」
  - 音效處理器:「認得常見音訊格式」「音效與圖片走同一條索引路徑」「讀得懂 WAV 的取樣率、聲道數與長度」「chunk 之間夾雜 LIST 時仍然讀得到 fmt 與 data」「奇數長度的 chunk 後面有 padding byte」「不是 WAV 的音訊格式只分類不解碼 —— 仍然入庫」「壞掉的 WAV 回 Nothing 而不是爆炸」
  - PNG 中繼資料:「取出尺寸與 alpha」「色數是區分手繪與色盤像素風的訊號」「壞掉的 PNG 回 Nothing 而不是爆炸」「副檔名不認得時不呼叫任何 probe」
