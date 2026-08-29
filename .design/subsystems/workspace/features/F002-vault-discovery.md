---
id: F002
type: feature
title: vault-discovery
description: "向上探測 .aapms/、selector 解析、重讀 marker 取權威身分、不可達降級"
status: open
created: 2026-08-29
updated: 2026-08-29
depends-on: [F001]
related-adr: [ADR-008, ADR-014, ADR-017]
related-feature: []
---

# F002: 向上探測、selector 解析、重讀 marker(vault-discovery)

## 功能概述

實作 `workspace` 裁決管線的**第三、四步**:selector 解析或向上探測(「這個字串 / 這個目錄
指的是哪個 vault」)→ 重讀該 vault 的 marker 取權威身分。負責模組是 design.md「內部模組劃分」
的 **Discovery**,只寫一個檔案 `workspace/src/Aapms/Workspace/Discovery.hs`。

本 feature 是契約 C 的 `VaultRef` / `ScopeIssue` 兩個型別的**第一個生產者**——型別本身已由 F001
一次寫齊在 `Aapms.Workspace.Types`,本 feature **不新增、不修改任何型別與任何 `WorkspaceError`
建構子**。

**驗收標準**(逐字抄自契約卡):

1. `detectVault` 從一個位於 vault 內任意深度的子目錄出發,回傳**含 `.aapms/` 的那一層**的絕對
   路徑;從 vault 外任何目錄出發(一路到檔案系統根都沒有 marker)回 `Nothing` — 觀察點:契約 C
   的 `detectVault`
2. `lookupSelector` 先比 `veId` 的完整字串再比 `veName`:當某字串同時是甲的 id 與乙的 name 時,
   回甲 — 觀察點:契約 C 的 `lookupSelector`
3. 兩列 `VaultEntry` 同名時以該名稱查回 `VaultSelectorAmbiguous`,且其清單**含全部**撞名的列 —
   觀察點:契約 C 的 `lookupSelector`、契約 F 的 `VaultSelectorAmbiguous`
4. `readVaultRef` 回傳的 `vrMarker` 一律來自檔案:把中樞的 `veName` / `veKind` 改成與 marker
   不同的值後重跑,`vrMarker` 不變 — 觀察點:模組間公開介面的 `readVaultRef`、契約 C 的 `VaultRef`
5. 路徑不存在 → `VaultPathMissing`;路徑在但 marker 解不開 → `VaultMarkerBroken` 且捧著
   graph-core 的 `StoreError` 原件;marker 的 id 與中樞不符 → `VaultIdDrift` 帶兩個 id —
   觀察點:契約 C 的 `ScopeIssue`

