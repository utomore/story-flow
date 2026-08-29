---
id: F001
type: feature
title: hub-registry
description: "中樞位置解析、config.toml 四段的讀寫與可手寫保留、載入失敗即失敗;Types 一次寫齊契約 A–F 的全部型別"
status: spec
created: 2026-08-29
updated: 2026-08-29
depends-on: []
related-adr: [ADR-008, ADR-014, ADR-017]
related-feature: []
---

# F001: 中樞位置、config.toml 四段讀寫、全套型別與錯誤(hub-registry)

## 功能概述

實作 `workspace` 裁決管線的前兩步(`hubLocation` → `loadHub`)與生命週期管線的最後一步
(`saveHub`),並依 build-log D2 把契約 A–F 的**全部型別**與 `WorkspaceError` 的**全部建構子**
一次寫齊。負責模組是 design.md「內部模組劃分」的 Types、Location、Hub 三個。

**驗收標準**(逐字抄自契約卡):

1. `AAPMS_HOME` 設為非空字串時 `hlSource == FromEnv` 且 `hlPath` 等於該字串的絕對化;未設或
   空字串時 `hlSource == FromPlatformDefault` — 觀察點:契約 A 的 `hubLocation`
2. 中樞檔案不存在時 `loadHub` 回 `HubNotFound` 且**不是**空的 `Hub` — 觀察點:契約 A 的
   `loadHub`、契約 F 的 `HubNotFound`
3. TOML 解不開回 `HubUnreadable`、解得開但欄位不合規(`id` 缺、`kind` 不是 `asset` / `story`、
   路徑非絕對)回 `HubMalformed`,兩者的訊息都含**檔案路徑** — 觀察點:契約 F 的
   `renderWorkspaceError`
4. 對任意合法中樞檔案,`loadHub` 後立刻 `saveHub` 再 `loadHub`,兩次的 `hubVaults` /
   `hubProjects` / `hubLlm` / `hubTools` 逐欄相等,且**檔案中原有的註解與空白行逐字保留** —
   觀察點:契約 A 的 `loadHub` / `saveHub` 與契約 B 的四個 getter
5. `hubLlm` 對「整段缺席」回 `Nothing`、對「空的 `[llm]` 段」回 `Just` 空表,兩者可區分 —
   觀察點:契約 B 的 `hubLlm`
6. `thumbCachePath loc (Sha256 h)` 的結果一律是 `<hlPath>/cache/thumbs/<take 2 h>/<h>.png`,
   而且以 `thumbCacheDir loc` 為前綴 — 觀察點:契約 B 的 `thumbCachePath` / `thumbCacheDir`
7. `renderWorkspaceError` 對 `WorkspaceError` 的**每一個**建構子都回一段非空的繁中訊息,且訊息
   含該建構子攜帶的路徑 / 名稱 / id(契約 F 逐條規定的那些值) — 觀察點:契約 F 的
   `renderWorkspaceError`

