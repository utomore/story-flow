# 12 份 `status: planned` feature 文檔盤點

盤點日期:2026-09-06。來源:`.design/subsystems/service/features/`、`.design/subsystems/shell/features/`、
`.design/subsystems/service/design.md`、`.design/subsystems/shell/design.md`、`service/src/**`。

---

# 目錄

- 第 0 節:已建置 `service` 套件的現況(模組、匯出清單、`ServiceM` / `Env` / `ServiceError` 定義)
- 第 1 節:service 的 6 份 planned 文檔(F003–F008)
- 第 2 節:shell 的 6 份 planned 文檔(F001–F006)
- 第 3 節:依賴圖與程式碼存在性總表

---

# 0. 已建置 `aapms-service` 套件的現況

## 0.1 `cabal.project` 的 packages

`core/`、`types/`、`md/`、`store/`、`workspace/`、`contract/`、`service/`。
`conflict/`、`llm/`、`workshop/`、`cli/`、`api/`、`server/`、`mcp/` **全部被註解掉**(P1 凍結下游,
ADR-018),所以 `cli/` `api/` `server/` `mcp/` 裡的是舊 story-flow 凍結程式碼,不參與建置。

## 0.2 `service/src/**/*.hs` 的完整清單

只有四個模組:

| 檔案 | 模組 | 對應 feature |
|---|---|---|
| `service/src/Aapms/Service/Types.hs` | `Aapms.Service.Types` | F001 建骨架、F002 加 `UnknownType` |
| `service/src/Aapms/Service/Monad.hs` | `Aapms.Service.Monad` | F001 |
| `service/src/Aapms/Service/Scope.hs` | `Aapms.Service.Scope` | F001 |
| `service/src/Aapms/Service/Machine.hs` | `Aapms.Service.Machine` | F002 |

`service/aapms-service.cabal` 的 `exposed-modules` 逐字:

```
    exposed-modules:
        Aapms.Service.Types
        Aapms.Service.Monad
        Aapms.Service.Scope
        Aapms.Service.Machine
```

`build-depends`(library)逐字:

```
        , base          >=4.14 && <5
        , containers
        , directory
        , mtl
        , text
        , aapms-core
        , aapms-store
        , aapms-types
        , aapms-workspace
```

design.md 的七個模組裡,**Validate / Read / Write 三個檔案完全不存在** —— 那正是 F003–F008 要建的。

## 0.3 匯出清單(逐字)

### `Aapms.Service.Types`

```haskell
module Aapms.Service.Types
  ( -- * 契約 C:本機 View 型別
    SetupView (..)
  , PurgeView (..)
  , VaultView (..)
  , VaultInfoView (..)
  , DoctorView (..)
  , ProjectView (..)

    -- * 契約 F:錯誤
  , ServiceError (..)
  , errorCode
  , renderServiceError
  ) where
```

### `Aapms.Service.Monad`

```haskell
module Aapms.Service.Monad
  ( -- * 契約 A:執行環境
    Env
  , ServiceM
  , openEnv
  , runService
  , closeEnv
  , withEnv

    -- * 'Env' 內容的存取(模組間公開介面:Scope \/ Machine \/ Read \/ Write → Monad)
  , askHubLocation
  , askHub
  , reloadHub
  , askRegistry
  , askNaming
  , askRegistrySource
  , askSelector
  , askCwd

    -- * handle 快取(模組間公開介面:Scope → Monad)
  , handleFor
  , indexIssuesFor

    -- * 錯誤(模組間公開介面:全部模組 → Monad)
  , throwService
  , liftStore
  , liftWorkspace

    -- * 收尾(模組間公開介面:Scope 與 F002 起的全部模組 → Monad)
  , finallyService
  ) where
```

### `Aapms.Service.Scope`

```haskell
module Aapms.Service.Scope
  ( -- * 模組間公開介面:Read \/ Write \/ Machine → Scope
    withRead
  , withWrite
  , withPipeline
  ) where
```

### `Aapms.Service.Machine`

```haskell
module Aapms.Service.Machine
  ( -- * 契約 C:本機 View 型別(宣告在 "Aapms.Service.Types",此處 re-export)
    SetupView (..)
  , PurgeView (..)
  , VaultView (..)
  , VaultInfoView (..)
  , DoctorView (..)
  , ProjectView (..)

    -- * 契約 C:工作區
  , workspaceSetup
  , workspaceDoctor
  , workspaceTools
  , workspacePurge

    -- * 契約 C:vault 生命週期
  , vaultInit
  , vaultAdd
  , vaultList
  , vaultInfo
  , vaultForget
  , vaultCheck

    -- * 契約 C:專案登錄
  , projectRegister
  , projectList
  , projectForget

    -- * 契約 C:型別註冊表
  , listTypes
  , showType

    -- * 契約 C:縮圖快取
  , thumbPath

    -- * re-export(契約 C:一律 re-export 不重新定義)
  , VaultKind (..)
  , InitMode (..)
  , DeleteIndex (..)
  , PurgeScope (..)
  , ScopeIssue (..)
  , ToolStatus (..)
  , ToolOrigin (..)
  , HubSource (..)
  , IndexIssue (..)
  , AdoptNotice (..)
  ) where
```

## 0.4 `ServiceM` / `Env` / `ServiceError` 定義(逐字)

**沒有 `ServiceEnv` 這個名字**;design.md 契約 A 與程式碼都叫 `Env`,住在
`service/src/Aapms/Service/Monad.hs`。`ServiceError` 住在 `service/src/Aapms/Service/Types.hs`。

`Env`(`Monad.hs`,建構子與欄位**不匯出**):

```haskell
data Env = Env
  { envHubLocation :: HubLocation
  , envHubRef :: IORef Hub
  , envRegistry :: TypeRegistry
  , envNaming :: NamingVocab
  , envRegistrySource :: RegistrySource
  , envSelector :: Maybe Text
  , envCwd :: FilePath
  , envHandles :: IORef (Map VaultId VaultHandle)
  , envIndexIssues :: IORef (Map VaultId [IndexIssue])
  , envLock :: MVar ()
  }
```

`ServiceM`(`Monad.hs`,建構子不匯出;**實例只有這四個,不得再加**,由 F001 的 LAW-25 以原始碼
文字靜態守住):

```haskell
newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)
  deriving newtype (Functor, Applicative, Monad, MonadIO)
```

生命週期四函式(`Monad.hs`)逐字簽名:

```haskell
openEnv    :: Maybe Text -> FilePath -> IO (Either ServiceError Env)
runService :: Env -> ServiceM a -> IO (Either ServiceError a)
closeEnv   :: Env -> IO ()
withEnv    :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
```

`Env` 存取器與 helper(`Monad.hs`)逐字簽名:

```haskell
askHubLocation    :: ServiceM HubLocation
askHub            :: ServiceM Hub
reloadHub         :: ServiceM Hub
askRegistry       :: ServiceM TypeRegistry
askNaming         :: ServiceM NamingVocab
askRegistrySource :: ServiceM RegistrySource
askSelector       :: ServiceM (Maybe Text)
askCwd            :: ServiceM FilePath
handleFor         :: VaultRef -> ServiceM VaultHandle
indexIssuesFor    :: VaultId -> ServiceM [IndexIssue]
throwService      :: ServiceError -> ServiceM a
liftStore         :: IO (Either StoreError a) -> ServiceM a
liftWorkspace     :: IO (Either WorkspaceError a) -> ServiceM a
finallyService    :: ServiceM a -> ServiceM b -> ServiceM a
```

三個範圍口(`Scope.hs`)逐字簽名:

```haskell
withRead     :: (VaultSet -> [VaultRef] -> ServiceM a) -> ServiceM a
withWrite    :: (VaultHandle -> VaultSet -> ServiceM a) -> ServiceM a
withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a
```

`ServiceError`(`Types.hs`)**目前只有五個建構子**;design.md 契約 F 列了 14 個,其餘九個由
F003–F006 分波加入:

