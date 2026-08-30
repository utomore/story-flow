---
id: service
type: subsystem
title: service
description: 所有業務操作的唯一定義處:ServiceM、錯誤語彙、樂觀鎖與業務驗證的執行點
status: active
created: 2026-08-29
updated: 2026-08-30
parent: system
related-adr: [ADR-006, ADR-013, ADR-014, ADR-015, ADR-017, ADR-022]
code-paths: [service/src]
---

# 業務契約(service)子系統架構

## 定位與範圍

主架構「子系統劃分 › 契約 › `service`」。這一層是 ADR-006 的實體化,經 ADR-015 收窄:
**業務邏輯存在於 `service` 與各領域子系統的對外契約,`shell` 零業務邏輯**。三個殼(CLI / HTTP /
MCP)看到的行為由型別強制一致——邏輯只有一份,不可能悄悄長歪。

涵蓋一個套件:

| 元件 | 職責 | IO |
|---|---|---|
| `aapms-service` | `ServiceM` 與全部業務操作;`ServiceError` / `errorCode` / `renderServiceError`;業務驗證(必填、型別、關聯、樹);樂觀鎖的執行點;`Env` 的 vault handle 快取與互斥 | 委派 graph-core 與 workspace,自己不碰檔案格式 |

相依:`aapms-core` / `aapms-types` / `aapms-store`(graph-core)、`aapms-workspace`。
(`aapms-types` 由 2026-08-30 的 W1 閘門補列:契約 A 明文要求 `openEnv` 載入型別註冊表,而
`loadRegistry` 住在 `aapms-types`——原句漏列,不是新的架構變更。)
**不 import 任何領域子系統**(`archive` / `ingest` / `reorg` / `conflict` / `llm` / `ai` / `workshop` /
`project`),也不 import `shell` 的任何套件——契約層單向向下,由 `CabalSpec` 逐字清單釘住
(system.md 通訊拓撲硬規則 1)。

**明確不做**:

- **呈現**。統一信封、exit code、終端編碼、HTTP 狀態碼、OpenAPI、MCP 映射全部在 `shell`。
  本子系統回的是型別,不是字串格式
- **參數解析**。`--vault` / `--remote` / `--json` 的**解析**在 `shell`;本子系統只收一個
  「selector 字串」與一個「起點目錄」,語意由 `workspace` 裁決
- **落地格式**。Markdown 分節、索引 schema、原子寫入屬 graph-core;中樞 TOML 屬 `workspace`
- **領域管線**。壓縮檔、縮圖、叢集、衝突判斷、LLM、專案產出各屬其領域子系統。本子系統只提供
  它們需要的圖譜讀寫,而且**那些出口目前刻意未定**(見「暫不定案的下游出口」)

**這一層存在的價值不是「多一層」**:`store` 沒做的四件事——型別驗證有人呼叫、範圍與連線收進
`Env`、錯誤講業務語彙、組合操作有歸屬——在這裡補上,而且只補一次。

**與 legacy 的關係**:legacy `service-and-interfaces`(`.design/legacy/subsystems/`)是移植參考,
它的 28 個操作在此擴編為統一節點的操作集;`api` / `server` / `cli` 依 ADR-015 拆進 `shell`,
本文件不涵蓋它們。

## 對外契約(Public Interface & DTOs)

消費者:`shell` 的三個殼(全部 REST / CLI 出口)、四個領域子系統(僅內嵌出口,見文末)。

每個操作標明**出口**:`內嵌` = 只給本專案其他子系統與測試、`CLI` = 有對應子指令、`REST` = 有路由。
**動這台機器的操作一律不上 REST**(`workspace setup` / `purge`、`vault init` / `forget`):
它們管的是這台機器,跨 HTTP 沒有意義——沿用 legacy 對 `doctor` 的同一條判準。

### A. 執行環境

```haskell
data Env                                    -- 中樞快照 + 註冊表 + selector + cwd + handle 快取 + 鎖
newtype ServiceM a

openEnv    :: Maybe Text -> FilePath -> IO (Either ServiceError Env)
runService :: Env -> ServiceM a -> IO (Either ServiceError a)
closeEnv   :: Env -> IO ()
withEnv    :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
```

| 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `openEnv` 第一參數 | Maybe Text | `Nothing` = 沒給 `--vault`;`Just s` 的 `s` 非空 | 原樣交給 `workspace` 的 selector,本層**不解讀** |
| `openEnv` 第二參數 | FilePath | 絕對路徑,通常是行程的當前目錄 | 向上探測的起點 |

**`openEnv` 不開任何索引**(與 legacy 相反):它做兩件事——載入中樞(`loadHub`)與載入型別註冊表
(`loadRegistry`),兩者任一失敗即失敗,**不退回空值**(主架構全域錯誤策略第 3 條)。
vault 索引在第一個真的需要它的操作上才開,開過就留在 `Env` 的快取裡,`closeEnv` 一次全關。

**`Env` 內含一把互斥鎖,而且是全域一把**(不是每個 vault 一把)。三件事都靠它:

1. `sqlite-simple` 的 `Connection` 不保證多執行緒安全,而 warp 是多執行緒的
2. handle 快取本身是可變狀態
3. 「先寫檔、再更新索引」這條紀律在**請求之間**也要是原子的——兩個並發的寫入不可能交錯成
   「A 寫檔 → B 寫檔 → A 更新索引」

**鎖從 `shell` 搬進 `Env`**(legacy 放在 `aapms-server` 的 `AppState`):`Env` 現在自帶可變狀態,
保護它的責任跟著搬,否則每個殼都要自己記得包一層。**被否決的替代方案**:每個 vault 一把鎖,
可並行寫不同 vault(system.md 也明說寫鎖預算逐索引適用)——否決理由是跨 vault 讀要一次拿多把鎖,
就得再定一套取得順序來避免死結,而單人工作室的吞吐量不是瓶頸;legacy 已經為同一個取捨留過紀錄。

### B. 範圍與 View 的共用形狀

```haskell
data NodeView = NodeView
  { nvVault    :: VaultId
  , nvMeta     :: Meta
  , nvPath     :: FilePath          -- 相對 vault 根目錄
  , nvAnchor   :: Maybe Text        -- 節層錨點;檔案層節點為 Nothing
  , nvWarnings :: [MetaWarning]     -- checkMeta 的結果,只警告不擋
  , nvDetail   :: NodeDetail }

data NodeDetail
  = DEntity  { deBody :: Text }
  | DAsset   { daName :: Maybe LogicalName, daSha256 :: Sha256, daEntry :: Text
             , daExt :: Maybe Text, daKindMeta :: Value, daLicense :: Maybe Ref
             , daAuthor :: Maybe Text }
  | DPack    { dpVendor :: Maybe Text, dpArchive :: Maybe FilePath, dpSha256 :: Maybe Sha256
             , dpLicense :: Maybe Ref, dpAuthor :: Maybe Author, dpSourceUrl :: Maybe Text
             , dpAiDisclosure :: AiDisclosure }
  | DLicense { dlCommercial :: Bool, dlAttributionRequired :: Bool, dlCreditText :: Maybe Text
             , dlModificationAllowed, dlRedistributionAllowed, dlResaleAllowed, dlNftAllowed :: Maybe Bool
             , dlSourceUrl :: Maybe Text, dlFullText :: Maybe Text }
  | DLevel   { dvRoot :: Id, dvTree :: Maybe NodeTreeView }
  | DNode    { dnLevel :: Id, dnParent :: Maybe Id, dnOrder :: Int, dnKind :: NodeKind
             , dnEntities :: [Ref] }

data NodeTreeView = NodeTreeView { ntvNode :: NodeView, ntvChildren :: [NodeTreeView] }
```

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `nvVault` | VaultId | 恒非空;跨 vault 查詢時**每一筆都帶** | 這筆來自哪個 vault(ADR-017 決策三) |
| `nvPath` | FilePath | **相對 vault 根目錄**,POSIX 分隔符 | 作者要拿去開檔的位置 |
| `nvAnchor` | Maybe Text | `Just` 時等於節層 `{#id}` 的 id 字串;檔案層節點為 `Nothing` | 節在檔案裡的位置 |
| `nvWarnings` | [MetaWarning] | 可為空;`checkMeta` 的原件 | **只警告不擋**;擋不擋是寫入路徑的事(契約 E) |
| `dvTree` | Maybe NodeTreeView | `Nothing` = 這次沒要樹(清單查詢);`Just` = 完整子樹 | 避免清單查詢付整棵樹的成本 |

