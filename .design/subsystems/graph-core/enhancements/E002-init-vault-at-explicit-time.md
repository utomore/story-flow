---
id: E002
type: enhance
title: init-vault-at-explicit-time
description: initVaultAt 的時間提成明碼參數,並讓它不再逸出 IOException
status: open
created: 2026-08-29
updated: 2026-08-30
depends-on: [F001, F005]
related-adr: [ADR-013, ADR-017]
related-feature: [F005]
---

# E002:`initVaultAt` 的明碼時間版本,兼修 `IOException` 逸出

## 現況分析

`store/src/Aapms/Store/Marker.hs:148-171`(2026-08-30 打開讀到的實況):

```haskell
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
initVaultAt givenRoot kind name = do
  root <- makeAbsolute givenRoot                     -- ① 可拋,未捕捉
  exists <- doesFileExist (configPath root)
  if exists
    then pure (Left (VaultAlreadyInitialized root))
    else do
      createDirectoryIfMissing True (markerDir root) -- ② 可拋,實測會拋
      now <- getCurrentTime                          -- ③ 內部取樣
      let vid = VaultId (renderId (newId PVlt name now 0))
          marker = VaultMarker vid kind name []
      writeR <- atomicWriteText (configPath root) (renderMarker marker)
      ...
```

**兩個獨立的缺陷,同一個函式**:

### 一、時間內部取樣 → 撞號分支永遠測不到(原 E002)

`newId`(`core/src/Aapms/Core/Id.hs:103-109`)是純函式,`payload = name ⑴ show t ⑴ show salt`,
**相同輸入必得相同輸出**。所以 id 能不能重現,只取決於 `now` 能不能重現;而 `now` 在函式內部,
呼叫端碰不到。實測同名連續兩次呼叫得到 `vlt-1c5bcb0f` / `vlt-b8122656`。

後果:`workspace` 的 `initVault`(`workspace/src/Aapms/Workspace/Lifecycle.hs:190-193`)有一整條
「新 id 撞到中樞既有 `veId` 就回 `VaultIdCollision` 並回滾 `.aapms/`」的分支,**沒有任何人能證明
它是對的** —— 造不出碰撞。F004 的 L18 / L19 / X18 / X19 因此停在 `pendingWith`
(`workspace/test/Aapms/Workspace/LifecycleSpec.hs:513-527`,qa 留了註解掉的建構供日後參考)。

graph-core 自己已經為同一件事裁決過一次:`allocateId` 的 **2026-08-25 G8 裁決**改收明碼 `UTCTime`
(`design.md` 契約 E),理由逐字是「藏在函式內部取樣,呼叫端就無法預先造出碰撞,salt 重試迴圈也就
永遠測不到 —— 而碰撞在正常情況下幾乎不發生,那段程式碼可能永遠是錯的而沒人知道」。
`initVaultAt` 沒有跟著改,是 graph-core 內部的不一致。

### 二、`IOException` 逸出 → 型別在說謊(原 B002)

`createDirectoryIfMissing`(②)未捕捉。實測:vault 根目錄的**父層被一個一般檔案佔住**時,它把
`CreateDirectory ... AlreadyExists` 這個 `IOException` 往上拋,而不是回 `Left`。`makeAbsolute`(①)
同樣未捕捉(機率低,要 cwd 被刪)。

違反 `system.md` 全域錯誤處理策略第 2 條:「資料庫錯誤與檔案系統例外同樣不得逸出」。後果:
`workspace` 為此新增的 `VaultInitFailed`(契約 F)**唯一的驗收路徑**是「`initVaultAt` 回 `Left`」,
現在驗不到,F004 的 L44 / X41 同樣停在 `pendingWith`(`LifecycleSpec.hs:477-491`)。

同一個套件裡 `Aapms.Store.Atomic`(`:37`、`:45`)與 `Aapms.Store.Walk.statOf`(`:70`)都用
`try … :: IO (Either IOException a)` 包好了,本函式是例外。

## Scope(涵蓋範圍)

**動**:`store/src/Aapms/Store/Marker.hs` 一個檔案、`initVaultAt` 一個函式(新增它的明碼時間版本、
補上例外邊界)。graph-core 契約 E 新增一列。

**明確不動**:

