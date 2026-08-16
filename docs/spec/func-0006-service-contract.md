---
id: func-0006
type: spec
title: service-contract
description: 以 ServiceM 定義 Vault、Entity、Link、Level、Node 的唯一業務契約
status: open
created: 2026-08-16
updated: 2026-08-16
depends-on: [func-0002, func-0003, func-0004, func-0005]
related-adr: [adr-0002, adr-0003, adr-0005, adr-0006, adr-0008]
related-spec: []
---

## Service 業務契約 功能規格

### 功能概述

ADR-0006 的核心主張:**業務邏輯只存在於 `storyflow-service`,它是唯一的契約定義處**。
CLI(func-0007)、servant server(func-0008)、未來的 MCP adapter 全部是它的薄包裝。這一層
存在的價值不是「多一層」,而是**讓三種介面的行為由型別強制一致**——邏輯只有一份,不可能
悄悄長歪。

func-0005 完成後,`storyflow-store` 有了完整的讀寫能力,但它們是**落地操作**,不是業務操作。
兩者的差距是這一層要補的:

- store 的 `createEntityFile` 吃 `NewEntity` 就寫檔,**不驗證型別註冊表**——`checkEntity`
  是純函式,沒人呼叫它
- store 的每個函式各自吃 `Connection` / `Vault` / `TypeRegistry`,呼叫端要自己張羅這三樣
- store 回的是 `StoreError`(檔案與索引的語彙),不是業務語彙
- 「建一個 Entity 並同時建立它與另一個 Entity 的關聯」這種**組合操作**沒有歸屬

驗收標準:

1. `service` 覆蓋 P2 需要的全部操作:Vault、Entity、Link、Level、Node、型別清單、索引維護
2. `service` 的測試不經過 CLI 也不經過 HTTP——用 `temporary` 建臨時 Vault,直接 hspec
   跑完整業務流程(ADR-0006 的正面影響之一)
3. `service` 不 import 任何與終端輸出、HTTP、`optparse-applicative` 有關的東西;
   `storyflow-service.cabal` 的 `build-depends` 就是這條界線的證明
4. 樂觀鎖在每一個會改動既有實體的操作上都是**必填參數**,不是選配(ADR-0006 的負面影響第三條:
   兩種模式下都必須生效)
5. 型別註冊表在執行期找得到——不是只有從原始碼目錄跑才行

明確**不做**的:conflict(P4)、workshop(P5)、LLM。它們在 ADR-0006 的操作清單裡,但屬於
後續階段;本 spec 只做 P2 那一段。跨 Vault 的讀寫也不做,見下。

### 相依性

`depends-on: [func-0002, func-0003, func-0004, func-0005]`。前三者已 done,**func-0005 尚未
開工**,是本 spec 的唯一阻塞來源。

- **func-0005**:本 spec 的每一個寫入操作都直接包裝它的函式(`createEntityFile`、`addFragment`、
  `deleteEntity`、`addNode`、`removeNode`、`listLevels`、擴充後的 `writeEntityMeta` 等)。
  這些函式**目前不存在於程式碼中**,介面表裡對應的簽名是依 func-0005 的介面約定寫的,不是
  從原始碼讀出的——實作時若 func-0005 的簽名有偏差,本 spec 要跟著修
- **func-0004**:`Vault` 定位、`openVaultIndex`、既有的查詢函式、`StoreError`
- **func-0003**:`MetaOverride` 是 `writeEntityMeta` 的參數型別,service 的 patch 要組出它;
  `MdWarning` 隨寫入結果回傳
- **func-0002**:全部核心型別與 `checkEntity` / `TypeRegistry`

func-0001 建立的 `cabal.project` 要加一行 `service/`,但那是骨架的延伸、不是介面相依,
因此不列入 `depends-on`。

**可否平行開發**:不能與 func-0005 平行——本 spec 的實作面幾乎全部是對它的包裝。
func-0007(CLI)與 func-0008(server)都必須等本 spec,但**這兩支彼此可以平行**:
它們各自包裝同一組 `ServiceM` 函式,互不相干。

### 實作方式

#### 一、`ServiceM` 與 `Env`

```haskell
data Env = Env
  { envVault :: Vault
  , envConn  :: Connection
  , envTypes :: TypeRegistry
  }

newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)
  deriving newtype
    (Functor, Applicative, Monad, MonadIO, MonadReader Env, MonadError ServiceError)

runService :: Env -> ServiceM a -> IO (Either ServiceError a)
```

用 `ReaderT` + `ExceptT` 而不是「每個函式吃 `Env` 回 `IO (Either ...)`」的理由:業務操作是
**組合**的。「建一個 Entity 並同時掛一條 `partOf` 關聯」是三次落地呼叫串起來,每一次都可能
失敗;手工串 `Either` 會讓每個函式的主體被 `case` 淹沒,而錯誤處理正是最不該被淹沒的部分。

