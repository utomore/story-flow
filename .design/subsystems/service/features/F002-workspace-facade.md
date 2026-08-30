---
id: F002
type: feature
title: workspace-facade
description: "vault 與專案生命週期、workspace setup / doctor / tools / purge、型別註冊表查詢與縮圖路徑;十五個 ServiceM 動作加一個先於環境的 workspaceSetup"
status: done
created: 2026-08-30
updated: 2026-08-30
depends-on: [F001, graph-core/F001, graph-core/F002, graph-core/F005, graph-core/F006, workspace/F001, workspace/F002, workspace/F004, workspace/F005, workspace/F006]
related-adr: [ADR-006, ADR-013, ADR-015, ADR-017]
related-feature: []
---

# F002: 本機與註冊表門面(workspace-facade)

## 功能概述

`aapms-service` 的第二塊:把 `aapms-workspace` 的生命週期那一組、型別註冊表與縮圖快取包成
`ServiceM` 動作(十六個操作裡的十五個;`workspaceSetup` 是先於環境的頂層 IO,見 A2),並把下層
的報告型別投影成**線上格式**。實作那些操作的模組是 design.md「內部模組劃分」的 **Machine**
一個;六個 View 型別依同一張表住 **Types**(A1),`Machine.hs` 原地 re-export。

本 feature 之後,三個殼的「本機」子指令(`workspace setup / doctor / tools / purge`、
`vault init / add / list / info / forget / check`、`project register / list / forget`、`type list / show`)
都有一份業務契約可包,而且**只有一份**。

**驗收標準**(逐字抄自契約卡):

1. `vaultList` 對每個中樞條目都回一筆,且 `vvReachable == False` 恰好對應 workspace 回報
   `VaultPathMissing` 或 `VaultMarkerBroken` 的那些 — 觀察點:契約 C 的 `vaultList` / `VaultView`
2. 在一個未註冊的 vault 目錄裡 `openEnv` 後,`workspaceDoctor` 的 `dvVaults` 含一筆
   `vvRegistered == False` 的項目 — 觀察點:契約 C 的 `DoctorView` / `VaultView`
3. `dvLlmConfigured` 只反映「中樞有沒有 `[llm]` 段」,而 `DoctorView` 的**任何欄位都不含**該段的值
   (可觀察:把 `api_key` 設成一個特徵字串,整份報告序列化後不含它) — 觀察點:契約 C 的 `DoctorView`
4. `workspaceDoctor` 與 `vaultCheck` 執行前後,中樞目錄與各 vault 的 `.aapms/` 位元組不變 —
   觀察點:契約 C 的 `workspaceDoctor` / `vaultCheck`
5. `vaultInfo` 的 `viCounts` 鍵集合是實際存在的 `IdPrefix` 文字表示,值等於該 vault 索引裡的節點數;
   對一個剛 `vaultInit` 的空 vault 全部為 0 或鍵不出現 — 觀察點:契約 C 的 `VaultInfoView`
6. `vaultInit` / `vaultAdd` / `vaultForget` / `projectRegister` / `projectForget` 之後,同一個 `Env`
   的後續 `vaultList` / `projectList` **看得到變更**(中樞快照有被重新載入) — 觀察點:模組間公開
   介面的 Machine → `aapms-workspace` 那一列、契約 C 的 `vaultList` / `projectList`
7. `showType` 對註冊表沒有的鍵回 `UnknownType` — 觀察點:契約 C 的 `showType`、契約 F 的 `UnknownType`
8. `thumbPath` 對快取裡存在的雜湊回 `Just p` 且 `p` 讀得到、對不存在的回 `Nothing`,而且 `p` 恒等於
   `workspace` 的 `thumbCachePath`(不自己拼路徑) — 觀察點:契約 C 的 `thumbPath`

**2026-08-30 W2 閘門的八條裁決已全部套進本文檔**(四條待確認假設的裁決結果見文末「待確認假設」,
條目保留為決策紀錄)。其中三條改變了本 feature 的形狀:

1. **`workspaceSetup` 移出 `ServiceM`**(A2):新契約是
   `workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)`,與 `openEnv`
   同層。它是十六個操作裡**唯一**不經 `Env` 的一個。
2. **六個 View 型別住 `Aapms.Service.Types`**(A1),`Machine.hs` 在匯出清單裡**原地 re-export**
   ——消費端的 import 路徑不變。
3. **`vaultInit` 回 `(VaultView, AdoptNotice)`**(A3);**`vaultInfo` 直接對參數指定的 vault
   取 handle**(A4,`Machine → Monad` 新增 `handleFor`),不再經 `withRead`。

**驗收標準 7 的 `UnknownType Text` 由本 feature 交付**(W2 閘門阻塞項 1 授權):`Types.hs` 本波
納入寫入白名單,只加這一個建構子與它在 `errorCode` / `renderServiceError` 的兩個分支,規格見
「數據 › `ServiceError` 新增的建構子」。

**明確不做**(逐字抄自契約卡):不重新定義中樞的檔案格式、不自己拼 `.aapms/` 底下的路徑
(一律用 workspace 與 graph-core 的函式);不把 7-Zip 缺席當錯誤;不上 REST 的那幾個操作不得出現在
`shell` 的路由需求裡。追加四條:不做任何圖譜寫入(F004 起);不解讀 selector 字串的比對規則
(`aapms-workspace` 的裁決,本層原樣透傳它的失敗);不決定 HTTP 狀態碼與終端輸出(`shell`);
**不呼叫 `syncHub`** —— 它會寫中樞,而驗收標準 4 要求 `doctor` 與 `check` 位元組不變。

## 相依性

`depends-on` **十項**:同子系統的 `F001`(`ServiceM`、`ask*`、`handleFor` 與錯誤 helper 的來源),
`workspace` 的 `F001` / `F002` / `F004` / `F005` / `F006`(中樞、探測、生命週期、專案、工具),
`graph-core` 的 `F001` / `F002` / `F005` / `F006`(id 與 `Meta`、註冊表、marker 與 schema、
`VaultHandle`、`NodeFilter` 與 `listNodes`)。全部由「使用到的既有串接介面」表逐列反推得出。

**`graph-core/F009` 在 W2 閘門後移出 `depends-on`**:A4 裁決讓 `vaultInfo` 改用單 vault 的
`listNodes`,`VaultSet` / `listAcross`(F009 的跨 vault 組)不再被用到,依步驟 7 第 3 條
「frontmatter 有、候選沒有 → 刪掉」處理。

三個下層子系統的相關 feature 都已 `done`(`graph-core` 9/9、`workspace` 6/6、`service` F001),
本 feature 用到的**六十三個符號**(「使用到的既有串接介面」表的列數)全部打開原始碼讀到簽名原文,
沒有一條是依文檔的介面約定推的。

本子系統內:F008(index-ops)的負責模組同樣含 Machine,會落在同一個檔案上;F003–F007 不依賴本 feature。

## 對應的 Level 2 契約

### 契約 C(全部十六個函式 + 六個型別)

design.md 契約 C 已於 2026-08-30 W2 閘門由編排者回寫;下表的「原文」欄是**回寫後**的版本。

| design.md 契約 C 原文 | 本 feature |
|---|---|
| `workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)` | 交付,簽名逐字(A2 裁決後的新契約;唯一不在 `ServiceM` 裡的操作) |
| `workspaceDoctor :: ServiceM DoctorView` | 交付,簽名逐字 |
| `workspaceTools :: ServiceM [ToolStatus]` | 交付,簽名逐字 |
| `workspacePurge :: PurgeScope -> ServiceM PurgeView` | 交付,簽名逐字 |
| `vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)` | 交付,簽名逐字(A3 裁決後的新契約;`AdoptNotice` 進 re-export 清單) |
| `vaultAdd :: FilePath -> ServiceM VaultView` | 交付,簽名逐字 |
| `vaultList :: ServiceM [VaultView]` | 交付,簽名逐字 |
| `vaultInfo :: Text -> ServiceM VaultInfoView` | 交付,簽名逐字;目標是**參數指到的 vault**(A4) |
| `vaultForget :: Text -> DeleteIndex -> ServiceM VaultView` | 交付,簽名逐字 |
| `vaultCheck :: ServiceM [ScopeIssue]` | 交付,簽名逐字 |
| `projectRegister :: FilePath -> Text -> ServiceM ProjectView` | 交付,簽名逐字 |
| `projectList :: ServiceM [ProjectView]` | 交付,簽名逐字 |
| `projectForget :: Text -> ServiceM ProjectView` | 交付,簽名逐字 |
| `listTypes :: ServiceM [TypeDecl]` | 交付,簽名逐字(與 `Aapms.Core.Registry.listTypes` 撞名,見 S2) |
| `showType :: TypeKey -> ServiceM TypeDecl` | 交付,簽名逐字;失敗路徑**擋在 `UnknownType` 上** |
| `thumbPath :: Sha256 -> ServiceM (Maybe FilePath)` | 交付,簽名逐字 |
| `VaultView`(六欄) | 交付於 `Types.hs`,欄位名與型別逐字 |
| `VaultInfoView`(三欄) | 交付於 `Types.hs`,欄位名與型別逐字 |
| `DoctorView`(七欄) | 交付於 `Types.hs`,欄位名與型別逐字 |
| `ProjectView`(四欄) | 交付於 `Types.hs`,欄位名與型別逐字 |
| `SetupView`(三欄) | 交付於 `Types.hs`,欄位名與型別逐字 |
| `PurgeView`(三欄) | 交付於 `Types.hs`,欄位名與型別逐字 |

六個 View 型別**宣告在 `Aapms.Service.Types`**(A1 裁決),`Machine.hs` 在匯出清單裡原地
re-export:design.md「內部模組劃分」的 Types 列已寫明「**全部 View 型別住這裡**」,而契約卡的
「負責模組:Machine」指的是誰實作那十六個操作。`shell` 兩條 import 路徑都拿得到同一個型別。

契約 C 的 re-export 規則(「`VaultKind` / `InitMode` / `DeleteIndex` / `PurgeScope` / `ScopeIssue` /
`ToolStatus` / `HubSource` 一律 re-export 不重新定義」)照做,另加三個同一條規則涵蓋、但原文沒點名的
(`ToolOrigin`、`IndexIssue`、`AdoptNotice`——後者由 A3 裁決帶進來),並**排除** `RegistrySource`
—— 見下面「待上游 enhance」,是 GHC 的硬限制,不是本層的選擇。

### 契約 F(要用、但不由本 feature 建構的)

| design.md 契約 F 原文 | 本 feature |
|---|---|
| `WorkspaceFailed WorkspaceError` | **使用**(F001 已交付):十四個操作的下層失敗一律原樣包成這一個 |
| `StoreFailed StoreError` | **使用**(F001 已交付):`vaultInfo` 開索引失敗走這一個(`handleFor` 內部就已包好) |
| `UnknownType Text` | **本 feature 交付**(W2 閘門阻塞項 1 授權):建構子 + `errorCode` + `renderServiceError` 三處,規格見「數據」 |

### 模組間公開介面(design.md 表裡本 feature 用到的列)

| design.md 原文 | 本 feature |
|---|---|
| `Read / Write / Machine → Scope`:`withRead` | **本 feature 不使用**。A4 裁決後 `vaultInfo` 改走 `handleFor`,Machine 沒有第二個需要範圍解析的操作;這一列留給 F003 起的讀取操作 |
| `Machine / Read / Write → Monad`:`askHubLocation` / `askHub` / `reloadHub` / `askRegistry` / `askRegistrySource` / `askCwd` / `throwService` / `liftWorkspace` | 使用,**無新增** |
| `Machine → Monad`:`handleFor`(2026-08-30 W2 閘門 A4 新增的一列) | 使用(`vaultInfo` 唯一的用處):對 `lookupSelector` 解出來的那一個 vault 取 handle |
| `Machine → aapms-workspace`:生命週期那一組;`Env` 的中樞快照在寫入後必須重新載入 | 使用;「寫入後重新載入」的執行點是 `reloadHub`,適用範圍逐條釘在 L14 / L13 |
| `Machine → aapms-store`:**查詢組,只讀**(2026-08-30 W2 閘門補列的一列) | 使用(`vaultInfo` 的 `viCounts`:`listNodes` + `NodeFilter`)。**不再需要 `MultiVault`**——A4 之後目標只有一個 vault,不必組 `VaultSet` |
| `Scope → Monad`:`indexIssuesFor :: VaultId -> ServiceM [IndexIssue]` | **使用(呼叫方是 Machine,不是 Scope)**。這是 W1 閘門 A3 加這個介面的**原始理由**(build-log:「`vaultInfo` 的 `viIssues` 欄(F002)要得到它」),但它被寫在 `Scope → Monad` 那一列。建議編排者把它併進新增的 `Machine → Monad` 列(A4 已把 `handleFor` 放在那裡,兩者是同一次呼叫的前後腳) |

**本 feature 不再新增任何表上沒有的邊**:原本標為「新增」的 `Machine → aapms-store` 已由編排者
在 W2 閘門補進 design.md「模組間公開介面」,`Machine → Monad: handleFor` 同樣已補;兩者都列在
下面的「依賴方向」段對帳。

## 實作方式

### 相依性查證(2026-08-30 打開 `core/src/`、`types/src/`、`store/src/`、`workspace/src/`、`service/src/` 讀到的實況)

七件會直接改變設計的事實:

1. **`initVault` 回三個值,不是兩個**:`IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))`
   (`workspace/src/Aapms/Workspace/Lifecycle.hs:147`)。第三個是「掃到的 legacy marker 清單,
   **只報告不刪除**」,而契約 C 原本的 `vaultInit` 只回 `VaultView`,沒有任何欄位裝得下它。
   → A3,**裁決:契約 C 改回 `(VaultView, AdoptNotice)`**,兩個回傳值都不丟。
