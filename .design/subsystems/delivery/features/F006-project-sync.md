---
id: F006
type: feature
title: project-sync
description: 把符合條件的素材增量加入已登記專案,對帳分四類且只增不刪
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: [F005, F001]
related-adr: []
related-feature: []
---

# F006: 專案增量同步

## 功能概述

`assetdb new-project` 只能一次性建出專案。專案開工之後想再加素材,目前唯一的辦法是
「用新條件重新產生到另一個目錄,再把 `assets/` 換過去」—— 樣板 `SKILL.md` 現在就是
這樣寫的,而且明講 `project sync`「尚未實作」。這是 README 的「尚未實作」清單裡最痛的
一項:每加一張圖就要重跑一次全量產生,手寫程式碼與素材目錄之間永遠差一次手動搬移。

本功能新增 `assetdb project sync`,對**已登記的專案**做增量加入:

```text
assetdb project sync --name <NAME> [--pack SLUG]… [--match Q] [--allow-non-commercial] [--confirm]
```

四個設計決定:

1. **對帳先於寫入。** 每筆候選素材先歸入「新增 / 已存在 / 來源已更新 / 本地已修改」四類
   之一,再決定要不要動磁碟。分類是純查詢,不需要壓縮檔,所以它可以被直接測到 ——
   而「該不該覆蓋一個使用者可能已經手改過的檔案」正是這個功能最容易寫錯的地方。
2. **只增不刪、不覆蓋。** 只有「新增」類會被寫進磁碟。「來源已更新」與「本地已修改」
   只回報不處理 —— 那兩件事各自需要自己的旗標與自己的確認語意,不在本契約內。
   `project_assets` 的既有列一律不動(注意 `createProject` 的登記是
   `DELETE FROM project_assets` 之後重灌,本功能**不可以**沿用那條路徑)。
3. **授權閘門只擋新增,不回溯既有。** 既有登記素材的素材包後來授權降級或被改回未查證時,
   它仍留在磁碟、仍列入重新產生的 `manifest.json` 與 `Assets.hs`,只是在回報中逐包警告。
   否則 manifest 與磁碟會不一致,而遊戲端已經 `import` 的 `AssetKey` 常數會靜默消失
   —— 一個無關的新增不該因為舊的授權問題而編不過。
4. **0 筆新增不是失敗**(與 `new-project` 相反)。「沒有東西要加」是同步的正常結果。

**驗收標準**(逐條對應 Level 2 契約卡):

- V1 未登記的 `--name`、以及登記了但目錄已不存在的專案,都不動任何檔案、非 0 結束,
  訊息分別指出「未登記」與「目錄不存在」
- V2 預設(無 `--confirm`)不寫磁碟、不寫資料庫,但印出四類筆數與清單;連跑兩次結果一致
- V3 四類判定可被直接測到:同一筆素材在「未登記」「已登記且三個雜湊相同」「來源 sha 改變」
  「磁碟檔案被改 / 被刪」四種狀態下各落入對應類別
- V4 `--confirm` 後只新增「新增」類:已存在的檔案一個位元組都沒變;「來源已更新」與
  「本地已修改」的檔案不被覆蓋,且仍列在回報裡
- V5 `--confirm` 後 `manifest.json` 與 `Assets.hs` 含既有 + 新增的全集,識別字去重規則與
  `new-project` 一致;`SKILL.md`、`README.md`、`<NAME>.cabal` 的內容不變
- V6 `project_assets` 新增列帶 `copied_sha256`,既有列不變;`projects.updated_at` 更新
- V7 授權閘門行為與 `new-project` 完全一致(不可商用與 NULL 都擋;`--allow-non-commercial`
  才放行);被擋下的素材包逐包告知
- V8 授權閘門只擋新增不回溯既有,被降級的既有素材包逐包警告
- V9 0 筆新增時結束碼 0;`--confirm` 下全部新增項都讀取失敗時非 0
- V10 `assetdb project sync --help` 列出全部旗標;`new-project` 的行為與輸出不受影響
- V11 樣板 `SKILL.md` 的「加入新素材」段落改為說明 `project sync` 的用法

**明確不做**(照抄契約卡,不放寬):不刪除、不覆蓋、不搬移專案內任何既有檔案;不提供
「更新到來源新版本」或「還原本地修改」的旗標;不重寫樣板檔案(`SKILL.md` 的樣板**內容**
會改,但同步時**不會**把它重寫到既有專案上);不改 `new-project` 的選素材語意;
不新增 HTTP 端點或前端入口;不做 hardlink 複製模式(`copy_mode` 仍固定 `'copy'`);
不把 `new-project` 改成 `project new`。

## 相依性

