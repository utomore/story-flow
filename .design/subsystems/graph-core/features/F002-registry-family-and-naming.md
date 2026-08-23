---
id: F002
type: feature
title: registry-family-and-naming
description: 型別註冊表加 family 與 asset 八族、naming.toml 詞彙、命名文法改吃注入詞彙
status: open
created: 2026-08-23
updated: 2026-08-23
depends-on: [F001]
related-adr: [ADR-005, ADR-019]
related-feature: []
---

# F002: 註冊表 `family` 與命名文法(registry-family-and-naming)

## 功能概述

把型別註冊表從「只有五種 entity 族」擴充成「entity 族 + 八種 asset 族」,並把 assetdb 的命名文法
(`AssetDB.Naming`)搬進 `aapms-core`、改吃註冊表載入的詞彙(`NamingVocab`)而不是編譯期常數。
`aapms-types` 只保留 IO(定位、讀檔、TOML 解析),純型別與純驗證全部在 `aapms-core`(D7)。

**驗收標準**(逐字抄自契約卡):

1. `types/registry/` 含原五種 entity 族 + 八種 asset 族 + `naming.toml`
2. `asset-pack` / `asset-license` / `level` 出現在註冊表是載入錯誤
3. 載入失敗讓程序失敗,不退回空註冊表
4. `checkMeta` 對 asset 檢查 `name` 第一段在該型別的 `name_kinds` 內、關聯在 `allowed_links` 內,
   只回警告
5. `validateLogicalName` 對 `ui_gui_travel-book-frame_001` 通過、對非 ASCII / 超過 64 字元 /
   少於三段拒絕
6. `defaultVocab` 與 DB `naming_vocab` 表都不存在

## 相依性

`depends-on: [F001]`——本 feature 的全部型別都建立在 F001 定義的 `Meta` / `AnyNode` / `TypeKey` /
`LinkKind` / `LogicalName` / `MetaWarning` 骨架之上(`checkMeta :: TypeRegistry -> AnyNode ->
[MetaWarning]` 直接吃 F001 的 `AnyNode` 與 `MetaWarning`;`TypeDecl` 的 `tdAllowedLinks ::
[LinkKind]` 直接吃 F001 的 `LinkKind`)。F001 status 為 `open`(設計已定案、尚未實作),因此下表
「使用到的既有串接介面」對 F001 定義但程式碼裡還沒有的型別,來源文檔一律填 `F001`,不引用不存在
的程式碼。

