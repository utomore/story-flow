---
id: B006
type: bugfix
title: sync-license-warning-scope
description: 同步的授權降級警告只涵蓋本次候選,不在篩選內的既有素材包被靜靜吞掉
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: []
related-feature: [F006]
---

# B006: 授權降級警告的涵蓋範圍小於契約

## 症狀

`assetdb project sync --name X --pack foo` 時,專案裡既有的 `bar` 包若授權已降級為不可
商用(或被改回未查證),`bar` 的素材**照樣被寫進重新產生的 `manifest.json` 與 `Assets.hs`**
(這是契約要的:閘門只擋新增、不回溯既有),卻**不會出現在任何警告裡**。

- 預期:重寫的產物涵蓋登記全集,警告就必須跟著全集(design.md §6「授權閘門只擋新增,
  不回溯既有」最後一段)。
- 實際:只有本次 `--pack` / `--match` 命中的候選素材,其所屬素材包才會被查授權。不在
  篩選條件內的既有素材包,授權問題靜靜通過。
- 影響:使用者以為「同步跑完沒警告 = 可以發行」,但專案裡實際帶著不可商用素材。這是
  整個子系統少數帶法律後果的判斷。

## 重現步驟

1. 專案 `game` 已登記,`project_assets` 裡有 `noncomm` 包的既有素材(該包 `commercial = 0`)。
2. 跑 `planSync`,只帶 `--pack comm`(即 `soPacks = ["comm"]`),不帶 `--allow-non-commercial`。
3. 觀察:回報中沒有任何提到 `noncomm` 的警告;新契約欄位 `spWarnedPacks` 為空。

最小重現碼見 `project/test/AssetDB/Project/SyncSpec.hs` 的
「警告涵蓋登記的全集,不受 --pack / --match 篩選限制」。

## 根因分析

`project/src/AssetDB/Project/Sync.hs:164-171`(修復前):

```haskell
let newPacks = nub [pkPack p | (p, e) <- classified, seClass e == SyncNew]
    oldPacks = nub [pkPack p | (p, e) <- classified, seClass e /= SyncNew]
(blocked, warned) <-
  if soAllowNonCommercial
    then pure ([], [])
    else do
      bad <- nonCommercialPacks conn (nub (newPacks <> oldPacks))
      pure (filter (`elem` bad) newPacks, filter (`elem` bad) oldPacks)
```

`classified` 完全來自 `selectAssets conn soPacks soQuery`,也就是**本次候選**。
但 `rewriteGenerated`(`Sync.hs:307`)重寫產物時讀的是 `project_assets` 的**全集**
(`SELECT … FROM project_assets pa … WHERE pa.project_id = ?`)。

兩者涵蓋範圍不一致:`oldPacks` ⊆ 候選所屬素材包,而產物涵蓋全集。差集(登記了但這次
沒被 `--pack` / `--match` 命中的素材)因此完全逃過授權查核。

另外,警告當時只以 `soOnEvent` 送出,沒有進入 `SyncPlan`,呼叫端(CLI、測試)拿不到
結構化資料,也就無從對帳警告涵蓋範圍。

## 修復方向

契約已由編排者寫入 `.design/subsystems/delivery/design.md`(§6 與模組間公開介面 `project`):

1. 警告的來源改為**登記的全集**:直接查 `project_assets` join 到 `packs` 取素材包 slug,
   與 `rewriteGenerated` 同一份範圍,不再用本次候選。
2. `SyncPlan` 加 `spWarnedPacks :: [Text]`。`spBlocked` 是「被擋下、不會加入」的素材包,
   `spWarnedPacks` 是「既有素材仍留著、但授權有問題」的素材包,**兩者語意不同不可合併**。
3. CLI(`cli/app/AssetDB/Cli/Project.hs`)的警告輸出改為讀 `spWarnedPacks`。
4. 維持既有裁決 A7:`soAllowNonCommercial = True` 時警告一併關閉。