代價是 store 回的 `IO (Either StoreError a)` 要逐個轉進來,收在一個輔助函式:

```haskell
liftStore :: IO (Either StoreError a) -> ServiceM a
liftStore act = liftIO act >>= either (throwError . StoreFailed) pure

liftStoreIO :: IO a -> ServiceM a        -- store 的純查詢(listEntities 等)不回 Either
liftStoreIO = liftIO
```

`ServiceM` 用 `GeneralizedNewtypeDeriving` 拿 `MonadError` / `MonadReader`,呼叫端因此不必
知道它是 `ReaderT` 疊 `ExceptT`——這一層的內部結構未來要換(例如加 `StateT` 放快取)不會
波及 `server` 與 `cli`。

**沒有把時鐘放進 `Env`**:func-0004 的 `writeEntityMeta` 已經自己 `getCurrentTime`,
func-0005 的建立函式同理。把時鐘注入 service 卻不注入 store,等於只有一半可控,不如統一。

#### 二、`Env` 的取得與型別註冊表的執行期定位

```haskell
openEnv  :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))
closeEnv :: Env -> IO ()
withEnv  :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
```

`Maybe Text` 是 `--vault <名稱>`,`FilePath` 是 cwd——兩者原樣轉給 `resolveVault`,ADR-0008
的三段規則(向上搜尋 → 全域註冊表)不在這裡重寫一遍。`openVaultIndex` 回的 `[IndexIssue]`
一併帶出:作者用編輯器改過檔案的話,索引在這一步就補上了,而解析失敗的檔案要讓呼叫端能提醒。

**型別註冊表在執行期怎麼找得到**——這是 P2 才第一次浮現、但現在不解決就會卡住的問題。
`types/registry/*.toml` 隨程式碼版控(architecture.md),從原始碼目錄跑測試時相對路徑找得到,
但 `cabal install` 之後的 `story-flow` 執行檔沒有這個相對路徑。作法:

1. `types/storyflow-types.cabal` 加 `data-files: registry/*.toml`,新增
   `defaultRegistryDir :: IO FilePath`,內部走 cabal 產生的 `Paths_storyflow_types.getDataDir`
2. 環境變數 `STORYFLOW_REGISTRY` 有值時優先——開發時指向工作目錄的 `types/registry/`,
   作者想自訂型別時也不必重編譯
3. 兩者都拿不到有效目錄時回 `RegistryUnavailable`,訊息要說出去哪裡放

`loadRegistry` 回的是 `Either [LoadError] TypeRegistry`;載入失敗**直接讓 `openEnv` 失敗**,
不退回空註冊表——空註冊表會讓 `checkEntity` 對每個 Entity 都回 `UnknownEntityType`,把設定
錯誤偽裝成資料錯誤。

#### 三、驗證策略

`checkEntity :: TypeRegistry -> Entity -> [EntityWarning]` 是純函式,回三種警告。service 的
處理**依種類分流**:

| `EntityWarning` | 處置 | 理由 |
|---|---|---|
| `MissingRequiredField` | **拒絕寫入**,回 `ValidationFailed` | `required = true` 是作者自己在 TOML 裡設的。擋下來是執行作者的意思,不是工具越權 |
| `LinkNotAllowed` | 警告,照寫 | ADR-0005 明說自訂關聯合法,引擎當純標註儲存 |
| `UnknownEntityType` | 警告,照寫 | 主體型別本來就可能不在註冊表;而且擋下來等於逼作者先寫 TOML 才能記一句設定 |

驗證發生在**寫檔之前**:先用請求資料組出 `Entity`(id 還沒配置,先用佔位的 `PEnt` 零值,
`checkEntity` 不看 id),`checkEntity` 過了才呼叫 store。這樣 `ValidationFailed` 時一個位元組
都沒寫,與樂觀鎖的 `StaleRevision` 語意一致。

警告不是丟掉,而是進回傳值的 `evWarnings`。CLI 印出來、API 放在 JSON 裡——AI Agent 因此
看得到「你這筆 link 不在 allowed_links 裡」並自己決定要不要改。

#### 四、跨 Vault:只存不解析

`Ref` 帶 `refVault`,`links` 表也有 `dst_vault` 欄位,所以 `<vault>:<id>` 這種 target
**寫得進去、查得出來**——那是 func-0004 已經做完的事,本 spec 不動它。

