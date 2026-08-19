---
id: F001
type: feature
title: domain-types-and-ulid
description: 領域列舉的穩定文字表示與 ULID 永久識別碼的產生、編解碼
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-003, ADR-008]
---

# F001: 領域型別與 ULID

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

定義全系統共用的領域列舉,以及它們的**穩定小寫文字表示**:所有列舉一律以文字進出
SQLite 與 JSON,不存序號 —— 序號會在有人重新排列 Haskell 建構子時無聲損毀整個資料庫,
而 `WHERE kind='audio'` 是人看得懂的(ADR-008)。同時提供 ULID 作為資源的永久識別碼:
前 48 bits 是毫秒時間戳,所以字典序等同時間序,`ORDER BY ulid` 免費得到建檔順序(ADR-003)。

核心模型刻意**不認識「圖片」**:`AssetKind` 開放到足以涵蓋未來的音效、影片、3D,
而 kind 專屬的 metadata 一律走 JSON,不進核心資料表。加入音效時這裡不需要任何改動。

## 落地位置

- `core/src/AssetDB/Types.hs` —— `TextEnum` 協定、十個領域列舉、分類軸映射、JSON instance
- `core/src/AssetDB/Id.hs` —— `ULID` 與 Crockford Base32 編解碼、JSON instance
- `core/assetdb-core.cabal` —— `exposed-modules` 中的 `AssetDB.Types`、`AssetDB.Id`

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Types` 與 `AssetDB.Id` 兩節:

- `class TextEnum a where toTextEnum :: a -> Text`,搭配 `textEnumValues :: TextEnum a => [a]`
  與 `parseTextEnum :: TextEnum a => Text -> Either Text a`。解析失敗的 `Left` 訊息會列出
  全部可用值。
- 十個列舉:`AssetKind`、`KindPrefix`、`AssetStatus`、`PackStatus`、`AiDisclosure`、
  `CopyMode`、`TagSource`、`EntityType`、`LinkRel`、`NoteKind`。全部是 `TextEnum` 實例,
  並附 `ToJSON` / `FromJSON`(都走 `TextEnum`,所以 JSON 與 SQLite 表示保證一致)。
- 分類軸映射:`prefixKind :: KindPrefix -> AssetKind`(多對一,`spr`/`tex`/`ui`/`atlas`
  都是 `KImage`)、`kindPrefixes :: AssetKind -> [KindPrefix]`(反向,掃描時限縮推導範圍)、
  `kindDefaultDir :: AssetKind -> Text`(專案 `assets/` 底下的預設落點)。
- `PackStatus` 的 `PkDraft` / `PkReady` 是匯入流程的核心機制:draft 的素材照樣入庫、
  算雜湊、產縮圖,但不進搜尋預設結果、不可用於建專案。
- `AiDisclosure` 的 `AiUnknown`(還沒查)與 `AiNone`(作者明確聲明未使用)是不同的值,
  發行前稽核只接受後者。
- `ULID`:抽象型別(建構子不外露),`newULID :: IO ULID`、
  `mkULID :: Integer -> Integer -> Either Text ULID`(純函數,範圍檢查 48/80 bits)、
  `renderULID` / `parseULID`、`ulidTimestamp` / `ulidRandomness`、`unULID`,以及 JSON instance。
  `parseULID` 依 Crockford 建議寬鬆解碼:接受小寫,`I`/`L` 視為 `1`、`O` 視為 `0`。

## 驗收依據

- `core/test/AssetDB/IdSpec.hs`
  - 「編碼」:`永遠是 26 個字元`、`只使用 Crockford 字母表(不含 I / L / O / U)`、
    `render / parse 來回一致`、`全零與最大值都能表示`
  - 「字典序 == 時間序」:`時間戳較大的 ULID,文字排序也較大`、
    `同一批 ULID 依文字排序與依值排序結果相同`
  - 「解碼的寬鬆處理」:`接受小寫`、`I 與 L 視為 1、O 視為 0`
  - 「解碼的嚴格處理」:`拒絕長度不對的字串`、`拒絕字母表外的字元`、
    `拒絕超過 128 位元的值(首字元大於 7)`
  - 「建構的範圍檢查」:`拒絕超出 48 位元的時間戳`、`拒絕超出 80 位元的亂數`、`拒絕負值`
  - 「取值」:`亂數部分取得回來`、`時間戳解讀為毫秒`
  - 「newULID」:`連續產生的 ID 不重複`
- `AssetDB.Types` **沒有專屬的 spec 檔**。它的行為由下游測試間接涵蓋:
  - `core/test/AssetDB/NamingSpec.hs` 使用 `KindPrefix` 與 `toTextEnum` 組出名稱首段
    (見「mkLogicalName / parseLogicalName」的 `組出計畫裡的實際目標名稱`)
  - `core/test/AssetDB/ManifestSpec.hs` 的 `完整 manifest` round-trip 驗證 `AssetKind`
    的 JSON 文字表示
  - `store/test/AssetDB/Store/SchemaSpec.hs` 的「列舉欄位」(`status 只接受已知值`、
    `archive format 只接受支援的格式`)與「AI 使用揭露」(`預設是 unknown,不是 none`、
    `只接受已知的揭露值`)以 CHECK 約束的角度驗證同一組文字值
