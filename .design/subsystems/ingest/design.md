---
id: ingest
type: subsystem
title: ingest
description: 把磁碟上的壓縮檔與散檔轉成內容定址的索引資料
status: active
created: 2026-08-19
updated: 2026-08-19
parent: system
related-adr: [ADR-002, ADR-004, ADR-005]
---

# Ingest 子系統架構

## 定位與範圍

ingest 是 AssetDB 唯一**碰素材庫檔案系統**的子系統。它把磁碟上的現況(壓縮檔、散檔、Markdown 筆記)轉換成 catalog 定義的資料表內容:每一筆內容都有 SHA-256、每一個檔案都有 kind 與 kind 專屬中繼資料、每一個素材包都有可從磁碟重建的 `pack.toml`。

由三個 cabal 套件構成:

| 套件 | 職責 |
|---|---|
| `archive` | 壓縮檔存取:列出內容與讀取單筆項目,**不解壓到磁碟** |
| `ingest` | 掃描與內容定址、格式處理器、素材包中繼資料、叢集推論、縮圖、筆記與關聯圖 |
| `reorg` | 一次性的素材庫結構搬遷:快照 → 計畫 → 執行 → 對帳 → 回退 |

### 明確不做什麼

- **不定義領域型別、不定義資料表結構、不寫 migration。** `AssetKind`、`KindPrefix`、`TextEnum`、ULID、命名文法、SQLite schema 全部屬於 catalog;ingest 是使用者。跨套件共用的路徑/文字工具(`leafOf`、`extensionOf`、`slugify`、`ThumbSize`、`thumbPath`)同樣屬於 catalog 的 `AssetDB.PathText`,ingest 只是引用者。
- **不提供查詢。** 全文檢索、facet 統計、分頁一律屬於 catalog 的 `store` 套件。ingest 只寫入,唯一的讀取是為了寫入而做的存在性判斷(壓縮檔雜湊是否已知、授權名稱是否存在)。
- **不做 HTTP、不做 CLI 參數解析、不做終端機輸出決策。** 進度以事件回呼(`ScanEvent`、`ApplyEvent`)交出去,渲染函式回傳 `Text`,由 delivery 決定印到哪裡。ingest 內部不呼叫 `putStrLn`。
- **不做語意判斷。** 「這是像素風還是手繪」「這張圖畫的是什麼」屬於 ai-tagging。ingest 只產生客觀訊號(尺寸、色數、取樣率、檔名形狀)。
- **不保留解壓副本。** 唯一會落地的解壓是掃描 solid 壓縮檔時的暫存目錄,算完雜湊即刪除。
- **不再自動搬移或刪除散檔。** 2026-08-09 的一次性搬遷已執行完畢,其路徑規則已退役(enhance-0009);現行規劃器對散檔一律產生 `OpKeep`。`OpDelete` 型別與其執行器保留為通用機制,但規劃器不會產生它。
- **不做增量檔案監看。** 沒有 file watcher,重掃是使用者觸發的動作;冪等性由壓縮檔雜湊比對提供。

## 對外契約(Public Interface & DTOs)

其他子系統對 ingest 的依賴全部來自 delivery(`cli` 用全部、`project` 只用壓縮檔讀取)。ai-tagging 不直接依賴 ingest。

### 壓縮檔存取 — `AssetDB.Archive`

```haskell
newtype ArchiveTools = ArchiveTools { atSevenZip :: Maybe SevenZip }

discoverTools         :: IO ArchiveTools
supportedFormats      :: ArchiveTools -> [ArchiveFormat]
describeTools         :: ArchiveTools -> Text

listEntries           :: ArchiveTools -> FilePath -> IO (Either ArchiveError [ArchiveEntry])
readEntry             :: ArchiveTools -> FilePath -> Text -> IO (Either ArchiveError ByteString)
extractAllTo          :: ArchiveTools -> FilePath -> FilePath -> IO (Either ArchiveError ())
prefersBulkExtraction :: ArchiveFormat -> Bool
```

重新匯出 `AssetDB.Archive.Types` 的全部內容:

```haskell
data ArchiveFormat = FmtZip | FmtRar | Fmt7z        -- instance TextEnum
detectFormat     :: FilePath -> Maybe ArchiveFormat
formatExtensions :: ArchiveFormat -> [String]       -- 壓縮副檔名的權威來源
needsSidecar     :: ArchiveFormat -> Bool

data ArchiveEntry = ArchiveEntry
  { aePath :: Text, aeSize :: Word64, aePackedSize :: Maybe Word64
  , aeCrc32 :: Maybe Word32, aeModified :: Maybe UTCTime, aeIsDir :: Bool }

normalizeEntryPath :: Text -> Text     -- 一律 '/' 分隔、去掉開頭 "./"
toNativeEntryPath  :: Text -> Text     -- 傳給外部工具時轉回平台分隔符

data ArchiveError
  = UnsupportedExtension FilePath
  | SidecarNotFound ArchiveFormat [FilePath]
  | SidecarFailed FilePath Int Text
  | EntryNotFound FilePath Text
  | MalformedArchive FilePath Text
renderArchiveError :: ArchiveError -> Text
```

`AssetDB.Archive.Sidecar` 另外公開 `SevenZip(..)`、`findSevenZip`、`sevenZipCandidates` 與 `parseListing`(後者匯出供測試)。

### 掃描與索引 — `AssetDB.Ingest`(繖形模組,重新匯出 Scan / Hash / Handler / Report)

```haskell
data ScanOptions = ScanOptions
  { soRootPath :: FilePath, soRootLabel :: Text, soRootKind :: Text
  , soRehash :: Bool, soOnEvent :: ScanEvent -> IO () }
defaultScanOptions :: FilePath -> ScanOptions

data ScanEvent
  = EvDiscovered Int Int | EvArchiveStart FilePath Int Int | EvArchiveDone FilePath Int
  | EvArchiveSkipped FilePath | EvLooseStart Int | EvLooseDone Int | EvProblem Text

data ScanReport = ScanReport
  { srArchives :: Int, srArchivesSkipped :: Int, srEntries :: Int
  , srEntriesUnread :: Int, srLooseFiles :: Int, srBytesHashed :: Integer
  , srProblems :: [Text] }
emptyReport :: ScanReport

scanRoot :: Store -> ArchiveTools -> ScanOptions -> IO ScanReport
```

