---
id: F004
type: feature
title: vault-lifecycle
description: "中樞建立、vault 的 init/adopt/add/forget、體檢與回寫、purge 清理"
status: done
created: 2026-08-29
updated: 2026-08-30
depends-on: [F001, F002]
related-adr: [ADR-008, ADR-014, ADR-017]
related-feature: []
---

# F004: 中樞建立、vault 生命週期、體檢與清理(vault-lifecycle)

## 功能概述

實作 `workspace` **生命週期管線全段**(前置檢查 → `initVaultAt` → 撞號檢查 → `AdoptNotice` →
`Hub` 追加 → `saveHub`),以及本機環境管線的 `checkVaults` / `syncHub` 那一段。負責模組是
design.md「內部模組劃分」的 **Lifecycle**,只寫一個檔案
`workspace/src/Aapms/Workspace/Lifecycle.hs`。

Lifecycle 擁有的唯一事實是 **「撤除的分層界線」**——什麼能刪、什麼絕不刪。ADR-017 決策五的三條
硬性約束在本模組被實體化:任何情況不碰 `library/` 與任何 `.md`;`forgetVault` 預設只動中樞;
中樞的寫入只追加一列或刪整列,註解與空白行原樣保留。

本 feature **不新增、不修改任何型別與任何 `WorkspaceError` 建構子**——契約 A–F 的型別已由 F001
一次寫齊在 `Aapms.Workspace.Types`。本 feature 是契約 D 七個函式與契約 F **七個建構子**
(`VaultAlreadyInitialized` / `VaultDirMissing` / `VaultDirNotEmpty` / `VaultIdCollision` /
`InvalidName`,加上 **WAVE-4 閘門新增的 `VaultInitFailed` 與 `DeleteTargetIdDrift`**)的
**第一個生產者**。

> **2026-08-29 WAVE-4 閘門對本 spec 的兩條裁決**(全文見「待確認假設」的裁決欄):
> **裁決 A** = ASM-6 選 b,契約 F 新增 `VaultInitFailed FilePath StoreError`;
> **裁決 B** = 刪索引前先驗身分(推翻 ASM-5 的暫採),`forgetVault DeleteIndex` 與
> `purge PurgeAllVaults` 刪 `index.db` 前先 `readMarker`——讀不到照刪、讀得到但 `vmId` 不符就
> 拒絕;它的失敗通道由 **ASM-8 定案為新增的 `DeleteTargetIdDrift VaultId FilePath VaultId`**
> (與 WAVE-3 的 `WriteTargetIdDrift` 是一組對稱家族)。三條的落地是 LAW-44–LAW-47、EX-41–EX-45,以及資料流
> 與 LAW-42(b) 白名單的修訂。`Types.hs` 的四個新建構子由 **F001 的 impl** 在解凍那一輪單線補上,
> 本 feature 不碰 `workspace/src/` 底下任何 `.hs`——**七條簽名一個字都沒動**。

**驗收標準**(逐字抄自契約卡):

1. `setupHub` 冪等:第一次跑後 `spHubCreated == True`,同一位置再跑一次 `spHubCreated == False`
   且中樞內容逐欄不變 — 觀察點:契約 D 的 `setupHub` / `SetupReport`、契約 A 的 `loadHub`
2. `initVault` 以 `FreshVault` 對非空目錄回 `VaultDirNotEmpty`;以 `AdoptExisting` 對不存在的
   目錄回 `VaultDirMissing`;對任何已有 `.aapms/` 的目錄一律回 `VaultAlreadyInitialized` 且
   **不覆寫**該檔(前後位元組相同) — 觀察點:契約 D 的 `initVault`、契約 F 的三個建構子
3. `AdoptExisting` 對含 `.assetdb/` 的目錄成功後:`anLegacyMarkers` 列出該路徑,而 `.assetdb/`
   **仍然存在**、目錄內其餘檔案位元組不變 — 觀察點:契約 D 的 `AdoptNotice`
4. 名稱去空白後為空時回 `InvalidName`,不寫任何檔案 — 觀察點:契約 D 的 `initVault`、契約 F 的
   `InvalidName`
5. `forgetVault` 以 `KeepIndex` 執行後:中樞少一列,而 `<vault>/.aapms/config.toml` 與
   `<vault>/.aapms/index.db` 都還在;以 `DeleteIndex` 執行後 `index.db` 不在、`config.toml` 還在
   — 觀察點:契約 D 的 `forgetVault` / `DeleteIndex`
6. `purge` 在任何 `PurgeScope` 下都不刪除任何 `library/` 下的檔案與任何 `.md`,
   `prVaultIndexesRemoved` 只列出 `index.db` 路徑 — 觀察點:契約 D 的 `purge` / `PurgeReport`
7. `checkVaults` 不寫任何檔案(呼叫前後整棵中樞目錄的位元組相同);`syncHub` 只把 `veName` /
   `veKind` 的漂移回寫,`VaultPathMissing` 與 `VaultIdDrift` 仍原樣出現在回傳清單 — 觀察點:
   契約 D 的 `checkVaults` / `syncHub`
8. `initVaultAt` 產生的 id 與中樞既有 `veId` 相同時回 `VaultIdCollision` 並帶兩個路徑 —
   觀察點:契約 F 的 `VaultIdCollision`

**明確不做**(逐字抄自契約卡):不解析 vault 內的任何 Markdown、不開索引、不重建索引;不刪除舊的
`.assetdb/` 或 `.storyflow/`(只報告);不做 `vault info` 的統計(那要索引,屬 `service` 組合)。

追加三條由「明確不做」與 design.md「依賴方向」推出來的硬界線,全部寫成可機械驗證的條文:

- **不執行任何外部程式**(那是 F006) — LAW-37(e)
- **不自己寫任何檔案文字**:落地只經 `saveHub`(中樞)與 `initVaultAt`(marker + 空索引);
  本模組不 import `Aapms.Store.Atomic` — LAW-37(d)
- **不呼叫同層的 Scope / Projects / Tools**:`Lifecycle` / `Projects` / `Tools` 彼此不互相呼叫
  (design.md「方向是線性的」) — LAW-37(a)

## 相依性

`depends-on: [F001, F002]`——design.md「功能規劃」階段二表 #4 的「依賴」欄是 `#2`,而 `#2` 依賴
`#1`。逐條查證後兩者都真的用到:

- **F001**:`Hub`(不透明)、`HubLocation` / `hlPath`、`VaultEntry`、`ScopeIssue`、
  `WorkspaceError` 與契約 D 的六個 DTO;`loadHub` / `saveHub` / `hubVaults` /
  `upsertVault` / `removeVault`;`Location` 的 `configPath` / `thumbCacheDir`
- **F002**:`readVaultRef`(已註冊的一列 → 權威身分,失敗是降級)、`readVaultRefAt`(只知道路徑,
  失敗是硬失敗)、`lookupSelector`(`forgetVault` 的 selector 規則)

跨子系統:`graph-core` 九個 feature 全數 `done`,本 feature 用到的七個符號(`initVaultAt` /
`indexDbPath` / `markerDir` / `readMarker` / `VaultMarker` 的三個欄位存取子 / `StoreError` /
`VaultKind`)都已交付,簽名逐一開原始碼查證過,見「使用到的既有串接介面」。
(`readMarker` 是 WAVE-4 裁決 B 帶進來的第七個。)

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base` / `containers` / `directory` /
`filepath` / `text` / `time` / `toml-reader` / `aapms-core` / `aapms-store` 覆蓋本 feature 全部所需。

**與同波兩個 feature 的關係**:F005(`Projects.hs`)與 F006(`Tools.hs`)各寫一個不同的 `.hs`,
與本 feature **無任何呼叫關係**,可完全平行。三者共讀的 `Types.hs` / `Hub.hs` / `Location.hs` /
`Discovery.hs` 都只讀不寫。

## 對應的 Level 2 契約

### 契約 D(本 feature 負責的七個函式與六個 DTO)

```haskell
data InitMode    = FreshVault | AdoptExisting
data DeleteIndex = KeepIndex  | DeleteIndex
data PurgeScope  = PurgeHubOnly | PurgeAllVaults

setupHub    :: HubLocation -> IO (Either WorkspaceError SetupReport)
initVault   :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode
            -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
addVault    :: HubLocation -> Hub -> FilePath -> IO (Either WorkspaceError (Hub, VaultEntry))
forgetVault :: HubLocation -> Hub -> Text -> DeleteIndex -> IO (Either WorkspaceError (Hub, VaultEntry))
checkVaults :: Hub -> IO [ScopeIssue]
syncHub     :: HubLocation -> Hub -> IO (Either WorkspaceError (Hub, [ScopeIssue]))
purge       :: HubLocation -> Hub -> PurgeScope -> IO (Either WorkspaceError PurgeReport)

data SetupReport = SetupReport { spHubPath :: FilePath, spHubCreated :: Bool, spCacheCreated :: Bool }
data AdoptNotice = AdoptNotice { anLegacyMarkers :: [FilePath] }
data PurgeReport = PurgeReport
  { prHubRemoved :: Bool, prThumbsRemoved :: Int, prVaultIndexesRemoved :: [FilePath] }
```

七條簽名**逐字照抄契約 D**,一個字都沒動;六個 DTO 與三個 enum 都已由 F001 宣告完畢
(`Types.hs:214-254`),本 feature 一個字都不改。契約 D 的 `registerProject` / `forgetProject`
屬 F005,本 feature 不碰。

### 契約 F(本 feature 負責的七個建構子)

`VaultAlreadyInitialized FilePath` / `VaultDirMissing FilePath` / `VaultDirNotEmpty FilePath` /
`VaultIdCollision VaultId FilePath FilePath` / `InvalidName Text`。五者的**宣告與繁中訊息**都已在
F001 交付(`Types.hs:307-328`、`renderWorkspaceError`),本 feature 是它們的**第一個生產者**,
不改 `renderWorkspaceError` 一個字。

**第六、第七個是 WAVE-4 閘門新增的兩個建構子**(2026-08-29),兩者的宣告與繁中訊息都由 F001 的
impl 在 `Types.hs` 解凍那一輪補上(本 feature 不得碰那個檔),而本 feature 是**兩者的唯一
生產者**:

| 建構子 | 從哪一條裁決來 | 在本 feature 的角色 |
|---|---|---|
| `VaultInitFailed FilePath StoreError` | **裁決 A**(本 spec 的 ASM-6 選 b) | vault 根目錄 + graph-core 的 `StoreError` **原件**;`initVaultAt` **建** marker 或建空索引失敗時用它。借用 `MarkerUnreadable` 會說「marker **讀**不出來」,叫使用者去看一個還沒被建出來的檔 |
| `DeleteTargetIdDrift VaultId FilePath VaultId` | **裁決 B 的失敗通道**(本 spec 的 ASM-8 判定,WAVE-4 閘門採納 b) | 中樞那一列的 `veId` + 該 vault 的 `vePath` + marker 裡實際的 `vmId`;刪索引前驗身分發現「這個路徑上是**別人**」時用它。與 WAVE-3 的 `WriteTargetIdDrift` 是一組對稱家族(寫入目標漂移 / 刪除目標漂移),欄位形狀相同、語意各管一條路徑 |

另外**沿用**三個既有建構子(不是本 feature 新引入的語意,只是它們也會從本模組流出來):

| 建構子 | 誰產生的 | 在本 feature 的角色 |
|---|---|---|
| `VaultSelectorNotFound` / `VaultSelectorAmbiguous` | `lookupSelector`(F002) | `forgetVault` 的 selector 失敗,原樣往上拋 |
| `MarkerUnreadable FilePath StoreError` | `readVaultRefAt`(F002) | `addVault` 讀不到既有 marker 的硬失敗。**WAVE-4 之後它不再兼任「建失敗」**——那是 `VaultInitFailed` |
| `HubWriteFailed FilePath Text` | `saveHub`(F001) | 中樞寫回失敗;本模組自己的建目錄 / 刪檔失敗也走它(ASM-6 的裁決只換掉 `initVaultAt` 那一半) |

**`WriteTargetIdDrift` 不在本 feature 的產出裡**:它專屬**寫入目標**路徑(`resolveWrite`,F003),
撤除路徑走 `DeleteTargetIdDrift`——ASM-8 的裁決把這兩者分開,正是為了不讓 WAVE-3 新增
`WriteTargetIdDrift` 所要避免的一詞多義再造回來。

### 模組間公開介面(design.md「模組間公開介面」)

本 feature 用到表裡的四列(**WAVE-4 閘門已依本 spec 的建議補表**,以下為補完後的原文):

```text
Lifecycle → aapms-store   initVaultAt(寫 marker + 空索引)、indexDbPath(--delete-index 要刪的
                          那一個檔)、markerDir(.aapms 這個名字的唯一真相)、readMarker 與
                          VaultMarker 的 vmId / vmKind / vmName 三個欄位存取子(刪索引前驗身分、
                          syncHub 對帳)                              -- 2026-08-29 WAVE-4 補表
Lifecycle → Location      configPath(中樞的)與 thumbCacheDir——setupHub 建中樞、purge 清快取
                          要用                                       -- 2026-08-29 WAVE-4 補表