**明確不做**(逐字抄自契約卡):不建立任何目錄或檔案(那是 `setupHub`,#4);不解讀 `[llm]` 的
任何鍵;不驗證 `vePath` 指的目錄真的存在(那是 #2 的重讀 marker);**契約 C / D / E 的函式完全
不在本 feature**——它們住在 Discovery / Scope / Lifecycle / Projects / Tools,那幾個模組由各自的
feature 建立,本 feature 只把它們會用到的**型別**一次宣告到位。

## 相依性

`depends-on: []`——design.md「功能規劃」階段一表 #1 列的「依賴」欄是 `-`。#2 / #3 / #5 / #6 反過來
依賴本 feature。

跨子系統:`graph-core` 九個 feature 全數 `done`,本 feature 用到的六個符號
(`VaultId` / `Id` / `Sha256` / `VaultKind` / `VaultMarker` / `StoreError` 與
`markerDir` / `configPath` / `indexDbPath` / `atomicWriteText` / `readTextFile` /
`renderStoreError`)都已交付,簽名逐一開原始碼查證過,見「使用到的既有串接介面」。

## 對應的 Level 2 契約

### 契約 A(全部)

```haskell
data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }
data HubSource   = FromEnv | FromPlatformDefault
data Hub                                        -- 已載入的中樞快照,不可變

hubLocation :: IO HubLocation
loadHub     :: HubLocation -> IO (Either WorkspaceError Hub)
saveHub     :: HubLocation -> Hub -> IO (Either WorkspaceError ())   -- 原子寫入
```

### 契約 B(契約卡指定的十個項目)

```haskell
data VaultEntry   = VaultEntry { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }
data ProjectEntry = ProjectEntry { peId :: Id, peName :: Text, pePath :: FilePath }
newtype LlmSection = LlmSection (Map Text TOML.Value)
data ToolsConfig   = ToolsConfig { tcSevenZip :: Maybe FilePath }

hubVaults   :: Hub -> [VaultEntry]
hubProjects :: Hub -> [ProjectEntry]
hubLlm      :: Hub -> Maybe LlmSection
hubTools    :: Hub -> ToolsConfig

thumbCacheDir  :: HubLocation -> FilePath
thumbCachePath :: HubLocation -> Sha256 -> FilePath
```

### 契約 C / D / E(**只有型別宣告**,函式不在本 feature)

`VaultRef` / `ScopeIssue` / `ReadScope` / `WriteScope` / `PipelineScope` /
`InitMode` / `DeleteIndex` / `PurgeScope` / `SetupReport` / `AdoptNotice` / `PurgeReport` /
`ToolOrigin` / `ToolStatus`——全部宣告在 `Aapms.Workspace.Types`,欄位與值域逐字照 design.md
契約 C / D / E 的表。

### 契約 F(全部)

`WorkspaceError` 與 `renderWorkspaceError`。

> **對帳發現(建議編排者修訂 design.md 的敘述,不改列舉)**:契約卡與 build-log D2 的散文寫
> 「`WorkspaceError` 的**十五**個建構子」,但 design.md 契約 F 的程式碼區塊逐條列出的是
> **十六**個(`HubNotFound` / `HubUnreadable` / `HubMalformed` / `HubWriteFailed` /
> `VaultSelectorNotFound` / `VaultSelectorAmbiguous` / `VaultKindMismatch` / `NoWriteTarget` /
> `VaultAlreadyInitialized` / `VaultDirMissing` / `VaultDirNotEmpty` / `VaultIdCollision` /
> `MarkerUnreadable` / `ProjectSelectorNotFound` / `ProjectPathMissing` / `InvalidName`)。
> 本 feature 以**列舉為準**寫十六個——散文的數字是概述,列舉才是契約本體,而且少寫一個建構子
> 會讓階段二的某個 feature 沒有錯誤可用、被迫回頭改 `Types.hs`(D2 要避免的正是這件事)。

### 模組間公開介面(design.md「模組間公開介面」表,本 feature 要交付的兩列)

```haskell
-- Hub → Location
configPath :: HubLocation -> FilePath

-- Lifecycle / Projects → Hub(對 Hub 值的純操作)
upsertVault   :: VaultEntry   -> Hub -> Hub
removeVault   :: VaultId      -> Hub -> Hub
upsertProject :: ProjectEntry -> Hub -> Hub
removeProject :: Id           -> Hub -> Hub
```

`upsertVault` / `removeVault` 在 design.md 的「模組間公開介面」表裡逐字出現(`Lifecycle → Hub`
那一列);`upsertProject` / `removeProject` 是對稱補齊,理由見「待確認假設」A2。四者都住
`Aapms.Workspace.Hub`——那是本 feature 的檔案,而 F004 / F005 的骨架白名單只有
`Lifecycle.hs` / `Projects.hs`,它們沒有地方寫這四個函式。

## 實作方式

### 相依性查證(2026-08-29 打開 `core/src/` 與 `store/src/` 讀到的實況)

四點與契約文字不同、必須在實作前知道的事實:

1. **`VaultKind` 不在 `Aapms.Store.Marker`,在 `Aapms.Store.Schema`**
   (`store/src/Aapms/Store/Schema.hs:63-64`)。design.md 相依段落寫「`aapms-store`
   (`readMarker` / `VaultMarker` / `VaultKind` / …)」沒有指模組;`Types.hs` 要
   `import Aapms.Store.Schema (VaultKind)` 而不是從 `Marker` 拿。`renderVaultKind` /
   `parseVaultKind` 也在同一個模組。
2. **`Sha256` 在 `Aapms.Core.Asset`,不在 `Aapms.Core.Id`**
   (`core/src/Aapms/Core/Asset.hs:18-20`),建構子有匯出(`Sha256 (..)`)。
3. **`StoreError` 已經有 `VaultAlreadyInitialized FilePath` 與
   `VaultIdCollision VaultId FilePath FilePath` 兩個同名建構子**
   (`store/src/Aapms/Store/Error.hs:29-83`),而契約 F 的 `WorkspaceError` 也要這兩個名字。
   兩者住不同模組所以型別上沒有衝突,但**任何同時 import 兩個錯誤模組的模組**(F004 的
   `Lifecycle` 必然如此:它呼叫 `initVaultAt` 拿 `StoreError`、回 `WorkspaceError`)會撞名,
   要用 qualified import 或明確 import 清單。本 feature 的三個檔案只 import `StoreError` 這個
   **型別名**(不含建構子),不受影響;此處記錄是為了讓 F004 不必重新踩一次。
4. **`toml-reader` 是 0.3.0.0**(`C:\cabal\store\ghc-9.14.1-bd8b\toml-reader-0.3.0.0-*`)。
   `TOML.Value` 十個建構子(`Table` / `Array` / `String` / `Integer` / `Float` / `Boolean` /
   `OffsetDateTime` / `LocalDateTime` / `LocalDate` / `LocalTime`),`deriving (Show, Eq)`;
   `type Table = Map Text Value`。`LlmSection` 因此 derive 得出 `Show` / `Eq`,`Hub` 也是。
   `decode :: DecodeTOML a => Text -> Either TOMLError a`,取 `Value` 即可拿到整棵樹
   (`Aapms.Store.Marker.parseMarker` 就是這樣用的,`store/src/Aapms/Store/Marker.hs:96-98`)。

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base` / `containers` / `directory` /
`filepath` / `text` / `time` / `toml-reader` / `aapms-core` / `aapms-store` 覆蓋本 feature 全部
所需。`time` 本 feature 用不到(它是 F004 / F005 配號時 `newId` 要的),留著不動。

### 模組配置

| 檔案 | 內容 | 職責界線 |
|---|---|---|
| `workspace/src/Aapms/Workspace/Types.hs` | 契約 A–F 的**全部**型別、`WorkspaceError` 十六個建構子、`renderWorkspaceError`;`Hub` 的定義與 `mkHub` / 四個 getter / `hubSourceText` | **不得 import 本套件的任何其他模組**(避免相依環,design.md「Types 為什麼要獨立」);只依賴 `aapms-core` / `aapms-store` 的型別與 `TOML.Value` |
| `workspace/src/Aapms/Workspace/Location.hs` | `hubLocation` / `configPath` / `thumbCacheDir` / `thumbCachePath` | 擁有「中樞在哪」與中樞目錄的內部佈局;**只回答路徑是什麼**,不建目錄、不判斷存在 |
| `workspace/src/Aapms/Workspace/Hub.hs` | `loadHub` / `saveHub` / 四個 getter 轉出 / `upsertVault` / `removeVault` / `upsertProject` / `removeProject` | 擁有「中樞記了什麼」(四段的檔案格式);**自己不解析中樞位置**,經 `Location.configPath` 取檔案位置 |

依賴方向 `Types ← Location ← Hub`,沒有回頭邊。

### `Hub` 為什麼是不透明型別、`hubSourceText` 為什麼在裡面

驗收標準 4 要求 `saveHub` 保住檔案原有的註解與空白行,而 `saveHub` 的簽名
(`HubLocation -> Hub -> IO ...`)只拿得到這兩個值。兩條路:

- `saveHub` 自己**重讀**磁碟上的 `config.toml` 當底稿 → 讀與寫之間有窗口、`setupHub` 寫全新中樞
  時沒有底稿可讀、`Hub` 從別的位置載入再存到這個位置時會拿錯底稿
- `Hub` **載入時就帶著**原始檔案文字(`hubSourceText`)→ 底稿與四段結構化內容同源、確定性、
  全新中樞以空字串表示

採後者。因此 `Hub` 的建構子**不匯出**:允許外部逐欄拼裝就是允許拼出「`hubSourceText` 與四段
對不上」的快照。建構唯一入口是 `mkHub`(F004 的 `setupHub` 也要用它造空中樞),讀取走四個
getter,增刪走 `upsertVault` 那一組純函式。相關的契約偏離見「待確認假設」A1。

### 中樞 `config.toml` 的格式與合規規則

格式沿用 system.md「系統對外介面 › 6. 全局中樞」與 ADR-017 決策二:

```toml
[[vaults]]
id   = "vlt-7f3b2a91"
name = "alchbees-assets"
kind = "asset"
path = "C:/Users/User/Documents/alchbees-assets"

[[projects]]
id   = "prj-91c0aa12"
name = "Circle"
path = "D:/games/Circle"

[llm]
base_url = "http://127.0.0.1:8080/v1"
model    = "qwen2.5-7b-instruct"

[tools]
seven_zip = "C:/Program Files/7-Zip/7z.exe"
```

**四段全部可缺席**:`[[vaults]]` / `[[projects]]` 缺席 → 空清單;`[llm]` 缺席 → `Nothing`;
`[tools]` 缺席 → `ToolsConfig Nothing`。**「四段都缺席」與「檔案不存在」不同**:前者是合法的
空中樞(`Right`),後者是 `HubNotFound`。

`loadHub` 的錯誤分流:

| 情況 | 結果 |
|---|---|
| `configPath loc` 不存在 | `Left (HubNotFound (configPath loc))` |
| 檔案讀不進來(IO 失敗、不是合法 UTF-8) | `Left (HubUnreadable (configPath loc) <原因>)` |
| `TOML.decode` 失敗 | `Left (HubUnreadable (configPath loc) (TOML.renderTOMLError e))` |
| 最上層不是 TOML 表 | `Left (HubMalformed (configPath loc) "檔案的最上層不是 TOML 表")` |
| 下表任一條欄位不合規 | `Left (HubMalformed (configPath loc) <指出哪一段哪個鍵、為什麼>)` |

欄位合規規則(逐條;訊息風格對照 `Aapms.Store.Marker.parseMarker`,如「缺少必填鍵 `id`」):

| 段 | 鍵 | 規則 | 不合規時的訊息要點 |
|---|---|---|---|
| `[[vaults]]` | — | 必須是表的陣列 | ``鍵 `vaults` 必須是表的陣列`` |
| `[[vaults]]` | `id` | 必填、字串、`parseId` 通過且前綴是 `vlt` | 缺鍵 / 必須是字串 / 不是合法的 `vlt-` id(附原始字串) |
| `[[vaults]]` | `name` | 必填、字串、去前後空白後長度 ≥ 1 | 缺鍵 / 必須是字串 / 不得為空 |
| `[[vaults]]` | `kind` | 必填、字串、`parseVaultKind` 通過 | 缺鍵 / 必須是字串 / 必須是 asset 或 story,收到 `<原始字串>` |
| `[[vaults]]` | `path` | 必填、字串、`System.FilePath.isAbsolute` 為真 | 缺鍵 / 必須是字串 / 必須是絕對路徑,收到 `<原始字串>` |
| `[[vaults]]` | — | 全部 `id` 在中樞內**唯一** | vault id `<id>` 在中樞裡出現一次以上 |
| `[[projects]]` | `id` | 必填、字串、`parseId` 通過且前綴是 `prj` | 同上,前綴換 `prj-` |
| `[[projects]]` | `name` | 必填、字串、去前後空白後長度 ≥ 1 | 同上 |
| `[[projects]]` | `path` | 必填、字串、`isAbsolute` 為真 | 同上 |
| `[[projects]]` | — | 全部 `id` 在中樞內**唯一** | project id `<id>` 在中樞裡出現一次以上 |
| `[llm]` | — | 必須是表;**內容不解讀** | ``鍵 `llm` 必須是表`` |
| `[tools]` | — | 必須是表 | ``鍵 `tools` 必須是表`` |
| `[tools]` | `seven_zip` | 選填、字串、`isAbsolute` 為真 | 必須是字串 / 必須是絕對路徑,收到 `<原始字串>` |

**未知的鍵與未知的頂層段一律容忍且原樣保留**,不是 `HubMalformed`:中樞是「可手寫」的檔案
(ADR-017 決策二),對使用者自己加的註記、以及未來版本新增的段落嚴格拒收,會讓一個新版寫出的
檔案被舊版判成壞檔。理由與自裁層級見「實作備註」S1。

**`vePath` / `pePath` 指的目錄存不存在不檢查**(契約卡「明確不做」):`loadHub` 只驗「是不是
絕對路徑」,存在性是 #2 重讀 marker 時的 `VaultPathMissing`。

### `hubLocation` 的解析

```text
lookupEnv "AAPMS_HOME"
  → Just s,且 s 去前後空白後非空 → makeAbsolute s → HubLocation <絕對路徑> FromEnv
  → Nothing 或 Just ""(或全空白)   → 平台預設                → HubLocation <平台路徑> FromPlatformDefault
```

平台預設用 `System.Directory.getXdgDirectory XdgConfig "aapms"`:它在 Windows 回
`%APPDATA%\aapms`、在其他平台回 `$XDG_CONFIG_HOME/aapms`(未設時 `~/.config/aapms`),與
design.md 契約 A 的兩句話逐字對應,**不需要自己寫平台分支**。

**沒有第三層、不搜尋、不猜。**

### `loadHub` → `saveHub` 的資料流

```text
HubLocation
  → Location.configPath loc                            -- <hlPath>/config.toml
  → doesFileExist → False → Left (HubNotFound fp)      -- 不回空中樞
  → Aapms.Store.Atomic.readTextFile fp                 -- UTF-8,不看 locale
      Left e → Left (HubUnreadable fp (renderStoreError e))
  → TOML.decode txt :: Either TOMLError TOML.Value
      Left e → Left (HubUnreadable fp (TOML.renderTOMLError e))
  → 逐段解析 [[vaults]] / [[projects]] / [llm] / [tools]
      任一條不合規 → Left (HubMalformed fp <訊息>)
  → mkHub vaults projects llm tools txt                -- txt 逐字留在 hubSourceText
  → Right hub

saveHub loc hub
  → 以 hubSourceText hub 為底稿,把四段渲染回去
      未變動的區塊、註解、空白行、未知段落 → 逐字沿用
      新增的列 → 追加到對應段落的末尾;刪除的列 → 整塊移除
  → Aapms.Store.Atomic.atomicWriteText (Location.configPath loc) <新文字>
      Left e → Left (HubWriteFailed fp (renderStoreError e))
  → Right ()
```

`saveHub` **不建立目錄**(契約卡「明確不做」):`<hlPath>` 不存在時 `atomicWriteText` 失敗,
原樣包成 `HubWriteFailed`。建目錄是 F004 的 `setupHub`。原子寫入沿用 `atomicWriteText`,
**不另寫一份**(design.md「使用的技術」)。

`upsertVault` / `removeVault` / `upsertProject` / `removeProject` **只動結構化的四段,不動
`hubSourceText`**——底稿與「現在應該長什麼樣」的差異由 `saveHub` 一次收斂。這是「既有列的相對
順序、使用者寫的註解與空白行原樣保留」(ADR-017 決策二)成立的前提:純操作若順手改寫底稿,
每一次增刪都要重做一次保留邏輯。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newtype VaultId = VaultId Text`(建構子匯出) | `core/src/Aapms/Core/Id.hs:148-150` | graph-core F001 | `veId`、`ScopeIssue`、`WorkspaceError` 三處的 vault 身分 |
| `data Id`(不透明,只能經 `newId` / `parseId` 取得) | `core/src/Aapms/Core/Id.hs:86-88` | graph-core F001 | `peId` 的型別 |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/Aapms/Core/Id.hs:127-135` | graph-core F001 | `loadHub` 驗 `[[vaults]].id` / `[[projects]].id` 的格式與前綴 |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123-124` | graph-core F001 | 序列化 `peId`、錯誤訊息裡印 id |
| `data IdPrefix = … \| PVlt \| PPrj`(八個建構子) | `core/src/Aapms/Core/Id.hs:46-55` | graph-core F001 | 驗前綴:vault 必須 `PVlt`、project 必須 `PPrj` |
| `renderIdPrefix :: IdPrefix -> Text` | `core/src/Aapms/Core/Id.hs:57-66` | graph-core F001 | 錯誤訊息裡指出「收到的前綴不是 vlt-/prj-」 |
| `newtype Sha256 = Sha256 Text`(建構子匯出) | `core/src/Aapms/Core/Asset.hs:18-20` | graph-core F001 | `thumbCachePath` 的第二參數,直接 pattern match 取出 64 位十六進位字串 |
| `data VaultKind = AssetVault \| StoryVault` | `store/src/Aapms/Store/Schema.hs:63-64` | graph-core F005 | `veKind`、`VaultKindMismatch` 的型別 |
| `renderVaultKind :: VaultKind -> Text`(`asset` / `story`) | `store/src/Aapms/Store/Schema.hs:66-68` | graph-core F005 | `saveHub` 序列化 `kind`;`renderWorkspaceError` 印 kind |
| `parseVaultKind :: Text -> Maybe VaultKind`(只認 `asset` / `story`) | `store/src/Aapms/Store/Schema.hs:71-74` | graph-core F005 | `loadHub` 驗 `kind` |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57-63` | graph-core F005 | `VaultRef.vrMarker` 的型別(本 feature 只宣告型別,不讀 marker) |
| `data StoreError`(26 個建構子,`deriving stock (Show, Eq)`) | `store/src/Aapms/Store/Error.hs:29-83` | graph-core F005/F008 | `ScopeIssue.VaultMarkerBroken` 與 `WorkspaceError.MarkerUnreadable` 捧著的原件 |
| `renderStoreError :: StoreError -> Text` | `store/src/Aapms/Store/Error.hs:91` | graph-core F005 | 把 `readTextFile` / `atomicWriteText` 的失敗轉成 `HubUnreadable` / `HubWriteFailed` 的 `Text`;`MarkerUnreadable` 的訊息也由它產生,**這一層不翻譯** |
| `readTextFile :: FilePath -> IO (Either StoreError Text)` | `store/src/Aapms/Store/Atomic.hs:35-42` | graph-core F005 | `loadHub` 讀 `config.toml`(一律當 UTF-8,不看本機 locale) |
| `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` | `store/src/Aapms/Store/Atomic.hs:44-72` | graph-core F005 | `saveHub` 的原子寫入,**不另寫一份** |
| `markerDir :: FilePath -> FilePath`(`root </> ".aapms"`) | `store/src/Aapms/Store/Marker.hs:46-47` | graph-core F005 | 本 feature **不用**;列出是因為 #2 / #4 會用,且它與 `Location.configPath` 同名不同義,先標明界線 |
| `configPath :: FilePath -> FilePath`(`markerDir root </> "config.toml"`) | `store/src/Aapms/Store/Marker.hs:49-50` | graph-core F005 | 同上——**vault 的** `config.toml`;`Aapms.Workspace.Location.configPath` 是**中樞的**,兩者同名,同時 import 要 qualified |
| `indexDbPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:52-53` | graph-core F005 | 本 feature 不用(#4 的 `--delete-index` 要) |
| `decode :: DecodeTOML a => Text -> Either TOMLError a`;`Value (..)`;`type Table = Map Text Value`;`renderTOMLError :: TOMLError -> Text` | `toml-reader-0.3.0.0` 的 `TOML` 模組 | - | `loadHub` 的解析;`LlmSection` 的元素型別 |
| `lookupEnv :: String -> IO (Maybe String)` | `base` 的 `System.Environment` | - | `hubLocation` 讀 `AAPMS_HOME` |
| `getXdgDirectory :: XdgDirectory -> FilePath -> IO FilePath`、`makeAbsolute`、`doesFileExist` | `directory` | - | `hubLocation` 的平台預設與絕對化;`loadHub` 的存在性判斷 |
| `(</>) :: FilePath -> FilePath -> FilePath`、`isAbsolute :: FilePath -> Bool` | `filepath` | - | 衍生路徑組裝;`path` 欄位的絕對性檢查 |

## 新增的介面

行號是**建檔當下**的導航線索,impl 填完本體後必然往下移;一致性檢查一律比對**簽名原文**。

### `workspace/src/Aapms/Workspace/Types.hs`

```haskell
-- 契約 A
data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }   -- :71
  deriving stock (Show, Eq)
data HubSource = FromEnv | FromPlatformDefault                                  -- :79
  deriving stock (Show, Eq)

-- | 建構子不匯出;匯出的是型別、mkHub、五個 selector。
data Hub                                                                        -- :90
  deriving stock (Show, Eq)
mkHub :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text -> Hub  -- :109
hubSourceText :: Hub -> Text                                                    -- :100

-- 契約 B
hubVaults   :: Hub -> [VaultEntry]                                              -- :91
hubProjects :: Hub -> [ProjectEntry]                                            -- :93
hubLlm      :: Hub -> Maybe LlmSection                                          -- :95
hubTools    :: Hub -> ToolsConfig                                               -- :98

data VaultEntry = VaultEntry                                                    -- :122
  { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }
  deriving stock (Show, Eq)
data ProjectEntry = ProjectEntry { peId :: Id, peName :: Text, pePath :: FilePath }  -- :135
  deriving stock (Show, Eq)
newtype LlmSection = LlmSection (Map Text TOML.Value)                           -- :147
  deriving stock (Show) ; deriving newtype (Eq)
data ToolsConfig = ToolsConfig { tcSevenZip :: Maybe FilePath }                 -- :152
  deriving stock (Show, Eq)

-- 契約 C(只有型別)
data VaultRef = VaultRef { vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }  -- :162
data ScopeIssue                                                                 -- :173
  = VaultPathMissing VaultEntry FilePath
  | VaultMarkerBroken VaultEntry StoreError
  | VaultIdDrift VaultEntry VaultId
  | RefVaultNotRegistered VaultId VaultId
data ReadScope     = ReadScope     { rsVaults :: [VaultRef], rsIssues :: [ScopeIssue] }               -- :186
data WriteScope    = WriteScope    { wsTarget :: VaultRef, wsRead :: [VaultRef], wsIssues :: [ScopeIssue] }  -- :194
data PipelineScope = PipelineScope { psRuns :: [VaultRef], psIssues :: [ScopeIssue] }                 -- :204

-- 契約 D(只有型別)
data InitMode    = FreshVault | AdoptExisting                                   -- :214
data DeleteIndex = KeepIndex | DeleteIndex                                      -- :223
data PurgeScope  = PurgeHubOnly | PurgeAllVaults                                -- :227
data SetupReport = SetupReport { spHubPath :: FilePath, spHubCreated :: Bool, spCacheCreated :: Bool }  -- :232
newtype AdoptNotice = AdoptNotice { anLegacyMarkers :: [FilePath] }             -- :240
data PurgeReport = PurgeReport                                                  -- :248
  { prHubRemoved :: Bool, prThumbsRemoved :: Int, prVaultIndexesRemoved :: [FilePath] }

-- 契約 E(只有型別)
data ToolOrigin = FromToolsConfig | FromPath | FromCandidate | NotFound         -- :258
data ToolStatus = ToolStatus                                                    -- :270
  { tsName :: Text, tsPath :: Maybe FilePath, tsOrigin :: ToolOrigin, tsSearched :: [FilePath] }

-- 契約 F
data WorkspaceError                                                             -- :288
  = HubNotFound FilePath | HubUnreadable FilePath Text | HubMalformed FilePath Text
  | HubWriteFailed FilePath Text
  | VaultSelectorNotFound Text | VaultSelectorAmbiguous Text [VaultEntry]
  | VaultKindMismatch VaultId VaultKind VaultKind
  | NoWriteTarget FilePath
  | VaultAlreadyInitialized FilePath | VaultDirMissing FilePath | VaultDirNotEmpty FilePath
  | VaultIdCollision VaultId FilePath FilePath
  | MarkerUnreadable FilePath StoreError
  | ProjectSelectorNotFound Text | ProjectPathMissing Text FilePath
  | InvalidName Text
  deriving stock (Show, Eq)

renderWorkspaceError :: WorkspaceError -> Text                                  -- :330
```

### `workspace/src/Aapms/Workspace/Location.hs`

```haskell
hubLocation    :: IO HubLocation                     -- :28
configPath     :: HubLocation -> FilePath            -- :35   <hlPath>/config.toml
thumbCacheDir  :: HubLocation -> FilePath            -- :40   <hlPath>/cache/thumbs
thumbCachePath :: HubLocation -> Sha256 -> FilePath  -- :47   <thumbCacheDir>/<take 2 h>/<h>.png
```

### `workspace/src/Aapms/Workspace/Hub.hs`

```haskell
loadHub :: HubLocation -> IO (Either WorkspaceError Hub)          -- :53
saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())    -- :62