```haskell
-- 內容雜湊
data Sha256                                  -- newtype over Text,Show = 小寫十六進位
unSha256    :: Sha256 -> Text
sha256Bytes :: ByteString -> Sha256
sha256File  :: FilePath -> IO Sha256         -- 串流,不整檔載入記憶體
crc32Hex    :: Word32 -> Text

-- 格式處理器註冊表
data Handler = Handler
  { hName :: Text, hExtensions :: [Text], hKind :: AssetKind
  , hProbe :: ByteString -> Maybe Value }
handlers          :: [Handler]
handlerFor        :: Text -> Maybe Handler
kindForPath       :: Text -> AssetKind        -- 不認得的副檔名 → KSource,不丟棄
probeContent      :: Text -> ByteString -> Maybe Value
archiveExtensions :: [Text]                   -- 由 formatExtensions 導出
extensionOf       :: Text -> Text             -- re-export,唯一實作在 AssetDB.PathText

-- 掃描結果渲染
renderEvent  :: ScanEvent -> Maybe Text       -- Nothing = 這個事件不必顯示
renderReport :: ScanReport -> Text
humanBytes   :: Integer -> Text
```

### 素材包中繼資料 — `AssetDB.Ingest.Catalogue`

```haskell
newtype Catalogue = Catalogue { catPacks :: [PackEntry] }
data PackEntry = PackEntry
  { peArchive :: Text, peName :: Text, peSlug :: Text
  , peVendor, peAuthor, peAuthorUrl, peAuthorContact, peLicense, peAi :: Maybe Text
  , peSourceUrl, peVersion :: Maybe Text, pePrice :: Maybe Double
  , peAcquired, peKind, peNotes :: Maybe Text }

parseCatalogue :: Text -> Either Text Catalogue

data ApplyResult = ApplyResult
  { arMatched :: [(Text, Bool)]        -- (壓縮檔名, 是否升級為 ready)
  , arMissingArchive :: [Text], arMissingLicense :: [Text] }
applyCatalogue :: Store -> Catalogue -> IO ApplyResult
```

### 命名輔助 — `AssetDB.Ingest.Cluster` / `AssetDB.Ingest.ClusterDb`

```haskell
-- 檔名形狀
data Token = Token { tkLetters :: Text, tkDigits :: Text, tkSuffix :: Text }
tokenize  :: Text -> [Token]
fileShape :: Text -> Text

-- 目錄角色
data DirRole = RoleSprites | RoleAnimated | RoleSheet | RoleSource
             | RolePreview | RoleFont | RoleDoc | RoleOther
dirRole     :: Text -> DirRole
dirRoleText :: DirRole -> Text

-- 叢集
data ClusterKey = ClusterKey { ckRole :: DirRole, ckShape :: Text, ckExt :: Text }
clusterKeyText :: ClusterKey -> Text
clusterKeyOf   :: Text -> ClusterKey
data Cluster = Cluster { clKey :: ClusterKey, clCount :: Int, clSamples :: [Text] }
clusterBy      :: [Text] -> [Cluster]

-- 命名規則(持久化格式:手寫 ToJSON/FromJSON)
data NumericRole = NumAuto | NumVariant | NumIndex
data NameRule = NameRule
  { nrKind :: KindPrefix, nrDomain :: Text, nrSubject :: Maybe Text
  , nrDropTokens :: [Int], nrIncludeDirs :: Int
  , nrNumeric :: NumericRole, nrTags :: [Text] }
applyRule :: NamingVocab -> NameRule -> Text -> Either NameError LogicalName
```

```haskell
data PackRef = PackRef { pkId :: Int, pkSlug :: Text, pkName :: Text }
listPacks     :: Store -> Maybe Text -> IO [PackRef]
packPaths     :: Store -> Int -> IO [Text]
packClusters  :: Store -> Int -> IO [Cluster]
saveRule      :: Store -> Int -> Cluster -> NameRule -> IO ()
loadRules     :: Store -> Int -> IO (Map Text NameRule)

data NamePreview = NamePreview { npPath :: Text, npResult :: Either Text Text }
previewCluster :: NamingVocab -> NameRule -> [Text] -> [NamePreview]

data ApplyNames = ApplyNames
  { anNamed :: Int, anSkipped :: Int
  , anFailed :: [(Text, Text)], anCollisions :: [(Text, [Text])] }
applyNames :: Store -> NamingVocab -> Int -> IO ApplyNames
```

### 縮圖 — `AssetDB.Ingest.Thumb` / `AssetDB.Ingest.ThumbRun`

```haskell
-- ThumbSize / thumbPath / thumbSizes 的唯一實作在 AssetDB.PathText,此處 re-export
data ThumbSize
thumbSizes  :: [ThumbSize]
thumbPath   :: FilePath -> Text -> ThumbSize -> FilePath
makeThumb   :: ThumbSize -> ByteString -> Either Text ByteString   -- 輸出 PNG
renderThumb :: Int -> Image PixelRGBA8 -> Image PixelRGBA8

data ThumbOptions = ThumbOptions
  { toCacheRoot :: FilePath, toLibraryRoot :: FilePath, toForce :: Bool
  , toOnProgress :: Int -> Int -> Text -> IO () }
defaultThumbOptions :: FilePath -> FilePath -> ThumbOptions
data ThumbReport = ThumbReport { trMade :: Int, trSkipped :: Int, trFailed :: [(Text, Text)] }
generateThumbs :: Store -> ArchiveTools -> ThumbOptions -> IO ThumbReport
```

### 筆記與關聯圖 — `AssetDB.Ingest.Notes`

```haskell
data NoteDoc = NoteDoc
  { ndTitle :: Text, ndBody :: Text, ndFront :: [(Text, Text)], ndSource :: Text }
parseFrontMatter :: Text -> Text -> NoteDoc              -- (來源檔名, 原始內容)
frontJson        :: [(Text, Text)] -> Text

importNotes  :: Store -> NoteKind -> FilePath -> IO [(Text, Text)]   -- [(標題, 來源)]
listNotes    :: Store -> Maybe NoteKind -> IO [(Text, Text, Text, Text)]
reindexNotes :: Store -> IO Int

tableOf      :: Text -> Either Text Text                 -- 實體型別 → 資料表名
linkEntities :: Store -> Text -> Text -> Text -> Text -> LinkRel -> Maybe Text
             -> IO (Either Text ())
entityLinks  :: Store -> Text -> Text -> IO (Either Text [(Text, Text, Text, Text)])
             -- 每筆 = (方向 "in"/"out", rel, 對端型別, 對端 ULID),雙向
```

### 結構搬遷 — `AssetDB.Reorg.*`(無繖形模組,呼叫端直接匯入各模組)

