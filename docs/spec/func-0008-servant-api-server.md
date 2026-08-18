---
id: func-0008
type: spec
title: servant-api-server
description: servant REST API、OpenAPI 文件與 CLI 的遠端模式
status: done
created: 2026-08-16
updated: 2026-08-18
depends-on: [func-0002, func-0004, func-0005, func-0006, func-0007]
related-adr: [adr-0002, adr-0003, adr-0006, adr-0008]
related-spec: []
---

## servant REST API 與遠端模式 功能規格

### 功能概述

P3 的完成標準是**「claude code 只靠 API 文件就能建/查片段與關聯」**。這需要三件東西一起到位:
一組覆蓋 `service` 全部操作的 REST API、一份從型別自動推導的 OpenAPI 文件、以及 ADR-0006
承諾的 CLI `--remote`。三者共用同一份 servant API 型別——這正是 ADR-0006 選 servant 的理由:
**同一個型別同時產生 server、client 與文件,三邊無法悄悄長歪**。

因此本 spec 交付三個東西,而不是一個:

1. `storyflow-api` —— **只有** servant API 型別與 schema 實例的薄套件
2. `storyflow-server` —— servant handler + warp,綁 loopback
3. `storyflow-cli` 的 `--remote <url>` —— func-0007 刻意留下的另一半

**為什麼 API 型別要獨立成一個套件**:`cli --remote` 需要 API 型別去產生 `servant-client`。
若型別住在 `storyflow-server` 裡,CLI 就得依賴 server,連帶把 `warp` 與 `servant-server`
拖進一個預設根本不開伺服器的執行檔。獨立成 `storyflow-api` 後,server 與 cli 各自依賴它,
誰也不必知道對方存在——architecture.md 架構圖裡 server 與 cli 平行的關係因此得以維持。
這是本 spec 對 architecture.md 的唯一結構性新增。

驗收標準:

1. servant API 覆蓋 func-0006 `ServiceM` 的**每一個**操作,沒有只有 CLI 做得到的事
2. `story-flow serve --openapi` 輸出的 OpenAPI 3 文件,能讓一個沒讀過原始碼的人
   (或 Agent)完成「建一個 Entity、查它、掛一條關聯」
3. handler 內**沒有業務判斷**:每個 handler 都是「轉換請求 → `runService` → 對應狀態碼」
   三行結構,`storyflow-server` 不 import `storyflow-store`
4. `story-flow --remote <url> entity list` 與不帶 `--remote` 的同一個指令,**輸出完全相同**
5. 預設綁 `127.0.0.1`;綁非 loopback 位址時必須明確加旗標、必須設定 token、且印出警告

### 相依性

`depends-on: [func-0002, func-0004, func-0005, func-0006, func-0007]`。

- **func-0006**:API 的每一條路由都對應一個 `ServiceM` 函式;請求與 View 型別、`ServiceError`、
  `errorCode` 全部來自它。**尚未開工**,是主要阻塞來源
- **func-0007**:本 spec 要在它交付的 CLI 上長出 `--remote`——`GlobalOpts` 加欄位、
  `runCli` 的分派多一條路徑、`Command` 的每個建構子多一個遠端執行路徑。沒有那份 CLI
  就沒有東西可以改
- **func-0005**:狀態碼對照表**逐個列舉** `StoreError` 的建構子,其中 `ReferencedBy` /
  `NotAFileMain` / `NotAFragment` / `CannotRemoveRootNode` / `NodeDepthExceeded` /
  `FileAlreadyExists` / `TreeInvalid` 都是它新增的。server 不 import `storyflow-store`
  (驗收標準 3),但它必須**認得**這些建構子才能分派狀態碼——透過 `StoreFailed` 包在
  `ServiceError` 裡看到它們
- **func-0004**:`EntityFilter` 是查詢路由的 query parameter 來源;`StoreError` 的其餘建構子
- **func-0002**:核心型別與它們的 aeson 實例;OpenAPI 要為同一批型別補 `ToSchema`

**沒有相依 func-0003**:與 func-0007 同理,server 在 `service` 之後,碰不到 md。

**可否平行開發**:不能與 func-0007 平行——`--remote` 是長在它上面的。與 func-0006 更不能。
本 spec 是 0005 → 0006 → 0007 → 0008 這條鏈的最後一環。

若要縮短關鍵路徑,可行的切法是把本 spec 的第 1 部分(`storyflow-api` 型別)提前到
func-0007 完成前開工——它只依賴 func-0006 的型別。但 `--remote` 那一段仍然要等。

### 實作方式

#### 一、`storyflow-api`:只有型別

`build-depends`:`base` / `text` / `servant` / `openapi3` / `servant-openapi3` /
`storyflow-core` / `storyflow-service`。**沒有** `servant-server`、`servant-client`、`warp`
——那是兩個消費端各自的事。

路由設計。名詞複數、REST 慣例,與 CLI 的名詞-動詞一一對應:

