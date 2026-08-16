---
id: func-0005
type: spec
title: store-write-operations
description: 補齊建檔、增節、改寫、刪除與 Level 節點的落地寫入能力
status: open
created: 2026-08-16
updated: 2026-08-16
depends-on: [func-0002, func-0003, func-0004]
related-adr: [adr-0002, adr-0003, adr-0005, adr-0009, adr-0010]
related-spec: []
---

# 落地層寫入能力補齊 功能規格

## 功能概述

func-0004 完成後,`storyflow-store` 的**寫入面只有兩個函式**:`writeEntityMeta`(改既有節的
meta)與 `allocateId`。「新建一份主題檔」「往檔案加一個片段」「改正文」「刪除」「增刪關聯」
「建 Level 與節點」**全部不存在**。P2 的驗收標準是「能純用 CLI 把教室場景與琳達的片段從零
建起來」——這件事現在一行也做不到,而它不是 `service` 的職責:`service` 只做業務組合,碰檔案
的事全部收在 `store` 一層(這是本 spec 的前提)。

同時補掉 architecture.md「已知缺口」記的那個洞:檔案層主體(frontmatter)的 meta 改不動,
`writeEntityMeta` 對它一律回 `FrontmatterWriteUnsupported`。

驗收標準:

1. 從一個空 Vault 出發,只呼叫本 spec 新增的函式,能建出 architecture.md 範例裡的
   `characters/琳達.md`(主體 + 兩個片段,含 `links`)與 `levels/教室.md`(六個 Node 的樹),
   且解析回來的結果與範例等價
2. 每一個寫入函式走完後,索引與檔案一致——`rebuildIndex` 之後的查詢結果與寫入當下相同
3. 未被修改的區塊逐字不變(ADR-0010):對一份含 YAML 註解、混合行尾、非標準縮排的檔案做
   任一種寫入,只有目標區塊的位元組改變
4. 樂觀鎖在所有會改動既有實體的路徑上生效,`StaleRevision` 時**一個位元組都不寫**
5. `FrontmatterWriteUnsupported` 建構子從 `StoreError` 消失,architecture.md 的「已知缺口」
   一節刪除

明確**不做**的:Node 的移動與重排(`moveNode` / `reorderNode`)。標題階層即樹(ADR-0009),
作者直接改檔案的標題層級就是移動,工具層先不介入。跨檔案的交易(刪 Entity 時順手清掉別的
檔案裡指向它的 link)也不做——見「刪除策略」。

## 相依性

`depends-on: [func-0002, func-0003, func-0004]`,三者**都已 done**,沒有等待對象。

- **func-0002**(`storyflow-core`):`Meta` / `Entity` / `Level` / `Node` / `Link` / `Id` 型別
  與 `TypeRegistry`。本 spec 要**擴充** `EntityTypeSpec`(加 `dir` / `owner_type`),因此不只
  是使用,還會回頭改 func-0002 交付的模組
- **func-0003**(`storyflow-md`):`Document` / `Section` 與既有的節層編輯純函式。本 spec 要
  **擴充** md 的編輯面(frontmatter 序列化與改寫、正文改寫、新檔產生)
- **func-0004**(`storyflow-store`):`Vault` 定位、索引維護、原子寫入、樂觀鎖模式。本 spec
  的每一個新函式都是「先寫檔、再更新索引」這條既有紀律的複製品

`storyflow-types`(func-0002 的一部分)的 TOML 載入器要跟著新欄位改,`types/registry/*.toml`
五份檔案要補欄位。

**可否平行開發**:本 spec 動到 core / types / md / store 四個套件,是 P2 的地基。
func-0006(`service`)在介面約定確定前無法開工,**必須等本 spec 完成**。與本 spec 平行可做的
只有不碰寫入的東西(例如 P3 的 servant 型別草稿),實務上建議序列進行。

## 實作方式

### 一、`storyflow-md` 擴充(純函式,零 IO)

md 已經有 `updateSection` / `insertSection` / `removeSection` / `mkSection` / `renderDocument`,
節層編輯是完整的。缺的是三件事,全部加在 `StoryFlow.Md.Render`,理由與 ADR-0010 一致:
**「只重寫被修改的那一段」這條保證必須由一個模組獨佔**,散出去就等於保證分裂。

**1. frontmatter 序列化**。`renderMetaBlock` 吃的是 `MetaOverride`(每個欄位 `Maybe`),
frontmatter 吃的是**完整的** `Meta`——它一定有 `id` 與 `title`,而 `MetaOverride` 根本沒有
這兩個欄位。因此另開 `renderFrontmatter :: Meta -> LineEnding -> Text`,欄位順序 `id` 起頭:

```
frontmatterFieldOrder = [id, type, vault, title, summary, tags, status,
                         timeline, aliases, source, revision, created, updated, links]
```

`metaFieldOrder` 的相對順序原樣保留為子序列,只把 `id` / `title` 插進去、拿掉 `kind`
(frontmatter 描述的是 Entity 或 Level,不是 Node)。純量的引號規則、`links` 的流式風格、
`timeline` 的兩種寫法全部沿用 `renderMetaBlock` 現有的 `scalar` / `flowScalar` /
`timelineLine` / `linkLine` 私有輔助函式——**不複製一份**,否則兩處的跳脫規則遲早分歧。

輸出**不含** `---` 界線:`renderDocument` 已經負責重生那兩行,`docFrontRaw` 的界線是
「開頭界線的行尾字元起算、到結尾界線的 `---` 之前為止」(func-0003 實作備註 4)。

與 `renderMetaBlock` 不同,`Meta` 的欄位沒有 `Maybe`,所以**每個欄位都會輸出**。空值
(`summary = ""`、`tags = []`、`links = []`)照樣寫出來,讓 frontmatter 自我說明有哪些欄位。

