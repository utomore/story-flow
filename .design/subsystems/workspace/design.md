---
id: workspace
type: subsystem
title: workspace
description: 工具自己的狀態:中樞註冊表、vault 探測與作用範圍裁決、本機設定與外部工具
status: active
created: 2026-08-29
updated: 2026-09-04
parent: system
related-adr: [ADR-008, ADR-014, ADR-017]
code-paths: [workspace/src]
---

# 全局中樞(workspace)子系統架構

## 定位與範圍

主架構「子系統劃分 › 地基 › `workspace`」。這個子系統管的不是資料,是**工具自己**:這台機器上
有哪些 vault 與專案、它們現在在哪、外部工具在不在、本機設定是什麼,以及每一次指令**對哪些
vault 生效**。ADR-017 的「讀跨、寫單一」在這裡被實體化成三個裁決函式。

涵蓋一個套件:

| 元件 | 職責 | IO |
|---|---|---|
| `aapms-workspace` | 中樞註冊表讀寫、vault 探測與 selector 解析、作用範圍裁決、vault 與專案的生命週期、本機設定與外部工具探測 | 檔案系統(TOML、目錄走訪、執行檔探測) |

相依:`aapms-core`(`VaultId` / `Id` / `Sha256` / `newId` / `parseId`)、`aapms-store`
(`readMarker` / `VaultMarker` / `VaultKind` / `initVaultAt` / `indexDbPath`)、`toml-reader`。
**不依賴 `aapms-service` 以上的任何套件**——「地基不認識上面」由 `CabalSpec` 逐字釘住。

> **2026-08-29 裁決,修訂 system.md 原文**:主架構原本寫 `aapms-workspace`「刻意輕量:只依賴
> `aapms-core` 與 TOML 解析」。這句與同一節的「vault 探測」「讀跨寫單一的**裁決點**」互斥:
> vault 的身分(`id` / `kind` / `name` / `refs`)住在 `.aapms/config.toml`,而讀它的 `readMarker`
> 已經實作在 `aapms-store`(graph-core F005,已交付),graph-core 那份 `design.md` 也明寫
> 「vault 探測與中樞註冊表不是我的事」。裁決是**讓 workspace 依賴 `aapms-store`**,裁決點整段留在
> 這裡,graph-core 一行不動。「輕量」那句的原始理由(legacy assetdb 的硬規則「server 只准依賴
> core + store」)在 aapms 已經不存在——現在的硬規則只擋 `archive` / `ingest` / `reorg`,而
> `aapms-server` 本來就經 `service` 依賴 `aapms-store`。

**明確不做**:

- **vault 裡面裝什麼**。不讀索引內容、不解析 Markdown、不開 SQLite 連線。本子系統只回答
  「去開這個路徑」,`openVault` / `openVaultSet` 由 `service` 呼叫 graph-core 完成
- **任何業務判斷**。「這個指令屬於讀還是寫」由呼叫端(`service`)選擇呼叫哪一個裁決函式;
  本子系統只依 ADR-017 的規則把它換算成 vault 集合
- **`[llm]` 段的語意**。中樞持有並原樣捧出那張 TOML 表,鍵名、必填、預設值屬 `ai` 子系統
  (沿用 legacy `vaultConfig` 不解讀的做法)
- **ATTACH 上限的判斷**。graph-core 契約 E 的 `maxAttachedVaults` / `TooManyVaults` 已經擁有這個
  事實,本子系統不重複一份
- **縮圖的產生與讀取**。只擁有「快取在哪」這一個事實;寫是 `asset-ingest`、讀是 `shell`

**與 legacy 的關係**:story-flow 的 vault 探測與註冊表(現凍結於 `service/src/Aapms/Service/Monad.hs`
的 `vaultsFile` / `openEnv`)與 legacy assetdb ADR-011 / ADR-012 的設計(當時未實作)在此合流。
`~/.config/story-flow/vaults.toml` 與 `STORYFLOW_VAULTS` 一併作廢。

## 對外契約(Public Interface & DTOs)

消費者只有一個:**`service`**(全部介面)。`shell` 不直接 import 本套件——它只把 `--vault` 的字串
原樣交給 `service`(ADR-015 第三條:`shell` 零業務邏輯)。

### A. 中樞位置與載入

```haskell
data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }
data HubSource   = FromEnv | FromPlatformDefault
data Hub                                        -- 已載入的中樞快照,不可變;**建構子不外露**

hubLocation :: IO HubLocation
loadHub     :: HubLocation -> IO (Either WorkspaceError Hub)
saveHub     :: HubLocation -> Hub -> IO (Either WorkspaceError ())   -- 原子寫入

-- 2026-08-29 WAVE-1 閘門裁決:Hub 做成不透明型別,建構與底稿各留一個入口
mkHub         :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text -> Hub
hubSourceText :: Hub -> Text                    -- 這次載入時的原始檔案文字,saveHub 的底稿
```

| 欄位 / 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `hlPath` | FilePath | 絕對路徑,指向**目錄**(不是 `config.toml`) | 中樞根目錄 |
| `hlSource` | Enum | `FromEnv`(`AAPMS_HOME` 已設且非空)/ `FromPlatformDefault` | 這個位置怎麼決定的;`doctor` 要印出來 |
| `mkHub` 的第五參數 / `hubSourceText` | Text | 這次載入時 `config.toml` 的**逐字內容**;`mkHub` 造空中樞時為空字串 | `saveHub` 的底稿。四個純增刪函式**只動結構化的四段、不動它**,差異由 `saveHub` 一次收斂——「既有列的順序、註解與空白行原樣保留」(ADR-017 決策二)靠這條成立 |

`Hub` **不外露建構子**(2026-08-29 WAVE-1 閘門裁決):它捧著「底稿」與「解析出來的四段」兩半,
兩者必須來自同一次載入。攤開欄位就沒有任何東西守這個不變量,而 `saveHub` 會照著一個不一致的
快照把使用者手寫的檔案寫壞——那是一條不會報錯的資料損毀路徑。被否決的替代方案:`Hub (..)`
全欄位匯出(照抄 graph-core `VaultHandle` 的先例,成本零,代價就是上面那條路徑)。

**`loadHub` 的合規判準**(2026-08-29 WAVE-1 閘門裁決,補契約卡驗收標準沒點名的三種情況):
對**工具自己寫得出來的欄位從嚴**——`veName` / `peName` 去空白後為空、或 `veId` / `peId` 在中樞內
重複,一律 `HubMalformed`(重複 id 的立場與 graph-core 契約 G 對重複 `vmId` 的處置一致:身分不
確定時,任何以 id 為鍵的操作都是不確定的);對**工具不認識的東西從寬**——未知的鍵與未知的頂層
段一律容忍且由 `saveHub` 原樣保留,不是 `HubMalformed`。理由是中樞依 ADR-017 決策二是「可手寫」
的檔案:嚴格拒收未知段落會讓新版寫出的檔案被舊版判成壞檔,也會拒掉使用者自己加的註記。

