---
id: func-0004
type: spec
title: store-vault-io-and-index
description: Vault 檔案原子寫入與 SQLite 可重建索引及 FTS5 檢索
status: done
created: 2026-08-16
updated: 2026-08-16
depends-on: [func-0002, func-0003]
related-adr: [adr-0002, adr-0003, adr-0008]
related-spec: [func-0001, func-0002, func-0003]
---

# P1 Vault 落地與 SQLite 索引 功能規格

## 功能概述

`storyflow-store` 是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:
**把資料安全地寫進檔案**,以及**維護一份隨時可以刪掉重建的 SQLite 索引**。

ADR-0002 的核心主張——Markdown 是真相、SQLite 是衍生——只有在這一層被真正實現。
這代表兩條必須守住的底線:任何寫入路徑都是「先寫檔、再更新索引」,索引更新失敗**不算資料遺失**;
以及 `index rebuild` 的結果必須與重建前等價,這是「檔案才是真相」唯一可驗證的證明。

同時處理 ADR-0003 的樂觀鎖:AI Agent 與作者很可能同時改同一個 Vault,`revision` 不符即拒絕寫入。

**功能邊界**

做:Vault 定位與初始化、原子寫入、SQLite schema 與 FTS5 trigram、單檔索引更新、
全量重建、檔案過時偵測、樂觀鎖寫入、查詢與檢索。

不做:業務操作的組合(「建立一個片段並自動加 `partOf` 關聯」屬 `service`,P2)、
CLI 與 API(P2/P3)、跨 Vault 的查詢合併(P2,本規格只保證單 Vault 的索引與
`<vault>:<id>` 的原樣儲存)、衝突偵測(P4)。

**驗收標準**

- 從任意子目錄向上找得到 `.storyflow/`;找不到時錯誤訊息明確指出下一步
- `vault init` 產生的 Vault 目錄結構完整,`.gitignore` 已含 `index.db`
- 原子寫入在寫入過程被中斷時,原檔完好無損(不會出現半寫的檔案)
- 刪除 `index.db` 後重建,所有表的內容與刪除前逐筆相同(排序後比對)
- 以「織紋」搜尋能命中「織紋刀」,以「埃提亞」能命中內文中間的出現位置(trigram 子字串檢索)
- `revision` 不符的寫入被拒絕且原檔不變
- 檔案被外部編輯器改動後,查詢會偵測到過時並重讀該檔

## 相依性

`depends-on: [func-0002, func-0003]` —— 需要 core 的全部型別與純函式,以及 md 的解析與寫回。

**對 func-0003 的相依是型別層級的,不是選擇性的**。`storyflow-store` 沒有 `storyflow-md`
無法編譯,理由有三處:

1. `StoreError` 的 `ParseFailed FilePath [MdError]` 與 `data IndexIssue = IndexIssue FilePath [MdError]`
   直接引用 func-0003 的 `MdError`。`StoryFlow.Store.Error` 是本套件每個模組都要 import 的,
   因此連 T1 也繞不開。
2. `writeEntityMeta` 的簽名含 `MetaOverride`,該型別定義在 `StoryFlow.Md.Inherit`,core 沒有。
3. `indexFile` 吃 `FilePath`,必須讀檔後呼叫 `parseDocument` / `parseEntityFile` / `parseLevelFile`
   才能得到要寫進索引的型別值。

**平行開發的邊界在 T4 與 T5 之間**:

| 任務 | 是否需要 md 的實作 |
|---|---|
| T1 `resolveVault` / T2 `initVault` / T3 `atomicWriteText` | 否(僅需 `MdError` 的型別宣告可見) |
| T4 `Schema` 的 DDL 與 PRAGMA | 否;但「版本不符自動重建」會呼叫 `rebuildIndex`,該路徑需要 |
| T5 `indexFile` | 是 —— 真正呼叫解析器的地方 |
| T6 `rebuildIndex` / T7 等價性 | 是(經由 T5) |
| T8 `refreshStale` | 是(經由 T5) |
| T9 `writeEntityMeta` | 是 —— `parseDocument`(步驟 2)、`updateSection`(步驟 5)、`renderDocument`(步驟 6) |
| T10 `lookupEntity` | 是 —— `body` 需回讀檔案並解析 |
| T11 `searchEntities` | SQL 本體不需要,但測試資料要靠 T5 灌進索引 |

**func-0003 已於 8c9eaa3 完成並合併**(status: done,160 examples 全綠),合流點的實作
已可直接使用,本規格 11 項任務不再有等待。

合流點清單(型別也算介面):`parseDocument`、`documentKind`、`parseEntityFile`、
`parseLevelFile`、`updateSection`、`renderDocument`、`data MdError`、`data MdWarning`、
`data MetaOverride`。

**開工前需吸收 func-0003 的三點實作結果**(見其「實作備註」):

