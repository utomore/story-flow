---
id: B001
type: bugfix
title: fixture-vault-layout
description: 測試 fixture 的 vault 目錄配置不符主架構,已擴散到三個測試檔
status: done
created: 2026-08-27
updated: 2026-09-04
depends-on: []
related-adr: [ADR-013]
related-feature: [graph-core/F006, graph-core/F008, graph-core/F009, graph-core/F007]
code-paths: [md/src/Aapms/Md/Error.hs, store/aapms-store.cabal, store/test/Aapms/Store/CreateSpec.hs, store/test/Aapms/Store/Fixtures.hs, store/test/Aapms/Store/IndexSpec.hs, store/test/Aapms/Store/MultiVaultSpec.hs, store/test/Aapms/Store/SearchSpec.hs, store/test/Aapms/Store/VaultLayoutSpec.hs, store/test/Aapms/Store/WriteSpec.hs, store/test/Spec.hs]
---

# B001: 測試 fixture 的 vault 目錄配置不符 `system.md:439`

## 症狀

`system.md:439` 對 asset vault 的目錄配置是明訂的:

```text
<asset vault>/
├── .aapms/{config.toml, index.db}
├── library/
│   ├── licenses.md                 ← 授權節點(lic-)
│   ├── packs/<vendor>/<pack-slug>/
│   │   └── pack.md
│   ├── reference/<topic>/
│   └── studio/
```

`store/test/` 的 fixture 有三份把 `pack.md` 與 `licenses.md` 放在 **vault 根目錄**,少了
`library/` 這一層。三份 fixture 因此描述了一個**在真實 vault 裡不會出現的形狀**,而 273 條
store 測試全部建立在這個形狀上。

**不是產品缺陷**:`Aapms.Store.Index` 的 `isReferencePath`(`Index.hs:350-351`)以
`"library/reference/"` 做 infix 比對,reference 的判定不受非 reference pack 的路徑影響;
索引與查詢也不對 `licenses.md` 的位置有任何假設。**壞的是測試對主架構的忠實度**——
以及它正在擴散。

**影響範圍與擴散軌跡**:

| 時間 | 事件 |
|---|---|
| F006(2026-08-23) | `Fixtures.hs` 首次把 `licenses.md` 放在 vault 根、pack 放在 `packs/` |
| F008(2026-08-25) | `WriteSpec.hs` 的 LAW-8 撞上這件事,被仲裁糾正;qa **另建**一份路徑正確的 fixture,並在 `:339-341` 留下註解說明「不沿用 F006 那份」——**個案繞開,沒有修源頭** |
| F007 | `SearchSpec.hs:299` 照抄 `packs/…` |
| F009(2026-08-26) | `MultiVaultSpec.hs:363-364` 再照抄一次 |
| 階段三閘門(2026-08-26) | 列為「留給後續的四條」第 1 條,建議走 `/bugfix` |
| `/arch-audit subsys graph-core`(2026-08-27) | 複查:狀態不變,且發現偏離範圍不只 `licenses.md`,pack 路徑同樣少了 `library/` |

擴散的機制很清楚:**沒有任何測試在斷言 vault 的目錄配置**,所以新的 fixture 只會照抄最近的
那一份,而最近的那一份是錯的。

## 重現步驟

不需要跑程式,`grep` 即可穩定重現(修復前):

```
$ grep -rn '"packs/\|"licenses.md"' store/test/Aapms/Store/Fixtures.hs \
      store/test/Aapms/Store/MultiVaultSpec.hs store/test/Aapms/Store/SearchSpec.hs
Fixtures.hs:264:  [ ("packs/test-vendor/pack.md", assetPackMd)
Fixtures.hs:265:  , ("licenses.md", assetLicensesMd)
MultiVaultSpec.hs:363:  [ ("packs/potions/pack.md", potionsPackMd)
MultiVaultSpec.hs:364:  , ("licenses.md", bLicensesMd)
SearchSpec.hs:299:  , ("packs/fts-vendor/pack.md", ftsPackMd)
```

對照 `WriteSpec.hs:344` 的 `licensesPath = "library/licenses.md"`(唯一正確的一份),
**三份 fixture 兩種寫法**。

機械化的重現條件寫成 STEP-1 的測試(見下):對每一份 vault fixture 的檔案組,
「每個 `licenses.md` 的路徑等於 `library/licenses.md`」與「每個 `pack.md` 的路徑以
`library/` 開頭」兩條在修復前皆為假。

## 根因分析

**直接原因**:`store/test/Aapms/Store/Fixtures.hs:264-265` 的 `assetVaultFiles` 寫錯路徑,
後續 fixture 照抄。

