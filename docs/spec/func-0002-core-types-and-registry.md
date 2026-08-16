---
id: func-0002
type: spec
title: core-types-and-registry
description: 統一 Meta 與五個核心型別的純函式層與型別註冊表
status: open
created: 2026-08-16
updated: 2026-08-16
depends-on: [func-0001]
related-adr: [adr-0003, adr-0004, adr-0005, adr-0008]
related-spec: [func-0001, func-0003, func-0004]
---

# P1 核心型別與型別註冊表 功能規格

## 功能概述

建立 `storyflow-core`(零 IO 的純型別與純函式)與 `storyflow-types`(型別註冊表的 TOML 載入層)。
這是整個系統的語彙表:後面每一個套件——解析、落地、業務、衝突偵測、介面——都只操作這裡定義的
型別。定義錯了,錯誤會擴散到所有地方;因此本規格的每一條不變量都要有對應的測試。

涵蓋 architecture.md 的:統一 `Meta`、`Entity` / `Level` / `Node`、`LinkKind` 八個核心關聯、
ID 生成、樹的合法性與走訪、關聯圖遍歷、型別註冊表。

**功能邊界**

做:型別定義、純函式(ID 生成、樹驗證與走訪、關聯遍歷、註冊表驗證)、aeson 編解碼、
`types/registry/*.toml` 的載入與驗證、5 份初始型別宣告 TOML。

不做:任何 Markdown 解析(func-0003)、任何檔案讀寫或 SQLite(func-0004)、
工作坊階段的實際執行(P5,本規格只把 `stages` 當資料存下來)。

**`storyflow-types` 為何獨立成一個套件**

ADR-0005 要求 P1 就要做型別宣告的驗證與清楚的錯誤訊息;而 ADR-0001 要求 `core` 零 IO。
讀 `*.toml` 是 IO,所以拆成兩層:`core` 持有 `TypeRegistry` 的純資料模型與純驗證函式,
`types` 只負責「讀檔 + TOML 解析 + 呼叫 core 的驗證」。這讓註冊表的所有規則都能在
零 IO 的情況下被單元測試,`types` 套件本身薄到幾乎不需要測試邏輯,只測讀檔與錯誤彙整。

本規格同時涵蓋這兩個套件,因為它們是同一件事的純/不純兩半,拆成兩份 spec 只會製造
來回查閱的成本。

**驗收標準**

- 五個核心型別(`Meta` / `Entity` / `Link` / `Level` / `Node`)與 architecture.md 的欄位表逐項一致
- ID 生成對相同輸入穩定、對不同輸入分散,且提供碰撞重試的介面
- 樹的五條不變量(單一父、無環、根唯一、無孤兒、同層 `order` 唯一)各有一條反例測試
- `supersedes` 推導出的過時集合正確,且 `contradicts` 能列出所有矛盾對
- 註冊表載入 `types/registry/` 下 5 份 TOML 成功;每一種宣告錯誤都有明確的錯誤訊息與檔名
- `cabal test all` 綠燈

## 相依性

`depends-on: [func-0001]` —— 需要 func-0001 建立的 `core/` 與 `types/` 套件骨架。

本規格是 P1 的關鍵路徑:func-0003(md 解析)與 func-0004(store 落地)都操作這裡定義的型別,
兩者都必須等本規格完成才能實質開工。因此**本規格無法與 P1 的其他工作平行**,應優先完成。

完成後 func-0003 與 func-0004 即可同時開工(見 func-0004 的相依性說明)。

## 實作方式

### 模組劃分

