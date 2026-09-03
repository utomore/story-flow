---
id: E001
type: enhance
title: init-vault-explicit-time
description: initVault 的時間提成明碼參數,讓撞號與建檔失敗兩條分支驗得到
status: done
created: 2026-08-30
updated: 2026-09-04
depends-on: [workspace/F001, workspace/F004, graph-core/F001, graph-core/F005, graph-core/E002]
related-adr: [ADR-014, ADR-017]
related-feature: [workspace/F004]
code-paths: [workspace/src/Aapms/Workspace/Lifecycle.hs, workspace/test/Aapms/Workspace/LifecycleSpec.hs]
---

# E001:`initVault` 的明碼時間版本,兼收 `VaultInitFailed` 的驗收路徑

## 現況分析

`workspace/src/Aapms/Workspace/Lifecycle.hs:149-199`(2026-08-30 打開讀到的實況;行號為本文檔骨架寫入**後**的值):

```haskell
initVault
  :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode
  -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
initVault loc hub dir kind name mode
  | T.null (T.strip name) = pure (Left (InvalidName name))
  | otherwise = do
      dir' <- canonicalizePath dir                              -- :160
      ...
              initR <- initVaultAt dir' kind (T.strip name)     -- :182
              case initR of
                Left err -> do
                  removePathForcibly (markerDir dir')
                  pure (Left (VaultInitFailed dir' err))        -- LAW-44 的分支
                Right m -> case find ((== vmId m) . veId) (hubVaults hub) of
                  Just existing -> do
                    removePathForcibly (markerDir dir')
                    pure (Left (VaultIdCollision (vmId m) (vePath existing) dir'))  -- LAW-18/LAW-19 的分支
```

**痛點一:撞號分支永遠測不到(spec-gap GAP-4,`status: open`)。**
`:182` 的 `initVaultAt` 是 graph-core 的薄包裝,時間在它內部取樣
(`store/src/Aapms/Store/Marker.hs:177-180`)。vault id 是 `newId PVlt name t 0` 的結果,
`t` 控制不到就造不出兩個相同的 id,於是 `VaultIdCollision` 這條分支——連同它的回滾——
**沒有任何呼叫端驗得了**。`workspace/test/Aapms/Workspace/LifecycleSpec.hs:519` 與 `:526`
因此是 `pendingWith`。

graph-core E002 已經把它自己那一層解決了(`initVaultAtWith` 收明碼 `UTCTime`,
`Marker.hs:146`),但 `initVault` 沒跟上,所以 GAP-4 沒有因為 E002 完成而結案。

**痛點二:`VaultInitFailed` 的驗收路徑已經打通了,但沒有人去收(spec-gap GAP-5 的 workspace 側尾巴)。**
GAP-5 標成 `resolved`,裁決是「修 graph-core,讓 `initVaultAt` 不逸出 `IOException`」,已由
graph-core B002 隨 E002 完成。2026-08-30 實測(`cabal repl aapms-workspace`):

```
initVaultAt  => Right (Left (FileWriteFailed "…\blocker\sub\.aapms" "…CreateDirectory … already exists"))
canonicalize => Right "…\blocker\sub"
```

兩件事同時確認:`initVaultAt` 現在回 `Left` 而不是拋例外;`initVault` 在 `:160` 那個**沒有包
`try`** 的 `canonicalizePath` 對這個建構也不拋例外,不會擋在 `initVaultAt` 之前。也就是
**LAW-44 / EX-41 現在不改一行實作就測得起來**,只差沒有人把 `LifecycleSpec.hs:485` 的 `pendingWith`
換成斷言。

**痛點三:`Lifecycle.hs` 的逐字 import 斷言會擋住這次改動。**
F004 的 **LAW-42(b)** 要求 `Aapms.Store.Marker` 的 import 行**逐字是**

```haskell
import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, markerDir, readMarker)
```

斷言在 `LifecycleSpec.hs:978-984`,現況的 import 行在 `Lifecycle.hs:47`。要用
`initVaultAtWith` 就必須同步修訂這條 law 的字串——這與 spec-gap **GAP-2 / GAP-3 是同一類問題**
(白名單擋住同一份 spec 其他條文要求的行為),差別在這次是**設計階段先查出來**,不是留給 qa 撞。

