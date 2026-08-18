---
id: func-0007
type: spec
title: cli-embedded
description: story-flow 指令的內嵌模式,全指令支援統一信封的 --json
status: done
created: 2026-08-16
updated: 2026-08-18
depends-on: [func-0002, func-0004, func-0006]
related-adr: [adr-0005, adr-0006, adr-0008, adr-0009]
related-spec: []
---

## CLI 內嵌模式 功能規格

### 功能概述

`story-flow` 指令是 P2 的驗收面:**能純用 CLI 把「教室」場景與琳達的片段從零建起來**。
ADR-0006 的雙模式決策裡,本 spec 只做**內嵌**那一半——直接呼叫 `storyflow-service` 的
`ServiceM` 函式,不需要 daemon、啟動即用、堆疊追蹤完整。

`--remote` 那一半刻意留給 func-0008:它要走 `servant-client`,而 servant 的 API 型別在
func-0008 才定義。硬要在本 spec 先做,就得先發明一份 API 型別再讓 func-0008 去對齊它——
契約會有兩個定義處,正是 ADR-0006 要避免的事。architecture.md 的階段表也把
「CLI `--remote`」排在 P3。

這一層**不含任何業務判斷**。它只做四件事:解析引數、把引數轉成 service 的請求型別、
呼叫 service、把結果render 成文字或 JSON。任何「這樣做對不對」的判斷出現在 CLI 裡,就代表
它應該在 `service`。

驗收標準:

1. 只用 `story-flow` 指令,從 `vault init` 開始建出 architecture.md 範例的琳達
   (主體 + 兩個片段 + 關聯)與教室 Level(六個 Node 的樹),`level show` 印出的樹形狀
   與 architecture.md 的圖一致
2. 每一個子指令都支援 `--json`,且輸出通過同一個信封 schema 的檢查
3. `storyflow-cli.cabal` 的 `build-depends` **不含** `sqlite-simple` / `direct-sqlite` /
   `storyflow-store` —— CLI 碰不到落地層,只認得 `service`
4. 業務錯誤以非零 exit code 收尾,且 `--json` 模式下錯誤也是合法 JSON

### 相依性

`depends-on: [func-0002, func-0004, func-0006]`。

- **func-0006**(`storyflow-service`):唯一的業務入口。本 spec 的每個子指令都是對某個
  `ServiceM` 函式的包裝。(實作時 func-0006 已 `done`,阻塞解除)
- **func-0004**:`EntityFilter` 的四個欄位直接對應到 `--type` / `--status` / `--tag` /
  `--limit` 四個選項,CLI 自己組出它
- **func-0002**:`parseId` / `parseStatus` / `parseLinkKind` / `parseNodeKind` / `parseRef`
  是引數解析的驗證函式;`Meta` / `Entity` / `NodeTree` 是輸出渲染的對象

**沒有相依 func-0003 與 func-0005**:CLI 不 import `storyflow-md` 也不 import
`storyflow-store`。`MdWarning` 在 `EntityView` 裡已經被 service render 成 `Text`,CLI 拿到的
是字串;落地層的一切都在 `service` 後面。這不是巧合,是驗收標準 3 要守的界線。

**可否平行開發**:與 func-0008 **可以平行**——兩者各自包裝同一組 `ServiceM` 函式,互不相干。
唯一的接觸點是 func-0008 要回頭在本 spec 交付的 CLI 上加 `--remote`,那是 func-0008 的工作,
不構成本 spec 對它的相依。兩者都必須等 func-0006。

### 實作方式

#### 一、套件與進入點

新套件 `storyflow-cli`,一個 executable `story-flow`,一個 library(讓測試不必跑子行程)。
library 匯出 `runCli :: [String] -> IO ExitCode`,executable 就是
`main = getArgs >>= runCli >>= exitWith`。這讓全部子指令都能在 hspec 裡直接跑,不必
`readProcess`。

`build-depends`:`base` / `text` / `optparse-applicative` / `aeson` / `bytestring` /
`containers` / `directory` / `mtl` / `transformers` / `storyflow-core` / `storyflow-service`。
**沒有** `storyflow-store`、`storyflow-md`、`sqlite-simple`——驗收標準 3 就是靠這一行證明的。
(`mtl` 是為了 `catchError`,`transformers` 是為了 `ExceptT CliError ServiceM` ——定址與
輸入失敗由這一層帶,業務失敗由 `runService` 的 `Either` 帶,兩者在 `emit` 之前併成 `CliError`。)

#### 二、指令樹

名詞在前、動詞在後(`git remote add` / `docker image ls` 的形狀):同一個名詞的操作聚在一起,
`--help` 才讀得下去。