```
storyflow-core (零 IO)
├── StoryFlow.Core.Id          -- Id / IdPrefix / 生成與解析
├── StoryFlow.Core.Meta        -- 統一 Meta 與其列舉
├── StoryFlow.Core.Link        -- LinkKind / Link
├── StoryFlow.Core.Entity      -- Entity
├── StoryFlow.Core.Level       -- Level / Node / NodeKind
├── StoryFlow.Core.Tree        -- 樹的建構、驗證、走訪
├── StoryFlow.Core.Graph       -- 關聯圖遍歷與推論
├── StoryFlow.Core.Registry    -- TypeRegistry 純模型與驗證
└── StoryFlow.Core.Json        -- aeson 實例集中處

storyflow-types (唯一的 IO 是讀檔)
└── StoryFlow.Types.Loader     -- 掃描 types/registry/*.toml → TypeRegistry
```

`StoryFlow.Core.Json` 把 aeson 實例集中在一個模組,而不是散在各型別模組——因為
`meta` 區塊(func-0003)、SQLite 序列化(func-0004)、REST API(P3)、CLI `--json`(P2)
用的是同一套編碼規則,規則只該有一份。

### ID 生成(`StoryFlow.Core.Id`)

architecture.md 定義 ID 為 `<prefix>-<8 hex>`,「從內容 + 時間雜湊」。核心零 IO,
所以時間由呼叫端提供:

```haskell
data IdPrefix = PEnt | PLvl | PNod | PVlt

newtype Id = Id Text            -- 不變量:符合 <prefix>-<8 hex>

-- | 由前綴、內容、時間、salt 產生 ID。純函式:相同輸入必得相同輸出。
--   salt 供碰撞重試使用(見下)。
mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id

parseId  :: Text -> Either IdError (IdPrefix, Id)
renderId :: Id -> Text
```

雜湊採 **FNV-1a 64-bit** 在 core 內自行實作(約 10 行),取低 32 位輸出 8 位十六進位。
選它而不是 SHA-256 的理由:core 要維持零重量級依賴(assetdb 的 `core` 同樣刻意如此),
而這裡不需要密碼學強度——ID 只要夠分散且可重現。

**碰撞處理**:32 位空間在數千個片段的規模下碰撞機率約千分之幾,不可忽略。因此 `mkId` 帶
一個 `salt :: Int` 參數,由呼叫端(func-0004 的 store)在寫入前查索引,若 ID 已存在就
`salt + 1` 重算,直到不重複。core 只保證「相同輸入穩定、不同輸入分散」,唯一性由持有
索引的那一層負責——這是零 IO 的必然分工。

**跨 Vault 定址**(ADR-0008):

```haskell
data Ref = Ref { refVault :: Maybe Text, refId :: Id }

parseRef  :: Text -> Either IdError Ref   -- "ent-7f3a" | "shared-lore:ent-7f3a"
renderRef :: Ref -> Text
```

`refVault = Nothing` 表示本 Vault。所有關聯的 `target` 都是 `Ref`,不是 `Id`——
跨 Vault 引用從型別上就是一等公民,不是後補的字串慣例。

### 統一 Meta(`StoryFlow.Core.Meta`)

逐欄對應 architecture.md 的欄位表(ADR-0003):

```haskell
data Status   = Draft | Canon | Deprecated
data Source   = Human | Agent Text | Workshop Text   -- agent:claude-code / workshop:character
data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }

data Meta = Meta
  { metaId       :: Id
  , metaVault    :: Text
  , metaType     :: Text        -- 註冊表的鍵;core 只當它是字串
  , metaTitle    :: Text
  , metaSummary  :: Text
  , metaTags     :: [Text]
  , metaStatus   :: Status
  , metaTimeline :: Timeline
  , metaAliases  :: [Text]
  , metaLinks    :: [Link]
  , metaSource   :: Source
  , metaRevision :: Int
  , metaCreated  :: Day
  , metaUpdated  :: Day
  }
```

`metaType` 刻意是 `Text` 而非封閉 enum:ADR-0005 的宣告式註冊表要求 core 不認識任何具體
型別。合法性由 `Registry` 在載入後檢查,不由編譯器檢查——這是明確買下的取捨。

輔助純函式:

```haskell
bumpRevision :: Day -> Meta -> Meta        -- revision + 1 且更新 updated
isCanon      :: Meta -> Bool               -- 衝突偵測的比對基準過濾器
renderSource :: Source -> Text             -- "human" / "agent:claude-code"
parseSource  :: Text -> Either MetaError Source
```

### 關聯(`StoryFlow.Core.Link`)

ADR-0005:八個核心建構子 + 一個 `Custom`,讓核心關聯的處理可以窮盡比對。

```haskell
data LinkKind
  = Contradicts | Supersedes | DerivedFrom | PartOf
  | Involves | OccursIn | References | ConvergesTo
  | Custom Text

data Link = Link
  { linkKind   :: LinkKind
  , linkTarget :: Ref
  , linkNote   :: Maybe Text
  }

renderLinkKind :: LinkKind -> Text
parseLinkKind  :: Text -> LinkKind        -- 不在八個核心詞彙內 → Custom

-- | 自訂關聯的名稱與某個核心關聯高度相似時,回傳建議。
--   ADR-0005 的「使用者以為引擎懂『矛盾於』」問題的緩解措施,供 CLI/API 提示用。
suggestCoreKind :: Text -> Maybe LinkKind
```

`parseLinkKind` 不回傳 `Either`:任何字串都是合法關聯,認不得就是 `Custom`。這正是
ADR-0005 的決策——引擎不阻止作者表達,只是不對自訂關聯做推論。

### Entity / Level / Node(`StoryFlow.Core.Entity` / `.Level`)

```haskell
data Entity = Entity { entMeta :: Meta, entBody :: Text }

data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }

data NodeKind = KScene | KCast | KCamera | KInteraction | KDialogue | KBranch

data Node = Node
  { nodMeta     :: Meta
  , nodLevel    :: Id
  , nodParent   :: Maybe Id      -- Nothing = 根節點
  , nodOrder    :: Int           -- 同層兄弟排序
  , nodKind     :: NodeKind
  , nodEntities :: [Ref]         -- 允許多個,建議一個
  }
```

`NodeKind` 是封閉集合(ADR-0003:Node 的 kind 是引擎自己的東西,不進註冊表)。

### 樹的建構與驗證(`StoryFlow.Core.Tree`)

ADR-0004:嚴格樹,合流以 `convergesTo` 標註而不改變結構。

```haskell
data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }

data TreeError
  = MultipleRoots [Id]
  | NoRoot
  | OrphanNode Id Id            -- 節點, 指向的不存在父節點
  | Cycle [Id]                  -- 環上的節點序列
  | DuplicateOrder Id Int [Id]  -- 父節點, order 值, 衝突的子節點
  | DuplicateNodeId Id
  | RootMismatch Id Id          -- Level 宣告的 root, 實際找到的 root

buildTree :: Level -> [Node] -> Either [TreeError] NodeTree
```

`buildTree` **回傳全部錯誤而非第一個**:作者手改 Markdown 後常一次壞好幾處,一次列完
比修一個跑一次有用得多。實作為兩趟——先建 id → Node 的 Map 並收集重複 id,再從根往下
遞迴建樹、以已訪集合偵測環、對每層檢查 `order` 唯一。`convergesTo` 關聯在這裡**完全不看**,
它只是 `metaLinks` 裡的一筆資料,不參與結構。

走訪函式(全部只看父子邊,不跟隨任何關聯):

```haskell
preorder    :: NodeTree -> [Node]
subtreeAt   :: Id -> NodeTree -> Maybe NodeTree
pathTo      :: Id -> NodeTree -> Maybe [Node]     -- 根到該節點
nodesOfKind :: NodeKind -> NodeTree -> [Node]
entitiesIn  :: NodeTree -> [Ref]                  -- 子樹內所有 Node 關聯到的 Entity,去重

-- | 列出所有 convergesTo 標註及其是否指向本 Level 內存在的 Node。
--   ADR-0004 明說合流是標註不是結構,因此只能靠檢查發現懸空——這是 P2
--   `story-flow level lint` 的資料來源,在 core 先備好純函式。
convergenceReport :: NodeTree -> [(Id, Ref, Bool)]
```