**基準線**(2026-08-30,`cabal test aapms-workspace-test`):
**310 examples、0 failures、3 pending**。三條 pending 全部在 `LifecycleSpec.hs`(`:485` / `:519` / `:526`),
就是上面痛點一與痛點二的那五條驗收(LAW-18 / LAW-19 / EX-18 / EX-19、LAW-44 / EX-41)。

## Scope(涵蓋範圍)

2026-08-30 與開發者定案。

**涵蓋**(全部落在 `workspace` 單一子系統):

1. 新增 `initVaultWith`——`initVault` 的明碼時間版本,**進 `design.md` 契約 D**(開發者拍板:
   公開,比照三個既有先例,不藏 `*.Internal`)
2. `initVault` **簽名一個字不改**,退成薄包裝(取當下時間後轉呼)
3. 修訂 F004 的 **LAW-42(b)** 逐字 import 字串,加入 `initVaultAtWith`
4. 把 F004 被卡住的五條驗收轉成正式斷言:**LAW-18 / LAW-19 / EX-18 / EX-19**(GAP-4)與 **LAW-44 / EX-41**(GAP-5 尾巴)

**明確不動**:

- **`service`**:`Machine.vaultInit`(`service/src/Aapms/Service/Machine.hs:258`)一行不改——
  這正是「`initVault` 簽名不變」這個選擇要換到的東西。因此本文檔是**單一子系統**的 `E001`,
  不是全域 `G-E00x`
- **`graph-core`**:E002 / B002 已經做完它那一層,本次不動 `aapms-store` 的任何一行
- **`Projects` 模組**:`registerProject` 的同類問題早已由 `allocateProjectId`
  (`Projects.hs:167`)解決,不重做
- **`initVault` 的現有簽名**與它的四條前置檢查語意:一律維持,由回歸 law 釘住
- **`Lifecycle.hs:160` 那個沒包 `try` 的 `canonicalizePath`**:實測不擋路(現況分析痛點二),
  本次不順手加防護——那是另一件事,要做請另開文檔

**對外契約**:`design.md` 契約 D 增加一列 `initVaultWith`;「模組間公開介面」表的
`Lifecycle → aapms-store` 那一列增加 `initVaultAtWith`。**Level 1(`system.md`)不受影響**。

## 改善目標

| 指標 | 現況(2026-08-30 基準線) | 完成判準 |
|---|---|---|
| `aapms-workspace-test` 的 pending 數 | **3** | **0** |
| `aapms-workspace-test` 的 failures | 0 | 0(不得倒退) |
| `aapms-workspace-test` 的 examples | 310 | **≥ 310**(只增不減) |
| `VaultIdCollision` 建構子的斷言數 | 0 | ≥ 1 |
| `VaultInitFailed` 建構子的斷言數 | 0 | **≥ 2**(`initVault` 一條走 REG-5、`initVaultWith` 一條走 LAW-7) |
| `workspace/spec-gaps.md` 的未結條目 | 1(GAP-4) | **0** |
| `service` 受影響的程式碼行數 | — | **0** |

## 數據與介面變動