Lifecycle → Hub           upsertVault / removeVault(對 Hub 值的純操作)+ saveHub
Lifecycle → Discovery     AdoptExisting 與 addVault 時讀既有 marker 取 id / kind / name
```

> **兩列補表的理由(本 spec 提出、WAVE-4 閘門採納)**:`markerDir` 是「`.aapms` 這個目錄名」的唯一
> 真相(`Marker.hs:46-47`),`initVault` 的 `VaultAlreadyInitialized` 前置檢查要靠它,不能在
> workspace 再寫一份 `".aapms"` 字面值;`vmId` / `vmKind` / `vmName` 是撞號比對、`syncHub` 的
> 漂移比對與 `VaultEntry` 組裝要用的,而 `Types.hs:65` 對 `VaultMarker` 是**裸型別 import**
> (F001 的 LAW-17(d) 釘死),轉不出欄位存取子。`Lifecycle → Location` 原本整條不存在,而
> 「中樞目錄的內部佈局」的唯一真相住在 Location,本模組不自己拼 `hlPath </> "config.toml"`;
> 這條邊**不違反**「方向是線性的」(`Types ← Location ← Hub ← Discovery ← Scope`,Lifecycle
> 往左依賴)。
>
> **`readMarker` 是 WAVE-4 裁決 B 帶進來的第三個補列**:刪索引前的身分驗證要的是「這個路徑上的
> marker 現在是誰」,而 Discovery 的 `readVaultRef` 除了讀 marker 還會**把失敗折成
> `ScopeIssue`**——`VaultPathMissing` 與 `VaultMarkerBroken` 在這條路徑上要走的是「照刪」而不是
> 「降級紀錄」,折過一次反而要再拆開。直接用 `readMarker` 拿三態(讀不到 / id 相符 / id 不符)
> 最貼合裁決 B 的三個分支。兩處都**不動任何對外契約**。

## 實作方式

### 相依性查證(2026-08-29 打開 `store/src/`、`core/src/` 與 `workspace/src/` 讀到的實況)

七點與文字描述不同、必須在實作前知道的事實:

1. **`initVaultAt` 自己會 `makeAbsolute`、自己會 `createDirectoryIfMissing True (markerDir root)`**
   (`Marker.hs:134-159`)。所以 `FreshVault` 對**不存在**的目錄不需要本模組先建目錄——
   `createDirectoryIfMissing True` 連父層一起建。本模組仍要先 `canonicalizePath`,因為回傳的
   `VaultEntry.vePath` 與各種錯誤裡的路徑都必須是**同一個**正規化寫法(WAVE-2 閘門:正規化一律
   `canonicalizePath`),而 `initVaultAt` 用的是 `makeAbsolute`,兩者對 `..` 與 8.3 短檔名的結果
   不同。
2. **`initVaultAt` 的「已初始化」判準是 `doesFileExist (configPath root)`**(同上),而契約卡
   要求的是「**任何已有 `.aapms/` 的目錄**一律回 `VaultAlreadyInitialized`」。兩者不等價:
   `.aapms/` 存在但裡面沒有 `config.toml` 時 `initVaultAt` 會**照樣寫下去**。所以前置檢查必須由
   本模組自己做(判準見下方「`.aapms` 存在性的判準」),不能指望 `initVaultAt` 擋。
3. **`initVaultAt` 產生的 id 帶時間成分**:`newId PVlt name now 0`(`Marker.hs:143-144`,
   `now <- getCurrentTime`)。所以契約 D 說的「撞號時要求重跑一次,重跑即不同」成立——前提是
   重跑真的跑得起來,見「撞號後的回滾」。
4. **`initVaultAt` 會建立並立刻關閉一個空索引**(`openIndexAt` → `closeIndex`,`Marker.hs:149-155`)。
   `vault init` 之後 `<vault>/.aapms/index.db` **一定存在**——`forgetVault --delete-index` 與
   `purge --all-vaults` 的驗收才有東西可刪。本模組**自己不開索引**(LAW-37(c) 守著)。
5. **`Aapms.Store.Marker.configPath`(vault 的)與 `Aapms.Workspace.Location.configPath`(中樞的)
   同名不同義**(F001 / F002 查證留下的事實)。本 feature **只 import 中樞那一份**;vault 的
   `config.toml` 路徑在實作裡一次都不需要(前置檢查看 `markerDir`,刪索引看 `indexDbPath`),
   所以 LAW-37(b) 的白名單**不放行** `Aapms.Store.Marker.configPath`,撞名在本檔不會發生。
6. **`StoreError` 與 `WorkspaceError` 有 `VaultAlreadyInitialized` / `VaultIdCollision` 兩對同名
   建構子**(`Error.hs:35` vs `Types.hs:308`)。本 feature **只 import `WorkspaceError` 那一邊的
   建構子**;`StoreError` 一律原樣捧著、不 pattern match(ASM-6 的暫採方案不需要拆開它),所以
   撞名在本檔不會發生。
7. **`upsertVault` 的語意是「以 `veId` 為鍵,有就就地覆寫、沒有才追加到末尾」**
   (`Hub.hs:473-481` 的 `replaceOrAppend`),而 `saveHub` 的底稿式序列化對「id 還在但欄位變了」
   是**重新產生那一段**、對「id 不在了」是**整段刪除**(`Hub.hs:249-278` 的 Haddock)。
   `addVault` 的「重複納管不長第二列」與 `syncHub` 的「只改 name / kind、順序不動」因此都**不需要
   本模組再做任何事**,直接用這兩個純函式即可。

程式碼知識圖(knot)另外查到一件影響架構的事:`Aapms.Store.Marker.initVaultAt` 目前
**沒有任何呼叫者**(`knot query reachable Aapms.Store.Marker.initVaultAt --reverse --depth 2`
只回模組層節點,decl 層一個都沒有)。本 feature 是它的**第一個消費者**;`indexDbPath` 目前的
呼叫者只有 `initVaultAt` / `openVault` / `openVaultSet` 三個,全在 `aapms-store` 內,本 feature
是它在套件外的第一個消費者。這兩條新的依賴邊已逐條列進「依賴方向」。

### 「正規化」在本 spec 全篇的定義

> **正規化 = `System.Directory.canonicalizePath`**(2026-08-29 WAVE-2 閘門釘死,全子系統一致)。

本 spec 全篇的 `dir'` 一律指「`dir` 經 `canonicalizePath` 之後的值」。所有回傳的路徑
(`vePath`、`spHubPath`、`anLegacyMarkers` 的每一項、`prVaultIndexesRemoved` 的每一項)與所有
錯誤裡帶的路徑都用同一個寫法,測試才能逐字比對。

**例外一處**:`forgetVault` 與 `purge` 對 `index.db` 的**驗身分與刪除都用中樞那一列記的
`vePath` 原值**,不再正規化。理由:兩者必須指向**同一個**目錄才驗得出東西來,而
`readMarker` 本來就不做絕對化(F002 查證的事實 2),所以「驗誰就刪誰」在這裡靠的是**用同一個
字串**,不是靠正規化。見待確認假設 ASM-5(WAVE-4 裁決 B 之後的版本)。

### `.aapms` 存在性的判準

`initVault` 的第 2 條前置檢查(`VaultAlreadyInitialized`)判準是:

> `markerDir dir'` 這個**路徑存在**——不論它是目錄還是普通檔案。

與 F002 的 `detectVault`(要求**是目錄**才算命中)刻意不同,因為兩者問的問題不同:`detectVault`
問「這裡是不是一個可用的 vault 根」,`initVault` 問「這個路徑是不是**已經被佔用**」。用
「是目錄」當判準會留下一個洞:`.aapms` 是普通檔案時前置檢查放行,而 `initVaultAt` 的
`createDirectoryIfMissing` 會撞上同名檔案拋出未捕捉的 IO 例外——那不是一個可接受的行為。

### 七個函式的資料流

```text
setupHub loc
  → fp = Location.configPath loc;td = Location.thumbCacheDir loc
  → hubExisted   = doesFileExist fp
    cacheExisted = doesDirectoryExist td
  → hubExisted   == False → createDirectoryIfMissing True (hlPath loc)
                            saveHub loc (mkHub [] [] Nothing (ToolsConfig Nothing) "")
  → cacheExisted == False → createDirectoryIfMissing True td
  → Right (SetupReport (hlPath loc) (not hubExisted) (not cacheExisted))
  -- 既有的 config.toml 一個位元組都不讀、不解析、不覆寫

initVault loc hub dir kind name mode
  → T.strip name == "" → Left (InvalidName name)          -- 帶原始字串,不碰檔案系統
  → dir' = canonicalizePath dir
  → markerDir dir' 這個路徑存在 → Left (VaultAlreadyInitialized dir')
  → mode == FreshVault
      dir' 是既存目錄 且 listDirectory dir' /= [] → Left (VaultDirNotEmpty dir')
    mode == AdoptExisting
      dir' 不是既存目錄 → Left (VaultDirMissing dir')
  → initVaultAt dir' kind (T.strip name)                  -- 寫 marker + 建空索引
      Left e → 回滾 removePathForcibly (markerDir dir')    -- 半成品不留(同 LAW-19 的理由)
               Left (VaultInitFailed dir' e)               -- WAVE-4 裁決 A:專屬建構子,原件不翻譯
  → vmId m 與 hubVaults hub 的某列 veId 相同
      → 回滾:removePathForcibly (markerDir dir')
        Left (VaultIdCollision (vmId m) (該列的 vePath) dir')
  → notice = AdoptNotice [p | n <- [".assetdb", ".storyflow"]
                            , let p = dir' </> n, doesDirectoryExist p]
  → entry  = VaultEntry (vmId m) (vmName m) (vmKind m) dir'
  → hub'   = upsertVault entry hub → saveHub loc hub'
  → Right (hub', entry, notice)

addVault loc hub dir
  → dir' = canonicalizePath dir
  → readVaultRefAt hub dir'                                 -- 硬失敗:MarkerUnreadable
  → m     = vrMarker ref
    entry = VaultEntry (vmId m) (vmName m) (vmKind m) dir'
  → hub' = upsertVault entry hub → saveHub loc hub'         -- 以 id 為鍵,搬家只改 vePath
  → Right (hub', entry)

forgetVault loc hub sel di
  → lookupSelector hub sel                                  -- 先 id 後 name,逐字精確
      Left e → Left e                                       -- NotFound / Ambiguous 原樣往上
  → di == DeleteIndex → 前置驗身分:readMarker (vePath e)    -- WAVE-4 裁決 B,排在任何寫入之前
      Left _                     → 照刪(那正是 forget 最常見的理由)
      Right m, vmId m /= veId e  → Left (DeleteTargetIdDrift (veId e) (vePath e) (vmId m))
                                    -- 拒絕刪除(WAVE-4 裁決 B 的失敗通道,ASM-8 選 b)
      Right m, vmId m == veId e  → 照刪
    di == KeepIndex → 完全不讀 marker(不刪東西就不需要驗身分)
  → hub' = removeVault (veId e) hub → saveHub loc hub'      -- 先確定中樞寫得掉
  → di == DeleteIndex → removeFile (indexDbPath (vePath e)) -- 不存在就跳過,不報錯
  → Right (hub', e)

checkVaults hub
  → [issue | e <- hubVaults hub, Left issue <- readVaultRef e (vePath e)]
  -- 保序;讀得到且 id 相符的列不產生任何項目;不寫任何檔案;不展開 refs

syncHub loc hub
  → 對 hubVaults hub 逐列 readVaultRef e (vePath e)
      Left issue → 收進 issues,該列不動
      Right ref  → vmName / vmKind 與 veName / veKind 有差 → 收進 fixes(只換這兩欄)
  → fixes == [] → Right (hub, issues)                       -- 不寫檔案
  → hub' = foldr upsertVault hub fixes → saveHub loc hub'
  → Right (hub', issues)

purge loc hub scope
  → fp = Location.configPath loc;td = Location.thumbCacheDir loc
  → scope == PurgeAllVaults → 前置驗身分:對 hubVaults hub 的每一列 readMarker (vePath e)
      任一列 Right m 且 vmId m /= veId e
        → Left (DeleteTargetIdDrift (veId e) (vePath e) (vmId m))   -- 全有或全無:此刻還沒刪
      其餘(讀不到 / id 相符)→ 通過                                -- WAVE-4 裁決 B
    scope == PurgeHubOnly → 完全不讀任何 marker
  → hubRemoved = doesFileExist fp → removeFile fp
  → thumbs     = td 底下遞迴的檔案總數 → removePathForcibly td
  → scope == PurgeAllVaults
      → [indexDbPath (vePath e) | e <- hubVaults hub, 該檔存在] 逐一 removeFile
  → Right (PurgeReport hubRemoved thumbs 那份清單)
  -- 任何情況都不碰 library/、不碰任何 .md、不碰 vault 的 .aapms/config.toml
```

### 從契約原文直接推導出來的四件事(不是判斷,不進待確認假設)

1. **`spHubPath == hlPath loc`**(中樞根**目錄**,不是 `config.toml` 的路徑)。契約 A 的
   `hlPath` 欄已規定「絕對路徑,指向**目錄**(不是 `config.toml`)」,同一份文檔裡的
   「hub path」不會突然改指另一個東西。
2. **`anLegacyMarkers` 只看 vault 根的兩個固定名字,不遞迴**。`.assetdb/` 與 `.storyflow/` 是
   舊工具的 **marker 目錄**(ADR-008 的目錄圖:`.storyflow/config.toml` 就在 vault 根;
   system.md CLI 表的 `init --adopt` 也寫「在既有目錄(含舊 `.assetdb/` / `.storyflow/`)上建
   `.aapms/`」),依定義住在 vault 根。遞迴掃描一個素材庫既慢又會撈到不相干的東西,而契約卡的
   「明確不做」已經排除任何需要走訪整棵樹的統計。
3. **`checkVaults` 不產生 `RefVaultNotRegistered`**。design.md 資料流管線寫的是「對每個
   `[[vaults]]` 重讀 marker,產生 `ScopeIssue` 清單」,沒有 `refs` 展開;而「`refs` 遞移展開」是
   Scope 擁有的事實(design.md「內部模組劃分」),Lifecycle 不得呼叫 Scope(「彼此不互相呼叫」)。
   `service` 要那個資訊就自己呼叫 `resolveRead`。
4. **`veName` / `veKind` 的漂移不是 `ScopeIssue`**。契約 C 的 `ScopeIssue` 只有四個建構子,
   沒有一個表達得出「名稱快取過時」。所以 `syncHub` 的回傳清單與 `checkVaults` 對同一個 `Hub`
   的輸出必然逐項相同(LAW-28),而不是「少了被修掉的那幾條」。

## 使用到的既有串接介面

