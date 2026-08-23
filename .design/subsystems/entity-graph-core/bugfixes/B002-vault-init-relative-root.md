---
id: B002
type: bugfix
title: vault-init-relative-root
description: initVault 把呼叫端給的相對路徑原樣當 vaultRoot,寫進全域註冊表後定址失效
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-008]
related-feature: [F004]
---

# B002: `vault init .` 把相對路徑寫進全域註冊表

## 症狀

`story-flow vault init . --name myworld` 之後,全域 `vaults.toml` 多了一行
`myworld = "."`。在別的目錄下 `story-flow --vault myworld …` 會把「目前目錄」當成那個
Vault 的根 —— 找不到 `.storyflow/` 就報 `vault_not_found`,更糟的是如果目前目錄剛好也是
某個 Vault,就**靜默操作到錯的 Vault**。

ADR-008 的「`--vault <名稱>` 查全域註冊表」這條設計,在使用者用最自然的寫法(`init .`)時
直接失效。2026-08-22 smoke test 的 `vaults.toml` 裡就有一筆 `測試世界 = "."`。

## 重現步驟

```
cd /some/dir
story-flow vault init . --name relworld
cd /elsewhere
story-flow --vault relworld vault info     # vault_not_found,或指到 /elsewhere
```

最小重現碼(已成回歸測試 `store/test/StoryFlow/Store/VaultSpec.hs`):

```haskell
v <- withCurrentDirectory dir (initVault "." "relworld")
isAbsolute (vaultRoot v) `shouldBe` True
```

修復前:`False`。

## 根因分析

`store/src/StoryFlow/Store/Vault.hs:253`(`initVault root name`):`root` 從頭用到尾都是
呼叫端給的原字串,最後 `loadVaultAt root` 建出的 `Vault` 的 `vaultRoot` 就是 `"."`。
`service` 的 `createVault` 接著把 `vaultRoot v` 交給 `registerVaultIn` 寫進全域檔。

兩個呼叫端(CLI 的 `vault init`、REST 的 `POST /vaults`)都沒有在交給 `store` 之前轉絕對
路徑,而 `store` 也沒有。沒有人負責,所以沒有人做。

## 修復方向

在 `initVault` 一進來就 `makeAbsolute`。放在 `store` 而不是各個呼叫端:`vaultRoot` 這個值會
被寫進全域檔、被從任何目錄拿來定址,「它必須是絕對路徑」是 `Vault` 這個型別的不變量,該由
建構它的地方保證,不該讓每個呼叫端各記一次。

`resolveVaultWith` 比對路徑時用 `normalise`,絕對路徑不影響既有行為。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗)  `dep: -`
- [x] T2: `initVault` 開頭 `root <- makeAbsolute givenRoot`  `dep: T1`

## 驗證方式

- `cabal test storyflow-store`:T1 由紅轉綠
- 實跑:在臨時目錄 `vault init . --name 測試世界二`,`vaults.toml` 寫的是
  `"測試世界二" = "C:/Users/…/tmp…"`,不是 `"."`

## 修復紀錄

照「修復方向」修完,無偏差。與 B001 同一次 smoke test 找到、同一個函式附近,
兩者合成一個 commit。