| 項目 | 動作 | 簽名 / 定義 | 語意(做什麼) | 受影響呼叫端 | 骨架位置 |
|---|---|---|---|---|---|
| `initVaultWith` | **新增**(進契約 D) | `initVaultWith :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> UTCTime -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))` | 在一個目錄上建立 vault 並登錄進中樞,**新 vault 的 id 由呼叫端給的時間決定**;前置檢查、撞號處置、回滾與 `AdoptNotice` 的語意與 `initVault` 完全相同 | 無(新符號) | `workspace/src/Aapms/Workspace/Lifecycle.hs:216` |
| `initVault` | **修改**(簽名逐字不變) | `initVault :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))` | 取當下時間後轉呼 `initVaultWith`;**對外行為完全不變** | 1 處(`service/src/Aapms/Service/Machine.hs:258`),**不需修改** | `workspace/src/Aapms/Workspace/Lifecycle.hs:149` |
| `Aapms.Workspace.Lifecycle` 匯出清單 | **修改** | 「vault 的建立與納管」段新增 `initVaultWith` | 本套件七個模組全部 `exposed`,匯出即進契約 D | 無 | `workspace/src/Aapms/Workspace/Lifecycle.hs:28` |
| `Lifecycle.hs` 的 `Aapms.Store.Marker` import 行 | **修改** | `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)` | 多放行 `initVaultAtWith` 一個名字;`vmRefs` / `openVault` / `closeVault` / `configPath` **仍然不放行** | 無 | `workspace/src/Aapms/Workspace/Lifecycle.hs:47` |
| F004 的 **LAW-42(b)** 逐字字串 | **修訂**(改既有 spec 的條文) | 同上一列的字串 | LAW-42(b) 守的三件事(見 F004 原文①②③)**一條都不放寬**,只多一個名字 | `LifecycleSpec.hs:978-984` 的期望值 | — |

`initVault` 與 `initVaultWith` 的參數順序**除了尾端多一個 `UTCTime` 之外完全相同**;時間放最後,
與 `allocateProjectId`(`Projects.hs:167`)、`initVaultAtWith`(`Marker.hs:146`)一致。

## Laws(行為性質)

### 回歸 law(改完必須一模一樣的現有行為)

- **REG-1(簽名不動)**:`initVault` 的型別簽名逐字等於
  `initVault :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))`。
  這條是 `service` 一行不改的前提
- **REG-2(前置檢查四條不變)**:對任意輸入,下列判定順序與結果與現況相同,且**一個位元組都不寫**:
  名稱去空白後為空 → `Left (InvalidName name)`(帶**原始**字串);目標目錄已有 `.aapms/` →
  `Left (VaultAlreadyInitialized dir')`(兩種 `InitMode` 都是);`FreshVault` 對存在且非空的目錄 →
  `Left (VaultDirNotEmpty dir')`;`AdoptExisting` 對不存在的目錄 → `Left (VaultDirMissing dir')`
- **REG-3(成功時身分逐欄來自 marker)**:成功時回傳的 `VaultEntry` 滿足 `veId == vmId m`、
  `veName == vmName m`、`veKind == vmKind m`、`vePath == dir'`,其中 `m` 是 `dir'` 的 marker
- **REG-4(`initVault` 仍然每次取當下時間)**:對同一個 `name`、兩個各自為空且互不相同的目錄,
  連續兩次 `initVault` 產生**不同**的 `veId`。這條防止實作把時間改成常數來湊 LAW-1
- **REG-5(`initVault` 建檔失敗 → `VaultInitFailed`,且不留半成品)**:呼叫 **`initVault`**
  (**不是** `initVaultWith`)時,若它內部用來建 marker 的那一步回 `Left err`,則 `initVault` 回
  `Left (VaultInitFailed dir' err)`——`err` 是**原件**(不轉字串、不翻譯);
  且 `markerDir dir'` 在呼叫後**不存在**、`dir'` 底下其餘檔案逐位元組相同、中樞檔案位元組不變。
  **不得**回 `MarkerUnreadable`。
  〔**這是 F004 的 LAW-44 / EX-41 原文**,主詞就是 `initVault`。現況程式碼已經正確,本條是**回歸 law**:
  從第一天就該綠,收掉 `LifecycleSpec.hs:485` 那條 `pendingWith`——GAP-5 的 workspace 側尾巴。
  `initVaultWith` 的同一個行為由 **LAW-7** 管,兩者分開,不要合寫成一條〕
- **REG-6(LAW-42 的另外五條不放寬)**:`Lifecycle.hs` 的 import 行仍滿足 F004 的 LAW-42 (a)(c)(d)(e)(f)
  ——本套件內只 import `Types` / `Location` / `Hub` / `Discovery` 四個;`Aapms.Store.Schema` 的
  import 行逐字是 `import Aapms.Store.Schema (VaultKind)`;完全不得 import `Aapms.Store.Atomic`、
  不得 import `Aapms.Store` 門面與 `Index` / `MultiVault` / `Query` / `Write` / `Create` / `Edit`、
  不得 import `System.Process`

