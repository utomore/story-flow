---
id: F001
type: feature
title: service-env-and-scope
description: "Env(中樞 + 註冊表 + handle 快取 + 全域鎖)、openEnv / runService / closeEnv / withEnv、三個範圍取得口、ServiceError 前四個建構子與 errorCode / renderServiceError"
status: open
created: 2026-08-30
updated: 2026-08-30
depends-on: [graph-core/F001, graph-core/F002, graph-core/F005, graph-core/F009, workspace/F001, workspace/F003]
related-adr: [ADR-006, ADR-013, ADR-014, ADR-015, ADR-017]
related-feature: []
---

# F001: 執行環境、範圍取得與錯誤語彙骨架(service-env-and-scope)

## 功能概述

`aapms-service` 的地基:一次執行期間的資源怎麼開、怎麼被鎖保護、怎麼關,以及
「這道指令對哪些 vault 生效」怎麼從 `aapms-workspace` 的裁決變成開好的把手。負責模組是
design.md「內部模組劃分」的 **Types**(只建錯誤語彙骨架)、**Monad**、**Scope** 三個。

本 feature 之後,`Env` 開得起來、錯誤語彙立得住、三條資料流管線的**共用前段**可以跑;
F002 起的每一個操作都只是「拿到 handle 之後做什麼」。

**驗收標準**(逐字抄自契約卡):

1. `openEnv` 成功回傳後**尚未開任何 vault 索引**(可觀察:任一 vault 的 `index.db` 檔案 mtime
   不變,且該 vault 的 `.aapms/` 沒有新增暫存檔) — 觀察點:契約 A 的 `openEnv`
2. 中樞載不起來或型別註冊表載不起來時 `openEnv` 回 `Left`,**不回一個空的 `Env`**;錯誤分別是
   `WorkspaceFailed` 與 `RegistryUnavailable` / `RegistryLoadFailed` — 觀察點:契約 A 的
   `openEnv`、契約 F 的四個建構子
3. 同一個 `Env` 上對同一個 vault 連續兩次 `withRead`,第二次**不再呼叫 `openVault`**(可觀察:
   索引檔的存取次數不增,或以一個只會成功一次的假路徑替換後第二次仍成功) — 觀察點:模組間
   公開介面的 `handleFor`
4. `closeEnv` 後所有開過的 handle 都被關閉:同一目錄可立即被另一個 `Env` 開啟且無鎖檔殘留 —
   觀察點:契約 A 的 `closeEnv`
5. 兩個並發的 `runService` 不會交錯:對同一個 `Env` 同時跑兩個寫入,最終 `revision` 恒為 +2 且
   兩次都成功或其中一次回 `RevisionConflict`,**不會出現索引與檔案不一致** — 觀察點:契約 A 的
   `runService`、契約 F 的 `RevisionConflict`
6. `errorCode` 對每個建構子都回一個非空、snake_case、**不含產品前綴**的字串,且兩兩相異 —
   觀察點:契約 F 的 `errorCode`
7. `renderServiceError (StoreFailed e)` 逐字等於 graph-core 的 `renderStoreError e`;
   `WorkspaceFailed` 同理委派 — 觀察點:契約 F 的 `renderServiceError`

**驗收標準 5 在本 feature 只能驗到一半**,而且這是刻意的:`RevisionConflict` 與「寫入」都屬
F004(node-write),本 feature 連 `Revision` 都沒有。本 feature 交付的是**互斥本身**——兩個並發的
`runService` 的臨界區恒不重疊(L11);「所以最終 revision 是 +2」是 F004 接上寫入之後才驗得到的
推論。這一點在「1-to-1 測試對照表」逐條標了出來。

**明確不做**(逐字抄自契約卡):不實作任何業務操作(F002 起);不做業務驗證(F004);不決定
HTTP 狀態碼(`shell`)。追加三條:不解讀 selector 字串(`aapms-workspace` 的裁決,design.md
「明確不做 › 參數解析」);不判斷 ATTACH 上限(graph-core 的 `Aapms.Store.MultiVault`);
不定義任何 View 或請求型別(那些隨各自的 feature 進 Types)。

## 相依性

`depends-on: [graph-core/F001, graph-core/F002, graph-core/F005, graph-core/F009, workspace/F001,
workspace/F003]`——design.md「功能規劃」階段一表 #1 的「依賴」欄是 `-`(本子系統內無前置),
但**跨子系統**的六個來源都是本 feature 的呼叫對象,依「使用到的既有串接介面」表逐列反推得出。

兩個下層子系統都已交付:`graph-core` 9/9 `done`、`workspace` 6/6 `done`,本 feature 用到的
**三十一個符號**全部打開原始碼讀到簽名原文(見下表),沒有一條是依文檔的介面約定推的。

本子系統內:F002–F008 全部反過來依賴本 feature。

## 對應的 Level 2 契約

### 契約 A(全部四個函式 + 兩個型別)

| design.md 契約 A 原文 | 本 feature |
|---|---|
| `data Env` | 交付。**不透明**——design.md 對它沒有列任何欄位,而同一份文件裡每個要露欄位的型別都逐欄列了出來 |
| `newtype ServiceM a` | 交付。不透明,建構子不匯出 |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError Env)` | 交付,簽名逐字 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | 交付,簽名逐字 |
| `closeEnv :: Env -> IO ()` | 交付,簽名逐字 |
| `withEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)` | 交付,簽名逐字 |

### 契約 F(骨架:四個建構子 + 兩個函式)

| design.md 契約 F 原文 | 本 feature |
|---|---|
| `StoreFailed StoreError` | 交付,酬載逐字 |
| `WorkspaceFailed WorkspaceError` | 交付,酬載逐字 |
| `RegistryUnavailable RegistryError` | 交付,酬載逐字(A1 已裁決為 a,編排者已回寫 design.md) |
| `RegistryLoadFailed RegistryError` | 交付,酬載逐字(原文的 `[LoadError]` 在樹上不存在;A1 已裁決為 a,編排者已回寫 design.md) |
| `errorCode :: ServiceError -> Text` | 交付,簽名逐字 |
| `renderServiceError :: ServiceError -> Text` | 交付,簽名逐字 |

其餘九個建構子(`ValidationFailed` / `UnknownType` / `DanglingLinkTarget` / `LinkTargetOutOfScope` /
`LevelTreeInvalid` / `RevisionConflict` / `LogicalNameTaken` / `AmbiguousRef` / `NodeNotFound`)
**不在本 feature**,依契約卡「建構子先做」那四個與 build-log 配號表的「後續波次由編排者在該波的
白名單裡明確授權」。

### 模組間公開介面(design.md 表裡本 feature 要交付的四列)

| design.md 原文 | 本 feature |
|---|---|
| `withRead :: (VaultSet -> [VaultRef] -> ServiceM a) -> ServiceM a` | 交付,簽名逐字 |
| `withWrite :: (VaultHandle -> VaultSet -> ServiceM a) -> ServiceM a` | 交付,簽名逐字 |
| `withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a` | 交付,簽名逐字 |
| `handleFor :: VaultRef -> ServiceM VaultHandle` | 交付,簽名逐字;**本套件唯一開 handle 的地方** |

另外九個介面(八個 `Env` 存取器 + `indexIssuesFor`,加上三個錯誤 helper)在 W1 閘門(2026-08-30)
裁決為接受(A2 / A3),編排者已把 `indexIssuesFor` 與新的一列 **`Machine / Read / Write → Monad`**
回寫進 design.md 的「模組間公開介面」表——本段與 design.md 現在一致,理由與代價仍留在 A2 / A3。

**W1 交付後的定向修訂(2026-08-30)再加一列**:`finallyService :: ServiceM a -> ServiceM b -> ServiceM a`,
同樣屬 **`Monad → 其餘模組`**(`Scope` 是第一個呼叫端,F002–F008 只要在 `ServiceM` 裡持有需要釋放的
資源就會用到)。它取代的是 W1 impl 自己補上的 `deriving newtype instance MonadError ServiceError ServiceM`——
來由、歸因與裁決見「實作備註」,守衛是 **L25**。這一列**尚未**進 design.md 的「模組間公開介面」表,
建議編排者比照 `indexIssuesFor` 回填。

## 實作方式

### 相依性查證(2026-08-30 打開 `core/src/`、`types/src/`、`store/src/`、`workspace/src/` 讀到的實況)

三件與 design.md 不同、必須先講清楚的事實:

1. **`LoadError` 不存在。** 註冊表的載入層只有一個錯誤型別 `RegistryError`
   (`core/src/Aapms/Core/Registry.hs:251`,14 個建構子,其中 `RegistryErrors [RegistryError]`
   本身就是「彙整多個問題」的那一格),而 `loadRegistry` 回的是**單一個** `RegistryError`,
   不是清單。契約 F 的 `RegistryLoadFailed [LoadError]` 照抄會編不過。→ A1
2. **`openVault` 一併回 `[IndexIssue]`**
   (`store/src/Aapms/Store/Marker.hs:207`)。契約的 `handleFor` 只回 `VaultHandle`,而快取命中時
   第二次呼叫不會再產生這份清單;F002 的 `viIssues` 欄要得到它,只能在第一次開啟時存起來。→ A3
3. **`openVault` 收 `TypeRegistry` 當第一參數**(graph-core D9:「先載入註冊表、再開 vault」這個
   順序用型別釘死)。這正好與「`openEnv` 載入註冊表、之後才有人開 vault」一致,不需要任何調整。

另外兩件確認過、**不需要**動契約的:

- `resolveRead` / `resolveWrite` / `resolvePipeline` 的三個回傳型別各自帶 `*Issues`
  欄,而三個 `with*` 的簽名(design.md 原文)都沒有 `[ScopeIssue]`。這不是遺漏:讀取路徑上
  `ScopeIssue` 只要「不中止」就夠(design.md 契約 D),而要**呈現**它們的
  `workspaceDoctor` / `vaultCheck`(F002)走本機管線,直接呼叫
  `Aapms.Workspace.Lifecycle.checkVaults :: Hub -> IO [ScopeIssue]`
  (`workspace/src/Aapms/Workspace/Lifecycle.hs:328`),不經過 Scope。
- `closeVaultSet` **不關閉任何 `VaultHandle`**(`store/src/Aapms/Store/MultiVault.hs:190-197`
  的 haddock 明文),所以 `with*` 收尾關 `VaultSet` 不會把快取裡的 handle 一起關掉。這條是
  L14 成立的前提。

### 模組配置

三個檔案,依賴方向是線性的一段:`Types ← Monad ← Scope`,沒有回頭邊。

| 檔案 | 職責 | 依賴 |
|---|---|---|
| `Aapms/Service/Types.hs` | `ServiceError` + `errorCode` + `renderServiceError` | 只有下層子系統的型別;**不 import 本套件任何模組** |
| `Aapms/Service/Monad.hs` | `Env` / `ServiceM` / 生命週期 / 存取器 / handle 快取 / 錯誤 helper | Types |
| `Aapms/Service/Scope.hs` | `withRead` / `withWrite` / `withPipeline` | Monad(以及經由它的 Types) |

本套件**不設門面模組**(build-log D5),三個模組全部 `exposed`。

### `Env` 為什麼不透明

`Env` 的建構子與欄位不匯出,與 `aapms-workspace` 的 `Hub` 同一個道理:

- **不變量**:中樞快照、型別註冊表、命名詞彙表、註冊表來源四者必須來自**同一次 `openEnv`**。
  允許外部逐欄拼裝就是允許拼出一個「中樞是 A、註冊表是 B」的執行環境,而那不會有任何編譯錯誤
- **可變狀態**:handle 快取、`IndexIssue` 表、中樞快照三格都是可變的,鎖是保護它們的東西。直接
  露出欄位等於把「誰負責拿鎖」交給呼叫端記得,而漏拿不會有編譯錯誤

證據在 design.md 自己:契約 A 把它寫成 `data Env` 而不列欄位,而同一份文件裡 `NodeView` /
`VaultView` / `DoctorView` / `SetupView` / `PurgeView` 每一個都逐欄列了出來。

### `Env` 的欄位結構

| 欄位 | 型別 | 可變 | 語意 |
|---|---|---|---|
| `envHubLocation` | `HubLocation` | 否 | 中樞根目錄與「這個位置怎麼決定的」。`DoctorView` 的 `dvHubPath` / `dvHubSource` 兩欄的來源 |
| `envHubRef` | `IORef Hub` | **是** | 中樞快照。`saveHub` 之後必須重新載入——`Hub` 是不可變值,寫回檔案不會改到手上這一份 |
| `envRegistry` | `TypeRegistry` | 否 | 型別註冊表;型別宣告在一次執行期間不會變 |
| `envNaming` | `NamingVocab` | 否 | 命名文法詞彙表。與上一格是 `loadRegistry` **同一次呼叫**的兩個回傳值 |
| `envRegistrySource` | `RegistrySource` | 否 | 三層定位的哪一層。`DoctorView` 的 `dvRegistry` 欄的來源 |
| `envSelector` | `Maybe Text` | 否 | `--vault` 的原始字串,**本層不解讀** |
| `envCwd` | `FilePath` | 否 | 向上探測的起點,絕對路徑 |
| `envHandles` | `IORef (Map VaultId VaultHandle)` | **是** | handle 快取。鍵是 marker 的 `VaultId`,**不是路徑**(ADR-017:vault 的身分就是 marker 裡的 id) |
| `envIndexIssues` | `IORef (Map VaultId [IndexIssue])` | **是** | 每個 vault 第一次被開啟時 `openVault` 一併回的清單(A3) |
| `envLock` | `MVar ()` | — | **全域一把**互斥鎖 |

### 鎖在 `runService` 上,不在別的地方

design.md 契約 A 給了三個理由(`Connection` 非執行緒安全、handle 快取是可變狀態、「先寫檔再更新
索引」在請求之間也要原子),三個合起來只指向一個位置:**一次 `runService` = 一個臨界區**。放在
`handleFor` 只保護第二件事,放在各操作則每個新操作都要記得包一層,而漏包不會有編譯錯誤——那正是
design.md 不可逆決定第三列否決「鎖留在 `AppState`」的同一條理由。

代價已知且刻意接受:**巢狀 `runService` 會死結**。契約沒有任何一條需要巢狀(三條資料流管線裡
`Env` 只被建立一次、`runService` 也只跑一次),所以**不為它付執行期偵測的成本**——不做重入計數、
不換成可重入鎖、不在 `ServiceM` 裡藏一個「已經在臨界區了」的旗標。

但「不支援」不等於「沒有防線」。W1 閘門(2026-08-30)的裁決是:整個 `runService` 當臨界區照收,
**另補一條靜態的 law 擋住那個坑**——**L23**,對 `service/src/` 的原始碼文字斷言「`Aapms/Service/Monad.hs`
以外的模組一個字都不准提到 `runService`」。理由是 F002–F008 六個 feature 都會在 `ServiceM` 裡組合
別的操作,而巢狀呼叫**編得過、跑起來才掛**,遲早有人踩;靜態斷言在編譯期之後、跑測試時就紅,
而且不必付執行期的成本。L11 只驗兩個並發的 `runService` 不重疊,擋不到巢狀——兩條 law 管的是
不同的事,不能互相取代。

### `openEnv` 的資料流

```text
openEnv sel cwd
  → hubLocation                    -- 解析中樞位置(env var → 平台預設)
  → loadHub loc                    -- 失敗 → Left (WorkspaceFailed e),不回空中樞
  → locateRegistry                 -- 失敗 → Left (RegistryUnavailable e)
  → loadRegistry dir               -- 失敗 → Left (RegistryLoadFailed e)
  → 建三個空的可變格(Hub 的 IORef、handle 快取、IndexIssue 表)與一把新的 MVar
  → Right Env