```haskell
data ServiceError
  = -- | graph-core 的落地失敗,原件。訊息委派
    -- 'Aapms.Store.Error.renderStoreError'
    StoreFailed StoreError
  | -- | @aapms-workspace@ 的工作區設定失敗,原件。訊息委派
    -- 'Aapms.Workspace.Types.renderWorkspaceError'
    WorkspaceFailed WorkspaceError
  | -- | 型別註冊表__定位不到__(三層都沒找到,或環境變數指向不存在的目錄):
    -- 'Aapms.Types.Loader.locateRegistry' 回的原件。與 'RegistryLoadFailed' 分成
    -- 兩個建構子是因為 @code@ 要分得出「去裝\/去設環境變數」與「型別宣告寫錯了」
    RegistryUnavailable RegistryError
  | -- | 型別註冊表__載入失敗__(目錄找到了但內容不合規):
    -- 'Aapms.Types.Loader.loadRegistry' 回的原件
    RegistryLoadFailed RegistryError
  | -- | 註冊表裡沒有這個型別鍵(F002 的 @showType@;F004 起的寫入路徑同用)。
    -- 酬載是__那個鍵的字串本身__,不是別的訊息
    UnknownType Text
  deriving stock (Show, Eq)

errorCode :: ServiceError -> Text
errorCode = \case
  StoreFailed _ -> "store_failed"
  WorkspaceFailed _ -> "workspace_failed"
  RegistryUnavailable _ -> "registry_unavailable"
  RegistryLoadFailed _ -> "registry_load_failed"
  UnknownType _ -> "unknown_type"

renderServiceError :: ServiceError -> Text
renderServiceError = \case
  StoreFailed e -> renderStoreError e
  WorkspaceFailed e -> renderWorkspaceError e
  RegistryUnavailable e -> renderRegistryError e
  RegistryLoadFailed e -> renderRegistryError e
  UnknownType k ->
    "型別註冊表裡沒有「"
      <> k
      <> "」這個型別鍵。用 type list 看目前有哪些型別,或到型別註冊表目錄"
      <> "(types/registry/)補一份宣告後重試。"
```

`Machine.hs` 的 16 個操作(F002 已交付)逐字簽名:

```haskell
workspaceSetup  :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)
workspaceDoctor :: ServiceM DoctorView
workspaceTools  :: ServiceM [ToolStatus]
workspacePurge  :: PurgeScope -> ServiceM PurgeView
vaultInit       :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)
vaultAdd        :: FilePath -> ServiceM VaultView
vaultList       :: ServiceM [VaultView]
vaultInfo       :: Text -> ServiceM VaultInfoView
vaultForget     :: Text -> DeleteIndex -> ServiceM VaultView
vaultCheck      :: ServiceM [ScopeIssue]
projectRegister :: FilePath -> Text -> ServiceM ProjectView
projectList     :: ServiceM [ProjectView]
projectForget   :: Text -> ServiceM ProjectView
listTypes       :: ServiceM [TypeDecl]
showType        :: TypeKey -> ServiceM TypeDecl
thumbPath       :: Sha256 -> ServiceM (Maybe FilePath)
```

## 0.5 build-log 的排程狀態

`.design/subsystems/service/build-log.md`:

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 | WAVE-1 | service-env-and-scope | **done**(`aapms-service-test` 62/0) |
| 階段一 | WAVE-2 | workspace-facade | **done**(`aapms-service-test` 120/0) |
| 階段二 | WAVE-3–WAVE-6 | node-read / node-write / asset-naming / level-and-node | 本次不跑 |
| 階段三 | WAVE-7 | search-facade ∥ index-ops | 本次不跑 |

`shell` **沒有 build-log**(`.design/subsystems/shell/` 只有 `design.md` + `features/` +
空的 `bugfixes/` `enhancements/`),也沒有任何一個 shell 套件在 `cabal.project` 裡。

---

# 1. service 子系統的 6 份 planned 文檔

全部屬 **`aapms-service`** 這一個套件(design.md「涵蓋一個套件」)。全部 `stage: S3`、`rev: 0`、
`code-paths: []`、`related-adr: []`、`related-feature: []`。

---

## 1.1 service/F003 — node-read

**檔案**:`.design/subsystems/service/features/F003-node-read.md`

**title**:`node-read`
**description(frontmatter 原文)**:`` `getNode` / `listNodes` / `childrenOf` / `linksOf`;`AnyNode → NodeView` 投影、每筆帶 vault ``
**一句話意圖**:把 graph-core 讀回來的 `AnyNode` 投影成統一的 `NodeView`(每筆帶 `nvVault`),並提供
四個讀取操作。

**計畫的模組**:`Read`(`modules: [Read]`)→ 尚不存在的 `service/src/Aapms/Service/Read.hs`。
**套件**:`aapms-service`。

**depends-on**:`[service/F001]`。**被誰依賴**:service/F004(node-write)、service/F007
(search-facade)、service/F008(index-ops)—— 三份的 `depends-on` 都是 `[service/F003]`。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… node …… 的全部操作(本份是節點讀取那一組)」(system.md「子系統劃分」§service 職責)
- **階段**:階段二
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 B 全部(`NodeView` / `NodeDetail` / `NodeTreeView`);契約 D 的
  `getNode` / `listNodes` / `childrenOf` / `linksOf` / `Page` / `LinkReport`;契約 F 的
  `NodeNotFound` / `AmbiguousRef`;使用 service/F001-service-env-and-scope 的 `withRead`(無新增)
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
- **明確不做**:不做任何寫入;不擋懸空關聯(那是寫入路徑的事);不做全文檢索(service/F007-search-facade)
```

### 它承諾的簽名(來自 design.md 契約 B / D,文檔以引用方式承諾)

```haskell
getNode     :: Ref -> Bool -> ServiceM NodeView            -- 第二參數:Level 要不要帶樹
listNodes   :: NodeFilter -> ServiceM (Page NodeView)
childrenOf  :: Ref -> ServiceM [NodeView]
linksOf     :: Ref -> ServiceM LinkReport

data Page a      = Page { pgItems :: [a], pgTotal :: Int, pgOffset :: Int, pgLimit :: Int }
data LinkReport  = LinkReport { lrOut :: [(Link, Maybe NodeView)], lrIn :: [(NodeView, Link)] }

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

契約 F 要加的兩個建構子:`AmbiguousRef Id [VaultId]`、`NodeNotFound Ref`。

### 程式碼存在性

**零**。`service/src`、`workspace/src`、`store/src` 全樹:

- `getNode` / `linksOf` / `NodeView` / `NodeDetail` / `NodeTreeView` / `LinkReport` /
  `AmbiguousRef` — **一個都沒有**(`NodeView` 在 `service/src/Aapms/Service/Monad.hs:16` 只出現在
  Haddock 註解裡,不是定義)。
- `listNodes` / `childrenOf` / `NodeNotFound` **只有 graph-core 的下層原件**,不是本層的:
  - `store/src/Aapms/Store/Query.hs:240` `listNodes :: VaultHandle -> NodeFilter -> IO [Meta]`
  - `store/src/Aapms/Store/Query.hs:249` `childrenOf :: VaultHandle -> Id -> IO [Meta]`
  - `store/src/Aapms/Store/Error.hs` 的 `NodeNotFound`(`StoreError` 的建構子)
  - `service/src/Aapms/Service/Machine.hs:113,290` import 並呼叫 `Aapms.Store.Query.listNodes`
    (`vaultInfo` 的 `viCounts`),那是 F002 的用法,不是 F003 承諾的 `listNodes`。
- 舊凍結程式碼:`api/src/Aapms/Api.hs`、`cli/src/Aapms/Cli/Backend.hs`、`server/src/Aapms/Server.hs`
  裡有 `linksOf`(只在 frozen old code)。`getNode` / `NodeView` / `NodeDetail` 在舊碼裡也沒有
  (舊碼用的是分裂的 `EntityView` 等)。

---

## 1.2 service/F004 — node-write

