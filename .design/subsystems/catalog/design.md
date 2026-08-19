---
id: catalog
type: subsystem
title: catalog
description: 定義領域型別、命名文法、Manifest schema 與 SQLite 儲存/檢索,是全系統的型別與資料基座
status: active
created: 2026-08-19
updated: 2026-08-19
parent: system
related-adr: [ADR-001, ADR-003, ADR-004, ADR-006, ADR-008]
---

# Catalog 子系統架構

## 定位與範圍

Catalog 是依賴圖的**底部**。它由 `assetdb-core` 與 `assetdb-store` 兩個 cabal 套件組成:
`core` 提供不含 IO 的領域型別與純函數規則,`store` 提供 SQLite 的 schema、遷移、索引與查詢。
其他三個子系統(ingest / ai-tagging / delivery)都依賴 catalog,catalog **不依賴任何子系統**。

`core` 還有一個系統外的消費者:**遊戲本體**。遊戲專案會直接 `import AssetDB.Manifest`
來解析自己 repo 裡的 `assets/manifest.json`,兩邊共用同一份型別,所以 schema 改動會在
編譯期爆炸而不是在執行期變成黑畫面。這也是 `core` 刻意保持零重量級依賴的理由。

### 承接的職責

- 全系統共用的領域列舉與其**穩定文字表示**(ADR-008),含 JSON 與 SQLite 兩側的編解碼
- 永久識別碼 ULID 的產生、編碼、解碼與取值(ADR-003)
- 檔案命名文法:建構、渲染、解析、驗證,以及供 ingest 使用的文字正規化基本操作(ADR-004)
- `assets/manifest.json` 的 schema 定義與序列化(定義,不含產生)
- SQLite 連線設定(PRAGMA)、版本化 migration 的執行器與全部 DDL(ADR-006)
- FTS5 trigram + CJK unicode61 bigram 雙索引的建立、填充與查詢展開
- 條件組裝的檢索與 facet 計數

### 明確不做什麼

- **不做啟發式推導**。「這個廠商檔名該對應到哪個 kind/domain」牽涉路徑規則與人工覆寫,
  屬於 ingest。命名模組只負責「給定部位產生名稱」與「給定名稱拆回部位」。
- **不讀寫檔案系統的素材**。core 完全無 IO;store 只碰自己那一個 SQLite 檔。壓縮檔存取、
  掃描、雜湊、縮圖產生全部在 ingest。
- **不產生 manifest**。catalog 定義 `Manifest` 型別與它的 JSON 形狀;實際蒐集素材、
  過授權閘門、寫檔的是 delivery 的 `project` 套件。
- **不定義業務用的 repository 層**。store 只交付 `Connection` 與檢索查詢,各子系統的
  資料表讀寫 SQL 由該子系統自己持有(如 ingest 的掃描寫入、ai-tagging 的建議表)。
- **不填充 notes 全文索引**。catalog 建立 `notes_fts` / `notes_cjk` 的 DDL 並提供
  n-gram 展開函式,實際灌入由 ingest 的 notes 匯入負責。
- **不呼叫 LLM、不做影像解碼、不啟 HTTP**。

---

## 對外契約(Public Interface & DTOs)

以下全部是套件 `exposed-modules` 的實際 export。

### `AssetDB.Types` —— 領域列舉與文字編碼

```haskell
class (Eq a, Enum a, Bounded a, Show a) => TextEnum a where
  toTextEnum :: a -> Text

textEnumValues :: TextEnum a => [a]
parseTextEnum  :: TextEnum a => Text -> Either Text a
```

列舉型別(全部是 `TextEnum` 實例,並附 `ToJSON` / `FromJSON`):

| 型別 | 建構子 | 文字表示 |
|---|---|---|
| `AssetKind` | `KImage KAudio KFont KLevel KShader KDoc KSource KArchive` | `image audio font level shader doc source archive` |
| `KindPrefix` | `PSpr PTex PAtlas PUi PFnt PSfx PBgm PVo PLvl PShd PSrc PDoc` | `spr tex atlas ui fnt sfx bgm vo lvl shd src doc` |
| `AssetStatus` | `StActive StExcluded StMissing StArchived` | `active excluded missing archived` |
| `PackStatus` | `PkDraft PkReady` | `draft ready` |
| `AiDisclosure` | `AiUnknown AiNone AiAssisted AiGenerated` | `unknown none assisted generated` |
| `CopyMode` | `CmCopy CmHardlink` | `copy hardlink` |
| `TagSource` | `TsManual TsRule TsInferred` | `manual rule inferred` |
| `EntityType` | `EAsset EProject ENote ECollection EPack` | `asset project note collection pack` |
| `LinkRel` | `RelUses RelDerivesFrom RelVariantOf RelSimilarTo RelDocuments RelPromotes` | `uses derives-from variant-of similar-to documents promotes` |
| `NoteKind` | `NkKnowledge NkMarketing NkDecision NkReference` | `knowledge marketing decision reference` |

分類軸的映射函式:

```haskell
prefixKind     :: KindPrefix -> AssetKind   -- 多對一
kindPrefixes   :: AssetKind -> [KindPrefix] -- 反向,掃描時限縮推導範圍
kindDefaultDir :: AssetKind -> Text         -- 專案 assets/ 底下的預設落點
```

### `AssetDB.Id` —— 永久識別碼

```haskell
data ULID                                       -- 建構子不外露;Eq / Ord / Show / ToJSON / FromJSON
unULID        :: ULID -> Text
newULID       :: IO ULID
mkULID        :: Integer -> Integer -> Either Text ULID   -- 毫秒時間戳 + 80 位元亂數,純函數
renderULID    :: ULID -> Text                             -- 26 字元 Crockford Base32
parseULID     :: Text -> Either Text ULID                 -- 寬鬆:接受小寫,I/L→1、O→0
ulidTimestamp :: ULID -> UTCTime
ulidRandomness :: ULID -> Integer
```