- `parseEntityFile` / `parseLevelFile` 的實際簽名是
  `Document -> Either [MdError] (EntityFile, [MdWarning])` ——**帶警告**。原本的
  `IndexIssue FilePath [MdError]` 沒有地方放警告,索引時 `MissingSummary` /
  `CustomLinkKind` / `EmptyBody` 會被靜靜丟掉;已於「錯誤處理」節改為
  `IndexIssue FilePath [MdError] [MdWarning]`。
- `MetaOverride` 比本規格引用時多了 `moKind :: Maybe NodeKind`,序列化欄位順序也隨之
  變成 13 欄。T9 的 `writeEntityMeta` 因此同樣能安全地改 Level 檔的 Node 節,不會在
  重寫時把 `kind:` 抹掉。
- `MdErrorKind` 多了 `UnknownSectionId Id`;T9 步驟 5 呼叫 `updateSection` 時,
  「索引有記錄但檔案裡找不到該節」會以這個錯誤回來,`StoreError` 需要能轉譯它
  (語意上接近 `EntityNotFound`,但成因是索引過時而非資料不存在,建議走 `ParseFailed`
  或另立建構子)。

`storyflow-store` 的 `build-depends` 因此包含 `storyflow-md`(架構圖中 `md` 與 `core`
同時匯入 `store`);func-0001 建立骨架時漏了這一條,已於本規格修正時補上。

## 實作方式

### 模組劃分

```
storyflow-store
├── StoryFlow.Store.Vault    -- Vault 定位、config.toml、init
├── StoryFlow.Store.Atomic   -- 原子寫入
├── StoryFlow.Store.Schema   -- SQLite DDL、版本戳、開啟連線
├── StoryFlow.Store.Index    -- 單檔 upsert/刪除、全量重建、過時偵測
├── StoryFlow.Store.Write    -- 樂觀鎖寫入流程(檔案 → 索引)
├── StoryFlow.Store.Query    -- 條件查詢、關聯查詢、FTS5 檢索
└── StoryFlow.Store.Error    -- StoreError
```

### Vault 定位與初始化(`StoryFlow.Store.Vault`)

ADR-0008 的三段規則:

```haskell
data Vault = Vault
  { vaultName :: Text
  , vaultRoot :: FilePath        -- 含 .storyflow/ 的那一層
  , vaultCfg  :: VaultConfig
  }

data VaultConfig = VaultConfig
  { cfgName      :: Text
  , cfgReferences :: [Text]      -- 引用的其他 Vault 名稱(唯讀)
  , cfgLlm       :: Maybe LlmConfig   -- P5 才用,P1 只原樣讀存
  }

-- | 1. Just name → 查全域註冊表
--   2. Nothing   → 從 cwd 向上搜尋 .storyflow/
--   3. 都沒有    → Left VaultNotFound(訊息含建議指令)
resolveVault :: Maybe Text -> FilePath -> IO (Either StoreError Vault)

loadRegistryFile :: IO (Either StoreError (Map Text FilePath))   -- ~/.config/story-flow/vaults.toml
initVault :: FilePath -> Text -> IO (Either StoreError Vault)
```

向上搜尋在抵達檔案系統根目錄時停止;`resolveVault` 也要處理「向上搜尋找到了,但
`config.toml` 壞了」——這種情況回 `VaultConfigInvalid` 而非繼續往上找,否則會默默寫進
上一層的另一個 Vault,這正是 ADR-0008 列出的「誤操作風險」。

`initVault` 產生:

```
<root>/.storyflow/config.toml
<root>/.storyflow/.gitignore      內容:index.db
<root>/characters/  lore/  items/  dialogues/  levels/
<root>/.gitignore                 若不存在則建立,含 .storyflow/index.db
```

`.gitignore` 已存在時**只追加缺少的行**,不覆寫作者既有內容。

`config.toml`:

```toml
name = "liftgame"
references = ["shared-lore"]

[llm]
endpoint = "http://127.0.0.1:8080/v1"
model = "qwen2.5-14b-instruct"
```

`[llm]` 是 P5 的東西,P1 原樣讀進 `Maybe LlmConfig` 並在寫回時保留,不解讀內容。
TOML 解析沿用 func-0002 選定的 `toml-reader`。

### 原子寫入(`StoryFlow.Store.Atomic`)

```haskell
-- | 寫入暫存檔 → fsync → rename 覆蓋。中途失敗時原檔完好。
atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())
```

實作要點:

- 暫存檔與目標檔**放同一個目錄**(`<target>.tmp-<pid>`),跨檔案系統的 rename 不是原子操作
- 寫完後 `hFlush` + `hClose`;內容 encode 為 UTF-8 **不加 BOM**
- **Windows 的 rename 不會覆蓋既有檔案**——`System.Directory.renamePath` 在 Windows 上
  對已存在的目標會失敗。這是本模組最容易踩的坑,實作時必須驗證行為;若 `renamePath`
  不可用則以 `Win32.moveFileEx` 搭配 `MOVEFILE_REPLACE_EXISTING`,並以 CPP 條件編譯隔離
  (`if os(windows)` 加入 `Win32` 相依,作法與 assetdb 的 console 模組一致)