但 service 的**讀取與寫入一律只碰本 Vault**:任何以 `Ref` 定址且 `refVault` 不是 `Nothing`
也不等於 `vaultName envVault` 的請求,回 `CrossVaultUnsupported`。理由是跨 Vault 讀取要開
第二個索引連線,連帶帶出連線快取、生命週期、目標 Vault 索引過時要不要一起補等一整批問題,
而 P2 的驗收標準完全不需要它。`links` 裡的跨 Vault 記錄仍然存在且可查詢,將來要支援時
資料是現成的。

#### 五、回傳型別:重用 core 的型別,只補索引才知道的東西

不另造一套與 `Meta` / `Entity` 平行的 DTO。core 的型別已經有完整的 aeson 實例
(`StoryFlow.Core.Json` 有 `ToJSON`/`FromJSON` for `Id` / `Ref` / `Meta` / `Entity` /
`Level` / `Node` / `Link` / `Status` / `Source` / `Timeline` / `NodeKind` / `LinkKind`),
複製一份十四個欄位的 DTO 只會製造兩份要同步維護的編碼規則。

View 型別只包一層,補上**檔案裡沒有、只有索引知道**的資訊:

```haskell
data EntityView = EntityView
  { evEntity   :: Entity
  , evPath     :: FilePath        -- Vault 相對路徑
  , evAnchor   :: Maybe Text      -- Nothing = 檔案層主體
  , evWarnings :: [Text]          -- checkEntity 與 md 的警告,已 render 成繁中
  }

data LevelView = LevelView
  { lvView :: Level
  , lvTree :: NodeTree            -- buildTree 的結果,不是扁平 [Node]
  , lvPath :: FilePath
  }
```

`LevelView` 回**樹**而不是扁平清單:`buildTree` 已經驗證過合法性,把驗證結果丟掉再讓 CLI
與 server 各自重建一次,就是三個地方各有一份樹邏輯。

`EntityFilter`(`efType` / `efStatus` / `efTag` / `efLimit`)直接沿用 store 的定義,不重造。
它是一個沒有行為的過濾條件記錄,重造只會多一次欄位對欄位的搬運。

#### 六、操作清單

全部型別都是 `ServiceM`,除了三個在 `Env` 存在之前就要能跑的:

```text
-- Vault(不需要 Env)
createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)
listVaults  :: IO (Either ServiceError [VaultView])
openEnv / closeEnv / withEnv

-- Vault(需要 Env)
vaultInfo    :: ServiceM VaultView
reindex      :: ServiceM IndexReport      -- 全量重建
refreshIndex :: ServiceM IndexReport      -- 只補過時的檔案

-- 型別註冊表
listEntityTypes :: ServiceM [EntityTypeSpec]

-- Entity
createEntity  :: NewEntityReq   -> ServiceM EntityView
addFragment   :: Id -> NewFragmentReq -> ServiceM EntityView
getEntity     :: Id -> ServiceM EntityView
listEntities  :: EntityFilter -> ServiceM [Meta]
searchEntity  :: Text -> EntityFilter -> ServiceM [SearchHit]
updateEntity  :: Id -> Int -> EntityPatch -> ServiceM EntityView
setEntityBody :: Id -> Int -> Text -> ServiceM EntityView
deleteEntity  :: Id -> Int -> Bool -> ServiceM DeleteReport   -- Bool = force

-- Link
addLink    :: Id -> Int -> Link -> ServiceM EntityView
removeLink :: Id -> Int -> LinkKind -> Ref -> ServiceM EntityView
linksOf    :: Id -> ServiceM LinkReport        -- 正向 + 反向一次給

-- Level / Node
createLevel :: NewLevelReq -> ServiceM LevelView
getLevel    :: Id -> ServiceM LevelView
listLevels  :: EntityFilter -> ServiceM [Meta]
deleteLevel :: Id -> Int -> Bool -> ServiceM DeleteReport
addNode     :: Id -> Int -> NewNodeReq -> ServiceM LevelView
removeNode  :: Id -> Int -> Bool -> ServiceM LevelView
```

每個會改動既有實體的操作都有一個 `Int` 參數:**expected revision**。它是必填而不是
`Maybe Int`,因為 ADR-0006 明列「樂觀鎖在兩種模式下都必須生效,不能只在 server 端做」——
給一個「不帶就跳過檢查」的逃生口,CLI 一定會用它,然後遠端模式的並發保護就只剩一半。
CLI 的作法是**先讀再寫**(func-0007 的事),不是繞過。

`linksOf` 一次回正向與反向,是因為「琳達這個片段跟什麼有關」在作者心裡是一個問題,不是兩個;
分成兩個 API 會讓每個介面都得自己組合。

`addLink` / `removeLink` 走 store 的 `addEntityLink` / `removeEntityLink`,但在呼叫前檢查
`linkTarget` 指向的 id **確實存在**(`lookupEntity` / `lookupLevel`),不存在就
`DanglingLinkTarget`。這是 service 才做得到的驗證:store 的單檔操作看不到別的檔案。
`refVault` 非本 Vault 時走 `CrossVaultUnsupported` 那條路,不做存在性檢查。