### 新 law(這次優化才成立的性質)

- **LAW-1(決定性)**:對任意 `kind`、任意去空白後非空的 `name`、任意 `t`,與任意兩個各自為空且
  互不相同的目錄 `d1` / `d2`,兩次 `initVaultWith … t` 成功時回傳的 `veId` **相同**
- **LAW-2(id 的來源逐字可算)**:`initVaultWith loc hub d kind name mode t` 成功時,
  `veId == VaultId (renderId (newId PVlt (T.strip name) t 0))`。`newId` 是 graph-core 契約 B 的
  公開純函式,呼叫端算得出期望值,**不需要讀 graph-core 的實作**——GAP-4 要的就是這一條
- **LAW-3(薄包裝等價)**:`initVault loc hub d kind name mode` 的結果,除了 `veId` 之外,與
  `initVaultWith loc hub d kind name mode t`(任意 `t`)逐欄相同:`veName` / `veKind` / `vePath`
  一致、`AdoptNotice` 一致、落地的檔案集合一致、中樞新增的列數一致
- **LAW-4(撞號的三個值)**:若中樞 `hubVaults hub` 中某一列 `e` 的 `veId` 等於
  `VaultId (renderId (newId PVlt (T.strip name) t 0))`,則 `initVaultWith … t` 回
  `Left (VaultIdCollision thatId (vePath e) dir')`——**第二個是中樞裡既有那個 vault 的路徑、
  第三個是這次要建立的路徑**,兩者順序不可互換;`renderWorkspaceError` 的輸出同時含這兩個路徑。
  〔F004 的 LAW-18,本次才第一次可斷言〕
- **LAW-5(撞號要回滾)**:承 LAW-4,`markerDir dir'` 在呼叫後**不存在**,且 `dir'` 底下其餘檔案逐位元組
  相同、中樞檔案位元組不變。因此**對同一個目錄改用 `initVault` 立刻重跑一次,不會撞到
  `VaultAlreadyInitialized`**。〔F004 的 LAW-19 + LAW-20,本次才第一次可斷言〕
- **LAW-6(import 行的新逐字字串)**:`Lifecycle.hs` 的 `Aapms.Store.Marker` import 行**必須逐字是**
  `import Aapms.Store.Marker (VaultMarker (vmId, vmKind, vmName), indexDbPath, initVaultAt, initVaultAtWith, markerDir, readMarker)`
  ——比對前先去除行尾 `\r`(F004 LAW-42 的 CRLF 規則沿用)。放寬成 `VaultMarker (..)`、
  或多列 `vmRefs` / `openVault` / `closeVault` / `VaultHandle` / `configPath` 任何一個名字都要紅
