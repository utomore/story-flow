---
id: F003
type: feature
title: manifest-schema-v2
description: 兩份 manifest(assets/story)的 schema 2 型別、JSON 編碼與 kind 專屬型別化讀取
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: [F001, F002]
related-adr: [ADR-012, ADR-014]
related-feature: []
---

# F003: Manifest schema 2(manifest-schema-v2)

## 功能概述

定義 `project` 產出、遊戲本體消費的兩份 manifest 型別:`assets/manifest.json`(`Manifest`,
`schemaVersion = 2`)與 `story/manifest.json`(`StoryManifest`)。這是 graph-core 三條管線之外的
第三種角色——遊戲本體只 import `aapms-core`,而 `Manifest` 一組型別是遊戲本體唯一會用到的
`aapms-core` 匯出(`AssetKey` 是 `Assets.hs` 產生器的查表 key,`manifestIndex` 是遊戲啟動時建表
的入口)。本 feature 只定型別、JSON 編碼、`AssetKey`、`manifestIndex`、`imageMeta`/`audioMeta`
型別化讀取;誰產生 manifest、誰做授權判斷不在範圍內。

**驗收標準**(逐字抄自契約卡):

1. `schemaVersion = 2`,每筆 asset 帶 `id`(短 id)/ `key`(邏輯名稱)/ `path` / `type` / `sha256` /
   `vault`(來源 vault id)/ `pack` / `license`
2. `StoryManifest` 每筆帶 `ref`(`<vault>:<id>`)/ `title` / `summary` / `purpose` / `revision`
3. `FromJSON` 對 `schemaVersion = 1` 回明確錯誤「請重新產生」而不是靜默解析
4. golden file roundtrip 測試

## 相依性

`depends-on: [F001, F002]`——與 `design.md`「功能規劃」表 #3 列(`manifest-schema-v2`,依賴
`#1, #2`)一致,反推自下方「使用到的既有串接介面」表:

- 對 **F001** 的依賴是型別層級的直接使用:`ManifestAsset` 的 `id` / `sha256` / `vault` / `type`
  欄位直接吃 F001 定義的 `Id`(經 `parseId`/`renderId` 的既有 JSON 慣例)、`Sha256`、`VaultId`、
  `TypeKey` newtype;`StoryManifestEntry` 的 `ref` 欄位直接吃 F001 的 `Ref`;`revision` 欄位吃
  F001 的 `Revision`。F001 status 為 `open`(設計已定案、尚未實作),下表對應列的「來源檔案」
  填「尚未實作」、「來源文檔」填 `F001`
- 對 **F002** 的依賴是資料層級的:golden fixture 與測試裡 `ManifestAsset.type` 使用的具體字面值
  (`"asset-image"` 等 8 個鍵)是 F002 在 `types/registry/` 宣告的 asset 族型別鍵,`"asset-pack"` /
  `"asset-license"` 是 F002 訂為保留鍵、因此**不會**出現在任何 asset 的 `type` 欄位裡——這條「合法
  取值範圍」的事實只有 F002 定案後才存在依據,本 feature 的型別定義本身(`TypeKey` 是 F001 的自由
  文字 newtype)不強制檢查這個範圍(那是 `checkMeta`,F002 的範圍),但測試資料的正確性建立在 F002
  之上