```text
GET    /vaults                          → [VaultView]
POST   /vaults                          {root, name}          → VaultView
GET    /vault                           → VaultView            (目前 Vault)
POST   /vault/index/rebuild             → IndexReport
POST   /vault/index/refresh             → IndexReport
GET    /types                           → [EntityTypeSpec]

GET    /entities        ?type&status&tag&limit                → [Meta]
POST   /entities        NewEntityReq                          → EntityView
GET    /entities/:id                                          → EntityView
PATCH  /entities/:id    ?revision  EntityPatch                → EntityView
PUT    /entities/:id/body  ?revision  {body}                  → EntityView
DELETE /entities/:id    ?revision&force                       → DeleteReport
POST   /entities/:id/fragments  NewFragmentReq                → EntityView   (無 revision,見實作備註 4)
GET    /entities/:id/links                                    → LinkReport
POST   /entities/:id/links      ?revision  Link               → EntityView
DELETE /entities/:id/links      ?revision&kind&target         → EntityView

GET    /search          ?q&type&status&tag&limit              → [SearchHit]

GET    /levels          ?status&limit                         → [Meta]
POST   /levels          NewLevelReq                           → LevelView
GET    /levels/:id                                            → LevelView
DELETE /levels/:id      ?revision&force                       → DeleteReport
POST   /nodes/:id       ?levelId&revision  NewNodeReq         → LevelView   (:id 是父節點)
DELETE /nodes/:id       ?levelId&revision&force               → LevelView
```

> 兩條 node 路由的 capture 同名(實作備註 5),並多一個必填的 `levelId` ——service 的
> `addNode` / `removeNode` 都要 Level 的 id,而 REST 路徑上只有節點。

`revision` 是 **query parameter 而且必填**(servant 的 `QueryParam' '[Required]`),不是
選配。理由與 func-0006 相同:ADR-0006 明列樂觀鎖在兩種模式下都要生效,而遠端模式恰恰是
多客戶端並發真的會發生的那一種。CLI 遠端模式的「先讀再寫」由 CLI 自己補,server 不提供
逃生口。

`DELETE /entities/:id/links` 以 query parameter 帶 `kind` 與 `target` 而不是 request body:
HTTP 的 DELETE 帶 body 在中介軟體與 client 函式庫之間的支援度不一致,而這兩個值都很短。

`GET /vaults` 與 `POST /vaults` 在**沒有目前 Vault 的情況下**也要能跑(它們對應 func-0006
不需要 `Env` 的那兩個函式),因此 server 的 `Env` 是**延遲取得**的,不是啟動時就必須成功。

`ToSchema` 實例與 aeson 實例放在一起同一個模組定義,並在測試裡斷言兩者的欄位名一致——
`ToJSON` 與 `ToSchema` 分開手寫是 OpenAPI 文件說謊最常見的來源。

#### 二、`storyflow-server`:handler 與並發

handler 的形狀固定,寫成一個輔助函式,不讓任何一個 handler 有自己的想法:

```haskell
run1 :: MVar Env -> ServiceM a -> Handler a
run1 mv op = do
  r <- liftIO (withMVar mv (\env -> runService env op))
  either (throwError . toServerError) pure r
```

**`MVar Env`——所有請求序列化**。`sqlite-simple` 的 `Connection` 不保證多執行緒安全,而
warp 是多執行緒的。三種可能的解法裡:每請求開一條連線(每次都要重跑 schema 檢查與過時偵測)、
連線池(要處理 SQLite 的寫入鎖)、單一連線加互斥鎖——單人本機工具選第三個。它讓
「先寫檔、再更新索引」這條紀律在請求之間也是原子的,代價是吞吐量,而單人工作室的吞吐量
不是瓶頸。這個取捨要寫進 `storyflow-server` 的模組註解,別讓後人以為是疏忽。

`ServiceError` → HTTP 狀態碼:

| `ServiceError` | 狀態 | 理由 |
|---|---|---|
| `StoreFailed (EntityNotFound _)` / `VaultNotFound _` | 404 | 資源不存在 |
| `StoreFailed (StaleRevision ...)` | **409** | 樂觀鎖衝突,客戶端重讀後可重試 |
| `StoreFailed (ReferencedBy ...)` | **409** | 目前狀態不允許,加 `force` 可以 |
| `StoreFailed (VaultAlreadyExists _)` / `FileAlreadyExists _` | 409 | 同上 |
| `ValidationFailed` / `DanglingLinkTarget` | 422 | 語法對、語意不成立 |
| `UnknownType` / `StoreFailed (NotAFileMain _)` / `NotAFragment _` / `CannotRemoveRootNode _` / `NodeDepthExceeded ..` | 400 | 請求本身就錯 |
| `CrossVaultUnsupported` | **501** | 不是錯誤,是還沒做 |
| `StoreFailed (ParseFailed ..)` / `LevelTreeInvalid` / `StoreFailed (TreeInvalid ..)` | 500 | Vault 裡的資料壞了,不是客戶端的錯 |
| `RegistryUnavailable` / `RegistryLoadFailed` / `StoreFailed (SqliteError _)` | 500 | 伺服器設定或環境問題 |
| `StoreFailed (IndexUpdateFailed ..)` | **500** | 見下 |

`IndexUpdateFailed` 是唯一需要解釋的:**檔案已經寫成功了**,只有索引沒跟上(ADR-0002:
索引是衍生物)。回 2xx 會讓客戶端以為一切正常、繼續用過時的索引查詢;回 500 至少會讓它停下來。
訊息本身已經寫明「資料是安全的,執行 `story-flow index rebuild` 即可」,`errorCode` 是
`index_update_failed`——客戶端要區分「白寫了」與「寫了但索引壞了」,靠的是代碼不是狀態碼。

錯誤 body 一律:

```json
{"error": {"code": "stale_revision", "message": "寫入被拒絕:ent-7f3a 的 revision 是 4,……"}}
```

`code` 來自 func-0006 的 `errorCode`,與 CLI `--json` 用的**是同一個函式**。這是三種介面
錯誤語彙一致的唯一保證。

#### 三、繫結與認證

```text
story-flow-serve [--port <n>] [--bind <位址>] [--vault <名稱>] [--openapi]
```

> 指令名從 `story-flow serve` 改成獨立執行檔 `story-flow-serve`,理由見實作備註 1。

- 預設 `--bind 127.0.0.1`、`--port 8787`
- `--openapi`:不啟動伺服器,把 OpenAPI 3 文件印到 stdout 後結束。這讓
  `story-flow serve --openapi > openapi.json` 成為給 Agent 的一步驟交付
- **Token**:`STORYFLOW_TOKEN` 環境變數或 Vault 設定裡的 `token` 有值時,啟用
  `Authorization: Bearer <token>` 驗證;沒有就不驗證
- **綁非 loopback 時強制要求 token**:沒設就拒絕啟動並說明原因,不是印個警告了事。
  ADR-0006 只要求「明確加旗標並顯示警告」,本 spec 收得更緊——警告會被忽略,而
  「整個 Vault 暴露在區域網路上」不是可以靠使用者留意來緩解的事。啟動時仍然印出
  綁定位址的警告

token 比較用**定時比較**(逐位元組 XOR 累加後判零),不用 `==`:短路比較會洩漏前綴長度。
這是幾行的事,沒有理由不做。

servant 的認證以 `AuthProtect` 搭配一個 `Context`,未啟用時裝一個永遠放行的檢查器——
路由型別因此在兩種模式下相同,`servant-client` 那邊不必分兩套。

#### 四、CLI `--remote`

`GlobalOpts` 加 `goRemote :: Maybe Text`(base url)。`runCli` 的分派變成兩條路徑:

```haskell
data Backend
  = Embedded Env
  | Remote ClientEnv (Maybe Text)   -- token
```

每個 `Command` 各自有「內嵌怎麼跑」與「遠端怎麼跑」兩個實作,但**共用同一個渲染器**——
驗收標準 4(兩種模式輸出完全相同)是靠這一點達成的,不是靠對照測試碰運氣。兩條路徑
回的都是 func-0006 的 View 型別:內嵌路徑直接拿到,遠端路徑由 `servant-client` 依同一份
型別解碼出來。

**遠端模式的「先讀再寫」**:func-0007 的邏輯原樣適用,只是 `getEntity` 換成 HTTP GET。
`currentRevision` 因此要對 `Backend` 分派,不是只對 `ServiceM`。

`--remote` 與 `--vault` 同時出現時:`--vault` 送不過去(server 已經綁定了它自己的 Vault),
回一個明確的用法錯誤,不是靜默忽略。

`servant-client` 的連線錯誤(連不上、逾時、非 JSON 回應)不是 `ServiceError`,要另外對應到
CLI 的錯誤輸出,`code` 用 `remote_unavailable` / `remote_bad_response`。

### 使用到的既有串接介面

> 來源 spec 為 func-0006 / func-0007 的各列,原先是依那兩份 spec 的「新增的介面」約定填寫的。
> 實作時兩個套件都已經存在,逐條對照過原始碼——有出入的記在「實作備註」,
> 其中最重要的是 `parseId` 回 `(IdPrefix, Id)`、`addNode` / `removeNode` 多一個 Level 參數、
> 以及 `GlobalOpts` / `CliError` / `resolveEntity` 的實際形狀(func-0007 已經與規格不同)。