**檔案**:`.design/subsystems/service/features/F004-node-write.md`

**title**:`node-write`
**description**:`建立 / 片段 / 改寫 / 刪除、樂觀鎖、五條業務驗證`
**一句話意圖**:所有節點寫入操作的落點——樂觀鎖比對的翻譯處與五條業務驗證的執行點。

**計畫的模組**:`Write`、`Validate`(`modules: [Write, Validate]`)→ 兩個尚不存在的檔案
`service/src/Aapms/Service/Write.hs`、`service/src/Aapms/Service/Validate.hs`。
**套件**:`aapms-service`。

**depends-on**:`[service/F003]`。**被誰依賴**:service/F005(asset-naming)、service/F006
(level-and-node),兩份的 `depends-on` 都是 `[service/F004]`。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… node …… 的全部操作;並且是「樂觀鎖的執行點」的唯一落點」(system.md「子系統劃分」§service 職責)
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
- **明確不做**:不碰 asset 專屬欄位與命名(service/F005-asset-naming);不碰 Level / Node(service/F006-level-and-node);不自己實作位元組保留的
  寫回與樂觀鎖比對(那是 graph-core,本層只傳 `Revision` 並翻譯失敗)
```

### 它承諾的簽名(design.md 契約 E)

```haskell
createEntity :: NewEntityReq -> ServiceM NodeView
addFragment  :: Ref -> NewFragmentReq -> ServiceM NodeView
updateMeta   :: Ref -> Revision -> MetaPatch -> ServiceM NodeView
setBody      :: Ref -> Revision -> Text -> ServiceM NodeView
deleteNode   :: Ref -> Revision -> DeleteMode -> ServiceM DeleteReport
addLink      :: Ref -> Revision -> Link -> ServiceM NodeView
removeLink   :: Ref -> Revision -> Link -> ServiceM NodeView

data DeleteReport = DeleteReport { drRemoved :: [Ref], drVault :: VaultId }

data NewEntityReq   = NewEntityReq   { neType :: TypeKey, neTitle :: Text, neSummary :: Text
                                     , neTags :: [Text], neStatus :: Maybe Status
                                     , neTimeline :: Maybe Timeline, neAliases :: [Text]
                                     , neLinks :: [Link], neSource :: Source, neBody :: Text }
data NewFragmentReq = NewFragmentReq { nfType :: Maybe TypeKey, nfTitle :: Text, nfSummary :: Text
                                     , nfTags :: [Text], nfAliases :: [Text], nfLinks :: [Link]
                                     , nfSource :: Source, nfBody :: Text }
data MetaPatch      = MetaPatch      { mpTitle, mpSummary :: Maybe Text, mpTags, mpAliases :: Maybe [Text]
                                     , mpStatus :: Maybe Status, mpTimeline :: Maybe (Maybe Timeline) }
```

模組間公開介面(design.md「模組間公開介面」表的 `Write → Validate` 那一列):

```haskell
validateForWrite :: TypeRegistry -> VaultSet -> AnyNode -> ServiceM ()
```

契約 F 要加的建構子:`ValidationFailed (Maybe Id) [MetaWarning]`、`DanglingLinkTarget Ref`、
`LinkTargetOutOfScope Ref`、`LevelTreeInvalid Id [TreeError]`、`RevisionConflict Ref Revision Revision`
(`UnknownType Text` 已由 F002 交付)。

### 程式碼存在性

**零**(除了 `UnknownType`)。

- `createEntity` / `addFragment` / `updateMeta` / `setBody` / `setAssetName` / `validateForWrite` /
  `DeleteReport` / `NewEntityReq` / `NewFragmentReq` / `MetaPatch` / `DanglingLinkTarget` /
  `LinkTargetOutOfScope` / `LevelTreeInvalid` / `RevisionConflict` — 在 `service/src`、
  `workspace/src`、`store/src` **零命中**。
- `ValidationFailed` 在 `service/src/Aapms/Service/Types.hs:22` 只出現在註解裡(「`ValidationFailed`
  起的其餘建構子屬 F003–F006 的範圍」),**不是定義**。
- graph-core 有同名的下層原件(不是本層要的):
  - `store/src/Aapms/Store/Write.hs:244` `addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)`
  - `store/src/Aapms/Store/Write.hs:260` `removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)`
  - `deleteNode` 在 `store/src/Aapms/Store/{Create,Node,Write}.hs`(graph-core 的落地函式)
- 舊凍結程式碼:`createEntity` / `addFragment` 在 `cli/src/Aapms/Cli/Backend.hs`、
  `server/src/Aapms/Server.hs`(`addFragment` 另在 `api/src/Aapms/Api.hs`);
  `DeleteReport` / `NewEntityReq` 在 `api/src/Aapms/Api.hs`、`api/src/Aapms/Api/Instances.hs`、
  `cli/src/Aapms/Cli/Backend.hs`、`cli/src/Aapms/Cli/Render.hs`、`cli/src/Aapms/Cli/Options.hs`
  —— **只在 frozen old code**。`updateMeta` / `setBody` / `MetaPatch` 舊碼裡也沒有。

---

## 1.3 service/F005 — asset-naming

**檔案**:`.design/subsystems/service/features/F005-asset-naming.md`

**title**:`asset-naming`
**description**:`` `setAssetName` 的全域唯一、`updateAssetMeta`、`upsertLicense` ``
**一句話意圖**:素材邏輯名稱的**跨全部已註冊 vault** 唯一性檢查,加上 asset 專屬欄位與授權節點的
寫入。

**計畫的模組**:`Write`、`Validate`(`modules: [Write, Validate]`)。**套件**:`aapms-service`。
(build-log:與 F006 同樣動 `Write`,骨架會重疊,所以拆成 WAVE-5 / WAVE-6 兩波。)

**depends-on**:`[service/F004]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… asset …… 的全部操作(本份是素材命名與授權那一組)」(system.md「子系統劃分」§service 職責)
- **階段**:階段二
- **負責模組**:Write、Validate
- **實作的 Level 2 介面**:契約 E 的 `setAssetName` / `updateAssetMeta` / `upsertLicense`;
  契約 F 的 `LogicalNameTaken`;使用 service/F001-service-env-and-scope 的 `withRead` 取「全部已註冊」範圍(無新增)
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
```

### 它承諾的簽名(design.md 契約 E)

```haskell
setAssetName    :: Ref -> Revision -> LogicalName -> ServiceM NodeView
updateAssetMeta :: Ref -> Revision -> AssetPatch -> ServiceM NodeView
upsertLicense   :: NewLicenseReq -> ServiceM NodeView

data NewLicenseReq  = NewLicenseReq  { nlcKey :: Text, nlcTitle :: Text, nlcCommercial :: Bool
                                     , nlcAttributionRequired :: Bool, nlcCreditText :: Maybe Text
                                     , nlcModificationAllowed, nlcRedistributionAllowed
                                     , nlcResaleAllowed, nlcNftAllowed :: Maybe Bool
                                     , nlcSourceUrl, nlcFullText :: Maybe Text }