行號是**建檔當下**的導航線索;一致性檢查一律比對**簽名原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)` | `store/src/Aapms/Store/Marker.hs:134` | graph-core F005 | `initVault` 的唯一落地入口:寫 marker + 建空索引、發新 `vlt-` id |
| `indexDbPath :: FilePath -> FilePath`(`markerDir root </> "index.db"`) | `store/src/Aapms/Store/Marker.hs:52-53` | graph-core F005 | `forgetVault --delete-index` 與 `purge --all-vaults` 要刪的那一個檔 |
| `markerDir :: FilePath -> FilePath`(`root </> ".aapms"`) | `store/src/Aapms/Store/Marker.hs:46-47` | graph-core F005 | `VaultAlreadyInitialized` 的前置檢查、撞號 / 建失敗回滾要刪的那個目錄;`.aapms` 這個名字的唯一真相 |
| `readMarker :: FilePath -> IO (Either StoreError VaultMarker)` | `store/src/Aapms/Store/Marker.hs:85-93` | graph-core F005 | **刪索引前的身分驗證**(WAVE-4 裁決 B):三態 = 讀不到 / `vmId` 相符 / `vmId` 不符 |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57-63` | graph-core F005 | `VaultEntry` 的三欄來源、撞號比對、`syncHub` 的漂移比對(**`vmRefs` 不用**) |
| `configPath :: FilePath -> FilePath`(**vault 的**) | `store/src/Aapms/Store/Marker.hs:49-50` | graph-core F005 | **本 feature 不 import**;列出是因為驗收 5 要斷言它「還在」(那是測試的事),且它與 `Aapms.Workspace.Location.configPath` 同名不同義 |
| `data StoreError`(26 個建構子;`VaultAlreadyInitialized FilePath` 在 `Error.hs:35`) | `store/src/Aapms/Store/Error.hs:29-83` | graph-core F005/F008 | `initVaultAt` 的失敗原件,原樣捧進 `MarkerUnreadable`(ASM-6) |
| `data VaultKind = AssetVault \| StoryVault` | `store/src/Aapms/Store/Schema.hs:63` | graph-core F002 | `initVault` 第四參數的型別(契約 D 寫死);`Types` 不轉出它,只能從這裡取 |
| `data Hub`(不透明)、`mkHub`、`hubSourceText` | `workspace/src/Aapms/Workspace/Types.hs:91-117` | F001 | 七個函式的輸入 / 輸出;`setupHub` 造空中樞走 `mkHub` |
| `loadHub :: HubLocation -> IO (Either WorkspaceError Hub)` | `workspace/src/Aapms/Workspace/Hub.hs:79` | F001 | **本 feature 不呼叫**(七個函式都吃已載入的 `Hub`);列出是因為驗收 1 與 LAW-2 / LAW-12 用它觀察落地結果 |
| `saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())` | `workspace/src/Aapms/Workspace/Hub.hs:223` | F001 | 中樞的唯一寫入點;底稿式序列化保住註解與空白行 |
| `upsertVault :: VaultEntry -> Hub -> Hub` / `removeVault :: VaultId -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:473` / `:483` | F001 | 對 `Hub` 值的純增刪(以 `veId` 為鍵) |
| `hubVaults :: Hub -> [VaultEntry]` | `workspace/src/Aapms/Workspace/Types.hs:92`(定義)、`Hub.hs:19`(轉出) | F001 | 撞號比對、`checkVaults` / `syncHub` / `purge` 的候選清單 |
| `configPath :: HubLocation -> FilePath`(**中樞的**) | `workspace/src/Aapms/Workspace/Location.hs:48-49` | F001 | `setupHub` 判斷「本來就在」、`purge` 要刪的那個檔 |
| `thumbCacheDir :: HubLocation -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:53-54` | F001 | `setupHub` 建、`purge` 刪的縮圖快取根 |
| `readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)` | `workspace/src/Aapms/Workspace/Discovery.hs:110` | F002 | `checkVaults` / `syncHub` 的逐列重讀(失敗是降級) |
| `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)` | `workspace/src/Aapms/Workspace/Discovery.hs:135` | F002 | `addVault` 的權威身分(失敗是硬失敗 `MarkerUnreadable`) |
| `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | `workspace/src/Aapms/Workspace/Discovery.hs:77` | F002 | `forgetVault` 的 selector 規則(先 id 後 name、逐字精確、撞名回全部) |
| `canonicalizePath` / `doesFileExist` / `doesDirectoryExist` / `listDirectory` / `createDirectoryIfMissing` / `removeFile` / `removePathForcibly` | `directory` 的 `System.Directory` | - | 正規化、存在性、空目錄判定、建目錄、刪檔、回滾與清理 |
| `(</>)` | `filepath` 的 `System.FilePath` | - | `anLegacyMarkers` 的兩個固定名字 |

## 新增的介面

全部七條都在 `workspace/src/Aapms/Workspace/Lifecycle.hs`(本 feature 唯一寫入的 `.hs`)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `setupHub :: HubLocation -> IO (Either WorkspaceError SetupReport)` | 建中樞骨架(`config.toml` + `cache/thumbs/`),冪等;既有檔案完全不碰不解析 | `workspace/src/Aapms/Workspace/Lifecycle.hs:74` |
| `initVault :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))` | 前置檢查 → `initVaultAt` → 撞號檢查(撞了就回滾)→ 舊 marker 只報告 → 中樞追加一列 → 寫回 | `workspace/src/Aapms/Workspace/Lifecycle.hs:104` |
| `addVault :: HubLocation -> Hub -> FilePath -> IO (Either WorkspaceError (Hub, VaultEntry))` | 把已經是 vault 的目錄納管:重讀 marker 取身分 → 以 id 為鍵 upsert → 寫回 | `workspace/src/Aapms/Workspace/Lifecycle.hs:125` |
| `forgetVault :: HubLocation -> Hub -> Text -> DeleteIndex -> IO (Either WorkspaceError (Hub, VaultEntry))` | selector 解析 → 中樞刪整列 → 寫回;`DeleteIndex` 才多刪一個 `index.db` | `workspace/src/Aapms/Workspace/Lifecycle.hs:146` |
| `purge :: HubLocation -> Hub -> PurgeScope -> IO (Either WorkspaceError PurgeReport)` | 刪中樞 `config.toml` 與整棵 `cache/thumbs/`;`PurgeAllVaults` 另刪各 vault 的 `index.db` | `workspace/src/Aapms/Workspace/Lifecycle.hs:168` |
| `checkVaults :: Hub -> IO [ScopeIssue]` | 純體檢:逐列重讀 marker,回降級紀錄;不寫檔、無失敗通道 | `workspace/src/Aapms/Workspace/Lifecycle.hs:187` |
| `syncHub :: HubLocation -> Hub -> IO (Either WorkspaceError (Hub, [ScopeIssue]))` | 把 `veName` / `veKind` 的漂移從 marker 回寫中樞;修不掉的原樣回傳 | `workspace/src/Aapms/Workspace/Lifecycle.hs:200` |

模組匯出清單只有這七個函式;型別一律讓消費端從 `Aapms.Workspace.Types` 取,本模組**不轉出**任何
型別(與 Discovery / Scope 同一個做法)。

## 數據

本 feature **不新增、不修改、不刪除任何型別**。

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `InitMode` | 沿用(F001 宣告) | `FreshVault \| AdoptExisting` | 「這次 init 是開新的還是接管既有目錄」 |
| `DeleteIndex` | 沿用 | `KeepIndex \| DeleteIndex` | 「撤除時要不要順手刪索引」 |
| `PurgeScope` | 沿用 | `PurgeHubOnly \| PurgeAllVaults` | 「清理的半徑」 |
| `SetupReport` | 沿用 | `{ spHubPath, spHubCreated, spCacheCreated }` | 「中樞在哪、這次是剛裝好還是早就裝好」 |
| `AdoptNotice` | 沿用 | `{ anLegacyMarkers :: [FilePath] }` | 「接管的目錄裡還躺著哪些舊工具的 marker」(**只報告**) |
| `PurgeReport` | 沿用 | `{ prHubRemoved, prThumbsRemoved, prVaultIndexesRemoved }` | 「這次真的刪掉了什麼」 |
| `WorkspaceError` | 沿用 | 二十一個建構子(WAVE-4 閘門新增四個),本 feature 產生**七個**(五個 F001 交付的 + `VaultInitFailed` + `DeleteTargetIdDrift`),另沿用三個 | 「這個子系統會有哪些失敗」(Types 擁有,不是 Lifecycle) |

本 feature **新增的唯一常數**(住在 `Lifecycle.hs` 的私有範圍,不匯出):

| 常數 | 值 | 為什麼住這裡 |
|---|---|---|
| 舊 marker 目錄名清單 | `[".assetdb", ".storyflow"]`(固定順序) | ADR-017 決策六修訂版把「掃出舊 marker 只報告」指給 `vault init --adopt`,而 `.assetdb` / `.storyflow` 這兩個名字在整個 aapms 沒有別的擁有者(graph-core 只知道 `.aapms`)。它是「撤除的分層界線」的一部分:**知道它們在、而且知道不准刪** |

### 測試素材:三種目錄狀態

| 造法 | `initVault` 的預期 |
|---|---|
| 目錄不存在 | `FreshVault` → 成功(目錄由 `initVaultAt` 建);`AdoptExisting` → `VaultDirMissing` |
| 目錄存在且空 | 兩種模式都成功 |
| 目錄存在且有 `library/`、`a.md`、`.assetdb/` | `FreshVault` → `VaultDirNotEmpty`;`AdoptExisting` → 成功,`anLegacyMarkers == [dir'/.assetdb]` |
| 目錄已有 `.aapms/`(不論裡面有沒有 `config.toml`) | 兩種模式都 `VaultAlreadyInitialized`,且該目錄逐位元組不變 |
| 目錄下 `.aapms` 是普通**檔案** | 兩種模式都 `VaultAlreadyInitialized`(路徑已被佔用) |

### 測試素材:中樞

`Hub` 是不透明型別,測試造它走 `mkHub vs ps llm tools txt`(F001 的唯一建構入口)。`purge` /
`checkVaults` / `syncHub` / `forgetVault` 只讀 `hubVaults`,所以 `ps` / `llm` / `tools` 填什麼都
不影響行為;但 `txt`(底稿)會影響 `saveHub` 寫出來的**檔案文字**,驗「註解與空白行保留」的
example 必須從一份真的有註解的 `config.toml` 經 `loadHub` 造 `Hub`,不能用 `mkHub _ _ _ _ ""`。

## Laws

### `setupHub`

- **LAW-1(冪等且不改位元組)**:對任意 `loc`,連續兩次 `setupHub loc` 都回 `Right`;第二次的
  `spHubCreated == False` 且 `spCacheCreated == False`,且第一次結束後與第二次結束後
  **整棵中樞目錄逐位元組相同**。
- **LAW-2(`setupHub` 之後 `loadHub` 一定成功)**:對任意原本不存在中樞的 `loc`,`setupHub loc` 回
  `Right _` 之後 `loadHub loc` 回 `Right h`,且 `hubVaults h == []`、`hubProjects h == []`、
  `hubLlm h == Nothing`、`tcSevenZip (hubTools h) == Nothing`。(這條把「跑完 `workspace setup`
  之後任何指令都不該再看到 `HubNotFound`」釘死。)
- **LAW-3(兩個 Bool 的判準)**:`spHubCreated == True` **當且僅當**呼叫前
  `Aapms.Workspace.Location.configPath loc` 不存在;`spCacheCreated == True` **當且僅當**呼叫前
  `thumbCacheDir loc` 不是既存目錄。呼叫成功後兩者**都存在**。`spHubPath == hlPath loc`
  (中樞根目錄,不是 `config.toml`)。
- **LAW-4(既有檔案完全不碰、不解析)**:若呼叫前 `configPath loc` 已存在且內容為任意位元組串
  (**包含解不開的 TOML 與不合規的欄位**),`setupHub loc` 仍回 `Right sp`、`spHubCreated sp ==
  False`,該檔**逐位元組不變**,且**不回** `HubUnreadable` / `HubMalformed` / `HubNotFound`。
- **LAW-5(只建這兩個東西)**:呼叫前後,中樞目錄下除了 `config.toml` 與 `cache/thumbs/` 這條路徑上
  的目錄之外,沒有任何檔案或目錄被新增、修改或刪除;特別是**不建立** `[[vaults]]` 提到的任何
  vault 目錄。

### `initVault`:前置檢查

- **LAW-6(名稱檢查最先,且不碰檔案系統)**:若 `T.strip name` 為空,則對**任意** `dir` / `kind` /
  `mode` 回 `Left (InvalidName name)`——第二個值是**原始**字串(不是 strip 後的);且呼叫前後
  `dir`(存在時)底下整棵樹逐位元組相同,`dir` 不存在時**仍然不存在**,中樞檔案位元組不變。
- **LAW-7(已被佔用一律 `VaultAlreadyInitialized`)**:若 `markerDir dir'` 這個路徑存在(是目錄或是
  普通檔案都算),則對**兩種** `InitMode` 都回 `Left (VaultAlreadyInitialized dir')`,且 `dir'`
  底下整棵樹逐位元組相同——特別是 `.aapms/config.toml`(若在)**不被覆寫**,中樞檔案也不被寫入。
- **LAW-8(`FreshVault` 的目錄前置)**:`mode == FreshVault` 且 LAW-6 / LAW-7 都不成立時——`dir'` 是既存
  目錄且 `listDirectory dir'` 非空 → `Left (VaultDirNotEmpty dir')`,不寫任何檔案;`dir'` 不存在
  或存在且為空 → 通過(繼續往下)。
- **LAW-9(`AdoptExisting` 的目錄前置)**:`mode == AdoptExisting` 且 LAW-6 / LAW-7 都不成立時——`dir'`
  不是既存目錄 → `Left (VaultDirMissing dir')`,不寫任何檔案;是既存目錄(**可非空**)→ 通過。
- **LAW-10(判定順序恒定)**:四條前置檢查的判定順序恒為 LAW-6 → LAW-7 → (LAW-8 或 LAW-9)。任兩條同時成立時,
  回**排在前面**的那一個錯誤(例如:空名稱 + 已有 `.aapms/` → `InvalidName`;已有 `.aapms/` +
  `FreshVault` + 非空 → `VaultAlreadyInitialized`)。
- **LAW-11(前置檢查失敗一律零副作用)**:LAW-6 / LAW-7 / LAW-8 / LAW-9 任一條命中時,呼叫前後**中樞檔案**與
  **`dir'` 底下整棵樹**都逐位元組相同,且回傳的 `Hub` 值不存在(回的是 `Left`,呼叫端手上那個
  `Hub` 自然不變)。

### `initVault`:成功路徑

- **LAW-12(marker 是真相,`VaultEntry` 是它的投影)**:成功時 `readMarker dir'` 回 `Right m`,且
  `vmKind m == kind`、`vmName m == T.strip name`、`vmRefs m == []`;回傳的 `VaultEntry` 滿足
  `veId == vmId m`、`veName == vmName m`、`veKind == vmKind m`、`vePath == dir'`。
  (名稱**寫進 marker 的是 strip 後的值**,見待確認假設 ASM-2。)
- **LAW-13(中樞只多一列,其餘三段不動)**:成功時回傳的 `Hub` 的 `hubVaults` 等於原本的
  `hubVaults ++ [entry]`(順序保留、既有列逐欄不變),而 `hubProjects` / `hubLlm` / `hubTools`
  **逐欄不變**。
- **LAW-14(真的落地了)**:成功後 `loadHub loc` 回 `Right h2`,且 `hubVaults h2` 含一列與 `entry`
  逐欄相等;若中樞原檔有註解與空白行,它們**逐字仍在**(`saveHub` 的性質)。
- **LAW-15(`AdoptExisting` 不動既有內容)**:成功時 `dir'` 底下**除了新建的 `.aapms/`** 之外,所有
  檔案與子目錄逐位元組相同——特別是 `library/` 下的檔案、任何 `.md`、`.assetdb/`、`.storyflow/`
  都還在且內容不變。
- **LAW-16(`AdoptNotice`)**:`anLegacyMarkers` 恰好等於
  `[dir' </> n | n <- [".assetdb", ".storyflow"], dir' </> n 是既存目錄]`(**固定順序、不遞迴**);
  清單裡的每個路徑在呼叫**之後仍然存在**(只報告不刪除)。`FreshVault` 成功時
  `anLegacyMarkers == []`(空目錄不可能有)。
- **LAW-17(空索引一定被建出來)**:成功後 `indexDbPath dir'` 存在——它由 `initVaultAt` 建立,本模組
  不自己開索引。

### `initVault`:撞號

- **LAW-18(撞號的三個值)**:若 `initVaultAt` 產生的 `vmId m` 等於 `hubVaults hub` 中某一列 `e` 的
  `veId`,則回 `Left (VaultIdCollision (vmId m) (vePath e) dir')`——**第二個是中樞裡既有那個
  vault 的路徑、第三個是這次要建立的路徑**,兩者順序不可互換;`renderWorkspaceError` 的輸出
  同時含這兩個路徑。
- **LAW-19(撞號要回滾)**:撞號時 `markerDir dir'` 在呼叫後**不存在**,且 `dir'` 底下其餘檔案逐位元組
  相同、中樞檔案位元組不變。因此**對同一個目錄立刻重跑一次 `initVault`,不會撞到
  `VaultAlreadyInitialized`**(id 含時間成分,重跑即不同——契約 D 的「要求重跑一次」因此是可執行
  的建議)。見待確認假設 ASM-3。
- **LAW-20(任何 `Left` 都不動中樞檔案)**:`initVault` 回 `Left` 的**每一種**情況下,
  `configPath loc` 的位元組都不變。

### `addVault`

- **LAW-21(身分一律來自 marker)**:成功時回傳的 `VaultEntry` 滿足 `veId == vmId m`、
  `veName == vmName m`、`veKind == vmKind m`、`vePath == dir'`,其中 `m` 是 `dir'` 的 marker;
  呼叫端無法用任何參數影響這四欄。
- **LAW-22(讀不到 marker 是硬失敗)**:若 `readMarker dir'` 回 `Left err`(路徑不存在、`.aapms/`
  不在、marker 壞掉都算),則 `addVault` 回 `Left (MarkerUnreadable dir' err)`,`err` 是**原件**
  (不轉字串、不翻譯),且中樞檔案位元組不變。
- **LAW-23(以 id 為鍵,重複納管不長第二列)**:對同一個目錄連續呼叫兩次,第二次回傳的 `hubVaults`
  與第一次**逐欄相同**;把中樞裡同一個 id 的那列 `vePath` 改成別的路徑後再 `addVault dir`,結果
  仍只有**一列**,且 `vePath == dir'`(搬家只改路徑,身分不變)。見待確認假設 ASM-4。
- **LAW-24(不動 vault 目錄)**:呼叫前後 `dir'` 底下整棵樹逐位元組相同——不建立、不修改、不刪除
  任何東西,特別是**不覆寫 marker**。

### `forgetVault`

- **LAW-25(selector 規則同 `lookupSelector`)**:對任意 `hub` 與 `sel`,`forgetVault` 選中的那一列
  恒等於 `lookupSelector hub sel` 的 `Right`;`lookupSelector` 回 `Left e` 時 `forgetVault` 原樣
  回 `Left e`(`VaultSelectorNotFound` / `VaultSelectorAmbiguous`,清單含全部撞名的列)。
- **LAW-26(selector 失敗零副作用)**:LAW-25 的 `Left` 情況下,中樞檔案位元組不變,且**沒有任何**
  `index.db` 被刪除。
- **LAW-27(`KeepIndex`:只動中樞)**:成功後回傳的 `Hub` 的 `hubVaults` 等於原本的清單**刪掉那一列**
  (其餘列逐欄不變、相對順序不變),`hubProjects` / `hubLlm` / `hubTools` 逐欄不變;
  `loadHub loc` 重新讀得到這個結果;而 `vePath e` 底下**整棵樹逐位元組相同**——
  `.aapms/config.toml` 與 `.aapms/index.db` **都還在**。
- **LAW-28(`DeleteIndex`:只多刪一個檔)**:成功後 `indexDbPath (vePath e)` **不存在**,而
  `Aapms.Store.Marker.configPath (vePath e)` **仍存在**;`vePath e` 底下除了 `index.db` 之外的
  每一個檔案逐位元組相同——特別是 `library/` 下的檔案與任何 `.md` 一個都沒少。
  **前提是身分驗證通過**(WAVE-4 裁決 B,見 LAW-45)。
- **LAW-29(刪索引失敗不算失敗)**:`DeleteIndex` 時若 `indexDbPath (vePath e)` 本來就不存在(路徑
  已搬走、索引已被刪過),`forgetVault` 仍回 `Right`,中樞那一列照樣被移除(另見 LAW-47)。
- **LAW-30(回傳被移除的那一列)**:成功時回傳的 `VaultEntry` 與呼叫前 `hubVaults hub` 裡被刪掉的
  那一列**逐欄相同**(是中樞記的值,不是 marker 的值——這一列已經要走了,不重讀真相)。

### `checkVaults` 與 `syncHub`

- **LAW-31(`checkVaults` 的內容與順序)**:`checkVaults h` 逐項等於
  `[issue | e <- hubVaults h, readVaultRef e (vePath e) == Left issue]`——順序同 `hubVaults`,
  讀得到且 `vmId == veId` 的列**不產生任何項目**;`veName` / `veKind` 與 marker 不符**也不產生
  任何項目**(那不是 `ScopeIssue` 的值域)。
- **LAW-32(`checkVaults` 不寫任何東西,也沒有失敗通道)**:呼叫前後整棵中樞目錄與每個 `vePath`
  底下的目錄樹都**逐位元組相同**;函式型別沒有 `Either`,對任何 `Hub`(含空中樞、含指向不存在
  路徑的列)都回得出一個清單。
- **LAW-33(不展開 `refs`)**:任何 marker 的 `refs` 內容都不影響 `checkVaults` 的輸出;輸出裡
  **永遠不出現** `RefVaultNotRegistered`。
- **LAW-34(`syncHub` 只修 `veName` / `veKind`)**:對每一列,若 `readVaultRef` 成功且
  `vmName m /= veName e` 或 `vmKind m /= veKind e`,則新 `Hub` 的該列 `veName == vmName m`、
  `veKind == vmKind m`,而 `veId` 與 `vePath` **不變**;`readVaultRef` 成功且兩欄都相同的列
  逐欄不變;`readVaultRef` 失敗的列**逐欄不變**(修不掉的不亂動)。清單長度與順序不變。
- **LAW-35(`syncHub` 的 issue 清單等於 `checkVaults`)**:對任意 `hub`,`syncHub loc hub` 回
  `Right (_, issues)` 時,`issues` 與 `checkVaults hub` **逐項相同**(含順序)——
  `VaultPathMissing` / `VaultMarkerBroken` / `VaultIdDrift` 都原樣出現。
- **LAW-36(方向只有 marker → 中樞;沒有漂移就不寫)**:呼叫前後每個 `vePath` 底下整棵樹**逐位元組
  相同**(marker **絕不**被反向覆寫);若沒有任何一列需要修正,`configPath loc` 的位元組也不變;
  有列需要修正時,`loadHub loc` 讀回的那一列的 `veName` / `veKind` 等於 marker 的值,而原檔的
  註解與空白行逐字仍在。

### `purge`

- **LAW-37(`PurgeHubOnly` 的範圍)**:成功後 `configPath loc` **不存在**且 `prHubRemoved == True`
  (呼叫前它就不存在時 `prHubRemoved == False`);`thumbCacheDir loc` **不存在**,
  `prThumbsRemoved` 等於呼叫前該目錄樹底下的**檔案總數**;中樞目錄下**其他**檔案與目錄
  (使用者自己放的東西、未知檔)**逐位元組不變**。
- **LAW-38(`PurgeHubOnly` 不碰任何 vault)**:`prVaultIndexesRemoved == []`,且每個
  `vePath e` 底下整棵樹逐位元組相同。
- **LAW-39(`PurgeAllVaults` 只多刪 `index.db`)**:`prVaultIndexesRemoved` 逐項等於實際被刪掉的
  `indexDbPath (vePath e)`(順序同 `hubVaults`;呼叫前就不存在的**不列入**);每個 `vePath e`
  底下除了 `index.db` 之外的每一個檔案逐位元組相同——`.aapms/config.toml` 還在、
  `library/` 下的檔案還在。**前提是每一列的身分驗證都通過**(WAVE-4 裁決 B,見 LAW-46:任一列漂移時
  本條不適用,因為那時什麼都不會被刪)。
- **LAW-40(任何 `PurgeScope` 都不刪 `library/` 與 `.md`)**:對任意 `scope`、任意中樞內容,呼叫前後
  每個 vault 的 `library/` 底下所有檔案與**副檔名為 `.md` 的所有檔案**(不論在哪一層)逐位元組
  相同,一個都沒少。`prVaultIndexesRemoved` 的每一項的檔名恒為 `index.db`。
- **LAW-41(冪等)**:對已經 purge 過的同一組輸入再跑一次,回 `Right (PurgeReport False 0 [])`。

### 依賴方向與職責界線

- **LAW-42(以 import 行驗證;**比對前先去除行尾 `\r`**)**:專案的 `core.autocrlf` 讓 `.hs` 在乾淨
  checkout 上是 CRLF,逐字比對前必須先把行尾的 `\r` 去掉(WAVE-1 的教訓)。
  `Lifecycle.hs` 的 **import 行**滿足:
  - (a) **完全不得**出現 `import Aapms.Workspace.Scope` / `Aapms.Workspace.Projects` /
    `Aapms.Workspace.Tools` ——`Lifecycle` / `Projects` / `Tools` 是同層,design.md 明訂
    「彼此不互相呼叫」。本套件內允許的 import 只有 `Aapms.Workspace.Types` /
    `Aapms.Workspace.Location` / `Aapms.Workspace.Hub` / `Aapms.Workspace.Discovery` 四個。
  - (b) **若**有對 `Aapms.Store.Marker` 的 import 行,它**必須逐字是**
    `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)`。
    (**2026-08-30 E001 修訂**:字串多了 `initVaultAtWith` 一個名字——`initVaultWith` 要靠它把明碼
    時間往下傳。守的三件事①②③**一條都沒有放寬**。E001 落地前的原字串不含 `initVaultAtWith`;
    以 **E001 的 LAW-6 為準**。)
    **這條 law 守的是三件事,不是 import 衛生**:①放行的欄位存取子沒有 `vmRefs`,所以日後有人
    在本模組展開 `refs`(那是 Scope 的事)會編得過但**這條紅**;②沒有 `openVault` /
    `closeVault` / `VaultHandle`——**不開索引、不重建索引**;③沒有 `configPath`,所以中樞與
    vault 的兩個同名 `configPath` 不可能在本檔撞名。放寬成 `VaultMarker (..)` 或多列任何一個
    名字都要紅。
    (`readMarker` 是 **2026-08-29 WAVE-4 裁決 B 加進白名單**的:刪索引前要驗身分,而
    design.md「模組間公開介面」的 `Lifecycle → aapms-store` 那一列已同步補上它。修訂前這條
    law 的白名單沒有它,理由是「重讀 marker 一律經 Discovery」——裁決 B 之後那個理由不再成立,
    因為 `readVaultRef` 會把失敗折成 `ScopeIssue`,而這條路徑要的是未折疊的三態。)
    (寫成條件式是因為骨架階段的簽名用不到這五個名字,留著會有 `-Wall` 的 redundant import
    警告;impl 填本體時才會出現這一行。)
  - (c) 對 `Aapms.Store.Schema` 的 import 行**必須逐字是** `import Aapms.Store.Schema (VaultKind)`
    ——只取型別(契約 D 的簽名寫死了它),不得取 `openIndexAt` / `closeIndex` /
    `parseVaultKind` / `renderVaultKind`。這條**不是條件式**:骨架階段就有這一行。
  - (d) **完全不得** import `Aapms.Store.Atomic` ——本模組不自己寫任何檔案文字,落地只經
    `saveHub`(中樞)與 `initVaultAt`(marker)。
  - (e) **完全不得** import `Aapms.Store`(門面)、`Aapms.Store.Index`、`Aapms.Store.MultiVault`、
    `Aapms.Store.Query`、`Aapms.Store.Write`、`Aapms.Store.Create`、`Aapms.Store.Edit` ——
    不開索引、不重建索引、不讀 vault 內容、不解析任何 Markdown。
  - (f) **完全不得** import `System.Process` ——不執行任何外部程式(那是 F006)。

  **判準只看 import 行,不做全檔字串搜尋**:本檔的 Haddock 本來就會提到 `readMarker` /
  `library/` / `.assetdb/` 這些名字來說明界線,全檔搜尋會把「文件寫得清楚」誤判成「越界」。

- **LAW-43(七個函式合起來的檔案系統足跡)**:對任意輸入,本模組**只可能**新增 / 修改 / 刪除下列
  路徑,其他一律不碰:
  (i) 中樞的 `config.toml`(`setupHub` 建、`saveHub` 寫、`purge` 刪);
  (ii) 中樞的 `cache/thumbs/` 整棵樹(`setupHub` 建、`purge` 刪);
  (iii) `<vault>/.aapms/`(`initVault` 經 `initVaultAt` 建;撞號或 `initVaultAt` 失敗時回滾刪);
  (iv) `<vault>/.aapms/index.db`(`forgetVault --delete-index` 與 `purge --all-vaults` 刪)。
  特別是:**任何 `.md` 檔、任何 `library/` 下的檔案、任何 `.assetdb/` 或 `.storyflow/` 目錄
  在任何情況下都不被修改或刪除**。

### WAVE-4 閘門裁決追加(2026-08-29)

- **LAW-44(`initVaultAt` 失敗 → `VaultInitFailed`,且不留半成品)**:若
  `initVaultAt dir' kind (T.strip name)` 回 `Left err`,則 `initVault` 回
  `Left (VaultInitFailed dir' err)`——`err` 是**原件**(不轉字串、不翻譯,這一層不翻譯);
  且 `markerDir dir'` 在呼叫後**不存在**、`dir'` 底下其餘檔案逐位元組相同、中樞檔案位元組不變
  (回滾的理由同 LAW-19:留下半成品會讓下一次重跑撞上 `VaultAlreadyInitialized`)。
  **不得**回 `MarkerUnreadable`——那則訊息會說「marker **讀**不出來」,叫使用者去看一個還沒被
  建出來的檔(WAVE-4 裁決 A)。
- **LAW-45(`forgetVault` 刪索引前先驗身分)**:`DeleteIndex` 時,在**寫任何東西之前**先
  `readMarker (vePath e)`,三態各自對應一種行為:
  (a) `Left _`(路徑不見、marker 壞)→ **照刪**,行為與 WAVE-4 之前完全相同;
  (b) `Right m` 且 `vmId m /= veId e` → `Left (DeleteTargetIdDrift (veId e) (vePath e) (vmId m))`
  ——**三個值依序是中樞記的 id、那一列的 `vePath`、marker 裡實際的 id**;此時**中樞檔案位元組
  不變、`hubVaults` 那一列還在、沒有任何檔案被刪**(零副作用);
  (c) `Right m` 且 `vmId m == veId e` → 照刪。
  `KeepIndex` 時**完全不讀 marker**:不刪東西就不需要驗身分,所以 (b) 的情境在 `KeepIndex`
  下仍回 `Right`。(建構子的裁決見 ASM-8:選 b。)
- **LAW-46(`purge PurgeAllVaults` 是全有或全無)**:`PurgeAllVaults` 對 `hubVaults hub` 的**每一列**
  先做一次 LAW-45 的三態判定,**全部通過才開始刪任何東西**;任一列落在 (b) 即回
  `Left (DeleteTargetIdDrift …)`,而且此時**中樞的 `config.toml` 還在、`cache/thumbs/` 還在、
  每一個 `index.db` 都還在**——整棵中樞目錄與每個 `vePath` 底下逐位元組不變。
  `PurgeHubOnly` **完全不讀任何 marker**。
- **LAW-47(驗身分不改變「讀不到就照刪」)**:對一個 `vePath` 指向不存在路徑、或 `.aapms/` 在但
  marker 解不開的列,`forgetVault … DeleteIndex` 與 `purge … PurgeAllVaults` 的結果與 WAVE-4 之前
  **完全相同**(刪得到就刪、沒東西可刪就跳過,一律回 `Right`)——身分驗證只擋「讀得到而且是
  **別人**」這一種情況,不擋「讀不到」。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」**逐條**判定,不是整批全紅):