### 關聯圖遍歷(`StoryFlow.Core.Graph`)

衝突偵測第 1 層(P4)的純函式基礎,P1 先建好並測透:

```haskell
type LinkGraph = Map Id [Link]        -- 來源端持有,與儲存格式一致

buildGraph :: [Meta] -> LinkGraph

-- | 順著指定的關聯種類走,最多 depth 層,回傳可達集合(不含起點)。
follow :: [LinkKind] -> Int -> Id -> LinkGraph -> Set Ref

-- | 被 supersedes 指到的一律視為過時,遞移閉包。
--   ADR-0005:B 被 A 取代後不再當比對基準。
supersededSet :: LinkGraph -> Set Ref

-- | 所有已知矛盾對。contradicts 語意對稱,但儲存只在來源端,
--   因此輸出正規化為 (較小 id, 較大 id) 以免同一對出現兩次。
contradictionPairs :: LinkGraph -> [(Id, Ref)]
```

`follow` 帶深度上限而非無限展開:關聯圖沒有樹那樣的無環保證(`derivedFrom` 完全可能被
寫成環),深度上限 + 已訪集合是防止無限迴圈的兩道保險。

### 型別註冊表(`StoryFlow.Core.Registry` + `StoryFlow.Types.Loader`)

純模型與純驗證在 core:

```haskell
data FieldSpec = FieldSpec
  { fsName     :: Text          -- 對應 Meta 的欄位名
  , fsRequired :: Bool
  , fsHint     :: Text          -- 給作者與 AI Agent 的提示(ADR-0005)
  }

data EntityTypeSpec = EntityTypeSpec
  { etsKey          :: Text
  , etsName         :: Text
  , etsFields       :: [FieldSpec]
  , etsAllowedLinks :: [LinkKind]
  , etsStages       :: [Text]   -- P5 工作坊用;P1 只存不用
  }

newtype TypeRegistry = TypeRegistry (Map Text EntityTypeSpec)

data RegistryError
  = DuplicateTypeKey Text
  | UnknownMetaField Text Text        -- 型別 key, 欄位名
  | EmptyTypeKey
  | UnknownLinkInAllowed Text Text    -- 型別 key, 關聯名(僅警告等級,見下)

validateRegistry :: [EntityTypeSpec] -> Either [RegistryError] TypeRegistry
lookupType       :: Text -> TypeRegistry -> Maybe EntityTypeSpec
listTypes        :: TypeRegistry -> [EntityTypeSpec]

-- | 檢查一個 Entity 是否符合其型別宣告:必填欄位有值、關聯在 allowed_links 內。
--   回傳警告而非錯誤——ADR-0005 的立場是引導而非阻擋,實際是否拒絕由 service(P2)決定。
checkEntity :: TypeRegistry -> Entity -> [EntityWarning]
```

`UnknownMetaField` 是硬錯誤(TOML 寫了 `Meta` 上不存在的欄位名,一定是打錯);
`allowed_links` 裡出現非核心關聯**不是**錯誤,自訂關聯本來就合法。

載入層在 `storyflow-types`:

```haskell
-- | 掃描目錄下所有 *.toml,逐檔解析,彙整後交給 core 驗證。
--   單檔解析失敗不中斷,繼續讀其餘檔案,最後一次回報全部問題。
loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)

data LoadError
  = TomlParseError FilePath Text      -- 檔名 + 解析器訊息
  | MissingField FilePath Text        -- 檔名 + 缺少的必填鍵
  | RegistryInvalid RegistryError
```