`manifest-schema-v2` 不依賴階段二、三的任何 feature(`aapms-md` / `aapms-store` 尚未存在),也不
被階段一其餘 feature 依賴——可與 `md-unified-sections`(#4)等階段二 feature 平行開發,只要 F001 /
F002 先定案。

D1(委派決策記錄):下游套件已從 `cabal.project` 凍結,`service` / `project` / `cli` / … 舊碼一律
不碰、不考慮相容。

## 對應的 Level 2 契約

### 契約 B(部分,依契約卡指定)

- `data Manifest`(`assets/manifest.json, schemaVersion = 2`)
- `data StoryManifest`(`story/manifest.json`)
- `newtype AssetKey = AssetKey Text`
- `manifestIndex :: Manifest -> Map AssetKey ManifestAsset`
- `imageMeta :: Value -> Maybe ImageMeta`、`audioMeta :: Value -> Maybe AudioMeta`(design.md 契約 A
  段落緊接 `astKindMeta :: Value` 之後提出,但契約卡明文把這兩個函式的實作指派給本 feature)

**不做**:契約 B 其餘函式(`newId` / `parseId` / `parseRef` / `renderRef` / `prefixOf` /
`buildTree` 屬 #1;`checkMeta` / `mkLogicalName` / `parseLogicalName` / `validateLogicalName` 屬
#2)。

### 明確不做(契約卡逐字)

不產生 manifest(`project`);不產生 `Assets.hs`(`project`);不做授權判斷。

## 相依性查證

### 舊 `AssetDB.Manifest`(schema 1,本 feature 改寫的參照基準,**不移植欄位**只作對照)

- `currentSchemaVersion :: Int` `= 1` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:52-53`
- `data Manifest = Manifest { mSchemaVersion :: Int, mProject :: Text, mGeneratedAt :: UTCTime,
  mAssets :: [ManifestAsset], mPacks :: [ManifestPack], mLicenses :: [ManifestLicense] }` ——
  `legacy/assetdb/core/src/AssetDB/Manifest.hs:55-64`
- `newtype AssetKey = AssetKey { unAssetKey :: Text }` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:70-71`
  (**不沿用欄位存取器**:契約卡把簽名寫死成 `newtype AssetKey = AssetKey Text`,無 record 語法,
  與 F001 全部具名純量 newtype 的風格一致——見「新增的介面」)
- `data ManifestAsset = ManifestAsset { maId :: ULID, maKey :: LogicalName, maPath :: Text,
  maKind :: AssetKind, maSha256 :: Text, maPack :: Maybe Text, maLicense :: Maybe Text,
  maMeta :: Value }` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:74-90`
  (`maId` 是 ULID 字串;`maKind` 是封閉的 `AssetKind` 列舉,非型別註冊表鍵;`maPack`/`maLicense`
  是**名稱**字串,非圖譜身分——三處都是本次改寫要修正的形狀落差,見「JSON 形狀規格」與待確認假設)
- `data ManifestPack = ManifestPack { mpName :: Text, mpVendor :: Maybe Text, mpSourceUrl :: Maybe Text,
  mpVersion :: Maybe Text, mpLicense :: Maybe Text }` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:92-99`
  (`mpVersion` **不沿用**:新 `Pack` 型別(F001 契約 A)沒有 version 欄位)
- `data ManifestLicense = ManifestLicense { mlName :: Text, mlCommercial :: Bool,
  mlAttributionRequired :: Bool, mlNotes :: Maybe Text }` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:101-108`
  (新 `License`(F001 契約 A)有 9 個欄位,本次擴充對齊,見「JSON 形狀規格」)
- `manifestIndex :: Manifest -> Map Text ManifestAsset` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:114-116`
  (鍵型別從 `Text` 改成契約 B 指定的 `AssetKey`,邏輯不變:以 `key` 欄位建表)
- `lookupAsset :: LogicalName -> Manifest -> Maybe ManifestAsset` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:118-119`
  (**不沿用**:契約 B 只列出 `manifestIndex`,`lookupAsset` 不在清單內,呼叫端可用
  `Map.lookup` 自己做,不多開一個函式)
- `data ImageMeta = ImageMeta { imWidth :: Int, imHeight :: Int, imHasAlpha :: Bool,
  imColorCount :: Maybe Int }` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:124-132`(原樣沿用)
- `data AudioMeta = AudioMeta { amDurationMs :: Int, amSampleRate :: Int, amChannels :: Int }` ——
  `legacy/assetdb/core/src/AssetDB/Manifest.hs:134-139`(原樣沿用)
- `imageMeta :: ManifestAsset -> Maybe ImageMeta` / `audioMeta :: ManifestAsset -> Maybe AudioMeta`
  —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:142-146`(`parseMaybe parseJSON . maMeta`;
  **簽名改變**:契約 B 寫的是 `Value -> Maybe ImageMeta`,拿掉了 `ManifestAsset` 包裝,直接吃
  `Value`——見「JSON 形狀規格」的 `meta` 欄位與待確認假設 A1)
- `checkVersion :: Int -> Parser ()` —— `legacy/assetdb/core/src/AssetDB/Manifest.hs:176-185`
  (「版本不符要直接拒絕載入並給出明確訊息」的立場原樣沿用,訊息文字改成 schema 2 與
  `aapms project sync`)
- `instance FromJSON Manifest` 先讀 `schemaVersion` 再 `checkVersion` 短路 —— `:165-174`
  (fail-fast 順序原樣沿用,見「實作方式」)

### F001(尚未實作,型別依據)

- `Id`(短 id,ADR-014 格式 `<prefix>-<8 hex>`)——`ManifestAsset.id`;既有 `Id` 的 `ToJSON`/`FromJSON`
  慣例(字串,非物件)由 F001 的 `Json.hs` 建立,本 feature 沿用同一慣例
- `newtype Sha256 = Sha256 Text` —— `ManifestAsset.sha256`
- `newtype VaultId = VaultId Text` —— `ManifestAsset.vault`
- `newtype TypeKey = TypeKey Text` —— `ManifestAsset.type`
- `newtype Revision = Revision Int` —— `StoryManifestEntry.revision`
- `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`renderRef :: Ref -> Text` ——
  `StoryManifestEntry.ref`,JSON 沿用 F001 既定的字串編碼(`"<vault>:<id>"` 或 `"<id>"`)

### F002(尚未實作,資料依據)

- `types/registry/asset-{image,audio,font,level,shader,doc,source,archive}.toml` 的
  `key = "asset-<kind>"` 8 個具體值——golden fixture 與測試的 `type` 欄位字面值來源
- `reservedTypeKeys` 含 `"asset-pack"` / `"asset-license"`——保證這兩個鍵不會出現在任何
  `ManifestAsset.type`,是本 feature golden fixture 選值合法性的依據

## 實作方式

### 套件內模組配置

本 feature 只新增**一個型別模組**,JSON 編碼規則依 `design.md`「內部模組劃分」的既有分工
(`Json | 全系統唯一的 aeson 編碼規則`)放進 F001 建立的 `Json.hs`,不在 `Manifest.hs` 裡另開
孤兒實例:

| 檔案 | 內容 |
|---|---|
| `core/src/Aapms/Core/Manifest.hs`(新) | `AssetKey`、`Manifest`、`ManifestAsset`、`ManifestPack`、`ManifestLicense`、`StoryManifest`、`StoryManifestEntry`、`ImageMeta`、`AudioMeta`、`currentSchemaVersion` / `currentStoryManifestSchemaVersion`、`manifestIndex`、`imageMeta`、`audioMeta` |
| `core/src/Aapms/Core/Json.hs`(F001 已建,本 feature 擴充) | 上述全部型別的 `ToJSON`/`FromJSON`,含兩份 manifest 各自的 `schemaVersion` 短路檢查 |

### `schemaVersion` 短路檢查(兩份 manifest 各自獨立)

沿用舊 `Manifest.hs:165-185` 的 fail-fast 順序:`FromJSON` 先讀 `schemaVersion` 欄位、版本不符
立刻 `fail` 明確中文訊息,不繼續解析其餘欄位(避免版本不符時連鎖冒出一堆缺欄位錯誤,蓋掉真正
原因)。`Manifest` 與 `StoryManifest` **各自有獨立的 `schemaVersion` 欄位與獨立的版本常數**——
`story/manifest.json` 是本次新增的檔案,schema 1 時代不存在,理由見待確認假設 A4。

```haskell
checkSchemaVersion :: Text -> Int -> Int -> Parser ()
checkSchemaVersion docName expected got
  | got == expected = pure ()
  | otherwise =
      fail $ T.unpack docName <> " schemaVersion 是 " <> show got <> ",本工具只支援 "
        <> show expected <> "。請重新產生(aapms project sync)。"
```

`Manifest` 呼叫 `checkSchemaVersion "manifest" 2`,`StoryManifest` 呼叫
`checkSchemaVersion "story manifest" 2`。

### `imageMeta` / `audioMeta` 的簽名落差(對照舊版)

契約 B 寫 `imageMeta :: Value -> Maybe ImageMeta`(直接吃 `Value`),舊版是
`ManifestAsset -> Maybe ImageMeta`(`maMeta` 取值後再吃)。新簽名讓這兩個函式同時適用於
`ManifestAsset` 的 `meta` 欄位與契約 A `Asset.astKindMeta`(F001,兩者都是 `Value`)——呼叫端
自己取欄位再傳入(`imageMeta (maMeta asset)` 或 `imageMeta (astKindMeta asset)`),函式本體邏輯
與舊版相同(`parseMaybe parseJSON`)。

### `pack` / `license` 欄位:name → id 的形狀修正

舊版 `maPack :: Maybe Text` / `maLicense :: Maybe Text` 存的是**名稱**,合併後 pack 與 license
都是圖譜節點(ADR-012)、有短 id。契約卡沒有規定這兩欄的確切型別,只規定欄位存在;本 feature
選擇存**同 vault 內的短 id**(`Maybe Id`)而非全域 `Ref`——理由見待確認假設 A2。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Id`,`Id` 的 `ToJSON`/`FromJSON`(字串編碼) | 尚未實作 | F001 | `ManifestAsset.id` / `ManifestPack.id` / `ManifestLicense.id`,沿用既定字串編碼慣例 |
| `newtype Sha256 = Sha256 Text` | 尚未實作 | F001 | `ManifestAsset.sha256` |
| `newtype VaultId = VaultId Text` | 尚未實作 | F001 | `ManifestAsset.vault` |
| `newtype TypeKey = TypeKey Text` | 尚未實作 | F001 | `ManifestAsset.type` |
| `newtype Revision = Revision Int` | 尚未實作 | F001 | `StoryManifestEntry.revision` |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`renderRef :: Ref -> Text` | 尚未實作 | F001 | `StoryManifestEntry.ref`,`"<vault>:<id>"` 字串編碼 |
| `types/registry/asset-image.toml` 等 8 份的 `key = "asset-<kind>"` | 尚未實作(TOML 資料,非程式碼) | F002 | golden fixture 與測試裡 `type` 欄位的合法字面值 |
| `reservedTypeKeys` 含 `"asset-pack"` / `"asset-license"` | 尚未實作 | F002 | 保證 golden fixture 的 `type` 值不誤用保留鍵 |
| `currentSchemaVersion :: Int` `= 1`,`FromJSON Manifest` 的 `checkVersion` 短路寫法 | `legacy/assetdb/core/src/AssetDB/Manifest.hs:52-53, 165-185` | - | 本次改寫的 fail-fast 模式起點,版本號與訊息文字改新 |
| `data ImageMeta (..)` / `data AudioMeta (..)` | `legacy/assetdb/core/src/AssetDB/Manifest.hs:124-139` | - | 原樣沿用,無改動 |
| `manifestIndex :: Manifest -> Map Text ManifestAsset` | `legacy/assetdb/core/src/AssetDB/Manifest.hs:114-116` | - | 改寫起點,鍵型別換成 `AssetKey` |

## JSON 形狀規格

### `assets/manifest.json`(`Manifest`,`schemaVersion = 2`)

```haskell
data Manifest = Manifest
  { mSchemaVersion :: Int              -- 固定 2
  , mProject       :: Text
  , mGeneratedAt   :: UTCTime
  , mAssets        :: [ManifestAsset]
  , mPacks         :: [ManifestPack]   -- 出現在 mAssets 的 pack,去重
  , mLicenses      :: [ManifestLicense] -- 出現在 mAssets 的 license,去重
  }

data ManifestAsset = ManifestAsset
  { maId      :: Id        -- 短 id,ast- 前綴
  , maKey     :: AssetKey  -- 邏輯名稱文字,遊戲載入器查表 key(Assets.hs 的常數)
  , maPath    :: Text      -- 專案根目錄相對路徑,/ 分隔
  , maType    :: TypeKey   -- 註冊表鍵,asset-<kind>(F002 宣告的 8 個值之一)
  , maSha256  :: Sha256
  , maVault   :: VaultId   -- 來源 vault id
  , maPack    :: Maybe Id  -- 所屬 pack 節點的短 id(與該 asset 同一 vault)
  , maLicense :: Maybe Id  -- 授權節點的短 id(與該 asset 同一 vault)
  , maMeta    :: Value     -- kind 專屬 JSON;imageMeta/audioMeta 型別化讀取
  }

data ManifestPack = ManifestPack
  { mpId        :: Id
  , mpTitle     :: Text        -- 對應 Pack 的 metaTitle
  , mpVendor    :: Maybe Text
  , mpSourceUrl :: Maybe Text
  , mpLicense   :: Maybe Id
  }

data ManifestLicense = ManifestLicense
  { mlId                    :: Id
  , mlTitle                 :: Text   -- 對應 License 的 metaTitle
  , mlCommercial            :: Bool
  , mlAttributionRequired   :: Bool
  , mlCreditText            :: Maybe Text
  , mlModificationAllowed   :: Maybe Bool
  , mlRedistributionAllowed :: Maybe Bool
  , mlResaleAllowed         :: Maybe Bool
  , mlNftAllowed            :: Maybe Bool
  , mlSourceUrl             :: Maybe Text
  }
```

JSON 範例(`assets/manifest.json`):

```json
{
  "schemaVersion": 2,
  "project": "Circle",
  "generatedAt": "2026-08-23T10:00:00Z",
  "assets": [
    {
      "id": "ast-3f9c1d20",
      "key": "ui_gui_travel-book-frame_001",
      "path": "sprites/ui_gui_travel-book-frame_001.png",
      "type": "asset-image",
      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1",
      "vault": "vlt-a0c4e1f8",
      "pack": "pck-11223344",
      "license": "lic-55667788",
      "meta": { "width": 512, "height": 512, "hasAlpha": true, "colorCount": 128 }
    },
    {
      "id": "ast-7ad20c31",
      "key": "sfx_ui_button-click_001",
      "path": "audio/sfx_ui_button-click_001.ogg",
      "type": "asset-audio",
      "sha256": "3b241101707d52a324d3540c8bcffbca8ea0d1e1e2a3e1c3e1b6b6b3f7a2b0f",
      "vault": "vlt-a0c4e1f8",
      "pack": null,
      "license": null,
      "meta": { "durationMs": 240, "sampleRate": 44100, "channels": 2 }
    }
  ],
  "packs": [
    {
      "id": "pck-11223344",
      "title": "Kenney UI Pack",
      "vendor": "Kenney",
      "sourceUrl": "https://kenney.nl/assets/ui-pack",
      "license": "lic-55667788"
    }
  ],
  "licenses": [
    {
      "id": "lic-55667788",
      "title": "CC0",
      "commercial": true,
      "attributionRequired": false,
      "creditText": null,
      "modificationAllowed": true,
      "redistributionAllowed": true,
      "resaleAllowed": true,
      "nftAllowed": true,
      "sourceUrl": "https://creativecommons.org/publicdomain/zero/1.0/"
    }
  ]
}
```

### `story/manifest.json`(`StoryManifest`)

```haskell
data StoryManifest = StoryManifest
  { smSchemaVersion :: Int                  -- 固定 2
  , smProject       :: Text
  , smGeneratedAt   :: UTCTime
  , smEntities      :: [StoryManifestEntry]
  }

data StoryManifestEntry = StoryManifestEntry
  { smeRef      :: Ref     -- "<vault>:<id>",不複製任何位元組
  , smeTitle    :: Text
  , smeSummary  :: Text
  , smePurpose  :: Text    -- 這筆 Entity 在本專案的用途(project 產出時填寫的自由文字)
  , smeRevision :: Revision
  }
```

JSON 範例(`story/manifest.json`):

```json
{
  "schemaVersion": 2,
  "project": "Circle",
  "generatedAt": "2026-08-23T10:00:00Z",
  "entities": [
    {
      "ref": "vlt-9d2e5b70:ent-7f3b2a91",
      "title": "琳達",
      "summary": "旅店老闆娘,知道鎮上所有的八卦",
      "purpose": "主角的資訊來源與旁白視角",
      "revision": 3
    }
  ]
}
```

### `AssetKey` 與 `manifestIndex`

```haskell
newtype AssetKey = AssetKey Text
  deriving newtype (Eq, Ord, Show)

manifestIndex :: Manifest -> Map AssetKey ManifestAsset
manifestIndex m = Map.fromList [(maKey a, a) | a <- mAssets m]
```

`AssetKey` 的 JSON 是純字串(與 `LogicalName` 的文字相同,但型別上互不相通——`AssetKey` 不經
`Naming` 模組的任何驗證函式,只是 manifest/`Assets.hs` 查表用的不透明字串;`LogicalName` 才是
命名文法(F002)管轄的型別)。

## 新增的介面

```haskell
-- Aapms.Core.Manifest

newtype AssetKey = AssetKey Text
  deriving newtype (Eq, Ord, Show)

currentSchemaVersion :: Int
currentSchemaVersion = 2               -- assets/manifest.json

currentStoryManifestSchemaVersion :: Int
currentStoryManifestSchemaVersion = 2  -- story/manifest.json

data Manifest = Manifest
  { mSchemaVersion :: Int, mProject :: Text, mGeneratedAt :: UTCTime
  , mAssets :: [ManifestAsset], mPacks :: [ManifestPack], mLicenses :: [ManifestLicense]
  }
  deriving stock (Eq, Show)

data ManifestAsset = ManifestAsset
  { maId :: Id, maKey :: AssetKey, maPath :: Text, maType :: TypeKey, maSha256 :: Sha256
  , maVault :: VaultId, maPack :: Maybe Id, maLicense :: Maybe Id, maMeta :: Value
  }
  deriving stock (Eq, Show)

data ManifestPack = ManifestPack
  { mpId :: Id, mpTitle :: Text, mpVendor :: Maybe Text, mpSourceUrl :: Maybe Text
  , mpLicense :: Maybe Id
  }
  deriving stock (Eq, Show)

data ManifestLicense = ManifestLicense
  { mlId :: Id, mlTitle :: Text, mlCommercial :: Bool, mlAttributionRequired :: Bool
  , mlCreditText :: Maybe Text, mlModificationAllowed :: Maybe Bool
  , mlRedistributionAllowed :: Maybe Bool, mlResaleAllowed :: Maybe Bool
  , mlNftAllowed :: Maybe Bool, mlSourceUrl :: Maybe Text
  }
  deriving stock (Eq, Show)

data StoryManifest = StoryManifest
  { smSchemaVersion :: Int, smProject :: Text, smGeneratedAt :: UTCTime
  , smEntities :: [StoryManifestEntry]
  }
  deriving stock (Eq, Show)

data StoryManifestEntry = StoryManifestEntry
  { smeRef :: Ref, smeTitle :: Text, smeSummary :: Text, smePurpose :: Text
  , smeRevision :: Revision
  }
  deriving stock (Eq, Show)

data ImageMeta = ImageMeta
  { imWidth :: Int, imHeight :: Int, imHasAlpha :: Bool, imColorCount :: Maybe Int }
  deriving stock (Eq, Show)

data AudioMeta = AudioMeta
  { amDurationMs :: Int, amSampleRate :: Int, amChannels :: Int }
  deriving stock (Eq, Show)

manifestIndex :: Manifest -> Map AssetKey ManifestAsset
imageMeta :: Value -> Maybe ImageMeta
audioMeta :: Value -> Maybe AudioMeta
```

## TodoList

- [x] T1: `Manifest.hs`(新):`AssetKey`、`Manifest`/`ManifestAsset`/`ManifestPack`/`ManifestLicense`、
  `StoryManifest`/`StoryManifestEntry`、`ImageMeta`/`AudioMeta`、兩個 `currentSchemaVersion` 常數、
  `manifestIndex`、`imageMeta`、`audioMeta`  `dep: F001, F002`
- [x] T2: `Json.hs`(F001 基礎上擴充):上述全部型別的 `ToJSON`/`FromJSON`,`Manifest`/
  `StoryManifest` 的 `FromJSON` 各自先檢查 `schemaVersion` 再解析其餘欄位  `dep: T1`
- [x] T3: `aapms-core.cabal`:`exposed-modules` 加入 `Aapms.Core.Manifest`  `dep: T1`
- [x] T4: 新增 golden fixtures `core/test/golden/manifest.golden.json` +
  `core/test/golden/story-manifest.golden.json`(手寫,對應本文件「JSON 形狀規格」的範例)
  `dep: T1`
- [x] T5: `core/test/Aapms/Core/ManifestSpec.hs`:golden roundtrip(兩份檔案各自 decode → encode →
  語意相同 JSON;decode 後的型別值可再 encode/decode 相等)  `dep: T2, T4`
- [x] T6: `ManifestSpec.hs`:`schemaVersion` 錯誤路徑(`Manifest` 與 `StoryManifest` 各自對
  `schemaVersion = 1` 與 `= 3` 回 `Left`,錯誤訊息含「請重新產生」)  `dep: T2`
- [x] T7: `ManifestSpec.hs`:`manifestIndex` 正確性(以 `AssetKey` 建表、查得到已知 key、查不到
  不存在 key)  `dep: T1`
- [x] T8: `ManifestSpec.hs`:`imageMeta`/`audioMeta` 型別化讀取(相符 kind 的 `Value` 回 `Just` 且
  欄位正確;不相符/欄位缺漏回 `Nothing` 或以預設值解析,對照 `ImageMeta`/`AudioMeta` 各自的
  `FromJSON`)  `dep: T1, T2`
- [x] T9: `core/test/Spec.hs` 的 `describe` 清單加入 `ManifestSpec`  `dep: T5, T6, T7, T8`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_manifest_types_construct | 全部新型別可建構、欄位可存取;`AssetKey` 可比較與排序(`Ord`) |
| T2 | test_json_field_names | `toJSON` 一筆 `ManifestAsset` 恰好得到 `id`/`key`/`path`/`type`/`sha256`/`vault`/`pack`/`license`/`meta` 九個鍵;`toJSON` 一筆 `StoryManifestEntry` 恰好得到 `ref`/`title`/`summary`/`purpose`/`revision` 五個鍵 |
| T3 | test_cabal_exposes_manifest | `aapms-core.cabal` 的 `exposed-modules` 含 `Aapms.Core.Manifest` |
| T4 | test_golden_files_valid_json | 兩份 golden 檔可被 `eitherDecodeStrict` 解成合法 `Value`,且 `schemaVersion` 鍵存在且為 `2` |
| T5 | test_golden_roundtrip | `manifest.golden.json` decode 成 `Manifest`、encode 回去與原始檔案語意相同(鍵序無關);`story-manifest.golden.json` 對 `StoryManifest` 同樣成立 |
| T6 | test_schema_version_rejected | `Manifest`/`StoryManifest` 對 `schemaVersion = 1` 與 `= 3` 的 `FromJSON` 皆回 `Left`,訊息字串含 `"請重新產生"` |
| T7 | test_manifest_index | 3 筆 fixture asset 建出的 `manifestIndex`,對已知 `AssetKey` 回 `Just`、對不存在的 `AssetKey` 回 `Nothing` |
| T8 | test_image_audio_meta | 合法 image `Value` → `imageMeta` 回 `Just` 且四欄正確;合法 audio `Value` → `audioMeta` 回 `Just`;image `Value` 餵給 `audioMeta` 回 `Nothing`;`imColorCount` 缺漏時 `imageMeta` 仍解析成功(`Nothing`) |
| T9 | test_spec_registration | `core/test/Spec.hs` 的 `describe` 清單引用 `ManifestSpec` |

## 待確認假設

- A1:契約 B 把 `imageMeta` / `audioMeta` 的簽名寫成 `Value -> Maybe ImageMeta`(拿掉舊版的
  `ManifestAsset` 包裝),但 design.md 提出這兩個函式時是緊接在契約 A 的 `Asset.astKindMeta`
  之後,而非契約 B 的 `Manifest` 型別區塊裡;契約卡卻明確把它們指派給本 feature(manifest-schema-v2)
  而不是 F001(core-unified-meta)。→ 採取:視為「通用於任何 kind 專屬 `Value` 的型別化讀取」,
  同時可套用在 `ManifestAsset.meta` 與 F001 的 `Asset.astKindMeta` 兩處,函式本體在 `aapms-core`
  只實作一次 → 影響:若編排者認為這兩個函式其實該歸 F001(因為 `astKindMeta` 是 F001 定義的
  欄位),只是搬移歸屬,簽名與行為不變,不影響其他判斷
- A2:`ManifestAsset.pack` / `maLicense` 與 `ManifestPack.mpLicense` 的型別,契約卡只規定「帶
  `pack` / `license` 兩個欄位」,未規定確切型別。舊版是**名稱**字串(`Maybe Text`),但 pack 與
  license 在合併後(ADR-012)都是圖譜節點、有短 id。→ 採取:選 `Maybe Id`(同 vault 內的短 id,
  不用 `Ref`),理由是 pack.md / licenses.md 是同一個 vault 內的檔案,asset 引用的 pack/license
  一定與 asset 本身同 vault,不需要跨 vault 定址的 `<vault>:<id>` 形式;`ManifestAsset.vault` 欄位
  已經標明了這個共同的 vault 語境 → 影響:若編排者認為 manifest 需要支援「pack/license 來自另一個
  vault」的情境(目前 `design.md` 沒有描述這種情境),`Maybe Id` 要改成 `Maybe Ref`,`aapms-store`
  寫 pack.md 的邏輯與寫 manifest 的邏輯(`project`)都要能表達跨 vault 引用
- A3:`Manifest` 頂層是否要有 `packs` / `licenses` 兩個去重清單,契約卡完全沒提(只提到
  `ManifestAsset` 逐筆要帶 `pack` / `license` 兩個欄位)。→ 採取:比照舊版與 `system.md`「專案
  目錄」一節「`manifest.json` ← 素材……**授權**……」的描述,保留頂層 `packs` / `licenses` 兩個
  去重清單,供遊戲端做致謝名單與授權稽核(`ManifestPack` / `ManifestLicense` 的完整欄位見「JSON
  形狀規格」)→ 影響:若編排者認為 manifest 不該重複帶這兩份資料(遊戲端本來就只認 `assets` 陣列
  裡的 id,去重清單只是方便),移除這兩個頂層欄位是相容性改動,`Manifest` 型別與兩份 golden file
  都要跟著改
- A4:`StoryManifest` 是否要有獨立的 `schemaVersion` 欄位與獨立的版本拒絕邏輯,契約卡「`FromJSON`
  對 `schemaVersion = 1` 回明確錯誤」這句話緊接在 `StoryManifest` 欄位清單之後,但 schema 1 時代
  (assetdb)根本沒有 `story/manifest.json` 這個檔案,不存在真正的「舊版本」可拒絕。→ 採取:仍然
  給 `StoryManifest` 一個獨立 `schemaVersion` 欄位與同樣的短路拒絕邏輯(對稱於 `Manifest`,為未來
  `story/manifest.json` 若要 schema 3 預留同一套機制),而非省略這個欄位 → 影響:若編排者認為
  `story/manifest.json` 不需要版本號(它從一開始就沒有相容性負擔),`smSchemaVersion` 欄位與 T6
  對 `StoryManifest` 的版本拒絕測試要整個移除,JSON 形狀也要跟著拿掉這個鍵

## 實作備註

- `imageMeta` / `audioMeta` 依文件指示「不在 `Manifest.hs` 開孤兒實例」放進 `Json.hs`,但這與
  `imageMeta :: Value -> Maybe ImageMeta` 要直接呼叫 `parseJSON` 產生了真正的模組環——`Json.hs`
  要 import `Manifest.hs` 才能定義 `instance FromJSON ImageMeta`,若 `imageMeta` 又靠型別類別解析
  就必須反向 import `Json.hs`,兩個模組互相 import 在 Haskell 裡不合法。解法:`Manifest.hs` 匯出
  `parseImageMeta :: Value -> Parser ImageMeta` / `parseAudioMeta :: Value -> Parser AudioMeta`
  兩個**純函式**(非型別類別方法),`imageMeta`/`audioMeta` 直接呼叫它們;`Json.hs` 的
  `instance FromJSON ImageMeta` 再委派回同一份函式(`parseJSON = parseImageMeta`)。邏輯仍然只有
  一份,`Manifest.hs` 沒有任何 `instance ToJSON`/`FromJSON` 宣告,符合「唯一一份 aeson 編碼規則」的
  精神——只是解析邏輯的「定義處」在 `Manifest.hs`、「型別類別掛勾」在 `Json.hs`。
- `maPack` / `maLicense`(以及 `ManifestPack`/`ManifestLicense` 內的選填欄位)採用 aeson 對
  `Maybe a` 的內建行為:鍵**恆存在**,`Nothing` 編碼為 `null` 而非省略鍵。這與 `Asset`/`Pack` 等
  型別「`Nothing` 就省略鍵」的既有慣例不同,但與 F003 doc 給的 JSON 範例(`"pack": null` 顯式出現)
  和驗收標準 T2「恰好九個鍵」一致,屬型別內部 JSON 形狀的自主決定,不影響契約簽名。
- golden 檔案讀取沿用 `CabalSpec.hs` 的雙路徑探測寫法(`core/test/golden/...` 與
  `test/golden/...`),因為測試可能從專案根目錄或 `core/` 底下執行。
