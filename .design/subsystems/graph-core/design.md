---
id: graph-core
type: subsystem
title: graph-core
description: 統一片段圖譜核心:型別、註冊表、兩種 Markdown 格式與可丟棄的索引
status: active
created: 2026-08-23
updated: 2026-08-23
parent: system
related-adr: [ADR-002, ADR-005, ADR-009, ADR-010, ADR-012, ADR-013, ADR-014, ADR-016, ADR-017, ADR-019, ADR-022]
code-paths: [core/src, types/src, types/registry, md/src, store/src]
---

# 片段圖譜核心(graph-core)子系統架構

## 定位與範圍

主架構「子系統劃分 › 地基 › `graph-core`」。這個子系統把**兩種 vault 的檔案**變成**一張**可查詢的
圖譜,並守住 ADR-013 那條線:檔案是真相,SQLite 是可以 `rm` 的衍生物。

涵蓋四個套件與一份資料:

| 元件 | 職責 | IO |
|---|---|---|
| `types/registry/*.toml` | 宣告式型別註冊表:entity 族與 asset 族的型別、命名文法詞彙 | 資料,非程式 |
| `aapms-core` | 統一 `Meta` 與全部節點型別、短 id、`Ref`、關聯詞彙、樹合法性、註冊表純驗證、命名文法、Manifest schema、全系統唯一的 aeson 編碼規則。**遊戲本體會 import 它**,零重量級相依 | **零 IO** |
| `aapms-types` | 讀 TOML、解析、錯誤彙整、三層定位(環境變數 → 執行檔旁 → `data-files`) | 唯一 IO 是讀檔 |
| `aapms-md` | 分節 Markdown ↔ 核心型別,四種文件(主題檔 / Level 檔 / pack.md / licenses.md)共用一個分節引擎;位元組保留的寫回 | 純函式 |
| `aapms-store` | vault marker、原子寫入、SQLite 索引建立與重建、FTS5 雙索引、樂觀鎖、單一與跨 vault 查詢 | 檔案 + SQLite |

**明確不做**:

- 任何業務判斷。「必填欄位缺了要不要擋」「關聯目標存不存在要不要拒絕」屬 `service`。本子系統只
  「說出發生了什麼」(回警告清單、回懸空引用清單),不決定怎麼辦
- vault **探測**與中樞註冊表。那是 `workspace`:它告訴本子系統「去開這個路徑」,本子系統不知道
  `--vault`、不讀 `%APPDATA%`
- 讀壓縮檔、算雜湊、產縮圖。那是 `asset-ingest`:它把算好的 `sha256` / `entry` / `meta` 交給
  本子系統寫進 pack.md 與索引
- 授權閘門的判斷(`project`)。本子系統只把 license 節點的八個維度存好、查得到

**與舊 `entity-graph-core` 的關係**:舊文檔(`.design/legacy/subsystems/entity-graph-core/`)是移植參考;它的
F002–F005 對應本文件的 #1 / #4 / #6 / #8,但全部要改接統一 `Meta`。本文件完成後舊資料夾刪除。

## 對外契約(Public Interface & DTOs)

消費者有兩個:`service`(全部介面)與 `asset-ingest`(只用純型別與「寫入」組的 pack 相關函式)。
`aapms-core` 另有一個特殊消費者——遊戲本體,它只 import Manifest 那一組。

### A. 純型別(`aapms-core`)

```haskell
-- 統一 Meta:所有節點共用(ADR-012)
data Meta = Meta
  { metaId       :: Id            -- <prefix>-<8 hex>
  , metaVault    :: VaultId       -- 所屬 vault 的 id
  , metaType     :: TypeKey       -- 註冊表鍵;level / asset-pack / asset-license 為保留鍵
  , metaTitle    :: Text
  , metaSummary  :: Text
  , metaTags     :: [Text]
  , metaStatus   :: Status        -- Draft | Canon | Deprecated | Missing
  , metaTimeline :: Maybe Timeline
  , metaAliases  :: [Text]
  , metaLinks    :: [Link]
  , metaSource   :: Source        -- human | agent:<name> | workshop:<type> | scan | ai:<model>
  , metaRevision :: Revision
  , metaCreated  :: Day
  , metaUpdated  :: Day
  }

-- 具名純量一律 newtype(2026-08-23 批次澄清):建構子匯出;LogicalName 只經 mkLogicalName 取得
newtype VaultId     = VaultId Text
newtype TypeKey     = TypeKey Text
newtype Sha256      = Sha256 Text
newtype LogicalName = LogicalName Text
newtype Revision    = Revision Int

-- pack 的 AI 揭露(沿用 assetdb):文字表示 unknown / none / assisted / generated;缺漏為 unknown
data AiDisclosure = AiUnknown | AiNone | AiAssisted | AiGenerated

data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }
data Ref  = Ref  { refVault :: Maybe VaultId, refId :: Id }     -- 寫成 id 或 <vault>:<id>
data LinkKind = Contradicts | Supersedes | DerivedFrom | PartOf | Involves | OccursIn
              | References | ConvergesTo | Uses | Depicts | Custom Text

data IdPrefix = PEnt | PAst | PPck | PLic | PLvl | PNod | PVlt | PPrj

-- 節點型別:Meta + 專屬欄位
data Entity  = Entity  { entMeta :: Meta, entBody :: Text }
data Asset   = Asset   { astMeta :: Meta, astName :: Maybe LogicalName, astSha256 :: Sha256
                       , astEntry :: Text, astExt :: Maybe Text, astKindMeta :: Value
                       , astLicense :: Maybe Ref, astAuthor :: Maybe Text, astBody :: Text }
data Pack    = Pack    { pckMeta :: Meta, pckVendor :: Maybe Text, pckArchive :: Maybe FilePath
                       , pckSha256 :: Maybe Sha256, pckLicense :: Maybe Ref, pckAuthor :: Maybe Author
                       , pckSourceUrl :: Maybe Text, pckAiDisclosure :: AiDisclosure, pckBody :: Text }
data Author  = Author  { authorName :: Text, authorUrl :: Maybe Text, authorContact :: Maybe Text }
data License = License { licMeta :: Meta, licCommercial :: Bool, licAttributionRequired :: Bool
                       , licCreditText :: Maybe Text, licModificationAllowed :: Maybe Bool
                       , licRedistributionAllowed :: Maybe Bool, licResaleAllowed :: Maybe Bool
                       , licNftAllowed :: Maybe Bool, licSourceUrl :: Maybe Text, licFullText :: Maybe Text }
data Level   = Level   { lvlMeta :: Meta, lvlRoot :: Id }
data Node    = Node    { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int
                       , nodKind :: NodeKind, nodEntities :: [Ref] }
data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }

-- 任一節點的統一視角:service 與 store 對「不知道是哪種節點」的情境用它
data AnyNode = NEntity Entity | NAsset Asset | NPack Pack | NLicense License | NLevel Level | NNode Node
anyMeta :: AnyNode -> Meta
```