| 排除項 | 理由 |
|---|---|
| `workspace` 的 `initVault` | 它自己也內部取樣時間,**本文檔完成後 G4 仍不會結案**(X18 / X19 依舊造不出撞號)。要關 G4 得另開一份 workspace 的 enhance 把同樣形狀的接縫延伸上去 —— 那是 workspace 的契約 F,不屬本子系統 |
| `ensureDir`(`Edit.hs:246`)、`vaultMarkdownFiles`(`Walk.hs:40`)、`toVaultRelative`(`Index.hs:69`)、`openVault`(`Marker.hs:196`)四處同類的 `IOException` 逸出 | 2026-08-30 `/arch-audit subsys graph-core` 的發現 1。B002 原文的修法只寫「把 `initVaultAt` 內所有會拋 `IOException` 的呼叫包起來」,擴大到四處是新的 scope 決定,待開發者裁決後另開文檔 |
| `createTopicFile` / `createLevelFile` / `createPackFile` 內部的 `getCurrentTime` | 形狀相同但**不是缺陷**:三者取到的 `t` 往下傳給 `allocateId`,撞號與 salt 重試已經在可測的那一層 |
| 既有 15 處呼叫端 | 本次形狀(薄包裝)刻意讓它們**一行都不用改** |

**對外契約**:向後相容。`initVaultAt` 的簽名逐字不變,契約 E **新增**一列而非修改一列。

## 改善目標

| 目標 | 量化驗收 |
|---|---|
| vault id 可由呼叫端確定性重現 | 同一個 `(kind, name, t)` 在兩個不同的空目錄產生**相同** `vmId`(L1 / E2) |
| `initVaultAt` 兌現 `Either StoreError` 的承諾 | 父層被檔案佔住的建構回 `Left`,**不拋例外**(L5 / E5);`workspace` F004 的 L44 / X41 兩條可從 `pendingWith` 轉正式斷言 |
| 不動既有行為 | `aapms-store-test` 基準線 **279 examples / 0 failures**(2026-08-30 實跑)一條都不轉紅 |
| 不動既有呼叫端 | 15 處呼叫端的原始碼零改動 |

## 數據與介面變動

| 項目 | 動作 | 簽名 / 定義 | 語意(做什麼) | 受影響呼叫端 | 骨架位置 |
|---|---|---|---|---|---|
| `initVaultAtWith` | **新增** | `initVaultAtWith :: FilePath -> VaultKind -> Text -> UTCTime -> IO (Either StoreError VaultMarker)` | 建立 vault 骨架(發 id、寫 marker、建空索引),**id 由呼叫端給的時間決定**;檔案系統失敗一律回 `Left`,不拋例外 | 無(新符號) | `store/src/Aapms/Store/Marker.hs:145` |
| `initVaultAt` | **修改**(簽名逐字不變) | `initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)` | 取當下時間後轉呼 `initVaultAtWith`;對外行為除了「不再拋例外」以外完全不變 | 15 處,**全部不需修改** | `store/src/Aapms/Store/Marker.hs:148` |
| `Aapms.Store.Marker` 匯出清單 | **修改** | 「讀寫」段新增 `initVaultAtWith` | 隨 `Aapms.Store` 門面的整模組 re-export 自動進契約 E 的門面 | 無 | `store/src/Aapms/Store/Marker.hs:14` |

`Aapms.Store`(門面)以 `module Aapms.Store.Marker` 整模組 re-export,**不需要另外改**。

## Laws(行為性質)

**回歸 law(改完必須一模一樣的現有行為)**

- **R1**:對任意空目錄 `d`、任意 `kind`、任意非空 `name`,`initVaultAt d kind name` 成功後
  `d/.aapms/config.toml` 解析出的 `VaultMarker` 四欄為:`vmId` 符合 `vlt-<8 個小寫十六進位>`、
  `vmKind == kind`、`vmName == name`、`vmRefs == []`
- **R2**:對**已經有** `.aapms/config.toml` 的目錄呼叫 `initVaultAt` 或 `initVaultAtWith`,一律回
  `Left (VaultAlreadyInitialized root)`(`root` 是絕對路徑),且該目錄底下**每一個檔案逐位元組不變**
- **R3**:`initVaultAt` 成功後 `d/.aapms/index.db` 存在,且 `openVault` 開得起來
- **R4**:`initVaultAt` 的型別簽名逐字等於
  `initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)`