```haskell
-- Snapshot:規劃所需資料的唯一 IO 邊界
data Snapshot = Snapshot
  { snPacks :: [PackRow], snLoose :: [LooseRow], snArchivedBy :: Map Text Text }
  -- snArchivedBy: 項目 SHA-256 → 壓縮檔相對路徑(刪除閘門的證據來源)
data PackRow = PackRow
  { prSlug, prName :: Text, prVendor, prAuthor, prLicense :: Maybe Text
  , prKind, prStatus, prAi :: Text, prSourceUrl, prVersion, prNotes :: Maybe Text
  , prArchiveRel, prArchiveSha :: Text, prArchiveBytes :: Integer, prEntryCount :: Int }
data LooseRow = LooseRow { lrRelPath :: Text, lrSha :: Maybe Text, lrBytes :: Integer }
loadSnapshot :: Store -> IO Snapshot

-- Plan:純函數
data Op = OpMkDir  { opPath :: Text }
        | OpMove   { opFrom, opTo :: Text, opBytes :: Integer, opWhy :: Text }
        | OpWrite  { opTo :: Text, opWhy :: Text }
        | OpDelete { opFrom, opSha, opCoveredBy :: Text, opBytes :: Integer }
        | OpKeep   { opFrom :: Text, opWhy :: Text }
data Plan = Plan
  { planSourceRoot, planTargetRoot :: Text, planOps :: [Op], planWarnings :: [Text] }
data PlanStats = PlanStats
  { psMkDir, psMove, psWrite, psDelete, psKeep :: Int
  , psBytesMoved, psBytesFreed :: Integer }
planStats    :: Plan -> PlanStats
buildPlan    :: Text -> Text -> Snapshot -> Plan
targetDirFor :: PackRow -> Text
slugify      :: Text -> Text            -- re-export,唯一實作在 AssetDB.PathText

-- Render
data Verbosity = Summary | Verbose
renderPlan    :: Verbosity -> Plan -> Text
renderSummary :: Plan -> Text
humanBytes    :: Integer -> Text

-- PackToml
renderPackToml :: PackRow -> Text

-- Execute
data ApplyOptions = ApplyOptions
  { aoBatchId :: Text, aoDeleteCovered :: Bool, aoOnEvent :: ApplyEvent -> IO () }
defaultApplyOptions :: Text -> ApplyOptions
data ApplyEvent = EvPreflight Text | EvPhase Text | EvProgress Int Int Text
                | EvNote Text | EvFailure Text
data ApplyReport = ApplyReport
  { arDirsCreated, arMoved, arWritten, arDeleted, arReconciled :: Int
  , arBytesMoved :: Integer, arErrors :: [Text] }
applyPlan    :: Store -> Snapshot -> ApplyOptions -> Plan -> IO ApplyReport
undoBatch    :: Store -> FilePath -> FilePath -> Text -> (Text -> IO ()) -> IO (Int, [Text])
listBatches  :: Store -> IO [(Text, Int, Text)]     -- (批次, 筆數, 最早時間)
```

### 契約的橫向約束

1. **錯誤是值,不是例外。** 對外介面回傳 `Either`、`Maybe`、或帶 `srProblems` / `arErrors` 的報告。唯一允許拋例外的是不可能發生的資料庫不一致。
2. **進度是回呼,不是輸出。** `soOnEvent` / `aoOnEvent` / `toOnProgress` 由呼叫端提供,預設是無操作。
3. **對外識別一律 ULID 或 SHA-256**,內部整數 id 不出模組邊界(`PackRef`、`applyNames` 的 pack id 例外:那是同子系統內的 handle,由 `listPacks` 產生後立即消耗)。
4. **路徑一律 `/` 分隔的 `Text`**,平台原生分隔符只出現在真正呼叫檔案系統或外部程式的那一刻。

## 內部模組劃分(Internal Modules)

### `archive` 套件

| 模組 | 職責 | 對誰公開 |
|---|---|---|
| `AssetDB.Archive.Types` | 格式列舉、項目 DTO、錯誤型別、路徑正規化 | 全系統 |
| `AssetDB.Archive.Zip` | ZIP 的純 Haskell 實作:讀 central directory、單筆解壓 | 套件內(經 `AssetDB.Archive` 派送) |
| `AssetDB.Archive.Sidecar` | 7-Zip 探索、呼叫與輸出解析 | 套件內 + `parseListing` 供測試 |
| `AssetDB.Archive` | 格式派送與工具探索;統一兩條實作路徑的行為差異 | 全系統的入口 |

派送規則:ZIP 走原生實作,失敗時若有 7-Zip 則以 sidecar 後備;rar/7z 一律 sidecar。目錄項目在入口統一過濾掉——兩條路徑對目錄的處理不同,差異不外洩。

### `ingest` 套件

| 模組 | 職責 |
|---|---|
| `AssetDB.Ingest.Hash` | SHA-256(整份與串流兩種入口)與 CRC32 格式化 |
| `AssetDB.Ingest.Handler` | 格式處理器註冊表:副檔名 → `AssetKind` + kind 專屬中繼資料抽取 |
| `AssetDB.Ingest.Scan` | 目錄走訪、壓縮檔與散檔的索引寫入、冪等判斷 |
| `AssetDB.Ingest.Report` | 掃描事件與報告的人類可讀渲染 |
| `AssetDB.Ingest.Catalogue` | `pack.toml` 格式的解析與套用到資料庫 |
| `AssetDB.Ingest.Cluster` | 檔名形狀抽象、目錄角色、分群、命名規則套用(**純函數**) |
| `AssetDB.Ingest.ClusterDb` | 叢集規則的持久化、預覽與批次套用 |
| `AssetDB.Ingest.Thumb` | 單張縮圖的縮放與編碼(**純函數**);定址規則 re-export 自 catalog |
| `AssetDB.Ingest.ThumbRun` | 縮圖批次產生與 `blobs.thumb_status` 維護 |
| `AssetDB.Ingest.Notes` | Markdown 筆記匯入、front matter 解析、關聯圖讀寫、筆記全文索引重建 |
| `AssetDB.Ingest` | 繖形模組,重新匯出 Scan / Hash / Handler / Report |

分界原則:**純函數與 IO 分開成不同模組**。`Cluster` 與 `Thumb` 完全不碰資料庫與檔案系統,對應的 IO 殼是 `ClusterDb` 與 `ThumbRun`。這讓最容易出錯的推導(形狀分群、縮放取樣)可以在測試裡窮舉,而不必準備真實素材庫。

### `reorg` 套件