`pckArchive = Nothing` 表示散檔目錄(`studio/`、`reference/<topic>/`),此時各 asset 的 `astEntry`
是相對該目錄的路徑。`astKindMeta` 是 kind 專屬 JSON,`aapms-core` 提供型別化讀取
(`imageMeta :: Value -> Maybe ImageMeta` 等),不開新表、不開新欄位。

### B. 純函式(`aapms-core`)

```haskell
-- id 與定址(ADR-014)
newId      :: IdPrefix -> Text -> UTCTime -> Int -> Id      -- 內容 + 時間 + salt;唯一性由 store 重試保證
parseId    :: Text -> Either IdError (IdPrefix, Id)
parseRef   :: Text -> Either IdError Ref
renderRef  :: Ref -> Text
prefixOf   :: AnyNode -> IdPrefix

-- 樹(Level 嚴格樹,ADR-004)
buildTree  :: Level -> [Node] -> Either [TreeError] NodeTree

-- 註冊表純驗證:只回警告,不決定怎麼辦
checkMeta  :: TypeRegistry -> AnyNode -> [MetaWarning]

-- 命名文法(ADR-019,詞彙來自註冊表)
data NameParts = NameParts
  { npKind    :: Segment          -- 封閉,必須在 nvKinds 內
  , npDomain  :: Segment          -- 開放受控,必須在 nvDomains 內
  , npSubject :: Segment
  , npVariant :: Maybe Segment    -- 開放,不查詞彙表
  , npState   :: Maybe Segment    -- 封閉,必須在 nvStates 內
  , npIndex   :: Maybe Int }      -- 尾端三位純數字,純語法判斷

mkLogicalName       :: NamingVocab -> NameParts -> Either NameError LogicalName
parseLogicalName    :: NamingVocab -> Text -> Either NameError NameParts
validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()   -- 第一段必須是該型別允許的 kind

-- Manifest(遊戲本體 import 的那一組)
data Manifest      -- assets/manifest.json, schemaVersion = 2;頂層含 assets + packs + licenses
data StoryManifest -- story/manifest.json
newtype AssetKey = AssetKey Text
manifestIndex :: Manifest -> Map AssetKey ManifestAsset
imageMeta :: Value -> Maybe ImageMeta        -- kind 專屬 meta 的型別化讀取
audioMeta :: Value -> Maybe AudioMeta
```

**manifest 的兩條定案**(2026-08-23 階段一閘門):

- **manifest 內部的引用一律 vault 化**:凡是「A 指向 B」的欄位都是 `Ref`(寫成 `<vault>:<id>`),不是裸短 id
  ——`ManifestAsset` 的 `pack` / `license`、頂層 `packs` / `licenses` 清單各項的 `id`、`ManifestPack` 的
  `license` 全都適用。短 id 只在單一 vault 內唯一,專案的素材未來可能來自兩個 vault;**引用端與被引用端
  必須同一種形狀**,否則比對時要剝掉 vault 前綴,剝完又回到會撞號的狀態(這是 2026-08-23 閘門的二輪補正)。
  節點**自身身分**的欄位不在此列:`ManifestAsset` 的 `id` 維持裸短 id,因為它另有一個並列的 `vault` 欄位
- `Manifest` 頂層帶 **`packs` / `licenses` 去重清單**,每筆 license 含八個授權維度。專案要能離開 vault
  獨立存在:P6 的授權閘門必須在專案資料夾內就判斷得出「這個專案能不能商用」,不回頭讀 vault;
  共用同一份 CC0 的數十個 pack 也不必各自重複八個欄位

### C. 註冊表(`aapms-types`)

```haskell
data Family   = FEntity | FAsset
data TypeDecl = TypeDecl
  { tdKey :: TypeKey, tdName :: Text, tdFamily :: Family
  , tdDir :: Maybe FilePath, tdOwnerType :: Maybe TypeKey        -- entity 族
  , tdAllowedLinks :: [LinkKind], tdStages :: [Text], tdFields :: [FieldDecl]
  , tdNameKinds :: [Segment] }                                    -- asset 族:命名文法第一段的合法值
data TypeRegistry
data NamingVocab = NamingVocab
  { nvKinds   :: [Segment]     -- 封閉:驅動格式處理器與資料夾
  , nvDomains :: [Segment]     -- 開放受控:每加一種素材領域只改 naming.toml
  , nvStates  :: [Segment] }   -- 封閉:up / down / hover / pressed…;拆解時唯一要查的表

locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))
loadRegistry   :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
lookupType     :: TypeRegistry -> TypeKey -> Maybe TypeDecl
```

載入失敗讓程序失敗,**不退回空註冊表**。`asset-pack`、`asset-license`、`level` 是保留鍵,
註冊表出現它們是錯誤。