- 失敗時清掉暫存檔,不留垃圾

殘留競態:重讀檔案(樂觀鎖比對)與 rename 之間存在極短窗口,兩個行程剛好在此交錯仍可能
互相覆蓋。這是本規格明確接受的殘留風險(開發者已確認 P1 不做作業系統層檔案鎖);
影響範圍是「單機、單人 + AI Agent」,窗口是毫秒級,且損失可由 git 復原。

### SQLite schema(`StoryFlow.Store.Schema`)

以 architecture.md 的索引結構為準,**新增兩個欄位**(需回寫 architecture.md):

```sql
CREATE TABLE meta_info(key TEXT PRIMARY KEY, value TEXT);   -- schema_version 等

CREATE TABLE files(
  path        TEXT PRIMARY KEY,     -- 相對 vault root
  mtime       INTEGER NOT NULL,     -- ★ 新增:過時偵測
  size        INTEGER NOT NULL      -- ★ 新增:過時偵測
);

CREATE TABLE entities(
  id TEXT PRIMARY KEY, vault TEXT, type TEXT, title TEXT, summary TEXT,
  status TEXT, timeline TEXT, timeline_order INTEGER,
  source TEXT, revision INTEGER, created TEXT, updated TEXT,
  file_path TEXT NOT NULL, section_anchor TEXT,
  FOREIGN KEY(file_path) REFERENCES files(path) ON DELETE CASCADE
);

CREATE TABLE entity_aliases(entity_id TEXT, alias TEXT);
CREATE TABLE links(src TEXT, dst_vault TEXT, dst TEXT, kind TEXT, note TEXT);
CREATE TABLE levels(id TEXT PRIMARY KEY, vault TEXT, title TEXT, summary TEXT,
                    root TEXT, status TEXT, file_path TEXT NOT NULL, ...);
CREATE TABLE nodes(id TEXT PRIMARY KEY, level_id TEXT, parent_id TEXT,
                   order_idx INTEGER, kind TEXT, title TEXT, summary TEXT,
                   file_path TEXT NOT NULL, section_anchor TEXT, ...);
CREATE TABLE node_entities(node_id TEXT, entity_id TEXT);

CREATE VIRTUAL TABLE entities_fts USING fts5(
  title, summary, body, aliases, tags,
  content='', tokenize='trigram'
);
CREATE TABLE fts_map(rowid INTEGER PRIMARY KEY, entity_id TEXT);
```

`files` 表是為了過時偵測而新增的——原本的設計沒有地方放 mtime。它同時讓「這個檔案的所有
Entity」的級聯刪除變成一行 SQL。

`entities_fts` 用 `content=''`(external content 的 contentless 模式)並以 `fts_map`
對應 rowid → entity_id:FTS5 的 rowid 是整數,而我們的 id 是字串,需要一張對照表。
`body` 進 FTS 但**不進 `entities` 表**——正文只有檔案有,索引只需要能搜到它。

開啟連線時:`PRAGMA foreign_keys = ON`、`PRAGMA journal_mode = WAL`(讀寫並行)、
寫入 `schema_version`。schema 變更時**不寫遷移程式**,直接 rebuild——這正是 ADR-0002
買到的好處(對照 design-studio 的 bug-0003「session schema 從未遷移」)。
`openIndex` 讀到的 `schema_version` 與程式內建版本不符時,自動觸發全量重建。

### 索引更新與重建(`StoryFlow.Store.Index`)

```haskell
-- | 單檔更新:刪掉該檔既有的全部記錄,再插入新的。整檔替換而非逐筆 diff。
indexFile :: Connection -> Vault -> FilePath -> IO (Either StoreError ())

-- | 全量重建:掃描 Vault 下所有 .md(略過 .storyflow/ 與隱藏目錄),
--   逐檔解析並索引。單檔解析失敗**不中斷**,收集後一併回報。
rebuildIndex :: Connection -> Vault -> IO (Either StoreError [IndexIssue])

-- | 比對 files 表的 mtime/size 與磁碟現況。
staleFiles :: Connection -> Vault -> IO [FilePath]

-- | 對 staleFiles 逐一 indexFile,並移除磁碟上已不存在的檔案記錄。
refreshStale :: Connection -> Vault -> IO (Either StoreError [IndexIssue])
```

**整檔替換而非逐筆 diff**:一份 `.md` 的所有 Entity 一起進退,不需要算哪個節被改了。
這在正確性上遠比 diff 可靠,而檔案級的重新索引成本本來就很低。

`indexFile` 全程包在一個 transaction 裡:刪 + 插要嘛全成功要嘛全不動,不會出現
「舊記錄刪了、新記錄沒進去」的半殘索引。

`refreshStale` 是 ADR-0002「檔案被外部改動後索引過時」的答案:每次查詢前呼叫一次,
成本是對每個檔案做一次 `getFileStatus`(數百檔的規模下是毫秒級)。作者用編輯器改完檔案
直接查詢,結果就是新的,不需要手動 rebuild。

