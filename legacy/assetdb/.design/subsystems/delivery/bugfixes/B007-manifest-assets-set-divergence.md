---
id: B007
type: bugfix
title: manifest-assets-set-divergence
description: manifest.json 與 Assets.hs 用兩個不同集合產生,驗證失敗的登記列被靜默丟棄
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: []
related-feature: [F005, F006]
---

# B007: manifest 與 Assets.hs 用了兩個不同集合,靜默丟資料

## 症狀

某筆登記素材若 `toFullManifest` 失敗(ULID 解析失敗,或 `validateLogicalName` 失敗),
它**會出現在 `Assets.hs` 卻不在 `manifest.json`**。

- 預期(design.md §6 最後一條):兩個產物從同一份集合產生,任一筆被排除就兩邊一起排除,
  而且要經事件回呼出聲。
- 實際:`Assets.hs` 多出一個 `AssetKey` 常數,`manifest.json` 沒有對應項目。遊戲端
  `import Assets` 後用那個常數**編譯得過,但執行期查表落空** —— 正是這套型別安全設計
  要消滅的失敗模式(產生 `Assets.hs` 的全部理由就是把「查表落空」提前成編譯錯誤)。
- 另外 `logical_name` 為空的登記列被**完全靜默地丟棄**,使用者收不到任何訊息。

同樣的寫法在 `new-project` 路徑早就存在,是從 `F005` 繼承的既有缺陷。

## 重現步驟

1. 專案 `game` 已登記,`project_assets` 有兩筆:一筆合法(`ui_gui_alpha_01`),
   一筆邏輯名稱不合命名文法(含大寫與空白,例如 `UI Gui Bad 01`)。
2. 跑 `assetdb project sync --name game --match alpha --confirm`。
3. 觀察 `assets/manifest.json` 與 `assets/Assets.hs`:
   - manifest 只有 `ui_gui_alpha_01`;
   - `Assets.hs` 多出 `UI Gui Bad 01` 對應的常數;
   - 整個過程沒有任何訊息提到那一筆被排除。

最小重現碼見 `project/test/AssetDB/Project/SyncSpec.hs` 的
「manifest.json 與 Assets.hs 涵蓋同一組 key」與「被排除的列必須經事件回呼出聲」。

## 根因分析

### Sync 路徑 — `project/src/AssetDB/Project/Sync.hs:323-335`(修復前)

```haskell
let usable  = [r | r <- rows, not (T.null (frName r))]      -- 靜默丟棄
    mAssets = [a | Right a <- map toFullManifest usable]     -- Left 靜默消失
...
writeUtf8Bytes … (Manifest … mAssets …)
writeUtf8 … (renderAssetsModule name [AssetRef (frName r) (frPath r) (frPack r) | r <- usable])
```

`manifest.json` 用 `mAssets`(通過 `toFullManifest` 的子集),`Assets.hs` 用 `usable`
(只過濾空名稱)。`usable ⊋ mAssets`,差集就是「有常數、沒 manifest 項目」的那些。
兩處的 `[x | Right x <- …]` 與 list comprehension 過濾都是**靜默**的:沒有任何一條
路徑會把被丟掉的列告訴使用者。

### Create 路徑 — `project/src/AssetDB/Project/Create.hs:82` 與 `:92`(修復前)

```haskell
let mAssets = [a | Right a <- map (toManifest coPath) copied]   -- 第 82 行,Left 靜默消失
...
renderAssetsModule coName [AssetRef (pkName p) (relOf p) (Just (pkPack p)) | p <- copied]  -- 第 92 行,用全部的 copied
```

完全相同的形狀:manifest 用過濾後的子集,`Assets.hs` 用全集 `copied`。這是從 `F005`
繼承的既有缺陷,兩條路徑都要修。

### 順帶:落點算法有兩份(A8 留下的漂移風險)

`Internal.destRelOf` 與 `Create.relOf`(`Create.hs:102`)逐字相同;`Create.registerProject`
(`Create.hs:137`)與 `Internal.toManifest`(`Internal.hs:146`)另外又各自把同一個字串
拼了一次,共四份。落點是「檔案寫到哪、manifest 說在哪、登記說在哪」的唯一真相,
四份實作彼此漂移就會產生 manifest 指向不存在路徑的狀況。

## 修復方向

契約已由編排者寫入 `.design/subsystems/delivery/design.md` §6 最後一條:

1. `manifest.json` 與 `Assets.hs` 從**同一個集合**產生:任一筆被排除(邏輯名稱缺漏、
   ULID 或名稱驗證失敗)就兩邊一起排除。
2. 被排除的列必須經 `soOnEvent`(Sync)/ `coOnEvent`(Create)**出聲**,附上足以定位的
   資訊(邏輯名稱 / ULID / 專案內落點)與被排除的原因。
3. `createProject` 與 `syncProject` 兩條路徑都要修,共用邏輯放進 `AssetDB.Project.Internal`。
4. 收斂落點算法:`Create` 改用 `Internal.destRelOf`,刪掉重複的那份。純等價替換,
   `new-project` 的行為不得改變。

替代方案(已否決):讓 `Assets.hs` 也走 `toFullManifest` 之後再取 `arKey` —— 那只是把
同一份驗證跑兩次,兩邊仍可能因為呼叫順序不同而漂移;真正的修法是**只算一次、兩邊共用**。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(修復前應失敗)  `dep: -`
- [x] T2: `Internal` 加入共用的「產物集合過濾 + 排除出聲」輔助  `dep: T1`
- [x] T3: `Sync.rewriteGenerated` 改用共用輔助,manifest 與 Assets.hs 同集合  `dep: T2`
- [x] T4: `Create.createProject` 改用共用輔助,manifest 與 Assets.hs 同集合  `dep: T2`
- [x] T5: 落點算法收斂到 `Internal.destRelOf`,刪掉 `Create.relOf`  `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 | 結果 |
|------|------|------|------|
| T1/T2/T3 | `SyncSpec.重寫全集.manifest.json 與 Assets.hs 涵蓋同一組 key` | 驗證失敗的登記列兩邊一起排除 | ✅ |
| T2/T3 | `SyncSpec.重寫全集.被排除的列必須經事件回呼出聲,附邏輯名稱與原因` | 不再靜默丟資料 | ✅ |
| T2/T3 | `SyncSpec.重寫全集.logical_name 為空的登記列被排除時同樣出聲,並附 ULID 與落點` | 空名稱沒有名字可指,靠 ULID / 落點定位 | ✅ |
| T3(回歸) | `SyncSpec.重寫全集.manifest.json 含全部登記素材,path 取 dest_rel_path、sha256 取 copied_sha256` | 合法列的行為不變 | ✅ |
| T3(回歸) | `SyncSpec.重寫全集.Assets.hs 每筆一個常數,識別字撞名時去重` | 去重仍在共用集合之後生效 | ✅ |
| T1/T2/T4 | `CreateSpec.createProject 的產物集合.manifest.json 與 Assets.hs 涵蓋同一組 key,驗證失敗的列兩邊一起排除` | F005 繼承的缺陷,走真正的 `createProject` | ✅ |
| T2/T4 | `CreateSpec.createProject 的產物集合.被排除的列經 coOnEvent 出聲,附邏輯名稱與落點` | Create 路徑不再靜默丟資料 | ✅ |
| T5 | `CreateSpec.createProject 的產物集合.manifest 的 path 與 project_assets 的 dest_rel_path 逐字相同` | 落點四份收斂成一份後三處一致 | ✅ |
| T4 | `CreateSpec.createProject 的產物集合.被排除的素材仍然被複製、仍然登記,不是靜默丟掉整筆` | 排除的是**產物列入**,不是素材本身 | ✅ |
| T4/T5(回歸) | `AssetsSpec` / `TemplateSpec` / `CreateSpec.nonCommercialPacks` 全部既有案例 | `new-project` 行為不變 | ✅ |

## 驗證方式

```
cabal build all
cabal test all
```

重現測試修復前為紅,修復後為綠;既有測試(含 `CreateSpec` / `TemplateSpec` / `AssetsSpec`)
全數維持綠燈。

## 修復紀錄

### 共用輔助(`AssetDB.Project.Internal`)

```haskell
excludeUnusable
  :: (Text -> IO ())        -- 事件回呼(coOnEvent / soOnEvent)
  -> (a -> Text)            -- 定位資訊
  -> (a -> Either Text b)   -- 驗證,Left 是被排除的原因
  -> [a] -> IO [(a, b)]
