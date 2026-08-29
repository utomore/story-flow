---
id: F003
type: feature
title: scope-resolution
description: "resolveRead / resolveWrite / resolvePipeline、refs 遞移展開與擋環、保序去重"
status: done
created: 2026-08-29
updated: 2026-08-29
depends-on: [F001, F002]
related-adr: [ADR-008, ADR-014, ADR-017]
related-feature: []
---

# F003: 三種作用範圍的裁決(scope-resolution)

## 功能概述

實作 `workspace` 裁決管線的**第五、六步**:`refs` 遞移展開 → 保序去重 → 三種 scope,到交還
`service` 為止。負責模組是 design.md「內部模組劃分」的 **Scope**,只寫一個檔案
`workspace/src/Aapms/Workspace/Scope.hs`。

這是 ADR-017 決策三「讀跨、寫單一」被實體化成程式碼的那一點。本 feature 是契約 C 的
`ReadScope` / `WriteScope` / `PipelineScope` 三個型別的**唯一生產者**——型別本身已由 F001
一次寫齊在 `Aapms.Workspace.Types`,本 feature **不新增、不修改任何型別與任何 `WorkspaceError`
建構子**。全部檔案系統存取都經 F002 的 `detectVault` / `lookupSelector` / `readVaultRef` /
`readVaultRefAt`,本模組自己**不讀 marker、不算 `.aapms` 路徑**。

**驗收標準**(逐字抄自契約卡):

1. 對任意中樞,`resolveRead hub Nothing` 的 `rsVaults` 的 id 集合 = 全部**讀得到 marker 的**
   已註冊 vault,且**與當前目錄無關**(在 vault 內外各跑一次結果相同) — 觀察點:契約 C 的
   `resolveRead`
2. 對任意 `X`,`resolveRead hub (Just X)` 的 id 集合 = `{X} ∪ refs*(X)`;`refs` 成環時仍終止且
   結果是集合(不重複) — 觀察點:契約 C 的 `resolveRead`、`ReadScope`
3. `resolveWrite` 的 `wsTarget` 恒**不**來自 `refs` 展開:對任意 `X`,`wsTarget` 的 id 恒等於
   selector 指定或向上探測到的那一個 — 觀察點:契約 C 的 `WriteScope`
4. 沒有 selector 且從起點一路向上都沒有 `.aapms/` 時 `resolveWrite` 回 `NoWriteTarget`,訊息含
   **起點路徑** — 觀察點:契約 C 的 `resolveWrite`、契約 F 的 `renderWorkspaceError`
5. `resolvePipeline` 無 selector 時 `psRuns` 只含 `vmKind` 相符者;有 selector 且 kind 不符時回
   `VaultKindMismatch`,帶 vault id、要求的 kind、實際的 kind 三個值 — 觀察點:契約 C 的
   `resolvePipeline`、契約 F 的 `VaultKindMismatch`
6. 任一 vault 路徑不見或 marker 壞掉時,三個函式都仍回 `Right`,該 vault 不在結果集裡而在
   `*Issues` 裡 — 觀察點:契約 C 的三個 scope 型別的 `*Issues` 欄位
7. 三個結果清單都**保序去重**:同一個 vault 被 selector 與 `refs` 各帶進來一次時只出現一次,
   且順序是第一次出現的位置 — 觀察點:契約 C 的 `rsVaults` / `wsRead` / `psRuns`

> **驗收標準 6 的唯一例外,由契約本體給出**:design.md 契約 C 的第 2 條性質寫「整個指令只在
> **連中樞都載不起來**或**寫入目標決定不了**時才失敗」。`resolveWrite` 的**寫入目標**因此不受
> 第 6 條保護——目標的路徑不見 / marker 壞 / id 漂移時整道指令就該硬失敗。第 6 條在
> `resolveWrite` 上管的是 `wsRead` 那一段(`refs` 展開)。這條區分是本 spec 的 L12 / L13;
> 其中「id 漂移該回哪個 `WorkspaceError`」由 **2026-08-29 W3 閘門裁決**(A1 選 c),契約 F 新增
> `WriteTargetIdDrift VaultId FilePath VaultId`。

**明確不做**(逐字抄自契約卡):不判斷 ATTACH 上限(graph-core 的 `maxAttachedVaults` /
`TooManyVaults` 擁有它);不開任何 vault;不決定「這個指令屬於讀還是寫」(呼叫端選函式)。

追加三條由「明確不做」與 design.md 推出來的硬界線,都寫成可機械驗證的條文:

- **本 feature 不建立、不修改、不刪除任何檔案或目錄**(L4、L25(d))
- **本模組不自己讀 marker、不自己算 `.aapms` 的路徑**——那是 Discovery 擁有的事實,Scope 只
  消費它的四個函式(L25(b))
- **本模組唯一直接碰檔案系統的動作是 `canonicalizePath`**,而且只用在 `NoWriteTarget` 的起點
  路徑上(L25(f);理由見「正規化」段)

## 相依性

`depends-on: [F001, F002]`——design.md「功能規劃」階段一表 #3 的「依賴」欄是 `#2`,而 #2 本身
依賴 #1;查證後兩層都逐條用到:

- **F001**:`Hub` / `VaultEntry` / `VaultRef` / `ScopeIssue` / `ReadScope` / `WriteScope` /
  `PipelineScope` / `WorkspaceError` 八個型別,以及 `hubVaults` 一個 getter
- **F002**:`detectVault` / `lookupSelector` / `readVaultRef` / `readVaultRefAt` 四個函式**全用到**
  ——本 feature 是它們的第一個(也是目前唯一的)消費者

跨子系統:`graph-core` 九個 feature 全數 `done`。本 feature 用到的三個符號(`VaultMarker` 的
`vmId` / `vmKind` / `vmRefs` 三個欄位存取子、`VaultKind` 型別)都已交付,簽名逐一開原始碼查證
過,見「使用到的既有串接介面」。

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base` / `containers` / `directory` /
`filepath` / `text` / `time` / `toml-reader` / `aapms-core` / `aapms-store` 覆蓋本 feature 全部
所需(`containers` 供 `refs` 展開的 `Data.Set` visited 集合;`directory` 供
`canonicalizePath`)。

## 對應的 Level 2 契約

### 契約 C(本 feature 負責的六項)

```haskell
data ReadScope     = ReadScope     { rsVaults :: [VaultRef], rsIssues :: [ScopeIssue] }
data WriteScope    = WriteScope    { wsTarget :: VaultRef, wsRead :: [VaultRef], wsIssues :: [ScopeIssue] }
data PipelineScope = PipelineScope { psRuns   :: [VaultRef], psIssues :: [ScopeIssue] }

resolveRead     :: Hub -> Maybe Text -> IO (Either WorkspaceError ReadScope)
resolveWrite    :: Hub -> Maybe Text -> FilePath -> IO (Either WorkspaceError WriteScope)
resolvePipeline :: Hub -> VaultKind -> Maybe Text -> IO (Either WorkspaceError PipelineScope)
```

三個型別**已由 F001 宣告完畢**(`Types.hs:187-210`),本 feature 一個字都不改;三條簽名逐字
照抄契約 C,**沒有任何偏離**。

契約 C 的規則表(design.md「三個裁決的規則」),本 feature 逐格實作:

| 函式 | selector = `Nothing` | selector = `Just X` |
|---|---|---|
| `resolveRead` | 全部已註冊 vault。**不看當前目錄** | `{X} ∪ refs*(X)`,`refs*` 是遞移閉包 |
| `resolveWrite` | 從第三參數逐層向上找含 `.aapms/` 的目錄;找不到回 `NoWriteTarget`。`wsRead` = `{目標} ∪ refs*(目標)` | 目標 = `X`;`wsRead` = `{X} ∪ refs*(X)` |
| `resolvePipeline` | 全部已註冊且 `vmKind` 相符的 vault,各跑一次 | `{X}`;`X` 的 `vmKind` 不符時回 `VaultKindMismatch` |

### 契約 F(本 feature 負責的三個建構子)

`NoWriteTarget FilePath` / `VaultKindMismatch VaultId VaultKind VaultKind` /
`WriteTargetIdDrift VaultId FilePath VaultId`。本 feature 是三者的**唯一生產者**,而且
**不改 `renderWorkspaceError` 一個字**。

- 前兩個的**宣告與繁中訊息**已在 F001 交付(`Types.hs:303-306`、`renderWorkspaceError`)。
- `WriteTargetIdDrift` 是 **2026-08-29 W3 閘門裁決新增**(本 spec 的 A1 選 c)。三個值依序是
  **註冊表記的 `VaultId`、該 vault 的路徑、marker 裡實際的 `VaultId`**;訊息要說出下一步
  (`vault check` / `syncHub` / 重新 `vault add`)。它與 `ScopeIssue.VaultIdDrift` 是同一件事
  的兩種身分——**讀取路徑上是降級,寫入目標上是硬失敗**。
  **宣告與訊息由 F001 的 impl 加進 `Types.hs`,不屬本 feature 的寫入白名單**;本 feature 只是
  它的產生點(`resolveWrite` 的 id 守門,見 L13(b))。

本 feature 另外會**原樣透傳**三個由 F002 產生的建構子(不重新包裝、不改訊息):
`VaultSelectorNotFound` / `VaultSelectorAmbiguous`(來自 `lookupSelector`)、`MarkerUnreadable`
(來自 `readVaultRefAt`)。

### `ScopeIssue` 的四個建構子

前三個(`VaultPathMissing` / `VaultMarkerBroken` / `VaultIdDrift`)由 F002 的 `readVaultRef`
產生,本 feature 只**彙整**它們;第四個 `RefVaultNotRegistered VaultId VaultId` 是本 feature
的**唯一生產者**——`refs` 展開是唯一算得出「來源 vault、在中樞查不到的目標」這一對值的地方。

### 模組間公開介面(design.md 表裡與 Scope 有關的兩列)

```haskell
-- Scope → Discovery
readVaultRef   :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)
readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)
detectVault    :: FilePath -> IO (Maybe FilePath)
-- (lookupSelector 在契約 C,同樣由 Discovery 提供)