```text
story-flow [--vault <名稱>] [--json] <名詞> <動詞> ...

vault  init [<目錄>] --name <名稱>
       list
       info
index  rebuild
       refresh
type   list
entity new         --type <型別> --title <標題> [--summary <s>] [--body <t> | --body-file <f>]
                   [--tag <t>]... [--alias <a>]... [--status <s>] [--timeline <t>]
                   [--order <n>] [--source <s>] [--link <kind>:<target>[:<note>]]...
       add         <主體> --title <標題> [同上的片段欄位]
       show        <實體>
       list        [--type <t>] [--status <s>] [--tag <t>] [--limit <n>]
       set         <實體> [--title|--summary|--status|--timeline|--order|--source]
                   [--tag <t>]... [--alias <a>]... [--revision <n>]
       set-body    <實體> (--body <t> | --body-file <f> | -)
       rm          <實體> [--force] [--revision <n>]
search <關鍵詞> [--type] [--status] [--tag] [--limit]
link   add   <來源> --kind <關聯> --target <目標> [--note <n>] [--revision <n>]
       rm    <來源> --kind <關聯> --target <目標> [--revision <n>]
       list  <實體>
level  new   --title <標題> [--summary] [--body] --root-title <標題> --root-kind <kind>
       show  <Level>
       list  [--status] [--limit]
       rm    <Level> [--force] [--revision <n>]
node   add   <父節點> --title <標題> --kind <kind> [--summary] [--body]
             [--link <kind>:<target>]... [--revision <n>]
       rm    <節點> [--force] [--revision <n>]
```

`--type` 的合法值來自 `listEntityTypes`,**不寫死**在 optparse 的列舉裡(垂直切片 1:新增型別
不改程式)。作法是照收字串,由 service 的 `UnknownType` 負責擋;`--help` 的說明文字則提示
「以 `story-flow type list` 查看可用型別」——optparse 的 help 是在有 `Env` 之前就要組出來的,
拿不到註冊表。

`--tag` / `--alias` / `--link` 用 `many`,重複出現即累積。`--link` 的
`<kind>:<target>[:<note>]` 是一個緊湊格式,因為 `entity new` 常常要一次掛好幾條 `partOf`;
`:` 在 note 裡出現時只切前兩個。

`--kind` **沒有驗證步驟**:`parseLinkKind :: Text -> LinkKind` 是全函式,任何字串都是合法的
關聯(ADR-0005 明說自訂關聯合法,引擎當純標註儲存)。CLI 能做的只有**提示**——
`isCoreKind` 為 `False` 時,以 `suggestCoreKind` 找最接近的核心關聯,有結果就印
「`contradict` 不是核心關聯,你是不是要打 `contradicts`?已照原樣存為自訂關聯」到 stderr。
這是提示不是阻擋:打錯字與刻意自訂在字串層面無法區分,擋下來會擋到合法用法。

#### 三、實體定址:id 或標題都行

使用者記得住的是「琳達」,不是 `ent-7f3a`。所有吃 `<實體>` / `<Level>` / `<節點>` 的位置都
走同一個解析函式:

1. 引數符合 `<prefix>-<8 hex>` 的 id 格式(`parseId` 成功)→ 直接當 id 用
2. 否則當標題,以 `listEntities` / `listLevels` 的結果做**精確比對**(不做模糊比對——猜錯
   然後改到別的片段,比找不到糟得多)
3. 剛好一筆 → 用它;零筆 → 錯誤訊息附上「以 `story-flow entity list` 查看」;
   **多筆 → 錯誤並列出全部候選的 id、型別與 summary**,讓使用者改用 id 重下

Node 的標題重複率很高(「出場人物」會出現在每個場景),所以 `node` 的定址在多筆命中時
額外提示可以用 `story-flow level show <Level>` 取得節點 id。

#### 四、樂觀鎖:預設先讀再寫

service 的每個修改操作都要 expected revision(func-0006 刻意設成必填)。CLI 的填法:

- **不帶 `--revision`**:先呼叫對應的 `get`(`getEntity` / `getLevel`)拿當前 revision,
  再帶著它呼叫寫入。人用起來就是「改一欄就改一欄」,不必先查數字
- **帶 `--revision <n>`**:照用。腳本與 AI Agent 要真樂觀鎖時用這條——它們手上本來就有
  上一次讀到的 revision

先讀再寫之間有毫秒級窗口,與 func-0004 已明確接受的競態(重讀與 rename 之間)是同一種,
不另外加鎖。真正需要保護的並發場景是「Agent 拿著五分鐘前讀到的資料來寫」,`--revision`
擋得住那個;擋不住的是同一毫秒的兩次寫入,而那在單人本機工具上不是真實情境。

`level` 與 `node` 的修改操作,expected revision 一律是 **Level 主體**的 revision
(func-0005 的 `addNode` / `removeNode` 就是這麼定的),不是節點自己的。

#### 五、輸出

兩種模式共用同一組資料,分開 render。

**`--json`:統一信封**,成功與失敗都印到 stdout:

```json
{"ok": true,  "data": <資料本體>}
{"ok": false, "error": {"code": "entity_not_found", "message": "索引裡找不到 ent-7f3a"}}
```