| 介面(含完整簽名) | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: Text, metaType :: Text, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Int, metaCreated :: Day, metaUpdated :: Day }` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | 清單路由的回應元素;要補 `ToSchema` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | func-0002 | `EntityView` 內層;要補 `ToSchema` |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `LevelView` 內層;要補 `ToSchema` |
| `data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | 同上 |
| `data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `LevelView` 的樹;`ToSchema` 是遞迴 schema,要顯式命名避免無限展開 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `POST /entities/:id/links` 的 body |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `DELETE .../links` 的 `target` query param |
| `parseId :: Text -> Either IdError Id` / `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `Id` 的 `FromHttpApiData` / `ToHttpApiData`(capture 段) |
| `parseRef :: Text -> Either IdError Ref` / `renderRef :: Ref -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `Ref` 的 `FromHttpApiData` / `ToHttpApiData` |
| `parseStatus :: Text -> Either MetaError Status` / `renderStatus :: Status -> Text` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `?status=` query param 的編解碼 |
| `parseLinkKind :: Text -> LinkKind` / `renderLinkKind :: LinkKind -> Text` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `?kind=` query param;**全函式,不會失敗** |
| `data EntityTypeSpec`(func-0005 擴充後含 `etsDir` / `etsOwnerType`) | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `GET /types` 的回應 |
| `ToJSON` / `FromJSON` 實例(`Id` / `Ref` / `Meta` / `Entity` / `Level` / `Node` / `Link` / `Status` / `Source` / `Timeline` / `NodeKind` / `LinkKind`) | `core/src/StoryFlow/Core/Json.hs` | func-0002 | 全部 body 的編解碼;`ToSchema` 必須與它們一致 |
| `data EntityFilter = EntityFilter { efType :: Maybe Text, efStatus :: Maybe Status, efTag :: Maybe Text, efLimit :: Maybe Int }` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 四個 query parameter 組成它 |
| `emptyFilter :: EntityFilter` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 沒帶 query parameter 時的預設 |
| `data StoreError = VaultNotFound Text \| VaultConfigInvalid FilePath Text \| VaultAlreadyExists FilePath \| EntityNotFound Id \| StaleRevision Id Int Int \| IdCollision IdPrefix \| FileReadFailed FilePath Text \| FileWriteFailed FilePath Text \| IndexUpdateFailed FilePath Text \| ParseFailed FilePath [MdError] \| SqliteError Text`(`renderStoreError :: StoreError -> Text`) | `store/src/StoryFlow/Store/Error.hs` | func-0004 | 狀態碼對照表要逐個建構子分派 |
| `StoreError` 的新建構子:`ReferencedBy Id [(Id, Link)]` / `NotAFileMain Id` / `NotAFragment Id` / `NodeDepthExceeded Id Int` / `CannotRemoveRootNode Id` / `LinkNotFound Id LinkKind Ref` / `FileAlreadyExists FilePath` / `TreeInvalid FilePath [TreeError]` / `RegistryDirUnknown Text` | `store/src/StoryFlow/Store/Error.hs` | func-0005 | 同上;它們各自對應到 409 / 400 / 500 |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | 啟動時建立 `MVar Env`;失敗時仍讓 `/vaults` 可用 |
| `closeEnv :: Env -> IO ()` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | 關機時釋放連線 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | `run1` 輔助函式的核心 |
| `data ServiceError`(`renderServiceError :: ServiceError -> Text`) | `service/src/StoryFlow/Service/Error.hs` | func-0006 | 錯誤 body 的 `message` 與狀態碼對照 |
| `errorCode :: ServiceError -> Text` | `service/src/StoryFlow/Service/Error.hs` | func-0006 | 錯誤 body 的 `code`,**與 CLI 用同一個函式** |
| func-0006 的全部業務函式(`createVault` / `listVaults` / `vaultInfo` / `reindex` / `refreshIndex` / `listEntityTypes` / `createEntity` / `addFragment` / `getEntity` / `listEntities` / `searchEntity` / `updateEntity` / `setEntityBody` / `deleteEntity` / `addLink` / `removeLink` / `linksOf` / `createLevel` / `getLevel` / `listLevels` / `deleteLevel` / `addNode` / `removeNode`) | `service/src/StoryFlow/Service.hs` | func-0006 | 每條路由各對應一個,handler 不做業務判斷 |
| `data EntityView` / `LevelView` / `VaultView` / `SearchHit` / `LinkReport` / `IndexReport` / `DeleteReport` | `service/src/StoryFlow/Service/Types.hs` | func-0006 | 回應型別;要補 `ToSchema` |
| `data NewEntityReq` / `NewFragmentReq` / `NewLevelReq` / `NewNodeReq` / `EntityPatch`(`emptyPatch`) | `service/src/StoryFlow/Service/Types.hs` | func-0006 | 請求 body 型別;要補 `ToSchema` |
| `ToJSON` / `FromJSON` 實例(上述 View 與請求型別) | `service/src/StoryFlow/Service/Json.hs` | func-0006 | body 編解碼;`servant-client` 解碼回同一批型別 |
| `runCli :: [String] -> IO ExitCode` | `cli/src/StoryFlow/Cli.hs` | func-0007 | **要擴充**:分派出遠端路徑 |
| `data GlobalOpts = GlobalOpts { goVault :: Maybe Text, goJson :: Bool }` | `cli/src/StoryFlow/Cli/Options.hs` | func-0007 | **要擴充**:加 `goRemote :: Maybe Text` |
| `data Command`(23 個建構子) | `cli/src/StoryFlow/Cli/Options.hs` | func-0007 | 每個建構子多一條遠端執行路徑 |
| `data Selector = SelById Id \| SelByTitle Text` | `cli/src/StoryFlow/Cli/Options.hs` | func-0007 | 標題定址在遠端模式改用 HTTP 清單查詢 |
| `resolveEntity :: Selector -> ServiceM (Either ResolveError Id)`(同 `resolveLevel` / `resolveNode`) | `cli/src/StoryFlow/Cli/Resolve.hs` | func-0007 | **要擴充**:改成對 `Backend` 分派而非只吃 `ServiceM` |
| `currentRevision :: Id -> ServiceM Int` | `cli/src/StoryFlow/Cli/Resolve.hs` | func-0007 | **要擴充**:同上,遠端模式走 HTTP GET |
| `data Envelope a = Ok a \| Err Text Text`(`ToJSON` 實例) | `cli/src/StoryFlow/Cli/Render.hs` | func-0007 | 兩種模式共用,連線錯誤也裝進它 |
| `renderEntity :: EntityView -> Text` / `renderMetaTable :: [Meta] -> Text` / `renderSearch :: [SearchHit] -> Text` / `renderLevelTree :: LevelView -> Text` / `renderLinks :: LinkReport -> Text` | `cli/src/StoryFlow/Cli/Render.hs` | func-0007 | **兩條路徑共用同一個渲染器**,這是驗收標準 4 的達成方式 |

### 新增的介面

#### `storyflow-api`(`StoryFlow.Api`)

```haskell
-- | 唯一的 API 契約。server、client、OpenAPI 三者都由它產生。
type StoryFlowAPI = VaultAPI :<|> EntityAPI :<|> LinkAPI :<|> LevelAPI :<|> NodeAPI :<|> MiscAPI