-- Scope → Hub
hubVaults :: Hub -> [VaultEntry]        -- 依 veId 反查 VaultEntry,供 refs 展開把 VaultId 換成路徑
```

四個函式的簽名與 W2 閘門裁決逐字相同,本 feature **不要求任何修改**。

## 實作方式

### 相依性查證(2026-08-29 打開 `store/src/`、`core/src/` 與 `workspace/src/` 讀到的實況)

六點與文字描述不同、必須在實作前知道的事實:

1. **`Aapms.Workspace.Types` 對 `VaultMarker` 的 import 是裸型別**(`Types.hs:65`,
   `import Aapms.Store.Marker (VaultMarker)`,F001 的 L17(d) 釘死),**轉不出欄位存取子**。
   本 feature 要用 `vmId`(去重與 id 守門)、`vmKind`(管線過濾與 `VaultKindMismatch`)、
   `vmRefs`(遞移展開)三個,只能從本模組自己對 `Aapms.Store.Marker` 的 import 拿——這與 F002
   的 L18(b) 是同一個處境,處置也同一套(見 L25(b))。
2. **`VaultKind` 不由 `Aapms.Workspace.Types` 轉出**(`Types.hs:66` 是
   `import Aapms.Store.Schema (VaultKind, renderVaultKind)`,而匯出清單裡沒有它)。
   `resolvePipeline` 的第二參數是契約 C 明定的 `VaultKind`,所以本模組**必須**直接
   `import Aapms.Store.Schema (VaultKind)`。這是 design.md「模組間公開介面」表**沒有**的一條
   邊(`Scope → aapms-store`),已列進「依賴方向」。
3. **`VaultKind` 只 derive `Show` / `Eq`**(`store/src/Aapms/Store/Schema.hs:63-64`)。kind 比對
   用 `==` 就夠,不需要 `Ord`,也**不需要** import `VaultKind (..)`——實例隨型別走,與 import
   清單裡列不列建構子無關。
4. **`VaultId` 是 `newtype VaultId = VaultId Text`,`deriving newtype (Eq, Ord)`**
   (`core/src/Aapms/Core/Id.hs:148-150`)。`Ord` 已經有了,所以 `refs` 展開的 visited 集合可以
   直接用 `Data.Set.Set VaultId`,**不需要**在本套件補任何實例。
5. **`markerDir` / `readMarker` / `configPath` / `indexDbPath` 在本 feature 一次都用不到**:
   路徑存在性、marker 讀取、`.aapms` 目錄名全部封在 F002 的四個函式裡。本模組因此對
   `Aapms.Store.Marker` 只需要三個欄位存取子,一個函式都不要——這由 L25(b) 逐字守住。
6. **`maxAttachedVaults = 10` 與 `TooManyVaults Int Int` 住在 graph-core**
   (`store/src/Aapms/Store/MultiVault.hs:126-127`、`store/src/Aapms/Store/Error.hs:76`),
   由 `openVaultSet` 在**去重之後**判定。契約卡的「明確不做」把這件事整個指給對方,所以本
   feature 對結果清單的長度**沒有任何上限檢查**——L24 把這一點寫成可驗證的條文(11 個 vault
   仍回 `Right`)。

程式碼知識圖(knot)查到的一件事:`knot query reachable Aapms.Store.MultiVault.openVaultSet
--reverse --depth 2` 只回 **2 個節點**(`Aapms.Store.MultiVault` 與門面 `Aapms.Store`)——ATTACH
上限那條路徑到今天為止只有 graph-core 自己在走。**這份圖建於 `ff07877`,不涵蓋 workspace 的
四個新模組**(依委派決策不重跑 `knot extract`:這台 Windows 機器會撞 MAX_PATH),所以它證得了
「graph-core 那一側沒有別人在用」,workspace 這一側則由 L25(d) 的 import 行守住。

### 「正規化」在本 spec 全篇的定義

> **正規化 = `System.Directory.canonicalizePath`**(W2 閘門裁決,design.md 契約 C 的 `vrPath`
> 值域欄已釘死)。

本模組只在**一個地方**自己呼叫它:`resolveWrite` 找不到寫入目標時,`NoWriteTarget` 帶的那個
起點路徑。其餘全部路徑(`vrPath`、`detectVault` 的回傳)都是 F002 已經正規化過的產出,本模組
原樣捧著、不再處理。

理由:`NoWriteTarget "."` 對使用者沒有任何價值,而 design.md 契約 C 的 `vrPath` 值域欄對
`canonicalizePath` 的取捨理由原文就是「錯誤訊息印的是工具**真正去看的**那個位置——使用者拿它去
`ls` 才有意義」。
`canonicalizePath` 對不存在的路徑不拋例外(F002 在本機 GHC 9.14.1 / Windows 實測),所以這條
路徑安全。

### 三個函式的資料流

```text
resolveRead hub Nothing
  → walkAll hub                                  -- 全部已註冊,不展開 refs
  → Right (ReadScope vaults issues)

resolveRead hub (Just s)
  → lookupSelector hub s
      Left e  → Left e                           -- 原樣透傳:Selector{NotFound,Ambiguous}
      Right e → readVaultRef e (vePath e)
          Left iss  → Right (ReadScope [] [iss]) -- 種子不可達:仍是 Right,且不展開它的 refs
          Right ref → expandRefs hub ref
                        → Right (ReadScope vaults issues)

resolveWrite hub sel start
  -- 寫入目標:兩條路都經 readVaultRefAt,失敗型別本來就是 WorkspaceError
  → sel == Nothing:
        detectVault start
          Nothing   → canonicalizePath start >>= \s' → Left (NoWriteTarget s')
          Just root → readVaultRefAt hub root
                        Left e  → Left e                     -- MarkerUnreadable,原樣透傳
                        Right r → target = r
    sel == Just s:
        lookupSelector hub s
          Left e  → Left e                                   -- 原樣透傳
          Right e → readVaultRefAt hub (vePath e)
                      Left err → Left err                    -- MarkerUnreadable(路徑不見與 marker 壞都在這)
                      Right r
                        | vmId (vrMarker r) /= veId e
                            → Left (WriteTargetIdDrift (veId e) (vrPath r) (vmId (vrMarker r)))
                              -- id 漂移:註冊表記的 id、路徑、marker 實際的 id(W3 閘門)
                        | otherwise → target = r
  → expandRefs hub target                        -- wsRead = {target} ∪ refs*(target),target 排第一
  → Right (WriteScope target reads issues)

resolvePipeline hub k Nothing
  → walkAll hub
  → 過濾 vmKind == k(不符者不產生 issue)→ 保序去重
  → Right (PipelineScope runs issues)

resolvePipeline hub k (Just s)
  → lookupSelector hub s
      Left e  → Left e                                       -- 原樣透傳
      Right e → readVaultRef e (vePath e)
          Left iss  → Right (PipelineScope [] [iss])          -- 讀不到 marker 就判不了 kind
          Right ref
            | vmKind (vrMarker ref) /= k
                → Left (VaultKindMismatch (vmId (vrMarker ref)) k (vmKind (vrMarker ref)))
            | otherwise
                → Right (PipelineScope [ref] [])              -- 恰好一個,不展開 refs
```

兩個私有 helper(**不匯出**,簽名由 impl 自己決定,本 spec 只釘行為):

```text
walkAll hub                                       -- 全部已註冊,不展開 refs
  → 對 hubVaults hub 的每一列 e,依中樞順序:
      readVaultRef e (vePath e)
        Left iss  → issues ++= [iss]
        Right ref → out    ++= [ref]
  → 以 vmId 保序去重(保留首次出現的位置)