| 模組 | 職責 |
|---|---|
| `AssetDB.Reorg.Snapshot` | 規劃所需資料的**唯一** IO 邊界:一次撈出素材包、散檔、內容覆蓋表 |
| `AssetDB.Reorg.Plan` | 由快照推導計畫(**純函數**):目標路徑、動作清單、警告 |
| `AssetDB.Reorg.Render` | 計畫的報告渲染,分摘要與完整兩種詳盡度 |
| `AssetDB.Reorg.PackToml` | 由素材包列產生 `pack.toml` 文字(**純函數**) |
| `AssetDB.Reorg.Execute` | 前置檢查、兩階段執行、雜湊對帳、批次稽核與回退 |

`reorg` 對 `ingest` 的依賴是刻意且最小的:雜湊入口(對帳)與壓縮副檔名清單(判斷哪些搬移需要對帳)。它不使用掃描器,也不使用格式處理器的探測能力。

## 資料流管線(Data Flow Pipeline)

### 管線 A:掃描(F001 + F002)

```text
素材庫根目錄
  │
  ├─ ① 走訪:遞迴列目錄,跳過點號開頭的目錄與系統自產的中繼檔案
  │        以 canonical path 集合防護符號連結/junction 迴圈,
  │        重複目錄跳過並產生警告(進 srProblems 與 EvProblem)
  │        依 detectFormat 分成「壓縮檔」與「散檔」兩路
  │
  ├─ ②A 壓縮檔路徑
  │     整檔 SHA-256 ──► 已知且未指定 rehash?──是──► EvArchiveSkipped
  │                                            └─否─┐
  │     listEntries(只讀檔頭/central directory,不解壓)
  │       │
  │       ├─ ZIP:逐筆讀取項目內容(一次 seek)
  │       └─ rar/7z:整包解到暫存目錄再逐筆讀(solid 壓縮,逐筆抽取為 O(n²));
  │                  算完雜湊即刪除暫存目錄
  │       │
  │     每筆項目:kind 判定 ──► kind 專屬中繼資料抽取 ──► 內容 SHA-256
  │       │                                                │
  │       │   讀不到內容的項目仍入庫(sha256 為 NULL),計入 srEntriesUnread
  │       ▼
  │     單一交易內:刪除該壓縮檔既有項目 → 寫 archives → 寫 blobs(內容去重)
  │                → 寫 assets
  │
  └─ ②B 散檔路徑(單一交易)
        kind 判定
          ├─ 圖片/音效:整檔讀一次,同一份位元組同時供探測與雜湊
          └─ 其餘 kind:串流雜湊 + 檔案大小查詢(不整檔進記憶體)
        寫 blobs → 依 (root, 相對路徑) 覆寫 assets
                  │
                  ▼
              ScanReport ──► renderReport / renderEvent ──► delivery
```

### 管線 B:素材包中繼資料(F003)

```text
pack.toml 文字 ──parseCatalogue──► Catalogue
                                     │
                        每個 PackEntry:以壓縮檔**基本檔名**比對 archives
                                     │
                     ┌───────────────┼────────────────┐
              找不到壓縮檔      授權名稱不存在      兩者齊備
                     │               │                │
              arMissingArchive  arMissingLicense   作者 upsert(補空欄位,不覆蓋)
                                                      │
                                          授權與作者都在 → status = ready
                                          否則           → status = draft
                                                      │
                                                  arMatched
```

反向:`PackRow` ──`renderPackToml`──► `pack.toml` 文字(含註解),由管線 D 的階段 A 寫入磁碟。這兩個方向構成「資料庫 ↔ 磁碟」的雙向可重建。

### 管線 C:命名(F005)

```text
一包的項目路徑清單
  │
  ├─ 目錄角色判定(preview 優先)
  ├─ 檔名主幹 → 權杖序列 → 形狀字串
  └─ 副檔名
        └──► ClusterKey → 分群(依成員數遞減)→ 代表性樣本(頭/中/尾)
                │
        人對叢集給出 NameRule ──► previewCluster(不寫入,先看結果)
                │
        saveRule(以 (pack, 形狀鍵) upsert;存規則而非結果)
                │
        applyNames:載入規則 → 全部路徑各自套用
                │
          ┌─────┴──────────────────────┐
      有失敗或撞名                  全部乾淨
          │                             │
   一筆都不寫,回報所有問題      單一交易寫入 logical_name
```

分群與反查用**同一段程式碼**產生形狀鍵,否則規則會套到錯的檔案上。

### 管線 D:結構搬遷(F004)

```text
資料庫 ──loadSnapshot──► Snapshot(素材包 / 散檔 / 內容覆蓋表)
                            │
                     buildPlan(純函數)
                            │
                    Plan = 建目錄 + 搬壓縮檔 + 寫 pack.toml + 散檔一律 OpKeep
                            │
              ┌─────────────┴─────────────┐
        renderPlan / renderSummary      applyPlan
        (dry-run,不動任何檔案)             │
                                    ① 前置檢查:逐筆搬移的四種狀態
                                       (未做 / 已做 / 兩邊都無 / 兩邊都有)
                                       後兩者拒絕動作
                                            │
                                    ② 階段 A:建目錄 → 搬移(rename,失敗退回複製)
                                       → 寫 pack.toml;每筆記入 moves 表
                                            │
                                    ③ 對帳:重算每個壓縮檔在新位置的 SHA-256
                                       與資料庫紀錄比對
                                            │
                                  ┌─────────┴─────────┐
                              不符                    相符
                                │                       │
                    中止,不執行任何刪除        ④ 階段 B(需 --delete-covered)
                    可用 undoBatch 回退           刪除已證明覆蓋的散檔(不可回退)
                                                  ※ 現行規劃器不產生 OpDelete
```

### 管線 E:縮圖(F006)

```text
blobs(kind = image,thumb_status = pending 或強制)依 sha256 去重
  │
  ├─ 三種尺寸的快取檔都在且未強制 → 標記 ok,計入 trSkipped
  │
  └─ readEntry 取出內容 ──► 解碼 → 縮放 → 編碼 PNG
                              ├─ 放大:最近鄰,取整數倍後置中(像素風完好)
                              └─ 縮小:面積平均
                              │
                        寫入 thumbPath(以雜湊前兩碼分層)
                              │
                    成功 → thumb_status = 'ok';失敗 → 'failed' + thumb_error
```

失敗寫回資料庫,重跑不會反覆重試同一批壞檔案。

### 管線 F:筆記與關聯圖(F007)

```text
Markdown 目錄
  │  只取 .md / .markdown
  ├─ front matter 解析(僅 key: value 純量)
  │  標題:front matter → 第一個 Markdown 標題 → 檔名
  ├─ front matter → JSON(交由 aeson 轉義)
  └─ 以 source_path 為識別鍵 upsert notes(重複匯入是更新)
        │
        └──► reindexNotes:清空並重建 trigram 與 CJK bigram 兩個索引
                (筆記全是繁體中文,bigram 是主力而非備援)

link 指令 ──► 實體型別 → 資料表名(未知型別回 Left)
              → ULID 解析為內部 id → (src, dst, rel) 三元組唯一插入
entityLinks ──► 雙向查詢,對端識別轉回 ULID
```