`NodeDetail` 對節點種類做 sum(與 graph-core 的 `AnyNode` 同構,建構子封閉):新增節點型別時
編譯器會列出全部待處理處。**一種形狀**是刻意的——system.md 的「AI Agent 只 parse 一種形狀」與
「統一 `Meta`,抽象成本只付一次」在這一層兌現。

### C. 本機與註冊表(出口:內嵌 + CLI;`vault list` / `type` 另加 REST)

```haskell
workspaceSetup  :: ServiceM SetupView                         -- 內嵌 + CLI
workspaceDoctor :: ServiceM DoctorView                        -- 內嵌 + CLI
workspaceTools  :: ServiceM [ToolStatus]                      -- 內嵌 + CLI
workspacePurge  :: PurgeScope -> ServiceM PurgeView           -- 內嵌 + CLI

vaultInit   :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM VaultView   -- 內嵌 + CLI
vaultAdd    :: FilePath -> ServiceM VaultView                 -- 內嵌 + CLI
vaultList   :: ServiceM [VaultView]                           -- 內嵌 + CLI + REST
vaultInfo   :: Text -> ServiceM VaultInfoView                 -- 內嵌 + CLI + REST
vaultForget :: Text -> DeleteIndex -> ServiceM VaultView      -- 內嵌 + CLI
vaultCheck  :: ServiceM [ScopeIssue]                          -- 內嵌 + CLI

projectRegister :: FilePath -> Text -> ServiceM ProjectView   -- 內嵌 + CLI
projectList     :: ServiceM [ProjectView]                     -- 內嵌 + CLI + REST
projectForget   :: Text -> ServiceM ProjectView               -- 內嵌 + CLI

listTypes :: ServiceM [TypeDecl]                              -- 內嵌 + CLI + REST
showType  :: TypeKey -> ServiceM TypeDecl                     -- 內嵌 + CLI + REST

thumbPath :: Sha256 -> ServiceM (Maybe FilePath)              -- 內嵌(供 shell 的 /thumb 端點)

data VaultView = VaultView
  { vvId :: VaultId, vvName :: Text, vvKind :: VaultKind, vvPath :: FilePath
  , vvRegistered :: Bool, vvReachable :: Bool }
data VaultInfoView = VaultInfoView
  { viVault :: VaultView, viCounts :: [(Text, Int)], viIssues :: [IndexIssue] }
data DoctorView = DoctorView
  { dvHubPath :: FilePath, dvHubSource :: HubSource, dvRegistry :: RegistrySource
  , dvVaults :: [VaultView], dvScopeIssues :: [ScopeIssue], dvTools :: [ToolStatus]
  , dvLlmConfigured :: Bool }
data ProjectView = ProjectView { pvId :: Id, pvName :: Text, pvPath :: FilePath, pvReachable :: Bool }
data SetupView   = SetupView   { svHubPath :: FilePath, svHubCreated :: Bool, svCacheCreated :: Bool }
data PurgeView   = PurgeView   { pvHubRemoved :: Bool, pvThumbsRemoved :: Int
                               , pvVaultIndexesRemoved :: [FilePath] }
```

`SetupView` / `PurgeView` 是 workspace 的 `SetupReport` / `PurgeReport` 的**線上投影**(欄位一一對應、
語意與值域相同,見 workspace 契約 D)。它們住在本層是因為線上格式屬本層;**投影是單向無狀態的**,
被投影的事實仍屬 workspace(`boundary-rules.md` 的知識歸屬:投影函數可以住在消費端,被投影的
事實不行)。`VaultKind` / `InitMode` / `DeleteIndex` / `PurgeScope` / `ScopeIssue` / `ToolStatus` /
`HubSource` 一律 **re-export 不重新定義**——那些是判斷,不是投影。

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `vvRegistered` | Bool | `False` = 這是向上探測到、但不在中樞的 vault | 讓 `doctor` 說得出「你在一個未註冊的 vault 裡」 |
| `vvReachable` | Bool | `False` = 路徑不存在或 marker 讀不出來 | 對應 workspace 的 `ScopeIssue` |
| `viCounts` | [(Text, Int)] | 鍵是 `IdPrefix` 的文字表示(`ent` / `ast` / `pck` / …),值 ≥ 0 | 節點數;**要開索引才算得出來** |
| `dvLlmConfigured` | Bool | `True` ⟺ 中樞有 `[llm]` 段 | **只報告有沒有,不報告內容**——鍵與語意屬 `ai`,而且 `api_key` 不該進診斷輸出 |
| `thumbPath` 的參數 | Sha256 | 64 位小寫十六進位 | 內容位址 |
| `thumbPath` 的回傳 | Maybe FilePath | `Nothing` = 快取裡**沒有這個檔**;`Just p` = `p` 存在且可讀 | 位置由 `workspace` 的 `thumbCachePath` 算,本層只多做一次存在性檢查 |

`thumbPath` 是 2026-08-29 由 `shell` 的 B2 對帳補進來的(`/thumb/<sha256>` 端點的來源)。
它**只開內嵌出口**:`shell` 拿到路徑後自己回檔案,`service` 不碰位元組、不解碼影像。

`workspaceDoctor` 是唯一一個「彙總這台機器狀態」的地方。它組合的全部來自 `workspace` 與
graph-core,**不 import 任何領域子系統**——這正是 `[tools]` 與 `[llm]` 住中樞的理由
(ADR-017 2026-08-29 補充):否則 `doctor` 在現行拓撲下無處可放。

### D. 圖譜讀取(出口:全部三種)

```haskell
getNode     :: Ref -> Bool -> ServiceM NodeView            -- 第二參數:Level 要不要帶樹
listNodes   :: NodeFilter -> ServiceM (Page NodeView)
childrenOf  :: Ref -> ServiceM [NodeView]
linksOf     :: Ref -> ServiceM LinkReport
search      :: SearchQuery -> ServiceM SearchView

data Page a      = Page { pgItems :: [a], pgTotal :: Int, pgOffset :: Int, pgLimit :: Int }
data LinkReport  = LinkReport { lrOut :: [(Link, Maybe NodeView)], lrIn :: [(NodeView, Link)] }
data SearchView  = SearchView { svHits :: [SearchHitView], svTotal :: Int, svFacets :: Maybe FacetCounts }
data SearchHitView = SearchHitView { shvNode :: NodeView, shvSnippet :: Text, shvScore :: Double }
```