```

順序固定,**任一步失敗即失敗**。四步都不碰任何 vault 目錄:`hubLocation` 只算路徑、`loadHub` 只讀
中樞的 `config.toml`、註冊表那兩步只碰 `types/registry/`。這就是驗收標準 1 的成立方式——不是
「記得不要開」,而是**這條路徑上沒有任何一步會開**。

### `handleFor` 的資料流

```text
handleFor ref
  → 查 envHandles(鍵:vmId (vrMarker ref))
     命中 → 直接回,不碰檔案系統
     未命中 → openVault registry (vrPath ref)
              失敗 → StoreFailed 短路
              成功 (h, issues) → 兩張表各放一筆 → 回 h
```

**這是本套件唯一開 vault handle 的地方。** 多一個開法就多一條不會進快取、也不會被 `closeEnv`
關掉的洩漏路徑,而在 Windows 上一條沒關的 SQLite 連線就足以讓整個 vault 目錄刪不掉。

### 三個 `with*` 的資料流

```text
withRead k
  → askHub / askSelector
  → resolveRead hub sel                       -- Left → WorkspaceFailed 短路
  → mapM handleFor (rsVaults scope)           -- 逐一取 handle(走快取)
  → openVaultSet handles                      -- Left → StoreFailed 短路
  → k vaultSet (rsVaults scope)               -- 結束時(含短路)closeVaultSet,走 finallyService

withWrite k
  → askHub / askSelector / askCwd
  → resolveWrite hub sel cwd                  -- Left(含 NoWriteTarget)→ WorkspaceFailed 短路,k 不被呼叫
  → handleFor (wsTarget scope)
  → mapM handleFor (wsRead scope) → openVaultSet
  → k targetHandle vaultSet                   -- 結束時 closeVaultSet

withPipeline kind k
  → askHub / askSelector
  → resolvePipeline hub kind sel              -- Left → WorkspaceFailed 短路
  → mapM handleFor (psRuns scope)
  → k handles                                 -- 不組 VaultSet
```

三條的共同性質:`ScopeIssue` **不中止**(它們留在 `resolve*` 的回傳值裡,本層不轉成錯誤);
`VaultSet` 由本層開、本層關;`VaultHandle` 由 `Env` 持有,本層不關。

**「結束時(含短路)關掉 `VaultSet`」怎麼做得到**:`ServiceM` 只有 `Functor` / `Applicative` /
`Monad` / `MonadIO` 四個實例,`Scope` 拿不到任何攔截 `throwService` 短路的能力——這是刻意的
(不可逆決定第一列:`ServiceM` 不透明)。收尾因此走 `Monad` 匯出的 **`finallyService`**:拆
`ServiceM` 的 newtype 這件事只發生在 `Monad.hs` 內部,`Scope` 與 F002–F008 只看得到一個
登記過的名字。**不**給 `ServiceM` derive 一個 `MonadError ServiceError` 實例:類別方法不進匯出
清單,derive 一個實例等於讓每一個 import `Monad` 的模組都自動拿到 `catchError` / `throwError`
兩條沒登記在介面表上的對外 API,而 `throwError` 還是一條繞過 `throwService` 的拋出路徑。
這條界線由 **L25** 靜態守住。

## 使用到的既有串接介面

每一列的簽名都是 2026-08-30 打開來源檔案讀到的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `hubLocation :: IO HubLocation` | `workspace/src/Aapms/Workspace/Location.hs:33` | `workspace/F001` | `openEnv` 第一步 |
| `loadHub :: HubLocation -> IO (Either WorkspaceError Hub)` | `workspace/src/Aapms/Workspace/Hub.hs:81` | `workspace/F001` | `openEnv` 第二步、`reloadHub` |
| `data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }` | `workspace/src/Aapms/Workspace/Types.hs:72` | `workspace/F001` | `Env` 欄位 |
| `data Hub`(建構子不匯出;getter `hubVaults` / `hubProjects` / `hubLlm` / `hubTools`) | `workspace/src/Aapms/Workspace/Types.hs:91` | `workspace/F001` | `Env` 欄位 |
| `data WorkspaceError`(21 個建構子) | `workspace/src/Aapms/Workspace/Types.hs:289` | `workspace/F001` | `ServiceError` 酬載 |
| `renderWorkspaceError :: WorkspaceError -> Text` | `workspace/src/Aapms/Workspace/Types.hs:352` | `workspace/F001` | `renderServiceError` 委派 |
| `data VaultRef = VaultRef { vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }` | `workspace/src/Aapms/Workspace/Types.hs:163` | `workspace/F001` | `handleFor` 的參數、`withRead` 交出去的清單 |
| `resolveRead :: Hub -> Maybe Text -> IO (Either WorkspaceError ReadScope)` | `workspace/src/Aapms/Workspace/Scope.hs:81` | `workspace/F003` | `withRead` |
| `resolveWrite :: Hub -> Maybe Text -> FilePath -> IO (Either WorkspaceError WriteScope)` | `workspace/src/Aapms/Workspace/Scope.hs:116` | `workspace/F003` | `withWrite` |
| `resolvePipeline :: Hub -> VaultKind -> Maybe Text -> IO (Either WorkspaceError PipelineScope)` | `workspace/src/Aapms/Workspace/Scope.hs:157` | `workspace/F003` | `withPipeline` |
| `locateRegistry :: IO (Either RegistryError (FilePath, RegistrySource))` | `types/src/Aapms/Types/Loader.hs:92` | `graph-core/F002` | `openEnv` 第三步 |
| `loadRegistry :: FilePath -> IO (Either RegistryError (TypeRegistry, NamingVocab))` | `types/src/Aapms/Types/Loader.hs:148` | `graph-core/F002` | `openEnv` 第四步 |
| `data RegistrySource = FromEnv \| BesideExecutable \| FromDataDir` | `types/src/Aapms/Types/Loader.hs:67` | `graph-core/F002` | `Env` 欄位、`DoctorView` 的來源 |
| `data RegistryError`(14 個建構子) | `core/src/Aapms/Core/Registry.hs:251` | `graph-core/F002` | `ServiceError` 酬載(A1) |
| `renderRegistryError :: RegistryError -> Text` | `core/src/Aapms/Core/Registry.hs:280` | `graph-core/F002` | `renderServiceError` 委派 |
| `newtype TypeRegistry = TypeRegistry (Map TypeKey TypeDecl)` | `core/src/Aapms/Core/Registry.hs:110` | `graph-core/F002` | `Env` 欄位、`openVault` 的第一參數 |
| `data NamingVocab = NamingVocab { nvKinds, nvDomains, nvStates :: [Segment] }` | `core/src/Aapms/Core/Naming.hs:116` | `graph-core/F002` | `Env` 欄位 |
| `listTypes :: TypeRegistry -> [TypeDecl]` | `core/src/Aapms/Core/Registry.hs:159` | `graph-core/F002` | X5c 的觀察口(`TypeRegistry` 不透明,沒有 `Eq`) |
| `openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))` | `store/src/Aapms/Store/Marker.hs:207` | `graph-core/F005` | `handleFor` 的未命中路徑 |
| `closeVault :: VaultHandle -> IO ()` | `store/src/Aapms/Store/Marker.hs:217` | `graph-core/F005` | `closeEnv` |
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection, vhRegistry :: TypeRegistry }` | `store/src/Aapms/Store/Marker.hs:75` | `graph-core/F005` | 快取的值、三個 `with*` 交出去的東西 |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:59` | `graph-core/F005` | 快取的鍵(`vmId`) |
| `data StoreError`(29 個建構子) | `store/src/Aapms/Store/Error.hs:29` | `graph-core/F005` | `ServiceError` 酬載 |
| `renderStoreError :: StoreError -> Text` | `store/src/Aapms/Store/Error.hs:91` | `graph-core/F005` | `renderServiceError` 委派 |
| `data VaultKind = AssetVault \| StoryVault` | `store/src/Aapms/Store/Schema.hs:63` | `graph-core/F005` | `withPipeline` 第一參數 |
| `data IndexIssue`(`SchemaRebuilt` / `ParseFailed` / …) | `store/src/Aapms/Store/Schema.hs:85` | `graph-core/F005` | `indexIssuesFor` 的回傳(A3) |
| `data VaultSet`(不透明) | `store/src/Aapms/Store/MultiVault.hs:119` | `graph-core/F009` | `withRead` / `withWrite` 交出去的東西 |
| `openVaultSet :: [VaultHandle] -> IO (Either StoreError VaultSet)` | `store/src/Aapms/Store/MultiVault.hs:172` | `graph-core/F009` | `withRead` / `withWrite` |
| `closeVaultSet :: VaultSet -> IO ()` | `store/src/Aapms/Store/MultiVault.hs:196` | `graph-core/F009` | `withRead` / `withWrite` 收尾;**不關 handle** |
| `vaultSetIds :: VaultSet -> [VaultId]` | `store/src/Aapms/Store/MultiVault.hs:203` | `graph-core/F009` | L12 / L13 的唯一觀察口 |
| `newtype VaultId = VaultId Text` | `core/src/Aapms/Core/Id.hs:148` | `graph-core/F001` | 快取的鍵 |

## 新增的介面

### `service/src/Aapms/Service/Types.hs`

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data ServiceError = StoreFailed StoreError \| WorkspaceFailed WorkspaceError \| RegistryUnavailable RegistryError \| RegistryLoadFailed RegistryError` | 本子系統的唯一錯誤型別;四個建構子各捧著下層的錯誤原件 | `service/src/Aapms/Service/Types.hs:36` |
| `errorCode :: ServiceError -> Text` | 給機器的穩定識別碼 | `service/src/Aapms/Service/Types.hs:60` |
| `renderServiceError :: ServiceError -> Text` | 給人的繁中訊息 | `service/src/Aapms/Service/Types.hs:72` |