#### 七、`ServiceError`

```haskell
data ServiceError
  = StoreFailed StoreError                    -- 落地層的失敗原樣帶上
  | RegistryUnavailable Text                  -- 註冊表載不到,附上找過哪些路徑
  | RegistryLoadFailed [LoadError]             -- 不叫 RegistryInvalid:LoadError 已佔用該名稱
  | ValidationFailed Id [EntityWarning]       -- 必填欄位缺漏,拒絕寫入
  | UnknownType Text                          -- 建立時給了註冊表沒有的型別
  | DanglingLinkTarget Ref                    -- link 指向不存在的 id
  | CrossVaultUnsupported Ref
  | LevelTreeInvalid Id [TreeError]           -- 讀出來的 Level 樹不合法
  deriving stock (Show, Eq)

renderServiceError :: ServiceError -> Text
```

`StoreFailed` 原樣包住 `StoreError` 而不逐個翻譯:func-0004 的 `renderStoreError` 每一則
訊息都已經寫成「說出下一步該做什麼」的形式(`IndexUpdateFailed` 直接叫人跑
`story-flow index rebuild`),重寫一遍只會讓兩份訊息漂移。`renderServiceError` 對這個
建構子就是委派給 `renderStoreError`。

`LevelTreeInvalid` 是**讀取**時才可能出現的:func-0005 的 `addNode` / `removeNode` 在寫檔前
就驗過樹,但作者可以直接編輯 Level 檔把樹改壞。`getLevel` 因此要能回報這件事,而不是崩潰。

### 使用到的既有串接介面

> func-0005 的介面**尚未實作**,下表中來源 spec 為 func-0005 的各列是依該 spec 的
> 「新增的介面」約定填寫,不是從原始碼讀出的簽名。