`depends-on: [F005]`。本功能與 F005(project-scaffold)共用四樣東西,而且必須逐字相同:

- **選素材的 SQL 語意**(已命名 + `status='active'` + 有 `sha256`,`--pack` 先取包、
  `--match` 再篩名稱、依 `logical_name` 排序)
- **授權閘門**(`nonCommercialPacks`,NULL 與 0 等價)
- **單筆解壓**(`readEntry` 逐筆取出,永遠不整包解開)
- **`manifest.json` / `Assets.hs` 的產生規則**(含識別字去重)

前三項在 F005 是 `AssetDB.Project.Create` 的**私有**函式。本功能不重寫它們(重寫必然漂移,
而漂移的後果是兩條指令對「哪些素材可用」給出不同答案),改為把它們搬到套件內部的共用模組,
`Create` 與 `Sync` 同時引用。第四項的 `renderAssetsModule` 本來就是公開的,直接呼叫。

F001(cli-entrypoint)定義的 `Command` / `invocationInfo` / `resolveDbPathForQuery` 是本功能
擴充的對象。它沒有列進 `depends-on`,原因是編排者在委派時指定了 `depends-on: [F005]`,而
F005 本身 `depends-on: [F001]`,相依關係經 F005 傳遞可達;若編排者要求嚴格反推一致,
建議改為 `[F005, F001]`(見回報的建議事項)。

**可否平行開發**:不可。F005 必須先完成(已 done),且本功能會動到 `Create.hs` 的內部結構,
與任何同時修改 `project` 套件的任務衝突。與 `catalog` / `ingest` / `server` / `web` 的任務
可平行。

## 對應的 Level 2 契約

| Level 2 條目 | 本文件的落實 |
|---|---|
| 對外契約 §3 指令表的 `project sync` 列 | T8 的 `project` 指令群與 `sync` 子指令 |
| §3 跨指令契約「會改動狀態的動作預設只預覽」 | `soConfirm=False` 時 `syncProject` 等同 `planSync`(T5、T6) |
| §3 跨指令契約「授權閘門預設是開的」 | `syAllowNonCommercial` 預設 `False`(T4、T8) |
| §6 專案增量同步(全部條目) | T2–T7 |
| 模組間公開介面 `project` 的 `SyncOptions` / `SyncClass` / `SyncEntry` / `SyncPlan` / `SyncResult` / `SyncError` / `planSync` / `syncProject` | T2–T7,簽名逐字採用 Level 2 的宣告 |
| 模組間公開介面 `cli` 的 `CmdProjectSync` / `SyncArgs` / `runProjectSync` | T8、T9 |
| P6 專案增量同步管線(全段) | 「實作方式」的資料流 |
| P5 的「單筆解壓 → 寫 manifest / `Assets.hs` → 登記」三段 | 共用 `Internal` 的 `copyAssets` / `toManifest`,語意相同 |
| `project` 的 `nonCommercialPacks` / `AssetRef` / `renderAssetsModule` | 只使用,不改簽名 |
| 內部模組劃分表的 `AssetDB.Project.Sync` 一列 | 新模組,職責與不做照抄 |

**未超出範圍的確認**:`project` 套件新增的 **exposed** 模組只有 `AssetDB.Project.Sync`
一個,匯出項與 Level 2 宣告一字不差;共用私有輔助放在 `other-modules` 的
`AssetDB.Project.Internal`,套件外部看不到,因此不構成公開介面的新增(見「待確認假設 A5」
關於 `cli` 側唯一一個超出列舉的匯出)。

## 實作方式

### 資料流(P6 的落地)

```text
assetdb project sync --name N [--pack]… [--match] [--allow-non-commercial] [--confirm]
  → Options 解析成 CmdProjectSync SyncArgs → Main 走「查詢語意」的 resolveDbPathForQuery
  → runProjectSync:discoverTools、由 db 路徑推導 library 根、組出 SyncOptions
  → syncProject:
      1. 定位專案:SELECT id, path FROM projects WHERE name = ?
           查無 → Left (ProjectNotRegistered N)
           目錄不存在 → Left (ProjectDirMissing path)
      2. 候選:selectAssets(與 new-project 同一份 SQL)
      3. 既有登記:project_assets ⋈ assets(取 ulid / dest_rel_path / copied_sha256 / 來源 sha256)
      4. 四類判定(逐筆,見下)
      5. 授權閘門:只對「新增」類的素材包呼叫 nonCommercialPacks
           被擋的整包從 entries 移除 → spBlocked
           既有登記素材所屬的不可商用素材包 → 只經 soOnEvent 逐包警告,不移除
      6. 產出 SyncPlan(到此為止完全沒有寫入)
      7. soConfirm=False → SyncResult plan 0 []  ← 預覽結束
      8. soConfirm=True:
           a. copyAssets:逐筆 readEntry → 寫 assets/<kind 預設目錄>/<邏輯名稱><副檔名>
           b. registerAdditions:只 INSERT 成功複製的列(含 copied_sha256),
              **不 DELETE**;同一交易內更新 projects.updated_at
           c. 重讀 project_assets 的全集 → 重寫 assets/manifest.json 與 assets/Assets.hs
           d. SyncResult plan (length copied) (讀取失敗訊息)
  → runProjectSync 印出四類筆數與清單、被擋 / 被警告的素材包、複製與失敗筆數
  → 結束碼:定位失敗非 0;--confirm 且有新增項但全部讀取失敗非 0;其餘 0
```