expandRefs hub seed                               -- 種子 + refs 遞移展開(BFS)
  visited := { vmId (vrMarker seed) }             -- 種子先進 visited:refs 指回種子時直接略過
  out     := [seed]                               -- 種子恒排第一
  queue   := [ (vmId (vrMarker seed), t) | t <- vmRefs (vrMarker seed) ]   -- (來源, 目標)
  issues  := []
  while queue 非空,取出隊首 (src, t):
     t ∈ visited → 略過(擋環;同一個目標只處理一次)
     否則 visited += t,然後:
       find ((== t) . veId) (hubVaults hub) 沒命中
         → issues ++= [RefVaultNotRegistered src t]          -- 降級,不中止
       命中 e:
         readVaultRef e (vePath e)
           Left iss  → issues ++= [iss]                      -- 不可達:排除,且不展開它的 refs
           Right ref → out ++= [ref]
                       queue ++= [ (vmId (vrMarker ref), t') | t' <- vmRefs (vrMarker ref) ]
  → 以 vmId 保序去重
```

四個必須明講的細節:

前三條逐字落實 design.md **契約 C 的「展開的走訪規則」**段(2026-08-29 W3 閘門裁決新增),
第四條是它們的實作前提——**四條都是 Level 2 契約,不是本 feature 的實作自主權**:

- **走訪順序是 BFS(廣度優先,先進先出),種子排第一**(契約 C 走訪規則第二條):接著是種子
  `refs` 在 marker 裡的順序,再下一層。契約原文的理由是「`rsVaults` 的順序是『跟我直接相鄰的
  先出現』而不是深優先的長鏈」;`refs` 的語意本來就是「收窄時的**最小**讀取集合」,而且順序
  必須是確定的,laws 才寫得出來。
- **不可達的節點不展開它自己的 `refs`,三種不可達一視同仁**(契約 C 走訪規則第一條):路徑
  不見與 marker 壞是「讀不到 `refs`,沒有東西可展開」;**id 漂移是「讀得到但不採信」**——
  契約原文「身分不確定時,任何以它為起點的關係都是不確定的,而 ADR-017 把 id 撞號定義成
  『有人複製了整個 vault 目錄』,那一串的來源本身就可疑」。代價是一個壞掉的中繼 vault 會讓
  它後面整串退出範圍,但那一串本來就是靠它的 marker 才找得到的。
- **同一個未註冊目標只產生一則 `RefVaultNotRegistered`**(契約 C 走訪規則第三條),`src` 取
  **BFS 序最早**列出它的那個來源(visited 擋掉後續的)。
- **visited 以「走到它時用的 `VaultId`」為鍵**,不是以 `VaultEntry` 為鍵:種子用它 marker 的
  `vmId`,`refs` 目標用 `refs` 裡那個 `VaultId`。ADR-017「vault 的身分就是 marker 裡的 id」,
  這是唯一自洽的鍵(`VaultEntry` 也沒有 `Ord`);而中樞是有限的,visited 單調成長,所以
  **任何 `refs` 圖都終止**。

### `resolveWrite` 怎麼把兩條路的失敗收斂成同一個 `Either WorkspaceError WriteScope`

編排者交辦的那一格。答案是:**寫入目標這一路完全不走 `readVaultRef`,所以根本不需要
`ScopeIssue → WorkspaceError` 的轉換。**

`readVaultRef` 回 `Either ScopeIssue VaultRef`,是因為它的呼叫情境是「查詢範圍裡的一個候選」
——失敗是降級。`readVaultRefAt` 回 `Either WorkspaceError VaultRef`,是因為它的呼叫情境是
「決定寫入目標」——失敗是硬錯誤。F002 拆這兩個函式的整個理由就是這個(F002 的 A1)。所以
`resolveWrite` 的正確做法不是「把 selector 那條路的 `ScopeIssue` 翻譯成 `WorkspaceError`」,
而是**讓 selector 那條路也走 `readVaultRefAt`**,只是起點路徑改成 `vePath e`:

| 失敗 | selector 路徑(`readVaultRefAt hub (vePath e)`) | 探測路徑(`readVaultRefAt hub root`) |
|---|---|---|
| 路徑不存在 | `MarkerUnreadable p' (VaultMarkerMissing …)` | 同左(`detectVault` 命中過,所以罕見) |
| marker 解不開 | `MarkerUnreadable p' (VaultMarkerInvalid …)` | 同左 |
| id 漂移 | **`readVaultRefAt` 表達不出**——它不知道使用者點名的是誰;由 `resolveWrite` 的 id 守門補上,回 `WriteTargetIdDrift` | 不存在這種失敗(沒有被點名的 id) |

換句話說,兩條路的失敗型別**不需要收斂,因為它們本來就是同一個型別**;真正剩下的只有一格:
`readVaultRefAt` 沒有「使用者點名的是哪一列」這個資訊,所以**id 漂移只能由 `resolveWrite`
自己補一道守門**。

那一格該回哪個 `WorkspaceError`,由 **2026-08-29 W3 閘門裁決**(本 spec 的 A1 選 c):契約 F
新增 `WriteTargetIdDrift VaultId FilePath VaultId`,守門回
`Left (WriteTargetIdDrift (veId e) (vrPath r) (vmId (vrMarker r)))`。被否決的兩個候選都會說謊
——`NoWriteTarget` 的訊息裡「未指定 `--vault`」「向上找不到 `.aapms`」在這條路徑上都不成立,
而 `MarkerUnreadable` 要在這一層**捏造**一個 graph-core 的 `StoreError`(違反契約 F「這一層不
翻譯」)且會叫使用者去修一個沒壞的 marker。完整的成本比較留在 A1 備查。

`wsIssues` 因此**只**裝 `expandRefs` 產生的降級紀錄,**恒不含任何描述 `wsTarget` 的
`ScopeIssue`**(L13(c))——這是「寫入目標決定不了就硬失敗」在型別以外的另一半保證。

## 使用到的既有串接介面

行號是**建檔當下**的導航線索;一致性檢查一律比對**簽名原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `detectVault :: FilePath -> IO (Maybe FilePath)` | `workspace/src/Aapms/Workspace/Discovery.hs:53` | F002 | `resolveWrite` 無 selector 時從起點向上找寫入目標 |
| `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | `workspace/src/Aapms/Workspace/Discovery.hs:77` | F002 | 三個函式的 `Just s` 分支;失敗**原樣透傳** |
| `readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)` | `workspace/src/Aapms/Workspace/Discovery.hs:110` | F002 | 查詢範圍裡每個候選的權威身分;失敗是降級 |
| `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)` | `workspace/src/Aapms/Workspace/Discovery.hs:135` | F002 | **寫入目標專用**;失敗是硬錯誤 `MarkerUnreadable` |
| `hubVaults :: Hub -> [VaultEntry]` | `workspace/src/Aapms/Workspace/Types.hs:92`(定義)、`Hub.hs:19`(轉出) | F001 | `walkAll` 的候選清單;`refs` 展開時依 `veId` 反查 |
| `data VaultEntry = VaultEntry { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:123-133` | F001 | `vePath` 是 `readVaultRef` 的第二參數;`veId` 是反查鍵與 id 守門的一邊 |
| `data VaultRef = VaultRef { vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }` | `workspace/src/Aapms/Workspace/Types.hs:163-171` | F001 | 三個結果清單的元素 |
| `data ScopeIssue`(四個建構子) | `workspace/src/Aapms/Workspace/Types.hs:174-184` | F001 | `*Issues` 的元素;本 feature 產生第四個 `RefVaultNotRegistered` |
| `data ReadScope` / `WriteScope` / `PipelineScope` | `workspace/src/Aapms/Workspace/Types.hs:187-210` | F001 | 本 feature 的三個產出型別 |
| `data WorkspaceError`(**十七個**建構子)、`renderWorkspaceError :: WorkspaceError -> Text` | `workspace/src/Aapms/Workspace/Types.hs:289-331` | F001 | 失敗通道;本 feature 產生 `NoWriteTarget` / `VaultKindMismatch` / `WriteTargetIdDrift`,透傳三個 |
| `WriteTargetIdDrift VaultId FilePath VaultId`(註冊表記的 id、路徑、marker 實際的 id) | `workspace/src/Aapms/Workspace/Types.hs`(由 **F001 的 impl** 補上,W3 閘門新增) | design.md 契約 F(2026-08-29 W3) | `resolveWrite` 的 id 守門(L13(b))**唯一**產生它;本 feature **不宣告、不寫它的訊息** |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57-63` | graph-core F005 | 本 feature 用 `vmId` / `vmKind` / `vmRefs` 三個欄位;**`vmName` 一次都不用** |
| `data VaultKind = AssetVault \| StoryVault`(`deriving stock (Show, Eq)`) | `store/src/Aapms/Store/Schema.hs:63-64` | graph-core F005 | `resolvePipeline` 的第二參數與 `vmKind` 的比對 |
| `renderVaultKind :: VaultKind -> Text` | `store/src/Aapms/Store/Schema.hs:66-68` | graph-core F005 | **本 feature 不呼叫**;列出是因為 `VaultKindMismatch` 的訊息經 F001 的 `renderWorkspaceError` 轉呼叫它,測試斷言要用 |
| `newtype VaultId = VaultId Text`(`deriving newtype (Eq, Ord)`) | `core/src/Aapms/Core/Id.hs:146-150` | graph-core F001 | 去重鍵、visited 集合的元素、`RefVaultNotRegistered` 的兩個值 |
| `readMarker :: FilePath -> IO (Either StoreError VaultMarker)`、`markerDir`、`configPath`(vault 的) | `store/src/Aapms/Store/Marker.hs:46-93` | graph-core F005 | **本 feature 一個都不 import**(L25(b));列出是因為測試要拿 `readMarker` 造預期值、拿 `configPath` 算 `VaultMarkerMissing` 帶的路徑 |
| `maxAttachedVaults :: Int`(= 10)、`TooManyVaults Int Int` | `store/src/Aapms/Store/MultiVault.hs:126-127`、`store/src/Aapms/Store/Error.hs:76` | graph-core F009 | **本 feature 明確不做**;列出是為了 L24 指得出「這件事屬於誰」 |
| `canonicalizePath :: FilePath -> IO FilePath` | `directory` 的 `System.Directory` | - | 只用在 `NoWriteTarget` 的起點路徑上 |
| `Data.Set.Set` / `insert` / `member` | `containers` | - | `refs` 展開的 visited 集合(`VaultId` 已有 `Ord`) |

## 新增的介面

全部三條都在 `workspace/src/Aapms/Workspace/Scope.hs`(本 feature 唯一寫入的 `.hs`)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `resolveRead :: Hub -> Maybe Text -> IO (Either WorkspaceError ReadScope)` | 查詢類指令的作用範圍:無 selector = 全部已註冊(不看當前目錄、不展開 `refs`);有 selector = `{X} ∪ refs*(X)` | `workspace/src/Aapms/Workspace/Scope.hs:66` |
| `resolveWrite :: Hub -> Maybe Text -> FilePath -> IO (Either WorkspaceError WriteScope)` | 寫入類指令的作用範圍:唯一寫入目標 + 它的最小讀取集合;目標決定不了就硬失敗 | `workspace/src/Aapms/Workspace/Scope.hs:90` |
| `resolvePipeline :: Hub -> VaultKind -> Maybe Text -> IO (Either WorkspaceError PipelineScope)` | 管線類指令的作用範圍:`vmKind` 相符的 vault 各跑一次;有 selector 且 kind 不符即錯 | `workspace/src/Aapms/Workspace/Scope.hs:105` |

模組匯出清單只有這三個函式;型別一律讓消費端從 `Aapms.Workspace.Types` 取,本模組**不轉出**
任何型別(沿用 W1 / W2 立下的慣例)。兩個私有 helper(`walkAll` / `expandRefs` 的實作)
**不得匯出**——它們是本模組的內部佈線,不是契約。

## 數據

本 feature **不新增、不修改、不刪除任何型別**。

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `ReadScope` | 沿用(F001 宣告) | `{ rsVaults :: [VaultRef], rsIssues :: [ScopeIssue] }` | 「這道查詢實際讀得到哪些 vault、哪些被降級掉了」 |
| `WriteScope` | 沿用(F001 宣告) | `{ wsTarget :: VaultRef, wsRead :: [VaultRef], wsIssues :: [ScopeIssue] }` | 「這道寫入落在哪一個 vault、它解得開哪些跨 vault 的 `Ref`」 |
| `PipelineScope` | 沿用(F001 宣告) | `{ psRuns :: [VaultRef], psIssues :: [ScopeIssue] }` | 「這條管線要對哪些 vault 各跑一次」 |
| `ScopeIssue` | 沿用(F001 宣告) | 四個建構子 | 「一個候選 vault 為什麼進不了結果集」;本 feature 是第四個建構子的唯一生產者 |
| `WorkspaceError` | 沿用(F001 宣告) | 十六個建構子,本 feature 產生兩個、透傳三個 | 「這個子系統會有哪些失敗」(Types 擁有,不是 Scope) |

**Scope 擁有的唯一事實是 ADR-017 的三種範圍規則**——不是 vault 的身分(marker 擁有)、不是
中樞記了什麼(Hub 擁有)、也不是「這個字串指的是哪個 vault」(Discovery 擁有)。

### 測試素材:一組固定的 vault 佈局

Examples 全部建立在同一組暫存目錄 `T` 上(`refs` 用 ADR-014 的 `vlt-` + 8 位小寫十六進位):

| 名稱 | 路徑 | marker(`id` / `kind` / `name` / `refs`) | 中樞 `[[vaults]]` 那一列 |
|---|---|---|---|
| A | `T/a` | `vlt-aaaa1111` / asset / `"a"` / `["vlt-bbbb2222"]` | `veId=vlt-aaaa1111`、`veName="a"`、`veKind=AssetVault` |
| B | `T/b` | `vlt-bbbb2222` / story / `"b"` / `["vlt-cccc3333"]` | `veId=vlt-bbbb2222`、`veName="b"`、`veKind=StoryVault` |
| C | `T/c` | `vlt-cccc3333` / asset / `"c"` / `["vlt-aaaa1111"]` | `veId=vlt-cccc3333`、`veName="c"`、`veKind=AssetVault` |
| D | `T/d` | `vlt-dddd4444` / asset / `"d"` / `[]` | `veId=vlt-dddd4444`、`veName="d"`、`veKind=AssetVault` |
| M | `T/m` | `.aapms/` 目錄在,**沒有** `config.toml` | `veId=vlt-mmmm1111`、`veName="m"` |
| P | `T/gone`(**不存在**) | — | `veId=vlt-pppp1111`、`veName="p"` |
| Z | `T/z` | `vlt-99998888` / asset / `"z"` / `[]` | `veId=vlt-77776666`(**與 marker 不符**)、`veName="z"` |
| E | `T/e` | `vlt-eeee5555` / story / `"e"` / `[]` | **不在中樞**(未註冊) |

中樞 `[[vaults]]` 的順序固定為 **A, B, C, D, M, P, Z**。`A → B → C → A` 是一個三節點的環,
用來驗 L19。`Hub` 是不透明型別,測試造它走 `mkHub vs ps llm tools txt`(F001 的唯一建構入口)。

## Laws

### 三個函式共用

- **L1(保序去重,以 `vmId`)**:對任意輸入,`rsVaults` / `wsRead` / `psRuns` 三個清單裡任兩個
  元素的 `vmId (vrMarker …)` 互不相同;而且清單等於「走訪序列」以 `vmId` 為鍵、**保留首次
  出現位置**的去重結果(`nubOn vmId`),不是排序、不是取最後一次。
- **L2(marker 是真相)**:三個清單裡每一個 `VaultRef r`,`vrMarker r` 逐欄等於直接對 `vrPath r`
  呼叫 `readMarker` 的結果。把中樞那一列的 `veName` / `veKind` 換成與 marker **不同**的任何值
  後重跑,三個函式的結果**逐欄不變**(中樞是快取,marker 才是真相)。
- **L3(不可達不中止)**:某個候選 vault 路徑不見 / marker 壞 / id 漂移時,`resolveRead` 與
  `resolvePipeline` **恒回 `Right`**;該 vault 的 `vmId` 不出現在結果清單裡,而
  `readVaultRef` 對它回的那一則 `ScopeIssue` **逐欄相同地**出現在對應的 `*Issues` 裡。
  `resolveWrite` 在**非寫入目標**的候選上同樣如此(寫入目標見 L12 / L13)。
- **L4(三個函式都不動檔案系統)**:對任意輸入,呼叫前後 `T` 底下的整棵目錄樹(檔案清單 +
  逐位元組內容)相同;特別是**不會建立** `.aapms/`、不會建立或開啟任何 `index.db`、不會修補
  壞掉的 marker、不會寫回中樞。
- **L5(`*Issues` 的來源受限)**:`RefVaultNotRegistered` **只**由 `refs` 展開產生——
  `resolveRead hub Nothing` 與 `resolvePipeline hub k Nothing` 的 `*Issues` 恒不含它(那兩條路
  不展開 `refs`),即使中樞裡某個 vault 的 `refs` 指向未註冊的 id。

### `resolveRead`

- **L6(無 selector = 全部已註冊,與當前目錄無關)**:`resolveRead hub Nothing` 的 `rsVaults`
  的 `vmId` 集合 = `{ vmId m | e ∈ hubVaults hub, readVaultRef e (vePath e) == Right (VaultRef _ _ m) }`;
  順序是 `hubVaults hub` 的順序(去重後)。且對任意兩個工作目錄(一個在某 vault 內、一個在
  全部 vault 外),兩次呼叫的結果**逐欄相同**。
- **L7(有 selector = `{X} ∪ refs*(X)`,BFS 順序;design.md 契約 C「展開的走訪規則」第二條)**:`resolveRead hub (Just s)` 在
  `lookupSelector hub s == Right e` 且 `readVaultRef e (vePath e) == Right seed` 時,`rsVaults`
  的第一個元素是 `seed`,其餘是自 `seed` 出發沿 `vmRefs` 邊、**廣度優先**走到且
  `readVaultRef` 成功的節點,順序是首次入隊的順序。
- **L8(selector 解不開就是硬錯,原樣透傳)**:`lookupSelector hub s == Left err` 時
  `resolveRead hub (Just s) == Left err`——`err` 與 `lookupSelector` 回的**逐欄相同**
  (`VaultSelectorNotFound` / `VaultSelectorAmbiguous`,不重新包裝、不改訊息)。
- **L9(種子自己不可達仍是 `Right`,且不展開)**:`lookupSelector` 成功但
  `readVaultRef e (vePath e) == Left iss` 時,`resolveRead hub (Just s) == Right (ReadScope [] [iss])`
  ——空清單、恰好一則 issue,而且**不產生任何 `RefVaultNotRegistered`**(讀不到 marker 就
  讀不到 `refs`;id 漂移時身分不確定,同樣不展開)。

### `resolveWrite`

- **L10(`wsTarget` 恒不來自 `refs` 展開)**:對任意輸入,若 `resolveWrite hub sel start == Right ws`,
  則 `vmId (vrMarker (wsTarget ws))` 等於——`sel == Just s` 時,`lookupSelector hub s` 命中那一列的
  `veId`;`sel == Nothing` 時,`detectVault start` 命中那一層的 marker 的 `vmId`。**即使某個
  `refs` 目標也在 `wsRead` 裡,`wsTarget` 不會換人**;把中樞裡任何一個 vault 的 `refs` 任意改寫,
  `wsTarget` 逐欄不變。
- **L11(`wsRead` = `{目標} ∪ refs*(目標)`,目標排第一)**:`head (map (vmId . vrMarker) (wsRead ws))
  == vmId (vrMarker (wsTarget ws))`;其餘元素與 `resolveRead` 對同一個種子的展開結果**逐欄相同**
  (同一個 BFS、同一套保序去重)。`wsRead` 恒非空。
- **L12(沒有 selector 且探測不到 → `NoWriteTarget`,帶正規化後的起點)**:`sel == Nothing` 且
  `detectVault start == Nothing` 時,`resolveWrite hub Nothing start == Left (NoWriteTarget s')`,
  `s'` 是 `canonicalizePath start`;且 `renderWorkspaceError (NoWriteTarget s')` 的輸出**含 `s'`
  這個字串**。
- **L13(寫入目標的失敗一律是 `WorkspaceError`,不是 `ScopeIssue`)**:
  (a) 目標路徑上 `readMarker` 失敗(路徑不存在或 marker 解不開)時,
  `resolveWrite` 回 `Left (MarkerUnreadable p' err)`,`p'` 是目標路徑的正規化、`err` 是
  `readMarker p'` 回的**原件**(逐欄相同,不轉字串、不翻譯);兩條路(selector 與探測)都適用。
  (b) `sel == Just s` 且 `lookupSelector` 命中的那一列的 `veId` 與目標 marker 的 `vmId` **不符**
  時,`resolveWrite` 回 `Left (WriteTargetIdDrift (veId e) p' (vmId m))`——三個值依序是
  **註冊表記的 id、目標路徑(正規化後)、marker 裡實際的 id**,三者都出現在
  `renderWorkspaceError` 的輸出裡。這是**硬失敗**,不是降級:同一件事在讀取路徑上是
  `ScopeIssue.VaultIdDrift`(該 vault 退出範圍、其餘照跑),在寫入目標上整道指令就該停
  (2026-08-29 W3 閘門裁決,design.md 契約 F)。
  (c) `wsIssues` **恒不含任何以 `wsTarget` 為對象的 `ScopeIssue`**——它只裝 `refs` 展開產生的
  降級紀錄。
- **L14(未註冊的 vault 可以是寫入目標)**:`detectVault` 命中一個中樞 `[[vaults]]` 裡沒有的
  vault 時,`resolveWrite hub Nothing start` 仍回 `Right`,`vrEntry (wsTarget ws) == Nothing`,
  且 `wsRead` 的第一個元素就是它。
- **L15(selector 勝過探測)**:`sel == Just s` 時,`resolveWrite hub (Just s) start` 的結果
  **與 `start` 無關**——對任意兩個起點(一個在別的 vault 內、一個不在任何 vault 內),結果
  逐欄相同,且 `detectVault` 的結果不影響任何一個欄位。

### `resolvePipeline`

- **L16(無 selector = 全部已註冊且 kind 相符)**:`psRuns` 的 `vmId` 集合 =
  `{ vmId m | e ∈ hubVaults hub, readVaultRef e (vePath e) == Right (VaultRef _ _ m), vmKind m == k }`;
  順序是 `hubVaults hub` 的順序。**kind 不符不產生任何 `ScopeIssue`**——`psIssues` 與
  `resolveRead hub Nothing` 的 `rsIssues` 逐欄相同(那是「這條管線與它無關」,不是降級)。
- **L17(有 selector 且 kind 相符 = 恰好一個,不展開 `refs`)**:`psRuns` 的長度恰好 1,
  其 `vmId` 等於 selector 命中那一列的 `veId`;`psIssues == []`。把該 vault 的 `refs` 改成
  任何值,`psRuns` 逐欄不變(管線每次執行都寫自己的索引,`refs` 展開進來的一律唯讀)。
- **L18(有 selector 且 kind 不符 → `VaultKindMismatch`,三個值)**:回
  `Left (VaultKindMismatch vid want got)`,`vid == vmId` of 該 vault 的 **marker**、
  `want` == `resolvePipeline` 的第二參數、`got` == `vmKind` of 該 vault 的 marker;且
  `renderWorkspaceError` 的輸出同時含 `vid` 的字串、`renderVaultKind want` 與
  `renderVaultKind got`。
- **L19(有 selector 但該 vault 不可達 → `Right` + issue,不是 `VaultKindMismatch`;design.md
  契約 C「展開的走訪規則」第四條)**:`readVaultRef` 對它回 `Left iss` 時,
  `resolvePipeline hub k (Just s) == Right (PipelineScope [] [iss])`——契約原文:「kind 是從
  marker 讀出來的,marker 都拿不到就談不上 kind 相不相符」。三種不可達(路徑不見 / marker 壞 /
  id 漂移)都適用。

### `refs` 遞移展開

- **L20(遞移閉包、對環安全、恒終止;design.md 契約 C 性質 3 + 「展開的走訪規則」第二條)**:
  對任意 `refs` 圖(含自環 `A → A`、互指 `A ⇄ B`、長環 `A → B → C → A`、菱形
  `A → {B,C}, B → D, C → D`),展開結果 = 「自種子出發沿 `vmRefs` 邊可達、且 `readVaultRef`
  成功的節點」的集合,**不重複**,順序是 **BFS 的首次入隊序、種子排第一**;且對任意輸入三個
  函式都在有限步內終止(visited 集合單調成長且被 `hubVaults` 的長度所限)。
- **L21(未註冊的 `refs` 目標降級為警告;ADR-017 2026-08-29 補充 + design.md 契約 C「展開的
  走訪規則」第三條)**:`refs` 裡某個 `VaultId t` 在 `hubVaults hub` 裡找不到 `veId == t` 的
  列時,產生 `RefVaultNotRegistered src t`(`src` 是列出它的那個 vault 的 `vmId`),進
  `*Issues`;**不中止、不進結果集**。同一個 `t` 被多個來源列出時**只產生一則**,`src` 是
  **BFS 序最早**的那一個來源。
- **L22(不可達的節點不展開它自己的 `refs`,三種不可達一視同仁;design.md 契約 C「展開的走訪
  規則」第一條 + 性質 1)**:某個 `refs` 目標的 `readVaultRef` 回 `Left iss` 時,`iss` 進
  `*Issues`,而它 marker 裡的 `refs`**不參與展開**——把該 vault 的 `refs` 換成任何值,結果
  清單逐欄不變。**`VaultIdDrift` 也適用**:那種情況下 marker 讀得到、`refs` 也拿得到,但依契約
  原文「身分不確定時,任何以它為起點的關係都是不確定的」,一律不展開。代價是一個壞掉的中繼
  vault 會讓它後面整串退出範圍,而那一串本來就是靠它的 marker 才找得到的。
- **L23(展開進來的一律唯讀)**:`resolveWrite` 的 `wsRead` 裡除第一個元素外,沒有任何一個
  的 `vmId` 會等於 `vmId (vrMarker (wsTarget ws))`(L1 的去重保證),而且對任意 `refs` 圖,
  `wsTarget` 都不是「只能經由 `refs` 走到」的那些節點之一;`psRuns` 恒不含任何只經由 `refs`
  走到的 vault。

### 明確不做

- **L24(不判 ATTACH 上限)**:中樞含 11 個以上讀得到 marker 的 vault 時,`resolveRead hub Nothing`
  回 `Right`,`length (rsVaults rs) == 11`;`resolvePipeline` 同理。三個函式**不回任何與數量
  有關的錯誤**,`WorkspaceError` 也沒有那種建構子(`TooManyVaults` 屬 graph-core 的
  `Aapms.Store.Error`)。

### 依賴方向與職責界線

- **L25(以 import 行驗證;**比對前先去除行尾 `\r`**)**:專案的 `core.autocrlf = true` 讓 `.hs`
  在乾淨 checkout 上是 CRLF,逐字比對前必須先把行尾的 `\r` 去掉(W1 的 L17(d) 與 W2 的 L18
  各踩過一次)。`Scope.hs` 的 **import 行**滿足:
  - (a) 本套件內允許的 import **只有** `Aapms.Workspace.Types`、`Aapms.Workspace.Hub`、
    `Aapms.Workspace.Discovery` 三個。**不得**出現 `import Aapms.Workspace.Location` /
    `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Projects` / `Aapms.Workspace.Tools` 的行——
    方向是 `Types ← Location ← Hub ← Discovery ← Scope`,Scope 是最下游,不得往下游拿東西,
    也不需要中樞的檔案位置(禁 `Location` 同時把「用 `HubMalformed` 報寫入目標問題」這條路
    堵死,見 A1 的選項 d)。
  - (b) **若**有對 `Aapms.Store.Marker` 的 import 行,它**必須逐字是**
    `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmRefs))`。
    **這條 law 守的是「Scope 只讀 marker 的三個欄位、自己不讀 marker」**:清單放行的是三個
    欄位存取子,一個函式都沒有;所以日後有人在本模組直接呼叫 `readMarker`、用 `markerDir` /
    `configPath` / `indexDbPath` 自己拼 `.aapms` 的路徑、或碰 `initVaultAt` / `openVault` /
    `closeVault` / `VaultHandle`,編譯得過但**這條會紅**——「路徑 → 權威身分」的知識歸屬在
    Discovery,不在這裡。被放寬成 `VaultMarker (..)` 同樣紅(多出來的 `vmName` 在本 feature
    一次都用不到,列進來就是界線鬆掉)。
    (寫成條件式是因為骨架階段的三條簽名用不到這三個名字,留著會有 `-Wall` 的 redundant
    import 警告;impl 填本體時才會出現這一行。與 F002 的 L18(b) 同一個處置。)
  - (c) **若**有對 `Aapms.Store.Schema` 的 import 行,它**必須逐字是**
    `import Aapms.Store.Schema (VaultKind)`——只取型別。**不得**是 `VaultKind (..)`,也不得
    含 `renderVaultKind` / `parseVaultKind` / `schemaVersion` / 任何索引函式:本模組只用 `==`
    比較 kind(實例隨型別走),**不渲染、不解析**——`VaultKindMismatch` 的訊息由 F001 的
    `renderWorkspaceError` 產生,這一層不翻譯。
    (這一行在**骨架階段就存在**,因為 `resolvePipeline` 的簽名要用 `VaultKind`,所以本條
    在兩個階段都做實質比對。)
  - (d) **完全不得** import `Aapms.Store.Atomic`(不寫任何檔案)、`Aapms.Store`(門面)、
    `Aapms.Store.Schema` 以外的任何 `Aapms.Store.*`——特別是 `Aapms.Store.MultiVault`
    (ATTACH 上限屬 graph-core,見 L24)、`Aapms.Store.Index` / `Query` / `Write` / `Create` /
    `Edit` / `Walk` / `Node` / `Row` / `Tokenize`(不開索引、不查內容、不寫入)。
    `Aapms.Store.Error` 也不得 import:`StoreError` 只被原樣捧在 `MarkerUnreadable` 裡透傳,
    本模組一次都不 pattern match、不 render。
  - (e) **完全不得** import `System.Process`——不執行任何外部程式(那是 F006)。
  - (f) **若**有對 `System.Directory` 的 import 行,它**必須逐字是**
    `import System.Directory (canonicalizePath)`。**不得**含 `doesDirectoryExist` /
    `doesFileExist` / `createDirectory` / `createDirectoryIfMissing` / `removeFile` /
    `removeDirectoryRecursive` / `listDirectory` / `getDirectoryContents` / `findExecutable` /
    `makeAbsolute` / `getCurrentDirectory`。守的是三件事:本模組**不自己判斷路徑存不存在**
    (那是 `readVaultRef` 的 `VaultPathMissing`)、**不建立也不刪除任何東西**(L4)、
    **不看當前目錄**(L6 的「與當前目錄無關」——`getCurrentDirectory` 一旦出現就是違反)。
    `System.FilePath` 則完全不需要,出現也算違反(路徑拼接是 Discovery 的事)。

  **判準只看 import 行,不做全檔字串搜尋**:本檔的 Haddock 本來就會提到 `.aapms/` /
  `readMarker` / `maxAttachedVaults` / `TooManyVaults` 這些名字來說明界線,全檔搜尋會把
  「文件寫得清楚」誤判成「越界」。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」逐條判定,**不是整批全紅**):