2. **`setupHub` 只在中樞位置上工作,而 `openEnv` 已經要求中樞載得起來**:`loadHub` 對
   `config.toml` 不存在回 `HubNotFound`(`workspace/src/Aapms/Workspace/Hub.hs:81`,
   F001 的 X2 逐字驗過),`openEnv` 把它包成 `WorkspaceFailed` 就失敗了
   (`service/src/Aapms/Service/Monad.hs:155`)。所以任何 `ServiceM` 動作跑得到的時候,中樞
   **必定已存在**,留在 `ServiceM` 裡的 `workspaceSetup` 會讓 `svHubCreated` 恒為 `False`。
   → A2,**裁決:移出 `ServiceM`**,新契約與 `openEnv` 同層
   (`Maybe Text -> FilePath -> IO (Either ServiceError SetupView)`)。它需要的只有
   `hubLocation :: IO HubLocation`(`workspace/src/Aapms/Workspace/Location.hs:33`)與
   `setupHub`,兩者都不經 `Env`。
3. **`withRead` 用的是 `Env` 的 selector,不是 `vaultInfo` 的參數**
   (`service/src/Aapms/Service/Scope.hs:65` → `askSelector`)。`resolveRead hub (Just s)` 的範圍是
   `{s} ∪ refs*(s)`(`workspace/src/Aapms/Workspace/Scope.hs:81`),所以 `--vault A` 之下
   `vault info B`(B 不在 A 的 `refs*` 裡)拿不到 B 的索引。→ A4,**裁決:`vaultInfo` 改用
   `handleFor`**,直接對參數指到的那一個 vault 取 handle,不再經 `withRead`。
4. **graph-core 沒有任何「數節點」的介面**:`store/src/Aapms/Store/` 底下沒有 `count*`,能拿到
   節點清單的只有 `listNodes :: VaultHandle -> NodeFilter -> IO [Meta]`
   (`store/src/Aapms/Store/Query.hs:240`)與
   `listAcross :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]`
   (`store/src/Aapms/Store/MultiVault.hs:230`)。`viCounts` 因此是「查回來再數」;A4 裁決之後
   目標只有**一個** vault、手上是一個 `VaultHandle`,所以走**單 vault 的 `listNodes`**,
   跨 vault 的 `listAcross` 不再需要(也就不必再從結果裡篩 `VaultId`)。
   **兩個地雷**,規格逐條釘在 L21:
   - `emptyNodeFilter` 的 `nfLimit` 預設是 **1000**(`store/src/Aapms/Store/Query.hs:129`),
     照抄預設會讓超過一千個節點的 vault 靜默少算;
   - `nfIncludeReference` 預設 **`False`**(同檔 `:129`),會把 reference pack 的內容排除在外,
     而「索引裡的節點數」不該漏掉它們。
5. **`readVaultRefAt` 就是「未註冊 vault」的判準**
   (`workspace/src/Aapms/Workspace/Discovery.hs:135`):`vrEntry == Nothing` **當且僅當**中樞裡
   沒有一列的 `veId` 等於 marker 的 `vmId`(身分是 marker 的 id,路徑不參與比對)。`doctor` 的
   `vvRegistered == False` 那一筆用它,不必自己比路徑。
6. **`checkVaults` 不寫檔、沒有失敗通道**(`workspace/src/Aapms/Workspace/Lifecycle.hs:328`),
   而同一段的 `syncHub`(`:343`)**會 `saveHub`**。驗收標準 4 因此把 `syncHub` 排除在本 feature
   之外 —— 兩個函式住在同一個模組、名字只差一個字,是本 feature 最容易踩錯的一步。
7. **`HubSource` 與 `RegistrySource` 各有一個 `FromEnv` 建構子**
   (`workspace/src/Aapms/Workspace/Types.hs:80`、`types/src/Aapms/Types/Loader.hs:67`)。
   F001 的 Laws 段末已把它記為「寫測試時的一個地雷」;在**匯出**這一側它更硬:同一個模組
   同時 re-export 兩者的建構子是 GHC 的 conflicting exports,編不過。
   → W2 閘門裁決:**根治的作法是上游改建構子名**,但那動的是 `aapms-workspace` /
   `aapms-types` 的已交付契約,要另開 enhance,**不在本波**;F002 先照現況走(不 re-export
   `RegistrySource`)。細節見下面「待上游 enhance」。

三件確認過、**不需要**動契約的:

- `detectSevenZip :: ToolsConfig -> IO ToolStatus`(`workspace/src/Aapms/Workspace/Tools.hs:74`)
  **沒有失敗通道**,找不到時回 `ToolStatus "7-Zip" Nothing NotFound searched`。契約 C 的
  `workspaceTools :: ServiceM [ToolStatus]` 因此恒是長度 1 的清單,不是「可能為空」。
- `thumbCachePath :: HubLocation -> Sha256 -> FilePath`(`workspace/src/Aapms/Workspace/Location.hs:60`)
  是純函式,分片規則(前兩碼 / `.png`)完全由它擁有。本層只多做一次存在性檢查,
  一個路徑片段都不拼。
- `hubLlm :: Hub -> Maybe LlmSection`(`workspace/src/Aapms/Workspace/Types.hs:96`)。
  `DoctorView` 沒有任何欄位裝 `LlmSection`,所以「不外洩 `[llm]` 內容」在**型別上**就成立;
  L8 驗的是這一點沒有被某個 `Show` 的旁路破壞。

### 模組配置

一個新檔案 `service/src/Aapms/Service/Machine.hs`,加上對既有 `service/src/Aapms/Service/Types.hs`
的兩處擴充(六個 View 型別、`UnknownType` 建構子)。依賴方向仍是線性的一段,沒有回頭邊:

```text
Types ← Monad ← Machine        （Scope 不在 Machine 的路徑上）
```

A4 裁決之後 `Machine` **不再 import `Scope`**:唯一用過 `withRead` 的 `vaultInfo` 改走
`Monad` 的 `handleFor`,十六個操作因此全部只依賴 `Monad` 的存取器、`handleFor` 與錯誤 helper。
`Types` 依舊不 import 本套件任何模組(六個 View 只依賴 graph-core、`aapms-types` 與 workspace
的型別),型別歸屬圖仍是一棵樹。

### 十六個操作的資料流

四組:三組對應 design.md「本機」管線的三段,外加 A2 裁決之後自成一格的 `workspaceSetup`。

**0. 不經 `Env`(一個):`workspaceSetup`**

```text
hubLocation（讀 AAPMS_HOME / 平台預設）
  → setupHub loc
  → Right report → 逐欄投影成 SetupView
  → Left e       → Left (WorkspaceFailed e)
```

它是十六個操作裡唯一的頂層 `IO`(A2):中樞還不存在時 `openEnv` 一定回 `Left`,留在 `ServiceM`
裡就永遠跑不到。兩個參數(selector 與起點目錄)與 `openEnv` **同形但本層不使用**——中樞位置由
`hubLocation` 從 `AAPMS_HOME` 與平台預設決定,和它們無關;同形是為了讓 `shell` 對本機子指令用
同一種分派。**不得**在本操作裡跑 `Monad` 的執行入口(F001 的 L23;它也不需要 `Env`)。

**A. 只讀中樞快照(不碰檔案系統)**

```text
askHub / askHubLocation / askRegistry / askRegistrySource
  → 投影
```

`vaultList`(逐列投影 `hubVaults`)、`projectList`(逐列投影 `hubProjects`,外加一次
`doesDirectoryExist` 決定 `pvReachable`)、`listTypes`(轉出 `Aapms.Core.Registry.listTypes`)、
`showType`(`lookupType`)。

**B. 讀檔案系統但不寫**

```text
askHub(+ askCwd)→ workspace 的純體檢 / 探測 → 投影
```

- `vaultCheck` = `checkVaults hub`,原樣。
- `workspaceTools` = `[detectSevenZip (hubTools hub)]`。
- `workspaceDoctor` = 中樞位置兩欄 + 註冊表來源一欄 + `vaultList` 的結果(再依 `vaultCheck` 的
  issue 決定 `vvReachable`)+ 向上探測到的那一筆未註冊 vault(有才加)+ `vaultCheck` +
  `workspaceTools` + `[llm]` 存不存在。
- `thumbPath` = `thumbCachePath loc h` + 一次存在性檢查。
- `vaultList` 的 `vvReachable` 與 `doctor` 的 `dvScopeIssues` **來自同一次** `checkVaults`:
  同一個 `ServiceM` 動作裡對中樞重讀兩輪 marker,兩份結果可能不一致,而使用者看到的是同一份報告。

**C. 寫中樞(五個)與開索引(一個)**

```text
askHubLocation + askHub → workspace 的生命週期函式(它自己 saveHub)
  → reloadHub(換掉 Env 的快照)→ 投影被建立 / 被移除的那一列
```

`vaultInit` / `vaultAdd` / `vaultForget` / `projectRegister` / `projectForget` 五個。
下層回 `Left e` 時**一個位元組都沒寫**(那是 workspace 的契約),本層原樣包成 `WorkspaceFailed`
短路,**不呼叫 `reloadHub`**。

`workspacePurge` **不在這一組**:驗收標準 6 只點名上面五個,而 `purge` 刪掉的正是 `reloadHub`
要讀的那個檔 —— 重載必然回 `HubNotFound`(L13)。`workspaceSetup` 更不在:它連 `Env` 都沒有。

`vaultInfo` 是唯一要開索引的(A4 裁決後改走 `handleFor`):

```text
askHub → lookupSelector（失敗原樣透傳）→ 目標的 VaultEntry e
  → readVaultRefAt hub (vePath e)（失敗原樣透傳）→ 目標的 VaultRef
  → handleFor：查 Env 的 handle 快取,缺的才 openVault（開啟失敗以 StoreFailed 短路）
  → listNodes handle（NodeFilter 覆寫 nfLimit 與 nfIncludeReference）→ 依 idPrefix 分組計數
  → indexIssuesFor（目標的 VaultId,取第一次開啟時一併回的清單)
  → VaultInfoView
```

**為什麼不是 `withRead`**:`withRead` 的範圍來自 `--vault`,而 `vault info <sel>` 的語意是
「我點名這一個」;用範圍去解一個點名,`--vault story vault info assets` 會靜默回空的計數。
`handleFor` 仍是本套件**唯一開 handle 的地方**,handle 一樣進 `Env` 的快取、一樣由 `closeEnv`
關,`viIssues` 也因此拿得到(`indexIssuesFor` 讀的正是 `handleFor` 第一次開啟時存下的那份)。

### 撞名的兩處怎麼處理

- **`listTypes`**:本模組的 `listTypes :: ServiceM [TypeDecl]` 與
  `Aapms.Core.Registry.listTypes :: TypeRegistry -> [TypeDecl]` 同名。作法是 **qualified import**
  (`import qualified Aapms.Core.Registry as Registry`),兩邊的名字都不動 —— 契約 C 與 graph-core
  契約各自的原文都是對外契約,為了本層的方便改任何一邊都是把成本推給別人。骨架不含這個
  import(本體是 `undefined`,還用不到),由 impl 加。
- **`FromEnv`**:本波以「不 re-export `RegistrySource`」繞開,根治留給上游 enhance(見下)。

### 待上游 enhance:`RegistrySource` 的 `FromEnv` 衝突

`Aapms.Workspace.Types.HubSource` 與 `Aapms.Types.Loader.RegistrySource` **各有一個叫 `FromEnv`
的建構子**。契約 C 要求本層「一律 re-export 不重新定義」,但同一個模組同時 re-export 兩者的
建構子是 GHC 的 conflicting exports,**編不過**——這是語言的硬限制,不是取捨。

W2 閘門的裁決是**根治:上游改建構子名**(例如 `RegistrySource` 的 `FromEnv` 改成
`RegistryFromEnv`)。那動的是 `aapms-workspace` / `aapms-types` 已交付的契約,要另開一份
enhance,**不在本波**。

**在那份 enhance 落地之前,F002 照現況走**:`Machine.hs` 的匯出清單有 `HubSource (..)`,
**沒有** `RegistrySource`。因此消費端(`shell` 的三個殼、測試)要為 `DoctorView` 的 `dvRegistry`
欄寫出型別、或比對它的建構子時,**得自己 `import Aapms.Types.Loader (RegistrySource (..))`**,
不能只 import `Aapms.Service.Machine`。這是一條已知的、寫下來的例外,不是遺漏。

(`Aapms.Service.Types` 這一側沒有這個問題:它只 import 兩個型別名、不 import 建構子,也不
re-export 任何一個,所以 `DoctorView` 的欄位型別寫得出來。)

## 使用到的既有串接介面