upsertVault   :: VaultEntry   -> Hub -> Hub                       -- :67
removeVault   :: VaultId      -> Hub -> Hub                       -- :71
upsertProject :: ProjectEntry -> Hub -> Hub                       -- :76
removeProject :: Id           -> Hub -> Hub                       -- :80

-- 自 Aapms.Workspace.Types 轉出(同一個實體,import 兩邊不會 ambiguous):
-- hubVaults / hubProjects / hubLlm / hubTools
```

## 數據

### `renderWorkspaceError` 的訊息規格

每一則都必須:**非空**、**含中文字元**、**含「請」/「改用」/「可以」/「才」至少一個**
(「說出下一步」的可機械驗證代理)、**不含 `show` 痕跡**(不出現 `Left` / `Right` / `Just ` /
`Nothing` / 該建構子自己的名字)。逐條必須嵌入的值:

| 建構子 | 訊息必須含 |
|---|---|
| `HubNotFound fp` | `fp` |
| `HubUnreadable fp reason` | `fp`、`reason` |
| `HubMalformed fp reason` | `fp`、`reason` |
| `HubWriteFailed fp reason` | `fp`、`reason` |
| `VaultSelectorNotFound s` | `s` |
| `VaultSelectorAmbiguous s es` | `s`,以及 `es` 中**每一列**的 `veId` 與 `vePath` |
| `VaultKindMismatch vid want got` | `vid`、`renderVaultKind want`、`renderVaultKind got` |
| `NoWriteTarget start` | `start` |
| `VaultAlreadyInitialized dir` | `dir` |
| `VaultDirMissing dir` | `dir` |
| `VaultDirNotEmpty dir` | `dir` |
| `VaultIdCollision vid old new` | `vid`、`old`、`new`(**兩個路徑都要印**) |
| `MarkerUnreadable root e` | `root`、`renderStoreError e` |
| `ProjectSelectorNotFound s` | `s` |
| `ProjectPathMissing name fp` | `name`、`fp` |
| `InvalidName raw` | `raw`,且以「」夾住(`raw` 可能全是空白,不夾住就驗不出來) |

### 中樞路徑常數

| 名稱 | 值 |
|---|---|
| 環境變數 | `AAPMS_HOME` |
| 中樞檔案 | `<hlPath>/config.toml` |
| 縮圖快取根 | `<hlPath>/cache/thumbs` |
| 縮圖分片 | `take 2 h`(`h` 是 64 位小寫十六進位) |
| 縮圖副檔名 | `.png`(固定) |

### 測試素材:一份「有註解與空白行」的合法中樞

```toml
# 我的中樞設定 —— 手寫,請勿用工具整檔重寫