`hubLocation` 的解析順序固定兩層:環境變數 `AAPMS_HOME` 非空 → 用它;否則平台預設
(Windows `%APPDATA%\aapms`,其他平台 XDG `$XDG_CONFIG_HOME/aapms`,該變數未設時 `~/.config/aapms`)。
**沒有第三層、不搜尋、不猜**。`loadHub` 在檔案不存在時回 `HubNotFound`,**不回空中樞**——
空註冊表會把「你還沒跑 `workspace setup`」偽裝成「你一個 vault 都沒有」(主架構全域錯誤策略第 3 條)。

### B. 中樞內容

```haskell
data VaultEntry = VaultEntry
  { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }

data ProjectEntry = ProjectEntry
  { peId :: Id, peName :: Text, pePath :: FilePath }

newtype LlmSection = LlmSection (Map Text TOML.Value)      -- 原樣的 TOML 表,不解讀
data ToolsConfig   = ToolsConfig { tcSevenZip :: Maybe FilePath }

hubVaults   :: Hub -> [VaultEntry]
hubProjects :: Hub -> [ProjectEntry]
hubLlm      :: Hub -> Maybe LlmSection
hubTools    :: Hub -> ToolsConfig

thumbCacheDir  :: HubLocation -> FilePath
thumbCachePath :: HubLocation -> Sha256 -> FilePath
```

`VaultEntry`(中樞 `[[vaults]]` 的一列):

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `veId` | VaultId | `vlt-` + 8 位小寫十六進位;中樞內唯一 | **鍵**。搬動 vault 只改 `vePath`,身分不變(ADR-017 決策二) |
| `veName` | Text | 非空;**允許重複**(重複時以名稱查回 `VaultSelectorAmbiguous`) | marker `vmName` 的**快取**,不是真相 |
| `veKind` | Enum | `AssetVault` / `StoryVault` | marker `vmKind` 的**快取**,不是真相 |
| `vePath` | FilePath | 絕對路徑,指向 vault 根目錄(**含** `.aapms/` 的那一層) | 目前位置;路徑不是身分 |

`ProjectEntry`(中樞 `[[projects]]` 的一列):

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `peId` | Id | `prj-` + 8 位小寫十六進位;中樞內唯一 | 鍵 |
| `peName` | Text | 非空 | 專案名 |
| `pePath` | FilePath | 絕對路徑,指向含 `assets/` 與 `story/` 的那一層 | 專案根目錄 |

`ToolsConfig`(中樞 `[tools]` 段):

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `tcSevenZip` | Maybe FilePath | 絕對路徑;`Nothing` = **沒有覆寫**(去探測),不是「沒有 7-Zip」 | 使用者指定的 7-Zip 執行檔位置 |

`LlmSection`:**鍵與語意屬 `ai` 子系統**,本子系統只保證「TOML 表裡有什麼,捧出來就有什麼」。
`Nothing`(整段缺席)與 `Just` 空表是**不同的兩件事**:前者是沒設定,後者是設了一個空段。

`thumbCachePath loc (Sha256 h)` = `<hlPath>/cache/thumbs/<h 的前 2 個字元>/<h>.png`。分片是前兩碼、
副檔名固定 `.png`(內容定址快取,ADR-017 決策七)。`h` 是 64 位小寫十六進位。

### C. 探測與作用範圍裁決

```haskell
data VaultRef = VaultRef
  { vrEntry  :: Maybe VaultEntry     -- 中樞裡的那一列;未註冊的 vault 為 Nothing
  , vrPath   :: FilePath             -- 絕對路徑,已正規化
  , vrMarker :: VaultMarker }        -- 權威的 id / kind / name / refs

data ScopeIssue
  = VaultPathMissing      VaultEntry FilePath
  | VaultMarkerBroken     VaultEntry StoreError
  | VaultIdDrift          VaultEntry VaultId          -- 註冊表的 id、marker 實際的 id
  | RefVaultNotRegistered VaultId VaultId             -- 來源 vault、refs 裡查不到的目標

data ReadScope     = ReadScope     { rsVaults :: [VaultRef], rsIssues :: [ScopeIssue] }
data WriteScope    = WriteScope    { wsTarget :: VaultRef, wsRead :: [VaultRef], wsIssues :: [ScopeIssue] }
data PipelineScope = PipelineScope { psRuns   :: [VaultRef], psIssues :: [ScopeIssue] }

resolveRead     :: Hub -> Maybe Text -> IO (Either WorkspaceError ReadScope)
resolveWrite    :: Hub -> Maybe Text -> FilePath -> IO (Either WorkspaceError WriteScope)
resolvePipeline :: Hub -> VaultKind -> Maybe Text -> IO (Either WorkspaceError PipelineScope)

detectVault    :: FilePath -> IO (Maybe FilePath)
lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry
```

| 參數 / 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| 第二參數(三個 `resolve*`) | Maybe Text | `Nothing` = 沒給 `--vault`;`Just s` 的 `s` 非空 | selector 先比 `veId` 的完整字串,再比 `veName`;都不中回 `VaultSelectorNotFound` |
| `resolveWrite` 第三參數 | FilePath | 絕對路徑;通常是行程的當前目錄 | 向上探測的起點 |
| `resolvePipeline` 第二參數 | VaultKind | `AssetVault` / `StoryVault` | 這條管線只對這種 kind 的 vault 有意義 |
| `rsVaults` / `wsRead` / `psRuns` | [VaultRef] | **保序去重**(以 `vmId` 去重);可為空清單 | 這次指令實際可讀 / 要各跑一次的 vault |
| `wsTarget` | VaultRef | 恰好一個 | 這次指令的**唯一寫入目標** |
| `rsIssues` / `wsIssues` / `psIssues` | [ScopeIssue] | 可為空;**不中止查詢** | 降級紀錄,由 `shell` 印成警告 |
| `vrEntry` | Maybe VaultEntry | `Nothing` ⟺ 這個 vault 不在中樞 `[[vaults]]` 裡(向上探測到的未註冊 vault) | 它在中樞的那一列 |
| `vrPath` | FilePath | 絕對路徑,**正規化 = `System.Directory.canonicalizePath`**(2026-08-29 WAVE-2 閘門釘死):解 `.` / `..`、解 symlink、還原 Windows 8.3 短檔名;指向含 `.aapms/` 的那一層 | vault 根目錄。同一個目錄的兩種寫法會歸一,錯誤訊息印的是工具**真正去看的**那個位置——使用者拿它去 `ls` 才有意義。**被否決**:`makeAbsolute`(純字串 + cwd、不碰檔案系統、好測,但 `C:\x\..\y` 與 `C:\y` 是兩個字串,8.3 短檔名與 symlink 都不還原) |
| `vrMarker` | VaultMarker | graph-core 契約 E 的型別,**一律來自檔案** | 權威的 `id` / `kind` / `name` / `refs` |