TOML 解析採 **`toml-reader`**(architecture.md 原寫「`tomland` 或 `toml-reader`」,
本規格明確選定):純 Haskell、無 C 相依、API 面積小,而註冊表格式本身很單純,
不需要 `tomland` 的雙向 codec 能力。

錯誤訊息一律帶檔名。ADR-0005 的負面影響那條明說「寫錯只能在載入時檢查並報錯,
因此 P1 就要做清楚的錯誤訊息」——沒有檔名的錯誤訊息在 5 個以上型別檔時等於沒有。

### 初始型別宣告(`types/registry/*.toml`)

隨程式碼版控,5 份,對應 architecture.md 的目錄結構:

```toml
# types/registry/character-fragment.toml
key  = "character-fragment"
name = "角色片段"

[[fields]]
name = "summary"
required = true
hint = "一句話說明這個片段講角色的哪一面(外貌、動機、與某人的關係)"

[[fields]]
name = "timeline"
required = false
hint = "這段設定屬於故事內的哪個時期,可模糊如「崩塌前」"

allowed_links = ["partOf", "occursIn", "contradicts", "supersedes", "references"]
stages = ["定位", "外貌與舉止", "動機與過往", "關係網"]
```

其餘四份(`lore-fragment` / `item-fragment` / `dialogue` / `plot-fragment`)同結構,
欄位提示與 `allowed_links` 依型別調整。`stages` 是 P5 的資料,P1 只驗證它是字串陣列。

### 錯誤處理原則

本套件零 IO,所有失敗都以 `Either e a` 或 `[warning]` 表達,**不拋例外、不用 `error`**。
需要回報多個問題的地方(樹驗證、註冊表驗證、載入)一律回傳清單而非第一個錯誤。
所有錯誤型別都要 `derive (Show, Eq)` 以便測試直接比對。

## 使用到的既有串接介面

func-0001 產出的建置骨架:

| 介面 | 來源 | 用途 |
|---|---|---|
| `cabal.project` 的 `packages:` 與依賴方向 | func-0001 | `core` 零依賴、`types` 依賴 `core` |
| `StoryFlow.Core` / `StoryFlow.Types` 佔位模組 | func-0001 | 本規格建立實際模組後移除 |
| `core/test/Spec.hs` 的 UTF-8 進入點 | func-0001 T6 | 新增的 spec 模組掛在同一個進入點下 |

外部套件介面:

| 介面 | 來源 | 用途 |
|---|---|---|
| `Data.Map.Strict` (`Map`, `insertWith`, `lookup`, `fromListWith`) | `containers` | 註冊表、關聯圖、樹的節點索引 |
| `Data.Set` (`Set`, `member`, `insert`) | `containers` | 走訪的已訪集合、過時集合 |
| `Data.Time.Calendar.Day` / `Data.Time.Clock.UTCTime` | `time` | `created` / `updated` 與 ID 生成的時間輸入 |
| `Data.Aeson` (`ToJSON`, `FromJSON`, `withObject`, `.:?`) | `aeson` | `StoryFlow.Core.Json` 的編解碼 |
| `TOML.decode :: DecodeTOML a => Text -> Either TOMLError a` | `toml-reader` | 型別宣告解析 |
| `System.Directory.listDirectory` | `directory` | 掃描 `types/registry/` |

## 新增的介面

### `storyflow-core`

