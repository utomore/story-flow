# Alchbees Asset & Project Management System (AAPM)

> 修訂 2:改為**壓縮檔中心**架構,並重新設計實體資料夾。修訂前的版本假設散檔是真相,
> 那個假設在使用者說明「未來素材都以壓縮檔匯入」後不成立。

## Context

Alchbees Studio 目前的資源管理是純手工資料夾:5,721 個檔案 / 3.42 GB。命名完全繼承自各廠商,
至少五種互不相容的風格並存(`UI_TravelBook_Frame01a.png` / `Blue Potion 2.png` / `idle_down.png` /
`potion10.png` / `00.png` / `#1 - Transparent Icons.png`)。沒有資料庫、沒有 script、沒有 manifest。

三個具體問題:

1. **找不到東西。** 找「書本風格的 GUI 框」只能靠記憶翻資料夾。
2. **建專案很慢。** `GameProjects/Col` 有 26 KB 的 GDD,但 `assets/` 是空的 —— 手動挑素材的成本太高。
3. **授權風險。** `Commercial/` 與 `Non-Commercial/` 的分流只存在於目錄結構,沒有機制阻止
   Non-Commercial 素材進入商業專案。

外加一個掃描才發現的問題:**散檔與壓縮檔同時存在**,同一份資料存了兩遍,約浪費 1.4 GB,
而且雲端備份要同步 5,721 個小檔。

### 已確認的決策