**2. `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document`**。
解出目前的 `Meta`(`decodeFrontmatter docFrontRaw`)、套用函式、以 `renderFrontmatter`
重新序列化整個 frontmatter。這是**整段重寫**,不是逐欄改寫——frontmatter 是一整塊 YAML,
沒有像節那樣的「只有 meta 區塊要換」的細界線可切。代價是作者寫在 frontmatter 裡的 YAML
註解會被抹掉;節層的位元組保留不受影響(那才是 ADR-0010 真正在保護的東西,因為片段是
被工具高頻改寫的那一種)。frontmatter YAML 壞掉時回 `Left`,**不覆蓋**。

> **與 architecture.md 的偏差**:「已知缺口」一節開的簽名是
> `(MetaOverride -> MetaOverride) -> Document -> Either MdError Document`。改用 `Meta -> Meta`
> 的理由是 `MetaOverride` 表達不了 `id` 與 `title`,而改標題正是主體 Entity 最常見的修改;
> 且 frontmatter 一定是完整的 `Meta`,用「每欄 `Maybe`」的型別去描述它會把「沒寫」與「寫了
> 空值」混成同一件事。此偏差需開發者確認後同步更新 architecture.md。

**3. `replaceSectionBody :: Id -> Text -> Document -> Either MdError Document`**。
只換 `secBodyRaw`,`secHeadingRaw` 與 `secMetaRaw` 一個位元組都不動。新正文若不以行尾結尾
且它不是最後一節,補一個 `docEnding` 的行尾——否則下一節的標題會黏上來(與 `insertSection`
的 `padNL` 同一個坑)。

**4. `mkDocument :: LineEnding -> Meta -> Text -> Document`**。從零產生一份只有 frontmatter
與正文、還沒有任何節的 `Document`。三段切片依 `renderDocument` 的重組規則填:

```haskell
docFrontRaw = nl <> renderFrontmatter meta le
docPreamble = nl <> nl <> body        -- 結尾界線之後的行尾 + 一行空白 + 正文
docSections = []
docFinalNL  = body 以行尾結尾
```

`Level` 檔沒有 `Meta` 以外的檔案層欄位需要序列化——`lvlRoot` 由標題階層推導(ADR-0009),
不寫進 frontmatter,所以 Entity 檔與 Level 檔共用同一個 `mkDocument`,差別只在 `metaType`
是不是 `"level"`。

### 二、`storyflow-core` / `storyflow-types` 擴充:型別註冊表宣告子目錄

新建主題檔時「檔案放哪個目錄」必須是**宣告式**的,否則垂直切片 1(新增型別不改程式)就破了。
`EntityTypeSpec` 加兩個欄位:

```haskell
etsDir       :: Maybe Text   -- 該型別的檔案放哪個子目錄,如 "characters"
etsOwnerType :: Maybe Text   -- 這個片段型別所屬的主體型別鍵,如 "character"
```

兩個都是 `Maybe`:既有的五份 TOML 在補欄位之前必須仍能載入,`validateRegistry` 不因缺欄位
報錯(ADR-0005 的立場是引導而非阻擋)。

`owner_type` 存在的理由是一個**已經在資料裡、但註冊表沒表達**的事實:檔案層主體寫
`type: character`,節層片段寫 `type: character-fragment`,而 `character` 這個鍵**不在註冊表
裡**——`checkEntity` 對主體 Entity 一律回 `UnknownEntityType`。宣告 `owner_type = "character"`
之後,「查 `character` 的目錄」與「查 `character-fragment` 的目錄」都能命中同一筆宣告。

新增純函式:

```haskell
lookupDir :: Text -> TypeRegistry -> Maybe Text
```

先以 `key` 精確查;沒有就掃描全部宣告找 `etsOwnerType == Just k` 的第一筆(依 `etsKey`
排序取最小,結果才穩定)。兩者都沒有時回 `Nothing`,由呼叫端決定丟哪裡。

`validateRegistry` 新增一條檢查:同一個 `owner_type` 被兩份宣告以**不同的 `dir`** 認領時回
`ConflictingOwnerDir Text`——這代表註冊表在自我矛盾,靜默取第一筆會讓檔案散在兩個目錄。

`storyflow-types` 的 `Loader` 解析新的兩個鍵;`types/registry/` 五份 TOML 各補上:

| 檔案 | `dir` | `owner_type` |
|---|---|---|
| `character-fragment.toml` | `characters` | `character` |
| `lore-fragment.toml` | `lore` | `lore` |
| `item-fragment.toml` | `items` | `item` |
| `dialogue.toml` | `dialogues` | (無,對話本身就是主體) |
| `plot-fragment.toml` | `lore` | `plot` |

`level` 是保留鍵不可出現在註冊表,所以 Level 檔的目錄由 `store` 硬編為 `levels/`——
`vaultSubdirs` 已經含它,`initVault` 也已經會建它。

### 三、`storyflow-store` 擴充

新增模組 `StoryFlow.Store.Create`(建立與刪除)與 `StoryFlow.Store.Node`(Level 樹編輯),
既有的 `StoryFlow.Store.Write` 保留給「改既有實體」。三個模組共用同一條紀律,寫成一個私有
輔助函式避免每處各寫一遍:

```
讀檔 → 解析 → 樂觀鎖比對 → 純函式編輯 → atomicWriteText → indexFile
                                              ↑ 失敗 = FileWriteFailed(真失敗)
                                                          ↑ 失敗 = IndexUpdateFailed(資料安全)
```

#### 建立主題檔