[[vaults]]
id   = "vlt-7f3b2a91"
name = "alchbees-assets"
kind = "asset"          # 素材庫
path = "C:/Users/User/Documents/alchbees-assets"

# 故事側
[[vaults]]
id   = "vlt-a0c4e1f8"
name = "liftgame"
kind = "story"
path = "D:/story-vaults/liftgame"

[[projects]]
id   = "prj-91c0aa12"
name = "Circle"
path = "D:/games/Circle"

[llm]
base_url = "http://127.0.0.1:8080/v1"
model    = "qwen2.5-7b-instruct"

[tools]
seven_zip = "C:/Program Files/7-Zip/7z.exe"
```

## Laws

- **L1(`hubLocation` 的兩層解析)**:對任意去前後空白後非空的字串 `s`,在
  `AAPMS_HOME = s` 之下 `hubLocation` 回的 `hlSource == FromEnv` 且
  `hlPath == <s 的 makeAbsolute>`;在 `AAPMS_HOME` 未設或設為空字串(或全空白)之下,
  `hlSource == FromPlatformDefault`。兩種情形的 `hlPath` 恒為絕對路徑。
- **L2(`configPath` / `thumbCacheDir` 是純衍生)**:對任意 `HubLocation loc`,
  `configPath loc == hlPath loc </> "config.toml"` 且
  `thumbCacheDir loc == hlPath loc </> "cache" </> "thumbs"`。兩者與 `hlSource` 無關
  (同一個 `hlPath` 配 `FromEnv` 與 `FromPlatformDefault` 得到相同結果)。
- **L3(`thumbCachePath` 的分片與前綴)**:對任意 64 位小寫十六進位字串 `h` 與任意 `loc`,
  `thumbCachePath loc (Sha256 h) == thumbCacheDir loc </> take 2 h </> (h <> ".png")`,
  且 `thumbCacheDir loc` 是 `thumbCachePath loc (Sha256 h)` 的前綴。
- **L4(中樞檔案不存在即失敗,不退回空中樞)**:對任意 `loc`,若 `configPath loc` 不存在,
  `loadHub loc` 回 `Left (HubNotFound (configPath loc))`——**不是** `Right` 配一個四段皆空的
  `Hub`。
- **L5(TOML 壞掉 vs 欄位不合規)**:對任意**不是合法 TOML** 的檔案內容,`loadHub` 回
  `Left (HubUnreadable fp _)`;對任意**合法 TOML 但違反「欄位合規規則」表任一條**的內容,
  回 `Left (HubMalformed fp _)`。兩者的 `fp` 都等於 `configPath loc`,且
  `renderWorkspaceError` 的輸出含 `fp`。
- **L6(四段缺席是合法的空中樞)**:對任意「檔案存在但四段全部缺席」的合法 TOML 檔,
  `loadHub` 回 `Right hub`,且 `hubVaults hub == []`、`hubProjects hub == []`、
  `hubLlm hub == Nothing`、`hubTools hub == ToolsConfig Nothing`。**這與 L4 是不同的兩件事。**
- **L7(`hubLlm` 三態可區分)**:`[llm]` 整段缺席 → `Nothing`;`[llm]` 存在但沒有任何鍵 →
  `Just (LlmSection <空表>)`;`[llm]` 存在且有 `n` 個鍵 → `Just (LlmSection m)` 且
  `Data.Map.size m == n`,`m` 的鍵集合等於檔案中該段的鍵集合、值原樣(不解讀)。
  前兩者**不相等**。
- **L8(`saveHub` 對未修改的 `Hub` 是位元組恆等)**:對任意合法中樞檔案,
  `loadHub` 成功後立刻 `saveHub` 同一個 `Hub` 到同一個 `loc`,檔案內容與呼叫前**逐位元組
  相同**——註解、空白行、鍵的對齊空白、段落順序、行尾風格全部不變。
- **L9(roundtrip 逐欄相等)**:對任意合法中樞檔案,`loadHub` → `saveHub` → `loadHub` 兩次得到
  的 `hubVaults` / `hubProjects` / `hubLlm` / `hubTools` **逐欄相等**(清單含順序)。
- **L10(改動後仍保留註解與空白行)**:對任意合法中樞檔案與任意 `VaultEntry e`(其 `veId`
  不在檔案中),`loadHub` → `upsertVault e` → `saveHub` → 重讀檔案文字後:原檔中**每一行
  註解**(去前導空白後以 `#` 開頭者)與**每一個空白行**都仍逐字存在且相對順序不變;而
  `loadHub` 回的 `hubVaults` 的最後一列是 `e`,其餘列與原本逐欄相等且順序不變。