| 欄位 / 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `getNode` 第一參數 | Ref | 帶 vault 時定址該 vault;不帶時預設 vault = 本次寫入目標,沒有寫入目標時 = 讀取範圍裡**唯一**含此 id 的 vault,撞到多個回 `AmbiguousRef` | 定址 |
| `getNode` 第二參數 | Bool | `True` 才填 `dvTree`;非 Level 節點時忽略 | 樹的成本要呼叫端明確要 |
| `pgTotal` | Int | ≥ 0;**符合條件的總數**,不是本頁筆數 | 分頁 |
| `pgOffset` / `pgLimit` | Int | ≥ 0;回傳的是**實際生效**的值(被夾住後的) | 分頁 |
| `lrOut` 的 `Maybe NodeView` | Maybe | `Nothing` = 目標在讀取範圍內解不到(懸空) | 讀取不擋懸空,只如實呈現 |
| `shvScore` | Double | bm25,**越大越相關**;恒有值(兩條 FTS 路徑都給分,ADR-016) | 相關度 |

**讀取一律走讀取範圍**(`resolveRead`):沒有 `--vault` 就是全部已註冊 vault,每一筆都帶
`nvVault`。`search` 因此「一次回兩種」——asset 與 entity 在同一張索引上,命中集合天然含兩者
(system.md 對外介面第 1 節)。

範圍解析產生的 `ScopeIssue` 在讀取路徑上**不中止**;它們經 `workspaceDoctor` 與 `vaultCheck`
呈現,`shell` 另在非 `--json` 模式的輸出開頭顯示作用中的 vault。

### E. 圖譜寫入(出口:CLI + REST;`expected revision` 一律必填)

```haskell
createEntity :: NewEntityReq -> ServiceM NodeView
addFragment  :: Ref -> NewFragmentReq -> ServiceM NodeView
updateMeta   :: Ref -> Revision -> MetaPatch -> ServiceM NodeView
setBody      :: Ref -> Revision -> Text -> ServiceM NodeView
deleteNode   :: Ref -> Revision -> DeleteMode -> ServiceM DeleteReport

setAssetName    :: Ref -> Revision -> LogicalName -> ServiceM NodeView
updateAssetMeta :: Ref -> Revision -> AssetPatch -> ServiceM NodeView
upsertLicense   :: NewLicenseReq -> ServiceM NodeView

addLink    :: Ref -> Revision -> Link -> ServiceM NodeView
removeLink :: Ref -> Revision -> Link -> ServiceM NodeView

createLevel :: NewLevelReq -> ServiceM NodeView
deleteLevel :: Ref -> Revision -> ServiceM DeleteReport
addNode     :: Ref -> NewNodeReq -> ServiceM NodeView       -- 第一參數:父節點
removeNode  :: Ref -> Revision -> ServiceM DeleteReport

reindex       :: ServiceM [IndexReport]
refreshIndex  :: ServiceM [IndexReport]
data IndexReport = IndexReport { irVault :: VaultId, irFiles :: Int, irIssues :: [IndexIssue] }
data DeleteReport = DeleteReport { drRemoved :: [Ref], drVault :: VaultId }
```

| 參數 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| 每個寫入的 `Revision` | Revision | **必填,沒有逃生口**;必須等於目標目前的 `metaRevision`,否則 `RevisionConflict` | 樂觀鎖 |
| `deleteNode` 的 `DeleteMode` | graph-core 契約 E 的型別 | 沿用,不重新定義 | 刪除範圍 |
| `irFiles` | Int | ≥ 0,**這個 vault 這次重讀的檔案數** | 索引報告 |
| `drRemoved` | [Ref] | 非空;含被級聯刪除的子節點 | 真的刪了什麼 |

**請求型別**(線上格式的另一半;`shell` 解碼成它們,本層之後只認它們):

```haskell
data NewEntityReq   = NewEntityReq   { neType :: TypeKey, neTitle :: Text, neSummary :: Text
                                     , neTags :: [Text], neStatus :: Maybe Status
                                     , neTimeline :: Maybe Timeline, neAliases :: [Text]
                                     , neLinks :: [Link], neSource :: Source, neBody :: Text }
data NewFragmentReq = NewFragmentReq { nfType :: Maybe TypeKey, nfTitle :: Text, nfSummary :: Text
                                     , nfTags :: [Text], nfAliases :: [Text], nfLinks :: [Link]
                                     , nfSource :: Source, nfBody :: Text }
data MetaPatch      = MetaPatch      { mpTitle, mpSummary :: Maybe Text, mpTags, mpAliases :: Maybe [Text]
                                     , mpStatus :: Maybe Status, mpTimeline :: Maybe (Maybe Timeline) }
data NewLevelReq    = NewLevelReq    { nlTitle :: Text, nlSummary :: Text, nlRootTitle :: Text
                                     , nlSource :: Source }
data NewNodeReq     = NewNodeReq     { nnTitle :: Text, nnSummary :: Text, nnKind :: NodeKind
                                     , nnEntities :: [Ref], nnBody :: Text, nnSource :: Source }
data NewLicenseReq  = NewLicenseReq  { nlcKey :: Text, nlcTitle :: Text, nlcCommercial :: Bool
                                     , nlcAttributionRequired :: Bool, nlcCreditText :: Maybe Text
                                     , nlcModificationAllowed, nlcRedistributionAllowed
                                     , nlcResaleAllowed, nlcNftAllowed :: Maybe Bool
                                     , nlcSourceUrl, nlcFullText :: Maybe Text }
-- AssetPatch 沿用 graph-core 契約 E 的型別,本層不重新定義
```

| 欄位 | 型別 | 單位 / 值域 | 語意 |
|---|---|---|---|
| `neType` | TypeKey | 必須在註冊表且 `family == FEntity`;保留鍵(`level` / `asset-pack` / `asset-license`)一律拒絕 | 建立什麼型別 |
| `neStatus` | Maybe Status | `Nothing` = 取預設 `Draft`;不接受 `Missing`(那是掃描才給的) | 初始狀態 |
| `neTimeline` / `nfType` | Maybe | `Nothing` = **沒有這個值**(不是「不變」——建立時沒有「不變」可言) | — |
| `nfType` | Maybe TypeKey | `Nothing` = 繼承檔案層的 `type`(graph-core 的節層繼承規則) | 片段型別 |
| `mp*` 各欄 | Maybe | `Nothing` = **不變**;`Just v` = 改成 `v`。這是 patch 語意,與建立請求相反 | 部分改寫 |
| `mpTimeline` | Maybe (Maybe Timeline) | 三態:`Nothing` = 不變、`Just Nothing` = **清空**、`Just (Just t)` = 設成 `t` | 唯一需要三態的欄位 |
| `neSource` / `nfSource` / `nlSource` / `nnSource` | Source | 必填,**不給預設**:寫入者是誰是稽核資訊,猜錯比缺漏更糟 | `human` / `agent:<name>` / … |
| `nlRootTitle` | Text | 去空白後長度 ≥ 1 | Level 建立時同時建根節點,`lvlRoot` 指向它 |
| `nnKind` | NodeKind | graph-core 的型別,沿用 | 場景節點種類 |
| `nlcKey` | Text | 非空、小寫 kebab-case;同一 vault 內唯一 | `licenses.md` 的節名(如 `cc0`) |
| 全部 `*Req` 的 `id` | — | **沒有這個欄位**:id 一律由 `allocateId` 配,呼叫端不得指定 | ADR-014 |

**寫入一律走寫入範圍**(`resolveWrite`):寫只進 `wsTarget` 一個 vault,讀(關聯目標檢查)走
`wsRead`。沒有寫入目標時直接失敗——`workspace` 的 `NoWriteTarget` 原樣包上,**程式不猜**。