| 項目 | 決定 |
|---|---|
| 技術棧 | TS 前端 + Haskell 後端 + SQLite |
| 部署範圍 | 目前單人,schema 為多人預留 |
| 命名策略 | 不改廠商原檔名;DB 存 ULID + 正規化邏輯名稱 |
| 關卡格式 | LDtk(`.ldtk` / JSON) |
| **素材真相來源** | **壓縮檔**。散檔經雜湊驗證後刪除 |
| **參考資料** | 納入系統,標記 reference,預設不混進素材搜尋 |
| **壓縮格式** | ZIP 原生(Haskell);rar / 7z 交給 7-Zip sidecar(**使用者需自行安裝**) |
| **工作室根目錄** | 搬到無空格路徑 `C:\Users\User\Documents\alchbees-assets\` |

### 環境現況(已驗證)

- GHC 9.14.1 / cabal 3.16.1.0 / Node 24.11.1 / git —— 皆已安裝,不使用 stack
- `Alchbees Studio` 屬性為純 `Directory`:**沒有 OneDrive 佔位檔**,原計畫的風險 1 不存在
- `LongPathsEnabled = 1`:260 字元上限已解除,原計畫的風險 2 已緩解
- **GHC 的 `llvm-ar` 無法處理含空格的建置路徑** —— 這是實測撞到的真實限制,
  也是工具原碼與工作室根目錄都必須無空格的原因
- 7-Zip 未安裝;WinRAR 已安裝(`UnRAR.exe` 可用作備援)

---

## 為什麼是 Haskell 後端

`assets/manifest.json` 有兩個讀者:資源系統(產生它)與**遊戲本體**(消費它)。
遊戲是 Haskell(h-raylib + apecs + effectful)。兩邊都是 Haskell 時,manifest 的型別定義
放在共用的 `assetdb-core`,遊戲直接 `import` —— schema 改動在編譯期爆炸,而不是執行期黑畫面。
Python / TS 方案下這會是兩份手寫、緩慢漂移的 parser。

Haskell 的實質弱點是影像雜活(TIFF / PSD / HEIC 解碼、縮圖)與 rar / 7z 解壓。
解法不是換語言,是外包給 CLI sidecar —— 這是所有專業 asset pipeline 的標準做法。
PNG(佔 91%)與 ZIP 都用純 Haskell 處理,不需要 sidecar。

---

## 核心設計原則

### 原則 1:壓縮檔是唯一真相,其餘皆為衍生物

```
library/**/*.{zip,rar,7z}   不可變。備份目標。26 個檔案,不是 5,721 個
.assetdb/cache/             縮圖與衍生資料。可隨時刪除重建
projects/*/assets/          實體檔案。只有該專案用到的,已正規化命名
```

索引一個壓縮檔內的資源**不需要解壓**,只需要讀:

| 需要的資訊 | 成本 |
|---|---|
| 項目路徑、大小、CRC32 | 零解壓 —— ZIP 的 central directory 直接列出 |
| SHA-256、圖片尺寸 | 串流解壓該筆項目,不落地 |
| 縮圖、phash | 完整解碼該筆項目一次,結果進快取 |

誠實的但書:**PNG 本來就壓縮過,zip 幾乎省不到體積。** 真正的收益是
(a) 雲端備份從 5,721 個檔變成 26 個檔、(b) 散檔與壓縮檔的重複儲存消失、
(c) 廠商原檔位元級完整,授權爭議或版本比對時拿得出來。

**唯一的例外是 `library/studio/`(自製素材)** —— 那些會被頻繁編輯,壓縮檔會變成阻力,
所以維持散檔 + git。這是有理由的例外,不是不一致。

### 原則 2:實體檔案不可變,邏輯名稱在資料庫

廠商原檔永遠不動。DB 給每個資源:

- `ulid` —— 永久識別碼。專案 manifest、關聯、收藏全部引用它,所以改名不會壞
- `logical_name` —— 給人看的正規化名稱,也是遊戲載入器的 key

改名只發生在「解壓進專案 `assets/`」的那一刻。

### 原則 3:搜尋速度來自索引,不是資料夾

**有了資料庫之後,資料夾就不再是搜尋索引。** 把資料夾設計成分類法會重現原本的問題,
因為一個資源同時屬於多個分類(書本風格的 GUI 框 = GUI + Book + Crusenho + pixel-art),
而資料夾只能歸一類。

所以實體結構按 **provenance(來源)** 組織 —— 那是真正單值且永久的屬性。
分類、風格、作者全部進 DB,做成多對多。

### 原則 4:核心模型不認識「圖片」

`AssetKind` 是列舉,格式處理器是註冊表。加音效 = 往列表 append 一筆,不動核心資料表。

---

## 實體資料夾結構(重新設計)

```
C:\Users\User\Documents\alchbees-assets\   ← 工作室根,無空格
├── library/
│   ├── packs/<vendor>/<pack-slug>/        ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml                      ← 中繼資料。人可編輯,git 可追蹤
│   │   ├── <廠商原始檔名>.zip              ← 不可變
│   │   └── LICENSE.txt                    ← 從壓縮檔抽出,方便直接看
│   ├── reference/<topic-slug>/            ← 見圖參考,非遊戲素材
│   │   ├── pack.toml
│   │   └── jinmen-architecture.rar
│   └── studio/                            ← 自製素材,散檔(見原則 1 的例外)
│       ├── shared/
│       └── <project-slug>/
├── projects/                              ← 原 GameProjects
├── knowledge/                             ← 原 Papers + 未來知識建檔
├── marketing/                             ← 原 行銷
└── .assetdb/
    ├── assetdb.sqlite
    ├── config.toml
    ├── cache/thumbs/<sha256 前兩碼>/       ← 內容定址,跨包自動去重
    └── backups/
```

### 從現況的對應

| 現況 | 新位置 |
|---|---|
| `Game Assets itchio/Commercial/2D/GUI/Crusenho/[GUI] Pixel Art…/` | `library/packs/crusenho/complete-ui-book-styles/` |
| `Game Assets itchio/Commercial/Raw壓縮檔/Kibyra/*.zip` | `library/packs/kibyra/<pack-slug>/` |
| `Game Assets itchio/Non-Commercial/Magic Shader All.zip` | `library/packs/<vendor>/magic-shader-all/`(`commercial = false`) |
| `現實資源/生活實際照片/1990 年代文化風格/台灣/金門建築.rar` | `library/reference/1990s-taiwan-jinmen/` |
| `現實資源/…/日本/福岡廟宇/*.HEIC`(266 個散檔) | `library/reference/1990s-japan-fukuoka/fukuoka-temples.zip`(**store 模式,不壓縮**) |
| `GameProjects/` | `projects/` |
| `Papers/` | `knowledge/papers/` |
| `行銷/` | `marketing/` |

### 消失的層級,以及為什麼

| 消失 | 理由 |
|---|---|
| `Commercial/` `Non-Commercial/` | 授權是**屬性不是位置**。而且一個包可能有混合授權,資料夾表達不了。改由 `pack.toml` + DB,並在建專案時實際擋下違規素材 —— 資料夾從來沒做到這件事 |
| `2D/` `3D/` | 目前全部是 2D,`3D/` 是空的。3D 進來時是 `pack.toml` 的一個欄位,不是一層資料夾 |
| `Characters/` `FX/` `GUI/` `Maps/` | 分類是多值的,屬於 DB。一個包同時是 GUI 又是 Book 時,資料夾只能選一個 |
| `Raw壓縮檔/` | 壓縮檔不再是「原始備份」,它就是本體,所以跟中繼資料放在一起 |

### 中文資料夾名改為 ASCII

`Raw壓縮檔`、`現實資源`、`行銷` 等改成 ASCII kebab-case。理由與檔名規範相同:
跨平台編碼、shell 跳脫、git 路徑。**檔案內容與 DB 顯示名稱仍然是中文** ——
`pack.toml` 的 `name` 欄位存「1990 年代金門建築」,前端顯示的是那個,不是 slug。

---

## `pack.toml` —— 讓每個包自述

這是整個重構的關鍵新增物。有了它,**資料庫可以從磁碟完全重建**(災難復原),
而且每個包的處理規則跟著包走,不是散落在一張全域規則表裡。

```toml
schema = 1
slug   = "complete-ui-book-styles"
name   = "Complete UI Book Styles Pack"
vendor = "Crusenho"
author = "Crusenho Agus Hendri"
source_url = "https://crusenho.itch.io/complete-gui-essential-pack"
version    = "1.0"
acquired   = "2026-05-12"

[archive]
file    = "Complete_UI_Book_Styles_Pack_Full.7z"
sha256  = "…"
entries = 412

[license]
name = "itch.io Commercial"
commercial = true            # ← 建專案時的授權閘門讀這個欄位
attribution_required = false
entry = "LICENSE.txt"

[content]
categories = ["gui", "book"]
styles     = ["pixel-art"]

# 結構規則,由上而下,最先命中者勝
[[content.rule]]
match  = "Preview/**"
action = "exclude"
reason = "廠商宣傳圖"

[[content.rule]]
match  = "Sprites/UI_*.png"
kind   = "ui"
domain = "gui"
tags   = ["book"]
```

`content.rule` 的檔名解析語法在 Phase 2 實作時定案 —— 現在寫死語法會是憑空猜測。

---

## 解決「每個作者結構都不一樣」

這是使用者點出的真正難點。四層,最具體者勝:

| 層 | 作法 | 涵蓋 |
|---|---|---|
| 1. `pack.toml` 包內宣告 | 每包手寫一次 | 26 包 × 約 10 分鐘 |
| 2. 結構啟發式 | 認得 `Sprites/` `Preview/` `Aseprite/` `PSD/` `Spritesheets/` 等通用慣例 | 免費 |
| 3. **檔名叢集推論** | 見下 | **關鍵** |
| 4. 人工覆寫 | `source='manual'`,永遠勝過前三層 | 少量 |

### 第三層是答案

同一包內的檔名一定內部一致。把檔名 tokenize 成**形狀**再分群:

```
UI_TravelBook_Frame01a.png  ┐
UI_TravelBook_Banner01b.png ├─→ 形狀 WORD_CamelWord_CamelWord{NN}{a}   (287 個檔案)
UI_HoloBook_Alert01a.png    ┘

00.png, 01.png, 02.png …    ──→ 形狀 {NN}                              (312 個檔案)
idle_down.png, attack1_up.png ─→ 形狀 word{n}_word                     (48 個檔案)
```

一包 300 個檔案通常塌縮成 3–5 個叢集。系統對每個叢集提出一次解析方案,即時預覽數個
轉換結果,人按一次確認就套用整群。

**5,211 個檔案的決策量降到約 100 次確認。** 而且 DB 存的是「確認過的規則」而不是結果,
所以廠商出更新版時自動重套。

---

## 統一檔案命名規範

```
<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]
```

| 欄位 | 值 |
|---|---|
| `kind` | `spr` `tex` `atlas` `ui` `fnt` `sfx` `bgm` `vo` `lvl` `shd` `src` `doc` |
| `domain` | 開放受控詞彙:`gui` `ground` `book` `char` `fx` `prop` `bldg` `item` `env` `rune` … |
| `subject` | 單一分段,內部可用 `-` 連接多字 |
| `variant` | 兩位數字加可選字母(`01a`),或具名詞彙(`red` `large`) |
| `state` | 封閉詞彙:`idle` `hover` `pressed` `up` `down` … |
| `NNN` | 序號,補零三位 |

硬性規則:`^[a-z0-9]+(_[a-z0-9-]+)*$`、最長 64 字元、全域唯一、純 ASCII。

`kind` 是封閉列舉(驅動處理器與資料夾),`domain` 是開放詞彙 ——
每加一種素材領域都要改程式碼會違反原則 4。

**已實作並通過 89 個測試**,包含 `parse ∘ render == id` 的 QuickCheck 性質測試。
單元測試的輸入全部取自真實素材庫,不是編造的例子。

實際轉換:

| 現況 | 正規化後 |
|---|---|
| `UI_TravelBook_Frame01a.png` | `ui_gui_travel-book-frame_01a` |
| `UI_HoloBook_Alert01a_1.png` | `ui_gui_holo-book-alert_01a_000` |
| `Blue Potion 2.png` | `spr_item_blue-potion_02` |
| `TX Tileset Grass.png` | `tex_ground_tileset-grass` |
| `attack1_up.png` | `spr_char_hero_attack-01_up` |
| `rune100.png` | `fnt_rune_runic-codex_100` |
| `#1 - Transparent Icons.png` | *(排除 —— 宣傳圖)* |
| `福岡廟宇.HEIC` | *(拒絕 —— `NoAsciiContent`,要求人工命名)* |

最後一條是刻意的:自動音譯會產生沒人查得到的名稱,不如當場要求人工命名。

---

## 系統架構

```
assetdb-core      領域型別、命名規則、ULID、Manifest schema   ← 遊戲也依賴這個
assetdb-store     SQLite schema、migrations、查詢、FTS
assetdb-archive   壓縮檔抽象:列表、串流讀單筆項目、格式註冊表
assetdb-ingest    掃描、格式處理器註冊表、hash、縮圖、叢集推論
assetdb-project   專案樣板、scaffolding、manifest、Assets.hs 產生
assetdb-server    servant HTTP API + 靜態縮圖服務
assetdb-cli       scan / search / import / new-project / reorganize / doctor
web/              Vite + React + TypeScript
```

前端型別由後端產生:`servant-openapi3` → OpenAPI → `openapi-typescript`。前端無法自行編造 API 形狀。

**後端**:`servant-server` `sqlite-simple` `aeson` `zip`(ZIP 原生) `toml-parser`
`JuicyPixels` `JuicyPixels-extra` `crypton`(SHA-256) `typed-process`(sidecar)
`text` `bytestring` `containers` `unordered-containers` `filepath` `directory`
`fsnotify` `wai-app-static` `optparse-applicative` `hspec` `QuickCheck`

**前端**:Vite、React、TanStack Query、**TanStack Virtual**(5,000+ 縮圖的感知效能取決於此)、Tailwind

**Sidecar**:7-Zip(rar / 7z,使用者自行安裝);ImageMagick(TIFF / PSD / HEIC 縮圖,選配)。
缺席時對應資源仍會建索引,只是沒有預覽圖 —— `doctor` 會列出來。

---

## 資料庫 Schema

SQLite,`journal_mode=WAL`、`foreign_keys=ON`。

```sql
-- 來源
roots     (id, path, label, kind, enabled)        -- kind: packs|reference|studio
packs     (id, ulid, slug, name, vendor, author, source_url, version,
           acquired, license_id, root_id, rel_dir, toml_sha256)
authors   (id, name, url)
licenses  (id, name, commercial, attribution_required, notes, entry_path)

-- 壓縮檔:新的核心
archives  (id, ulid, pack_id, rel_path, format, sha256, bytes,
           entry_count, indexed_at)

-- 內容定址,跨包自動去重
blobs     (sha256 PRIMARY KEY, bytes, kind, meta_json,
           phash, thumb_status, first_seen)

assets (
  id INTEGER PRIMARY KEY,
  ulid TEXT UNIQUE NOT NULL,
  logical_name TEXT UNIQUE,               -- 未命名前可為 NULL
  kind TEXT NOT NULL,
  archive_id INT,  entry_path TEXT,       -- 壓縮檔內項目
  root_id   INT,  rel_path   TEXT,        -- 散檔(studio/)
  original_name TEXT,                     -- 廠商原始檔名,保留供搜尋
  sha256 TEXT REFERENCES blobs(sha256),
  pack_id, author_id, license_id,
  status TEXT,                            -- active|excluded|missing|archived
  meta_json TEXT,
  created_at, updated_at, created_by
);
CREATE UNIQUE INDEX ON assets(archive_id, entry_path) WHERE archive_id IS NOT NULL;
CREATE UNIQUE INDEX ON assets(root_id, rel_path)      WHERE root_id   IS NOT NULL;
CREATE INDEX ON assets(kind, status);
CREATE INDEX ON assets(sha256);

-- 分類
categories       (id, parent_id, name, slug, path)
asset_categories (asset_id, category_id)
tags             (id, name, facet)         -- facet: style|theme|palette|free
asset_tags       (asset_id, tag_id, source, confidence)   -- manual 勝過 rule
collections      (id, name, notes, created_at)
collection_items (collection_id, entity_type, entity_id, sort)

-- 通用關聯圖 —— 知識庫與行銷不需要自己的子系統
links (src_type, src_id, dst_type, dst_id, rel, notes)
      -- rel: uses | derives-from | variant-of | similar-to | documents | promotes

-- 專案
projects       (id, name, path, template, created_at, updated_at)
project_assets (project_id, asset_id, dest_rel_path, copy_mode, copied_sha256, added_at)

-- 知識建檔與行銷
notes (id, kind, title, body_md, front_matter_json, source_path, …)
      -- kind: knowledge | marketing | decision | reference

-- 叢集推論
name_clusters (id, pack_id, shape, sample_json, rule_json, confirmed_by, confirmed_at)

-- 重構稽核與還原
moves  (id, batch_id, ts, from_path, to_path, sha256, action, undone)
events (id, ts, actor, action, entity_type, entity_id, payload_json)

schema_migrations (version, applied_at)

CREATE VIRTUAL TABLE assets_fts USING fts5(
  logical_name, original_name, entry_path, tags, pack, author, notes,
  content='', tokenize='trigram'
);
```

**`tokenize='trigram'` 不是預設的 `unicode61`** —— 後者不切分中日文,而知識庫與筆記內容
全是繁體中文。trigram 同時免費給到子字串搜尋(`potion` 命中 `blue-potion`)。

**`blobs` 表是內容定址的去重層。** 多家廠商常常附上同一份免費字型或授權文字;
同一個 sha256 只算一次縮圖、只存一份快取。

---

## 重構執行:安全設計

搬動 3.42 GB 是不可逆操作。**由工具執行,不是臨時 script**,順序是:

1. **先掃描現況** —— 完整清單,每個檔案的 SHA-256 都入庫。此時不動任何東西
2. **產生搬移計畫** —— dry-run,輸出可審閱的完整清單
3. **執行** —— 每筆搬移寫進 `moves` 表
4. **對帳** —— 搬移前存在的每一個雜湊,搬移後必須仍然存在,且檔案數相符
5. **刪除散檔** —— **只刪除經逐筆雜湊證明確實存在於某個保留壓縮檔內的散檔**。
   任何對不上的檔案一律保留並列入報告,不連帶刪除
6. **undo manifest** —— 每個批次可回退

第 5 點是硬性閘門。掃描已知有些包(如 Crusenho 的 GUI 包)的壓縮檔對應需要驗證,
在雜湊證明之前不會刪除任何東西。

---

## 匯入流程(使用者的日常操作)

```
前端拖入 pack.zip
  → 存進 library/packs/<vendor>/<slug>/
  → 讀 central directory,不解壓,一項一列進 assets
  → 串流計算每筆 SHA-256,建 blobs
  → 解碼圖片產生縮圖與 phash(只進快取)
  → 叢集推論 → 前端呈現 3-5 個叢集請人確認
  → 寫回 pack.toml
```

建專案時:搜尋 → 加入收藏集 → `new-project`,**只對選中的項目做單筆解壓**,
正規化命名後寫進 `assets/`。永遠不會整包解開。

---

## 專案 Scaffolding

```
<project>/
├── SKILL.md                     ← 給 AI agent / 新成員:怎麼跑、資源在哪、命名規則、加素材流程
├── README.md
├── docs/{提案書,技術文檔,game-design-doc}.md
│   └── decisions/ADR-0001-*.md
├── src/  app/Main.hs  test/
├── assets/
│   ├── manifest.json            ← 由 AAPM 產生,型別是 AssetDB.Manifest.Manifest
│   ├── sprites/{gui,characters,items,fx}/
│   ├── tilesets/ground/  fonts/  levels/  shaders/
│   ├── audio/{sfx,bgm}/         ← 先建空目錄,音效上線即可用
│   └── theme/theme.json         ← 9-slice margin
├── tools/
├── .assetdb/project.json
├── .gitattributes               ← Git LFS(*.png *.psd *.wav)
└── <project>.cabal
```

額外產出 `Assets.hs`:

```haskell
-- 由 assetdb 產生,請勿手動編輯
uiGuiTravelBookFrame01a :: AssetKey
uiGuiTravelBookFrame01a = AssetKey "ui_gui_travel-book-frame_01a"
```

素材 key 打錯 = 編譯錯誤,不是執行期黑畫面。IDE 的 find-references 直接回答
「這個專案用了哪些素材」。

**授權閘門**:選入 `commercial = false` 的素材時阻擋並列出違規項。

---

## 實作階段

| 階段 | 內容 | 狀態 |
|---|---|---|
| **0** | `assetdb-core`:型別、ULID、命名文法、Manifest schema | ✅ |
| **0b** | `assetdb-store`:schema、migrations、FTS5 + 中日韓 n-gram | ✅ |
| **1** | `assetdb-archive`:ZIP 原生列表與串流讀取;rar/7z sidecar | ✅ |
| **2** | `assetdb-ingest` + CLI `scan`:掃描現況、SHA-256、blobs | ✅ |
| **2b** | `packs.toml` 中繼資料目錄 + CLI `pack` | ✅ |
| **3** | CLI `reorganize`:dry-run → 執行 → 對帳 → 刪散檔 → undo | ✅ **已對真實素材庫執行** |
| **4** | 叢集推論:把 6,393 筆的命名決策壓成約 100 次確認 | ✅ **6 次確認命名 1,653 筆** |
| **5** | FTS5 + facet 查詢 + CLI `search` | ✅ |
| **6** | 縮圖 pipeline(JuicyPixels,內容定址快取) | ✅ |
| **7** | `assetdb-server` + `--emit-types` → TS 型別 | ✅ |
| **8** | React 前端:虛擬化網格、facet 側欄 | ✅ |
| **9** | `assetdb-project`:樣板、單筆解壓、manifest、`Assets.hs` | ✅ |
| **10** | `notes`(知識庫 / 行銷)+ `links` 圖譜 | ✅ |
| **11** | 音效驗證:`probeWav` —— **不動任何核心表** | ✅ **已驗證,見下** |

階段 11 是設計正確性的實證,不該省略。

### 階段 11 的實際結果(2026-08-11 執行)

四個手工產生的 `.wav`(不同取樣率、聲道數、位元深度)放進 `library/studio/shared/audio/`,
`scan` 之後:

```
kind=audio 的 meta_json
  ui_click.wav          {"bitsPerSample":16,"channels":2,"durationMs":250, "sampleRate":44100}
  ui_page_turn.wav      {"bitsPerSample":16,"channels":1,"durationMs":600, "sampleRate":44100}
  bgm_village_loop.wav  {"bitsPerSample":16,"channels":2,"durationMs":2000,"sampleRate":22050}
  sfx_rune_charge.wav   {"bitsPerSample":8, "channels":1,"durationMs":1500,"sampleRate":8000}
```

四筆的值與產生時指定的參數逐一相符。facet 面板自動長出 `audio 4`,
`search -q village --kind audio` 的全文與 kind 條件組合正常。

**這一階段改動的檔案只有兩個,都在 `assetdb-ingest`:**

```
M ingest/src/AssetDB/Ingest/Handler.hs       -- audioHandlerStub 的 hProbe 換成 probeWav
M ingest/test/AssetDB/Ingest/HandlerSpec.hs
```

`git diff --stat HEAD -- store/src/AssetDB/Store/Schema.hs store/src/AssetDB/Store/Migrate.hs`
輸出為空 —— 沒有新資料表、沒有 migration、沒有動 `assets` 或 `blobs`。
原則 4「核心模型不認識圖片」到此不再是宣稱,而是可覆核的事實。

順帶證實的一件事:`probeWav` 不引入音訊解碼函式庫。取樣率、聲道數、長度三個值
全部在 `fmt ` 與 `data` 兩個 chunk 的檔頭裡,與「讀 PNG 的 IHDR 就能得到尺寸」同理。
chunk 逐個走訪而非假設固定位移 —— 真實 WAV 常在 `fmt ` 與 `data` 之間夾 `LIST`,
而且 RIFF 要求奇數長度的 chunk 補一個 padding byte,漏掉會讓後續全部位移錯一格。
這兩件事各有一個測試。

### 階段 3 的實際結果(2026-08-09 執行)

```
搬移      32 個檔案(3.2 GiB)     對帳 27/27 通過
寫入      27 份 pack.toml
刪除    5424 個散檔、146 個空目錄
```

**5,456 → 59 個檔案。** 磁碟只省下 131.9 MiB —— 散檔全是幾百 bytes 的小圖示,
先前估的 1.4 GB 是錯的。真正的收益是**雲端備份的檔案數從五千多降到 59**。

---

## 驗證方式

```bash
cabal test all
```

```bash
cabal run assetdb -- scan --root "C:/Users/User/Documents/Alchbees Studio"
```

```bash
cabal run assetdb -- reorganize --dry-run --out reorg-plan.txt
```

```bash
cabal run assetdb -- doctor
```

`doctor` 檢查:遺失檔案、sidecar 缺席、重複內容、未分類資源數、授權缺漏、
專案素材與來源不一致。

端到端(階段 9):

```bash
cabal run assetdb -- new-project --template haskell-raylib-2d --name Circle --collection "Circle 主 UI 套組"
```

驗收:目錄結構完整、`manifest.json` 可被 `AssetDB.Manifest` 解析、`Assets.hs` 編譯通過、
Non-Commercial 素材被正確阻擋。

階段 11:丟幾個 `.wav` 進素材庫 → `scan` → 出現在搜尋結果、facet 面板自動長出音訊篩選項、
**且 git diff 顯示沒有任何 migration 動到 `assets` 表**。

---

## 明確不做

- 不改廠商原檔名
- 不自建 spritesheet 打包器
- 不做即時協作 / 多人鎖 —— 只留 schema 欄位與 event log
- **不重新打包廠商壓縮檔** —— 位元級原檔是授權與版本比對的依據
- 不做圖片編輯功能 —— 開啟外部工具即可