- **L11(`upsertVault` 的語意)**:對任意 `Hub h` 與 `VaultEntry e`——若 `veId e` 不在
  `hubVaults h` 中,`hubVaults (upsertVault e h) == hubVaults h ++ [e]`;若在,則
  `hubVaults (upsertVault e h)` 與 `hubVaults h` **等長且順序相同**,只有該 id 那一列換成 `e`。
  兩種情形下 `hubProjects` / `hubLlm` / `hubTools` / `hubSourceText` 都不變。
- **L12(`removeVault` 的語意)**:對任意 `Hub h` 與 `VaultId v`,
  `hubVaults (removeVault v h) == filter ((/= v) . veId) (hubVaults h)`(保序);`v` 不存在時
  `removeVault v h == h`。`hubProjects` / `hubLlm` / `hubTools` / `hubSourceText` 都不變。
- **L13(`upsertProject` / `removeProject` 對 `[[projects]]` 成立同樣的兩條)**:把 L11 / L12
  的 `hubVaults` 換成 `hubProjects`、`veId` 換成 `peId`,結論相同;且 `hubVaults` 不變。
- **L14(`renderWorkspaceError` 全建構子非空且說得出下一步)**:對 `WorkspaceError`
  **每一個**建構子的任意值,`renderWorkspaceError` 回的 `Text` 非空、含中文字元、含
  「請」/「改用」/「可以」/「才」之一,且**不含** `Left` / `Right` / `Just ` / `Nothing` /
  該建構子自己的名字。
- **L15(錯誤訊息含攜帶的值)**:對 `WorkspaceError` 每一個建構子,`renderWorkspaceError` 的
  輸出含「訊息規格」表逐條列出的每一個值。
- **L16(`mkHub` 與五個 selector 互逆)**:對任意 `vs` / `ps` / `llm` / `tools` / `txt`,
  `let h = mkHub vs ps llm tools txt` 有 `hubVaults h == vs`、`hubProjects h == ps`、
  `hubLlm h == llm`、`hubTools h == tools`、`hubSourceText h == txt`。
- **L17(依賴方向與職責界線,以 import 清單驗證)**:三個檔案的 **import 行**滿足——
  (a) `Types.hs` 沒有任何以 `import Aapms.Workspace.` 開頭的行(Types 不得 import 本套件的
  任何其他模組,否則型別歸屬圖有環);(b) `Location.hs` 不 import `Aapms.Workspace.Hub`
  (方向是 `Location ← Hub`,不得回頭);(c) `Location.hs` 與 `Hub.hs` **完全不得** import
  `Aapms.Store.Marker`——本 feature 不探測、不讀 vault marker,那是 #2;(d) `Types.hs` 對
  `Aapms.Store.Marker` 的 import 行**必須逐字是** `import Aapms.Store.Marker (VaultMarker)`
  ——契約 C 的 `VaultRef` 帶 `vrMarker :: VaultMarker`,那個型別只有這個模組給得出來,所以
  Types **必須**拿得到型別,但**拿不到** `readMarker` / `markerDir` / `configPath` /
  `indexDbPath` / `initVaultAt` 任何一個函式;(e) 三個檔案都不 import `Aapms.Store.Schema`
  的 `openIndexAt` / `closeIndex`(不開索引),也不 import `System.Process`(不執行任何外部
  程式,那是 #6)。
  **判準只看 import 行,不做全檔字串搜尋**:三個檔案的 Haddock 註解本來就會提到
  `.aapms/` / `readMarker` / `setupHub` 這些名字來說明界線,全檔搜尋會把「文件寫得清楚」
  誤判成「越界」。

  > **2026-08-29 閘門裁決(qa 的 G1)**:本條原文的 (c) 是「**三個檔案都**不 import
  > `Aapms.Store.Marker`」,與同一份 spec 的契約 C 互相矛盾——`VaultRef.vrMarker` 的型別
  > `VaultMarker` 只能從該模組取得,`Types.hs` 從骨架第一天起就是
  > `import Aapms.Store.Marker (VaultMarker)`。開發者裁決把 (c) 拆成 (c) 與 (d),讓這條守住
  > **真正的用意**(本 feature 不做 marker 的探測與讀取),而不是守一個守不住的 import 禁令:
  > 對 `Location.hs` / `Hub.hs` 維持全面禁止,對 `Types.hs` 改成「逐字限定只拿型別」——
  > 只要 import 清單長出任何一個函式名,這條就紅。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」逐條判定,**不是整批全紅**):