**四條業務驗證,全部在這一層,全部擋下**(graph-core 只說出發生了什麼,不決定怎麼辦):

| 驗證 | 錯誤 | 判準 |
|---|---|---|
| 必填欄位缺漏 | `ValidationFailed` | `checkMeta` 回的警告裡**只有 `MissingRequiredField` 這一個建構子**擋下寫入;`LinkNotAllowed` / `UnknownNodeType` / `NameKindNotAllowed` 只進 `nvWarnings` |
| 型別不在註冊表 | `UnknownType` | 建立時給的 `TypeKey` 查不到 |
| 關聯目標不存在 | `DanglingLinkTarget` | 目標的 vault **在**讀取範圍內,但節點不存在 |
| 關聯目標的 vault 不在範圍 | `LinkTargetOutOfScope` | 目標 vault 不在 `wsRead` 裡。**不靜默接受**:訊息要說出「把它加進這個 vault 的 `refs`,或用 `--vault` 展開範圍」 |
| Level 樹不合法 | `LevelTreeInvalid` | `buildTree` 失敗;graph-core 在寫入路徑也擋一次,這裡是先擋 |

**`setAssetName` 的全域唯一另成一條**(2026-08-29 裁決):寫 `name` 時的唯一性檢查**不受
`--vault` 收窄影響**,一律對**全部已註冊 vault**做——本層另外取一次「全部已註冊」的範圍查
`lookupByName`,撞名回 `LogicalNameTaken`(帶既有那筆的 `<vault>:<id>`)。理由是
`system.md` 把 `name` 定為 `Assets.hs` 的 key 且**全域唯一**,而寫入路徑天生是收窄的;
若只在收窄範圍內檢查,保證會隨使用者怎麼下旗標而變。代價寫在「不可逆決定」那一節。

### F. 錯誤契約(三個殼共用的唯一來源)

```haskell
data ServiceError
  = StoreFailed StoreError | WorkspaceFailed WorkspaceError
  | RegistryUnavailable RegistryError | RegistryLoadFailed RegistryError
  | ValidationFailed (Maybe Id) [MetaWarning]
  | UnknownType Text
  | DanglingLinkTarget Ref | LinkTargetOutOfScope Ref
  | LevelTreeInvalid Id [TreeError]
  | RevisionConflict Ref Revision Revision        -- 期望、實際
  | LogicalNameTaken LogicalName Ref
  | AmbiguousRef Id [VaultId]
  | NodeNotFound Ref

errorCode          :: ServiceError -> Text        -- snake_case 穩定識別碼
renderServiceError :: ServiceError -> Text        -- 繁中,每則說出下一步
```

`errorCode` / `renderServiceError` 是**三個殼共用 `code` 與訊息的唯一來源**(system.md 全域錯誤
策略第 1 條)。`code` 是 snake_case、**不帶產品前綴**(legacy MCP 的 `story_flow_*` 在此退場,
主架構 P0 進度已把它列為刻意留到 P3 的執行期名稱)。

下層錯誤**原樣包、不重寫訊息**:`StoreFailed` 委派 graph-core 的 `renderStoreError`、
`WorkspaceFailed` 委派 `renderWorkspaceError`。`errorCode` 對這兩個建構子仍要給出**可分辨的**
code——機器要分得出「落地失敗」與「工作區設定失敗」,而那是本層才有的知識。

`RevisionConflict` 必須同時列出期望與實際的 `revision`,呼叫端才知道要重讀再試。
`AmbiguousRef` 必須列出全部候選 vault,使用者才寫得出 `<vault>:<id>`。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 | 擁有的事實(唯一真相來源) |
|---|---|---|
| Types | 請求型別、View 型別、`Page`、`ServiceError` 與兩個 render / code 函式 | **線上格式**與**錯誤語彙**(`code` 與訊息) |
| Monad | `Env`、`ServiceM`、`openEnv` / `runService` / `closeEnv`、handle 快取與鎖 | **一次執行期間的資源生命週期** |
| Scope | `withRead` / `withWrite` / `withPipeline`:把 workspace 的裁決換成開好的 handle 與 `VaultSet` | **範圍與 handle 的對應**(誰要被開、誰要被 ATTACH) |
| Validate | 四條業務驗證 + 樂觀鎖比對的前置 | **什麼情況擋下寫入**(業務政策) |
| Read | 讀取類操作、`AnyNode → NodeView` 的投影 | — |
| Write | 寫入類操作、`setAssetName` 的全域唯一 | **命名唯一性在哪個範圍上成立** |
| Machine | 本機與註冊表門面(`workspace*` / `vault*` / `project*` / `listTypes`) | — |

沒有兩個模組宣稱擁有同一個事實。**節點的落地形狀不屬於任何一個模組**——那是 graph-core;
本層只擁有它的**線上投影**。

**Types 為什麼要獨立**(與 graph-core 契約 G、workspace 的 Types 同一個道理):`ServiceError`
捧著 `Ref` / `LogicalName` / `StoreError` / `WorkspaceError` 與本層的 `MetaWarning`,而每個模組
都回 `Either ServiceError a`。Types 可以依賴 graph-core 與 workspace 的型別,但**不得 import
本套件的任何其他模組**;其餘六個模組全部往 Types 依賴,型別歸屬圖因此是一棵樹。

## 資料流管線(Data Flow Pipeline)

三條;`Env` 在每條裡只被建立一次。

**讀取(請求 → 範圍 → 圖譜 → View)**

```text
shell 解碼成請求型別(NodeFilter / SearchQuery / Ref)
  → runService:自 Env 取中樞快照、註冊表、selector、cwd
  → Scope.withRead:workspace.resolveRead → 對每個 VaultRef 查 handle 快取,缺的 openVault
    → openVaultSet 組 VaultSet(ATTACH 上限由 graph-core 判)→ ScopeIssue 一併帶出
  → graph-core:listAcross / searchAcross / lookupRef / linksTo(每筆帶 VaultId)
  → aapms-core:checkMeta 產生 nvWarnings(只警告,不擋)
  → Read:AnyNode + 檔案路徑 + 錨點 → NodeView / Page / SearchView
  → 出口渲染(shell):統一信封 / REST body
```

**寫入(請求 → 驗證 → 落地 → 新 revision)**

```text
shell 解碼成請求型別 + expected revision(必填)
  → Scope.withWrite:workspace.resolveWrite → 寫入目標一個 handle、讀取範圍一個 VaultSet
     沒有寫入目標 → WorkspaceFailed NoWriteTarget,到此為止
  → Validate:UnknownType → ValidationFailed(必填)→ 關聯目標(在範圍內?存在?)
     → Level 樹合法性;setAssetName 另取「全部已註冊」範圍查 lookupByName
  → graph-core 的寫入組:樂觀鎖比對(重讀檔案,不是索引)→ 位元組保留寫回 → 原子寫入 → indexFile
  → 回 WriteResult 的新 revision → 重投影成 NodeView
```

任一段失敗都短路成 `ServiceError`,由 `errorCode`(機器)與 `renderServiceError`(人)產出三個殼
共用的同一組 code 與訊息。**這一層之後不再有業務判斷**——`shell` 只用 `code` 字串分派狀態碼。

**本機(這台機器 → 一份報告)**