`ScopeIssue` 四個建構子的參數:

| 建構子 | 參數 | 語意 |
|---|---|---|
| `VaultPathMissing` | `VaultEntry`、`FilePath` | 中樞的那一列、它指的**不存在**的路徑 |
| `VaultMarkerBroken` | `VaultEntry`、`StoreError` | 中樞的那一列、graph-core `readMarker` 回的**原件**(訊息由對方的 `render*` 產生) |
| `VaultIdDrift` | `VaultEntry`、`VaultId` | 中樞的那一列(含它記的 id)、marker 裡**實際**的 id |
| `RefVaultNotRegistered` | `VaultId`、`VaultId` | `refs` 的**來源** vault、`refs` 裡那個在中樞查不到的**目標** |

三個裁決的規則(ADR-017 決策三;`refs` 語意由 2026-08-29 裁決補上):

| 函式 | selector = `Nothing` | selector = `Just X` |
|---|---|---|
| `resolveRead` | 全部已註冊 vault。**不看當前目錄** | `{X} ∪ refs*(X)`,`refs*` 是遞移閉包 |
| `resolveWrite` | 從第三參數逐層向上找含 `.aapms/` 的目錄;找不到回 `NoWriteTarget`。`wsRead` = `{目標} ∪ refs*(目標)` | 目標 = `X`;`wsRead` = `{X} ∪ refs*(X)` |
| `resolvePipeline` | 全部已註冊且 `vmKind` 相符的 vault,各跑一次 | `{X}`;`X` 的 `vmKind` 不符時回 `VaultKindMismatch` |

四條性質,三個函式共用:

1. **marker 是真相**。三個函式都**重讀每個候選 vault 的 marker**,回傳的 `vrMarker` 一律來自檔案;
   中樞的 `veName` / `veKind` 只在 marker 讀不到時作為降級顯示。中樞與 marker 的 `id` 不符時
   產生 `VaultIdDrift`,而**該 vault 不進結果集**——身分不確定時任何跨 vault 的 `Ref` 解析都是
   不確定的(與 graph-core 契約 G 對重複 `vmId` 的處置同一個理由)
2. **不可達不中止**。路徑不存在、marker 解不開、`refs` 指向未註冊的 vault,一律進 `*Issues`
   並把該 vault 排除,其餘照跑。整個指令只在**連中樞都載不起來**或**寫入目標決定不了**時才失敗
3. **`refs` 遞移展開對環是安全的**。`A → B → A` 的展開結果是 `{A, B}`,不是錯誤、也不是不終止
4. **`refs` 展開進來的一律唯讀**。它們只出現在 `rsVaults` / `wsRead`,**永遠不會**成為 `wsTarget`

**展開的走訪規則**(2026-08-29 WAVE-3 閘門裁決,補契約沒說到的三處):

- **不可達的節點不展開它自己的 `refs`**,三種不可達一視同仁——包含 marker 讀得到、只是身分對不上的
  **id 漂移**。理由與性質 1 同一條:身分不確定時,任何以它為起點的關係都是不確定的,而 ADR-017 把
  id 撞號定義成「有人複製了整個 vault 目錄」,那一串的來源本身就可疑。代價是一個壞掉的中繼 vault
  會讓它後面整串退出範圍——但那一串本來就是靠它的 marker 才找得到的
- **走訪是 BFS,種子排第一**,所以 `rsVaults` 的順序是「跟我直接相鄰的先出現」而不是深優先的長鏈
- **同一個未註冊的 `refs` 目標被多個來源列到時只產生一則** `RefVaultNotRegistered`,`src` 取 BFS 序
  最早的那個來源
- **`resolvePipeline (Just X)` 而 X 不可達**時回 `Right (PipelineScope [] [issue])`,**不是**
  `VaultKindMismatch`——kind 是從 marker 讀出來的,marker 都拿不到就談不上 kind 相不相符

`detectVault` 是 ADR-008 的 git 式探測:從給定目錄逐層往上,回第一個含 `.aapms/` 子目錄的那一層的
絕對路徑(同樣經 `canonicalizePath`);走到根仍沒有回 `Nothing`。起點**不先驗存在性**,不存在也照樣
往上走。**它只決定寫入目標,不影響查詢範圍。**

**`lookupSelector` 的比對規則**(2026-08-29 WAVE-2 閘門裁決,補契約 C 只說「先比 id 再比 name」沒說
怎麼比的空缺):兩階段都是**逐字精確比對**——不去前後空白、不忽略大小寫。`veId` 階段萬一撞號,
處置與 `veName` 撞名**同一套**:回 `VaultSelectorAmbiguous` 並列出全部,不取第一列。理由是這條
規則被四個 feature 共用(三個 `resolve*` 與 `forgetVault` 都寫「比對規則同 `lookupSelector`」),
多一種折疊就多一處要各自解釋的地方;而中樞是**可手寫**的檔案,忽略大小寫會讓手寫的 `Foo` 與
`foo` 突然變成撞名。找不到時的訊息要列得出可用的 vault 名稱,使用者才改得掉。

### D. 生命週期

```haskell
data InitMode    = FreshVault | AdoptExisting
data DeleteIndex = KeepIndex  | DeleteIndex
data PurgeScope  = PurgeHubOnly | PurgeAllVaults

setupHub    :: HubLocation -> IO (Either WorkspaceError SetupReport)
initVault   :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode
            -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
-- 2026-08-30 E001:時間明碼,撞號分支才測得到(同 allocateProjectId 的理由)
initVaultWith :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> UTCTime
              -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
addVault    :: HubLocation -> Hub -> FilePath -> IO (Either WorkspaceError (Hub, VaultEntry))
forgetVault :: HubLocation -> Hub -> Text -> DeleteIndex -> IO (Either WorkspaceError (Hub, VaultEntry))
checkVaults :: Hub -> IO [ScopeIssue]
syncHub     :: HubLocation -> Hub -> IO (Either WorkspaceError (Hub, [ScopeIssue]))
purge       :: HubLocation -> Hub -> PurgeScope -> IO (Either WorkspaceError PurgeReport)

registerProject :: HubLocation -> Hub -> FilePath -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))
allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id   -- 2026-08-29 WAVE-4:時間明碼,salt 重試才測得到
forgetProject   :: HubLocation -> Hub -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))

data SetupReport = SetupReport { spHubPath :: FilePath, spHubCreated :: Bool, spCacheCreated :: Bool }
data AdoptNotice = AdoptNotice { anLegacyMarkers :: [FilePath] }
data PurgeReport = PurgeReport
  { prHubRemoved :: Bool, prThumbsRemoved :: Int, prVaultIndexesRemoved :: [FilePath] }
```

