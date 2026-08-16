---
id: adr-0008
type: adr
title: textenum-stable-text-representation
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0008: 所有列舉一律以穩定小寫文字存進 DB/JSON,不用序數

## 狀態(Status)

Accepted。實作於 `core/src/AssetDB/Types.hs`(`TextEnum` typeclass)與
`store/src/AssetDB/Store/Orphans.hs`(sqlite-simple 橋接)。

## 背景(Context)

系統有多個貫穿全層(DB → Haskell → JSON → TypeScript)的列舉型別:`AssetKind`、
`AssetStatus`、`PackStatus`、`AiDisclosure`、`CopyMode`、`TagSource`、`EntityType`、
`LinkRel`、`NoteKind`。若用整數序數存這些列舉(Haskell 衍生 `Enum` 的預設行為),
新增列舉值時若插入到中間,既有資料的數值意義會全部位移,而且序數本身對閱讀 SQL
查詢結果或除錯毫無語意。

## 決策(Decision)

- 定義 `TextEnum` typeclass,所有領域列舉型別實作它,DB 欄位與 JSON 欄位都存
  對應的穩定小寫文字(如 `"ready"`、`"assisted"`、`"variant-of"`),而非整數序數。
- JSON 與 SQLite 的文字表示由**同一個函式**產生(`TextEnum` 的方法),不是分別在
  `aeson` 的 `ToJSON`/`FromJSON` 與 `sqlite-simple` 的 `ToField`/`FromField` 各自手刻
  一份對照表 —— 避免兩份對照表漂移。
- 讀取時做正規化驗證(如 `store/Orphans.hs` 讀 `LogicalName` 時重新驗證格式),
  不假設資料庫內容永遠合法。

## 考慮過的替代方案(Alternatives Considered)

- **整數序數 + Haskell 端對照表**:效能上理論更優(SQLite 整數欄位比文字欄位小),
  但序數在資料庫層不具自解釋性,且新增/刪除列舉值時的位移風險被判定為比省下的
  幾個 bytes 更重要,已放棄。
- **各層各自定義字串對照(不透過共用 typeclass)**:是目前少數幾個貫穿層仍手寫
  JSON instance(如 `core/Manifest.hs`、`server/Api.hs`)的做法 —— 那些是刻意的例外
  (保護外部契約穩定,見架構文件),但列舉本身的文字表示仍統一經由 `TextEnum`,
  沒有第二套獨立的字串常數表。

## 影響(Consequences)

- 新增列舉值(如新的 `AssetKind`)只需要在 `TextEnum` 實例加一個 case,DB 端不需要
  遷移既有資料的數值,新增值不會與既有值衝突。
- 文字欄位在 SQLite 中需要額外的 `CHECK` 約束或應用層驗證才能防止拼寫錯誤寫入
  非法值(目前依賴讀取時的正規化驗證,寫入路徑的防線集中在 Haskell 型別系統本身
  —— 只要寫入前經過 `TextEnum` 編碼,就不可能寫入型別以外的字串)。