### `service/src/Aapms/Service/Monad.hs`

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data Env` | 一次執行期間的全部資源;不透明 | `service/src/Aapms/Service/Monad.hs:85` |
| `newtype ServiceM a` | 業務操作的執行 monad;不透明,實例**只有** `Functor` / `Applicative` / `Monad` / `MonadIO` 四個(L25 靜態守住) | `service/src/Aapms/Service/Monad.hs:126` |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError Env)` | 建立執行環境:載入中樞與型別註冊表,不開任何 vault 索引 | `service/src/Aapms/Service/Monad.hs:139` |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | 在一個 `Env` 上跑一段業務操作,全程獨占該 `Env` | `service/src/Aapms/Service/Monad.hs:148` |
| `closeEnv :: Env -> IO ()` | 關閉這個 `Env` 開過的全部 vault handle;冪等 | `service/src/Aapms/Service/Monad.hs:156` |
| `withEnv :: Maybe Text -> FilePath -> (Env -> IO a) -> IO (Either ServiceError a)` | `openEnv` 與 `closeEnv` 的成對包裝 | `service/src/Aapms/Service/Monad.hs:163` |
| `askHubLocation :: ServiceM HubLocation` | 取中樞根目錄與它的來源 | `service/src/Aapms/Service/Monad.hs:167` |
| `askHub :: ServiceM Hub` | 取目前的中樞快照 | `service/src/Aapms/Service/Monad.hs:171` |
| `reloadHub :: ServiceM Hub` | 從磁碟重新載入中樞、換掉快照,並回傳新的那一份 | `service/src/Aapms/Service/Monad.hs:180` |
| `askRegistry :: ServiceM TypeRegistry` | 取型別註冊表 | `service/src/Aapms/Service/Monad.hs:184` |
| `askNaming :: ServiceM NamingVocab` | 取命名文法詞彙表 | `service/src/Aapms/Service/Monad.hs:188` |
| `askRegistrySource :: ServiceM RegistrySource` | 取註冊表是從哪一層定位到的 | `service/src/Aapms/Service/Monad.hs:192` |
| `askSelector :: ServiceM (Maybe Text)` | 取 `--vault` 的原始字串 | `service/src/Aapms/Service/Monad.hs:196` |
| `askCwd :: ServiceM FilePath` | 取向上探測的起點 | `service/src/Aapms/Service/Monad.hs:200` |
| `handleFor :: VaultRef -> ServiceM VaultHandle` | 取一個 vault 的 handle;同一個 vault 在一次執行期間**只被開啟一次** | `service/src/Aapms/Service/Monad.hs:211` |
| `indexIssuesFor :: VaultId -> ServiceM [IndexIssue]` | 取某個 vault 被開啟時一併回報的索引問題清單 | `service/src/Aapms/Service/Monad.hs:218` |
| `throwService :: ServiceError -> ServiceM a` | 以一個 `ServiceError` 短路目前的 `ServiceM` | `service/src/Aapms/Service/Monad.hs:222` |
| `liftStore :: IO (Either StoreError a) -> ServiceM a` | 跑一個 graph-core 的動作,`Left` 原樣包成 `StoreFailed` | `service/src/Aapms/Service/Monad.hs:226` |
| `liftWorkspace :: IO (Either WorkspaceError a) -> ServiceM a` | 跑一個 `aapms-workspace` 的動作,`Left` 原樣包成 `WorkspaceFailed` | `service/src/Aapms/Service/Monad.hs:231` |
| `finallyService :: ServiceM a -> ServiceM b -> ServiceM a` | 跑第一個動作;無論它正常結束、以 `throwService` 短路、還是拋出 IO 例外,第二個動作(收尾)都恰好被執行一次,然後第一個動作的結果原樣傳出——短路原樣再短路、例外原樣重拋;第二個動作的回傳值被丟棄。參數順序同 `Control.Exception.finally` | `service/src/Aapms/Service/Monad.hs:335` |

### `service/src/Aapms/Service/Scope.hs`

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `withRead :: (VaultSet -> [VaultRef] -> ServiceM a) -> ServiceM a` | 取得讀取範圍:交出一個開好的 `VaultSet` 與它涵蓋的 vault 清單 | `service/src/Aapms/Service/Scope.hs:48` |
| `withWrite :: (VaultHandle -> VaultSet -> ServiceM a) -> ServiceM a` | 取得寫入範圍:交出寫入目標的 handle 與讀取範圍的 `VaultSet` | `service/src/Aapms/Service/Scope.hs:60` |
| `withPipeline :: VaultKind -> ([VaultHandle] -> ServiceM a) -> ServiceM a` | 取得管線範圍:交出符合該 kind 的每個 vault 的 handle | `service/src/Aapms/Service/Scope.hs:71` |

## 數據

### `errorCode` 的四個值

規則只有一條:**`code` 是建構子名的 snake_case**。寫成規則而不是一份對照表,是為了讓 F003–F006
加建構子時不必回頭問「這個該叫什麼」——`code` 因此不是一份要維護的表,而是建構子名的函數。
(design.md 對 `code` 只規定「snake_case、不帶產品前綴、兩兩相異」,沒有指定字串。)

| 建構子 | `errorCode` | 什麼時候出現 |
|---|---|---|
| `StoreFailed` | `store_failed` | graph-core 的落地或索引失敗 |
| `WorkspaceFailed` | `workspace_failed` | 中樞 / 探測 / 範圍裁決失敗(含 `NoWriteTarget`) |
| `RegistryUnavailable` | `registry_unavailable` | 型別註冊表三層都定位不到 |
| `RegistryLoadFailed` | `registry_load_failed` | 註冊表目錄找到了,內容不合規 |

四個字串均為非空、只含 `[a-z_]`、不以 `story_flow` 或 `aapms` 開頭、兩兩相異。

### `renderServiceError` 的訊息規格

四個建構子**一律逐字委派下層的 `render*`,本層一個字都不加**:

| 建構子 | 訊息 |
|---|---|
| `StoreFailed e` | `renderStoreError e`(逐字) |
| `WorkspaceFailed e` | `renderWorkspaceError e`(逐字) |
| `RegistryUnavailable e` | `renderRegistryError e`(逐字) |
| `RegistryLoadFailed e` | `renderRegistryError e`(逐字) |

加前綴會讓同一則訊息在 `service` 與在下層各長一個樣,而下層的訊息已經寫過「下一步」
(`renderRegistryError (RegistryNotFound paths)` = 「找不到型別註冊表,查過:…」)。兩個註冊表
建構子因此渲染成**相同**的文字;分辨它們是 `errorCode` 的責任,不是訊息的責任。

### 測試素材:一組固定的工作區佈局

Laws 與 Examples 以這組佈局為基準(qa 自行以 `temporary` 建在暫存目錄下,`AAPMS_HOME` 指向
`hub/`,`STORYFLOW_REGISTRY_DIR` 一類的註冊表環境變數指向專案的 `types/registry/`):

```text
<tmp>/hub/config.toml          -- [[vaults]] 兩列:VA(story)、VB(asset);無 [llm]
<tmp>/va/.aapms/config.toml    -- id = VA, kind = story, name = "story", refs = []
<tmp>/vb/.aapms/config.toml    -- id = VB, kind = asset, name = "assets", refs = []
<tmp>/outside/                 -- 不是 vault,也不在任何 vault 底下
```

兩個 vault 都**尚未**有 `index.db`——`index.db` 只在 `openVault` 第一次被呼叫時才被建出來,
這正是 L1 的觀察點。

## Laws

### `openEnv` / `closeEnv` / `withEnv`

- **L1**(不開索引):對所有 `sel`、所有起點 `cwd`,`openEnv sel cwd` 回 `Right env` 之後,
  佈局裡每個 vault 的 `<root>/.aapms/index.db` 的**存在性與 mtime 都與呼叫前相同**。
  (兩個 vault 起始都沒有 `index.db`,所以觀察等價於「呼叫後仍不存在」。)
- **L2**(中樞載不起來即失敗):對所有 `sel`、`cwd`,中樞的 `config.toml` 不存在時
  `openEnv sel cwd` 回 `Left (WorkspaceFailed (HubNotFound _))`,**不是** `Right`。
- **L3**(註冊表定位不到即失敗):對所有 `sel`、`cwd`,註冊表三層都定位不到時 `openEnv sel cwd`
  回 `Left (RegistryUnavailable _)`。
- **L4**(註冊表載入失敗即失敗):對所有 `sel`、`cwd`,註冊表目錄存在但內容不合規(例如缺
  `naming.toml`)時 `openEnv sel cwd` 回 `Left (RegistryLoadFailed _)`。
- **L5**(`closeEnv` 釋放乾淨):對所有 `env` 與任意一串 `withRead` / `withWrite` 操作,
  `closeEnv env` 之後,`openEnv` 一個新的 `env'` 並重跑同一串操作**全部成功**,且佈局所在的
  整個暫存目錄可被刪除(Windows 上有未關閉的 SQLite 連線就刪不掉)。
- **L6**(`closeEnv` 冪等):對所有 `env`,`closeEnv env >> closeEnv env` 與 `closeEnv env` 不可
  區分——第二次不丟例外、不改變任何檔案。
- **L7**(`withEnv` = `openEnv` + `closeEnv`):對所有 `sel`、`cwd` 與所有 `f :: Env -> IO a`,
  `openEnv` 會成功時 `withEnv sel cwd f` 回 `Right` 且 `f` 恰好被呼叫一次;`openEnv` 會失敗時
  `withEnv sel cwd f` 回**與 `openEnv` 相同的** `Left`,且 `f` **一次都沒被呼叫**。

### `handleFor` 與快取

- **L8**(快取命中不再開檔):對所有 `ref`,同一個 `env` 上第二次 `handleFor ref` 回的
  `vhRoot` 與 `vhMarker` 與第一次相等,**即使第一次之後把 `<vrPath ref>/.aapms/config.toml`
  刪掉**(重新開會回 `StoreFailed (VaultMarkerMissing _)`)。
- **L9**(開啟失敗即短路):對所有指向非 vault 目錄的 `ref`,`handleFor ref` 以
  `StoreFailed (VaultMarkerMissing _)` 短路,而後續同一個 `runService` 裡的動作**不被執行**。
- **L10**(`indexIssuesFor` 與開啟同步):對所有 `ref`,`handleFor ref` 成功之後
  `indexIssuesFor (vmId (vrMarker ref))` 回的清單等於該次 `openVault` 回的清單;在
  `handleFor` 之前呼叫則回 `[]`。