### 四類判定(對帳的核心)

輸入是一筆候選素材的 `ulid`、它在 `project_assets` 的登記(若有)與磁碟現況:

| 條件 | 類別 |
|---|---|
| `ulid` 不在 `project_assets` | `SyncNew` |
| 有登記,但 `<專案目錄>/<dest_rel_path>` 不存在 | `SyncLocallyModified` |
| 有登記,磁碟檔案大小 ≠ `copied_sha256` 對應的 `blobs.bytes` | `SyncLocallyModified`(不必讀檔) |
| 有登記,磁碟 SHA-256 ≠ `copied_sha256` | `SyncLocallyModified` |
| 有登記,磁碟 SHA-256 = `copied_sha256` = `assets.sha256` | `SyncUnchanged` |
| 有登記,磁碟 SHA-256 = `copied_sha256` ≠ `assets.sha256` | `SyncSourceUpdated` |

「磁碟檔案雜湊」一律取 `AssetDB.Ingest.Hash.sha256File`(決策 D1)—— delivery 不自行實作
摘要,內容識別在全系統只有一種定義(ADR-002)。大小優先的短路見「實作備註」。

`copied_sha256` 為 NULL 的列(手改過的資料庫或未來的 legacy 列)沒有比對基準,退回與
`assets.sha256` 比:相同算 `SyncUnchanged`,不同算 `SyncLocallyModified`(見待確認假設 A4)。

`spEntries` 只包含**候選**素材。已登記但不符合本次 `--pack` / `--match` 條件的素材不列入
四類清單,但**仍然屬於重寫 manifest 的全集** —— 這兩件事的集合不同,不可以合成一個查詢。

### 重寫 manifest 與 `Assets.hs`

`--confirm` 的寫入完成後,**重讀資料庫**取全集,而不是在記憶體裡合併「既有 + 新增」:
合併邏輯會與登記邏輯漂移,而重讀天然保證「manifest 描述的就是登記的」。

```sql
SELECT a.ulid, a.logical_name, a.kind, a.meta_json, p.slug, l.name,
       pa.dest_rel_path, COALESCE(pa.copied_sha256, a.sha256)
FROM project_assets pa
JOIN assets a ON a.id = pa.asset_id
LEFT JOIN packs p ON p.id = a.pack_id
LEFT JOIN licenses l ON l.id = p.license_id
WHERE pa.project_id = ?
ORDER BY a.logical_name
```

三個刻意的選擇:

- **路徑取 `pa.dest_rel_path`,不重算**。重算會在命名規則變動後把既有素材指到一個不存在的
  新路徑上。
- **`maSha256` 取 `copied_sha256`**。manifest 描述的是專案目錄裡的那份檔案,不是來源的最新版;
  取來源 sha 會讓「來源已更新」的項目在 manifest 裡宣稱一個磁碟上並不存在的雜湊(A2)。
- **`packs` 走 LEFT JOIN**(`assets.pack_id` 可為 NULL)。少一筆就少一個 `AssetKey` 常數,
  而那會讓遊戲端編不過。`selectAssets` 對候選用的是 INNER JOIN,那是 F005 的既有語意,不動。

`Assets.hs` 直接餵給既有的 `renderAssetsModule`,識別字去重與排序規則因此與 `new-project`
**同一份實作**,不是「行為相同的另一份」(V5)。`manifest.json` 的 `packs` / `licenses`
區塊沿用 `manifestPacks` / `manifestLicenses`,輸入是全集的素材包 slug 去重後的清單。

樣板檔案(`SKILL.md`、`README.md`、`docs/*`、`.gitattributes`、`.gitignore`、
`theme.json`、`<NAME>.cabal`)**一個都不重寫**,連內容相同也不寫 —— 使用者手改過樣板是
預期中的事。

### 錯誤處理

- 邊界回 `Either SyncError`,不讓例外穿越子系統邊界(system.md 全域策略 1);訊息在 CLI 側
  組成繁體中文,`SyncError` 本身只帶資料。
