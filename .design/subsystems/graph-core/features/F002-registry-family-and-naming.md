---
id: F002
type: feature
title: registry-family-and-naming
description: 型別註冊表加 family 與 asset 八族、naming.toml 詞彙(kinds/domains/states)、命名文法改吃注入詞彙並語意區分 variant/state
status: done
created: 2026-08-23
updated: 2026-09-04
stage: S1
modules: ["Registry 載入", "Registry 純驗證", Naming]
depends-on: [graph-core/F001]
related-adr: [ADR-005, ADR-019]
related-feature: []
code-paths: [core/aapms-core.cabal, core/src/Aapms/Core/Naming.hs, core/src/Aapms/Core/Registry.hs, core/test/Aapms/Core/CabalSpec.hs, core/test/Aapms/Core/NamingCasesSpec.hs, core/test/Aapms/Core/NamingSpec.hs, core/test/Aapms/Core/RegistrySpec.hs, core/test/Spec.hs, types/src/Aapms/Types/Loader.hs, types/test/Aapms/Types/LoaderSpec.hs, types/test/Spec.hs]
---

# F002: 註冊表 `family` 與命名文法(registry-family-and-naming)

## 功能概述

把型別註冊表從「只有五種 entity 族」擴充成「entity 族 + 八種 asset 族」,並把 assetdb 的命名文法
(`AssetDB.Naming`)搬進 `aapms-core`、改吃註冊表載入的詞彙(`NamingVocab`)而不是編譯期常數。
`aapms-types` 只保留 IO(定位、讀檔、TOML 解析),純型別與純驗證全部在 `aapms-core`(DEC-7)。

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

DEC-1(委派決策記錄):graph-core 以外的程式碼(`service` / `conflict` / `cli` / … 舊碼仍 import 舊
`Aapms.Core.Registry` 與 `Aapms.Types.Loader`)一律不碰、不考慮相容。

## 契約

- **階段**:階段一
- **負責模組**:Registry 載入(`aapms-types`)、Registry 純驗證、Naming(`aapms-core`)
- **驗收標準**(契約卡原文):`types/registry/` 含原五種 entity 族 + 八種 asset 族 + `naming.toml`;`asset-pack` /
  `asset-license` / `level` 出現在註冊表是載入錯誤;載入失敗程序失敗、不退回空註冊表;
  `checkMeta` 對 asset 檢查 `name` 第一段在該型別的 `name_kinds` 內、關聯在 `allowed_links` 內,
  只回警告;`validateLogicalName` 對 `ui_gui_travel-book-frame_001` 通過、對非 ASCII / 超過 64 字元 /
  少於三段拒絕;`defaultVocab` 與 DB `naming_vocab` 表都不存在

### 契約 C(全部,套件歸屬依 2026-08-23 DEC-7 裁決)

- `Family = FEntity | FAsset`、`TypeDecl`(9 欄,含 `tdNameKinds :: [Segment]`)、`TypeRegistry`、
  `NamingVocab { nvKinds :: [Segment], nvDomains :: [Segment], nvStates :: [Segment] }`(2026-08-23
  階段一閘門加 `nvStates`,見「待確認假設」ASM-1)、`lookupType`——**定義在 `aapms-core`**
  (`Aapms.Core.Registry`)
- `locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))`、
  `loadRegistry :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))`——
  **定義在 `aapms-types`**(`Aapms.Types.Loader`),並 re-export 上一項的全部型別
- `asset-pack` / `asset-license` / `level` 是保留鍵,出現在註冊表是載入錯誤
- 載入失敗讓程序失敗,不退回空註冊表

### 契約 B(部分,依契約卡指定)

- `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`(`aapms-core`,吃 F001 的 `AnyNode` /
  `MetaWarning`)
- `mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName`
- `parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts`(2026-08-23 階段一閘門
  改回**帶** `NamingVocab` 參數——原 ASM-1 判斷「契約 B 拿掉了這個參數」是誤判,見「待確認假設」ASM-1)
- `validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()`

**不做**:契約 B 其餘函式(`newId` / `parseId` / `parseRef` / `renderRef` / `prefixOf` /
`buildTree` / `Manifest` 一組)屬 #1 / #3。

### 契約 G(部分)

- `RegistryError`(全部建構子,涵蓋純驗證與 TOML 載入兩類問題)
- `NameError`(全部建構子)

