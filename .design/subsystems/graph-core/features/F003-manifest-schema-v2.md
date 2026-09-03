---
id: F003
type: feature
title: manifest-schema-v2
description: 兩份 manifest(assets/story)的 schema 2 型別、JSON 編碼與 kind 專屬型別化讀取
status: done
created: 2026-08-23
updated: 2026-09-04
stage: S1
modules: [Manifest]
depends-on: [graph-core/F001, graph-core/F002]
related-adr: [ADR-012, ADR-014]
related-feature: []
code-paths: [core/aapms-core.cabal, core/src/Aapms/Core/Json.hs, core/src/Aapms/Core/Manifest.hs, core/test/Aapms/Core/CabalSpec.hs, core/test/Aapms/Core/ManifestSpec.hs, core/test/Spec.hs]
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

DEC-1(委派決策記錄):下游套件已從 `cabal.project` 凍結,`service` / `project` / `cli` / … 舊碼一律
不碰、不考慮相容。

## 契約

- **階段**:階段一
- **負責模組**:Manifest(`aapms-core`)
- **驗收標準**(契約卡原文):`schemaVersion = 2`,每筆 asset 帶 `id`(短 id)/ `key`(邏輯名稱)/ `path` / `type` /
  `sha256` / `vault`(來源 vault id)/ `pack` / `license`;`StoryManifest` 每筆帶 `ref`(`<vault>:<id>`)/
  `title` / `summary` / `purpose` / `revision`;`FromJSON` 對 `schemaVersion = 1` 回明確錯誤「請重新產生」
  而不是靜默解析;golden file roundtrip 測試

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

- **明確不做**(契約卡原文):不產生 manifest(`project`);不產生 `Assets.hs`(`project`);不做授權判斷

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
  `Value`——見「JSON 形狀規格」的 `meta` 欄位與待確認假設 ASM-1)
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
`story/manifest.json` 是本次新增的檔案,schema 1 時代不存在,理由見待確認假設 ASM-4。

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
最初選擇存**同 vault 內的短 id**(`Maybe Id`),2026-08-23 階段一閘門裁決改為 **`Maybe Ref`**
——見下方「已裁決假設」ASM-2 與「實作備註」。