- 單筆讀取失敗記錄後續跑(策略 2 的「單筆失敗」),訊息用既有的 `renderArchiveError`。
- 破壞性動作預設 dry-run(策略 3):`--confirm` 之前不開啟任何寫入交易。
- 登記與 `updated_at` 更新放在同一個 `withTransaction` 內,避免出現「檔案寫了但沒登記」與
  「登記了但時間戳沒動」的中間狀態。

### 共用私有輔助的搬移(T1)

`Create.hs` 目前的私有定義中,`Sync` 需要的是:`Pick`(含 `FromRow`)、`selectAssets`、
`copyAssets`、`toManifest`、`manifestPacks`、`manifestLicenses`、`extOf`、`writeUtf8`、
`writeUtf8Bytes`。把這些搬進新的 `AssetDB.Project.Internal`(cabal 的 `other-modules`,
**不 exposed**),`Create` 改為 import。`packCredits`、`cabalFile`、`registerProject`
留在 `Create` —— `Sync` 不寫樣板、不寫 cabal、也不能用那條刪光重灌的登記路徑。

搬移是純粹的位置調整,不改任何一行邏輯;`new-project` 的行為不變由既有測試把關(V10)。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `nonCommercialPacks :: Connection -> [Text] -> IO [Text]` | `project/src/AssetDB/Project/Create.hs:201` | F005 | 授權閘門,只餵「新增」類的素材包 slug |
| `data AssetRef = AssetRef { arKey :: Text, arPath :: Text, arPack :: Maybe Text }` | `project/src/AssetDB/Project/Assets.hs:22` | F005 | 組出重寫 `Assets.hs` 的輸入 |
| `renderAssetsModule :: Text -> [AssetRef] -> Text` | `project/src/AssetDB/Project/Assets.hs:51` | F005 | 以全集重新產生 `Assets.hs`(去重與排序在它內部) |
| `sha256File :: FilePath -> IO Sha256` | `ingest/src/AssetDB/Ingest/Hash.hs:43` | - | 對帳時計算磁碟檔案的內容雜湊(D1) |
| `unSha256 :: Sha256 -> Text` | `ingest/src/AssetDB/Ingest/Hash.hs:33` | - | 與資料庫存的十六進位字串比對 |
| `readEntry :: ArchiveTools -> FilePath -> Text -> IO (Either ArchiveError ByteString)` | `archive/src/AssetDB/Archive.hs:110` | - | 單筆解壓(經共用的 `copyAssets`) |
| `newtype ArchiveTools = ArchiveTools { atSevenZip :: Maybe SevenZip }` | `archive/src/AssetDB/Archive.hs:35` | - | `syncProject` 的參數 |
| `discoverTools :: IO ArchiveTools` | `archive/src/AssetDB/Archive.hs:41` | - | CLI runner 取得工具 |
| `renderArchiveError :: ArchiveError -> Text` | `archive/src/AssetDB/Archive/Types.hs:115` | - | 讀取失敗訊息(經共用的 `copyAssets`) |
| `data Store = Store { storeConn :: Connection, storePath :: FilePath }` | `store/src/AssetDB/Store.hs:27` | - | 取 `Connection` 下 SQL |
| `withStore :: FilePath -> (Store -> IO a) -> IO a` | `store/src/AssetDB/Store.hs:48` | - | CLI runner 開庫 |
| `initSchema :: Store -> IO [Migration]` | `store/src/AssetDB/Store.hs:73` | - | CLI runner 套用 migration(與 `runNewProject` 同) |
| `data Manifest = Manifest { mSchemaVersion :: Int, mProject :: Text, mGeneratedAt :: UTCTime, mAssets :: [ManifestAsset], mPacks :: [ManifestPack], mLicenses :: [ManifestLicense] }` | `core/src/AssetDB/Manifest.hs:55` | - | 重寫 `manifest.json` |
| `data ManifestAsset = ManifestAsset { maId :: ULID, maKey :: LogicalName, maPath :: Text, maKind :: AssetKind, maSha256 :: Text, maPack :: Maybe Text, maLicense :: Maybe Text, maMeta :: Value }` | `core/src/AssetDB/Manifest.hs:74` | - | 全集的每一筆 |
| `currentSchemaVersion :: Int` | `core/src/AssetDB/Manifest.hs:52` | - | manifest 的 schema 版本欄位 |
| `parseULID :: Text -> Either Text ULID` | `core/src/AssetDB/Id.hs:107` | - | `toManifest` 內的 ulid 還原 |
| `validateLogicalName :: Text -> Either NameError LogicalName` | `core/src/AssetDB/Naming.hs:313` | - | `toManifest` 內的 key 驗證 |
| `extensionOf :: Text -> Text` | `core/src/AssetDB/PathText.hs:37` | - | 新增項的目的檔名副檔名 |
| `kindDefaultDir :: AssetKind -> Text` | `core/src/AssetDB/Types.hs:93` | - | 新增項的目的目錄 |
| `parseTextEnum :: forall a. TextEnum a => Text -> Either Text a` | `core/src/AssetDB/Types.hs:54` | - | 資料庫的 kind 字串還原成 `AssetKind` |
| `projects` 表:`id / ulid / name UNIQUE / path UNIQUE / template / created_at / updated_at` | `store/src/AssetDB/Store/Schema.hs:322` | - | 以 `name` 定位專案、更新 `updated_at` |
| `project_assets` 表:`project_id / asset_id / dest_rel_path / copy_mode CHECK IN ('copy','hardlink') / copied_sha256 / added_at`,`PRIMARY KEY (project_id, asset_id)`,`UNIQUE (project_id, dest_rel_path)` | `store/src/AssetDB/Store/Schema.hs:333` | - | 既有登記查詢與新增列 |
| `blobs` 表:`sha256 PRIMARY KEY / bytes NOT NULL / …` | `store/src/AssetDB/Store/Schema.hs:163` | - | D3 大小優先短路的期望大小來源 |
| `data Command = … \| CmdNewProject ProjectArgs \| …` | `cli/app/AssetDB/Cli/Options.hs:57` | F001 | 加一個 `CmdProjectSync SyncArgs` 建構子 |
| `invocationInfo :: ParserInfo Invocation` | `cli/app/AssetDB/Cli/Options.hs:117` | F001 | 指令文法的可測入口(`execParserPure`) |
| `runNewProject :: FilePath -> ProjectArgs -> IO ()` | `cli/app/AssetDB/Cli/Project.hs:20` | F001 / F005 | `runProjectSync` 沿用它的形狀、library 根推導與輸出風格 |
| `resolveDbPathForQuery :: GlobalArgs -> IO FilePath` | `cli/app/AssetDB/Cli/Options.hs`(Level 2 宣告) | F001 | `project sync` 是查詢語意,資料庫必須已存在 |
| `templateFiles :: Text -> Text -> [TemplateFile]`(其中 `skillMd` 的「加入新素材」段落) | `project/src/AssetDB/Project/Template.hs:44` | F005 | V11 改寫該段落文字 |