>
> - **預期綠**:**L25 的六條子斷言 (a)–(f) 全部**。它們驗的是骨架原文自身就承載的事實
>   (本檔的 import 行),不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠
>   就退回重寫。** 其中 (b) 與 (f) 是條件式,**兩個階段都預期綠**:骨架階段沒有那兩行,條件
>   為假即通過;impl 補上之後必須**逐字**相符才算通過。(c) 在**骨架階段就已經有那一行**,
>   兩個階段都做實質比對。
> - **預期紅**:其餘每一條 law 與每一個 example——三個函式的本體全是 `undefined`。
>
> 骨架裡**沒有**任何不是 `undefined` 的本體(與 F001 的 `mkHub = Hub` 不同,本 feature 沒有
> 「定義就是那個建構子」的函式)。

## Examples

素材見「測試素材:一組固定的 vault 佈局」。`h` 是以 A, B, C, D, M, P, Z 七列(依此順序)造出
來的 `Hub`;`T/e` 上的 E **不在中樞**。

| # | 輸入 | 預期 | 覆蓋的 law |
|---|---|---|---|
| X1 | `resolveRead h Nothing` | `Right rs`;`map (vmId . vrMarker) (rsVaults rs) == [vlt-aaaa1111, vlt-bbbb2222, vlt-cccc3333, vlt-dddd4444]`(中樞順序);`rsIssues rs == [VaultMarkerBroken mEntry err, VaultPathMissing pEntry (T/gone 的正規化), VaultIdDrift zEntry (VaultId "vlt-99998888")]` | L3, L6 |
| X2 | 把當前目錄切到 `T/a/deep`,再切到 `T` 外的另一個暫存目錄,各跑一次 `resolveRead h Nothing` | 兩次結果**逐欄相同**,且與 X1 相同 | L6 |
| X3 | `resolveRead h (Just "a")` | `Right rs`;`map (vmId . vrMarker) (rsVaults rs) == [vlt-aaaa1111, vlt-bbbb2222, vlt-cccc3333]`(BFS,`A → B → C → A` 成環仍終止且不重複);`rsIssues rs == []` | L7, L20 |
| X4 | `resolveRead h (Just "vlt-aaaa1111")`(改用 id) | 與 X3 **逐欄相同** | L7 |
| X5 | `resolveRead h (Just "d")`(`refs == []`) | `Right (ReadScope [D 的 ref] [])`——恰好一個 | L7 |
| X6 | `resolveRead h (Just "nope")` | `Left (VaultSelectorNotFound "nope")`,與 `lookupSelector h "nope"` 回的逐欄相同 | L8 |
| X7 | 中樞多加兩列同名 `veName == "dup"`;`resolveRead h' (Just "dup")` | `Left (VaultSelectorAmbiguous "dup" [兩列])`,原樣透傳 | L8 |
| X8 | 把 A 的 marker `refs` 改成 `["vlt-bbbb2222", "vlt-ffff0000"]`(後者中樞查不到);`resolveRead h (Just "a")` | `rsVaults` 仍是 `[A, B, C]`;`rsIssues` 含 `RefVaultNotRegistered (VaultId "vlt-aaaa1111") (VaultId "vlt-ffff0000")` | L21 |
| X9 | `resolveRead h (Just "m")`(種子的 marker 壞) | `Right (ReadScope [] [VaultMarkerBroken mEntry err])`——仍是 `Right`,空清單 | L3, L9 |
| X10 | `resolveRead h (Just "p")`(種子路徑不存在) | `Right (ReadScope [] [VaultPathMissing pEntry (T/gone 的正規化)])` | L9 |
| X11 | `resolveRead h (Just "z")`(種子 id 漂移) | `Right (ReadScope [] [VaultIdDrift zEntry (VaultId "vlt-99998888")])`,且**不含任何 `RefVaultNotRegistered`** | L9 |
| X12 | 造一個自環 `F`(`refs = ["vlt-ffff1111"]` 指自己);`resolveRead h'' (Just "f")` | `rsVaults` 恰好一個 F,終止 | L20 |
| X13 | X8 的中樞;`resolveRead h Nothing` | `rsIssues` **不含**任何 `RefVaultNotRegistered`(無 selector 不展開 `refs`) | L5 |
| X14 | 中樞加第二列 `veId == vlt-dddd4444`、`vePath == T/d`(重複 id,以 `mkHub` 直接造);`resolveRead h''' Nothing` | `rsVaults` 裡 `vlt-dddd4444` **只出現一次**,位置是**第一列**的位置 | L1 |
| X15 | 把 A 的中樞那一列的 `veName` 改成 `"stale"`、`veKind` 改成 `StoryVault`(marker 不動);`resolveRead h (Just "vlt-aaaa1111")` | 結果與 X4 **逐欄相同**(`vrMarker` 全部來自檔案) | L2 |
| X16 | `resolveWrite h Nothing (T/a/deep/deeper)` | `Right ws`;`vmId (vrMarker (wsTarget ws)) == vlt-aaaa1111`;`map (vmId . vrMarker) (wsRead ws) == [vlt-aaaa1111, vlt-bbbb2222, vlt-cccc3333]`;`wsIssues ws == []` | L10, L11 |
| X17 | `resolveWrite h Nothing T2`(`T2` 是一個一路到根都沒有 `.aapms/` 的暫存目錄) | `Left (NoWriteTarget T2')`,`T2'` 是 `canonicalizePath T2`;`renderWorkspaceError` 的輸出含 `T2'` | L12 |
| X18 | `resolveWrite h Nothing (T/e/x)`(E 未註冊) | `Right ws`;`vrEntry (wsTarget ws) == Nothing`;`wsRead ws` 恰好一個 E | L14 |
| X19 | `resolveWrite h (Just "z") (T/a)`(selector 指到 id 漂移的 Z) | `Left (WriteTargetIdDrift (VaultId "vlt-77776666") (T/z 的正規化) (VaultId "vlt-99998888"))`;`renderWorkspaceError` 的輸出同時含 `"vlt-77776666"`、該路徑、`"vlt-99998888"` 三個值 | L13(b) |
| X20 | `resolveWrite h (Just "p") (T/a)`(中樞那列路徑不存在) | `Left (MarkerUnreadable p' (VaultMarkerMissing (Aapms.Store.Marker.configPath p')))`,`p'` 是 `T/gone` 的正規化 | L13(a) |
| X21 | `resolveWrite h (Just "m") (T/a)`(marker 壞) | `Left (MarkerUnreadable m' err)`,`err` 與直接呼叫 `readMarker m'` 的結果**逐欄相同** | L13(a) |
| X22 | `resolveWrite h Nothing (T/m/deep)`(探測命中 M,但 marker 壞) | `Left (MarkerUnreadable m' err)`——探測命中之後 marker 壞仍是**硬失敗** | L13(a) |
| X23 | `resolveWrite h (Just "b") (T/a/deep)`(起點在 A 裡,selector 指 B) | `vmId (vrMarker (wsTarget ws)) == vlt-bbbb2222`;`map (vmId . vrMarker) (wsRead ws) == [vlt-bbbb2222, vlt-cccc3333, vlt-aaaa1111]`——A 只以**唯讀**身分經 `refs` 進來,`wsTarget` 仍是 B | L10, L15, L23 |
| X24 | X23 的同一組輸入,起點改成 `T2`(不在任何 vault 內) | 與 X23 **逐欄相同** | L15 |
| X25 | X8 的 marker;`resolveWrite h (Just "a") (T/a)` | `wsIssues ws` 含 `RefVaultNotRegistered (VaultId "vlt-aaaa1111") (VaultId "vlt-ffff0000")`,且**不含**任何以 `wsTarget` 為對象的 issue | L13(c), L21 |
| X26 | `resolvePipeline h AssetVault Nothing` | `Right ps`;`map (vmId . vrMarker) (psRuns ps) == [vlt-aaaa1111, vlt-cccc3333, vlt-dddd4444]`(B 是 story,**靜默排除**);`psIssues ps` 與 X1 的 `rsIssues` **逐欄相同** | L16 |
| X27 | `resolvePipeline h StoryVault Nothing` | `psRuns` 恰好 `[B]` | L16 |
| X28 | `resolvePipeline h AssetVault (Just "a")` | `Right (PipelineScope [A 的 ref] [])`——**恰好一個**,不含 B / C(`refs` 不展開) | L17 |
| X29 | `resolvePipeline h AssetVault (Just "b")` | `Left (VaultKindMismatch (VaultId "vlt-bbbb2222") AssetVault StoryVault)`;`renderWorkspaceError` 的輸出同時含 `"vlt-bbbb2222"`、`"asset"`、`"story"` | L18 |
| X30 | `resolvePipeline h AssetVault (Just "m")` | `Right (PipelineScope [] [VaultMarkerBroken mEntry err])`——**不是** `VaultKindMismatch` | L19 |
| X31 | `resolvePipeline h AssetVault (Just "nope")` | `Left (VaultSelectorNotFound "nope")` | L8 |
| X32 | 造 11 個 kind 都是 `AssetVault` 的 vault 並全部註冊;`resolveRead h4 Nothing` 與 `resolvePipeline h4 AssetVault Nothing` | 兩者都回 `Right`,清單長度都是 11,**沒有任何錯誤**(ATTACH 上限屬 graph-core) | L24 |
| X33 | X1 / X16 / X26 三次呼叫的前後,對 `T` 遞迴列出全部檔案與內容 | 三次前後完全相同——沒有新增 `.aapms/`、沒有 `index.db`、壞掉的 M 沒有被修補 | L4 |
| X34 | 菱形 `refs`:`A → [B, C]`、`B → [D]`、`C → [D]`;`resolveRead h5 (Just "a")` | `map (vmId . vrMarker) (rsVaults rs) == [A, B, C, D]`——BFS 順序,D 只出現一次 | L1, L7, L20 |
| X35 | `refs` 指向 M(marker 壞):`A → [M]`;`resolveRead h6 (Just "a")` | `rsVaults == [A]`;`rsIssues` 含 `VaultMarkerBroken mEntry err`;把 M 的 `refs` 改成任何值結果不變(不可達的節點不展開) | L22 |
| X36 | `refs` 指向 **Z**(marker 讀得到,但 id 漂移):`A → [vlt-77776666]`,而 Z 的 marker `refs = ["vlt-dddd4444"]`;`resolveRead h7 (Just "a")` | `rsVaults == [A]`——Z 自己不進結果集,**D 也不會被展開進來**;`rsIssues` 含 `VaultIdDrift zEntry (VaultId "vlt-99998888")`。把 Z 的 `refs` 改成任何值結果逐欄不變:marker 讀得到不代表它說的話可信 | L22 |