### 樂觀鎖寫入(`StoryFlow.Store.Write`)

ADR-0003 的 `revision` 比對,完整流程:

```haskell
data WriteResult = WriteResult { wrNewRevision :: Int, wrPath :: FilePath }

-- | 修改既有 Entity 的 Meta。
--   expected 為呼叫端手上那份資料的 revision。
writeEntityMeta
  :: Connection -> Vault -> Id -> Int          -- expected revision
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreError WriteResult)
```

步驟:

1. 查索引取得 `file_path` 與 `section_anchor`(找不到 → `EntityNotFound`)
2. **重讀該檔**並 `parseDocument`(不信任索引裡的 revision,索引可能過時)
3. 比對該節的 `revision` 與 `expected`:不符 → `StaleRevision expected actual`,**不寫任何東西**
4. 套用修改函式,`revision + 1`,`updated` 設為今天
5. `updateSection` 產生新的檔案內容(只有這一節的 meta 區塊被重寫)
6. `atomicWriteText` 寫回
7. `indexFile` 更新索引

**先寫檔、再更新索引**(ADR-0002)。第 7 步失敗時回 `IndexUpdateFailed` 但**檔案已經寫成功**
——這不是資料遺失,呼叫端(P2 的 service)應提示「資料已寫入,索引需重建」而不是報告失敗。
這個語意差別要在 `StoreError` 的型別上表達清楚,不能和真正的寫入失敗混在同一個建構子。

新建 Entity 的 ID 碰撞處理:func-0002 的 `mkId` 帶 `salt`,本層在寫入前查 `entities` 表,
若 id 已存在則 `salt + 1` 重算,最多重試 8 次後回 `IdCollision`(8 次都撞的機率可忽略,
但無上限的迴圈是不可接受的)。

### 查詢與檢索(`StoryFlow.Store.Query`)

```haskell
data EntityFilter = EntityFilter
  { efType   :: Maybe Text
  , efStatus :: Maybe Status
  , efTag    :: Maybe Text
  , efLimit  :: Maybe Int
  }

lookupEntity   :: Connection -> Id -> IO (Maybe Entity)      -- 含 body,需回讀檔案
listEntities   :: Connection -> EntityFilter -> IO [Meta]    -- 不含 body
linksFrom      :: Connection -> Id -> IO [Link]
linksTo        :: Connection -> Ref -> IO [(Id, Link)]       -- 反向查詢,索引才做得到
loadLinkGraph  :: Connection -> IO LinkGraph                 -- 餵給 core 的 Graph 函式
lookupLevel    :: Connection -> Id -> IO (Maybe (Level, [Node]))

-- | FTS5 檢索。查詢字串會被跳脫,避免使用者輸入被當成 FTS 語法。
searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]
--                                                          ^ snippet
```

`linksTo` 是索引存在的主要理由之一:關聯只存在來源端(ADR-0002),檔案裡查不到
「誰指向我」,只有索引能做反向查詢。

`searchEntities` 的查詢字串處理:使用者輸入以雙引號包成 FTS5 的 phrase query 並跳脫
內部的雙引號,避免 `OR` / `NEAR` / `*` 被當成語法。中文以 trigram 切分,搜「織紋」
會命中「織紋刀」的內部位置——這正是選 trigram 而非預設 tokenizer 的原因。
以 `snippet()` 回傳命中片段供 CLI 顯示。

`lookupEntity` 需要 `body`,而 `body` 不在 `entities` 表——它會依 `file_path` +
`section_anchor` 回讀檔案並解析。這是刻意的:正文可能很長,不該在索引裡存兩份。

### 錯誤處理

```haskell
data StoreError
  = VaultNotFound Text                 -- 訊息含「執行 story-flow vault init 或指定 --vault」
  | VaultConfigInvalid FilePath Text
  | VaultAlreadyExists FilePath
  | EntityNotFound Id
  | StaleRevision Id Int Int           -- id, expected, actual
  | IdCollision IdPrefix
  | FileWriteFailed FilePath Text
  | IndexUpdateFailed FilePath Text    -- ★ 檔案已寫成功,只有索引失敗
  | ParseFailed FilePath [MdError]
  | SqliteError Text

data IndexIssue = IndexIssue FilePath [MdError] [MdWarning]
```

`IndexIssue` 帶 `[MdWarning]`:`storyflow-md` 是純函式庫,警告只能靠呼叫端輸出。
索引是唯一會走過 Vault 全部檔案的地方,不在這裡收集,`MissingSummary` /
`CustomLinkKind` / `EmptyBody` 就永遠不會被作者看到。

`IndexUpdateFailed` 與 `FileWriteFailed` 分開是刻意的:前者資料安全,重建即可;
後者是真正的失敗。呼叫端必須能區分。

所有 SQLite 例外在本套件邊界被捕捉並轉成 `SqliteError`,**不讓例外洩漏到上層**——
`service`(P2)面對的應該是 `Either StoreError a`,不是可能從任何地方拋出的 `SQLError`。