`data` 是 service 的 View 型別經 `StoryFlow.Service.Json` 序列化的結果,CLI 不重新編碼。
`code` 是 `ServiceError` 建構子的 snake_case 名稱(`StoreFailed` 則往內取 `StoreError` 的
建構子名,例如 `stale_revision`)——**穩定的機器可讀識別碼**;`message` 是
`renderServiceError` 的繁中訊息,給人看的。兩者都給,是因為 Agent 需要前者做判斷、需要後者
決定怎麼跟作者說。

信封化(而不是「成功印本體、失敗印 stderr」)的理由是 AI Agent 只要 parse 一種形狀。
代價是 `jq` 要多一層 `.data`,對人來說是小事——人本來就不會加 `--json`。

`--json` 模式下 **stdout 只有那一個 JSON 物件**,警告與提示不混進去(它們在 `data` 的
`warnings` 欄位裡)。

**人類可讀模式**:

- `entity show`:frontmatter 風格的欄位清單 + 正文;`links` 逐行列出 `kind → target(標題)`
- `entity list` / `search`:對齊的表格,欄位 `id | type | status | title | summary`;
  `search` 多一欄 snippet
- `level show`:**樹狀圖**,形狀與 architecture.md 的場景樹圖一致

```text
lvl-3a01 教室
└─ nod-0001 scene        午後的教室,窗外是崩塌後的天際線
   ├─ nod-0002 cast      出場人物
   │  └─ nod-0004 interaction  琳達走向講台
   └─ nod-0003 camera    自窗外緩推至講台,焦段 35mm
```

樹的繪製吃 `LevelView` 的 `lvTree`(`NodeTree`),不自己從扁平清單重建——func-0006 特意回樹
就是為了這件事。

- 寫入類指令:一行結果(`已建立 ent-7f3a(characters/琳達.md)`),警告以 `警告:` 前綴
  逐行印到 **stderr**,不干擾管線

**exit code**:`0` 成功;`1` 業務錯誤(`ServiceError`);`2` 用法錯誤(optparse 自己產生)。

#### 六、全域選項

- `--vault <名稱>`:原樣傳給 `openEnv`,ADR-0008 的解析規則不在 CLI 重寫
- `--json`:如上
- 沒有 `--verbose` / `--quiet`:目前沒有需要分級的輸出;真需要時再加

`vault init` 與 `vault list` 在 `Env` 存在之前就要能跑,所以它們走 func-0006 的
`createVault` / `listVaults`(非 `ServiceM`);其餘全部包在同一個外框裡。外框用的是
`openEnv` + `finally closeEnv` 而不是 `withEnv` ——後者把 `[IndexIssue]` 丟掉了,
而下一段那條「每個指令開頭都印索引警告」的規則正需要它。

`openEnv` 回的 `[IndexIssue]`(外部改動偵測到的解析錯誤)在**每個指令**開頭印到 stderr,
不管是哪個子指令——作者用編輯器把某個檔案改壞了,應該在下一次用 CLI 時就知道,而不是等到
剛好查到那個檔案。

### 使用到的既有串接介面

> 來源 spec 為 func-0006 的各列,原先是依該 spec 的「新增的介面」約定填寫的。實作時
> `storyflow-service` 已經存在,逐條對照過原始碼——有出入的四條記在「實作備註」1,
> 本表其餘各列與 `service/src/` 相符。