- **R5**:`initVaultAt` 對同一個 `name` 連續兩次呼叫(不同的空目錄)產生**不同**的 `vmId`
  —— 薄包裝仍然每次取當下時間,這條防止實作把時間改成常數來湊 L1

**新 law(這次優化才成立的性質)**

- **L1(決定性)**:對任意 `kind`、任意非空 `name`、任意 `t`,與任意兩個各自為空且互不相同的目錄
  `d1` / `d2`,兩次 `initVaultAtWith` 成功時 `vmId` **相同**
- **L2(id 的來源逐字可算)**:`initVaultAtWith d kind name t` 成功時,
  `vmId == VaultId (renderId (newId PVlt name t 0))`。`newId` 是契約 B 的公開純函式,呼叫端算得出期望值
- **L3(薄包裝等價)**:`initVaultAt d kind name` 的結果,除了 `vmId` 之外,與
  `initVaultAtWith d kind name t`(任意 `t`)逐欄相同:`vmKind` / `vmName` / `vmRefs` 一致,
  落地的檔案集合一致
- **L4(不逸出)**:對**任意**輸入(含不存在的路徑、父層被佔、名稱含非法字元),`initVaultAt` 與
  `initVaultAtWith` 都不拋 `IOException` —— 失敗一律以 `Left` 回傳
- **L5(建目錄失敗的錯誤值)**:vault 根目錄的父層被一個**一般檔案**佔住時,回
  `Left (FileWriteFailed (markerDir root) msg)`,且 `msg` 非空

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| E1 | 空目錄 `d`、`AssetVault`、`"alchbees-assets"`,呼叫 `initVaultAt` | `Right m`;`d/.aapms/config.toml` 的四欄如 R1;`d/.aapms/index.db` 存在 | R1, R3(**= 現況**) |
| E2 | 兩個空目錄 `d1` ≠ `d2`,同樣 `StoryVault` / `"liftgame"` / 同一個 `t`,各呼叫一次 `initVaultAtWith` | 兩次都 `Right`,且 `vmId` **相同** | L1(撞號可重現) |
| E3 | 空目錄 `d`、`StoryVault`、`"liftgame"`、`t`,呼叫 `initVaultAtWith` | `vmId == VaultId (renderId (newId PVlt "liftgame" t 0))` | L2(期望值可獨立算出) |
| E4 | 對 E1 產生的 `d` 再呼叫一次 `initVaultAt`(換一個名字) | `Left (VaultAlreadyInitialized <d 的絕對路徑>)`;`config.toml` 逐位元組不變 | R2(**= 現況**) |
| E5 | `blocker` 是一個**一般檔案**,對 `blocker/sub` 呼叫 `initVaultAt` | `Left (FileWriteFailed …)`,**不拋例外**;`msg` 非空 | L4, L5(B002 的重現) |
| E6 | 同 E5,改呼叫 `initVaultAtWith … t` | 與 E5 逐欄相同的 `Left` | L3, L4(兩個入口同一條錯誤路徑) |

## 遷移約束

- **`initVaultAt` 的簽名不得改動**(R4)。15 處既有呼叫端與 `workspace/src/Aapms/Workspace/Lifecycle.hs:45`
  的逐字 import 行斷言(`LifecycleSpec.hs:980`)都依賴它不變
- **不得移除 `initVaultAt`**:它是三個殼與既有測試 fixture 的入口
- 本文檔完成**不代表** `workspace` 的 spec-gap G4 結案(見 Scope);G5 則可結案

## 邊界與知識歸屬

- **擁有的知識**:vault marker 的格式與 `.aapms/` 佈局仍由 `Aapms.Store.Marker` 唯一持有,不變。
  **時間**從此不是本模組擁有的事實 —— `initVaultAtWith` 收下呼叫端給的值,與 `allocateId` 一致;
  `initVaultAt` 這層薄包裝仍然自己取樣,那是**便利入口的預設值**,不是知識歸屬
- **依賴方向**:不變。`Aapms.Store.Marker → Aapms.Core.Id`(`newId` / `renderId`)、
  `→ Aapms.Store.Atomic`、`→ Aapms.Store.Schema`、`→ Aapms.Store.Error` 都已存在。
  **新增的依賴邊:無**。`Control.Exception (IOException, try)` 是 base,不是架構邊