## 模組間公開介面(Module Interfaces)

跨模組(含跨套件)的抽象介面。同套件內部的私有輔助不列。

| 提供者 | 介面 | 消費者 | 契約要點 |
|---|---|---|---|
| `Archive.Types` | `ArchiveFormat` / `detectFormat` / `formatExtensions` / `needsSidecar` | `Archive`、`Archive.Zip`、`Archive.Sidecar`、`Ingest.Handler`、`Ingest.Scan` | 壓縮副檔名的**唯一權威來源**;`Ingest.Handler.archiveExtensions` 由它導出,`Reorg.Execute` 再引用該導出值 |
| `Archive.Types` | `ArchiveEntry` | `Archive.Zip`、`Archive.Sidecar` → `Archive` → `Ingest.Scan` | 兩條實作路徑產生**同一形狀**的資料;`aePath` 一律 `/` 分隔 |
| `Archive.Types` | `normalizeEntryPath` / `toNativeEntryPath` | `Archive.Zip`、`Archive.Sidecar` | 進資料庫前正規化、出去給外部程式前轉原生;違反會讓同一項目產生兩筆 `entry_path` |
| `Archive.Types` | `ArchiveError` / `renderArchiveError` | 全系統 | 錯誤是值;`SidecarNotFound` 必須帶找過的位置 |
| `Archive` | `listEntries` / `readEntry` / `extractAllTo` / `prefersBulkExtraction` | `Ingest.Scan`、`Ingest.ThumbRun`、delivery 的 `project` | 格式派送與目錄過濾對呼叫端透明;`prefersBulkExtraction` 是呼叫端選擇讀取策略的唯一依據 |
| `Archive` | `ArchiveTools` / `discoverTools` / `describeTools` / `supportedFormats` | delivery 的組合根 | 工具**一次探索、重複使用**;沒有 7-Zip 不是錯誤,是能力縮減 |
| `Ingest.Hash` | `Sha256` / `sha256Bytes` / `sha256File` / `unSha256` | `Ingest.Scan`、`Reorg.Execute` | 兩個入口必須算出相同結果;`unSha256` 是唯一進資料庫的形式 |
| `Ingest.Handler` | `Handler` / `handlerFor` / `hProbe` / `hKind` | `Ingest.Scan` | 新增格式只需擴充註冊表;不認得的副檔名歸 `KSource`,**不丟棄** |
| `Ingest.Handler` | `kindForPath` / `probeContent` | `Ingest.Scan` | kind 判定與探測都只吃路徑與位元組,不碰資料庫 |
| `Ingest.Handler` | `archiveExtensions` | `Reorg.Execute` | 判斷哪些搬移需要雜湊對帳 |
| `Ingest.Scan` | `ScanEvent` / `ScanReport` | `Ingest.Report`、delivery | 渲染與統計分離;`srEntriesUnread` 非零代表刪除閘門的依據不完整 |
| `Ingest.Cluster` | `ClusterKey` / `clusterKeyOf` / `clusterKeyText` / `Cluster` / `clusterBy` | `Ingest.ClusterDb`、delivery 的 `cli`(含 AI 輔助流程) | 分群與反查共用同一個鍵函式;`clusterKeyText` 是資料庫裡的形狀鍵格式 |
| `Ingest.Cluster` | `NameRule`(含手寫 JSON codec)/ `applyRule` | `Ingest.ClusterDb` | JSON 欄位名是**跨版本持久化格式**,不由 Haskell 欄位名間接決定 |
| `Ingest.ClusterDb` | `PackRef` / `listPacks` / `packPaths` / `packClusters` | delivery 的 `cli` | pack 的內部整數 id 只在同一次操作內流通 |
| `Ingest.Thumb` | `makeThumb` / `renderThumb` | `Ingest.ThumbRun` | 純函數;輸入壞掉回 `Left`,不拋例外 |
| `AssetDB.PathText`(catalog) | `ThumbSize` / `thumbSizes` / `thumbPath` / `leafOf` / `extensionOf` / `slugify` | `Ingest.Thumb`(re-export)、`Ingest.Scan`、`Ingest.Handler`(re-export)、`Ingest.Cluster`、`Reorg.Plan`(re-export)、`Reorg.PackToml`、`Reorg.Execute` | **產生端與讀取端必須是同一套定址規則**;`slugify` 對純非 ASCII 輸入會回空字串,呼叫端必須有退路 |
| `Reorg.Snapshot` | `Snapshot` / `PackRow` / `LooseRow` / `loadSnapshot` | `Reorg.Plan`、`Reorg.PackToml`、`Reorg.Execute` | 規劃器的**唯一** IO 邊界;`snArchivedBy` 的值是刪除證據而非布林 |
| `Reorg.Plan` | `Op` / `Plan` / `PlanStats` / `buildPlan` / `targetDirFor` | `Reorg.Render`、`Reorg.Execute`、delivery | 計畫是**資料**;`targetDirFor` 同時決定規劃與執行時的 `pack.toml` 歸屬 |
| `Reorg.PackToml` | `renderPackToml` | `Reorg.Execute` | 產出必須能被 `Ingest.Catalogue` 的解析器讀回 |
| `Reorg.Execute` | `ApplyEvent` / `ApplyReport` / `applyPlan` / `undoBatch` / `listBatches` | delivery | 階段 A 完全可回退;階段 B 需獨立旗標;對帳失敗**不執行任何刪除** |

### 依賴方向

```text
catalog(core / store)
   ▲            ▲            ▲
   │            │            │
archive ◄──── ingest ◄──── reorg
```

`archive` 只依賴 `core`(型別與路徑工具),不知道資料庫存在。`ingest` 依賴 `archive` + `core` + `store`。`reorg` 依賴 `ingest` + `core` + `store`。子系統內無循環。

## 使用的技術