| 介面(含完整簽名) | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: Text, metaType :: Text, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Int, metaCreated :: Day, metaUpdated :: Day }` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `entity list` 的表格欄位;`--revision` 未給時取 `metaRevision` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | func-0002 | `entity show` 的渲染對象 |
| `data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `level show` 的樹狀輸出,直接遞迴它 |
| `data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | 樹的每一行要印 id / kind / summary |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 定址第一步:引數是不是 id 格式 |
| `idPrefix :: Id -> IdPrefix` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `currentRevision` 決定去問 `getEntity` 還是 `getLevel` |
| `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 所有輸出裡的 id |
| `parseRef :: Text -> Either IdError Ref` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `--target` 支援 `<vault>:<id>` 寫法 |
| `renderRef :: Ref -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `link list` 的輸出 |
| `parseStatus :: Text -> Either MetaError Status` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `--status` 的驗證 |
| `renderStatus :: Status -> Text` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | 表格的 status 欄 |
| `parseSource :: Text -> Either MetaError Source` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `--source` 的驗證 |
| `parseLinkKind :: Text -> LinkKind` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `--kind` 的轉換。**它是全函式,不會失敗**——自訂關聯一律合法(ADR-0005),所以 CLI 沒有「驗證 kind」這個步驟 |
| `isCoreKind :: LinkKind -> Bool` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | 判斷 `--kind` 是否落在引擎認得的詞彙內,決定要不要提示 |
| `suggestCoreKind :: Text -> Maybe LinkKind` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | 非核心關聯時提示最接近的核心關聯(`Just` 才印) |
| `coreLinkKinds :: [LinkKind]` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `link add --kind` 的 `--help` 列出核心關聯詞彙 |
| `renderLinkKind :: LinkKind -> Text` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `link list` 的輸出 |
| `parseNodeKind :: Text -> Either LevelError NodeKind` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `--kind`(Node)的驗證 |
| `renderNodeKind :: NodeKind -> Text` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `level show` 每一行的 kind |
| `allNodeKinds :: [NodeKind]` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `node add --kind` 的 `--help` 列出全部合法值 |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `--timeline` 與 `--order` 兩個選項組成它 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `--link <kind>:<target>[:<note>]` 解析後的產物 |
| `data EntityTypeSpec`(func-0005 擴充後含 `etsDir` / `etsOwnerType`) | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `type list` 的輸出:key、名稱、必填欄位、允許的關聯 |
| `ToJSON` / `FromJSON` 實例(`Id` / `Ref` / `Meta` / `Entity` / `Level` / `Node` / `Link` / `Status` / `Source` / `Timeline` / `NodeKind` / `LinkKind`) | `core/src/StoryFlow/Core/Json.hs` | func-0002 | `--json` 的 `data` 欄位序列化 |
| `data EntityFilter = EntityFilter { efType :: Maybe Text, efStatus :: Maybe Status, efTag :: Maybe Text, efLimit :: Maybe Int }` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `--type` / `--status` / `--tag` / `--limit` 四個選項直接組成它 |
| `emptyFilter :: EntityFilter` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 沒給任何過濾選項時的預設值 |
| `withEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | 除 `vault init` / `vault list` 外每個子指令的外框 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | 在 `withEnv` 內執行業務操作 |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))` | `service/src/StoryFlow/Service/Monad.hs` | func-0006 | 需要拿 `[IndexIssue]` 印警告時直接用它而非 `withEnv` |
| `data ServiceError`(`renderServiceError :: ServiceError -> Text`) | `service/src/StoryFlow/Service/Error.hs` | func-0006 | `message` 欄位與人類可讀模式的錯誤輸出 |
| `errorCode :: ServiceError -> Text` | `service/src/StoryFlow/Service/Error.hs` | func-0006 | 信封的 `code`。**定義在 service 而非 CLI**:server 與未來的 MCP 要用同一套代碼 |
| `createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)` | `service/src/StoryFlow/Service.hs` | func-0006 | `vault init` |
| `listVaults :: IO (Either ServiceError [VaultView])` | `service/src/StoryFlow/Service.hs` | func-0006 | `vault list` |
| `vaultInfo :: ServiceM VaultView` | `service/src/StoryFlow/Service.hs` | func-0006 | `vault info` |
| `reindex :: ServiceM IndexReport` / `refreshIndex :: ServiceM IndexReport` | `service/src/StoryFlow/Service.hs` | func-0006 | `index rebuild` / `index refresh` |
| `listEntityTypes :: ServiceM [EntityTypeSpec]` | `service/src/StoryFlow/Service.hs` | func-0006 | `type list` |
| `createEntity :: NewEntityReq -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity new` |
| `addFragment :: Id -> NewFragmentReq -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity add` |
| `getEntity :: Id -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity show`;先讀再寫的「先讀」 |
| `listEntities :: EntityFilter -> ServiceM [Meta]` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity list`;標題定址的候選來源 |
| `searchEntity :: Text -> EntityFilter -> ServiceM [SearchHit]` | `service/src/StoryFlow/Service.hs` | func-0006 | `search` |
| `updateEntity :: Id -> Int -> EntityPatch -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity set` |
| `setEntityBody :: Id -> Int -> Text -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity set-body` |
| `deleteEntity :: Id -> Int -> Bool -> ServiceM DeleteReport` | `service/src/StoryFlow/Service.hs` | func-0006 | `entity rm`,`Bool` 來自 `--force` |
| `addLink :: Id -> Int -> Link -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `link add` |
| `removeLink :: Id -> Int -> LinkKind -> Ref -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | func-0006 | `link rm` |
| `linksOf :: Id -> ServiceM LinkReport` | `service/src/StoryFlow/Service.hs` | func-0006 | `link list`,正反向一次印完 |
| `createLevel :: NewLevelReq -> ServiceM LevelView` | `service/src/StoryFlow/Service.hs` | func-0006 | `level new` |
| `getLevel :: Id -> ServiceM LevelView` | `service/src/StoryFlow/Service.hs` | func-0006 | `level show`;node 操作的「先讀」 |
| `listLevels :: EntityFilter -> ServiceM [Meta]` | `service/src/StoryFlow/Service.hs` | func-0006 | `level list`;Level 的標題定址 |
| `deleteLevel :: Id -> Int -> Bool -> ServiceM DeleteReport` | `service/src/StoryFlow/Service.hs` | func-0006 | `level rm` |
| `addNode :: Id -> Id -> Int -> NewNodeReq -> ServiceM LevelView`(Level、父 Node、expected) | `service/src/StoryFlow/Service.hs` | func-0006 | `node add`。多出來的 Level 參數見實作備註 1 |
| `removeNode :: Id -> Id -> Int -> Bool -> ServiceM LevelView` | `service/src/StoryFlow/Service.hs` | func-0006 | `node rm` |
| `evId` / `evRevision` / `lvId` / `lvRevision` | `service/src/StoryFlow/Service/Types.hs` | func-0006 | 先讀再寫時從 View 取 id 與 revision,不自己往下鑽三層 |
| `renderIndexIssue :: IndexIssue -> Text` | `store/src/StoryFlow/Store/Index.hs`(由 service 重新匯出) | func-0004 | 每個指令開頭印到 stderr 的索引警告 |
| `data EntityView` / `LevelView` / `VaultView` / `SearchHit` / `LinkReport` / `IndexReport` / `DeleteReport` | `service/src/StoryFlow/Service/Types.hs` | func-0006 | 兩種輸出模式的渲染對象 |
| `data NewEntityReq` / `NewFragmentReq` / `NewLevelReq` / `NewNodeReq` / `EntityPatch`(`emptyPatch`) | `service/src/StoryFlow/Service/Types.hs` | func-0006 | 選項解析後組出來的請求 |
| `ToJSON` 實例(上述 View 與請求型別) | `service/src/StoryFlow/Service/Json.hs` | func-0006 | `--json` 的 `data`,CLI 不重新編碼 |