**命名文法的拆解規則**(2026-08-23 階段一閘門定案,取代 legacy assetdb 的兩張詞彙表)——由右往左,
只查 `nvStates` 一張表:① 尾端三位純數字是 `npIndex`(純語法,不查表)→ ② 再往左一段若在 `nvStates`
內就是 `npState` → ③ 剩下的一段是 `npVariant`(開放,不查表)→ ④ 還有更多段是錯誤。
變體天生開放(`01a` / `blue` / `attack-01` / `v2`),封閉清單列不完,legacy 那張 17 個變體詞的表因此退場。
**詞彙表全部住在 `types/registry/naming.toml`,程式碼裡不得有 `defaultVocab`**。
`nvStates` 改版會改變既有名稱的拆解結果:名稱字串本身(在 `pack.md`)是真相,拆解結果是衍生物,
詞彙表改版 bump `schema_version` 讓索引整庫重建(與 ADR-016 對切詞規則的處置一致)。

**套件歸屬**(2026-08-23 釐清,避免相依環):`Family` / `TypeDecl` / `TypeRegistry` / `NamingVocab` /
`lookupType` 與純驗證錯誤是**純型別,定義在 `aapms-core`**(與「內部模組劃分」的「Registry 純驗證」一致,
`checkMeta` 才能吃它們);`aapms-types` 只有 `locateRegistry` / `loadRegistry` 兩個 IO 入口與 TOML 解析,
並 re-export 上述型別。`aapms-types → aapms-core` 單向。

### D. Markdown(`aapms-md`)

```haskell
data DocKind = TopicDoc | LevelDoc | PackDoc | LicenseDoc     -- 由檔案層 frontmatter 的 type 判別
data Document                                                  -- 保留原始位元組的分節結構

parseDocument :: Text -> Either MdError Document
docKind       :: Document -> DocKind

-- 解析方向:Document → 核心型別(節層繼承已套用)
toTopic    :: Document -> Either MdError (Entity, [Entity])     -- 主體 + 片段
toLevel    :: Document -> Either MdError (Level, [Node])
toPack     :: Document -> Either MdError (Pack, [Asset])
toLicenses :: Document -> Either MdError [License]

-- 寫回方向:只重新序列化被改的區塊(ADR-010)
renderDocument    :: Document -> Text
updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document
overrideAt        :: Id -> Document -> Either MdError MetaOverride   -- 讀出某節目前的 override(store 樂觀鎖比對用)
updateSection     :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document
updateSectionBody :: Id -> Text -> Document -> Either MdError Document
appendSection     :: NewSection -> Document -> Either MdError Document
-- NewSection 的 payload 對節點種類做 sum(2026-08-24 裁決,見下方 G1)
data NewSection = NewSection
  { nsId :: Id, nsLevel :: Int, nsTitle :: Text, nsBody :: Text
  , nsPayload :: NewSectionPayload }
data NewSectionPayload
  = NSFragment MetaOverride          -- 主題檔的片段
  | NSAsset    MetaOverride NewAsset -- pack.md 的一筆 asset(專屬欄位在 NewAsset)
  | NSLicense  MetaOverride NewLicense -- licenses.md 的一種授權(八個維度)
  | NSNode     MetaOverride NewNode  -- Level 檔的一個節點
removeSection     :: Id -> Document -> Either MdError Document
newDocument       :: DocKind -> Meta -> Text -> Document
```

**G1 定案(2026-08-24)**:`NewSection` 原本只有 `nsMeta :: MetaOverride` 一個管道,而 `MetaOverride`
沒有 asset 的 `sha256` / `entry` / `ext` / `meta` / `license` / `author`,也沒有 license 的八個授權維度
——`appendSection` / `addSection` 因此寫不出能通過 `toPack` / `toLicenses` 驗證的完整新節。改成
**對節點種類做 sum**(`NewSectionPayload`,封閉建構子),與契約 A 的 `AnyNode`、`LinkKind` 同一個模式:
新增節點型別時編譯器會列出所有待處理處,`addSection` 也維持單一入口。
**不採**「把 asset / license 欄位塞進 `MetaOverride`」——那個型別是 md 與 store 共用的節層繼承 DTO,
污染它會動到 ADR-010 位元組保留所依賴的繼承規則。

`docKind` 只看檔案層 `type`:`level` → `LevelDoc`、`asset-pack` → `PackDoc`、`asset-license` → `LicenseDoc`、
其餘一律 `TopicDoc`(md 不認識註冊表)。`licenses.md` 的檔案層是**容器不是節點**:frontmatter 寫
`type: asset-license`,節層繼承它;每節一個 `lic-` 節點、`owner` 為空;檔案層不進 `nodes` 表
(`toLicenses` 因此只回 `[License]`)。

### E. 落地(`aapms-store`),全部 `IO (Either StoreError a)` 除非標明

```haskell
-- vault 把手:由 workspace 決定路徑,本子系統負責開
data VaultKind   = AssetVault | StoryVault
data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }
data VaultHandle                                              -- 含 marker、根目錄、索引連線、型別註冊表

readMarker  :: FilePath -> IO (Either StoreError VaultMarker)
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)   -- 寫 marker、建空索引
openVault   :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))  -- schema 不符重建、過時刷新
closeVault  :: VaultHandle -> IO ()

-- 索引維護
rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])
refreshStale :: VaultHandle -> IO (Either StoreError [IndexIssue])
indexFile    :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])
unindexFile  :: VaultHandle -> FilePath -> IO (Either StoreError ())
```

**型別註冊表由 `VaultHandle` 攜帶**(2026-08-23 階段二裁決):`openVault` 收 `TypeRegistry` 並存進
handle,索引路徑因此叫得動 `checkMeta`(資料流管線「`aapms-core` 純驗證」那一段與 F006 契約卡的
「`checkMeta` 的警告進 `IndexIssue`」都靠它)。**不採「各函式加參數」**——`openVault` 自己就要做
過時刷新,註冊表遲早得在 handle 裡,分次加只會讓簽名逐次長胖。註冊表載入失敗讓程序死在啟動階段
(契約 C),`openVault` 收得到它代表這個順序被型別釘死。`initVaultAt` 只寫 marker 與空索引,不需要。