### `runService`

- **L11**(互斥):對所有 `n`,對同一個 `env` **並發**跑 `n` 次
  `runService env (liftIO (modifyIORef' r (+1) 之類的讀-改-寫))`,最終值恒為 `n`,且任意兩次
  `runService` 的臨界區**不重疊**(在動作內先讀一個共用旗標、暫停、再檢查旗標未被改動)。
  註:**不支援巢狀** `runService`(會死結);契約沒有任何一條需要巢狀。巢狀由 **L23** 靜態擋住,
  本條**不驗**巢狀(要驗就得真的跑一次巢狀,而那會把測試掛死)。
- **L12**(錯誤傳播):對所有 `e`,`runService env (throwService e)` 回 `Left e`,逐欄相等。

### 收尾組合子 `finallyService`

- **L24**(兩條路徑都收尾)。**編號接在 L23 之後**,是因為它在 W1 交付後的定向修訂(2026-08-30)
  才追加;L1–L23 一律不重編。

  對所有 `env`、所有 `a :: ServiceM x`、所有 `e :: ServiceError`,以及一個把「被執行過」寫進
  `IORef Int` 的收尾動作 `fin = liftIO (modifyIORef' c (+1))`:

  1. **成功路徑**:`runService env (finallyService (pure v) fin)` 回 `Right v`,且事後 `c == 1`;
  2. **短路路徑**:`runService env (finallyService (throwService e) fin)` 回 `Left e`(逐欄相等,
     與 L12 同一個判準),且事後 `c == 1`;
  3. **收尾恰好一次**:上面兩式跑完 `c` 各自只增加 1,不是 0(沒收尾)也不是 2(收兩次);
  4. **收尾在動作之後**:兩式都可用「動作內先寫 `1`、收尾寫 `2`」的順序旗標觀察到收尾後發生。

  第二個動作的回傳值被丟棄(型別上就丟掉了:回傳型別是第一個動作的 `a`)。

  **不驗的**:IO 例外那一條路徑。骨架的語意欄寫了它(`Control.Exception` 的例外一樣要收尾),
  但在 `ServiceM` 裡構造一個 IO 例外要 `liftIO (throwIO …)`,而斷言「例外原樣重拋」需要在
  `runService` 之外再包一層 `try`——那是 `shell` 的形狀,不是本層任何契約需要的。本層只釘住
  契約真正依賴的兩條(`withRead` / `withWrite` 的 `VaultSet` 只會走這兩條:`k` 正常回傳,或
  `k` / `handleFor` / `liftStore` 以 `throwService` 短路)。

### 巢狀 `runService` 的靜態防線(以原始碼文字驗證)

- **L23**(`ServiceM` 動作不得自己呼叫 `runService`)。**編號接在最後**,是因為它在 W1 閘門
  (2026-08-30)才追加;L1–L22 一律不重編。

  **為什麼要有這條**:`runService` 從頭到尾持有 `Env` 那把全域互斥鎖(見「不可逆決定」第二列),
  所以任何在 `ServiceM` 動作內部對**同一個 `Env`** 再呼叫一次 `runService` 都會死結。這是那個決定
  的**已知代價**,而 F002–F008 六個 feature 都會在 `ServiceM` 裡組合別的操作——巢狀呼叫編得過、
  型別也對,只有跑起來才掛。L11 只驗兩個並發的 `runService` 不重疊,擋不到這件事。

  **判準只看程式碼行,不做全檔字串搜尋**(`Monad.hs` 的 haddock 本來就要寫「鎖在 `runService`
  上」「巢狀會死結」這些字,全檔搜尋會把「文件寫得清楚」誤判成「越界」——同 `workspace/F004`
  的 L42):

  1. **掃描範圍**:`service/src/` 底下**遞迴**取得的每一個 `.hs` 檔,**不是一份寫死的清單**——
     這條 law 的價值就在於 F002–F008 之後新增的每個模組都自動被納入。`service/test/` **不在範圍
     內**:qa 自己非呼叫 `runService` 不可(L11 / L12 / X4–X6 全都要它)。
     (檔案路徑的解析沿用本專案既有測試的做法:先試 `src/…`,不存在再試 `service/src/…`,因為
     `cabal test` 的工作目錄可能是套件目錄或倉庫根目錄。)
  2. **正規化**(逐行,順序固定):
     - 去掉行尾的 `\r`——專案的 `core.autocrlf` 讓 `.hs` 在乾淨 checkout 上是 CRLF,逐字比對前
       不去掉會全紅(W1 的教訓);
     - 丟掉 **trim 後以 `--` 開頭的整行**(行註解與 haddock);
     - 把剩下每行**第一個出現的 ` --`**(前面至少一個空白的雙連字號)起截掉(行尾註解)。

     剩下的叫**程式碼行**。本套件不使用區塊註解 `{- … -}`(骨架三檔的現況),所以不必處理。
  3. **(a) 範圍外的檔案一律零出現**:除 `Aapms/Service/Monad.hs` 之外,`service/src/` 底下任何
     `.hs` 檔的程式碼行都**不得含子字串 `runService`**——包含 `import Aapms.Service.Monad
     (runService)` 這種 import 行。`Scope` 與 F002–F008 的模組連 import 它都不該:它們交出去的
     是 `ServiceM` 動作,執行是 `shell` 的事。
  4. **(b) `Monad.hs` 之內只允許三種形狀**,含 `runService` 的程式碼行必須落在其中之一:
     - **匯出清單那一段的行**——從 trim 後以 `module Aapms.Service.Monad` 起頭的那一行,到**第一個**
       含 `) where` 的行為止(兩端都含),這一段內不受限;
     - **型別簽名行**——trim 後**逐字等於**
       `runService :: Env -> ServiceM a -> IO (Either ServiceError a)`;
     - **定義等式的開頭**——以 `runService` 起頭於**第 0 欄**(行首完全無空白)的行。

     這三種以外任何提到 `runService` 的程式碼行都是違規,**特別是有前導空白的那些**:縮排 +
     `runService` 正是「在某個函式的本體裡呼叫它」的形狀,而 `Monad.hs` 裡唯一會有本體的呼叫端
     就是某個 `ServiceM` 相關的 helper。

  **斷言**:違規行的清單為**空**。違規訊息必須帶出**檔名與行號**,否則 F005 的人看到紅燈也不知道
  紅在哪。判準本身寫成對「(檔名, 檔案全文)」的純函數,`service/src/` 的實況(X24)與一份合成文字
  (X25)餵的是同一個判準——**沒有 X25 這條 law 就可能是空洞的**(掃描器寫壞時正向斷言照樣綠)。

  **不在本條範圍內的**:`withEnv` 巢狀不受限(它每次開的是**新的** `Env`、新的鎖,不會死結);
  `shell` 與領域子系統對 `runService` 的呼叫也不受限——它們是這把鎖的**正當**使用者,而且不在
  `service/src/` 底下。

### `ServiceM` 額外實例的靜態防線(以原始碼文字驗證)

- **L25**(`service/src/` 不得宣告任何 type class 實例,`ServiceM` 的 deriving 子句逐字釘死)。
  **編號接在 L24 之後**,同屬 W1 交付後的定向修訂(2026-08-30)。

  **為什麼要有這條**:`ServiceM` 不透明是本 feature 的第一條不可逆決定,而**匯出清單守不住實例**——
  類別方法不出現在 `module … ( … ) where` 裡,任何 import `Aapms.Service.Monad` 的模組都自動拿到
  該實例的全部方法。多 derive 一個 `MonadError ServiceError ServiceM`,`catchError` 與 `throwError`
  就成了兩條沒有登記在 design.md「模組間公開介面」表上的對外 API,而 `throwError` 還是一條繞過
  `throwService` 的拋出路徑。這正是 W1 impl 撞到的事:資料流要求「結束時(含短路)`closeVaultSet`」,
  而骨架沒給任何攔截短路的能力,於是它自己補了那個實例(歸因見「實作備註」)。修訂的答案是
  `finallyService`(L24),而這一條負責讓答案**留在原地**。

  理由與 L23 相同:它要守的是 **F002–F008 每一波**,不是只有這一波。編譯期看不出違規(多一個實例
  永遠編得過,而且會讓程式碼「變好寫」),靜態斷言在該模組進來的那一刻就紅。

  **掃描範圍與正規化**:與 L23 **逐字相同**(`service/src/` 底下遞迴取得的每一個 `.hs` 檔,不是
  寫死的清單;`service/test/` 不在範圍內;去行尾 `\r` → 丟掉 trim 後以 `--` 開頭的整行 →
  截掉第一個 ` --` 起的行尾註解)。剩下的叫**程式碼行**。同一個正規化服務兩條 law,理由也一樣:
  模組 haddock 本來就要寫「不給 `ServiceM` 加 `MonadError` 實例」這句話,全檔字串搜尋會把
  「文件寫得清楚」誤判成「越界」。

  **判準**(四條,任一違反即產生一筆違規,訊息必須帶**檔名與行號**):

  1. **沒有手寫實例**:任何程式碼行 trim 後**不得以 `instance ` 起頭**。本套件不定義任何 type
     class 實例——需要 `Show` / `Eq` 一律走資料宣告上的 deriving 子句。
  2. **沒有 standalone deriving**:任何 trim 後以 `deriving` 起頭的程式碼行**不得含子字串
     `instance`**(擋 `deriving instance` / `deriving newtype instance` /
     `deriving anyclass instance` / `deriving stock instance` 全部四種寫法)。
  3. **沒有 `StandaloneDeriving` pragma**:任何程式碼行**不得含子字串 `StandaloneDeriving`**。
     這一條是**輔助**而非主力:`.cabal` 的 `default-language` 是 **GHC2021**,而
     `StandaloneDeriving` 本來就在 GHC2021 的清單裡——沒有 pragma 也 derive 得起來,所以真正
     擋住事情的是第 2 條的行形狀,第 3 條只是讓「有人特地寫了這個 pragma」這種意圖也留不下來。
  4. **`ServiceM` 的 deriving 子句逐字釘死**:整個 `service/src/` 底下,trim 後以 `deriving`
     起頭**且含子字串 `Monad`** 的程式碼行**恰好一行**,它必須位於 `Aapms/Service/Monad.hs`,
     且 trim 後**逐字等於** `deriving newtype (Functor, Applicative, Monad, MonadIO)`。
     這一條擋的是第 1–3 條擋不到的那個寫法:直接把 `MonadError ServiceError` 塞進 `ServiceM`
     宣告上那個既有的 deriving 子句。以「含 `Monad`」當篩選條件是為了不誤傷未來模組的
     `deriving stock (Show, Eq)` 一類的行。

  **斷言**:違規行的清單為**空**。判準本身寫成對「(檔名, 檔案全文)」的純函數,`service/src/` 的
  實況(X28)與一份合成文字(X29)餵的是同一個判準——**沒有 X29 這條 law 就可能是空洞的**
  (掃描器寫壞時正向斷言照樣綠),與 L23 / X24 / X25 是同一個理由。

  **不在本條範圍內的**:`service/test/`(qa 要為自己的 fixture 定義實例是它的自由);`shell`
  與領域子系統(`ServiceM` 的建構子不匯出,它們**derive 不出**任何實例,不需要靜態擋);資料
  宣告上不含 `Monad` 的 deriving 子句(`deriving stock (Show, Eq)` 一類,是本套件唯一被允許的
  實例來源)。**未來真的需要一個實例時**,那是契約層級的改動:改這條 law 要上閘門,不是在
  某一波的實作裡順手加一行。

### 三個 `with*`

- **L13**(讀取範圍與裁決一致):對所有 `sel`,`withRead (\vs refs -> pure (vaultSetIds vs, map (vmId . vrMarker) refs))`
  的兩個結果**互相相等**,且都等於 `resolveRead hub sel` 的 `rsVaults` 的 `vmId` 清單
  (同一組、同一順序)。