### 新增的介面

#### `storyflow-cli`(library)

```haskell
-- | 進入點。executable 只是 main = getArgs >>= runCli >>= exitWith。
--   回 ExitCode 而不是自己 exitWith,測試才能在同一個行程裡跑完整個指令。
runCli :: [String] -> IO ExitCode

-- | 三個 handle 可注入的版本。runCli = runCliWith defaultCliIO。
--   測試把它們換成暫存檔就拿得到 stdout / stderr,不必動全域的標準輸出。
data CliIO = CliIO { cliOut :: Handle, cliErr :: Handle, cliIn :: Handle }
runCliWith :: CliIO -> [String] -> IO ExitCode
```

#### `StoryFlow.Cli.Options`

```haskell
data GlobalOpts = GlobalOpts { goVault :: Maybe Text, goJson :: Bool }

data Command
  = VaultInit FilePath Text | VaultList | VaultInfo
  | IndexRebuild | IndexRefresh
  | TypeList
  | EntityNew NewEntityReq BodySource | EntityAdd Selector NewFragmentReq BodySource
  | EntityShow Selector | EntityList EntityFilter
  | EntitySearch Text EntityFilter
  | EntitySet Selector (Maybe Int) EntityPatch
  | EntitySetBody Selector (Maybe Int) BodySource
  | EntityRm Selector (Maybe Int) Bool
  | LinkAdd Selector (Maybe Int) Link | LinkRm Selector (Maybe Int) LinkKind Ref
  | LinkList Selector
  | LevelNew NewLevelReq | LevelShow Selector | LevelList EntityFilter
  | LevelRm Selector (Maybe Int) Bool
  | NodeAdd Selector (Maybe Int) NewNodeReq | NodeRm Selector (Maybe Int) Bool

-- | 使用者打的是 id 還是標題,解析後才知道。
data Selector = SelById Id | SelByTitle Text

-- | set-body 的三種來源:直接給、讀檔、讀 stdin。
data BodySource = BodyLiteral Text | BodyFile FilePath | BodyStdin

parseCli :: [String] -> ParserResult (GlobalOpts, Command)
```

#### `StoryFlow.Cli.Resolve`

```haskell
-- | 定址的對象種類。錯誤訊息要說出下一步該打哪一條指令,而那三條各不相同。
data Subject = SubEntity | SubLevel | SubNode

-- | Selector → Id。標題多筆命中時 Left 帶候選清單。
data ResolveError = NotFound Subject Text | Ambiguous Subject Text [Meta]

resolveEntity :: Selector -> ServiceM (Either ResolveError Id)
resolveLevel  :: Selector -> ServiceM (Either ResolveError Id)
-- 回 (Level id, Node id):service 的 addNode / removeNode 兩者都要,而指令列上只有節點
resolveNode   :: Selector -> ServiceM (Either ResolveError (Id, Id))

-- | 沒給 --revision 時先讀一次拿當前值。前綴決定去問 getEntity 還是 getLevel。
currentRevision :: Id -> ServiceM Int
```

#### `StoryFlow.Cli.Render`

```haskell
-- | 統一信封。成功與失敗都是合法 JSON,都印到 stdout。
--   code / message 來自 service 的 errorCode / renderServiceError,CLI 不自己編一套。
data Envelope a = Ok a | Err Text Text     -- code, message

instance (ToJSON a) => ToJSON (Envelope a)

-- | CLI 會回報的三種失敗。業務失敗原樣委派給 service 的 errorCode /
--   renderServiceError;另外兩種是 CLI 自己的(service 沒有「用標題找實體」這回事,
--   也不知道 --body-file 讀不讀得到)。
data CliError = CliService ServiceError | CliResolve ResolveError | CliInput Text
cliErrorCode    :: CliError -> Text
cliErrorMessage :: CliError -> Text

renderEntity   :: EntityView -> Text
renderMetaTable:: [Meta] -> Text
renderSearch   :: [SearchHit] -> Text
renderLevelTree:: LevelView -> Text     -- ASCII 樹,形狀與 architecture.md 的圖一致
renderLinks    :: LinkReport -> Text
```