不變量:`parseULID . renderULID == Right`;字典序等同時間序。

### `AssetDB.Naming` —— 命名文法

```haskell
data Segment                       -- 已保證 ^[a-z0-9]+(-[a-z0-9]+)*$;建構子不外露
segmentText :: Segment -> Text
mkSegment   :: Text -> Either NameError Segment

data LogicalName                   -- ToJSON / FromJSON(FromJSON 走 validateLogicalName)
logicalNameText :: LogicalName -> Text

data NameParts = NameParts
  { npKind    :: KindPrefix
  , npDomain  :: Segment           -- 開放,不比對任何詞彙表
  , npSubject :: Segment
  , npVariant :: Maybe Segment
  , npState   :: Maybe Segment
  , npIndex   :: Maybe Int         -- 渲染時補零到三位
  }

data NameError
  = EmptySegment | BadSegment Text | NoAsciiContent Text | TooLong Int Text
  | UnknownKindPrefix Text | TooFewSegments Int Text | AmbiguousTrailing [Text] Text
  | SubjectLooksLikeModifier Text | IndexOutOfRange Int
renderNameError :: NameError -> Text

data NamingVocab = NamingVocab { nvStates :: Set Text, nvVariants :: Set Text }
defaultVocab :: NamingVocab        -- 全庫唯一真相(B001)

mkLogicalName       :: NamingVocab -> NameParts -> Either NameError LogicalName
parseLogicalName    :: NamingVocab -> Text -> Either NameError NameParts
validateLogicalName :: Text -> Either NameError LogicalName   -- 以 defaultVocab 驗形
renderParts         :: NameParts -> Either NameError Text

variantFromNumber :: Int -> Maybe Segment          -- 0..99,補零兩位
indexSegment      :: Int -> Either NameError Segment -- 0..999,補零三位
isVariantShaped   :: Text -> Bool
isIndexShaped     :: Text -> Bool

normalizeSegment    :: Text -> Either NameError Segment   -- 給 ingest:任意廠商文字 → 合法分段
splitCamel          :: Text -> [Text]
splitTrailingNumber :: Text -> (Text, Maybe Text)

maxLogicalNameLength :: Int        -- 64
```

名稱形狀:`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`。
不變量:`parseLogicalName vocab . renderParts == 原 NameParts`(對所有 `mkLogicalName` 接受的組合)。

### `AssetDB.Manifest` —— 專案 manifest schema(DTO)

```haskell
currentSchemaVersion :: Int        -- 1;只在破壞相容時遞增

data Manifest = Manifest
  { mSchemaVersion :: Int, mProject :: Text, mGeneratedAt :: UTCTime
  , mAssets :: [ManifestAsset], mPacks :: [ManifestPack], mLicenses :: [ManifestLicense] }

data ManifestAsset = ManifestAsset
  { maId :: ULID, maKey :: LogicalName, maPath :: Text, maKind :: AssetKind
  , maSha256 :: Text, maPack :: Maybe Text, maLicense :: Maybe Text, maMeta :: Value }

data ManifestPack    = ManifestPack { mpName, mpVendor, mpSourceUrl, mpVersion, mpLicense }
data ManifestLicense = ManifestLicense
  { mlName :: Text, mlCommercial :: Bool, mlAttributionRequired :: Bool, mlNotes :: Maybe Text }

newtype AssetKey = AssetKey { unAssetKey :: Text }

manifestIndex :: Manifest -> Map Text ManifestAsset
lookupAsset   :: LogicalName -> Manifest -> Maybe ManifestAsset

data ImageMeta = ImageMeta { imWidth, imHeight :: Int, imHasAlpha :: Bool, imColorCount :: Maybe Int }
data AudioMeta = AudioMeta { amDurationMs, amSampleRate, amChannels :: Int }
imageMeta :: ManifestAsset -> Maybe ImageMeta
audioMeta :: ManifestAsset -> Maybe AudioMeta
```

JSON 欄位名全部手寫,不由 Generic 前綴剝除規則間接決定。
`FromJSON Manifest` 在 `schemaVersion` 不等於 `currentSchemaVersion` 時**直接失敗**。
`maMeta` 是開放的 `Value`,kind 專屬欄位透過型別化存取函式取用。

### `AssetDB.PathText` —— 跨套件共用的路徑/文字定址(G-E002)

```haskell
leafOf      :: Text -> Text        -- '/' 分隔路徑的最後一段
extensionOf :: Text -> Text        -- 小寫副檔名含點號;無副檔名回空字串
slugify     :: Text -> Text        -- 路徑安全識別字串;純中文會得到空字串,呼叫端須自備退路

data ThumbSize = Thumb128 | Thumb512
thumbSizes   :: [ThumbSize]
thumbSizePx  :: ThumbSize -> Int
thumbSizeTag :: ThumbSize -> Text
thumbPath    :: FilePath -> Text -> ThumbSize -> FilePath   -- 快取根 → sha256 → 尺寸
```

`thumbPath` 是**縮圖快取的唯一定址規則**:產生端(ingest)與讀取端(ai-tagging、delivery)
必須共用這一個函式,否則症狀是縮圖找不到卻不報錯。

### `AssetDB.Console`

```haskell
setupConsole :: IO ()              -- stdout/stderr UTF-8 + Windows console code page 65001
```

### `AssetDB.Store` —— 連線與初始化