## 依賴方向

- **依賴誰**:`Aapms.Workspace.Types`(八個型別)、`Aapms.Workspace.Hub`(`hubVaults`)、
  `Aapms.Workspace.Discovery`(四個函式)、`Aapms.Store.Marker`(`VaultMarker` 的三個欄位
  存取子)、`Aapms.Store.Schema`(`VaultKind` 型別)、`directory`(`canonicalizePath`)、
  `containers`(`Data.Set`)、`text`。
- **誰會依賴它**:`aapms-service`(P3,`Env` 要靠三個裁決函式決定開哪些 vault),目前尚未存在。
  本套件內**沒有任何模組會依賴 Scope**——它是 `Types ← Location ← Hub ← Discovery ← Scope`
  這條線的最下游,`Lifecycle` / `Projects` / `Tools` 都不經過它。
- **新增的依賴邊**(一條都不能漏):
  - `Aapms.Workspace.Scope → Aapms.Workspace.Types`(新)
  - `Aapms.Workspace.Scope → Aapms.Workspace.Hub`(新;impl 填本體時出現)
  - `Aapms.Workspace.Scope → Aapms.Workspace.Discovery`(新;impl 填本體時出現。
    **Discovery 在 `aapms-store` 之外的第一個消費者**,也是目前唯一的)
  - `Aapms.Workspace.Scope → Aapms.Store.Marker`(新;**只取三個欄位存取子,一個函式都不取**
    ——design.md「模組間公開介面」表沒有這一列,理由與 F002 的 `Discovery → aapms-store` 同一個
    :`Aapms.Workspace.Types` 對 `VaultMarker` 是裸型別 import,轉不出欄位存取子)
  - `Aapms.Workspace.Scope → Aapms.Store.Schema`(新;**只取 `VaultKind` 型別**——契約 C 的
    `resolvePipeline` 第二參數就是它,而 `Aapms.Workspace.Types` 沒有把它轉出。
    design.md「模組間公開介面」表同樣沒有這一列,**建議編排者補表**)
  - **套件層級不新增任何依賴邊**:`aapms-workspace → aapms-store` / `→ aapms-core` /
    `→ directory` / `→ containers` 在 F001 就已存在,`.cabal` 的 `build-depends` 一行不用動。