```text
openEnv 已載入的中樞快照 + 註冊表來源
  → workspace:checkVaults(不寫檔)、detectSevenZip、hubLlm 是否存在
  → 需要節點數時(vaultInfo)才 withRead 開該 vault 的索引
  → 組成 DoctorView / VaultInfoView;[llm] 只報告有沒有,不報告內容
```

## 模組間公開介面(Module Interfaces)

| 呼叫方向 | 介面 |
|---|---|
| 全部模組 → Types | 請求 / View 型別與 `ServiceError`;Types 不回頭 import 任何一個 |
| Read / Write / Machine → Scope | `withRead :: (VaultSet -> [VaultRef] -> ServiceM a) -> ServiceM a`、`withWrite :: (VaultHandle -> VaultSet -> ServiceM a) -> ServiceM a`、`withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a`;範圍解析的結果只經這三個口進來 |
| Scope → Monad | `handleFor :: VaultRef -> ServiceM VaultHandle`(查快取,缺的 `openVault` 後放回)。**唯一開 handle 的地方**;`indexIssuesFor :: VaultId -> ServiceM [IndexIssue]` 取第一次開啟時 `openVault` 一併回的問題清單(2026-08-30 W1 閘門 A3:那份清單只在第一次開啟時產生,快取命中的第二次拿不到,所以由 `Env` 存住而不是塞進 `handleFor` 的回傳——後者會讓同一個輸入有兩種輸出) |
| Machine / Read / Write → Monad | `askHubLocation` / `askHub` / `reloadHub` / `askRegistry` / `askNaming` / `askRegistrySource` / `askSelector` / `askCwd`,全部是 `ServiceM` 動作;加錯誤 helper `throwService` / `liftStore` / `liftWorkspace`。**`Env` 維持不透明**(建構子與欄位不匯出),讀它的內容一律經這一組(2026-08-30 W1 閘門 A2:原表只有 `Scope → Monad` 一列,但 `DoctorView` 的 `dvHubPath` / `dvHubSource` / `dvRegistry` 與 `vaultList` 都要讀中樞快照,`withRead` 自己也要 hub + selector + cwd)。`reloadHub` 是「`Env` 的中樞快照在寫入後必須重新載入」那條規則的執行點 |
| Scope → `aapms-workspace` | `resolveRead` / `resolveWrite` / `resolvePipeline`;失敗原樣包成 `WorkspaceFailed` |
| Scope → `aapms-store` | `openVault` / `openVaultSet` / `closeVaultSet`;`VaultSet` 不進快取(ATTACH 便宜,`openVault` 不便宜) |
| Write → Validate | `validateForWrite :: TypeRegistry -> VaultSet -> AnyNode -> ServiceM ()`;通過才進落地 |
| Read / Write → `aapms-store` | 查詢組與寫入組;樂觀鎖由 graph-core 執行,本層只把 `Revision` 傳下去並把失敗翻成 `RevisionConflict` |
| Machine → `aapms-workspace` | 生命週期那一組;`Env` 的中樞快照在寫入後**必須重新載入**(`Hub` 是不可變值) |

**方向是線性的**:`Types ← Monad ← Scope ← {Validate, Read, Write, Machine}`。沒有回頭邊。

## 使用的技術

沿用主架構。子系統特有的兩個決定:

- **`mtl` 的 `ReaderT Env` + `ExceptT ServiceError`**:業務操作是**組合**的,手工串 `Either` 會讓
  每個函式的主體被 `case` 淹沒,而錯誤處理正是最不該被淹沒的部分(沿用 legacy)
- **handle 快取 + 全域一把鎖**,不是連線池:見契約 A 的理由與被否決的替代方案

`aeson` 的編碼規則沿用 `aapms-core` 的 Json 模組,**本層不另立一套**——`ToSchema` 與 `ToJSON`
逐欄對齊的責任在 `shell` 的 `aapms-api`。

## 架構圖

```text
              shell(aapms-api / -cli / -server / -mcp)    領域子系統(P4–P6)
                          │                                      │
                          ▼                                      ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │  aapms-service                          ★ 唯一業務契約                │
   │                                                                      │
   │   ┌────────┐   ┌────────┐   ┌────────┐                               │
   │   │ Types  │◄──│ Monad  │◄──│ Scope  │◄─┬─ Validate  四條業務驗證     │
   │   │ View   │   │ Env    │   │ withRead │ ├─ Read      投影成 NodeView │
   │   │ 請求型別│   │ handle │   │ withWrite│ ├─ Write     樂觀鎖·命名唯一 │
   │   │ Error  │   │ 快取+鎖 │   │ withPipe │ └─ Machine   本機與註冊表    │
   │   │ code   │   └────────┘   └────────┘                               │
   │   └────────┘                                                         │
   └───────┬──────────────────────────────────────────┬───────────────────┘
           │ resolveRead / resolveWrite / 生命週期      │ openVault · 查詢 · 寫入
           ▼                                           ▼
    aapms-workspace                             graph-core(core / store)

   出口:內嵌(本專案其他子系統與測試)· CLI · REST
   不上 REST:workspace setup / purge、vault init / forget —— 它們管的是這台機器
```

## 開發階段

對應主架構 **P3「骨幹」**,與 `workspace`、`shell` 同期。本子系統夾在中間:`workspace` 的階段一
(中樞與裁決)是它的前提,而 `shell` 的每一個殼都只是它的薄包裝。

內部里程碑即下方三個階段:階段一結束時 `Env` 開得起來、錯誤語彙立好;階段二結束時兩種 vault 的
節點都 CRUD 得動;階段三結束時 `search` 一次回兩種、索引重建報告得出來,主架構 P3 的交付判準
在 `shell` 接上後可驗。

## 功能規劃

### 階段一:骨幹

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | service-env-and-scope | `Env`(中樞 + 註冊表 + handle 快取 + 鎖)、`openEnv` / `runService` / `closeEnv`、三個範圍取得、`ServiceError` / `errorCode` 骨架 | Types、Monad、Scope | - | F001-service-env-and-scope.md |
| 2 | workspace-facade | vault 與專案生命週期、`workspace setup / doctor / tools / purge`、型別註冊表查詢 | Machine | #1 | - |

### 階段二:圖譜操作

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 3 | node-read | `getNode` / `listNodes` / `childrenOf` / `linksOf`;`AnyNode → NodeView` 投影、每筆帶 vault | Read | #1 | - |
| 4 | node-write | 建立 / 片段 / 改寫 / 刪除、樂觀鎖、五條業務驗證 | Write、Validate | #3 | - |
| 5 | asset-naming | `setAssetName` 的全域唯一、`updateAssetMeta`、`upsertLicense` | Write、Validate | #4 | - |
| 6 | level-and-node | Level 與 Node 的建立 / 刪除、樹視圖 | Write、Read | #4 | - |

### 階段三:檢索與索引

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 7 | search-facade | `search` 一次回 asset 與 entity 兩種、facet、每筆帶 vault | Read | #3 | - |
| 8 | index-ops | `reindex` / `refreshIndex` / `IndexReport` | Machine、Scope | #3 | - |

小結:共 **8 個 features、3 個階段**;全部完成即代表三個殼有一份完整的業務契約可包,主架構 P3
的「兩種 vault 都能經統一外殼 CRUD、search 一次回兩種」在 `shell` 接上後可驗。

## Feature 契約卡

### service-env-and-scope