| 欄位 / 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `initVault` 第三參數 | FilePath | 絕對或相對路徑,內部正規化為絕對 | vault 根目錄 |
| `initVault` 第四參數 | VaultKind | `AssetVault` / `StoryVault`;**必填,不猜** | 一個 vault 一種 kind(ADR-017 決策一) |
| `initVault` 第五參數 | Text | 去除前後空白後長度 ≥ 1;否則 `InvalidName` | vault 名稱,寫進 marker 的 `name` |
| `initVaultWith` 第七參數 | UTCTime | 任意時間值 | **新 vault 的 id 由它決定**(`newId PVlt 名稱 時間 0`)。前六個參數與語意和 `initVault` 完全相同,`initVault` 是「取當下時間後轉呼它」的薄包裝。時間放最後,與 `allocateProjectId`、graph-core 的 `initVaultAtWith` 一致(2026-08-30 E001) |
| `addVault` 第三參數 | FilePath | 絕對或相對路徑,內部正規化為絕對;該目錄**必須已有** `.aapms/` | 要納管的既有 vault |
| `forgetVault` 第三參數 | Text | 非空;比對規則同 `lookupSelector`(先 id 後 name) | 要移除的 vault |
| `registerProject` 第三/第四參數 | FilePath、Text | 路徑必須存在(否則 `ProjectPathMissing`);名稱去空白後長度 ≥ 1 | 專案根目錄、專案名 |
| `forgetProject` 第三參數 | Text | 非空;先比 `peId` 再比 `peName` | 要移除的專案 |
| `InitMode` | Enum | `FreshVault` = 目錄不存在或為空,由本子系統建立;`AdoptExisting` = 目錄已存在且可非空,內容一律不動 | 取代 legacy 的 `vault migrate`(2026-08-29 裁決) |
| `anLegacyMarkers` | [FilePath] | 絕對路徑;可為空 | `AdoptExisting` 時在該目錄下發現的 `.assetdb/` 或 `.storyflow/`。**只報告不刪除** |
| `DeleteIndex` | Enum | `KeepIndex`(預設)/ `DeleteIndex` | `DeleteIndex` 才刪 `<vault>/.aapms/index.db`;`config.toml` 與 `library/` **任何情況都不碰** |
| `PurgeScope` | Enum | `PurgeHubOnly`(預設)/ `PurgeAllVaults` | 後者連各 vault 的 `.aapms/index.db` 一起刪 |
| `spHubCreated` / `spCacheCreated` | Bool | `True` = 這次建立的;`False` = 本來就在(`setupHub` 冪等) | 讓 `shell` 分得出「剛裝好」與「早就裝好」 |
| `prThumbsRemoved` | Int | 檔案數,≥ 0 | 刪掉的縮圖檔數量 |
| `checkVaults` | — | 回傳可為空清單;**不寫任何檔案** | 純體檢,無失敗通道 |
| `syncHub` | — | 把**修得掉**的漂移(`veName` / `veKind` 與 marker 不符)回寫中樞 | 修不掉的(路徑不見、id 漂移)原樣回傳 |

**刪索引前先驗身分**(2026-08-29 WAVE-4 閘門裁決):`forgetVault DeleteIndex` 與
`purge PurgeAllVaults` 在刪 `<vault>/.aapms/index.db` **之前**先 `readMarker`——

- **讀不到**(路徑不見、marker 壞)→ **照刪**。那正是 `forget` 最常見的理由
- **讀得到但 `vmId` 與中樞那一列不符** → **拒絕刪除**並回錯

理由:中樞的 `vePath` 是**快取**(契約 B 寫死),marker 才是真相。那一列過期時——使用者搬走
vault、原路徑放了**另一個** vault——照 `vePath` 刪掉的是別人的索引。索引是衍生物、rebuild 得回來,
但使用者不會知道發生過什麼。這與 WAVE-3「身分不確定就不往下走」、契約 C 性質 1「marker 是真相」
是同一條原則的第三次適用。**被否決**:只依 `vePath` 刪(零成本,代價如上);把防線移到
`shell` 的 `--confirm`(使用者正是因為以為那個路徑還是舊 vault 才按下去的,確認擋不住這個錯誤)。

三條硬性約束(ADR-017 決策五):

- **任何情況下不碰 `library/`、不碰任何 `.md`**。它們是真相,不是衍生物
- `forgetVault` 預設**只動中樞**;vault 目錄原封不動,搬到另一台機器 `vault add` 就能繼續用
- 中樞的寫入點只有上列八個函式,而且只**追加一列或刪整列**;既有列的相對順序、使用者寫的
  註解與空白行原樣保留——保住「可手寫」(ADR-017 決策二)

`initVault` 的 vault id 由 `initVaultAt`(graph-core)產生。產生後若與中樞既有的 `veId` 相同,
回 `VaultIdCollision` 並要求重跑一次(id 含時間成分,重跑即不同);**不靜默接受**。

### E. 本機外部工具

```haskell
data ToolOrigin = FromToolsConfig | FromPath | FromCandidate | NotFound
data ToolStatus = ToolStatus
  { tsName :: Text, tsPath :: Maybe FilePath, tsOrigin :: ToolOrigin, tsSearched :: [FilePath] }

detectSevenZip :: ToolsConfig -> IO ToolStatus
-- 2026-08-29 WAVE-4 閘門新增:把「去哪裡找」變成明碼參數,NotFound 與 FromCandidate 才驗得到
data ToolSearchPlan = ToolSearchPlan { tspPathDirs :: [FilePath], tspCandidates :: [FilePath] }
detectSevenZipIn :: ToolSearchPlan -> ToolsConfig -> IO ToolStatus
```

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `tsName` | Text | 固定字串,如 `"7-Zip"` | 給人看的工具名 |
| `tsPath` | Maybe FilePath | 絕對路徑;`Nothing` ⟺ `tsOrigin == NotFound` | 找到的執行檔 |
| `tsOrigin` | Enum | 見上 | 這個路徑**哪裡來的**:`[tools]` 覆寫 / PATH / 內建候選清單 / 沒找到 |
| `tsSearched` | [FilePath] | 依序、去重;`NotFound` 時**必為非空** | 找過哪些地方——訊息要說出下一步,所以這是必要資訊 |