storyFlowAPI :: Proxy StoryFlowAPI

-- | OpenAPI 3 文件。story-flow serve --openapi 直接印它。
storyFlowOpenApi :: OpenApi
```

#### `storyflow-api`(`StoryFlow.Api.Instances`)

```haskell
-- FromHttpApiData / ToHttpApiData:capture 段與 query parameter 用
instance FromHttpApiData Id ; instance ToHttpApiData Id
instance FromHttpApiData Ref ; instance ToHttpApiData Ref
instance FromHttpApiData Status ; instance ToHttpApiData Status
instance FromHttpApiData LinkKind ; instance ToHttpApiData LinkKind

-- ToSchema:與 core / service 的 aeson 實例逐欄對齊(有測試守著)
instance ToSchema Id ; instance ToSchema Ref ; instance ToSchema Meta
instance ToSchema Entity ; instance ToSchema Level ; instance ToSchema Node
instance ToSchema NodeTree      -- 遞迴,顯式命名避免無限展開
instance ToSchema Link ; instance ToSchema Status ; instance ToSchema Source
instance ToSchema Timeline ; instance ToSchema NodeKind ; instance ToSchema LinkKind
instance ToSchema EntityTypeSpec
instance ToSchema EntityView ; instance ToSchema LevelView ; instance ToSchema VaultView
instance ToSchema SearchHit ; instance ToSchema LinkReport ; instance ToSchema IndexReport
instance ToSchema DeleteReport
instance ToSchema NewEntityReq ; instance ToSchema NewFragmentReq
instance ToSchema NewLevelReq ; instance ToSchema NewNodeReq ; instance ToSchema EntityPatch
```

#### `storyflow-server`(`StoryFlow.Server`)

```haskell
data ServeOpts = ServeOpts
  { soPort  :: Int              -- 預設 8787
  , soBind  :: Text             -- 預設 "127.0.0.1"
  , soToken :: Maybe Text       -- STORYFLOW_TOKEN 或 Vault 設定
  , soVault :: Maybe Text
  }

-- | 啟動 warp。綁非 loopback 且沒有 token 時直接失敗,不只是警告。
runServer :: ServeOpts -> IO (Either Text ())

-- | 錯誤 body 是 {"error":{"code":...,"message":...}},code 來自 service 的 errorCode。
toServerError :: ServiceError -> ServerError

-- | 所有請求序列化。sqlite-simple 的 Connection 不保證多執行緒安全。
run1 :: MVar Env -> ServiceM a -> Handler a

-- | 定時比較,不用 (==):短路比較會洩漏 token 前綴長度。
constantTimeEq :: Text -> Text -> Bool

isLoopback :: Text -> Bool
```

#### `storyflow-cli`(擴充)

```haskell
data GlobalOpts = GlobalOpts
  { goVault  :: Maybe Text
  , goJson   :: Bool
  , goRemote :: Maybe Text      -- 新增:base url
  }

-- | 兩條執行路徑。分派落在「操作」層而不是「指令」層(實作備註 6),
--   token 掛在 ClientEnv 的 Manager 上而不是這裡(實作備註 3)。
data Backend = Embedded Env | Remote ClientEnv

-- | 開後端 → 用 → 關。內嵌模式順便帶出 openEnv 的索引警告。
withBackend :: GlobalOpts -> (Either CliError (Backend, [Text]) -> IO a) -> IO a

-- | 指令的執行環境;兩條路徑的失敗最後併進同一個 CliError。
type M = ExceptT CliError IO
runM :: M a -> IO (Either CliError a)

-- | 23 個操作各一個三行的分派函式,指令層因此看不見 Backend 的建構子。
getEntityB :: Backend -> Id -> M EntityView        -- 其餘 22 個同形狀
```

#### `storyflow-cli`(`StoryFlow.Cli.Error`,新模組)

```haskell
-- | 全部錯誤型別集中一處:ResolveError 在 Resolve、CliError 在 Render 的舊配置
--   在加入 RemoteError 之後會形成循環 import。
data CliError
  = CliService ServiceError | CliRemote RemoteError | CliResolve ResolveError
  | CliInput Text | CliUsage Text

-- | RemoteStatus 帶著伺服器自己回的 code 與 message,cliErrorCode 原樣用它們
--   ——這是驗收標準 4 在錯誤路徑上的實作(實作備註 7)。
data RemoteError = RemoteUnavailable Text | RemoteBadResponse Text | RemoteStatus Int Text Text

data Subject = SubEntity | SubLevel | SubNode
data ResolveError = NotFound Subject Text | Ambiguous Subject Text [Meta]

