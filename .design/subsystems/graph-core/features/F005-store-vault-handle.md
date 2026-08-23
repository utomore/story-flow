---
id: F005
type: feature
title: store-vault-handle
description: "aapms-store 的 vault marker 讀寫、initVaultAt / openVault / closeVault、schema 骨架"
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: [F001]
related-adr: [ADR-013, ADR-017, ADR-022]
related-feature: []
---

# F005: vault marker、原子寫入、schema 骨架(store-vault-handle)

## 功能概述

實作 graph-core 讀取管線的第一段:「`openVault`:讀 marker → 開索引 → schema 判斷」。本 feature
落地契約 E 的 `VaultKind` / `VaultMarker` / `VaultHandle` / `readMarker` / `initVaultAt` /
`openVault` / `closeVault`,以及契約 G `StoreError` 的骨架(只含本 feature 自己用得到的建構子,
其餘建構子由後續 feature 各自新增)。負責模組是 design.md「內部模組劃分」的 Marker、Atomic、
Schema 三個(`aapms-store`)。

**驗收標準**(逐字抄自契約卡):

1. `initVaultAt` 寫出 `.aapms/config.toml`(含新發的 `vlt-` id 與 kind)與空索引
2. 對已有 marker 的目錄再 `initVaultAt` 是錯誤
3. `openVault` 對 marker 損壞回指出欄位的錯誤,不自動建檔
4. `schema_version` 不符時整庫重建並在 `IndexIssue` 回報
5. 原子寫入在 Windows 上能覆蓋既有檔案
6. 沒有任何程式路徑讀 `%APPDATA%` 或向上探測——那是 `workspace`