>
> - **預期綠**:**LAW-42 的六條子斷言 (a)–(f) 全部**。它們驗的是骨架原文自身就承載的事實
>   (本檔的 import 行),不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠就
>   退回重寫。** 其中 (b) 是條件式,**兩個階段都預期綠**:骨架階段沒有對 `Aapms.Store.Marker`
>   的 import 行,條件為假即通過;impl 補上之後那一行必須**逐字**相符才算通過。(c) 從骨架階段
>   起就是實斷言(骨架已經有 `import Aapms.Store.Schema (VaultKind)`)。
> - **預期紅**:其餘每一條 law 與每一個 example——七個函式的本體全是 `undefined`。
>
> 骨架裡**沒有**任何不是 `undefined` 的本體。LAW-43 與 WAVE-4 追加的 LAW-44–LAW-47 都是行為條文
> (要真的跑函式才驗得到),因此**一律預期紅**,不屬於上面那組綠。
>
> **WAVE-4 對紅綠預期的唯一影響**:LAW-42(b) 的逐字字串多了一個 `readMarker`。它仍是條件式、
> 仍**兩個階段都預期綠**——骨架階段照樣沒有那一行。綠的條數不變(六條)。

## Examples

| # | 輸入 | 預期 | 覆蓋的 law |
|---|---|---|---|
| EX-1 | 空的暫存目錄 `H` 當中樞;`setupHub (HubLocation H FromEnv)` | `Right (SetupReport H True True)`;`H/config.toml` 與 `H/cache/thumbs/` 都存在 | LAW-1, LAW-3 |
| EX-2 | 承 EX-1 立刻再跑一次 | `Right (SetupReport H False False)`,且 `H` 整棵樹與第一次結束時**逐位元組相同** | LAW-1, LAW-3 |
| EX-3 | 承 EX-1 之後 `loadHub` | `Right h`,`hubVaults h == []`、`hubProjects h == []`、`hubLlm h == Nothing`、`tcSevenZip (hubTools h) == Nothing` | LAW-2 |
| EX-4 | `H/config.toml` 先放一份**解不開**的 TOML(`id   = "vlt-`),再 `setupHub` | `Right sp`,`spHubCreated sp == False`,該檔逐位元組不變;**不是** `HubUnreadable` | LAW-4 |
| EX-5 | `H` 裡另有一個 `H/notes.txt`;`setupHub H` | `notes.txt` 逐位元組不變,沒有其他新檔案 | LAW-5 |
| EX-6 | `initVault loc hub V AssetVault "   " FreshVault`(`V` 不存在) | `Left (InvalidName "   ")`——帶**原始**字串;`V` 仍不存在,中樞檔案位元組不變 | LAW-6, LAW-11 |
| EX-7 | `V` 已有 `V/.aapms/config.toml`(內容任意);`initVault … FreshVault` 與 `… AdoptExisting` 各跑一次 | 兩次都 `Left (VaultAlreadyInitialized V')`,`V/.aapms/config.toml` 逐位元組不變 | LAW-7, LAW-10 |
| EX-8 | `V/.aapms` 是普通**檔案**;`initVault … AdoptExisting` | `Left (VaultAlreadyInitialized V')`,不拋例外 | LAW-7 |
| EX-9 | `V` 存在且含 `a.md`;`initVault … FreshVault` | `Left (VaultDirNotEmpty V')`,`a.md` 逐位元組不變,`V/.aapms` 不存在 | LAW-8, LAW-11 |
| EX-10 | `V` 不存在;`initVault … AdoptExisting` | `Left (VaultDirMissing V')`,`V` 仍不存在 | LAW-9, LAW-11 |
| EX-11 | `V` 不存在;`initVault … FreshVault` | `Right`,`V/.aapms/config.toml` 與 `V/.aapms/index.db` 都存在 | LAW-12, LAW-17 |
| EX-12 | `V` 空目錄;`initVault loc hub V StoryVault "  Lore  " FreshVault` | `Right (hub', e, AdoptNotice [])`;`readMarker V'` 的 `vmName == "Lore"`、`vmKind == StoryVault`、`vmRefs == []`;`e == VaultEntry (vmId m) "Lore" StoryVault V'` | LAW-12, LAW-16 |
| EX-13 | 承 EX-12,中樞原檔有 `# 我的註記` 與空白行;`loadHub loc` | `hubVaults` 含 `e`(逐欄相等),而檔案裡 `# 我的註記` 與空白行**逐字仍在** | LAW-14 |
| EX-14 | 承 EX-12,比較 `hub` 與 `hub'` | `hubVaults hub' == hubVaults hub ++ [e]`;`hubProjects` / `hubLlm` / `hubTools` 逐欄相同 | LAW-13 |
| EX-15 | `V` 含 `library/x.png`、`notes.md`、`.assetdb/`(內有一個檔);`initVault … AdoptExisting` | `Right (_, _, AdoptNotice [V'/.assetdb])`;`.assetdb/` **仍存在**且內容不變,`library/x.png` 與 `notes.md` 逐位元組不變 | LAW-15, LAW-16 |
| EX-16 | `V` 同時含 `.assetdb/` 與 `.storyflow/`;`initVault … AdoptExisting` | `anLegacyMarkers == [V'/.assetdb, V'/.storyflow]`(**固定順序**) | LAW-16 |
| EX-17 | `V` 含 `sub/.assetdb/`(在子目錄裡,不在根);`initVault … AdoptExisting` | `anLegacyMarkers == []`——**不遞迴** | LAW-16 |
| EX-18 | 中樞已有一列 `veId == vlt-aaaa1111`、`vePath == O`;讓 `initVaultAt` 產出同一個 id(以固定時間 / 名稱造出撞號)後 `initVault … V …` | `Left (VaultIdCollision (VaultId "vlt-aaaa1111") O V')`——第二個是 `O`、第三個是 `V'`;`renderWorkspaceError` 的輸出同時含這兩個路徑 | LAW-18 |
| EX-19 | 承 EX-18,檢查 `V` | `V/.aapms` **不存在**(已回滾),`V` 底下其餘檔案逐位元組不變,中樞檔案位元組不變 | LAW-19, LAW-20 |
| EX-20 | `V` 是一個已 init 好的 vault(marker `id=vlt-7f3b2a91 / kind=asset / name="real"`);`addVault loc hub V` | `Right (hub', e)`,`e == VaultEntry (VaultId "vlt-7f3b2a91") "real" AssetVault V'` | LAW-21 |
| EX-21 | 承 EX-20 立刻再 `addVault loc hub' V` | `hubVaults` 與第一次**逐欄相同**(只有一列) | LAW-23 |
| EX-22 | 中樞已有一列 `veId == vlt-7f3b2a91`、`vePath == O`(舊位置);`addVault loc hub V`(同一個 id,新位置) | 結果只有**一列**,`vePath == V'`;`O` 那一列不再存在 | LAW-23 |
| EX-23 | `X` 不存在;`addVault loc hub X` | `Left (MarkerUnreadable X' (VaultMarkerMissing (Aapms.Store.Marker.configPath X')))`,中樞檔案位元組不變 | LAW-22 |
| EX-24 | 承 EX-20,呼叫前後對 `V` 遞迴列出全部檔案與內容 | 完全相同(marker 沒被覆寫) | LAW-24 |
| EX-25 | 中樞有 e3 / e4 兩列 `veName == "lore"`;`forgetVault loc hub "lore" KeepIndex` | `Left (VaultSelectorAmbiguous "lore" [e3, e4])`,中樞檔案位元組不變,兩個 vault 的 `index.db` 都還在 | LAW-25, LAW-26 |
| EX-26 | `forgetVault loc hub "nope" DeleteIndex` | `Left (VaultSelectorNotFound "nope")`,**沒有任何**檔案被刪 | LAW-25, LAW-26 |
| EX-27 | 中樞三列,對中間那一列 `forgetVault … KeepIndex` | `Right (hub', e)`;`hubVaults hub'` 是剩下兩列(順序不變);`loadHub` 讀得到同樣結果;`<vault>/.aapms/config.toml` 與 `<vault>/.aapms/index.db` **都還在** | LAW-27, LAW-30 |
| EX-28 | 同一情境改用 `DeleteIndex`(該 vault 另有 `library/a.png` 與 `b.md`) | `index.db` **不存在**;`config.toml`、`library/a.png`、`b.md` 逐位元組不變 | LAW-28 |
| EX-29 | 該 vault 的 `index.db` 事先手動刪掉;`forgetVault … DeleteIndex` | `Right`,中樞那一列照樣被移除 | LAW-29 |
| EX-30 | 中樞三列:一列正常、一列 `vePath` 指向不存在的路徑、一列 marker 的 id 與中樞不符;`checkVaults hub` | `[VaultPathMissing e2 p2', VaultIdDrift e3 (marker 的 id)]`——順序同 `hubVaults`,正常那列不出現 | LAW-31 |
| EX-31 | 承 EX-30,呼叫前後對中樞目錄與三個 vault 目錄遞迴列出全部檔案與內容 | 完全相同 | LAW-32 |
| EX-32 | 某 vault 的 marker `refs = ["vlt-11112222"]`(該 id 不在中樞);`checkVaults hub` | 輸出裡**沒有** `RefVaultNotRegistered` | LAW-33 |
| EX-33 | 中樞那列 `veName == "stale"`、`veKind == StoryVault`,marker 是 `"real"` / `AssetVault`;`syncHub loc hub` | `Right (hub', issues)`;該列變成 `veName == "real"`、`veKind == AssetVault`,`veId` / `vePath` 不變;`loadHub` 讀得到同樣的值 | LAW-34, LAW-36 |
| EX-34 | 承 EX-30 的中樞(含兩個修不掉的問題)跑 `syncHub` | `issues` 與 `checkVaults` 對同一個 `hub` 的輸出**逐項相同**;那兩列在 `hub'` 裡逐欄不變 | LAW-34, LAW-35 |
| EX-35 | 中樞每一列都與 marker 一致;`syncHub loc hub` | `Right (hub, [])`,`configPath loc` 的位元組**不變**(沒寫檔) | LAW-36 |
| EX-36 | 承 EX-33,呼叫前後對每個 vault 目錄遞迴列出全部檔案與內容 | 完全相同——marker 沒有被反向覆寫 | LAW-36 |
| EX-37 | 中樞有 `config.toml`、`cache/thumbs/ab/<sha>.png` 兩個檔與一個 `notes.txt`,中樞列了兩個 vault;`purge loc hub PurgeHubOnly` | `Right (PurgeReport True 2 [])`(兩個縮圖檔);`config.toml` 與 `cache/thumbs/` 不存在,`notes.txt` 逐位元組不變;兩個 vault 的 `index.db` 都**還在** | LAW-37, LAW-38 |
| EX-38 | 同一情境改用 `PurgeAllVaults` | `prVaultIndexesRemoved == [vault1/.aapms/index.db, vault2/.aapms/index.db]`(順序同 `hubVaults`);兩個 `.aapms/config.toml`、`library/` 下的檔案與所有 `.md` 逐位元組不變 | LAW-39, LAW-40 |
| EX-39 | 其中一個 vault 的 `index.db` 事先刪掉;`purge … PurgeAllVaults` | `prVaultIndexesRemoved` 只列另一個,回 `Right` | LAW-39 |
| EX-40 | 承 EX-38 立刻再跑一次 | `Right (PurgeReport False 0 [])` | LAW-41 |
| EX-41 | 讓 `initVaultAt` 失敗(例如 `V` 的父層唯讀、或 `V/.aapms` 這個名字被一個唯讀檔佔住且繞過前置檢查的情境);`initVault … FreshVault` | `Left (VaultInitFailed V' err)`,`err` 與直接呼叫 `initVaultAt V' kind name'` 得到的 `Left` **逐欄相同**;`V/.aapms` **不存在**(已回滾),中樞檔案位元組不變 | LAW-44 |
| EX-42 | 中樞那列 `veId == vlt-aaaa1111`、`vePath == P`,而 `P` 上的 marker 實際是 `vlt-bbbb2222`;`forgetVault loc hub "vlt-aaaa1111" DeleteIndex` | `Left (DeleteTargetIdDrift (VaultId "vlt-aaaa1111") P (VaultId "vlt-bbbb2222"))`;中樞檔案位元組不變、`hubVaults` 那一列還在、`P/.aapms/index.db` **還在** | LAW-45(b) |
| EX-43 | 同一情境改用 `KeepIndex` | `Right`,中樞少一列,`P/.aapms/index.db` 與 `config.toml` 都還在——**完全不讀 marker**,漂移不影響 | LAW-45(`KeepIndex` 分支) |
| EX-44 | 中樞兩列,第一列身分相符、第二列 id 漂移;`purge loc hub PurgeAllVaults` | `Left (DeleteTargetIdDrift …)`,且中樞 `config.toml`、`cache/thumbs/` 與**兩個** `index.db` 全都還在(全有或全無) | LAW-46 |
| EX-45 | 中樞那列的 `vePath` 指向一個不存在的路徑;`forgetVault … DeleteIndex` | `Right`——讀不到就照刪(沒東西可刪也不失敗),中樞那一列照樣被移除 | LAW-45(a), LAW-47 |

