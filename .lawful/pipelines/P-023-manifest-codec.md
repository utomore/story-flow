---
id: P-023
description: 兩份 manifest 的 schema 2 編解碼、版本閘門與遊戲啟動時的查表索引
status: ready
updated: 2026-09-06
---
# P-023-manifest-codec:兩份 manifest 的 schema 2 編解碼、版本閘門與遊戲啟動時的查表索引

## Brief
`project` 產出、遊戲本體消費的兩份邊界契約:`assets/manifest.json`(`Manifest`)與 `story/manifest.json`(`StoryManifest`),兩者都是 schema 2。input 是一份 manifest 的值或它的 JSON;output 是編碼後的 JSON、解碼回來的值,以及遊戲啟動時以 `AssetKey` 建的查表索引。流向:manifest 值 → JSON 編碼 → 版本閘門先讀 `schemaVersion` 再解析其餘欄位 → manifest 值 → 以 `maKey` 建索引;kind 專屬的 `meta` 欄位另有一條型別化讀取的岔路(image / audio)。誰產生 manifest、誰做授權判斷不在這條裡(那是 P-019-project-export 與 S6)。它是子流:遊戲本體只 import `aapms-core`,而這組型別是它唯一會用到的匯出。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `imageMeta :: Value -> Maybe ImageMeta` | 圖片 kind 專屬 meta 的型別化讀取 | `Aapms.Core.Manifest` | types |
| 2 | `audioMeta :: Value -> Maybe AudioMeta` | 音訊 kind 專屬 meta 的型別化讀取 | `Aapms.Core.Manifest` | types |
| = | `manifestIndex :: Manifest -> Map AssetKey ManifestAsset` | 純的整條:解碼後的 manifest 投影成遊戲啟動時的查表索引 | `Aapms.Core.Manifest` | types |

## Laws
- LAW-1 [roundtrip] 版本相符的 assets manifest 編成 JSON 再讀回來是同一個值
  - forall m in Manifest
  - given mSchemaVersion m == currentSchemaVersion
  - |- Data.Aeson.fromJSON (Data.Aeson.toJSON m) == Success m
- LAW-2 [roundtrip] 版本相符的 story manifest 編成 JSON 再讀回來是同一個值
  - forall sm in StoryManifest
  - given smSchemaVersion sm == currentStoryManifestSchemaVersion
  - |- Data.Aeson.fromJSON (Data.Aeson.toJSON sm) == Success sm
- LAW-3 [invariant] schemaVersion 不是本工具支援的那一個就不解析,不靜默通過
  - forall m in Manifest
  - given not (mSchemaVersion m == currentSchemaVersion)
  - |- Data.Aeson.fromJSON (Data.Aeson.toJSON m) /= Success m
- LAW-4 [invariant] story manifest 的版本閘門獨立於 assets manifest,用自己的常數
  - forall sm in StoryManifest
  - given not (smSchemaVersion sm == currentStoryManifestSchemaVersion)
  - |- Data.Aeson.fromJSON (Data.Aeson.toJSON sm) /= Success sm
- LAW-5 [relation] key 不重複時,每一筆 asset 都能用自己的 key 從索引查回自己
  - forall m in Manifest, a in mAssets m
  - given nub (map maKey (mAssets m)) == map maKey (mAssets m)
  - |- lookup (maKey a) (toList (manifestIndex m)) == Just a
- LAW-6 [invariant] 索引的鍵集合就是 asset 的 key 集合,不多也不少
  - forall m in Manifest
  - |- sort (map fst (toList (manifestIndex m))) == sort (nub (map maKey (mAssets m)))
- LAW-7 [relation] 沒出現在 manifest 裡的 key 查不到東西
  - forall m in Manifest, k in AssetKey
  - given notElem k (map maKey (mAssets m))
  - |- lookup k (toList (manifestIndex m)) == Nothing
- LAW-8 [roundtrip] ImageMeta 編成 JSON 再型別化讀回來是同一個值
  - forall im in ImageMeta
  - |- imageMeta (Data.Aeson.toJSON im) == Just im
- LAW-9 [roundtrip] AudioMeta 編成 JSON 再型別化讀回來是同一個值
  - forall am in AudioMeta
  - |- audioMeta (Data.Aeson.toJSON am) == Just am
- LAW-10 [total] 任何 Value 丟給兩個型別化讀取都有值,欄位缺漏或型別不符回 Nothing 而不是拋例外
  - forall v in Value
  - |- total (imageMeta v) and total (audioMeta v)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | golden 檔 `manifest.golden.json`(`schemaVersion` 2,兩筆 asset、一筆 pack、一筆 license) | 解得出 `Manifest`,再編碼與原檔語意相同;`decode (encode m)` 得回同一個值 | LAW-1 |