每一列的簽名都是 2026-08-30 打開來源檔案讀到的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newtype ServiceM a`(不透明) | `service/src/Aapms/Service/Monad.hs:138` | `F001` | 十六個操作裡**十五個**的回傳(`workspaceSetup` 是頂層 IO,見 A2) |
| `askHub :: ServiceM Hub` | `service/src/Aapms/Service/Monad.hs:227` | `F001` | A / B / C 三組的入口 |
| `askHubLocation :: ServiceM HubLocation` | `service/src/Aapms/Service/Monad.hs:223` | `F001` | `dvHubPath` / `dvHubSource`、五個寫中樞操作、`thumbPath` |
| `reloadHub :: ServiceM Hub` | `service/src/Aapms/Service/Monad.hs:238` | `F001` | C 組五個操作的收尾 |
| `askRegistry :: ServiceM TypeRegistry` | `service/src/Aapms/Service/Monad.hs:249` | `F001` | `listTypes` / `showType` |
| `askRegistrySource :: ServiceM RegistrySource` | `service/src/Aapms/Service/Monad.hs:257` | `F001` | `dvRegistry` |
| `askCwd :: ServiceM FilePath` | `service/src/Aapms/Service/Monad.hs:265` | `F001` | `doctor` 的未註冊 vault 探測起點 |
| `indexIssuesFor :: VaultId -> ServiceM [IndexIssue]` | `service/src/Aapms/Service/Monad.hs:296` | `F001` | `viIssues` |
| `throwService :: ServiceError -> ServiceM a` | `service/src/Aapms/Service/Monad.hs:303` | `F001` | `showType` 的失敗路徑 |
| `liftWorkspace :: IO (Either WorkspaceError a) -> ServiceM a` | `service/src/Aapms/Service/Monad.hs:314` | `F001` | 五個寫中樞操作、`purge`、`vaultInfo` 的 `readVaultRefAt`(`workspaceSetup` **用不到**:它不在 `ServiceM` 裡,自己 `case` 下層的 `Either`) |
| `handleFor :: VaultRef -> ServiceM VaultHandle` | `service/src/Aapms/Service/Monad.hs:276` | `F001` | `vaultInfo`(A4:對參數指到的 vault 取 handle);開啟失敗已由它包成 `StoreFailed` |
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection, vhRegistry :: TypeRegistry }` | `store/src/Aapms/Store/Marker.hs:75` | `graph-core/F005` | `handleFor` 的回傳、`listNodes` 的第一參數 |
| `data HubLocation = HubLocation { hlPath :: FilePath, hlSource :: HubSource }` | `workspace/src/Aapms/Workspace/Types.hs:72` | `workspace/F001` | `dvHubPath` / `dvHubSource` / `svHubPath` |
| `data HubSource = FromEnv \| FromPlatformDefault` | `workspace/src/Aapms/Workspace/Types.hs:80` | `workspace/F001` | `dvHubSource`;re-export |
| `hubVaults :: Hub -> [VaultEntry]` | `workspace/src/Aapms/Workspace/Types.hs:92` | `workspace/F001` | `vaultList` |
| `hubProjects :: Hub -> [ProjectEntry]` | `workspace/src/Aapms/Workspace/Types.hs:94` | `workspace/F001` | `projectList` |
| `hubLlm :: Hub -> Maybe LlmSection` | `workspace/src/Aapms/Workspace/Types.hs:96` | `workspace/F001` | `dvLlmConfigured` |
| `hubTools :: Hub -> ToolsConfig` | `workspace/src/Aapms/Workspace/Types.hs:99` | `workspace/F001` | `workspaceTools` |
| `data VaultEntry = VaultEntry { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:123` | `workspace/F001` | `VaultView` 的前四欄 |
| `data ProjectEntry = ProjectEntry { peId :: Id, peName :: Text, pePath :: FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:136` | `workspace/F001` | `ProjectView` 的前三欄 |
| `data ScopeIssue = VaultPathMissing VaultEntry FilePath \| VaultMarkerBroken VaultEntry StoreError \| VaultIdDrift VaultEntry VaultId \| RefVaultNotRegistered VaultId VaultId` | `workspace/src/Aapms/Workspace/Types.hs:174` | `workspace/F001` | `vaultCheck` / `dvScopeIssues`;`vvReachable` 的判準;re-export |
| `data SetupReport = SetupReport { spHubPath :: FilePath, spHubCreated :: Bool, spCacheCreated :: Bool }` | `workspace/src/Aapms/Workspace/Types.hs:233` | `workspace/F001` | `SetupView` 的被投影者 |
| `data PurgeReport = PurgeReport { prHubRemoved :: Bool, prThumbsRemoved :: Int, prVaultIndexesRemoved :: [FilePath] }` | `workspace/src/Aapms/Workspace/Types.hs:249` | `workspace/F001` | `PurgeView` 的被投影者 |
| `newtype AdoptNotice = AdoptNotice { anLegacyMarkers :: [FilePath] }` | `workspace/src/Aapms/Workspace/Types.hs:241` | `workspace/F001` | `vaultInit` 的第三個回傳值(A3) |
| `data InitMode = FreshVault \| AdoptExisting` | `workspace/src/Aapms/Workspace/Types.hs:215` | `workspace/F001` | `vaultInit` 參數;re-export |
| `data DeleteIndex = KeepIndex \| DeleteIndex` | `workspace/src/Aapms/Workspace/Types.hs:224` | `workspace/F001` | `vaultForget` 參數;re-export |
| `data PurgeScope = PurgeHubOnly \| PurgeAllVaults` | `workspace/src/Aapms/Workspace/Types.hs:228` | `workspace/F001` | `workspacePurge` 參數;re-export |
| `data ToolOrigin = FromToolsConfig \| FromPath \| FromCandidate \| NotFound` | `workspace/src/Aapms/Workspace/Types.hs:259` | `workspace/F001` | `ToolStatus` 的欄位型別;re-export |
| `data ToolStatus = ToolStatus { tsName :: Text, tsPath :: Maybe FilePath, tsOrigin :: ToolOrigin, tsSearched :: [FilePath] }` | `workspace/src/Aapms/Workspace/Types.hs:271` | `workspace/F001` | `workspaceTools` / `dvTools`;re-export |
| `data WorkspaceError`(21 個建構子) | `workspace/src/Aapms/Workspace/Types.hs:289` | `workspace/F001` | 失敗一律包成 `WorkspaceFailed` |
| `thumbCachePath :: HubLocation -> Sha256 -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:60` | `workspace/F001` | `thumbPath` 的**唯一**路徑來源 |
| `hubLocation :: IO HubLocation` | `workspace/src/Aapms/Workspace/Location.hs:33` | `workspace/F001` | `workspaceSetup` 取中樞位置(它沒有 `Env`,拿不到 `askHubLocation`) |
| `detectVault :: FilePath -> IO (Maybe FilePath)` | `workspace/src/Aapms/Workspace/Discovery.hs:53` | `workspace/F002` | `doctor` 的未註冊 vault 探測 |
| `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | `workspace/src/Aapms/Workspace/Discovery.hs:77` | `workspace/F002` | `vaultInfo` 的 selector 解析 |
| `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)` | `workspace/src/Aapms/Workspace/Discovery.hs:135` | `workspace/F002` | `doctor` 判斷「這個 vault 有沒有註冊」 |
| `data VaultRef = VaultRef { vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }` | `workspace/src/Aapms/Workspace/Types.hs:163` | `workspace/F001` | 未註冊那一筆 `VaultView` 的來源 |
| `setupHub :: HubLocation -> IO (Either WorkspaceError SetupReport)` | `workspace/src/Aapms/Workspace/Lifecycle.hs:95` | `workspace/F004` | `workspaceSetup` |
| `initVault :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))` | `workspace/src/Aapms/Workspace/Lifecycle.hs:147` | `workspace/F004` | `vaultInit` |
| `addVault :: HubLocation -> Hub -> FilePath -> IO (Either WorkspaceError (Hub, VaultEntry))` | `workspace/src/Aapms/Workspace/Lifecycle.hs:210` | `workspace/F004` | `vaultAdd` |
| `forgetVault :: HubLocation -> Hub -> Text -> DeleteIndex -> IO (Either WorkspaceError (Hub, VaultEntry))` | `workspace/src/Aapms/Workspace/Lifecycle.hs:243` | `workspace/F004` | `vaultForget` |
| `purge :: HubLocation -> Hub -> PurgeScope -> IO (Either WorkspaceError PurgeReport)` | `workspace/src/Aapms/Workspace/Lifecycle.hs:285` | `workspace/F004` | `workspacePurge` |
| `checkVaults :: Hub -> IO [ScopeIssue]` | `workspace/src/Aapms/Workspace/Lifecycle.hs:328` | `workspace/F004` | `vaultCheck` / `dvScopeIssues` / `vvReachable` |
| `registerProject :: HubLocation -> Hub -> FilePath -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))` | `workspace/src/Aapms/Workspace/Projects.hs:83` | `workspace/F005` | `projectRegister` |
| `forgetProject :: HubLocation -> Hub -> Text -> IO (Either WorkspaceError (Hub, ProjectEntry))` | `workspace/src/Aapms/Workspace/Projects.hs:130` | `workspace/F005` | `projectForget` |
| `detectSevenZip :: ToolsConfig -> IO ToolStatus` | `workspace/src/Aapms/Workspace/Tools.hs:74` | `workspace/F006` | `workspaceTools` |
| `data IdPrefix = PEnt \| PAst \| PPck \| PLic \| PLvl \| PNod \| PVlt \| PPrj` | `core/src/Aapms/Core/Id.hs:46` | `graph-core/F001` | `viCounts` 的分組鍵 |
| `renderIdPrefix :: IdPrefix -> Text` | `core/src/Aapms/Core/Id.hs:57` | `graph-core/F001` | `viCounts` 的鍵文字 |
| `idPrefix :: Id -> IdPrefix` | `core/src/Aapms/Core/Id.hs:139` | `graph-core/F001` | `viCounts` 的分組 |
| `newtype VaultId = VaultId Text` | `core/src/Aapms/Core/Id.hs:148` | `graph-core/F001` | `vvId`、`indexIssuesFor` 的鍵 |
| `newtype Id = Id Text` | `core/src/Aapms/Core/Id.hs:86` | `graph-core/F001` | `pvId` |
| `newtype Sha256 = Sha256 Text` | `core/src/Aapms/Core/Asset.hs:18` | `graph-core/F001` | `thumbPath` 參數 |
| `newtype TypeKey = TypeKey Text` | `core/src/Aapms/Core/Meta.hs:45` | `graph-core/F001` | `showType` 參數;`UnknownType` 的酬載來源 |
| `data Meta = Meta { metaId :: Id, metaVault :: VaultId, … }` | `core/src/Aapms/Core/Meta.hs`(`data Meta`) | `graph-core/F001` | `viCounts` 的計數對象 |
| `data TypeDecl = TypeDecl { tdKey :: TypeKey, tdName :: Text, tdFamily :: Family, … }` | `core/src/Aapms/Core/Registry.hs:88` | `graph-core/F002` | `listTypes` / `showType` 的回傳 |
| `listTypes :: TypeRegistry -> [TypeDecl]`(依 `tdKey` 排序) | `core/src/Aapms/Core/Registry.hs:159` | `graph-core/F002` | 本層 `listTypes` 的唯一來源(qualified) |
| `lookupType :: TypeRegistry -> TypeKey -> Maybe TypeDecl` | `core/src/Aapms/Core/Registry.hs:155` | `graph-core/F002` | `showType` |
| `data RegistrySource = FromEnv \| BesideExecutable \| FromDataDir` | `types/src/Aapms/Types/Loader.hs:67` | `graph-core/F002` | `dvRegistry`(**不** re-export,見「待上游 enhance」) |
| `data VaultKind = AssetVault \| StoryVault` | `store/src/Aapms/Store/Schema.hs:63` | `graph-core/F005` | `vvKind` / `vaultInit` 參數;re-export |
| `data IndexIssue`(五個建構子) | `store/src/Aapms/Store/Schema.hs:85` | `graph-core/F005` | `viIssues`;re-export |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:59` | `graph-core/F005` | 未註冊那一筆 `VaultView` 的前四欄 |
| `data NodeFilter = NodeFilter { nfPrefixes :: [IdPrefix], …, nfIncludeReference :: Bool, nfLimit :: Int, nfOffset :: Int }` | `store/src/Aapms/Store/Query.hs:102` | `graph-core/F006` | `viCounts` 的查詢條件 |
| `emptyNodeFilter :: NodeFilter`(`nfLimit = 1000`、`nfIncludeReference = False`) | `store/src/Aapms/Store/Query.hs:119` | `graph-core/F006` | 同上;**兩個預設值都要改**(L21) |
| `listNodes :: VaultHandle -> NodeFilter -> IO [Meta]` | `store/src/Aapms/Store/Query.hs:240` | `graph-core/F006` | `viCounts` 的唯一資料來源(A4 之後目標只有一個 vault,不再需要 `MultiVault` 的 `listAcross`) |

## 新增的介面

### `service/src/Aapms/Service/Types.hs`(A1 之後六個 View 型別的家;既有檔案的擴充)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data SetupView = SetupView { svHubPath :: FilePath, svHubCreated :: Bool, svCacheCreated :: Bool }` | `workspace setup` 的線上投影 | `service/src/Aapms/Service/Types.hs:64` |
| `data PurgeView = PurgeView { pvHubRemoved :: Bool, pvThumbsRemoved :: Int, pvVaultIndexesRemoved :: [FilePath] }` | `workspace purge` 的線上投影 | `service/src/Aapms/Service/Types.hs:76` |
| `data VaultView = VaultView { vvId :: VaultId, vvName :: Text, vvKind :: VaultKind, vvPath :: FilePath, vvRegistered :: Bool, vvReachable :: Bool }` | 一個 vault 在本機的樣子 | `service/src/Aapms/Service/Types.hs:91` |
| `data VaultInfoView = VaultInfoView { viVault :: VaultView, viCounts :: [(Text, Int)], viIssues :: [IndexIssue] }` | 一筆 `VaultView` 加上要開索引才算得出來的兩欄 | `service/src/Aapms/Service/Types.hs:110` |
| `data DoctorView = DoctorView { dvHubPath :: FilePath, dvHubSource :: HubSource, dvRegistry :: RegistrySource, dvVaults :: [VaultView], dvScopeIssues :: [ScopeIssue], dvTools :: [ToolStatus], dvLlmConfigured :: Bool }` | 這台機器的狀態彙總 | `service/src/Aapms/Service/Types.hs:124` |
| `data ProjectView = ProjectView { pvId :: Id, pvName :: Text, pvPath :: FilePath, pvReachable :: Bool }` | 一個已登錄專案在本機的樣子 | `service/src/Aapms/Service/Types.hs:141` |
| `UnknownType Text`(`ServiceError` 的第五個建構子) | 註冊表裡沒有這個型別鍵;酬載是那個鍵的字串本身 | `service/src/Aapms/Service/Types.hs:176` |