## 依賴方向

- **依賴誰**:`Aapms.Workspace.Types`(十一個型別)、`Aapms.Workspace.Location`
  (`configPath` / `thumbCacheDir`)、`Aapms.Workspace.Hub`(`saveHub` / `hubVaults` /
  `upsertVault` / `removeVault`)、`Aapms.Workspace.Discovery`(`readVaultRef` /
  `readVaultRefAt` / `lookupSelector`)、`Aapms.Store.Marker`(`initVaultAt` / `indexDbPath` /
  `markerDir` / `readMarker` / `VaultMarker` 三個欄位存取子)、`Aapms.Store.Schema`
  (`VaultKind`)、`directory`、`filepath`、`text`。**與 design.md「模組間公開介面」WAVE-4 補表後的
  `Lifecycle → aapms-store` 與 `Lifecycle → Location` 兩列逐項一致**(已對帳)。
- **誰會依賴它**:`service`(S3 的 `workspace setup` / `vault init|add|forget|check` /
  `workspace purge` 指令組),尚未存在。本套件內**沒有任何模組依賴 Lifecycle**。
- **新增的依賴邊**(一條都不能漏):
  - `Aapms.Workspace.Lifecycle → Aapms.Workspace.Types`(新;骨架階段就有)
  - `Aapms.Workspace.Lifecycle → Aapms.Store.Schema`(新;骨架階段就有,只取 `VaultKind`)
  - `Aapms.Workspace.Lifecycle → Aapms.Workspace.Location`(新;impl 填本體時出現。
    **WAVE-4 閘門已把這一列補進 design.md 的模組間介面表**)
  - `Aapms.Workspace.Lifecycle → Aapms.Workspace.Hub`(新;impl 填本體時出現)
  - `Aapms.Workspace.Lifecycle → Aapms.Workspace.Discovery`(新;impl 填本體時出現)
  - `Aapms.Workspace.Lifecycle → Aapms.Store.Marker`(新;impl 填本體時出現。
    **`initVaultAt` 在整個 codebase 的第一個消費者**——knot 反向可達確認它目前沒有任何呼叫者;
    `indexDbPath` 在 `aapms-store` 之外的第一個消費者;`readMarker` 則是繼 `Discovery`(F002)
    之後**第二個**套件外消費者,WAVE-4 裁決 B 帶進來)
  - **套件層級不新增任何依賴邊**:`aapms-workspace → aapms-store` / `→ aapms-core` 在 F001 就
    已存在,`.cabal` 的 `build-depends` 一行不用動。
- **可否與其他進行中任務平行開發**:可以與 F005(`Projects.hs`)、F006(`Tools.hs`)平行——
  三者的寫入白名單各是一個不同的 `.hs`,共讀的 `Types.hs` / `Location.hs` / `Hub.hs` /
  `Discovery.hs` 都只讀不寫。與 F001 / F002 / F003 之間是**單向**依賴,那三個已交付且凍結。

## 不可逆決定

| 決定 | 被否決的替代方案與否決理由 |
|---|---|
| **撞號時把剛寫出的 `.aapms/` 回滾**(LAW-19) | **(a) 留著不管**:實作最省,而且「不刪東西」聽起來比較安全。否決理由是它會讓契約 F 的訊息說謊——`VaultIdCollision` 的訊息寫「對新的那一份重新執行 vault init」,但目錄裡已經有 `.aapms/` 了,重跑只會拿到 `VaultAlreadyInitialized`,使用者被兩則錯誤夾在中間、沒有任何一步走得出去。**(b) 不回滾,改成「撞號時把已寫出的 marker 當成有效結果、只是不進中樞」**:否決理由是那等於默許兩個 vault 帶同一個 id,而 ADR-017 對這件事的一貫立場是「身分不確定不能靜默帶過」 |
| **`vault init` 的前置檢查由本模組做,不靠 `initVaultAt` 的 `VaultAlreadyInitialized`** | **直接呼叫 `initVaultAt`、把它的 `StoreError.VaultAlreadyInitialized` 翻成 `WorkspaceError`**:少一次 stat。否決理由是兩者的判準不等價(`initVaultAt` 看 `config.toml` 是否為**檔案**,契約卡要的是「任何已有 `.aapms/` 的目錄」),`.aapms/` 空目錄的情況會被放行而寫進去;而且那要求本模組 pattern match `StoreError`,把 graph-core 的錯誤語意抄一份到這一層 |
| **`purge` 只刪 `config.toml` 與 `cache/thumbs/`,不刪整個中樞目錄** | **`removePathForcibly (hlPath loc)`**:一行搞定、最徹底。否決理由是中樞目錄在 `AAPMS_HOME` 模式下可能是使用者自己選的既有目錄(甚至是 `~/.config`),裡面可能有別的東西;`purge` 是可回復的清理(重跑 `setup` 即可),不是「刪掉我的家目錄」。代價:中樞目錄清完之後仍留著一個空殼 |
| **刪索引前先 `readMarker` 驗身分;讀不到照刪、讀得到但 id 不符就拒絕**(LAW-45 / LAW-46;**2026-08-29 WAVE-4 閘門裁決**,不是本 spec 的判斷) | **只依 `vePath` 刪**:零成本。否決理由是中樞的 `vePath` 是**快取**(契約 B 寫死),那一列過期時(使用者搬走 vault、原路徑放了另一個 vault)刪掉的是別人的索引——索引 rebuild 得回來,但使用者不會知道發生過什麼。**把防線移到 `shell` 的 `--confirm`**:否決理由是使用者正是因為以為那個路徑還是舊 vault 才按下去的,確認擋不住這個錯誤。這是 WAVE-3「身分不確定就不往下走」、契約 C 性質 1「marker 是真相」的第三次適用 |
| **`purge PurgeAllVaults` 的驗身分是「全部驗完才開始刪」(全有或全無)** | **逐 vault 邊驗邊刪**:實作最直接。否決理由是中樞的 `config.toml` 與 `cache/thumbs/` 排在 vault 索引之前被刪,一旦第三個 vault 才驗出漂移,使用者拿到的是 `Left` 加上一個**已經被清掉一半**的中樞——而 `PurgeReport` 是 `Right` 那一側的欄位,回 `Left` 時完全表達不出「已經刪了什麼」 |
| **`checkVaults` 沒有失敗通道(型別就沒有 `Either`)** | 契約 D 已經寫死簽名,本 spec 不動它。記在這裡是因為它決定了一件事:**中樞裡任何一列壞掉都不會讓 `doctor` 整個掛掉**,而這正是 ADR-017「不可達不中止」在體檢路徑上的體現 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `workspace/src/Aapms/Workspace/Lifecycle.hs` | 模組宣告與匯出清單(七個函式)、七條完整簽名與各自的 Haddock;本體一律 `undefined` |