-- AssetPatch 沿用 graph-core 契約 E 的型別,本層不重新定義
```

契約 F 要加的建構子:`LogicalNameTaken LogicalName Ref`。

### 程式碼存在性

**零**。`setAssetName` / `updateAssetMeta` / `NewLicenseReq` / `LogicalNameTaken` 在 `service/src`、
`workspace/src`、`store/src` 與 frozen old code **都零命中**。

graph-core 的下層原件(F005 要委派的,不是它承諾的):

- `store/src/Aapms/Store/Write.hs:314` `upsertLicense :: VaultHandle -> License -> IO (Either StoreError WriteResult)`
- `store/src/Aapms/Store/Query.hs:479` `lookupByName :: VaultHandle -> LogicalName -> IO (Maybe Asset)`
- `store/src/Aapms/Store/Error.hs` 另有一處提到 `upsertLicense`(錯誤訊息)

---

## 1.4 service/F006 — level-and-node

**檔案**:`.design/subsystems/service/features/F006-level-and-node.md`

**title**:`level-and-node`
**description**:`Level 與 Node 的建立 / 刪除、樹視圖`
**一句話意圖**:場景樹那一組寫入操作,外加一次 `buildTree` 前置驗證與 `NodeTreeView` 的樹視圖。

**計畫的模組**:`Write`、`Read`(`modules: [Write, Read]`)。**套件**:`aapms-service`。

**depends-on**:`[service/F004]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… level / node …… 的全部操作(本份是場景樹那一組)」(system.md「子系統劃分」§service 職責)
- **階段**:階段二
- **負責模組**:Write、Read
- **實作的 Level 2 介面**:契約 E 的 `createLevel` / `deleteLevel` / `addNode` / `removeNode` 與
  `NewLevelReq` / `NewNodeReq`;契約 B 的 `NodeTreeView` / `DLevel` / `DNode`;契約 F 的
  `LevelTreeInvalid`;使用 service/F004-node-write 的驗證(無新增)
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
```

### 它承諾的簽名(design.md 契約 E)

```haskell
createLevel :: NewLevelReq -> ServiceM NodeView
deleteLevel :: Ref -> Revision -> ServiceM DeleteReport
addNode     :: Ref -> NewNodeReq -> ServiceM NodeView       -- 第一參數:父節點
removeNode  :: Ref -> Revision -> ServiceM DeleteReport

data NewLevelReq    = NewLevelReq    { nlTitle :: Text, nlSummary :: Text, nlRootTitle :: Text
                                     , nlSource :: Source }
data NewNodeReq     = NewNodeReq     { nnTitle :: Text, nnSummary :: Text, nnKind :: NodeKind
                                     , nnEntities :: [Ref], nnBody :: Text, nnSource :: Source }
```

### 程式碼存在性

**零**。`createLevel` / `deleteLevel` / `addNode` / `removeNode` / `NewLevelReq` / `NewNodeReq` /
`NodeTreeView` / `LevelTreeInvalid` 在 `service/src`、`workspace/src`、`store/src` 全部零命中。

舊凍結程式碼:`createLevel` / `deleteLevel` / `addNode` / `removeNode` 在
`cli/src/Aapms/Cli/Backend.hs`、`server/src/Aapms/Server.hs`(`addNode` / `removeNode` 另在
`cli/src/Aapms/Cli/Resolve.hs`)—— **只在 frozen old code**。`NewLevelReq` / `NewNodeReq` /
`NodeTreeView` 連舊碼裡也沒有。

---

## 1.5 service/F007 — search-facade

**檔案**:`.design/subsystems/service/features/F007-search-facade.md`

**title**:`search-facade`
**description**:`` `search` 一次回 asset 與 entity 兩種、facet、每筆帶 vault ``
**一句話意圖**:把 graph-core 的 `searchAcross` 包成一個跨 vault、一次同時回 asset 與 entity 的
`SearchView` 門面。

**計畫的模組**:`Read`(`modules: [Read]`)。**套件**:`aapms-service`。
**階段**:階段三(build-log WAVE-7,與 F008 平行)。

**depends-on**:`[service/F003]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… search …… 的全部操作(本份是檢索門面)」(system.md「子系統劃分」§service 職責)
- **階段**:階段三
- **負責模組**:Read
- **實作的 Level 2 介面**:契約 D 的 `search` / `SearchView` / `SearchHitView`;使用 service/F003-node-read 的
  `NodeView` 投影與 service/F001-service-env-and-scope 的 `withRead`(無新增)
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
- **明確不做**:不實作切詞與 bm25 合併(graph-core/F007-store-fts-dual-index 與 graph-core/F009-store-multi-vault-read 已擁有);不做自然語句查詢規劃
  (那是 `ai`)
```

### 它承諾的簽名(design.md 契約 D)

```haskell
search :: SearchQuery -> ServiceM SearchView

data SearchView    = SearchView { svHits :: [SearchHitView], svTotal :: Int, svFacets :: Maybe FacetCounts }
data SearchHitView = SearchHitView { shvNode :: NodeView, shvSnippet :: Text, shvScore :: Double }
```

### 程式碼存在性

**零**。`SearchView` / `SearchHitView` 在 `service/src`、`workspace/src`、`store/src` 與舊碼全部
零命中。

graph-core 的下層原件(F007 要委派的):

- `store/src/Aapms/Store/MultiVault.hs:338` `searchAcross :: VaultSet -> SearchQuery -> IO SearchResult`
- `store/src/Aapms/Store/Query.hs:591` `search :: VaultHandle -> SearchQuery -> IO SearchResult`

---

## 1.6 service/F008 — index-ops

**檔案**:`.design/subsystems/service/features/F008-index-ops.md`

**title**:`index-ops`
**description**:`` `reindex` / `refreshIndex` / `IndexReport` ``
**一句話意圖**:索引維護——對管線範圍內每個 vault 各跑一次重建 / 刷新,各回一筆 `IndexReport`。

**計畫的模組**:`Machine`、`Scope`(`modules: [Machine, Scope]`)—— **這兩個檔案已經存在**
(`Machine.hs` / `Scope.hs`),F008 是往裡面加。**套件**:`aapms-service`。
**階段**:階段三(build-log WAVE-7,與 F007 平行)。

**depends-on**:`[service/F003]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,service 就無法「以 `ServiceM` 定義 …… index …… 的全部操作(本份是索引維護)」(system.md「子系統劃分」§service 職責)
- **階段**:階段三
- **負責模組**:Machine、Scope
- **實作的 Level 2 介面**:契約 E 的 `reindex` / `refreshIndex` / `IndexReport`;模組間公開介面的
  `withPipeline`;使用 service/F001-service-env-and-scope 的 `Env`(無新增)
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
```

### 它承諾的簽名(design.md 契約 E)

```haskell
reindex      :: ServiceM [IndexReport]
refreshIndex :: ServiceM [IndexReport]
data IndexReport = IndexReport { irVault :: VaultId, irFiles :: Int, irIssues :: [IndexIssue] }
```

`withPipeline` 這一列**已經交付**(F001):
`withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a`,在
`service/src/Aapms/Service/Scope.hs`。F008 是它的**第一個呼叫端**——目前樹上沒有任何呼叫者。

### 程式碼存在性

- `withPipeline`:**已存在**於 `service/src/Aapms/Service/Scope.hs`(已匯出,尚無呼叫端)。
- `reindex` / `refreshIndex` / `IndexReport`:在 `service/src`、`workspace/src`、`store/src`
  **零命中**。
- graph-core 的下層原件:`store/src/Aapms/Store/Index.hs:99`
  `indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])`、
  `store/src/Aapms/Store/Index.hs:361` `rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])`。
- 舊凍結程式碼:`reindex` / `refreshIndex` 在 `cli/src/Aapms/Cli/Backend.hs`、
  `server/src/Aapms/Server.hs`;`IndexReport` 在 `api/src/Aapms/Api.hs`、
  `api/src/Aapms/Api/Instances.hs`、`cli/src/Aapms/Cli/Backend.hs`、`cli/src/Aapms/Cli/Render.hs`
  —— **只在 frozen old code**。

---

# 2. shell 子系統的 6 份 planned 文檔

shell 涵蓋**五個套件**(design.md):`aapms-api` / `aapms-backend` / `aapms-cli` /
`aapms-server` / `aapms-mcp`。其中 **`aapms-backend` 這個目錄在樹上根本不存在**
(`ls -d backend` 無);其餘四個目錄存在但**不在 `cabal.project`**,裡面是舊 story-flow 程式碼。

全部六份 `stage: S3`、`rev: 0`、`code-paths: []`、`related-adr: []`、`related-feature: []`。

---

## 2.1 shell/F001 — api-types-and-openapi

**檔案**:`.design/subsystems/shell/features/F001-api-types-and-openapi.md`

**title**:`api-types-and-openapi`
**description**:`` servant 路由型別、`HttpApiData`、`ToSchema`、OpenAPI 3 輸出、`ToJSON` ↔ `ToSchema` 逐欄對齊 ``
**一句話意圖**:唯一那份 servant 路由型別與它的 HTTP / schema 實例,三個消費端(server、CLI 遠端、
MCP)都由它推導。

**計畫的模組**:`Api.Routes`、`Api.Instances`、`Api.OpenApi`。**套件**:`aapms-api`。
**階段**:階段一。

**depends-on**:`[]`(空)。**被誰依賴**:shell/F002(backend-dispatch)、shell/F005(http-server)
—— 兩份的 `depends-on` 都是 `[shell/F001]`;shell/F006 的契約也寫「使用 shell/F001 的路由型別」
(但 frontmatter 的 `depends-on` 是 `[shell/F002]`)。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「OpenAPI」(system.md「子系統劃分」§shell 職責)
- **階段**:階段一
- **負責模組**:Api.Routes、Api.Instances、Api.OpenApi
- **實作的 Level 2 介面**:契約 C 的路由表全部條目與四個參數(`{ref}` / `{selector}` /
  `revision` / `mode` / `{sha256}`);契約 C 的錯誤 body 形狀;使用 `service` 契約 B / C / D / E 的
  View 與請求型別(無新增)
- **資料流管線段落**:HTTP 管線的「servant 依 `Api.Routes` 解碼」那一段,以及 CLI 遠端路徑與
  MCP tool 映射共用的型別來源
- **驗收標準**:
  - 路由表的**每一條**都對應到 `service` 的一個操作,且 `service` 契約 C / D / E 裡標了 REST 出口的
    操作**每一個**都有路由(雙向無遺漏) — 觀察點:契約 C 的路由表
  - 每個寫入 method 的 `revision` 是**必填** query 參數:缺它時 servant 解碼失敗而不是進 handler —
    觀察點:契約 C 的 `revision`
  - `{ref}` 的 `FromHttpApiData` 對 `<id>` 與 `<vault>:<id>` 都解得開,對其他形狀回解碼失敗;
    `ToHttpApiData` 與它互為反函數 — 觀察點:契約 C 的 `{ref}`
  - 對每個 View 型別,`ToJSON` 樣本值的鍵集合等於 `ToSchema` 的 `properties` 鍵集合 — 觀察點:
    Api.Instances
  - `--openapi` 產出的文件可被通用 OpenAPI 3 驗證器接受,且 `paths` 的數量等於路由表的條目數 —
    觀察點:Api.OpenApi
  - `aapms-api` 的 `build-depends` **不含** `servant-server` / `servant-client` / `warp` /
    `aapms-store` / `aapms-workspace`;**含** `aapms-service`(View 與請求型別住在那裡,路由型別
    必須引用它) — 觀察點:`CabalSpec`
- **明確不做**:不含任何 handler 實作、不含 client 函式、不決定狀態碼(shell/F005-http-server)
```