| 用途 | 選擇 | 理由 |
|---|---|---|
| ZIP 存取 | `zip` | 純 Haskell,直接讀 central directory,列出內容不觸碰壓縮資料 |
| rar / 7z 存取 | 7-Zip 外部程式,經 `typed-process` | rar 是專有格式、7z 無 Haskell 綁定;參數以陣列傳遞,素材庫路徑含空格與 `&` `#` `'` 等字元,任何字串拼接都會出事 |
| 內容雜湊 | `crypton` | SHA-256;串流入口以 lazy `ByteString` 分區塊處理 |
| 圖片解碼與縮圖 | `JuicyPixels` | 純 Haskell,無外部編碼器相依;輸出 PNG |
| 音效中繼資料 | 自行解析 RIFF/WAVE 檔頭 | 只需取樣率、聲道數、長度,三者都在 chunk 檔頭裡;不引入音訊解碼函式庫 |
| `pack.toml` 讀取 | `toml-parser` | schema 驅動,缺必填欄位是解析錯誤而非執行期 `Nothing` |
| `pack.toml` 寫出 | 手寫產生器 | 檔案給人編輯,註解要解釋每個欄位為什麼在那裡;序列化器不會產生註解 |
| kind 專屬中繼資料 | `aeson` → `meta_json` | 不同 kind 的欄位差異不反映成資料表結構差異 |
| 資料庫存取 | `sqlite-simple` | 超過 10 欄的插入以 `[SQLData]` 表達,NULL 與型別一目了然 |
| 暫存目錄 | `temporary` | solid 壓縮檔的整包解壓,離開作用域即刪除 |
| 檔案系統 | `directory` / `filepath` | 搬移先試 rename(同磁碟區為原子操作),失敗退回複製 |
| 測試 | `hspec` + `hspec-discover` + `temporary` | 純函數窮舉 + 真實壓縮檔與真實 SQLite 的整合測試 |

環境相關的兩個硬性作法:呼叫 7-Zip 一律帶 UTF-8 主控台輸出旗標(Windows 預設字碼頁會把中文檔名變成亂碼);自行產生的檔案一律以 UTF-8 位元組寫出,不走 locale 編碼。

## 架構圖

```text
                        delivery(cli 組合根 / project 產出)
                              │           │
        ┌─────────────────────┘           └──────────────┐
        │ 掃描 / 中繼資料 / 命名 / 縮圖 / 筆記 / 搬遷        │ 單筆解壓
        ▼                                                 ▼
┌────────────────────────────────────────────┐   ┌──────────────────┐
│ reorg 套件                                 │   │                  │
│                                            │   │                  │
│  Snapshot ──► Plan ──► Render(dry-run)     │   │                  │
│  (唯一 IO)   (純函數)                       │   │                  │
│     │          │                           │   │                  │
│     │          └──► Execute ──► PackToml   │   │                  │
│     │               階段A/對帳/階段B/undo    │   │                  │
└─────┼───────────────┼──────────────────────┘   │                  │
      │               │ sha256File                │                  │
      │               │ archiveExtensions         │                  │
      ▼               ▼                           │                  │
┌────────────────────────────────────────────┐    │                  │
│ ingest 套件                                │    │                  │
│                                            │    │                  │
│  ┌── 純函數 ──────────┐  ┌── IO 殼 ───────┐│    │                  │
│  │ Hash              │  │ Scan           ││    │                  │
│  │ Handler(註冊表)   │◄─┤ Catalogue      ││    │                  │
│  │ Cluster           │◄─┤ ClusterDb      ││    │                  │
│  │ Thumb             │◄─┤ ThumbRun       ││    │                  │
│  │ Report            │  │ Notes          ││    │                  │
│  └───────────────────┘  └────────┬───────┘│    │                  │
└──────────────────────────────────┼────────┘    │                  │
                                   │ listEntries │ readEntry        │
                                   │ readEntry   │ extractAllTo     │
                                   ▼             ▼                  │
┌───────────────────────────────────────────────────────────────────┐
│ archive 套件                                                       │
│                          AssetDB.Archive                           │
│                     (格式派送 + 工具探索 + 目錄過濾)                 │
│                     ┌──────────┴──────────┐                        │
│              Archive.Zip            Archive.Sidecar                │
│            (ZIP 原生,讀檔頭)      (7-Zip:list / -so / 整包解壓)    │
│                     └──────────┬──────────┘                        │
│                        Archive.Types                               │
│                (格式 / 項目 DTO / 錯誤 / 路徑正規化)                 │
└───────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                    catalog(core:型別、ULID、命名文法、PathText
                            store:schema、FTS5、tokenizer)
```

## 開發階段

| 階段 | 內容 | 狀態 |
|---|---|---|
| 1 | `archive`:ZIP 原生列表與串流讀取;rar/7z sidecar | 完成 |
| 2 | 掃描與內容定址:走訪、SHA-256、blobs 去重、格式處理器 | 完成 |
| 2b | `pack.toml` 中繼資料的產生與讀取 | 完成 |
| 3 | 結構搬遷:dry-run → 執行 → 對帳 → 刪散檔 → undo | 完成(2026-08-09 已對真實素材庫執行;該次的一次性路徑規則已於 enhance-0009 退役) |
| 4 | 檔名叢集推論與命名規則套用 | 完成 |
| 6 | 縮圖 pipeline(內容定址快取) | 完成 |
| 10 | 筆記匯入與 links 關聯圖 | 完成 |
| 11 | 音效格式驗證(零核心表改動) | 完成(2026-08-11 驗證) |

階段編號沿用系統主架構的全域編號,缺號的階段屬於其他子系統。功能面全部完成並通過測試;後續變更走 `/enhance-design` 或 `/bugfix`。

## 功能規劃

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 1 | archive-access | ZIP 原生列表與串流讀取,rar/7z 交給 7-Zip sidecar | `AssetDB.Archive`、`Archive.Types`、`Archive.Zip`、`Archive.Sidecar` | - | F001 |
| 2 | content-addressed-scan | 目錄走訪、SHA-256 內容定址、格式處理器與中繼資料抽取 | `Ingest.Scan`、`Ingest.Hash`、`Ingest.Handler`、`Ingest.Report` | #1 | F002 |
| 3 | pack-metadata | pack.toml 的產生與讀取,讓資料庫可從磁碟重建 | `Ingest.Catalogue`、`Reorg.PackToml` | #2 | F003 |
| 4 | library-reorganize | 快照→計畫→執行→對帳→回退的安全搬遷機制 | `Reorg.Snapshot`、`Reorg.Plan`、`Reorg.Render`、`Reorg.Execute` | #3 | F004 |
| 5 | name-clustering | 檔名形狀抽象、叢集推論與命名規則套用 | `Ingest.Cluster`、`Ingest.ClusterDb` | #2 | F005 |
| 6 | thumbnail-pipeline | 縮圖產生與內容定址快取 | `Ingest.Thumb`、`Ingest.ThumbRun` | #2 | F006 |
| 7 | notes-and-links | Markdown 筆記匯入、front matter 解析與 links 關聯圖 | `Ingest.Notes` | - | F007 |

## Feature 契約卡