### 測試策略

落地層測試用 `temporary` 建臨時 Vault(architecture.md 已指定此作法),每個測試自帶
一個完整的 Vault 骨架與幾份 `.md`,測完即刪。SQLite 部分測試用 `:memory:`,
需要驗證檔案行為的(WAL、重開連線)用臨時目錄下的真實檔案。

## 使用到的既有串接介面

func-0002(core):

| 介面 | 用途 |
|---|---|
| `data Meta` / `Entity` / `Level` / `Node` / `Link` / `Status` / `Source` / `Timeline` | 索引的讀寫對象 |
| `newtype Id`, `data Ref`, `parseId`, `renderId`, `parseRef`, `renderRef` | 主鍵與跨 Vault 定址的儲存格式 |
| `mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | 新建實體的 ID 生成(salt 由本層遞增) |
| `renderLinkKind` / `parseLinkKind` | `links` 表的 `kind` 欄位 |
| `renderNodeKind` / `parseNodeKind` | `nodes` 表的 `kind` 欄位 |
| `bumpRevision :: Day -> Meta -> Meta` | 樂觀鎖寫入的第 4 步 |
| `type LinkGraph`, `buildGraph :: [Meta] -> LinkGraph` | `loadLinkGraph` 的組裝 |

func-0003(md,T5 起全面需要):

| 介面 | 用途 | 任務 |
|---|---|---|
| `parseDocument :: FilePath -> Text -> Either [MdError] Document` | 讀檔後的第一步 | T5 / T9 / T10 |
| `documentKind :: Document -> Either [MdError] DocKind` | 判別 Entity 檔或 Level 檔 | T5 |
| `parseEntityFile` / `parseLevelFile` | 取得要索引的型別值 | T5 / T10 |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | 樂觀鎖寫入的第 5 步 | T9 |
| `renderDocument :: Document -> Text` | 產生要寫回的檔案內容 | T9 |
| `data MetaOverride` | `writeEntityMeta` 的修改函式型別 | T9 |
| `data MdError`, `renderMdError` | `ParseFailed` / `IndexIssue` 的內容 | 全部(經 `StoreError`) |

func-0001:`storyflow-store` 套件骨架與其 FTS5 smoke test。

外部套件介面:

| 介面 | 來源 | 用途 |
|---|---|---|
| `Database.SQLite.Simple` (`withConnection`, `execute`, `execute_`, `query`, `query_`, `withTransaction`, `lastInsertRowId`) | `sqlite-simple` | 全部 SQL 存取 |
| `System.Directory` (`listDirectory`, `doesFileExist`, `createDirectoryIfMissing`, `renamePath`, `removeFile`, `getXdgDirectory`) | `directory` | 檔案與目錄操作、全域註冊表路徑 |
| `System.Directory.getModificationTime` / `getFileSize` | `directory` | 過時偵測的 mtime 與 size(不需引入 `unix-compat`) |
| `System.FilePath` (`</>`, `takeDirectory`, `makeRelative`, `takeExtension`) | `filepath` | 路徑組裝與向上搜尋 |
| `System.IO.Temp.withSystemTempDirectory` | `temporary` | 測試用臨時 Vault |
| `TOML.decode` | `toml-reader` | `config.toml` 與 `vaults.toml` |
| `Graphics.Win32` / `System.Win32.File.moveFileEx` | `Win32`(僅 Windows) | rename 覆蓋既有檔案 |

## 新增的介面

| 模組 | 介面 |
|---|---|
| `StoryFlow.Store.Vault` | `data Vault`, `data VaultConfig`, `resolveVault :: Maybe Text -> FilePath -> IO (Either StoreError Vault)`, `initVault :: FilePath -> Text -> IO (Either StoreError Vault)`, `loadVaultRegistry :: IO (Either StoreError (Map Text FilePath))`, `vaultRelPath :: Vault -> FilePath -> FilePath` |
| `StoryFlow.Store.Atomic` | `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` |
| `StoryFlow.Store.Schema` | `openIndex :: Vault -> IO (Either StoreError Connection)`, `createSchema :: Connection -> IO ()`, `schemaVersion :: Int`, `closeIndex :: Connection -> IO ()` |
| `StoryFlow.Store.Index` | `indexFile :: Connection -> Vault -> FilePath -> IO (Either StoreError ())`, `unindexFile :: Connection -> FilePath -> IO ()`, `rebuildIndex :: Connection -> Vault -> IO (Either StoreError [IndexIssue])`, `staleFiles :: Connection -> Vault -> IO [FilePath]`, `refreshStale :: Connection -> Vault -> IO (Either StoreError [IndexIssue])`, `data IndexIssue` |
| `StoryFlow.Store.Write` | `writeEntityMeta :: Connection -> Vault -> Id -> Int -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)`, `allocateId :: Connection -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)`, `data WriteResult` |
| `StoryFlow.Store.Query` | `data EntityFilter`, `emptyFilter`, `lookupEntity`, `listEntities`, `linksFrom`, `linksTo`, `loadLinkGraph`, `lookupLevel`, `searchEntities` |
| `StoryFlow.Store.Error` | `data StoreError`, `renderStoreError :: StoreError -> Text` |

**Schema 契約**(本規格新確立、需回寫 architecture.md):新增 `files(path, mtime, size)` 表
與 `meta_info(key, value)` 表;`entities_fts` 採 contentless 模式並以 `fts_map` 對應
rowid → entity_id。

## TodoList

- [x] T1: `StoryFlow.Store.Vault` —— 向上搜尋 `.storyflow/`、全域註冊表查詢、`--vault` 三條定位路徑與 `config.toml` 解析
- [x] T2: `initVault` —— 建立 `.storyflow/`、`config.toml`、子目錄骨架,`.gitignore` 追加而不覆寫
- [x] T3: `StoryFlow.Store.Atomic` —— 同目錄暫存檔 + rename 覆蓋,Windows 覆蓋行為處理,失敗清理
- [x] T4: `StoryFlow.Store.Schema` —— 全部表與 `entities_fts`(trigram)DDL、`schema_version`、PRAGMA 設定、版本不符自動重建
- [x] T5: `indexFile` / `unindexFile` —— 單檔整檔替換,包 transaction,涵蓋 entities / aliases / links / levels / nodes / node_entities / FTS
- [x] T6: `rebuildIndex` —— 掃描全 Vault 的 `.md`,單檔失敗不中斷並收集為 `IndexIssue`
- [x] T7: 重建等價性 —— 刪除 `index.db` 後重建的結果與刪除前逐表逐筆相同
- [x] T8: `staleFiles` / `refreshStale` —— 以 mtime + size 偵測外部改動與檔案刪除
- [x] T9: `writeEntityMeta` —— 重讀比對 revision、`StaleRevision` 拒絕、寫檔成功但索引失敗的語意分離;`allocateId` 的碰撞重試
- [x] T10: `StoryFlow.Store.Query` —— `lookupEntity`(回讀 body)/ `listEntities` / `linksFrom` / `linksTo` / `loadLinkGraph` / `lookupLevel`
- [x] T11: `searchEntities` —— FTS5 trigram 中文檢索、查詢字串跳脫、snippet 回傳、與 `EntityFilter` 併用

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Store.VaultSpec` | 臨時 Vault 下:從三層深的子目錄向上搜尋找得到 root;無 `.storyflow/` 時回 `VaultNotFound` 且訊息含 `vault init` 建議;`--vault name` 經全域註冊表解析;向上搜尋找到但 `config.toml` 語法錯誤時回 `VaultConfigInvalid` **而非繼續往上找**;`[llm]` 區塊被原樣保留 |
| T2 | `StoryFlow.Store.InitSpec` | `initVault` 後 `.storyflow/config.toml` 與五個子目錄存在;`.gitignore` 含 `index.db`;對已有 `.gitignore` 的目錄執行時**原有內容完整保留**且只追加缺少的行;重複 init 回 `VaultAlreadyExists` 且不覆寫既有 config |
| T3 | `StoryFlow.Store.AtomicSpec` | 寫入後內容正確且無 BOM;**覆蓋既有檔案成功**(Windows 的關鍵驗證);寫入後目錄下無殘留 `.tmp-*`;目標路徑不可寫時回 `FileWriteFailed` 且原檔內容未變 |
| T4 | `StoryFlow.Store.SchemaSpec` | `createSchema` 後全部表與 `entities_fts` 存在;`entities_fts` 的 tokenizer 為 trigram;`foreign_keys` 為 ON;`meta_info` 有 `schema_version`;把 `schema_version` 竄改為舊值後 `openIndex` 觸發重建而非報錯 |
| T5 | `StoryFlow.Store.IndexSpec` | 索引一份含 2 個片段的 Entity 檔後 `entities` 有 3 筆(主體 + 2 片段)、`links` 筆數正確、`entity_aliases` 正確、FTS 可查到;同檔改為只剩 1 個片段再 `indexFile`,舊記錄**全部消失**不留孤兒;索引 Level 檔後 `nodes` / `node_entities` 正確;中途拋錯時 transaction 回滾、索引維持原狀 |
| T6 | `StoryFlow.Store.RebuildSpec` | 對含 5 份檔案(3 Entity + 2 Level)的 Vault `rebuildIndex` 後各表筆數正確;其中一份檔案 YAML 損壞時**其餘四份仍被索引**且回傳一筆 `IndexIssue` 帶檔名與 `MdError`;`.storyflow/` 與隱藏目錄下的 `.md` 不被掃描 |
| T7 | `StoryFlow.Store.RebuildSpec`(等價性) | 建好索引後 dump 全部表(排序後序列化)→ 刪除 `index.db` → `rebuildIndex` → 再 dump,兩份 dump 逐字相同。這是 ADR-0002「檔案才是真相」的可執行證明 |
| T8 | `StoryFlow.Store.StaleSpec` | 外部修改某檔內容後 `staleFiles` 回報該檔;`refreshStale` 後查詢得到新內容;檔案被刪除後 `refreshStale` 移除其全部記錄;未改動的檔案不出現在 `staleFiles`(避免每次查詢都全量重讀);修改後大小相同但 mtime 不同的檔案仍被偵測到 |
| T9 | `StoryFlow.Store.WriteSpec` | 以正確 revision 寫入成功,檔案中該節 summary 已更新、`revision` 加一、`updated` 為今天,**其餘節逐字未變**;以過期 revision 寫入回 `StaleRevision` 且檔案**位元組完全未變**;寫入不存在的 id 回 `EntityNotFound`;索引連線關閉後寫入回 `IndexUpdateFailed` 而檔案已成功寫入(語意分離的驗證);`allocateId` 在 id 已存在時遞增 salt 產生相異 id |
| T10 | `StoryFlow.Store.QuerySpec` | `lookupEntity` 回傳含 body 的完整 Entity(body 來自回讀檔案);`listEntities` 依 type / status / tag 過濾正確且不含 body;`linksFrom` 得來源端關聯;`linksTo` 得**反向**關聯(檔案查不到、只有索引做得到);`loadLinkGraph` 餵給 core 的 `supersededSet` 得到正確的過時集合;`lookupLevel` 得 Level 與其全部 Node |
| T11 | `StoryFlow.Store.SearchSpec` | 以「織紋」命中「織紋刀」(子字串,證明 trigram 生效);以「埃提亞」命中正文中段的出現;查詢字串含 `OR` / `"` / `*` 時被跳脫為字面而非 FTS 語法;搭配 `efStatus = Just Canon` 時 draft 片段不出現;`snippet` 回傳含命中詞的片段;無結果時回空清單而非錯誤 |