- **L14**(`ScopeIssue` 不中止):對所有 `sel`,`resolveRead` 產生非空 `rsIssues` 時
  `withRead k` 仍回 `Right`(k 照常被呼叫);範圍為空時 `k` 也照常被呼叫,拿到的
  `vaultSetIds` 是空清單。
- **L15**(`VaultSet` 關掉、handle 不關):對所有 `k`,`withRead k` 結束後,同一個 `env` 上再跑
  一次 `withRead` 仍成功(handle 還在快取裡),而整個暫存目錄在 `closeEnv` 之後可被刪除
  (`VaultSet` 自己的連線已被關)。
- **L16**(沒有寫入目標即失敗):起點在 `outside/` 之下且 `sel == Nothing` 時,對所有 `k`,
  `withWrite k` 回 `Left (WorkspaceFailed (NoWriteTarget _))`,且 `k` **一次都沒被呼叫**。
- **L17**(寫入目標唯一):`sel == Just s` 且 `s` 解得到時,對所有 `k`,`withWrite k` 交給 `k`
  的 `VaultHandle` 的 `vmId (vhMarker h)` 恒等於 `resolveWrite hub sel cwd` 的
  `vmId (vrMarker (wsTarget scope))`,而交出去的 `VaultSet` 的 `vaultSetIds` 等於 `wsRead` 的
  `vmId` 清單。
- **L18**(管線只給符合 kind 的):對所有 `kind`、所有 `sel`,`withPipeline kind k` 交給 `k` 的
  每個 handle 都滿足 `vmKind (vhMarker h) == kind`,清單的順序等於 `psRuns` 的順序;沒有任何
  vault 符合時 `k` 收到空清單且仍被呼叫。

### `errorCode` / `renderServiceError`

- **L19**(`code` 的形狀):對所有 `e :: ServiceError`,`errorCode e` 非空、只含 `[a-z0-9_]`、
  不以 `story_flow` 或 `aapms` 開頭。
- **L20**(`code` 兩兩相異):對所有 `e1`、`e2`,兩者的**建構子不同**時
  `errorCode e1 /= errorCode e2`;建構子相同時 `errorCode e1 == errorCode e2`(`code` 只看
  建構子,不看酬載)。
- **L21**(訊息逐字委派):對所有 `e :: StoreError`,`renderServiceError (StoreFailed e) == renderStoreError e`;
  對所有 `e :: WorkspaceError`,`renderServiceError (WorkspaceFailed e) == renderWorkspaceError e`;
  對所有 `e :: RegistryError`,`renderServiceError (RegistryUnavailable e) == renderRegistryError e`
  且 `renderServiceError (RegistryLoadFailed e) == renderRegistryError e`。
- **L22**(訊息非空):對所有 `e :: ServiceError`,`renderServiceError e` 非空。

`L-`:`askHubLocation` / `askHub` / `askRegistry` / `askNaming` / `askRegistrySource` /
`askSelector` / `askCwd` 七個存取器**無獨立 law**,理由具體:它們的唯一性質是「回 `openEnv` 那一次
載入的那一份,原樣」——寫成 property 只會得到「`askX env` 等於 `openEnv` 內部存進去的那個值」,
兩邊是同一個表達式,斷言恆真。而那一份的**內容**成不成立是下層子系統的 law(`workspace/F001` 的
`loadHub`、`graph-core/F002` 的 `locateRegistry` / `loadRegistry`),本層重述一次只是把別人的 law
抄過來。可觀察的部分(值確實被傳到了、而且沒有被本層改寫)逐一寫成 example:`askSelector` → X4、
`askRegistrySource` → X5、`askHubLocation` / `askCwd` → X5b、`askRegistry` / `askNaming` → X5c、
`askHub` → X6(與 `reloadHub` 同一個 example 的前後兩次觀察)。

**寫測試時的一個地雷**:`Aapms.Workspace.Types.HubSource` 與 `Aapms.Types.Loader.RegistrySource`
**各有一個叫 `FromEnv` 的建構子**。兩者同時 import 時必須 qualify,否則是 ambiguous occurrence。

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 | 由哪幾條 law 推出 |
|---|---|---|---|---|
| X1 | 完整佈局,`openEnv Nothing <tmp>/va` | `Right env`;`<tmp>/va/.aapms/index.db` 與 `<tmp>/vb/.aapms/index.db` **都不存在** | 正常路徑 + 驗收標準 1 | L1 |
| X2 | 刪掉 `<tmp>/hub/config.toml` 後 `openEnv Nothing <tmp>/va` | `Left (WorkspaceFailed (HubNotFound "<tmp>/hub/config.toml"))` | 中樞缺席 | L2 |
| X3 | 註冊表環境變數指向不存在的目錄,`openEnv Nothing <tmp>/va` | `Left (RegistryUnavailable _)` | 註冊表定位失敗 | L3 |
| X3b | 註冊表目錄存在但沒有 `naming.toml`,`openEnv Nothing <tmp>/va` | `Left (RegistryLoadFailed _)` | 註冊表載入失敗 | L4 |
| X4 | `openEnv (Just "story") <tmp>/outside` 後 `runService env askSelector` | `Right (Just "story")` | selector 原樣捧著、**未被解讀** | L12(短路的對偶:成功路徑) |
| X5 | 同上,`runService env askRegistrySource` | `Right Loader.FromEnv`(環境變數指向專案的 `types/registry/` 時) | 註冊表來源可觀察 | L-(見 Laws 段末) |
| X5b | 同上,`runService env ((,) <$> askHubLocation <*> askCwd)` | `hlPath` = `<tmp>/hub`、`hlSource == Types.FromEnv`、`askCwd` = `<tmp>/outside` 的絕對路徑 | 中樞位置與起點原樣捧著 | L-(見 Laws 段末) |
| X5c | 同上,`runService env ((,) <$> (length . listTypes <$> askRegistry) <*> askNaming)` | 型別數 > 0;`NamingVocab` 逐欄等於直接對同一目錄呼叫 `loadRegistry` 得到的第二個回傳值 | 註冊表與詞彙表來自同一次載入 | L-(見 Laws 段末) |
| X6 | 手動改寫 `<tmp>/hub/config.toml` 加一列 vault 後 `runService env ((,) <$> askHub <*> reloadHub)` | `askHub` 的 `hubVaults` 長度 = 2(舊快照),`reloadHub` 的 = 3 | 中樞快照可重載;`askHub` 在重載前不變 | L-(見 Laws 段末) |
| X7 | 同一 `env` 上 `handleFor refVA`,刪掉 `<tmp>/va/.aapms/config.toml`,再 `handleFor refVA` | 兩次的 `vhRoot` 相同、`vmId (vhMarker h)` 相同,第二次**成功** | 快取命中 + 驗收標準 3 | L8 |
| X8 | 手工組一個 `VaultRef`(`vrEntry = Nothing`、`vrPath = <tmp>/outside`、`vrMarker` 用任一合法 marker 值),對它 `handleFor` | `Left (StoreFailed (VaultMarkerMissing "<tmp>/outside/.aapms/config.toml"))` | 開啟失敗 | L9 |
| X9 | `withRead` 一串操作後 `closeEnv env`,然後刪除整個 `<tmp>` | 刪除成功;`openEnv` 新的 `env'` 重跑同一串仍成功 | 資源釋放 + 驗收標準 4 | L5, L15 |
| X10 | `closeEnv env >> closeEnv env` | 不丟例外 | 冪等 | L6 |
| X11 | `openEnv` 會失敗(中樞缺席)時 `withEnv Nothing <tmp>/va (\_ -> writeIORef flag True >> pure ())` | 回 `Left (WorkspaceFailed …)`,且 `flag == False` | `withEnv` 的失敗路徑 | L7 |
| X12 | 對同一 `env` 並發 8 次 `runService env (liftIO (readIORef r >>= \v -> yield >> writeIORef r (v+1)))` | 最終 `r == 8` | 互斥 + 驗收標準 5(的互斥那一半) | L11 |
| X13 | `runService env (throwService (WorkspaceFailed (NoWriteTarget "/x")))` | `Left (WorkspaceFailed (NoWriteTarget "/x"))` | 錯誤傳播 | L12 |
| X14 | `sel == Nothing` 時 `withRead (\vs refs -> pure (vaultSetIds vs, map (vmId . vrMarker) refs))` | 兩個清單都等於 `[VA, VB]`(中樞順序) | 讀跨全部 vault | L13 |
| X15 | 中樞多一列指向不存在路徑的 vault(產生 `VaultPathMissing`)時 `withRead` | 仍回 `Right`;`vaultSetIds` 是 `[VA, VB]`(壞的那個被排除) | `ScopeIssue` 不中止 | L14 |
| X16 | 中樞的 `[[vaults]]` 清空後 `withRead (\vs _ -> pure (vaultSetIds vs))` | `Right []`(k 有被呼叫) | 空範圍 | L14 |
| X17 | 起點 `<tmp>/outside`、`sel == Nothing` 時 `withWrite (\_ _ -> liftIO (writeIORef flag True))` | `Left (WorkspaceFailed (NoWriteTarget p))`,`p` = `<tmp>/outside` 的**正規化**路徑(`resolveWriteTarget` 自己 `canonicalizePath` 過);且 `flag == False` | 沒有寫入目標 | L16 |
| X18 | `sel == Just "story"` 時 `withWrite (\h vs -> pure (vmId (vhMarker h), vaultSetIds vs))` | `(VA, [VA])`(VA 的 `refs` 是空的) | 寫單一 | L17 |
| X19 | `withPipeline AssetVault (\hs -> pure (map (vmId . vhMarker) hs))`,`sel == Nothing` | `Right [VB]`(VA 是 story,不符 kind,**不是 issue**) | 管線逐一 + kind 篩選 | L18 |
| X20 | `withPipeline StoryVault (\hs -> pure (length hs))`,中樞的 `[[vaults]]` 只剩 VB | `Right 0`(k 有被呼叫) | 管線空範圍 | L18 |
| X21 | `map errorCode [StoreFailed e1, WorkspaceFailed e2, RegistryUnavailable e3, RegistryLoadFailed e3]` | `["store_failed","workspace_failed","registry_unavailable","registry_load_failed"]` | `code` 表 + 驗收標準 6 | L19, L20 |
| X22 | `renderServiceError (StoreFailed (VaultMarkerMissing "/x/.aapms/config.toml"))` | 逐字等於 `renderStoreError (VaultMarkerMissing "/x/.aapms/config.toml")` | 訊息委派 + 驗收標準 7 | L21, L22 |
| X23 | `renderServiceError (RegistryUnavailable e)` 與 `renderServiceError (RegistryLoadFailed e)`,同一個 `e` | 兩者**逐字相同**;而 `errorCode` 兩者**不同** | 「訊息可同、code 必異」 | L20, L21 |
| X24 | 對 `service/src/` 的**實況**(骨架階段是 `Types.hs` / `Monad.hs` / `Scope.hs` 三個檔)跑 L23 的判準 | 違規清單**為空**;且 `Types.hs` 與 `Scope.hs` 含 `runService` 的程式碼行各為 **0 行**,`Monad.hs` 恰好 **3 行**,三行分屬三種允許形狀:匯出清單段的 `, runService`、簽名行 `runService :: Env -> ServiceM a -> IO (Either ServiceError a)`、第 0 欄起頭的定義行(骨架期是 `runService = undefined`)。`Monad.hs` 提到 `runService` 的**註解行**(模組 haddock 講「鎖在 `runService` 上」與 `ServiceM` 的說明)全部被正規化丟掉,**不計入** | 巢狀防線的正向路徑;順帶驗「判準不把註解誤判成越界」 | L23 |
| X25 | 一份**合成**的模組文字(只存在於測試裡,不寫進 repo):檔名 `Aapms/Service/Scope.hs`,內容取 `Scope.hs` 現況再插入一行 `  _ <- liftIO (runService env inner)`,以及一行 `-- 這裡本來想 runService,別這麼做`,連同一份合法的 `Monad.hs` 文字一起餵給同一個判準 | 違規清單**恰好一條**,指向插入的那一行(帶檔名與行號);那行**註解**不被算成違規 | 判準非空洞(掃描器壞掉時 X24 也會綠)+ 註解豁免的負向確認 | L23 |
| X26 | `runService env (finallyService (pure (42 :: Int)) (liftIO (modifyIORef' c (+1))))`,`c` 起始為 `0` | `Right 42`,且事後 `readIORef c == 1` | 收尾組合子的成功路徑 | L24 |
| X27 | `runService env (finallyService (throwService (WorkspaceFailed (NoWriteTarget "/x")) :: ServiceM Int) (liftIO (modifyIORef' c (+1))))`,`c` 起始為 `0` | `Left (WorkspaceFailed (NoWriteTarget "/x"))`(與 X13 逐欄相同),且事後 `readIORef c == 1` | 收尾組合子的短路路徑;短路**不被吞掉** | L24 |
| X28 | 對 `service/src/` 的**實況**(骨架階段是 `Types.hs` / `Monad.hs` / `Scope.hs` 三個檔)跑 L25 的判準 | 違規清單**為空**;且三個檔的程式碼行中,trim 後以 `instance ` 起頭的**共 0 行**,含 `StandaloneDeriving` 的**共 0 行**,trim 後以 `deriving` 起頭的**恰好 2 行**(`Types.hs` 的 `deriving stock (Show, Eq)` 與 `Monad.hs` 的 `deriving newtype (Functor, Applicative, Monad, MonadIO)`),其中含 `Monad` 的**恰好 1 行**且逐字等於後者。`Monad.hs` \/ `Scope.hs` 的**註解**裡提到 `MonadError` \/ `catchError` 的那些行全部被正規化丟掉,**不計入** | `ServiceM` 不透明的正向路徑;順帶驗「判準不把註解誤判成越界」 | L25 |
| X29 | 三份**合成**的模組文字(只存在於測試裡,不寫進 repo),各餵給同一個判準:(a) 檔名 `Aapms/Service/Monad.hs`,內容取現況再插入一行 `deriving newtype instance MonadError ServiceError ServiceM`;(b) 同檔名,把 `deriving newtype (Functor, Applicative, Monad, MonadIO)` 改成 `deriving newtype (Functor, Applicative, Monad, MonadIO, MonadError ServiceError)`;(c) 檔名 `Aapms/Service/Scope.hs`,內容取現況再插入一行 `instance Semigroup (ServiceM ()) where` 與一行 `-- 這裡本來想 deriving newtype instance,別這麼做` | (a) 違規**恰好一條**,指向插入的那一行(判準 2);(b) 違規**恰好一條**,指向被改掉的那一行(判準 4);(c) 違規**恰好一條**,指向 `instance` 那一行(判準 1),**註解那一行不算違規**。三者的訊息都帶檔名與行號 | 判準非空洞(掃描器壞掉時 X28 也會綠)+ 四條判準各自抓得到東西 | L25 |