```haskell
data Store = Store { storeConn :: Connection, storePath :: FilePath }

openStore         :: FilePath -> IO Store    -- 建目錄、開檔、套 PRAGMA;不跑 migration
openStoreInMemory :: IO Store                -- 測試用,不套 WAL
withStore         :: FilePath -> (Store -> IO a) -> IO a
initSchema        :: Store -> IO [Migration] -- 套用待執行的 migration,回傳這次跑了哪些
storeVersion      :: Store -> IO Int
-- 另重新匯出 module AssetDB.Store.Migrate
```

PRAGMA 一律在此設定:`foreign_keys=ON`、`journal_mode=WAL`(檔案庫)、`synchronous=NORMAL`、
`busy_timeout=5000`、`optimize`。這是全系統唯一的設定點。

### `AssetDB.Store.Migrate` —— 遷移執行器(ADR-006)

```haskell
data Migration = Migration { migVersion :: Int, migName :: Text, migStatements :: [Query] }

runMigrations   :: Connection -> [Migration] -> IO [Migration]   -- 冪等
currentVersion  :: Connection -> IO Int                          -- 全新資料庫回 0
appliedVersions :: Connection -> IO [(Int, Text, Text)]          -- (version, name, applied_at)

data MigrationError
  = MigrationsOutOfOrder [Int] | DatabaseNewerThanCode Int Int | MigrationFailed Int Text Text
  deriving Show                    -- instance Exception

lit :: Text -> Query               -- 值 → SQL 字面值(單引號加倍)
num :: Int  -> Query
```

只有正向 migration。每個 migration 各自包在一個交易裡,失敗只回滾自己那一個。

### `AssetDB.Store.Schema` —— DDL

```haskell
migrations    :: [Migration]       -- 001 初始 schema / 002 notes source_path 唯一鍵
                                   -- 003 AI 分類詞彙與建議表 / 004 naming_vocab 退場
schemaVersion :: Int               -- 程式端已知的最新版本
```

資料表(供其他子系統讀寫,catalog 只負責建立與約束):
`roots` `authors` `licenses` `packs` `archives` `blobs` `assets` `categories`
`asset_categories` `tags` `asset_tags` `collections` `collection_items` `links`
`projects` `project_assets` `notes` `name_clusters` `moves` `events`
`ai_runs` `ai_suggestions`,以及四張 FTS5 虛擬表
`assets_fts` `assets_cjk` `notes_fts` `notes_cjk`。

### `AssetDB.Store.Orphans` —— 型別橋接

只匯出 instance,沒有值。目前橋接的型別是:`AssetKind`、`KindPrefix`、`AssetStatus`、
`CopyMode`、`TagSource`、`EntityType`、`LinkRel`、`NoteKind`、`ULID`、`LogicalName` 的
`ToField` / `FromField`。列舉一律以文字進出資料庫;`LogicalName` 在**讀取時**也會重新驗證。

> 注意:`PackStatus` 與 `AiDisclosure` 雖然是 `TextEnum` 實例,但**沒有** `ToField` /
> `FromField` instance,`packs.status` 與 `packs.ai_disclosure` 目前以原始文字讀寫。

### `AssetDB.Store.Tokenize` —— 中日韓 n-gram 與 FTS5 跳脫

```haskell
data CjkIndex = CjkIndex { cjkUni :: Text, cjkBi :: Text }
cjkIndex     :: Text -> CjkIndex
cjkUnigrams  :: Text -> Text       -- 空白分隔的單字元
cjkBigrams   :: Text -> Text       -- 空白分隔的重疊雙字元,不跨越非中日韓字元
cjkMatchExpr :: Text -> Maybe Text -- 查詢側;不含中日韓時回 Nothing
hasCJK       :: Text -> Bool
isCJK        :: Char -> Bool
ftsQuoted    :: Text -> Text       -- 讓 * : ^ - ( ) " 失去運算子意義
ftsPhrase    :: Text -> Text       -- 空白分隔的 token 串 → 片語查詢
```

**不變量:寫入側與查詢側必須共用這個模組。** 這是雙索引設計唯一需要守住的一致性。

### `AssetDB.Store.Index` —— 索引填充

```haskell
reindexFts  :: Connection -> IO Int          -- 全量重建 assets_fts + assets_cjk,回傳列數
ftsRowCount :: Connection -> IO (Int, Int)   -- (assets_fts, assets_cjk)
ftsStale    :: Connection -> IO Bool         -- 索引是否落後於 assets
```

索引來源是跨表 JOIN(資源 + 素材包 + 作者 + 標籤),因此是 contentless FTS5,
沒有觸發器可以自動維護,只能全量重建。`status = 'archived'` 的資源不進索引。

### `AssetDB.Store.Search` —— 檢索與 facet

```haskell
data SearchQuery = SearchQuery
  { sqText :: Maybe Text
  , sqKinds, sqPacks, sqAuthors, sqVendors, sqCategories :: [Text]
  , sqCommercialOnly, sqNamedOnly, sqIncludeExcluded, sqIncludeReference :: Bool
  , sqLimit, sqOffset :: Int }
emptyQuery :: SearchQuery            -- sqLimit = 50(函式庫層保守預設,各入口會覆寫)

data SearchHit = SearchHit
  { hitUlid :: Text, hitLogical :: Maybe Text, hitOriginal :: Text, hitKind :: Text
  , hitPack :: Maybe Text, hitAuthor :: Maybe Text, hitPath :: Text, hitSha :: Maybe Text }
  -- instance FromRow

data FacetCounts = FacetCounts
  { fcKinds, fcPacks, fcAuthors, fcVendors, fcCategories :: [(Text, Int)] }

search      :: Connection -> SearchQuery -> IO [SearchHit]
searchCount :: Connection -> SearchQuery -> IO Int
facetCounts :: Connection -> SearchQuery -> IO FacetCounts
```