- **可否與其他進行中任務平行開發**:**不能**與 F002 平行(本 feature 的三個函式全部吃它的
  產出);**可以**與 F004(vault-lifecycle)、F005(project-registry)、F006(machine-tools)
  平行——四者的寫入白名單各是一個不同的 `.hs`,共同讀的 `Types.hs` / `Hub.hs` / `Discovery.hs`
  都只讀不寫。

## 不可逆決定

| 決定 | 被否決的替代方案與否決理由 |
|---|---|
| `resolveWrite` 的**寫入目標**兩條路都走 `readVaultRefAt`,selector 那條只是把起點路徑換成 `vePath e`,並自己補一道 id 守門,回 `WriteTargetIdDrift`(**2026-08-29 W3 閘門裁決**,A1 選 c) | **(a) selector 那條走 `readVaultRef`,再把 `ScopeIssue` 逐個翻譯成 `WorkspaceError`**:與探測那條對稱。否決理由是三個 `ScopeIssue` 裡有兩個**翻譯不出來**——`VaultPathMissing` 與 `VaultIdDrift` 都沒有 `StoreError`,而契約 F 相關的 `MarkerUnreadable` 要求一個**原件**;硬要生一個就是在 workspace 這一層**捏造 graph-core 的錯誤**,而 design.md 對 `MarkerUnreadable` 的規定原文是「訊息由 graph-core 的 `render*` 產生,這一層不翻譯」。**(b) 兩條路都走 `readVaultRefAt` 但不補 id 守門**:程式碼最短,漂移時以 marker 為準。否決理由是 design.md 契約 C 性質 1 明訂「id 不符時該 vault **不進結果集**」,而 `wsTarget` 就是結果集;使用者打 `--vault liftgame` 卻靜默寫進另一個 vault,正是 ADR-017「寫入要明確」要擋的那條路徑 |
| `refs` 展開走 **BFS**,種子排第一,visited 以「走到它時用的 `VaultId`」為鍵(**2026-08-29 W3 閘門裁決**,已寫進 design.md 契約 C 的「展開的走訪規則」) | **DFS(深度優先)**:實作略短(遞迴即可)。否決理由是 `refs` 的語意是「收窄時的**最小**讀取集合」,DFS 會把最遠的節點排在第二個,`shell` 印「作用中的 vault」時順序讀起來莫名其妙;而且無論選哪個,順序都必須是**確定的**(laws 要斷言順序),BFS 的順序對得上 marker 裡 `refs` 的書寫順序。**以 `VaultEntry` 為 visited 的鍵**:否決理由是 `VaultEntry` 沒有 `Ord`,而且 ADR-017 的身分是 marker 的 id,不是中樞那一列 |
| 不可達的節點(路徑不見 / marker 壞 / id 漂移)**不展開它自己的 `refs`**,三種一視同仁(**2026-08-29 W3 閘門裁決**,已寫進 design.md 契約 C 的「展開的走訪規則」) | **id 漂移的節點仍展開它的 `refs`**:marker 讀得到,`refs` 拿得到。否決理由是 design.md 契約 C 性質 1 的原文——「身分不確定時任何跨 vault 的 `Ref` 解析都是不確定的」;一個身分對不上的 vault 說「我引用了誰」,那句話本身就不可信 |
| `resolvePipeline` 兩條路**都不展開 `refs`** | **`Just X` 時也展開**:與 `resolveRead` 對稱。否決理由是管線的語意是「對每個 vault **各跑一次**,每次**只寫自己的索引**」,而 ADR-017 補充明訂「`refs` 展開進來的一律唯讀」——把唯讀的 vault 排進 `psRuns` 就是叫 `scan` 去寫它的索引,直接違反 |
| `resolvePipeline` 的 kind 不符在**無 selector** 時靜默排除、在**有 selector** 時硬失敗 | **無 selector 時也產生一則 `ScopeIssue`**:資訊最全。否決理由是 `ScopeIssue` 的四個建構子沒有一個表達得了「kind 不符」(要加就得動 `Types.hs`),而且那不是降級——`scan --asset` 跳過 story vault 是**正常行為**,每次都印一則警告會把真正的降級淹掉 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `workspace/src/Aapms/Workspace/Scope.hs` | 模組宣告與匯出清單(三個函式)、三條完整簽名與各自的 Haddock;本體一律 `undefined` |