探測順序固定三層:`tcSevenZip` 覆寫 → PATH 上的 `7z` / `7zz` → 內建候選清單
(Windows `C:\Program Files\7-Zip\7z.exe` 等,沿用 legacy assetdb 的清單)。判準只有「檔案存在且
可執行」,**不執行它、不查版本**——版本相容性是 `asset-ingest` 真的要用時的事。

**7-Zip 缺席不是錯誤**(主架構:「sidecar 缺席只影響預覽與縮圖,不影響索引」),所以本組沒有
失敗通道,`ToolStatus` 一律回得出來。

### F. 錯誤契約

```haskell
data WorkspaceError
  = HubNotFound FilePath | HubUnreadable FilePath Text | HubMalformed FilePath Text
  | HubWriteFailed FilePath Text
  | VaultSelectorNotFound Text | VaultSelectorAmbiguous Text [VaultEntry]
  | VaultKindMismatch VaultId VaultKind VaultKind
  | NoWriteTarget FilePath
  | VaultAlreadyInitialized FilePath | VaultDirMissing FilePath | VaultDirNotEmpty FilePath
  | VaultIdCollision VaultId FilePath FilePath
  | WriteTargetIdDrift VaultId FilePath VaultId     -- 2026-08-29 WAVE-3 閘門新增
  | MarkerUnreadable FilePath StoreError
  | ProjectSelectorNotFound Text | ProjectPathMissing Text FilePath
  | ProjectSelectorAmbiguous Text [ProjectEntry]      -- 2026-08-29 WAVE-4 閘門新增
  | ProjectAlreadyRegistered Id FilePath              -- 2026-08-29 WAVE-4 閘門新增
  | VaultInitFailed FilePath StoreError               -- 2026-08-29 WAVE-4 閘門新增
  | DeleteTargetIdDrift VaultId FilePath VaultId      -- 2026-08-29 WAVE-4 閘門新增
  | InvalidName Text

renderWorkspaceError :: WorkspaceError -> Text
```

`WorkspaceError` 是本套件的**唯一**錯誤型別,每個建構子都有對應的繁中訊息,**每一則說出下一步
該做什麼**;`service` 原樣包成一個建構子,不重寫訊息(主架構全域錯誤策略第 1 條,與 graph-core
契約 G 同一個模式)。`errorCode` 的對照表歸 `service` 擁有——三個殼共用的 `code` 只能有一個來源。

`MarkerUnreadable` 捧著 `StoreError` 而不是字串:訊息由 graph-core 的 `render*` 產生,這一層不翻譯。
`VaultSelectorAmbiguous` 必須列出**全部**撞名的 `VaultEntry`(含 id 與路徑),使用者才知道改用哪個 id。
`VaultKindMismatch` 帶三個值:vault 的 id、要求的 kind、實際的 kind。
`VaultIdCollision` 帶三個值:撞到的 `VaultId`、**中樞裡既有**那個 vault 的路徑、**這次要建立**的路徑
——兩個路徑都要印,使用者才看得出是不是自己複製了整個 vault 目錄。
`ProjectPathMissing` 帶專案名與那個不存在的路徑。`InvalidName` 帶收到的原始字串。

**2026-08-29 WAVE-4 閘門新增的三個建構子**,共同的理由是同一條:借用既有建構子會讓訊息**說出一件
假的事**——與 WAVE-3 新增 `WriteTargetIdDrift` 是同一個判準。

| 建構子 | 帶的值 | 不補的話會說什麼謊 |
|---|---|---|
| `ProjectSelectorAmbiguous` | selector 字串、**全部**撞名的 `ProjectEntry` | 借用 `ProjectSelectorNotFound` 會說「找不到」,但它其實**找到了兩個**。vault 側早就有 `VaultSelectorAmbiguous`,專案側缺這一個本來就不對稱 |
| `ProjectAlreadyRegistered` | 既有那一列的 `peId`、它的路徑 | 同一個路徑註冊兩次時,契約 B 對 `pePath` 沒有唯一性要求,所以「靜默發第二個 id」是合法的——但中樞會出現兩列指同一個目錄,`projectList` 印兩次而 `forgetProject` 只刪一列。訊息要說出下一步(要改名就先 `forget` 再註冊) |
| `VaultInitFailed` | vault 根目錄、graph-core 的 `StoreError` 原件 | `initVaultAt` **建** marker 失敗時借用 `MarkerUnreadable`,訊息會說「marker **讀**不出來」,叫使用者去看一個還沒被建出來的檔 |
| `DeleteTargetIdDrift` | 中樞那一列的 `veId`、該 vault 的 `vePath`、marker 裡實際的 `vmId` | 與 `WriteTargetIdDrift` **完全對稱**,構成「寫入目標漂移 / 刪除目標漂移」家族。借用後者的話,訊息開頭會說「**寫入目標**……」——而 `forget --delete-index` 與 `purge` 是**撤除**,這條路徑上根本沒有寫入目標;它給的下一步「重新執行 `vault add`」更是**反方向**,照做會把使用者剛想拿掉的東西加回來。訊息要件三樣:擋下來的原因、**不會**誤刪的替代做法(不加 `--delete-index` 的 `vault forget`)、把中樞修正確的路 |