| 介面(含完整簽名) | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: Text, metaType :: Text, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Int, metaCreated :: Day, metaUpdated :: Day }` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `listEntities` / `listLevels` 的回傳元素 |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | func-0002 | `EntityView` 內層;`checkEntity` 的輸入 |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `LevelView` 內層 |
| `data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `buildTree` 的輸入 |
| `data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `LevelView` 回樹而不是扁平清單 |
| `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `getLevel` 組樹;失敗回 `LevelTreeInvalid` |
| `data TreeError = MultipleRoots [Id] \| NoRoot \| OrphanNode Id Id \| Cycle [Id] \| DuplicateOrder Id Int [Id] \| DuplicateNodeId Id \| RootMismatch Id Id` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `LevelTreeInvalid` 的酬載 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `addLink` 的參數 |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 跨 Vault 判定與 `DanglingLinkTarget` |
| `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `linksOf` 的反向查詢參數 |
| `checkEntity :: TypeRegistry -> Entity -> [EntityWarning]` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | 寫入前的型別驗證,依警告種類分流 |
| `data EntityWarning = MissingRequiredField Text Text \| LinkNotAllowed Text Text \| UnknownEntityType Text` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | 分流的判斷依據與 `ValidationFailed` 的酬載 |
| `data EntityTypeSpec`(func-0005 擴充後含 `etsDir` / `etsOwnerType`) | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `listEntityTypes` 的回傳;CLI 的 `--type` 選項來源 |
| `lookupType :: Text -> TypeRegistry -> Maybe EntityTypeSpec` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | 建立時確認型別存在,不存在回 `UnknownType` |
| `listTypes :: TypeRegistry -> [EntityTypeSpec]` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `listEntityTypes` |
| `loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)` | `types/src/StoryFlow/Types/Loader.hs` | func-0002 | `openEnv` 載入註冊表;失敗即 `RegistryLoadFailed` |
| `data LoadError = TomlParseError FilePath Text \| MissingField FilePath Text \| BadFieldType FilePath Text Text \| UnknownKey FilePath Text \| RegistryDirMissing FilePath \| RegistryInvalid RegistryError`(`renderLoadError :: LoadError -> Text`) | `types/src/StoryFlow/Types/Loader.hs` | func-0002 | `RegistryLoadFailed` 的酬載與訊息。**注意它已有一個 `RegistryInvalid` 建構子**,`ServiceError` 因此不可同名 |
| `data MetaOverride`(13 個 `Maybe` 欄位) | `md/src/StoryFlow/Md/Inherit.hs` | func-0003 | `EntityPatch` 轉成它交給 `writeEntityMeta` |
| `emptyOverride :: MetaOverride` | `md/src/StoryFlow/Md/Inherit.hs` | func-0003 | patch 的起點 |
| `data MdWarning = MissingSummary Id \| CustomLinkKind Id Text \| EmptyBody Id`(`renderMdWarning :: MdWarning -> Text`) | `md/src/StoryFlow/Md/Error.hs` | func-0003 | 併進 `evWarnings` |
| `data Vault = Vault { vaultName :: Text, vaultRoot :: FilePath, vaultCfg :: VaultConfig }` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | `Env` 的欄位;`VaultView` 的來源 |
| `resolveVault :: Maybe Text -> FilePath -> IO (Either StoreError Vault)` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | `openEnv` 的第一步,ADR-0008 的規則不重寫 |
| `initVault :: FilePath -> Text -> IO (Either StoreError Vault)` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | `createVault` |
| `loadVaultRegistry :: IO (Either StoreError (Map Text FilePath))` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | `listVaults`:全域註冊表的名稱 → 路徑 |
| `registryPath :: IO FilePath` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | `RegistryUnavailable` 的訊息要說出去哪裡找過 |
| `openVaultIndex :: Vault -> IO (Either StoreError (Connection, [IndexIssue]))` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | `openEnv` 開索引並順手補過時檔案 |
| `closeIndex :: Connection -> IO ()` | `store/src/StoryFlow/Store/Schema.hs` | func-0004 | `closeEnv` |
| `rebuildIndex :: Connection -> Vault -> IO (Either StoreError [IndexIssue])` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | `reindex` |
| `refreshStale :: Connection -> Vault -> IO (Either StoreError [IndexIssue])` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | `refreshIndex` |
| `data IndexIssue = IndexIssue FilePath [MdError] [MdWarning]`(`issueHasError`, `renderIndexIssue`) | `store/src/StoryFlow/Store/Index.hs` | func-0004 | `IndexReport` 的酬載 |
| `data EntityFilter = EntityFilter { efType :: Maybe Text, efStatus :: Maybe Status, efTag :: Maybe Text, efLimit :: Maybe Int }` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 直接沿用,不重造過濾條件 |
| `emptyFilter :: EntityFilter` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 預設過濾條件 |
| `lookupEntity :: Connection -> Id -> IO (Maybe Entity)` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `getEntity`;`addLink` 的目標存在性檢查 |
| `listEntities :: Connection -> EntityFilter -> IO [Meta]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `listEntities` |
| `lookupLevel :: Connection -> Id -> IO (Maybe (Level, [Node]))` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `getLevel`,取出後餵 `buildTree` |
| `linksFrom :: Connection -> Id -> IO [Link]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `linksOf` 的正向 |
| `linksTo :: Connection -> Ref -> IO [(Id, Link)]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `linksOf` 的反向 |
| `searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `searchEntity`;`Text` 是 snippet |
| `data StoreError = VaultNotFound Text \| VaultConfigInvalid FilePath Text \| VaultAlreadyExists FilePath \| EntityNotFound Id \| StaleRevision Id Int Int \| IdCollision IdPrefix \| FileReadFailed FilePath Text \| FileWriteFailed FilePath Text \| IndexUpdateFailed FilePath Text \| ParseFailed FilePath [MdError] \| SqliteError Text`(func-0005 再加九個、刪 `FrontmatterWriteUnsupported`;`renderStoreError :: StoreError -> Text`) | `store/src/StoryFlow/Store/Error.hs` | func-0004 | `StoreFailed` 包住它,訊息委派不重寫 |
| `data WriteResult = WriteResult { wrNewRevision :: Int, wrPath :: FilePath }` | `store/src/StoryFlow/Store/Write.hs` | func-0004 | 寫入後拿新 revision 組 View |
| `writeEntityMeta :: Connection -> Vault -> Id -> Int -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)`(func-0005 擴充為支援主體) | `store/src/StoryFlow/Store/Write.hs` | func-0004 | `updateEntity` |
| `createEntityFile :: Connection -> Vault -> TypeRegistry -> NewEntity -> IO (Either StoreError CreateResult)` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | `createEntity` |
| `createLevelFile :: Connection -> Vault -> NewLevel -> IO (Either StoreError CreateResult)` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | `createLevel` |
| `addFragment :: Connection -> Vault -> Id -> Int -> NewFragment -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | `addFragment` |
| `deleteEntity :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError DeleteResult)` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | `deleteEntity` |
| `deleteLevel :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError DeleteResult)` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | `deleteLevel` |
| `data NewEntity` / `NewFragment` / `NewLevel` / `NewNode` / `CreateResult` / `DeleteResult` / `DeleteMode` | `store/src/StoryFlow/Store/Create.hs` | func-0005 | 請求型別轉成它們;`Bool` 的 force 轉成 `DeleteMode` |
| `writeEntityBody :: Connection -> Vault -> Id -> Int -> Text -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Write.hs` | func-0005 | `setEntityBody` |
| `addEntityLink :: Connection -> Vault -> Id -> Int -> Link -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Write.hs` | func-0005 | `addLink` |
| `removeEntityLink :: Connection -> Vault -> Id -> Int -> LinkKind -> Ref -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Write.hs` | func-0005 | `removeLink` |
| `addNode :: Connection -> Vault -> Id -> Int -> NewNode -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Node.hs` | func-0005 | `addNode` |
| `removeNode :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Node.hs` | func-0005 | `removeNode` |
| `listLevels :: Connection -> EntityFilter -> IO [Meta]` | `store/src/StoryFlow/Store/Query.hs` | func-0005 | `listLevels` |
| `lookupDir :: Text -> TypeRegistry -> Maybe Text` | `core/src/StoryFlow/Core/Registry.hs` | func-0005 | 建立前確認型別有宣告目錄,否則訊息比 `RegistryDirUnknown` 更早給出 |