- **階段**:階段一
- **負責模組**:Types(建立骨架,後續 feature 各自擴充建構子)、Monad、Scope
- **實作的 Level 2 介面**:契約 A 全部(`Env` / `ServiceM` / `openEnv` / `runService` / `closeEnv` /
  `withEnv`);契約 F 的 `ServiceError` 骨架與 `errorCode` / `renderServiceError`,建構子先做
  `StoreFailed` / `WorkspaceFailed` / `RegistryUnavailable` / `RegistryLoadFailed`;模組間公開介面的
  `withRead` / `withWrite` / `withPipeline` / `handleFor`
- **資料流管線段落**:三條管線共用的前段(`runService` → `Scope.with*` → 開好 handle 與 `VaultSet`),
  到交給各操作為止
- **驗收標準**:
  - `openEnv` 成功回傳後**尚未開任何 vault 索引**(可觀察:任一 vault 的 `index.db` 檔案 mtime 不變,
    且該 vault 的 `.aapms/` 沒有新增暫存檔) — 觀察點:契約 A 的 `openEnv`
  - 中樞載不起來或型別註冊表載不起來時 `openEnv` 回 `Left`,**不回一個空的 `Env`**;錯誤分別是
    `WorkspaceFailed` 與 `RegistryUnavailable` / `RegistryLoadFailed` — 觀察點:契約 A 的 `openEnv`、
    契約 F 的四個建構子
  - 同一個 `Env` 上對同一個 vault 連續兩次 `withRead`,第二次**不再呼叫 `openVault`**(可觀察:
    索引檔的存取次數不增,或以一個只會成功一次的假路徑替換後第二次仍成功) — 觀察點:模組間公開
    介面的 `handleFor`
  - `closeEnv` 後所有開過的 handle 都被關閉:同一目錄可立即被另一個 `Env` 開啟且無鎖檔殘留 —
    觀察點:契約 A 的 `closeEnv`
  - 兩個並發的 `runService` 不會交錯:對同一個 `Env` 同時跑兩個寫入,最終 `revision` 恒為 +2 且
    兩次都成功或其中一次回 `RevisionConflict`,**不會出現索引與檔案不一致** — 觀察點:契約 A 的
    `runService`、契約 F 的 `RevisionConflict`
  - `errorCode` 對每個建構子都回一個非空、snake_case、**不含產品前綴**的字串,且兩兩相異 —
    觀察點:契約 F 的 `errorCode`
  - `renderServiceError (StoreFailed e)` 逐字等於 graph-core 的 `renderStoreError e`;
    `WorkspaceFailed` 同理委派 — 觀察點:契約 F 的 `renderServiceError`