**明確不做**(逐字抄自契約卡):不探測 vault、不讀中樞註冊表、不處理 `--vault`;不做 `migrate`
(`workspace`);不建任何業務表(#6,`store-unified-index`)。

## 相依性

`depends-on: [F001]`——與 `design.md`「功能規劃」表 #5 列(`store-vault-handle`,依賴 `#1`)一致,
反推自下方「使用到的既有串接介面」表:全部列都指向 `core/src/Aapms/Core/Id.hs`(F001 的 Id 模組),
沒有任何一列指向 F002(`aapms-types`/registry)或 F003(`Manifest`)。

不依賴 `md-unified-sections`(#4):讀取管線裡 `openVault` 只到「schema 判斷」為止,不涉及
`parseDocument`/`toTopic` 等 `aapms-md` 的功能;`design.md`「功能規劃」表也把 #4 與 #5 並列
(都只依賴 `#1`/`#1, #2`),隱含可平行開發。**但這個「可平行」目前只在 Level 2 契約層成立,
建置層不成立**——見下方「相依性查證」的「風險與建置阻塞」一節:`aapms-store.cabal` 的 library
對 `aapms-md` 有 `build-depends`,`aapms-md` 現在編不過會連帶讓 `aapms-store` 整個 library
元件無法編譯,無關本 feature 有沒有改對。本 feature的 TodoList 把「移除這條非必要的
`build-depends`」列為必要步驟(T1),移除後 F005 才能真正獨立於 F004 完成驗證。

`store-unified-index`(#6)、`store-fts-dual-index`(#7)、`store-write-operations`(#8)、
`store-multi-vault-read`(#9)四個 feature 依賴本 feature(它們都要用 `VaultHandle`/`openVault`),
但本 feature 不依賴它們。

## 對應的 Level 2 契約

### 契約 E(部分,依契約卡指定)

**2026-08-23 補述(D9,編排者已在 commit `5de2727` 改好 `design.md` 契約 E,以下同步):**
`VaultHandle` 多帶一個型別註冊表欄位,`openVault` 改成先收 `TypeRegistry`。理由:F006 設計時
發現 `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` 在索引管線(含 `openVault` 自己的
過時刷新)處處要用到註冊表,「各索引函式加參數」補不到 `openVault` 這條路徑,故改為「由
`openVault` 收下、存進 `VaultHandle`」,把「先載入註冊表、再開 vault」的順序用型別釘死。

```haskell
data VaultKind   = AssetVault | StoryVault
data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }
data VaultHandle                                              -- 含 marker、根目錄、索引連線、型別註冊表

readMarker  :: FilePath -> IO (Either StoreError VaultMarker)
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
openVault   :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))
closeVault  :: VaultHandle -> IO ()
```

### 契約 G(部分,只含本 feature 用得到的建構子)

`StoreError` 的骨架;`renderStoreError`;`trySqlite`(本套件與 SQLite 之間的唯一邊界,既有簽名
不變)。

**不做**:契約 E 其餘函式(`rebuildIndex`/`refreshStale`/`indexFile`/`unindexFile`/查詢函式群屬
#6/#7;`create*`/`write*`/`addLink`/`deleteNode`/`allocateId` 屬 #8;`VaultSet`/`*Across`/
`checkReferences` 屬 #9)。`IndexIssue` 的完整形狀屬 #6,本 feature 只定義 `schema_version`
重建那一種建構子(D3,見「待確認假設」A5)。

### 明確不做(契約卡逐字)

不探測 vault、不讀中樞註冊表、不處理 `--vault`;不做 `migrate`(`workspace`);不建任何業務表(#6)。

## 實作方式

### 相依性查證:`aapms-store` 現況(2026-08-23 打開 `store/src/` 讀到的實況)

`store/src/` 目前 12 個模組,全部是合併前 `entity-graph-core` 的舊碼(未改接 F001 的統一
`Meta`)。本 feature 只碰其中三個(`Vault.hs`→改名 `Marker.hs`、`Atomic.hs`、`Schema.hs`)與
`Error.hs`;其餘七個(`Create.hs`/`Edit.hs`/`Index.hs`/`Node.hs`/`Query.hs`/`Row.hs`/`Write.hs`)
屬 #6/#8 範圍,**經查證全部已編不過**,證據:

- `store/src/Aapms/Store/Query.hs:35` `import Aapms.Core.Graph (LinkGraph)`——`core/src/Aapms/Core/`
  目前**沒有 `Graph.hs`**(F001 已刪除該模組,見 `core/src/Aapms/Core/Link.hs:166-172` 的
  待確認假設 A2:四個純函式與其測試一併刪除,只留 `LinkGraph` 型別別名於 `Link.hs`)
- `store/src/Aapms/Store/Write.hs:34` `import Aapms.Core.Id (Id, IdPrefix, Ref, mkId, renderId)`——
  `core/src/Aapms/Core/Id.hs:6-33` 的匯出清單沒有 `mkId`,F001 定的名字是 `newId`
  (`core/src/Aapms/Core/Id.hs:103-109`)
- `store/test/Aapms/Store/Fixtures.hs:50-54` `import Aapms.Core.Registry (EntityTypeSpec (..),
  TypeRegistry, validateRegistry)`——`core/src/Aapms/Core/Registry.hs:18-35` 的匯出清單沒有
  `EntityTypeSpec`/`validateRegistry`(F002 重建的 `Registry` 換了一整組 API:`Family`/
  `TypeDecl`/`buildRegistry`/`lookupType`/`checkMeta`……)

`Create.hs`/`Index.hs`/`Node.hs`/`Edit.hs` 都直接或間接 import 上述任一個壞掉的符號,`Row.hs`
import `Aapms.Core.Meta` 但建構的是舊欄位順序的 `Meta`(未逐一比對,不影響本 feature 判斷)。
**這證實委派決策記錄寫的「store 自己有多少要改目前是未知數」——查證結果是:除了本 feature 承接
的四個模組,其餘七個模組與其對應的九份舊 Spec(`CreateSpec`/`DeleteSpec`/`EndToEndSpec`/
`IndexSpec`/`NodeSpec`/`QuerySpec`/`RebuildSpec`/`SearchSpec`/`StaleSpec`/`WriteSpec`)全部屬於
#6/#8 的重寫範圍,本 feature 不修但必須先讓它們「不擋路」,見下一節。**

### 風險與建置阻塞:兩層問題,本 feature 只能解決其中一層

1. **套件層阻塞(本 feature 可以解決)**:`store/aapms-store.cabal` 的 library
   `build-depends` 列了 `aapms-md`,但本 feature 保留的四個模組(`Marker`/`Atomic`/`Schema`/
   `Error`)**沒有任何一個 import `Aapms.Md.*`**(舊 `Error.hs:24` import 的
   `Aapms.Md.Error (MdError, renderMdError)` 隨 `ParseFailed` 建構子一起被拿掉,見下方
   `StoreError` 骨架)。只要同時①把七個壞掉的模組移出 `exposed-modules`/`other-modules`
   (見 T1),②把 `aapms-md` 移出 `build-depends`,`aapms-store` 這個 library 元件就不再
   相依 `aapms-md`,`cabal test aapms-store` 可以獨立於 `aapms-md` 是否編得過而綠燈。
   **這是本 feature 的 TodoList 第一項(T1)**,理由與影響見下方「新增的介面」前的說明與
   「待確認假設」A1。
2. **套件層阻塞(本 feature 無法解決,只能記錄)**:即使①②做完,`cabal build all` /
   `cabal test all` 仍會嘗試建置 `aapms-md`(它在 `cabal.project` 的 `packages:` 清單裡)
   並在那裡失敗——`md/src/Aapms/Md/Inherit.hs:40-41` 的 `MetaOverride` 欄位
   `moType :: Maybe Text` / `moVault :: Maybe Text`,與 `md/src/Aapms/Md/Inherit.hs:101-102`
   的 `overrideOf`(`moType = Just metaType, moVault = Just metaVault`)不符——`metaType`
   的型別是 `TypeKey`、`metaVault` 的型別是 `VaultId`(`core/src/Aapms/Core/Meta.hs:126-127`),
   都不是 `Text`,`Just metaType` 编不出 `Maybe Text`。**這是 `md-unified-sections`(#4)的
   範圍,本 feature 不修**。實務影響:驗證本 feature 時要跑**限定套件的**
   `cabal test aapms-store`,不能跑 `cabal build all`/`cabal test all`(後者會先在
   `aapms-md` 報錯,与 F005 本身的正確與否無關,也是使用者記憶裡「check.ps1 的 stderr
   陷阱」同一類「跑錯範圍導致假失敗」的情境)。

### 模組配置

| 檔案 | 內容 | 對照舊檔 |
|---|---|---|
| `store/src/Aapms/Store/Marker.hs`(新,取代 `Vault.hs`) | `VaultMarker`、`VaultHandle`、`readMarker`、`initVaultAt`、`openVault`、`closeVault`、路徑輔助 `markerDir`/`configPath`/`indexDbPath` | `Vault.hs`(313 行)整份改寫;移除 `resolveVault`/`resolveVaultWith`/`searchUp`/`loadVaultAt`(舊名)/全域註冊表三個函式/`LlmSection`/`vaultSubdirs`/`.gitignore` 追加邏輯——這些是探測、中樞註冊、LLM 設定,依契約卡「明確不做」與委派決策記錄全部刪除,不搬到別的套件(`workspace` 在 P3 重寫) |
| `store/src/Aapms/Store/Atomic.hs` | 不變 | 已是路徑無關的通用函式(`atomicWriteText`/`readTextFile`),沒有 import `Vault` 模組,不因 marker 目錄改名而需要改動;預期本 feature 對它是唯讀查證,不修改內容 |
| `store/src/Aapms/Store/Schema.hs` | `VaultKind`(`AssetVault`/`StoryVault`)、`renderVaultKind`/`parseVaultKind`、`IndexIssue`/`renderIndexIssue`、`openIndexAt`(內含 PRAGMA 設定、`schema_version` 判斷、`setVaultInfo`)、`closeIndex`、`createSchema`/`resetSchema`/`currentVersion`/`indexTables` | 舊檔(275 行)的業務表 DDL(`entities`/`entity_aliases`/`entity_tags`/`links`/`levels`/`nodes`/`node_entities`/`entities_fts`/`fts_map`,舊 `indexTables`/`schemaDDL`)全部刪除——契約卡「不建任何業務表(#6)」,`indexTables` 縮成只有 `meta_info` 一項,#6 接手時擴充(不是新建一份) |
| `store/src/Aapms/Store/Error.hs` | `StoreError` 骨架六個建構子、`renderStoreError`、`trySqlite`(簽名不變) | 舊檔 18 個建構子留 6 個(見下方「新增的介面」);拿掉對 `Aapms.Core.Link`/`Aapms.Md.Error` 的 import——本 feature 不再需要它們 |

### `.aapms/config.toml` 的格式與解析錯誤訊息

沿用 `system.md`「Vault 檔案」一節與 ADR-017 的格式:

```toml
id   = "vlt-7f3b2a91"
kind = "asset"            # asset | story
name = "alchbees-assets"
refs = []
```

`readMarker` 逐欄解析,任何一欄不合法都回 `VaultMarkerInvalid <路徑> <指出哪個欄位的訊息>`,
訊息風格對照舊 `Vault.hs:parseConfig`(如「缺少必填鍵 \`name\`」):

| 情況 | 訊息 |
|---|---|
| TOML 語法錯誤 | `TOML.renderTOMLError` 原文 |
| 最上層不是表 | `檔案的最上層不是 TOML 表` |
| 缺 `id` | `缺少必填鍵 id` |
| `id` 不是字串 | ``鍵 `id` 必須是字串`` |
| `id` 解析失敗或前綴不是 `vlt` | ``鍵 `id` 不是合法的 vlt- id:<原始字串>`` |
| 缺 `kind` | `缺少必填鍵 kind` |
| `kind` 不是 `asset`/`story` | ``鍵 `kind` 必須是 asset 或 story,收到 <原始字串>`` |
| 缺 `name` | `缺少必填鍵 name` |
| `name` 不是字串 | ``鍵 `name` 必須是字串`` |
| `refs` 不是字串陣列,或陣列裡有不合法的 `vlt-` id | ``鍵 `refs` 必須是字串陣列`` / ``鍵 `refs` 內有不是合法 vlt- id 的項目:<原始字串>`` |

`initVaultAt` 寫出的 marker 固定四行、欄位順序固定(`id`/`kind`/`name`/`refs`),字串以既有
`quote`(逃逸 `"`/`\`)包住,`refs` 一律新 vault 是 `[]`(契約卡沒有要求 `initVaultAt` 支援
一開始就帶 `refs`,`refs` 的填寫屬 `workspace` 的 `vault add`/`vault link` 之類的操作)。

### `openVault` 的資料流(讀取管線「openVault」段落的完整落地)

```text
FilePath(root,由呼叫端/workspace 給,本 feature 不探測)
  → readMarker root                                    -- 讀 marker
    → 失敗(不存在/損壞)→ Left StoreError,不建檔
  → Schema.openIndexAt (indexDbPath root) (vmId marker) (vmKind marker) (vmName marker)
    → open SQLite 連線(自動建立空檔案是 SQLite 內建行為,不是本模組主動「建檔」)
    → PRAGMA foreign_keys = ON / journal_mode = WAL / busy_timeout = 5000(ADR-022)
    → currentVersion 讀 meta_info.schema_version
      → 相符 → 不動
      → 不符(含 meta_info 表不存在,全新索引檔)→ resetSchema(目前只有 meta_info 一張表)
        → issues = [SchemaRebuilt 舊版本 新版本]
    → setVaultInfo 寫入 vault_id / vault_kind / vault_name(以 marker 的內容為準)
    → 成功 → Right (conn, issues)
  → 組出 VaultHandle { vhMarker = marker, vhRoot = root, vhConn = conn }
  → Right (handle, issues)
```

`initVaultAt` 共用同一個 `Schema.openIndexAt`(不是另外寫一套建索引邏輯):先確認目錄沒有既有
marker → 建 `.aapms/` 目錄 → 以 `newId PVlt name now 0` 發新 `VaultId` → 寫 marker →
`openIndexAt` 建空索引(忽略回傳的 `issues`,一定是全新索引所以一定會有一筆
`SchemaRebuilt Nothing schemaVersion`,對 `initVaultAt` 而言這不是「問題」,是預期行為)→
立刻 `closeIndex` → 回傳 marker。

**不建子目錄、不寫 `.gitignore`**:舊 `initVault` 會建 `characters`/`lore`/`items`/`dialogues`/
`levels` 五個子目錄與兩層 `.gitignore`。驗收標準只要求「`.aapms/config.toml`……與空索引」,且
`asset` vault 的目錄結構(`library/`)與 `story` vault(`characters/`……)完全不同,`initVaultAt`
不該替兩種 `kind` 各自的目錄結構下判斷——那是 `workspace` 的 `vault init` 指令組裝
`initVaultAt` 之後才做的事。此為委派決策記錄沒有明說、由本 feature 依契約卡文字直接反推的
實作決定,見待確認假設 A4。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data IdPrefix = PEnt \| PAst \| PPck \| PLic \| PLvl \| PNod \| PVlt \| PPrj` | `core/src/Aapms/Core/Id.hs:46-55` | F001 | 判斷/建構 `vlt-` 前綴(`PVlt`) |
| `renderIdPrefix :: IdPrefix -> Text` | `core/src/Aapms/Core/Id.hs:57-66` | F001 | 錯誤訊息裡顯示「收到的前綴不是 vlt-」 |
| `data Id`(不透明,只能經 `newId`/`parseId` 取得) | `core/src/Aapms/Core/Id.hs:86-97` | F001 | marker 的 `id` 欄位底層型別 |
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103-109` | F001 | `initVaultAt` 發新 `vlt-` id(`newId PVlt name now 0`) |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/Aapms/Core/Id.hs:127-135` | F001 | `readMarker` 解析 `id`/`refs` 欄位,順便驗證前綴 |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123-124` | F001 | 把 `newId`/`parseId` 得到的 `Id` 轉回文字,組成 `VaultId` |
| `newtype VaultId = VaultId Text`(建構子匯出) | `core/src/Aapms/Core/Id.hs:148-150` | F001 | `VaultMarker.vmId`/`vmRefs` 的型別;直接 `VaultId (renderId i)` 建構,不需要另外的轉換函式 |
| `data IdError = BadIdFormat Text \| UnknownIdPrefix Text \| BadRefFormat Text` | `core/src/Aapms/Core/Id.hs:90-97` | F001 | `parseId` 失敗時的錯誤內容,轉譯成 `VaultMarkerInvalid` 的訊息文字(不直接外露 `IdError`) |
| `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` | `store/src/Aapms/Store/Atomic.hs:44-72` | - | `initVaultAt` 寫 `.aapms/config.toml`,不修改此函式 |
| `readTextFile :: FilePath -> IO (Either StoreError Text)` | `store/src/Aapms/Store/Atomic.hs:35-42` | - | `readMarker` 讀 `.aapms/config.toml` 的 UTF-8 內容(取代舊 `Vault.hs:155-162` 自己重複實作的 `readUtf8`,兩份邏輯完全相同,改用既有的) |
| `Database.SQLite.Simple`(`open`/`execute_`/`query_`/`Connection`……) | `sqlite-simple` 套件(既有 `build-depends`) | - | `Schema.openIndexAt`/`closeIndex` 的連線開關與 PRAGMA |
| `TOML.decode` / `TOML.Table` / `TOML.String` / `TOML.Array` / `TOML.renderTOMLError` | `toml-reader` 套件(既有 `build-depends`) | - | `readMarker`/`renderMarker` 的 TOML 解析與渲染,API 與舊 `Vault.hs:164-183` 使用的完全相同 |

`store/src/Aapms/Store/{Vault,Schema,Error}.hs` 三份舊檔**不算「使用到的既有介面」**——它們是
本 feature 要整份改寫取代的對象,不是被呼叫的依賴,已在「相依性查證」一節列出對照。

## 新增的介面

```haskell
-- Aapms.Store.Schema

data VaultKind = AssetVault | StoryVault
  deriving stock (Show, Eq)

renderVaultKind :: VaultKind -> Text          -- AssetVault -> "asset", StoryVault -> "story"
parseVaultKind  :: Text -> Maybe VaultKind    -- 只認 "asset"/"story",其餘 Nothing

schemaVersion :: Int
schemaVersion = 1              -- 本 feature 起算的新 schema(只有 meta_info),與舊值 1 語意不同

-- | 目前只有一種:schema_version 不符觸發整庫重建(#6 依 IndexIssue 的完整形狀擴充建構子,
-- 不得整個換掉重定義——見待確認假設 A5)。
data IndexIssue = SchemaRebuilt
  { irOldVersion :: Maybe Int  -- meta_info 讀到的舊值;Nothing = 全新索引檔(表都還不存在)
  , irNewVersion :: Int
  }
  deriving stock (Show, Eq)

renderIndexIssue :: IndexIssue -> Text

-- | 開連線 + PRAGMA + schema_version 判斷(不符即重建)+ 寫入 vault 身分,全部在一個
-- trySqlite 區塊內完成,任何一步的 SQLite 例外都收斂成 Left (SqliteError _)。
openIndexAt
  :: FilePath                                   -- .aapms/index.db 的路徑
  -> VaultId -> VaultKind -> Text                -- marker 的 id / kind / name,寫進 meta_info
  -> IO (Either StoreError (Connection, [IndexIssue]))

closeIndex :: Connection -> IO ()

createSchema   :: Connection -> IO ()   -- 目前只建 meta_info 一張表
resetSchema    :: Connection -> IO ()   -- DROP IF EXISTS 全部 indexTables 後 createSchema
currentVersion :: Connection -> IO (Maybe Int)
indexTables    :: [Text]                -- ["meta_info"];#6 加業務表時擴充這份清單,不是另開一份

setVaultInfo :: Connection -> Text -> Text -> Text -> IO ()   -- vault_id, vault_kind, vault_name


-- Aapms.Store.Marker

data VaultMarker = VaultMarker
  { vmId   :: VaultId
  , vmKind :: VaultKind
  , vmName :: Text
  , vmRefs :: [VaultId]
  }
  deriving stock (Show, Eq)

-- | 含 marker、根目錄、已開的索引連線、型別註冊表(D9)。欄位全部匯出:#6 起的查詢/寫入
-- 函式都要能直接拿 vhConn 操作索引、拿 vhRoot 組出檔案的絕對路徑、拿 vhRegistry 跑 checkMeta。
data VaultHandle = VaultHandle
  { vhMarker   :: VaultMarker
  , vhRoot     :: FilePath
  , vhConn     :: Connection
  , vhRegistry :: TypeRegistry
  }

readMarker  :: FilePath -> IO (Either StoreError VaultMarker)
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
-- | D9:TypeRegistry 由呼叫端先載入好再給,openVault 只是收下存進 VaultHandle,不在這裡載入。
openVault   :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))
closeVault  :: VaultHandle -> IO ()

markerDir   :: FilePath -> FilePath   -- root </> ".aapms"
configPath  :: FilePath -> FilePath   -- markerDir root </> "config.toml"
indexDbPath :: FilePath -> FilePath   -- markerDir root </> "index.db"


-- Aapms.Store.Error

data StoreError
  = VaultMarkerMissing FilePath          -- 該路徑沒有 .aapms/config.toml(openVault 不自動建檔)
  | VaultMarkerInvalid FilePath Text     -- Text 指出是哪個欄位、為什麼不合法
  | VaultAlreadyInitialized FilePath     -- initVaultAt 對已有 marker 的目錄再次呼叫
  | FileReadFailed FilePath Text
  | FileWriteFailed FilePath Text
  | SqliteError Text
  deriving stock (Show, Eq)

renderStoreError :: StoreError -> Text
trySqlite :: IO a -> IO (Either StoreError a)   -- 簽名不變,沿用舊實作


-- Aapms.Store(門面模組,重新導出)

module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Error
  , module Aapms.Store.Marker
  , module Aapms.Store.Schema
  ) where
```

`StoreError` 之後每個新 feature(#6 起)會各自往這個型別**加**建構子(如 `IndexUpdateFailed`/
`StaleRevision`/`TooManyVaults`),不是重新定義——這是「契約 G 的骨架」这句話的字面意思。本
feature 移除的 12 個舊建構子(`VaultNotFound`/`VaultConfigInvalid`/`VaultAlreadyExists`/
`EntityNotFound`/`StaleRevision`/`IdCollision`/`IndexUpdateFailed`/`ParseFailed`/
`ReferencedBy`/`NotAFileMain`/`NotAFragment`/`NodeDepthExceeded`/`CannotRemoveRootNode`/
`LinkNotFound`/`FileAlreadyExists`/`TreeInvalid`/`RegistryDirUnknown`)全部屬於 #6/#8/#9 的
語意(索引更新失敗、樂觀鎖、關聯完整性、Level 樹合法性、跨 vault 上限……),等對應 feature
真正需要時再由那個 feature 加回來,現在留著只是死碼(而且部分已經編不過,如
`RegistryDirUnknown` 相依的 `Aapms.Core.Registry` API 已改)。

## TodoList

- [x] T1: `store/aapms-store.cabal`:library `exposed-modules` 與 test-suite `other-modules`
  移除 `Aapms.Store.Create`/`Edit`/`Index`/`Node`/`Query`/`Row`/`Write` 七個模組與對應的九份
  舊 Spec(`CreateSpec`/`DeleteSpec`/`EndToEndSpec`/`IndexSpec`/`NodeSpec`/`QuerySpec`/
  `RebuildSpec`/`SearchSpec`/`StaleSpec`/`WriteSpec`);library 與 test-suite 的 `build-depends`
  移除 `aapms-md`(本 feature 保留的四個模組都不 import 它)。原始檔**保留在磁碟不刪**,留給
  #6/#8/#9 接手改寫。`dep: -`
- [x] T2: `Aapms.Store.Error` 改寫:`StoreError` 縮成六個建構子、`renderStoreError` 逐條繁中
  可操作訊息、`trySqlite` 不變;移除對 `Aapms.Core.Link`/`Aapms.Md.Error` 的 import
  `dep: -`
- [x] T3: `Aapms.Store.Schema` 改寫:`VaultKind`/`renderVaultKind`/`parseVaultKind`、
  `IndexIssue`/`renderIndexIssue`、`indexTables` 縮成 `["meta_info"]`、`schemaDDL` 只剩
  `meta_info` 一張表、`openIndexAt` 新簽名(內含 PRAGMA foreign_keys/WAL/busy_timeout=5000、
  `currentVersion`/`resetSchema` 判斷、`setVaultInfo` 寫入 vault_id/vault_kind/vault_name)
  `dep: T2`
- [x] T4: 新建 `Aapms.Store.Marker`(取代 `Vault.hs`,檔案更名):`VaultMarker`、`VaultHandle`、
  `markerDir`/`configPath`/`indexDbPath`、`readMarker`(含逐欄錯誤訊息)、`renderMarker`
  (內部用,marker 轉 TOML 文字)、`initVaultAt`、`openVault`、`closeVault`;刪除
  `resolveVault`/`resolveVaultWith`/`searchUp`/全域註冊表三函式/`LlmSection`/`vaultSubdirs`/
  `.gitignore` 追加邏輯 `dep: T3`
- [x] T5: `Aapms.Store.Atomic`:讀碼確認現況(不 import 已刪除的 `Vault` 型別、路徑無關),
  預期免修改;若無不符只更新模組頂部文件註解確認路徑改為 `.aapms/` `dep: -`
- [x] T6: `Aapms.Store` 門面模組:`exposed-modules`/re-export 改成只有 `Atomic`/`Error`/
  `Marker`/`Schema` `dep: T2, T3, T4`
- [x] T7: `store/test/Aapms/Store/Fixtures.hs` 瘦身:只保留 `withTempVault`/`orDie`/`idOf`/
  `refOf`,移除 `withEmptyVault`/`withSampleVault`/`writeVaultFile`/`readVaultFile`/
  `withVaultIndex`/`withSampleIndex`/`countRows`/`scalarInt`/`textsOf`/`testRegistry`/
  `sampleFiles` 與全部範例 Markdown 常數(`lindaMd`……)——這些全部相依已移出 T1 範圍的模組
  或舊 `Vault`/`Registry` API `dep: T1`
- [x] T8: 刪除 `store/test/Aapms/Store/VaultSpec.hs`、`InitSpec.hs`;新建
  `store/test/Aapms/Store/MarkerSpec.hs` 覆蓋 `readMarker`/`initVaultAt`/`openVault`/
  `closeVault` 的驗收標準,含「原始碼不出現 `XdgConfig`/`getXdgDirectory`/`searchUp`/
  `vaults.toml`」的靜態檢查(對照舊 `VaultSpec.hs:129-132` 的「LlmConfig 改名徹底」手法)
  `dep: T4, T7`
- [x] T9: 改寫 `store/test/Aapms/Store/SchemaSpec.hs`:針對新 `meta_info`-only schema、PRAGMA
  設定(foreign_keys/WAL/busy_timeout)、`schema_version` 重建與 `IndexIssue`、vault 身分寫入
  `dep: T3, T7`
- [x] T10: 改寫 `store/test/Aapms/Store/ErrorSpec.hs`:只測本 feature 六個建構子的訊息(繁中、
  非空、可操作、不洩漏原始 `show` 痕跡,沿用舊檔 `showTraces`/`actionable` 的判斷方式)
  `dep: T2`
- [x] T11: `store/test/Spec.hs`:移除已刪除/移出範圍模組的 import 與 `describe`,新增
  `MarkerSpec`;保留 `Aapms.StoreSpec`(骨架測試,不受本次改動影響)與 `AtomicSpec`
  `dep: T8, T9, T10`
- [x] T12: `Aapms.StoreSpec`(骨架測試)新增兩條靜態檢查:①`store/aapms-store.cabal` 原始碼
  不含 `Aapms.Store.Index`/`Write`/`Create`/`Query`/`Node`/`Edit`/`Row` 模組項與 `aapms-md`
  依賴項;②`Aapms.Store` 門面模組可實際 import 並呼叫到 `openVault`/`initVaultAt`(間接證明
  T6 的 re-export 生效) `dep: T6, T1`
- [x] T13(2026-08-23 補做,D9 契約裁決):`Aapms.Store.Marker` 的 `VaultHandle` 加欄位
  `vhRegistry :: TypeRegistry`,`openVault` 簽名改成 `TypeRegistry -> FilePath -> IO (...)`;
  `readMarker`/`initVaultAt`/`closeVault` 不動。`store/aapms-store.cabal` 查證後**不需要新增
  `build-depends`**——`TypeRegistry` 定義在 `Aapms.Core.Registry`(`aapms-core`),library 與
  test-suite 本來就已經相依 `aapms-core`。測試新增 `Aapms.Store.Fixtures.testRegistry`
  (`buildRegistry []` 建出的空註冊表,理由見「實作備註」),`MarkerSpec.hs`/`StoreSpec.hs`
  呼叫 `openVault` 的地方改傳入 `testRegistry` `dep: T4, T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_cabal_excludes_out_of_scope_modules | `store/aapms-store.cabal` 原始碼不含七個移出模組的條目與 `aapms-md`(於 T12 實作) |
| T2 | test_error_messages_actionable | `StoreError` 六個建構子的 `renderStoreError` 皆非空、含中文、含「請/改用/可以/才」之一、不含 `Left`/`Right`/`Just `/建構子名稱等 show 痕跡 |
| T3 | test_meta_info_only_schema | `openIndexAt` 建出的資料庫只有 `meta_info` 一張表(`sqlite_master` 查詢),`schemaVersion` 寫入其中 |
| T3 | test_pragmas_set | `foreign_keys = 1`、`journal_mode = wal`、`busy_timeout = 5000` 三個 PRAGMA 查詢結果符合預期 |
| T3 | test_schema_rebuild_on_mismatch | 手動把 `meta_info.schema_version` 改成 `0` 後重新 `openIndexAt`,回傳的 `[IndexIssue]` 含一筆 `SchemaRebuilt (Just 0) schemaVersion`,且重建後 `currentVersion` 等於 `schemaVersion` |
| T3 | test_fresh_index_reports_rebuild | 對全新（尚無 `meta_info` 表）的 db 檔呼叫 `openIndexAt`,回傳 `[IndexIssue]` 含一筆 `SchemaRebuilt Nothing schemaVersion` |
| T3 | test_vault_identity_stored | `openIndexAt` 完成後 `meta_info` 含 `vault_id`/`vault_kind`/`vault_name` 三筆,值與傳入的 `VaultId`/`VaultKind`/`Text` 一致 |
| T4 | test_init_writes_marker_and_empty_index | `initVaultAt` 後 `.aapms/config.toml` 存在且四欄可被 `readMarker` 讀回(`vmKind`/`vmName` 與呼叫參數相符,`vmId` 前綴為 `vlt`,`vmRefs = []`);`.aapms/index.db` 存在且只有 `meta_info` 表 |
| T4 | test_init_twice_is_error | 對已 `initVaultAt` 過的目錄再呼叫,回 `Left (VaultAlreadyInitialized root)`,原 `config.toml` 內容不變(逐位元組比對) |
| T4 | test_read_marker_missing | 對沒有 `.aapms/config.toml` 的目錄呼叫 `readMarker`(或 `openVault`),回 `Left (VaultMarkerMissing _)`,且該路徑下**沒有**任何檔案被建立(驗收標準「不自動建檔」) |
| T4 | test_read_marker_invalid_fields | 五種欄位錯誤(缺 `id`/`id` 前綴不對/缺 `kind`/`kind` 值不對/缺 `name`)各自回 `Left (VaultMarkerInvalid _ msg)`,`msg` 含被違反的鍵名 |
| T4 | test_open_vault_success | 對合法 marker 呼叫 `openVault`,回 `Right (handle, issues)`,`vhMarker handle` 與 marker 內容相符、`vhRoot handle` 是絕對路徑、`vhConn handle` 可執行查詢;`closeVault` 後連線關閉(重複查詢丟例外或明確失敗) |
| T4 | test_no_probing_in_source | `Marker.hs` 原始碼不含 `XdgConfig`/`getXdgDirectory`/`searchUp`/`vaults.toml`/`AAPMS_HOME` 任一字串(驗收標準 6) |
| T5 | (沿用既有 5 條 `AtomicSpec` 案例,含「覆蓋既有檔案成功(Windows 的關鍵驗證)」)不修改則不新增測試,以既有測試繼續綠燈作為 T5 完成的證據 | 驗收標準 5 |
| T6 | test_facade_reexports | 從 `Aapms.Store`(而非個別子模組)import `openVault`/`initVaultAt`/`VaultKind`/`StoreError` 並成功編譯呼叫(於 T12 實作) |
| T7 | test_fixtures_slimmed | `Fixtures.hs` 原始碼不再含 `withSampleVault`/`lindaMd`/`testRegistry` 等字串(對照舊 `VaultSpec.hs` 的改名徹底檢查手法) |
| T8 | (併入上方 T4 各條,`MarkerSpec.hs` 是這些測試實際所在的檔案) | - |
| T9 | (併入上方 T3 各條,`SchemaSpec.hs` 是這些測試實際所在的檔案) | - |
| T10 | (併入上方 T2,`ErrorSpec.hs` 是測試實際所在的檔案) | - |
| T11 | test_spec_registration | `store/test/Spec.hs` 的 `describe`/import 清單含 `MarkerSpec`,不含已刪除的模組 |
| T12 | test_cabal_excludes_out_of_scope_modules、test_facade_reexports | 見上方 T1、T6 |
| T13 | test_openvault_threads_registry_into_handle | `openVault testRegistry dir` 開出的 `vhRegistry handle` 與傳入的 `testRegistry` 一致(`MarkerSpec.hs`「D9」條);`test_facade_reexports`(T12)與門面模組呼叫 `openVault` 的測試同步改傳 `testRegistry`,原本的斷言不變仍綠 |

## 待確認假設

- A1(cabal 瘦身與移除 `aapms-md` 依賴):**採取**——把 #6/#8 範圍的七個已編不過模組移出
  `exposed-modules`/`other-modules`,並把 `aapms-md` 移出 `aapms-store` 的 `build-depends`。
  契約卡沒有明文授權改動 cabal 的模組清單與套件依賴,但查證顯示不這麼做 `cabal test
  aapms-store` 連編譯都到不了,本 feature 無法產出任何「如實回報」的測試結果。**影響**:
  若編排者認為應該保留這些死碼在 build 目標內(例如想讓 `cabal build all` 的失敗訊息集中
  在同一個地方),則改為在 `.cabal` 檔加 `-- TODO(F006/F008)` 註解但不移出清單,代價是 F005
  本身就無法達成綠燈,委派模式的「機械性查證不可跳過」會卡死在建置階段
- A2(`Vault.hs` → `Marker.hs` 改名):**採取**。design.md「內部模組劃分」表本就把這個職責
  命名為 `Marker`(而非 `Vault`),且舊名字 `Vault` 現在容易與契約 E 的 `VaultHandle`/
  `VaultKind`/`VaultMarker` 三個型別名稱混淆。**影響**:純粹是檔名與模組路徑,若編排者偏好
  保留舊檔名只改內容,改動範圍縮小但與 design.md 的模組表對不上
- A3(`VaultHandle`/`openVault`/`closeVault` 放進 `Marker` 模組,不另開模組):**採取**。
  design.md 只為這個 feature 命名了 Marker/Atomic/Schema 三個模組,`VaultHandle` 是「marker +
  根目錄 + 索引連線」的組合,沒有更適合的既有模組名字可以放。**影響**:若後續 feature 覺得
  `Marker` 模組職責過重(混了「讀 config.toml」與「組裝 handle、判斷 schema」兩層),可以在
  #6 或更後面拆成獨立模組,屬於不影響契約簽名的內部重構
- A4(`initVaultAt` 不建業務子目錄、不寫 `.gitignore`):**採取**。驗收標準只寫「`.aapms/
  config.toml`……與空索引」,且 `asset`/`story` 兩種 `kind` 的目錄結構完全不同,子目錄清單
  屬於 `kind` 專屬的業務知識,不該寫死在本 feature。**影響**:若判斷錯誤、`workspace` 的
  `vault init` 預期 `initVaultAt` 自己建好子目錄,則要幫 `initVaultAt` 加一個「依 kind 建立
  骨架目錄」的參數或另開函式,屬於契約 E 簽名的擴充(需要回頭走 `/subsys-design` 更新模式)
- A5(`initVaultAt` 的 `vlt-` id 不做碰撞重試):**採取**,`newId PVlt name now 0`(固定
  `salt = 0`,不重試)。契約卡「明確不做」寫「不讀中樞註冊表」,本 feature 因此**沒有任何
  資料來源**可以拿來檢查新 id 是否與其他已註冊的 vault 撞號——`newId` 本身的說明
  (`core/src/Aapms/Core/Id.hs:99-102`)寫明「唯一性不在這一層」,由「持有索引的那一層」以
  salt 重試保證,但那一層(對 vault id 而言)是全域註冊表,屬 `workspace`,不是本 feature。
  **影響**:若中樞註冊表發現撞號(FNV-1a 64-bit 取低 32 位,實務機率極低但非零),那是
  `workspace` 註冊時的責任(可以要求作者重新 `vault init`),不影響本 feature 的正確性
- A6(`IndexIssue` 只放一個建構子,交由 #6 擴充而非重新定義):**採取**,依委派決策記錄 D3
  逐字指示。**影響**:若 #6 的設計者選擇整個重新定義 `IndexIssue`(而非在既有 `data
  IndexIssue = SchemaRebuilt {..} | ...` 後面加建構子),本 feature 產出的
  `SchemaRebuilt`/`renderIndexIssue`/相關測試都要跟著改,屬跨 feature 的協調風險,建議編排者
  在指派 #6 時明確告知「擴充不是重寫」

## 實作備註

- T1~T12 全部完成,無公開介面偏離。`Marker.hs`/`Schema.hs`/`Error.hs` 的簽名與「新增的介面」
  一節逐字一致
- `openIndexAt` 內的 PRAGMA 增加 `busy_timeout = 5000` 一條(ADR-022),查詢方式與
  `journal_mode` 相同(`query_ :: IO [Only Int]`,PRAGMA 設值也回一列結果)——這是內部實作
  細節,契約簽名未變
- 驗證時發現本文檔「風險與建置阻塞」第 2 點所述的 `aapms-md`(`Aapms.Md.Inherit`)編譯失敗
  __已不存在__:委派 prompt 的前置狀態說明 F004 已把 `aapms-md` 修好(239 examples/0
  failures),`cabal build all`/`cabal test all` 目前對全部四個套件(`aapms-core`/`aapms-types`/
  `aapms-md`/`aapms-store`)都乾淨通過,不再需要「只能跑限定套件」的迴避——但驗收指令仍照編排者
  指定的 `cabal build aapms-store` / `cabal test aapms-store` 執行並記錄結果,沒有改用
  `cabal build all` 取代
- `Aapms.Store.Fixtures` 依 T7 瘦身後只剩 `withTempVault`/`orDie`/`idOf`/`refOf`;
  `MarkerSpec.hs`/`SchemaSpec.hs` 需要的臨時目錄與手寫 marker 檔改為各自在測試檔內用
  `System.Directory`/`ByteString` 組裝,對照舊 `VaultSpec.hs` 的手法(未新增回 Fixtures)
- **更正(編排者查證,2026-08-23)**:上面第一輪回報把「移除 `aapms-md` 的
  `build-depends`」寫成「綠燈的必要條件」(待確認假設 A1),編排者查證後確認**不是**——本
  feature 留下的四個模組(`Marker`/`Atomic`/`Schema`/`Error`)沒有任何一個 import
  `Aapms.Md.*`,未使用的 `build-depends` 不會讓建置失敗。結果(移除該依賴)本身仍然合理
  (F006 需要 `aapms-md` 時會自己加回,契約卡也沒有要求 F005 保留它),但理由不成立;下一輪
  (T13,D9)不再用「移除某依賴才能綠燈」這種推論,已改成先查證再動 cabal

## D9(2026-08-23):`TypeRegistry` 併入 `VaultHandle`

- **背景**:F006 設計時發現 `design.md` 內部矛盾——資料流管線與模組間公開介面都寫「索引時跑
  `checkMeta` 產生警告」,但 `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` 需要註冊表,
  契約 E 的索引函式與 `VaultHandle` 都拿不到。開發者裁決:註冊表放進 `VaultHandle`,不是各函式
  加參數(理由:`openVault` 自己的過時刷新路徑同樣要用到,只補索引函式會漏掉這一段;由
  `openVault` 收下也把「先載入註冊表、再開 vault」的順序用型別釘死)。編排者已把 `design.md`
  契約 E 改成這個形狀(commit `5de2727`),本 feature 的契約 E 引用段落與「新增的介面」一節已
  同步更新
- **改動範圍**:只有 `Aapms.Store.Marker`——`VaultHandle` 加 `vhRegistry :: TypeRegistry` 欄位,
  `openVault` 簽名改成 `TypeRegistry -> FilePath -> IO (...)`。`readMarker`/`initVaultAt`/
  `closeVault` 不動(`initVaultAt` 只寫 marker 與空索引,不需要註冊表;這與「明確不做」清單
  一致,沒有新增業務邏輯,只是把已載入好的值存進 handle)
- **`aapms-store.cabal` 查證結果:不需要新增 `build-depends`**。`TypeRegistry` 依 D7 定義在
  `Aapms.Core.Registry`(`aapms-core`;`core/src/Aapms/Core/Registry.hs:24-27` 的匯出清單),
  library 與 test-suite 原本就已相依 `aapms-core`,直接 `import Aapms.Core.Registry
  (TypeRegistry)` 即可——不需要 `aapms-types`(那是 IO 載入層 `Aapms.Types.Loader`,見下一點)
- **測試用的 `TypeRegistry` 怎麼來(選擇與理由)**:在 `Aapms.Store.Fixtures` 新增
  `testRegistry :: TypeRegistry`,以 `Aapms.Core.Registry.buildRegistry []` 建一個空註冊表,
  __不__引入 `aapms-types`、也__不__真的讀 `types/registry/*.toml`。理由與舊
  `VaultSpec.hs`/`Fixtures.hs` 時代的 `testRegistry`(依賴 `EntityTypeSpec`/`validateRegistry`,
  已在 D8 隨七個模組移出範圍)同一個:讀取層(`Aapms.Types.Loader`)的載入邏輯是
  `aapms-types` 自己的測試範圍,落地層的測試不該因為別人改了一份 TOML、或多引入一個套件的
  `data-files`/`Paths_*` 機制而變紅或變重。`buildRegistry []` 的驗證規則全部是「對已有宣告的
  檢查」(重複鍵、保留鍵、未知欄位……),對空清單一定回 `Right`,`error` 分支只是防禦性寫法不會
  真的被打到——這一點已在型別上被 T13 的測試（`openVault` 把傳入值原樣放進 `vhRegistry`）間接
  驗證過(拿得到、放得回去)
- **範圍界線**:`vhRegistry` 目前__只是存放__,`Marker` 模組沒有任何函式讀取或使用它——
  `checkMeta` 的呼叫點在索引管線(F006),不在本 feature