語意保證:`sqCategories` 是**精確比對**,不做前綴展開;facet 計數在算某個 facet 的分佈時
會**排除該 facet 自己的條件**,否則選定之後側欄就只剩下已選項。

---

## 內部模組劃分(Internal Modules)

### `assetdb-core`(純函數,零 IO,遊戲本體也依賴)

| 模組 | 單一職責 |
|---|---|
| `AssetDB.Types` | 領域列舉與 `TextEnum` 文字編碼協定;JSON 編解碼一律走它 |
| `AssetDB.Id` | ULID 的建構、Crockford Base32 編解碼、時間戳/亂數取值 |
| `AssetDB.Naming` | 命名文法:分段驗證、名稱建構/渲染/解析,以及廠商文字的正規化基本操作 |
| `AssetDB.Manifest` | `assets/manifest.json` 的型別與手寫序列化、版本把關、查表 |
| `AssetDB.PathText` | 跨套件共用的路徑分解、slug 化與縮圖快取定址 |
| `AssetDB.Console` | 終端機位元組層設定(唯一有 IO 的核心模組) |

### `assetdb-store`(SQLite,知道 SQL;上面的層不該知道)

| 模組 | 單一職責 |
|---|---|
| `AssetDB.Store` | 連線生命週期與 PRAGMA 的唯一設定點;初始化入口 |
| `AssetDB.Store.Migrate` | 版本化 migration 的執行器與 SQL 字面值組裝 |
| `AssetDB.Store.Schema` | 全部 DDL 與已查證的種子資料,以 migration 清單表達 |
| `AssetDB.Store.Orphans` | core 型別 ↔ SQLite 欄位的橋接 instance |
| `AssetDB.Store.Tokenize` | 中日韓 n-gram 展開與 FTS5 語法跳脫(寫入與查詢共用) |
| `AssetDB.Store.Index` | 兩張 assets 全文索引的全量重建與落後偵測 |
| `AssetDB.Store.Search` | 條件組裝查詢、分頁與 facet 計數 |

依賴方向:`Store` → `Migrate` + `Schema` → `Migrate`;`Index` → `Tokenize`;
`Search` → `Tokenize`;`Orphans` → core。`Tokenize` 不依賴任何 store 內部模組。

---

## 資料流管線(Data Flow Pipeline)

### 管線 A:命名(建構方向)

```text
廠商原始檔名 (ingest 提供)
  → [正規化] normalizeSegment / splitCamel / splitTrailingNumber → Segment
  → [組裝]   NameParts(kind/domain/subject/variant/state/index)
  → [驗證]   mkLogicalName vocab —— 主體不得長得像修飾詞、長度 ≤ 64
  → LogicalName
  → [持久化] ToField LogicalName → assets.logical_name(UNIQUE)
```

### 管線 B:命名(解析方向)

```text
Text(來自 JSON、資料庫或 CLI)
  → [驗形] validateLogicalName(以 defaultVocab)→ LogicalName
  → [拆解] parseLogicalName vocab:由右往左剝 index → state → variant,剩下的是主體
  → NameParts
```

不變量 `parse ∘ render == id` 由「主體不得佔用修飾詞形狀」這條建構期檢查保證。

### 管線 C:儲存初始化

```text
FilePath
  → openStore:建目錄 → 開檔 → 套 PRAGMA(foreign_keys / WAL / synchronous / busy_timeout)
  → Store
  → initSchema:讀 schema_migrations 的最高版本
      → 版本高於程式所知 → 拋 DatabaseNewerThanCode
      → 版本號非遞增     → 拋 MigrationsOutOfOrder
      → 逐一套用待執行的 migration,各自一個交易,成功即寫入 schema_migrations
  → [Migration](這次實際跑了哪些)
```

### 管線 D:全文索引填充

```text
assets ⋈ packs ⋈ authors ⋈ asset_tags ⋈ tags(WHERE status <> 'archived')
  → 每列取出 logical_name / original_name / entry_path|rel_path / tags / pack / author
  → [清空] 兩張 contentless FTS5 表(delete-all 指令)
  → [寫入 trigram] assets_fts,rowid = assets.id
  → [判定] hasCJK
      → 含中日韓 → cjkIndex 展開 uni/bi 兩欄 → assets_cjk,共用同一個 rowid
      → 不含     → 不寫(空列會讓 rowid 對不上,也讓統計失去意義)
  → 寫入列數
```

### 管線 E:檢索與 facet

```text
SearchQuery
  → [條件組裝] 每個欄位各自產生一個具名條件片段與其參數
       文字條件 → cjkMatchExpr 判定走哪條索引
                   Nothing → 只走 trigram(ftsQuoted 後 MATCH)
                   Just    → trigram OR cjk 聯集
       分類條件 → 以子查詢做成員判定(避免多對多 JOIN 灌大列數)
       預設條件 → status='active'、素材包 kind='packs'(除非明確要求納入)
  → [組裝 WHERE] 全部條件以 AND 連接
  → search      → ORDER BY(已命名優先 → logical_name → original_name)→ LIMIT/OFFSET → [SearchHit]
  → searchCount → COUNT(*)
  → facetCounts → 對每個 facet 重跑一次:**先移除該 facet 自己的條件**,再 GROUP BY
                  (分類另走一份 JOIN 查詢,並以 COUNT(DISTINCT) 去重)
```

### 管線 F:manifest 序列化