>
> - **預期綠**:**L16**(`mkHub` 與五個 selector 互逆)與 **L17 的五條子斷言 (a)–(e) 全部**
>   (import 清單)。兩者驗的都是骨架原文自身就承載的事實——`Hub` 的 record 宣告與各檔的
>   import 行,不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠就退回重寫。**
>   2026-08-29 裁決新增的 (d) 同樣是這一類:`Types.hs:65` 從骨架建檔當下就是
>   `import Aapms.Store.Marker (VaultMarker)`,它**驗的是這一行有沒有被改寬**,不是驗某個
>   未實作的行為。
> - **預期紅**:其餘每一條 law 與每一個 example,它們都打在 `undefined` 的本體上。
>
> 骨架裡唯一不是 `undefined` 的本體是 `mkHub = Hub`(`Types.hs:116`)。這是刻意的:
> `mkHub` 之所以存在,只是因為 A1 決定不匯出 `Hub` 的建構子,它的定義**就是**那個建構子本身,
> 沒有第二種寫法,也不可能「回傳假值」。四個 getter 與 `hubSourceText` 同理——它們是 record
> 語法自動產生的 selector,不是實作。

## Examples

| # | 輸入 | 期望 |
|---|---|---|
| X1 | `AAPMS_HOME = "D:\hub"`,呼叫 `hubLocation` | `hlSource == FromEnv`;`hlPath` 是 `D:\hub` 的絕對化 |
| X2 | `AAPMS_HOME` 未設,呼叫 `hubLocation` | `hlSource == FromPlatformDefault`;`hlPath` 絕對且以 `aapms` 結尾 |
| X3 | `AAPMS_HOME = ""`,呼叫 `hubLocation` | 同 X2(空字串視同未設) |
| X4 | `loc` 指向一個存在但沒有 `config.toml` 的空目錄 | `Left (HubNotFound "<dir>/config.toml")` |
| X5 | `config.toml` 內容 `[[vaults` (TOML 語法錯) | `Left (HubUnreadable fp _)`;`renderWorkspaceError` 含 `fp` |
| X6 | 一列 `[[vaults]]` 只有 `name` / `kind` / `path`,缺 `id` | `Left (HubMalformed fp msg)`;`msg` 含 `id`;`renderWorkspaceError` 含 `fp` |
| X7 | 一列 `[[vaults]]` 的 `kind = "media"` | `Left (HubMalformed fp msg)`;`msg` 含 `kind` 與 `media` |
| X8 | 一列 `[[vaults]]` 的 `path = "assets/lib"`(相對路徑) | `Left (HubMalformed fp msg)`;`msg` 含 `path` 與 `assets/lib` |
| X9 | 一列 `[[vaults]]` 的 `id = "prj-91c0aa12"`(前綴錯) | `Left (HubMalformed fp msg)`;`msg` 含 `vlt` 與 `prj-91c0aa12` |
| X10 | 兩列 `[[vaults]]` 用同一個 `id = "vlt-7f3b2a91"` | `Left (HubMalformed fp msg)`;`msg` 含 `vlt-7f3b2a91` |
| X11 | 「數據」節的測試素材檔 | `Right hub`;`hubVaults` 兩列,依序 `vlt-7f3b2a91`(`alchbees-assets` / `AssetVault` / `C:/Users/User/Documents/alchbees-assets`)與 `vlt-a0c4e1f8`(`liftgame` / `StoryVault` / `D:/story-vaults/liftgame`);`hubProjects` 一列 `prj-91c0aa12` / `Circle` / `D:/games/Circle`;`hubLlm` 是 `Just`,表有 `base_url` / `model` 兩個鍵;`hubTools == ToolsConfig (Just "C:/Program Files/7-Zip/7z.exe")` |
| X12 | 檔案內容只有 `# 空的中樞\n` | `Right hub`;四段分別是 `[]` / `[]` / `Nothing` / `ToolsConfig Nothing` |
| X13 | 檔案含 `[llm]` 但該段下沒有任何鍵 | `hubLlm == Just (LlmSection <空表>)`,且 `/= Nothing` |
| X14 | 「數據」節的測試素材檔,`loadHub` 後立刻 `saveHub` | 檔案位元組與呼叫前相同(含開頭那行註解、`kind = "asset"` 後面的行內註解、`# 故事側` 與全部空白行) |
| X15 | X14 之後再 `loadHub` | 四個 getter 與 X11 的期望逐欄相等 |
| X16 | X11 的 `hub` 做 `upsertVault (VaultEntry (VaultId "vlt-11112222") "shared-lore" StoryVault "E:/vaults/shared")` 再 `saveHub`、再 `loadHub` | `hubVaults` 三列,前兩列與 X11 相同且順序不變,第三列是新增的那一列;檔案中原有的四行註解與全部空白行都還在 |
| X17 | X11 的 `hub` 做 `removeVault (VaultId "vlt-a0c4e1f8")` 再 `saveHub`、再 `loadHub` | `hubVaults` 只剩 `vlt-7f3b2a91` 那一列;`[[projects]]` / `[llm]` / `[tools]` 三段與開頭註解逐字不變 |
| X18 | `removeVault (VaultId "vlt-deadbeef")`(不存在) | 回傳的 `Hub` 與輸入相等 |
| X19 | `loc = HubLocation "C:\\hub" FromEnv` | `configPath loc == "C:\\hub\\config.toml"`;`thumbCacheDir loc == "C:\\hub\\cache\\thumbs"` |
| X20 | `thumbCachePath loc (Sha256 "3f9c1d20…")`(64 位),`loc` 同 X19 | `"C:\\hub\\cache\\thumbs\\3f\\3f9c1d20….png"` |
| X21 | `renderWorkspaceError (HubNotFound "C:/hub/config.toml")` | 非空繁中,含 `C:/hub/config.toml`,含「請」/「改用」/「可以」/「才」之一 |
| X22 | `renderWorkspaceError (VaultSelectorAmbiguous "lore" [e1, e2])` | 含 `lore`、`e1`/`e2` 各自的 `veId` 與 `vePath` 共四個值 |
| X23 | `renderWorkspaceError (VaultKindMismatch (VaultId "vlt-7f3b2a91") AssetVault StoryVault)` | 含 `vlt-7f3b2a91`、`asset`、`story`;**不含** `AssetVault` / `StoryVault` |
| X24 | `renderWorkspaceError (VaultIdCollision (VaultId "vlt-7f3b2a91") "C:/a" "D:/b")` | 三個值都在 |
| X25 | `renderWorkspaceError (InvalidName "   ")` | 含以「」夾住的 `   `;非空 |
| X26 | `renderWorkspaceError (MarkerUnreadable "D:/v" (VaultMarkerMissing "D:/v/.aapms/config.toml"))` | 含 `D:/v` 與 `renderStoreError` 對該 `StoreError` 的輸出 |
| X27 | `saveHub` 到一個**父目錄不存在**的 `loc` | `Left (HubWriteFailed fp _)`;呼叫後該目錄**仍不存在**(本 feature 不建目錄) |

## TodoList

- [ ] T1: `Aapms.Workspace.Types` 的 `renderWorkspaceError`:十六個建構子逐條寫出繁中訊息,
  依「訊息規格」表嵌入每個攜帶的值,每則含一句下一步指示;`renderVaultKind` /
  `renderStoreError` 借用既有的 `render*`,**不重寫**。其餘型別宣告骨架已到位,不再改動
  `dep: -`