cliErrorCode    :: CliError -> Text
cliErrorMessage :: CliError -> Text
isUsageError    :: CliError -> Bool   -- 用法錯誤 exit 2,其餘 exit 1
```

### TodoList

- [x] T1: 建立 `api/storyflow-api.cabal` 與 `cabal.project` 項目;`build-depends` 明確不含 `servant-server` / `servant-client` / `warp`  `dep: -`
- [x] T2: `StoryFlow.Api.Instances`:`FromHttpApiData` / `ToHttpApiData` 四組  `dep: T1`
- [x] T3: `StoryFlow.Api.Instances`:全部 `ToSchema` 實例,`NodeTree` 的遞迴 schema 顯式命名  `dep: T2`
- [x] T4: `StoryFlow.Api`:`StoryFlowAPI` 型別與五個子 API,`revision` 為必填 query parameter  `dep: T2`
- [x] T5: `storyFlowOpenApi`:由 `storyFlowAPI` 推導,補上標題、版本與每條路由的說明  `dep: T3, T4`
- [x] T6: 建立 `server/storyflow-server.cabal` 與 `cabal.project` 項目;`build-depends` 明確不含 `storyflow-store`  `dep: T4`
- [x] T7: `toServerError`:`ServiceError` → 狀態碼與錯誤 body,`code` 取自 `errorCode`  `dep: T6`
- [x] T8: `run1` 與 `MVar Env`;`openEnv` 延遲取得,讓 `/vaults` 在沒有目前 Vault 時仍可用  `dep: T7`
- [x] T9: 全部 handler(每條路由一個,三行結構)  `dep: T8`
- [x] T10: 認證:`AuthProtect` 與 `constantTimeEq`,未啟用時裝永遠放行的檢查器  `dep: T9`
- [x] T11: `runServer` 與 `story-flow serve` 子指令:`--port` / `--bind` / `--openapi`,綁非 loopback 且無 token 時拒絕啟動  `dep: T10, T5`
- [x] T12: CLI:`goRemote` 選項、`Backend` / `CliError` / `RemoteError`、`withBackend`  `dep: T4`
- [x] T13: CLI:`resolveEntity` / `resolveLevel` / `resolveNode` / `currentRevision` 改成對 `Backend` 分派  `dep: T12`
- [x] T14: CLI:每個 `Command` 的遠端執行路徑,共用既有渲染器;`--remote` 與 `--vault` 併用時的用法錯誤  `dep: T13`
- [x] T15: 端到端:同一組指令分別以內嵌與遠端跑一遍,輸出逐字元比對  `dep: T11, T14`

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `api/test/.../CabalSpec.hs` → `API 套件不依賴任何實作端` | 讀 `storyflow-api.cabal`,斷言 `build-depends` 不含 `servant-server` / `servant-client` / `warp` / `storyflow-store` |
| T2 | `api/test/.../HttpDataSpec.hs` → `四組 HttpApiData round-trip` | `Id` / `Ref` / `Status` / `LinkKind` 各自 `parseUrlPiece . toUrlPiece == Right x`;`Ref` 含 vault 前綴時也成立;非法字串回 `Left` |
| T3 | `api/test/.../SchemaSpec.hs` → `ToSchema 的欄位名與 ToJSON 一致` | 對每個型別取樣本值,比對 `toJSON` 的鍵集合與該型別 schema 的 `properties` 鍵集合相等;`NodeTree` 的 schema 產生有限輸出(不遞迴爆炸) |
| T4 | `api/test/.../ApiSpec.hs` → `路由涵蓋 service 的全部操作且 revision 必填` | 列出 `StoryFlowAPI` 的全部端點,斷言數量與 func-0006 的操作清單相符;每個寫入端點的 `revision` 缺席時型別層即拒絕(以 `servant-client` 呼叫時無法省略,由編譯期證明) |
| T5 | `api/test/.../OpenApiSpec.hs` → `OpenAPI 文件完整且每條路由有說明` | `storyFlowOpenApi` 的 `paths` 數等於路由數;每個 operation 有非空 `summary`;文件可被 `openapi3` 重新解碼;含 `info.title` 與 `info.version` |
| T6 | `server/test/.../CabalSpec.hs` → `server 不依賴落地層` | `build-depends` 不含 `storyflow-store` / `sqlite-simple` / `direct-sqlite` |
| T7 | `server/test/.../ErrorMapSpec.hs` → `每個 ServiceError 都對到規格表的狀態碼` | 逐一比對對照表:`StaleRevision` → 409、`CrossVaultUnsupported` → 501、`IndexUpdateFailed` → 500;錯誤 body 可解碼且 `code` 等於 `errorCode` 的輸出 |
| T8 | `server/test/.../ConcurrencySpec.hs` → `並發寫入被序列化且沒有 Vault 時 /vaults 仍可用` | 對同一個 Entity 同時發 20 個 PATCH(各自先 GET 拿 revision),最終 revision 等於成功次數、沒有例外逸出;在非 Vault 目錄啟動後 `GET /vaults` 回 200 而 `GET /entities` 回 404 |
| T9 | `server/test/.../HandlerSpec.hs` → `每條路由端到端可用` | 以 `warp` 起臨時伺服器 + `servant-client`,對每條路由各跑一次成功案例,斷言狀態碼與回應型別;建立 → 查詢 → 修改 → 刪除的完整流程綠燈 |
| T10 | `server/test/.../AuthSpec.hs` → `token 驗證與定時比較` | 設 token 後無 header → 401、錯 token → 401、對 token → 200;未設 token 時無 header → 200;`constantTimeEq` 對等長不同字串回 `False`、對相同字串回 `True`、對不等長回 `False` |
| T11 | `server/test/.../ServeOptsSpec.hs` → `綁非 loopback 且無 token 時拒絕啟動` | `soBind = "0.0.0.0"` 且 `soToken = Nothing` → `runServer` 回 `Left` 且訊息說明要設 token;有 token 時成功;`--openapi` 不開 port 且 stdout 是合法 JSON;`isLoopback` 對 `127.0.0.1` / `::1` / `localhost` 回 `True` |
| T12 | `cli/test/.../RemoteOptSpec.hs` → `--remote 解析與併用檢查` | `--remote http://127.0.0.1:8787` 進 `goRemote`;`--remote` 與 `--vault` 併用 → `CliUsage` 且 exit 2;連不上時 `code` 是 `remote_unavailable` |
| T13 | `cli/test/.../RemoteResolveSpec.hs` → `遠端模式的標題定址與先讀再寫` | 對真實伺服器以標題定址成功;兩筆同名 → `Ambiguous` 且候選與內嵌模式相同;不帶 `--revision` 的 `entity set` 在遠端模式也成功且 revision +1 |
| T14 | `cli/test/.../RemoteCmdSpec.hs` → `每個子指令的遠端路徑都可用` | 逐一在遠端模式跑過每個子指令,斷言 exit code 為 0 且 `--json` 的 `data` 可解碼 |
| T15 | `cli/test/.../ParitySpec.hs` → `內嵌與遠端輸出完全相同` | 同一個 Vault、同一串指令,分別以內嵌與遠端各跑一遍,兩邊的 stdout **逐字元相等**(人類模式與 `--json` 模式各驗一次);錯誤案例的 `code` 與 `message` 也相等 |