- **明確不做**:不實作任何業務操作(#2 起);不做業務驗證(#4);不決定 HTTP 狀態碼(`shell`)

### workspace-facade

- **階段**:階段一
- **負責模組**:Machine
- **實作的 Level 2 介面**:契約 C 全部(`workspaceSetup` / `workspaceDoctor` / `workspaceTools` /
  `workspacePurge` / `vaultInit` / `vaultAdd` / `vaultList` / `vaultInfo` / `vaultForget` /
  `vaultCheck` / `projectRegister` / `projectList` / `projectForget` / `listTypes` / `showType` / `thumbPath` /
  `VaultView` / `VaultInfoView` / `DoctorView` / `ProjectView`);使用契約 A 與 #1 的
  `withRead`(無新增)
- **資料流管線段落**:本機管線全段(中樞快照 → workspace 的體檢與工具探測 → 需要節點數時才開索引 →
  `DoctorView` / `VaultInfoView`)
- **驗收標準**:
  - `vaultList` 對每個中樞條目都回一筆,且 `vvReachable == False` 恰好對應 workspace 回報
    `VaultPathMissing` 或 `VaultMarkerBroken` 的那些 — 觀察點:契約 C 的 `vaultList` / `VaultView`
  - 在一個未註冊的 vault 目錄裡 `openEnv` 後,`workspaceDoctor` 的 `dvVaults` 含一筆
    `vvRegistered == False` 的項目 — 觀察點:契約 C 的 `DoctorView` / `VaultView`
  - `dvLlmConfigured` 只反映「中樞有沒有 `[llm]` 段」,而 `DoctorView` 的**任何欄位都不含**該段的
    值(可觀察:把 `api_key` 設成一個特徵字串,整份報告序列化後不含它) — 觀察點:契約 C 的
    `DoctorView`
  - `workspaceDoctor` 與 `vaultCheck` 執行前後,中樞目錄與各 vault 的 `.aapms/` 位元組不變 —
    觀察點:契約 C 的 `workspaceDoctor` / `vaultCheck`
  - `vaultInfo` 的 `viCounts` 鍵集合是實際存在的 `IdPrefix` 文字表示,值等於該 vault 索引裡的節點數;
    對一個剛 `vaultInit` 的空 vault 全部為 0 或鍵不出現 — 觀察點:契約 C 的 `VaultInfoView`
  - `vaultInit` / `vaultAdd` / `vaultForget` / `projectRegister` / `projectForget` 之後,同一個 `Env`
    的後續 `vaultList` / `projectList` **看得到變更**(中樞快照有被重新載入) — 觀察點:模組間公開
    介面的 Machine → `aapms-workspace` 那一列、契約 C 的 `vaultList` / `projectList`
  - `showType` 對註冊表沒有的鍵回 `UnknownType` — 觀察點:契約 C 的 `showType`、契約 F 的 `UnknownType`
  - `thumbPath` 對快取裡存在的雜湊回 `Just p` 且 `p` 讀得到、對不存在的回 `Nothing`,而且 `p` 恒等於
    `workspace` 的 `thumbCachePath`(不自己拼路徑) — 觀察點:契約 C 的 `thumbPath`
- **明確不做**:不重新定義中樞的檔案格式、不自己拼 `.aapms/` 底下的路徑(一律用 workspace 與
  graph-core 的函式);不把 7-Zip 缺席當錯誤;不上 REST 的那幾個操作不得出現在 `shell` 的路由需求裡

### node-read

- **階段**:階段二
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 B 全部(`NodeView` / `NodeDetail` / `NodeTreeView`);契約 D 的
  `getNode` / `listNodes` / `childrenOf` / `linksOf` / `Page` / `LinkReport`;契約 F 的
  `NodeNotFound` / `AmbiguousRef`;使用 #1 的 `withRead`(無新增)
- **資料流管線段落**:讀取管線自 `Scope.withRead` 之後到 `NodeView` 投影為止
- **驗收標準**:
  - 對讀取範圍內任一節點,`getNode` 回的 `nvVault` 等於它實際所在的 vault;跨 vault 查詢時
    `listNodes` 的**每一筆**都有 `nvVault` — 觀察點:契約 B 的 `nvVault`、契約 D 的 `listNodes`
  - `nvMeta` 與 graph-core 讀回的 `anyMeta` 逐欄相等(本層不改寫任何 `Meta` 欄位) — 觀察點:
    契約 B 的 `NodeView`
  - `nvDetail` 的建構子恒對應節點的 `IdPrefix`(`ast-` ⟺ `DAsset`,依此類推) — 觀察點:契約 B 的
    `NodeDetail`
  - `getNode` 第二參數為 `False` 時 Level 的 `dvTree == Nothing`;為 `True` 時 `dvTree` 的樹與
    graph-core 的 `buildTree` 結果同構 — 觀察點:契約 D 的 `getNode`、契約 B 的 `dvTree`
  - 不帶 vault 的 `Ref` 在讀取範圍內命中多個 vault 時回 `AmbiguousRef` 並列出全部候選;
    一個都沒有時回 `NodeNotFound` — 觀察點:契約 F 的兩個建構子
  - `listNodes` 的 `pgTotal` 是符合條件的**總數**而非本頁筆數:對任意 `limit`,
    `pgTotal` 不隨 `limit` 改變 — 觀察點:契約 D 的 `Page`
  - `linksOf` 的 `lrOut` 對解不到的目標回 `Nothing` 而**不是錯誤**(讀取不擋懸空) — 觀察點:
    契約 D 的 `LinkReport`
  - 範圍解析產生 `ScopeIssue` 時讀取操作仍成功 — 觀察點:契約 D 的四個讀取操作
- **明確不做**:不做任何寫入;不擋懸空關聯(那是寫入路徑的事);不做全文檢索(#7)

### node-write

- **階段**:階段二
- **負責模組**:Write、Validate
- **實作的 Level 2 介面**:契約 E 的 `createEntity` / `addFragment` / `updateMeta` / `setBody` /
  `deleteNode` / `addLink` / `removeLink` / `DeleteReport` 與請求型別;契約 F 的 `ValidationFailed` /
  `UnknownType` / `DanglingLinkTarget` / `LinkTargetOutOfScope` / `LevelTreeInvalid` /
  `RevisionConflict`;模組間公開介面的 `validateForWrite`
- **資料流管線段落**:寫入管線自 `Scope.withWrite` 之後到新 `revision` 投影回 `NodeView` 為止
- **驗收標準**:
  - 沒有 `--vault` 且從 cwd 向上找不到 `.aapms/` 時,任一寫入操作都回
    `WorkspaceFailed NoWriteTarget`,且**沒有任何檔案被建立或修改** — 觀察點:契約 E 的寫入組、
    契約 F 的 `WorkspaceFailed`
  - 寫入只落在 `wsTarget` 一個 vault:讀取範圍內其他 vault 的檔案與索引位元組不變 — 觀察點:
    契約 E 的寫入組、契約 C 的 `vaultInfo`(節點數不變)
  - 給出的 `revision` 不等於目標當前值時回 `RevisionConflict` 並同時列出期望與實際,且檔案未動 —
    觀察點:契約 F 的 `RevisionConflict`
  - 成功寫入後回的 `nvMeta` 的 `metaRevision` 恰好是原值 +1 — 觀察點:契約 B 的 `nvMeta`
  - 建立時給註冊表沒有的型別回 `UnknownType`;必填欄位缺漏回 `ValidationFailed` 並帶那些警告,
    而**非必填類的警告不擋**、只出現在成功結果的 `nvWarnings` — 觀察點:契約 F 的兩個建構子、
    契約 B 的 `nvWarnings`
  - 關聯目標的 vault 在讀取範圍內但節點不存在 → `DanglingLinkTarget`;目標 vault 不在讀取範圍內
    → `LinkTargetOutOfScope`,且訊息含「加進 `refs`」或「用 `--vault` 展開」的下一步 — 觀察點:
    契約 F 的兩個建構子與 `renderServiceError`
  - 任一驗證失敗時**檔案與索引都未被修改**(先驗證後落地) — 觀察點:契約 E 的寫入組
- **明確不做**:不碰 asset 專屬欄位與命名(#5);不碰 Level / Node(#6);不自己實作位元組保留的
  寫回與樂觀鎖比對(那是 graph-core,本層只傳 `Revision` 並翻譯失敗)

### asset-naming

- **階段**:階段二
- **負責模組**:Write、Validate
- **實作的 Level 2 介面**:契約 E 的 `setAssetName` / `updateAssetMeta` / `upsertLicense`;
  契約 F 的 `LogicalNameTaken`;使用 #1 的 `withRead` 取「全部已註冊」範圍(無新增)
- **資料流管線段落**:寫入管線的驗證段多一條分支(`setAssetName` 另取全部已註冊範圍查
  `lookupByName`),之後併回同一條落地路徑
- **驗收標準**:
  - 在 vault A 已有邏輯名稱 `N` 的情況下,於 vault B 用 `--vault B` 收窄執行 `setAssetName ... N`
    **仍然**回 `LogicalNameTaken`,且錯誤帶 A 那筆的 `<vault>:<id>` — 觀察點:契約 E 的
    `setAssetName`、契約 F 的 `LogicalNameTaken`
  - 上述檢查涵蓋**全部已註冊 vault**,與本次 `--vault` / `refs` 的範圍無關:把 B 的 `refs` 清空後
    重跑,結果不變 — 觀察點:契約 E 的 `setAssetName`
  - 名稱不合命名文法(第一段不在該型別的 `name_kinds`、或分段規則不符)時回 `ValidationFailed`,
    訊息來自 graph-core 的 `NameError` 而非本層自寫 — 觀察點:契約 F 的 `ValidationFailed` 與
    `renderServiceError`
  - `updateAssetMeta` 改寫 asset 專屬欄位後,同一節的**其他型別專屬條目與正文位元組不變**
    (graph-core 的 `MetaExtras` 機制沒有被繞過) — 觀察點:契約 E 的 `updateAssetMeta`、
    契約 B 的 `nvDetail`
  - `upsertLicense` 對已存在的 `lic-` 節點是更新而非新增:節點數不變、`revision` +1 — 觀察點:
    契約 E 的 `upsertLicense`、契約 C 的 `vaultInfo`
  - 唯一性檢查失敗時檔案未動 — 觀察點:契約 E 的 `setAssetName`
- **明確不做**:不推論名稱(叢集規則屬 `asset-ingest`);不判斷授權(閘門屬 `project`);
  不定義命名文法本身(graph-core)

### level-and-node

- **階段**:階段二
- **負責模組**:Write、Read
- **實作的 Level 2 介面**:契約 E 的 `createLevel` / `deleteLevel` / `addNode` / `removeNode` 與
  `NewLevelReq` / `NewNodeReq`;契約 B 的 `NodeTreeView` / `DLevel` / `DNode`;契約 F 的
  `LevelTreeInvalid`;使用 #4 的驗證(無新增)
- **資料流管線段落**:寫入管線,節點種類為 Level / Node 的那一支(多一次 `buildTree` 前置驗證)
- **驗收標準**:
  - 讓樹不合法的編輯(父節點不存在、跨 Level 的父子、成環)一律回 `LevelTreeInvalid` 並帶
    graph-core 的 `TreeError` 清單,且**檔案未動** — 觀察點:契約 F 的 `LevelTreeInvalid`、
    契約 E 的 `addNode` / `removeNode`
  - `addNode` 插入後,重讀該 Level 的 `dvTree` 中新節點恰好是指定父節點的**最後一個子節點** —
    觀察點:契約 B 的 `NodeTreeView`、契約 D 的 `getNode`
  - `removeNode` 的 `drRemoved` 含被級聯刪掉的整棵子樹的 `Ref`,數量等於刪除前該子樹的節點數 —
    觀察點:契約 E 的 `DeleteReport`
  - `deleteLevel` 後該 Level 的全部 `nod-` 節點都不再出現在 `listNodes` — 觀察點:契約 E 的
    `deleteLevel`、契約 D 的 `listNodes`
  - Level 與 Node 的寫入同樣受樂觀鎖約束:`revision` 不符回 `RevisionConflict` — 觀察點:
    契約 F 的 `RevisionConflict`
- **明確不做**:不決定 Level 檔在磁碟上的分節形狀(graph-core);不做場景的業務語意(那是作者的事)

### search-facade

- **階段**:階段三
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 D 的 `search` / `SearchView` / `SearchHitView`;使用 #3 的
  `NodeView` 投影與 #1 的 `withRead`(無新增)
- **資料流管線段落**:讀取管線的 `searchAcross` 那一支,到 `SearchView` 為止
- **驗收標準**:
  - 一次查詢的命中集合**同時可能含 asset 與 entity**:在同時有兩者命中的 fixture 上,
    `svHits` 的 `nvDetail` 出現至少兩種建構子 — 觀察點:契約 D 的 `SearchView`、契約 B 的 `NodeDetail`
  - 每一筆命中都帶 `nvVault`,且跨 vault 查詢時同一個查詢字串的結果是各 vault 結果的聯集 —
    觀察點:契約 B 的 `nvVault`、契約 D 的 `search`
  - `shvScore` 恒有值(不是 `Maybe`),且結果依它由大到小排序 — 觀察點:契約 D 的 `SearchHitView`
  - 中文二字詞(如「藥水」)查得到:在含該詞的 fixture 上 `svTotal > 0` — 觀察點:契約 D 的 `search`
  - `sqFacets` 為 `False` 時 `svFacets == Nothing`,為 `True` 時各 facet 的計數總和不小於
    `svHits` 的長度 — 觀察點:契約 D 的 `SearchView`
  - `svTotal` 是符合條件的總數,不隨分頁參數改變 — 觀察點:契約 D 的 `SearchView`
- **明確不做**:不實作切詞與 bm25 合併(graph-core F007 / F009 已擁有);不做自然語句查詢規劃
  (那是 `ai`)

### index-ops

- **階段**:階段三
- **負責模組**:Machine、Scope
- **實作的 Level 2 介面**:契約 E 的 `reindex` / `refreshIndex` / `IndexReport`;模組間公開介面的
  `withPipeline`;使用 #1 的 `Env`(無新增)
- **資料流管線段落**:管線範圍那一支(`resolvePipeline` → 對每個 vault 各跑一次 → 各自的
  `IndexReport`)
- **驗收標準**:
  - `reindex` 對範圍內**每個** vault 各回一筆 `IndexReport`,`irVault` 兩兩相異 — 觀察點:
    契約 E 的 `IndexReport`
  - 刪掉某個 vault 的 `index.db` 後 `reindex`,該 vault 的 `listNodes` 結果與刪除前逐欄相等
    (ADR-013:索引可丟) — 觀察點:契約 E 的 `reindex`、契約 D 的 `listNodes`
  - 單一 vault 的解析失敗只讓該檔進 `irIssues`,**不中止整批**:其餘檔案仍被索引 — 觀察點:
    契約 E 的 `IndexReport`
  - 某個 vault 不可達時,它不出現在 `IndexReport` 清單裡,而其餘 vault 照跑 — 觀察點:契約 E 的
    `reindex`、契約 C 的 `vaultCheck`
  - `refreshIndex` 對沒有變動的 vault 回 `irFiles == 0` — 觀察點:契約 E 的 `IndexReport`
- **明確不做**:不實作索引 schema 與重建邏輯(graph-core);不掃壓縮檔(`asset-ingest`);
  管線範圍不接受「沒有寫入目標」以外的降級——`resolvePipeline` 回什麼就跑什麼

## 暫不定案的下游出口

以下內嵌出口在 legacy 存在或可預見會需要,但**本次刻意不定簽名**:它們的消費者
(`conflict` / `ai` / `project`)還沒有 `design.md`,現在定就是在消費者不在場的情況下凍結一個
不可逆決定——那正是契約就緒度 B 段要擋的事。

| 預期出口 | 消費者 | 什麼時候定案 |
|---|---|---|
| 整張關聯圖(legacy `linkGraph`) | `conflict` 第 1 層 | `/subsys-design conflict` 的 B 段對帳 |
| 片段 id → title / aliases 反向索引(legacy `aliasIndex`) | `conflict` 第 2 層 | 同上 |
| 中樞 `[llm]` 段的取得 | `ai` | `/subsys-design ai` 的 B 段對帳 |
| Level → Entity → Asset 的連動查詢 | `project`(system.md 資料流 B 把遍歷放在本層) | `/subsys-design project` 的 B 段對帳 |

~~縮圖快取路徑的取得~~ 已於 2026-08-29 由 `/subsys-design shell` 的 B 段對帳定案為契約 C 的
`thumbPath`——消費者(`shell`)當時在場,不再是單方視角。

## 不可逆決定

| 決定 | 被否決的替代方案與理由 |
|---|---|
| `Env` 持 handle 快取,操作各自宣告範圍 | **`openEnv` 收 Intent、一次指令一個固定 `Env`**:無可變狀態、最好推理。否決理由是伺服器一個 `AppState` 同時服務讀與寫,`Env` 只能開成兩者的聯集(等於每次全開),而且「這道指令是讀還是寫」得從 `shell` 一路傳進來——那是業務知識,`shell` 不該持有。**每個操作開完就關**:狀態最少,但伺服器每個請求重跑 schema 檢查與全 vault 過時偵測,legacy 已明確否決(`server/State.hs` 取捨紀錄第 1 項),合併後成本再乘以 vault 數 |
| 全域一把鎖,不是每 vault 一把 | **每 vault 一把鎖**:可並行寫不同 vault,而 system.md 也說寫鎖預算逐索引適用。否決理由是跨 vault 讀要一次拿多把鎖,就得再定一套取得順序防死結;單人工作室的吞吐量不是瓶頸,而「先寫檔再更新索引在請求之間也原子」這條保證更值得守 |
| 鎖與快取住 `Env`(service),不住 `AppState`(shell) | **維持 legacy,鎖留在 `aapms-server`**:改動最小。否決理由是 `Env` 現在自帶可變狀態,把保護它的責任留在殼裡,等於每個殼(CLI / server / MCP)都要記得包一層,而漏包不會有編譯錯誤 |
| View 統一成 `NodeView` + `NodeDetail` sum | **每種節點各一個 View 型別**(legacy 的 `EntityView` / `LevelView` / …):欄位最貼身。否決理由是統一 `Meta` 的價值就在「抽象成本只付一次」;六種 View 會讓 `shell` 的路由、`ToSchema`、CLI 渲染器與 AI Agent 的 parse 各長六份,而它們的差異只在 `nvDetail` 那一格 |
| 命名唯一性在寫入時對**全部已註冊 vault** 檢查 | **降級為「單一 vault 內唯一」,撞名推遲到專案產出**:最便宜、寫入路徑不變。否決理由是撞名會在建專案時才爆,而那時要改的是已經寫進 `pack.md` 的人給名稱。**名稱加 vault 前綴**:從根本不撞,但 `Assets.hs` 的識別子會帶 vault 名,素材搬庫就改到遊戲程式碼——與「路徑不是身分」同一類錯誤。代價已知:命名寫入不再是只碰單一 vault 的操作,vault 數超過 ATTACH 上限時這條路會先撞到 `TooManyVaults` |
| 動這台機器的操作不上 REST | **全部操作都上 REST**,契約最整齊。否決理由是 `vault init` / `workspace purge` 管的是**執行伺服器的那台機器**,遠端呼叫它語意上就是錯的;legacy 已對 `doctor` 用過同一條判準 |
| 下游出口留白到消費者建檔 | **現在就把 legacy 的四個內嵌出口原樣搬過來**:P5 / P6 不用回頭改。否決理由是 legacy 那四個出口本來就是「`/subsys-build` 批次澄清時才加進來」的,形狀由當時的消費者決定;統一圖譜後消費者要的東西已經變了(例如 `vaultConfig` 的 `[llm]` 現在住中樞),原樣搬只是把一個過期的形狀變成新的不可逆決定 |