### 它承諾的形狀(design.md 契約 C 的路由表 + 四個參數)

| 路徑 | method | 對應的 `service` 操作 |
|---|---|---|
| `/vaults` | GET | `vaultList` |
| `/vaults/{selector}` | GET | `vaultInfo` |
| `/projects` | GET | `projectList` |
| `/types` · `/types/{key}` | GET | `listTypes` · `showType` |
| `/nodes` | GET | `listNodes`(query 參數即 `NodeFilter`) |
| `/nodes/{ref}` | GET · PATCH · DELETE | `getNode` · `updateMeta` · `deleteNode` |
| `/nodes/{ref}/body` | PUT | `setBody` |
| `/nodes/{ref}/children` | GET | `childrenOf` |
| `/nodes/{ref}/links` | GET · POST · DELETE | `linksOf` · `addLink` · `removeLink` |
| `/entities` | POST | `createEntity` |
| `/entities/{ref}/fragments` | POST | `addFragment` |
| `/assets/{ref}/name` | PUT | `setAssetName` |
| `/assets/{ref}/fields` | PATCH | `updateAssetMeta` |
| `/licenses` | PUT | `upsertLicense` |
| `/levels` | POST | `createLevel` |
| `/levels/{ref}` | DELETE | `deleteLevel` |
| `/levels/{ref}/nodes` | POST | `addNode` |
| `/levels/{lvl}/nodes/{ref}` | DELETE | `removeNode` |
| `/search` | GET | `search` |
| `/index` | POST | `reindex` / `refreshIndex`(query 參數 `full=true\|false`) |
| `/thumb/{sha256}` | GET | 讀 `service` 給的快取路徑後回檔案 |

錯誤 body 一律 `{"error":{"code":…,"message":…}}`,與 CLI 信封的 `error` 同形。

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**(而且依 ADR-006 / ADR-015 也不該有——
  `aapms-service.cabal` 的註解明寫「servant / warp / optparse-applicative / aeson 出現在這裡即為
  架構違規」)。
- **只在 frozen old code**:`FromHttpApiData` / `ToSchema` 在
  `api/src/Aapms/Api.hs`、`api/src/Aapms/Api/Instances.hs`;`toOpenApi` 在 `api/src/Aapms/Api.hs`。
  舊碼的模組名是 `Aapms.Api` / `Aapms.Api.Instances`,**不是**新設計的
  `Api.Routes` / `Api.Instances` / `Api.OpenApi` 三分。`api/aapms-api.cabal` 存在但不在
  `cabal.project`。

---

## 2.2 shell/F002 — backend-dispatch

**檔案**:`.design/subsystems/shell/features/F002-backend-dispatch.md`

**title**:`backend-dispatch`
**description**:`` `Backend` 的兩個建構子與 `runOp`、`BackendError` 三分、重管線指令的遠端拒絕 ``
**一句話意圖**:內嵌 / 遠端兩種模式的分派抽象,把兩條路徑收斂成同一批 View 與同一組錯誤,指令層
看不見建構子。

**計畫的模組**:`Backend`。**套件**:`aapms-backend`(**新增的第五個套件,目錄尚不存在**)。
**階段**:階段一。

**depends-on**:`[shell/F001]`。**被誰依賴**:shell/F003(cli-options-and-envelope)、
shell/F006(mcp-adapter)。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「`--vault` / `--remote` 解析」(system.md「子系統劃分」§shell 職責)
- **階段**:階段一
- **負責模組**:Backend
- **實作的 Level 2 介面**:契約 E 全部(`Backend` / `BackendError` / `runOp` / `Op`)
- **資料流管線段落**:CLI 與 MCP 管線的「`Backend.runOp` → 分派」那一段
- **驗收標準**:
  - 對每一個有 CLI 出口的 `service` 操作,`Embedded` 與 `Remote` 兩條路徑回傳的 View **逐欄相等**
    (以同一個 vault 起一個本機伺服器對照) — 觀察點:契約 E 的 `runOp`
  - 業務失敗時兩條路徑的 `BusinessError` 的 `code` 與 `message` **逐字相等** — 觀察點:契約 E 的
    `BusinessError`、契約 A 的 `ErrorBody`
  - `Remote` 下呼叫任一重管線指令回 `PipelineNotRemote` 並帶指令名,**不發出任何 HTTP 請求** —
    觀察點:契約 E 的 `PipelineNotRemote`
  - 連線失敗與非預期狀態碼回 `TransportError`,**不會**被誤包成 `BusinessError` — 觀察點:
    契約 E 的 `BackendError`
  - 指令層的型別看不見 `Embedded` / `Remote`:`Op` 的使用端不需要 case 兩個建構子 — 觀察點:
    契約 E 的 `Op`
  - `aapms-backend` 的 `build-depends` 不含 `optparse-applicative` / `warp` / `aapms-store` /
    `aapms-workspace` — 觀察點:`CabalSpec`
