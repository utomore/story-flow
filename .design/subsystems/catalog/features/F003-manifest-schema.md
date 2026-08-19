---
id: F003
type: feature
title: manifest-schema
description: 專案 assets/manifest.json 的型別定義、版本把關與手寫序列化
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002]
related-adr: [ADR-001, ADR-003, ADR-004]
---

# F003: Manifest Schema

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

定義 `assets/manifest.json` 的 schema 與序列化。這份 schema 有兩個讀者:資源管理系統
(產生它)與**遊戲本體**(消費它)。因為兩邊都是 Haskell、都 `import AssetDB.Manifest`,
schema 改動會在編譯期爆炸而不是在執行期變成黑畫面 —— 這是 ADR-001 技術選型的直接理由。

`maMeta` 刻意是開放的 `Value` 而非封閉 sum type:加入音效時 `width`/`height` 換成
`durationMs`/`sampleRate`,若 metadata 是封閉型別,這個檔案、資料庫 schema 與前端型別
會一起要改。開放 JSON + 型別化存取函式讓「加一種 kind」變成純粹的加法。

## 落地位置

- `core/src/AssetDB/Manifest.hs` —— 頂層 `Manifest`、三種條目 DTO、kind 專屬 metadata、
  查表函式、全部手寫的 `ToJSON` / `FromJSON`
- 依賴:`core/src/AssetDB/Id.hs`(`maId :: ULID`)、`core/src/AssetDB/Naming.hs`
  (`maKey :: LogicalName`)、`core/src/AssetDB/Types.hs`(`maKind :: AssetKind`)

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Manifest` 一節:

- `currentSchemaVersion :: Int`(目前為 1)。遞增規則:**只在破壞相容性時遞增**,
  純粹新增可選欄位不算破壞。
- `Manifest`:`mSchemaVersion` / `mProject` / `mGeneratedAt` / `mAssets` / `mPacks` /
  `mLicenses`。`mPacks` 是出現在 `mAssets` 裡的素材包去重後的清單,供授權稽核與致謝名單。
- `ManifestAsset`:`maId`(**關聯與追溯用這個**,不要用 key 或路徑 —— 那兩者會因重新命名
  而改變)、`maKey`、`maPath`(專案根的相對路徑,永遠用 `/` 分隔)、`maKind`、
  `maSha256`(讓 doctor 能分辨「素材被改過」與「來源更新了」)、`maPack`、`maLicense`、`maMeta`。
- `ManifestPack`:`mpName` / `mpVendor` / `mpSourceUrl` / `mpVersion` / `mpLicense`。
- `ManifestLicense`:`mlName` / `mlCommercial`(建專案的授權閘門依據)/
  `mlAttributionRequired` / `mlNotes`。
- `AssetKey`:遊戲端的素材查表 key。產生的 `Assets.hs` 把每個邏輯名稱變成一個這種型別的
  常數,所以「素材名稱打錯」從執行期黑畫面變成編譯錯誤。
- 查表:`manifestIndex :: Manifest -> Map Text ManifestAsset`(遊戲啟動時做一次)、
  `lookupAsset :: LogicalName -> Manifest -> Maybe ManifestAsset`。
- kind 專屬 metadata:`ImageMeta`(含 `imColorCount` —— 區分「手繪」與「色盤像素」風格
  最便宜的訊號)、`AudioMeta`,以及 `imageMeta` / `audioMeta` 兩個型別化存取函式,
  kind 不符或欄位缺漏時回 `Nothing` 而不是爆炸。
- JSON 行為:欄位名**全部手寫**,不由 Generic 的前綴剝除規則間接決定;
  `FromJSON Manifest` 在 `schemaVersion` 不等於 `currentSchemaVersion` 時直接失敗並
  在訊息裡指示重新產生 manifest;未知欄位被忽略;`packs` / `licenses` 缺席視為空清單;
  `meta` 缺席視為 `Null`。

## 驗收依據

- `core/test/AssetDB/ManifestSpec.hs`
  - 「JSON 來回一致」:`完整 manifest`、`欄位名稱是穩定的字面字串`
    (比對 `schemaVersion` `project` `generatedAt` `assets` `packs` `licenses`)
  - 「schemaVersion 把關」:`版本不符時拒絕載入,而不是留下一堆 Nothing`、
    `錯誤訊息說得出該怎麼修`
  - 「向前相容」:`多出來的未知欄位會被忽略`、`packs 與 licenses 缺席時視為空清單`
  - 「kind 專屬 metadata」:`圖片 metadata 取得出來`、
    `同一筆資料用錯的取用函式會拿到 Nothing,不會爆炸`、`音效素材走完全相同的路徑`、
    `meta 缺席時不影響其他欄位`
  - 「查表」:`以邏輯名稱為 key`、`lookupAsset 找得到`
  - 「授權欄位」:`commercial 是必填,沒有預設值`