```haskell
data NewEntity = NewEntity
  { neType    :: Text          -- 主體型別鍵,如 "character"
  , neTitle   :: Text
  , neSummary :: Text
  , neBody    :: Text
  , neTags    :: [Text]
  , neAliases :: [Text]
  , neStatus  :: Status
  , neTimeline:: Timeline
  , neLinks   :: [Link]
  , neSource  :: Source
  , nePath    :: Maybe FilePath  -- Vault 相對路徑;Nothing = 依註冊表推導
  }

createEntityFile
  :: Connection -> Vault -> TypeRegistry -> NewEntity
  -> IO (Either StoreError CreateResult)
```

路徑決定:`nePath` 有值就用它;否則 `lookupDir neType reg` 拿子目錄(查不到丟 Vault 根),
檔名由 `neTitle` 產生。檔名**保留中文原字元**(Vault 是給人看的 git repo,`characters/琳達.md`
比雜湊好一百倍),只替換檔案系統不接受的字元 `<>:"/\|?*` 與控制字元為 `-`,去掉頭尾空白與
句點,全空時退回 `renderId` 的結果。撞名時加 `-2` / `-3` 遞增直到不存在。

id 由 `allocateId conn PEnt (neTitle <> neSummary) now` 產生(內容 + 時間 + salt 遞增,
唯一性由索引保證)。組出 `Meta`(`metaRevision = 1`、`created`/`updated` = 今天)→ `mkDocument`
→ `renderDocument` → `atomicWriteText` → `indexFile`。

**先檢查檔案不存在再寫**:`atomicWriteText` 是覆蓋語意,不擋既有檔案。撞名檢查與寫入之間
仍有毫秒級窗口,與 func-0004 已接受的競態同一種,不另外加鎖。

行尾風格:新檔用 `LF`。Windows 上的 git 由 `core.autocrlf` 處理,工具不介入。

`createLevelFile` 是同一段邏輯的特例:`metaType = "level"`、目錄固定 `levels/`、id 前綴
`PLvl`(根 Node 用 `PNod`),且**一併建出根 Node**(一個 `nod-` 的節,`secLevel = 2`,
`kind` 由呼叫端給)
——Level 檔沒有根 Node 就解析不出 `lvlRoot`,建一個空殼等於建一份壞檔。

#### 往既有檔案加片段

```haskell
addFragment
  :: Connection -> Vault -> Id -> Int -> NewFragment
  -> IO (Either StoreError WriteResult)
```

`Id` 是**主體 Entity** 的 id(用來定位檔案),`Int` 是主體的 revision(樂觀鎖)。流程:

1. `locate` 查出檔案路徑;該 id 的 `section_anchor` 必須是 `NULL`(它得是主體),否則
   `NotAFileMain`
2. 重讀檔案、`parseEntityFile`,取 `efMain` 的實際 revision 比對 `expected`;不符即
   `StaleRevision`,**不寫**
3. `allocateId` 產新片段 id
4. `mkSection docEnding 2 newId title (Just override) body`——片段一律 `##`(二級);
   architecture.md 的規則是「第一個帶 `{#id}` 的標題才開始分節」,Entity 檔的節之間沒有階層
5. `insertSection (Just lastSectionId) newSec`,插在**檔尾**;檔案還沒有任何節時傳 `Nothing`
6. `updateFrontmatter` 把主體 revision +1、`updated` 改今天——這是樂觀鎖的另一半:
   不遞增的話,兩個並發的 `addFragment` 拿同一個 revision 都會通過
7. 寫檔 → `indexFile`

節層 `MetaOverride` 只寫**與檔案層不同**的欄位,其餘留 `Nothing` 讓繼承生效(func-0003 的
繼承規則)。但 `summary` / `revision` / `links` / `aliases` 不繼承,所以 `moSummary` 一定要
給值——缺了會產生 `MdWarning`,回傳裡一併帶出。

#### 改既有實體

- **`writeEntityMeta` 擴充**:`section_anchor` 為 `NULL` 時改走 `updateFrontmatter`(把
  `MetaOverride` 疊到現有 `Meta` 上),`FrontmatterWriteUnsupported` 建構子刪除。節層路徑
  一行不動
- **`writeEntityBody`**:同樣的樂觀鎖流程,節層走 `replaceSectionBody`,主體走「改
  `docPreamble`」。後者不需要新的 md 函式,`Document` 的欄位直接改即可,但為了讓 ADR-0010
  的邊界只有一處,仍在 md 加 `replacePreamble :: Text -> Document -> Document`
- **`addEntityLink` / `removeEntityLink`**:讀出目前的 `links`、增/刪一筆、整份寫回
  `moLinks`。`Link` 只存在來源端(ADR-0002),所以這是**單邊、單檔**操作,不牽動目標端。
  `removeEntityLink` 以 `(LinkKind, Ref)` 配對刪除,同一對出現多次時全部刪掉;一筆都沒命中
  時回 `LinkNotFound`,而不是靜默成功

#### 刪除

```haskell
data DeleteMode = DeleteSafe | DeleteForce

deleteEntity
  :: Connection -> Vault -> Id -> Int -> DeleteMode
  -> IO (Either StoreError DeleteResult)
```

先 `linksTo conn (localRef i)` 查出誰指向它。`DeleteSafe` 且非空 → `ReferencedBy i [(Id, Link)]`
**不刪**,錯誤訊息列出來源 id 讓呼叫端能直接告訴作者去改哪裡。`DeleteForce` 照刪,回傳的
`DeleteResult` 帶上被打斷的 link 清單。

**不自動清掉指向它的 link**:那要改其他檔案,而多檔寫入沒有交易保證——改到一半失敗會留下
不一致,比留幾筆孤兒 link 糟得多。孤兒 link 是可查詢、可修復的狀態;半套的刪除不是。