- **明確不做**:不解析參數(shell/F003-cli-options-and-envelope);不渲染(shell/F004-cli-render);不決定 exit code(shell/F003-cli-options-and-envelope)
```

### 它承諾的簽名(design.md 契約 E)

```haskell
data Backend = Embedded Env | Remote ClientEnv
data BackendError = BusinessError ErrorBody | TransportError Text | PipelineNotRemote Text

runOp :: Backend -> Op a -> IO (Either BackendError a)
```

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**。
- `runOp` / `BackendError` / `PipelineNotRemote` / `TransportError` / `BusinessError` /
  `ErrorBody`:**全樹零命中**,連 frozen old code 都沒有。
- `Backend` 這個字只在 frozen old code:`cli/src/Aapms/Cli/Backend.hs`、
  `cli/src/Aapms/Cli/Resolve.hs`、`cli/src/Aapms/Cli.hs`、`server/src/Aapms/Server.hs`、
  `mcp/src/Aapms/Mcp/Client.hs`、`mcp/src/Aapms/Mcp/Config.hs` —— 舊碼的 `Backend` 住在
  `aapms-cli` 裡(這正是新設計 2026-08-29 裁決要拆出去的東西),**不是**新的 `aapms-backend` 套件。

---

## 2.3 shell/F003 — cli-options-and-envelope

**檔案**:`.design/subsystems/shell/features/F003-cli-options-and-envelope.md`

**title**:`cli-options-and-envelope`
**description**:`optparse 指令樹與全域旗標互斥、統一信封、exit code、輸出編碼`
**一句話意圖**:argv 到 exit code 的整條 CLI 路徑(渲染那一格除外)——指令樹、四個全域旗標、
一行 JSON 信封、三分 exit code、Windows 主控台編碼。

**計畫的模組**:`Cli.Options`、`Cli.Envelope`、`Cli.Encoding`。**套件**:`aapms-cli`。
**階段**:階段二。

**depends-on**:`[shell/F002]`。**被誰依賴**:shell/F004(cli-render)。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「參數解析;統一信封、exit code、錯誤格式」(system.md「子系統劃分」§shell 職責)
- **階段**:階段二
- **負責模組**:Cli.Options、Cli.Envelope、Cli.Encoding
- **實作的 Level 2 介面**:契約 A 全部(`Envelope` / `ErrorBody` / `ExitKind` 與兩張表);
  契約 B 全部(四個全域旗標);使用 shell/F002-backend-dispatch 的 `runOp`(無新增)
- **資料流管線段落**:CLI 管線自 argv 到 exit code,渲染那一格除外
- **驗收標準**:
  - `--json` 模式的 stdout **恰好是一行合法 JSON**,且成功時有 `data` 無 `error`、失敗時有 `error`
    無 `data` — 觀察點:契約 A 的信封表
  - `--json` 模式下**沒有任何**非 JSON 的行(含作用中 vault 的提示行) — 觀察點:契約 A、契約 B 的
    `--json`
  - exit code 三分正確:成功 `0`;`ServiceError` 或 `TransportError` → `1`;參數解析失敗、
    `--vault` 與 `--remote` 同時給、`Remote` 下的重管線指令 → `2` — 觀察點:契約 A 的 exit code 表
  - `error.code` 對業務失敗逐字等於 `service` 的 `errorCode`;用法錯誤固定 `usage_error` —
    觀察點:契約 A 的信封表
  - 指令樹的葉子子指令集合等於 `service` 契約裡標了 CLI 出口的操作集合(雙向無遺漏),且這個
    數字**有測試釘住** — 觀察點:契約 B、`service` 契約 C / D / E 的出口欄
  - 含中日文的輸出在 Windows 主控台不出現替換字元:設定編碼後寫出一段中文再讀回,位元組可還原 —
    觀察點:Cli.Encoding
  - `aapms-cli` 的 `build-depends` 不含 `aapms-store` / `aapms-workspace` / `aapms-server` / `warp` —
    觀察點:`CabalSpec`
- **明確不做**:不實作人類可讀的版面(shell/F004-cli-render);不含任何業務分支——旗標互斥是語法規則,不是業務
```

### 它承諾的簽名(design.md 契約 A)

```haskell
data Envelope a = Ok a | Err ErrorBody
data ErrorBody  = ErrorBody { ebCode :: Text, ebMessage :: Text }
data ExitKind   = ExitOk | ExitFailure | ExitUsage
```

四個全域旗標(契約 B):`--vault <名稱|id>`(與 `--remote` 互斥)、`--remote <url>`、`--json`、
`--version`。exit code 表:`0` = 成功、`1` = `ServiceError` 或傳輸失敗、`2` = 用法錯誤。

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**。
- `ErrorBody` / `ExitKind`:**全樹零命中**(連舊碼都沒有)。
- `Envelope`:**只在 frozen old code** —— `cli/src/Aapms/Cli/Render.hs`、`cli/src/Aapms/Cli.hs`。
  舊碼沒有 `Cli.Envelope` / `Cli.Encoding` 這兩個模組(舊模組是
  `Aapms.Cli` / `Aapms.Cli.Options` / `Aapms.Cli.Render` / `Aapms.Cli.Backend` /
  `Aapms.Cli.Doctor` / `Aapms.Cli.Error` / `Aapms.Cli.Resolve`);`Aapms.Cli.Options` 同名檔存在
  於 `cli/src/Aapms/Cli/Options.hs`,**只在 frozen old code**。

---

## 2.4 shell/F004 — cli-render

**檔案**:`.design/subsystems/shell/features/F004-cli-render.md`

**title**:`cli-render`
**description**:`` 唯一的人類可讀渲染器:作用中 vault 的開頭行、節點 / 清單 / 樹 / 搜尋結果、警告與 `ScopeIssue` ``
**一句話意圖**:唯一那份把 View 型別印成人看的文字的渲染器,第一行永遠說出作用中的 vault。

**計畫的模組**:`Cli.Render`。**套件**:`aapms-cli`。**階段**:階段二。

**depends-on**:`[shell/F003]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「人類可讀輸出的編碼(`hSetEncoding` + Windows console code page)」(system.md「子系統劃分」§shell 職責)
- **階段**:階段二
- **負責模組**:Cli.Render
- **實作的 Level 2 介面**:契約 B 的「非 `--json` 模式第一行是作用中的 vault」;使用 `service` 的
  View 型別(無新增)
- **資料流管線段落**:CLI 管線的最後一格(View → 人類可讀文字)
- **驗收標準**:
  - 非 `--json` 模式的**第一行**指出作用中的 vault:寫入類指令印寫入目標的名稱與路徑,查詢類指令
    印涵蓋的 vault 數與名稱 — 觀察點:契約 B
  - 跨 vault 的清單與搜尋結果**每一筆**都看得出來源 vault — 觀察點:`service` 契約 B 的 `nvVault`
  - `service` 回的 `nvWarnings` 與範圍解析的 `ScopeIssue` 都被印出來,且**不影響 exit code**
    (成功仍是 `0`) — 觀察點:`service` 契約 B 的 `nvWarnings`、契約 A 的 exit code 表
  - Level 的樹以縮排呈現,層級與 `NodeTreeView` 的結構一致 — 觀察點:`service` 契約 B 的
    `NodeTreeView`
  - 渲染器是**唯一的一份**:內嵌與遠端兩條路徑的非 JSON 輸出逐字相等 — 觀察點:契約 E 的 `runOp`
  - 渲染器不呼叫任何 `service` 操作(它只吃已經拿到的 View) — 觀察點:Cli.Render 的模組介面
- **明確不做**:不決定 exit code(shell/F003-cli-options-and-envelope);不查型別註冊表決定怎麼印——要什麼欄位由 View 決定
```

**注意**:這份的「核心判準」引的是 `hSetEncoding` + Windows console code page,但那條在 shell/F003
的負責模組(`Cli.Encoding`)裡;F004 的負責模組只有 `Cli.Render`。兩份的核心判準引文有重疊。

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**(依 ADR-015 也不該有)。
- **只在 frozen old code**:`cli/src/Aapms/Cli/Render.hs`(舊的 `Aapms.Cli.Render` 模組,含
  `Envelope` / `IndexReport` / `DeleteReport` 的渲染)。它渲染的是舊的分裂 View 型別,不是新的
  `NodeView` / `NodeTreeView`。

