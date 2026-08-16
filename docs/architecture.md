---
id: architecture
type: architecture
title: assetdb
description: 工作室素材庫的索引、檢索與專案素材配置系統
status: active
created: 2026-08-16
updated: 2026-08-16
---

# AssetDB(Alchbees Asset & Project Management System)系統架構

> 本文取代並整併 `docs/DESIGN.md`、`docs/AI.md`、`docs/PACKS.md` 三份舊文件的架構相關內容,
> 三份原檔已移至 `docs/_archive/`。素材包盤點資料(非架構內容)請見 `docs/_archive/PACKS.md`
> 與機器可讀的 `data/packs.toml`。AI 分類功能的完整操作手冊(troubleshooting、CLI 逐步流程)
> 保留在 `docs/_archive/AI.md`,本文只收錄其架構決策。

## 需求說明

Alchbees Studio 的資源管理原本是純手工資料夾:5,721 個檔案 / 3.42 GB,命名繼承自各廠商,
至少五種互不相容的風格並存。沒有資料庫、沒有 script、沒有 manifest。三個具體問題驅動了本專案:

1. **找不到東西。** 例如「書本風格的 GUI 框」只能靠記憶翻資料夾。
2. **建專案很慢。** 手動從素材庫挑選、複製、重新命名的成本過高。
3. **授權風險。** 商用 / 非商用素材的分流只存在於目錄結構,沒有機制阻止非商用素材被用進商業專案。

外加掃描後才發現的問題:**散檔與壓縮檔同時存在**,同一份資料存兩遍,且雲端備份要同步數千個小檔。

核心功能清單:

- 掃描壓縮檔與散檔、建立內容定址索引(SHA-256 去重)
- 全文 + facet 搜尋(含中日韓文字支援)
- 依廠商叢集自動推論命名規則,大量降低人工決策次數
- 建立新遊戲專案時,從素材庫挑選並正規化複製,產生型別安全的 `Assets.hs`
- 授權閘門:非商用素材無法進入商業專案
- 離線 AI 分類與標註(本機 LLM),把中文標籤寫進索引供純 SQLite 查詢

使用者:單人工作室(目前),schema 已為多人協作預留欄位但不實作即時協作。

## 架構規劃(含垂直切片說明)

專案依「資源生命週期」切成垂直切片,每片對應一個 cabal 套件,可獨立測試、獨立編譯:

| 切片 | 對應套件 | 職責 |
|---|---|---|
| 型別與規則 | `core` | 領域型別(`AssetKind`/`TextEnum`)、ULID、命名文法、Manifest schema — 遊戲本體也依賴這個套件 |
| 儲存 | `store` | SQLite schema、migrations、FTS5 全文索引、查詢/facet |
| 壓縮檔存取 | `archive` | ZIP 原生列表與串流讀取;rar/7z 交給 7-Zip sidecar |
| 掃描與擷取 | `ingest` | 掃描壓縮檔/散檔、格式處理器註冊表、hash、縮圖、檔名叢集推論 |
| 一次性遷移 | `reorg` | 舊資料夾結構 → 新結構的安全搬遷(掃描→計畫→執行→對帳→刪除→undo) |
| AI 標註 | `ai` | 本機 LLM 分類/視覺標註,GBNF 約束輸出,離線寫入索引 |
| 專案產出 | `project` | 專案樣板、素材單筆解壓、manifest 產生、`Assets.hs` 產生、授權閘門 |
| API | `server` | Servant HTTP API + 靜態縮圖服務,只依賴 `core`+`store`,刻意保持精瘦 |
| 使用者入口 | `cli` | 所有指令的組合根,唯一依賴全部套件的模組 |
| 前端 | `web/` | Vite + React + TypeScript,虛擬化網格 + facet 側欄 |

垂直切片之間**沒有循環依賴**,依賴方向嚴格向下收斂到 `core`(詳見下方架構圖)。這個形狀
是「加音效不需要改核心表」「ai 不需要拖進 zip/圖片解碼函式庫」等低耦合特性的直接來源。

## 使用的技術