## 實作備註

實作於 2026-08-16 完成,`storyflow-store` 72 examples 全綠(`cabal test all` 四個套件
共 410 examples 全綠)。以下是與本規格原文不同、或規格沒寫而實作必須決定的地方。

### 1. `entities_fts` 不用 contentless(開發者確認)

規格與 architecture.md 都寫 `content=''`。實作時碰到兩個硬限制:contentless 的 FTS5 表
**不支援 `snippet()`**(T11 明確要求回傳命中片段),也**不支援刪除單列**(T5 要求單檔
重新索引時舊 FTS 記錄全部消失;contentless 只能以原始欄位值下 `'delete'` 指令,而那些值
正是 contentless 沒存的東西)。

改用一般 FTS5 表:`fts5(title, summary, body, aliases, tags, tokenize='trigram')`,
`fts_map` 對應 rowid → entity_id 的設計不變。代價是 body 在 `index.db` 裡多存一份——
索引本來就是可丟棄的衍生物,這個代價是划算的。已回寫 architecture.md。

### 2. 新增 `entity_tags` 表(開發者確認)

`EntityFilter.efTag` 要依 tag 過濾,而原本的索引結構只有 FTS 的 `tags` 欄位,沒有可查詢的
地方。新增 `entity_tags(entity_id, tag)`,與 `entity_aliases` 對稱。已回寫 architecture.md。