---

## 2.5 shell/F005 — http-server

**檔案**:`.design/subsystems/shell/features/F005-http-server.md`

**title**:`http-server`
**description**:`` handler、`AppState`、token middleware 與啟動閘門、`code` → 狀態碼、warp、`--openapi` ``
**一句話意圖**:整條 HTTP 管線——一行 handler、只裝一個 `Env` 的 `AppState`、token middleware 與
非回送位址的啟動閘門、由 `code` 字串分派的狀態碼。

**計畫的模組**:`Server.Handlers`、`Server.State`、`Server.Auth`、`Server.Status`。
**套件**:`aapms-server`(執行檔 `aapms-serve`)。**階段**:階段二。

**depends-on**:`[shell/F001]`。**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「統一信封、exit code、錯誤格式(本份是 `code` → HTTP 狀態碼那一段)」(system.md「子系統劃分」§shell 職責)
- **階段**:階段二
- **負責模組**:Server.Handlers、Server.State、Server.Auth、Server.Status
- **實作的 Level 2 介面**:契約 C 的狀態碼對照表與錯誤 body;`system.md` 對外介面第 2 節的繫結與
  認證規則;使用 shell/F001-api-types-and-openapi 的路由型別(無新增)
- **資料流管線段落**:HTTP 管線全段
- **驗收標準**:
  - 每個 handler 只做一件事:收解碼後的請求型別、呼叫**一個** `service` 操作、回傳。
    handler 內**沒有** `if` / `case` 的業務分支 — 觀察點:Server.Handlers 的模組介面
  - 綁非回送位址且未設 token 時**拒絕啟動**(行程以非零碼結束並印出原因),不是印警告後照跑 —
    觀察點:Server.Auth、`system.md` 對外介面第 2 節
  - loopback 模式未設 token 時可用;設了 token 後,錯誤的 token 一律 401,而比較耗時**不隨
    正確前綴長度變化** — 觀察點:Server.Auth
  - 狀態碼由 `code` 字串分派:對照表裡的每個 `code` 都對到表列狀態碼,表外的 `code` 一律 500 —
    觀察點:契約 C 的狀態碼表、Server.Status
  - 錯誤 body 與 CLI 信封的 `error` 同形,且 `code` / `message` 逐字相同 — 觀察點:契約 A 的
    `ErrorBody`、契約 C 的錯誤 body
  - 在**沒有**目前 vault 的目錄裡啟動,`GET /vaults` 仍可服務 — 觀察點:Server.State、
    `service` 契約 A 的「`openEnv` 不開任何索引」
  - `/thumb/{sha256}` 命中時回檔案並帶 `immutable` 快取標頭、未命中回 404,**任何情況都不解碼影像** —
    觀察點:契約 C 的 `/thumb/{sha256}`
  - `aapms-server` 的 `build-depends` 不含 `aapms-archive` / `aapms-ingest` / `aapms-reorg` /
    `aapms-store` / `aapms-workspace` / `JuicyPixels` — 觀察點:`CabalSpec`(硬規則 3)
- **明確不做**:不暴露契約 C「不暴露的」那一組;不做任何業務判斷;不自己包一層 `MVar`
  (互斥在 `service` 的 `Env`)
```

### 它承諾的形狀

模組間公開介面(design.md):`Server.Handlers → Server.Status`:`statusFor :: Text -> Status`
(吃 `code` 字串)。`AppState` 只裝一個 `Env`(legacy 是 `MVar (Maybe Env)`)。

狀態碼對照表(design.md 契約 C):

| `code` | 狀態碼 |
|---|---|
| `node_not_found` / `project_selector_not_found` / `vault_selector_not_found` | 404 |
| `revision_conflict` / `logical_name_taken` | 409 |
| `validation_failed` / `unknown_type` / `dangling_link_target` / `link_target_out_of_scope` / `level_tree_invalid` / `ambiguous_ref` | 400 |
| `usage_error` | 400 |
| 其餘 | 500 |

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**。
- `statusFor`:**全樹零命中**。
- **只在 frozen old code**:`server/src/Aapms/Server.hs`、`server/src/Aapms/Server/Auth.hs`、
  `server/src/Aapms/Server/Error.hs`、`server/src/Aapms/Server/State.hs`、`server/app/Main.hs`。
  舊碼的模組切法是 `Aapms.Server` / `.Auth` / `.Error` / `.State`,**不是**新設計的
  `Server.Handlers` / `Server.State` / `Server.Auth` / `Server.Status` 四分(舊的 `.Error` 大致
  對應新的 `.Status`,但舊碼是 case `ServiceError` 建構子,新契約明文改成由 `code` 字串分派)。

---

## 2.6 shell/F006 — mcp-adapter

**檔案**:`.design/subsystems/shell/features/F006-mcp-adapter.md`

**title**:`mcp-adapter`
**description**:`stdio JSON-RPC、tool 映射與命名、雙模式`
**一句話意圖**:stdio JSON-RPC 迴圈,tool 清單由同一份 servant 路由推導(不手寫),預設內嵌、
給 `--url` 才走遠端。

**計畫的模組**:`Mcp.Tools`、`Mcp.Rpc`。**套件**:`aapms-mcp`(執行檔 `aapms-mcp`)。
**階段**:階段二。

**depends-on**:`[shell/F002]`(契約內文另寫「使用 shell/F001 的路由型別」)。
**被誰依賴**:無。

### `## 契約` 逐字

```markdown
## 契約

- **核心判準**:少了它,shell 就無法「MCP tool 映射」(system.md「子系統劃分」§shell 職責)
- **階段**:階段二
- **負責模組**:Mcp.Tools、Mcp.Rpc
- **實作的 Level 2 介面**:契約 D 全部;使用 shell/F001-api-types-and-openapi 的路由型別與 shell/F002-backend-dispatch 的 `runOp`(無新增)
- **資料流管線段落**:MCP 管線全段
- **驗收標準**:
  - `tools/list` 的 tool 集合由路由推導:與契約 C 路由表(扣掉「不暴露的」)**一一對應**,
    沒有手寫的額外 tool — 觀察點:契約 D 的 tool 命名、契約 C 的路由表
  - tool 名是 snake_case 且**不含產品前綴**;同一個路由在不同版本間名稱穩定 — 觀察點:契約 D
  - 每個 tool 的參數 schema 與同一路由的 OpenAPI schema **逐欄相同** — 觀察點:契約 D 的參數 schema
  - 不給 `--url` 時走內嵌:**沒有任何 HTTP 請求發出**,而且不需要有 `aapms-serve` 在跑 —
    觀察點:契約 D 的傳輸、契約 E 的 `Backend`
  - 給 `--url` 時走遠端,回傳與內嵌逐欄相等 — 觀察點:契約 E 的 `runOp`
  - 失敗回 `{"code":…,"message":…}`,與 REST 錯誤 body 的 `error` 同形且逐字相同 — 觀察點:
    契約 D 的回傳、契約 C 的錯誤 body
  - `--version` 印一行後結束,**不進 JSON-RPC 迴圈**(stdin 不被讀取) — 觀察點:契約 D 的 `--version`
  - `aapms-mcp` 的 `build-depends` 不含 `aapms-archive` / `aapms-ingest` / `aapms-reorg` /
    `optparse-applicative` — 觀察點:`CabalSpec`
- **明確不做**:不另立一套 tool 契約;不做 MCP 的資源(resources)與提示(prompts),本期只有 tools
```

### 它承諾的形狀(design.md 契約 D)