- **不可逆決定**:
  - **契約 E 新增 `initVaultAtWith` 一列,而非修改 `initVaultAt` 那一列**(2026-08-30 開發者裁決)。
    被否決的替代方案:**直接在 `initVaultAt` 加第四個參數**(與 G8 的 `allocateId` 形狀完全一致,
    子系統內只有一種寫法,「時間明碼」由型別強制而非紀律維持)。否決的代價已知並接受:留下兩個
    入口,而較短的 `initVaultAt` 會看時鐘,「時間一律明碼」在本函式退化成靠 code review 維持

## 相依性

`depends-on: [F001, F005]` —— 由「使用到的既有介面」表的來源文檔去重反推。兩者都是
`status: done`,程式碼已落地且測試綠(F001 的 `newId` / `renderId`,F005 的 `atomicWriteText` /
`openIndexAt` / `markerDir` / `StoreError`),所以這兩條相依**不阻擋任何事**,本文檔可與任何其他
任務平行進行。

**影響**:`workspace/F004` 的 L44 / X41 兩條斷言在本文檔完成後可從 `pendingWith` 轉正式(G5 結案);
L18 / L19 / X18 / X19 **不受影響**(見 Scope)。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103` | graph-core/F001(契約 B) | 由 `(name, t, salt)` 算出 vault id;**純函式,相同輸入必得相同輸出** |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123` | graph-core/F001(契約 B) | `Id` → `vlt-<8 hex>` 文字 |
| `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` | `store/src/Aapms/Store/Atomic.hs:44` | graph-core/F005(契約 E) | 寫 `config.toml`;**已經捕捉 `IOException` 並回 `FileWriteFailed`** |
| `openIndexAt :: FilePath -> VaultId -> VaultKind -> Text -> IO (Either StoreError (Connection, [IndexIssue]))` | `store/src/Aapms/Store/Schema.hs:169` | graph-core/F005 | 建空索引 |
| `closeIndex :: Connection -> IO ()` | `store/src/Aapms/Store/Schema.hs:185` | graph-core/F005 | 關掉剛建的索引連線 |
| `markerDir :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:47` | graph-core/F005(契約 E) | `.aapms/` 的唯一真相;L5 的錯誤路徑用它 |
| `configPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:50` | graph-core/F005(契約 E) | marker 檔位置 |
| `indexDbPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:53` | graph-core/F005(契約 E) | 索引檔位置 |
| `VaultAlreadyInitialized FilePath`(`StoreError` 建構子) | `store/src/Aapms/Store/Error.hs:36` | graph-core/F005(契約 G) | R2 的錯誤值 |
| `FileWriteFailed FilePath Text`(`StoreError` 建構子) | `store/src/Aapms/Store/Error.hs:38` | graph-core/F005(契約 G) | L5 的錯誤值 |
| `data VaultKind = AssetVault \| StoryVault` | `store/src/Aapms/Store/Schema.hs:63` | graph-core/F005(契約 E) | 參數型別 |

## 骨架

| 檔案 | 變動 |
|---|---|
| `store/src/Aapms/Store/Marker.hs` | `:14` 匯出清單加 `initVaultAtWith`;`:26` import 加 `UTCTime`;`:145` 新增 `initVaultAtWith` 簽名 + haddock,本體 `undefined`(point-free,避免 `-Wall` 的未使用參數警告)。`initVaultAt`(`:148`)**原樣不動** —— 它現在的實作正是 R1–R3 / R5 的基準,impl 的工作是把本體搬進 `initVaultAtWith` 並補上例外邊界,再讓它成為薄包裝 |

編譯結果:`cabal build aapms-store` 通過(2026-08-30)。

**骨架上的紅綠預期**:

| 測試打到的 | 預期 |
|---|---|
| R1 / R2 / R3 / R5(`initVaultAt` 的現有行為) | **綠**(現況就是對的) |
| R4(簽名逐字比對) | **綠**(骨架原文自身承載的事實) |
| L1 / L2 / L3 / E2 / E3 / E6(`initVaultAtWith`) | **紅**(骨架是 `undefined`) |
| L4 / L5 / E5(不逸出) | **紅**(`initVaultAt` 目前會拋) |

## 實作備註

(撰寫時留空)