```haskell

-- 單一 vault 查詢(IO,不會失敗的回 Maybe / [])
lookupNode   :: VaultHandle -> Id -> IO (Maybe AnyNode)
lookupByName :: VaultHandle -> LogicalName -> IO (Maybe Asset)
listNodes    :: VaultHandle -> NodeFilter -> IO [Meta]
childrenOf   :: VaultHandle -> Id -> IO [Meta]                -- 包含關係:主題檔的片段、pack 的 asset
linksFrom    :: VaultHandle -> Id -> IO [Link]
linksTo      :: VaultHandle -> Ref -> IO [(Meta, Link)]
loadLinkGraph :: VaultHandle -> IO LinkGraph                  -- conflict 第 1 層用
search       :: VaultHandle -> SearchQuery -> IO SearchResult

-- 跨 vault 讀(ADR-017):呼叫端給把手集合,本子系統負責 ATTACH
data VaultSet
openVaultSet   :: [VaultHandle] -> IO (Either StoreError VaultSet)   -- 超過 ATTACH 上限回 TooManyVaults
lookupRef      :: VaultSet -> VaultId -> Ref -> IO (Maybe (VaultId, AnyNode))   -- 第二個參數:不帶 vault 的 Ref 的預設 vault
listAcross     :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]
searchAcross   :: VaultSet -> SearchQuery -> IO SearchResult  -- 每筆帶 vault
checkReferences :: VaultSet -> VaultHandle -> IO [DanglingRef] -- 本 vault 指出去的懸空引用

-- 寫入:先寫檔、再更新索引;全部經原子寫入與樂觀鎖
createTopicFile   :: VaultHandle -> TypeRegistry -> NewEntity  -> IO (Either StoreError CreateResult)
createLevelFile   :: VaultHandle -> TypeRegistry -> NewLevel   -> IO (Either StoreError CreateResult)
createPackFile    :: VaultHandle -> NewPack -> [NewAsset]      -> IO (Either StoreError CreateResult)
addSection        :: VaultHandle -> Id -> NewSection           -> IO (Either StoreError CreateResult) -- 片段 / asset / license / node,依 nsPayload 分派
writeMeta         :: VaultHandle -> Id -> Revision -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)
writeAssetFields  :: VaultHandle -> Id -> Revision -> AssetPatch -> IO (Either StoreError WriteResult)
writeBody         :: VaultHandle -> Id -> Revision -> Text      -> IO (Either StoreError WriteResult)
addLink / removeLink :: VaultHandle -> Id -> Revision -> Link   -> IO (Either StoreError WriteResult)
upsertLicense     :: VaultHandle -> License                     -> IO (Either StoreError WriteResult)
deleteNode        :: VaultHandle -> Id -> Revision -> DeleteMode -> IO (Either StoreError DeleteResult)
allocateId        :: VaultHandle -> IdPrefix -> Text -> IO Id   -- salt 遞增重試直到不撞
```

### F. 查詢 DTO

```haskell
data NodeFilter = NodeFilter
  { nfPrefixes :: [IdPrefix], nfTypes :: [TypeKey], nfStatus :: [Status], nfTags :: [Text]
  , nfOwner :: Maybe Id, nfLicense :: Maybe Ref, nfNamedOnly :: Bool, nfIncludeReference :: Bool
  , nfLimit :: Int, nfOffset :: Int }

data SearchQuery  = SearchQuery { sqText :: Maybe Text, sqFilter :: NodeFilter, sqFacets :: Bool }
data SearchHit    = SearchHit { shVault :: VaultId, shMeta :: Meta, shSnippet :: Text, shScore :: Double }
data FacetCounts  = FacetCounts { fcTypes, fcVaults, fcTags, fcOwners, fcLicenses :: [(Text, Int)] }
data SearchResult = SearchResult { srHits :: [SearchHit], srTotal :: Int, srFacets :: Maybe FacetCounts }
```

`shScore` 是 `Double`,不是 `Maybe Double`:兩條 FTS 路徑都給 bm25(ADR-016)。
`nfIncludeReference` 預設 `False`——找 GUI 框時不該跳出參考資料夾的廟宇照片;「是 reference」由
**pack.md 的路徑**決定(在 `library/reference/` 之下),索引時算好存進 `packs` 表,不靠人填欄位或 tag。
`nfStatus = []` 表示**全部但排除 `missing`**(draft / canon / deprecated 都回);要看 missing 明寫 `[Missing]`。

### G. 錯誤契約

`StoreError` / `MdError` / `RegistryError` / `IdError` / `NameError` 每個建構子都有對應的
`render*` 繁中訊息,**每一則說出下一步該做什麼**。上層(`service`)原樣包,不重寫。
跨 vault 的 `TooManyVaults` 必須列出當前數量與上限。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 | 套件 |
|---|---|---|
| `Meta` 與節點型別 | 契約 A 的型別、`Status` / `Source` / `LinkKind` 的文字表示(穩定小寫,進 DB 與 JSON 用同一份) | `aapms-core` |
| Id | 短 id 產生與解析、`Ref` 解析與渲染 | `aapms-core` |
| Tree | Level 嚴格樹的建構與合法性 | `aapms-core` |
| Registry 純驗證 | `checkMeta`:型別存在、欄位提示、關聯是否在 `allowed_links`、asset 名稱第一段是否在 `name_kinds` | `aapms-core` |
| Naming | 命名文法:分段、正規化、組合、驗證;詞彙由外部注入 | `aapms-core` |
| Manifest | 兩份 manifest 的型別與 JSON 編碼;`AssetKey`;kind 專屬 meta 型別化 | `aapms-core` |
| Json | 全系統唯一的 aeson 編碼規則 | `aapms-core` |
| Registry 載入 | TOML → `TypeRegistry` + `NamingVocab`,三層定位,錯誤彙整 | `aapms-types` |
| 分節引擎 | frontmatter + `{#id}` 標題 + ` ```meta ` 區塊 → `Document`;位元組保留 | `aapms-md` |
| 文件轉換 | `Document` ↔ 四種文件的核心型別;節層繼承規則 | `aapms-md` |
| Marker | `.aapms/config.toml` 讀寫 | `aapms-store` |
| Atomic | 原子寫入(暫存檔 + rename) | `aapms-store` |
| Schema | 索引表結構、`schema_version`、整庫重建 | `aapms-store` |
| Index | 檔案 → 索引:過時偵測、整檔替換、問題回報 | `aapms-store` |
| Tokenize | CJK unigram / bigram 預切、查詢路由判斷 | `aapms-store` |
| Query | 單一 vault 查詢、FTS 雙路徑與分數合併、facet | `aapms-store` |
| MultiVault | `VaultSet`:ATTACH、UNION、`Ref` 解析、懸空檢查 | `aapms-store` |
| Write | 建檔、增節、改寫、刪除、Node、License;樂觀鎖;`allocateId` | `aapms-store` |

## 資料流管線(Data Flow Pipeline)

三條管線,共用同一組型別;`aapms-core` 在每條裡都只做純計算。

**讀取(檔案 → 可查詢的圖譜)**

```text
workspace 給路徑 → openVault:讀 marker(id / kind)→ 開索引
  → schema_version 不符 → 整庫重建;否則 files 表比對 mtime / size 找出過時的檔
  → 對每個要讀的 .md:parseDocument → docKind 判別四種文件之一
  → toTopic / toLevel / toPack / toLicenses(節層繼承已套用)
  → aapms-core 純驗證:buildTree(Level)、checkMeta(每個節點,只產警告)
  → 整檔替換進索引:nodes + 專屬表 + links + 雙 FTS;owner 欄記包含關係
  → 查詢出口:lookupNode / listNodes / search(單 vault)或 VaultSet 的 *Across(跨 vault)