| 模組 | 介面 |
|---|---|
| `StoryFlow.Core.Id` | `data IdPrefix`, `newtype Id`, `data Ref`, `mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id`, `parseId`, `renderId`, `parseRef`, `renderRef` |
| `StoryFlow.Core.Meta` | `data Meta`, `data Status`, `data Source`, `data Timeline`, `bumpRevision :: Day -> Meta -> Meta`, `isCanon :: Meta -> Bool`, `renderSource`, `parseSource` |
| `StoryFlow.Core.Link` | `data LinkKind`, `data Link`, `renderLinkKind`, `parseLinkKind :: Text -> LinkKind`, `suggestCoreKind :: Text -> Maybe LinkKind` |
| `StoryFlow.Core.Entity` | `data Entity` |
| `StoryFlow.Core.Level` | `data Level`, `data Node`, `data NodeKind`, `renderNodeKind`, `parseNodeKind` |
| `StoryFlow.Core.Tree` | `data NodeTree`, `data TreeError`, `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree`, `preorder`, `subtreeAt`, `pathTo`, `nodesOfKind`, `entitiesIn`, `convergenceReport` |
| `StoryFlow.Core.Graph` | `type LinkGraph`, `buildGraph :: [Meta] -> LinkGraph`, `follow :: [LinkKind] -> Int -> Id -> LinkGraph -> Set Ref`, `supersededSet`, `contradictionPairs` |
| `StoryFlow.Core.Registry` | `data FieldSpec`, `data EntityTypeSpec`, `newtype TypeRegistry`, `data RegistryError`, `data EntityWarning`, `validateRegistry`, `lookupType`, `listTypes`, `checkEntity` |
| `StoryFlow.Core.Json` | `Meta` / `Entity` / `Level` / `Node` / `Link` / `Status` / `Source` / `Timeline` / `Ref` 的 `ToJSON` 與 `FromJSON` 實例 |

### `storyflow-types`

| 模組 | 介面 |
|---|---|
| `StoryFlow.Types.Loader` | `loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)`, `data LoadError`, `renderLoadError :: LoadError -> Text` |

### 資料檔

`types/registry/character-fragment.toml`、`lore-fragment.toml`、`item-fragment.toml`、
`dialogue.toml`、`plot-fragment.toml`

## TodoList