```text
delivery 蒐集的素材集合
  → Manifest{ mSchemaVersion = currentSchemaVersion, ... }
  → toJSON(手寫欄位名)→ assets/manifest.json
                        ↓
              遊戲本體 fromJSON
                → schemaVersion 不符 → 直接失敗並說明該跑 assetdb sync
                → 相符 → Manifest → manifestIndex / lookupAsset → ManifestAsset
                                   → imageMeta / audioMeta 取型別化視圖
```

---

## 模組間公開介面(Module Interfaces)

catalog **內部**模組之間、以及其他子系統呼叫進來的介面:

| 提供者 | 消費者 | 介面 |
|---|---|---|
| `AssetDB.Types` | 全系統 | `TextEnum` 協定 + 十個列舉的 `toTextEnum` / `parseTextEnum` |
| `AssetDB.Types` | `AssetDB.Naming` | `KindPrefix`、`parseTextEnum` 解析名稱首段 |
| `AssetDB.Id` | `AssetDB.Manifest`、store、ingest、delivery | `ULID`、`newULID`、`renderULID` / `parseULID` |
| `AssetDB.Naming` | ingest | `normalizeSegment` / `splitCamel` / `splitTrailingNumber`、`mkLogicalName` |
| `AssetDB.Naming` | delivery、store | `LogicalName`、`logicalNameText`、`validateLogicalName` |
| `AssetDB.Manifest` | delivery、遊戲本體 | `Manifest` 及其 DTO、`currentSchemaVersion`、`manifestIndex` / `lookupAsset` |
| `AssetDB.PathText` | ingest、ai-tagging、delivery | `slugify`、`leafOf` / `extensionOf`、`thumbPath` / `ThumbSize` |
| `AssetDB.Console` | delivery(cli / server 進入點) | `setupConsole` |
| `AssetDB.Store` | 全系統 | `Store`、`openStore` / `withStore` / `openStoreInMemory`、`initSchema`、`storeVersion` |
| `AssetDB.Store.Migrate` | `AssetDB.Store`、`AssetDB.Store.Schema` | `Migration`、`runMigrations`、`currentVersion`、`lit` / `num` |
| `AssetDB.Store.Schema` | `AssetDB.Store` | `migrations`、`schemaVersion` |
| `AssetDB.Store.Orphans` | 任何用 `sqlite-simple` 讀寫核心型別的模組 | `ToField` / `FromField` instance(以 `import ... ()` 取得) |
| `AssetDB.Store.Tokenize` | `AssetDB.Store.Index`、`AssetDB.Store.Search`、ingest(notes 索引) | `cjkIndex` / `cjkMatchExpr` / `hasCJK` / `ftsQuoted` / `ftsPhrase` |
| `AssetDB.Store.Index` | delivery(CLI reindex / doctor) | `reindexFts`、`ftsRowCount`、`ftsStale` |
| `AssetDB.Store.Search` | delivery(server API / CLI search) | `SearchQuery` / `emptyQuery`、`search` / `searchCount` / `facetCounts` |

---

## 使用的技術

沿用主架構:Haskell(GHC 9.14.1 / cabal),SQLite。本子系統特有的選型:

- **`assetdb-core` 刻意零重量級依賴**(`aeson` / `text` / `containers` / `time` / `random` /
  `filepath` / `bytestring`,Windows 另加 boot package `Win32`)。理由是遊戲本體也依賴它,
  不能為了持久化把 `sqlite-simple` 拖進遊戲的相依樹。
- **ULID 自行實作**而非引入 `ulid` 套件:編解碼是純函數,可用 QuickCheck 打 round-trip,
  省掉一個可能在 GHC 新版落後的相依。
- **列舉存穩定文字而非序號**(ADR-008):序號會在有人重排建構子時無聲損毀資料庫。
- **`ToField` / `FromField` 是刻意的 orphan instance**:core 不該知道 SQLite,
  `sqlite-simple` 不可能知道我們的型別,而 store 兩邊都擁有。
- **FTS5 雙索引**:`trigram` 給 ASCII 子字串與三字以上中文;`unicode61` + 自製重疊 bigram
  給兩字中文詞(FTS5 的 MATCH 最少三字元是硬限制,兩字中文詞在 trigram 索引搜不到)。
  兩張表共用 rowid,結果可直接聯集。
- **contentless FTS5**:索引內容來自跨表 JOIN,不是單一來源表,因此不能用 external content,
  也沒有觸發器可用,只能全量重建。
- **只有正向 migration**(ADR-006):單機 SQLite 的回退正確作法是從備份還原檔案,
  而不是跑一段幾乎不會被測到的反向 SQL。

---

## 架構圖