## 依賴方向

- **依賴誰**:`aapms-core`(`Aapms.Core.Id` / `Aapms.Core.Naming` / `Aapms.Core.Registry`)、
  `aapms-types`(`Aapms.Types.Loader`)、`aapms-store`(`Aapms.Store.Error` / `Aapms.Store.Marker` /
  `Aapms.Store.MultiVault` / `Aapms.Store.Schema`)、`aapms-workspace`
  (`Aapms.Workspace.Types` / `Aapms.Workspace.Hub` / `Aapms.Workspace.Location` /
  `Aapms.Workspace.Scope`)、`base` / `containers` / `mtl` / `text`。
- **誰會依賴它**:本子系統的 F002–F008;之後是 `shell` 的四個殼與四個領域子系統(僅內嵌出口)。
- **新增的依賴邊**(套件層級全部是新的,因為這是本套件的第一波):
  - `aapms-service` → `aapms-core`
  - `aapms-service` → `aapms-types`
  - `aapms-service` → `aapms-store`
  - `aapms-service` → `aapms-workspace`
  - 模組層級:`Aapms.Service.Monad` → `Aapms.Service.Types`;
    `Aapms.Service.Scope` → `Aapms.Service.Monad`。**沒有回頭邊**,
    `Aapms.Service.Types` 不 import 本套件任何模組。
  - **沒有**新增任何往 `shell` 或領域子系統的邊,也沒有 `servant` / `warp` /
    `optparse-applicative` / `aeson`(ADR-006 / ADR-015 的界線,由 `.cabal` 的
    `build-depends` 逐字釘住)。
- **可否與其他進行中任務平行開發**:本波只有本 feature,無平行對象。F002 依賴本 feature,
  必須等本波綠燈。

## 不可逆決定

| 決定 | 被否決的替代方案與理由 |
|---|---|
| **`Env` 與 `ServiceM` 都不透明**(建構子與欄位不匯出,存取一律經函式) | **露出 `Env` 的欄位**:F002 起的每個模組直接 `envHub e` 就好,少寫八個存取器。否決理由是 `Env` 有兩類不變量會被靜默破壞——四格「同一次 `openEnv` 載入」的一致性(拼得出「中樞是 A、註冊表是 B」的環境),以及三格可變狀態的鎖保護(直接讀 `envHandles` 的 `IORef` 不會有編譯錯誤,但繞過了 `runService` 的臨界區)。代價已知:每加一個 `Env` 欄位就要加一個存取器,而存取器是 API。**露出 `ServiceM` 的建構子**:qa 可以不經 `runService` 直接跑動作,測試好寫。否決理由是那正好繞過唯一拿鎖的地方,而「測試用的那條路不拿鎖」會讓 L11 這條 law 在測試裡永遠是綠的。**W1 交付後的定向修訂(2026-08-30)裁決:`ServiceM` 不透明照收,但這個決定要有守衛——守衛是 `L25`**(對 `service/src/` 的原始碼文字斷言:不得有任何 `instance` 宣告或 standalone deriving,`ServiceM` 的 deriving 子句逐字釘死為 `Functor` / `Applicative` / `Monad` / `MonadIO`)。理由是**匯出清單守不住實例**:類別方法不進 `module … ( … ) where`,多 derive 一個實例就等於多一組沒登記在介面表上的對外 API,而那件事編得過、review 時也長得像「讓程式碼變好寫」。真正需要攔截短路的那個場景由 `finallyService`(L24)以一個**登記過的名字**滿足,不靠實例。W1 的 impl 正是在這裡撞牆(見「實作備註」) |
| **鎖的臨界區是整個 `runService`** | **鎖在 `handleFor`**:粒度最細、並行度最高。否決理由是它只保護三件事裡的一件(快取),`Connection` 的使用與「先寫檔再更新索引」都在臨界區外。**鎖在各操作各自宣告**:粒度合適。否決理由是每個新操作都要記得包一層,漏包不會有編譯錯誤——與 design.md 不可逆決定第三列否決「鎖留在 `AppState`」是同一條理由。已知代價:巢狀 `runService` 死結、單一 `Env` 上無並行。**W1 閘門(2026-08-30)裁決:整個 `runService` 當臨界區照收,但「巢狀死結」這條代價要有守衛——守衛是 `L23`**(對 `service/src/` 的原始碼文字斷言:`Monad.hs` 以外的模組一個字都不准提到 `runService`;`Monad.hs` 內只允許匯出清單、簽名行、第 0 欄的定義等式三種形狀)。選的是**靜態斷言**而不是執行期偵測(重入計數 / 可重入鎖):後者要為一件契約上根本不該發生的事付每次呼叫的成本,前者在 F002–F008 的模組進來的那一刻就紅。L11 驗的是並發不重疊,擋不到巢狀,兩條不能互相取代 |
| **`code` 由「建構子名的 snake_case」規則產生,不是一份對照表** | **逐條指定字串**(如 `StoreFailed` → `storage_error`):可以挑更貼近使用者語彙的字。否決理由是 `code` 是**對外契約**(CLI exit code 對照、OpenAPI 的錯誤列舉),而後面還有九個建構子要加;一份人工對照表意味著每加一個建構子就要問一次「這個叫什麼」,而且問完之後沒有任何機制擋住下一個人取一個不一致的名字。代價:`code` 的字面被建構子名綁住,改建構子名就是改對外契約——這一點反而是想要的,因為它會逼人在改名時看見 |
| **四個建構子的訊息一律逐字委派下層 `render*`,本層不加前綴** | **加一層前綴**(如「工作區設定失敗 —— …」):訊息更能說出是哪一層出的事。否決理由是下層的訊息已經寫過「下一步」,加前綴會讓同一則訊息在兩層各長一個樣,而 `shell` 的三個殼都直接印這一則;想知道是哪一層的人看 `code`。已知代價:`RegistryUnavailable` 與 `RegistryLoadFailed` 對同一個酬載渲染成相同文字(X23 明文驗這件事) |
| **handle 快取的鍵是 marker 的 `VaultId`,不是路徑** | **用正規化後的路徑當鍵**:不必讀 marker 就查得到。否決理由是 ADR-017 明定 vault 的身分就是 marker 裡的 id;用路徑當鍵時,同一個 vault 經兩條路徑(符號連結、大小寫不同的磁碟機代號)進來會被開兩次,而兩份把手各自持有一條 SQLite 連線 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `service/src/Aapms/Service/Types.hs` | `ServiceError`(四個建構子)、`errorCode` / `renderServiceError` 簽名 |
| `service/src/Aapms/Service/Monad.hs` | `Env`(十欄,建構子不匯出)、`ServiceM`、契約 A 四個函式、八個存取器、`handleFor` / `indexIssuesFor`、三個錯誤 helper、`finallyService` 的簽名 |
| `service/src/Aapms/Service/Scope.hs` | `withRead` / `withWrite` / `withPipeline` 簽名 |

`cabal build aapms-service` **通過**(2026-08-30,W1 交付後的定向修訂重跑;`lib:aapms-service`
零警告零 error,只有 `service/test/` 的十一則 `-Wname-shadowing` 是 qa 檔案的既有警告)。
骨架階段原有的 `-Wunused-top-binds`(`Env` 十個 record 欄位)在 W1 impl 填完本體後已消失。

impl 只准替換 `undefined`,不得改動任何簽名、型別定義或匯出清單。

**W1 閘門追加的 L23 不動骨架**:它是對原始碼文字的斷言,不新增任何簽名、型別或匯出。骨架的現況
本身就是 L23 的第一個觀察對象(X24),所以這條 law 從第一天就綠——但它對 impl 仍是約束:
**填 `undefined` 的時候不得在 `Scope.hs`(或任何未來模組)寫出 `runService`**,`Monad.hs` 裡也
不得讓 `runService` 出現在匯出清單、簽名行、第 0 欄定義等式以外的地方。

**W1 交付後的定向修訂(2026-08-30)動了骨架三處**(來由見「實作備註」):

1. `Monad.hs` **刪掉** `deriving newtype instance MonadError ServiceError ServiceM` 與第 1 行的
   `{-# LANGUAGE StandaloneDeriving #-}` pragma;
2. `Monad.hs` **新增** `finallyService` 的匯出、簽名與 haddock,本體 `undefined`;
3. `Scope.hs` 的私有 helper `finallyCloseVaultSet` **還原成骨架形狀**(本體 `undefined`),
   連同它獨用的 `Control.Monad.Except (catchError, throwError)` /
   `Control.Monad.IO.Class (liftIO)` / `Aapms.Store.MultiVault (closeVaultSet)` 三個 import。
   `withRead` / `withWrite` / `withPipeline` 的本體**未動**——它們對 `finallyCloseVaultSet` 的
   呼叫形狀不變,下一輪 impl 只要把那個 helper 依 `finallyService` 重寫。

**連帶的一處機械性修補**:`throwService` 的本體原本是 `throwService = throwError`,靠的正是被撤掉
的那個實例。改成 `throwService e = ServiceM (throwError e)` ——在 `Monad.hs` 內部 `ServiceM` 的
建構子本來就看得見,`ReaderT Env (ExceptT ServiceError IO)` 的 `MonadError` 實例來自 mtl,語意
與原本**逐字相同**,只是把「拆 newtype」這件事寫明。這是為了讓整包在移除實例後仍編得過所做的
最小修補,不是行為改動。