本 feature 不依賴 graph-core 之外的任何 feature 文檔;`manifest-schema-v2`(#3)、
`md-unified-sections`(#4)才反過來依賴本 feature 定案的 `TypeRegistry` / `NamingVocab`。

D1(委派決策記錄):graph-core 以外的程式碼(`service` / `conflict` / `cli` / … 舊碼仍 import 舊
`Aapms.Core.Registry` 與 `Aapms.Types.Loader`)一律不碰、不考慮相容。

## 對應的 Level 2 契約

### 契約 C(全部,套件歸屬依 2026-08-23 D7 裁決)

- `Family = FEntity | FAsset`、`TypeDecl`(9 欄,含 `tdNameKinds :: [Segment]`)、`TypeRegistry`、
  `NamingVocab { nvKinds :: [Segment], nvDomains :: [Segment] }`、`lookupType`——**定義在
  `aapms-core`**(`Aapms.Core.Registry`)
- `locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))`、
  `loadRegistry :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))`——
  **定義在 `aapms-types`**(`Aapms.Types.Loader`),並 re-export 上一項的全部型別
- `asset-pack` / `asset-license` / `level` 是保留鍵,出現在註冊表是載入錯誤
- 載入失敗讓程序失敗,不退回空註冊表

### 契約 B(部分,依契約卡指定)

- `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`(`aapms-core`,吃 F001 的 `AnyNode` /
  `MetaWarning`)
- `mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName`
- `parseLogicalName :: Text -> Either NameError NameParts`
- `validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()`

**不做**:契約 B 其餘函式(`newId` / `parseId` / `parseRef` / `renderRef` / `prefixOf` /
`buildTree` / `Manifest` 一組)屬 #1 / #3。

### 契約 G(部分)

- `RegistryError`(全部建構子,涵蓋純驗證與 TOML 載入兩類問題)
- `NameError`(全部建構子)

**不做**:`IdError`(#1)、`MdError` / `StoreError`(其他子系統 feature)。

### 明確不做(契約卡逐字)

不決定警告要不要擋;不做叢集推論(`asset-ingest`);不改 `dir` / `owner_type` 語意。

## 相依性查證

### 舊 `Aapms.Core.Registry`(本 feature 整份重寫的起點)

- `data EntityTypeSpec = EntityTypeSpec { etsKey :: Text, etsName :: Text, etsFields :: [FieldSpec],
  etsAllowedLinks :: [LinkKind], etsStages :: [Text], etsDir :: Maybe Text, etsOwnerType :: Maybe Text }`
  —— `core/src/Aapms/Core/Registry.hs:49-69`
- `newtype TypeRegistry = TypeRegistry (M.Map Text EntityTypeSpec)` —— `core/src/Aapms/Core/Registry.hs:71-72`
- `reservedTypeKeys :: [Text]` `= ["level"]` —— `core/src/Aapms/Core/Registry.hs:81-82`
- `validateRegistry :: [EntityTypeSpec] -> Either [RegistryError] TypeRegistry` —— `core/src/Aapms/Core/Registry.hs:114-144`
  (回報**全部**錯誤,不是第一個;本 feature 延續這個立場,見「實作方式」的 `RegistryErrors` 設計)
- `lookupType :: Text -> TypeRegistry -> Maybe EntityTypeSpec` —— `core/src/Aapms/Core/Registry.hs:146-147`
- `listTypes :: TypeRegistry -> [EntityTypeSpec]` —— `core/src/Aapms/Core/Registry.hs:150-151`
- `lookupDir :: Text -> TypeRegistry -> Maybe Text` —— `core/src/Aapms/Core/Registry.hs:161-166`
- `checkEntity :: TypeRegistry -> Entity -> [EntityWarning]` —— `core/src/Aapms/Core/Registry.hs:171-190`
  (**不沿用**:改成吃 `AnyNode` 的 `checkMeta`,涵蓋 asset 的 `name_kinds` 檢查)
- `fieldPresent :: Text -> Meta -> Bool` —— `core/src/Aapms/Core/Registry.hs:196-214`(逐欄判斷某個
  `Meta` 欄位是否「有填」;邏輯原樣沿用,只把 `metaTimeline` 的判斷從 `tlLabel`/`tlOrder` 改成
  `Maybe Timeline` 的 `isJust`,因為 F001 把 `metaTimeline` 改成 `Maybe`)

### 舊 `Aapms.Types.Loader`(本 feature 整份重寫的起點)

- `locateRegistry :: IO (Maybe (RegistrySource, FilePath))` —— `types/src/Aapms/Types/Loader.hs:86-87`
  (簽名改為 `IO (Either RegistryError (FilePath, RegistrySource))`——找不到時要說出「查過哪裡」,
  `Maybe` 沒有這個表達力)
- `locateRegistryWith :: IO FilePath -> IO (Maybe (RegistrySource, FilePath))` —— `types/src/Aapms/Types/Loader.hs:100-114`
  (三層定位邏輯——環境變數 → 執行檔旁 → `data-files`——原樣沿用,只改回傳型別)
- `registryEnvVar :: String` `= "STORYFLOW_REGISTRY"` —— `types/src/Aapms/Types/Loader.hs:54-55`
  (**不改名**:system.md「P0 進度」明寫 `STORYFLOW_*` 環境變數是刻意留到 P3 由 `workspace` 依
  ADR-017 改的執行期名稱,graph-core 不碰)
- `registryBesideExecutable :: IO FilePath` —— `types/src/Aapms/Types/Loader.hs:93-94`(不變)
- `defaultRegistryDir :: IO (Maybe FilePath)` —— `types/src/Aapms/Types/Loader.hs:117-118`(簽名不變,
  是既有函式的投影,契約 C 沒提到它但也沒說要拿掉,保留)
- `data LoadError = TomlParseError FilePath Text | MissingField FilePath Text | BadFieldType FilePath
  Text Text | UnknownKey FilePath Text | RegistryDirMissing FilePath | RegistryInvalid RegistryError`
  —— `types/src/Aapms/Types/Loader.hs:120-134`(併入新的統一 `RegistryError`,見「實作方式」)
- `loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)` —— `types/src/Aapms/Types/Loader.hs:154-162`
  (簽名改為 `IO (Either RegistryError (TypeRegistry, NamingVocab))`)
- `loadRegistryFrom :: [FilePath] -> IO (Either [LoadError] TypeRegistry)` —— `types/src/Aapms/Types/Loader.hs:165-175`
  (掃描目錄改為排除 `naming.toml`,見「實作方式」)
- `readSpec` / `parseSpec` / `topLevelKeys` / `fieldKeys` / `fieldSpec` / 取值輔助
  (`reqString` / `optString` / `optMaybeString` / `optBool` / `optArray` / `optStrings`)——
  `types/src/Aapms/Types/Loader.hs:178-300`,解析邏輯原樣沿用,`topLevelKeys` 加入 `family` /
  `name_kinds` 兩個新鍵

### `types/registry/*.toml`(五份既有宣告,格式不變只加一行)

- 範例讀原文:`types/registry/character-fragment.toml:5-15`(`key` / `name` / `dir` / `owner_type` /
  `allowed_links` / `stages` / `[[fields]]`)。其餘四份(`dialogue.toml` / `item-fragment.toml` /
  `lore-fragment.toml` / `plot-fragment.toml`)同構,本 feature 只逐檔加一行 `family = "entity"`,
  不改其餘內容

### `types/aapms-types.cabal`

- `data-files: registry/*.toml` —— `types/aapms-types.cabal:12`(不變,`naming.toml` 與新的 8 份
  asset TOML 都落在同一個 `registry/` 目錄,自動涵蓋)
- `exposed-modules: Aapms.Types.Loader` —— `types/aapms-types.cabal:29-30`(不變,re-export 靠模組
  匯出清單完成,不需要新模組)

### `legacy/assetdb/core/src/AssetDB/Naming.hs`(命名文法的移植起點)

- `newtype Segment = Segment Text`,`mkSegment :: Text -> Either NameError Segment`,規則
  `^[a-z0-9]+(-[a-z0-9]+)*$` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:78-100`(規則原樣沿用)
- `maxLogicalNameLength :: Int` `= 64` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:125-126`(不變)
- `data NameParts = NameParts { npKind :: KindPrefix, npDomain :: Segment, npSubject :: Segment,
  npVariant :: Maybe Segment, npState :: Maybe Segment, npIndex :: Maybe Int }` ——
  `legacy/assetdb/core/src/AssetDB/Naming.hs:129-147`(**形狀改變**,見「實作方式」的 A1)
- `data NameError = EmptySegment | BadSegment Text | NoAsciiContent Text | TooLong Int Text |
  UnknownKindPrefix Text | TooFewSegments Int Text | AmbiguousTrailing [Text] Text |
  SubjectLooksLikeModifier Text | IndexOutOfRange Int` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:153-167`
  (`SubjectLooksLikeModifier` 不沿用,見 A1)
- `data NamingVocab = NamingVocab { nvStates :: Set Text, nvVariants :: Set Text }`,
  `defaultVocab :: NamingVocab` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:209-242`(**不沿用**:
  契約 C 的 `NamingVocab` 形狀是 `{ nvKinds :: [Segment], nvDomains :: [Segment] }`,與這裡的
  `nvStates`/`nvVariants` 是兩組不同的欄位;`defaultVocab` 的 27 個 state 詞與 17 個 variant 詞
  **不移植**,見 A1 的完整推導)
- `mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:279-289`
  (改吃契約 C 的新 `NamingVocab`,`isModifierLike` 檢查改成 `nvKinds` 成員檢查)
- `parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:323-356`
  (**簽名改變**:契約 B 的 `parseLogicalName :: Text -> Either NameError NameParts` 拿掉了
  `NamingVocab` 參數,右往左剝 state/variant 的演算法失去存在條件,改成位置式解析,見 A1)
- `validateLogicalName :: Text -> Either NameError LogicalName` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:313-316`
  (**簽名改變**:契約 B 是 `NamingVocab -> TypeKey -> LogicalName -> Either NameError ()`)
- `isVariantShaped` / `isIndexShaped` / `variantFromNumber` / `indexSegment` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:248-270`
  (`isIndexShaped` / `indexSegment` 沿用;`isVariantShaped` / `variantFromNumber` 不沿用,見 A1)
- `renderParts :: NameParts -> Either NameError Text` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:299-307`
  (改吃新 `NameParts` 形狀,邏輯同構:`kind_domain_subject` 後依序接 modifiers、index)

### `legacy/assetdb/core/src/AssetDB/Types.hs`(`name_kinds` 對應表的來源,D5 指定)

- `data AssetKind = KImage | KAudio | KFont | KLevel | KShader | KDoc | KSource | KArchive` ——
  `legacy/assetdb/core/src/AssetDB/Types.hs:70-79`,`toTextEnum`(`legacy/assetdb/core/src/AssetDB/Types.hs:81-90`)
  給出小寫文字:`image` / `audio` / `font` / `level` / `shader` / `doc` / `source` / `archive`——
  與 D 給定的八個 asset 型別鍵一一對應(`asset-<toTextEnum AssetKind>`)
- `data KindPrefix = PSpr | PTex | PAtlas | PUi | PFnt | PSfx | PBgm | PVo | PLvl | PShd | PSrc |
  PDoc` —— `legacy/assetdb/core/src/AssetDB/Types.hs:108-121`,`toTextEnum`(`:123-127`)給出:
  `spr` / `tex` / `atlas` / `ui` / `fnt` / `sfx` / `bgm` / `vo` / `lvl` / `shd` / `src` / `doc`
  (12 個)
- `prefixKind :: KindPrefix -> AssetKind` —— `legacy/assetdb/core/src/AssetDB/Types.hs:130-138`,
  `kindPrefixes :: AssetKind -> [KindPrefix]` —— `:141-142`(多對一;逐一算出下表)

**讀到的對應表**(`kindPrefixes` 逐一代入 8 個 `AssetKind` 算出):

| asset 型別鍵 | `AssetKind` | `name_kinds`(`KindPrefix` 的文字表示) |
|---|---|---|
| `asset-image` | `KImage` | `spr`, `tex`, `atlas`, `ui` |
| `asset-audio` | `KAudio` | `sfx`, `bgm`, `vo` |
| `asset-font` | `KFont` | `fnt` |
| `asset-level` | `KLevel` | `lvl` |
| `asset-shader` | `KShader` | `shd` |
| `asset-doc` | `KDoc` | `doc` |
| `asset-source` | `KSource` | `src` |
| `asset-archive` | `KArchive` | **(空)**——`kindPrefixes KArchive == []`,12 個 `KindPrefix` 沒有任何一個對應到 `KArchive`(`prefixKind` 的窮盡比對裡沒有任何分支指向它) |

`naming.toml` 的 `kinds` 詞彙 = 這 12 個 `KindPrefix` 文字值的聯集(`spr` / `tex` / `atlas` / `ui` /
`fnt` / `sfx` / `bgm` / `vo` / `lvl` / `shd` / `src` / `doc`)——即全系統合法的「kind」分段值,見 A1。

### `contract/fixtures/naming-cases.txt` 與 `contract/test/Aapms/Contract/NamingGrammarSpec.hs`

- 7 個合法案例、6 個非法案例,逐行格式 `ok <名稱>` / `bad <名稱>  # 理由` —— 全文已讀,見「實作方式」
  逐案代入驗證新演算法(A1)
- `NamingGrammarSpec.hs:50-51`:第三個 `it` 目前是 `pendingWith`,註解明寫「等 F002 落地後改為逐行
  呼叫 `aapms` 驗證」——但 D「contract 套件本身已凍結,不要改它」,因此本 feature **不修改**
  `contract/` 底下任何檔案;改為在 `aapms-core` 的新測試(`NamingCasesSpec.hs`)讀同一份
  `fixtures/naming-cases.txt`、逐行呼叫新的 `parseLogicalName` / `mkLogicalName` 驗證,把契約卡的
  驗收輸入納入 1-to-1 測試(T13)

## 實作方式

### 套件內模組配置

| 套件 | 檔案 | 內容 |
|---|---|---|
| `aapms-core` | `Registry.hs`(重寫) | `Family`、`FieldDecl`、`TypeDecl`、`TypeRegistry`、`buildRegistry`、`lookupType`、`listTypes`、`lookupDir`、`reservedTypeKeys`(擴充 3 項)、`checkMeta`、`RegistryError` |
| `aapms-core` | `Naming.hs`(新) | `Segment`、`mkSegment`、`segmentText`、`NameParts`、`NamingVocab`、`NameError`、`mkLogicalName`、`parseLogicalName`、`validateLogicalName`、`renderParts`、`maxLogicalNameLength`、`indexSegment`、`isIndexShaped` |
| `aapms-types` | `Loader.hs`(重寫) | `locateRegistry` / `loadRegistry` 新簽名、`naming.toml` 專屬解析、`family` / `name_kinds` 解析、re-export `Aapms.Core.Registry` 與 `Aapms.Core.Naming` 的型別 |
| `types/registry/` | `naming.toml`(新) | `kinds` / `domains` 兩個字串陣列 |
| `types/registry/` | `asset-image.toml` … `asset-archive.toml`(新,8 份) | `family = "asset"`、`name_kinds`、`allowed_links`(留空,靠載入器補 `depicts`) |
| `types/registry/` | 既有 5 份(改) | 各加一行 `family = "entity"` |

### `NameParts` 的新形狀與 `parseLogicalName` 的位置式演算法

```haskell
data NameParts = NameParts
  { npKind      :: Segment
  , npDomain    :: Segment
  , npSubject   :: Segment
  , npModifiers :: [Segment]   -- 0..2 個,對應原文法的 [variant][state],不再語意區分
  , npIndex     :: Maybe Int
  }
```

契約 B 的 `parseLogicalName :: Text -> Either NameError NameParts` **沒有** `NamingVocab` 參數。
legacy 版靠 `nvStates` / `nvVariants` 從右往左剝,才能在「有 state 沒 variant」這類缺項組合裡
正確分辨哪段是哪個角色;新簽名結構上不可能做這件事。演算法改為**純位置式、不需要任何詞彙表**:

1. `rawSegs = splitOn "_" full`;`(kindTxt : domainTxt : rest@(_:_))` 否則 `TooFewSegments`
2. `mkSegment` 驗證 `domainTxt` 與 `rest` 每一段(ASCII 小寫 + 數字 + 內部 `-`)
3. 若 `rest` 的最後一段 `isIndexShaped`(剛好 3 位數字),剝掉當 `npIndex`,`remaining` = 剩下的
4. `remaining` 為空 → `TooFewSegments`;否則 `head remaining` = `npSubject`,
   `tail remaining` = `npModifiers`
5. `length npModifiers > 2` → `AmbiguousTrailing`(超過 `[variant][state]` 兩個欄位能裝的量)

`renderParts` 方向不變:`kind_domain_subject` 之後依序接 `npModifiers`(原樣接,不重排)、
最後接 `npIndex`(補零到三位)。

### `NamingVocab` 的兩個欄位怎麼用

- `nvKinds :: [Segment]`——**強制**。`mkLogicalName` / `validateLogicalName` 檢查 `npKind` 是否為
  成員,不是就回 `UnknownKindPrefix`。ADR-019 明說「`kind` 是封閉列舉」,這條檢查延續那個立場,
  只是詞彙來源從編譯期的 `KindPrefix` 換成 `naming.toml` 的 `kinds` 陣列
- `nvDomains :: [Segment]`——**不強制**。ADR-019 明說「`npDomain` 根本不比對詞彙表……加一種素材
  領域連資料都不必動」,這條決策沒有被本次重構推翻。`nvDomains` 目前是空清單(見 A1),`mkLogicalName`
  / `validateLogicalName` 都不讀它,只是型別上與 `nvKinds` 對稱、供未來(如 `type list` 的 CLI
  提示)使用

### `validateLogicalName` 的 `TypeKey` 參數

`validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()` 的型別簽名
接受 `TypeKey`,但契約卡把「`name` 第一段必須在**該型別**的 `name_kinds` 內」明確指派給 `checkMeta`
(只回警告,見「明確不做:不決定警告要不要擋」)。`validateLogicalName` 回傳 `Either NameError ()`
是硬錯誤,若在這裡也做一次型別專屬的 `name_kinds` 檢查,會與 `checkMeta` 的「只警告」立場矛盾
(同一件事一邊硬擋一邊只警告)。本 feature 因此讓 `validateLogicalName` 只做**與型別無關**的檢查
(語法 + `nvKinds` 全域成員),`TypeKey` 參數目前不參與判斷邏輯——見 A2。

### `checkMeta` 的 asset 檢查

```haskell
checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]
checkMeta reg node = case lookupType reg (metaType m) of
  Nothing -> [UnknownNodeType (metaType m)]
  Just decl -> missingFields decl ++ badLinks decl ++ badNameKind decl
  where m = anyMeta node
```

- `missingFields` / `badLinks`:邏輯與舊 `checkEntity` 相同(對照 `fieldPresent` / `badLinks`),
  只是輸入從 `Entity` 換成 `anyMeta node`
- `badNameKind`:只對 `NAsset (Asset { astName = Just name })` 產生。用 `parseLogicalName` 拆出
  `npKind`,若 `tdNameKinds decl` 非空且 `npKind` 不在其中 → `[NameKindNotAllowed (tdKey decl)
  (segmentText npKind)]`。`astName = Nothing`(掃描剛寫入、尚未命名)不產生任何警告;`tdNameKinds`
  為空(目前只有 `asset-archive`)視為「未宣告限制」,對稱於 `allowed_links` 空清單的既有慣例——見 A3

### `RegistryError` 的合併與 `RegistryErrors` 包裝

契約 G 只有一個 `RegistryError`(單數),但 `loadRegistry` 的簽名是
`IO (Either RegistryError (TypeRegistry, NamingVocab))`——**單一值**,不是 `[RegistryError]`。
舊 `Loader.hs` 的設計哲學「單檔解析失敗不中斷,最後一次回報全部問題」（`loadRegistry` 註解原文)
是刻意的,不因簽名改變而放棄。因此 `RegistryError` 新增一個聚合建構子:

```haskell
data RegistryError
  = DuplicateTypeKey TypeKey
  | UnknownMetaField TypeKey Text
  | EmptyTypeKey
  | ReservedTypeKey TypeKey
  | ConflictingOwnerDir TypeKey
  | UnknownFamily FilePath Text
  | TomlParseError FilePath Text
  | MissingField FilePath Text
  | BadFieldType FilePath Text Text
  | UnknownKey FilePath Text
  | RegistryDirMissing FilePath
  | NamingFileMissing FilePath
  | RegistryNotFound [FilePath]
  | RegistryErrors [RegistryError]   -- 彙整多個問題,渲染時逐行攤平
  deriving stock (Show, Eq)
```

`loadRegistry` / `loadRegistryFrom` 內部仍收集一個 `[RegistryError]`,非空時包成
`Left (RegistryErrors errs)`(單一個元素時直接回那個元素,不多包一層)。`renderRegistryError` 對
`RegistryErrors` 逐行 `T.intercalate "\n"` 攤平。舊 `UnknownLinkInAllowed` 建構子(legacy 註解
明寫「保留但不由 `validateRegistry` 產生」的死碼)不沿用。

### `family` / `name_kinds` 的 TOML 解析與 reserved key 擴充

- `topLevelKeys` 加入 `family`(必填字串,`"entity"` 或 `"asset"`,其他值 → `UnknownFamily`)與
  `name_kinds`(選填字串陣列,每個元素過 `mkSegment`)
- `reservedTypeKeys = ["level", "asset-pack", "asset-license"]`(原本只有 `"level"`)
- 目錄掃描(`loadRegistry`)排除檔名為 `naming.toml` 的檔案,不當成型別宣告解析;缺少
  `naming.toml` → `NamingFileMissing`

### `locateRegistry` 的 `Either` 化

三層定位邏輯(環境變數 → 執行檔旁 → `data-files`)不變,只把最終「三層都沒找到」的 `Nothing`
換成 `Left (RegistryNotFound [三層各自查過的路徑])`,滿足 Loader.hs 原註解「`doctor` 要說得出查過
哪裡」(G-E002)的既有目標。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` | 尚未實作 | F001 | F001 定義的 `AnyNode` / `MetaWarning` 是本 feature 唯一的實作依據 |
| `data LinkKind = … \| Uses \| Depicts \| Custom Text` | 尚未實作(現況見 `core/src/Aapms/Core/Link.hs:22-41`,8+1 個,無 `Uses`/`Depicts`) | F001 | `TypeDecl.tdAllowedLinks` 與 asset 族「預設含 `depicts`」都要吃到 F001 擴充後的 10+1 個建構子 |
| `newtype TypeKey = TypeKey Text` | 尚未實作(現況 `metaType :: Text`,`core/src/Aapms/Core/Meta.hs`) | F001 | `TypeDecl.tdKey` / `tdOwnerType`、`RegistryError` 多個建構子、`validateLogicalName` 的型別參數 |
| `newtype LogicalName = LogicalName Text`(建構子匯出,只經 `mkLogicalName` 取得) | 尚未實作 | F001 | `mkLogicalName` 的回傳型別、`checkMeta` 讀 `astName :: Maybe LogicalName` |
| `data Asset = Asset { astName :: Maybe LogicalName, … }` | 尚未實作 | F001 | `checkMeta` 對 `NAsset` 額外做 `name_kinds` 檢查的資料來源 |
| `validateRegistry :: [EntityTypeSpec] -> Either [RegistryError] TypeRegistry` | `core/src/Aapms/Core/Registry.hs:114-144` | - | 改寫起點:「回報全部錯誤」的立場沿用,型別換成 `TypeDecl` / 新 `RegistryError` |
| `checkEntity :: TypeRegistry -> Entity -> [EntityWarning]` | `core/src/Aapms/Core/Registry.hs:171-190` | - | 改寫起點,邏輯拆進新 `checkMeta` 的 `missingFields` / `badLinks` |
| `fieldPresent :: Text -> Meta -> Bool` | `core/src/Aapms/Core/Registry.hs:196-214` | - | 邏輯原樣沿用(改 `metaTimeline` 判斷方式) |
| `locateRegistryWith :: IO FilePath -> IO (Maybe (RegistrySource, FilePath))` | `types/src/Aapms/Types/Loader.hs:100-114` | - | 三層定位邏輯沿用,回傳型別改 `Either` |
| `readSpec` / `parseSpec` / 取值輔助群 | `types/src/Aapms/Types/Loader.hs:178-300` | - | TOML 解析邏輯沿用,擴充 `family` / `name_kinds` 兩個鍵 |
| `mkSegment :: Text -> Either NameError Segment` | `legacy/assetdb/core/src/AssetDB/Naming.hs:88-92` | - | 規則(`^[a-z0-9]+(-[a-z0-9]+)*$`)原樣沿用 |
| `isIndexShaped :: Text -> Bool` / `indexSegment :: Int -> Either NameError Segment` | `legacy/assetdb/core/src/AssetDB/Naming.hs:257-270` | - | 原樣沿用,是新位置式解析演算法剝離 `npIndex` 的依據 |
| `renderParts :: NameParts -> Either NameError Text` | `legacy/assetdb/core/src/AssetDB/Naming.hs:299-307` | - | 改吃新 `NameParts` 形狀,拼接邏輯同構 |
| `data AssetKind (..)` / `data KindPrefix (..)` / `prefixKind` / `kindPrefixes` | `legacy/assetdb/core/src/AssetDB/Types.hs:70-142` | - | `name_kinds` 對應表與 `naming.toml` 的 `kinds` 詞彙的唯一來源(D5) |

## 新增的介面

### `aapms-core`(`Aapms.Core.Registry`)

```haskell
data Family = FEntity | FAsset
  deriving stock (Show, Eq)

renderFamily :: Family -> Text        -- "entity" / "asset",穩定小寫(ADR-008 風格)
parseFamily  :: Text -> Maybe Family

data FieldDecl = FieldDecl
  { fdName :: Text, fdRequired :: Bool, fdHint :: Text }
  deriving stock (Show, Eq)

data TypeDecl = TypeDecl
  { tdKey :: TypeKey, tdName :: Text, tdFamily :: Family
  , tdDir :: Maybe FilePath, tdOwnerType :: Maybe TypeKey
  , tdAllowedLinks :: [LinkKind], tdStages :: [Text], tdFields :: [FieldDecl]
  , tdNameKinds :: [Segment]
  }
  deriving stock (Show, Eq)

data TypeRegistry   -- 不透明,Map TypeKey TypeDecl

reservedTypeKeys :: [TypeKey]         -- [level, asset-pack, asset-license]

buildRegistry :: [TypeDecl] -> Either [RegistryError] TypeRegistry
lookupType    :: TypeRegistry -> TypeKey -> Maybe TypeDecl
listTypes     :: TypeRegistry -> [TypeDecl]
lookupDir     :: TypeRegistry -> TypeKey -> Maybe FilePath

checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]

data RegistryError = …   -- 見「實作方式」,14 個建構子
renderRegistryError :: RegistryError -> Text
```

### `aapms-core`(`Aapms.Core.Naming`,新模組)

```haskell
newtype Segment = Segment Text
segmentText :: Segment -> Text
mkSegment   :: Text -> Either NameError Segment

data NameParts = NameParts
  { npKind :: Segment, npDomain :: Segment, npSubject :: Segment
  , npModifiers :: [Segment], npIndex :: Maybe Int
  }
  deriving stock (Eq, Show)

data NamingVocab = NamingVocab { nvKinds :: [Segment], nvDomains :: [Segment] }
  deriving stock (Show, Eq)

data NameError
  = EmptySegment | BadSegment Text | NoAsciiContent Text | TooLong Int Text
  | UnknownKindPrefix Text | TooFewSegments Int Text | AmbiguousTrailing [Text] Text
  | IndexOutOfRange Int
  deriving stock (Eq, Show)
renderNameError :: NameError -> Text

maxLogicalNameLength :: Int   -- 64
indexSegment  :: Int -> Either NameError Segment
isIndexShaped :: Text -> Bool

mkLogicalName       :: NamingVocab -> NameParts -> Either NameError LogicalName
parseLogicalName     :: Text -> Either NameError NameParts
validateLogicalName  :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()
renderParts          :: NameParts -> Either NameError Text
```

### `aapms-types`(`Aapms.Types.Loader`,簽名變更)

```haskell
locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))
loadRegistry   :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
loadRegistryFrom :: [FilePath] -> FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))
  -- 第二個 FilePath 是 naming.toml 的路徑(明確傳入,供測試指定臨時目錄)