| 面向 | 契約 |
|---|---|
| tool 命名 | 由路由推導的穩定字串(`nodes_get` / `search` / `entities_create` …),snake_case;**不帶產品前綴**(legacy 的 `story_flow_*` 退場) |
| 參數 schema | 由 `ToSchema` 推導,與 OpenAPI 同源 |
| 回傳 | 成功回 `data` 的 JSON;失敗回 `{"code":…,"message":…}`,與 REST 同形 |
| 傳輸 | **雙模式**:預設內嵌(`Backend` 的 Embedded);給 `--url` 才走遠端 |
| `--version` | 印一行版本後結束,不進 JSON-RPC 迴圈 |

### 程式碼存在性

- 在 `service/src` / `workspace/src` / `store/src`:**零**。
- **只在 frozen old code**:`mcp/src/Aapms/Mcp.hs`、`mcp/src/Aapms/Mcp/Client.hs`、
  `mcp/src/Aapms/Mcp/Config.hs`、`mcp/src/Aapms/Mcp/Protocol.hs`、`mcp/src/Aapms/Mcp/Server.hs`、
  `mcp/src/Aapms/Mcp/Tools.hs`、`mcp/app/Main.hs`。舊碼有 `Aapms.Mcp.Tools`(對應新的 `Mcp.Tools`),
  但沒有 `Mcp.Rpc`(舊的是 `Protocol` + `Server` 兩個);而且 design.md 明寫 legacy 的
  `aapms-mcp` 是**純 HTTP 客戶端**(只認 `--url`),新契約改成雙模式,舊碼的 `Client.hs` 是
  被否決的那個形狀。

---

# 3. 依賴圖與程式碼存在性總表

## 3.1 service 依賴圖(取自 frontmatter `depends-on`)

```
F001 service-env-and-scope (done)
  └─ F003 node-read
       ├─ F004 node-write
       │    ├─ F005 asset-naming
       │    └─ F006 level-and-node
       ├─ F007 search-facade
       └─ F008 index-ops

F001 ─ F002 workspace-facade (done)     -- F002 depends-on [service/F001]
```

## 3.2 shell 依賴圖

```
F001 api-types-and-openapi (depends-on: 空)
  ├─ F002 backend-dispatch
  │    ├─ F003 cli-options-and-envelope
  │    │    └─ F004 cli-render
  │    └─ F006 mcp-adapter
  └─ F005 http-server
```

## 3.3 程式碼存在性總表

「已建置套件」= `service/src` + `workspace/src` + `store/src`(cabal.project 的
core/types/md/store/workspace/contract/service)。

| feature | 承諾的主要名字 | 在已建置套件 | 在 frozen old code |
|---|---|---|---|
| service/F003 | `getNode` `listNodes` `childrenOf` `linksOf` `NodeView` `NodeDetail` `NodeTreeView` `Page` `LinkReport` `AmbiguousRef` `NodeNotFound` | **無**(只有 graph-core 的下層 `Aapms.Store.Query.listNodes` / `.childrenOf` 與 `StoreError` 的 `NodeNotFound`) | `linksOf` 只在 `api/src/Aapms/Api.hs`、`cli/src/Aapms/Cli/Backend.hs`、`server/src/Aapms/Server.hs` |
| service/F004 | `createEntity` `addFragment` `updateMeta` `setBody` `deleteNode` `addLink` `removeLink` `DeleteReport` `NewEntityReq` `NewFragmentReq` `MetaPatch` `validateForWrite` 五個錯誤建構子 | **無**(只有 graph-core 的 `Aapms.Store.Write.addLink` / `.removeLink`、`Store.{Create,Node,Write}.deleteNode`) | `createEntity` `addFragment` `DeleteReport` `NewEntityReq` 只在 `api/src`、`cli/src`、`server/src` |
| service/F005 | `setAssetName` `updateAssetMeta` `upsertLicense` `NewLicenseReq` `LogicalNameTaken` | **無**(只有 graph-core 的 `Aapms.Store.Write.upsertLicense`、`Store.Query.lookupByName`) | 無 |
| service/F006 | `createLevel` `deleteLevel` `addNode` `removeNode` `NewLevelReq` `NewNodeReq` `NodeTreeView` `LevelTreeInvalid` | **無** | 四個操作只在 `cli/src/Aapms/Cli/Backend.hs`、`cli/src/Aapms/Cli/Resolve.hs`、`server/src/Aapms/Server.hs` |
| service/F007 | `search` `SearchView` `SearchHitView` | **無**(只有 graph-core 的 `Store.MultiVault.searchAcross`、`Store.Query.search`) | 無 |
| service/F008 | `reindex` `refreshIndex` `IndexReport` `withPipeline` | **`withPipeline` 已存在**(`service/src/Aapms/Service/Scope.hs`,無呼叫端);其餘無(graph-core 有 `Store.Index.indexFile` / `.rebuildIndex`) | `reindex` `refreshIndex` `IndexReport` 只在 `api/src`、`cli/src`、`server/src` |
| shell/F001 | `Api.Routes` `Api.Instances` `Api.OpenApi`、`FromHttpApiData` `ToSchema` `toOpenApi` | **無**(且不該有) | 只在 `api/src/Aapms/Api.hs`、`api/src/Aapms/Api/Instances.hs`(模組切法不同) |
| shell/F002 | `Backend` `BackendError` `runOp` `Op` | **無** | `Backend` 只在 `cli/src/Aapms/Cli/Backend.hs` 等(住在 aapms-cli,新設計要拆成獨立套件);`runOp` `BackendError` `PipelineNotRemote` `TransportError` `BusinessError` **全樹零命中** |
| shell/F003 | `Envelope` `ErrorBody` `ExitKind`、`Cli.Options` `Cli.Envelope` `Cli.Encoding` | **無** | `Envelope` 只在 `cli/src/Aapms/Cli/Render.hs`、`cli/src/Aapms/Cli.hs`;`Aapms.Cli.Options` 只在 `cli/src/Aapms/Cli/Options.hs`;`ErrorBody` `ExitKind` **全樹零命中** |
| shell/F004 | `Cli.Render` | **無** | 只在 `cli/src/Aapms/Cli/Render.hs`(渲染舊的分裂 View) |
| shell/F005 | `Server.Handlers` `Server.State` `Server.Auth` `Server.Status`、`statusFor` | **無** | 只在 `server/src/Aapms/Server{,/Auth,/Error,/State}.hs`;`statusFor` **全樹零命中** |
| shell/F006 | `Mcp.Tools` `Mcp.Rpc` | **無** | 只在 `mcp/src/Aapms/Mcp{,/Client,/Config,/Protocol,/Server,/Tools}.hs`(舊的是純 HTTP 客戶端) |

## 3.4 幾個要注意的落差

1. **`aapms-backend` 目錄不存在**。shell design.md 2026-08-29 裁決新增的第五個套件,樹上還沒有
   `backend/`,`cabal.project` 也沒有它的註解行(其他四個 shell 套件都有註解行)。
2. **`ServiceError` 只有 5/14 個建構子**。F003 要加 2 個、F004 要加 5 個、F005 要加 1 個
   (`LevelTreeInvalid` 由 F004 加、F006 使用)。build-log DEC-1:`.cabal` 的 `exposed-modules`
   由編排者單線維護,不屬任何 feature 的白名單。
3. **`Validate.hs` / `Read.hs` / `Write.hs` 三個檔案完全不存在**,design.md 的七模組只實作了四個。
4. **`withPipeline` 已交付但無人呼叫**——它的唯一計畫呼叫端是 service/F008,而 F008 在階段三。
5. **F002 SELF-1 的上游 enhance 未處理**:`Machine.hs` 的 re-export 排除 `RegistrySource`
   (GHC conflicting exports:`HubSource` 與 `RegistrySource` 各有一個 `FromEnv` 建構子),
   build-log 標「**未回寫,待另開 enhance**」。shell 的 `DoctorView.dvRegistry` 會撞到這一格。
6. **shell 沒有 build-log、沒有 spec-gaps**,六份文檔全部 `rev: 0` 未經實作檢驗;而 service
   design.md 說 shell「夾在最下游」,`service` 階段一是它的前提——service 目前只跑完階段一。