**明確不做**(逐字抄自契約卡):不做 `refs` 展開、不決定範圍(那是 #3);不開索引;marker 的
**寫入**不在這裡(#4)。

追加兩條由「明確不做」推出來的硬界線:**本 feature 不建立、不修改、不刪除任何檔案或目錄**
(連 `.aapms/` 都不建),也**不執行任何外部程式**(那是 #6)。兩者都寫成可機械驗證的條文
(L4、L12、L17)。

## 相依性

`depends-on: [F001]`——design.md「功能規劃」階段一表 #2 的「依賴」欄是 `#1`,而查證後確實逐條
用到 F001 交付的東西:`Hub` / `VaultEntry` / `VaultRef` / `ScopeIssue` / `WorkspaceError` 五個
型別、`hubVaults` 一個 getter。#3(scope-resolution)反過來依賴本 feature 的四個函式。

跨子系統:`graph-core` 九個 feature 全數 `done`,本 feature 用到的五個符號
(`readMarker` / `markerDir` / `VaultMarker` / `StoreError` / `VaultId`)都已交付,簽名逐一開
原始碼查證過,見「使用到的既有串接介面」。

**不需要新增任何套件依賴**:`aapms-workspace.cabal` 現有的 `base` / `containers` / `directory` /
`filepath` / `text` / `time` / `toml-reader` / `aapms-core` / `aapms-store` 覆蓋本 feature 全部
所需。

## 對應的 Level 2 契約

### 契約 C(本 feature 負責的四項)

```haskell
data VaultRef = VaultRef
  { vrEntry  :: Maybe VaultEntry     -- 中樞裡的那一列;未註冊的 vault 為 Nothing
  , vrPath   :: FilePath             -- 絕對路徑,已正規化
  , vrMarker :: VaultMarker }        -- 權威的 id / kind / name / refs

data ScopeIssue
  = VaultPathMissing      VaultEntry FilePath
  | VaultMarkerBroken     VaultEntry StoreError
  | VaultIdDrift          VaultEntry VaultId
  | RefVaultNotRegistered VaultId VaultId          -- 本 feature 不產生(refs 展開屬 #3)

detectVault    :: FilePath -> IO (Maybe FilePath)
lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry
```

兩個型別**已由 F001 宣告完畢**(`Types.hs:163-184`),本 feature 一個字都不改;`RefVaultNotRegistered`
是 #3 的 `refs` 展開才產生得出來的建構子,本 feature 不碰。

### 契約 F(本 feature 負責的三個建構子)

`VaultSelectorNotFound Text` / `VaultSelectorAmbiguous Text [VaultEntry]` / `MarkerUnreadable FilePath StoreError`。
三者的**宣告與繁中訊息**都已在 F001 交付(`Types.hs:299-324`、`renderWorkspaceError`),本 feature
是它們的**第一個生產者**,不改 `renderWorkspaceError` 一個字。

### 模組間公開介面(design.md「模組間公開介面」的 `Scope → Discovery` 那一列)

```haskell
readVaultRef :: Maybe VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)
```

> **本 spec 對這一列的偏離(見「待確認假設」A1)**:這個簽名**表達不出**「未註冊的 vault 讀不到
> marker」——`ScopeIssue` 的三個相關建構子(`VaultPathMissing` / `VaultMarkerBroken` /
> `VaultIdDrift`)**都要求一列 `VaultEntry`**,而第一參數為 `Nothing` 時沒有那一列可捧。這是
> design.md 內部兩處的矛盾(模組間介面表 vs 契約 C 的 `ScopeIssue`),不是契約卡漏寫。
>
> 本 spec 以**對外契約 C 為準**(它是契約本體,模組間介面表是內部佈線),把這一列拆成兩個函式:
>
> ```haskell
> readVaultRef   :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)   -- 已註冊的那一列
> readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)      -- 只知道路徑
> ```
>
> `readVaultRefAt` 同時是契約卡指給本 feature 的 `MarkerUnreadable` 的**唯一生產者**——沒有它,
> 契約卡列的那個建構子在本 feature 裡沒有任何地方生得出來。契約 C 的 `VaultRef` / `ScopeIssue`
> 與 `Types.hs` **一個字都沒動**。

## 實作方式

### 相依性查證(2026-08-29 打開 `store/src/`、`core/src/` 與 `workspace/src/` 讀到的實況)

五點與文字描述不同、必須在實作前知道的事實:

1. **`readMarker` 吃的是 vault 根目錄,不是 `.aapms/` 目錄**
   (`store/src/Aapms/Store/Marker.hs:85-93`):它自己算 `configPath root = markerDir root </>
   "config.toml"`。所以 `readVaultRef` / `readVaultRefAt` 傳進去的是**正規化後的 vault 根**,
   而 `VaultMarkerMissing` / `VaultMarkerInvalid` 帶回來的路徑就是那個根加上 `.aapms\config.toml`
   ——測試要斷言那個值時照著算,不要自己另拼一份。
2. **`readMarker` 不做絕對化**(同上;`openVault` 才先 `makeAbsolute`)。正規化因此是本模組的
   責任,不能指望被呼叫端做掉。
3. **`.aapms` 這個目錄名的唯一真相是 `markerDir :: FilePath -> FilePath`**
   (`Marker.hs:46-47`,`root </> ".aapms"`)。`detectVault` 用它,不在 workspace 再寫一份
   `".aapms"` 字面值(知識歸屬:同一個事實只能有一個地方知道)。
4. **`Aapms.Store.Marker.configPath`(vault 的)與 `Aapms.Workspace.Location.configPath`
   (中樞的)同名不同義**(F001 查證留下的事實 1)。本 feature **兩個都不 import**:`readMarker`
   自己算 vault 的那一份,而中樞的檔案位置與 Discovery 無關——所以本檔沒有 qualified import
   的需要,也不該有。
5. **`StoreError` 與 `WorkspaceError` 有 `VaultAlreadyInitialized` / `VaultIdCollision` 兩對同名
   建構子**(F001 查證留下的事實 3)。本 feature **不 import 任何一邊的建構子**:`StoreError`
   只被原樣塞進 `VaultMarkerBroken` / `MarkerUnreadable`,一次都不需要 pattern match,所以撞名
   在本檔不會發生。

程式碼知識圖(knot)另外查到一件影響架構的事:目前**只有 `Aapms.Store.Marker.openVault` 呼叫
`readMarker`**(`knot query reachable Aapms.Store.Marker.readMarker --reverse --depth 2`,回 9 個
節點全在 `aapms-store` 內)。本 feature 因此是 `readMarker` 在 `aapms-store` **之外的第一個消費者**
——這條新的依賴邊已逐條列進「依賴方向」。

### 「正規化」在本 spec 全篇的定義

> **正規化 = `System.Directory.canonicalizePath`。**

選它而不是 `makeAbsolute` 的理由有兩條,都與可測性直接相關:

- `makeAbsolute` **不解 `..`**。向上探測必須在解掉 `..` 之後才算得出「上一層」,否則從
  `<vault>/a/b/..` 出發會多走一層。
- 兩邊要**逐字比較**。測試會把 `detectVault` 的回傳值與自己造的 fixture 路徑比對,而 Windows 的
  暫存目錄常帶 8.3 短檔名(`C:\Users\User\AppData\Local\Temp\...` vs `C:\Users\User\AppDa~1\...`)
  ——`canonicalizePath` 兩邊都還原成同一個寫法,`makeAbsolute` 不會。

2026-08-29 在本機(GHC 9.14.1 / Windows)實測確認的三件事,實作與測試都可以依賴:

| 輸入 | `canonicalizePath` 的輸出 |
|---|---|
| `C:/…/story-flow/nope/../workspace/./no-such-dir/x`(路徑不存在) | `C:\…\story-flow\workspace\no-such-dir\x`——**不拋例外**,`.` / `..` 照樣解掉 |
| `.` | 當前目錄的絕對路徑 |
| `C:/` | `C:\` |

`System.FilePath.takeDirectory` 在磁碟機根是**不動點**(`takeDirectory "C:/" == "C:/"`,同日實測),
所以「走到檔案系統根」的終止條件就是 `takeDirectory p == p`,不需要平台分支。

### 四個函式的資料流

```text
detectVault start
  → canonicalizePath start                       -- 先解 . / ..,之後才算得出「上一層」
  → 逐層往上:doesDirectoryExist (markerDir d)
       True  → Just d                            -- 最近的那一層,不繼續往上
       False → d' = takeDirectory d
                 d' == d → Nothing               -- 到根了
                 否則    → 換 d' 再來一次
  -- 不讀 marker、不判斷它合不合法;.aapms 是普通檔案時不算命中

lookupSelector hub s
  → byId   = [e | e <- hubVaults hub, veId e == VaultId s]      -- 逐字精確比對
      length == 1 → Right e
      length >= 2 → Left (VaultSelectorAmbiguous s byId)
      length == 0 → 往下一階段
  → byName = [e | e <- hubVaults hub, veName e == s]
      length == 1 → Right e
      length >= 2 → Left (VaultSelectorAmbiguous s byName)
      length == 0 → Left (VaultSelectorNotFound s)
  -- 純函式;不讀檔、不碰 [[projects]] / [llm] / [tools]

readVaultRef e p                                  -- 中樞裡有這一列
  → p' = canonicalizePath p
  → doesDirectoryExist p' == False → Left (VaultPathMissing e p')
  → readMarker p'
      Left err → Left (VaultMarkerBroken e err)   -- 原件,不翻譯、不轉字串
  → vmId m /= veId e → Left (VaultIdDrift e (vmId m))
  → Right (VaultRef (Just e) p' m)

readVaultRefAt hub p                              -- 只知道路徑(向上探測的結果)
  → p' = canonicalizePath p
  → readMarker p'
      Left err → Left (MarkerUnreadable p' err)   -- 硬失敗:寫入目標決定不了
  → Right (VaultRef (find ((== vmId m) . veId) (hubVaults hub)) p' m)
  -- 身分就是 marker 的 id(ADR-017),路徑不參與中樞比對
```

`readVaultRefAt` 的失敗是**硬失敗**而不是降級,理由在 design.md 契約 C 的第 2 條性質:
「整個指令只在**連中樞都載不起來**或**寫入目標決定不了**時才失敗」。降級只放過查詢範圍裡的
個別 vault;決定不了寫入目標時,使用者需要的是一則說得出下一步的錯誤,不是一條靜默少掉的路徑。

`readVaultRefAt` 不先 `doesDirectoryExist`:路徑不存在時 `readMarker` 本來就回
`VaultMarkerMissing`,多一次判斷只會把同一件事分成兩個建構子,而契約 F 只給了 `MarkerUnreadable`
一個。`readVaultRef` 則必須先判斷——契約 C 的 `VaultPathMissing` 與 `VaultMarkerBroken` 是**兩個
不同的降級**,`doctor` 的訊息也不一樣(「路徑搬走了」vs「marker 壞了」)。

## 使用到的既有串接介面

行號是**建檔當下**的導航線索;一致性檢查一律比對**簽名原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `readMarker :: FilePath -> IO (Either StoreError VaultMarker)` | `store/src/Aapms/Store/Marker.hs:85-93` | graph-core F005 | 重讀權威身分;失敗原樣捧進 `VaultMarkerBroken` / `MarkerUnreadable` |
| `markerDir :: FilePath -> FilePath`(`root </> ".aapms"`) | `store/src/Aapms/Store/Marker.hs:46-47` | graph-core F005 | `detectVault` 的命中判準;`.aapms` 這個名字的唯一真相 |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57-63` | graph-core F005 | `vrMarker` 的型別;`vmId` 供漂移比對與中樞反查 |
| `configPath :: FilePath -> FilePath`(**vault 的**,`markerDir root </> "config.toml"`) | `store/src/Aapms/Store/Marker.hs:49-50` | graph-core F005 | **本 feature 不 import**;列出是因為 `VaultMarkerMissing` 帶的路徑就是它算出來的(測試斷言要用),且它與 `Aapms.Workspace.Location.configPath` 同名不同義 |
| `data StoreError`(26 個建構子,含 `VaultMarkerMissing FilePath` / `VaultMarkerInvalid FilePath Text`) | `store/src/Aapms/Store/Error.hs:29-83` | graph-core F005/F008 | `VaultMarkerBroken` 與 `MarkerUnreadable` 捧著的原件 |
| `renderStoreError :: StoreError -> Text` | `store/src/Aapms/Store/Error.hs:91` | graph-core F005 | **本 feature 不呼叫**;`MarkerUnreadable` 的訊息由 F001 的 `renderWorkspaceError` 轉呼叫它,這一層不翻譯 |
| `newtype VaultId = VaultId Text`(建構子匯出) | `core/src/Aapms/Core/Id.hs:146-150` | graph-core F001 | selector 比 id、marker 與中樞的 id 比對 |
| `data Hub`(不透明)、`mkHub`、`hubSourceText` | `workspace/src/Aapms/Workspace/Types.hs:91-117` | F001 | `lookupSelector` / `readVaultRefAt` 的第一參數;測試造 `Hub` 走 `mkHub` |
| `hubVaults :: Hub -> [VaultEntry]` | `workspace/src/Aapms/Workspace/Types.hs:92`(定義)、`Hub.hs:19`(轉出) | F001 | selector 與中樞反查的候選清單 |
| `data VaultEntry = VaultEntry { veId :: VaultId, veName :: Text, veKind :: VaultKind, vePath :: FilePath }` | `workspace/src/Aapms/Workspace/Types.hs:123-133` | F001 | 中樞的一列 |
| `data VaultRef = VaultRef { vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }` | `workspace/src/Aapms/Workspace/Types.hs:163-171` | F001 | 本 feature 的產出型別 |
| `data ScopeIssue`(四個建構子) | `workspace/src/Aapms/Workspace/Types.hs:174-184` | F001 | `readVaultRef` 的降級通道(本 feature 產生前三個) |
| `data WorkspaceError`(十六個建構子) | `workspace/src/Aapms/Workspace/Types.hs:289-324` | F001 | `lookupSelector` 與 `readVaultRefAt` 的失敗通道(本 feature 產生三個) |
| `canonicalizePath :: FilePath -> IO FilePath`、`doesDirectoryExist :: FilePath -> IO Bool` | `directory` 的 `System.Directory` | - | 正規化;`.aapms` 是否為既存目錄、vault 根是否存在 |
| `takeDirectory :: FilePath -> FilePath` | `filepath` 的 `System.FilePath` | - | 向上探測的「上一層」,不動點即檔案系統根 |

## 新增的介面

全部四條都在 `workspace/src/Aapms/Workspace/Discovery.hs`(本 feature 唯一寫入的 `.hs`)。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `detectVault :: FilePath -> IO (Maybe FilePath)` | 從給定目錄逐層往上,回最近一層含 `.aapms/` 目錄的絕對路徑;到檔案系統根仍沒有回 `Nothing` | `workspace/src/Aapms/Workspace/Discovery.hs:47` |
| `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | 把 `--vault` 的字串解析成中樞裡的一列:先比 id 再比 name,撞名回全部候選 | `workspace/src/Aapms/Workspace/Discovery.hs:63` |
| `readVaultRef :: VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)` | 中樞的一列 + 它指的路徑 → 權威身分;路徑不見 / marker 壞 / id 漂移各自降級成一則 `ScopeIssue` | `workspace/src/Aapms/Workspace/Discovery.hs:86` |
| `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)` | 只知道路徑時的權威身分:讀 marker 取 id,再回中樞反查決定 `vrEntry`;讀不到就是硬失敗 | `workspace/src/Aapms/Workspace/Discovery.hs:100` |

模組匯出清單只有這四個函式;型別一律讓消費端從 `Aapms.Workspace.Types` 取,本模組**不轉出**
任何型別(理由見「實作備註」S5)。

## 數據

本 feature **不新增、不修改、不刪除任何型別**。

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `VaultRef` | 沿用(F001 宣告) | `{ vrEntry :: Maybe VaultEntry, vrPath :: FilePath, vrMarker :: VaultMarker }` | 「這個路徑上的 vault 現在的權威身分是什麼、它在不在中樞」 |
| `ScopeIssue` | 沿用(F001 宣告) | 四個建構子,本 feature 產生前三個 | 「一個候選 vault 為什麼進不了結果集」 |
| `WorkspaceError` | 沿用(F001 宣告) | 十六個建構子,本 feature 產生三個 | 「這個子系統會有哪些失敗」(Types 擁有,不是 Discovery) |

**vault 的身分不屬於本模組**(design.md「內部模組劃分」):`id` / `kind` / `name` / `refs` 屬各
vault 的 marker;中樞存的是快取,Discovery 每次重讀真相。Discovery 擁有的唯一事實是
**「這個字串 / 這個目錄指的是哪個 vault」**。

### 測試素材:vault marker 的檔案格式

`<vault 根>/.aapms/config.toml`(graph-core `initVaultAt` 寫出來的形狀;`refs` 選填,缺席即空):

```toml
id   = "vlt-7f3b2a91"
kind = "asset"
name = "alchbees-assets"
refs = []
```

三種造得出來的壞 marker,對應 `readMarker` 的兩個 `StoreError`:

| 造法 | `readMarker` 回 |
|---|---|
| `<root>/.aapms/` 目錄在,但沒有 `config.toml` | `VaultMarkerMissing (<root>/.aapms/config.toml)` |
| `config.toml` 內容是 `id   = "vlt-` (TOML 語法錯) | `VaultMarkerInvalid fp _` |
| `config.toml` 的 `kind = "media"` | `VaultMarkerInvalid fp _` |

`parseId` 接受 1–8 位小寫十六進位,所以 `vlt-aaaa1111` / `vlt-7f3b2a91` 都是合法 id。

### 中樞素材

`Hub` 是不透明型別,測試造它走 `mkHub vs ps llm tools txt`(F001 的唯一建構入口)。本 feature
只讀 `hubVaults`,所以 `ps` / `llm` / `tools` / `txt` 填什麼都不影響結果(L8 就在驗這件事)。

## Laws

### 向上探測

- **L1(命中的是最近的那一層)**:對任意目錄 `d`,若 `detectVault d == Just p`,則同時成立:
  (a) `p` 是絕對路徑且不含 `.` / `..` 片段;(b) `p </> ".aapms"` 是**既存目錄**;
  (c) `p` 是「`d` 正規化後的路徑」的祖先或它自己;(d) 從 `d` 正規化後的路徑往上到 `p` **之前**
  的每一層,`.aapms` 都不是既存目錄(所以命中的是**最近**的那一層,不是最外面那一層)。
- **L2(到根仍沒有就是 `Nothing`,而且一定終止)**:若從 `d` 正規化後往上逐層檢查,一路到
  `takeDirectory p == p` 的那一層都沒有任何一層的 `.aapms` 是既存目錄,則 `detectVault d ==
  Nothing`;且對任意輸入 `detectVault` 都會終止(往上走的層數有限,終止條件是 `takeDirectory`
  的不動點)。
- **L3(自身也算、深度不敏感)**:若 `detectVault d == Just p`,則 `detectVault p == Just p`
  (起點那一層自己也算命中);且對 `p` 底下任意深度、中間沒有其他 `.aapms/` 目錄的子目錄 `d'`,
  `detectVault d' == Just p`——**與深度無關**。
- **L4(`detectVault` 不動檔案系統)**:對任意 `d`,呼叫前後從 `p`(或找不到時從 `d`)往上的
  整棵目錄樹的檔案清單與內容**逐位元組相同**;特別是**不會建立** `.aapms/`。
- **L5(`.aapms` 必須是目錄)**:若某一層的 `.aapms` 是普通**檔案**而不是目錄,該層不算命中,
  探測繼續往上——對任意 `d`,把 `d` 某個祖先的 `.aapms` 目錄換成同名檔案後,`detectVault d`
  的結果等於「那一層不存在時」的結果。

### selector 解析

- **L6(兩階段,id 絕對優先)**:對任意 `Hub h` 與任意 `s`,令
  `byId = filter ((== VaultId s) . veId) (hubVaults h)`、
  `byName = filter ((== s) . veName) (hubVaults h)`。`byId` 非空時,`lookupSelector h s` 的結果
  **只由 `byId` 決定**——把 `byName` 那些列的 `veName` 任意換掉,結果不變。
- **L7(命中集合 → 結果,兩階段同一套規則)**:令 `E` 是實際生效的那個命中集合(`byId` 非空時
  是它,否則是 `byName`)。`length E == 1` → `Right (head E)`;`length E >= 2` →
  `Left (VaultSelectorAmbiguous s E)`,且第二個欄位**逐列等於 `E`**(含全部撞名的列、順序同
  `hubVaults`);兩個集合都空 → `Left (VaultSelectorNotFound s)`。
- **L8(逐字精確比對)**:`lookupSelector` 不去前後空白、不忽略大小寫、不做前綴或子字串比對。
  對任意 `e` 與任意 `s`,若 `s` 既不逐字等於 `veId e` 的字串、也不逐字等於 `veName e`,則 `e`
  不出現在結果裡(不論是 `Right` 的那一列還是 `VaultSelectorAmbiguous` 的清單)。
- **L9(只看 `[[vaults]]`)**:對任意 `h`、`s`,`lookupSelector h s` 的結果只由 `hubVaults h`
  決定——用 `mkHub` 把 `hubProjects` / `hubLlm` / `hubTools` / `hubSourceText` 換成任何其他值,
  結果逐欄不變。且 `lookupSelector` 是純函式(不讀檔案、不看當前目錄)。

### 重讀 marker

- **L10(marker 是真相)**:對任意 `VaultEntry e` 與任意 marker 讀得到且 `vmId` 等於 `veId e`
  的 vault 根 `p`,`readVaultRef e p` 成功,且 `vrMarker` 逐欄等於直接對 `p` 呼叫 `readMarker`
  的結果。把 `e` 的 `veName` / `veKind` 換成與 marker **不同**的任何值後重跑,`vrMarker`
  **逐欄不變**(中樞是快取,不是真相)。
- **L11(成功時的三個欄位)**:承 L10,成功時 `vrEntry == Just e`、`vrPath == p 的正規化`、
  `vmId (vrMarker r) == veId e`。
- **L12(三種降級互斥且依序判定)**:對任意 `e` 與任意 `p`——
  (a) `p` 不是既存目錄 → `Left (VaultPathMissing e p')`,`p'` 是 `p` 的正規化;
  (b) `p` 是既存目錄但 `readMarker p'` 回 `Left err` → `Left (VaultMarkerBroken e err)`,
  且 `err` 與 `readMarker p'` 回的**逐欄相同**(原件,不轉字串、不翻譯);
  (c) marker 讀得到但 `vmId m /= veId e` → `Left (VaultIdDrift e (vmId m))`——第二個欄位是
  **marker 裡的** id,`e` 自己帶著中樞記的那一個。
  三者不可能同時成立,且判定順序恒為 (a) → (b) → (c)。
- **L13(`readVaultRef` 不動檔案系統)**:對任意 `e`、`p`,呼叫前後 `p` 底下的整棵目錄樹逐位元組
  相同——特別是 marker 讀不到時**不會被建立或修補**。
- **L14(`readVaultRefAt` 的身分回填)**:對任意 `Hub h` 與 marker 讀得到的 `p`,
  `readVaultRefAt h p` 回 `Right r`,且 `vrPath r == p 的正規化`、`vrMarker r` 逐欄等於
  `readMarker` 的結果;`vrEntry r == Just e` 當且僅當 `hubVaults h` 裡**第一列**滿足
  `veId e == vmId (vrMarker r)` 的是 `e`,一列都沒有時 `vrEntry r == Nothing`。
  **比對只看 id,不看路徑**(ADR-017:vault 的身分就是 marker 裡的 id)。
- **L15(`readVaultRefAt` 的失敗一律是 `MarkerUnreadable`)**:對任意 `h` 與任意 `p`,若
  `readMarker (p 的正規化)` 回 `Left err`(路徑不存在與 marker 壞掉都走這一條),則
  `readVaultRefAt h p == Left (MarkerUnreadable (p 的正規化) err)`,`err` 是原件;而且
  `renderWorkspaceError` 對它的輸出含**該路徑**與 `renderStoreError err`。
- **L16(兩個函式對同一個 vault 一致)**:對任意 `h`、`p`——若 `readVaultRefAt h p == Right r`
  且 `vrEntry r == Just e`,則 `readVaultRef e p == Right r`(**逐欄相同**);若
  `readVaultRefAt h p == Left (MarkerUnreadable _ err)` 且 `p` 是既存目錄,則對任意 `e`,
  `readVaultRef e p == Left (VaultMarkerBroken e err)`——同一個 `err` 原件。
- **L17(不展開 `refs`)**:對任意 marker,`vmRefs (vrMarker r)` 逐項等於檔案裡 `refs` 的內容
  (原樣捧著);且不論 `refs` 有幾項、指向誰,`readVaultRef` / `readVaultRefAt` 的回傳都恰好
  描述**一個** vault,`vrEntry` / `vrPath` 完全不受 `refs` 影響,也不產生任何
  `RefVaultNotRegistered`(那是 #3)。

### 依賴方向與職責界線

- **L18(以 import 行驗證;**比對前先去除行尾 `\r`**)**:專案的 `core.autocrlf = true` 讓 `.hs`
  在乾淨 checkout 上是 CRLF,逐字比對前必須先把行尾的 `\r` 去掉(W1 的 L17(d) 就是漏了這條,
  在乾淨 checkout 上紅了一輪)。`Discovery.hs` 的 **import 行**滿足:
  - (a) 沒有任何 `import Aapms.Workspace.Location` / `Aapms.Workspace.Scope` /
    `Aapms.Workspace.Lifecycle` / `Aapms.Workspace.Projects` / `Aapms.Workspace.Tools` 的行——
    方向是 `Types ← Location ← Hub ← Discovery ← Scope`,Discovery 不得回頭、也不得往下游拿東西。
    本套件內允許的 import 只有 `Aapms.Workspace.Types` 與 `Aapms.Workspace.Hub`。
  - (b) **若**有對 `Aapms.Store.Marker` 的 import 行,它**必須逐字是**
    `import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)`。
    **這條 law 守的是「Discovery 只讀 id」,不是單純的 import 衛生**:清單放行的欄位存取子
    只有 `vmId` 一個,所以日後有人在本模組碰 `vmRefs`(`refs` 展開是 #3 的事)或 `vmKind`
    (kind 過濾同樣是 #3、`syncHub` 是 #4),編譯得過但**這條會紅**——界線因此守得住,而不是
    只寫在 Haddock 裡。同理,只要清單長出 `initVaultAt` / `openVault` / `closeVault` /
    `configPath` / `indexDbPath` / `VaultHandle` 任何一個,或被放寬成 `VaultMarker (..)`,
    這條就紅——marker 的**寫入**、索引的開關與**中樞/vault 同名的 `configPath`** 都不在本
    feature。
    (寫成條件式是因為骨架階段的簽名用不到這三個名字,留著會有 `-Wall` 的 redundant import
    警告;impl 填本體時才會出現這一行。`vmId` 必須逐字列出的理由:`Aapms.Store.Marker` 的
    匯出是 `VaultMarker (..)`,但 `Aapms.Workspace.Types:65` 對它的 import 是裸型別
    `(VaultMarker)`——F001 的 L17(d) 釘死——**轉不出欄位存取子**,而本 spec 的 L12(c) 與 L14
    都要求用 `vmId` 做 id 比對。`vmId` 只能從本模組自己的這一行拿。
    2026-08-29 閘門裁決,修訂本條原文的 `(markerDir, readMarker)`,見「實作備註」。)
  - (c) **完全不得** import `Aapms.Store.Atomic`——本 feature 不寫任何檔案。
  - (d) **完全不得** import `Aapms.Store`(門面)、`Aapms.Store.Schema`、`Aapms.Store.Index`、
    `Aapms.Store.MultiVault`、`Aapms.Store.Query`、`Aapms.Store.Write`、`Aapms.Store.Create`
    ——不開索引、不查內容、不寫入。
  - (e) **完全不得** import `System.Process`——不執行任何外部程式(那是 #6)。

  **判準只看 import 行,不做全檔字串搜尋**:本檔的 Haddock 本來就會提到 `.aapms/` /
  `readMarker` / `initVaultAt` / `setupHub` 這些名字來說明界線,全檔搜尋會把「文件寫得清楚」
  誤判成「越界」。

> **紅綠預期**(`spec-roles.md`「qa 的交付判準」逐條判定,**不是整批全紅**):
>
> - **預期綠**:**L18 的五條子斷言 (a)–(e) 全部**。它們驗的是骨架原文自身就承載的事實
>   (各檔的 import 行),不經過任何 `undefined`。**從第一天就綠,而且應該綠;不得因為它綠就
>   退回重寫。** 其中 (b) 是條件式,**兩個階段都預期綠**:骨架階段沒有對
>   `Aapms.Store.Marker` 的 import 行,條件為假即通過;impl 補上之後,那一行必須**逐字**是
>   `import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)` 才算通過——它從
>   這一刻起真正守著「Discovery 只讀 id」,放寬成 `VaultMarker (..)` 或多列任何一個欄位就紅。
> - **預期紅**:其餘每一條 law 與每一個 example——四個函式的本體全是 `undefined`。
>
> 骨架裡**沒有**任何不是 `undefined` 的本體(與 F001 的 `mkHub = Hub` 不同,本 feature 沒有
> 「定義就是那個建構子」的函式)。

## Examples

| # | 輸入 | 預期 | 覆蓋的 law |
|---|---|---|---|
| X1 | 暫存目錄 `V` 有 `V/.aapms/config.toml`;`detectVault (V </> "a" </> "b" </> "c")` | `Just V'`,`V'` 是 `V` 的正規化 | L1, L3 |
| X2 | `detectVault V`(起點就是 vault 根) | `Just V'` | L1, L3 |
| X3 | `detectVault (V </> "a" </> ".." </> "a" </> "b")` | `Just V'`——起點先正規化,`..` 不會多走一層 | L1 |
| X4 | 一個沒有任何祖先含 `.aapms/` 的暫存目錄 `T`;`detectVault T` | `Nothing` | L2 |
| X5 | 巢狀:`V/.aapms/` 與 `V/inner/.aapms/` 都在;`detectVault (V </> "inner" </> "x")` | `Just (V/inner 的正規化)`——**最近**的那一層 | L1(d) |
| X6 | `V/.aapms` 是普通**檔案**(不是目錄),`V` 沒有其他 marker,且 `V` 的祖先也沒有;`detectVault (V </> "a")` | `Nothing` | L5 |
| X7 | X1 的情境,`detectVault` 呼叫前後對 `V` 遞迴列出全部檔案與內容 | 兩次完全相同(沒有新增任何目錄或檔案) | L4 |
| X8 | `h` 有 e1(`veId = vlt-7f3b2a91`、`veName = "alchbees-assets"`)與 e2(`veId = vlt-a0c4e1f8`、`veName = "vlt-7f3b2a91"`);`lookupSelector h "vlt-7f3b2a91"` | `Right e1`——id 先於 name | L6, L7 |
| X9 | `h` 有 e3、e4 兩列 `veName == "lore"`(id 不同);`lookupSelector h "lore"` | `Left (VaultSelectorAmbiguous "lore" [e3, e4])`,清單**兩列都在**且順序同中樞 | L7 |
| X10 | `lookupSelector h "nope"` | `Left (VaultSelectorNotFound "nope")` | L7 |
| X11 | `lookupSelector h "ALCHBEES-ASSETS"`(大小寫不同) | `Left (VaultSelectorNotFound "ALCHBEES-ASSETS")` | L8 |
| X12 | `lookupSelector h " alchbees-assets "`(前後有空白) | `Left (VaultSelectorNotFound " alchbees-assets ")` | L8 |
| X13 | 同一組 vaults,但 `mkHub` 的 projects / llm / tools / 原始文字換成完全不同的值;`lookupSelector h "alchbees-assets"` | 與換之前逐欄相同 | L9 |
| X14 | marker 是 `id=vlt-7f3b2a91 / kind=asset / name="real"`;中樞那列是 `veId=vlt-7f3b2a91`、`veName="stale"`、`veKind=StoryVault`;`readVaultRef e V` | `Right r`;`vmName (vrMarker r) == "real"`、`vmKind (vrMarker r) == AssetVault`、`vrEntry r == Just e`、`vrPath r == V 的正規化` | L10, L11 |
| X15 | 中樞那列指向一個不存在的路徑 `X`;`readVaultRef e X` | `Left (VaultPathMissing e (X 的正規化))` | L12(a) |
| X16 | `V/.aapms/` 目錄在但沒有 `config.toml`;`readVaultRef e V` | `Left (VaultMarkerBroken e (VaultMarkerMissing (Aapms.Store.Marker.configPath V')))`,`V'` 是 `V` 的正規化 | L12(b) |
| X17 | `V/.aapms/config.toml` 的 `kind = "media"`;`readVaultRef e V` | `Left (VaultMarkerBroken e err)`,`err` 與直接呼叫 `readMarker V'` 得到的 `VaultMarkerInvalid` **逐欄相同** | L12(b) |
| X18 | marker 的 id 是 `vlt-aaaa1111`,中樞那列的 `veId` 是 `vlt-bbbb2222`;`readVaultRef e V` | `Left (VaultIdDrift e (VaultId "vlt-aaaa1111"))`——第二個值是 **marker 裡的** id | L12(c) |
| X19 | 中樞含一列 `veId == vlt-7f3b2a91`,marker 也是它;`readVaultRefAt h V` | `Right r`,`vrEntry r == Just` 那一列、`vrPath r == V 的正規化` | L14 |
| X20 | 中樞**沒有**任何 `veId == marker 的 id` 的列(向上探測到的未註冊 vault);`readVaultRefAt h V` | `Right r`,`vrEntry r == Nothing`,`vrMarker r` 仍來自檔案 | L14 |
| X21 | 中樞有一列的 `vePath` 就是 `V` 但 `veId` 不同;`readVaultRefAt h V` | `vrEntry r == Nothing`——比對只看 id,**路徑不參與** | L14 |
| X22 | `readVaultRefAt h X`(`X` 不存在) | `Left (MarkerUnreadable X' (VaultMarkerMissing (configPath X')))`;`renderWorkspaceError` 的輸出含 `X'` 與 `renderStoreError` 的訊息 | L15 |
| X23 | X17 的壞 marker;先 `readVaultRefAt h V` 再 `readVaultRef e V`(`e` 是中樞那一列) | 前者 `Left (MarkerUnreadable V' err)`、後者 `Left (VaultMarkerBroken e err)`,兩個 `err` **逐欄相同** | L16 |
| X24 | marker 的 `refs = ["vlt-11112222", "vlt-33334444"]`;`readVaultRef e V` | `Right r`,`vmRefs (vrMarker r) == [VaultId "vlt-11112222", VaultId "vlt-33334444"]`;`vrEntry` / `vrPath` 與 `refs = []` 時完全相同 | L17 |

## 依賴方向

- **依賴誰**:`Aapms.Workspace.Types`(五個型別)、`Aapms.Workspace.Hub`(`hubVaults`)、
  `Aapms.Store.Marker`(`readMarker` / `markerDir`)、`Aapms.Core.Id`(`VaultId`)、
  `directory`、`filepath`、`text`。
- **誰會依賴它**:`Aapms.Workspace.Scope`(F003,`resolveRead` / `resolveWrite` /
  `resolvePipeline` 全部經由本模組取權威身分)、`Aapms.Workspace.Lifecycle`(F004,
  `AdoptExisting` 與 `addVault` 讀既有 marker)。兩者都尚未存在。
- **新增的依賴邊**(一條都不能漏):
  - `Aapms.Workspace.Discovery → Aapms.Workspace.Types`(新)
  - `Aapms.Workspace.Discovery → Aapms.Workspace.Hub`(新;impl 填本體時出現)
  - `Aapms.Workspace.Discovery → Aapms.Store.Marker`(新;**`readMarker` 在 `aapms-store`
    之外的第一個消費者**——knot 反向可達確認目前只有 `Aapms.Store.Marker.openVault` 用它)
  - `Aapms.Workspace.Discovery → Aapms.Core.Id`(新;只取 `VaultId`)
  - **套件層級不新增任何依賴邊**:`aapms-workspace → aapms-store` / `→ aapms-core` 在 F001
    就已存在,`.cabal` 的 `build-depends` 一行不用動。
- **可否與其他進行中任務平行開發**:可以與 F005(project-registry)、F006(machine-tools)
  平行——三者的寫入白名單各是一個不同的 `.hs`,共同讀的 `Types.hs` / `Hub.hs` 都只讀不寫。
  **不能**與 F003 平行:F003 的全部三個裁決函式都吃本 feature 的產出。

## 不可逆決定

| 決定 | 被否決的替代方案與否決理由 |
|---|---|
| `readVaultRef` 的第一參數收窄成 `VaultEntry`,未註冊路徑另走 `readVaultRefAt`(對外契約 C 與 `Types.hs` 一個字都不動,只動 design.md 模組間介面表的一列) | **(a) 給 `ScopeIssue` 加一個不帶 `VaultEntry` 的建構子**:語意最直白。否決理由是要回頭改已交付驗收(81/0 綠)的 `Types.hs`,而 build-log D2 明訂 Types 一次寫齊、階段二三個 feature 平行寫同一個檔案就是併發互蓋——當下成本是整波停擺,而換得的只是把兩個函式併回一個。**(b) 保留 `Maybe VaultEntry` 的單一函式,`Nothing` 的失敗「由呼叫端保證不會發生」**:當下成本零。否決理由是那讓 `readVaultRef` 在最需要清楚錯誤的路徑(決定寫入目標)上變成 partial function,qa 也寫不出那一格的斷言;三個月後的代價是 `resolveWrite` 在 marker 壞掉的目標上行為未定義,而這正是「寫錯庫」的高風險路徑 |
| 正規化一律用 `canonicalizePath`,寫進 spec 而不是留給 impl 選 | **用 `makeAbsolute`**:不解 symlink、比較不會出乎意料。否決理由有兩條:它**不解 `..`**,向上探測會多走一層;而且 Windows 暫存目錄的 8.3 短檔名不還原,qa 造的 fixture 路徑與回傳值逐字不等,會出現看起來莫名其妙的紅燈。**留給 impl 自己選**:當下成本零,但「兩邊要逐字相等」的東西沒有寫進 spec,就是把一個 spec-gap 埋到仲裁那一輪才爆。代價:`canonicalizePath` 會解 symlink,日後若要「保留使用者輸入的 symlink 路徑」得回頭改契約 C 的 `vrPath` 值域 |
| `detectVault` 的命中判準只有「`.aapms` 是既存目錄」,marker 壞不壞不影響 | **要求 `.aapms/config.toml` 解析得開才算命中**:探測結果一定是可用的 vault。否決理由是壞掉的 vault 會讓探測**穿過去**打到父目錄的另一個 vault,寫入靜默落到錯的庫;而現在的做法是命中之後由 `readVaultRefAt` 回一則 `MarkerUnreadable`,使用者看得到「這裡的 marker 壞了」。當下成本是多一次失敗的 `readMarker`,換掉一條沉默的寫錯庫路徑 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `workspace/src/Aapms/Workspace/Discovery.hs` | 模組宣告與匯出清單(四個函式)、四條完整簽名與各自的 Haddock;本體一律 `undefined` |

**編譯狀態**:`Aapms.Workspace.Discovery` **已列進 `aapms-workspace.cabal`**——library 的
`exposed-modules` 與 test-suite 的 `other-modules`(連同 `Aapms.Workspace.DiscoverySpec`)都由
**編排者**在本 feature 交件後補上(D2:`.cabal` 由編排者單線維護,本 feature 不得修改)。
`cabal build aapms-workspace` 從此涵蓋本模組,不再需要下面那道單檔檢查。

> **交件當下(骨架階段)的紀錄,保留備查**:那時本模組還沒進 `.cabal`,
> `cabal build aapms-workspace:lib:aapms-workspace` 回 **Up to date / exit 0**(既有三個模組仍
> 綠),骨架另以**唯讀**方式單檔型別檢查通過——在 `workspace/` 下跑
> `cabal exec -- ghc -fno-code -Wall -Wcompat -XGHC2021 -XDerivingStrategies -XLambdaCase
> -XOverloadedStrings -XRecordWildCards -XStrictData -package aapms-core -package aapms-store
> -package containers -package directory -package filepath -package toml-reader
> -hide-package text-2.1.3 -isrc -outputdir <暫存> src/Aapms/Workspace/Discovery.hs`
> → `[1 of 2] Aapms.Workspace.Types` / `[2 of 2] Aapms.Workspace.Discovery`,**exit 0、零警告**。
> 這道指令不寫任何檔案到專案樹,也沒有動 `.cabal`。

## TodoList

- [ ] T1: `detectVault`:`canonicalizePath` 起點 → 逐層 `doesDirectoryExist (markerDir d)` →
  命中即回;沒命中就 `takeDirectory`,到不動點回 `Nothing`。不讀 marker、不建任何東西
  `dep: -`
- [ ] T2: `lookupSelector`:兩階段命中集合(先 `veId` 後 `veName`,逐字精確比對)→ 0 / 1 / 多
  三分支,多的那支把**全部**命中列放進 `VaultSelectorAmbiguous` `dep: -`
- [ ] T3: `readVaultRef`:正規化 → `doesDirectoryExist` → `readMarker` → `vmId` 比對,三種
  `ScopeIssue` 依序判定;`StoreError` 原樣捧著不翻譯 `dep: -`
- [ ] T4: `readVaultRefAt`:正規化 → `readMarker`(失敗一律 `MarkerUnreadable`)→ 以 `vmId`
  回 `hubVaults` 反查填 `vrEntry` `dep: T3`
- [ ] T5: 兩者共用的私有 helper(正規化 + 讀 marker),確保 `readVaultRef` 與 `readVaultRefAt`
  對同一個 vault 給出逐欄相同的 `VaultRef` 與同一個 `StoreError` 原件 `dep: T3, T4`

## 1-to-1 測試對照表

| Todo | Law / Example | 測試 |
|------|---------------|------|
| T1 | L1, L2, L3, L4, L5 / X1–X7 | `test_detect_vault_from_nested_child`、`test_detect_vault_at_root_itself`、`test_detect_vault_normalizes_dotdot`、`test_detect_vault_outside_returns_nothing`、`test_detect_vault_picks_nearest`、`test_detect_vault_ignores_marker_file`、`test_detect_vault_creates_nothing` |
| T2 | L6, L7, L8, L9 / X8–X13 | `test_lookup_selector_id_beats_name`、`test_lookup_selector_ambiguous_lists_all`、`test_lookup_selector_not_found`、`test_lookup_selector_is_case_sensitive`、`test_lookup_selector_does_not_trim`、`test_lookup_selector_ignores_other_sections` |
| T3 | L10, L11, L12, L13 / X14–X18 | `test_read_vault_ref_marker_is_truth`、`test_read_vault_ref_fields_on_success`、`test_read_vault_ref_path_missing`、`test_read_vault_ref_marker_broken_carries_original`、`test_read_vault_ref_id_drift`、`test_read_vault_ref_creates_nothing` |
| T4 | L14, L15 / X19–X22 | `test_read_vault_ref_at_fills_entry_by_id`、`test_read_vault_ref_at_unregistered_is_nothing`、`test_read_vault_ref_at_ignores_path_match`、`test_read_vault_ref_at_marker_unreadable` |
| T5 | L16, L17 / X23, X24 | `test_two_readers_agree`、`test_refs_carried_verbatim_not_expanded` |
| (全部) | L18 (a)–(e) | `test_discovery_no_downstream_or_location_imports`(a)、`test_discovery_marker_import_is_id_reader_only`(b,條件式逐字比對 `import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)`——守的是「只讀 id」:`VaultMarker (..)` 與多出來的 `vmKind` / `vmName` / `vmRefs` 都要紅)、`test_discovery_never_imports_atomic`(c)、`test_discovery_never_imports_index_modules`(d)、`test_discovery_no_process_import`(e)。**五條都只掃 import 行,比對前先去除行尾 `\r`** |

## 待確認假設

- A1: 把 design.md「模組間公開介面」的
  `readVaultRef :: Maybe VaultEntry -> FilePath -> IO (Either ScopeIssue VaultRef)`
  **拆成兩個函式**(`readVaultRef :: VaultEntry -> …` 與
  `readVaultRefAt :: Hub -> FilePath -> IO (Either WorkspaceError VaultRef)`)。契約卡沒有答案,
  是因為這不是卡片漏寫,而是 design.md **內部兩處互相矛盾**:模組間介面表允許
  `Maybe VaultEntry`,但契約 C 的 `ScopeIssue` 三個相關建構子**都要求一列 `VaultEntry`**,
  第一參數為 `Nothing` 時失敗通道表達不出來。
  - 契約錨點:design.md「模組間公開介面」表的 `Scope → Discovery` 那一列(`readVaultRef`);
    契約 C 的 `ScopeIssue`(`VaultPathMissing` / `VaultMarkerBroken` / `VaultIdDrift`)與
    `VaultRef.vrEntry`;契約 F 的 `MarkerUnreadable`;新增符號 `readVaultRefAt`
  - 層級自答:出現在邊界上?**會**(它是 `Aapms.Workspace.Discovery` 的匯出清單,F003 / F004
    直接呼叫);改錯驚動其他模組?**要**(F003 的三個裁決函式全部經由它取權威身分,改簽名
    等於改 Scope 的每一條路徑)
  - 選項:
    a) **拆成兩個函式(本 spec 採用)**——當下成本:模組間介面表多一列、F003 的 spec 要知道
       「已註冊走哪個、探測到的走哪個」;三個月後代價:兩個函式的行為要一直保持一致(本 spec
       以 L16 把這條一致性釘成 law,漂移會紅),而且若日後 `ScopeIssue` 真的改成帶
       `Maybe VaultEntry`,`readVaultRefAt` 會變成一個可以合併掉的舊介面,得走一次契約修訂
    b) **給 `ScopeIssue` 加一個不帶 `VaultEntry` 的建構子(例如 `VaultRefUnreadable FilePath
       StoreError`)**——當下成本:要改已交付驗收的 `Types.hs`,而 D2 明訂 Types 一次寫齊、
       階段二三個 feature 平行寫同一個檔案,回頭改它就是併發寫入的風險,整波要重排;
       三個月後代價:最小——語意最直白,`readVaultRef` 保持單一入口,`Scope` 不必分兩條路
    c) **保留 `Maybe VaultEntry`,`Nothing` 的失敗定義成「呼叫端保證不會發生」**——當下成本:
       零,簽名逐字照抄;三個月後代價:`readVaultRef` 在 `Nothing` 分支是 partial function,
       而它的唯一呼叫情境正是「決定寫入目標」——marker 壞掉時使用者拿到的是崩潰或空結果,
       不是一則說得出下一步的錯誤;qa 也寫不出那一格的斷言,會變成一條 spec-gap
  - 傾向:a。理由是它在**不動任何已交付程式碼**的前提下讓每個型別都完整(沒有 partial 分支),
    而且順手給契約卡指名的 `MarkerUnreadable` 找到唯一的生產者——沒有 `readVaultRefAt`,本
    feature 的三個錯誤建構子只實作得出兩個。依賴的前提:`ScopeIssue` 的四個建構子在階段二
    不會再改(D2 已把 Types 凍結,契約 F 也已列全建構子),這個前提成立。b 客觀上是最乾淨的
    終局,但它的成本落在**這一波的排程**而不是設計本身;若編排者願意付停一波的代價,b 值得選。
    可逆性:**有條件可逆**——改成 b 要動 `Types.hs`(加一個建構子)、把 `readVaultRefAt` 併回
    `readVaultRef`,並改 F003 的呼叫端;此刻只有骨架與測試,代價還很小,**等 F003 寫完就會
    變成三個檔案的連帶修改**
  - 暫採:a(`readVaultRef :: VaultEntry -> FilePath -> …` + `readVaultRefAt :: Hub ->
    FilePath -> …`)→ 影響:若裁決成 b,`Types.hs` 的 `ScopeIssue` 加一個建構子、
    `renderWorkspaceError` 不動(它不管 `ScopeIssue`)、`readVaultRefAt` 併回
    `readVaultRef :: Maybe VaultEntry -> …`,Laws 的 L14 / L15 / L16 三條改寫成單一函式的版本,
    Examples 的 X19–X23 的呼叫形式跟著改;若裁決維持原簽名但不加建構子(選項 c),L15 與
    X22 要整條刪掉,並在 spec 明寫「`Nothing` + marker 壞」是未定義行為——那會是一條 spec-gap

- A2: `lookupSelector` 的**命中集合語意**——(i) `veId` 階段命中兩列以上時,與 `veName` 撞名
  **走同一套處置**(回 `VaultSelectorAmbiguous` 帶全部命中列),而不是取第一列;(ii) 兩階段
  都是**逐字精確比對**(不去前後空白、不忽略大小寫)。契約卡只規定了「id 優先」與「同名撞名
  回全部」兩件事,沒有規定 id 撞號怎麼辦(契約 B 說 `veId` 中樞內唯一,但 `Hub` 是不透明型別、
  `mkHub` 又是公開的建構入口,測試造得出重複 id 的 `Hub`),也沒有規定大小寫與空白。
  - 契約錨點:design.md 契約 C 的 `lookupSelector` 與「第二參數(三個 `resolve*`)」那一列
    (「selector 先比 `veId` 的完整字串,再比 `veName`」);契約 B 的 `veId` 值域(「中樞內
    唯一」)與 `veName` 值域(「非空;允許重複」);契約 F 的 `VaultSelectorAmbiguous`
  - 層級自答:出現在邊界上?**會**(它決定 `--vault X` 這個使用者輸入被接受還是被拒,那是
    system.md 的對外 CLI 契約);改錯驚動其他模組?**要**(F003 三個裁決函式與 F004 的
    `forgetVault` 都寫明「比對規則同 `lookupSelector`」)
  - 選項:
    a) **兩階段同一套命中集合規則 + 逐字精確比對(本 spec 採用)**——當下成本:多兩條 law
       與三個 example;三個月後代價:使用者打 `--vault Alchbees-Assets` 會被拒,要自己改大小寫
       ——但錯誤訊息(`VaultSelectorNotFound`)已經說了「請確認 id 或名稱是否正確,或先執行
       vault list」,改得掉
    b) **id 階段撞號時取第一列,只有 name 撞名才回 `Ambiguous`**——當下成本:零;三個月後
       代價:一份手寫的中樞若真的出現重複 id(`loadHub` 擋得掉,但 `mkHub` 造得出來、
       F004 的 `initVault` 也在撞號時才回 `VaultIdCollision`),`--vault <該 id>` 會**靜默**
       選中其中一個,而 ADR-017 對「兩個東西帶同一個 vault id」的一貫立場是「身分不確定時
       不能靜默帶過」(graph-core 的 `VaultIdCollision`、`loadHub` 的 `HubMalformed` 都是
       這個立場)——這裡開一個例外,以後查起來會很難
    c) **selector 比對前先 `T.strip`、且忽略大小寫**——當下成本:兩行;三個月後代價:
       `veName` 是使用者自己取的 Text,忽略大小寫會讓兩個原本合法共存的名字(`Lore` 與
       `lore`)突然變成撞名,而中樞裡它們是兩列合法的資料;而且 id 是小寫十六進位,放寬對它
       沒有任何好處
  - 傾向:a。理由是它讓「身分不確定就明講」在整個系統只有一種行為(與 `loadHub` 的
    `HubMalformed`、graph-core 的 `VaultIdCollision` 同一個立場),而 c 引入的撞名是**新造
    出來的**問題。依賴的前提:`--vault` 的字串來自 `shell` 原樣傳入、不做任何正規化
    (ADR-015 第三條「`shell` 零業務邏輯」),所以這一層看到的就是使用者打的字——這一點由
    design.md 對外契約段的「`shell` 不直接 import 本套件,只把 `--vault` 的字串原樣交給
    `service`」佐證。可逆性:**可逆**——放寬(改成 b 或 c)不會讓任何既有的中樞檔變成非法,
    也不會讓原本成功的指令失敗;收緊才會
  - 暫採:a → 影響:若裁決成 b,L7 拆成兩條(id 階段取 `head`、name 階段回 `Ambiguous`),
    X8 不變、要新增一個「重複 id」的 example;若裁決成 c,L8 整條改寫,X11 / X12 的預期從
    `VaultSelectorNotFound` 改成 `Right e1`

## 實作備註

### 2026-08-29 閘門裁決:L18(b) 的逐字字串(spec-gaps G2)

qa 與 impl 各自撞到 **L18(b) 與同一份 spec 的 L12(c) / L14 互相矛盾**:(b) 原文的白名單是
`import Aapms.Store.Marker (markerDir, readMarker)`,而 L12(c) 與 L14 都要求用 `vmId` 做 id 比對
——`vmId` 是 record 欄位存取子,只能經 `VaultMarker (..)` 或 `VaultMarker (vmId)` 取得,而
`Aapms.Workspace.Types:65` 對它的 import 是裸型別 `(VaultMarker)`(F001 的 L17(d) 釘死),
**轉不出欄位存取子**。原白名單因此讓 L12(c) / L14 沒有任何合法實作滿足得了。

開發者裁決:把 (b) 的逐字字串**收緊**成
`import Aapms.Store.Marker (VaultMarker (vmId), markerDir, readMarker)` ——**只放行 `vmId` 一個
欄位存取子**,不是 `VaultMarker (..)`。這樣一來這條 law 守的是「**Discovery 只讀 id**」:
日後有人在本模組碰 `vmRefs`(#3 的 `refs` 展開)或 `vmKind`(#3 的 kind 過濾、#4 的 `syncHub`),
編譯得過但測試會紅。

本次只改 L18(b) 的條文、「1-to-1 測試對照表」最後一列的措辭與「紅綠預期」對 (b) 的敘述;
**其餘 law、example 與四條介面一個字未動**。