## 新增的介面

### `project` 套件:`AssetDB.Project.Sync`(新 exposed 模組)

```haskell
module AssetDB.Project.Sync
  ( SyncOptions (..)
  , SyncClass (..)
  , SyncEntry (..)
  , SyncPlan (..)
  , SyncResult (..)
  , SyncError (..)
  , planSync
  , syncProject
  ) where

data SyncOptions = SyncOptions
  { soName :: Text                 -- ^ 專案名稱,即 projects.name
  , soLibraryRoot :: FilePath      -- ^ 素材庫根目錄,壓縮檔相對路徑的基準
  , soPacks :: [Text]              -- ^ --pack,可重複;空清單代表不限素材包
  , soQuery :: Maybe Text          -- ^ --match,邏輯名稱的子字串
  , soAllowNonCommercial :: Bool   -- ^ 關掉授權閘門
  , soConfirm :: Bool              -- ^ False 時不寫磁碟、不寫資料庫
  , soOnEvent :: Text -> IO ()     -- ^ 進度與警告
  }

-- | 對帳的四類。順序即回報的呈現順序。
data SyncClass = SyncNew | SyncUnchanged | SyncSourceUpdated | SyncLocallyModified
  deriving stock (Eq, Show)

data SyncEntry = SyncEntry
  { seUlid :: Text
  , seName :: Text        -- ^ 邏輯名稱
  , seRelPath :: Text     -- ^ 專案根目錄的相對路徑,永遠以 / 分隔
  , seClass :: SyncClass
  }
  deriving stock (Eq, Show)

data SyncPlan = SyncPlan
  { spProjectPath :: FilePath
  , spEntries :: [SyncEntry]   -- ^ 只含本次候選素材,依邏輯名稱排序
  , spBlocked :: [Text]        -- ^ 被授權閘門擋下的素材包(只影響新增)
  }
  deriving stock (Eq, Show)

data SyncResult = SyncResult
  { syPlan :: SyncPlan
  , syCopied :: Int
  , sySkipped :: [Text]        -- ^ 讀取失敗的訊息
  }
  deriving stock (Eq, Show)

data SyncError = ProjectNotRegistered Text | ProjectDirMissing FilePath
  deriving stock (Eq, Show)

-- | 只對帳,不寫磁碟也不寫資料庫。可重複執行,結果相同。
planSync :: Store -> SyncOptions -> IO (Either SyncError SyncPlan)

-- | soConfirm = False 時等同 'planSync'(包成 @SyncResult plan 0 []@)。
syncProject :: Store -> ArchiveTools -> SyncOptions -> IO (Either SyncError SyncResult)
```