### 3. `links` 多一個 `file_path` 欄位

關聯的來源可能是 Entity / Level / Node 三種表的任一種,靠 `src` 反查要三個子查詢。帶上
檔案路徑後,單檔重新索引就只是一次外鍵級聯(`DELETE FROM files WHERE path = ?`)。

`unindexFile` 因此只有兩條 SQL:先算出 rowid 清掉 FTS(FTS 沒有外鍵),再刪 `files` 一列,
其餘全部級聯。這也是 `PRAGMA foreign_keys = ON` 在本層是正確性前提而非潔癖的原因。

### 4. 二字詞檢索走 LIKE 掃描

驗收標準寫「以『織紋』搜尋能命中『織紋刀』」,但 trigram 以三字元為索引單位,二字詞
`MATCH` 一定不命中——func-0001 的 smoke test 已經把這個限制寫成一條測試。`searchEntities`
因此分兩條路徑:三字元以上走 `MATCH`,兩字元以下走 `LIKE '%…%'` 全表掃描並自己產生
snippet。角色名與道具名常常就是兩個字,這一段是本層必須自己補的。

### 5. 檔案層主體的 meta 目前寫不動

`updateSection` 只能改「節」,`storyflow-md` 沒有任何改 frontmatter 的介面。對
`section_anchor` 為 NULL 的 Entity,`writeEntityMeta` 回新增的
`FrontmatterWriteUnsupported Id` 並在訊息裡說明要改該檔的 frontmatter。缺口已記在
architecture.md 末節的「已知缺口」,留給後續 spec 補 `storyflow-md` 的 `updateFrontmatter`。

### 6. `StoreError` 多了 `FileReadFailed`