**`WriteTargetIdDrift` 帶三個值**:註冊表記的 `VaultId`、該 vault 的路徑、marker 裡**實際**的
`VaultId`。它與 `ScopeIssue.VaultIdDrift` 是同一件事的兩種身分:**在讀取路徑上是降級**
(那個 vault 退出範圍,其餘照跑),**在寫入目標上是硬失敗**(ADR-017:寫入目標決定不了就該
硬失敗,程式不猜)。2026-08-29 WAVE-3 閘門新增,理由是另外兩個候選都會說謊——`NoWriteTarget` 的
訊息裡「未指定 `--vault`」「向上找不到 `.aapms`」在這條路徑上都不成立,而 `MarkerUnreadable`
要在這一層捏造一個 graph-core 的 `StoreError`(違反契約 F「這一層不翻譯」),還會叫使用者去修
一個沒壞的 marker。訊息要說出真正的下一步:`vault check` / `syncHub` / 重新 `vault add`。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 | 擁有的事實(唯一真相來源) |
|---|---|---|
| Types | 本套件全部對外型別的定義,以及 `WorkspaceError` 與 `renderWorkspaceError` | **這個子系統會有哪些失敗、每則訊息怎麼講** |
| Location | 中樞根目錄的解析(`AAPMS_HOME` / 平台預設)與中樞內的衍生路徑(`config.toml`、`cache/thumbs/`) | **中樞在哪**、中樞目錄的內部佈局 |
| Hub | `config.toml` 四段的解析與序列化、原子寫入、對 `Hub` 值的純增刪 | **中樞記了什麼**(`[[vaults]]` / `[[projects]]` / `[llm]` / `[tools]` 的檔案格式) |
| Discovery | 向上探測 `.aapms/`、selector 解析、重讀 marker 成 `VaultRef` | **「這個字串 / 這個目錄指的是哪個 vault」** |
| Scope | 三個裁決函式、`refs` 遞移展開、保序去重、`ScopeIssue` 彙整 | **ADR-017 的三種範圍規則** |
| Lifecycle | vault 的建立 / 納管 / 撤除 / 體檢 / 清理 | **撤除的分層界線**(什麼能刪、什麼絕不刪) |
| Projects | 專案註冊表的增刪查、`prj-` 配號 | **這台機器上有哪些專案** |
| Tools | 外部工具的三層探測與 `ToolStatus` | **外部工具在哪、怎麼找的** |

沒有兩個模組宣稱擁有同一個事實。**vault 的身分(`id` / `kind` / `name` / `refs`)不屬於任何一個
模組**——它屬於 graph-core 的 marker;Hub 存的是快取,Discovery 每次重讀真相。

**Types 為什麼要獨立**(與 graph-core 契約 G 的「唯一錯誤型別成立的前提」同一個道理):
`WorkspaceError` 的 `VaultSelectorAmbiguous` 捧著 `[VaultEntry]`,而 `loadHub` 又回
`Either WorkspaceError Hub`——型別定義與錯誤型別若住在同一個模組以外的地方,兩者互相 import
就是相依環。做法是把**全部純型別與錯誤型別收在 Types**:它可以依賴 `aapms-core` 與 `aapms-store`
的型別(`VaultId` / `Id` / `Sha256` / `VaultKind` / `VaultMarker` / `StoreError`),但**不得 import
本套件的任何其他模組**。其餘七個模組全部往 Types 依賴,型別歸屬圖因此是一棵樹。

`WorkspaceError` 是本套件的唯一錯誤型別,不得另立平行的錯誤型別再橋接——多一個型別就是多一套
`render*` 與多一次翻譯,`service` 也會看到兩種形狀。

**Types 一次寫齊,不由各 feature 逐波擴充**(2026-08-29,`/subsys-build` 排波次時定案):契約 A–F
的型別與 `WorkspaceError` 的**全部建構子**、`renderWorkspaceError` 的全部訊息,都在第一個 feature
一次寫完。理由是階段二的三個 feature 平行執行,若各自往 `Types.hs` 加建構子,那是同一個檔案的
併發寫入——互蓋當下不會有任何錯誤訊息。契約 F 本來就把建構子列全了,一次寫齊只是照抄契約。

**本套件不設門面模組**(沒有 `Aapms.Workspace`):七個模組全部 `exposed`,界線由 `.cabal` 的
`exposed-modules` 守(與 graph-core E001「內部模組界線改由 cabal 守」同一個做法),消費端直接
import 需要的那一個。門面在 `aapms-store` 成立是因為它有一半模組刻意不外露,這裡沒有那個問題。

## 資料流管線(Data Flow Pipeline)

三條管線,`Hub` 這個不可變快照在每條裡都只被載入一次。

**裁決(旗標 → 這次指令對哪些 vault 生效)**

```text
shell 解析出 --vault 的字串(不解讀語意)→ service 依操作類別選裁決函式
  → hubLocation:AAPMS_HOME / 平台預設 → loadHub:解析四段(失敗即失敗,不退回空中樞)
  → selector 有值:lookupSelector 比 id 再比 name(撞名 → VaultSelectorAmbiguous)
    selector 沒值:讀 → 全部已註冊;寫 → detectVault 從 cwd 向上;管線 → 依 kind 過濾
  → 對每個候選:readMarker(graph-core)取權威 id / kind / name / refs
      路徑不見 / marker 壞 / id 漂移 → 進 ScopeIssue 並排除,不中止
  → refs 遞移展開(visited 集合擋環),展開進來的標記為唯讀;保序去重
  → 回 ReadScope / WriteScope / PipelineScope
  → service 逐一 openVault、必要時 openVaultSet(ATTACH 上限由 graph-core 判)
```

**生命週期(一個目錄 → 一個受納管的 vault)**

```text
service 給:目錄、kind、名稱、InitMode
  → 前置檢查:FreshVault 要求目錄不存在或為空;AdoptExisting 要求目錄存在
     已有 .aapms/ → VaultAlreadyInitialized(不覆寫)
  → initVaultAt(graph-core):寫 .aapms/config.toml + 建空索引 → 得到 VaultMarker
  → 與中樞既有 veId 比對,撞號 → VaultIdCollision(要求重跑)
  → AdoptExisting:掃該目錄下的 .assetdb/ 與 .storyflow/,列進 AdoptNotice(只報告)
  → Hub 值上追加一列 → saveHub 原子寫回 config.toml
  → 回 (新的 Hub, VaultEntry, AdoptNotice)
```

撤除走同一條路的反向:`forgetVault` 先從 `Hub` 值刪整列、`saveHub`,`DeleteIndex` 時才多刪一個
`indexDbPath`;`purge` 對中樞目錄與(可選)各 vault 的 `index.db` 做同一件事,兩者都**不碰
`library/` 與任何 `.md`**。

**本機環境(這台機器現在長什麼樣)**

```text
hubLocation → loadHub → hubTools
  → detectSevenZip:[tools] 覆寫 → PATH 上的 7z / 7zz → 內建候選清單
     每一步都記進 tsSearched;找到就停,tsOrigin 標明來源
  → hubLlm 原樣捧出 TOML 表(不解讀,鍵與語意屬 ai)
  → checkVaults:對每個 [[vaults]] 重讀 marker,產生 ScopeIssue 清單(不寫檔)
  → service 組成 doctor 報告;syncHub 才把修得掉的漂移回寫
```

## 模組間公開介面(Module Interfaces)

