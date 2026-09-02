---
id: F001
type: feature
title: core-unified-meta
description: 統一六種節點共用的 Meta、短 id、Link 詞彙與 aeson 編碼規則
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-004, ADR-005, ADR-012, ADR-014]
related-feature: []
---

# F001: 統一 Meta 與節點型別(core-unified-meta)

## 功能概述

`aapms-core` 是 graph-core 三條管線(讀取 / 寫入 / 跨 vault 讀)共用的零 IO 型別層。本 feature 把
舊 story-flow 的 `Aapms.Core.*`(`Entity` 為中心、`metaVault :: Text`、四種 id 前綴、八個核心關聯)
改寫成 ADR-012 統一後的形狀:六種節點(`Entity` / `Asset` / `Pack` / `License` / `Level` / `Node`)
共用同一個 `Meta`,八種 id 前綴(ADR-014),十個核心關聯詞彙(ADR-005 + `uses` / `depicts`),
`AnyNode` 給「不知道是哪種節點」的呼叫端一個統一視角。

**驗收標準**(逐字抄自契約卡,見「對應的 Level 2 契約」章節的查核):

1. 六種節點共用同一個 `Meta` 型別
2. `Status` / `Source` / `LinkKind` 的 JSON 與文字表示是穩定小寫且只有一份
3. `parseRef` 接受 `ent-7f3b2a91` 與 `vlt-a0c4e1f8:ent-7f3b2a91` 兩種寫法
4. `newId` 對同一輸入不同 salt 產生不同 id
5. `buildTree` 拒絕成環、跳級、多重父節點
6. `aapms-core` 的 `build-depends` 不含任何 IO / SQLite / 壓縮 / 影像套件(`CabalSpec` 斷言)

## 相依性

`depends-on: []`——本 feature 是 graph-core 階段一的第一項,`.design/subsystems/graph-core/design.md`
「功能規劃」表中 #2(`registry-family-and-naming`)與 #3(`manifest-schema-v2`)都以 `#1` 為前置,
本身沒有任何文檔依賴。它不呼叫任何其他子系統或既有 feature 文檔定義的介面(見下方「使用到的既有
串接介面」的說明),只讀取**同一個套件內、尚未有 feature 文檔承接的舊程式碼**作為改寫起點,因此
無法與任何其他 feature 平行開發——階段一的 #2、#3 與階段二、三全部 features 都要等本 feature
定案的型別。

DEC-1(委派決策記錄):下游套件已從 `cabal.project` 凍結,本 feature 以外的程式碼(`service` /
`conflict` / `cli` / … 舊碼仍 import 舊 `Aapms.Core.*`)一律不碰、不考慮相容。

## 對應的 Level 2 契約

### 契約 A(全部,`aapms-core`)

- `Meta`(14 欄,`metaVault :: VaultId`、`metaType :: TypeKey`、`metaTimeline :: Maybe Timeline`、
  `metaRevision :: Revision`)