### TodoList

- [x] T1: 建立 `cli/storyflow-cli.cabal`(library + executable `story-flow`)與 `cabal.project` 項目;`build-depends` 明確不含 `storyflow-store` / `storyflow-md` / `sqlite-simple`  `dep: -`
- [x] T2: `StoryFlow.Cli.Options`:`GlobalOpts` / `Command` / `Selector` / `BodySource` 與完整的 optparse 剖析器,含 `--help` 文案  `dep: T1`
- [x] T3: `StoryFlow.Cli.Render`:`Envelope` 與其 `ToJSON`,`code` / `message` 取自 service 的 `errorCode` / `renderServiceError`  `dep: T1`
- [x] T4: `StoryFlow.Cli.Render`:人類可讀渲染器(`renderEntity` / `renderMetaTable` / `renderSearch` / `renderLinks`)  `dep: T3`
- [x] T5: `renderLevelTree`:ASCII 樹,遞迴 `NodeTree`,分支字元與 architecture.md 的圖一致  `dep: T4`
- [x] T6: `StoryFlow.Cli.Resolve`:`Selector` → `Id`,多筆命中列候選;`currentRevision`  `dep: T2`
- [x] T7: `runCli` 骨架:全域選項、`withEnv` 外框、`[IndexIssue]` 警告輸出、exit code 對照  `dep: T3, T6`
- [x] T8: `vault` / `index` / `type` 三組子指令  `dep: T7`
- [x] T9: `entity new` / `entity add`,含 `--link <kind>:<target>[:<note>]` 的解析  `dep: T8`
- [x] T10: `entity show` / `entity list` / `search`  `dep: T4, T8`
- [x] T11: `entity set` / `entity set-body` / `entity rm`,含先讀再寫與 `--revision` 覆寫  `dep: T6, T9`
- [x] T12: `link` 三個子指令,含非核心 `--kind` 的 `suggestCoreKind` 提示(提示不阻擋)  `dep: T11`
- [x] T13: `level` 四個子指令  `dep: T5, T11`
- [x] T14: `node` 兩個子指令  `dep: T13`
- [x] T15: 端到端:純 CLI 從 `vault init` 建出琳達與教室  `dep: T12, T14`

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `cli/test/.../CabalSpec.hs` → `CLI 不依賴落地層` | 讀 `storyflow-cli.cabal`,斷言 `build-depends` 不含 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite`;含 `storyflow-service` |
| T2 | `cli/test/.../OptionsSpec.hs` → `每個子指令的引數都解析成正確的 Command` | 逐指令餵引數斷言 `Command` 的建構子與欄位;`--tag a --tag b` 累積成兩筆;缺必填引數時 `ParserResult` 是失敗且訊息提到該選項 |
| T3 | `cli/test/.../EnvelopeSpec.hs` → `信封的成功與失敗都是合法 JSON` | `Ok x` 編出 `{"ok":true,"data":...}`;`Err c m` 編出 `{"ok":false,"error":{"code":...,"message":...}}`;由 `ServiceError` 走完整條路徑得到的 `code` 等於 `errorCode` 的輸出(不重編一套) |
| T4 | `cli/test/.../RenderSpec.hs` → `表格對齊且欄位齊全` | `renderMetaTable` 的每一列欄數相同、含 id/type/status/title;含中日文標題時仍對齊(以顯示寬度計算);`renderEntity` 含正文與逐行的 links |
| T5 | `cli/test/.../TreeSpec.hs` → `level show 的樹形狀與架構文件一致` | 用 architecture.md 教室場景的六個 Node 建樹,斷言輸出逐行等於預期字串(含 `└─` / `├─` / `│` 的位置) |
| T6 | `cli/test/.../ResolveSpec.hs` → `id 直接用,標題精確比對,多筆命中列候選` | `ent-7f3a` 走 `parseId`;唯一標題回該 id;兩個同名 Entity → `Ambiguous` 且候選清單含兩者的 id 與 summary;不存在 → `NotFound` |
| T7 | `cli/test/.../RunCliSpec.hs` → `exit code 與索引警告` | 成功回 `ExitSuccess`;業務錯誤回 `ExitFailure 1`;引數錯誤回 `ExitFailure 2`;Vault 內有壞掉的 `.md` 時 stderr 出現該檔的警告 |
| T8 | `cli/test/.../VaultCmdSpec.hs` → `vault init 後 list 與 info 都看得到` | 臨時目錄 `vault init` → `vault list --json` 的 data 含它 → `vault info --json` 的名稱相符;`index rebuild --json` 的 `data.files` 等於實際 `.md` 數 |
| T9 | `cli/test/.../EntityNewSpec.hs` → `entity new 建檔並正確解析 --link` | `--link partOf:ent-7f3a:對雙親死因不一致` 解出三段;`--link` 只有兩段時 note 為 `Nothing`;`entity add` 後主體 revision +1 |
| T10 | `cli/test/.../EntityReadSpec.hs` → `show / list / search 的兩種輸出模式` | 同一筆資料 `--json` 的 `data` 與人類模式含相同的 id 與 title;`--type` / `--status` / `--tag` / `--limit` 各自縮小結果集;`search` 的 JSON 含 snippet |
| T11 | `cli/test/.../EntityWriteSpec.hs` → `先讀再寫與 --revision 覆寫` | 不帶 `--revision` 的 `entity set` 成功且 revision +1;帶過期的 `--revision` → exit 1 且 `code` 是 `stale_revision`、檔案不變;`set-body -` 從 stdin 讀取 |
| T12 | `cli/test/.../LinkCmdSpec.hs` → `link add / rm / list 與非核心 kind 的提示` | `link add` 後 `link list` 的正向含該筆、目標端的反向也含它;`link rm` 後兩邊都消失;刪不存在的配對 → exit 1;`--kind contradict`(缺 s)→ **成功寫入**且 stderr 提示 `contradicts`;`--kind 師承於` → 成功且無提示 |
| T13 | `cli/test/.../LevelCmdSpec.hs` → `level 四個子指令` | `level new` 後 `level show` 只有根節點;`level list` 含它;`level rm` 非 force 且被引用時 exit 1 且訊息列出來源 |
| T14 | `cli/test/.../NodeCmdSpec.hs` → `node add / rm 反映在樹上` | `node add` 到根之下後 `level show` 多一層;連續加三個兄弟時順序與加入順序相同;`node rm` 刪掉有子孫的節點後子孫全消失;對根節點 `node rm` → exit 1 |
| T15 | `cli/test/.../EndToEndSpec.hs` → `純 CLI 從零建出琳達與教室` | 只用 `runCli` 依序下 `vault init` → `entity new` → `entity add` ×2 → `link add` → `level new` → `node add` ×5,最後 `level show` 的輸出與 architecture.md 的樹圖一致 |

### 實作備註

#### 1. 規格寫在 `service` 實作之前,四條簽名對不上

本 spec 的「使用到的既有串接介面」是照 func-0006 的約定填的,實作時逐條對照原始碼,
四條與實際不同,一律**以原始碼為準**:

| 規格寫的 | 實際的 | 影響 |
|---|---|---|
| `addNode :: Id -> Int -> NewNodeReq -> ServiceM LevelView` | `addNode :: Id -> Id -> Int -> NewNodeReq -> ServiceM LevelView`(Level id、父 Node、expected) | CLI 必須自己知道節點屬於哪個 Level |
| `removeNode :: Id -> Int -> Bool -> ServiceM LevelView` | `removeNode :: Id -> Id -> Int -> Bool -> ServiceM LevelView` | 同上 |
| `addFragment :: Id -> NewFragmentReq -> ServiceM EntityView`(規格未提 revision) | 相同——service 自己讀主體的 revision | `entity add` 沒有 `--revision`,與其他寫入指令不對稱,但那是 service 的決定 |
| `parseId :: Text -> Either IdError Id` | `parseId :: Text -> Either IdError (IdPrefix, Id)` | `mkSelector` 取 `snd` |

`addNode` / `removeNode` 多出來的 Level 參數改變了 `resolveNode` 的形狀:

```haskell
-- 規格:resolveNode :: Selector -> Id -> ServiceM (Either ResolveError Id)
resolveNode :: Selector -> ServiceM (Either ResolveError (Id, Id))   -- (Level id, Node id)
```

規格的版本要呼叫端先提供 Level 上下文,但**指令樹裡沒有那個引數**(`node add <父節點>`、
`node rm <節點>` 都只有節點)。實作改成走過每一棵 Level 樹反查,順手把它所屬的 Level 帶回來
——反正為了找節點本來就要走過去,而 expected revision 要的正是那個 Level 的 revision。
代價是 Level 數量多時 `node` 指令要讀全部的 Level;P2 的規模下不構成問題,真的變慢時該補的是
索引的「由 Node 反查 Level」查詢,不是在 CLI 這一層想辦法。

走訪時某一份 Level 的標題階層被作者改壞(`LevelTreeInvalid`)就跳過它,不讓整個定址失敗
——一份壞掉的 Level 不該讓另一份 Level 上的節點也碰不到。

#### 2. `ResolveError` 多了 `Subject`

規格是 `NotFound Text | Ambiguous Text [Meta]`,但規格自己的第三節要求「Node 定址在多筆命中時
額外提示可以用 `story-flow level show <Level>`」——那句提示表達不了。實作加了一個
`data Subject = SubEntity | SubLevel | SubNode`,兩個建構子各多帶它一個:

```haskell
data ResolveError = NotFound Subject Text | Ambiguous Subject Text [Meta]
```

不折進訊息字串(那樣訊息就無法被測試比對),也不拆成三個平行的錯誤型別(呼叫端會各寫一次
`case`)。

#### 3. 三個規格沒有、但必要的介面

- **`BodySource` 進了 `Command`**:`EntityNew NewEntityReq BodySource` /
  `EntityAdd Selector NewFragmentReq BodySource`。`--body-file` 與 `-` 都要 IO,而 `parseCli`
  是純的,正文因此不可能在解析階段就變成 `Text`。`level new` / `node add` 只有字面 `--body`,
  維持規格的形狀不變
- **`CliError` 的第三個建構子 `CliInput Text`**(code `input_unreadable`):`--body-file` 讀不到
  或 stdin 掛掉是 CLI 自己的失敗,`ServiceError` 裡沒有對應的建構子,而讓它變成未捕捉的例外
  會繞過整個信封
- **`runCliWith :: CliIO -> [String] -> IO ExitCode`**:`runCli = runCliWith defaultCliIO`。
  三個 handle 可注入,測試就不必去動全域的 stdout/stderr(規格的 `runCli` 原樣保留,
  executable 用的是它)

#### 4. `ToJSON EntityTypeSpec` 補在 `core`,不在 CLI

驗收標準 2 要求**每一個**子指令支援 `--json`,而 `type list` 的資料本體是 `[EntityTypeSpec]`
——`StoryFlow.Core.Json` 當時沒有它的實例。實例補在 `core/src/StoryFlow/Core/Json.hs`
(連同 `FieldSpec`),不是在 CLI 就地編一份:那個模組的存在理由就是「編碼規則全系統一份」,
P3 的 REST 型別清單與 P5 的 MCP 能力宣告要用的是同一份。鍵名沿用 `types/registry/*.toml`
的欄位名(`allowed_links` / `owner_type`),讓讀 JSON 的人與寫 TOML 的人看到同一組字。

這是對已 `done` 的 func-0002 做的追加,純新增、不改既有行為。

#### 5. `--json` 的那一行寫成 UTF-8 位元組,繞過 handle 的 codec

Windows 上 GHC 的 handle 在輸出被導進管線或檔案時用系統的 ANSI code page(開發機是 cp950),
於是 `story-flow --json entity show 琳達 | jq` 拿到的不是合法的 UTF-8 JSON。信封是給機器讀的,
編碼不能跟著主控台的設定跑,所以 `jsonLine` 直接 `BS.hPut` 寫 UTF-8。

**人類可讀模式維持走 handle 的 codec**:cp950 主控台要靠它才顯示得出繁中。兩種模式的輸出
對象不同,編碼策略也就不同。

#### 6. 幾個規格沒講、實作時定下來的邊界

- **引數錯誤不走信封**:`--json` 這個旗標本身可能就是打錯的那一個,這時候假裝解析成功地印一個
  JSON 出來只會更難查。exit 2 + 純文字到 stderr
- **`--link` 的緊湊格式表達不了跨 Vault 目標**:`partOf:shared:ent-7f3a` 會把 `shared` 讀成
  目標、`ent-7f3a` 讀成說明。跨 Vault 的讀寫本來就還沒支援(service 的
  `CrossVaultUnsupported`),要用時走 `link add --target` 的分離形式
- **`entity new --link` 不驗目標存在**:service 的 `requireTargetExists` 只掛在 `addLink`,
  `createEntity` 那條路沒有。CLI **不補**這個檢查——那是業務判斷,補在這裡就會與 P3 的 REST
  行為不一致。現況以測試釘住(`EntityNewSpec`),要改的話該改 func-0006
- **`link add` 一個自訂關聯會同時得到兩則訊息**:CLI 的「你是不是要打 `contradicts`?」與
  service 的 `LinkNotAllowed`。兩者講的是不同的事(拼字 vs 型別宣告),都留著

#### 7. 驗收結果

| 驗收標準 | 結果 |
|---|---|
| 1. 純 CLI 建出琳達與教室,樹形狀與 architecture.md 一致 | ✅ `EndToEndSpec`:`vault init` → `entity new` → `entity add` ×2 → `link add` → `level new` → `node add` ×5 → `level show` 七行,分支字元逐項相符 |
| 2. 每個子指令都支援 `--json`,通過同一個信封 schema | ✅ 21 個子指令全部走同一個 `emit`;`EnvelopeSpec` 釘住信封形狀 |
| 3. `build-depends` 不含落地層 | ✅ `CabalSpec` 讀 .cabal 斷言不含 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite` |
| 4. 業務錯誤非零 exit code,`--json` 下錯誤也是合法 JSON | ✅ `RunCliSpec`:成功 0、業務錯誤 1、用法錯誤 2;錯誤信封解得出 `error.code` |

測試:`cabal test all` 全綠——`storyflow-cli-test` 131 examples / 0 failures,
六個套件合計 760 examples / 0 failures。library 與 executable 在 `-Wall -Wcompat
-Wincomplete-record-updates -Wincomplete-uni-patterns` 下零警告。