- [ ] T2: `Aapms.Workspace.Location.hubLocation`:`lookupEnv "AAPMS_HOME"` → 去空白判非空 →
  `makeAbsolute` + `FromEnv`;否則 `getXdgDirectory XdgConfig "aapms"` + `FromPlatformDefault`
  `dep: -`
- [ ] T3: `Aapms.Workspace.Location` 的三個純衍生路徑(`configPath` / `thumbCacheDir` /
  `thumbCachePath`),分片取 `take 2`、副檔名固定 `.png` `dep: -`
- [ ] T4: `Aapms.Workspace.Hub.loadHub` 的讀檔與 TOML 解析段:`doesFileExist` → `HubNotFound`;
  `readTextFile` 失敗 → `HubUnreadable`;`TOML.decode` 失敗 → `HubUnreadable`;最上層不是表 →
  `HubMalformed` `dep: T1, T3`
- [ ] T5: `loadHub` 的四段解析與合規檢查:依「欄位合規規則」表逐條驗 `[[vaults]]` /
  `[[projects]]` / `[llm]` / `[tools]`,含兩段各自的 id 唯一性;未知鍵與未知頂層段一律容忍;
  成功時以 `mkHub` 收成 `Hub`,原始文字放進 `hubSourceText` `dep: T4`
- [ ] T6: 四個純增刪 `upsertVault` / `removeVault` / `upsertProject` / `removeProject`:只動
  對應的那一段清單,`hubSourceText` 與其餘三段不變 `dep: T1`
- [ ] T7: `Aapms.Workspace.Hub.saveHub` 的序列化:以 `hubSourceText` 為底稿逐段收斂
  (未變動的區塊與註解、空白行、未知段落逐字沿用;新增的列追加到該段末尾;刪除的列整塊移除),
  **未修改時位元組恆等**;寫入走 `atomicWriteText`,失敗包成 `HubWriteFailed`;**不建目錄**
  `dep: T5, T6`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| T1 | L14, L15 / X21–X26 | `test_render_all_constructors_nonempty`、`test_render_embeds_carried_values`、`test_render_no_show_traces` |
| T2 | L1 / X1, X2, X3 | `test_hub_location_from_env`、`test_hub_location_empty_env_falls_back`、`test_hub_location_platform_default` |
| T3 | L2, L3 / X19, X20 | `test_config_path_derivation`、`test_thumb_cache_dir_derivation`、`test_thumb_cache_path_shard_and_prefix` |
| T4 | L4, L5 / X4, X5 | `test_load_hub_not_found`、`test_load_hub_unreadable_on_bad_toml`、`test_load_hub_never_returns_empty_on_missing` |
| T5 | L5, L6, L7 / X6–X13 | `test_load_hub_malformed_missing_id`、`test_load_hub_malformed_bad_kind`、`test_load_hub_malformed_relative_path`、`test_load_hub_malformed_wrong_prefix`、`test_load_hub_malformed_duplicate_id`、`test_load_hub_full_sample`、`test_load_hub_all_sections_absent`、`test_hub_llm_three_states` |
| T6 | L11, L12, L13, L16 / X16, X17, X18 | `test_upsert_vault_appends`、`test_upsert_vault_replaces_in_place`、`test_remove_vault_preserves_order`、`test_remove_vault_absent_is_noop`、`test_project_ops_mirror_vault_ops`、`test_mk_hub_selectors_roundtrip` |
| T7 | L8, L9, L10 / X14, X15, X16, X17, X27 | `test_save_hub_byte_identical_when_unmodified`、`test_load_save_load_field_equal`、`test_save_hub_preserves_comments_after_upsert`、`test_save_hub_preserves_other_sections_after_remove`、`test_save_hub_does_not_create_directory` |
| (全部) | L17 (a)–(e) | `test_types_imports_no_sibling_module`(a)、`test_location_does_not_import_hub`(b)、`test_location_and_hub_never_import_marker`(c)、`test_types_imports_marker_type_only`(d,逐字比對 `import Aapms.Store.Marker (VaultMarker)`)、`test_no_index_or_process_imports`(e)。**五條都只掃 import 行,不做全檔字串搜尋** |

## 待確認假設

- A1: `Hub` 做成**不透明型別**並在 `Types.hs` 額外匯出 `mkHub` 與 `hubSourceText` 兩個
  契約沒有的符號。契約 A 只寫 `data Hub -- 已載入的中樞快照,不可變`,沒說建構子露不露、也沒說
  「保住註解」要靠什麼載體;契約卡把四個 getter 指給本 feature,卻沒指出 `Hub` 的表示法住哪裡。
  - 契約錨點:design.md 契約 A 的 `Hub`;契約 B 的 `hubVaults` / `hubProjects` / `hubLlm` /
    `hubTools`;新增符號 `mkHub`、`hubSourceText`
  - 層級自答:出現在邊界上?**會**(它們是 `Aapms.Workspace.Types` 的匯出清單,`service` 與
    F004 / F005 都看得到);改錯驚動其他模組?**要**(F004 的 `setupHub` 要造空中樞、
    `initVault` 要回新的 `Hub`,拿不到建構入口就動不了)
  - 選項:
    a) **`Hub` 不透明 + `mkHub` + `hubSourceText`(本 spec 採用)**——當下成本:多兩個公開符號,
       文件要說明「為什麼有兩個看起來像內部細節的東西」;三個月後代價:`saveHub` 的保留策略若
       要換載體(例如改存解析後的 TOML 文件樹而不是原始文字),`hubSourceText` 這個名字與型別
       (`Text`)會變成必須維護的舊介面,得走一次契約修訂
    b) **`Hub` 匯出全部欄位(`Hub (..)`)**——當下成本:零,照抄 graph-core `VaultHandle`
       「欄位全部匯出」的先例;三個月後代價:`hubSourceText` 與四段之間「同一次載入」的不變量
       沒有任何東西守,任何人都能 record-update 出「文字說有三個 vault、清單只有一個」的 `Hub`,
       而 `saveHub` 會照著這種快照把使用者的檔案寫壞——這是一個沉默的資料損毀路徑
    c) **`Hub` 定義搬到 `Hub.hs`,`Types.hs` 完全不碰它**——當下成本:違反契約卡「Types 一次寫齊
       契約 A–F 的全部型別」的字面;三個月後代價:最小(`Hub` 的表示法確實只有 `Hub` 模組會碰,
       階段二沒有任何 feature 需要改它,D2 的併發理由對它不成立),但「型別一律去 Types 找」
       這條慣例出現一個例外,後續 feature 每次都要多想一次
  - 傾向:a。理由是它同時滿足「Types 一次寫齊」(字面照做)與「不可變快照的不變量有人守」
    (b 守不住),而 c 的唯一好處是省下兩個符號、代價是破壞剛立下的慣例。依賴的前提:F004 的
    `setupHub` / `initVault` 只需要「造一個 `Hub`」與「對 `Hub` 增刪」兩種能力,不需要看見表示法
    ——這一點已由 design.md「模組間公開介面」的 `Lifecycle → Hub | upsertVault / removeVault +
    saveHub` 那一列佐證(它列的就是這兩種能力,不是欄位存取)。可逆性:**有條件可逆**——改成
    b 只要放寬匯出清單、不動任何呼叫端;改成 c 要動 `Types.hs` 與 `Hub.hs` 的匯出並讓全部消費端
    改 import 來源,而那時 F004–F006 已經寫好,是三個檔案的連帶修改
  - 暫採:a(`Hub` 不透明,`Types.hs` 匯出 `Hub` / `mkHub` / `hubSourceText` / 四個 getter)
    → 影響:若裁決成 b,把 `Types.hs` 匯出清單的 `Hub` 改成 `Hub (..)` 並刪掉 `mkHub`,
    Laws 的 L16 改測欄位;若裁決成 c,`Hub` 的 `data` 宣告與 `mkHub` 整段搬到 `Hub.hs`,
    `Types.hs` 刪掉對 `LlmSection` 以外四段型別的引用,`Hub.hs` 的 import 清單同步縮減