### `project` 套件:`AssetDB.Project.Internal`(新 other-module,套件外不可見)

由 `Create` 搬移而來、`Create` 與 `Sync` 共用的私有輔助:`Pick`(含 `FromRow`)、
`selectAssets`、`copyAssets`、`toManifest`、`manifestPacks`、`manifestLicenses`、
`extOf`、`writeUtf8`、`writeUtf8Bytes`。**不是公開介面** —— 不在 `exposed-modules`,
套件外(含測試套件)引用不到,因此不構成 Level 2 契約的新增。內部簽名與命名屬實作自主權,
不在本文件鎖死。

### `cli` 套件:`AssetDB.Cli.Project` 新增

```haskell
data SyncArgs = SyncArgs
  { syName :: Text
  , syPacks :: [Text]
  , syQuery :: Maybe Text
  , syAllowNonCommercial :: Bool
  , syConfirm :: Bool
  }

runProjectSync :: FilePath -> SyncArgs -> IO ()

-- | 結束碼的判定單獨抽出來,理由與 'nonCommercialPacks' 相同:
-- 它是易錯的判斷(0 新增是成功、全部讀取失敗是失敗),而走到它需要一整組
-- 真實壓縮檔。見「待確認假設 A5」。
syncExitCode :: SyncArgs -> SyncResult -> ExitCode
```

欄位前綴用 `sy`,與同模組的 `ProjectArgs`(`pa`)以及 `AssetDB.Project.Sync` 匯出的
`syPlan` / `syCopied` / `sySkipped` 都不撞名(GHC2021 沒有 `DuplicateRecordFields`)。

### `cli` 套件:`AssetDB.Cli.Options` 新增

```haskell
data Command = … | CmdProjectSync SyncArgs | …
```

指令文法新增一個 `project` 指令群(`hsubparser`,與既有的 `pack` / `cluster` / `note` /
`ai` 同形),底下目前只有 `sync` 一個子指令。`new-project` 維持原名不動。旗標:
`--name`(必填)、`--pack`(可重複)、`--match`、`--allow-non-commercial`、`--confirm`。
`Options` 由 `AssetDB.Cli.Project` 再匯出 `SyncArgs (..)`。

### `cli` 套件:`main/Main.hs` 新增一條 dispatch

```haskell
CmdProjectSync a -> forQuery >>= \db -> runProjectSync db a
```

### 套件設定變更

- `project/assetdb-project.cabal`:`exposed-modules` 加 `AssetDB.Project.Sync`;
  新增 `other-modules: AssetDB.Project.Internal`;`build-depends` 加 `assetdb-ingest`
  (只為了 `sha256File`;`assetdb-ingest` 只依賴 archive / core / store,不產生循環)。
  測試套件加 `AssetDB.Project.SyncSpec` 與 `assetdb-archive`、`bytestring`、`directory`、
  `filepath`、`temporary` 相依。
- `cli/assetdb-cli.cabal`:library 不需要新相依(`assetdb-project` 已在);
  測試套件加 `assetdb-project`(讓 `syncExitCode` 的測試組得出 `SyncResult` 值)。

## TodoList

- [ ] T1: 把 `Create` 與 `Sync` 共用的私有輔助搬到 `AssetDB.Project.Internal`(other-module),
      `Create` 改為 import;cabal 加 `assetdb-ingest` 相依與 `other-modules`  `dep: F005`
- [ ] T2: 建立 `AssetDB.Project.Sync`,定義六個型別並實作專案定位
      (`ProjectNotRegistered` / `ProjectDirMissing`,兩者都不動任何檔案)  `dep: T1`
- [ ] T3: 對帳:既有登記查詢 + 磁碟狀態(大小優先短路 → `sha256File`)+ 四類判定  `dep: T2`
- [ ] T4: 授權閘門:只對「新增」類呼叫 `nonCommercialPacks`;既有素材包降級改走
      `soOnEvent` 逐包警告  `dep: T3`
- [ ] T5: `planSync` 組裝與 `syncProject` 的預覽分支(`soConfirm=False` 時不寫磁碟、
      不寫資料庫、可重複執行)  `dep: T4`
- [ ] T6: `syncProject` 的 `--confirm` 寫入:`copyAssets` 逐筆解壓新增項、只 INSERT 不 DELETE
      的登記(含 `copied_sha256`)、同交易更新 `projects.updated_at`  `dep: T5`