### 實作備註

#### 1. `story-flow serve` 改成獨立執行檔 `story-flow-serve`(已與開發者確認)

規格 T11 把 `serve` 寫成 CLI 的子指令,但那與 architecture.md 直接衝突:讓 `storyflow-api`
獨立成套件的**唯一理由**就是「CLI 的遠端模式需要 API 型別、但不需要 `servant-server` 與 `warp`
——一個預設根本不開伺服器的執行檔不該把整套 HTTP 伺服器拖進來」。CLI 要有 `serve`,就必須
依賴 `storyflow-server`,warp 隨即進來,那條理由當場失效。

依慣例「文檔衝突時以主架構為準」,並與開發者確認後,改為 `storyflow-server` 自己出一個
執行檔:

| 規格寫的 | 實際的 |
|---|---|
| `story-flow serve --openapi > openapi.json` | `story-flow-serve --openapi > openapi.json` |
| `story-flow serve --port 8787 --bind <位址>` | `story-flow-serve --port 8787 --bind <位址>` |

依賴關係因此與 architecture.md 的架構圖逐條相符:`storyflow-cli` → `api` + `service`(無
warp);`storyflow-server` → `api` + `service` + warp。CLI 的 `CabalSpec` 同時加強成
**只掃 `library` 與 `executable` 兩個 stanza**,並把 `storyflow-server` / `warp` /
`servant-server` 列進 forbidden ——測試套件為了跑對照而依賴 server 是合理的,但那條相依
不該把 library 的保護稀釋掉。

#### 2. 狀態碼分派走 `errorCode` 字串,不是 `StoreError` 的建構子

規格的對照表逐個列舉 `StoreError` 的建構子,但要對 `StoreFailed (StaleRevision …)` 做
pattern match,就得把那些建構子拉進作用域 —— 而 `StoryFlow.Service` 沒有重新匯出它們,
所以只能 `build-depends` 加 `storyflow-store`。那正是驗收標準 3 要擋的事。

改以 `errorCode` 的字串當分派鍵(`statusForCode :: Text -> ServerError`)。`errorCode` 本來
就是「穩定的機器可讀識別碼」,而且對 `StoreError` 的二十個建構子各給一個相異字串,拿到的
是同一份資訊、少一層相依,而且 CLI `--json` 的 `code` 與 HTTP 狀態碼從此由同一個函式決定。

代價是新增 `StoreError` 建構子時這裡不會編譯失敗,會靜靜落到預設的 500。`knownCodes` 與
T7 的最後一條測試補上那個保障。

#### 3. 認證改用 WAI middleware,不是 `AuthProtect`

規格寫「以 `AuthProtect` 搭配 `Context`,未啟用時裝永遠放行的檢查器——路由型別因此在兩種
模式下相同」。目標是對的,但 `AuthProtect` 達不到:它會出現在 `StoryFlowAPI` 的型別裡,
於是 `servant-client` 要多一個 `AuthClientData` 實例與 `AuthenticatedRequest` 包裝,OpenAPI
也會多一個安全定義。

middleware 把同一件事做得更徹底:**路由型別裡根本沒有認證**。server 端是一層
`bearerAuth :: Maybe Text -> Middleware`,client 端是 `managerModifyRequest` 加一個
`Authorization` header。認證是傳輸層的關切,本來就不屬於業務契約。`constantTimeEq` 照做。

#### 4. `POST /entities/:id/fragments` 沒有 `revision`

規格的路由表給了它 `?revision`,但 service 的 `addFragment` 在操作清單裡就沒有 `expected`
參數——加一個片段不覆蓋任何既有內容,所以它自己讀主體的 revision 再往下傳(並發保護仍然在,
store 會重讀檔案比對)。

收一個必填、卻不參與任何判斷的 `revision`,會讓客戶端以為自己拿到了樂觀鎖的保護,而它其實
什麼也沒做。**那比沒有更糟**,所以這條路由不收它。T4 的測試分成兩條:其餘八個寫入端點
`revision` 必填,這一條斷言它**沒有**。