### 新增的介面

#### `storyflow-types`(執行期定位)

```haskell
-- | 型別註冊表的執行期目錄。STORYFLOW_REGISTRY 優先,否則走 cabal data-files。
defaultRegistryDir :: IO (Maybe FilePath)
```

#### `storyflow-service`(`StoryFlow.Service.Monad`)

```haskell
data Env = Env { envVault :: Vault, envConn :: Connection, envTypes :: TypeRegistry }

newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)
  deriving newtype (Functor, Applicative, Monad, MonadIO,
                    MonadReader Env, MonadError ServiceError)

runService :: Env -> ServiceM a -> IO (Either ServiceError a)
liftStore  :: IO (Either StoreError a) -> ServiceM a

openEnv  :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))
closeEnv :: Env -> IO ()
withEnv  :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)
```

#### `storyflow-service`(`StoryFlow.Service.Error`)

```haskell
data ServiceError
  = StoreFailed StoreError
  | RegistryUnavailable Text
  | RegistryLoadFailed [LoadError]             -- 不叫 RegistryInvalid:LoadError 已佔用該名稱
  | ValidationFailed Id [EntityWarning]
  | UnknownType Text
  | DanglingLinkTarget Ref
  | CrossVaultUnsupported Ref
  | LevelTreeInvalid Id [TreeError]

-- | 給人看的繁中訊息。StoreFailed 委派給 renderStoreError,不重寫一遍。
renderServiceError :: ServiceError -> Text

-- | 給機器看的穩定識別碼,snake_case。StoreFailed 往內取 StoreError 的建構子名
--   (例如 stale_revision / entity_not_found)。
--
--   放在 service 而不是各介面自己一份:CLI 的 --json、servant 的錯誤 body、
--   未來 MCP 的錯誤回報必須用同一套代碼,否則 Agent 要為每個介面各學一次。
errorCode :: ServiceError -> Text
```

#### `storyflow-service`(`StoryFlow.Service.Types`)

```haskell
data EntityView = EntityView
  { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }

data LevelView = LevelView { lvLevel :: Level, lvTree :: NodeTree, lvPath :: FilePath }

data VaultView = VaultView { vvName :: Text, vvRoot :: FilePath, vvEntityCount :: Int }

data SearchHit = SearchHit { shMeta :: Meta, shSnippet :: Text }

data LinkReport = LinkReport { lrOutgoing :: [Link], lrIncoming :: [(Id, Link)] }

data IndexReport = IndexReport { irFiles :: Int, irIssues :: [Text] }

data DeleteReport = DeleteReport
  { drPath :: FilePath, drRemoved :: [Id], drBrokenLinks :: [(Id, Link)] }

-- 請求型別。與 store 的 NewEntity 分開:store 的版本帶 nePath 之類的落地細節,
-- 這裡的版本是業務語彙,且要能從 JSON 解出來(API 契約)。
data NewEntityReq = NewEntityReq
  { nerType :: Text, nerTitle :: Text, nerSummary :: Text, nerBody :: Text
  , nerTags :: [Text], nerAliases :: [Text], nerStatus :: Status
  , nerTimeline :: Timeline, nerLinks :: [Link], nerSource :: Source }

data NewFragmentReq = NewFragmentReq
  { nfrTitle :: Text, nfrSummary :: Text, nfrBody :: Text, nfrType :: Maybe Text
  , nfrTags :: [Text], nfrAliases :: [Text], nfrStatus :: Maybe Status
  , nfrTimeline :: Maybe Timeline, nfrLinks :: [Link], nfrSource :: Maybe Source }

data NewLevelReq = NewLevelReq
  { nlrTitle :: Text, nlrSummary :: Text, nlrBody :: Text
  , nlrRootTitle :: Text, nlrRootKind :: NodeKind, nlrStatus :: Status }

data NewNodeReq = NewNodeReq
  { nnrTitle :: Text, nnrKind :: NodeKind, nnrSummary :: Text
  , nnrBody :: Text, nnrLinks :: [Link] }

-- 只改有給值的欄位。全部 Maybe,直接對應到 MetaOverride。
data EntityPatch = EntityPatch
  { epTitle :: Maybe Text, epSummary :: Maybe Text, epTags :: Maybe [Text]
  , epStatus :: Maybe Status, epTimeline :: Maybe Timeline
  , epAliases :: Maybe [Text], epSource :: Maybe Source }

emptyPatch :: EntityPatch
```