**編譯狀態**:`Aapms.Workspace.Scope` **已列進 `aapms-workspace.cabal`**——library 的
`exposed-modules` 與 test-suite 的 `other-modules`(連同 `Aapms.Workspace.ScopeSpec`)都已由
**編排者**補上(D2:`.cabal` 由編排者單線維護,本 feature 不得修改)。`cabal build
aapms-workspace` 從此涵蓋本模組並通過,不再需要下面那道單檔檢查。

> **交件當下(骨架階段)的紀錄,保留備查**:那時本模組還沒進 `.cabal`,
> `cabal build aapms-workspace:lib:aapms-workspace` 回 **exit 0**(既有四個模組
> `Types` / `Location` / `Hub` / `Discovery` 仍綠),骨架另以**唯讀**方式單檔型別檢查通過
> ——在 `workspace/` 下跑
> `cabal exec -- ghc -fno-code -Wall -Wcompat -XGHC2021 -XDerivingStrategies -XLambdaCase
> -XOverloadedStrings -XRecordWildCards -XStrictData -package aapms-core -package aapms-store
> -package containers -package directory -package filepath -package toml-reader
> -hide-package text-2.1.3 -isrc -outputdir <暫存> src/Aapms/Workspace/Scope.hs`
> → `[1 of 2] Aapms.Workspace.Types` / `[2 of 2] Aapms.Workspace.Scope`,**exit 0、零警告**。
> 這道指令不寫任何檔案到專案樹,也沒有動 `.cabal`。

**W3 閘門裁決後骨架一個字未改**:`WriteTargetIdDrift` 只出現在 `resolveWrite` 的**本體**裡,
而本體是 `undefined`;三條簽名與匯出清單與交件當下逐字相同。

## TodoList

- [ ] T1: 私有 `walkAll`:依 `hubVaults` 順序對每一列跑 `readVaultRef e (vePath e)`,成功的進
  結果、失敗的進 issues;以 `vmId` 保序去重 `dep: -`
- [ ] T2: 私有 `expandRefs`:BFS 佇列帶 `(來源 VaultId, 目標 VaultId)`,`Data.Set` 的 visited
  以「走到它時用的 `VaultId`」為鍵(種子先放它的 `vmId`);中樞查不到 → `RefVaultNotRegistered`,
  `readVaultRef` 失敗 → 進 issues 且**不展開**;以 `vmId` 保序去重 `dep: -`
- [ ] T3: `resolveRead`:`Nothing` → `walkAll`;`Just s` → `lookupSelector`(失敗原樣透傳)→
  `readVaultRef` 種子(失敗 → `Right` + 空清單 + 一則 issue)→ `expandRefs` `dep: T1, T2`
- [ ] T4: `resolveWrite` 的**寫入目標**:`Nothing` → `detectVault`,沒命中就
  `canonicalizePath start` 後回 `NoWriteTarget`;命中就 `readVaultRefAt`。`Just s` →
  `lookupSelector` → `readVaultRefAt (vePath e)` → **id 守門**(`vmId /= veId e` 時回
  `WriteTargetIdDrift (veId e) (vrPath r) (vmId (vrMarker r))`) `dep: -`
- [ ] T5: `resolveWrite` 的 `wsRead`:對 `wsTarget` 跑 `expandRefs`,目標排第一;`wsIssues`
  只收 `expandRefs` 的產出 `dep: T2, T4`
- [ ] T6: `resolvePipeline`:`Nothing` → `walkAll` 後過濾 `vmKind == k`(不符不產生 issue);
  `Just s` → `lookupSelector` → `readVaultRef`(失敗 → `Right` + issue)→ kind 相符回單元素、
  不符回 `VaultKindMismatch (vmId m) k (vmKind m)` `dep: T1`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| T1 | L1, L6 / X1, X2, X14 | `test_resolve_read_all_registered_in_hub_order`、`test_resolve_read_independent_of_cwd`、`test_scope_dedupes_by_vmid_keeping_first` |
| T2 | L20, L21, L22 / X8, X12, X34, X35, X36 | `test_refs_expansion_is_transitive_and_cycle_safe`、`test_refs_self_loop_terminates`、`test_refs_diamond_bfs_order`、`test_refs_unregistered_target_degrades`、`test_unreachable_node_refs_not_expanded`、`test_id_drift_node_refs_not_expanded`(X36,W3 閘門把「id 漂移也不展開」升格為契約後補) |
| T3 | L2, L3, L5, L7, L8, L9 / X3–X5, X6, X7, X9–X11, X13, X15 | `test_resolve_read_selector_is_closure`、`test_resolve_read_selector_by_id_equals_by_name`、`test_resolve_read_selector_not_found_passthrough`、`test_resolve_read_selector_ambiguous_passthrough`、`test_resolve_read_seed_unreachable_still_right`、`test_resolve_read_no_selector_never_expands_refs`、`test_resolve_read_marker_is_truth` |
| T4 | L12, L13(a), L13(b), L14, L15 / X17–X24 | `test_resolve_write_no_target_carries_canonical_start`、`test_resolve_write_target_marker_unreadable_is_hard_error`、`test_resolve_write_id_drift_is_hard_error`(斷言 `WriteTargetIdDrift` 三個值,W3 閘門)、`test_resolve_write_unregistered_target_allowed`、`test_resolve_write_selector_ignores_start` |
| T5 | L10, L11, L13(c), L23 / X16, X23, X25 | `test_resolve_write_target_never_from_refs`、`test_resolve_write_read_starts_with_target`、`test_resolve_write_issues_never_describe_target` |
| T6 | L16, L17, L18, L19 / X26–X31 | `test_resolve_pipeline_filters_by_kind`、`test_resolve_pipeline_kind_mismatch_is_silent_without_selector`、`test_resolve_pipeline_selector_is_single_run`、`test_resolve_pipeline_kind_mismatch_carries_three_values`、`test_resolve_pipeline_unreachable_is_right` |
| (全部) | L4, L24 / X32, X33 | `test_scope_touches_no_files`、`test_scope_has_no_attach_limit` |
| (全部) | L25 (a)–(f) | `test_scope_no_downstream_or_location_imports`(a)、`test_scope_marker_import_is_three_fields_only`(b,條件式逐字比對 `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmRefs))`)、`test_scope_schema_import_is_type_only`(c,逐字比對 `import Aapms.Store.Schema (VaultKind)`,**骨架階段就實質比對**)、`test_scope_never_imports_store_internals`(d)、`test_scope_no_process_import`(e)、`test_scope_directory_import_is_canonicalize_only`(f)。**六條都只掃 import 行,比對前先去除行尾 `\r`** |

## 待確認假設

> **本段已全數裁決,保留備查。** A1 於 **2026-08-29 W3 閘門裁決成選項 c**(新增
> `WriteTargetIdDrift`),與本 spec 的暫採 a **不同**;正文的 L13(b)、X19、`resolveWrite` 的
> 資料流與收斂表都已改成 c。選項比較原文原樣留著,是為了讓後續要動這個建構子的人看得到 a / b
> 為什麼被否決。