- **後端**:Haskell(GHC 9.14.1 / cabal 3.16.1.0),`servant-server`、`sqlite-simple`、`aeson`、
  `zip`(ZIP 原生)、`toml-parser`、`JuicyPixels` / `JuicyPixels-extra`、`crypton`(SHA-256)、
  `typed-process`(sidecar 呼叫)、`fsnotify`、`wai-app-static`、`optparse-applicative`、
  `hspec` / `QuickCheck`
- **前端**:Node 24.11.1、Vite、React、TypeScript、TanStack Virtual(數千張縮圖的虛擬化渲染)
- **儲存**:SQLite(`journal_mode=WAL`、`foreign_keys=ON`),FTS5 雙索引(trigram + CJK unicode61 bigram)
- **Sidecar 外部工具**:7-Zip(rar/7z 解壓,使用者自行安裝)、llama.cpp(本機 LLM,OpenAI 相容端點)、
  ImageMagick(選配,TIFF/PSD/HEIC 縮圖)
- **AI**:本機推論,GBNF 文法約束 JSON Schema 輸出,分類結果離線寫回索引,查詢時不呼叫 LLM

## 架構圖

依賴方向(由 `.cabal` 逐一確認,無循環):

```
                    ┌─────────┐
                    │  core   │  型別、ULID、命名文法、Manifest(無任何內部依賴)
                    └────┬────┘
          ┌──────────┬───┴────┐
     ┌────┴───┐ ┌────┴───┐    │
     │ store  │ │archive │    │
     └───┬────┘ └───┬────┘    │
   ┌─────┼──────────┼─────────┤
┌──┴──┐ ┌┴────────┐ ┌┴───────┐│
│ ai  │ │ ingest  │ │project ││   ai      → core, store        (刻意不依賴 ingest,見 ADR-0007)
└──┬──┘ └──┬───┬──┘ └───┬────┘│   ingest  → core, store, archive
   │       │  ┌┴────┐   │     │   project → core, store, archive
   │       │  │reorg│   │     │   reorg   → core, store, ingest
   │  ┌────┴──┐  │      │     │
   │  │server │←─┼──────┼── core, store  **只有這兩個**
   │  └───────┘  │      │
   └──────┬──────┴──────┘
        ┌─┴─┐
        │cli│  組合根:依賴全部套件
        └───┘
```

資料流(日常匯入路徑):

```
前端拖入 pack.zip
  → 存進 library/packs/<vendor>/<slug>/
  → 讀 central directory,不解壓,一項一列進 assets
  → 串流計算每筆 SHA-256,寫入 blobs(內容定址去重)
  → 解碼圖片產生縮圖與 phash(僅進快取,可重建)
  → 檔名叢集推論 → 前端呈現 3-5 個叢集請人確認
  → 寫回 pack.toml
```

建專案:搜尋 → 加入收藏集 → `new-project`,只對選中項目做單筆解壓,正規化命名後寫進 `assets/`。
永遠不會整包解開壓縮檔。

## 資料結構的框架格式

**實體資料夾**(工作室根目錄無空格,原因見 ADR-0005 相關實測記錄):

```
<studio-root>/
├── library/
│   ├── packs/<vendor>/<pack-slug>/        ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml                      ← 中繼資料,人可編輯、git 可追蹤
│   │   ├── <廠商原始檔名>.zip              ← 不可變,唯一真相
│   │   └── LICENSE.txt
│   ├── reference/<topic-slug>/            ← 參考資料,非遊戲素材,預設不進搜尋
│   └── studio/                            ← 自製素材,散檔 + git(唯一不走壓縮檔的例外)
├── projects/
├── knowledge/
├── marketing/
└── .assetdb/
    ├── assetdb.sqlite
    ├── config.toml
    ├── cache/thumbs/<sha256 前兩碼>/       ← 內容定址,跨包自動去重
    └── backups/
```

**pack.toml**(讓每個包自述,資料庫可從磁碟完全重建):

```toml
schema = 1
slug   = "complete-ui-book-styles"
name   = "Complete UI Book Styles Pack"
vendor = "Crusenho"
[archive]
file = "Complete_UI_Book_Styles_Pack_Full.7z"
sha256 = "…"
[license]
name = "itch.io Commercial"
commercial = true            # 建專案時的授權閘門讀這個欄位
[content]
categories = ["gui", "book"]
[[content.rule]]             # 結構規則,由上而下,最先命中者勝
match = "Preview/**"
action = "exclude"
```