上述請求與 View 型別全部有 `ToJSON` / `FromJSON` 實例,定義在
`StoryFlow.Service.Json`——func-0008 的 servant API 型別直接吃它們,不再定義第二套編碼。

#### `storyflow-service`(`StoryFlow.Service`)

門面模組,re-export 上述四個模組,並定義「六、操作清單」的全部業務函式。

### TodoList

- [ ] T1: 建立 `service/storyflow-service.cabal` 與 `cabal.project` 的 `service/` 項目、`-Wall` 設定、hspec 測試骨架;`build-depends` 明確**不含** servant / optparse / warp  `dep: -`
- [ ] T2: `storyflow-types`:`data-files: registry/*.toml` 與 `defaultRegistryDir`,支援 `STORYFLOW_REGISTRY` 覆寫  `dep: -`
- [ ] T3: `StoryFlow.Service.Error`:`ServiceError`、`renderServiceError`(`StoreFailed` 委派給 `renderStoreError`)與 `errorCode`(三種介面共用的穩定機器碼)  `dep: T1`
- [ ] T4: `StoryFlow.Service.Monad`:`Env` / `ServiceM` / `runService` / `liftStore`  `dep: T3`
- [ ] T5: `openEnv` / `closeEnv` / `withEnv`:Vault 定位、開索引、載入註冊表,三種失敗各自對應到明確的 `ServiceError`  `dep: T2, T4`
- [ ] T6: `StoryFlow.Service.Types`:全部 View 與請求型別  `dep: T4`
- [ ] T7: `StoryFlow.Service.Json`:上述型別的 aeson 實例  `dep: T6`
- [ ] T8: 驗證輔助函式:`checkEntity` 的警告依種類分流,`MissingRequiredField` → `ValidationFailed`,其餘進 `evWarnings`  `dep: T6`
- [ ] T9: Vault 操作:`createVault` / `listVaults` / `vaultInfo` / `reindex` / `refreshIndex`  `dep: T5`
- [ ] T10: 型別操作:`listEntityTypes`  `dep: T5`
- [ ] T11: Entity 讀取:`getEntity` / `listEntities` / `searchEntity`,組出 `EntityView` 與 `SearchHit`  `dep: T6, T5`
- [ ] T12: Entity 寫入:`createEntity` / `addFragment`,寫檔前跑 T8 的驗證  `dep: T8, T11`
- [ ] T13: Entity 修改與刪除:`updateEntity` / `setEntityBody` / `deleteEntity`,`EntityPatch` → `MetaOverride`  `dep: T12`
- [ ] T14: Link:`addLink` / `removeLink` / `linksOf`,含目標存在性檢查與 `CrossVaultUnsupported`  `dep: T13`
- [ ] T15: Level 與 Node:`createLevel` / `getLevel` / `listLevels` / `deleteLevel` / `addNode` / `removeNode`,`getLevel` 以 `buildTree` 組樹  `dep: T13`
- [ ] T16: `StoryFlow.Service` 門面 re-export  `dep: T14, T15`
- [ ] T17: 端到端業務測試:臨時 Vault 從零建出琳達與教室,全程只呼叫 `ServiceM` 函式  `dep: T16`

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `service/test/Spec.hs` → `套件邊界:build-depends 不含介面層套件` | 讀取 `storyflow-service.cabal`,斷言 `build-depends` 不出現 `servant` / `warp` / `optparse-applicative`;`cabal build all` 綠燈本身即證明套件掛上去了 |
| T2 | `types/test/.../LoaderSpec.hs` → `defaultRegistryDir 以環境變數為優先` | 設 `STORYFLOW_REGISTRY` 指向臨時目錄時回該路徑;未設時回 `data-files` 目錄且該目錄含五份 `.toml`;指向不存在的路徑時回 `Nothing` |
| T3 | `service/test/.../ErrorSpec.hs` → `每個 ServiceError 都有非空訊息與唯一的 errorCode` | 逐一 `renderServiceError` 斷言非空;`StoreFailed e` 的輸出包含 `renderStoreError e` 的內容;`errorCode` 對每個建構子都回非空 snake_case 且**兩兩相異**,`StoreFailed (StaleRevision ...)` 回 `stale_revision` |
| T4 | `service/test/.../MonadSpec.hs` → `runService 傳播 throwError 與 liftStore 的失敗` | `throwError` 的值原樣出現在 `Left`;`liftStore (pure (Left e))` 得到 `Left (StoreFailed e)`;成功路徑回 `Right` |
| T5 | `service/test/.../EnvSpec.hs` → `openEnv 三種失敗各自可辨識` | 不在 Vault 內 → `StoreFailed (VaultNotFound "")`;註冊表目錄不存在 → `RegistryUnavailable`;註冊表 TOML 壞掉 → `RegistryLoadFailed`;成功時回傳的 `IndexIssue` 含外部改動的檔案 |
| T6 | `service/test/.../TypesSpec.hs` → `emptyPatch 不改任何欄位` | `emptyPatch` 轉成 `MetaOverride` 後每個欄位都是 `Nothing`;逐欄設值後只有該欄非 `Nothing` |
| T7 | `service/test/.../JsonSpec.hs` → `請求與 View 型別 round-trip 不失真` | 每個型別 `decode . encode == Just x`;`EntityView` 的 JSON 含 `path` 與 `warnings` 鍵 |
| T8 | `service/test/.../ValidateSpec.hs` → `必填欄位缺漏擋下,其餘只警告` | 缺 `summary`(character-fragment 的 `required = true`)→ `ValidationFailed`;用自訂關聯 → 成功且 `evWarnings` 非空;型別不在註冊表 → 成功且有警告 |
| T9 | `service/test/.../VaultSpec.hs` → `createVault 後 vaultInfo 與 listVaults 都看得到` | 臨時目錄建 Vault → `listVaults` 含它 → `openEnv` → `vaultInfo` 的名稱與根目錄相符;`reindex` 後 `irFiles` 等於實際 `.md` 數 |
| T10 | `service/test/.../TypeListSpec.hs` → `listEntityTypes 回傳註冊表全部型別且排序穩定` | 數量與 `types/registry/*.toml` 相同,依 `etsKey` 排序,連續呼叫結果相同 |
| T11 | `service/test/.../EntityReadSpec.hs` → `getEntity 帶出路徑與錨點,searchEntity 帶出片段` | 片段的 `evAnchor` 是 `Just`、主體是 `Nothing`;`evPath` 是 Vault 相對路徑;`searchEntity` 命中時 `shSnippet` 非空;`EntityFilter` 的四個欄位各自生效 |
| T12 | `service/test/.../EntityWriteSpec.hs` → `createEntity 落到註冊表指定的目錄,addFragment 遞增主體 revision` | `createEntity` 的 `evPath` 以 `characters/` 開頭;型別不在註冊表 → `UnknownType` 且不寫檔;`addFragment` 後 `getEntity` 主體的 `metaRevision` +1 |
| T13 | `service/test/.../EntityWriteSpec.hs` → `updateEntity 的樂觀鎖與 patch 語意` | 給錯 revision → `StoreFailed (StaleRevision ...)` 且檔案不變;`epSummary` 有值而 `epTags` 為 `Nothing` 時只有 summary 改變;`deleteEntity` 非 force 且被引用 → `StoreFailed (ReferencedBy ...)` |
| T14 | `service/test/.../LinkSpec.hs` → `link 目標必須存在,跨 Vault 被擋,linksOf 雙向` | 指向不存在的 id → `DanglingLinkTarget` 且不寫檔;`Ref (Just "other") i` → `CrossVaultUnsupported`;A→B 加一條後,A 的 `lrOutgoing` 與 B 的 `lrIncoming` 各含一筆 |
| T15 | `service/test/.../LevelSpec.hs` → `getLevel 回合法的樹,addNode 反映在樹上` | `createLevel` 後 `lvTree` 只有根節點;`addNode` 到根之下後樹多一個子節點且 `nodOrder` 正確;手工把 Level 檔改成兩個根 → `getLevel` 回 `LevelTreeInvalid` 而非崩潰 |
| T16 | `service/test/.../FacadeSpec.hs` → `只 import StoryFlow.Service 即可完成一輪增查改刪` | 測試檔只有一行 `import StoryFlow.Service`,跑完 create → get → update → delete 全綠 |
| T17 | `service/test/.../EndToEndSpec.hs` → `純 service 從零建出琳達與教室` | 臨時 Vault → `createVault` → 建主體與兩個片段、建 Level 與六個 Node、掛上 `involves` 關聯 → `getLevel` 的樹形狀與 architecture.md 的圖相符 → `reindex` 後全部查詢結果不變 |

### 實作備註

(撰寫時留空)