```

**寫入(請求 → 檔案 → 索引)**

```text
NewEntity / NewAsset / MetaOverride / AssetPatch(來自 service 或 asset-ingest)
  → allocateId(新節點)/ 讀回目標檔案比對 expected revision(樂觀鎖),不符即拒絕
  → aapms-md 寫回:updateSection / appendSection / updateFrontmatter,未改區塊逐字保留
  → 原子寫入(暫存檔 + rename)
  → indexFile:以 file_path 級聯刪除該檔舊記錄後整檔重建
  → 回傳 CreateResult / WriteResult(新 revision);索引失敗回 IndexUpdateFailed(檔案已落地)
```

順序固定是**先寫檔、再更新索引**;最壞情況是索引落後,`rebuildIndex` 修得好。

**跨 vault 讀(ADR-017)**

```text
workspace 解析出本次生效的 vault 集合 → service 逐一 openVault → openVaultSet
  → 一個讀連線 ATTACH 每個 vault 的索引(超過上限 → TooManyVaults,列出數量)
  → searchAcross / listAcross:UNION 各索引同名表,排序、分頁、facet 在 SQL 層完成
  → 每筆結果帶 VaultId;lookupRef 依 Ref 的 vault 欄位路由,缺省為呼叫端傳入的預設 vault
  → checkReferences:本 vault 所有 links 的目標逐一 lookupRef,找不到的回 DanglingRef
```

## 模組間公開介面(Module Interfaces)

| 呼叫方向 | 介面 |
|---|---|
| `aapms-types` → `aapms-core` | 解析完的 `TypeRegistry` 與 `NamingVocab` 交給 `checkMeta` / `validateLogicalName` |
| `aapms-md` ↔ `aapms-core` | `Document` ↔ `Entity` / `Level` / `Node` / `Pack` / `Asset` / `License`;`MetaOverride` 是 md 與 store 共用的「只改部分欄位」DTO |
| `aapms-store` → `aapms-md` | 讀取管線呼叫 `parseDocument` + `to*`;寫入管線呼叫 `update*` / `append*` + `renderDocument` |
| `aapms-store` → `aapms-core` | `buildTree` / `checkMeta` / `parseId` / `parseRef` 驗證後才進索引;`newId` 配 salt 重試 |
| Index → Tokenize | 寫入 FTS 前把文字欄位預切成 unigram + bigram 字串 |
| Query → Tokenize | 依查詢字串長度與字元類別決定走 trigram、cjk 或兩者 |
| MultiVault → Query | `*Across` 以同一組 SQL 片段對 UNION 後的視圖執行 |

**索引結構**(內部落地細節,可丟棄,不是對外契約):

```text
meta_info(key PK, value)                         -- schema_version、vault_id、vault_kind、vault_name
files(path PK, mtime, size, doc_kind)            -- 過時偵測;外鍵級聯的根
nodes(id PK, prefix, type, title, summary, status, timeline, timeline_order, source,
      revision, created, updated, file_path, section_anchor, owner)
                                                 -- owner = 檔案層節點的 id(片段→主體、asset→pack)
node_aliases(node_id, alias)  node_tags(node_id, tag)
links(src, dst_vault, dst, kind, note, file_path)
assets(id PK→nodes, name UNIQUE, sha256, entry, ext, meta_json, license, author)
packs(id PK→nodes, vendor, archive, sha256, license, author_json, source_url, ai_disclosure,
      is_reference)                              -- is_reference 由 file_path 在 library/reference/ 下推得
licenses(id PK→nodes, commercial, attribution_required, credit_text, modification_allowed,
         redistribution_allowed, resale_allowed, nft_allowed, source_url)