`UnknownType` 連帶擴充 F001 已交付的兩個全函式各**一個分支**:`errorCode`
(`service/src/Aapms/Service/Types.hs:193`)與 `renderServiceError`
(`service/src/Aapms/Service/Types.hs:213`)。規格見「數據」。

### `service/src/Aapms/Service/Machine.hs`

十六個函式;六個 View 型別在匯出清單裡**原地 re-export**(宣告在上表)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)` | 建立中樞註冊表檔與縮圖快取目錄;冪等;不經 `Env` | `service/src/Aapms/Service/Machine.hs:142` |
| `workspaceDoctor :: ServiceM DoctorView` | 彙總這台機器的狀態;不寫任何檔案 | `service/src/Aapms/Service/Machine.hs:149` |
| `workspaceTools :: ServiceM [ToolStatus]` | 探測這台機器上的外部工具;缺席不是錯誤 | `service/src/Aapms/Service/Machine.hs:153` |
| `workspacePurge :: PurgeScope -> ServiceM PurgeView` | 清理中樞與(可選)各 vault 的索引;冪等 | `service/src/Aapms/Service/Machine.hs:160` |
| `vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)` | 在一個目錄上建立 vault 並登錄進中樞;第二個回傳值是掃到的舊 marker 清單 | `service/src/Aapms/Service/Machine.hs:174` |
| `vaultAdd :: FilePath -> ServiceM VaultView` | 把一個已經是 vault 的目錄納管進中樞 | `service/src/Aapms/Service/Machine.hs:178` |
| `vaultList :: ServiceM [VaultView]` | 中樞裡的每一列各回一筆,順序同中樞 | `service/src/Aapms/Service/Machine.hs:182` |
| `vaultInfo :: Text -> ServiceM VaultInfoView` | 一個 vault 的詳情;本模組唯一要開索引的操作 | `service/src/Aapms/Service/Machine.hs:190` |
| `vaultForget :: Text -> DeleteIndex -> ServiceM VaultView` | 把一個 vault 從中樞移除 | `service/src/Aapms/Service/Machine.hs:195` |
| `vaultCheck :: ServiceM [ScopeIssue]` | 對中樞每一列重讀 marker 的純體檢 | `service/src/Aapms/Service/Machine.hs:199` |
| `projectRegister :: FilePath -> Text -> ServiceM ProjectView` | 把一個目錄登錄成專案 | `service/src/Aapms/Service/Machine.hs:206` |
| `projectList :: ServiceM [ProjectView]` | 中樞裡的每一列各回一筆,順序同中樞 | `service/src/Aapms/Service/Machine.hs:210` |
| `projectForget :: Text -> ServiceM ProjectView` | 把一列從中樞移除;專案目錄本身完全不動 | `service/src/Aapms/Service/Machine.hs:214` |
| `listTypes :: ServiceM [TypeDecl]` | 型別註冊表的全部宣告,本層不過濾、不重排 | `service/src/Aapms/Service/Machine.hs:224` |
| `showType :: TypeKey -> ServiceM TypeDecl` | 依鍵查一份型別宣告;沒有這個鍵時以 `UnknownType` 短路 | `service/src/Aapms/Service/Machine.hs:229` |
| `thumbPath :: Sha256 -> ServiceM (Maybe FilePath)` | 一個內容位址對應的縮圖檔在哪裡 | `service/src/Aapms/Service/Machine.hs:241` |

匯出清單另含**十項 re-export**(不是新介面,不重新定義):`VaultKind (..)` / `InitMode (..)` /
`DeleteIndex (..)` / `PurgeScope (..)` / `ScopeIssue (..)` / `ToolStatus (..)` / `ToolOrigin (..)` /
`HubSource (..)` / `IndexIssue (..)` / `AdoptNotice (..)`,以及六個 View 型別的原地 re-export。

## 數據

### `ServiceError` 新增的建構子(**本 feature 交付**;W2 閘門阻塞項 1 授權)

`Types.hs` 本波納入寫入白名單,只加這一個建構子與它的兩個分支;既有四個建構子與它們在
`errorCode` / `renderServiceError` 的分支**一個字都不動**:

| 建構子(design.md 契約 F 原文) | `errorCode` | `renderServiceError` | 誰用 |
|---|---|---|---|
| `UnknownType Text` | `unknown_type` | 本層自撰(**不委派**:下面沒有對應的錯誤原件)。繁中,說出下一步——訊息**必須含酬載那個鍵的字串**,並告訴使用者去型別註冊表目錄補宣告、或用 `type list` 看有哪些 | `showType`(L24 / X23);F004 起的寫入路徑同用 |

`code` 依 F001 的規則(建構子名的 snake_case)產生,不需要另行裁定。`renderServiceError` 的
「一律逐字委派下層 `render*`」是**四個包裝建構子**的規則(F001 不可逆決定第四列),`UnknownType`
不是包裝建構子,它是本層自己的判斷,訊息因此也由本層擁有 —— 這與「本層擁有錯誤語彙」一致。

**建構子的位置**:排在 `RegistryLoadFailed` 之後,與 design.md 契約 F 的列舉順序一致
(`ValidationFailed` 之後的其餘建構子屬 F003–F006,屆時插在它前後不影響本條)。

**為什麼這兩個分支不是 `undefined`**:骨架規則(本體一律未實作標記)守的是**本 feature 的新
介面**;`errorCode` / `renderServiceError` 是 F001 已交付的**全函式**,在它們身上留一個
`undefined` 分支等於把一個已交付的介面變成部分函數,而且沒有任何 F002 的操作會去填它。
兩個分支因此在骨架階段就寫完,對應的 L27 / X27 依 `spec-roles.md` 交付判準第二列(骨架自身
承載的事實)**從第一天就綠**。

### `viCounts` 的鍵

鍵是 `renderIdPrefix` 的輸出,值域是八個字串之一:

| `IdPrefix` | 鍵 |
|---|---|
| `PEnt` | `ent` |
| `PAst` | `ast` |
| `PPck` | `pck` |
| `PLic` | `lic` |
| `PLvl` | `lvl` |
| `PNod` | `nod` |
| `PVlt` | `vlt` |
| `PPrj` | `prj` |

清單依 `IdPrefix` 的 `Ord`(宣告順序,`deriving stock (… Ord, Enum, Bounded)`)排序,**值為零的
鍵不出現**。契約卡的驗收標準 5 對空 vault 明文允許「全部為 0 **或**鍵不出現」,本 feature 取後者
(理由見 S4)。

### `vvReachable` 的判準

對中樞的一列 `e`,令 `issues = checkVaults hub`:

| `issues` 裡與 `e` 有關的那一則 | `vvReachable` |
|---|---|
| 沒有 | `True` |
| `VaultPathMissing e _` | `False` |
| `VaultMarkerBroken e _` | `False` |
| `VaultIdDrift e _` | `True` |

`RefVaultNotRegistered` 不描述中樞的某一列(`checkVaults` 明文「不展開 `refs`,永遠不產生它」),
不參與本判準。

### 測試素材:一組固定的工作區佈局

Laws 與 Examples 以 F001「測試素材」那一組佈局為基準(qa 自行以 `temporary` 建在暫存目錄下,
`AAPMS_HOME` 指向 `hub/`,`STORYFLOW_REGISTRY` 指向專案的 `types/registry/`):

```text
<tmp>/hub/config.toml          -- [[vaults]] 兩列:VA(story)、VB(asset);無 [llm];無 [[projects]]
<tmp>/va/.aapms/config.toml    -- id = VA, kind = story, name = "story", refs = []
<tmp>/vb/.aapms/config.toml    -- id = VB, kind = asset, name = "assets", refs = []
<tmp>/outside/                 -- 不是 vault,也不在任何 vault 底下
<tmp>/proj/                    -- 一個普通目錄,供 projectRegister 用
```

## Laws

### `vaultList` 與 `VaultView`

- **L1**(逐列對應):對所有中樞內容,`vaultList` 的長度等於 `hubVaults hub` 的長度,第 `i` 筆的
  `vvId` / `vvName` / `vvKind` / `vvPath` 逐欄等於 `hubVaults hub !! i` 的
  `veId` / `veName` / `veKind` / `vePath`,**順序相同**。中樞沒有任何 vault 時回 `Right []`。
- **L2**(`vvRegistered` 恒真):對所有中樞內容,`vaultList` 的每一筆 `vvRegistered == True`
  ——它逐列來自中樞,「在中樞裡」是它的建構前提。
- **L3**(`vvReachable` 的判準):對所有中樞內容,
  `[vvId v | v <- vaultList, not (vvReachable v)]` 這個集合,**恰等於**
  `[veId e | VaultPathMissing e _ <- checkVaults hub] ++ [veId e | VaultMarkerBroken e _ <- checkVaults hub]`
  的集合。`VaultIdDrift` 出現在 `checkVaults` 的結果裡時,對應那一列的 `vvReachable` 仍為 `True`。

### `vaultCheck`

- **L4**(原樣轉出):對所有中樞內容,`vaultCheck` 的結果與 `checkVaults hub`(同一份中樞快照)
  **逐項相同、順序相同**。本層不過濾、不排序、不翻譯,也不合併。

### `workspaceDoctor`

- **L5**(六欄的來源):對所有中樞內容與所有起點,`workspaceDoctor` 回的 `DoctorView` 滿足
  `dvHubPath == hlPath loc`、`dvHubSource == hlSource loc`(`loc` = `askHubLocation`)、
  `dvRegistry == askRegistrySource`、`dvScopeIssues == vaultCheck`、`dvTools == workspaceTools`、
  `dvLlmConfigured == True` ⟺ `hubLlm hub` 是 `Just _`。
- **L6**(`dvVaults` 含 `vaultList` 全部):對所有中樞內容,`dvVaults` 的**前 `n` 筆**
  (`n` = `length (hubVaults hub)`)逐欄等於 `vaultList` 的結果;其後至多一筆,且那一筆的
  `vvRegistered == False`。
- **L7**(未註冊那一筆的存在條件):對所有起點 `cwd`,`dvVaults` 含 `vvRegistered == False` 的那一筆
  **當且僅當** `detectVault cwd` 回 `Just root`、`readVaultRefAt hub root` 回 `Right ref`、且
  `vrEntry ref == Nothing`。此時該筆的 `vvId` / `vvName` / `vvKind` 逐欄等於
  `vmId` / `vmName` / `vmKind` 對 `vrMarker ref` 的取值,`vvPath == vrPath ref`,
  `vvReachable == True`(marker 剛剛讀成功)。
  `detectVault` 回 `Nothing`、或 `readVaultRefAt` 回 `Left _` 時,`workspaceDoctor` 仍回 `Right`,
  只是不含這一筆 —— `DoctorView` 沒有任何欄位裝得下「探測到一個 marker 讀不開的目錄」,而
  `ScopeIssue` 的三個建構子都要求一列 `VaultEntry`,對未註冊的 vault 根本構造不出來
  (`workspace/F002` 的 haddock 明文)。
- **L8**(`[llm]` 內容不外洩):對所有 `[llm]` 段內容 `s`(視為一組字串),`show doctorView` 不含
  `s` 的任何鍵或值作為子字串;`dvLlmConfigured` 只反映該段**存不存在**。
- **L9**(唯讀):對所有中樞內容與所有起點,`workspaceDoctor` 與 `vaultCheck` 執行前後,中樞目錄
  與每個 vault 的 `.aapms/` 底下**所有檔案的存在性與位元組內容都相同**。

### `workspaceTools`

- **L10**(單筆、無失敗通道):對所有中樞內容,`workspaceTools` 恒回 `Right`,清單長度恰為 `1`,
  該筆等於 `detectSevenZip (hubTools hub)`(逐欄)。7-Zip 三層都找不到時該筆是
  `tsPath == Nothing`、`tsOrigin == NotFound`、`tsSearched` **非空**,而操作**仍然成功**。

### `workspaceSetup` / `workspacePurge`

- **L11**(`SetupView` 是逐欄投影,而且兩個參數不影響結果):對所有中樞狀態、所有 selector `sel`
  與所有起點 `cwd`,`workspaceSetup sel cwd` 回 `Right v` 時,`v` 的
  `svHubPath` / `svHubCreated` / `svCacheCreated` 逐欄等於**同一次** `setupHub loc` 回的
  `SetupReport` 的 `spHubPath` / `spHubCreated` / `spCacheCreated`(`loc` = `hubLocation`);
  回 `Left e` 時 `e == WorkspaceFailed e'`,`e'` 是 `setupHub` 回的那一個,逐欄相同。
  **它不開 `Env`**:中樞不存在時仍跑得起來(這正是 A2 把它移出 `ServiceM` 的理由),而且對同一個
  中樞位置,不同的 `sel` / `cwd` 得到**逐欄相同**的結果 —— 中樞位置只由 `hubLocation` 決定。
- **L12**(`PurgeView` 是逐欄投影):對所有 `scope`,`workspacePurge scope` 成功時回的 `PurgeView`
  的三欄逐欄等於**同一次** `purge loc hub scope` 回的 `PurgeReport` 的三欄;
  `scope == PurgeHubOnly` 時 `pvVaultIndexesRemoved == []`。
- **L13**(`purge` 不重載中樞快照):對所有 `scope`,`workspacePurge scope` 成功之後,同一個 `Env`
  的 `askHub` 回的中樞快照與呼叫前**逐欄相同** —— 中樞檔剛被自己刪掉,重載必然是
  `WorkspaceFailed (HubNotFound _)`,而 `purge` 的結果是成功的。`workspaceSetup` 連 `Env` 都
  沒有,更不可能重載任何快照(A2)。

### 五個寫中樞的操作

- **L14**(寫後同一個 `Env` 看得到):對 `vaultInit` / `vaultAdd` / `vaultForget` /
  `projectRegister` / `projectForget` 中任一次**成功**的呼叫,同一個 `Env` 的後續 `vaultList` /
  `projectList` 反映該次變更 —— 新增的那一列出現、被移除的那一列消失,且新的清單與
  「重新 `openEnv` 之後跑同一個查詢」的結果**逐項相同**。
- **L15**(`vaultInit` / `vaultAdd` 回的那一筆):兩者成功時回的 `VaultView`(`vaultInit` 取
  tuple 的**第一個分量**)的 `vvId` / `vvName` / `vvKind` / `vvPath` 逐欄等於下層回的
  `VaultEntry`,`vvRegistered == True`,`vvReachable == True`(marker 剛被寫出或剛被讀成功)。
  `vaultInit` 的**第二個分量**逐欄等於**同一次** `initVault` 回的 `AdoptNotice`
  (`anLegacyMarkers` 逐項相同、順序相同):本層**不過濾、不刪除、不重排**那份清單,也不因為它
  非空而改變第一個分量的任何一欄。沒有掃到 legacy marker 時它是 `AdoptNotice []`。
- **L16**(`vaultForget` 回的那一筆):成功時回的 `VaultView` 的前四欄逐欄等於**被移除的**那一列
  `VaultEntry`,`vvRegistered == False`(它已經不在中樞了),`vvReachable` 依 L3 的同一判準計算
  (`vault forget` 不刪 marker,所以正常情況下仍為 `True`)。
- **L17**(失敗即原樣包、什麼都不動):對五個寫中樞的操作與 `vaultInfo`,下層回 `Left e` 時本層
  回 `Left (WorkspaceFailed e)`,`e` **逐欄相同**;且此時同一個 `Env` 的 `askHub` 與中樞檔的
  位元組都與呼叫前相同(本層不呼叫 `reloadHub`)。

### `projectList` / `projectRegister` / `projectForget`

- **L18**(逐列對應):對所有中樞內容,`projectList` 的長度等於 `hubProjects hub` 的長度,第 `i` 筆
  的 `pvId` / `pvName` / `pvPath` 逐欄等於 `hubProjects hub !! i` 的 `peId` / `peName` / `pePath`,
  順序相同;`pvReachable == True` **當且僅當** `pePath` 是一個既存目錄。
- **L19**(回的那一筆):`projectRegister` 成功時回的 `ProjectView` 前三欄逐欄等於下層回的
  `ProjectEntry`;`projectForget` 成功時回的是**被移除的**那一列。兩者的 `pvReachable` 依 L18 的
  同一判準計算。

### `vaultInfo`

- **L20**(`viVault` 與 selector):對所有 selector `s`,`lookupSelector hub s` 回 `Right e` 時
  `vaultInfo s` 的 `viVault` 逐欄等於 `vaultList` 裡 `vvId == veId e` 的那一筆;回 `Left err` 時
  `vaultInfo s` 回 `Left (WorkspaceFailed err)`,`err` 逐欄相同(`VaultSelectorNotFound` 與
  `VaultSelectorAmbiguous` **原樣透傳**,本層不重新解釋 selector)。
- **L21**(`viCounts`):對**中樞裡的任一 vault** 與**任一 `--vault` selector**(含 `Nothing`),
  `viCounts` 是「該 vault 索引裡每個 `IdPrefix` 的節點總數」的清單:鍵是 `renderIdPrefix p`,
  值 `> 0`,**值為零的 prefix 不出現**,清單依 `IdPrefix` 的 `Ord` 排序。「總數」不受任何分頁
  上限影響(`nfLimit` 的預設值 `1000` 不得成為答案的上界),也**不排除** reference pack 的內容
  (`nfIncludeReference` 的預設值 `False` 不得成為答案的濾網)。索引裡一個節點都沒有時
  `viCounts == []`。
  **`Env` 的 `--vault` 不影響本操作**(A4 裁決):目標是參數解出來的那一個 vault,`vaultInfo`
  直接對它取 handle,所以 `--vault A` 之下問 B 仍算得出 B 的節點數(X28),**不會**靜默回空。
- **L22**(`viIssues`):對中樞裡的任一 vault,`viIssues` 等於該 vault 在本次執行期間**第一次**
  被開啟時一併回報的 `[IndexIssue]`(即 `indexIssuesFor` 對該 vault 的 `VaultId` 的結果),
  逐項相同、順序相同。本層不過濾、不合併。本操作自己就會讓目標被開起來(`handleFor`),所以
  這一欄與 `--vault` 無關,不會出現「沒開過因此為空」的情況。

### `listTypes` / `showType`

- **L23**(`listTypes` 逐項轉出):對所有註冊表,`listTypes` 的結果與
  `Aapms.Core.Registry.listTypes reg`(`reg` = `askRegistry`)**逐項相同、順序相同**。本層不過濾、
  不重排、不改寫任何欄位。
- **L24**(`showType` 的兩條路):對所有 `k :: TypeKey`,
  `lookupType reg k == Just d` 時 `showType k` 回 `Right d`(逐欄相同);
  `lookupType reg k == Nothing` 時 `showType k` 回 `Left (UnknownType t)`,其中 `TypeKey t == k`
  (酬載是**那個鍵的字串本身**,不是別的訊息)。

### `thumbPath`

- **L25**(位置由 workspace 算、本層只判存在):對所有 `h :: Sha256`,
  `thumbPath h` 回 `Just p` **當且僅當** `thumbCachePath loc h` 是一個既存且讀得到的一般檔案
  (`loc` = `askHubLocation`);而且此時 `p` **逐字等於** `thumbCachePath loc h`。否則回 `Nothing`。
  本操作在任何輸入下都不建立、不刪除、不寫入任何檔案,也**不回 `Left`**。

### Machine 不自己拼路徑的靜態防線(以原始碼文字驗證)

- **L26**(`service/src/` 的程式碼行不得出現本機路徑字面):契約卡「明確不做」第二條
  (「不自己拼 `.aapms/` 底下的路徑,一律用 workspace 與 graph-core 的函式」)在編譯期看不出違規
  —— 自己 `</> ".aapms" </> "index.db"` 拼出來的路徑編得過、跑起來多半也對,直到某一天下層改了
  分片規則或檔名。這一條讓它在該行寫下的那一刻就紅。

  **掃描範圍與正規化**:與 F001 的 L23 / L25 **逐字相同**(`service/src/` 底下**遞迴**取得的每一個
  `.hs` 檔,不是寫死的清單;`service/test/` 不在範圍內 —— qa 要自己組佈局路徑;去行尾 `\r` →
  丟掉 trim 後以 `--` 開頭的整行 → 截掉第一個 ` --` 起的行尾註解)。剩下的叫**程式碼行**。
  三條 law 共用同一個正規化,理由也一樣:模組 haddock 本來就要寫「不自己拼 `.aapms/` 底下的
  路徑」這句話,全檔字串搜尋會把「文件寫得清楚」誤判成「越界」。

  **判準**:任何程式碼行都不得含以下五個**帶引號的**子字串之一(逐字,含前後的雙引號):
  `".aapms"`、`"config.toml"`、`"index.db"`、`"cache"`、`"thumbs"`。命中即產生一筆違規,
  訊息必須帶**檔名與行號**。

  **斷言**:違規行的清單為**空**。判準本身寫成對「(檔名, 檔案全文)」的純函數,`service/src/` 的
  實況(X25)與一份合成文字(X26)餵的是同一個判準 —— **沒有 X26 這條 law 就可能是空洞的**
  (掃描器寫壞時正向斷言照樣綠),與 F001 的 L23 / L25 是同一個理由。

  **不在本條範圍內的**:`service/test/`;`shell` 與領域子系統(它們本來就要組路徑給使用者看);
  以及**不帶引號**的同名識別字(`indexDbPath` 這種函式名不受影響 —— 呼叫下層的路徑函式正是本條
  要求的作法)。

### `UnknownType` 的 `errorCode` 與 `renderServiceError`

- **L27**(本層自撰的那一則錯誤):對所有 `t :: Text`,
  `errorCode (UnknownType t) == "unknown_type"`(只看建構子、不看酬載,與 F001 的 L20 一致);
  `renderServiceError (UnknownType t)` **非空**、**含 `t` 作為子字串**(訊息要說出是哪個鍵),
  並**含 `type list` 這個字串**(system.md 全域錯誤策略第 2 條的「說出下一步」在本則的具體形式:
  去看有哪些型別,或到型別註冊表目錄補一份宣告)。訊息由**本層自撰、不委派**——它下面沒有可委派
  的錯誤原件。
  既有四個建構子的 `errorCode` 與 `renderServiceError` **一個字都沒變**(F001 的 L19–L22 與
  X21–X23 仍全數成立,本條不得與它們衝突)。

`L-`:六個 View 型別的 `deriving stock (Show, Eq)` 子句**無獨立 law**,理由具體:它們是骨架原文
承載的事實,寫成 property 只會得到「`show x` 不是空字串」這種恆真斷言;而它們**存在**這件事由
L8(要 `show` 得出整份報告才驗得到「不含 `[llm]` 的值」)與其餘每一條逐欄比較的 law(要 `Eq`)
間接要求 —— 少了它們,上面那些逐欄比較的 law 一條都寫不出來。

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 | 由哪幾條 law 推出 |
|---|---|---|---|---|
| X1 | 完整佈局,`runService env vaultList` | 兩筆,`vvId` 依序 `[VA, VB]`;`vvName` `["story", "assets"]`;`vvKind` `[StoryVault, AssetVault]`;兩筆的 `vvRegistered` 與 `vvReachable` 皆 `True` | 正常路徑 | L1, L2, L3 |
| X2 | 中樞多一列 `VC` 指向不存在的路徑後 `vaultList` 與 `vaultCheck` | `vaultList` 三筆;`VC` 那筆 `vvReachable == False`、其餘兩筆 `True`;`vaultCheck` 恰含一則 `VaultPathMissing` 且它的 `veId` 是 `VC` | 不可達的一列 + 驗收標準 1 | L1, L3, L4 |
| X3 | 把 `<tmp>/va/.aapms/config.toml` 的 id 改成別的值後 `vaultList` 與 `vaultCheck` | `vaultCheck` 恰含一則 `VaultIdDrift`;而 `vaultList` 裡 `VA` 那筆的 `vvReachable` 仍為 **`True`** | id 漂移**不是**不可達 | L3, L4 |
| X4 | 中樞的 `[[vaults]]` 清空後 `vaultList` | `Right []` | 空中樞 | L1 |
| X5 | 從中樞刪掉 `VA` 那一列(`<tmp>/va/.aapms/` 保留),`openEnv Nothing <tmp>/va` 後 `workspaceDoctor` | `dvVaults` 有兩筆:第一筆是 `VB`(`vvRegistered == True`),第二筆 `vvRegistered == False`、`vvId == VA`、`vvPath` 是 `<tmp>/va` 的正規化路徑、`vvReachable == True` | 未註冊的 vault + 驗收標準 2 | L6, L7 |
| X6 | 完整佈局,`openEnv Nothing <tmp>/outside` 後 `workspaceDoctor` | `dvVaults` 逐欄等於 `vaultList` 的兩筆,**沒有**任何 `vvRegistered == False` 的項目 | 起點不在任何 vault 底下 | L6, L7 |
| X7 | 中樞加一段 `[llm]`,其中 `api_key = "SENTINEL-7f3b9c"`,`workspaceDoctor` | `dvLlmConfigured == True`;`show` 整個 `DoctorView` 的結果**不含** `"SENTINEL"`、也不含 `"api_key"` | 金鑰不進診斷輸出 + 驗收標準 3 | L5, L8 |
| X8 | 無 `[llm]` 段時 `workspaceDoctor` | `dvLlmConfigured == False` | `[llm]` 缺席 | L5 |
| X9 | 對 `<tmp>/hub/`、`<tmp>/va/.aapms/`、`<tmp>/vb/.aapms/` 遞迴取「檔名 → 位元組」對照表,跑 `workspaceDoctor >> vaultCheck`,再取一次 | 兩份對照表**完全相同** | 唯讀 + 驗收標準 4 | L9 |
| X10 | `[tools]` 未設、`PATH` 清空後 `workspaceTools` | `Right [ts]`;`tsName ts == "7-Zip"`;`tsSearched ts` 非空(三層探測全都試過);**不斷言** `tsPath` / `tsOrigin` 的具體值——這台機器有沒有裝 7-Zip 決定它是 `NotFound` 還是找到路徑,兩種結果在裝與沒裝的機器上都該對這條 example 成立;`NotFound` 那個值仍由 L10 的 property test 間接覆蓋(機器沒裝時自然比對到它) | 三層探測皆已嘗試,結果不被「這台機器裝了什麼」綁死 | L10 |
| X11 | `AAPMS_HOME` 指向一個**空目錄**(中樞尚未建立),`workspaceSetup Nothing <tmp>/outside`;接著原封不動再跑一次 | 第一次 `Right v`,`svHubCreated == True`、`svCacheCreated == True`;第二次兩欄都 `False`;兩次的 `svHubPath` 都等於那個空目錄的絕對路徑。**全程沒有 `openEnv` / `Env`** | 乾淨機器上的第一次 setup + 冪等 + A2 裁決的實況 | L11 |
| X11b | 同一個已建好的中樞上,分別跑 `workspaceSetup Nothing <tmp>/va` 與 `workspaceSetup (Just "story") <tmp>/outside` | 兩次的 `SetupView` **逐欄相同**,且三欄都等於「中樞早就在」的那一組(`svHubCreated == False`、`svCacheCreated == False`、`svHubPath` 是中樞根目錄) | 兩個參數不影響結果(A2 的簽名是為了與 `openEnv` 同形) | L11 |
| X12 | `workspacePurge PurgeHubOnly`,然後 `askHub` | `pvHubRemoved == True`、`pvVaultIndexesRemoved == []`;`askHub` 的 `hubVaults` 仍是**兩筆**(快照未被重載) | purge 後不重載 | L12, L13 |
| X13 | `vaultInit "<tmp>/vc" AssetVault "third" FreshVault`,接著 `vaultList` | 回 `(v, notice)`:`v` 的 `vvKind == AssetVault`、`vvName == "third"`、`vvPath` 是 `<tmp>/vc` 的正規化路徑、`vvRegistered == True`、`vvReachable == True`;`notice == AdoptNotice []`(乾淨目錄,沒有 legacy marker);`vaultList` 變成三筆且含 `v` | 寫中樞後同一個 `Env` 看得到 + 驗收標準 6 + A3 的第二個回傳值 | L14, L15 |
| X13b | 在 `<tmp>/vd/.assetdb/` 底下放一個 legacy marker 檔後 `vaultInit "<tmp>/vd" AssetVault "fourth" AdoptExisting` | 第二個分量的 `anLegacyMarkers` 逐項等於 `initVault` 同一次回的那一份(非空,含那個 `.assetdb` 路徑);第一個分量的六欄與 X13 同一組判準;**那個 legacy 目錄仍在**(只報告不刪除) | A3:`AdoptNotice` 不被丟掉 | L15 |
| X14 | `vaultForget "story" KeepIndex`,接著 `vaultList` | 回的 `VaultView`:`vvId == VA`、`vvRegistered == **False**`、`vvReachable == True`;`vaultList` 只剩 `VB`;`<tmp>/va/.aapms/config.toml` 位元組不變 | 移除的那一列 + 驗收標準 6 | L14, L16 |
| X15 | `vaultForget "沒有這個" KeepIndex` | `Left (WorkspaceFailed (VaultSelectorNotFound "沒有這個"))`;`askHub` 與 `<tmp>/hub/config.toml` 的位元組都與呼叫前相同 | 下層失敗原樣包、什麼都不動 | L17 |
| X16 | `projectRegister "<tmp>/proj" "demo"` → `projectList` → `projectForget "demo"` → `projectList` | 第一步回的 `ProjectView`:`pvName == "demo"`、`pvPath` 是 `<tmp>/proj` 的正規化路徑、`pvReachable == True`;第二步一筆;第三步回**同一筆**;第四步 `[]` | 專案登錄的往返 + 驗收標準 6 | L14, L18, L19 |
| X17 | `projectRegister` 之後刪掉 `<tmp>/proj/`,再 `projectList` | 一筆,`pvReachable == False`,其餘三欄不變 | 專案路徑消失 | L18 |
| X18 | 完整佈局(兩個 vault 都是空的),`vaultInfo "assets"` | `viVault` 逐欄等於 `vaultList` 裡 `VB` 那一筆;`viCounts == []`;`viIssues` 等於同一次執行裡 `indexIssuesFor VB` 的結果(全新索引時含一則 `SchemaRebuilt { irOldVersion = Nothing }`) | 空 vault + 驗收標準 5 | L20, L21, L22 |
| X19 | 在 `<tmp>/vb` 放入一個合法的 asset 檔與一個合法的 pack 檔並以 graph-core 的 `indexFile` 建索引後,`vaultInfo "assets"` | `viCounts == [("ast", 1), ("pck", 1)]`(依 `IdPrefix` 的 `Ord`:`PAst` 在 `PPck` 之前);其餘六個 prefix **不出現** | 非空 vault、零值鍵不出現、鍵的排序 | L21 |
| X19b | 同 X19 的索引狀態,但 `openEnv (Just "story") <tmp>` (`--vault story`,而 `story` 的 `refs` 不含 `assets`)之後 `vaultInfo "assets"` | 與 X19 **完全相同**的 `viCounts`;`viIssues` 逐項等於**同一個 `Env`** 的 `indexIssuesFor` 對 `assets` 的結果(與 X18 同一判準,**不強制非空**——這是第二次開啟,`SchemaRebuilt` 只在生命週期第一次開啟時產生) | A4:點名的目標不受 `--vault` 範圍收窄影響(這一半判準不變) | L21, L22 |
| X20 | `vaultInfo "沒有這個"` | `Left (WorkspaceFailed (VaultSelectorNotFound "沒有這個"))` | selector 解不開 | L17, L20 |
| X21 | `listTypes` 與「直接對同一個註冊表目錄 `loadRegistry` 後呼叫 `Aapms.Core.Registry.listTypes`」 | 兩份清單**逐項相同、順序相同**;長度 `> 0` | 轉出不改寫 | L23 |
| X22 | `showType (tdKey d)`,`d` 是 X21 那份清單的第一筆 | `Right d`(逐欄相同) | 命中 | L24 |
| X23 | `showType (TypeKey "no-such-type-xyz")` | `Left (UnknownType "no-such-type-xyz")` | 未命中 + 驗收標準 7 | L24 |
| X24 | 對一個不在快取裡的 `h` 呼叫 `thumbPath h`;接著手動建出 `thumbCachePath loc h` 這個檔(含中間目錄)再呼叫一次 | 第一次 `Right Nothing`;第二次 `Right (Just p)` 且 `p` 逐字等於 `thumbCachePath loc h`、且 `p` 讀得出剛寫進去的位元組;兩次前後 `<tmp>/hub/cache/` 底下除了測試自己建的那個檔以外沒有任何變化 | 快取命中與未命中 + 驗收標準 8 | L25 |
| X25 | 對 `service/src/` 的**實況**(骨架階段是 `Types.hs` / `Monad.hs` / `Scope.hs` / `Machine.hs` 四個檔)跑 L26 的判準 | 違規清單**為空**。`Machine.hs` 的 haddock 提到 `.aapms\/` 的那些**註解行**全部被正規化丟掉,**不計入** | 路徑防線的正向路徑;順帶驗「判準不把註解誤判成越界」 | L26 |
| X26 | 一份**合成**的模組文字(只存在於測試裡,不寫進 repo):檔名 `Aapms/Service/Machine.hs`,內容取 `Machine.hs` 現況再插入一行 `  let p = root </> ".aapms" </> "index.db"`,以及一行 `-- 別自己拼 ".aapms" 底下的路徑` | 違規清單**恰好一條**,指向插入的那一行(帶檔名與行號);那行**註解**不被算成違規 | 判準非空洞(掃描器壞掉時 X25 也會綠)+ 註解豁免的負向確認 | L26 |
| X27 | `errorCode (UnknownType "no-such-type-xyz")` 與 `renderServiceError (UnknownType "no-such-type-xyz")` | `code` 逐字等於 `"unknown_type"`;訊息非空、**含 `"no-such-type-xyz"`**、且**含 `"type list"`**(說出下一步的其中一條) | 新建構子的 code 與訊息(骨架承載,預期綠) | L27 |

## 依賴方向

- **依賴誰**:同套件的 `Aapms.Service.Monad` 與 `Aapms.Service.Types`(**不再有 `Scope`**,見 A4);
  `aapms-core`(`Aapms.Core.Asset` / `Aapms.Core.Id` / `Aapms.Core.Meta` / `Aapms.Core.Registry`);
  `aapms-types`(`Aapms.Types.Loader`);`aapms-store`(`Aapms.Store.Schema` / `Aapms.Store.Query` /
  `Aapms.Store.Marker`);`aapms-workspace`(`Aapms.Workspace.Types` / `Aapms.Workspace.Location` /
  `Aapms.Workspace.Discovery` / `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Projects` /
  `Aapms.Workspace.Tools`);`base` / `containers` / `directory` / `text`。
- **誰會依賴它**:`shell` 的三個殼(CLI / HTTP / MCP);本子系統的 F008(index-ops,同樣落在
  Machine 模組)。F003–F007 **不**依賴本 feature(但 F003 起會 import `Aapms.Service.Types` 的
  View 型別,那是既有的「全部模組 → Types」那一列)。
- **新增的依賴邊**(逐條,一條都不能漏;分兩個模組):
  - `Aapms.Service.Machine` → `Aapms.Service.Monad`
  - `Aapms.Service.Machine` → `Aapms.Service.Types`(六個 View 型別與 `ServiceError`;
    「全部模組 → Types」那一列,不是新方向)
  - `Aapms.Service.Machine` → `Aapms.Core.Asset` / `Aapms.Core.Meta` / `Aapms.Core.Registry`
  - `Aapms.Service.Machine` → `Aapms.Store.Schema` / `Aapms.Store.Query`
    (`Aapms.Store.Marker` 只在 impl 要具名 `VaultHandle` 時才需要——`handleFor` 交出來的值
    直接餵給 `listNodes`,型別可以由推論得出)—— design.md「模組間公開介面」已於 W2 閘門補上
    `Machine → aapms-store`(**查詢組,只讀**)這一列,本組落在它裡面。`Aapms.Store.MultiVault`
    **不再需要**(A4 之後目標只有一個 vault)
  - `Aapms.Service.Machine` → `Aapms.Workspace.Types` / `Aapms.Workspace.Location` /
    `Aapms.Workspace.Discovery` / `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Projects` /
    `Aapms.Workspace.Tools`
  - **`Aapms.Service.Machine` → `Aapms.Service.Scope` 這條邊不存在**(原本因 `withRead` 而有,
    A4 裁決後 `vaultInfo` 改走 `handleFor`);`Machine` 對 `Monad` 多用一個既有介面 `handleFor`,
    design.md 已補 `Machine → Monad` 那一列
  - **`Aapms.Service.Types` 新增的四條**(A1 把六個 View 型別搬進來的後果):
    → `Aapms.Core.Id`(`Id` / `VaultId`)、→ `Aapms.Store.Schema`(`VaultKind` / `IndexIssue`)、
    → `Aapms.Types.Loader`(`RegistrySource`)、→ `Aapms.Workspace.Types` 多取三個型別
    (`HubSource` / `ScopeIssue` / `ToolStatus`,原本只取 `WorkspaceError` 與
    `renderWorkspaceError`)。**四條都是「Types 只依賴下層套件的型別」的既有規則之內**,
    `Types` 仍不 import 本套件任何模組,型別歸屬圖仍是樹
  - **套件層級無新增**:四個下層套件在 F001 就已全部進 `build-depends`;`directory` 已由編排者
    依 D1 加進 library 的 `build-depends`(`projectList` 的 `pvReachable` 與 `thumbPath` /
    `workspaceSetup` 的存在性檢查需要它)
  - **沒有**新增任何往 `shell` 或領域子系統的邊,也沒有 `servant` / `warp` /
    `optparse-applicative` / `aeson`
  - **沒有回頭邊**:`Aapms.Service.Types` 與 `Aapms.Service.Monad` 都不 import `Machine`
- **可否與其他進行中任務平行開發**:本波只有本 feature,無平行對象。F008 之後會落在同一個檔案上,
  屆時要在同一波裡排序,不可平行。

## 不可逆決定

| 決定 | 被否決的替代方案與理由 |
|---|---|
| **`SetupView` / `PurgeView` 是 workspace 報告型別的線上投影,而不是直接把 `SetupReport` / `PurgeReport` 當回傳型別** | **直接回下層的型別**:少兩個型別、少兩段逐欄複製,而且欄位語意保證不漂移。否決理由是**線上格式屬本層**(design.md「內部模組劃分」的 Types 列)——`shell` 的 REST body 與 CLI JSON 的欄位名會直接綁在 `aapms-workspace` 的 record 欄位名上,workspace 改一個欄位名就是改一次對外 API,而那是 workspace 完全不知情的後果。已知代價:每加一欄要改兩個地方,而且投影函數寫錯不會有編譯錯誤(L11 / L12 就是為此存在)。**這是不可逆的**:一旦 `shell` 的三個殼把欄位名發出去,改回來就是破壞相容 |
| **`vvReachable` 只認 `VaultPathMissing` 與 `VaultMarkerBroken`,`VaultIdDrift` 仍算「可達」** | **任何 `ScopeIssue` 都算不可達**:規則更簡單,也更「安全」。否決理由是 id 漂移的 vault 目錄還在、marker 也讀得出來,`vault forget` / `vault add` / 直接開檔都還能對它動作;報成 unreachable 會讓使用者以為磁碟壞了,而真正該做的是重新 `vault add`。契約卡的驗收標準 1 逐字寫「**恰好**對應 `VaultPathMissing` 或 `VaultMarkerBroken` 的那些」,本決定只是把它釘成 law。**這是不可逆的**:`vvReachable` 是布林,`shell` 會拿它決定要不要標紅、要不要給非零 exit code,語意翻面就是行為翻面。已知代價:`doctor` 的讀者必須同時看 `dvScopeIssues` 才知道有 id 漂移,`vvReachable` 一欄看不出來 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `service/src/Aapms/Service/Machine.hs` | 契約 C 十六個函式的簽名(本體一律 `undefined`)、六個 View 型別的原地 re-export、十項 re-export 的匯出清單 |
| `service/src/Aapms/Service/Types.hs` | **既有檔案的擴充**:六個 View 型別(欄位完整、`deriving stock (Show, Eq)`)+ `UnknownType Text` 建構子與它在 `errorCode` / `renderServiceError` 的兩個分支 |

`cabal build aapms-service` **編譯通過、零警告**(2026-08-30,GHC 9.14.1,`-Wall -Wcompat`;
`Aapms.Service.Machine` 已由編排者依 D1 加進 `exposed-modules`,`directory` 也已進
`build-depends`,所以這次是真的建過,不是 `repl` 側驗)。`cabal test aapms-service-test` 仍然
**62 / 0 綠**(F001 的測試不受影響)。

**已知且刻意留下的一個 test-suite 警告**:`service/test/Aapms/Service/TypesSpec.hs:117` 的
`ctorTag` 因為新增了 `UnknownType` 而變成 non-exhaustive(`-Wincomplete-patterns`)。它是 F001 的
測試檔,**spec 角色不得改測試**;該函式只被 F001 自己的 `genServiceError`(只生四個建構子)餵,
執行期碰不到新分支,所以 62 條全綠。處置建議見回報的「建議編排者做的上層動作」。

impl 只准替換 `undefined`,不得改動任何簽名、型別定義或匯出清單;**可以**新增 import
(qualified 的 `Aapms.Core.Registry`、`Aapms.Workspace.*` 的函式、`Aapms.Store.Query` 那些)
——骨架只帶了簽名與型別需要的那幾個。**`Types.hs` 沒有留給 impl 的 `undefined`**:六個 View
型別與兩個新分支都是骨架階段就完整的事實(理由見「數據」),impl 本波不需要動這個檔。

**`workspaceSetup` 的兩個提醒**:它是頂層 `IO`,**不得**用 `Monad` 模組的執行入口把自己包成
`ServiceM`(F001 的 L23 會在原始碼文字上抓到,而且它根本不需要 `Env`);兩個參數在本層用不到,
填本體時要用底線前綴命名(`_sel` / `_cwd`),否則 `-Wall` 的 `-Wunused-matches` 會出警告。

**三條靜態 law 對 impl 的約束**:F001 的 **L23**(本檔的程式碼行一個字都不准提到 `Monad` 模組的
執行入口)、F001 的 **L25**(不得寫 `instance` 宣告、不得 standalone deriving、不得動 `ServiceM`
的 deriving 子句)、本 feature 的 **L26**(不得出現 `".aapms"` / `"config.toml"` / `"index.db"` /
`"cache"` / `"thumbs"` 五個帶引號的字串字面)。三條都掃整個 `service/src/`(含本波動到的
`Types.hs`),填本體的時候踩到就紅。六個 View 型別搬進 `Types.hs` 之後仍**不違反 L25**:
它們走的是資料宣告上的 `deriving stock` 子句,不是 `instance` 宣告,也沒有一行 `deriving` 含
`Monad`。

## 待確認假設

四條,全部是契約層級,**全部已於 2026-08-30 的 W2 spec 批准閘門裁決**。條目保留為決策紀錄:
下面每一條的「選項 / 傾向 / 可逆性」是當時呈報給開發者的材料,末尾的「已裁決」欄是閘門的結果與
本次修訂實際做的事。**spec 與骨架現在照裁決結果寫,不再是「暫採」。**

- **A1**:契約 C 的六個 View 型別(`SetupView` / `PurgeView` / `VaultView` / `VaultInfoView` /
  `DoctorView` / `ProjectView`)該住 `Aapms.Service.Types` 還是 `Aapms.Service.Machine`。契約卡沒有
  答案,是因為它只寫「負責模組:Machine」,而 design.md「內部模組劃分」把「View 型別」整類歸給
  Types;兩份文件在這一格互相矛盾,而編排者指定的骨架白名單只有 `Machine.hs`。
  - 契約錨點:design.md「內部模組劃分」表的 **Types 列**(「請求型別、**View 型別**、`Page`、
    `ServiceError`…」)與 **Machine 列**;`SetupView` / `PurgeView` / `VaultView` /
    `VaultInfoView` / `DoctorView` / `ProjectView` 六個型別名
  - 層級自答:出現在邊界上?**會**(它決定 `shell` 從哪個模組 import 這六個型別);
    改錯驚動其他模組?**要**(F003 的 `NodeView` 與 F004 的請求型別會面對**同一個**問題,
    而且 F008 也落在 Machine 模組上)
  - 選項:
    a) **放 `Machine.hs`**(白名單唯一可寫的檔)——當下成本:零,骨架直接交付,`Machine.hs`
       自足;三個月後代價:design.md 的「Types 擁有線上格式」對本子系統不再成立,F003–F007 每一波
       都要重問一次「我的 View 放哪」,最後八個 feature 的 View 型別散在六個模組裡,而
       `shell` 要 import 六個模組才拼得出一個回應
    b) **放 `Types.hs`**(需編排者把 `Types.hs` 加進本波白名單)——當下成本:白名單多一個檔,
       而且 `Types.hs` 目前只有錯誤語彙、加進 View 型別後模組職責變寬;三個月後代價:幾乎沒有
       ——這正是 design.md 寫下來的形狀,`Types` 不 import 本套件任何模組的規則不受影響
       (六個 View 只依賴 graph-core 與 workspace 的型別)
  - 傾向:**b**。理由是 design.md 的模組劃分表是本子系統的知識歸屬結論,而 a 只是白名單的
    副作用;把 a 走完之後,F003 的 `NodeView`(被 F004 / F005 / F006 / F007 四個 feature 共用)
    沒有任何一個「負責模組」放得下它。依賴的前提:`Types.hs` 加進白名單之後仍由**單一 feature**
    在**單一波**裡寫(本子系統的波次不平行,build-log 排程表已載明),不會有併發互蓋。
    可逆性:**有條件可逆**——搬模組是機械動作,但 `shell` 一旦 import 定了就要跟著改;
    在 `shell` 接上之前都算可逆
  - 暫採:**a**(六個型別宣告寫在 `Machine.hs`)
    → 影響:若裁決 b,把那六段 `data … deriving stock (Show, Eq)` 連同 haddock **整段**搬進
    `Types.hs`,在 `Machine.hs` 改成 `import Aapms.Service.Types (…)` 並在匯出清單原地 re-export
    (`shell` 的 import 路徑不變)。`Machine.hs` 的十六個函式簽名、re-export 清單與全部 Laws
    **一個字都不用改**
  - **已裁決(2026-08-30 W2 閘門):採 b**。design.md「內部模組劃分」的 Types 列已寫明
    「全部 View 型別住這裡」。本次修訂:六段宣告連同 haddock 整段搬到
    `service/src/Aapms/Service/Types.hs:64` 起(`Types.hs` 本波納入寫入白名單),`Machine.hs`
    改為 `import Aapms.Service.Types (…)` 並在匯出清單原地 re-export。如當初評估,十六個函式
    簽名與全部 laws 一字未動;`Types.hs` 因此多了四條對下層型別的 import 邊(逐條列在
    「依賴方向」),仍不 import 本套件任何模組

- **A2**:契約 C 的 `workspaceSetup :: ServiceM SetupView` 在「中樞還不存在」這個它唯一有意義的
  情境下**跑不到**。契約卡沒有答案,是因為它把 `workspaceSetup` 當成契約 C 的一員引用,而契約 A
  的 `openEnv`「中樞載不起來即失敗、不退回空的 `Env`」是另一段寫的;兩段各自成立,合起來就把
  `svHubCreated == True` 這條路封死了。
  - 契約錨點:契約 C 的 **`workspaceSetup`** 與 **`SetupView` 的 `svHubCreated` 欄**;
    契約 A 的 **`openEnv`**
  - 層級自答:出現在邊界上?**會**(`workspaceSetup` 的型別是不是 `ServiceM`);
    改錯驚動其他模組?**要**(`shell` 的 `workspace setup` 子指令是使用者第一次跑的那一道,
    走不通就等於沒有 bootstrap 路徑,而 ADR-015 要求 `shell` 零業務邏輯,它不能自己去建中樞)
  - 選項:
    a) **維持契約原文**——當下成本:零;三個月後代價:`svHubCreated` 是一欄恒為 `False` 的死欄位,
       而 `workspace setup` 這道指令在 `shell` 接上時會發現「還沒 setup 就 setup 不了」,
       屆時要嘛 `shell` 自己繞過 `service` 建中樞(違反 ADR-015),要嘛回頭改契約 A
    b) **契約 C 把 `workspaceSetup` 改成不需要 `Env` 的形狀**(例如
       `workspaceSetup :: IO (Either ServiceError SetupView)`)——當下成本:契約 C 動一個簽名,
       本 feature 的骨架與一條 law 跟著改,`shell` 的 CLI 分派要多認一種「不開 `Env` 的操作」;
       三個月後代價:`service` 的操作從此有兩種形狀,而「全部業務操作都是 `ServiceM`」這條讓
       三個殼薄下來的性質被打破一個洞(不過 `workspace setup` 本來就是**先於環境**的操作,
       型別上說出這件事反而誠實)
    c) **`openEnv` 對 `HubNotFound` 退回空中樞**——當下成本:改 F001 的 `openEnv`;
       三個月後代價:違反 system.md 全域錯誤策略第 3 條(「不退回空值」),而且空中樞會讓
       每一個查詢都靜默回空。**直接否決**,列在這裡是為了說明它被考慮過
  - 傾向:**b**,但**不在本 feature 做**——它動的是契約 C 的簽名與 `shell` 的分派形狀,
    該由開發者在閘門上決定,而不是被一個 feature 的實作順手改掉。可逆性:**可逆**
    (`shell` 尚未接上,兩種形狀之間互轉是機械動作)
  - 暫採:**a**(骨架照契約原文寫 `workspaceSetup :: ServiceM SetupView`)
    → 影響:若裁決 b,`Machine.hs` 改一個簽名、L11 的敘述從「`workspaceSetup` 成功時」改成
    「`workspaceSetup` 回 `Right` 時」、X11 的第一次呼叫改成在**中樞不存在**的佈局上跑並斷言
    `svHubCreated == True`;其餘十五個操作不受影響
  - **已裁決(2026-08-30 W2 閘門):採 b**,契約 C 的新原文是
    `workspaceSetup :: Maybe Text -> FilePath -> IO (Either ServiceError SetupView)`
    (與 `openEnv` 同層、同參數形狀)。本次修訂:改簽名、把它從資料流的 A/B/C 三組裡拉出來
    自成「第 0 組」、L11 重寫(加「兩個參數不影響結果」)、L13 補一句「它連 `Env` 都沒有」、
    X11 改成**在中樞不存在的佈局上**跑並斷言 `svHubCreated == True`,另加 X11b 驗參數無關。
    骨架另加兩條給 impl 的提醒:不得用執行入口(L23)、未用參數要底線前綴(`-Wunused-matches`)

- **A3**:`vaultInit` 丟掉了 `AdoptNotice`。`initVault` 回三個值,第三個是「掃到的
  `.assetdb/` / `.storyflow/` legacy marker 清單,**只報告不刪除**」,而契約 C 的 `vaultInit` 只回
  `VaultView`,六個欄位裡沒有一個裝得下它。契約卡沒有答案,是因為它把契約 C 的簽名當成既定事實
  引用,而契約 C 寫下來的時候 workspace 的 `initVault` 還沒交付。
  - 契約錨點:契約 C 的 **`vaultInit`** 與 **`VaultView`**;`workspace` 契約 D 的
    **`AdoptNotice`**(`anLegacyMarkers`)
  - 層級自答:出現在邊界上?**會**(`vaultInit` 的回傳型別);改錯驚動其他模組?**要**
    (`shell` 的 `vault init --adopt` 要不要印「偵測到 legacy marker」那一行)
  - 選項:
    a) **丟棄**——當下成本:零;三個月後代價:`vault init --adopt` 對一個舊 assetdb 目錄跑完
       之後,使用者完全不知道那裡還躺著一個 `.assetdb/`;而 workspace 特地把它做成「只報告不刪除」
       就是為了讓人知道。要救回來得改契約 C 的簽名,那時 `shell` 已經接上
    b) **`vaultInit` 改回 `ServiceM (VaultView, AdoptNotice)`**——當下成本:契約 C 動一個簽名,
       `AdoptNotice` 要進 re-export 清單;三個月後代價:`vault init` 的回傳形狀比其他生命週期操作
       多一層 tuple,`shell` 的 JSON 要多一個欄位
    c) **`VaultView` 加一欄 `vvAdoptedLegacyMarkers :: [FilePath]`**——當下成本:契約 C 動一個
       DTO;三個月後代價:那一欄對 `vaultList` / `vaultAdd` / `vaultForget` 回的每一筆都恒為空,
       是典型的「只有一條路會填的欄位」,而 `VaultView` 是本子系統最常出現的 DTO
  - 傾向:**b**。理由是這個資訊只在 `vault init` 這一道指令上有意義,把它綁在該指令的回傳上、
    而不是稀釋進共用的 DTO(c),也不是丟掉(a)。依賴的前提:`shell` 願意為 `vault init` 印一段
    專屬的附註——這一點還沒有人確認過,所以是假設不是結論。可逆性:**可逆**(`shell` 尚未接上)
  - 暫採:**a**(骨架照契約原文寫 `vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM VaultView`)
    → 影響:若裁決 b,`Machine.hs` 改一個簽名、匯出清單加 `AdoptNotice (..)`、L15 加一句
    「第二個分量逐欄等於 `initVault` 回的 `AdoptNotice`」、X13 的預期輸出多一個分量
  - **已裁決(2026-08-30 W2 閘門):採 b**,契約 C 的新原文是
    `vaultInit :: FilePath -> VaultKind -> Text -> InitMode -> ServiceM (VaultView, AdoptNotice)`。
    本次修訂:改簽名、匯出清單加 `AdoptNotice (..)`(re-export 從九項變十項)、L15 補「第二個
    分量逐欄等於同一次 `initVault` 回的 `AdoptNotice`,本層不過濾不刪除」、X13 的預期輸出改成
    兩個分量,另加 X13b(有 legacy marker 的那條路)

- **A4**:`vaultInfo` 用的是 `Env` 的 selector 解出的**讀取範圍**,不是它自己那個參數指到的 vault。
  `withRead` 的範圍來自 `askSelector`(`--vault`),`resolveRead hub (Just s)` 的結果是
  `{s} ∪ refs*(s)`;所以 `--vault A` 之下 `vault info B`(B 不在 A 的 `refs*` 裡)開不到 B 的索引,
  `viCounts` 會是空的、`viIssues` 也是空的。契約卡沒有答案,是因為它只寫「使用契約 A 與 #1 的
  `withRead`(無新增)」,沒有預期到 `vaultInfo` 的參數與 `--vault` 可以指到不同的 vault。
  - 契約錨點:契約 C 的 **`vaultInfo`** 與 **`VaultInfoView` 的 `viCounts` / `viIssues`**;
    design.md「模組間公開介面」的 **`Read / Write / Machine → Scope`**(`withRead`)與
    **`Scope → Monad`**(`handleFor`)兩列
  - 層級自答:出現在邊界上?**會**(`vault info` 在某些旗標組合下回的是空的計數,而不是錯誤);
    改錯驚動其他模組?**要**(要修就得讓 Machine 也能呼叫 `handleFor`,那是「模組間公開介面」
    表要新增的一列)
  - 選項:
    a) **照契約卡只用 `withRead`**——當下成本:零;三個月後代價:`aapms --vault story vault info assets`
       會**靜默**回 `viCounts == []`,而使用者看到的是「這個 vault 是空的」,不是「你問錯範圍了」。
       這是最難查的一種錯:輸出合法、沒有錯誤碼、只有數字不對
    b) **「模組間公開介面」新增一列 `Machine → Monad: handleFor`,`vaultInfo` 直接開目標 vault
       的 handle**——當下成本:design.md 的表多一列,`vaultInfo` 不再經 Scope;
       三個月後代價:`handleFor` 的呼叫端從一個變成兩個,而它是「本套件唯一開 handle 的地方」
       這條規則的守衛點——多一個呼叫端不破壞規則(handle 仍進同一個快取、仍由 `closeEnv` 關),
       但「範圍解析的結果只經三個口進來」這條就多了一個例外:`vaultInfo` 拿到的 vault 不是任何
       範圍裁決的結果,而是使用者點名的
    c) **`vaultInfo` 在目標不在讀取範圍內時回 `WorkspaceFailed (VaultSelectorNotFound s)`**——
       當下成本:零;三個月後代價:訊息在說謊(那個 vault 明明在中樞裡),而且使用者無從得知
       真正的原因是 `--vault`
  - 傾向:**b**。理由是 `vault info <sel>` 的語意就是「我點名這一個」,它跟 `--vault` 決定的
    查詢範圍是兩件事;用範圍去解一個點名,結果只會在旗標組合上出現無法解釋的空值。
    依賴的前提:`handleFor` 的第二個呼叫端不會侵蝕「唯一開 handle 的地方」——這一點成立,因為
    `handleFor` 本身就是那條規則的**實作**,規則守的是「不要有第二種開法」,不是「不要有第二個
    呼叫端」。可逆性:**可逆**(改回 a 只要把那一列刪掉)
  - 暫採:**a**(骨架不動;L21 明文寫出「目標 vault 不在讀取範圍內時 `viCounts == []`」)
    → 影響:若裁決 b,`Machine.hs` 的匯出與簽名**都不動**(只動本體與 import),L21 / L22 刪掉
    「不在讀取範圍內」那一句、改成「對中樞裡的任一 vault 恒成立」,並補一個 example:
    `--vault story` 之下 `vaultInfo "assets"` 仍算得出 `assets` 的節點數
  - **已裁決(2026-08-30 W2 閘門):採 b**。design.md「模組間公開介面」已新增
    `Machine → Monad`(`handleFor`)那一列。本次修訂:簽名與匯出如評估**一字未動**,改的是
    `vaultInfo` 的資料流敘述(`lookupSelector` → `readVaultRefAt` → `handleFor` → `listNodes`)、
    L21 / L22 改寫成「對中樞裡的任一 vault、任一 `--vault` 恒成立」、補 X19b。
    **連帶的兩個後果**:`Machine` 不再 import `Scope`(唯一的 `withRead` 用處消失);
    `viCounts` 的資料來源從 `listAcross`(跨 vault)換成 `listNodes`(單 vault),
    `graph-core/F009` 因此退出 `depends-on`

## TodoList

- [ ] 六個 View 型別的欄位與 `deriving stock (Show, Eq)`(骨架已完成於 `Types.hs`,impl 不動)
- [ ] `UnknownType` 建構子與 `errorCode` / `renderServiceError` 的兩個分支(骨架已完成,impl 不動)
- [ ] `vaultList`:`hubVaults` 逐列投影 + `checkVaults` 決定 `vvReachable`
- [ ] `vaultCheck`:`checkVaults` 原樣轉出
- [ ] `workspaceTools`:`detectSevenZip (hubTools hub)` 包成單筆清單
- [ ] `workspaceDoctor`:六欄來源 + `vaultList` + 未註冊那一筆(`detectVault` → `readVaultRefAt`)
- [ ] `workspaceSetup`:**頂層 IO**,`hubLocation` → `setupHub` → 逐欄投影;失敗包成
      `WorkspaceFailed`;兩個參數不使用(底線前綴)
- [ ] `workspacePurge`:`purge` 的逐欄投影;**不**重載中樞快照
- [ ] `vaultInit` / `vaultAdd` / `vaultForget`:下層 → `reloadHub` → 投影被建立 / 被移除的那一列;
      `vaultInit` 另把 `AdoptNotice` 原樣當第二個回傳分量
- [ ] `projectRegister` / `projectList` / `projectForget`:同上 + `pvReachable` 的目錄存在性檢查
- [ ] `vaultInfo`:`lookupSelector` → `readVaultRefAt` → `handleFor` → `listNodes` 分組計數 →
      `indexIssuesFor`(`nfLimit` 與 `nfIncludeReference` 兩個預設值都要覆寫)
- [ ] `listTypes` / `showType`:`askRegistry` + qualified 的 `Aapms.Core.Registry.listTypes` /
      `lookupType`(`showType` 的失敗路徑**擋在 `UnknownType` 上**)
- [ ] `thumbPath`:`thumbCachePath` + 一次存在性檢查

## 1-to-1 測試對照表

| law / example | 觀察的介面 | 骨架狀態下預期 |
|---|---|---|
| L1–L3, X1–X4 | `vaultList` / `VaultView` | 紅 |
| L4, X2, X3 | `vaultCheck` | 紅 |
| L5–L8, X5–X8 | `workspaceDoctor` / `DoctorView` | 紅 |
| L9, X9 | `workspaceDoctor` / `vaultCheck`(唯讀) | 紅 |
| L10, X10 | `workspaceTools` | 紅 |
| L11, X11, X11b | `workspaceSetup` / `SetupView`(**頂層 IO,不經 `Env`**) | 紅 |
| L12, L13, X12 | `workspacePurge` / `PurgeView` | 紅 |
| L14–L16, X13, X13b, X14 | `vaultInit`(含 `AdoptNotice`)/ `vaultAdd` / `vaultForget` | 紅 |
| L17, X15 | 五個寫中樞操作的失敗路徑 | 紅 |
| L18, L19, X16, X17 | `projectRegister` / `projectList` / `projectForget` / `ProjectView` | 紅 |
| L20–L22, X18–X20, X19b | `vaultInfo` / `VaultInfoView`(含跨 `--vault` 的那條) | 紅 |
| L23, X21 | `listTypes` | 紅 |
| L24, X22 | `showType`(命中) | 紅 |
| L24, X23 | `showType`(未命中,回 `Left (UnknownType …)`) | 紅 |
| L25, X24 | `thumbPath` | 紅 |
| **L26, X25, X26** | `service/src/` 的**原始碼文字**(五個帶引號的路徑字面) | **綠** |
| **L27, X27** | `errorCode` / `renderServiceError` 對 `UnknownType` 的兩個分支 | **綠** |

**除了 L26 / X25 / X26 與 L27 / X27 之外全部預期紅**(X23 現在編得過了:`UnknownType` 已由本
feature 交付,它紅在 `showType` 的 `undefined` 上)。兩類的理由各自具體:

- **紅的那些**:沒有任何一條打在「骨架自身就承載的事實」上——六個 View 型別的欄位結構確實是骨架
  原文,但每一條與它們有關的 law 都要先經過一個 `undefined` 的操作才拿得到值。qa 若觀察到其中
  任何一條**綠**,那是斷言恆真或沒呼叫到受測介面,應退回重寫。
- **綠的那五條**:L26 / X25 / X26 是對**原始碼文字**的斷言,L27 / X27 是對骨架階段就寫完的兩個
  分支(`errorCode` / `renderServiceError` 的 `UnknownType`)的斷言——兩組都適用
  `spec-roles.md`「qa 的交付判準」第二列(骨架自身就承載的事實):它們從第一天就綠,而且
  **應該**綠。impl 把 `undefined` 換掉之後仍須維持綠(L26 守的是 F003–F008,不是本波;L27 守的
  是「本層自撰的訊息不被改成委派」)。**不得**因為它們綠就退回或刪掉。反過來,X26 是 L26 的
  非空洞證明:X25 綠而 X26 不綠(抓不到那條違規)代表判準寫壞了。

**覆蓋率(步驟 7 第 2 條)**:Laws **27 條**(L1–L27)、Examples **30 個**
(X1–X27 共 27 個,加 X11b / X13b / X19b 三個);「新增的介面」表共 **23 列**(`Types.hs` 的 6 個 View
型別 + 1 個 `ServiceError` 建構子,`Machine.hs` 的 16 個函式),每一列至少被一條 law 或一個
example 覆蓋。四處值得點名:六個 View 型別各自被投影它們的那個操作的 law 覆蓋
(`SetupView` → L11、`PurgeView` → L12、`VaultView` → L1–L3、`VaultInfoView` → L20–L22、
`DoctorView` → L5–L8、`ProjectView` → L18);`UnknownType` 由 L24(誰產生它)與 L27(它的 code
與訊息)兩面覆蓋;`deriving stock (Show, Eq)` 走 `L-` 的理由段;L17 與 L26 是**跨介面**的兩條
(失敗路徑與原始碼文字),不對應單一列。

**F001 的兩條靜態 law 也覆蓋本波動到的兩個檔**:L23(`service/src/` 底下除 `Monad.hs` 外不得提到
執行入口——`workspaceSetup` 變成頂層 IO 之後這一條更要緊)與 L25(不得有 `instance` 宣告 /
standalone deriving,含 `Monad` 的 `deriving` 行恰好一行)在 `Machine.hs` 進來、`Types.hs` 擴充的
那一刻自動生效;骨架階段已跑過整套 F001 測試驗證,**62 / 0 綠**。

## 實作備註

**2026-08-30 W2 仲裁:X10 / X19b 的預期改寫(歸因 spec bug)**

- **X10** 原本斷言 `[tools]` 未設 + `PATH` 清空會讓 `workspaceTools` 回具體的 `NotFound`。但
  `workspace/F006` 的三層探測第三層查的是**內建安裝路徑候選**,不受 `PATH` 或 `[tools]` 拘束——
  開發機裝了 7-Zip,實測回 `Just "C:\Program Files\7-Zip\7z.exe"`,這條 example 在該機器上永遠紅
  (L10 本身沒問題,它另有一條逐欄比對 `detectSevenZip (hubTools hub)` 的 property test 是綠的)。
  改成只斷言「三層都試過」(`tsSearched` 非空),不再斷言 `tsPath` / `tsOrigin` 的具體值。
- **X19b** 原本期待對已建好索引的 vault 呼叫 `vaultInfo` 時 `viIssues` 仍非空。但
  `SchemaRebuilt` 只在索引檔生命週期**第一次開啟**時產生,而建索引的唯一合法路徑
  (`openVault` + `indexFile` + `closeVault`——F002 自己從不呼叫 `indexFile`)本身就是那個第一次
  開啟,`vaultInfo` 內部的 `handleFor` 必然是第二次,依 L22 自己的定義 `viIssues` 就該是 `[]`。
  改成與 X18 同一判準:逐項等於同一個 `Env` 的 `indexIssuesFor`,不強制非空;X19b 驗 A4 裁決
  (`vaultInfo` 不受 `--vault` 範圍拘束)的那一半不動。

**共通教訓**:example 的預期輸出不得依賴「這台機器剛好沒裝某個外部工具」或「某個只在資源
生命週期第一次發生的事件」這類**環境或時序偶然**——寫得出來、但在正常環境下驗不到的驗收
標準,等於沒有(對照 `contract-readiness.md` 的 A9 可測性、`graph-core` 的 G5,同一個根)。
兩條都不是法條錯,是 example 把「一種可能結果」誤寫成「唯一結果」。