**manifest 內部引用一律 vault 化**(2026-08-23 二輪裁決,補正第一輪的不完整之處):第一輪只把
`ManifestAsset.maPack` / `maLicense` 這兩個「指過去」的欄位改成 `Ref`,但頂層 `packs` /
`licenses` 清單裡被指的那一端(`ManifestPack.mpId` / `ManifestLicense.mlId`)仍是裸短 `Id`,
造成「引用」與「被引用」兩端形狀不對稱——要比對得先剝掉 asset 端的 vault 前綴,剝掉後又回到
短 id 只在單一 vault 內唯一、跨 vault 撞名的原始問題,ASM-2 想擋的事情沒真正擋成。修正後
`ManifestPack.mpId`、`ManifestLicense.mlId`、`ManifestPack.mpLicense`(它指向頂層 licenses
清單,同樣的引用關係)全部改成 `Ref`,manifest 內部的引用圖(asset → pack、asset → license、
pack → license)兩端一致,用 `Ref` 相等比對就能唯一對應,兩個 vault 各有一筆 `pck-11223344`
時仍是兩筆可區分的項目。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Id`,`Id` 的 `ToJSON`/`FromJSON`(字串編碼) | 尚未實作 | F001 | `ManifestAsset.id`(短 id,本筆定義自己的身分),沿用既定字串編碼慣例 |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`renderRef` / `parseRef` | 尚未實作 | F001 | `ManifestPack.id` / `ManifestLicense.id` / `ManifestPack.license`(2026-08-23 二輪裁決:manifest 內部引用圖 vault 化) |
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
  , maPack    :: Maybe Ref -- 所屬 pack 節點的跨 vault 參照,"<vault>:<id>"(2026-08-23 裁決 ASM-2)
  , maLicense :: Maybe Ref -- 授權節點的跨 vault 參照,"<vault>:<id>"(2026-08-23 裁決 ASM-2)
  , maMeta    :: Value     -- kind 專屬 JSON;imageMeta/audioMeta 型別化讀取
  }

data ManifestPack = ManifestPack
  { mpId        :: Ref         -- "<vault>:<id>"(2026-08-23 二輪裁決:vault 化,見上方說明)
  , mpTitle     :: Text        -- 對應 Pack 的 metaTitle
  , mpVendor    :: Maybe Text
  , mpSourceUrl :: Maybe Text
  , mpLicense   :: Maybe Ref   -- "<vault>:<id>",指向頂層 licenses 清單
  }

data ManifestLicense = ManifestLicense
  { mlId                    :: Ref   -- "<vault>:<id>"
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
      "pack": "vlt-a0c4e1f8:pck-11223344",
      "license": "vlt-a0c4e1f8:lic-55667788",
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
      "id": "vlt-a0c4e1f8:pck-11223344",
      "title": "Kenney UI Pack",
      "vendor": "Kenney",
      "sourceUrl": "https://kenney.nl/assets/ui-pack",
      "license": "vlt-a0c4e1f8:lic-55667788"
    }
  ],
  "licenses": [
    {
      "id": "vlt-a0c4e1f8:lic-55667788",
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
  , maVault :: VaultId, maPack :: Maybe Ref, maLicense :: Maybe Ref, maMeta :: Value
  -- ^ maPack / maLicense:2026-08-23 階段一閘門裁決 ASM-2,從 Maybe Id 改為 Maybe Ref
  }
  deriving stock (Eq, Show)

data ManifestPack = ManifestPack
  { mpId :: Ref, mpTitle :: Text, mpVendor :: Maybe Text, mpSourceUrl :: Maybe Text
  , mpLicense :: Maybe Ref
  -- ^ mpId / mpLicense:2026-08-23 二輪裁決,從 Id / Maybe Id 改為 Ref / Maybe Ref
  }
  deriving stock (Eq, Show)

data ManifestLicense = ManifestLicense
  { mlId :: Ref  -- 2026-08-23 二輪裁決,從 Id 改為 Ref
  , mlTitle :: Text, mlCommercial :: Bool, mlAttributionRequired :: Bool
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

- [x] STEP-1: `Manifest.hs`(新):`AssetKey`、`Manifest`/`ManifestAsset`/`ManifestPack`/`ManifestLicense`、
  `StoryManifest`/`StoryManifestEntry`、`ImageMeta`/`AudioMeta`、兩個 `currentSchemaVersion` 常數、
  `manifestIndex`、`imageMeta`、`audioMeta`  `dep: F001, F002`
- [x] STEP-2: `Json.hs`(F001 基礎上擴充):上述全部型別的 `ToJSON`/`FromJSON`,`Manifest`/
  `StoryManifest` 的 `FromJSON` 各自先檢查 `schemaVersion` 再解析其餘欄位  `dep: T1`
- [x] STEP-3: `aapms-core.cabal`:`exposed-modules` 加入 `Aapms.Core.Manifest`  `dep: T1`
- [x] STEP-4: 新增 golden fixtures `core/test/golden/manifest.golden.json` +
  `core/test/golden/story-manifest.golden.json`(手寫,對應本文件「JSON 形狀規格」的範例)
  `dep: T1`
- [x] STEP-5: `core/test/Aapms/Core/ManifestSpec.hs`:golden roundtrip(兩份檔案各自 decode → encode →
  語意相同 JSON;decode 後的型別值可再 encode/decode 相等)  `dep: T2, T4`
- [x] STEP-6: `ManifestSpec.hs`:`schemaVersion` 錯誤路徑(`Manifest` 與 `StoryManifest` 各自對
  `schemaVersion = 1` 與 `= 3` 回 `Left`,錯誤訊息含「請重新產生」)  `dep: T2`
- [x] STEP-7: `ManifestSpec.hs`:`manifestIndex` 正確性(以 `AssetKey` 建表、查得到已知 key、查不到
  不存在 key)  `dep: T1`
- [x] STEP-8: `ManifestSpec.hs`:`imageMeta`/`audioMeta` 型別化讀取(相符 kind 的 `Value` 回 `Just` 且
  欄位正確;不相符/欄位缺漏回 `Nothing` 或以預設值解析,對照 `ImageMeta`/`AudioMeta` 各自的
  `FromJSON`)  `dep: T1, T2`
- [x] STEP-9: `core/test/Spec.hs` 的 `describe` 清單加入 `ManifestSpec`  `dep: T5, T6, T7, T8`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| STEP-1 | test_manifest_types_construct | 全部新型別可建構、欄位可存取;`AssetKey` 可比較與排序(`Ord`) |
| STEP-2 | test_json_field_names | `toJSON` 一筆 `ManifestAsset` 恰好得到 `id`/`key`/`path`/`type`/`sha256`/`vault`/`pack`/`license`/`meta` 九個鍵;`toJSON` 一筆 `StoryManifestEntry` 恰好得到 `ref`/`title`/`summary`/`purpose`/`revision` 五個鍵 |
| STEP-3 | test_cabal_exposes_manifest | `aapms-core.cabal` 的 `exposed-modules` 含 `Aapms.Core.Manifest` |
| STEP-4 | test_golden_files_valid_json | 兩份 golden 檔可被 `eitherDecodeStrict` 解成合法 `Value`,且 `schemaVersion` 鍵存在且為 `2` |
| STEP-5 | test_golden_roundtrip | `manifest.golden.json` decode 成 `Manifest`、encode 回去與原始檔案語意相同(鍵序無關);`story-manifest.golden.json` 對 `StoryManifest` 同樣成立 |
| STEP-6 | test_schema_version_rejected | `Manifest`/`StoryManifest` 對 `schemaVersion = 1` 與 `= 3` 的 `FromJSON` 皆回 `Left`,訊息字串含 `"請重新產生"` |
| STEP-7 | test_manifest_index | 3 筆 fixture asset 建出的 `manifestIndex`,對已知 `AssetKey` 回 `Just`、對不存在的 `AssetKey` 回 `Nothing` |
| STEP-8 | test_image_audio_meta | 合法 image `Value` → `imageMeta` 回 `Just` 且四欄正確;合法 audio `Value` → `audioMeta` 回 `Just`;image `Value` 餵給 `audioMeta` 回 `Nothing`;`imColorCount` 缺漏時 `imageMeta` 仍解析成功(`Nothing`) |
| STEP-9 | test_spec_registration | `core/test/Spec.hs` 的 `describe` 清單引用 `ManifestSpec` |

## 已裁決假設(2026-08-23 階段一閘門)

原「待確認假設」ASM-1–ASM-4 已由開發者裁決,結果如下:

- ASM-1(`imageMeta` / `audioMeta` 簽名歸屬):**接受,維持現狀**。`Value -> Maybe ImageMeta` /
  `Value -> Maybe AudioMeta` 留在 `aapms-core`(定義處在 `Manifest.hs`,型別類別掛勾在
  `Json.hs`),同時適用於 `ManifestAsset.meta` 與 F001 的 `Asset.astKindMeta` 兩處。不搬移歸屬。
- ASM-2(`ManifestAsset.pack` / `maLicense` 的型別):**要改**。原判斷(`Maybe Id`,同 vault 內短
  id)推翻,改為 **`Maybe Ref`**,JSON 編碼 `"<vault>:<id>"`(例:
  `"pack": "vlt-a0c4e1f8:pck-11223344"`)。理由:短 id 只在單一 vault 內唯一,專案的素材未來
  可能來自兩個 vault;現在多寫十幾個字元,換掉「開第二個 vault 時既有專案全部要重產」的風險。
  **一輪裁決**(2026-08-23)最初只改 `ManifestAsset.maPack` / `maLicense` 這兩個「指過去」的欄位,
  `Manifest` 頂層 `packs` / `licenses` 清單裡 `ManifestPack.mpId` / `ManifestLicense.mlId` 維持
  `Id`。**二輪裁決**(同日,補正一輪的不完整之處)發現這樣「引用」與「被引用」兩端形狀不對稱:
  要把 asset 的 `pack` 對到頂層清單項目得先剝掉 vault 前綴,剝掉後又回到短 id 跨 vault 撞名的
  原始問題——ASM-2 想擋的事情沒真正擋成。於是把 `ManifestPack.mpId`、`ManifestLicense.mlId`、
  `ManifestPack.mpLicense`(它指向頂層 licenses 清單,同樣是內部引用)**一併改成 `Ref`**,
  manifest 內部的整張引用圖(asset → pack、asset → license、pack → license)vault 化到底,
  兩端用 `Ref` 相等比對即可唯一對應,不必剝前綴。
  已改動:`core/src/Aapms/Core/Manifest.hs`(型別)、`core/test/golden/manifest.golden.json`
  (fixture)、`core/test/Aapms/Core/ManifestSpec.hs`(測試),`Json.hs` 的 `ToJSON`/`FromJSON`
  無需改動(`Maybe Ref` / `Ref` 已透過既有的 `instance ToJSON/FromJSON Ref`——即
  `renderRef`/`parseRef`——自動編解碼,不必另寫實例)。
- ASM-3(`Manifest` 頂層 `packs` / `licenses` 去重清單):**接受,維持現狀**。理由:專案要能離開
  vault 獨立存在,S6 授權閘門要在專案資料夾內就判斷得出能不能商用,不回頭讀 vault。
- ASM-4(`StoryManifest` 獨立 `schemaVersion`):**接受,維持現狀**。理由與原判斷相同,為未來
  `story/manifest.json` 若要 schema 3 預留同一套拒絕機制。

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
  和驗收標準 STEP-2「恰好九個鍵」一致,屬型別內部 JSON 形狀的自主決定,不影響契約簽名。
- golden 檔案讀取沿用 `CabalSpec.hs` 的雙路徑探測寫法(`core/test/golden/...` 與
  `test/golden/...`),因為測試可能從專案根目錄或 `core/` 底下執行。

### 2026-08-23 重工(一輪):ASM-2 裁決「要改」的落地(`ManifestAsset.pack` / `license` 改 `Maybe Ref`)

- `Manifest.hs`:`ManifestAsset.maPack` / `maLicense` 型別從 `Maybe Id` 改為 `Maybe Ref`;
  `ManifestPack` / `ManifestLicense` 當時不動(它們自己的 `id` 視為本 manifest 內定義,
  `mpLicense` 也維持 `Maybe Id`)——這個範圍判斷在二輪重工中被推翻,見下方。
- `Json.hs`:**無需改動**。`ManifestAsset` 的 `ToJSON`/`FromJSON` 本來就用泛用的 `.=`/`.:`,
  型別從 `Maybe Id` 換成 `Maybe Ref` 後,aeson 自動改用既有的 `instance ToJSON Ref`
  (`String . renderRef`)/ `instance FromJSON Ref`(`withText "Ref" (orFail . parseRef)`),
  兩者早已存在於 `Json.hs`,不必新寫實例。
- golden fixture:`manifest.golden.json` 的 `"pack": "pck-11223344"` → `"pack":
  "vlt-a0c4e1f8:pck-11223344"`,`"license"` 同理;`"pack": null` 的第二筆維持 `null`。
- **裸 id(不帶 vault 前綴)的 `FromJSON` 行為**:讀 `Aapms.Core.Id.parseRef` 實際簽名
  (`core/src/Aapms/Core/Id.hs:170-179`)後確認它**不會拒絕**裸 id——單段輸入(無 `:`)被解析
  為 `Ref { refVault = Nothing, refId = <id> }`,語意是「本 vault 內的參照」,這是刻意設計
  (`localRef`)而非缺陷。因此新增的測試(`ManifestSpec.hs`「ManifestAsset pack / license 為
  Ref」describe 區塊)驗證的是**正確處理**而非拒絕:裸 id `"pck-11223344"` 解碼後得到
  `Just (Ref Nothing (idOf "pck-11223344"))`。這與契約卡「短 id 只在單一 vault 內唯一」的前提
  一致——省略 vault 段落時,`ManifestAsset.vault` 欄位已標明的來源 vault 仍是唯一可能的語境。

### 2026-08-23 重工(二輪):manifest 內部引用圖整個 vault 化

一輪的範圍判斷不完整:只讓「引用」的一端(`ManifestAsset.maPack`/`maLicense`)vault 化,
「被引用」的一端(頂層 `packs`/`licenses` 清單裡的 `id`)仍是裸短 id。後果是要比對兩端得先
剝掉 asset 端的 vault 前綴,剝掉後又回到短 id 只在單一 vault 內唯一的原始問題——兩個 vault
各有一筆 `pck-11223344` 時,頂層 `packs` 會出現兩筆撞名的 `"id": "pck-11223344"`,無法區分,
ASM-2「換掉跨 vault 撞名風險」的目的沒有真正達成。

- `Manifest.hs`:`ManifestPack.mpId` 從 `Id` 改為 `Ref`;`ManifestLicense.mlId` 從 `Id` 改為
  `Ref`;`ManifestPack.mpLicense` 從 `Maybe Id` 改為 `Maybe Ref`(它指向頂層 `licenses` 清單,
  跟 `maPack`/`maLicense` 是同一種「manifest 內部引用」,理當同規則)。`ManifestAsset.maId`
  維持 `Id` 不變——那是本筆自己的身分,不是引用。
- `Json.hs`:同樣**無需改動**,原因同一輪:`ManifestPack`/`ManifestLicense` 的 `ToJSON`/
  `FromJSON` 已經是泛用的 `.=`/`.:`,型別換成 `Ref`/`Maybe Ref` 後自動吃到既有的 `Ref` 實例。
- golden fixture:`manifest.golden.json` 的 `packs[0].id`、`licenses[0].id`、`packs[0].license`
  三處補上 `vlt-a0c4e1f8:` 前綴。
- `ManifestSpec.hs`:`samplePack`/`sampleLicense` 改用 `refOf`;新增
  `describe "manifest 內部引用圖 vault 化(二輪裁決補述……)"` 兩條測試——① asset 的 `maPack`
  能以 `Ref` 整體相等(不剝前綴)唯一對應到 `mPacks` 裡的某一筆;② 建兩筆 `mpId` 短 id 相同但
  vault 不同的 `ManifestPack`(`vlt-aaaaaaaa:pck-11223344` 與 `vlt-bbbbbbbb:pck-11223344`),
  驗證兩者 `Ref` 不相等、各自能用完整 `Ref` 唯一查到,證明「manifest 內部引用圖 vault 化」後
  跨 vault 同號不再撞名。
- 範圍**沒有**擴大到 `ManifestAsset.maId`、`ManifestPack.mpTitle` 等本筆自身定義的欄位——只有
  「A 指向 B」這種內部引用關係的欄位才 vault 化。
