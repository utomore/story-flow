-- | 資料庫 schema,以版本化 migration 的形式表達。
--
-- == 讀這個檔案前該知道的三件事
--
-- 1. **列舉一律存文字,不存序號。** 序號會在有人重新排列 Haskell 建構子時
--    無聲損毀整個資料庫,而且 @WHERE kind='audio'@ 人看得懂。
--
-- 2. **時間一律存 ISO-8601 UTC 文字。** SQLite 沒有日期型別;文字格式排序正確、
--    人看得懂、時區明確。
--
-- 3. **布林值存 0/1 整數**,並在需要語意的地方加 CHECK 約束。
module AssetDB.Store.Schema
  ( migrations
  , schemaVersion
  ) where

import AssetDB.Store.Migrate (Migration (..))
import Database.SQLite.Simple (Query)

-- | 目前最新的 schema 版本。
schemaVersion :: Int
schemaVersion = maximum (map migVersion migrations)

migrations :: [Migration]
migrations = [migration001]

--------------------------------------------------------------------------------

migration001 :: Migration
migration001 =
  Migration
    { migVersion = 1
    , migName = "初始 schema"
    , migStatements =
        concat
          [ sources
          , archivesAndBlobs
          , assetsTable
          , classification
          , graph
          , projectsTable
          , notesTable
          , inference
          , audit
          , fullTextSearch
          , seeds
          ]
    }

--------------------------------------------------------------------------------
-- 來源