規格的錯誤清單只有寫入方向。索引與樂觀鎖都要讀檔,讀不到或不是合法 UTF-8 時既不是
`ParseFailed`(還沒進到解析)也不是 `SqliteError`,所以另立一個建構子。

### 7. `openIndex` 只管 schema 版本,資料層重建在 `openVaultIndex`

規格寫「`openIndex` 讀到的 `schema_version` 不符時自動觸發全量重建」,但重建要呼叫
`rebuildIndex`,而 `Schema` 不能 import `Index`(會循環相依)。拆成兩段:

- `Schema.openIndex` 版本不符時砍掉重建 schema(表變空)
- 新增 `Index.openVaultIndex :: Vault -> IO (Either StoreError (Connection, [IndexIssue]))`,
  開完連線後跑一次 `refreshStale`。schema 被重建後 `files` 表是空的,於是每一份 `.md`
  都被判定為過時而重新索引——資料自然回來

`openVaultIndex` 是 P2 的 `service` 該用的進入點:它同時涵蓋「版本不符要重建」與
「作者剛用編輯器改過檔案」兩件事。

### 8. Vault 定位多了可指定註冊表路徑的版本

`resolveVaultWith :: FilePath -> Maybe Text -> FilePath -> IO ...` 與
`loadVaultRegistryFrom :: FilePath -> IO ...`:測試不能去讀開發者本機真正的
`~/.config/story-flow/vaults.toml`。無參數版沿用規格簽名。

規格內文一處寫 `loadRegistryFile`、介面表寫 `loadVaultRegistry`,實作採用後者。

`vaultRelPath` **一律以 `/` 分隔**——索引可能被跨平台重建,而
`characters\琳達.md` 與 `characters/琳達.md` 是兩個不同的字串主鍵。另補
`vaultAbsPath` 做反向轉換。

### 9. 原子寫入:暫存檔命名與 fsync

- 暫存檔改用 `openBinaryTempFile <目錄> "<檔名>.tmp"` 而不是規格寫的
  `<target>.tmp-<pid>`:`base` 在 Windows 上沒有取 pid 的介面,而 `openBinaryTempFile`
  是同目錄、原子建立、跨行程唯一的
- **`renamePath` 在 Windows 上會覆蓋既有檔案**(以 T3 的測試實測確認),因此
  `Win32.moveFileEx` 的 CPP 條件編譯**沒有做**,`Win32` 也沒有進 build-depends
- **沒有 fsync**:`base` 沒有跨平台的檔案同步介面(`unix` 的 `fileSynchronise` 與
  Windows 的 `flushFileBuffers` 都要另外相依)。目前是 `hFlush` + `hClose` + rename,
  防的是「半寫的檔案」而不是「作業系統當掉」。要防後者是另一個層級的成本,P1 不付

### 10. `meta_info` 多存 `vault_root` / `vault_name`

`lookupEntity :: Connection -> Id -> IO (Maybe Entity)` 的簽名裡沒有 `Vault`,但 body
要回讀檔案。把 Vault 根目錄記在 `meta_info` 裡,連線就是自足的,規格簽名得以原樣保留。
`openIndex` 與每次 `indexFile` 都會更新這兩列。

### 11. 新增內部模組 `StoryFlow.Store.Row`

核心型別 ↔ 資料列的轉換集中在一處(理由與 `StoryFlow.Core.Json` 相同):寫入與讀出
必須是同一套規則,而「刪掉 index.db 重建後等價」這條保證完全建立在兩邊一致上。
不對外承諾介面。

### 12. 其他實作決定

- `files.mtime` 存**奈秒**:同一秒內改兩次是測試與人手都做得到的事,秒級解析度會漏掉
- `IndexIssue` 也用來承載「成功索引但有品質警告」的檔案(`[MdError]` 為空);
  `issueHasError` 區分兩者。`indexFile` 這個介面上警告會被丟掉,要收集請走
  `rebuildIndex` / `refreshStale`
- Level 與 Node **不進 FTS、不進 `entity_aliases` / `entity_tags`**:衝突偵測只面對
  Entity(ADR-0003),結構節點進檢索只會製造雜訊
- `node_entities.entity_id` 存的是 `Ref` 的字串形式(可能是 `<vault>:<id>`),因此不下外鍵
- 索引時把指向本 Vault 的 `dst_vault` 正規化成 NULL,否則 `liftgame:ent-7f3a` 與
  `ent-7f3a` 會變成反向查詢互相看不見的兩個東西
- T3 的「目標路徑不可寫」改以「目標是一個既有目錄」來造:這是 Windows 與 POSIX 上
  行為一致的失敗方式(唯讀屬性在兩邊的語意不同)
- T9 的「索引更新失敗但檔案已寫成功」以 `PRAGMA query_only = ON` 造出「讀得到、寫不了」
  的連線,正好對應該情境
- T5 的「transaction 中途失敗」以「另一份檔案的第二個片段與既有 id 相撞」造出主鍵衝突,
  是真正的中途失敗而非第一條 SQL 就失敗