**根本原因**:`system.md:439` 的目錄配置**沒有任何機械化的守衛**。它是一張畫在架構文檔裡的樹,
程式碼這一側只有 `isReferencePath` 一處在用它(而且只用到 `library/reference/` 那一枝),
其餘每一枝都只靠寫 fixture 的人記得。F008 的仲裁已經撞到過一次,處置是「本檔自己建一個正確的」
——把個案繞開,讓源頭繼續散播。

這與本子系統已經被咬過三次的形狀是同一個:**單一路徑(或單一 vault、單一層級)能跑對的東西,
換到另一種形狀就悄悄失效,而既有測試全都在能跑對的那一側**。

## 修復方向

1. **先立守衛**:在 `Fixtures.hs` 加一個純函式 `vaultLayoutViolations`,吃一份 vault 檔案組,
   回傳違反 `system.md:439` 的路徑清單。判準只取兩條**機械可判定**的子句,避免重蹈 GAP-3 / GAP-12
   (文字掃描分不出註解與程式碼)的覆轍——這裡比對的是 fixture 的**資料結構**,不是原始碼文字:
   - 路徑的檔名是 `licenses.md` → 路徑必須恰好是 `library/licenses.md`
   - 路徑的檔名是 `pack.md` → 路徑必須以 `library/` 開頭
   (`packs/` / `reference/<topic>/` / `studio/` 三種 pack 位置的深度不同,所以只約束前綴,
   不約束層數)
2. 新增 `Aapms.Store.VaultLayoutSpec`,對測試套件裡**每一份** vault 檔案組斷言上述兩條;
   接進手寫彙總器 `store/test/Spec.hs` 與 `aapms-store.cabal` 的 `other-modules`
   (E001 的教訓:`Spec.hs` 不是 `hspec-discover`,沒接線的模組不會跑)
3. 修正三份 fixture 的路徑,並同步更新以路徑字面定位的斷言
4. `WriteSpec.hs:339-341` 那段「不沿用 F006 fixture」的註解在源頭修好後已失效,一併更新

**明確不動**:`CreateSpec.hs:252/267/288` 的 `packs/e3-fixture` 等路徑是**呼叫端傳給
`createPackFile` 的目錄參數**(契約 E 的目錄由 `NewPack` 帶入,不是 vault 形狀的宣告),
不在本次範圍;`CreateSpec.hs:346` 讀的是共用 fixture,要跟著改。

**不動公開契約**:本次只改測試檔與一則註解,`aapms-store` 與 `aapms-md` 的對外簽名零變動。

**替代方案(未採用)**:把驗證塞進 `writeFiles`,讓任何 fixture 一寫就檢查。結構上更強
(零 opt-in),但違規會以 setup 期例外的形式炸掉整批測試而不是一條紅燈,失敗訊息也差。
本次採「純函式判準 + 專屬 spec」,代價是新增 vault fixture 時要記得加進 `VaultLayoutSpec`
的清單——已在該檔頂端寫明。

## TodoList

- [x] STEP-1: `Fixtures.hs` 加 `vaultLayoutViolations` 純函式並匯出;新增 `VaultLayoutSpec` 斷言五份 fixture 檔案組,接進 `Spec.hs` 與 `.cabal`;確認**修復前失敗** `dep: -`
- [x] STEP-2: 修正 `Fixtures.hs` 的 `assetVaultFiles` 路徑 `dep: T1`
- [x] STEP-3: 修正 `MultiVaultSpec.hs` 的 `vaultBFiles` 路徑 `dep: T1`
- [x] STEP-4: 修正 `SearchSpec.hs` 的 `ftsVaultFiles` 路徑 `dep: T1`
- [x] STEP-5: 同步 `IndexSpec.hs` / `WriteSpec.hs` / `CreateSpec.hs` 以路徑字面定位的斷言 `dep: T2,T3,T4`
- [x] STEP-6: 更新 `WriteSpec.hs:339-341` 已失效的註解 `dep: T2`
- [x] STEP-7: 修正 `md/src/Aapms/Md/Error.hs:98` 的誤導註解(宣稱骨架留 `undefined`,該分支早已實作) `dep: -`

## 驗證方式

- STEP-1 的測試在修復前為紅(逐條列出違規路徑)、STEP-2–STEP-5 後轉綠
- `cabal test all` 全綠,且 store 的 example 數只增不減(修復前 273)
- `grep -rn '"packs/\|"licenses.md"' store/test/` 在 fixture 檔案組裡零命中

## 修復紀錄

**實際修法與「修復方向」一致,無偏差。**

守衛(STEP-1):

- `store/test/Aapms/Store/Fixtures.hs:283-298` 新增純函式
  `vaultLayoutViolations :: [(FilePath, Text)] -> [FilePath]`,已匯出;路徑先正規化反斜線再比對
