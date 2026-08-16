---
id: adr-0001
type: adr
title: haskell-backend-typescript-frontend-sqlite
description: 後端 Haskell、前端 TypeScript、儲存 SQLite;manifest 型別與遊戲本體共用,schema 漂移在編譯期爆炸
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0001: 後端用 Haskell、前端用 TypeScript、儲存用 SQLite

## 狀態(Status)

Accepted。已完整實作(見 `docs/architecture.md` 開發階段 0–12)。

## 背景(Context)

`assets/manifest.json` 有兩個讀者:資源管理系統(產生它)與**遊戲本體**(消費它)。
遊戲引擎是 Haskell(h-raylib + apecs + effectful)。若資源系統用其他語言(如 Python 或純
TypeScript 後端),manifest 的型別定義會變成兩份手寫、彼此獨立演進的 parser,schema
改動只能在執行期黑畫面才會被發現。

工作室規模是單人,資料量約數千筆資源、數十個素材包,沒有高併發或分散式需求,
不需要為此選擇引入額外的維運複雜度。

## 決策(Decision)

- **後端**:Haskell,九個 cabal 套件(`core`/`store`/`archive`/`ingest`/`reorg`/`project`/`ai`/`server`/`cli`)。
  領域型別集中在 `core`,遊戲專案直接 `import AssetDB.Manifest`,schema 不相容在編譯期就報錯。
- **前端**:Vite + React + TypeScript,型別由後端手寫產生器(`server/TsTypes.hs`)輸出,
  不使用 OpenAPI(見 ADR 相關討論於 `docs/architecture.md` 資料結構章節)。
- **儲存**:單檔 SQLite,`journal_mode=WAL`、`foreign_keys=ON`。不用 PostgreSQL/MySQL —— 單人
  單機工具不需要獨立資料庫伺服器,SQLite 的單檔可攜性也方便備份與災難復原。

## 考慮過的替代方案(Alternatives Considered)

- **Python/TS 後端 + Haskell 遊戲**:manifest 型別需要在兩個語言各維護一份,曾評估但
  放棄 —— 這正是要避免的「兩份手寫、緩慢漂移的 parser」問題。
- **PostgreSQL**:多人協作與更大資料量下更合適,但目前是單人工作流程,SQLite 的零維運
  成本(無需啟動服務、無需連線設定)更符合實際需求。schema 已為多人協作預留欄位
  (如 `events` 表),但不提前實作即時協作機制。

## 影響(Consequences)

- Haskell 在影像雜活(TIFF/PSD/HEIC 解碼)與 rar/7z 解壓上生態較弱,需要外包給 CLI
  sidecar(見 ADR-0005)。這是刻意的取捨,不是缺陷。
- 前端型別安全依賴 `TsTypesSpec` 與人工執行 `--emit-types`,目前沒有 CI 自動比對
  磁碟上的 `web/src/api/types.ts` 是否為最新產物(已記錄於 `docs/enhance/`)。
- 單檔 SQLite 意味著同時只能有一個寫入者持有長交易;`busy_timeout=5000` 與
  「LLM 呼叫絕不跨交易持有寫鎖」是這個選擇下游的具體設計後果(見 ADR-0007)。