**L24 / L25 對 impl 的約束**:`finallyService` 是**唯一**被授權拆 `ServiceM` newtype 做收尾的
地方;`Scope` 與 F002–F008 一律呼叫它,**不得**自己 derive 任何實例、不得寫 `instance` 宣告、
不得動 `ServiceM` 的 deriving 子句。

## 待確認假設

三條全部在 **W1 的 spec 批准閘門(2026-08-30)裁決完畢,結論一律是「接受暫採」**。條目**不刪**——
它是決策紀錄:留著才知道當初有哪些選項、為什麼沒選、以及每條裁決依賴的前提是什麼(前提失效時就是
回頭重談的時機)。「暫採 → 影響」那一段同樣留著,因為它是「若改回 b / c 要動哪幾行」的清單。

- **A1**(**已裁決:接受暫採(2026-08-30 W1 閘門)——`RegistryUnavailable RegistryError` /
  `RegistryLoadFailed RegistryError`,兩個都收 `RegistryError`;design.md 契約 F 已由編排者回寫**):
  契約 F 的 `RegistryUnavailable Text` 與 `RegistryLoadFailed [LoadError]` 兩個建構子的
  酬載型別。契約卡沒有答案,是因為它把契約 F 的建構子當成既定事實引用,而契約 F 寫下來的時候
  沒有對照 `aapms-types` 的實況:**`LoadError` 這個型別在整棵樹上不存在**,註冊表的載入層只有
  `RegistryError`(`core/src/Aapms/Core/Registry.hs:251`),而且 `loadRegistry` 回的是**單一個**
  `RegistryError` 而不是清單(`RegistryError` 自己的 `RegistryErrors [RegistryError]` 就是彙整
  多個問題的那一格)。照抄編不過,所以這一格**必須**改;順帶要決定的是隔壁的
  `RegistryUnavailable Text` 要不要一起改成結構化。
  - **契約錨點**:design.md 契約 F 的 `ServiceError` 建構子 `RegistryUnavailable` 與
    `RegistryLoadFailed`;契約 F 的「下層錯誤原樣包、不重寫訊息」那一段;契約 A 的 `openEnv`
    (這兩個錯誤的唯一產生處)。**觸及符號**:`ServiceError`、`RegistryUnavailable`、
    `RegistryLoadFailed`、`errorCode`、`renderServiceError`、`RegistryError`、
    `renderRegistryError`、`locateRegistry`、`loadRegistry`、`openEnv`
  - **層級自答**:出現在邊界上?**會**(`ServiceError` 是 `shell` 三個殼看到的東西,酬載型別
    決定 `shell` 能不能做結構化處理);改錯驚動其他模組?**要**(改酬載要動 `Types.hs`、
    `renderServiceError`、`openEnv`,以及之後 `shell` 對這兩個 `code` 的處理)
  - **選項**:
    a) **兩個都收 `RegistryError`(本 spec 暫採)**——當下成本:`RegistryLoadFailed` 那格是
       被迫改(無替代),`RegistryUnavailable` 那格多改一個字;`openEnv` 兩條失敗路徑各一行,
       `renderServiceError` 兩格都委派 `renderRegistryError`。三個月後代價:兩個建構子的訊息
       **逐字相同**(只有 `code` 分得開),看起來像重複;而 design.md 契約 F 的原文與程式碼
       有兩處不一致,要回寫。
    b) **只改被迫的那一格**:`RegistryLoadFailed RegistryError`,`RegistryUnavailable Text`
       原樣保留——當下成本:同樣一行,`openEnv` 在定位失敗時寫
       `RegistryUnavailable (renderRegistryError e)`。三個月後代價:**結構在邊界上被壓成字串**。
       定位失敗的唯一有用資訊是 `RegistryNotFound [FilePath]` 裡那份「查過哪些路徑」的清單,
       壓成 `Text` 之後 `shell` 只能整段印出去——`doctor` 想把「查過的路徑」排成一欄、
       MCP 想把它放進結構化欄位,都得回頭改契約,而那時 `Text` 這個形狀已經有消費者了。
       同一份 `ServiceError` 裡三個建構子捧原件、一個捧字串,也讓「下層錯誤原樣包」這條規則
       出現一個沒有理由的例外。
  - **傾向**:**a**。理由是 (b) 省下的是零(兩者的當下成本一樣是一行),付出的是把一個
    **本來就有結構**的錯誤在邊界上壓成字串;而 design.md 契約 F 自己寫的規則就是「下層錯誤
    原樣包、不重寫訊息」——(a) 讓四個建構子一致地遵守它,(b) 製造一個例外。依賴的前提有一個,
    寫出來:「`shell` 之後會想結構化處理定位失敗」——這個前提**已經被 design.md 兌現**,
    因為 `DoctorView` 有 `dvRegistry :: RegistrySource` 這一欄,`doctor` 確實要報告註冊表的
    狀況;把定位失敗壓成字串就是讓 `doctor` 在失敗那一支只剩一句話可印。
    **可逆性**:**可逆**——在 `shell` 的 feature 開始對這兩個 `code` 寫處理邏輯之前,改酬載
    只動 `Types.hs` 兩行、`openEnv` 兩行、`renderServiceError` 兩行。`shell` 一旦接上就變成
    有條件可逆(要同步改 `ToSchema` 與 CLI 渲染)。
  - **暫採**:a(骨架已照 a 寫:`RegistryUnavailable RegistryError` /
    `RegistryLoadFailed RegistryError`)→ **影響**:若裁決為 b,改
    `Types.hs:46` 與 `Types.hs:49` 的兩個型別、`openEnv` 的一條失敗路徑、`renderServiceError` 的一格,以及本 spec
    的「對應的 Level 2 契約 › 契約 F」表與 X23。**兩種裁決都要回寫 design.md 契約 F**(`LoadError`
    不存在這件事無論如何都得改)。

- **A2**(**已裁決:接受暫採(2026-08-30 W1 閘門)——一組九個 `ServiceM` 動作(八個 `ask*` +
  `reloadHub`);design.md「模組間公開介面」表已由編排者補上 `Machine / Read / Write → Monad`
  那一列**):`Monad` 要不要對其他模組提供 `Env` 內容的存取器,以及以什麼形式。design.md 的
  「模組間公開介面」表**只有** `Scope → Monad` 一列(`handleFor`),沒有任何一列說 Machine /
  Read / Write 怎麼讀到中樞快照、註冊表或 selector——但 F002 的 `DoctorView` 需要
  `dvHubPath` / `dvHubSource` / `dvRegistry` 三欄,`vaultList` 需要中樞的 `[[vaults]]`,
  而 `Scope` 自己(本 feature)也需要 hub + selector + cwd 才呼叫得了三個 `resolve*`。
  沒有這一組,本 feature 的 `withRead` 就寫不出來。
  - **契約錨點**:design.md「模組間公開介面」表(缺 `Machine / Read / Write → Monad` 那一列);
    契約 A 的 `Env`;契約 C 的 `DoctorView` 的 `dvHubPath` / `dvHubSource` / `dvRegistry` 三欄;
    模組間公開介面的「Machine → `aapms-workspace`」那一列(「`Env` 的中樞快照在寫入後必須重新
    載入」——`reloadHub` 就是這句話的執行點)。**觸及符號**:`Env`、`askHubLocation`、`askHub`、
    `reloadHub`、`askRegistry`、`askNaming`、`askRegistrySource`、`askSelector`、`askCwd`、
    `throwService`、`liftStore`、`liftWorkspace`
  - **層級自答**:出現在邊界上?**會**(它們是 `Monad` 對本套件其餘六個模組的公開介面,而本套件
    模組全部 `exposed`,所以也是套件的對外 API);改錯驚動其他模組?**要**(F002–F008 全部會用)
  - **選項**:
    a) **一組 `ServiceM` 動作(本 spec 暫採)**:`askHub :: ServiceM Hub` 等八個,加
       `reloadHub`——當下成本:九個簽名、九行文檔;`Env` 維持不透明。三個月後代價:每加一個
       `Env` 欄位就要加一個存取器,而存取器是 API,加了就難收回;九個名字要維持一致的命名慣例。
    b) **匯出 `Env` 的欄位選擇器**(`envHub :: Env -> IORef Hub` 等):不必寫存取器,`Env` 直接
       當 record 用——當下成本:零(改一行匯出清單)。三個月後代價:見「不可逆決定」第一列——
       兩類不變量(同一次載入的一致性、可變狀態的鎖保護)都失去型別上的保護,而破壞它們不會有
       編譯錯誤;`IORef` 露在 API 上等於邀請呼叫端在 `runService` 之外讀寫它。
    c) **每個需要的模組自己收參數**(`withRead` 改成 `Hub -> Maybe Text -> …`):`Monad` 完全
       不對外露 `Env` 內容——當下成本:三個 `with*` 與 F002 的十六個操作全部多兩到三個參數,
       而且參數要從 `runService` 一路傳進來。三個月後代價:`ReaderT Env` 這個選擇失去意義
       (design.md「使用的技術」明寫選它的理由是「業務操作是組合的」),等於用手工傳參重新
       實作一次 Reader。
  - **傾向**:**a**。(b) 省下的九行換掉的是 `Env` 的兩類不變量,而那正是 design.md 把 `Env`
    寫成無欄位型別的原因;(c) 與 design.md 明文選定的 `ReaderT Env` 直接衝突。依賴的前提:
    「存取器的數量會隨 `Env` 欄位成長」——會,但成長的上界就是 `Env` 的欄位數,而 `Env` 的欄位
    由契約 A 那一句話(中樞快照 + 註冊表 + selector + cwd + handle 快取 + 鎖)封住了。
    **可逆性**:**有條件可逆**——收回或改名任何一個存取器,要同步改所有呼叫它的模組;波次越
    往後代價越高,所以現在定比 F002 之後定便宜。
  - **暫採**:a(骨架已寫入八個 `ask*` / `reloadHub` 與三個錯誤 helper)→ **影響**:若裁決為 b,
    刪掉 `Monad.hs:167-200` 九個函式、改匯出清單為 `Env (..)`,並改本 spec 的「新增的介面」表與
    X4 / X5 / X6;若裁決為 c,三個 `with*` 的簽名要改,而那三條是 design.md 模組間公開介面表的
    **原文**,等於要一併改 design.md。