- **LAW-7(`initVaultWith` 建檔失敗 → `VaultInitFailed`,且不留半成品)**:`initVaultAtWith` 回
  `Left err` 時,`initVaultWith` 回 `Left (VaultInitFailed dir' err)`——`err` 是**原件**;
  且 `markerDir dir'` 在呼叫後**不存在**、`dir'` 底下其餘檔案逐位元組相同、中樞檔案位元組不變;
  **不得**回 `MarkerUnreadable`。
  〔**與 REG-5 是同一個行為的兩個入口**:REG-5 打 `initVault`(現況、綠),本條打 `initVaultWith`
  (新增、骨架階段紅)。兩條都要,因為兩個入口在 impl 之後才會共用同一段本體——**在那之前
  沒有任何東西保證它們一致**,而 LAW-3「薄包裝等價」只寫了成功情況,接不住失敗路徑〕

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| EX-1 | 空目錄 `d`、`AssetVault`、`"alchbees-assets"`、`FreshVault`,呼叫 `initVault` | `Right (hub', entry, AdoptNotice [])`;`entry` 四欄如 REG-3;中樞多一列 | REG-3(**= 現況**) |
| EX-2 | 名稱 `"   "`(去空白後為空),呼叫 `initVault` | `Left (InvalidName "   ")`——帶**原始**字串;中樞檔案位元組不變 | REG-2(**= 現況**) |
| EX-3 | 兩個空目錄 `d1` ≠ `d2`,同樣 `StoryVault` / `"liftgame"` / `FreshVault` / 同一個 `t`,各呼叫一次 `initVaultWith` | 兩次都 `Right`,且 `veId` **相同** | LAW-1(撞號可重現) |
| EX-4 | 空目錄 `d`、`StoryVault`、`"liftgame"`、`FreshVault`、`t`,呼叫 `initVaultWith` | `veId == VaultId (renderId (newId PVlt "liftgame" t 0))` | LAW-2(期望值可獨立算出) |
| EX-5 | 先算出 `i = VaultId (renderId (newId PVlt "liftgame" t 0))`,把 `VaultEntry i "old" StoryVault O` 放進中樞;對空目錄 `V` 呼叫 `initVaultWith … "liftgame" … t` | `Left (VaultIdCollision i O V')`——第二個是 `O`、第三個是 `V'`;`renderWorkspaceError` 的輸出同時含這兩個路徑 | LAW-4(= F004 EX-18) |
| EX-6 | 承 EX-5,檢查 `V` 與中樞 | `V/.aapms` **不存在**(已回滾),`V` 底下其餘檔案逐位元組不變,中樞檔案位元組不變;接著對 `V` 呼叫 `initVault` 得到 `Right` | LAW-5(= F004 EX-19) |
| EX-7 | `blocker` 是一個**一般檔案**,對 `blocker/sub` 呼叫 **`initVault`**(`FreshVault`) | `Left (VaultInitFailed V' err)`,`err` 與直接呼叫 `initVaultAt V' kind name'` 得到的 `Left` **逐欄相同**;`V/.aapms` 不存在;中樞檔案位元組不變 | REG-5(**= 現況**;= F004 EX-41,GAP-5 尾巴) |
| EX-8 | 對 EX-1 產生的 `d` 再呼叫一次 `initVault`(換一個名字、`AdoptExisting`) | `Left (VaultAlreadyInitialized d')`;`d/.aapms/config.toml` 逐位元組不變 | REG-2(**= 現況**) |
| EX-9 | 同一個 `name`、兩個空目錄,連續兩次 `initVault` | 兩次 `veId` **不同** | REG-4(薄包裝仍取當下時間) |
| EX-10 | 同 EX-7 的建構(`blocker` 是一般檔案),改對 `blocker/sub` 呼叫 **`initVaultWith … t`**(`FreshVault`) | `Left (VaultInitFailed V' err)`,`err` 與直接呼叫 `initVaultAtWith V' kind name' t` 得到的 `Left` **逐欄相同**;`V/.aapms` 不存在;中樞檔案位元組不變 | LAW-7(新入口的同一條錯誤路徑) |

**Laws ↔ Examples 自洽對照**:EX-1←REG-3、EX-2←REG-2、EX-3←LAW-1、EX-4←LAW-2、EX-5←LAW-4、EX-6←LAW-5、**EX-7←REG-5**、EX-8←REG-2、
EX-9←REG-4、**EX-10←LAW-7**。EX-7 與 EX-10 是**同一個建構、兩個入口**:EX-7 打 `initVault`(現況程式碼,綠)、
EX-10 打 `initVaultWith`(骨架 `undefined`,紅);兩者的預期輸出形狀相同但**期望值各自從自己那條
law 推出**,不互相引用——`initVault` 的 `err` 對照 `initVaultAt`,`initVaultWith` 的對照
`initVaultAtWith`。
EX-5 的預期輸出由 LAW-2(算得出 `i`)與 LAW-4(撞號的三個值)共同推出,兩條一致;EX-6 的「重跑得到
`Right`」由 LAW-5 的回滾推出,與 REG-2 的 `VaultAlreadyInitialized` 不衝突——因為回滾後 `.aapms/`
已經不在。LAW-3 由 EX-1 與 EX-3/EX-4 對照覆蓋(同一組輸入、兩個入口),LAW-6 由 import 行斷言直接覆蓋。

## 遷移約束

