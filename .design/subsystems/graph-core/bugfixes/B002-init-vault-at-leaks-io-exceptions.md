---
id: B002
type: bugfix
title: init-vault-at-leaks-io-exceptions
description: initVaultAt 宣告回 Either StoreError 卻讓 IOException 逸出,型別在說謊
status: open
created: 2026-08-29
updated: 2026-08-30
parent: graph-core
depends-on: []
---

# B002:`initVaultAt` 讓 `IOException` 逸出

## 發現經過

2026-08-29 `/subsys-build workspace` 的 **W4 階段二閘門**。`workspace` 是 `initVaultAt` 在整個
codebase 的**第一個消費者**(knot 反向可達查證:此前 decl 層零呼叫者),這兩個洞因此到現在才現形。

由 F004 的 qa 在寫 X41 的測試時撞到並回報(workspace 的 spec-gaps **G5**),經編排者查證屬實。

## 現象

`store/src/Aapms/Store/Marker.hs`:

```haskell
initVaultAt :: FilePath -> VaultKind -> Text -> IO (Either StoreError VaultMarker)
initVaultAt givenRoot kind name = do
  root <- makeAbsolute givenRoot              -- ← 可拋
  exists <- doesFileExist (configPath root)
  if exists
    then pure (Left (VaultAlreadyInitialized root))
    else do
      createDirectoryIfMissing True (markerDir root)   -- ← 可拋,實測會拋
      ...
```

實測:當 vault 根目錄的**父層被一個檔案佔住**時,`createDirectoryIfMissing` 把
`CreateDirectory ... AlreadyExists` 這個 `IOException` **未捕捉地往上拋**,而不是回傳 `Left`。

## 為什麼是缺陷而不是設計

1. **型別在說謊**。簽名承諾了 `Either StoreError`,呼叫端因此有理由相信失敗都走那條通道。
2. **違反主架構的全域錯誤處理策略第 2 條**:「執行檔與 HTTP handler 層必須攔截並翻譯所有例外,
   **資料庫錯誤與檔案系統例外同樣不得逸出**」。一個底層函式把檔案系統例外丟給上層,等於把
   翻譯責任推給每一個消費者。
3. **它讓下游的錯誤值變成不可達**。`workspace` 在 W4 閘門為此新增了 `VaultInitFailed`
   (契約 F),而那個建構子的**唯一驗收路徑**就是「`initVaultAt` 回 `Left`」——現在驗不到。
   這與 graph-core 自己在 `allocateId` 的 2026-08-25 **G8 裁決**擔心的是同一件事:
   「那段程式碼可能永遠是錯的而沒人知道」。

## 修法(2026-08-29 開發者裁決:修 graph-core,不在 workspace 這層補例外邊界)

把 `initVaultAt` 內所有會拋 `IOException` 的呼叫包起來,轉成既有的 `StoreError` 建構子
(或視需要擴充一個)。**簽名不變**——它本來就承諾了這件事。

**被否決的替代方案**:

- **在 `workspace` 的 `initVault` 用 `try` 補一道例外邊界**:局部、不動 graph-core。否決理由是
  型別謊言還在,下一個消費者(`service` 包 workspace 時)會再踩一次;而且 `aapms-store` 裡
  可能還有別的函式是同一個寫法,修在根上才看得到。
- **只找一個確實會回 `Left` 的重現方式**:不改任何程式碼。否決理由是那條測試會綠,但它驗的是
  一條不具代表性的路徑——真實情境(磁碟滿、權限不足、路徑被佔)仍然是拋例外,而那些才是
  `VaultInitFailed` 要守的。

## 連帶

- 與 **E002**(`initVaultAt` 的時間提成明碼參數)是**同一個函式、同一輪**要做的事,合併處理。
- 修完後 `workspace` 的 spec-gaps **G5** 可結案,F004 的 **L44 / X41** 從 `pendingWith` 轉成
  正式斷言。
- 順手檢查 `aapms-store` 其他 `IO (Either StoreError a)` 的函式有沒有同一個寫法。

## 執行方式(2026-08-30)

依「連帶」的裁決,本缺陷**不另外跑 `/bugfix`**,併進 **`graph-core/E002`** 的同一份 spec 執行
(兩者是同一個函式、同一輪)。對應條文:

| 本文檔的主張 | E002 的條文 |
|---|---|
| `initVaultAt` 不得讓 `IOException` 逸出 | **L4**(對任意輸入都不拋,失敗一律回 `Left`) |
| 轉成既有的 `StoreError` 建構子 | **L5**(父層被檔案佔住 → `Left (FileWriteFailed (markerDir root) msg)`) |
| 重現方式 | **E5 / E6**(`blocker` 是一般檔案,對 `blocker/sub` 呼叫兩個入口各一次) |

E002 的測試全綠後本文檔一併改 `done`,`workspace` 的 spec-gap **G5** 同時結案。

**scope 未擴大**:2026-08-30 的 `/arch-audit subsys graph-core` 發現 `aapms-store` 另有**四處**同類的
逸出(`ensureDir` @ `Edit.hs:246`、`vaultMarkdownFiles` @ `Walk.hs:40`、`toVaultRelative` @
`Index.hs:69`、`openVault` @ `Marker.hs:196`),逃進 `commit` / `upsertLicense` / `rebuildIndex` /
`refreshStale` / `indexFile` / `unindexFile` / `openVault` 這些契約 E 明列、宣告回 `Either StoreError`
的函式。本文檔原文的修法只寫「把 `initVaultAt` 內所有會拋 `IOException` 的呼叫包起來」,
**擴大到四處是新的 scope 決定**,待開發者裁決後另開 B003。