```text
                       ┌──────────── 對外契約入口 ────────────┐
   ingest / ai-tagging / delivery / 遊戲本體 都從這裡進來
                       └───────────────┬──────────────────────┘
                                       │
╔══════════════════════════════ catalog ═══════════════════════════════╗
║                                                                       ║
║  ┌─────────────────── assetdb-core(純函數,零 IO)───────────────┐  ║
║  │                                                                 │  ║
║  │   AssetDB.Types ───────────┐                                    │  ║
║  │     TextEnum / AssetKind    │ KindPrefix                        │  ║
║  │     KindPrefix / 狀態列舉   ▼                                    │  ║
║  │                        AssetDB.Naming                            │  ║
║  │   AssetDB.Id ───┐        Segment / LogicalName / NameParts       │  ║
║  │     ULID        │        defaultVocab / normalizeSegment         │  ║
║  │                 │              │                                 │  ║
║  │                 ▼              ▼ LogicalName                     │  ║
║  │            AssetDB.Manifest ◀──┘                                 │  ║
║  │              Manifest / ManifestAsset / ImageMeta / AudioMeta    │  ║
║  │                                                                  │  ║
║  │   AssetDB.PathText          AssetDB.Console                      │  ║
║  │     slugify / thumbPath       setupConsole                       │  ║
║  └──────────────────────────────┬───────────────────────────────────┘  ║
║                                 │ 型別                                 ║
║  ┌──────────────────────────────▼─────── assetdb-store ────────────┐  ║
║  │                                                                  │  ║
║  │   AssetDB.Store.Orphans      AssetDB.Store.Schema                │  ║
║  │     ToField / FromField        migrations 001..004               │  ║
║  │                                     │                            │  ║
║  │   AssetDB.Store.Migrate ◀───────────┘                            │  ║
║  │     Migration / runMigrations / lit / num                        │  ║
║  │            ▲                                                     │  ║
║  │            │                                                     │  ║
║  │   AssetDB.Store ── openStore / initSchema / storeVersion         │  ║
║  │            │  Store{storeConn, storePath}                        │  ║
║  │            │                                                     │  ║
║  │   AssetDB.Store.Tokenize ──┬──▶ AssetDB.Store.Index              │  ║
║  │     cjkIndex / cjkMatchExpr│      reindexFts / ftsStale          │  ║
║  │     ftsQuoted / ftsPhrase  └──▶ AssetDB.Store.Search             │  ║
║  │                                   search / searchCount           │  ║
║  │                                   facetCounts                    │  ║
║  └──────────────────────────────┬───────────────────────────────────┘  ║
╚═════════════════════════════════│═════════════════════════════════════╝
                                  ▼
                        assetdb.sqlite(WAL)
              assets / packs / blobs / categories / links …
              assets_fts(trigram)  assets_cjk(unicode61 bigram)
              notes_fts             notes_cjk        ← DDL 在此,填充在 ingest
```

---

## 開發階段

對應主架構的開發階段表:

| 主架構階段 | 內容 | catalog 的份 |
|---|---|---|
| 0 | `core`:型別、ULID、命名文法、Manifest schema | F001 / F002 / F003 |
| 0b | `store`:schema、migrations、FTS5 + 中日韓 n-gram | F004 / F005 |
| 5 | FTS5 + facet 查詢 | F006(CLI `search` 那半屬 delivery) |

全部階段狀態為**已完成並通過測試**。`cabal test all` 中 `assetdb-core-test`
與 `assetdb-store-test` 兩個套件對應本子系統。

---

## 功能規劃

### 階段 0:領域模型

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 1 | domain-types-and-ulid | 領域列舉的穩定文字表示與 ULID 永久識別碼 | `AssetDB.Types`、`AssetDB.Id` | - | F001 |
| 2 | naming-grammar | 檔案命名文法、詞彙表與 `LogicalName` 驗證 | `AssetDB.Naming` | #1 | F002 |
| 3 | manifest-schema | 專案 manifest 的 schema 與序列化 | `AssetDB.Manifest` | #1, #2 | F003 |

### 階段 0b:儲存層

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 4 | sqlite-schema-migrations | SQLite schema DDL 與版本化 migration | `AssetDB.Store`、`AssetDB.Store.Migrate`、`AssetDB.Store.Schema`、`AssetDB.Store.Orphans` | #1, #2 | F004 |
| 5 | fts-cjk-index | FTS5 trigram + CJK bigram 雙索引與重建 | `AssetDB.Store.Tokenize`、`AssetDB.Store.Index` | #4 | F005 |

### 階段 5:檢索

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 6 | search-and-facets | 條件組裝查詢與 facet 計數 | `AssetDB.Store.Search` | #4, #5 | F006 |

---

## Feature 契約卡

### domain-types-and-ulid

- **階段**:階段 0(領域模型)
- **負責模組**:`AssetDB.Types`、`AssetDB.Id`
- **實作的 Level 2 介面**:
  - `AssetDB.Types` 全部條目:`TextEnum` / `textEnumValues` / `parseTextEnum`;
    `AssetKind` `KindPrefix` `AssetStatus` `PackStatus` `AiDisclosure` `CopyMode`
    `TagSource` `EntityType` `LinkRel` `NoteKind` 及其 `ToJSON` / `FromJSON`;
    `prefixKind` / `kindPrefixes` / `kindDefaultDir`
  - `AssetDB.Id` 全部條目:`ULID` / `unULID` / `newULID` / `mkULID` /
    `renderULID` / `parseULID` / `ulidTimestamp` / `ulidRandomness` 及 JSON instance
  - 模組間介面表中「`AssetDB.Types` → 全系統」「`AssetDB.Id` → `AssetDB.Manifest`、store」兩列
- **資料流管線段落**:是所有管線的**型別基礎**,本身不構成管線。ULID 在管線 A 的持久化端
  與管線 F 的 `maId` 欄位出現;列舉的文字表示是管線 C 建立的 CHECK 約束值域來源。
- **驗收標準**:
  - 每個列舉的 `parseTextEnum . toTextEnum` 對所有建構子回傳 `Right` 原值;
    未知字串回傳的 `Left` 訊息列得出可用值
  - JSON 表示與 SQLite 表示是同一組字串(單一真相)
  - `renderULID` 永遠 26 字元,只用 Crockford 字母表(不含 I/L/O/U)
  - `parseULID . renderULID == Right`;接受小寫,I/L 視為 1、O 視為 0
  - 拒絕長度不符、字母表外字元、超出 128 位元(首字元大於 `7`)的輸入
  - `mkULID` 拒絕超出 48 位元的時間戳與超出 80 位元的亂數
  - ULID 的字典序與時間序一致
  - `prefixKind` 的每個前綴都映射得到 `AssetKind`;`kindPrefixes` 是其反向且封閉