- [ ] T7: 以重讀的登記全集重寫 `assets/manifest.json` 與 `assets/Assets.hs`;樣板檔案與
      `<NAME>.cabal` 一律不重寫  `dep: T6`
- [ ] T8: CLI 文法:`SyncArgs`、`project` 指令群與 `sync` 子指令、`CmdProjectSync`、
      `Main.hs` 的 dispatch(走查詢語意)  `dep: T2`
- [ ] T9: CLI runner `runProjectSync`:四類筆數與清單、被擋/被警告素材包、複製與失敗筆數的
      輸出,以及 `syncExitCode` 的結束碼規則  `dep: T6, T8`
- [ ] T10: 樣板 `SKILL.md` 的「加入新素材」段落改寫為 `project sync` 的用法  `dep: -`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `AssetDB.Project.CreateSpec` / `TemplateSpec` / `AssetsSpec` 全數維持綠燈(重構回歸) | 搬移沒有改變 `new-project` 的任何行為(V10) |
| T2 | `SyncSpec`「專案定位」:未登記的 `--name` 回 `ProjectNotRegistered`;登記了但目錄不存在回 `ProjectDirMissing`;兩者都不建立任何檔案、不改資料庫 | V1 |
| T3 | `SyncSpec`「四類判定」:同一筆素材分別佈置成未登記 / 三雜湊相同 / 來源 sha 改變 / 磁碟檔案被改 / 磁碟檔案被刪,各自落入 `SyncNew` / `SyncUnchanged` / `SyncSourceUpdated` / `SyncLocallyModified`;另加一條「大小不同時不讀檔也判為 `SyncLocallyModified`」 | V3 + D3 |
| T4 | `SyncSpec`「授權閘門」:不可商用與 NULL 授權的新增項都被擋且列入 `spBlocked`;`soAllowNonCommercial=True` 時全部放行;**既有登記素材的素材包不可商用時仍留在 entries、不進 `spBlocked`,而是出現在 `soOnEvent` 捕捉到的警告裡** | V7、V8 |
| T5 | `SyncSpec`「預覽」:`soConfirm=False` 執行後專案目錄的檔案清單與內容位元組全部不變、`project_assets` 與 `projects.updated_at` 不變;連跑兩次 `planSync` 得到相同的 `SyncPlan` | V2 |
| T6 | `SyncSpec`「confirm 的寫入邊界」:以「新增項的來源壓縮檔無法讀取」佈置,驗證既有檔案一個位元組都沒變、「來源已更新」與「本地已修改」的檔案未被覆蓋且仍列在 entries、`project_assets` 既有列(`dest_rel_path` / `copied_sha256` / `added_at`)完全不變且沒有多出新列、`projects.updated_at` 已更新 | V4、V6(可及的部分,缺口見 A3) |
| T7 | `SyncSpec`「重寫全集」:`--confirm` 後 `manifest.json` 的 `assets` 含全部登記素材(含不符合本次條件的那些)、`schemaVersion` 正確、每筆 `path` 等於登記的 `dest_rel_path`、`sha256` 等於 `copied_sha256`;`Assets.hs` 每筆一個常數且識別字撞名時去重;`SKILL.md` / `README.md` / `<NAME>.cabal` 的位元組不變 | V5 |
| T8 | `AssetDB.Cli.ParserSpec`「project sync」:`project sync --help` 以成功結束且列出 `--name` / `--pack` / `--match` / `--allow-non-commercial` / `--confirm`;缺 `--name` 解析失敗;`--pack` 可重複並保留順序;沒有 `--confirm` 時 `syConfirm == False`、沒有 `--allow-non-commercial` 時 `syAllowNonCommercial == False`;`new-project` 的解析結果不受影響 | V10、§3 的兩條跨指令契約 |
| T9 | `AssetDB.Cli.ProjectSpec`「syncExitCode」:0 筆新增 → `ExitSuccess`;`--confirm` 且有新增項但 `syCopied == 0` 且 `sySkipped` 非空 → 非 0;`--confirm` 且部分成功 → `ExitSuccess`;無 `--confirm` 時永遠 `ExitSuccess`。另在 `EndToEndSpec` 加一條:對已初始化的資料庫執行 `project sync --name <未登記>` 以非 0 結束 | V9、V1 的 CLI 側 |
| T10 | `AssetDB.Project.TemplateSpec`:`SKILL.md` 的「加入新素材」段落含 `assetdb project sync` 且**不再**含「尚未實作」 | V11 |

## 待確認假設

- A1: 「既有登記素材的素材包授權降級」的警告要放哪裡 → 採取:`SyncPlan` 只有
  `spBlocked` 一個欄位,而那些素材**沒有被擋**,放進去會讓語意變質;改為在 `planSync`
  內經 `soOnEvent` 逐包發出警告(測試以 `IORef` 捕捉)→ 影響:若編排者希望它成為結構化
  資料,要在 Level 2 給 `SyncPlan` 加一個欄位(例:`spWarnedPacks :: [Text]`),
  屬於契約變動。