| 呼叫方向 | 介面 |
|---|---|
| 全部模組 → Types | 型別定義與 `WorkspaceError` / `renderWorkspaceError`;Types 不回頭 import 任何一個 |
| Types → `aapms-store` / `aapms-core` | 只取型別:`StoreError` / `VaultMarker` / `VaultKind` / `VaultId` / `Id`。**2026-08-29 WAVE-1 補表**(原本只寫在「Types 為什麼要獨立」的散文裡) |
| Hub → Location | `configPath :: HubLocation -> FilePath`、`thumbCacheDir`;Hub 自己不解析中樞位置 |
| Hub → `aapms-store` | `readTextFile`(讀 `config.toml`,一律 UTF-8)、`atomicWriteText`(寫回)、`renderStoreError`(把落地失敗的訊息原樣轉成 `HubUnreadable` / `HubWriteFailed` 的 `Text`,**這一層不翻譯**)。**2026-08-29 WAVE-1 補表**(原本只寫在「使用的技術」的散文裡) |
| Location → `aapms-core` | `Sha256`——`thumbCachePath :: HubLocation -> Sha256 -> FilePath` 的第二參數。**2026-08-29 WAVE-1 補表** |
| Discovery → `aapms-store` | `readMarker :: FilePath -> IO (Either StoreError VaultMarker)`;失敗原樣包成 `MarkerUnreadable`,不翻譯訊息。另用 `markerDir`——`.aapms` 這個目錄名的唯一真相在 graph-core,本子系統不自己寫一份字面值(**2026-08-29 WAVE-2 補列**) |
| Discovery → Hub | `hubVaults` 取候選清單;`lookupSelector` 是純函式,只吃 `Hub` 值 |
| Scope → Discovery | `lookupSelector`(selector → `VaultEntry`);`readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)`(**已註冊**的 vault:路徑 → 權威身分,失敗是降級紀錄)<br>`readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)`(**向上探測到**的路徑,可能未註冊;失敗是硬錯誤 `MarkerUnreadable`)<br>`detectVault` |
| Scope → Hub | 依 `veId` 反查 `VaultEntry`,供 `refs` 展開把 `VaultId` 換成路徑 |
| Scope → `aapms-store` | `VaultMarker` 的 `vmId` / `vmKind` / `vmRefs` 三個欄位存取子,以及 `Aapms.Store.Schema` 的 `VaultKind` 型別(`resolvePipeline` 的簽名是契約 C 寫死的)。**2026-08-29 WAVE-3 補表**——`Types.hs` 對 `VaultMarker` 是裸型別 import(F001 的 LAW-17(d) 釘死),轉不出欄位存取子;`VaultKind` 也不在 Types 的匯出清單裡 |
| Lifecycle → `aapms-store` | `initVaultAt` 與 **`initVaultAtWith`**(寫 marker + 空索引;後者收明碼 `UTCTime`,**2026-08-30 E001 補列**——`initVaultWith` 靠它把時間往下傳)、`indexDbPath`(`--delete-index` 要刪的那一個檔)、`markerDir`(`.aapms` 這個名字的唯一真相)、`readMarker` 與 `VaultMarker` 的 `vmId` / `vmKind` / `vmName` 三個欄位存取子(刪索引前驗身分、`syncHub` 對帳)。**2026-08-29 WAVE-4 補表** |
| Lifecycle → Location | `configPath`(**中樞的**)與 `thumbCacheDir`——`setupHub` 建中樞、`purge` 清快取要用。**2026-08-29 WAVE-4 補表**(表裡原本整條不存在) |
| Projects → Hub | `upsertProject` / `removeProject`(見上)+ `hubProjects`(撞號比對與 selector 候選都要讀它)。**2026-08-29 WAVE-4 補表** |
| Lifecycle → Hub | `upsertVault` / `removeVault`(對 `Hub` 值的純操作)+ `saveHub` |
| Projects → Hub | `upsertProject :: ProjectEntry -> Hub -> Hub` / `removeProject :: Id -> Hub -> Hub` + `saveHub`。**2026-08-29 WAVE-1 閘門裁決補上**:`Hub` 不外露建構子,Projects 的骨架又只有 `Projects.hs`,沒有這兩個入口它動不了 `[[projects]]`。語意與 vault 那一組同構(以 id 為鍵、追加或就地取代、保序) |
| Lifecycle → Discovery | `AdoptExisting` 與 `addVault` 時讀既有 marker 取 id / kind / name |
| Projects → `aapms-core` | `newId PPrj`(純函式,時間由呼叫端給);唯一性由 Projects 對中樞既有 `peId` 重試保證 |
| Tools → Hub | `hubTools` 取 `ToolsConfig`;Tools 不讀檔案格式 |

**`readVaultRef` 為什麼拆成兩個**(2026-08-29 WAVE-2 閘門裁決):本表原本只有一個
`readVaultRef :: Maybe VaultEntry -> ...`,但契約 C 的 `ScopeIssue` 三個相關建構子**每一個都要求
一列 `VaultEntry`**——第一參數為 `Nothing`(向上探測到、未註冊的 vault)時失敗通道表達不出來,
而契約卡又把 `MarkerUnreadable` 指給 Discovery,那個回傳型別也生不出它。兩條路徑的**失敗語意本來
就不同**:「註冊表裡那一列壞了」是降級(其餘 vault 照跑),「你 cd 所在的 vault 壞了」是硬失敗
(寫入目標決定不了,ADR-017)。拆開之後型別分得出來。**被否決的替代方案**:給 `ScopeIssue` 加一個
不帶 `VaultEntry` 的建構子——語意最乾淨,但要改已交付的 `Types.hs`,而 DEC-2 的併發前提正是
「WAVE-2 之後沒人再碰 `Types.hs`」,等於整波重排。

**方向是線性的**:`Types ← Location ← Hub ← Discovery ← Scope`,`Lifecycle` / `Projects` / `Tools`
各自往左依賴,彼此不互相呼叫。沒有任何一條回頭邊,型別歸屬圖因此無環。

## 使用的技術

沿用主架構。子系統特有的:

- **`toml-reader`**:中樞 `config.toml` 的解析。與 vault marker、型別註冊表同一個解析器,
  「人可手寫的設定都是 TOML」在整個系統只有一種解析行為
- **中樞的序列化自己寫**(固定段落順序、保留使用者的註解與空白行),不用泛型 encoder——
  這是「可手寫」這條性質的前提,與 graph-core 對 `meta` 區塊的處置同一個理由
- **`directory` / `filepath`**:向上探測、路徑正規化(`canonicalizePath`)、`getPermissions` 的可執行判準。**不用 `findExecutable`**(2026-08-29 WAVE-4 校正):它在 Windows 走 Win32 `SearchPath`,搜過哪些地方由登錄檔決定、測試控制不了,而契約 E 的 `tsSearched` 要求說得出「找過哪些地方」——PATH 由本子系統自己展開
- 原子寫入沿用 `aapms-store` 的 `atomicWriteText`,**不另寫一份**