- [ ] T1: `StoryFlow.Core.Id` —— `Id` / `IdPrefix` / `Ref`、FNV-1a 雜湊生成(含 salt)、解析與渲染、跨 Vault `<vault>:<id>` 定址
- [ ] T2: `StoryFlow.Core.Meta` —— `Meta` 全欄位、`Status` / `Source` / `Timeline` 及其文字互轉、`bumpRevision`、`isCanon`
- [ ] T3: `StoryFlow.Core.Link` —— `LinkKind` 八個核心建構子 + `Custom`、`Link`、雙向文字轉換、`suggestCoreKind`
- [ ] T4: `StoryFlow.Core.Entity` 與 `StoryFlow.Core.Level` —— `Entity` / `Level` / `Node` / `NodeKind`
- [ ] T5: `StoryFlow.Core.Tree` 的 `buildTree` 與 `TreeError` —— 五條不變量的檢查,一次回報全部錯誤
- [ ] T6: `StoryFlow.Core.Tree` 的走訪函式 —— `preorder` / `subtreeAt` / `pathTo` / `nodesOfKind` / `entitiesIn` / `convergenceReport`
- [ ] T7: `StoryFlow.Core.Graph` —— `buildGraph` / `follow`(深度上限與防環)/ `supersededSet`(遞移)/ `contradictionPairs`(去重正規化)
- [ ] T8: `StoryFlow.Core.Registry` —— `EntityTypeSpec` 模型、`validateRegistry`、`lookupType`、`checkEntity`
- [ ] T9: `StoryFlow.Core.Json` —— 全部核心型別的 aeson 編解碼
- [ ] T10: `StoryFlow.Types.Loader` —— 掃描目錄、`toml-reader` 解析、錯誤彙整帶檔名
- [ ] T11: 撰寫 `types/registry/` 下 5 份初始型別宣告 TOML

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Core.IdSpec` | 相同 (prefix, 內容, 時間, salt) 得相同 ID;任一項不同則 ID 不同;輸出符合 `<prefix>-<8 hex>`;salt 遞增可產生相異 ID;`parseRef "shared-lore:ent-7f3a"` 得跨 Vault `Ref`,`parseRef "ent-7f3a"` 得 `refVault = Nothing`;格式錯誤字串回 `Left` |
| T2 | `StoryFlow.Core.MetaSpec` | `Status` / `Source` / `Timeline` 的 `render` 與 `parse` 互為反函式(含 `agent:claude-code`、`workshop:character`);`bumpRevision` 使 `revision` 加一且 `updated` 更新為傳入日期;`isCanon` 只對 `Canon` 為真 |
| T3 | `StoryFlow.Core.LinkSpec` | 八個核心關聯 `parse . render == id`;未知字串 `"師承於"` 解析為 `Custom "師承於"` 且不失真;`suggestCoreKind "矛盾於"` 回 `Just Contradicts`,`suggestCoreKind "宿敵"` 回 `Nothing` |
| T4 | `StoryFlow.Core.EntitySpec` | `Entity` / `Level` / `Node` 可建構且欄位齊全,對照 architecture.md 欄位表逐項存在;`NodeKind` 六個建構子的 `render`/`parse` 互為反函式 |
| T5 | `StoryFlow.Core.TreeSpec`(建構) | 合法的教室場景範例建樹成功且結構正確;五個反例各回對應錯誤:兩個 `parent = Nothing` → `MultipleRoots`;指向不存在的父 → `OrphanNode`;A→B→A → `Cycle`;同父兩子 `order` 相同 → `DuplicateOrder`;`Level.root` 與實際根不符 → `RootMismatch`;一次放入多個錯誤時全部回報而非只回第一個 |
| T6 | `StoryFlow.Core.TreeSpec`(走訪) | 以教室場景驗證 `preorder` 順序符合 `order`;`subtreeAt nod-0002` 只含其子樹;`pathTo nod-0005` 得根到該節點的完整路徑;`nodesOfKind KBranch` 得兩個分支節點;`entitiesIn` 去重後含琳達與塔主;`convergenceReport` 找出 `nod-0009 → nod-0010` 且標記為存在,指向不存在 Node 時標記為 `False` |
| T7 | `StoryFlow.Core.GraphSpec` | `follow [PartOf] 1` 只走一層;`follow` 遇到 `derivedFrom` 環時因深度上限與已訪集合而終止不無限迴圈;`supersededSet` 對 A→B→C 的取代鏈回傳 `{B, C}`;`contradictionPairs` 對同一對矛盾只回一筆(正規化順序) |
| T8 | `StoryFlow.Core.RegistrySpec` | 合法宣告集通過 `validateRegistry`;重複 `key` → `DuplicateTypeKey`;欄位名 `summry` → `UnknownMetaField`;`allowed_links` 含自訂關聯**不**產生錯誤;`checkEntity` 對缺少必填 `summary` 的 Entity 回警告,對使用未列於 `allowed_links` 的關聯回警告,合規 Entity 回空清單 |
| T9 | `StoryFlow.Core.JsonSpec` | 對每個核心型別做 `decode . encode == Just x` 的 round-trip;`Timeline` 兩欄皆 `Nothing` 時編碼不產生空鍵;`Ref` 編碼為單一字串 `"vault:id"` 而非物件 |
| T10 | `StoryFlow.Types.LoaderSpec` | 以 `temporary` 建臨時目錄放測試 TOML:正常 3 檔載入成功且 `listTypes` 得 3 筆;某檔 TOML 語法錯誤 → `TomlParseError` 帶該檔名,且**其餘檔案仍被讀取**、錯誤一次回報;缺 `key` → `MissingField` 帶檔名;空目錄回空註冊表而非錯誤 |
| T11 | `StoryFlow.Types.LoaderSpec`(實檔) | 載入專案實際的 `types/registry/` 得 5 個型別,`key` 分別為 `character-fragment` / `lore-fragment` / `item-fragment` / `dialogue` / `plot-fragment`,且全部通過 `validateRegistry` |

## 實作備註

(撰寫時留空)