片段(`section_anchor` 非 NULL)→ `removeSection` + 主體 revision +1 + 寫檔 + `indexFile`。
主體(NULL)→ **刪整份檔案**,連同檔內所有片段;因此 `DeleteSafe` 要對**每一個片段**也做
`linksTo` 檢查,任一個被指向就拒絕。刪檔後 `unindexFile conn rel` 清索引。

`Int` 是被刪目標的 revision:刪除也走樂觀鎖,否則「作者剛改完、Agent 拿舊資料刪掉」會靜默
生效。

#### Level 節點

```haskell
addNode    :: Connection -> Vault -> Id -> Int -> NewNode -> IO (Either StoreError WriteResult)
removeNode :: Connection -> Vault -> Id -> Int -> DeleteMode -> IO (Either StoreError WriteResult)
```

`addNode` 的 `Id` 是**父 Node**。ADR-0009 的規則反過來用:新節的標題層級 = 父節點層級 + 1,
插入位置 = 父節點子樹的**最後一節之後**。「子樹的最後一節」= 從父節點往後掃,直到遇到
`secLevel <= 父層級` 的節為止,取前一節——這是 `insertSection` 的註解已經指出的用法
(「之後」是該節本身之後,不是它整棵子樹之後)。

限制檢查:新層級 > 6 時回 `NodeDepthExceeded`(Markdown 只有六級標題,architecture.md 已載明
此限制與繞道方式)。

`removeNode` 刪掉該節**與其整棵子樹**(同一段掃描邏輯:後續所有 `secLevel > 目標層級` 的節)。
根 Node 不可刪——刪了整份 Level 檔就解析不出 `lvlRoot`——回 `CannotRemoveRootNode`,請呼叫端
改用 `deleteLevel`(刪整份檔案,與主體 Entity 的刪除同一條路徑)。`DeleteSafe` 對子樹裡
**每一個** Node 做 `linksTo` 檢查,`convergesTo` 指向被刪節點的情況會在這裡被擋下來。

寫回後以 `parseLevelFile` + `buildTree` **驗證樹仍然合法**再 `indexFile`;`buildTree` 回
`Left` 時不寫索引、回 `TreeInvalid`。檔案已經寫出去了,所以這是 `IndexUpdateFailed` 等級的
處境——但這裡有更好的做法:**驗證放在寫檔之前**,對編輯後的 `Document` 先 `parseLevelFile`
+ `buildTree`,通過才寫。純函式驗證不花 IO,沒有理由先寫壞檔再說。

### 四、`StoreError` 變更