- A2: `Aapms.Workspace.Hub` 除了 design.md 明列的 `upsertVault` / `removeVault` 之外,**補上對稱
  的 `upsertProject` / `removeProject`**。design.md「模組間公開介面」表的 `Projects → aapms-core`
  那一列只寫 `newId PPrj`,沒有寫 Projects 怎麼把新的 `ProjectEntry` 放進 `Hub`;而 F005 的契約卡
  寫「使用……模組間公開介面的 `newId PPrj` 用法(**無新增**)」,代表它預期需要的東西都已存在。
  - 契約錨點:design.md「模組間公開介面」表的 `Lifecycle → Hub`(`upsertVault` / `removeVault`)
    與 `Projects → aapms-core` 兩列;新增符號 `upsertProject`、`removeProject`
  - 層級自答:出現在邊界上?**會**(`Aapms.Workspace.Hub` 的匯出清單,F005 直接呼叫);
    改錯驚動其他模組?**要**(F005 的 `registerProject` / `forgetProject` 必須回新的 `Hub`,
    沒有這兩個函式就只能自己動 `Hub` 的表示法——而 A1 決定表示法不外露)
  - 選項:
    a) **本 feature 現在補上兩個對稱函式(本 spec 採用)**——當下成本:兩個十行以內的純函式與
       兩條 law;三個月後代價:若 F005 最後根本不用它們(例如選擇讓 Projects 自己重建整個 `Hub`),
       就是兩個死碼,而死碼在 `-Wall` 下不會被抓到(它們是匯出的)
    b) **不補,等 F005 自己想辦法**——當下成本:零;三個月後代價:F005 的骨架白名單只有
       `Projects.hs`,它**寫不進** `Hub.hs`,唯一的出路是走 spec-gaps 停下整個 feature、回頭改
       F001 的檔案,而那時 F004 / F006 正在平行跑、`Hub.hs` 已經是「W1 之後沒人再碰」的檔案
       (D2 的前提被打破)
    c) **改成一組泛用的 `withVaults` / `withProjects` 之類的高階函式**——當下成本:要多設計一層
       抽象;三個月後代價:呼叫端要自己寫 list 操作,「追加或就地取代」這條語意會在 Lifecycle
       與 Projects 各實作一次,兩邊漂移時沒有任何測試會紅
  - 傾向:a。理由是 b 的失敗模式(階段二平行波次被單一檔案的擁有權卡死)正是 D2 想避免的事,
    而 a 的失敗模式(兩個死碼)代價極小且事後刪得掉。依賴的前提:`[[projects]]` 的增刪語意與
    `[[vaults]]` 相同(以 id 為鍵、追加或就地取代、保序)——design.md 契約 B 對 `peId` 寫的
    「中樞內唯一;鍵」與對 `veId` 寫的完全同構,這個前提成立。可逆性:**可逆**——若閘門認為
    不該有,刪掉兩個函式與兩條 law 即可,沒有任何既有呼叫端
  - 暫採:a(`Hub.hs` 提供四個純增刪函式)→ 影響:若裁決不補,刪掉 `upsertProject` /
    `removeProject` 與 L13,並要在指派 F005 時把 `Hub.hs` 加進它的寫入白名單

- A3: `loadHub` 對 `[[vaults]].name` / `[[projects]].name` 的**空字串一律回 `HubMalformed`**。
  契約卡的驗收標準 3 只點名「`id` 缺、`kind` 不是 asset/story、路徑非絕對」三種不合規,沒有提
  name;但契約 B 的欄位表對 `veName` / `peName` 都寫了值域「非空」。
  - 契約錨點:design.md 契約 B 的 `VaultEntry.veName` 與 `ProjectEntry.peName` 的值域欄;
    契約 F 的 `HubMalformed`、`InvalidName`
  - 層級自答:出現在邊界上?**會**(它決定一份手寫的中樞檔是被接受還是被拒絕,那是 system.md
    第 6 節的對外檔案契約);改錯驚動其他模組?**要**(#2 的 `lookupSelector` 以 `veName` 比對,
    空名稱會讓「`--vault ''`」這種輸入的行為變成未定義)
  - 選項:
    a) **空 name 即 `HubMalformed`(本 spec 採用)**——當下成本:兩條額外的檢查與一條 example;
       三個月後代價:若使用者真的想暫時留一個沒名字的 vault,整份中樞都載不起來,而錯誤訊息
       指的是「name 不得為空」,使用者改得掉——代價可控
    b) **空 name 照收,由 #2 的 selector 比對自然地比不到**——當下成本:零;三個月後代價:
       契約 B 白紙黑字的「非空」變成沒人守的註解,而 `veName` 是要印給使用者看的欄位,
       `doctor` 會印出一列空白;更糟的是寫入路徑的 `InvalidName`(F004 對名稱去空白後長度 ≥ 1)
       與讀取路徑不對稱——工具自己寫不出來的檔案,工具讀得進來
  - 傾向:a。理由是「讀寫兩端對同一個欄位用同一套值域」是可手寫檔案能維持一致的前提,b 造成的
    不對稱會在 `vault add` 之類的往返操作上冒出來。可逆性:**可逆**(放寬檢查比收緊容易,
    收緊會讓既有的檔案突然變非法,放寬不會)
  - 暫採:a → 影響:若裁決成 b,刪掉合規表的兩列 name 檢查與對應的 example,`veName` / `peName`
    的值域註解要同步改成「可為空」

## 實作備註

### 自裁記錄(實作層級,不上閘門)

- **S1(未知鍵與未知頂層段一律容忍且保留)**:中樞是 ADR-017 決策二明訂「可手寫」的檔案,
  對使用者自己加的鍵、以及未來版本新增的段落嚴格拒收,會讓新版寫出的檔案被舊版判成壞檔;
  而 `saveHub` 本來就以原始文字為底稿,保留是它的自然行為。不影響任何簽名,只影響 `loadHub`
  的內部分支。
- **S2(重複 id 即 `HubMalformed`)**:契約 B 對 `veId` / `peId` 都寫「中樞內唯一」,而
  graph-core 契約 G 對重複 `vmId` 的處置是「不能靜默去重帶過」(`VaultIdCollision`)。中樞
  沿用同一個立場:身分不確定時任何以 id 為鍵的操作都是不確定的。用既有的 `HubMalformed`,
  不新增建構子。
- **S3(`saveHub` 不建立父目錄)**:契約卡「明確不做」寫「不建立任何目錄或檔案(那是
  `setupHub`)」。`saveHub` 寫出 `config.toml` 本身是契約 A 的職責,但**目錄**的建立留給 F004;
  父目錄不存在時 `atomicWriteText` 自然失敗,原樣包成 `HubWriteFailed`。
- **S4(`hubLocation` 的平台預設用 `getXdgDirectory XdgConfig`,不自己寫平台分支)**:
  `directory` 的這個函式在 Windows 回 `%APPDATA%\<name>`、其他平台回 XDG,與契約 A 的兩句話
  逐字對應;自己寫 `#ifdef` 分支等於重做一次已經被驗證的邏輯。
- **S5(`Hub` 與 `WorkspaceError` derive `Show` / `Eq`)**:兩者都要進 hspec 的失敗訊息與
  `shouldBe`;`LlmSection` 的 `Eq` 走 `deriving newtype`(`TOML.Value` 已有 `Eq`)。
  沿用 graph-core 全套型別的做法。

### 給編排者的注意事項

- 三個骨架檔案已建立並**編譯通過、零警告**(`cabal build aapms-workspace`,GHC 9.14.1;
  library 與 test-suite 兩個元件都過)。`aapms-workspace.cabal` **一行未動**,不需要新增任何
  套件依賴。
- 契約 F 的建構子數目在 design.md 內部不一致(散文「十五」vs 列舉十六),見「對應的 Level 2
  契約 › 契約 F」的對帳說明。建議把契約卡與 build-log D2 的「十五個建構子」改成「十六個」。
- `Aapms.Workspace.Location.configPath` 與 `Aapms.Store.Marker.configPath` 同名不同義
  (中樞的 vs vault 的)。F002 / F004 同時要用兩者時必須 qualified import;建議在指派那兩個
  feature 時把這一句放進 prompt。