- A1: `resolveWrite` 的**寫入目標**上出現 `ScopeIssue` 時(路徑不見 / marker 壞 / **id 漂移**),
  該回哪一個 `WorkspaceError`。契約卡沒有答案,是因為契約 F 的十六個建構子裡沒有一個是為
  「註冊表指的位置上不是使用者點名的那個 vault」寫的,而 ADR-017 又要求「寫入目標決定不了就
  硬失敗」。
  **實際只有一格待裁**:路徑不見與 marker 壞這兩種,只要讓 selector 那條路也走
  `readVaultRefAt`(而不是 `readVaultRef`),就天然回 `MarkerUnreadable` 且捧著 graph-core 的
  **原件**,零成本、無爭議(見「實作方式」的收斂表)。**剩下的是 id 漂移**——`readVaultRefAt`
  不知道使用者點名的是哪一列,表達不出這種失敗,只能由 `resolveWrite` 自己補一道守門,而那道
  守門要回什麼,契約 F 沒有現成答案。
  - 契約錨點:design.md 契約 C 的 `resolveWrite` / `WriteScope.wsTarget` 與「三個裁決的規則」
    表的 `resolveWrite` 那一列;契約 C 的第 1、2 條性質(「id 不符時該 vault 不進結果集」、
    「整個指令只在中樞載不起來或**寫入目標決定不了**時才失敗」);契約 F 的
    `NoWriteTarget FilePath` / `MarkerUnreadable FilePath StoreError` / `HubMalformed FilePath Text`;
    契約 C 的 `ScopeIssue.VaultIdDrift`;模組間公開介面表的 `Scope → Discovery`
    (`readVaultRef` / `readVaultRefAt`)。**觸及符號**:`resolveWrite`、`wsTarget`、
    `NoWriteTarget`、`MarkerUnreadable`、`VaultIdDrift`、`readVaultRefAt`、`readVaultRef`、
    `renderWorkspaceError`、`WorkspaceError`
  - 層級自答:出現在邊界上?**會**(它是 `service` 拿到的錯誤,而 `errorCode` 對照表由
    `service` 擁有——多一個或少一個建構子直接改對外 CLI / OpenAPI 的錯誤碼表);改錯驚動其他
    模組?**要**(選 c 要動已交付驗收的 `Types.hs` 與 F001 的測試)
  - 選項:
    a) **沿用 `NoWriteTarget (vrPath r)`(本 spec 暫採)**——當下成本:零,`Types.hs` 一個字
       不動,只是 `resolveWrite` 多兩行守門;`NoWriteTarget` 的語意(「寫入目標決定不了」)
       正是這件事。三個月後代價:訊息**有一句是假的**——`renderWorkspaceError` 現在的原文是
       「…從這裡向上找不到任何 .aapms 目錄,**且未指定 --vault**;請先執行 vault init,或改用
       --vault 指定寫入目標」,而這條路徑上使用者**確實指定了** `--vault`,那個目錄裡也**確實
       有** `.aapms/`。使用者拿到的路徑是對的(可以去 `ls`),但診斷方向是錯的,實際的原因
       (中樞那一列的 id 過時了,該跑 `doctor` / `syncHub` / `vault add`)一個字都沒說出來。
       這條路徑罕見但高風險——它出現的時機正是「差一點寫錯庫」的那一秒
    b) **沿用 `MarkerUnreadable (vrPath r) <自己造一個 StoreError>`**——當下成本:兩行,同樣
       不動 `Types.hs`。三個月後代價:要在 workspace 這一層**捏造一個 graph-core 的
       `StoreError`**(唯一勉強沾邊的是 `VaultMarkerInvalid fp txt`,但 marker 其實完全合法),
       而 design.md 對 `MarkerUnreadable` 的規定是「捧著 `StoreError` 而不是字串:訊息由
       graph-core 的 `render*` 產生,**這一層不翻譯**」——捏造等於把這條規矩反過來用。更糟的
       是它會讓 `renderStoreError` 的輸出說「marker 不合法」,而 marker 完全沒問題,使用者會
       去修一個沒壞的檔案。**這比 a 更誤導**
    c) **新增建構子,例如 `WriteTargetIdDrift VaultId FilePath VaultId`(中樞記的 id、目標
       路徑、marker 實際的 id)**——當下成本:**要動已交付驗收的 `Types.hs`**(+1 建構子、
       `renderWorkspaceError` +1 則訊息),而那**打破 D2「`Types.hs` 在 W1 一次寫齊,W2 之後
       沒人再碰它」的併發前提**——W4 的三個 feature 平行寫作正是建立在這條上;此外 F001 的
       驗收 law「`renderWorkspaceError` 對**每一個**建構子都回一段非空的繁中訊息」的測試要
       跟著改,等於 W1 要多跑一輪 qa,`aapms-workspace.cabal` 雖不用動但 F001 文檔要回寫。
       三個月後代價:**最小**——訊息說得出三個值與正確的下一步(「中樞說 `vlt-X` 在這裡,
       但這裡的 marker 是 `vlt-Y`;請執行 `aapms doctor` 或 `vault add` 更新中樞」),
       `service` 的 `errorCode` 表也多一格明確的碼。**注意:W3 是單 feature 波次,此刻沒有
       任何併發寫入 `Types.hs` 的風險——D2 的前提要到 W4 才真正生效,所以「現在改」比
       「W4 之後再改」便宜一個數量級**
    d) **沿用 `HubMalformed`(中樞與現實不一致,叫使用者去修中樞)**——當下成本:語意上最貼切
       (壞掉的確實是中樞那一列),`Text` 欄位還放得下三個值。**否決,不列為可選**:
       `HubMalformed` 的第一個欄位是**中樞 `config.toml` 的路徑**,而 `resolveWrite` 的簽名
       只有 `Hub`(不透明、不帶路徑),沒有 `HubLocation`——它**生不出那個路徑**。要拿到就得
       改契約 C 的三條簽名或讓 Scope 去 import `Aapms.Workspace.Location` 自己再解析一次中樞
       位置(那會讓「中樞在哪」這個事實出現第二個知道的人)。列在這裡是為了說明「為什麼不是
       它」,以及 L25(a) 為什麼要把 `Aapms.Workspace.Location` 一起禁掉
  - 傾向:**c**,但**暫採 a**。理由分兩層。**設計上 c 是對的**:a 與 b 都是把一則會誤導使用者
    的訊息留在「差一點寫錯庫」這條路徑上,而這正是 ADR-017 決策三整條規則存在的理由;訊息
    要「說出下一步該做什麼」是 system.md 全域錯誤策略第 2 條,a 說的下一步是錯的、b 說的是
    另一個檔案。**流程上 a 是此刻唯一能交付的**:委派規則明訂我不得修改 `Types.hs`,需要新
    建構子就停下該項——而 a 與 c 的**函式簽名完全相同**,差別只在 `resolveWrite` 裡那一行回
    哪個建構子,以及 `Types.hs` 有沒有那個建構子。所以裁決成 c 時,要改的只有:`Types.hs`
    (+1 建構子 +1 則訊息)、本 spec 的 L13(b) 一條、X19 一格、`Scope.hs` 一行、F001 的
    `renderWorkspaceError` 測試一處——**沒有任何 law 需要重寫,骨架一個字不用改**。
    我依賴的前提有兩個,都經查證:(i) W3 是單 feature 波次,`build-log.md` 的排程表只列
    `scope-resolution` 一項,所以此刻動 `Types.hs` 沒有併發對象;(ii) F001 的 `Types.hs`
    現有十六個建構子,`renderWorkspaceError` 是一個 `\case` 全覆蓋,加一格不會讓既有訊息
    改變(不是「加一層 wrapper 就好」那種未經論證的假設——我讀過那個函式的全文)。
    可逆性:**可逆**(a → c 的成本如上;c → a 則是刪一個建構子,同樣小)。**但這個可逆性
    有保存期限**:F004(`vault-lifecycle`)的 `syncHub` 會處理同一種漂移、`service` 的
    `errorCode` 表要為每個建構子配碼——等那兩件事落地,改建構子就變成三個子系統的連帶修改
  - 暫採:a(`Left (NoWriteTarget (vrPath r))`)→ 影響:若裁決成 c,改 `Types.hs`
    (+`WriteTargetIdDrift VaultId FilePath VaultId` 與它的繁中訊息)、本 spec 的 L13(b)、
    X19、1-to-1 表裡 `test_resolve_write_id_drift_is_hard_error` 那一格的預期值,以及 F001
    文檔裡「`renderWorkspaceError` 的全部建構子」那條 law 的計數;若裁決成 b,只改 L13(b)
    與 X19,但要在 spec 明寫「這裡的 `StoreError` 是本層合成的,不是 graph-core 的原件」
    ——那會是一條與 design.md 契約 F 原文衝突的例外,建議一併回寫 design.md
  - **裁決(2026-08-29 W3 閘門):選 c**。`design.md` 契約 F 已新增
    `WriteTargetIdDrift VaultId FilePath VaultId`(註冊表記的 id、路徑、marker 實際的 id),
    並寫明它與 `ScopeIssue.VaultIdDrift` 是同一件事的兩種身分、訊息要說出
    `vault check` / `syncHub` / 重新 `vault add`。開發者採納了「W3 是單 feature 波次、此刻
    沒有併發對象,現在改比 W4 之後便宜一個數量級」這條論證。**宣告與訊息由 F001 的 impl 加進
    `Types.hs`、F001 的 qa 補那一格斷言;本 feature 不碰那個檔**,只在 `resolveWrite` 的 id
    守門產生它。本 spec 實際改動:L13(b)、X19、`resolveWrite` 資料流、收斂表、TodoList T4、
    1-to-1 表 T4 那一格——**law 總數不變(25 條)、X19 只換預期值,骨架一個字不改**

## 實作備註

### 2026-08-29 W3 閘門裁決(兩條)

**裁決一(本 spec 的 A1)——選 c,契約 F 新增 `WriteTargetIdDrift VaultId FilePath VaultId`。**
`resolveWrite` 的 selector 路徑在「註冊表記的 `veId` 與目標 marker 的 `vmId` 不符」時回它,
三個值依序是註冊表記的 id、目標路徑、marker 裡實際的 id。被否決的 a(`NoWriteTarget`)與
b(`MarkerUnreadable` + 自造 `StoreError`)都會說謊,理由見 A1 原文與 design.md 契約 F 的
新增段。**型別宣告與繁中訊息由 F001 的 impl 加進 `Types.hs`,不在本 feature 的寫入白名單**;
本 feature 是它唯一的產生點。改動落在 L13(b)、X19、`resolveWrite` 的資料流與收斂表、
TodoList T4、1-to-1 表 T4 那一格,**骨架 `Scope.hs` 一個字未改**(簽名相同,新建構子只出現在
`undefined` 的本體裡)。

**裁決二——`refs` 展開的走訪規則升格為 Level 2 契約。** design.md 契約 C 新增「展開的走訪
規則」段,四條:(1) 不可達的節點不展開它自己的 `refs`,**三種不可達一視同仁,包含 id 漂移**;
(2) 走訪是 **BFS,種子排第一**;(3) 同一個未註冊的 `refs` 目標只產生一則
`RefVaultNotRegistered`,`src` 取 BFS 序最早;(4) `resolvePipeline (Just X)` 而 X 不可達時回
`Right (PipelineScope [] [issue])`,**不是** `VaultKindMismatch`。四條與本 spec 交件時的行為
**完全一致**,所以 law 的**條數與判準**(L7 / L19 / L20 / L21 / L22)都沒變;本次只把它們在
「三個函式的資料流」與相關 law 裡的**出處**從「自裁」改成 design.md 契約 C 的引用、把「三種
不可達一視同仁(含 id 漂移)」與「BFS 種子排第一」從散文提升成 law 條文裡的明文,並在
「不可逆決定」表標註閘門日期。**唯一新增的是 X36**:裁決一把「id 漂移的節點也不展開它的
`refs`」明確化之後,原本只有 X35(marker 壞)這一路被覆蓋,「marker 讀得到但不採信」那一路
沒有 example——那正是這條契約最容易被實作反過來寫的一格。Examples 因此由 35 條增為 **36 條**。

**編排者的升級篩結果**:本 spec 交件時列的九條自裁(S1、S2、S4、S5、S6、S7、S8、S9、S10)
全部被判為**契約層級**——它們的「層級自答」欄自己寫著「邊界:會」,依 `boundary-rules.md` 就
不該進自裁清單。其中 S2 / S4 / S5 / S9 即裁決二的四條,已升格進 design.md 契約 C;
S1(`NoWriteTarget` 帶正規化後的起點)、S6(無 selector 時 kind 不符靜默排除)、
S7(`resolvePipeline` 兩條路都不展開 `refs`)、S8(`VaultKindMismatch` 取 `vmId` 不取 `veId`)、
S10(以 `vmId` 保序去重、保留首次出現位置)沿用既有裁決,條文不動。本 spec 正文自此**不再
引用任何「自裁 Sx」編號**,每一條都指得到 design.md 或 ADR 的原文。