| EX-2 | golden 檔 `story-manifest.golden.json` | 解得出 `StoryManifest`,`smSchemaVersion` 為 2,編回去語意相同 | LAW-2 |
| EX-3 | 把 `manifest.golden.json` 的 `schemaVersion` 換成 1 或 3(邊界:支援值的上下各一格) | 兩者都解不出來,訊息含「請重新產生」 | LAW-3 |
| EX-4 | 把 `story-manifest.golden.json` 的 `schemaVersion` 換成 1 或 3 | 兩者都解不出來,用的是 story manifest 自己的版本常數 | LAW-4 |
| EX-5 | 帶 `ui_gui_travel-book-frame_001` 與 `sfx_ui_button-click_001` 兩筆 asset 的 manifest | `manifestIndex` 對兩個 `AssetKey` 都回 `Just`,對 `AssetKey "does-not-exist"` 回 `Nothing` | LAW-5、LAW-7 |
| EX-6 | `mAssets` 為 `[]` 的 manifest(邊界:空清單) | `manifestIndex` 是空表,鍵集合為 `[]` | LAW-6 |
| EX-7 | `maPack` 與 `maLicense` 皆為 `Nothing` 的 asset | 編碼後仍恰好九個鍵,兩者的值是 `null` 而不是省略鍵;讀回來還是 `Nothing` | LAW-1 |
| EX-8 | JSON 的 `pack` 寫成裸 id `"pck-11223344"`(不帶 vault 段) | 讀成 `Just (Ref Nothing …)`,視為本 vault 參照而不是錯誤 | LAW-1 |
| EX-9 | 兩筆短 id 相同、vault 不同的 pack:`vlt-aaaaaaaa:pck-11223344` 與 `vlt-bbbbbbbb:pck-11223344` | 兩個 `mpId` 不相等,各自能被完整 `Ref` 唯一查到,不必剝前綴 | LAW-1 |
| EX-10 | `imageMeta` 餵 `{"width": 512, "height": 512, "hasAlpha": true, "colorCount": 128}`,以及缺 `colorCount` 的同形物件 | 依序 `Just (ImageMeta 512 512 True (Just 128))` 與 `Just (ImageMeta 64 64 False Nothing)` | LAW-8 |
| EX-11 | `audioMeta` 餵 `{"durationMs": 240, "sampleRate": 44100, "channels": 2}` | `Just (AudioMeta 240 44100 2)` | LAW-9 |
| EX-12 | 把 image 的 `Value` 餵給 `audioMeta`,把 audio 的餵給 `imageMeta` | 兩邊都是 `Nothing`,不拋例外 | LAW-10 |

## 決定
- **兩份 manifest 各有自己的版本常數與版本閘門。** 否決:共用一個 `schemaVersion`。理由:為 `story/manifest.json` 日後單獨升到 schema 3 預留同一套拒絕機制(F003 ASM-4)
- **版本不符立刻失敗,不繼續解析其餘欄位。** 否決:先把欄位解完再檢查版本。理由:版本不符時連鎖冒出一堆缺欄位錯誤,會蓋掉真正的原因
- **manifest 內部的引用圖整個 vault 化:`maPack` / `maLicense` / `mpId` / `mpLicense` / `mlId` 一律是 `Ref`,只有節點自己的 `maId` 維持 `Id`。** 否決:引用端用 `Ref`、被引用端維持短 id。理由:那樣要對到頂層清單得先剝掉 vault 前綴,剝完又回到短 id 跨 vault 撞名的原始問題,想擋的事沒真正擋成(F003 ASM-2 二輪裁決)
- **`Manifest` 頂層帶去重過的 `packs` / `licenses` 清單。** 否決:只留 asset 上的引用,要看細節回頭讀 vault。理由:專案要能離開 vault 獨立存在,授權閘門要在專案資料夾內就判斷得出能不能商用(F003 ASM-3)
- **選填欄位的鍵恆存在,`Nothing` 編成 `null` 而不是省略鍵。** 否決:比照 `Asset` / `Pack` 的「`Nothing` 就省略鍵」慣例。理由:遊戲本體是逐鍵讀的消費端,鍵的集合固定比省那幾個位元組重要
- **`imageMeta` / `audioMeta` 的解析邏輯定義在 `Aapms.Core.Manifest` 的 `parseImageMeta` / `parseAudioMeta`,`Aapms.Core.Json` 的實例委派回同一份。** 否決:`imageMeta` 直接透過型別類別解析。理由:`Aapms.Core.Json` 要 import `Aapms.Core.Manifest` 才建得出實例,反過來 import 會成環;這兩個純函式不列成 stage,它們的自由度由 LAW-8 / LAW-9 / LAW-10 承接
- **JSON 編解碼的 law 直接引用 aeson 的具名限定寫法,不為它們造包裝函數。** 否決:在 `Aapms.Core.Manifest` 加 `encodeManifest` / `decodeManifest` 兩個薄包裝當 stage。理由:全系統的 aeson 規則只有一份、住在 `Aapms.Core.Json` 的實例裡;多一層包裝等於多一個繞得過那份規則的入口
- **`currentSchemaVersion` / `currentStoryManifestSchemaVersion` 是常數,不各寫一條 law。** 否決:寫一條斷言它等於 2 的 law。理由:常數的型別留下零個自由度,由初始值與 golden 檔的 example 驗收
- **`AssetKey` 是不透明字串鍵,不經任何命名文法驗證。** 否決:直接用 `LogicalName` 當索引鍵。理由:manifest 是遊戲本體消費的邊界契約,兩者文字相同但型別上互不相通,遊戲端不該被迫拉進命名文法(見 P-022-logical-name)
- **不提供 `lookupAsset`,呼叫端拿 `manifestIndex` 自己查。** 否決:沿用 legacy 的 `lookupAsset`。理由:契約 B 只列 `manifestIndex`,多一個函式沒有換到任何東西

## 修訂記錄
無