labelOf   :: Text -> Text -> Text -> Text   -- 名稱 / ULID / 落點
pickLabel :: Pick -> Text
```

回傳 `[(a, b)]` 而不是 `[b]` 是關鍵:兩個產物各需要原始列的不同欄位(manifest 要
`ManifestAsset`,`Assets.hs` 要名稱 / 路徑 / 素材包),配對回傳讓兩邊**天然拿到同一個
集合**,不需要靠呼叫端自律。`Internal` 不在 `exposed-modules`,沒有新增任何公開介面。

`labelOf` 的名稱可能為空(那正是被排除的原因之一),所以 ULID 與落點永遠都在。

### Sync 路徑

- `rewriteGenerated` 多收一個 `(Text -> IO ())` 參數(內部函式,非公開介面),
  `syncProject` 傳入 `soOnEvent`。
- `usable <- excludeUnusable onEvent rowLabel toFullManifest rows`;manifest 用
  `map snd usable`,`Assets.hs` 用 `[(r, _) <- usable]`。空 `logical_name` 不再另外靜默
  過濾 —— 它會走進 `toFullManifest` 的 `validateLogicalName` 而得到一個有原因的 `Left`。
- `rowLabel r = labelOf (frName r) (frUlid r) (frPath r)`。

### Create 路徑

- `listed <- excludeUnusable coOnEvent pickLabel (toManifest coPath) copied`;manifest 用
  `map snd listed`,`Assets.hs` 用 `[(p, _) <- listed]`。
- 被排除的素材**仍然被複製、仍然登記**:排除的是「產物列入」,不是素材本身。

### 落點收斂(T5)

原本四份逐字相同的實作 → 一份 `Internal.destRelOf`:

| 位置 | 修復前 | 修復後 |
|---|---|---|
| `Create.relOf`(`Create.hs:102`) | 自己拼 | 刪除,呼叫點改用 `destRelOf` |
| `Create.registerProject`(`Create.hs:137`) | 自己拼 | `destRelOf p` |
| `Internal.toManifest`(`maPath`) | 自己拼 | `destRelOf p` |
| `Internal.destRelOf` | — | 唯一實作 |

純等價替換(三處是同一個字串運算式),`new-project` 的行為未改變。
`Create.hs` 因此不再需要 `import AssetDB.Types (kindDefaultDir)`,一併移除。

### 素材包 / 授權中繼資料的涵蓋範圍

`manifestPacks` / `manifestLicenses` 的輸入**刻意不跟著產物集合縮減**:被排除的那一筆
檔案仍然在專案目錄裡,致謝與授權義務跟著**檔案**走,不跟著 `AssetKey` 常數走。
Sync 改用登記全集 `rows`(修復前是「非空名稱」的子集),Create 維持 `copied`。

## 驗證結果

- `cabal build all`:成功,無 error、無 warning。
- `cabal test all`:**604 examples / 0 failures**(9 個 test suite)。
  基準線 592 → B006 +5 → B007 +7。
- 重現測試修復前確實為紅:
  - Sync 路徑 3 條 —— `expected ["ui_gui_alpha_01"] but got ["UI Gui Bad 01","ui_gui_alpha_01"]`
    (`Assets.hs` 多出那一筆)、事件清單 `predicate failed on: []`(靜默)×2。
  - Create 路徑:把 `Create.hs` 暫時改回缺陷形狀(`Assets.hs` 用 `copied`、事件回呼靜音)
    後重跑,得到 2 failures,同樣是「`Assets.hs` 多一筆」與「沒有事件」;還原後轉綠。
- `CreateSpec` / `TemplateSpec` / `AssetsSpec` 全數維持綠燈,`new-project` 行為未改變。

## 實作備註

- `CreateSpec` 新增的四條測試走**真正的 `createProject`**,fixture 是測試中即時建立的
  ZIP。ZIP 是 `readEntry` 的原生路徑(不需要 7-Zip 側車),所以整條「選素材 → 單筆解壓 →
  寫產物 → 登記」在任何機器上都跑得動 —— 這正是 `$licenseGate` 註解說「貴到不會有人寫」
  的那種測試,實際上只要不挑 `.rar` 就寫得出來。測試套件因此新增 `zip >= 2.0` 相依
  (`assetdb-archive` 早已依賴它,不是新的第三方套件)。
- `cli/test/AssetDB/Cli/ProjectSpec.hs` 的 `SyncPlan` 固定資料在 B006 已補上
  `spWarnedPacks = []`。