新增:`ReferencedBy Id [(Id, Link)]`、`NotAFileMain Id`、`NotAFragment Id`、
`NodeDepthExceeded Id Int`、`CannotRemoveRootNode Id`、`LinkNotFound Id LinkKind Ref`、
`FileAlreadyExists FilePath`、`TreeInvalid FilePath [TreeError]`、`RegistryDirUnknown Text`。
刪除:`FrontmatterWriteUnsupported`。每一個都要在 `renderStoreError` 有繁中訊息,並且說出
**下一步該做什麼**(既有訊息全部是這個風格,如 `IndexUpdateFailed` 直接叫人跑
`story-flow index rebuild`)。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: Text, metaType :: Text, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Int, metaCreated :: Day, metaUpdated :: Day }` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `renderFrontmatter` 的輸入;新建實體時組出來 |
| `bumpRevision :: Day -> Meta -> Meta` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | 主體 revision +1 與 `updated` 改今天,不自己寫一份 |
| `metaFieldNames :: [Text]` | `core/src/StoryFlow/Core/Meta.hs` | func-0002 | `frontmatterFieldOrder` 的欄位名以它為準,拼錯即編譯期外的靜默錯誤 |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | func-0002 | `parseEntityFile` 的產物,取 `entMeta` 比對 revision |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | 建 Level 檔時確認根 Node 存在 |
| `data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | `addNode` / `removeNode` 之後驗證樹的輸入 |
| `renderNodeKind :: NodeKind -> Text` | `core/src/StoryFlow/Core/Level.hs` | func-0002 | 新 Node 的 `kind` 欄位序列化(經由 `renderMetaBlock`) |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | `addEntityLink` / `removeEntityLink` 的操作對象 |
| `data IdPrefix = PEnt \| PLvl \| PNod \| PVlt` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `allocateId` 的前綴:Entity 用 `PEnt`、Level 用 `PLvl`、Node 用 `PNod` |
| `mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 經 `allocateId` 間接使用,不直接呼叫 |
| `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 檔名全部被替換掉時的退路;frontmatter 的 `id` 欄位 |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `linksTo` 的參數;`removeEntityLink` 的配對鍵 |
| `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 刪除前查誰指向我,本 Vault 內定址 |
| `data EntityTypeSpec = EntityTypeSpec { etsKey :: Text, etsName :: Text, etsFields :: [FieldSpec], etsAllowedLinks :: [LinkKind], etsStages :: [Text] }` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | **要擴充**:加 `etsDir` / `etsOwnerType` |
| `lookupType :: Text -> TypeRegistry -> Maybe EntityTypeSpec` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `lookupDir` 的精確查詢那一半 |
| `listTypes :: TypeRegistry -> [EntityTypeSpec]` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | `lookupDir` 掃 `owner_type` 時用它取得穩定排序 |
| `validateRegistry :: [EntityTypeSpec] -> Either [RegistryError] TypeRegistry` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | **要擴充**:加 `ConflictingOwnerDir` 檢查 |
| `reservedTypeKeys :: [Text]` | `core/src/StoryFlow/Core/Registry.hs` | func-0002 | 確認 `level` 仍是保留鍵,Level 目錄因此只能硬編 |
| `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/StoryFlow/Core/Tree.hs` | func-0002 | `addNode` / `removeNode` 寫檔**之前**驗證樹合法 |
| `loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)` | `types/src/StoryFlow/Types/Loader.hs` | func-0002 | **要擴充**:解析 `dir` / `owner_type` 兩個鍵 |
| `data Document = Document { docPath :: FilePath, docFrontRaw :: Text, docPreamble :: Text, docSections :: [Section], docEnding :: LineEnding, docFinalNL :: Bool }` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | `mkDocument` 產生它;`replacePreamble` 改 `docPreamble` |
| `data Section = Section { secLevel :: Int, secHeadingRaw :: Text, secTitle :: Text, secId :: Id, secMetaRaw :: Maybe Text, secBodyRaw :: Text, secLine :: Int }` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | `secLevel` 是子樹掃描的依據;`replaceSectionBody` 改 `secBodyRaw` |
| `sectionById :: Id -> Document -> Maybe Section` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | 定位目標節與父 Node |
| `sectionIds :: Document -> [Id]` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | `addFragment` 找檔尾最後一節 |
| `detectLineEnding :: Text -> LineEnding` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | 既有檔的新產生行沿用原風格 |
| `renderLineEnding :: LineEnding -> Text` | `md/src/StoryFlow/Md/Document.hs` | func-0003 | `mkDocument` 組三段切片 |
| `parseDocument :: FilePath -> Text -> Either [MdError] Document` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | 每個寫入路徑的第一步:重讀檔案 |
| `parseEntityFile :: Document -> Either [MdError] (EntityFile, [MdWarning])` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | 取 `efMain` 的 revision 做樂觀鎖比對 |
| `parseLevelFile :: Document -> Either [MdError] (LevelFile, [MdWarning])` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | Level 檔寫回前的樹驗證 |
| `data EntityFile = EntityFile { efMain :: Entity, efFragments :: [Entity] }` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | 刪主體時要逐一檢查 `efFragments` 的被引用狀況 |
| `data LevelFile = LevelFile { lfLevel :: Level, lfNodes :: [Node] }` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | 直接餵給 `buildTree` |
| `documentKind :: Document -> Either [MdError] DocKind` | `md/src/StoryFlow/Md/Parse.hs` | func-0003 | 對 Entity 檔誤用 `addNode` 時提早擋下 |
| `renderDocument :: Document -> Text` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | 所有寫入路徑的最後一步 |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | 節層 meta 與 links 的改寫 |
| `insertSection :: Maybe Id -> Section -> Document -> Either MdError Document` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | `addFragment` / `addNode` 的插入 |
| `removeSection :: Id -> Document -> Either MdError Document` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | 刪片段;`removeNode` 對子樹逐一呼叫 |
| `mkSection :: LineEnding -> Int -> Id -> Text -> Maybe MetaOverride -> Text -> Section` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | 組新片段 / 新 Node,`Int` 就是標題層級 |
| `renderMetaBlock :: MetaOverride -> LineEnding -> Text` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | `renderFrontmatter` 共用它的私有純量與 links 輔助函式 |
| `metaFieldOrder :: [Text]` | `md/src/StoryFlow/Md/Render.hs` | func-0003 | `frontmatterFieldOrder` 以它為子序列 |
| `data MetaOverride = MetaOverride { moKind, moType, moVault, moSummary, moTags, moStatus, moTimeline, moAliases, moLinks, moSource, moRevision, moCreated, moUpdated }`(全部 `Maybe`) | `md/src/StoryFlow/Md/Inherit.hs` | func-0003 | 新片段與新 Node 的節層 meta |
| `emptyOverride :: MetaOverride` | `md/src/StoryFlow/Md/Inherit.hs` | func-0003 | 組 override 的起點 |
| `decodeFrontmatter :: Text -> Either Text Meta` | `md/src/StoryFlow/Md/Yaml.hs` | func-0003 | `updateFrontmatter` 解出目前的 `Meta` |
| `data MdWarning = MissingSummary Id \| CustomLinkKind Id Text \| EmptyBody Id`(`renderMdWarning :: MdWarning -> Text`) | `md/src/StoryFlow/Md/Error.hs` | func-0003 | 缺 `summary` 之類的警告一併回傳,不吞掉 |
| `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` | `store/src/StoryFlow/Store/Atomic.hs` | func-0004 | 所有寫檔;覆蓋語意,故建檔前要自己檢查存在 |
| `readTextFile :: FilePath -> IO (Either StoreError Text)` | `store/src/StoryFlow/Store/Atomic.hs` | func-0004 | 重讀檔案,不信任索引裡的 revision |
| `indexFile :: Connection -> Vault -> FilePath -> IO (Either StoreError ())` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | 寫檔成功後更新索引;失敗回 `IndexUpdateFailed` |
| `unindexFile :: Connection -> FilePath -> IO ()` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | 刪整份檔案後清掉該檔的所有索引記錄 |
| `linksTo :: Connection -> Ref -> IO [(Id, Link)]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | 刪除前的被引用檢查,反向查詢只有索引做得到 |
| `linksFrom :: Connection -> Id -> IO [Link]` | `store/src/StoryFlow/Store/Query.hs` | func-0004 | `removeEntityLink` 找出目前的 links |
| `allocateId :: Connection -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)` | `store/src/StoryFlow/Store/Write.hs` | func-0004 | 產生索引裡沒人用的 id,撞了 salt+1 重試 |
| `writeEntityMeta :: Connection -> Vault -> Id -> Int -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)` | `store/src/StoryFlow/Store/Write.hs` | func-0004 | **要擴充**:支援 `section_anchor` 為 NULL 的主體 |
| `data WriteResult = WriteResult { wrNewRevision :: Int, wrPath :: FilePath }` | `store/src/StoryFlow/Store/Write.hs` | func-0004 | 新寫入函式沿用同一個回傳型別 |
| `data StoreError = VaultNotFound Text \| VaultConfigInvalid FilePath Text \| VaultAlreadyExists FilePath \| EntityNotFound Id \| StaleRevision Id Int Int \| IdCollision IdPrefix \| FileReadFailed FilePath Text \| FileWriteFailed FilePath Text \| IndexUpdateFailed FilePath Text \| ParseFailed FilePath [MdError] \| FrontmatterWriteUnsupported Id \| SqliteError Text`(`renderStoreError :: StoreError -> Text`) | `store/src/StoryFlow/Store/Error.hs` | func-0004 | **要擴充**:九個新建構子,刪掉 `FrontmatterWriteUnsupported` |
| `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/StoryFlow/Store/Error.hs` | func-0004 | 新增的查詢一律包它,`SQLError` 不得外洩 |
| `data Vault = Vault { vaultName :: Text, vaultRoot :: FilePath, vaultCfg :: VaultConfig }` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | 所有寫入函式的 Vault 上下文 |
| `vaultAbsPath :: Vault -> FilePath -> FilePath` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | 索引相對路徑 → 可開檔的絕對路徑 |
| `vaultRelPath :: Vault -> FilePath -> FilePath` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | 新建檔的絕對路徑 → 存進索引的相對路徑 |
| `vaultSubdirs :: [FilePath]` | `store/src/StoryFlow/Store/Vault.hs` | func-0004 | 已含 `levels`,Level 目錄硬編的依據 |
| `openVaultIndex :: Vault -> IO (Either StoreError (Connection, [IndexIssue]))` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | 測試建臨時 Vault 時取得連線 |
| `rebuildIndex :: Connection -> Vault -> IO (Either StoreError [IndexIssue])` | `store/src/StoryFlow/Store/Index.hs` | func-0004 | 驗收標準 2:重建後結果須與寫入當下相同 |