- **A3**(**已裁決:接受暫採(2026-08-30 W1 閘門)——`handleFor` 簽名不動,另加
  `indexIssuesFor`;design.md「模組間公開介面」表已由編排者補上 `indexIssuesFor`**):
  `openVault` 一併回的 `[IndexIssue]` 該怎麼傳到 F002 的 `vaultInfo` 的 `viIssues` 欄。
  契約卡沒有答案,是因為 `handleFor :: VaultRef -> ServiceM VaultHandle`(design.md 模組間公開
  介面的原文)沒有這一格,而契約 C 的 `VaultInfoView` 又有 `viIssues :: [IndexIssue]`。實況是
  `openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))`
  (`store/src/Aapms/Store/Marker.hs:207`)——這份清單**只在第一次開啟時產生**,快取命中的第二次
  拿不到。
  - **契約錨點**:design.md 模組間公開介面的 `Scope → Monad`(`handleFor`);契約 C 的
    `VaultInfoView` 的 `viIssues` 欄;契約 A 的 `Env`(「handle 快取」那一格要不要一併存 issues)。
    **觸及符號**:`handleFor`、`indexIssuesFor`、`Env`、`envIndexIssues`、`openVault`、
    `IndexIssue`、`VaultInfoView`、`viIssues`
  - **層級自答**:出現在邊界上?**會**(不論選哪個,`Monad` 對外的介面都會多一個東西);
    改錯驚動其他模組?**要**(F002 的 `vaultInfo` 直接依賴它)
  - **選項**:
    a) **`handleFor` 簽名不動,另加 `indexIssuesFor :: VaultId -> ServiceM [IndexIssue]`
       (本 spec 暫採)**——當下成本:`Env` 多一格 `IORef (Map VaultId [IndexIssue])`,`Monad`
       多一個函式。三個月後代價:多一個「第一次開啟的副產物」要記得維護;`indexIssuesFor` 對
       「還沒開過」與「開過但沒問題」都回 `[]`,分不出來(呼叫端 `vaultInfo` 本來就會先讓它被
       開起來,所以在契約上不構成問題,但這是一個要記得的前提)。
    b) **`handleFor` 改成回 `(VaultHandle, [IndexIssue])`**——當下成本:改一個簽名,`Env` 不必多
       一格。三個月後代價:**不冪等**——快取命中的第二次要回什麼?回 `[]` 就與第一次不同(同一個
       輸入兩種輸出),回存起來的那份就等於 (a) 換一個包裝但每個呼叫端都被迫解一個大多數時候
       用不到的二元組;而 `handleFor` 的呼叫端是三個 `with*` 的每一個 vault,全部都要多解一次。
       這個簽名也不是 design.md 的原文,同樣要回寫。
    c) **`vaultInfo` 自己另跑一次索引檢查**,不靠 `openVault` 的副產物——當下成本:F002 要找一個
       graph-core 的出口重算,而目前**沒有**這樣的出口(`IndexIssue` 只從 `openVault` /
       `openIndexAt` 出來)。三個月後代價:要嘛請 graph-core 加一個出口(跨子系統,而 graph-core
       已凍結交付),要嘛 `vaultInfo` 重開一次 vault——後者會繞過快取,正好是 L8 要擋的事。
  - **傾向**:**a**。(b) 的問題是把一個「只有第一次才有」的值放進一個「每次都會被呼叫」的簽名,
    冪等性從此要靠註解維持;(c) 在 graph-core 已凍結的前提下不可行。依賴的前提:「`vaultInfo`
    會先讓目標 vault 被開起來才問 issues」——這是 design.md 本機管線寫死的順序(「需要節點數時
    (`vaultInfo`)才 `withRead` 開該 vault 的索引」),不是我的假設。
    **可逆性**:**可逆**——`indexIssuesFor` 目前只有 F002 一個未來的呼叫端,現在改或 F002 之後
    改的代價一樣;`Env` 多一格的成本在 `Env` 不透明的前提下對外不可見。
  - **暫採**:a(骨架已寫入 `envIndexIssues` 欄與 `indexIssuesFor`)→ **影響**:若裁決為 b,
    改 `Monad.hs:211` 的 `handleFor` 簽名、刪 `indexIssuesFor` 與 `envIndexIssues` 欄,並改三個
    `with*` 的資料流敘述與 L10;若裁決為 c,刪同樣兩處,並把「`viIssues` 從哪來」列為 F002 的
    阻塞項。

## TodoList

- [ ] `ServiceError` 四個建構子 + `errorCode`(建構子名 snake_case)+ `renderServiceError`(逐字委派)
- [ ] `Env` 十欄 + `ServiceM` 的 `ReaderT` / `ExceptT` 疊法
- [ ] `openEnv`:`hubLocation` → `loadHub` → `locateRegistry` → `loadRegistry` → 建三格可變狀態與鎖
- [ ] `runService`:`withMVar envLock` 包住整段
- [ ] `closeEnv`:關全部 handle、清空快取、冪等
- [ ] `withEnv`:成對包裝,失敗時不呼叫第三參數
- [ ] 八個 `ask*` 存取器 + `reloadHub`
- [ ] `handleFor`:查快取 → `openVault` → 兩張表各放一筆
- [ ] `indexIssuesFor`
- [ ] `throwService` / `liftStore` / `liftWorkspace`
- [ ] `finallyService`:拆 `ServiceM` 的 newtype,成功 / `throwService` 短路兩條路徑都恰好收尾一次
- [ ] `withRead` / `withWrite` / `withPipeline`:`resolve*` → `handleFor` → `openVaultSet` → 以 `finallyService` 收尾 `closeVaultSet`

## 1-to-1 測試對照表

| law / example | 觀察的介面 | 骨架狀態下預期 |
|---|---|---|
| L1, X1 | `openEnv` | 紅 |
| L2–L4, X2, X3, X3b | `openEnv` | 紅 |
| L5, L6, X9, X10 | `closeEnv` | 紅 |
| L7, X11 | `withEnv` | 紅 |
| L8–L10, X7, X8 | `handleFor` / `indexIssuesFor` | 紅 |
| L11, L12, X12, X13 | `runService` | 紅 |
| L13–L15, X14–X16 | `withRead` | 紅 |
| L16, L17, X17, X18 | `withWrite` | 紅 |
| L18, X19, X20 | `withPipeline` | 紅 |
| L19–L22, X21–X23 | `errorCode` / `renderServiceError` | 紅 |
| X4, X5, X5b, X5c, X6 | 八個 `ask*` 存取器與 `reloadHub` | 紅 |
| L24, X26, X27 | `finallyService` | 紅 |
| **L23, X24, X25** | `service/src/` 的**原始碼文字**(`runService` 出現在哪些程式碼行) | **綠** |
| **L25, X28, X29** | `service/src/` 的**原始碼文字**(`instance` / `deriving` 出現在哪些程式碼行) | **綠** |

**除了 L23 / X24 / X25 與 L25 / X28 / X29 之外全部預期紅**。兩類的理由各自具體:

- **紅的那些**:沒有任何一條打在「骨架自身就承載的事實」上——`ServiceError` 的建構子結構確實是
  骨架原文,但每一條與它有關的 law(L19–L22)都要經過 `errorCode` 或 `renderServiceError`,兩者
  都還是 `undefined`。qa 若觀察到其中任何一條**綠**,那是斷言恆真或沒呼叫到受測介面,應退回重寫。
- **綠的那六條**:L23 與 L25 都是對**原始碼文字**的斷言,`spec-roles.md`「qa 的交付判準」第二列
  (骨架自身就承載的事實)適用——它們從第一天就綠,而且**應該**綠;impl 把 `undefined` 換掉之後
  仍須維持綠(那正是這兩條 law 存在的意義:它們守的是 F002–F008,不是本波)。**不得**因為它們綠
  就退回或刪掉。反過來,X25 / X29 是各自的非空洞證明:X24 綠而 X25 不綠(抓不到那條違規)、或
  X28 綠而 X29 不綠,都代表判準寫壞了。

**覆蓋率(步驟 7 第 2 條)**:Laws **25 條**(L1–L25,其中 L23 為 W1 閘門追加,L24 / L25 為 W1
交付後的定向修訂追加)、Examples **32 個**(X1–X29,含 X3b / X5b / X5c);「新增的介面」表共
**26 列**(Types 3 + Monad 20 + Scope 3),每一列至少被一條 law 或一個 example 覆蓋。四處值得
點名:七個 `ask*` 存取器走 `L-` 的理由段 + X4 / X5 / X5b / X5c / X6;`liftStore` / `liftWorkspace`
收的是 `IO (Either …)`,只在呼叫端可觀察,分別由 L9 / X8(`StoreFailed` 短路)與 L16 / X17
(`WorkspaceFailed` 短路)覆蓋;`runService` 由 L11 / L12(執行期)與 L23(原始碼文字)兩個角度
覆蓋;`finallyService` 由 L24 / X26 / X27(執行期,兩條路徑)直接覆蓋,而它**存在的理由**——
「不用實例達成同一件事」——由 L25 / X28 / X29(原始碼文字)從反面守住。

**驗收標準 5 的另一半驗不到**:`RevisionConflict` 與寫入都屬 F004。L11 / X12 只驗互斥本身
(用 `liftIO` 對一個共用 `IORef` 做讀-改-寫),「所以最終 revision 是 +2」留給 F004。

## 實作備註

### 修訂 R2(2026-08-30):收尾能力從 `MonadError` 實例改為 `finallyService` 組合子

**怎麼被發現的**:W1 的 impl 交付後,編排者比對骨架快照,發現
`service/src/Aapms/Service/Monad.hs:140` 多了一行不在骨架裡的
`deriving newtype instance MonadError ServiceError ServiceM`(外加第 1 行的
`{-# LANGUAGE StandaloneDeriving #-}`),而 `Scope.hs` 用 mtl 的 `catchError` 寫了一個私有 helper
`finallyCloseVaultSet`。

**impl 為什麼那樣做**:本 spec「三個 `with*` 的資料流」寫了「結束時(**含例外**)`closeVaultSet`」,
而骨架給 `ServiceM` 的能力只有 `Functor` / `Applicative` / `Monad` / `MonadIO` ——**沒有任何攔截
`throwService` 短路的機制**。impl 要兌現那句話,只剩「自己補一個實例」這一條路。

**歸因:spec bug,不是 impl 錯。** 依 `spec-roles.md`「仲裁協議」第三列——spec 要求的行為在骨架
給的能力範圍內做不出來,對應不上任何一條既有 law 的合法實作路徑。責任在設計:承諾寫了,機制沒給。

**為什麼那個實例不能留**:`MonadError` 實例是**全域可見、匯出清單藏不住**的。任何 import
`Aapms.Service.Monad` 的模組(F002–F008 六個 feature 與三個殼)都自動拿到 `catchError` 與
`throwError` ——兩條沒有登記在 design.md「模組間公開介面」表上的對外 API,其中 `throwError` 還是
一條繞過 `throwService` 的拋出路徑。這與 W1 閘門剛裁決的第一條不可逆決定(`Env` / `ServiceM`
保持不透明)直接衝突,而衝突的形式正是那條決定最怕的那種:**編得過、跑得動、不會有任何編譯錯誤**。

**開發者的裁決(2026-08-30)**:改成不暴露實例的收尾組合子。

- 撤掉 `deriving newtype instance MonadError ServiceError ServiceM` 與 `StandaloneDeriving` pragma;
- `Aapms.Service.Monad` 匯出一個範圍受控的組合子 **`finallyService`**,內部自己拆 `ServiceM` 的
  newtype 做收尾;`Scope.hs` 用它取代 `catchError`;
- `ServiceM` 對外仍然只有 `Functor` / `Applicative` / `Monad` / `MonadIO`。

**本次修訂在 spec 留下的東西**:「新增的介面 › Monad.hs」多一列(第 20 列);Laws 多兩條
(**L24** 釘住組合子在成功與短路兩條路徑都收尾一次,**L25** 以原始碼文字靜態守住「不得有額外
實例」);Examples 多四個(X26 / X27 對應 L24,X28 / X29 對應 L25);「不可逆決定」第一列補上
L25 作為守衛;「三個 `with*` 的資料流」補上收尾走 `finallyService` 的說明。

**一條與 L23 相同的取捨**:L25 寫成靜態斷言而不是靠 review 紀律。理由也相同——它要守的是
**F002–F008 每一波**,而「多 derive 一個實例」在每一波都會長成一個看起來很合理的小改動
(「這樣 `Scope` 就好寫了」),沒有任何編譯期或執行期的信號會反對它。

**一個實作上必須知道的事實**:`.cabal` 的 `default-language` 是 **GHC2021**,而 `StandaloneDeriving`
本來就在 GHC2021 的清單裡——**刪掉 pragma 並不會讓 standalone deriving 編不過**。所以 L25 的主力
是判準 2 / 4(行的形狀),判準 3(pragma)只是輔助。

### 為什麼 L24 / L25 是兩條 law 而不是一條

裁決的字面是「補一條 law + example」,實際寫成兩條,理由是**紅綠判準不同、無法列在同一列**:
L24 是執行期性質,骨架階段 `finallyService = undefined`,預期**紅**;L25 是對原始碼文字的斷言,
適用 `spec-roles.md`「qa 的交付判準」第二列(骨架自身就承載的事實),從第一天就**綠**、而且
**應該**綠。硬併成一條會讓「1-to-1 測試對照表」的「骨架狀態下預期」欄無法填。另一個理由是
「不可逆決定」第一列要引用的守衛**只有靜態的那一半**(L25):L24 是那個決定的**替代方案**,
不是它的守衛。