- **明確不做**:不決定某個檔案該是哪個 kind(那是 ingest 的推導);ULID 不保證同毫秒
  單調遞增(80 位元亂數在單機寫入速率下碰撞機率遠低於磁碟出錯)。

### naming-grammar

- **階段**:階段 0(領域模型)
- **負責模組**:`AssetDB.Naming`
- **實作的 Level 2 介面**:
  - 型別:`Segment` / `segmentText` / `mkSegment`、`LogicalName` / `logicalNameText`
    及其 JSON instance、`NameParts(..)`、`NameError(..)` / `renderNameError`
  - 詞彙表:`NamingVocab(nvStates, nvVariants)` / `defaultVocab`
  - 建構與解析:`mkLogicalName` / `parseLogicalName` / `validateLogicalName` / `renderParts`
  - 數字部位:`variantFromNumber` / `indexSegment` / `isVariantShaped` / `isIndexShaped`
  - 給 ingest 的基本操作:`normalizeSegment` / `splitCamel` / `splitTrailingNumber`
  - 常數 `maxLogicalNameLength`
  - 模組間介面表中「`AssetDB.Naming` → ingest」「`AssetDB.Naming` → delivery、store」兩列
- **資料流管線段落**:管線 A(命名建構方向)全段;管線 B(命名解析方向)全段。
- **驗收標準**:
  - `parseLogicalName vocab` 對任何 `mkLogicalName vocab` 接受的組合還原出原 `NameParts`
  - `validateLogicalName` 接受所有自己產生的名稱
  - 缺項組合(有 state 沒 variant、有 variant 沒 state)都解析正確
  - 主體含連字號時不被誤拆;主體長得像修飾詞時在**建構期**就被拒絕
  - `normalizeSegment` 的輸出永遠通過 `mkSegment`;純中文輸入回報 `NoAsciiContent`
    而不是自作主張音譯
  - `isVariantShaped` 與 `isIndexShaped` 永不同時成立
  - `variantFromNumber` 補零兩位並拒絕三位數;`indexSegment` 補零三位並拒絕範圍外
  - 名稱長度超過 64 時回報 `TooLong`
- **明確不做**:不比對 `npDomain` 是否在任何詞彙表內(開放性由此承擔,ADR-004);
  詞彙表不從資料庫載入(`naming_vocab` 表已於 migration 004 移除,B001);
  不做廠商檔名 → kind/domain 的啟發式推導。

### manifest-schema

- **階段**:階段 0(領域模型)
- **負責模組**:`AssetDB.Manifest`
- **實作的 Level 2 介面**:
  - `currentSchemaVersion`
  - `Manifest(..)`、`ManifestAsset(..)`、`ManifestPack(..)`、`ManifestLicense(..)`、`AssetKey`
  - `ImageMeta(..)` / `AudioMeta(..)` / `imageMeta` / `audioMeta`
  - `manifestIndex` / `lookupAsset`
  - 全部手寫的 `ToJSON` / `FromJSON`
  - 模組間介面表中「`AssetDB.Manifest` → delivery、遊戲本體」一列
- **資料流管線段落**:管線 F(manifest 序列化)全段,含遊戲端的消費側。
- **驗收標準**:
  - 完整 manifest 的 JSON round-trip 一致
  - 頂層欄位名是穩定的字面字串
    (`schemaVersion` `project` `generatedAt` `assets` `packs` `licenses`)
  - `schemaVersion` 不符時**拒絕載入**,而不是留下一堆 `Nothing`;錯誤訊息說得出該怎麼修
  - 多出來的未知欄位被忽略(向前相容);`packs` / `licenses` 缺席時視為空清單
  - `imageMeta` / `audioMeta` 在 kind 不符時回 `Nothing` 而不是爆炸;
    `meta` 缺席不影響其他欄位
  - `manifestIndex` 以邏輯名稱為 key,`lookupAsset` 找得到
  - `ManifestLicense` 的 `commercial` 是必填,沒有預設值
- **明確不做**:不蒐集素材、不做授權閘門判斷、不寫檔(那是 delivery 的 `project` 套件);
  `maMeta` 不做成封閉 sum type,新增 kind 只能是加法。

### sqlite-schema-migrations

- **階段**:階段 0b(儲存層)
- **負責模組**:`AssetDB.Store`、`AssetDB.Store.Migrate`、`AssetDB.Store.Schema`、
  `AssetDB.Store.Orphans`
- **實作的 Level 2 介面**:
  - `Store(storeConn, storePath)`、`openStore` / `openStoreInMemory` / `withStore` /
    `initSchema` / `storeVersion`
  - `Migration(migVersion, migName, migStatements)`、`runMigrations` / `currentVersion` /
    `appliedVersions`、`MigrationError(..)`、`lit` / `num`
  - `migrations`(001..004)/ `schemaVersion`,以及對外契約中列出的全部資料表與 FTS5 虛擬表
  - `AssetDB.Store.Orphans` 的 `ToField` / `FromField` instance
  - 模組間介面表中 `AssetDB.Store` / `Migrate` / `Schema` / `Orphans` 四列