**編譯狀態**:`Aapms.Workspace.Lifecycle` 在本 feature 開跑**之前**就已列進
`aapms-workspace.cabal`(library 的 `exposed-modules` 與 test-suite 的 `other-modules`,連同
`Aapms.Workspace.LifecycleSpec`),由**編排者**單線維護(DEC-2:`.cabal` 不屬任何 feature 的寫入
白名單)。因此:

```text
cabal build aapms-workspace:lib:aapms-workspace
  → [5 of 8] Compiling Aapms.Workspace.Lifecycle …   exit 0、零警告
  → 第二次執行:Up to date、exit 0
```

(2026-08-29 在本機 GHC 9.14.1 / Windows 實測。`-Wall -Wcompat` 下沒有任何 redundant import
警告——骨架的 import 只有簽名用得到的 `Data.Text (Text)`、`Aapms.Store.Schema (VaultKind)` 與
`Aapms.Workspace.Types` 的十一個型別。)

## TodoList

- [ ] STEP-1: `setupHub`:兩個存在性快照(`configPath` / `thumbCacheDir`)→ 缺什麼建什麼(空中樞經
  `saveHub`,快取目錄經 `createDirectoryIfMissing True`)→ 依快照組 `SetupReport`。既有檔案
  一律不讀不解析 `dep: -`
- [ ] STEP-2: `initVault` 的四條前置檢查與判定順序(名稱 → `.aapms` 佔用 → 模式專屬),每一條都在
  **寫任何東西之前**完成 `dep: -`
- [ ] STEP-3: `initVault` 的成功路徑:`initVaultAt` → 用回傳的 `VaultMarker` 組 `VaultEntry` →
  `upsertVault` → `saveHub`;`initVaultAt` 回 `Left` 時回滾 `markerDir dir'` 並包成
  `VaultInitFailed`(WAVE-4 裁決 A) `dep: T2`
- [ ] STEP-4: `initVault` 的撞號分支:比對 `hubVaults` 的 `veId` → 回滾 `markerDir dir'` →
  `VaultIdCollision`(既有路徑在前、這次的在後) `dep: T3`
- [ ] STEP-5: `AdoptNotice`:掃 `dir'` 下的 `.assetdb` / `.storyflow` 兩個固定名字(不遞迴、只報告)
  `dep: T3`
- [ ] STEP-6: `addVault`:`canonicalizePath` → `readVaultRefAt` → 用 marker 組 `VaultEntry` →
  `upsertVault` → `saveHub` `dep: -`
- [ ] STEP-7: `forgetVault`:`lookupSelector` → `removeVault` → `saveHub` → `DeleteIndex` 時多刪
  `indexDbPath (vePath e)`(不存在就跳過) `dep: -`
- [ ] STEP-8: `checkVaults`:逐列 `readVaultRef`,把 `Left` 收成保序清單 `dep: -`
- [ ] STEP-9: `syncHub`:逐列 `readVaultRef` → 分成 issues 與 fixes → 有 fixes 才 `upsertVault` +
  `saveHub`;issues 與 `checkVaults` 同一份 `dep: T8`
- [ ] STEP-10: `purge`:刪 `config.toml`、數完再刪整棵 `cache/thumbs/`、`PurgeAllVaults` 時逐 vault
  刪 `index.db` 並收集實際刪掉的路徑 `dep: -`
- [ ] STEP-11: 共用的私有 helper:路徑正規化、「存在才刪」、IO 例外 → `WorkspaceError` 的轉換
  (`HubWriteFailed <失敗的路徑> <原因>`),讓七個函式對同一種失敗給出同一個建構子
  `dep: T1, T7, T10`
- [ ] STEP-12: **刪索引前的身分驗證**(WAVE-4 裁決 B):一個共用的三態判定(`readMarker` → 讀不到 /
  id 相符 / id 不符),`forgetVault DeleteIndex` 逐列用一次、`purge PurgeAllVaults` 對全部列
  先跑完再開始刪(全有或全無);`KeepIndex` 與 `PurgeHubOnly` 完全不呼叫它 `dep: T7, T10`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| STEP-1 | LAW-1, LAW-2, LAW-3, LAW-4, LAW-5 / EX-1–EX-5 | `test_setup_hub_is_idempotent`、`test_setup_hub_then_load_hub_succeeds`、`test_setup_hub_flags_reflect_prior_state`、`test_setup_hub_never_parses_existing_file`、`test_setup_hub_creates_only_two_things` |
| STEP-2 | LAW-6, LAW-7, LAW-8, LAW-9, LAW-10, LAW-11 / EX-6–EX-10 | `test_init_vault_rejects_blank_name_first`、`test_init_vault_already_initialized_both_modes`、`test_init_vault_marker_path_taken_by_file`、`test_init_vault_fresh_rejects_non_empty`、`test_init_vault_adopt_requires_existing_dir`、`test_init_vault_precheck_has_no_side_effects` |
| STEP-3 | LAW-12, LAW-13, LAW-14, LAW-15, LAW-17, LAW-20, LAW-44 / EX-11–EX-15, EX-41 | `test_init_vault_entry_mirrors_marker`、`test_init_vault_appends_one_row_only`、`test_init_vault_persists_and_keeps_comments`、`test_init_vault_adopt_keeps_existing_files`、`test_init_vault_creates_empty_index`、`test_init_vault_init_failure_is_vault_init_failed`(含回滾斷言) |
| STEP-4 | LAW-18, LAW-19, LAW-20 / EX-18, EX-19 | `test_init_vault_id_collision_carries_both_paths`、`test_init_vault_id_collision_rolls_back` |
| STEP-5 | LAW-16 / EX-15, EX-16, EX-17 | `test_adopt_notice_lists_legacy_markers`、`test_adopt_notice_order_is_fixed`、`test_adopt_notice_is_not_recursive` |
| STEP-6 | LAW-21, LAW-22, LAW-23, LAW-24 / EX-20–EX-24 | `test_add_vault_identity_from_marker`、`test_add_vault_unreadable_marker_is_hard_failure`、`test_add_vault_is_idempotent`、`test_add_vault_updates_path_on_move`、`test_add_vault_touches_nothing` |
| STEP-7 | LAW-25, LAW-26, LAW-27, LAW-28, LAW-29, LAW-30 / EX-25–EX-29 | `test_forget_vault_selector_rules`、`test_forget_vault_selector_failure_has_no_side_effects`、`test_forget_vault_keep_index`、`test_forget_vault_delete_index_only_removes_index`、`test_forget_vault_missing_index_is_ok`、`test_forget_vault_returns_removed_row` |
| STEP-8 | LAW-31, LAW-32, LAW-33 / EX-30–EX-32 | `test_check_vaults_lists_issues_in_order`、`test_check_vaults_writes_nothing`、`test_check_vaults_does_not_expand_refs` |
| STEP-9 | LAW-34, LAW-35, LAW-36 / EX-33–EX-36 | `test_sync_hub_fixes_name_and_kind_only`、`test_sync_hub_issues_match_check_vaults`、`test_sync_hub_never_writes_marker`、`test_sync_hub_no_drift_no_write` |
| STEP-10 | LAW-37, LAW-38, LAW-39, LAW-40, LAW-41 / EX-37–EX-40 | `test_purge_hub_only_scope`、`test_purge_hub_only_leaves_vaults_alone`、`test_purge_all_vaults_removes_indexes_only`、`test_purge_never_touches_library_or_md`、`test_purge_is_idempotent` |
| STEP-11 | LAW-43 / (全部) | `test_lifecycle_filesystem_footprint`(對一組涵蓋七個函式的操作序列驗 (i)–(iv) 之外的路徑一個都沒動) |
| STEP-12 | LAW-45, LAW-46, LAW-47 / EX-42–EX-45 | `test_forget_vault_delete_index_rejects_id_drift`、`test_forget_vault_keep_index_ignores_drift`、`test_purge_all_vaults_is_all_or_nothing`、`test_delete_index_still_proceeds_when_marker_unreadable` |
| (全部) | LAW-42 (a)–(f) | `test_lifecycle_no_sibling_imports`(a)、`test_lifecycle_marker_import_is_exact`(b,條件式逐字比對 `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, markerDir)`)、`test_lifecycle_schema_import_is_type_only`(c)、`test_lifecycle_never_imports_atomic`(d)、`test_lifecycle_never_imports_index_modules`(e)、`test_lifecycle_no_process_import`(f)。**六條都只掃 import 行,比對前先去除行尾 `\r`** |

## 待確認假設

> **全部八條已於 2026-08-29 WAVE-4 閘門處理完畢,沒有任何一條未結**,每條末尾附「裁決」欄。
> ASM-6 選 b(新增 `VaultInitFailed`)、ASM-5 的暫採被**推翻**(改為刪索引前先驗身分)、
> ASM-8 選 b(新增 `DeleteTargetIdDrift`)、其餘五條由編排者**降級**。
> **選項與代價的原文一律保留備查**——包含被否決的那些,以及 ASM-8 原本的暫採記錄。

- ASM-1: `initVault` 的**前置檢查判定順序**(名稱 → `.aapms` 佔用 → 模式專屬)與 **`.aapms` 存在性
  的判準**(路徑存在即算,不要求是目錄)。契約卡沒有答案,是因為它的三條驗收標準各自用「一律」
  描述,但沒有規定兩條同時成立時回哪一個:空名稱 + 已有 `.aapms/` 該回 `InvalidName` 還是
  `VaultAlreadyInitialized`?而「`.aapms` 是普通檔案」這種情況三條都沒涵蓋。
  - 契約錨點:design.md 契約 D 的 `initVault` 與 `InitMode` 欄;契約 F 的
    `InvalidName` / `VaultAlreadyInitialized` / `VaultDirNotEmpty` / `VaultDirMissing`;
    graph-core 契約 E 的 `markerDir`
  - 層級自答:出現在邊界上?**會**(它決定 `vault init` 對同一個輸入回哪一個錯誤碼,而
    `errorCode` 的對照表由 `service` 擁有、是三個殼共用的對外契約);改錯驚動其他模組?**要**
    (`service` 的指令組與 CLI 說明要照著寫下一步該做什麼)
  - 選項:
    a) **名稱最先、`.aapms` 次之、模式檢查最後;`.aapms` 路徑存在即算被佔用(本 spec 採用)**
       ——當下成本:多一條 law(LAW-10)與兩個 example;三個月後代價:使用者同時打錯名稱又選錯
       目錄時只看得到第一則錯誤,得修兩次才過——但每一則都說得出下一步,而「先擋不碰檔案系統
       的那一條」讓「失敗即零副作用」變成一條好證明的性質
    b) **先做檔案系統檢查、名稱檢查最後**——當下成本:零;三個月後代價:`InvalidName` 這條
       「純參數錯誤」被排在三次 stat 之後,而 `vault init` 最常見的誤用(貼了一段帶引號的空
       名稱)要等到工具摸完磁碟才回應;更麻煩的是 LAW-11「前置檢查失敗零副作用」要多驗一種順序
    c) **`.aapms` 必須是目錄才算被佔用(與 `detectVault` 同一個判準)**——當下成本:零,且
       整個子系統只有一種 `.aapms` 判準;三個月後代價:`.aapms` 是普通檔案時前置檢查放行,
       `initVaultAt` 的 `createDirectoryIfMissing` 會撞上同名檔案拋出**未捕捉的 IO 例外**——
       那是這個子系統唯一一條會讓工具直接崩掉的路徑
  - 傾向:a。理由是它同時買到兩件事:「不碰檔案系統就能判定的錯誤先回」讓 LAW-11 成為一條乾淨的
    性質,而「路徑存在即算佔用」堵掉唯一一條會崩潰的輸入。依賴的前提是「兩個判準不同不會讓
    使用者困惑」——成立,因為 `detectVault` 問的是「這裡是不是可用的 vault」、`initVault` 問的是
    「這個位置能不能建」,後者本來就該更保守。可逆性:**可逆**——調整順序或放寬判準都只動本模組
    的一個 `case`,不影響任何簽名與型別;但它會改變 `service` 已經寫好的錯誤訊息對照,所以愈晚
    改愈吵
  - 暫採:a → 影響:若裁決成 b,LAW-10 的順序條文與 EX-6 / EX-7 的預期要對調;若裁決成 c,LAW-7 的判準
    改成「是既存目錄」,EX-8 要改寫成「`.aapms` 是檔案時的行為」——而那個行為必須另外定義
    (否則就是一條 spec-gap)
  - **裁決(2026-08-29 WAVE-4 閘門)**:**編排者降級,維持 a**。理由:選項 c 會留下**唯一一條會拋
    未捕捉 IO 例外**的路徑,不算真實的第二方案;沒有真實第二方案的假設不上閘門。
    spec 與骨架**一字未改**。