## 新增的介面

### `storyflow-core`(`StoryFlow.Core.Registry`)

```haskell
data EntityTypeSpec = EntityTypeSpec
  { etsKey          :: Text
  , etsName         :: Text
  , etsFields       :: [FieldSpec]
  , etsAllowedLinks :: [LinkKind]
  , etsStages       :: [Text]
  , etsDir          :: Maybe Text   -- 新增:該型別的檔案子目錄
  , etsOwnerType    :: Maybe Text   -- 新增:片段型別所屬的主體型別鍵
  }

-- | 型別鍵 → 子目錄。先精確查 key,再掃 owner_type(依 etsKey 排序取第一筆)。
lookupDir :: Text -> TypeRegistry -> Maybe Text

-- RegistryError 新增建構子:同一個 owner_type 被兩份宣告以不同的 dir 認領
data RegistryError = ... | ConflictingOwnerDir Text
```

### `storyflow-md`(`StoryFlow.Md.Render` / `StoryFlow.Md.Document`)

```haskell
-- | frontmatter 的固定欄位順序。metaFieldOrder 的相對順序保留為子序列,
--   插入 id / title,去掉 kind。
frontmatterFieldOrder :: [Text]

-- | 完整 Meta → frontmatter 內容(不含 --- 界線,含結尾行尾)。
--   純量引號規則與 links / timeline 風格與 renderMetaBlock 共用。
renderFrontmatter :: Meta -> LineEnding -> Text

-- | 改寫 frontmatter。整段重新序列化(YAML 註解不保留);
--   節層的位元組保留不受影響。frontmatter 壞掉時 Left,不覆蓋。
updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document

-- | 只換某一節的正文,標題行與 meta 區塊逐字不動。
replaceSectionBody :: Id -> Text -> Document -> Either MdError Document

-- | 只換 frontmatter 與第一個節之間的正文(檔案層主體的 body)。
replacePreamble :: Text -> Document -> Document

-- | 從零產生一份只有 frontmatter 與正文、還沒有節的 Document。
mkDocument :: LineEnding -> Meta -> Text -> Document
```

### `storyflow-store`(`StoryFlow.Store.Create`)

```haskell
data NewEntity = NewEntity
  { neType :: Text, neTitle :: Text, neSummary :: Text, neBody :: Text
  , neTags :: [Text], neAliases :: [Text], neStatus :: Status
  , neTimeline :: Timeline, neLinks :: [Link], neSource :: Source
  , nePath :: Maybe FilePath
  }

data NewFragment = NewFragment
  { nfTitle :: Text, nfSummary :: Text, nfBody :: Text
  , nfType :: Maybe Text, nfTags :: [Text], nfAliases :: [Text]
  , nfStatus :: Maybe Status, nfTimeline :: Maybe Timeline
  , nfLinks :: [Link], nfSource :: Maybe Source
  }

data NewLevel = NewLevel
  { nlTitle :: Text, nlSummary :: Text, nlBody :: Text
  , nlRootTitle :: Text, nlRootKind :: NodeKind, nlStatus :: Status
  }

data NewNode = NewNode
  { nnTitle :: Text, nnKind :: NodeKind, nnSummary :: Text
  , nnBody :: Text, nnLinks :: [Link]
  }

data CreateResult = CreateResult
  { crId :: Id, crPath :: FilePath, crWarnings :: [MdWarning] }

data DeleteMode = DeleteSafe | DeleteForce

data DeleteResult = DeleteResult
  { drPath :: FilePath
  , drRemovedIds :: [Id]        -- 刪整份檔案時可能不只一個
  , drBrokenLinks :: [(Id, Link)]  -- DeleteForce 打斷的關聯
  }

createEntityFile :: Connection -> Vault -> TypeRegistry -> NewEntity
                 -> IO (Either StoreError CreateResult)

createLevelFile  :: Connection -> Vault -> NewLevel
                 -> IO (Either StoreError CreateResult)

-- Id = 主體 Entity 的 id,Int = 主體的 revision(樂觀鎖)
addFragment :: Connection -> Vault -> Id -> Int -> NewFragment
            -> IO (Either StoreError WriteResult)

-- Id = 被刪目標,Int = 它的 revision
deleteEntity :: Connection -> Vault -> Id -> Int -> DeleteMode
             -> IO (Either StoreError DeleteResult)

deleteLevel  :: Connection -> Vault -> Id -> Int -> DeleteMode
             -> IO (Either StoreError DeleteResult)
```