#### 5. `POST /nodes/:parentId` 改名為 `POST /nodes/:id`

兩條 node 路由若一條 capture 叫 `parentId`、另一條叫 `id`,OpenAPI 會產出兩個 URL 模板相同、
只有參數名不同的 path item ——不少 codegen 工具會直接拒絕那個形狀。改成同名之後兩者合併成
一個 path item 的 `post` 與 `delete`,語意差異寫在各自的 `Summary` 裡。

另外 node 的兩條路由都多一個必填的 `levelId` query parameter:service 的 `addNode` /
`removeNode` 都要 Level 的 id(func-0007 實作備註 1 記錄過同一件事),而 REST 路徑上只有節點。

#### 6. `--remote` 的分派落在「操作」層,不是「指令」層

規格寫「每個 `Command` 各自有內嵌怎麼跑與遠端怎麼跑兩個實作」——那會有 21 組平行的程式碼
要對齊,而驗收標準 4 正是要它們不能有差。

實作改成每個 **service 操作**一個三行的分派函式(`StoryFlow.Cli.Backend` 的 `getEntityB`
等 23 個),指令層完全看不見 `Backend` 的兩個建構子:它只呼叫那些函式,拿到同一批 View 型別,
交給同一個渲染器。驗收標準 4 因此是**結構上成立**的,不是靠對照測試碰運氣(對照測試仍然有,
就是 T15)。

連帶的重構:`StoryFlow.Cli.Resolve` 從吃 `ServiceM` 改成吃 `Backend`,錯誤型別集中到新的
`StoryFlow.Cli.Error`(原本 `ResolveError` 在 Resolve、`CliError` 在 Render,加上
`RemoteError` 之後會形成循環 import)。func-0007 的 131 條測試在重構後全數通過,是這次改動
的回歸保護。

`Backend` 的 `Remote` 建構子只帶 `ClientEnv`,不帶 token(規格寫 `Remote ClientEnv (Maybe Text)`)
——token 掛在 `ClientEnv` 的 `Manager` 上,那是第 3 點的直接結果。

#### 7. 遠端模式的業務錯誤原樣沿用伺服器的 `code` 與 `message`

`RemoteError` 的 `RemoteStatus Int Text Text` 帶著伺服器回的 code 與 message,而
`cliErrorCode` / `cliErrorMessage` **原樣用它們、不重新分類**。伺服器那邊的錯誤 body 也是
`errorCode` / `renderServiceError` 產生的,所以
`story-flow --remote … entity show ent-00000000` 與不帶 `--remote` 的同一個指令,連錯誤訊息
都逐字元相同。這是驗收標準 4 在錯誤路徑上的實作。

只有真正的傳輸層失敗才有 CLI 自己的代碼:`remote_unavailable`(連不上)與
`remote_bad_response`(回的東西不是這個 API 的形狀)。

#### 8. 實作期間發現並修掉的一個缺陷

401 的 body 原本寫成 `ByteString` 字面值。`OverloadedStrings` 給 `ByteString` 的實例是
**逐字元截成 8 bit**,body 裡的繁中因此被切成不合法的 UTF-8、JSON 解不開,客戶端於是把
「token 錯了」誤報成「`--remote` 指到的不是 story-flow 的伺服器」——一個會把人帶去查錯方向的
訊息。改成走 aeson 的 `encode`,並在 server 的 `AuthSpec` 與 CLI 的 `RemoteOptSpec` 各加一條
測試釘住。

這個缺陷是拿真的執行檔跑端到端才發現的:單元測試裡 server 與 client 在同一個行程,
`codeOf` 讀得到的路徑與 CLI 的 `classify` 走的是不同的解碼點。

#### 9. 驗收結果

| 驗收標準 | 結果 |
|---|---|
| 1. API 覆蓋 `ServiceM` 的每一個操作 | ✅ 23 個 operation 對 23 個業務函式,`ApiSpec` 以一張獨立手寫的對照表比對路徑與方法 |
| 2. OpenAPI 文件足以讓沒讀過原始碼的人完成建立/查詢/掛關聯 | ✅ 14 條路徑、23 個 operation、31 個具名 schema,每個 operation 都有非空 `summary`;`story-flow-serve --openapi` 產出的檔案以 `JSON.parse` 驗過 |
| 3. handler 無業務判斷,server 不 import `storyflow-store` | ✅ 每個 handler 一行;`CabalSpec` 讀 .cabal 斷言不含落地層 |
| 4. `--remote` 與內嵌輸出完全相同 | ✅ `ParitySpec`:七條讀取指令的 stdout 與 `--json` 信封**逐字元相等**,五個錯誤案例的 code / message / exit code 也相等 |
| 5. 預設綁 loopback;綁非 loopback 必須設 token 且印警告 | ✅ 收得比 ADR-0006 更緊——沒 token 直接**拒絕啟動**;`ServeOptsSpec` 驗 `0.0.0.0` / 區網位址 / 空字串 token,並確認 warp 萬用字元不算 loopback |

測試:`cabal test all` 全綠。本 spec 新增 `storyflow-api-test` 51 條、`storyflow-server-test`
60 條,並把 `storyflow-cli-test` 從 131 條擴到 172 條;八個套件合計 912 examples / 0 failures。
全部 library 與 executable 在 `-Wall -Wcompat -Wincomplete-record-updates
-Wincomplete-uni-patterns` 下零警告。