**SQLite schema**(核心表,完整 DDL 見 `store/src/AssetDB/Store/Schema.hs`):

```sql
roots / packs / authors / licenses          -- 來源與授權
archives                                    -- 壓縮檔本體
blobs (sha256 PRIMARY KEY, …)               -- 內容定址去重層
assets (id, ulid, logical_name, kind,
        archive_id/entry_path  XOR  root_id/rel_path,   -- CHECK 約束互斥
        sha256 REFERENCES blobs, status, …)
categories / asset_categories / tags / asset_tags / collections
links (src_type, src_id, dst_type, dst_id, rel, notes)   -- 通用關聯圖
projects / project_assets
notes (kind: knowledge | marketing | decision | reference)
name_clusters                               -- 檔名叢集推論
moves / events                              -- 重構稽核與還原
schema_migrations
categories.definition / ai_scope / sort, ai_runs, ai_suggestions, blobs.ai_status  -- migration 3:AI 分類
CREATE VIRTUAL TABLE assets_fts USING fts5(…, tokenize='trigram');
CREATE VIRTUAL TABLE assets_cjk USING fts5(…, tokenize='unicode61 …');  -- 中日韓 bigram/unigram
```

**命名文法**:`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,規則 `^[a-z0-9]+(_[a-z0-9-]+)*$`,
最長 64 字元、全域唯一、純 ASCII。`kind` 是封閉列舉、`domain` 是開放詞彙(見 ADR-0004)。

**前端型別契約**:後端 `server/src/AssetDB/Server/TsTypes.hs` 手寫產生器輸出 `web/src/api/types.ts`,
以 `TsTypesSpec` 保證與 `Api.hs` 的 `ToJSON` 一致(不用 OpenAPI)。已知落地缺口見
`docs/enhance/enhance-0014-ts-types-drift-check.md`。

## 使用到的套件

九個 cabal 套件(見上表)+ `web/` 一個 npm 套件。跨套件共用的小型純函數目前分散重複
(`leafOf`/`slugify`/縮圖路徑規則等各 2–5 份),整併計畫見 `docs/enhance/`。

## 開發階段

| 階段 | 內容 | 狀態 |
|---|---|---|
| 0 | `core`:型別、ULID、命名文法、Manifest schema | ✅ |
| 0b | `store`:schema、migrations、FTS5 + 中日韓 n-gram | ✅ |
| 1 | `archive`:ZIP 原生列表與串流讀取;rar/7z sidecar | ✅ |
| 2 | `ingest` + CLI `scan`:掃描現況、SHA-256、blobs | ✅ |
| 2b | `pack.toml` 中繼資料目錄 + CLI `pack` | ✅ |
| 3 | CLI `reorganize`:dry-run → 執行 → 對帳 → 刪散檔 → undo | ✅ 已對真實素材庫執行(2026-08-09) |
| 4 | 檔名叢集推論 | ✅ |
| 5 | FTS5 + facet 查詢 + CLI `search` | ✅ |
| 6 | 縮圖 pipeline(內容定址快取) | ✅ |
| 7 | `server` + `--emit-types` → TS 型別 | ✅ |
| 8 | React 前端:虛擬化網格、facet 側欄 | ✅ |
| 9 | `project`:樣板、單筆解壓、manifest、`Assets.hs` | ✅ |
| 10 | `notes`(知識庫/行銷)+ `links` 圖譜 | ✅ |
| 11 | 音效格式驗證(`probeWav`,零核心表改動) | ✅ 已驗證(2026-08-11) |
| 12 | AI 離線分類與標註(本機 LLM + GBNF) | ✅ 已對真實素材庫執行 |

**目前狀態**:功能面已完整實作並驗證;下一階段是收斂
`docs/analysis/report-2026-08-12-architecture-review.md`
與 `docs/bugfix/`、`docs/enhance/` 中記錄的已知問題,而非新增功能切片。新功能規劃請用
`/func-spec` 產出 `docs/spec/func-XXXX-*.md`,並在此文件的「開發階段」表補上對應列。