- A2: `manifest.json` 的 `maSha256` 對既有素材取 `copied_sha256` 而非來源 `assets.sha256`;
  且 `--confirm` 即使 0 筆新增也重寫 `manifest.json` / `Assets.hs`(時間戳會變) →
  採取:如上 → 影響:若改取來源 sha,「來源已更新」的項目會在 manifest 裡宣稱一個磁碟上
  不存在的雜湊;若要求 0 新增時不重寫,T7 的測試與 `syncProject` 的寫入分支要加條件。
- A3: `--confirm` 下**真的複製成功**的路徑沒有自動化測試 → 採取:遵守決策 D4
  (壓縮檔解壓的 IO 路徑不直接測,沿用 `project` 套件既有風格 —— `copyAssets` 在 F005
  也沒有測試),T6 改以「新增項讀取失敗」與「0 筆新增」兩條路徑覆蓋 confirm 分支 →
  影響:「`project_assets` 新增列帶 `copied_sha256`」只能靠人工驗收;要補上的話,最小
  成本是在 `project` 測試套件加一個 stored ZIP fixture(`zip` 套件已是 `assetdb-archive`
  的相依),或在 `EndToEndSpec` 建一個含真實 ZIP 的暫存素材庫跑完整流程。
- A4: `project_assets.copied_sha256` 為 NULL 的列如何判定 → 採取:退回與 `assets.sha256`
  比對,相同算 `SyncUnchanged`、不同算 `SyncLocallyModified`(保守:永遠不覆蓋)→
  影響:`createProject` 一律寫入 `copied_sha256`,此分支只在手改資料庫時觸發;若要求
  一律視為 `SyncLocallyModified`,改一行判定即可。
- A5: `AssetDB.Cli.Project` 匯出 `syncExitCode` 超出契約卡列舉的 `SyncArgs` /
  `runProjectSync` → 採取:比照 `nonCommercialPacks` 的先例匯出(結束碼規則是易錯且有
  契約意義的判斷,而 `runProjectSync` 會呼叫 `exitFailure`,測不動)→ 影響:建議編排者
  在 `design.md` 的 `cli` 模組介面補上這一行;若不接受,T9 只剩 `EndToEndSpec` 那一條,
  「0 筆新增結束碼 0」將無法在不建 ZIP fixture 的情況下測到。

## 實作備註

- **D3 大小優先**:對帳時先比檔案大小 —— 磁碟檔案大小與 `copied_sha256` 對應的
  `blobs.bytes` 不同就直接判定「本地已修改」,大小相同才真的讀檔算 SHA-256。正確性不變
  (大小不同必然內容不同),但多數情況下省掉整批 IO:一個 300 筆素材的專案在「沒有東西
  要加」時,原本要讀 300 個檔案,現在只要讀 `stat`。`blobs` 查不到對應列時(理論上不會,
  `assets.sha256` 有外鍵指向它)退回直接讀檔算雜湊,不因為缺一筆中繼資料就誤判。
  這是實作策略,**不是 Level 2 契約的一部分**,對外行為與逐筆算雜湊完全相同。
- 大小取 `System.Directory.getFileSize :: FilePath -> IO Integer`,`blobs.bytes` 是
  `INTEGER`,比對前統一成 `Integer`。
- 四類判定寫成不碰 IO 的純函式(輸入:登記的 `copied_sha256` / 來源 `sha256` / 磁碟狀態),
  由 `planSync` 餵它;它不單獨匯出,測試經 `planSync` 對著真實 SQLite 暫存庫與真實暫存
  目錄驅動(決策 D4 的「純函數 + 真實 SQLite 暫存庫」)。
- `registerAdditions` 用 `INSERT OR IGNORE`(與 `registerProject` 同),讓
  `PRIMARY KEY (project_id, asset_id)` 與 `UNIQUE (project_id, dest_rel_path)` 自然吸收
  重複;`copy_mode` 固定 `'copy'`。**絕對不能出現 `DELETE FROM project_assets`** ——
  那是 `createProject` 的路徑,在同步語意下等於把整個專案的登記洗掉。
- `soLibraryRoot` 由 CLI 以 `takeDirectory (takeDirectory dbPath) </> "library"` 推導,
  與 `runNewProject` 完全相同的算法。
- 所有寫檔一律走共用的 `writeUtf8` / `writeUtf8Bytes`(UTF-8 位元組),`Data.Text.IO` 在
  Windows 上用 locale 編碼,寫不出中文與符號。