- ASM-2: `initVault` 的名稱**寫進 marker 與中樞前先 `T.strip`**(`" Lore "` → 存 `"Lore"`)。
  契約 D 第五參數只規定「去除前後空白後長度 ≥ 1;否則 `InvalidName`」與「寫進 marker 的 `name`」
  ——那是**合法性**規則,沒說存進去的是原始值還是去空白後的值。
  - 契約錨點:design.md 契約 D 的 `initVault` 第五參數那一列;契約 B 的 `veName` 值域
    (「非空;允許重複」);契約 C 的 `lookupSelector`(WAVE-2 閘門裁決的「逐字精確比對」);
    graph-core 契約 E 的 `VaultMarker.vmName`
  - 層級自答:出現在邊界上?**會**(`vmName` 是寫進使用者看得到的 `.aapms/config.toml` 的值,
    `veName` 是中樞裡那一列的值,兩者都是對外出入口);改錯驚動其他模組?**要**
    (`lookupSelector` 逐字精確比對,存什麼就只能用什麼查;`syncHub` 也拿這兩個值逐字比對)
  - 選項:
    a) **存 `T.strip name`(本 spec 採用)**——當下成本:一行,加上 LAW-12 要寫明「marker 的
       `vmName` 是 strip 後的值」;三個月後代價:使用者若真的想要一個前後帶空白的 vault 名稱
       (幾乎不可能),做不到
    b) **存原始字串**——當下成本:零;三個月後代價:`" Lore "` 這一列只有 `--vault " Lore "`
       才查得到(`lookupSelector` 不去空白,WAVE-2 已裁決),而 shell 幾乎一定會把使用者打的引號
       與空白原樣傳進來;使用者看到 `vault list` 印出 `Lore` 卻怎麼樣都選不中,而錯誤訊息
       (`VaultSelectorNotFound`)完全指不出原因
    c) **strip 只用在合法性檢查,marker 存原始值、中樞存 strip 後的值**——當下成本:零;
       三個月後代價:`syncHub` 會**每次**都認為這一列漂移了(marker 的 `vmName` 與中樞的
       `veName` 逐字不等),於是每跑一次 `doctor --fix` 就把中樞改回帶空白的值,再跑一次又改
       回去——一條永遠收斂不了的回寫迴圈
  - 傾向:a。理由是 c 客觀上是壞的(不收斂),而 a 與 b 的差別只在「要不要保留一個沒有人想要的
    前後空白」;a 讓「marker 與中樞逐字相等」成為 `syncHub` 的不動點,那是 LAW-34 / LAW-36 成立的前提。
    依賴的前提是「`--vault` 的字串由 `shell` 原樣傳入、不做正規化」(ADR-015 第三條),所以
    使用者輸入端不會替我們去空白——這一點由 design.md 對外契約段佐證。可逆性:**有條件可逆**
    ——改成 b 只動本模組一行,但**已經建好的 vault 不會回頭改**,舊 marker 裡的值會長期共存
  - 暫採:a → 影響:若裁決成 b,LAW-12 的 `vmName m == T.strip name` 改成 `== name`,EX-12 的
    `"  Lore  "` 預期從 `"Lore"` 改成 `"  Lore  "`;LAW-34 / LAW-36 不受影響(它們只要求兩邊一致)
  - **裁決(2026-08-29 WAVE-4 閘門)**:**編排者降級,維持 a**。決定性理由**不在本 spec 的分析裡**:
    **WAVE-2 已裁 `lookupSelector` 逐字精確比對**,存未 trim 的名稱會讓那一列**永遠選不到**——所以
    trim 是被前一條已生效的裁決逼出來的,不是一個開放選項。spec 與骨架**一字未改**。
    (跨 feature 對帳:F005 的 `registerProject` 第四參數共用同一句值域,兩份 spec 的寫法一致
    ——都先驗名稱、再驗路徑,都存 trim 後的字串。)

- ASM-3: **撞號時把剛寫出的 `.aapms/` 回滾**(刪掉 `markerDir dir'` 整個目錄),而不是留在原地。
  契約 D 只寫「產生後若與中樞既有的 `veId` 相同,回 `VaultIdCollision` 並要求重跑一次」,沒說
  已經落地的 marker 與空索引怎麼辦——而資料流管線把撞號檢查明確排在 `initVaultAt` **之後**。
  - 契約錨點:design.md 契約 D 的「`initVault` 的 vault id 由 `initVaultAt` 產生……回
    `VaultIdCollision` 並要求重跑一次」那一段;資料流管線「生命週期」的第三步;契約 F 的
    `VaultIdCollision` 與 `VaultAlreadyInitialized`;ADR-017 決策五「任何情況不碰 `library/`」
  - 層級自答:出現在邊界上?**會**(它決定 `VaultIdCollision` 的訊息「對新的那一份重新執行
    vault init」是不是一句可執行的建議);改錯驚動其他模組?**要**(`service` 要據此決定
    `vault init` 失敗後要不要叫使用者手動清目錄,CLI 說明也要跟著寫)
  - 選項:
    a) **回滾 `markerDir dir'`(本 spec 採用)**——當下成本:多一次 `removePathForcibly`,以及
       一條要驗「回滾後重跑得起來」的 law(LAW-19);三個月後代價:本模組出現了唯一一次「刪除
       自己剛剛建立的東西」,日後若 `initVaultAt` 改成順便建業務子目錄(`library/` 等),回滾的
       半徑要跟著重新定義——**這個前提要寫下來**:目前 `initVaultAt` 的 Haddock 明寫「不建業務
       子目錄、不寫 `.gitignore`」,所以 `.aapms/` 就是它建立的全部
    b) **不回滾,留著**——當下成本:零;三個月後代價:錯誤訊息叫使用者「重新執行 vault init」,
       但重跑必定撞上 `VaultAlreadyInitialized`(那條檢查排在最前面),使用者被兩則互相矛盾的
       錯誤夾住;唯一的出路是自己 `rm -rf .aapms`,而工具從來沒告訴他這件事
    c) **不回滾,改成把已寫出的 marker 當有效結果、只是不進中樞(回 `Right` 帶警告)**——
       當下成本:要改契約 D 的回傳型別(`AdoptNotice` 之外再帶一個警告);三個月後代價:等於
       默許磁碟上有兩個 vault 帶同一個 id,而那正是 ADR-017 用 `VaultIdCollision` 明確拒絕的
       狀態;跨 vault 的 `<vault-id>:<id>` 定址從此可能指向兩個地方
  - 傾向:a。理由是 b 讓契約 F 已經寫定的訊息變成一句做不到的建議(訊息是 F001 交付的,不能改),
    而 c 直接牴觸 ADR-017 決策二的身分規則。依賴的前提:`initVaultAt` 建立的東西**恰好**是
    `.aapms/` 這一棵(已由它的 Haddock 與原始碼查證,`Marker.hs:141-155`)。可逆性:**可逆**
    ——回滾與否只動本模組的一個分支,不影響任何簽名;但一旦有使用者遇過撞號,兩種行為留下的
    磁碟狀態不同
  - 暫採:a → 影響:若裁決成 b,LAW-19 整條刪掉並改寫成「撞號後 `.aapms/` 仍在」,EX-19 的預期反轉,
    而且要在 spec 明寫「使用者必須手動刪除 `.aapms/` 才能重跑」——那應該同時提一個
    `renderWorkspaceError` 的訊息修訂建議(那要動 F001 已交付的 `Types.hs`)
  - **裁決(2026-08-29 WAVE-4 閘門)**:**編排者降級,維持 a**。理由:不回滾會讓 F001 **已交付**的
    `VaultIdCollision` 訊息(「對新的那一份重新執行 vault init」)變成一句做不到的建議,而那則
    訊息改不得——同 ASM-1,沒有真實第二方案。spec 與骨架**一字未改**;WAVE-4 裁決 A 另把同一條回滾規則
    延伸到 `initVaultAt` **建失敗**的情況(LAW-44)。

- ASM-4: **`addVault` 對「marker 的 id 已在中樞」是 `upsertVault`(就地覆寫、只改 `vePath`),
  不是回 `VaultIdCollision`**。契約卡的八條驗收標準**一條都沒提到 `addVault`**,契約 D 也只規定
  第三參數「該目錄必須已有 `.aapms/`」。
  - 契約錨點:design.md 契約 D 的 `addVault` 與它的第三參數那一列;契約 B 的 `veId`
    (「**鍵**。搬動 vault 只改 `vePath`,身分不變」);模組間公開介面的
    `Lifecycle → Hub`(`upsertVault`);契約 F 的 `VaultIdCollision`
  - 層級自答:出現在邊界上?**會**(它決定 `vault add` 對同一個 vault 跑第二次是成功還是報錯);
    改錯驚動其他模組?**要**(`service` 的 `vault add` 指令與「搬家之後怎麼修中樞」這條使用者
    流程都建在這個行為上)
  - 選項:
    a) **`upsertVault` 語意:同 id 就地覆寫、只換 `vePath`(本 spec 採用)**——當下成本:零
       (`upsertVault` 本來就是這個語意);三個月後代價:「同一個 vault 被 `add` 兩次」與
       「vault 搬家後重新 `add`」都靜默成功,使用者不會被告知「這一列本來就在」——`SetupReport`
       那種「是不是這次建的」的旗標在 `addVault` 沒有對應物,契約 D 也沒給它一個回傳欄位
    b) **同 id 已存在就回 `VaultIdCollision`**——當下成本:零;三個月後代價:ADR-017 的
       「搬動 vault 只改 `path`」失去唯一的執行路徑——使用者搬完目錄之後必須先 `vault forget`
       再 `vault add`,而 `forget` 的預設會不會順手刪索引又是另一個要記的規則;而且
       `VaultIdCollision` 的訊息寫的是「這通常是整個 vault 目錄被複製過」,套在「我把庫搬到
       D 槽了」上是誤導
    c) **同 id 且路徑不同 → 更新;同 id 且路徑相同 → 回一個「已註冊」的錯誤**——當下成本:
       多一個分支;三個月後代價:契約 F **沒有**「已註冊」這個建構子,要新增就得動已凍結的
       `Types.hs`;硬借 `VaultIdCollision` 又會印出兩個一模一樣的路徑
  - 傾向:a。理由是契約 B 已經把「搬動 vault 只改 `vePath`」寫成 `veId` 這個鍵的語意,而
    `upsertVault` 這個純函式(F001 交付、模組間介面表指名給 Lifecycle 用)就是它的執行體;
    b 與 c 都要在契約之外再造一條規則。依賴的前提:`vault add` 是低頻的維運指令,靜默成功的
    代價可接受——若日後 `service` 真的要區分「新增」與「更新」,可以自己比對呼叫前後的
    `hubVaults`(`Hub` 的 getter 是公開的),**不需要改本函式的簽名**。可逆性:**可逆**
    ——改成 b 只是在 `upsertVault` 之前多一次比對,不動任何型別
  - 暫採:a → 影響:若裁決成 b,LAW-23 反轉成「第二次回 `Left (VaultIdCollision …)`」,EX-21 / EX-22
    的預期跟著改,並要在 spec 補一條「搬家的正式流程是 forget + add」
  - **裁決(2026-08-29 WAVE-4 閘門)**:**編排者降級,維持 a**。理由:這是契約 B 「`veId` 是**鍵**。
    搬動 vault 只改 `vePath`,身分不變」的**直接推論**,不是開放選項——契約已經替它決定了。
    spec 與骨架**一字未改**。

- ASM-5: **撤除類的刪除只依中樞那一列記的 `vePath`,不重讀 marker 驗身分**;`purge` 的
  `PurgeHubOnly` 刪的是**中樞的 `config.toml` 與整棵 `cache/thumbs/`**(不是整個中樞目錄),
  `prThumbsRemoved` 是刪除前 `cache/thumbs/` 底下的**檔案總數**。契約 D 只給了三個報告欄位與
  「後者連各 vault 的 `.aapms/index.db` 一起刪」,沒說刪之前要不要確認那個路徑現在還是同一個
  vault,也沒說中樞目錄裡的其他東西怎麼辦。
  - 契約錨點:design.md 契約 D 的 `forgetVault` / `DeleteIndex` / `PurgeScope` /
    `PurgeReport`(`prHubRemoved` / `prThumbsRemoved` / `prVaultIndexesRemoved` 三欄);
    ADR-017 決策五(「`workspace purge` 清中樞與快取」)與決策七(縮圖快取的佈局);
    契約 B 的 `thumbCacheDir` / `thumbCachePath`
  - 層級自答:出現在邊界上?**會**(這是本子系統唯一會刪除使用者磁碟上東西的路徑,
    `PurgeReport` 的三個欄位是 `shell` 要印給人看的);改錯驚動其他模組?**要**
    (`service` 的破壞性操作要先印路徑再 `--confirm`,印什麼取決於這裡刪什麼)
  - 選項:
    a) **只依 `vePath` 刪、只刪 `config.toml` + `cache/thumbs/`、`prThumbsRemoved` 數檔案總數
       (本 spec 採用)**——當下成本:零額外 IO;三個月後代價:若中樞那一列的路徑已經指向
       另一個 vault(id 漂移而沒跑過 `syncHub`),`--delete-index` 會刪掉**那個 vault** 的索引
       ——不過索引是衍生物,`index rebuild` 就回來了,而 `library/` 與 `.md` 在任何情況都不碰
    b) **刪之前先 `readVaultRef` 驗 id,漂移就跳過不刪(只移除中樞那一列)**——當下成本:每個
       要刪的 vault 多一次 marker 讀取,而且 `forgetVault` / `purge` 從此在「vault 不可達」時
       行為不同(刪不到);三個月後代價:使用者跑 `vault forget --delete-index` 想騰出空間,
       工具卻靜默沒刪——而 `PurgeReport` / `forgetVault` 的回傳型別**沒有欄位**表達「跳過了
       哪些」,只能寫進日誌,那就變成一個查不到原因的行為
    c) **`PurgeHubOnly` 直接 `removePathForcibly (hlPath loc)`**——當下成本:最省;三個月後
       代價:`AAPMS_HOME` 可以指到使用者自己選的既有目錄,整個刪掉會連帶清掉不屬於 aapms 的
       檔案;而 `purge` 的語意是「回到剛裝好的狀態」,不是「刪掉這個資料夾」
  - 傾向:a。理由是索引是可重建的衍生物(ADR-017 決策六「舊索引檔丟棄,純索引,重建即可」是
    同一個立場),而 b 買到的安全在型別上表達不出來、只會變成靜默行為;c 的破壞半徑超出契約。
    依賴的前提:`library/` 與 `.md` 在**所有**分支都不在刪除清單上(由 LAW-40 與 LAW-43 釘死),
    所以最壞情況的代價上限是「多重建一次索引」。可逆性:**可逆**——加上身分驗證只是在刪除前
    多一個條件,不動任何簽名;但已經刪掉的檔案回不來
  - 暫採:a → 影響:若裁決成 b,LAW-28 / LAW-39 要補「id 漂移時不刪」的分支,EX-28 / EX-38 要各多一個
    漂移情境,而且要決定「跳過」怎麼讓使用者看得到(可能需要動 `PurgeReport`,那會動到已凍結
    的 `Types.hs`);若裁決成 c,LAW-37 的「其他檔案逐位元組不變」整條刪掉
  - **裁決(2026-08-29 WAVE-4 閘門)——暫採 a 的前半被推翻,改為 b 的變體(裁決 B)**:
    - **推翻的部分**:「只依 `vePath` 刪、不重讀 marker」改成 **`forgetVault DeleteIndex` 與
      `purge PurgeAllVaults` 在刪 `index.db` 之前先 `readMarker` 驗身分**——**讀不到照刪**
      (那正是 `forget` 最常見的理由)、**讀得到但 `vmId` 與中樞那一列不符就拒絕刪除並回錯**。
      理由是中樞的 `vePath` 是快取、marker 才是真相;那一列過期時照 `vePath` 刪掉的是**別人的
      索引**。這與 WAVE-3「身分不確定就不往下走」、契約 C 性質 1 是同一條原則的第三次適用。
      本 spec 原本評估「最壞代價是多重建一次索引」——閘門認為「使用者不會知道發生過什麼」
      才是真正的代價,而**讀不到就照刪**這個分支剛好保住了本 spec 擔心的
      「想騰空間卻靜默沒刪」(那才是 b 原案的缺點,裁決 B 沒有它)。
    - **維持的部分**:`PurgeHubOnly` 只刪 `config.toml` + 整棵 `cache/thumbs/`(**不是**整個
      中樞目錄)、`prThumbsRemoved` 數檔案總數——選項 c 的破壞半徑超出契約,維持原判。
    - **spec 的落地**:新增 LAW-45 / LAW-46 / LAW-47 與 EX-42–EX-45;LAW-28 / LAW-39 各加一句「前提是身分驗證
      通過」;資料流的 `forgetVault` / `purge` 兩段改寫;`readMarker` 進 LAW-42(b) 的 import
      白名單;「正規化」段的例外一處改寫成「驗誰就刪誰靠的是用同一個字串」。
      **拒絕刪除的失敗通道由 ASM-8 定案:`DeleteTargetIdDrift`。**