- **`initVault` 的簽名不得改動**(REG-1)。`service/src/Aapms/Service/Machine.hs:258` 依賴它不變,
  而 `service` 已經通過階段一閘門驗收
- **不得移除 `initVault`**:它是 `service` 與既有測試 fixture 的唯一入口;`initVaultWith` 是**增設**,
  不是取代
- **LAW-42(b) 的修訂必須與 import 行同一輪落地**:spec 條文、`LifecycleSpec.hs` 的期望值、
  `Lifecycle.hs` 的 import 行三處不同步就會紅。這是 GAP-2 / GAP-3 的教訓
- 本文檔完成後,`workspace/spec-gaps.md` 的 **GAP-4 應回填 `resolved`**;GAP-5 的「workspace 這一側還有
  一步」也隨 REG-5 收掉

## 邊界與知識歸屬

- **擁有的知識**:不新增也不搬動任何事實。vault 的身分(`id` / `kind` / `name` / `refs`)仍屬
  graph-core 的 marker;**「現在幾點」這個事實從 `initVault` 內部移到呼叫端**,與
  `allocateProjectId` / `initVaultAtWith` 一致。`Lifecycle` 模組擁有的「撤除的分層界線」不受影響
- **依賴方向**:方向不變(`Lifecycle → aapms-store`)。**新增的依賴邊:無**——
  `Aapms.Workspace.Lifecycle → Aapms.Store.Marker` 這條邊本來就存在(`Lifecycle.hs:47`),
  本次只是在**同一條邊**上多放行一個符號(`initVaultAtWith`)。**移除的依賴邊:無**
- **不可逆決定**:

| 決定 | 被否決的替代方案與理由 |
|---|---|
| `initVaultWith` 進**公開**契約 D,不藏 `*.Internal` | **(a) 開一個不外露的 `Aapms.Workspace.Lifecycle.Internal`,接縫只給測試 import**:契約面不變。否決理由是本套件 design.md 明訂「不設門面模組,七個模組全部 `exposed`」,新開一個 `other-modules` 等於為了一次測試打破整個套件的結構規則;而同一件事在這個專案已經有三個公開先例(`allocateProjectId` 契約 D、`detectSevenZipIn` 契約 E、`initVaultAtWith` graph-core 契約 E),藏起來會讓同一個問題在專案裡有兩種答案。代價是契約面永久多一個入口。**(b) 直接改 `initVault` 的簽名吃 `UTCTime`**:不新增符號。否決理由是 `service/Machine.hs:258` 要跟著改,而 `service` 那一層又得自己取樣——問題只是往上推一層,還動到已交付驗收的 `service/F002` |
| 時間放**參數列最後** | **放在 `mode` 之前(緊跟 `name`)**:語意上時間與 id 生成相關,離 `name` 近。否決理由是 `allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id` 與 `initVaultAtWith :: FilePath -> VaultKind -> Text -> UTCTime -> IO …` 兩個先例都把時間放最後,而「`…With` 版本 = 原簽名尾端多一個明碼參數」是這個專案已經成形的讀法;換位置省不到任何東西,只多一種要記的形狀 |

## 相依性

`depends-on: [F001, F004, graph-core/F001, graph-core/F005, graph-core/E002]`,**逐條由
「使用到的既有介面」表的來源文檔欄反推**(一致性檢查步驟 3):

- **`F004`**:本文檔優化的就是 F004 交付的 `initVault`,並**修訂 F004 的 LAW-42(b) 條文**、
  把它的 LAW-18 / LAW-19 / LAW-44 從 `pendingWith` 轉正。同子系統,直接寫 id
- **`graph-core/E002`**:本文檔用的 `initVaultAtWith` 是 E002 新增的符號(`Marker.hs:146`),
  E002 未完成前本文檔做不了。跨子系統,帶路徑
- **`F001`**:`saveHub` / `upsertVault` / `hubVaults` 三個入口都是 F001 交付的,
  `initVaultWith` 的成功路徑與撞號比對都要用
- **`graph-core/F001`**:`newId` / `renderId`。**這條不是形式相依**——LAW-2 / LAW-4 的期望值就是
  `VaultId (renderId (newId PVlt (T.strip name) t 0))`,qa 得直接呼叫它們算出來
