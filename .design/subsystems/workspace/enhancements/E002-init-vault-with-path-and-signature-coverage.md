---
id: E002
type: enhance
title: init-vault-with-path-and-signature-coverage
description: 補 initVaultWith 的 vePath 斷言,並修 LAW-3 不可滿足的措辭
status: planned
created: 2026-08-30
updated: 2026-09-04
depends-on: [workspace/E001, workspace/F004]
related-adr: [ADR-017]
related-feature: [workspace/F004]
code-paths: []
---

# E002:`initVaultWith` 的 `vePath` 覆蓋缺口,與 LAW-3 的措辭修正

> **本檔由 `/arch-audit feature workspace/E001`(2026-08-30)建立,只記錄發現與依據,
> 不是 spec。** 真要動手,先走 `/spec-design` enhance 更新模式談 scope、寫 Laws/Examples
> 與骨架——本檔的「建議修法」只是分析結論,不具備 spec 的效力,qa 與 impl 不得直接拿它施工。

## 為什麼開這一份

`workspace/E001` 已於 2026-08-30 交付並全綠(`aapms-workspace-test` 319/0/0)。
**程式碼行為是對的,本檔記的兩條都不是執行期缺陷**,而是**驗收覆蓋**與 **spec 措辭**的問題。

## 發現一(中):LAW-3 的條文不可滿足,`initVaultWith` 的 `vePath` 沒有任何斷言

### 條文與現實對不上

E001 的 **LAW-3(薄包裝等價)**原文:

> `initVault loc hub **d** kind name mode` 的結果,除了 `veId` 之外,與
> `initVaultWith loc hub **d** kind name mode t`(任意 `t`)逐欄相同:
> `veName` / `veKind` / **`vePath`** 一致、`AdoptNotice` 一致、落地的檔案集合一致、
> 中樞新增的列數一致

**這個情境不可達**:兩次呼叫用**同一個 `d`**,第一次會建出 `.aapms/`,第二次必然回
`VaultAlreadyInitialized`——那正是 E001 自己的 **REG-2** 規定的行為。LAW-3 字面要求的「兩個
`Right` 逐欄比較」永遠取不到。

### qa 實際怎麼做

`workspace/test/Aapms/Workspace/LifecycleSpec.hs:674-694`(`L3(property)`):改用**兩個
不同目錄** `d1` / `d2`,比較的元組是

```haskell
( veName e, veKind e, notice, length (hubVaults hub'), files )   -- files = .aapms/ 底下排序後的檔名
```

——**`vePath` 被排除在比較之外**。測試名逐字寫著「除 `veId`\/`vePath` 外逐欄相同」,
所以**不算隱瞞**;但依 `spec-roles.md`「spec-gaps 協議」,spec 內部矛盾時 qa 應該
**停下該項並記一條 gap**,而不是自行改寫 law 的內容。這是 E001 那一輪唯一一次協議被繞過。

### 後果:一個契約欄位零覆蓋

| 入口 | `vePath` 的斷言 |
|---|---|
| `initVault` | 有 —— `LifecycleSpec.hs:605`、`:430` 的 `vePath e \`shouldBe\` canonV` |
| **`initVaultWith`** | **一條都沒有** |

而 `vePath` 是 `design.md` 契約 B 明訂的欄位:

> `vePath` | FilePath | 絕對路徑,**正規化 = `System.Directory.canonicalizePath`**
> (2026-08-29 WAVE-2 閘門釘死):解 `.` / `..`、解 symlink、還原 Windows 8.3 短檔名

WAVE-2 閘門**特意否決**了 `makeAbsolute`(純字串、不碰檔案系統、好測,但 `C:\x\..\y` 與
`C:\y` 是兩個字串,8.3 短檔名與 symlink 都不還原)。也就是說這一欄的正規化方式是被論證過的
不可逆決定,現在新入口上沒有任何東西守它。

**目前沒有壞**:`Lifecycle.hs:188` 的 `dir' <- canonicalizePath dir` 住在 `initVaultWith`
裡,兩個入口共用同一行,所以行為正確。但它是靠「實作剛好對」守著,不是靠斷言守著——
日後有人把那一行改成 `makeAbsolute` 或拿掉,**整套測試不會紅**。

### 建議修法(分析結論,不是 spec)

1. LAW-3 改寫成兩個**相異**目錄的等價性,並明列比較欄位(把 `vePath` 從「一致」改成
   「各自等於自己的正規化路徑」)
2. 補一條 `initVaultWith` 的 `vePath` 斷言,形狀比照 `LifecycleSpec.hs:605`
3. 可考慮把「`vePath` 一律等於 `canonicalizePath` 的結果」提成一條獨立的 law,讓兩個入口
   共用——這比在兩處各寫一條更貼近「契約 B 的那一欄只有一種正規化」

## 發現二(低):REG-1「簽名逐字等於」沒有逐字驗證

E001 的 **REG-1** 要求 `initVault` 的型別簽名**逐字等於**

```haskell
initVault :: HubLocation -> Hub -> FilePath -> VaultKind -> Text -> InitMode -> IO (Either WorkspaceError (Hub, VaultEntry, AdoptNotice))
```

qa 的對照表(`LifecycleSpec.hs:112`)填的是「由既有呼叫端持續以 6 參數呼叫 `initVault`
編譯通過保證」。

**編譯通過擋不到「逐字」層級**:Haskell 的 `type FilePath = String`,把簽名裡的 `FilePath`
換成 `String`,編譯結果完全一樣、所有呼叫端照過,而 REG-1 的字面要求已經被違反。

這個專案本來就有**逐字比對原始碼文字**的慣例(`lifecycleImportLines` 那一組 LAW-42 測試,
`LifecycleSpec.hs:1146` 附近),REG-1 用同一套手法做得到。

**實際風險低**:`design.md` 契約 D 也釘著這條簽名,而且 `/arch-audit` 的「骨架符合度」檢查
會比對簽名原文(2026-08-30 這次就是這樣驗過的)。

### 建議修法(二擇一)

- 補一條逐字比對 `initVault` 簽名行的測試(比照 LAW-42 的做法,比對前去除行尾 `\r`);或
- 把 REG-1 的措辭從「逐字等於」放寬成「arity 與參數型別不變」,讓條文與驗證方式對齊

兩者都可以,重點是**條文與驗證手段必須一致**——目前是條文寫得比驗證強。

## 明確不在本檔範圍

- **`Lifecycle.hs:188` 那個沒包 `try` 的 `canonicalizePath`**:E001 的 Scope 已明文排除,
  而且 E001 只是把它從 `initVault` 搬到 `initVaultWith`,全專案未受保護的呼叫仍是一處、
  風險未變。要處理請另開文檔,不要併進本檔
- **任何 `service` / `graph-core` 的改動**:本檔兩條都落在 `workspace` 的測試與 spec 措辭

## 本次檢測通過的項目(備查)

`/arch-audit feature workspace/E001` 2026-08-30 的其餘檢查全部通過:Level 2 介面符合度
(契約 D 兩條簽名與程式碼逐字相同)、骨架符合度(impl 未動任何簽名或型別)、
Laws/Examples 對照(13 條 law 全部有測試、10 個 example 全部有具名測試、**qa 腦補 0 條**)、
邊界與依賴(新增的兩個 import 都已登記、新增依賴邊 0、`.cabal` 未動)、
**無測試後門**(`hubWith` 走公開的 `mkHub`,測試只 import 公開模組)。