### archive-access

- **階段**:階段 1(壓縮檔存取)
- **負責模組**:`AssetDB.Archive`、`AssetDB.Archive.Types`、`AssetDB.Archive.Zip`、`AssetDB.Archive.Sidecar`
- **實作的 Level 2 介面**:`ArchiveTools` / `discoverTools` / `supportedFormats` / `describeTools`;`listEntries` / `readEntry` / `extractAllTo` / `prefersBulkExtraction`;`ArchiveFormat` / `detectFormat` / `formatExtensions` / `needsSidecar`;`ArchiveEntry`;`normalizeEntryPath` / `toNativeEntryPath`;`ArchiveError` / `renderArchiveError`;`SevenZip` / `findSevenZip` / `sevenZipCandidates` / `parseListing`
- **資料流管線段落**:管線 A 的 ①②A 中「listEntries / readEntry / 整包解壓」三個節點;管線 E 中的 `readEntry`;delivery 的 `project` 建專案時的單筆解壓
- **驗收標準**:
  - 三種副檔名(含大小寫混雜、路徑含空格與特殊字元)判定正確,不認得的回 `Nothing`
  - 列出 ZIP 內容不解壓任何資料,回傳的 `aePath` 一律 `/` 分隔且不含目錄項目
  - CRC32 與大小取自檔頭;`.7z` 的小數秒時間戳解析得出來
  - 中文檔名、含 `&` 與空格的檔名都讀得到內容;傳入反斜線路徑也找得到
  - 項目不存在回 `EntryNotFound`,壓縮檔損壞回 `MalformedArchive` —— 兩者可分辨
  - 缺 7-Zip 時 `SidecarNotFound` 列出找過的位置與安裝方式;`supportedFormats` 縮減為僅 ZIP
  - `.zip` 與 `.7z` 對目錄的兩種不同表示都判為目錄,不會漏判成檔案
- **明確不做**:不做寫入或建立壓縮檔;不解壓到磁碟(唯一例外是呼叫端明確要求的整包解壓);不做密碼保護壓縮檔;不快取項目清單(那是資料庫的事);不知道資料庫存在

### content-addressed-scan

- **階段**:階段 2(掃描與索引)
- **負責模組**:`AssetDB.Ingest.Scan`、`AssetDB.Ingest.Hash`、`AssetDB.Ingest.Handler`、`AssetDB.Ingest.Report`
- **實作的 Level 2 介面**:`ScanOptions` / `defaultScanOptions` / `ScanEvent` / `ScanReport` / `emptyReport` / `scanRoot`;`Sha256` / `unSha256` / `sha256Bytes` / `sha256File` / `crc32Hex`;`Handler` / `handlers` / `handlerFor` / `kindForPath` / `probeContent` / `archiveExtensions`;`renderEvent` / `renderReport` / `humanBytes`
- **資料流管線段落**:管線 A 全段(①、②A、②B 與報告輸出)
- **驗收標準**:
  - 壓縮檔內項目與散檔都進資料庫,每一筆都有 SHA-256(讀不到內容的項目除外,且計入 `srEntriesUnread`)
  - 相同內容跨來源只產生一筆 blob
  - 目錄不會被當成資源;系統自產的中繼檔案不被索引
  - 路徑一律 `/` 分隔;中文檔名完整保留
  - 素材包一律建成 `draft`;識別鍵用相對路徑,純中文檔名的素材包不會被靜默合併
  - 重掃時壓縮檔雜湊未變即跳過且不產生重複資源;`soRehash` 強制重算
  - 散檔兩條雜湊路徑(圖片/音效整檔讀、其餘串流)算出相同的雜湊與大小
  - 含自我指涉符號連結/junction 的目錄樹不無窮遞迴,且產生警告
  - 不認得的副檔名歸 `KSource` 而不是丟棄;`archiveExtensions` 與 `formatExtensions` 一致
  - PNG 取出尺寸/alpha/色數;WAV 取出取樣率/聲道數/長度,chunk 間夾雜其他 chunk 或奇數長度 padding 都不影響;壞掉的輸入回 `Nothing` 而不是爆炸
- **明確不做**:不做查詢與統計;不做語意標記;不刪除或搬移任何檔案;不做增量檔案監看;不對 kind 為非圖片/音效的散檔做內容探測;不猜授權與作者(那是 F003)

### pack-metadata

- **階段**:階段 2b(素材包中繼資料)
- **負責模組**:`AssetDB.Ingest.Catalogue`、`AssetDB.Reorg.PackToml`
- **實作的 Level 2 介面**:`Catalogue` / `PackEntry` / `parseCatalogue` / `ApplyResult` / `applyCatalogue`;`renderPackToml`
- **資料流管線段落**:管線 B 全段(解析 → 比對 → 作者/授權解析 → status 判定;以及反向的 `pack.toml` 產生)
- **驗收標準**:
  - 讀出所有欄位;可選欄位缺席不影響解析;缺必填欄位或語法錯誤回 `Left`
  - 以壓縮檔**基本檔名**比對,不是完整路徑
  - 授權與作者齊備時 status 升級為 `ready`,缺作者維持 `draft`
  - 引用不存在的授權名稱會回報在 `arMissingLicense`,不是靜靜忽略
  - 資料庫裡沒有的壓縮檔回報在 `arMissingArchive`
  - 作者只建立一次,已存在時補上先前缺的欄位但不覆蓋已有值
  - 重複套用不產生變化(冪等)
  - 產出的 `pack.toml` 含識別欄位、壓縮檔雜湊/大小/項目數;只寫檔名不寫路徑;缺欄位不產生空白 key;雙引號與反斜線跳脫;中文原樣保留
  - 沒有授權時不產生 `[license]` 區塊,而是留下顯眼說明且 status 為 `draft`
- **明確不做**:不刪除目錄裡沒提到的素材包;不定義授權條款本身(那是 catalog 的種子資料);不從檔名或資料夾名推測 vendor / kind / 授權;不做授權閘門的執行(那是 delivery 的 `project`)

### library-reorganize