- 新增 `store/test/Aapms/Store/VaultLayoutSpec.hs`(LAW-1 / LAW-2 對五份檔案組各一條,加 EX-3 證明
  判準不是恆真),接進 `store/test/Spec.hs` 與 `store/aapms-store.cabal` 的 `other-modules`
- `MultiVaultSpec` / `SearchSpec` 的模組匯出各多一項(`vaultAFiles` / `vaultBFiles` /
  `ftsVaultFiles`),讓守衛掃得到原本是模組私有的檔案組

**修復前的紅燈(STEP-1 驗收,已實際觀測)**:279 examples / **3 failures**,逐條指出違規路徑——

```
Fixtures.assetVaultFiles      expected: []  but got: ["packs/test-vendor/pack.md","licenses.md"]
MultiVaultSpec.vaultBFiles    expected: []  but got: ["packs/potions/pack.md","licenses.md"]
SearchSpec.ftsVaultFiles      expected: []  but got: ["packs/fts-vendor/pack.md"]
```

同一輪 `storyVaultFiles` / `vaultAFiles` 為綠、EX-3 為綠,所以不是「整批全紅」也不是斷言恆真。

路徑修正(STEP-2–STEP-5)——一律補足 `system.md:439` 的完整形狀,pack 連 `<pack-slug>` 那一層也補上:

| 檔案 | 修正前 | 修正後 |
|---|---|---|
| `Fixtures.hs` `assetVaultFiles` | `packs/test-vendor/pack.md` | `library/packs/test-vendor/test-pack/pack.md` |
| `Fixtures.hs` `assetVaultFiles` | `licenses.md` | `library/licenses.md` |
| `MultiVaultSpec.hs` `vaultBFiles` | `packs/potions/pack.md` | `library/packs/test-vendor/potions/pack.md` |
| `MultiVaultSpec.hs` `vaultBFiles` | `licenses.md` | `library/licenses.md` |
| `SearchSpec.hs` `ftsVaultFiles` | `packs/fts-vendor/pack.md` | `library/packs/fts-vendor/fts-pack/pack.md` |
| `IndexSpec.hs`(9 處) | `packs/test-vendor/pack.md`、`packs/dup/pack.md` | 對應的 `library/packs/…` |
| `WriteSpec.hs`(2 處)、`CreateSpec.hs:346` | `packs/test-vendor/pack.md` | `library/packs/test-vendor/test-pack/pack.md` |

註解(STEP-6 / STEP-7):

- `WriteSpec.hs:337-342` 的「不沿用 F006 fixture」理由已失效(源頭已修),改寫成仍然成立的
  理由(LAW-8 只需要一份乾淨的授權檔),並註記原理由已被 B001 解除
- `md/src/Aapms/Md/Error.hs:98` 原文宣稱 `HeadingTooDeep` 分支「骨架留 undefined」,該分支
  在 F004 交付時就已填實,註解已成誤導。改寫成「建骨架時刻意留 undefined……交付後已填實」,
  保住原本要傳達的設計理由(spec 與 impl 兩次獨立轉錄)而不再誤導後人

**驗證結果(編排者外實跑)**:

- `cabal build all` 全綠
- `cabal test all`:`aapms-core` 224 / 0、`aapms-types` 42 / 0、`aapms-md` 327 / 0、
  `aapms-store` **279 / 0**、`aapms-contract-rules-test` 6 / 0 —— 合計 **878 examples、0 failures**
- store 由 273 增為 279(+6 = VaultLayoutSpec 的 5 條 fixture 斷言 + EX-3),**沒有任何既有測試
  因為改路徑而失效**——這也順帶證明了沒有斷言是靠舊路徑成立的
- hedgehog 相關連跑三次,`aapms-store` 三次皆 279 / 0
- `grep -rn '"packs/\|"licenses.md"' store/test/` 在 fixture 檔案組裡零命中;剩餘命中只有
  `CreateSpec` 的呼叫端目錄參數(明確不動)、判準本身與 `VaultLayoutSpec` 刻意違規的
  `badFixture`

**沒有順手做的事**:`CreateSpec.hs:252/267/288/290` 的 `packs/e3-fixture` 等一律未動——
那些是傳給 `createPackFile` 的目錄參數,不是 vault 形狀的宣告。

**建議另開的項目(本次未做)**:`/arch-audit subsys graph-core`(2026-08-27)的中-1
——`aapms-store` 的 `Atomic` / `Schema` / `Tokenize` / `Query` 與 `aapms-md` 的 `Lexer` / `Yaml`
仍有約 48 個契約未登記的符號在 `exposed-modules` 上,是 E001 沒掃完的同類洞。屬改善而非缺陷,
應走 `/enhance-design` 開 E002,不在本文檔範圍。