```

(`RegistrySource`、`registryEnvVar`、`registryBesideExecutable`、`defaultRegistryDir` 簽名不變,
re-export `Family` / `TypeDecl` / `TypeRegistry` / `NamingVocab` / `lookupType` / `RegistryError`
與 `NameError` 等型別。)

## TOML 格式規格

### 型別宣告(entity 族與 asset 族共用同一個檔案形狀)

```toml
key    = "asset-image"      # 必填,型別鍵;不可為 "level" / "asset-pack" / "asset-license"
name   = "圖片素材"          # 必填
family = "asset"            # 必填,"entity" 或 "asset",其他值是載入錯誤

# entity 族專用(asset 族的 dir 無意義,依契約卡不宣告)
dir        = "characters"   # 選填
owner_type = "character"    # 選填

allowed_links = ["depicts"] # 選填;asset 族即使留空,載入器也會補上 depicts(見下)
stages        = []          # 選填,P5 用

# asset 族專用:命名文法第一段的合法值,對應 legacy AssetKind 的 kindPrefixes
name_kinds = ["spr", "tex", "atlas", "ui"]

[[fields]]
name     = "summary"
required = true
hint     = "一句話說明這個素材的用途"
```

- `family` 是新增的必填鍵;既有 5 份 entity TOML 各補一行 `family = "entity"`,其餘內容不變
- `name_kinds` 只有 asset 族需要宣告非空值;entity 族省略(視為 `[]`,`checkMeta` 對 entity 族
  的 `NAsset` 分支不適用,不影響)
- asset 族的 `allowed_links`:載入器對 `family = "asset"` 的宣告,若 `depicts` 不在明寫的
  `allowed_links` 裡就自動補上(契約卡「預設含 `depicts`」),因此 8 份 asset TOML 的
  `allowed_links` 一律留空陣列 `[]`,由載入器補齊

### `naming.toml`(新檔案,不是型別宣告,載入時特別排除)

```toml
# 命名文法(ADR-019)的詞彙表。kinds 是全系統合法的「kind」分段值(命名文法第一段),
# 逐字取自 legacy/assetdb/core/src/AssetDB/Types.hs 的 KindPrefix(12 個)。
# domains 刻意留空——ADR-019 明說 domain 不比對任何詞彙表,這裡不引入新的限制;
# 保留欄位是為了與 kinds 對稱、供未來 CLI 提示使用。
kinds   = ["spr", "tex", "atlas", "ui", "fnt", "sfx", "bgm", "vo", "lvl", "shd", "src", "doc"]
domains = []
```

## TodoList

- [ ] T1: `aapms-core`:新增 `Naming.hs`(`Segment` / `NameParts` / `NamingVocab` / `NameError` /
  `mkLogicalName` / `parseLogicalName` / `validateLogicalName` / `renderParts` /
  `maxLogicalNameLength` / `indexSegment` / `isIndexShaped`)  `dep: F001`
- [ ] T2: `aapms-core`:重寫 `Registry.hs`(`Family` / `FieldDecl` / `TypeDecl` / `TypeRegistry` /
  `buildRegistry` / `lookupType` / `listTypes` / `lookupDir` / `reservedTypeKeys` 擴充 /
  `RegistryError`)  `dep: T1, F001`
- [ ] T3: `aapms-core`:`Registry.hs` 加 `checkMeta`(`missingFields` / `badLinks` /
  `badNameKind`)  `dep: T2`
- [ ] T4: `aapms-core.cabal`:`exposed-modules` 加入 `Aapms.Core.Naming`  `dep: T1`
- [ ] T5: `aapms-types`:重寫 `Loader.hs`(`locateRegistry` / `loadRegistry` 新簽名、`naming.toml`
  排除與解析、`family` / `name_kinds` 解析、`topLevelKeys` 擴充、re-export)  `dep: T2, T3`
- [ ] T6: `types/registry/naming.toml`(新):`kinds`(12 項)、`domains`(空)  `dep: -`
- [ ] T7: `types/registry/asset-{image,audio,font,level,shader,doc,source,archive}.toml`
  (新,8 份):`family = "asset"`、對照表填 `name_kinds`(`asset-archive` 留空陣列)、
  `allowed_links = []`  `dep: -`
- [ ] T8: `types/registry/{character-fragment,dialogue,item-fragment,lore-fragment,
  plot-fragment}.toml`(改,5 份):各加一行 `family = "entity"`  `dep: -`
- [ ] T9: `core/test/Aapms/Core/NamingSpec.hs`(新):`Segment` 規則、位置式 `parseLogicalName`
  演算法、`mkLogicalName` 的 `nvKinds` 檢查、`renderParts`  `dep: T1`
- [ ] T10: `core/test/Aapms/Core/NamingCasesSpec.hs`(新):讀
  `contract/fixtures/naming-cases.txt`,逐行以新 `parseLogicalName` + `mkLogicalName`(用
  T6 的 `naming.toml` 詞彙)驗證 ok/bad  `dep: T1, T6, T9`
- [ ] T11: `core/test/Aapms/Core/RegistrySpec.hs`(重寫):`family` 驗證、
  `reservedTypeKeys` 三項、`buildRegistry` 錯誤彙整(`RegistryErrors`)、`checkMeta`
  對 entity 與 asset 兩族  `dep: T2, T3`
- [ ] T12: `types/test/Aapms/Types/LoaderSpec.hs`(重寫):新簽名、`naming.toml` 缺漏 /
  格式錯誤、`family` 缺漏或非法值、13 份真實 TOML(5 entity + 8 asset)整批可載入、
  `locateRegistry` 的 `RegistryNotFound` 情境  `dep: T5, T6, T7, T8`
- [ ] T13: `types/test/Aapms/Types/LoaderSpec.hs` 加一個整合測試:對
  `types/registry/`(專案實檔目錄)跑 `loadRegistry`,驗收標準「含原五種 entity 族 + 八種
  asset 族 + `naming.toml`」直接對真實檔案斷言  `dep: T12`
- [ ] T14: `core/test/Spec.hs` 與 `types/test/Spec.hs` 的 `describe` 清單補上新 Spec
  `dep: T9, T10, T11, T13`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_segment_and_nameparts_shape | `mkSegment` 對合法/非法輸入的 `Either`;`NameParts` 可建構與存取 |
| T2 | test_family_and_typedecl | `Family` render/parse 互為反函式;`reservedTypeKeys` 含 3 項;`buildRegistry` 對重複鍵 / 空鍵 / 保留鍵回對應 `RegistryError` |
| T3 | test_checkmeta_entity_and_asset | entity 族:缺必填欄位、關聯不在 `allowed_links` 各回一則警告;asset 族:`name_kinds` 內/外的 `LogicalName` 各回是否有 `NameKindNotAllowed`;`astName = Nothing` 不產生 `NameKindNotAllowed` |
| T4 | test_cabal_exposes_naming | `aapms-core.cabal` 的 `exposed-modules` 含 `Aapms.Core.Naming` |
| T5 | test_loader_new_signatures | `locateRegistry` / `loadRegistry` 回傳型別為 `Either RegistryError …`;`naming.toml` 不被當成型別宣告解析;`family` / `name_kinds` 缺漏或型別錯誤各回對應 `RegistryError` |
| T6 | test_naming_toml_shape | `types/registry/naming.toml` 可被 T5 的解析器讀出 12 個 `kinds`、0 個 `domains` |
| T7 | test_asset_tomls_loadable | 8 份 asset TOML 各自 `family = FAsset`、`tdNameKinds` 與對照表相符(`asset-archive` 為 `[]`)、`tdDir = Nothing` |
| T8 | test_entity_tomls_still_loadable | 5 份既有 entity TOML 加了 `family = "entity"` 後仍可解析、`tdFamily = FEntity`,其餘欄位與加欄位前相同 |
| T9 | test_parselogicalname_positional | 對 `spr_char_hero_attack-01_up` 等位置式案例:`npModifiers` 長度 0..2 時各自正確;3 個以上非 index 尾段回 `AmbiguousTrailing`;`renderParts . parseLogicalName == id`(限定合法輸入) |
| T10 | test_naming_cases_fixture | `naming-cases.txt` 全部 `ok` 案例以 `naming.toml` 詞彙驗證通過;全部 `bad` 案例被對應 `NameError` 拒絕 |
| T11 | test_registry_family_reserved_and_errors | `key = "level"` / `"asset-pack"` / `"asset-license"` 各回 `ReservedTypeKey`;`family` 非 `"entity"`/`"asset"` 回 `UnknownFamily`;多重錯誤彙整進 `RegistryErrors` 且逐項可讀 |
| T12 | test_loader_naming_and_family_integration | 缺 `naming.toml` 回 `NamingFileMissing`;13 份 fixture TOML(5+8)整批 `loadRegistry` 成功且 `TypeRegistry` 含全部鍵;`locateRegistry` 三層都找不到時回 `RegistryNotFound` 並列出三個查過的路徑 |
| T13 | test_loader_real_registry_dir | 對專案的 `types/registry/` 目錄跑 `loadRegistry`:成功、`TypeRegistry` 恰好 13 個鍵(5 entity + 8 asset)、`NamingVocab` 的 `nvKinds` 恰好 12 個 |
| T14 | test_spec_registration | `core/test/Spec.hs` 引用 `NamingSpec` / `NamingCasesSpec`;`types/test/Spec.hs` 沿用 `LoaderSpec`(內容已擴充) |

## 待確認假設

- A1:契約 B 的 `parseLogicalName :: Text -> Either NameError NameParts` 拿掉了 `NamingVocab`
  參數,而契約 C 的 `NamingVocab { nvKinds, nvDomains }` 與 legacy `defaultVocab` 的
  `{ nvStates, nvVariants }` 是完全不同的兩組欄位(前者管 kind/domain 分段,後者管 variant/state
  消歧)。這代表 legacy 演算法「用 27 個 state 詞 + 17 個 variant 詞從右往左剝」在新簽名下**結構上
  不可能實作**。→ 採取:改成純位置式解析(見「實作方式」),`npVariant` / `npState` 合併成
  `npModifiers :: [Segment]`(不再語意區分,只留順序),`state`/`variant` 兩組詞彙表**不移植**;
  已逐案代入 `contract/fixtures/naming-cases.txt` 全部 13 案(含 `spr_char_hero_attack-01_up` 這種
  在 legacy 演算法下會因 `AmbiguousTrailing` 被誤拒的案例)驗證新演算法全部給出正確結果,見
  「相依性查證」與「新增的介面」→ 影響:若這個結構性判斷有誤(即契約簽名其實是設計時的筆誤,
  `parseLogicalName` 原意仍要吃 `NamingVocab`),需要回頭找編排者確認 design.md 契約 B 那一行,
  且 `NameParts` 要改回帶語意標籤的 `npVariant :: Maybe Segment` / `npState :: Maybe Segment`,
  `SubjectLooksLikeModifier` 與 `nvStates`/`nvVariants` 詞彙表都要補回來
- A2:`validateLogicalName` 的 `TypeKey` 參數,在契約卡「`checkMeta` 對 asset 檢查 name 第一段在
  該型別的 `name_kinds` 內……**只回警告**」與「明確不做:不決定警告要不要擋」兩句之間,若
  `validateLogicalName`(回傳硬錯誤 `Either NameError ()`)也做同一件事的型別專屬檢查,會與
  「只警告」的立場矛盾。→ 採取:`validateLogicalName` 只做語法 + `nvKinds` 全域成員檢查,不吃
  `TypeKey` 做型別專屬過濾,型別專屬的 `name_kinds` 檢查完全交給 `checkMeta` → 影響:若編排者
  認為 `validateLogicalName` 確實該依 `TypeKey` 做硬性型別過濾(例如未來某處需要在寫入前**拒絕**
  而非僅警告一個名稱），需要重新設計 `NamingVocab` 的形狀(讓它能依 `TypeKey` 查到專屬
  `name_kinds`,目前的 `nvKinds :: [Segment]` 是扁平清單做不到),屬於契約 C 的變動
- A3:`tdNameKinds` 為空清單時的語意,契約卡與驗收標準都沒有明講(只講「非空時檢查成員」)。
  `asset-archive` 依 D5 的對照表算出來剛好是空清單(legacy `KindPrefix` 沒有任何值對應
  `KArchive`)。→ 採取:比照既有 `allowed_links` 空清單 = 「未宣告限制」的慣例(舊
  `checkEntity`/`badLinks` 明寫「`etsAllowedLinks` 為空視為未宣告限制」),`tdNameKinds` 空清單
  時 `checkMeta` 不對該型別的 asset 產生 `NameKindNotAllowed` → 影響:若編排者認為
  `asset-archive` 應該完全不允許被命名(任何 `name` 都是警告),需要把「空清單」的語意反過來,
  且要另外決定 `asset-archive` 的 `name_kinds` 該填什麼非空值(目前的來源資料——legacy
  `KindPrefix`——就是沒有這個值)

## 實作備註

(留空)