替代方案(已否決):把 `selectAssets` 的篩選條件放寬到全集再分類 —— 那會讓對帳去讀
所有登記素材的磁碟雜湊,成本與語意都變了,而且四類判定的定義是「候選 × 登記」。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗)  `dep: -`
- [x] T2: `Sync.hs` 新增「登記全集的素材包 slug」查詢  `dep: T1`
- [x] T3: `prepare` 的警告來源改為全集;`SyncPlan` 加 `spWarnedPacks` 並填值  `dep: T2`
- [x] T4: CLI 報告區塊讀 `spWarnedPacks`  `dep: T3`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 | 結果 |
|------|------|------|------|
| T1/T2/T3 | `SyncSpec.警告涵蓋登記的全集,不受 --pack / --match 篩選限制` | 既有 `noncomm` 素材不在 `--pack comm` 篩選內,仍須進 `spWarnedPacks` | ✅ |
| T3 | `SyncSpec.授權未查證(NULL)的既有素材包同樣進 spWarnedPacks` | NULL 與 0 在警告這一側等價 | ✅ |
| T3 | `SyncSpec.可商用的既有素材包不進 spWarnedPacks` | 不誤報 | ✅ |
| T3 | `SyncSpec.--allow-non-commercial 時 spWarnedPacks 為空(A7)` | 裁決 A7 未被改動 | ✅ |
| T3 | `SyncSpec.spBlocked 與 spWarnedPacks 語意不同不可合併` | 同一次同步中兩個欄位分別成立 | ✅ |
| T3(回歸) | `SyncSpec.既有登記素材的素材包降級時仍留在 entries、不進 spBlocked,只逐包警告` | 閘門不回溯既有(F006 V8)未被改動 | ✅ |

## 驗證方式

```
cabal build all
cabal test all
```

重現測試修復前為紅(`spWarnedPacks` 為 `[]`),修復後為綠;既有 592 examples 全數維持綠燈。

## 修復紀錄

- `Sync.hs` 新增內部 `registeredPackSlugs :: Connection -> Int -> IO [Text]`,以
  `SELECT DISTINCT p.slug FROM project_assets pa JOIN assets a … JOIN packs p … WHERE pa.project_id = ?`
  取登記全集的素材包。`packs` 走 INNER JOIN:`assets.pack_id` 為 NULL 的列沒有素材包、
  也就沒有授權可查,不屬於警告對象。
- `prepare` 的授權查詢輸入改為 `nub (newPacks <> registeredPacks)`,`warned` 從
  `registeredPacks` 篩出;`spBlocked` 仍只從 `newPacks` 篩出,語意不變。
- `SyncPlan` 加 `spWarnedPacks`,`prepare` 填值。既有的 `soOnEvent` 逐包警告文字保留不動,
  只是涵蓋範圍變成全集。
- CLI `report` 在 `spBlocked` 區塊之後加一段讀 `spWarnedPacks` 的摘要,與既有 `spBlocked`
  摘要對稱(`spBlocked` 目前也是「`soOnEvent` 逐包詳述 + 報告摘要一行」兩處輸出)。
- `cli/test/AssetDB/Cli/ProjectSpec.hs` 的 `SyncPlan` 固定資料補上 `spWarnedPacks = []`
  (新欄位造成 `-Wmissing-fields`)。

## 驗證結果

- `cabal build all`:成功,無 error、無 warning。
- `cabal test all`:**597 examples / 0 failures**(9 個 test suite)。基準線 592 + 本次新增 5 條。
- 重現測試在修復前確實為紅(3 條:`expected ["noncomm"] but got []`、
  `expected ["unlicensed"] but got []` ×2),修復後轉綠並保留為回歸測試。

## 待確認假設

- A1: 契約說「CLI 的警告輸出改為讀 `spWarnedPacks`」,但既有 SyncSpec 的 F006 V8 測試
  斷言 `soOnEvent` 會送出「既有登記素材」字樣的事件 → 採取:**保留** `prepare` 的
  `soOnEvent` 逐包警告(涵蓋範圍改成全集),另在 CLI 報告加一行讀 `spWarnedPacks` 的摘要,
  與 `spBlocked` 現有的「事件 + 摘要」雙輸出模式對稱 → 影響:若編排者要的是「警告只從
  `spWarnedPacks` 出、`prepare` 不再發事件」,需刪掉 `Sync.hs` 的 `mapM_ … warned` 並改寫
  該條既有測試,CLI 改印逐包詳述。