- **階段**:階段 3(結構搬遷)
- **負責模組**:`AssetDB.Reorg.Snapshot`、`AssetDB.Reorg.Plan`、`AssetDB.Reorg.Render`、`AssetDB.Reorg.Execute`
- **實作的 Level 2 介面**:`Snapshot` / `PackRow` / `LooseRow` / `loadSnapshot`;`Op` / `Plan` / `PlanStats` / `planStats` / `buildPlan` / `targetDirFor`;`Verbosity` / `renderPlan` / `renderSummary`;`ApplyOptions` / `defaultApplyOptions` / `ApplyEvent` / `ApplyReport` / `applyPlan` / `undoBatch` / `listBatches`
- **資料流管線段落**:管線 D 全段;消費管線 B 的 `renderPackToml`、管線 A 的雜湊入口
- **驗收標準**:
  - 商業素材包依 vendor 分組;沒有 vendor 或 vendor 全為非 ASCII 時落在 `unknown/` 而非空目錄名或頂層;參考資料不進 `packs/`
  - 壓縮檔搬移後保留廠商原始檔名
  - 散檔一律 `OpKeep`,計畫裡不出現任何散檔的搬移或刪除;即使加上刪除旗標也不刪散檔
  - `draft` 的素材包會在警告裡被點名;全部就緒時沒有警告
  - 階段 A 跑完:壓縮檔在目標路徑、`pack.toml` 已寫出、散檔原封不動
  - 對帳:壓縮檔在新位置的 SHA-256 與資料庫紀錄一致;不符時中止且不執行任何刪除
  - 冪等:階段 A 跑過再跑一次會跳過已完成的搬移
  - 前置檢查:來源與目標都找不到(計畫過期)或同時存在(上次中斷)時拒絕動作
  - 回退:批次可整批倒回原位;含刪除的批次會明講刪除無法回退;批次列得出來
- **明確不做**:不做散檔的自動搬移或刪除規則(已退役,規則留在 git 歷史);規劃器不產生 `OpDelete`(型別與執行器保留為通用機制);不重算項目層級的雜湊(壓縮檔雜湊相同即證明內容完好);不在同一個旗標下綁定可回退與不可回退的動作;不清理空目錄

### name-clustering

- **階段**:階段 4(命名輔助)
- **負責模組**:`AssetDB.Ingest.Cluster`、`AssetDB.Ingest.ClusterDb`
- **實作的 Level 2 介面**:`Token` / `tokenize` / `fileShape`;`DirRole` / `dirRole` / `dirRoleText`;`ClusterKey` / `clusterKeyText` / `clusterKeyOf` / `Cluster` / `clusterBy`;`NumericRole` / `NameRule` / `applyRule`;`PackRef` / `listPacks` / `packPaths` / `packClusters` / `saveRule` / `loadRules` / `NamePreview` / `previewCluster` / `ApplyNames` / `applyNames`
- **資料流管線段落**:管線 C 全段
- **驗收標準**:
  - 同一系列的不同成員形狀相同(分群成立的前提);分隔符種類不影響形狀
  - 認得廠商的通用目錄慣例;`preview` 優先於 `sprites`;無可辨識目錄時為 `other`
  - 同形狀同角色歸為一群;副檔名不同就分開;依成員數遞減排序
  - 規則存進去讀得回來;同一叢集重複確認是覆寫而非新增
  - 只套用已確認叢集,其餘計入 `anSkipped`;沒有任何規則時什麼都不做
  - 撞名在寫入之前攔下,回報**所有**撞名而不是第一個,且一筆都不寫
  - 預覽不寫入任何東西
  - 產生的名稱一律通過 catalog 的命名文法驗證;純中文檔名回報錯誤而不是產生垃圾
  - 非末尾權杖的數字保留(否則同一系列的變體會撞名);三位數以上自動判為格號而非變體
- **明確不做**:不自動決定尾端數字是變體還是格號(`NumAuto` 只在形狀明確時下結論,其餘由人指定);不猜檔名裡缺失的主體;不做語意分類;不改檔案名稱(只寫資料庫的 `logical_name`);不做跨素材包的叢集合併

### thumbnail-pipeline

- **階段**:階段 6(縮圖)
- **負責模組**:`AssetDB.Ingest.Thumb`、`AssetDB.Ingest.ThumbRun`
- **實作的 Level 2 介面**:`ThumbSize` / `thumbSizes` / `thumbPath`(re-export 自 `AssetDB.PathText`)/ `makeThumb` / `renderThumb`;`ThumbOptions` / `defaultThumbOptions` / `ThumbReport` / `generateThumbs`
- **資料流管線段落**:管線 E 全段;消費 F001 的 `readEntry`
- **驗收標準**:
  - 輸出永遠是正方形畫布;非正方形來源置中而不拉伸
  - 放大用最近鄰且取整數倍:原始像素變成乾淨方塊,不產生中間色、不出現半個像素
  - 縮小用面積平均:細節不會整片消失
  - 吃真的 PNG 吐真的 PNG;壞掉的輸入回 `Left` 而不是爆炸
  - 快取路徑以雜湊前兩碼分層;不同尺寸不同檔名
  - 以 blob 的 SHA-256 去重,同一份內容只產生一次縮圖
  - 已有全部尺寸且未強制時跳過並計入 `trSkipped`
  - 失敗寫回 `thumb_status = 'failed'` 與錯誤訊息,重跑不反覆重試
- **明確不做**:不產生非圖片 kind 的縮圖;不輸出 WebP 或其他需要外部編碼器的格式;不做動畫預覽;不提供縮圖的讀取端 API(那是 delivery 的 `server`);不自行定義定址規則(唯一實作在 catalog)

### notes-and-links

- **階段**:階段 10(知識與關聯)
- **負責模組**:`AssetDB.Ingest.Notes`
- **實作的 Level 2 介面**:`NoteDoc` / `parseFrontMatter` / `frontJson`;`importNotes` / `listNotes` / `reindexNotes`;`tableOf` / `linkEntities` / `entityLinks`
- **資料流管線段落**:管線 F 全段
- **驗收標準**:
  - 讀 front matter 的 `title`;沒有時取第一個 Markdown 標題;兩者都沒有時退回檔名;標題的引號脫掉
  - front matter 不會混進內文;所有 `key: value` 都解析得出來
  - `---` 後直接 EOF 或只有換行的內容都正確解析
  - 含反斜線與控制字元的值產生**合法** JSON;空 front matter 是空物件
  - 只匯入 `.md` / `.markdown`;以來源路徑為識別鍵,重複匯入是更新而不是新增;可依 kind 篩選
  - 中文筆記進 CJK bigram 索引(對中文而言那是主力而非備援)
  - 未知實體型別回 `Left` 帶友善訊息而非崩潰;五種已知型別對應到資料表
  - 邊建立後雙向都查得到;重複建立同一條邊是無操作;`entityLinks` 回傳的對端識別是 ULID 而非內部整數 id
- **明確不做**:不支援巢狀 YAML(只支援純量 `key: value`);不渲染 Markdown;不做筆記的查詢與檢索(那是 catalog 的 `store`);不遞迴子目錄;不刪除來源已消失的筆記;不做關聯圖的傳遞閉包或路徑查詢