levels(id PK→nodes, root)
tree_nodes(id PK→nodes, level_id, parent_id, order_idx, kind)  tree_node_entities(node_id, ref)
fts_tri(title, summary, body, aliases, tags, name)   -- FTS5 trigram
fts_cjk(title, summary, body, aliases, tags, name)   -- FTS5 unicode61,內容已預切
fts_map(rowid PK, node_id)
```

- 一張 `nodes` 表裝所有節點,專屬欄位各自一張表以 id 關聯:`search` 與 `listNodes` 對一張表工作,
  專屬欄位只在需要時 JOIN
- `owner` 讓包含關係是一個欄位:`childrenOf` 是一次索引查詢,asset 不必寫 `partOf`
- `assets.name UNIQUE` 在**單一 vault 內**由 SQLite 保證;跨 vault 的全域唯一由 `service` 在
  寫入前以 `VaultSet` 查 `lookupByName` 保證——索引不跨庫加約束
- `fts_tri` / `fts_cjk` 都不是 contentless:要 `snippet()`,也要能整批刪除單檔記錄
- `body` 進 FTS 但不進 `nodes`:正文只有檔案有
- `files.doc_kind` 讓 `rebuildIndex` 不必解析就知道哪些檔是 pack.md(asset vault 的大檔)

**節層繼承規則**(四種文件共用,差異只在一列):

| 欄位 | 主題檔 / Level 檔 | pack.md |
|---|---|---|
| `id` / `title` / `summary` / `aliases` / `links` / `revision` | 不繼承 | 不繼承 |
| `vault` / `status` / `timeline` / `source` / `created` / `updated` | 繼承 | 繼承 |
| `type` | 繼承(片段通常同型別) | **不繼承**,節必寫(asset 的型別一定不是 `asset-pack`) |
| `tags` | 聯集去重 | 聯集去重 |

## 使用的技術

沿用主架構。子系統特有的:

- **`direct-sqlite` `+fulltextsearch`**:兩張 FTS5 表都要它
- **`toml-reader`**:註冊表、`naming.toml`、vault marker;純 Haskell
- **`HsYAML` + `HsYAML-aeson`**:只用於解析方向;寫回的 `meta` 區塊序列化自己寫(固定欄位順序),
  這是 ADR-010 的前提
- **`Win32`**(僅 Windows):原子寫入的 rename 覆蓋
- `aapms-core` **禁止**依賴以上任何一個以及 `sqlite-simple` / `zip` / `JuicyPixels`——它是遊戲本體
  的相依面,由 `CabalSpec` 逐字斷言

## 架構圖

```text
                  ┌────────────────────────────────┐
   對外入口 ────► │ types/registry/*.toml          │  型別(entity 族 + asset 族)+ naming.toml
                  └───────────────┬────────────────┘
                                  │ 讀檔(唯一 IO)
                  ┌───────────────┴────────────────┐
                  │ aapms-types                    │  TOML → TypeRegistry + NamingVocab
                  │ locateRegistry(env / 旁 / data)│  失敗即失敗,不退回空註冊表
                  └───────────────┬────────────────┘
                                  │
   ┌──────────────────┐  ┌────────┴───────────────────────────┐
   │ aapms-md         │  │ aapms-core                 零 IO   │
   │                  │  │                                    │
   │ parseDocument ───┼─►│ Meta · Entity · Asset · Pack       │  ◄── 遊戲本體只 import 這裡
   │ to{Topic,Level,  │  │ License · Level · Node · AnyNode   │      (Manifest / AssetKey)
   │   Pack,Licenses} │  │ Id / Ref · buildTree · checkMeta   │
   │ update* ◄────────┼──┤ Naming(詞彙注入)· Manifest v2      │
   │ 位元組保留寫回    │  │ Json 編碼規則(唯一一份)            │
   └────────┬─────────┘  └────────┬───────────────────────────┘
            │ Document ↔ 型別      │ 純型別、純驗證
            └──────────┬──────────┘
   ┌───────────────────┴──────────────────────────────────────┐
   │ aapms-store                                              │
   │                                                          │
   │ Marker(.aapms/config.toml)  Atomic(暫存 + rename)       │
   │                                                          │
   │   ┌──────────────┐   ┌────────────────────────────────┐  │
   │   │ 檔案(真相)  │──►│ Index → Schema                  │  │  files 表 mtime/size
   │   │ 主題檔 Level │   │ nodes + 專屬表 + links          │  │  過時就整檔替換
   │   │ pack.md      │   │ fts_tri ◄─ Tokenize ─► fts_cjk │  │
   │   │ licenses.md  │   └───────────────┬────────────────┘  │
   │   └──────────────┘                   │                   │
   │   Write:樂觀鎖 → md 寫回 → Atomic → Index                │
   │                                      ▼                   │
   │   Query(單 vault)◄───────── MultiVault(VaultSet:ATTACH)│
   └──────────────────────────┬───────────────────────────────┘
                              │ VaultHandle / VaultSet / StoreError
                              ▼
              service(全部)· asset-ingest(型別 + pack 寫入)
```

## 開發階段

對應主架構 **P1**(全部)。P0 的契約測試(Markdown roundtrip、索引等價)在 P0 對舊程式碼立起來,
本子系統的每個 feature 都必須讓它們維持綠燈。內部里程碑即下方三個階段;階段二結束時
`rebuildIndex` 已能對兩種 vault 跑,階段三結束時主架構 P1 的三條交付判準全部可驗。

## 功能規劃

### 階段一:純層

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | core-unified-meta | 統一 `Meta`、`Asset` / `Pack` / `License` / `AnyNode` 型別、八種 id prefix、`Ref`、`uses` / `depicts`、aeson 編碼規則 | Meta 與節點型別、Id、Tree、Json | - | F001-core-unified-meta.md |
| 2 | registry-family-and-naming | 註冊表 `family`、asset 族八項、`naming.toml` 詞彙、`name_kinds`;命名文法改吃注入詞彙;`checkMeta` 涵蓋 asset | Registry 載入、Registry 純驗證、Naming | #1 | F002-registry-family-and-naming.md |
| 3 | manifest-schema-v2 | `Manifest` v2 與 `StoryManifest` 型別、JSON 編碼、`AssetKey`、kind 專屬 meta 型別化 | Manifest | #1, #2 | F003-manifest-schema-v2.md |

### 階段二:解析與落地

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 4 | md-unified-sections | 分節引擎改接統一 `Meta`;`PackDoc` / `LicenseDoc` 的解析與寫回;四種文件的繼承規則 | 分節引擎、文件轉換 | #1, #2 | F004-md-unified-sections.md |
| 5 | store-vault-handle | marker 讀寫、`initVaultAt` / `openVault` / `closeVault`,schema 不符重建、過時刷新 | Marker、Atomic、Schema | #1 | F005-store-vault-handle.md |
| 6 | store-unified-index | 一份 schema(`nodes` + 專屬表 + `owner`)、`files` 過時偵測、整檔替換、`rebuildIndex`、單 vault 查詢(不含 FTS) | Schema、Index、Query | #1, #4, #5 | F006-store-unified-index.md |

### 階段三:檢索與寫入

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 7 | store-fts-dual-index | `fts_tri` + `fts_cjk`、預切、查詢路由、bm25 合併、`search` 與 facet、`LIKE` 退場 | Tokenize、Query | #6 | - |
| 8 | store-write-operations | 建檔 / 增節 / 改寫 / 刪除 / Node / License 的寫入改接統一 `Meta`;`AssetPatch`;樂觀鎖;`allocateId` | Write | #4, #6 | - |
| 9 | store-multi-vault-read | `VaultSet`:ATTACH、`*Across`、`lookupRef`、`TooManyVaults`、`checkReferences` | MultiVault | #7 | - |

小結:共 **9 個 features、3 個階段**;全部完成即主架構 P1 交付:`rm index.db` → rebuild 兩種
vault 都等價、「藥水」搜得到、`aapms-core` 零重量級相依。

## Feature 契約卡

### core-unified-meta

- **階段**:階段一
- **負責模組**:Meta 與節點型別、Id、Tree、Json(`aapms-core`)
- **實作的 Level 2 介面**:契約 A 全部;契約 B 的 `newId` / `parseId` / `parseRef` / `renderRef` /
  `prefixOf` / `buildTree`;契約 G 的 `IdError`
- **資料流管線段落**:不走管線;它是三條管線共用的型別層
- **驗收標準**:六種節點共用同一個 `Meta` 型別;`Status` / `Source` / `LinkKind` 的 JSON 與文字表示
  是穩定小寫且只有一份;`parseRef` 接受 `ent-7f3b2a91` 與 `vlt-a0c4e1f8:ent-7f3b2a91` 兩種寫法;
  `newId` 對同一輸入不同 salt 產生不同 id;`buildTree` 拒絕成環、跳級、多重父節點;
  `aapms-core` 的 `build-depends` 不含任何 IO / SQLite / 壓縮 / 影像套件(`CabalSpec` 斷言)
- **明確不做**:不讀檔、不解析 Markdown、不碰註冊表載入;不定義命名文法(那是 #2);
  不定義 Manifest(#3)

### registry-family-and-naming

- **階段**:階段一
- **負責模組**:Registry 載入(`aapms-types`)、Registry 純驗證、Naming(`aapms-core`)
- **實作的 Level 2 介面**:契約 C 全部;契約 B 的 `checkMeta` / `mkLogicalName` / `parseLogicalName` /
  `validateLogicalName`;契約 G 的 `RegistryError` / `NameError`
- **資料流管線段落**:讀取管線的前置(註冊表載入)與「`aapms-core` 純驗證」一段
- **驗收標準**:`types/registry/` 含原五種 entity 族 + 八種 asset 族 + `naming.toml`;`asset-pack` /
  `asset-license` / `level` 出現在註冊表是載入錯誤;載入失敗程序失敗、不退回空註冊表;
  `checkMeta` 對 asset 檢查 `name` 第一段在該型別的 `name_kinds` 內、關聯在 `allowed_links` 內,
  只回警告;`validateLogicalName` 對 `ui_gui_travel-book-frame_001` 通過、對非 ASCII / 超過 64 字元 /
  少於三段拒絕;`defaultVocab` 與 DB `naming_vocab` 表都不存在
- **明確不做**:不決定警告要不要擋;不做叢集推論(`asset-ingest`);不改 `dir` / `owner_type` 語意

### manifest-schema-v2

- **階段**:階段一
- **負責模組**:Manifest(`aapms-core`)
- **實作的 Level 2 介面**:契約 B 的 `Manifest` / `StoryManifest` / `AssetKey` / `manifestIndex`,
  以及 `imageMeta` / `audioMeta` 型別化讀取
- **資料流管線段落**:不走管線;它是 `project` 產出與遊戲本體之間的契約,住在這裡是因為遊戲本體
  只能 import `aapms-core`
- **驗收標準**:`schemaVersion = 2`,每筆 asset 帶 `id`(短 id)/ `key`(邏輯名稱)/ `path` / `type` /
  `sha256` / `vault`(來源 vault id)/ `pack` / `license`;`StoryManifest` 每筆帶 `ref`(`<vault>:<id>`)/
  `title` / `summary` / `purpose` / `revision`;`FromJSON` 對 `schemaVersion = 1` 回明確錯誤「請重新產生」
  而不是靜默解析;golden file roundtrip 測試
- **明確不做**:不產生 manifest(`project`);不產生 `Assets.hs`(`project`);不做授權判斷

### md-unified-sections

- **階段**:階段二
- **負責模組**:分節引擎、文件轉換(`aapms-md`)
- **實作的 Level 2 介面**:契約 D 全部;「模組間公開介面」的 `aapms-md` ↔ `aapms-core`(含 `MetaOverride`);
  契約 G 的 `MdError`
- **資料流管線段落**:讀取管線的「parseDocument → docKind → to*」一段;寫入管線的「md 寫回」一段
- **驗收標準**:四種文件 roundtrip(解析 → 寫回 → 再解析)不失真;未修改區塊位元組相同(P0 契約測試
  持續綠);繼承規則照本文件表格——pack.md 的節層 `type` 不繼承且缺漏是錯誤;
  `toPack` 把檔案層轉成 `Pack`、每節轉成 `Asset`;`toLicenses` 每節一個 `License`,八個維度缺漏為
  `Nothing` 而非錯誤(`commercial` 與 `attribution_required` 除外,缺漏是錯誤);`appendSection`
  在 1,693 節的文件末尾追加一節,前面 1,693 節位元組不變;`MdError` 指出行號
- **明確不做**:不碰檔案系統與索引;不驗證關聯目標;不算 sha256(`asset-ingest` 給)

### store-vault-handle

- **階段**:階段二
- **負責模組**:Marker、Atomic、Schema(`aapms-store`)
- **實作的 Level 2 介面**:契約 E 的 `VaultKind` / `VaultMarker` / `VaultHandle` / `readMarker` /
  `initVaultAt` / `openVault` / `closeVault`;契約 G 的 `StoreError` 骨架
- **資料流管線段落**:讀取管線的「openVault:讀 marker → 開索引 → schema 判斷」一段
- **驗收標準**:`initVaultAt` 寫出 `.aapms/config.toml`(含新發的 `vlt-` id 與 kind)與空索引;
  對已有 marker 的目錄再 `initVaultAt` 是錯誤;`openVault` 對 marker 損壞回指出欄位的錯誤,不自動
  建檔;`schema_version` 不符時整庫重建並在 `IndexIssue` 回報;原子寫入在 Windows 上能覆蓋既有檔案;
  沒有任何程式路徑讀 `%APPDATA%` 或向上探測——那是 `workspace`
- **明確不做**:不探測 vault、不讀中樞註冊表、不處理 `--vault`;不做 `migrate`(`workspace`);
  不建任何業務表(#6)

### store-unified-index

- **階段**:階段二
- **負責模組**:Schema、Index、Query(`aapms-store`)
- **實作的 Level 2 介面**:契約 E 的 `rebuildIndex` / `refreshStale` / `indexFile` / `unindexFile` /
  `lookupNode` / `lookupByName` / `listNodes` / `childrenOf` / `linksFrom` / `linksTo` / `loadLinkGraph`;
  契約 F 的 `NodeFilter`;「模組間公開介面」的索引結構(不含兩張 FTS 表)
- **資料流管線段落**:讀取管線從「files 表比對」到「整檔替換進索引」,以及查詢出口的非全文部分
- **驗收標準**:對 story vault 與 asset vault 各一個測試 fixture,`rebuildIndex` 兩次結果相同;
  `rm index.db` 後 `openVault` + `rebuildIndex` 與刪除前的 `listNodes` / `linksFrom` 結果相同
  (P0 契約測試);`childrenOf pck` 回該 pack 全部 asset、`childrenOf ent`(主體)回其片段;
  `files` 表以 mtime / size 偵測外部改動並只重讀那個檔;`checkMeta` 的警告與 `buildTree` 的錯誤
  進 `IndexIssue`,不中斷整批;單一 vault 內 `assets.name` 重複是 `IndexIssue` 錯誤;
  `pack.md` 條目為 `missing` 狀態的 asset 仍在索引、`listNodes` 預設不回
- **明確不做**:不建 FTS 表、不做全文檢索(#7);不做任何寫入(#8);不跨 vault(#9)

### store-fts-dual-index

- **階段**:階段三
- **負責模組**:Tokenize、Query(`aapms-store`)
- **實作的 Level 2 介面**:契約 E 的 `search`;契約 F 的 `SearchQuery` / `SearchHit` / `FacetCounts` /
  `SearchResult`;「模組間公開介面」的 Index → Tokenize、Query → Tokenize
- **資料流管線段落**:讀取管線「整檔替換進索引」的 FTS 寫入部分,與查詢出口的全文部分
- **驗收標準**:「藥水」「琳達」(二字詞)命中且 `shScore > 0`;「travel-book」命中;三字以上中文
  走 trigram 並有分數;同時含中英的查詢兩張表都查、結果以分數合併去重;`snippet` 回命中片段;
  `sqFacets = True` 時 `FacetCounts` 五個維度都有;`LIKE` 路徑在程式碼裡不存在;
  索引體積對 6,783 筆 asset 在可接受範圍(記錄數字,不設硬上限)——**這一條等 P2 真資料進場再驗**,
  P1 不合成大 fixture
- **明確不做**:不引入 ICU / jieba;不做自然語句查詢(`ai`);不做跨 vault(#9)

### store-write-operations

- **階段**:階段三
- **負責模組**:Write(`aapms-store`)
- **實作的 Level 2 介面**:契約 E 的 `createTopicFile` / `createLevelFile` / `createPackFile` /
  `addSection` / `writeMeta` / `writeAssetFields` / `writeBody` / `addLink` / `removeLink` /
  `upsertLicense` / `deleteNode` / `allocateId`
- **資料流管線段落**:寫入管線全段
- **驗收標準**:`createTopicFile` 依註冊表 `dir` 落檔;`createPackFile` 在指定目錄寫出 `pack.md`,
  節的順序與給定順序相同;`writeAssetFields` 只改 `name` / `license` / `author` / `tags` 這些
  人給欄位,**拒絕**改 `sha256` / `entry`(那是掃描器的事,要改走 `addSection` / `deleteNode`);
  所有寫入比對 `revision`,不符回 `RevisionMismatch` 且檔案未動;`allocateId` 在人為製造碰撞時
  以 salt 重試直到不撞;寫入後 `indexFile` 只重讀該檔;交易內無任何檔案 IO(寫鎖預算,ADR-022)
- **明確不做**:不做跨 vault 寫入;不決定業務規則(名稱全域唯一由 `service` 先查);不產縮圖、
  不算雜湊

### store-multi-vault-read

- **階段**:階段三
- **負責模組**:MultiVault(`aapms-store`)
- **實作的 Level 2 介面**:契約 E 的 `VaultSet` / `openVaultSet` / `lookupRef` / `listAcross` /
  `searchAcross` / `checkReferences`;契約 G 的 `TooManyVaults`;「模組間公開介面」的 MultiVault → Query
- **資料流管線段落**:跨 vault 讀管線全段
- **驗收標準**:兩個 fixture vault(一 story 一 asset)`searchAcross` 一次回兩種、每筆 `shVault` 正確;
  排序與分頁跨 vault 正確(不是各自排完再接);`lookupRef` 對不帶 vault 的 `Ref` 以呼叫端指定的
  預設 vault 解析;第 11 個 vault 回 `TooManyVaults` 並列出 10;`checkReferences` 找出指向不存在
  節點與不存在 vault 的兩種懸空;`VaultSet` 只開讀取,任何寫入函式不接受它
- **明確不做**:不決定「本次生效哪些 vault」(`workspace`);不做超過上限的分批查詢(Level 3 之後
  視需要開 E);不做跨 vault 寫入