sources :: [Query']
sources =
  [ -- 素材庫可以有多個根。路徑是設定,不是寫死的常數 ——
    -- 素材庫搬家或多人各自掛載時只改這張表。
    "CREATE TABLE roots ( \
    \  id      INTEGER PRIMARY KEY, \
    \  path    TEXT    NOT NULL UNIQUE, \
    \  label   TEXT    NOT NULL, \
    \  kind    TEXT    NOT NULL CHECK (kind IN ('packs','reference','studio')), \
    \  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)) \
    \)"
  , -- contact 是匯入時的必填項之一。素材出問題要找人時,
    -- 「作者叫 Kibyra」沒有用,要有 itch.io 商店頁或 Discord。
    "CREATE TABLE authors ( \
    \  id      INTEGER PRIMARY KEY, \
    \  name    TEXT NOT NULL UNIQUE, \
    \  url     TEXT, \
    \  contact TEXT, \
    \  notes   TEXT \
    \)"
  , -- 授權的各個維度分開存,而不是塞在一段自由文字裡,
    -- 因為建專案的閘門要能程式判讀。
    --
    -- commercial 刻意 NOT NULL 且**沒有預設值**:漏填時寧可寫入失敗,
    -- 也不要預設成允許而放行 Non-Commercial 素材。
    --
    -- 其餘布林值**允許 NULL**,而且 NULL 與 0 意義不同:
    -- NULL 是「授權條款沒寫,我們不知道」,0 是「明確禁止」。
    -- 把未知當成禁止會讓一堆素材無故不可用,當成允許則是法律風險。
    "CREATE TABLE licenses ( \
    \  id                     INTEGER PRIMARY KEY, \
    \  name                   TEXT    NOT NULL UNIQUE, \
    \  commercial             INTEGER NOT NULL CHECK (commercial IN (0,1)), \
    \  attribution_required   INTEGER NOT NULL CHECK (attribution_required IN (0,1)), \
    \  credit_text            TEXT, \
    \  modification_allowed   INTEGER CHECK (modification_allowed   IN (0,1)), \
    \  redistribution_allowed INTEGER CHECK (redistribution_allowed IN (0,1)), \
    \  resale_allowed         INTEGER CHECK (resale_allowed         IN (0,1)), \
    \  nft_allowed            INTEGER CHECK (nft_allowed            IN (0,1)), \
    \  source_url             TEXT, \
    \  full_text              TEXT, \
    \  notes                  TEXT, \
    \  entry_path             TEXT \
    \)"
  , -- status 是匯入流程的核心機制。
    --
    -- 廠商壓縮檔裡常常什麼中繼資料都沒有(現有素材庫的四個 Effects 包
    -- 就完全沒有 readme 或 license),作者與授權得回賣場頁翻。
    -- 強迫當場填完會讓匯入卡住;乾脆不填則會讓授權風險靜靜累積。
    --
    -- 折衷:'draft' 的素材照樣入庫、算雜湊、產縮圖,但不進搜尋預設結果、
    -- 不可用於建專案。授權缺漏因此是一個看得見的待辦,而不是看不見的風險。
    --
    -- ai_disclosure 不是可有可無的欄位:itch.io 已經把它做成商品頁必填,
    -- Steam 上架也要求申報。'unknown'(還沒查)與 'none'(作者明確聲明未使用)
    -- 意義不同,發行前稽核只接受後者。
    "CREATE TABLE packs ( \
    \  id            INTEGER PRIMARY KEY, \
    \  ulid          TEXT NOT NULL UNIQUE, \
    \  slug          TEXT NOT NULL, \
    \  name          TEXT NOT NULL, \
    \  vendor        TEXT, \
    \  author_id     INTEGER REFERENCES authors(id), \
    \  source_url    TEXT, \
    \  version       TEXT, \
    \  acquired      TEXT, \
    \  price_usd     REAL, \
    \  license_id    INTEGER REFERENCES licenses(id), \
    \  status        TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','ready')), \
    \  ai_disclosure TEXT NOT NULL DEFAULT 'unknown' \
    \                CHECK (ai_disclosure IN ('unknown','none','assisted','generated')), \
    \  ai_notes      TEXT, \
    \  root_id       INTEGER NOT NULL REFERENCES roots(id), \
    \  rel_dir       TEXT NOT NULL, \
    \  toml_sha256   TEXT, \
    \  created_at    TEXT NOT NULL, \
    \  updated_at    TEXT NOT NULL, \
    \  UNIQUE (root_id, rel_dir), \
    \  CHECK (status = 'draft' OR (license_id IS NOT NULL AND author_id IS NOT NULL)) \
    \)"
  , "CREATE INDEX packs_slug_idx ON packs(slug)"
  , "CREATE INDEX packs_status_idx ON packs(status)"
  ]

--------------------------------------------------------------------------------
-- 壓縮檔與內容定址

archivesAndBlobs :: [Query']
archivesAndBlobs =
  [ "CREATE TABLE archives ( \
    \  id          INTEGER PRIMARY KEY, \
    \  ulid        TEXT NOT NULL UNIQUE, \
    \  pack_id     INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE, \
    \  rel_path    TEXT NOT NULL, \
    \  format      TEXT NOT NULL CHECK (format IN ('zip','rar','7z')), \
    \  sha256      TEXT NOT NULL, \
    \  bytes       INTEGER NOT NULL, \
    \  entry_count INTEGER, \
    \  indexed_at  TEXT, \
    \  UNIQUE (pack_id, rel_path) \
    \)"
  , "CREATE INDEX archives_sha_idx ON archives(sha256)"
  , -- 內容定址的去重層。多家廠商常常附上同一份免費字型或授權文字;
    -- 同一個 sha256 只算一次縮圖、只存一份快取。
    -- 也是重構時「證明散檔確實存在於某個壓縮檔內」的比對依據。
    "CREATE TABLE blobs ( \
    \  sha256       TEXT PRIMARY KEY, \
    \  bytes        INTEGER NOT NULL, \
    \  kind         TEXT    NOT NULL, \
    \  meta_json    TEXT, \
    \  phash        INTEGER, \
    \  thumb_status TEXT    NOT NULL DEFAULT 'pending' \
    \                       CHECK (thumb_status IN ('pending','ok','failed','na')), \
    \  thumb_error  TEXT, \
    \  first_seen   TEXT    NOT NULL \
    \)"
  , "CREATE INDEX blobs_phash_idx ON blobs(phash) WHERE phash IS NOT NULL"
  , "CREATE INDEX blobs_thumb_idx ON blobs(thumb_status)"
  ]

--------------------------------------------------------------------------------
-- 資源

assetsTable :: [Query']
assetsTable =
  [ -- 一筆資源要嘛在壓縮檔裡(archive_id + entry_path),
    -- 要嘛是散檔(root_id + rel_path)。CHECK 約束讓「兩者都填」或
    -- 「兩者都空」在資料庫層就寫不進去,而不是靠應用層自律。
    --
    -- logical_name 允許 NULL:剛掃進來還沒命名的資源是合法狀態,
    -- 強迫當場命名會讓匯入卡住。
    "CREATE TABLE assets ( \
    \  id            INTEGER PRIMARY KEY, \
    \  ulid          TEXT NOT NULL UNIQUE, \
    \  logical_name  TEXT UNIQUE, \
    \  kind          TEXT NOT NULL, \
    \  archive_id    INTEGER REFERENCES archives(id) ON DELETE CASCADE, \
    \  entry_path    TEXT, \
    \  root_id       INTEGER REFERENCES roots(id), \
    \  rel_path      TEXT, \
    \  original_name TEXT NOT NULL, \
    \  ext           TEXT, \
    \  sha256        TEXT REFERENCES blobs(sha256), \
    \  pack_id       INTEGER REFERENCES packs(id) ON DELETE CASCADE, \
    \  author_id     INTEGER REFERENCES authors(id), \
    \  license_id    INTEGER REFERENCES licenses(id), \
    \  status        TEXT NOT NULL DEFAULT 'active' \
    \                CHECK (status IN ('active','excluded','missing','archived')), \
    \  meta_json     TEXT, \
    \  created_at    TEXT NOT NULL, \
    \  updated_at    TEXT NOT NULL, \
    \  created_by    TEXT NOT NULL DEFAULT 'local', \
    \  CHECK ( \
    \    (archive_id IS NOT NULL AND entry_path IS NOT NULL AND root_id IS NULL AND rel_path IS NULL) \
    \ OR (archive_id IS NULL AND entry_path IS NULL AND root_id IS NOT NULL AND rel_path IS NOT NULL) \
    \  ) \
    \)"
  , "CREATE UNIQUE INDEX assets_archive_entry_idx ON assets(archive_id, entry_path) \
    \  WHERE archive_id IS NOT NULL"
  , "CREATE UNIQUE INDEX assets_root_rel_idx ON assets(root_id, rel_path) \
    \  WHERE root_id IS NOT NULL"
  , "CREATE INDEX assets_kind_status_idx ON assets(kind, status)"
  , "CREATE INDEX assets_sha_idx  ON assets(sha256)"
  , "CREATE INDEX assets_pack_idx ON assets(pack_id)"
  ]

--------------------------------------------------------------------------------
-- 分類

classification :: [Query']
classification =
  [ -- path 欄位存物化路徑(如 'gui/book'),讓「找 GUI 底下所有子分類」
    -- 變成一次 LIKE 前綴查詢,而不是遞迴 CTE。
    "CREATE TABLE categories ( \
    \  id        INTEGER PRIMARY KEY, \
    \  parent_id INTEGER REFERENCES categories(id) ON DELETE CASCADE, \
    \  name      TEXT NOT NULL, \
    \  slug      TEXT NOT NULL, \
    \  path      TEXT NOT NULL UNIQUE, \
    \  UNIQUE (parent_id, slug) \
    \)"
  , "CREATE TABLE asset_categories ( \
    \  asset_id    INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE, \
    \  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE, \
    \  source      TEXT NOT NULL DEFAULT 'rule' \
    \              CHECK (source IN ('manual','rule','inferred')), \
    \  PRIMARY KEY (asset_id, category_id) \
    \)"
  , "CREATE INDEX asset_categories_cat_idx ON asset_categories(category_id)"
  , "CREATE TABLE tags ( \
    \  id    INTEGER PRIMARY KEY, \
    \  name  TEXT NOT NULL, \
    \  facet TEXT NOT NULL DEFAULT 'free' \
    \        CHECK (facet IN ('style','theme','palette','free')), \
    \  UNIQUE (facet, name) \
    \)"
  , -- source 決定衝突時誰贏:manual 永遠勝過 rule。
    -- 這讓規則可以重跑而不會蓋掉人工修正。
    "CREATE TABLE asset_tags ( \
    \  asset_id   INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE, \
    \  tag_id     INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE, \
    \  source     TEXT NOT NULL DEFAULT 'rule' \
    \             CHECK (source IN ('manual','rule','inferred')), \
    \  confidence REAL, \
    \  PRIMARY KEY (asset_id, tag_id) \
    \)"
  , "CREATE INDEX asset_tags_tag_idx ON asset_tags(tag_id)"
  , "CREATE TABLE collections ( \
    \  id         INTEGER PRIMARY KEY, \
    \  ulid       TEXT NOT NULL UNIQUE, \
    \  name       TEXT NOT NULL UNIQUE, \
    \  notes      TEXT, \
    \  created_at TEXT NOT NULL \
    \)"
  , "CREATE TABLE collection_items ( \
    \  collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE, \
    \  entity_type   TEXT    NOT NULL, \
    \  entity_id     INTEGER NOT NULL, \
    \  sort          INTEGER NOT NULL DEFAULT 0, \
    \  PRIMARY KEY (collection_id, entity_type, entity_id) \
    \)"
  , -- 命名詞彙表。AssetDB.Naming 的 NamingVocab 從這裡讀 ——
    -- 「加一個新的 domain」是插一列資料,不是改程式碼重編譯。
    "CREATE TABLE naming_vocab ( \
    \  id    INTEGER PRIMARY KEY, \
    \  facet TEXT NOT NULL CHECK (facet IN ('domain','state','variant')), \
    \  value TEXT NOT NULL, \
    \  notes TEXT, \
    \  UNIQUE (facet, value) \
    \)"
  ]

--------------------------------------------------------------------------------
-- 通用關聯圖
--
-- 知識庫與行銷資訊不需要自己的子系統,它們是這張圖上的節點。

graph :: [Query']
graph =
  [ "CREATE TABLE links ( \
    \  id       INTEGER PRIMARY KEY, \
    \  src_type TEXT    NOT NULL, \
    \  src_id   INTEGER NOT NULL, \
    \  dst_type TEXT    NOT NULL, \
    \  dst_id   INTEGER NOT NULL, \
    \  rel      TEXT    NOT NULL, \
    \  notes    TEXT, \
    \  UNIQUE (src_type, src_id, dst_type, dst_id, rel) \
    \)"
  , -- 反向查詢要跟正向一樣快:「改這張 tileset 會影響哪些關卡」
    -- 是從 dst 出發的查詢。
    "CREATE INDEX links_dst_idx ON links(dst_type, dst_id, rel)"
  , "CREATE INDEX links_src_idx ON links(src_type, src_id, rel)"
  ]

--------------------------------------------------------------------------------
-- 專案

projectsTable :: [Query']
projectsTable =
  [ "CREATE TABLE projects ( \
    \  id         INTEGER PRIMARY KEY, \
    \  ulid       TEXT NOT NULL UNIQUE, \
    \  name       TEXT NOT NULL UNIQUE, \
    \  path       TEXT NOT NULL UNIQUE, \
    \  template   TEXT, \
    \  created_at TEXT NOT NULL, \
    \  updated_at TEXT NOT NULL \
    \)"
  , -- copied_sha256 讓 doctor 能分辨兩種不同的狀況:
    -- 「專案裡的素材被改過」與「來源壓縮檔更新了」。
    "CREATE TABLE project_assets ( \
    \  project_id    INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE, \
    \  asset_id      INTEGER NOT NULL REFERENCES assets(id), \
    \  dest_rel_path TEXT    NOT NULL, \
    \  copy_mode     TEXT    NOT NULL DEFAULT 'copy' \
    \                CHECK (copy_mode IN ('copy','hardlink')), \
    \  copied_sha256 TEXT, \
    \  added_at      TEXT    NOT NULL, \
    \  PRIMARY KEY (project_id, asset_id), \
    \  UNIQUE (project_id, dest_rel_path) \
    \)"
  , "CREATE INDEX project_assets_asset_idx ON project_assets(asset_id)"
  ]

--------------------------------------------------------------------------------
-- 知識建檔與行銷

notesTable :: [Query']
notesTable =
  [ "CREATE TABLE notes ( \
    \  id                INTEGER PRIMARY KEY, \
    \  ulid              TEXT NOT NULL UNIQUE, \
    \  kind              TEXT NOT NULL \
    \                    CHECK (kind IN ('knowledge','marketing','decision','reference')), \
    \  title             TEXT NOT NULL, \
    \  body_md           TEXT NOT NULL DEFAULT '', \
    \  front_matter_json TEXT, \
    \  source_path       TEXT, \
    \  created_at        TEXT NOT NULL, \
    \  updated_at        TEXT NOT NULL \
    \)"
  , "CREATE INDEX notes_kind_idx ON notes(kind)"
  ]

--------------------------------------------------------------------------------
-- 叢集推論

inference :: [Query']
inference =
  [ -- 存的是「確認過的規則」而不是套用結果。
    -- 廠商出更新版時規則自動重套,不必重新確認一次。
    "CREATE TABLE name_clusters ( \
    \  id           INTEGER PRIMARY KEY, \
    \  pack_id      INTEGER NOT NULL REFERENCES packs(id) ON DELETE CASCADE, \
    \  shape        TEXT    NOT NULL, \
    \  member_count INTEGER NOT NULL DEFAULT 0, \
    \  sample_json  TEXT, \
    \  rule_json    TEXT, \
    \  confirmed_by TEXT, \
    \  confirmed_at TEXT, \
    \  UNIQUE (pack_id, shape) \
    \)"
  ]

--------------------------------------------------------------------------------
-- 稽核與還原

audit :: [Query']
audit =
  [ -- 重構 3.42 GB 是不可逆操作。每一筆搬移都記錄,
    -- 讓每個批次可以整批回退。
    "CREATE TABLE moves ( \
    \  id        INTEGER PRIMARY KEY, \
    \  batch_id  TEXT    NOT NULL, \
    \  ts        TEXT    NOT NULL, \
    \  action    TEXT    NOT NULL CHECK (action IN ('move','copy','delete','mkdir')), \
    \  from_path TEXT, \
    \  to_path   TEXT, \
    \  sha256    TEXT, \
    \  bytes     INTEGER, \
    \  undone    INTEGER NOT NULL DEFAULT 0 CHECK (undone IN (0,1)) \
    \)"
  , "CREATE INDEX moves_batch_idx ON moves(batch_id, id)"
  , -- 單人時是還原歷史,多人時是同步基礎。現在加成本極低,之後補則要重寫。
    "CREATE TABLE events ( \
    \  id           INTEGER PRIMARY KEY, \
    \  ts           TEXT    NOT NULL, \
    \  actor        TEXT    NOT NULL DEFAULT 'local', \
    \  action       TEXT    NOT NULL, \
    \  entity_type  TEXT, \
    \  entity_id    INTEGER, \
    \  payload_json TEXT \
    \)"
  , "CREATE INDEX events_entity_idx ON events(entity_type, entity_id, id)"
  ]

--------------------------------------------------------------------------------
-- 全文搜尋

fullTextSearch :: [Query']
fullTextSearch =
  [ -- tokenize='trigram' 而非預設的 'unicode61'。
    --
    -- unicode61 以空白與標點切詞,**完全不切分中日文** —— 而知識庫、
    -- 行銷文案、參考資料的說明全部是繁體中文,用預設 tokenizer 等於搜不到。
    -- trigram 另外免費送到子字串搜尋:輸入 "potion" 命中 "blue-potion"。
    --
    -- content='' 是 contentless 模式:索引內容來自跨表 JOIN,
    -- 不是單一來源表,所以不能用 external content。
    "CREATE VIRTUAL TABLE assets_fts USING fts5( \
    \  logical_name, original_name, entry_path, tags, pack, author, notes, \
    \  content='', tokenize='trigram' \
    \)"
  , "CREATE VIRTUAL TABLE notes_fts USING fts5( \
    \  title, body_md, \
    \  content='', tokenize='trigram' \
    \)"
  , -- trigram 有一個硬限制:MATCH 的查詢至少要三個字元。
    -- 中文雙字詞(金門、行銷、廟宇、素材)因此完全搜不到 —— 這是實測撞到的,
    -- 不是理論推測。
    --
    -- 補救方式是另建一張 unicode61 索引,內容是由 AssetDB.Store.Tokenize
    -- 預先展開的重疊 bigram。unicode61 遇空白斷詞,而中日韓字元不是分隔符,
    -- 所以「金門 門建 建築」正好是三個 token,雙字查詢變成精確比對。
    --
    -- rowid 與 assets_fts 共用,所以兩張表的結果可以直接 UNION。
    "CREATE VIRTUAL TABLE assets_cjk USING fts5( \
    \  uni, bi, \
    \  content='', tokenize='unicode61' \
    \)"
  , "CREATE VIRTUAL TABLE notes_cjk USING fts5( \
    \  uni, bi, \
    \  content='', tokenize='unicode61' \
    \)"
  ]

--------------------------------------------------------------------------------
-- 初始資料

seeds :: [Query']
seeds =
  [ "INSERT INTO naming_vocab (facet, value) VALUES \
    \  ('domain','gui'),('domain','ground'),('domain','book'),('domain','char'), \
    \  ('domain','fx'),('domain','prop'),('domain','bldg'),('domain','item'), \
    \  ('domain','env'),('domain','rune'),('domain','ui'),('domain','map')"
  , "INSERT INTO naming_vocab (facet, value) VALUES \
    \  ('state','idle'),('state','hover'),('state','pressed'),('state','disabled'), \
    \  ('state','active'),('state','selected'),('state','focus'), \
    \  ('state','open'),('state','closed'),('state','empty'),('state','full'), \
    \  ('state','on'),('state','off'), \
    \  ('state','walk'),('state','run'),('state','attack'),('state','dash'), \
    \  ('state','death'),('state','hurt'),('state','cast'), \
    \  ('state','up'),('state','down'),('state','left'),('state','right'), \
    \  ('state','front'),('state','back'), \
    \  ('state','north'),('state','south'),('state','east'),('state','west'), \
    \  ('state','day'),('state','night'),('state','dawn'),('state','dusk'), \
    \  ('state','intro'),('state','loop'),('state','outro')"
  , "INSERT INTO naming_vocab (facet, value) VALUES \
    \  ('variant','red'),('variant','green'),('variant','blue'),('variant','yellow'), \
    \  ('variant','purple'),('variant','orange'),('variant','pink'),('variant','brown'), \
    \  ('variant','black'),('variant','white'),('variant','grey'),('variant','gold'), \
    \  ('variant','silver'),('variant','cyan'), \
    \  ('variant','tiny'),('variant','small'),('variant','medium'),('variant','large'), \
    \  ('variant','huge'),('variant','wide'),('variant','tall'), \
    \  ('variant','wood'),('variant','stone'),('variant','iron'),('variant','bronze'), \
    \  ('variant','steel'),('variant','mithril')"
  , -- 現有素材庫實際持有的授權,全部逐字取自壓縮檔內的 License 檔或商品頁。
    --
    -- 把它們寫進 migration 而不是留給人工輸入,是因為這些條款是**查證過的證據**,
    -- 重打一次就是重新引入打錯的機會。資料庫因此可以從程式碼完整重建。
    --
    -- 刻意**不**收錄的:Magic Shader All(來源不明)。
    -- 沒有查證過的授權不該存在於資料庫裡 —— 那會讓閘門建立在猜測上。
    "INSERT INTO licenses \
    \  (name, commercial, attribution_required, credit_text, modification_allowed, \
    \   redistribution_allowed, resale_allowed, nft_allowed, source_url, notes) VALUES \
    \  ('Crusenho Asset License', 1, 1, \
    \   'Give appropriate credit, or provide a link to this product page, and indicate if changes were made.', \
    \   1, 0, 0, 0, 'https://crusenho.itch.io', \
    \   '逐字取自壓縮檔內 License.txt。全庫唯一明確要求署名的授權。'), \
    \  ('Cainos Asset License', 1, 0, NULL, 1, 0, 0, NULL, 'https://cainos.itch.io', \
    \   'Credit is not needed but appreciated. 取自商品頁 LICENCE 區塊。'), \
    \  ('Shikashi Fantasy Icons', 1, 1, \
    \   'Matt Firth (shikashipx), game-icons.net', \
    \   1, NULL, NULL, NULL, 'https://shikashipx.itch.io', \
    \   '部分圖示衍生自 game-icons.net。我們持有的 v2 內附 txt 寫 CC BY 3.0,商品頁現寫 CC BY 4.0 —— 版本不同,以手上這份為準。'), \
    \  ('Idylwild Runic Codex', 1, 0, NULL, 1, 1, NULL, NULL, 'https://idylwild.itch.io', \
    \   'Attribution - You may attribute me, but it is not mandatory. 這批素材裡唯一允許再散布的。'), \
    \  ('Kibyra Asset License', 1, 0, NULL, 1, 0, 0, NULL, 'https://kibyra.itch.io', \
    \   'Do not resell or redistribute the file as-is. Do not upload this asset elsewhere as your own.'), \
    \  ('Adventurer 2D Pixel Art', 1, 0, NULL, 1, 0, 0, 0, NULL, \
    \   'Credit is not required but it is appreciated. 逐字取自壓縮檔內 License.txt。'), \
    \  ('Studio Owned', 1, 0, NULL, 1, 1, 1, 1, NULL, \
    \   '工作室自有素材(自製或自行拍攝)。所有權利在我們手上,沒有外部限制。'), \
    \  ('BDragon1727 Full License', 1, 0, NULL, 1, 0, 0, NULL, 'https://bdragon1727.itch.io', \
    \   '取自商品頁 LICENSE: FULL 區塊,pack 1 與 pack 2 條款完全相同。明文允許個人、商業與非商業用途。禁再散布:no matter how much you modify it you can use it but not share or re-sell it。')"
  , -- 頂層分類。子分類由匯入時的規則與人工建立。
    "INSERT INTO categories (parent_id, name, slug, path) VALUES \
    \  (NULL,'GUI','gui','gui'), \
    \  (NULL,'Ground','ground','ground'), \
    \  (NULL,'Character','character','character'), \
    \  (NULL,'FX','fx','fx'), \
    \  (NULL,'Prop','prop','prop'), \
    \  (NULL,'Font','font','font'), \
    \  (NULL,'Audio','audio','audio'), \
    \  (NULL,'Level','level','level'), \
    \  (NULL,'Reference','reference','reference')"
  ]

--------------------------------------------------------------------------------

-- | 單一 SQL 敘述。用 alias 只是為了讓上面的清單讀起來就是一疊 SQL,
-- 不被型別雜訊打斷。
type Query' = Query