## 架構圖

```text
                        service(唯一消費者)
                              │
   ┌──────────────────────────┼───────────────────────────────────┐
   │  aapms-workspace         │                                   │
   │                          ▼                                   │
   │   ┌──────────┐   ┌──────────┐   ┌───────────┐   ┌─────────┐  │
   │   │ Location │◄──│   Hub    │◄──│ Discovery │◄──│  Scope  │  │  ★ 裁決點
   │   │ AAPMS_   │   │ 四段解析  │   │ 向上探測   │   │ 讀跨    │  │
   │   │ HOME /   │   │ 原子寫入  │   │ selector  │   │ 寫單一  │  │
   │   │ 平台預設  │   │ 可手寫    │   │ 重讀marker│   │ 管線    │  │
   │   └──────────┘   └────┬─────┘   └─────┬─────┘   └─────────┘  │
   │        ▲              │               │                      │
   │        │         ┌────┴─────┬─────────┴──┐                   │
   │        │         │Lifecycle │  Projects  │   ┌───────┐       │
   │        └─────────│ init/add │  prj- 配號 │   │ Tools │       │
   │                  │ forget   │            │   │ 7-Zip │       │
   │                  │ purge    │            │   │ 三層  │       │
   │                  └────┬─────┘            │   └───────┘       │
   └───────────────────────┼──────────────────┴───────────────────┘
                           │ readMarker · initVaultAt · indexDbPath · atomicWriteText
                           ▼
                  graph-core 的 aapms-store / aapms-core

   對外出入口:%APPDATA%\aapms\config.toml(可手寫)· cache/thumbs/<aa>/<sha256>.png
             · 各 vault 的 .aapms/config.toml(只讀,寫由 initVaultAt)
```

## 開發階段

對應主架構 **S3「骨幹」**(與 `service`、`shell` 同期)。本子系統是 S3 三個子系統裡的**最上游**:
`service` 的 `Env` 要靠它決定開哪些 vault,所以階段一結束前 `service` 動不了。

內部里程碑即下方兩個階段:階段一結束時「一道指令對哪些 vault 生效」已經算得出來(給定一份手寫的
中樞檔案);階段二結束時中樞可以由工具自己建立與維護,主架構 S3 的「舊 marker 探測、`doctor` 合一」
兩條交付判準可驗。

## 功能總覽

<!-- BEGIN FEATURE INDEX:由 scan-status.mjs --write-index 產生,不要手改 -->
| id | feature | 階段 | 模組 | 狀態 |
|---|---|---|---|---|
| F001 | hub-registry | S3 | Types、Location、Hub | done |
| F002 | vault-discovery | S3 | Discovery | done |
| F003 | scope-resolution | S3 | Scope | done |
| F004 | vault-lifecycle | S3 | Lifecycle | done |
| F005 | project-registry | S3 | Projects | done |
| F006 | machine-tools | S3 | Tools | done |
<!-- END FEATURE INDEX -->

### 規劃註記(v1「功能規劃」小結原文搬移)

本節與各 feature 文檔內文出現的 `#n` 是 v1「功能規劃」表的列號,該表已在 v2 廢除。
**列號與 feature 編號一對一**(`#3` 即 workspace/F003),照上方「功能總覽」表對回文檔全名。

小結:共 **6 個 features、2 個階段**;全部完成即代表 `service` 拿得到「這次指令對哪些 vault 生效」、
中樞可由 `workspace setup` 從零建立、`doctor` 報告得出中樞位置與外部工具狀態。

## 不可逆決定

| 決定 | 被否決的替代方案與理由 |
|---|---|
| 中樞是 TOML,不是 SQLite | **中樞也用 SQLite**:可交易、可查詢。否決理由是內容只有個位數列,不需要 SQL,而且多一份 schema 要養;壞掉時使用者無法自己修,而中樞正是「壞了要看得懂」的那種檔案(ADR-011 已裁決,此處沿用) |
| 中樞以 `veId` 為鍵,`veName` / `veKind` 是快取、marker 是真相 | **中樞的 `name` 是機器本地別名(與 marker 各自獨立)**:同一個 vault 可以在兩台機器叫不同名字。否決理由是「改一個 vault 的名字」會變成要改兩個地方,而 vault 本來就自述名稱;別名的好處在單人工作室換不到那個代價 |
| `refs` = 收窄時的最小讀取集合(展開進來唯讀) | **刪掉 `refs`**:契約面最小。否決理由是 `--vault X` 收窄後跨 vault 的 `Ref` 一律解不開,`project new --vault <story vault>` 要手指素材庫。**`refs` 取代預設全域查詢**:否決理由是會讓查詢結果與「你 cd 在哪裡」綁定,失去「一次找遍所有素材」 |
| `aapms-workspace` 依賴 `aapms-store` | **只依賴 `aapms-core` + TOML,marker 交給 `service` 讀**:照 system.md 原文。否決理由是 vault 身分的知識會被切成三半(中樞 / marker / 拼裝),新增一條與 vault 身分有關的規則要改三個地方。**把 marker 讀寫搬進 workspace、`aapms-store` 反過來依賴它**:知識歸屬最乾淨,但要動已交付驗收的 graph-core F005 與契約 E,且依賴方向翻轉是不可逆的 |
| `[llm]` 住中樞,不住 vault marker | **維持 legacy 的 per-vault `[llm]`**:兩個 vault 可以用不同模型。否決理由是新的 `VaultMarker` 只有四欄,承接 `[llm]` 要回頭擴充已交付的 graph-core;而端點本來就是這台機器的東西,per-vault 等於同一組設定抄 N 次 |
| `vault init --adopt` 取代 `vault migrate` | **保留 `vault migrate`**:與 ADR-017 決策六原文一致、不用改 ADR。否決理由是 S2 匯出器已於 2026-08-29 放棄,`migrate` 扣掉資料搬遷後與「在既有目錄上 init」是同一件事,而 `.storyflow/` 那條分支在這台機器上沒有任何真實對象;留著等於養一條永遠不會被呼叫、卻要進 CLI 說明與 OpenAPI 的路徑 |
| 中樞的序列化保留使用者的註解與空白行 | **用泛型 encoder 整檔重寫**:實作最省。否決理由是 ADR-017 決策二把「可手寫」列為中樞的性質,整檔重寫會把使用者寫的註解吃掉一次就沒了 |