- **`graph-core/F005`**:`initVaultAt` / `markerDir` / `VaultMarker` 的三個欄位存取子

**五份都是 `status: done`,沒有任何一條會擋住本文檔開跑。**

**可否平行**:可以。本文檔只寫 `workspace/src/Aapms/Workspace/Lifecycle.hs` 與
`workspace/test/Aapms/Workspace/LifecycleSpec.hs` 兩個檔,與 `service` 階段二的六個待展開
feature 沒有共用寫入點,可同時進行。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `initVaultAtWith :: FilePath -> VaultKind -> Text -> UTCTime -> IO (Either StoreError VaultMarker)` | `store/src/Aapms/Store/Marker.hs:146` | `graph-core/E002` | `initVaultWith` 把明碼時間往下傳的那一步 |
| `initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)` | `store/src/Aapms/Store/Marker.hs:177` | `graph-core/F005`、`graph-core/E002` | 現況 `:182` 的呼叫;改完後**不再被 `Lifecycle` 呼叫**,但仍留在 import 白名單(LAW-6)與 `Marker` 的匯出清單 |
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103` | `graph-core/F001` | LAW-2 / LAW-4 / EX-4 / EX-5 的期望值由它算出(**qa 用得到,不必讀 graph-core 實作**) |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123` | `graph-core/F001` | 同上,把 `Id` 轉成 `VaultId` 的字串 |
| `data VaultMarker = VaultMarker`,欄位 `vmId` / `vmKind` / `vmName` | `store/src/Aapms/Store/Marker.hs:59` | `graph-core/F005` | 成功時把 marker 的三欄搬進 `VaultEntry`(REG-3) |
| `markerDir :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:48` | `graph-core/F005` | 前置檢查與回滾的目標路徑(REG-5 / LAW-5) |
| `saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())` | `workspace/src/Aapms/Workspace/Hub.hs:225` | `F001` | 成功時把新的一列原子寫回中樞 |
| `upsertVault :: VaultEntry -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:489` | `F001` | 對 `Hub` 值追加一列(純函式) |
| `hubVaults :: Hub -> [VaultEntry]`(`Hub` 的 record 欄位,`Hub` 不外露建構子) | 定義 `workspace/src/Aapms/Workspace/Types.hs:92`;`Lifecycle` 經 `Aapms.Workspace.Hub` 的 re-export 取用(`Hub.hs:19`) | `F001` | 撞號比對的候選清單(LAW-4) |
| `getCurrentTime :: IO UTCTime` | `time` 套件的 `Data.Time` | — | `initVault` 薄包裝取當下時間(`Projects.hs:101` 已是同一個用法) |

`time` **已經在** `workspace/aapms-workspace.cabal` 的 `build-depends`(`Projects.hs` 先用了),
本次**不需要改 `.cabal`**。

## 骨架

| 檔案 | 變動 |
|---|---|
| `workspace/src/Aapms/Workspace/Lifecycle.hs` | 匯出清單加 `initVaultWith`;加 `import Data.Time (UTCTime)`;加 `initVaultWith` 的**完整簽名 + Haddock + `undefined`**。**`initVault` 現有的本體一個字不動** |

**骨架階段的紅綠預期**(三類分開,依 `spec-roles.md` 的 qa 交付判準):

| 這條打到的東西 | 骨架狀態 | 預期 |
|---|---|---|
| LAW-1 / LAW-2 / LAW-3 / LAW-4 / LAW-5 / **LAW-7**(全部經 `initVaultWith`) | `undefined` | **紅** |
| LAW-6(import 行的新逐字字串) | `Lifecycle.hs:47` 仍是舊字串(骨架用不到 `initVaultAtWith`,先放進去會有 `-Wall` 的 redundant import 警告) | **紅** |
| REG-1–REG-4、REG-6(`initVault` 與其餘 import 行,現況程式碼) | 未經任何未實作標記 | **綠** |
| **REG-5**(**`initVault`** 的 `VaultInitFailed` 路徑,現況程式碼已正確) | 未經任何未實作標記 | **綠**——這條是 GAP-5 尾巴,它從第一天就該綠 |