**不做**:`IdError`(#1)、`MdError` / `StoreError`(其他子系統 feature)。

### 明確不做(契約卡逐字)

不決定警告要不要擋;不做叢集推論(`asset-ingest`);不改 `dir` / `owner_type` 語意。

- **明確不做**(契約卡原文):不決定警告要不要擋;不做叢集推論(`asset-ingest`);不改 `dir` / `owner_type` 語意

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
  (**不改名**:system.md「S0 進度」明寫 `STORYFLOW_*` 環境變數是刻意留到 S3 由 `workspace` 依
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
  `legacy/assetdb/core/src/AssetDB/Naming.hs:129-147`(**2026-08-23 階段一閘門定案**:形狀**沿用**
  legacy 的 `npVariant :: Maybe Segment` / `npState :: Maybe Segment` 語意區分——原 ASM-1「合併成
  `npModifiers`」的判斷被開發者推翻,見「待確認假設」ASM-1。`npKind` 仍從 `KindPrefix`〔封閉列舉〕
  換成一般 `Segment`〔合法值改查外部注入的 `nvKinds`〕,這點不變)
- `data NameError = EmptySegment | BadSegment Text | NoAsciiContent Text | TooLong Int Text |
  UnknownKindPrefix Text | TooFewSegments Int Text | AmbiguousTrailing [Text] Text |
  SubjectLooksLikeModifier Text | IndexOutOfRange Int` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:153-167`
  (`SubjectLooksLikeModifier` 仍**不沿用**——不是因為 ASM-1 的舊理由,而是因為新演算法的「至少留一段
  給 subject」guard〔見「實作方式」與待確認假設 ASM-4〕已經讓 `parseLogicalName` 對「subject 長得像
  state 詞」的輸入結構上不會誤判,不需要一個額外錯誤建構子來擋)
- `data NamingVocab = NamingVocab { nvStates :: Set Text, nvVariants :: Set Text }`,
  `defaultVocab :: NamingVocab` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:209-242`(**部分沿用,
  2026-08-23 階段一閘門定案**:契約 C 的新 `NamingVocab` 形狀是
  `{ nvKinds :: [Segment], nvDomains :: [Segment], nvStates :: [Segment] }`——`nvStates` 這一張表
  **移植**〔型別從 `Set Text` 換成 `[Segment]`,語意不變:封閉、只用於分辨 state〕;`nvVariants`
  那張 17 個具名變體詞的表**依舊不移植**——variant 天生開放,`isVariantShaped` 的「兩位數字+可選字母」
  形狀限制也不移植,新設計裡 variant 是任何合法 `Segment` 都收。`defaultVocab` 整體**不移植**
  〔詞彙表全部改住 `types/registry/naming.toml`,程式碼裡不得有編譯期常數〕。`nvStates` 的實際詞數
  是 37〔互動狀態 7 + 開合 6 + 動作 7 + 方向 10 + 時段 7〕,不是舊版 ASM-1 誤植的「27」——見「TOML 格式
  規格」的 `naming.toml` 定案清單)
- `mkLogicalName :: NamingVocab -> NameParts -> Either NameError LogicalName` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:279-289`
  (改吃契約 C 的新 `NamingVocab`;`isModifierLike`〔檢查 subject 撞見 state/variant 詞彙〕不沿用,
  改成直接檢查 `npKind ∈ nvKinds` 與 `npState`〔若為 `Just`〕`∈ nvStates` 兩項——後者是新增檢查,
  舊版沒有對稱的「建構時驗證 npState 合法」邏輯,因為舊版 `npState` 本來就只可能來自
  `parseLogicalName` 拆解的結果,見「實作方式」)
- `parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:323-356`
  (**簽名沿用**,不是 ASM-1 舊判斷以為的「拿掉 `NamingVocab` 參數」——契約 B 該行是設計時筆誤,已由
  開發者裁決訂正,見待確認假設 ASM-1。演算法從「右往左剝、同時查 `nvStates` 與 `nvVariants` 兩張表」
  簡化成「右往左剝、只查 `nvStates` 一張表」——index 純語法判斷、state 查表、variant 開放全收,
  見「實作方式」)
- `validateLogicalName :: Text -> Either NameError LogicalName` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:313-316`
  (**簽名改變**:契約 B 是 `NamingVocab -> TypeKey -> LogicalName -> Either NameError ()`)
- `isVariantShaped` / `isIndexShaped` / `variantFromNumber` / `indexSegment` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:248-270`
  (`isIndexShaped` / `indexSegment` 沿用;`isVariantShaped` / `variantFromNumber` 依舊不沿用——variant
  的形狀限制被拿掉,任何合法 `Segment` 都算 variant,不必再判斷是不是「兩位數字+字母」)
- `renderParts :: NameParts -> Either NameError Text` —— `legacy/assetdb/core/src/AssetDB/Naming.hs:299-307`
  (邏輯同構,沿用 legacy 順序:`kind_domain_subject` 後接 `npVariant`、`npState`、`npIndex`,依序
  只在 `Just` 時附加)

### `legacy/assetdb/core/src/AssetDB/Types.hs`(`name_kinds` 對應表的來源,DEC-5 指定)

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
`fnt` / `sfx` / `bgm` / `vo` / `lvl` / `shd` / `src` / `doc`)——即全系統合法的「kind」分段值,見 ASM-1。

### `contract/fixtures/naming-cases.txt` 與 `contract/test/Aapms/Contract/NamingGrammarSpec.hs`

- 7 個合法案例、6 個非法案例,逐行格式 `ok <名稱>` / `bad <名稱>  # 理由` —— 全文已讀,見「實作方式」
  逐案代入驗證新演算法(ASM-1)
- `NamingGrammarSpec.hs:50-51`:第三個 `it` 目前是 `pendingWith`,註解明寫「等 F002 落地後改為逐行
  呼叫 `aapms` 驗證」——但 D「contract 套件本身已凍結,不要改它」,因此本 feature **不修改**
  `contract/` 底下任何檔案;改為在 `aapms-core` 的新測試(`NamingCasesSpec.hs`)讀同一份
  `fixtures/naming-cases.txt`、逐行呼叫新的 `parseLogicalName` / `mkLogicalName` 驗證,把契約卡的
  驗收輸入納入 1-to-1 測試(STEP-10;原文誤植為 STEP-13,順手訂正)

## 實作方式

### 套件內模組配置

| 套件 | 檔案 | 內容 |
|---|---|---|
| `aapms-core` | `Registry.hs`(重寫) | `Family`、`FieldDecl`、`TypeDecl`、`TypeRegistry`、`buildRegistry`、`lookupType`、`listTypes`、`lookupDir`、`reservedTypeKeys`(擴充 3 項)、`checkMeta`、`RegistryError` |
| `aapms-core` | `Naming.hs`(新) | `Segment`、`mkSegment`、`segmentText`、`NameParts`(`npVariant`/`npState` 語意分開)、`NamingVocab`(含 `nvStates`)、`NameError`(含 `UnknownState`)、`mkLogicalName`、`parseLogicalName`(帶 `NamingVocab`)、`validateLogicalName`、`renderParts`、`maxLogicalNameLength`、`indexSegment`、`isIndexShaped` |
| `aapms-types` | `Loader.hs`(重寫) | `locateRegistry` / `loadRegistry` 新簽名、`naming.toml` 專屬解析、`family` / `name_kinds` 解析、re-export `Aapms.Core.Registry` 與 `Aapms.Core.Naming` 的型別 |
| `types/registry/` | `naming.toml`(新) | `kinds` / `domains` / `states` 三個字串陣列(`states` 是 2026-08-23 階段一閘門新增,見下) |
| `types/registry/` | `asset-image.toml` … `asset-archive.toml`(新,8 份) | `family = "asset"`、`name_kinds`、`allowed_links`(留空,靠載入器補 `depicts`) |
| `types/registry/` | 既有 5 份(改) | 各加一行 `family = "entity"` |

### `NameParts` 的形狀(2026-08-23 階段一閘門定案,推翻舊 ASM-1)與 `parseLogicalName` 的演算法

```haskell
data NameParts = NameParts
  { npKind    :: Segment
  , npDomain  :: Segment
  , npSubject :: Segment
  , npVariant :: Maybe Segment   -- 開放,不查詞彙表
  , npState   :: Maybe Segment   -- 封閉,必須在 nvStates 內
  , npIndex   :: Maybe Int
  }
```

開發者在階段一閘門裁決:語意區分 variant 與 state 有必要保留(不能合併成 `npModifiers`),但
不必遷就 legacy 的**兩張**詞彙表(`nvStates` 27/37 詞 + `nvVariants` 17 詞——legacy 那張 variant
表正是它會誤拒 `spr_char_hero_attack-01_up` 的原因:`attack-01` 不在 17 個具名變體詞裡,legacy
的 `isVariantShaped` 也不吃帶連字號的複合詞)。契約 B 因此訂正為
`parseLogicalName :: NamingVocab -> Text -> Either NameError NameParts`(**帶** `NamingVocab`
參數——design.md 現在的字面簽名如此,舊 ASM-1「拿掉參數」是誤判)。演算法**只查一張表**
(`nvStates`),variant 天生開放:

1. `rawSegs = splitOn "_" full`;`(kindTxt : domainTxt : rest@(_:_))` 否則 `TooFewSegments`
2. `mkSegment` 驗證 `domainTxt` 與 `rest` 每一段(ASCII 小寫 + 數字 + 內部 `-`);`kindTxt` 同樣先
   過 `mkSegment`(不再是封閉列舉的 `KindPrefix` 解析),`nvKinds` 成員檢查留給
   `mkLogicalName` / `validateLogicalName`(`parseLogicalName` 本身不查任何詞彙表對錯——它只拆
   段,`UnknownKindPrefix` 由建構/驗證端回,對稱於 legacy 把 `nvStates` 成員檢查放在拆解本身、
   詞彙錯誤與語法錯誤分屬不同函式的分工)
3. 由右往左剝,只查 `nvStates`:
   a. 若 `rest` 的最後一段 `isIndexShaped`(剛好 3 位純數字,純語法、不查表),剝掉當
      `npIndex`,得到 `afterIndex`
   b. **guard**:僅當 `length afterIndex >= 2`(剝掉後還留得下至少一段給 subject)且
      `afterIndex` 的最後一段 `∈ nvStates` 時,才剝掉當 `npState`,得到 `afterState`;否則
      `npState = Nothing`、`afterState = afterIndex`(這個 guard 沿用 legacy `peel` 函式「不剝到
      清空」的保護,見待確認假設 ASM-4——沒有它,單獨一段又剛好撞見 state 詞的主體〔如
      `spr_char_up`,subject 就叫 `up`〕會被誤剝成「沒有 subject」而報錯)
   c. `afterState` 依長度分派:`[s]` → `npSubject = s`、`npVariant = Nothing`;
      `[s, v]` → `npSubject = s`、`npVariant = Just v`(**開放,不查表**,任何合法 `Segment` 都
      收);`[]` → `TooFewSegments`;更長 → `AmbiguousTrailing`

`renderParts` 方向不變、沿用 legacy 順序:`kind_domain_subject` 之後依序接 `npVariant`、
`npState`(各自只在 `Just` 時附加)、最後 `npIndex`(補零到三位)。

`mkLogicalName` 除了原本的 `npKind ∈ nvKinds` 檢查,新增 `npState`(若為 `Just`)`∈ nvStates`
檢查,失敗回新建構子 `UnknownState Text`——這條規則 legacy 沒有對稱物,因為 legacy 的 `npState`
只可能來自 `parseLogicalName` 拆解(結構上保證合法),但契約 B 的 `mkLogicalName` 也接受呼叫端
手工建構的 `NameParts`(如 `service` 端組名稱後才驗證),`npState` 可能是任意值,「封裝不變量」
不能只靠 `parseLogicalName` 那一條路徑保證。

### `NamingVocab` 的三個欄位怎麼用

- `nvKinds :: [Segment]`——**強制**。`mkLogicalName` / `validateLogicalName` 檢查 `npKind` 是否為
  成員,不是就回 `UnknownKindPrefix`。ADR-019 明說「`kind` 是封閉列舉」,這條檢查延續那個立場,
  只是詞彙來源從編譯期的 `KindPrefix` 換成 `naming.toml` 的 `kinds` 陣列
- `nvDomains :: [Segment]`——**不強制**。ADR-019 明說「`npDomain` 根本不比對詞彙表……加一種素材
  領域連資料都不必動」,這條決策沒有被本次重構推翻。`nvDomains` 目前是空清單,`mkLogicalName`
  / `validateLogicalName` 都不讀它,只是型別上與 `nvKinds` 對稱、供未來(如 `type list` 的 CLI
  提示)使用
- `nvStates :: [Segment]`——**強制、封閉**(2026-08-23 階段一閘門新增)。`parseLogicalName` 拆解
  時唯一查的表:候選段落在表內才歸類成 `npState`,不在表內就落回 `npVariant`(開放全收,見上一節
  的演算法)。`mkLogicalName` 額外驗證手工建構的 `npState`(若為 `Just`)必須是成員,不是就回
  `UnknownState`。內容住在 `naming.toml` 的 `states` 陣列(見「TOML 格式規格」),**不是**
  legacy 的 27/37 個詞照搬——本 feature 有裁量權增刪,已依「時態/方向/開合/互動/動作」五組重新
  審視,結論是**沿用 legacy 全部 37 個詞**(legacy 本身已經是良好分類、彼此語意不重疊,沒有找到
  明顯該刪或該加的項目;`up` 這個 `spr_char_hero_attack-01_up` 驗收案例需要的詞已經在「方向」組
  裡,不必額外新增)

### `validateLogicalName` 的 `TypeKey` 參數

`validateLogicalName :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()` 的型別簽名
接受 `TypeKey`,但契約卡把「`name` 第一段必須在**該型別**的 `name_kinds` 內」明確指派給 `checkMeta`
(只回警告,見「明確不做:不決定警告要不要擋」)。`validateLogicalName` 回傳 `Either NameError ()`
是硬錯誤,若在這裡也做一次型別專屬的 `name_kinds` 檢查,會與 `checkMeta` 的「只警告」立場矛盾
(同一件事一邊硬擋一邊只警告)。本 feature 因此讓 `validateLogicalName` 只做**與型別無關**的檢查
(語法 + `nvKinds` 全域成員),`TypeKey` 參數目前不參與判斷邏輯——見 ASM-2。

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
- `badNameKind`:只對 `NAsset (Asset { astName = Just name })` 產生。**不呼叫**完整
  `parseLogicalName`(2026-08-23 階段一閘門後它需要 `NamingVocab` 參數,而 `checkMeta` 的契約簽名
  `TypeRegistry -> AnyNode -> [MetaWarning]` 沒有這個參數,見待確認假設 ASM-6)——改成直接切
  `logicalNameText name` 第一個 `_` 之前的文字當 `npKind` 用(`astName :: LogicalName` 的建構子只
  經 `mkLogicalName` 取得,第一段合法性〔`nvKinds` 成員〕已在寫入時保證過,這裡只需要文字本身,不
  需要重新驗證)。若 `tdNameKinds decl` 非空且這段文字不在其中 → `[NameKindNotAllowed (tdKey decl)
  kindTxt]`。`astName = Nothing`(掃描剛寫入、尚未命名)不產生任何警告;`tdNameKinds` 為空(目前
  只有 `asset-archive`)視為「未宣告限制」,對稱於 `allowed_links` 空清單的既有慣例——見 ASM-3

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

### `naming.toml` 的 `states` 解析(2026-08-23 階段一閘門新增)

`readNamingToml` / `parseNaming` 加第三個鍵 `states`(選填字串陣列,每個元素過 `mkSegment`,規則
與 `kinds` / `domains` 相同),`NamingVocab` 建構式從 `NamingVocab <$> eKinds <*> eDomains` 改成
`NamingVocab <$> eKinds <*> eDomains <*> eStates`;`unknownErrs` 的允許鍵清單從
`["kinds", "domains"]` 加 `"states"`。`states` 空清單目前不是錯誤(型別上允許,但契約卡的驗收
案例 `spr_char_hero_attack-01_up` 需要 `up` 在表內才過,所以專案實檔的 `naming.toml` 必須非空,
只是型別層面不強制)。

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
| `isIndexShaped :: Text -> Bool` / `indexSegment :: Int -> Either NameError Segment` | `legacy/assetdb/core/src/AssetDB/Naming.hs:257-270` | - | 原樣沿用,是「由右往左剝、只查 `nvStates`」演算法剝離 `npIndex` 的依據 |
| `renderParts :: NameParts -> Either NameError Text` | `legacy/assetdb/core/src/AssetDB/Naming.hs:299-307` | - | 邏輯同構沿用(`npVariant` / `npState` 兩個語意分開的欄位也沿用,不必像舊 ASM-1 那樣重寫拼接順序) |
| `peel :: (Text -> Bool) -> [Segment] -> ([Segment], Maybe Segment)`(`not (null others)` guard) | `legacy/assetdb/core/src/AssetDB/Naming.hs:360-364` | - | guard 邏輯沿用,是「只查 `nvStates`」新演算法避免 subject 撞見 state 詞被誤剝的依據,見待確認假設 ASM-4 |
| `data AssetKind (..)` / `data KindPrefix (..)` / `prefixKind` / `kindPrefixes` | `legacy/assetdb/core/src/AssetDB/Types.hs:70-142` | - | `name_kinds` 對應表與 `naming.toml` 的 `kinds` 詞彙的唯一來源(DEC-5) |

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
  , npVariant :: Maybe Segment   -- 開放,不查詞彙表
  , npState   :: Maybe Segment   -- 封閉,必須在 nvStates 內
  , npIndex   :: Maybe Int
  }
  deriving stock (Eq, Show)

data NamingVocab = NamingVocab
  { nvKinds :: [Segment], nvDomains :: [Segment], nvStates :: [Segment] }
  deriving stock (Show, Eq)

data NameError
  = EmptySegment | BadSegment Text | NoAsciiContent Text | TooLong Int Text
  | UnknownKindPrefix Text | UnknownState Text | TooFewSegments Int Text
  | AmbiguousTrailing [Text] Text | IndexOutOfRange Int
  deriving stock (Eq, Show)
renderNameError :: NameError -> Text

maxLogicalNameLength :: Int   -- 64
indexSegment  :: Int -> Either NameError Segment
isIndexShaped :: Text -> Bool

mkLogicalName       :: NamingVocab -> NameParts -> Either NameError LogicalName
parseLogicalName     :: NamingVocab -> Text -> Either NameError NameParts
validateLogicalName  :: NamingVocab -> TypeKey -> LogicalName -> Either NameError ()
renderParts          :: NameParts -> Either NameError Text
```

（`UnknownState` 是本次階段一閘門後新增的建構子——見「實作方式」的 `mkLogicalName` 對手工建構
`npState` 的驗證。`renderNameError` 對它的文字比照 `UnknownKindPrefix` 的風格:
`"未知的 state 詞 " <> tshow t`。)

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
stages        = []          # 選填,S5 用

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

# states 是命名文法拆解 npState 時唯一查的表(2026-08-23 階段一閘門新增,取代 legacy 的
# nvStates + nvVariants 兩張表)。逐字取自 legacy/assetdb/core/src/AssetDB/Naming.hs 的
# defaultVocab 的 nvStates(37 個詞,分五組),本 feature 審視過分類邊界、沒有找到需要增刪的
# 項目(見「NamingVocab 的三個欄位怎麼用」)。variant 天生開放,刻意不設詞彙表。
states = [
  # 互動狀態
  "idle", "hover", "pressed", "disabled", "active", "selected", "focus",
  # 開合
  "open", "closed", "empty", "full", "on", "off",
  # 動作
  "walk", "run", "attack", "dash", "death", "hurt", "cast",
  # 方向
  "up", "down", "left", "right", "front", "back", "north", "south", "east", "west",
  # 時段與播放段落
  "day", "night", "dawn", "dusk", "intro", "loop", "outro",
]
```

## TodoList

**2026-08-23 階段一閘門推翻 ASM-1 後,以下項目已完成但內容不符新契約,需重做**(勾選狀態保留代表
「這個項目本身仍然要做」,不代表現有程式碼已經符合新契約):STEP-1、STEP-3、STEP-5、STEP-6、STEP-9、STEP-10、STEP-11、STEP-12、
STEP-13。STEP-2、STEP-4、STEP-7、STEP-8、STEP-14 不受影響。

**2026-08-23 重工完成**:STEP-1、STEP-3、STEP-5、STEP-6、STEP-9、STEP-10、STEP-11、STEP-12、STEP-13 已依本文檔新契約(`npVariant` /
`npState` 語意分開、`nvStates` 詞彙、`parseLogicalName` 帶 `NamingVocab`、`checkMeta` 的
`badNameKind` 改切文字不呼叫 `parseLogicalName`)重寫,`cabal test aapms-core aapms-types` 全綠
(224 / 42,0 failures)。

- [x] STEP-1(**需重做**): `aapms-core`:重寫 `Naming.hs`(`Segment` / `NameParts` 改回
  `npVariant :: Maybe Segment` + `npState :: Maybe Segment`〔不是 `npModifiers`〕/ `NamingVocab`
  加 `nvStates` / `NameError` 加 `UnknownState` / `mkLogicalName`〔多驗 `npState ∈ nvStates`〕/
  `parseLogicalName`〔簽名改回帶 `NamingVocab`,演算法改成「由右往左剝、只查 `nvStates`」+
  ASM-4 的 guard〕/ `validateLogicalName` / `renderParts` / `maxLogicalNameLength` / `indexSegment` /
  `isIndexShaped`)  `dep: F001`
- [x] STEP-2: `aapms-core`:重寫 `Registry.hs`(`Family` / `FieldDecl` / `TypeDecl` / `TypeRegistry` /
  `buildRegistry` / `lookupType` / `listTypes` / `lookupDir` / `reservedTypeKeys` 擴充 /
  `RegistryError`)  `dep: T1, F001`
- [x] STEP-3(**需重做**): `aapms-core`:`Registry.hs` 的 `checkMeta`(`missingFields` / `badLinks` /
  `badNameKind`)——`badNameKind` 不能再呼叫完整 `parseLogicalName`(需要 `NamingVocab`,但
  `checkMeta` 簽名沒有這個參數,見 ASM-6),改成直接切 `LogicalName` 文字的第一段  `dep: T2`
- [x] STEP-4: `aapms-core.cabal`:`exposed-modules` 加入 `Aapms.Core.Naming`  `dep: T1`
- [x] STEP-5(**需重做**): `aapms-types`:重寫 `Loader.hs`(`locateRegistry` / `loadRegistry` 新簽名、
  `naming.toml` 排除與解析——`parseNaming` 加第三個鍵 `states`、`NamingVocab` 建構式多帶一個
  引數、`family` / `name_kinds` 解析、`topLevelKeys` 擴充、re-export)  `dep: T2, T3`
- [x] STEP-6(**需重做**): `types/registry/naming.toml`:`kinds`(12 項,不變)、`domains`(空,不變)、
  新增 `states`(37 項,見「TOML 格式規格」選定清單與理由)  `dep: -`
- [x] STEP-7: `types/registry/asset-{image,audio,font,level,shader,doc,source,archive}.toml`
  (新,8 份):`family = "asset"`、對照表填 `name_kinds`(`asset-archive` 留空陣列)、
  `allowed_links = []`  `dep: -`
- [x] STEP-8: `types/registry/{character-fragment,dialogue,item-fragment,lore-fragment,
  plot-fragment}.toml`(改,5 份):各加一行 `family = "entity"`  `dep: -`
- [x] STEP-9(**需重做**): `core/test/Aapms/Core/NamingSpec.hs`:`Segment` 規則、「由右往左剝、只查
  `nvStates`」的 `parseLogicalName` 演算法(含 ASM-4 guard 的邊界案例:單段 subject 撞見 state 詞)、
  `mkLogicalName` 的 `nvKinds` / `nvStates`(`UnknownState`)檢查、`renderParts`  `dep: T1`
- [x] STEP-10(**需重做**): `core/test/Aapms/Core/NamingCasesSpec.hs`:讀
  `contract/fixtures/naming-cases.txt`,逐行以新 `parseLogicalName`(帶 STEP-6 的 `naming.toml`
  詞彙,含 `states`)+ `mkLogicalName` 驗證 ok/bad,`spr_char_hero_attack-01_up` 必須拆出
  `npVariant = Just "attack-01"`、`npState = Just "up"`  `dep: T1, T6, T9`
- [x] STEP-11(**需重做**): `core/test/Aapms/Core/RegistrySpec.hs`:`family` 驗證、
  `reservedTypeKeys` 三項、`buildRegistry` 錯誤彙整(`RegistryErrors`)、`checkMeta`
  對 entity 與 asset 兩族(測試 fixture 建構 `NamingVocab` 時要補上 `nvStates` 欄位)  `dep: T2, T3`
- [x] STEP-12(**需重做**): `types/test/Aapms/Types/LoaderSpec.hs`:新簽名、`naming.toml` 缺漏 /
  格式錯誤(含 `states` 型別錯誤案例)、`family` 缺漏或非法值、13 份真實 TOML(5 entity + 8 asset)
  整批可載入、`locateRegistry` 的 `RegistryNotFound` 情境  `dep: T5, T6, T7, T8`
- [x] STEP-13(**需重做**): `types/test/Aapms/Types/LoaderSpec.hs` 加一個整合測試:對
  `types/registry/`(專案實檔目錄)跑 `loadRegistry`,驗收標準「含原五種 entity 族 + 八種
  asset 族 + `naming.toml`」直接對真實檔案斷言,`NamingVocab` 的 `nvStates` 恰好 37 個
  `dep: T12`
- [x] STEP-14: `core/test/Spec.hs` 與 `types/test/Spec.hs` 的 `describe` 清單補上新 Spec
  `dep: T9, T10, T11, T13`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| STEP-1 | test_segment_and_nameparts_shape | `mkSegment` 對合法/非法輸入的 `Either`;`NameParts` 可建構與存取(含 `npVariant` / `npState` 兩個獨立欄位) |
| STEP-2 | test_family_and_typedecl | `Family` render/parse 互為反函式;`reservedTypeKeys` 含 3 項;`buildRegistry` 對重複鍵 / 空鍵 / 保留鍵回對應 `RegistryError` |
| STEP-3 | test_checkmeta_entity_and_asset | entity 族:缺必填欄位、關聯不在 `allowed_links` 各回一則警告;asset 族:`name_kinds` 內/外的 `LogicalName` 各回是否有 `NameKindNotAllowed`;`astName = Nothing` 不產生 `NameKindNotAllowed`(取 kind 的邏輯不吃 `NamingVocab`,只切文字) |
| STEP-4 | test_cabal_exposes_naming | `aapms-core.cabal` 的 `exposed-modules` 含 `Aapms.Core.Naming` |
| STEP-5 | test_loader_new_signatures | `locateRegistry` / `loadRegistry` 回傳型別為 `Either RegistryError …`;`naming.toml` 不被當成型別宣告解析;`family` / `name_kinds` / `states` 缺漏或型別錯誤各回對應 `RegistryError` |
| STEP-6 | test_naming_toml_shape | `types/registry/naming.toml` 可被 STEP-5 的解析器讀出 12 個 `kinds`、0 個 `domains`、37 個 `states` |
| STEP-7 | test_asset_tomls_loadable | 8 份 asset TOML 各自 `family = FAsset`、`tdNameKinds` 與對照表相符(`asset-archive` 為 `[]`)、`tdDir = Nothing` |
| STEP-8 | test_entity_tomls_still_loadable | 5 份既有 entity TOML 加了 `family = "entity"` 後仍可解析、`tdFamily = FEntity`,其餘欄位與加欄位前相同 |
| STEP-9 | test_parselogicalname_vocab_driven | 對 `spr_char_hero_attack-01_up`:`npVariant = Just "attack-01"`、`npState = Just "up"`(不是 `npModifiers`);`npState` 只在候選段落 `∈ nvStates` 時才成立,不在表內落回 `npVariant`;ASM-4 guard 案例:單段 subject 剛好是 state 詞(如 `spr_char_up`)仍解析出 `npSubject = "up"`、`npState = Nothing`,不誤判成 `TooFewSegments`;3 段以上非 index 尾段回 `AmbiguousTrailing`;`mkLogicalName` 對 `npState = Just <非 nvStates 成員>` 回 `UnknownState`;`renderParts . parseLogicalName == id`(限定合法輸入) |
| STEP-10 | test_naming_cases_fixture | `naming-cases.txt` 全部 `ok` 案例以 `naming.toml` 詞彙(含 `states`)驗證通過,`spr_char_hero_attack-01_up` 額外斷言 `npVariant` / `npState` 拆分正確;全部 `bad` 案例被對應 `NameError` 拒絕 |
| STEP-11 | test_registry_family_reserved_and_errors | `key = "level"` / `"asset-pack"` / `"asset-license"` 各回 `ReservedTypeKey`;`family` 非 `"entity"`/`"asset"` 回 `UnknownFamily`;多重錯誤彙整進 `RegistryErrors` 且逐項可讀 |
| STEP-12 | test_loader_naming_and_family_integration | 缺 `naming.toml` 回 `NamingFileMissing`;`states` 型別錯誤(非字串陣列)回 `BadFieldType`;13 份 fixture TOML(5+8)整批 `loadRegistry` 成功且 `TypeRegistry` 含全部鍵;`locateRegistry` 三層都找不到時回 `RegistryNotFound` 並列出三個查過的路徑 |
| STEP-13 | test_loader_real_registry_dir | 對專案的 `types/registry/` 目錄跑 `loadRegistry`:成功、`TypeRegistry` 恰好 13 個鍵(5 entity + 8 asset)、`NamingVocab` 的 `nvKinds` 恰好 12 個、`nvStates` 恰好 37 個 |
| STEP-14 | test_spec_registration | `core/test/Spec.hs` 引用 `NamingSpec` / `NamingCasesSpec`;`types/test/Spec.hs` 沿用 `LoaderSpec`(內容已擴充) |

## 待確認假設

- ASM-1(**已裁決**,2026-08-23 階段一閘門):原判斷「契約 B 的 `parseLogicalName` 拿掉了
  `NamingVocab` 參數,因此 `npVariant` / `npState` 必須合併成 `npModifiers`」被開發者推翻。裁決:
  語意區分 variant 與 state **有必要保留**,`parseLogicalName` 簽名訂正為
  `NamingVocab -> Text -> Either NameError NameParts`(**帶** `NamingVocab` 參數——這是 design.md
  現在的字面契約,舊 ASM-1 的「拿掉參數」是設計時筆誤,已由開發者確認訂正)。且開發者明確表示**不必
  遷就 legacy 的舊格式與舊資料**(素材可全部重新下載),設計自由度大——因此**不是**簡單「把
  legacy 兩張表原樣搬回來」,而是**只留一張表**(`nvStates`):variant 天生開放、不查表,state
  封閉、必查 `nvStates`。拆解規則(design.md「命名文法的拆解規則」段落逐字):由右往左,①尾端
  三位純數字是 `npIndex`(純語法)→②再往左一段若在 `nvStates` 內是 `npState`→③剩下的一段是
  `npVariant`(開放)→④還有更多段是錯誤。已依此規則逐案代入 `contract/fixtures/naming-cases.txt`
  全部 7 個合法案例驗證(見「實作方式」的推導),`spr_char_hero_attack-01_up` 正確拆出
  `npVariant = Just "attack-01"`、`npState = Just "up"`,不再誤判成 `AmbiguousTrailing`。
  `nvStates` 詞彙不從 legacy 的 27/37 詞照搬而是重新審視,見「NamingVocab 的三個欄位怎麼用」。
- ASM-2:`validateLogicalName` 的 `TypeKey` 參數,在契約卡「`checkMeta` 對 asset 檢查 name 第一段在
  該型別的 `name_kinds` 內……**只回警告**」與「明確不做:不決定警告要不要擋」兩句之間,若
  `validateLogicalName`(回傳硬錯誤 `Either NameError ()`)也做同一件事的型別專屬檢查,會與
  「只警告」的立場矛盾。→ 採取:`validateLogicalName` 只做語法 + `nvKinds` 全域成員檢查,不吃
  `TypeKey` 做型別專屬過濾,型別專屬的 `name_kinds` 檢查完全交給 `checkMeta` → 影響:若編排者
  認為 `validateLogicalName` 確實該依 `TypeKey` 做硬性型別過濾(例如未來某處需要在寫入前**拒絕**
  而非僅警告一個名稱），需要重新設計 `NamingVocab` 的形狀(讓它能依 `TypeKey` 查到專屬
  `name_kinds`,目前的 `nvKinds :: [Segment]` 是扁平清單做不到),屬於契約 C 的變動
- ASM-3:`tdNameKinds` 為空清單時的語意,契約卡與驗收標準都沒有明講(只講「非空時檢查成員」)。
  `asset-archive` 依 DEC-5 的對照表算出來剛好是空清單(legacy `KindPrefix` 沒有任何值對應
  `KArchive`)。→ 採取:比照既有 `allowed_links` 空清單 = 「未宣告限制」的慣例(舊
  `checkEntity`/`badLinks` 明寫「`etsAllowedLinks` 為空視為未宣告限制」),`tdNameKinds` 空清單
  時 `checkMeta` 不對該型別的 asset 產生 `NameKindNotAllowed` → 影響:若編排者認為
  `asset-archive` 應該完全不允許被命名(任何 `name` 都是警告),需要把「空清單」的語意反過來,
  且要另外決定 `asset-archive` 的 `name_kinds` 該填什麼非空值(目前的來源資料——legacy
  `KindPrefix`——就是沒有這個值)
- ASM-4(新增,ASM-1 推翻後浮現的演算法完整性問題):design.md「命名文法的拆解規則」字面上四步驟沒有
  提到 legacy `peel` 函式的「不剝到清空」guard。若照字面實作,單獨一段的 subject 剛好撞見
  `nvStates` 的詞(如 `spr_char_up`,`domain`後只有一段 `up` 且沒有任何 variant/state/index),
  步驟②會把它誤剝成 `npState`,剝完 `remaining` 淨空,步驟③「剩下的一段」不存在,結構上會被判成
  `TooFewSegments`——但這其實是一個完全合法的名稱(`subject = "up"`,沒有 modifier)。
  → 採取:比照 legacy `peel` 的 guard,②的剝除只在「剝掉後 `remaining` 還留得下至少一段」時才
  發生,否則整段留給 subject(見「實作方式」演算法步驟 3b、待驗證的 STEP-9 邊界案例)→ 影響:這是純
  演算法層級的補強,不改變任何契約簽名或 `naming-cases.txt` 既有案例的結果;若編排者認為「subject
  不該與 state 詞彙撞名,撞了就該是使用者的錯」,則這個 guard 要拿掉,`spr_char_up` 這類輸入改成
  回錯誤而非解析成功——這是行為選擇,不是正確性問題,兩種都自洽
- ASM-5(新增):`mkLogicalName` 允許呼叫端手工建構 `NameParts`(不是每次都經過 `parseLogicalName`)。
  若呼叫端把一個剛好在 `nvStates` 內的詞放進 `npVariant`(而非 `npState`),`mkLogicalName` 目前
  **不會**拒絕它(`npVariant` 開放、不查表是刻意設計)——但 `renderParts` 產生的字串經
  `parseLogicalName` 重新拆解時,那段文字會依規則②被歸類成 `npState`,與原始 `NameParts` 的欄位
  標籤不一致(值不變,語意標籤變了)。→ 採取:不視為錯誤——契約與 STEP-9 承諾的是
  `renderParts . parseLogicalName == id`(parse 之後 render 拿回原字串),不是「render 之後 parse
  拿回原始語意標籤」;`npVariant` 的文件字串已經明講「開放,不查詞彙表」,呼叫端若把 state 詞放
  進 `npVariant` 是自找的語意漂移,不是本 feature 的契約義務 → 影響:若編排者認為這個漂移
  不可接受(例如某處依賴「我建構時標的是 variant,讀回來也該是 variant」的不變量),需要在
  `mkLogicalName` 加一條檢查:`npVariant` 不可為 `nvStates` 成員,回一個新錯誤建構子
- ASM-6(新增):`checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` 的契約簽名沒有 `NamingVocab`
  參數,但 ASM-1 裁決後 `parseLogicalName` 需要它,`badNameKind` 因此不能再呼叫完整
  `parseLogicalName` 取得 `npKind`。→ 採取:`badNameKind` 改成直接切 `LogicalName` 文字第一個
  `_` 之前的片段當 kind 文字用,不重新驗證合法性(`astName :: LogicalName` 的唯一建構路徑是
  `mkLogicalName`,已經保證第一段是 `nvKinds` 成員,見「實作方式」的 `checkMeta` 小節)→ 影響:
  若編排者認為 `checkMeta` 未來需要更完整的命名文法資訊(例如也要對 `npState`/`npVariant` 做型別
  專屬檢查),`checkMeta` 的契約簽名要加一個 `NamingVocab` 參數,屬於契約 B 的變動

## 實作備註

- `core/test/Aapms/Core/CabalSpec.hs`(F001 產出)原本斷言 `exposed-modules` __不含__
  `Aapms.Core.Registry`;本 feature 依契約 C 重建該模組是既定契約(design.md「內部模組劃分」
  一開始就把「Registry 純驗證」與「Naming」都歸在 `aapms-core`),因此把這條斷言改成
  `Registry` __應該__出現、只有 `Graph`(F001 的待確認假設 ASM-2,確認不沿用)永久不該出現。
  這不是重寫被取代的整份 Spec(DEC-6 的範圍),只調整其中一個 `it` 的斷言方向,原檔案其餘測試
  (禁用套件、Asset/Pack/License/AnyNode 存在)不動。
- 8 份 asset TOML(STEP-7)與 `naming.toml`(STEP-6)都加了一個 `[[fields]] summary` 區塊 / 註解,
  這在契約卡與驗收標準之外,是實作自主權範圍內的選擇(對照既有 5 份 entity TOML 都有
  `summary` 必填欄位的慣例,讓 asset 族的型別宣告也一致地引導作者/AI 該寫什麼)。
- `aapms-types` 的 `Aapms.Types.Loader` 用 `module Aapms.Core.Registry` /
  `module Aapms.Core.Naming` 整段模組 re-export(而非逐一列名),對應 design.md 契約 C
  「並 re-export 上一項的全部型別」的字面意思——呼叫端只需 `import Aapms.Types.Loader`
  就拿到全部純型別、純驗證與載入 IO。
- `loadRegistryFrom` 的第二個參數(`naming.toml` 路徑)由呼叫端明確給,`loadRegistry`
  內部固定組成 `dir </> "naming.toml"`,符合契約卡「第二個 FilePath 是 naming.toml 的路徑」
  的簽名描述。
- `locateRegistry`/`locateRegistryWith` 的 `RegistryNotFound` 在「環境變數指向不存在目錄」
  情境下只列出那一個查過的路徑(不繼續查執行檔旁與 data-files,沿用舊版「不往下退」的行為);
  在「環境變數未設定、執行檔旁與 data-files 都沒有」情境下列出兩個查過的路徑。專案的
  `cabal test` 環境裡 `data-files` 一定存在(`registry/*.toml` 隨套件裝好),因此「三層都真的
  查無」的完整情境無法在不 mock `getDataDir` 的前提下於本機測試重現,`LoaderSpec` 對這條
  只測了「環境變數指到不存在目錄」與「執行檔旁缺、退到 data-files 成功」兩段,合起來涵蓋
  `RegistryNotFound` 的建構與訊息列路徑的行為,但沒有一個測試案例是三層同時失敗。