### `storyflow-store`(`StoryFlow.Store.Write` 擴充)

```haskell
data BodyTarget = BodyOfSection | BodyOfMain   -- 由 section_anchor 自動判定,不必呼叫端給

writeEntityBody :: Connection -> Vault -> Id -> Int -> Text
                -> IO (Either StoreError WriteResult)

addEntityLink    :: Connection -> Vault -> Id -> Int -> Link
                 -> IO (Either StoreError WriteResult)

removeEntityLink :: Connection -> Vault -> Id -> Int -> LinkKind -> Ref
                 -> IO (Either StoreError WriteResult)
```

### `storyflow-store`(`StoryFlow.Store.Query` 擴充)

```haskell
-- | 列出 Level 的 Meta(不含 Node)。既有的 lookupLevel 只能依 id 單查,
--   「這個 Vault 有哪些場景」沒有任何函式回答得了。
--   沿用 EntityFilter 的 efStatus / efLimit;efType / efTag 對 Level 無意義,忽略。
listLevels :: Connection -> EntityFilter -> IO [Meta]
```

### `storyflow-store`(`StoryFlow.Store.Node`)

```haskell
-- Id = 父 Node,Int = Level 主體的 revision
addNode    :: Connection -> Vault -> Id -> Int -> NewNode
           -> IO (Either StoreError WriteResult)

-- Id = 要刪的 Node(連整棵子樹),根 Node 回 CannotRemoveRootNode
removeNode :: Connection -> Vault -> Id -> Int -> DeleteMode
           -> IO (Either StoreError WriteResult)
```

### `StoreError` 新增建構子

```haskell
  | ReferencedBy Id [(Id, Link)]      -- DeleteSafe 被拒,附上誰指向它
  | NotAFileMain Id                   -- 對片段用了只能用在主體的操作
  | NotAFragment Id                   -- 反之
  | NodeDepthExceeded Id Int          -- 新層級 > 6
  | CannotRemoveRootNode Id           -- 請改用 deleteLevel
  | LinkNotFound Id LinkKind Ref      -- removeEntityLink 一筆都沒命中
  | FileAlreadyExists FilePath
  | TreeInvalid FilePath [TreeError]  -- 編輯後的 Level 樹不合法,已擋在寫檔之前
  | RegistryDirUnknown Text           -- 型別沒宣告 dir 且呼叫端沒給路徑
-- 刪除:FrontmatterWriteUnsupported
```

## TodoList