**REG-5 與 LAW-7 不可合寫**(2026-08-30 `/spec-build` 閘門擋下的原因):兩條講的是同一個行為,但**打的是
不同的入口、骨架狀態相反**——合成一條就會出現「條文指 `initVaultWith`(紅)、預期欄寫綠」這種
自相矛盾,qa 照字面翻譯必然撞上 `spec-roles.md`「該綠卻紅」那一格,只能開 gap 停下該項。

impl 填本體時把 `initVault` 的現有本體整段搬進 `initVaultWith`(尾端多一個 `t`,`:182` 換成
`initVaultAtWith dir' kind (T.strip name) t`),`initVault` 改成 `getCurrentTime` 後轉呼,
並同步把 `:45` 的 import 行換成 LAW-6 的字串。

## 實作備註

**2026-08-30(委派模式 impl)**:骨架的兩個未實作標記(`initVaultWith = undefined`、
`Lifecycle.hs:47` 舊 import 行)已換成本體。做法完全依骨架段落最後一段的指示:把
`initVault` 現有本體整段搬進 `initVaultWith`(尾端多收 `t`,`:182` 改呼
`initVaultAtWith dir' kind (T.strip name) t`),`initVault` 改成 `getCurrentTime` 取樣後
轉呼 `initVaultWith`(新增 `import Data.Time (getCurrentTime)`),並把 `:47` 的 import 行
換成 LAW-6 的逐字字串。`cabal build aapms-workspace` 通過,只有既有的 `-Wall`
`redundant import`(`initVaultAt` 未被本模組呼叫,但依 LAW-6 仍須留在白名單)與
`test/` 既有的 `name-shadowing` 警告,無 `-Werror`,不擋建置。

**改善目標對照表**(2026-08-30 `cabal test aapms-workspace-test`,310 examples,
**1 failure**、**3 pending**):

| 指標 | 基準線 | 完成判準 | 本輪結果 |
|---|---|---|---|
| pending 數 | 3 | 0 | **3(未達成)** |
| failures | 0 | 0 | **1(倒退,見下)** |
| examples | 310 | ≥ 310 | 310 |
| `VaultIdCollision` 斷言數 | 0 | ≥ 1 | 0(未達成) |
| `VaultInitFailed` 斷言數 | 0 | ≥ 2 | 0(未達成) |
| `workspace/spec-gaps.md` 未結條目 | 1(GAP-4) | 0 | 1(未達成) |
| `service` 受影響行數 | — | 0 | **0** |

**未達成的原因不在 impl 這一側**:`LifecycleSpec.hs` 至今仍是 E001 開工前的舊版——
GAP-4/GAP-5 提到的三條 `pendingWith`(`:485` / `:519` / `:526`)一條都沒被翻成正式斷言,
`:978-984` 的 `test_lifecycle_marker_import_is_exact` 仍斷言 **F004 修訂前**的舊字串
(`... initVaultAt, markerDir, readMarker`),而不是 F004 doc 已經改好、E001 LAW-6 要求的新
字串(`... initVaultAt, initVaultAtWith, markerDir, readMarker`——`F004-vault-lifecycle.md:591`
已經是新字串,只有測試檔沒跟上)。`Lifecycle.hs` 的 import 行照 spec 改成新字串後,這條舊
斷言必然由綠轉紅——**這是預期中的紅,不是實作缺陷**:骨架段落早已言明 LAW-6 在骨架階段就該紅
(舊字串),而測試檔對它的翻譯至今仍卡在骨架階段之前那版。qa 對 `LifecycleSpec.hs` 的這一輪
更新(LAW-18/LAW-19/EX-18/EX-19、LAW-44/EX-41 轉正,LAW-42(b) 斷言換成新字串)不在本次委派範圍內,依角色禁區
impl 不得碰測試檔,原樣列為阻塞項回報編排者。

實作本身的正確性只能對照 spec 的 Laws/Examples 手動核對(見回報),核對結果與 LAW-1–LAW-7、
REG-1–REG-6 逐條相符,無需為此改動骨架簽名或另記 spec-gap。
