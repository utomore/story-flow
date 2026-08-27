---
id: B001
type: bugfix
title: vault-registry-bare-key
description: 中文 Vault 名被寫成 TOML 裸 key,全域 vaults.toml 下一次就解析失敗
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-008]
related-feature: [F004]
---

# B001: 中文 Vault 名寫壞全域註冊表

## 症狀

`story-flow vault init <目錄> --name 測試世界` 成功(exit 0),但之後**任何**讀全域註冊表的
操作全部失敗:`--vault <名稱>` 定址、`vault list`、起 `story-flow-serve`、MCP 的 `initialize`。
訊息:

```
vaults.toml: Vault 設定檔無法解析 —— 2:1:
2 | 測試世界 = "."
  | ^^
unexpected '測'
expecting "[[", '[', [A-Za-z0-9_-], double-quoted string, …
```

**影響範圍是全域的**:壞的是 `%APPDATA%\story-flow\vaults.toml`,一個中文名就讓這台機器上
所有 Vault 一起讀不到。2026-08-22 的 smoke test 第一步就踩到。

## 重現步驟

```
story-flow vault init . --name 測試世界      # exit 0
story-flow vault list                        # vault_config_invalid
```

最小重現碼(已成回歸測試 `store/test/StoryFlow/Store/VaultSpec.hs`):

```haskell
registerVaultIn reg "測試世界" dir `shouldReturn` Right ()
fmap M.keys <$> loadVaultRegistryFrom reg `shouldReturn` Right ["測試世界"]
```

修復前:`Left (VaultConfigInvalid … "unexpected '測'")`。

## 根因分析

`store/src/StoryFlow/Store/Vault.hs:244`(`registerVaultIn`):

```haskell
appendMissingLines regFile [name <> " = " <> quote (T.pack (toSlash root))]
--                          ^^^^ key 沒引號         ^^^^^ value 有引號
```

TOML 的裸 key 只准 `[A-Za-z0-9_-]`,其他字元的 key 必須加引號。`quote` 函式就在同一個檔案裡
(`:282`),value 有用、key 沒用。ASCII 名字(`liftgame`、`gatecheck`)剛好落在裸 key 的合法範圍,
所以既有測試全綠 —— **沒有任何測試用過非 ASCII 的 Vault 名**,而這個工具的全部輸出與預期使用
者都是繁體中文。

## 修復方向

key 也走 `quote`。`quote` 做的逃逸(`"` → `\"`、`\` → `\\`)對 key 與 value 是同一套 TOML 規則,
不需要第二個函式。讀取端(`loadVaultRegistryFrom`)用的是 TOML 解析器,引號 key 本來就認得,
不用動。

**最小修復**:一行。不順手重構 `registerVaultIn`。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗)  `dep: -`
- [x] T2: `registerVaultIn` 的 key 走 `quote`  `dep: T1`

## 驗證方式

- `cabal test storyflow-store`:T1 由紅轉綠,其餘 167 條不變
- 實跑:`vault init . --name 測試世界二` 後 `vaults.toml` 出現 `"測試世界二" = "…"`,`vault list`
  正常

## 修復紀錄

照「修復方向」一行修完,無偏差。`store-test` 167 → 169(含 B002 的一條)。

**順帶發現**:既有的 ASCII 名字登記在檔案裡仍是裸 key(`gatecheck = "…"`),與新寫入的引號 key
混在同一份檔案 —— TOML 兩種都合法,解析器一視同仁,不需要遷移。