- [ ] T1: `md`:`frontmatterFieldOrder` / `renderFrontmatter` / `mkDocument`,共用既有純量與 links 序列化輔助函式  `dep: -`
- [ ] T2: `md`:`updateFrontmatter`,整段重新序列化,frontmatter YAML 壞掉時不覆蓋  `dep: T1`
- [ ] T3: `md`:`replaceSectionBody` / `replacePreamble`,標題行與 meta 區塊逐字不動  `dep: -`
- [ ] T4: `core`:`EntityTypeSpec` 加 `etsDir` / `etsOwnerType`,新增 `lookupDir`,`validateRegistry` 加 `ConflictingOwnerDir` 檢查  `dep: -`
- [ ] T5: `types`:`Loader` 解析 `dir` / `owner_type`;五份 `types/registry/*.toml` 補欄位  `dep: T4`
- [ ] T6: `store`:新增 `StoryFlow.Store.Create` 與共用的「讀→鎖→編輯→寫檔→索引」私有輔助函式;實作 `createEntityFile`(路徑推導、檔名淨化、撞名遞增、建檔前存在檢查)  `dep: T1, T5`
- [ ] T7: `store`:`addFragment`——主體 revision 樂觀鎖、插在檔尾、主體 revision 遞增  `dep: T2, T6`
- [ ] T8: `store`:`writeEntityMeta` 支援 `section_anchor` 為 NULL 的主體,刪除 `FrontmatterWriteUnsupported`  `dep: T2`
- [ ] T9: `store`:`writeEntityBody`,節層與主體兩條路徑  `dep: T3, T8`
- [ ] T10: `store`:`addEntityLink` / `removeEntityLink`,單邊單檔,沒命中回 `LinkNotFound`  `dep: T8`
- [ ] T11: `store`:`deleteEntity`——`linksTo` 檢查、`DeleteSafe`/`DeleteForce`、片段刪節 vs 主體刪檔  `dep: T8`
- [ ] T12: `store`:`createLevelFile`,一併建出根 Node  `dep: T6`
- [ ] T13: `store`:新增 `StoryFlow.Store.Node`,實作 `addNode`——層級 = 父+1、插在子樹尾端、六級上限、寫檔前 `buildTree` 驗證  `dep: T12`
- [ ] T14: `store`:`removeNode`(連子樹、拒刪根)與 `deleteLevel`  `dep: T13`
- [ ] T15: `StoreError` 九個新建構子的 `renderStoreError` 繁中訊息,每一則都要說出下一步該做什麼  `dep: T14`
- [ ] T16: `store`:`StoryFlow.Store.Query` 新增 `listLevels`——`lookupLevel` 只能單查,「這個 Vault 有哪些場景」目前無人能答  `dep: -`
- [ ] T17: 端到端:從空 Vault 建出 architecture.md 範例的 `characters/琳達.md` 與 `levels/教室.md`,`rebuildIndex` 後結果等價  `dep: T15, T16`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `md/test/.../RenderSpec.hs` → `renderFrontmatter 依固定順序輸出且 mkDocument 可被 parseDocument 讀回` | 欄位順序等於 `frontmatterFieldOrder`;含冒號/前導 `-`/數字樣貌的 `title` 被正確加引號;`mkDocument` 產出的文字經 `parseDocument` → `parseEntityFile` 後 `Meta` 與輸入相等 |
| T2 | `md/test/.../EditSpec.hs` → `updateFrontmatter 改標題後節層位元組不變` | 改 `metaTitle` 後,`docSections` 每一節的 `secHeadingRaw`/`secMetaRaw`/`secBodyRaw` 與改前完全相同;frontmatter YAML 壞掉時回 `Left` 且 `renderDocument` 結果與原檔相同 |
| T3 | `md/test/.../EditSpec.hs` → `replaceSectionBody 只動目標節的正文` | 目標節 `secBodyRaw` 換掉、`secHeadingRaw` 與 `secMetaRaw` 逐字不變;新正文不以行尾結尾時自動補,下一節標題不黏連 |
| T4 | `core/test/.../RegistrySpec.hs` → `lookupDir 以 key 或 owner_type 命中,衝突宣告被擋下` | `lookupDir "character"` 與 `lookupDir "character-fragment"` 都回 `Just "characters"`;兩份宣告同 `owner_type` 不同 `dir` 時 `validateRegistry` 回 `ConflictingOwnerDir` |
| T5 | `types/test/.../LoaderSpec.hs` → `載入真實 registry 後五個型別都有 dir` | 對 `types/registry/` 實際目錄跑 `loadRegistry`,逐一確認 `etsDir` 與 `etsOwnerType` 與規格表相符;缺這兩個鍵的舊格式 TOML 仍能載入 |
| T6 | `store/test/.../CreateSpec.hs` → `createEntityFile 依註冊表落到正確目錄且撞名遞增` | `neType = "character"` 落在 `characters/琳達.md`;同標題再建一次得到 `琳達-2.md`;`neTitle` 含 `/` 與 `:` 時被淨化;型別沒 dir 且 `nePath` 為 `Nothing` 時回 `RegistryDirUnknown` |
| T7 | `store/test/.../CreateSpec.hs` → `addFragment 遞增主體 revision 且 revision 不符時不寫` | 成功後主體 revision +1、新片段出現在檔尾且 `revision = 1`;傳過期的 `expected` 回 `StaleRevision` 且檔案位元組完全不變 |
| T8 | `store/test/.../WriteSpec.hs` → `writeEntityMeta 能改主體的 frontmatter` | 對 `section_anchor` 為 NULL 的 id 改 `summary`,檔案 frontmatter 更新、索引跟著更新;`FrontmatterWriteUnsupported` 已不存在(編譯期即證明) |
| T9 | `store/test/.../WriteSpec.hs` → `writeEntityBody 對節與主體各自改到正確的正文` | 改片段正文後 `lookupEntity` 的 `entBody` 是新值、主體 `entBody` 不變;反之亦然 |
| T10 | `store/test/.../WriteSpec.hs` → `addEntityLink 與 removeEntityLink 只動來源端` | 加一筆 `contradicts` 後 `linksFrom` 多一筆、目標端檔案位元組不變;刪除不存在的配對回 `LinkNotFound` |
| T11 | `store/test/.../DeleteSpec.hs` → `DeleteSafe 遇到被引用時拒絕,DeleteForce 回報斷點` | 有他人 `partOf` 指向時 `DeleteSafe` 回 `ReferencedBy` 且檔案不變;`DeleteForce` 刪成功且 `drBrokenLinks` 列出該筆;刪主體時整份檔案與索引記錄一起消失 |
| T12 | `store/test/.../NodeSpec.hs` → `createLevelFile 產生可解析的 Level 與根 Node` | 產出的檔案經 `parseLevelFile` + `buildTree` 成功,`lvlRoot` 等於建出來的根 Node id,落在 `levels/` |
| T13 | `store/test/.../NodeSpec.hs` → `addNode 依父節點決定層級並插在子樹尾端` | 對 `##` 父節點新增得到 `###`;父節點已有子樹時新節排在子樹之後、而非緊貼父節點;層級會超過 6 時回 `NodeDepthExceeded` 且不寫檔 |
| T14 | `store/test/.../NodeSpec.hs` → `removeNode 連子樹一起刪且拒刪根節點` | 刪一個有兩層子孫的 Node 後,子孫全部從檔案與索引消失、兄弟不受影響;對根 Node 呼叫回 `CannotRemoveRootNode` |
| T15 | `store/test/.../ErrorSpec.hs` → `九個新建構子都有非空的繁中訊息` | 逐一 `renderStoreError`,斷言非空、不含 `Left`/建構子名稱之類的原始 `show` 痕跡 |
| T16 | `store/test/.../QuerySpec.hs` → `listLevels 依 status 過濾並回傳全部 Level` | 建三份 Level(兩 canon 一 draft),不帶過濾時三份都在、`efStatus = Just Canon` 時只剩兩份、`efLimit` 生效 |
| T17 | `store/test/.../EndToEndSpec.hs` → `從空 Vault 建出琳達與教室並通過索引重建等價` | 只用本 spec 的函式建出 architecture.md 的兩份範例檔;記下全部查詢結果 → `rm index.db` → `rebuildIndex` → 結果逐項相同 |

## 實作備註

(撰寫時留空)
