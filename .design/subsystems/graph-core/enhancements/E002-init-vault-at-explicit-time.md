---
id: E002
type: enhance
title: init-vault-at-explicit-time
description: initVaultAt 的時間提成明碼參數,與 allocateId 的 G8 裁決一致
status: open
created: 2026-08-29
updated: 2026-08-29
parent: graph-core
depends-on: []
---

# E002:`initVaultAt` 的時間提成明碼參數

## 發現經過

2026-08-29 `/subsys-build workspace` 的 **W4 階段二閘門**,由 F004 的 qa 回報(workspace 的
spec-gaps **G4**)。`workspace` 是 `initVaultAt` 的第一個消費者。

## 現況

```haskell
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
initVaultAt givenRoot kind name = do
  ...
  now <- getCurrentTime                       -- ← 內部取樣
  let vid = VaultId (renderId (newId PVlt name now 0))
```

`workspace` 的 `initVault` 在拿到 marker 之後,要比對它的 id 與中樞既有的 `veId`,撞號就回
`VaultIdCollision`(契約 F)。**但 qa 造不出那個碰撞**:時間藏在函式內部,呼叫端無法讓兩次
呼叫產生同一個 id;而 qa 依角色禁區**不得讀** `newId` 的實作去反推。

結果:`VaultIdCollision` 這條路徑上的 **L18 / L19 / X18 / X19 全部停在 `pendingWith`**,
既不是紅也不是綠。

## 這個問題 graph-core 自己已經解過一次

`allocateId` 的 **2026-08-25 G8 裁決**(見 `graph-core/design.md` 契約 E)逐字寫著:

> 時間是明碼參數,與 `aapms-core` 的 `newId` 一致:藏在函式內部取樣,呼叫端就無法預先造出碰撞,
> salt 重試迴圈也就永遠測不到——而碰撞在正常情況下幾乎不發生,那段程式碼可能永遠是錯的而沒人知道

`initVaultAt` **沒有跟著改**,是 graph-core 內部的不一致。

同一個判準在 2026-08-29 的 workspace W4 閘門又被套用了兩次:`allocateProjectId`(時間明碼)與
`detectSevenZipIn`(探測計畫明碼)。這會是第四次。

## 修法(2026-08-29 開發者裁決)

把時間提成明碼參數,形狀與 `allocateId` 對齊。簽名的具體形式(加參數 vs 另開一個
`initVaultAtWith` 而讓原簽名成為薄包裝)留給 spec 階段決定——**兩種都不改變既有呼叫端的
語意**,差別只在對外契約多一條還是改一條。

**被否決的替代方案**:

- **撤掉 workspace 那條驗收標準**:不動任何程式碼。否決理由是 `VaultIdCollision` 建構子與
  `initVault` 的那段判斷都還在,只是**永遠沒有人驗得到**——那正是 G8 那段話描述的狀態。
- **維持 pending**:否決理由是 pending 既不紅也不綠,不會讓任何人停下來,那條驗收標準
  實際上已經失效。

## 連帶

- 與 **B002**(`initVaultAt` 讓 `IOException` 逸出)是**同一個函式、同一輪**要做的事,合併處理。
- 修完後 `workspace` 的 spec-gaps **G4** 可結案,F004 的 **L18 / L19 / X18 / X19** 從
  `pendingWith` 轉成正式斷言。
- 契約 E 的 `initVaultAt` 那一列要同步更新;`workspace` 的 F004 spec 與 `Lifecycle.hs` 的呼叫端
  會跟著改一行。