- 具名純量 newtype:`VaultId` / `TypeKey` / `Sha256` / `LogicalName` / `Revision`(建構子匯出;
  `LogicalName` 的建構文法由 #2 的 `mkLogicalName` 守,本 feature 只定義型別本身)
- `AiDisclosure = AiUnknown | AiNone | AiAssisted | AiGenerated`
- `Link` / `Ref`(`refVault :: Maybe VaultId`)/ `LinkKind`(10 個核心建構子 + `Custom Text`,含
  `Uses` / `Depicts`)
- `IdPrefix`(8 個:`PEnt` / `PAst` / `PPck` / `PLic` / `PLvl` / `PNod` / `PVlt` / `PPrj`)
- 六種節點:`Entity` / `Asset` / `Pack`(+ `Author`)/ `License` / `Level` / `Node`
- `NodeTree`、`AnyNode`(六個建構子)、`anyMeta :: AnyNode -> Meta`

### 契約 B(部分,依契約卡指定)

- `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id`
- `parseId :: Text -> Either IdError (IdPrefix, Id)`
- `parseRef :: Text -> Either IdError Ref`
- `renderRef :: Ref -> Text`
- `prefixOf :: AnyNode -> IdPrefix`
- `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree`

**不做**:`checkMeta` / `mkLogicalName` / `parseLogicalName` / `validateLogicalName`(#2)、
`Manifest` / `StoryManifest` / `AssetKey` / `manifestIndex` / `imageMeta` / `audioMeta`(#3)。

### 契約 G(部分)

- `IdError`(全部建構子)

**不做**:`RegistryError` / `NameError` / `MdError` / `StoreError`(其他 feature 或子系統)。

### 明確不做(契約卡逐字)

不讀檔、不解析 Markdown、不碰註冊表載入;不定義命名文法(#2);不定義 Manifest(#3)。

## 實作方式

### 檔案配置(實作自主權,非 Level 2 契約項目)

Level 2 的「內部模組劃分」把契約 A/B/G 這部分全部歸在 `aapms-core` 的「Meta 與節點型別 / Id /
Tree / Json」四個概念桶。桶內實際拆成以下 `.hs` 檔(沿用舊檔名,新增的檔名以現有慣例延伸):

| 檔案 | 內容 |
|---|---|
| `Id.hs` | `IdPrefix`(8 值)、`Id`、`VaultId`(newtype)、`newId`(舊 `mkId` 改名)、`parseId`、`renderId`、`idPrefix`、`Ref`、`localRef`、`parseRef`、`renderRef`、`IdError`、`fnv1a64` |
| `Meta.hs` | `TypeKey` / `Revision`(newtype)、`Status`(+`Missing`)、`Source`(+`Scan`/`Ai`)、`Timeline`、`Meta`、`metaFieldNames`、`bumpRevision`、`isCanon`、`MetaWarning`(型別骨架,見待確認假設 ASM-1)、`MetaError` |
| `Link.hs` | `LinkKind`(+`Uses`/`Depicts`)、`Link`、`coreLinkKinds`、render/parse、`isCoreKind`、`suggestCoreKind`、`LinkGraph`(型別別名,見待確認假設 ASM-2) |
| `Entity.hs` | `Entity`(形狀不變,改吃新 `Meta`) |
| `Asset.hs`(新) | `Sha256` / `LogicalName`(newtype)、`Asset` |
| `Pack.hs`(新) | `AiDisclosure`、`Author`、`Pack` |
| `License.hs`(新) | `License` |
| `Level.hs` | `Level`、`Node`、`NodeKind`(沿用,不變)、`LevelError` |
| `AnyNode.hs`(新) | `AnyNode`、`anyMeta`、`prefixOf` |
| `Tree.hs` | `NodeTree`、`TreeError`、`buildTree`、既有走訪輔助(`preorder`/`subtreeAt`/`pathTo`/`nodesOfKind`/`entitiesIn`/`convergenceReport`)原樣沿用,只改吃新型別——這些函式不在契約 B 的清單內,但也不是新增的對外介面,是既有功能沿用,供子系統外目前還沒設計的衝突偵測日後使用 |
| `Json.hs` | 全系統唯一 aeson 規則:上述全部型別的 `ToJSON`/`FromJSON` |

### 刪除:`Registry.hs`、`Graph.hs`

決策記錄原文:「`Aapms.Core.Registry` 的純驗證與 `checkEntity` 屬 #2 的範圍,本 feature 只需讓它
還能編(或標明交給 #2 改接)」。查證後選擇「標明交給 #2」而非硬改到能編,理由見待確認假設 ASM-1——
`FieldSpec` / `EntityTypeSpec` / `TypeRegistry` 這三個型別在契約 C 整批搬到 `aapms-types`(型別
形狀也變了:`TypeDecl` 取代 `EntityTypeSpec`、多了 `Family` / `tdNameKinds`),留著舊形狀的
`Registry.hs` 只會製造兩份不同形狀的「型別宣告」型別,#2 勢必整份重寫。因此本 feature 直接刪除
`core/src/Aapms/Core/Registry.hs` 與 `core/test/Aapms/Core/RegistrySpec.hs`,`Json.hs` 對應的
`FieldSpec` / `EntityTypeSpec` 孤兒實例一併移除。

`Graph.hs` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 四個函式**不在**
Level 2 契約 B 的清單內(契約 B 只提到型別 `LinkGraph` 本身,經 `aapms-store` 的
`loadLinkGraph :: VaultHandle -> IO LinkGraph` 產生,消費端「衝突偵測第 1 層」屬未來的 `conflict`
子系統,不在 graph-core 範圍)。查證 `design.md` 的「內部模組劃分」表也沒有列出對應的 `Graph`
模組。因此本 feature 只留下 `type LinkGraph = Map Id [Link]` 這個型別別名(併入 `Link.hs`),刪除
`buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 與 `core/test/Aapms/Core/GraphSpec.hs`。
見待確認假設 ASM-2。

### `CabalSpec.hs`(新)

沿用 `conflict` / `llm` / `service` / … 已建立的先例(讀 `.cabal` 檔文字、抓 `build-depends` 逗號開頭
行、比對禁用清單)。禁用清單**逐字取自** `design.md`「使用的技術」一節:

> `aapms-core` **禁止**依賴以上任何一個(`direct-sqlite` / `toml-reader` / `HsYAML` /
> `HsYAML-aeson` / `Win32`)以及 `sqlite-simple` / `zip` / `JuicyPixels`

即 `["direct-sqlite", "toml-reader", "HsYAML", "HsYAML-aeson", "Win32", "sqlite-simple", "zip", "JuicyPixels"]`
八項,不是自行歸納的「IO / SQLite / 壓縮 / 影像套件」分類,是文件明寫的逐字清單。

### `Timeline` 的 `Maybe` 化

決策記錄:`metaTimeline :: Maybe Timeline` 取代 `emptyTimeline` 哨兵。`Meta.hs` 移除
`emptyTimeline` / `isEmptyTimeline` 匯出;`Json.hs` 的 `metaPairs` 只在 `Just` 時輸出 `"timeline"`
鍵,`parseMetaFields` 用 `o .:? "timeline"` 直接得到 `Maybe Timeline`(不再 `.!= emptyTimeline`)。

### `buildTree` 的驗收標準對應

契約卡「拒絕成環、跳級、多重父節點」對應既有 `TreeError` 的三類建構子,邏輯不變、只換型別:
`Cycle`(成環)、`OrphanNode`(跳級——作者手改 Markdown 標題層級跳過中間層,子節點指向的父節點
不存在)、`MultipleRoots`(多重父節點——多個節點同時宣告自己無父,等同樹有多個「頂端」)。

### `newId` 對同一輸入不同 salt 產生不同 id

既有 `mkId`(現改名 `newId`)已把 `salt` 併入雜湊 payload(`core/src/Aapms/Core/Id.hs:92-94`),
邏輯不變,只是重新命名以符合契約 B 的函式名。

## 使用到的既有串接介面

本 feature 是三條管線共用的最底層,`depends-on: []`,**不呼叫**任何其他子系統或既有 feature 文檔
定義的介面。以下記錄的是查證過的「舊程式碼現況」,作為本次改寫的起點與對照基準(來源文檔一律
`-`,因為這些簽名沒有任何 feature 文檔承接過,是移植前的原始碼):

| 介面(舊簽名,查證原文) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `mkId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:88-94` | - | 改名為 `newId`,雜湊邏輯不變 |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/Aapms/Core/Id.hs:112-120` | - | 原樣沿用,不變 |
| `parseRef :: Text -> Either IdError Ref` | `core/src/Aapms/Core/Id.hs:146-151` | - | `refVault` 型別由 `Maybe Text` 改 `Maybe VaultId`,解析邏輯不變 |
| `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/Aapms/Core/Tree.hs:86-144` | - | 五條不變量邏輯原樣沿用,只換 `Meta` 型別 |
| `data IdPrefix = PEnt \| PLvl \| PNod \| PVlt` | `core/src/Aapms/Core/Id.hs:43-48` | - | 擴充成 8 值(加 `PAst`/`PPck`/`PLic`/`PPrj`) |
| `data Status = Draft \| Canon \| Deprecated` | `core/src/Aapms/Core/Meta.hs:39-43` | - | 擴充成 4 值(加 `Missing`) |
| `data Source = Human \| Agent Text \| Workshop Text` | `core/src/Aapms/Core/Meta.hs:59-65` | - | 擴充成 5 值(加 `Scan`/`Ai Text`) |
| `data LinkKind = Contradicts \| … \| ConvergesTo \| Custom Text`(8+1) | `core/src/Aapms/Core/Link.hs:22-41` | - | 擴充成 10+1(加 `Uses`/`Depicts`) |
| `checkEntity :: TypeRegistry -> Entity -> [EntityWarning]` | `core/src/Aapms/Core/Registry.hs:171-190` | - | **不沿用**:改成 `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`,屬 #2;本 feature 只刪除舊實作、留 `MetaWarning` 型別骨架 |

## 新增的介面

### 具名純量(newtype,建構子匯出)

```haskell
newtype VaultId     = VaultId Text
newtype TypeKey     = TypeKey Text
newtype Sha256      = Sha256 Text
newtype LogicalName = LogicalName Text
newtype Revision    = Revision Int
```

### 列舉

```haskell
data IdPrefix = PEnt | PAst | PPck | PLic | PLvl | PNod | PVlt | PPrj
data Status   = Draft | Canon | Deprecated | Missing
data Source   = Human | Agent Text | Workshop Text | Scan | Ai Text
data AiDisclosure = AiUnknown | AiNone | AiAssisted | AiGenerated
data LinkKind = Contradicts | Supersedes | DerivedFrom | PartOf | Involves
              | OccursIn | References | ConvergesTo | Uses | Depicts | Custom Text
```

### 節點型別

```haskell
data Meta = Meta
  { metaId :: Id, metaVault :: VaultId, metaType :: TypeKey, metaTitle :: Text
  , metaSummary :: Text, metaTags :: [Text], metaStatus :: Status
  , metaTimeline :: Maybe Timeline, metaAliases :: [Text], metaLinks :: [Link]
  , metaSource :: Source, metaRevision :: Revision, metaCreated :: Day, metaUpdated :: Day
  }

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
data AnyNode = NEntity Entity | NAsset Asset | NPack Pack | NLicense License | NLevel Level | NNode Node

anyMeta  :: AnyNode -> Meta
prefixOf :: AnyNode -> IdPrefix
```

### Id 與定址

```haskell
newId     :: IdPrefix -> Text -> UTCTime -> Int -> Id
parseId   :: Text -> Either IdError (IdPrefix, Id)
parseRef  :: Text -> Either IdError Ref
renderRef :: Ref -> Text
```

### 樹

```haskell
buildTree :: Level -> [Node] -> Either [TreeError] NodeTree
```

### 錯誤與待接手型別骨架

```haskell
data IdError = BadIdFormat Text | UnknownIdPrefix Text | BadRefFormat Text

-- 待確認假設 ASM-1:形狀由本 feature 定,checkMeta 的實作屬 #2
data MetaWarning
  = MissingRequiredField TypeKey Text
  | LinkNotAllowed TypeKey Text
  | UnknownNodeType TypeKey
  | NameKindNotAllowed TypeKey Text

-- 待確認假設 ASM-2:只留型別別名,不含走訪函式
type LinkGraph = Map Id [Link]
```

## TodoList

- [x] STEP-1: `Id.hs`:`VaultId` newtype、`IdPrefix` 擴充 8 值、`mkId` 改名 `newId`、`Ref`/`parseRef` 改用 `VaultId`  `dep: -`
- [x] STEP-2: `Meta.hs`:`TypeKey`/`Revision` newtype、`Status` 加 `Missing`、`Source` 加 `Scan`/`Ai`、`Timeline` 改 `Maybe`、`Meta` 逐欄改型別、`MetaWarning` 型別骨架、`metaFieldNames`/`bumpRevision`/`isCanon`/`MetaError` 更新  `dep: T1`
- [x] STEP-3: `Link.hs`:`LinkKind` 加 `Uses`/`Depicts`、`LinkGraph` 型別別名併入  `dep: T1`
- [x] STEP-4: `Entity.hs`:改吃新 `Meta`  `dep: T2`
- [x] STEP-5: `Asset.hs`(新):`Sha256`/`LogicalName` newtype、`Asset` 型別  `dep: T1, T2`
- [x] STEP-6: `Pack.hs`(新):`AiDisclosure`、`Author`、`Pack` 型別  `dep: T2, T5`
- [x] STEP-7: `License.hs`(新):`License` 型別  `dep: T2`
- [x] STEP-8: `Level.hs`:`Level`/`Node` 改吃新 `Meta`/`Id`,`NodeKind` 沿用  `dep: T1, T2`
- [x] STEP-9: `AnyNode.hs`(新):`AnyNode`、`anyMeta`、`prefixOf`  `dep: T4, T5, T6, T7, T8`
- [x] STEP-10: `Tree.hs`:`buildTree` 與既有走訪函式改吃新型別  `dep: T8`
- [x] STEP-11: 刪除 `Registry.hs` / `RegistrySpec.hs`;`Graph.hs` 併入 `Link.hs` 後刪除、刪除 `GraphSpec.hs`  `dep: T3`
- [x] STEP-12: `Json.hs`:移除 `FieldSpec`/`EntityTypeSpec` 孤兒實例,新增全部新型別的 `ToJSON`/`FromJSON`  `dep: T2, T4, T5, T6, T7, T8, T9, T10`
- [x] STEP-13: `aapms-core.cabal`:`exposed-modules` 移除 `Registry`/`Graph`、加入 `Asset`/`Pack`/`License`/`AnyNode`  `dep: T1..T12`
- [x] STEP-14: 新增 `core/test/Aapms/Core/CabalSpec.hs`(斷言 8 項禁用套件不在 `build-depends`)  `dep: T13`
- [x] STEP-15: 重寫 `Fixtures.hs`(新 `Meta` 形狀、六種節點 fixture)  `dep: T12`
- [x] STEP-16: 重寫既有 Spec:`IdSpec` / `MetaSpec` / `LinkSpec` / `EntitySpec` / `TreeSpec` / `JsonSpec`  `dep: T15`
- [x] STEP-17: 新增 `AssetSpec` / `PackSpec` / `LicenseSpec` / `AnyNodeSpec`  `dep: T15`
- [x] STEP-18: 更新 `core/test/Spec.hs` 的 describe 清單(移除 Registry/Graph、加入新 Spec)  `dep: T16, T17`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| STEP-1 | test_id_newtypes_and_prefixes | `newId` 同輸入不同 salt 得不同 id;8 種 `IdPrefix` render/parse 互為反函式;`parseRef` 接受 `ent-7f3b2a91` 與 `vlt-a0c4e1f8:ent-7f3b2a91` |
| STEP-2 | test_meta_status_source_extended | `Status`/`Source` 4/5 值 render/parse 互為反函式(含 `Missing`/`Scan`/`Ai`);`bumpRevision` 對 `Revision` newtype 正確 +1 |
| STEP-3 | test_link_uses_depicts_and_linkgraph | `coreLinkKinds` 含 `Uses`/`Depicts`,render 為 `"uses"`/`"depicts"`;`LinkGraph` 可放入 `Map.fromList` 並查詢 |
| STEP-4 | test_entity_shape | `Entity` 以新 `Meta` 建構、欄位存取正確 |
| STEP-5 | test_asset_shape | `Asset` 全欄位建構與存取,`Sha256`/`LogicalName` 建構子可直接使用 |
| STEP-6 | test_pack_shape | `Pack` 全欄位建構,`pckAiDisclosure` 4 值可用,`Author` 三欄位 |
| STEP-7 | test_license_shape | `License` 9 個欄位(不含 `licMeta`)全部可建構與讀取 |
| STEP-8 | test_level_node_shape | `Level`/`Node` 以新 `Meta`/`Id` 建構,`NodeKind` 6 值 render/parse 不變 |
| STEP-9 | test_anynode_prefixof | 六種建構子的 `anyMeta` 回傳正確 `Meta`;`prefixOf` 對六種建構子回傳對應 `IdPrefix`(`NEntity`→`PEnt` 等) |
| STEP-10 | test_buildtree_invariants | 成環(`Cycle`)、跳級(`OrphanNode`)、多重父節點(`MultipleRoots`)三種壞資料各自被 `buildTree` 拒絕;合法教室場景 fixture 建樹成功 |
| STEP-11 | test_registry_graph_removed | `aapms-core.cabal` 文字裡不再出現 `Aapms.Core.Registry` / `Aapms.Core.Graph`;`Aapms.Core.Link` 匯出 `LinkGraph` 可用 |
| STEP-12 | test_json_roundtrip_all_nodes | 六種節點與 `AnyNode` 的 `ToJSON`/`decode`(用 `eitherDecodeStrictText`)roundtrip 相等;`metaTimeline = Nothing` 時輸出無 `"timeline"` 鍵;`Ref` 兩種寫法 encode/decode |
| STEP-13 | test_cabal_exposed_modules | `exposed-modules` 含 `Aapms.Core.Asset`/`Pack`/`License`/`AnyNode`,不含 `Registry`/`Graph` |
| STEP-14 | test_cabalspec_forbidden_deps | `build-depends` 不含 8 項禁用套件名(逐字比對) |
| STEP-15 | test_fixtures_build | `Fixtures.hs` 產生的六種節點 fixture 可被其餘 Spec 匯入使用,不編譯錯誤 |
| STEP-16 | test_existing_specs_pass | 6 個既有 Spec 全數以新型別重寫後綠燈 |
| STEP-17 | test_new_type_specs_pass | 4 個新 Spec 綠燈 |
| STEP-18 | test_spec_registration | `core/test/Spec.hs` 的 `describe` 清單引用全部現存 Spec、不引用已刪除的 `RegistrySpec`/`GraphSpec` |

## 待確認假設

- ASM-1: `MetaWarning` 的確切建構子清單(`MissingRequiredField` / `LinkNotAllowed` / `UnknownNodeType` /
  `NameKindNotAllowed`)是依 F002 契約卡驗收標準文字(「`checkMeta` 對 asset 檢查 `name` 第一段在該
  型別的 `name_kinds` 內、關聯在 `allowed_links` 內」)反推的最小合理形狀,`checkMeta` 本身**不**在
  本 feature 實作 → 採取:先把型別骨架放進 `Meta.hs` 供後續 import,`checkMeta` 的呼叫邏輯與
  `TypeRegistry` 相依留給 #2 → 影響:若 #2 需要更多警告種類(例如型別未宣告 `dir`),`MetaWarning`
  要加建構子,不影響 F001 已完成的其餘型別
- ASM-2: `Aapms.Core.Graph` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 四個
  純函式判定為**不在**本次 Level 2 契約範圍(design.md 契約 B 與「內部模組劃分」都沒有列出),
  只留 `LinkGraph` 型別別名 → 採取:刪除四個函式與 `GraphSpec.hs`,`LinkGraph` 併入 `Link.hs` →
  影響:若編排者認為這四個函式仍是「三條管線共用的型別層」該提供的能力(例如衝突偵測子系統設計
  時想直接沿用),需要回頭修 `design.md` 契約 B 補上這幾個函式簽名,再開一個小 feature 或併入
  日後的 `conflict` 子系統設計時原樣移植
- ASM-3: `aapms-core.cabal` 的 `CabalSpec.hs` 禁用清單固定抄 design.md「使用的技術」一節逐字列出的
  8 個套件名,不做「凡出現 IO / SQLite / 壓縮 / 影像類套件就擋」的模糊分類判斷(那需要套件分類
  知識庫,超出本 feature 範圍)→ 採取:逐字清單,新出現的違規套件名不會被這條測試攔下 → 影響:
  若日後 `aapms-core` 意外多相依一個沒列在清單裡的重量級套件,這條測試不會變紅,需要人工發現後
  補清單

## 實作備註

- `Entity.hs` 與 `Tree.hs` 的原始碼一字未動:兩者只透過抽象的 `Meta` / `Id` 型別
  操作(`metaId`、`metaLinks`、`nodMeta` 等存取器),STEP-4 與 STEP-10 完全由下游型別
  (`Meta`、`Ref`)換形狀後自動吃到新契約,不需要任何程式碼變更。
- `AnyNode` 的 `FromJSON` 沒有另外的判別鍵——解碼時讀 `id` 欄位的前綴決定要
  用哪一種節點的 `FromJSON`(`prefixOf` 的反函式)。這是內部實作自主權範圍
  內的選擇:id 前綴本來就唯一對應節點種類(ADR-014),不需要再多一個
  `"kind"` 欄位重複這件事。`vlt` / `prj` 前綴不對應任何 `AnyNode` 建構子,
  解碼時回傳明確的 `fail` 訊息。
- `Asset` / `Pack` / `License` 的 JSON 鍵名採用 design.md「索引結構」表中
  `assets` / `packs` / `licenses` 表的 snake_case 欄位名(如 `source_url`、
  `ai_disclosure`、`attribution_required`),讓未來 `aapms-store` 的欄位映射
  與這裡的 JSON 形狀一致,減少之後對照的心智負擔——這也是實作自主權範圍內
  的選擇,Level 2 契約沒有規定 JSON 鍵名。
- `License` 的 `licCommercial` / `licAttributionRequired` 在 JSON 中為必填
  (`.:` 而非 `.:?`),呼應 design.md md-unified-sections 契約卡「`commercial`
  與 `attribution_required` 除外,缺漏是錯誤」的既定政策,提前套用到本層的
  JSON 編碼。
- `AiDisclosure` 的 `FromJSON` 對不在四個合法字面值內的字串直接失敗,不吞成
  `AiUnknown`;「缺漏視為 unknown」由呼叫端(`Pack` 的 `.:? "ai_disclosure"
  .!= AiUnknown`)處理,兩種情境(缺鍵 vs. 打錯字)分開處理。
- `CabalSpec.hs` 沿用 `conflict` / `service` 等既有套件的先例(讀 `.cabal`
  檔文字、抓逗號開頭的 `build-depends` 行、逐字比對禁用清單),而非嘗試對
  `exposed-modules` 也做逐行解析——`isInfixOf` 對模組名稱字串已經足夠精確,
  不會與禁用套件名或其他文字誤觸發。