- ASM-6: **本模組自己的 IO 失敗一律借用既有建構子**:`initVaultAt` 回的 `StoreError` 包成
  `MarkerUnreadable dir' err`,本模組自己的建目錄 / 刪檔失敗包成 `HubWriteFailed <那個路徑> <原因>`。
  契約 F 的十七個建構子裡**沒有**「marker 寫入失敗」或「清理失敗」的專屬項,而 `Types.hs` 已凍結
  (build-log DEC-2),本 feature 不得新增建構子。
  - 契約錨點:design.md 契約 F 的 `MarkerUnreadable FilePath StoreError` 與
    `HubWriteFailed FilePath Text`;`renderWorkspaceError` 對這兩者的訊息原文
    (`Types.hs:348-349` 與 `Types.hs:398-399`);build-log DEC-2「Types 一次寫齊,WAVE-2 之後沒人再碰它」
  - 層級自答:出現在邊界上?**會**(它決定 `vault init` 在磁碟寫入失敗時 `service` 收到哪個
    建構子、使用者看到哪一則繁中訊息);改錯驚動其他模組?**要**(要修得漂亮就得動
    `Types.hs` 的 `WorkspaceError` 與 `renderWorkspaceError`,那是 F001 已交付、本波三個
    feature 共用且凍結的檔案)
  - 選項:
    a) **借用既有建構子(本 spec 採用)**——當下成本:零,不動任何已交付檔案;三個月後代價:
       訊息會**不精確**——`MarkerUnreadable` 的繁中原文是「讀取 vault marker 失敗……請確認後
       再試」,套在「磁碟滿了寫不進去」上是誤導;`HubWriteFailed` 的原文是「中樞設定檔寫入
       失敗」,套在「刪不掉某個 vault 的 index.db」上更遠。使用者拿到的下一步建議會指錯方向
    b) **請編排者在 `Types.hs` 補一個建構子(例如 `VaultInitFailed FilePath StoreError`)**
       ——當下成本:要打斷「WAVE-2 之後沒人再碰 `Types.hs`」的併發前提,本波三個 feature 之一
       (本 feature)得等編排者單線改完才繼續;三個月後代價:最小——每一則訊息都說得出真正的
       下一步,而契約 F「每一則說出下一步該做什麼」這條性質才真的成立
    c) **把落地失敗當成不可回復的例外直接讓它拋出去**——當下成本:零;三個月後代價:
       `aapms-service` 收到的是一個未包裝的 `IOException`,主架構全域錯誤策略第 1 條
       (「原樣包成一個建構子,不重寫訊息」)在這條路徑上失效,三個殼各自看到不同形狀的崩潰
  - 傾向:**b,但本 spec 暫採 a**。b 是客觀上正確的終局(契約 F 的「每一則說出下一步」是它自己
    寫下的性質),而 a 的代價完全落在訊息品質、不影響任何型別或行為;把 a 當暫採是為了不讓
    本波三個平行 feature 因為一個共用檔案停擺。依賴的前提:寫入失敗是**罕見**路徑(磁碟滿、
    權限不足),訊息不精確的期望損失小於整波停擺——若編排者判斷 `Types.hs` 現在改得起
    (F005 / F006 尚未動到它),應該直接選 b。可逆性:**可逆**——從 a 換到 b 只是把兩處
    `MarkerUnreadable` / `HubWriteFailed` 換成新建構子,測試跟著換兩個預期值
  - 暫採:a → 影響:若裁決成 b,LAW-22 之外要新增一條「`initVaultAt` 失敗 → `VaultInitFailed`」
    的 law,「對應的 Level 2 契約 › 契約 F」那張沿用表要改,`Types.hs` 與 `renderWorkspaceError`
    由**編排者**單線補上(不是本 feature),而 EX-23 之外要新增一個寫入失敗的 example
  - **裁決(2026-08-29 WAVE-4 閘門)——選 b**:契約 F 新增
    `VaultInitFailed FilePath StoreError`(帶 vault 根目錄與 graph-core 的 `StoreError`
    **原件**),`design.md` 已更新,宣告與繁中訊息由**編排者**單線補進 `Types.hs`。理由照本 spec
    寫的:借用 `MarkerUnreadable` 會讓訊息說「marker **讀**不出來」,而實際是**建**失敗,
    等於叫使用者去看一個還沒被建出來的檔。
    - **裁決只換掉 `initVaultAt` 那一半**:本模組自己的建目錄 / 刪檔失敗**仍走**
      `HubWriteFailed <失敗的路徑> <原因>`(暫採 a 的後半維持)。
    - **spec 的落地**:新增 LAW-44 與 EX-41;資料流的 `initVault` 段改寫;契約 F 那節從「五個建構子」
      改成「六個」,沿用表把 `MarkerUnreadable` 的「兼任建失敗」註記拿掉。

- ASM-7: **`setupHub` 寫出的初始 `config.toml` 是一份「空中樞」(經 `saveHub` 落地,內容為空字串),
  而不是一份帶註解的樣板;既有的 `config.toml` 一律不讀、不解析、不覆寫。**契約卡只規定冪等與
  兩個旗標,沒說第一次跑要寫什麼進去,也沒說遇到壞掉的既有檔案怎麼辦。
  - 契約錨點:design.md 契約 D 的 `setupHub` / `SetupReport`;契約 A 的 `loadHub`
    (「檔案不存在時回 `HubNotFound`,**不回空中樞**」)與 `saveHub`;ADR-017 決策二
    (中樞是**可手寫**的檔案);design.md 架構圖的「對外出入口:`%APPDATA%\aapms\config.toml`
    (可手寫)」
  - 層級自答:出現在邊界上?**會**(那個檔案是本系統的對外出入口之一,使用者會打開它手寫);
    改錯驚動其他模組?**要**(中樞的檔案格式是 Hub 模組擁有的事實;若 `setupHub` 自己拼一份
    樣板文字,那份格式知識就被抄成兩份)
  - 選項:
    a) **空中樞 + 既有檔案完全不碰(本 spec 採用)**——當下成本:零;三個月後代價:第一次
       `workspace setup` 之後使用者打開 `config.toml` 看到的是**空檔**,不知道可以寫什麼
       (`[llm]` / `[tools]` 兩段完全沒有線索),只能翻文件
    b) **寫一份帶註解的樣板(`# [[vaults]] 由 vault add 維護` / `# [llm]` / `# [tools]` …)**
       ——當下成本:要在 Lifecycle 裡拼一段 TOML 文字,而「中樞的檔案格式」是 Hub 擁有的唯一
       真相,等於把它抄第二份(除非同時請編排者在 Hub 加一個 `emptyHubTemplate`,那又要動
       已交付的 `Hub.hs`);三個月後代價:樣板的每一次演進都要記得同步兩個地方,而
       `saveHub` 的底稿機制會把使用者刪掉的註解**保留原狀**(它只認段落),樣板一旦寫錯就
       跟著每個使用者的中樞永久留存
    c) **既有檔案先 `loadHub` 驗一次,壞掉就回 `HubMalformed`**——當下成本:多一次解析;
       三個月後代價:`workspace setup` 從「把環境裝好」變成「順便體檢」,而體檢已經有
       `doctor`(`checkVaults`)那條路;更糟的是使用者手寫壞了中樞之後,連 `setup` 都跑不動,
       而 `setup` 正是他唯一還記得的那個指令
  - 傾向:a。理由是知識歸屬:中樞的檔案格式只能有一個地方知道(Hub),而 `saveHub` 已經是
    「把 `Hub` 值變成檔案」的唯一入口——`setupHub` 只要交給它一個空 `Hub` 就好。b 的價值
    (可發現性)可以由 `workspace setup` 的**終端輸出**提供(那是 `shell` 的事),不必寫進檔案。
    依賴的前提:`saveHub` 對「底稿為空字串、四段皆空」的 `Hub` 會寫出一份 `loadHub` 讀得回來的
    檔案——已由 `Hub.hs:249-278` 的底稿式序列化查證(空底稿 → 沒有任何段落 → 空檔;`loadHub`
    對空 TOML 回四段皆空的 `Hub`)。可逆性:**可逆**——改成 b 只是換 `setupHub` 寫出去的內容,
    既有使用者的檔案不受影響(`saveHub` 不會回頭補樣板)
  - 暫採:a → 影響:若裁決成 b,LAW-2 的「四段皆空」不變(樣板全是註解),但要新增一條「樣板的
    逐字內容」的 law 與對應 example,而樣板文字應該由**編排者**加進 `Hub.hs`(格式的擁有者),
    本 feature 只呼叫它;若裁決成 c,LAW-4 整條反轉,`setupHub` 多出 `HubUnreadable` /
    `HubMalformed` 兩條失敗通道
  - **裁決(2026-08-29 WAVE-4 閘門)**:**編排者降級,維持 a**。理由:沿用 WAVE-1 已裁的知識歸屬
    ——**中樞的檔案格式由 Hub 擁有**,`setupHub` 只能交給 `saveHub` 一個空 `Hub`;選項 b 會把
    那份格式知識抄第二份。spec 與骨架**一字未改**。

- ASM-8: **裁決 B 的「拒絕刪除」要用哪一個失敗通道。** 本 spec 暫採
  `WriteTargetIdDrift (veId e) (vePath e) (vmId m)`(欄位形狀完全吻合),但**判定它會說謊**,
  建議新增第四個 WAVE-4 建構子。WAVE-4 裁決 B 只定義了行為(「拒絕刪除並回錯」),沒有指定建構子;
  這是本次新增、**尚未裁決**的唯一一條假設。
  - 契約錨點:design.md 契約 D「刪索引前先驗身分」那一段(WAVE-4 新增);契約 F 的
    `WriteTargetIdDrift VaultId FilePath VaultId` 與它的訊息原文(`Types.hs:389-397`);
    契約 C 的 `ScopeIssue.VaultIdDrift`(同一件事在讀取路徑上的降級身分);
    本 spec 的 LAW-45(b) / LAW-46
  - 層級自答:出現在邊界上?**會**(`forgetVault` / `purge` 的失敗通道,而 `errorCode` 的對照表
    由 `service` 擁有、是三個殼共用的對外契約);改錯驚動其他模組?**要**(要換就得動
    `Types.hs` 的 `WorkspaceError` 與 `renderWorkspaceError`,那是共用且原訂凍結的檔案)
  - 選項:
    a) **沿用 `WriteTargetIdDrift`**——當下成本:零,欄位、順序、語意骨架都吻合(註冊表的 id、
       路徑、marker 實際的 id);三個月後代價:它的**訊息會說兩件假的事**。①開頭逐字是
       「寫入目標 <path> ……」而 `forgetVault --delete-index` 與 `workspace purge` 是**撤除**,
       這條路徑上根本沒有寫入目標;②結尾的下一步是「或對這個目錄重新執行 vault add」——
       那是**重新納管**,與使用者當下正在做的「移除」正好相反,照做會把他剛想拿掉的東西加回來。
       更深一層:design.md 對 `WriteTargetIdDrift` 的定義是「`ScopeIssue.VaultIdDrift` 在**寫入
       目標**上的硬失敗身分」,拿它兼任撤除路徑會讓這個建構子不再只指一件事,而 WAVE-3 當初新增它
       正是為了避免這種一詞多義
    b) **新增第四個 WAVE-4 建構子 `DeleteTargetIdDrift VaultId FilePath VaultId`(本 spec 建議)**
       ——當下成本:`Types.hs` 加一個建構子與一則訊息(編排者已表示解凍未派出、現在加是免費的),
       本 spec 逐處把建構子名替換掉(欄位與順序完全相同,是機械替換);三個月後代價:最小
       ——`WriteTargetIdDrift` / `DeleteTargetIdDrift` 成為一組對稱的家族(寫入目標漂移 /
       刪除目標漂移),與 WAVE-3 已建立的命名先例一致,而每一則訊息都說得出真正的下一步
    c) **借用 `MarkerUnreadable dir err`**——當下成本:零;三個月後代價:這一層要**捏造**一個
       graph-core 的 `StoreError`(marker 明明讀得很好,只是 id 不同),違反契約 F「這一層不
       翻譯」;而且訊息會叫使用者去修一個沒壞的 marker——與 WAVE-3 否決同一個候選的理由逐字相同
  - 傾向:**b**。理由是 a 的兩處說謊都落在「訊息要說出下一步」這條契約 F 自己寫下的性質上,
    而這條路徑正是**破壞性操作被擋下來**的時刻——使用者最需要一句準確的指示。依賴的前提:
    `Types.hs` 現在還加得起來(編排者已確認解凍未派出,且 F005 / F006 的建構子也是本波才加的
    ——`ProjectSelectorAmbiguous` / `ProjectAlreadyRegistered` / `VaultInitFailed` 三個已經
    進了 design.md,再加第四個不改變任何併發前提)。可逆性:**可逆**——兩者欄位與順序完全相同,
    互換只動建構子名與兩個測試預期值
  - 建議的訊息要點(繁中,由**編排者**寫進 `renderWorkspaceError`,本 feature 不碰 `Types.hs`):
    「刪除目標 `<path>` 在中樞裡登記的 id 是 `<registered>`,但這個目錄的 vault marker 實際上是
    `<actual>`——這個路徑現在放的是**另一個** vault,為避免刪掉別人的索引已經中止。請先執行
    `vault check` 確認中樞是否過期:vault 搬走了就用**不加 `--delete-index`** 的 `vault forget`
    移除那一列,或用 `vault add` 重新登記新位置。」三個要件都在:說出擋下來的原因、指出
    **不會**誤刪的替代做法、給一條把中樞修正確的路。
  - 暫採:a(`WriteTargetIdDrift`,三個值依序是 `veId e` / `vePath e` / `vmId m`)→ 影響:
    若裁決成 b,LAW-45(b) 與 LAW-46 的建構子名、EX-42 / EX-44 的預期值各換一個名字(欄位與順序不變),
    「契約 F」那節的沿用表把 `WriteTargetIdDrift` 那一列改成本 feature 負責的**第七個**建構子;
    `Types.hs` 與 `renderWorkspaceError` 由編排者單線補上。**骨架不受影響**(七條簽名都不變)
  - **裁決(2026-08-29 WAVE-4 閘門)——選 b**:契約 F 新增
    `DeleteTargetIdDrift VaultId FilePath VaultId`,`design.md` 已補上,形狀與本 spec 的建議
    **完全一致**(中樞那一列的 `veId`、該 vault 的 `vePath`、marker 裡實際的 `vmId`),訊息的
    三要件也照本 spec 寫的收進 design.md。閘門採納了本 spec 的兩條理由,並補上第三條:
    **讓一個建構子兼任兩種語意,等於把 WAVE-3 新增 `WriteTargetIdDrift` 所要避免的一詞多義又造
    回來**。`Types.hs` 的建構子與訊息由 **F001 的 impl** 平行補上(本 feature 不碰任何 `.hs`)。
    - **spec 的落地(機械替換,欄位與順序未動)**:資料流的 `forgetVault` / `purge` 兩段、
      LAW-45(b)、LAW-46、EX-42、EX-44 的建構子名一律換成 `DeleteTargetIdDrift`;「契約 F」那節從
      「六個建構子」改成「**七個**」,`WriteTargetIdDrift` 那一列**移出**沿用表並註明它專屬
      寫入目標路徑(F003);「數據」表的建構子計數改成二十一個 / 本 feature 產生七個。
    - **`WriteTargetIdDrift` 在本 feature 之後不再出現於任何 law 或 example**——它與
      `ScopeIssue.VaultIdDrift`、`DeleteTargetIdDrift` 三者各管一條路徑:降級(查詢)/
      硬失敗(寫入目標)/ 硬失敗(刪除目標)。