- **資料流管線段落**:管線 C(儲存初始化)全段;並為管線 D、E 提供 `Connection` 與資料表。
- **驗收標準**:
  - 全新資料庫版本為 0;套用後等於 `schemaVersion`;第二次呼叫是 no-op(冪等)
  - 每個 migration 的套用時間都被記錄
  - 版本號非遞增時直接拋錯且不半套;資料庫版本比程式新時拒絕動作
  - 單一 migration 失敗時它自己的交易整個回滾
  - 檔案資料庫在磁碟上建檔並啟用 WAL;重新開啟時保留已套用的 migration
  - `foreign_keys` 在連線上確實是開的
  - `lit` 把單引號加倍,含單引號的中文定義能跑完一個 migration 並原樣讀回;
    同一個值直接拼進 SQL 則會失敗
  - `assets` 的位置約束成立:壓縮檔內項目與散檔各自可寫入,兩種位置同時填或都不填都被拒絕
  - 授權欄位:`commercial` / `attribution_required` 無預設值,漏填寫不進去;
    只接受 0/1;未知維度可為 NULL 且 NULL 與 0 意義不同
  - 素材包完備狀態:`draft` 允許授權與作者留空,`ready` 缺任一者寫不進去,升級時同樣受檢
  - `ai_disclosure` 預設 `unknown`(不是 `none`),只接受已知值
  - 種子資料:只收錄有授權全文可查的、全部允許商用;分類都有給模型看的定義與適用範圍
  - migration 004 之後不再有 `naming_vocab` 表
- **明確不做**:沒有 down migration(ADR-006,回退是從備份還原檔案);不提供業務層
  repository —— 各子系統自己持有讀寫 SQL;不自動在 `openStore` 內跑 migration
  (分開才能「檢查版本但不改動」)。

### fts-cjk-index

- **階段**:階段 0b(儲存層)
- **負責模組**:`AssetDB.Store.Tokenize`、`AssetDB.Store.Index`
- **實作的 Level 2 介面**:
  - `CjkIndex(cjkUni, cjkBi)` / `cjkIndex` / `cjkUnigrams` / `cjkBigrams`
  - `cjkMatchExpr`、`hasCJK` / `isCJK`、`ftsQuoted` / `ftsPhrase`
  - `reindexFts` / `ftsRowCount` / `ftsStale`
  - 對外契約中 `assets_fts` / `assets_cjk` 兩張 FTS5 虛擬表的語意
    (rowid 共用、contentless、tokenizer 選擇)
  - 模組間介面表中「`AssetDB.Store.Tokenize` → Index / Search / ingest」
    與「`AssetDB.Store.Index` → delivery」兩列
- **資料流管線段落**:管線 D(全文索引填充)全段;並提供管線 E 的文字條件展開。
- **驗收標準**:
  - SQLite 編進了 FTS5 且 `trigram` tokenizer 可用
  - trigram 路徑:完整詞、子字串、跨欄位(作者名、廠商原始檔名)都搜得到;
    查詢中的減號不被當成 NOT;搜不到就是空
  - bigram 路徑:兩字中文詞在 trigram 索引搜不到但在 bigram 索引找得到;
    長詞兩邊都找得到;單字查詢走 unigram 欄
  - 片語查詢不會誤中不相鄰的組合;多段中日韓輸入以 AND 連接,段內才用片語
  - 中日韓查詢不會誤中純 ASCII 資料
  - `cjkBigrams` 不跨越非中日韓字元;n 個字產生 n−1 個 bigram;
    長度 1 的序列不產生 bigram
  - `cjkMatchExpr` 對純 ASCII 輸入回 `Nothing`;中英混合只取中日韓部分
  - `ftsQuoted` 讓 `*` 等運算子失效,內部雙引號以重複跳脫;`ftsPhrase` 正規化空白
  - `reindexFts` 之後筆數與 `status <> 'archived'` 的資源數相符;
    只有含中日韓字元的資源才進 bigram 索引;`ftsStale` 偵測得出索引落後
- **明確不做**:不做增量索引更新(全量重建,6,393 筆毫秒級完成;增量需要在每個寫入點
  記得同步兩張表,遲早會漏);不索引素材包的 notes(那是關於「這一包」的說明,
  攤進每一筆會讓搜「授權」吐出整包);不填充 `notes_fts` / `notes_cjk`(在 ingest)。

### search-and-facets

- **階段**:階段 5(檢索)
- **負責模組**:`AssetDB.Store.Search`
- **實作的 Level 2 介面**:
  - `SearchQuery(..)` 全部欄位、`emptyQuery`
  - `SearchHit(..)` 全部欄位與其 `FromRow`
  - `FacetCounts(..)`
  - `search` / `searchCount` / `facetCounts`
  - 消費 `AssetDB.Store.Tokenize` 的 `cjkMatchExpr` / `ftsQuoted`(見 F005)
  - 模組間介面表中「`AssetDB.Store.Search` → delivery」一列
- **資料流管線段落**:管線 E(檢索與 facet)全段。
- **驗收標準**:
  - 全文:以邏輯名稱、廠商原始檔名、作者都搜得到;ASCII 子字串命中;
    查詢中的減號不被當成 NOT;搜不到就是空而不是全部
  - 中文全文:兩字詞走 bigram 索引,長詞同樣找得到
  - 參考資料預設不出現(找 GUI 框時不該跳出廟宇照片),需明確 `sqIncludeReference`
  - 被排除的項目(宣傳圖等)預設不出現,需明確 `sqIncludeExcluded`
  - facet 篩選:依廠商、依素材包各自成立;多個條件是交集;`sqNamedOnly` 只留已命名的
  - facet 計數:算某個 facet 時**排除該 facet 自己的條件**;其他 facet 仍受目前條件約束
  - 分類條件是精確比對,計數以 `COUNT(DISTINCT)` 去重(一筆素材同時掛頂層與子分類)
  - 排序穩定:已命名的優先,其次依邏輯名稱,再次依原始檔名
- **明確不做**:不做分類路徑的前綴展開(分類器已同時寫入頂層與子分類兩列,
  查詢層再展開會產生說不清的結果);不決定各入口的分頁大小(`emptyQuery` 的
  `sqLimit = 50` 只是函式庫層保守預設,server / web / CLI 各自覆寫,G-E001);
  不搜尋 notes(`notes_fts` 的查詢在 ingest / delivery)。
