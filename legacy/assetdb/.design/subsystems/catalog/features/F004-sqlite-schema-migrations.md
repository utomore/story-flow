---
id: F004
type: feature
title: sqlite-schema-migrations
description: SQLite 連線設定、全部 schema DDL 與只做正向的版本化 migration 執行器
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002]
related-adr: [ADR-001, ADR-006, ADR-008]
---

# F004: SQLite Schema 與 Migration

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

提供整個系統的持久層基座:連線的 PRAGMA 設定收在**唯一一個地方**(SQLite 的多數
「效能問題」與「資料損毀」故事,追到最後都是某條連線忘了開 `foreign_keys` 或沒設
`busy_timeout`),以及一個刻意做得很小的版本化 migration 執行器 —— **沒有 down
migration**,對單機 SQLite 來說回退的正確作法是從備份還原檔案,而不是執行一段幾乎
不會被測到的反向 SQL(ADR-006)。

Schema 本身以 migration 清單的形式表達,包含 22 張實體表(另加 migration 執行器自建的
`schema_migrations`)、4 張 FTS5 虛擬表,以及
已查證的授權與分類種子資料。三個貫穿全 schema 的約定:列舉存文字不存序號(ADR-008)、
時間存 ISO-8601 UTC 文字、布林值存 0/1 並在需要語意處加 CHECK。

## 落地位置

- `store/src/AssetDB/Store.hs` —— `Store`、連線開啟與 PRAGMA、`initSchema`、`storeVersion`
- `store/src/AssetDB/Store/Migrate.hs` —— `Migration`、`runMigrations`、`currentVersion`、
  `appliedVersions`、`MigrationError`、SQL 字面值組裝(`lit` / `num`)
- `store/src/AssetDB/Store/Schema.hs` —— `migrations`(001..004)與 `schemaVersion`
- `store/src/AssetDB/Store/Orphans.hs` —— core 型別 ↔ SQLite 欄位的 `ToField` / `FromField`
- `store/assetdb-store.cabal` —— 四個模組的 `exposed-modules` 宣告
- 相關紀錄:`.design/subsystems/catalog/enhancements/E001-migration-sql-builder-safety.md`
  (`lit` / `num` 的由來)、`.design/subsystems/catalog/bugfixes/B001-naming-vocab-dual-source-of-truth.md`
  (migration 004)

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Store` / `AssetDB.Store.Migrate` /
`AssetDB.Store.Schema` / `AssetDB.Store.Orphans` 四節:

- `Store { storeConn :: Connection, storePath :: FilePath }`。
- `openStore`:建目錄 → 開檔 → 套 PRAGMA(`foreign_keys=ON`、`journal_mode=WAL`、
  `synchronous=NORMAL`、`busy_timeout=5000`、`optimize`)。**不會**自動跑 migration ——
  分開是為了讓「檢查版本但不改動」成為可能。
- `openStoreInMemory`:測試用,不套 WAL(記憶體資料庫沒有 journal 檔)。
- `withStore`:bracket 包裝,離開時關閉連線。
- `initSchema :: Store -> IO [Migration]`:套用所有待執行的 migration,回傳這次跑了哪些。
- `storeVersion :: Store -> IO Int`。
- `Migration { migVersion, migName, migStatements }`。`migStatements` 一律以無參數方式執行:
  migration 是一疊可以直接讀成 SQL 的敘述,值全是編譯期字面值,從來不是注入問題;
  少數需要把值組進 SQL 文字的地方(如中文分類定義)一律經過 `lit` / `num`,
  讓「有人在定義裡寫了單引號」這一整類錯誤不可能發生。
- `runMigrations`:冪等;版本號非嚴格遞增拋 `MigrationsOutOfOrder`;資料庫版本高於程式
  所知拋 `DatabaseNewerThanCode`;每個 migration 各自包在一個交易裡,失敗只回滾自己那一個,
  先前成功的保持已套用,修好後重跑會從失敗處接續。
- `currentVersion`(全新資料庫回 0)、`appliedVersions`(version / name / applied_at)。
- `migrations` 四個版本:001 初始 schema、002 筆記以 `source_path` 為唯一鍵、
  003 AI 分類詞彙與建議表、004 `naming_vocab` 退場。`schemaVersion` 是其中的最大版本號。
- Schema 提供的資料表(其他子系統讀寫,catalog 只負責建立與約束):
  `roots` `authors` `licenses` `packs` `archives` `blobs` `assets` `categories`
  `asset_categories` `tags` `asset_tags` `collections` `collection_items` `links`
  `projects` `project_assets` `notes` `name_clusters` `moves` `events` `ai_runs`
  `ai_suggestions`,以及 `assets_fts` `assets_cjk` `notes_fts` `notes_cjk` 四張 FTS5 虛擬表。
- 關鍵約束:`assets` 的位置二選一(壓縮檔內 `archive_id`+`entry_path`,或散檔
  `root_id`+`rel_path`,兩者都填或都空都寫不進去)、`packs` 的
  `status='draft' OR (license_id IS NOT NULL AND author_id IS NOT NULL)`、
  `licenses.commercial` NOT NULL 且無預設值、其餘授權維度允許 NULL 且 NULL 與 0 意義不同。
- `AssetDB.Store.Orphans` 只匯出 instance(以 `import ... ()` 取得):`AssetKind`、
  `KindPrefix`、`AssetStatus`、`CopyMode`、`TagSource`、`EntityType`、`LinkRel`、`NoteKind`、
  `ULID`、`LogicalName` 的 `ToField` / `FromField`(`PackStatus` 與 `AiDisclosure`
  目前未橋接)。`LogicalName` 在**讀取時**也會重新驗證,若有人手動 UPDATE 寫進不合法的
  名稱,在讀取當下就發現。

## 驗收依據

- `store/test/AssetDB/Store/MigrateSpec.hs`
  - 「runMigrations」:`全新資料庫的版本是 0`、`套用後版本等於最新的 migration`、
    `是冪等的:第二次呼叫什麼都不做`、`記錄每個 migration 的套用時間`、
    `版本號非遞增時直接爆炸,不半套`、`資料庫比程式新時拒絕動作`、
    `單一 migration 失敗時整個交易回滾`
  - 「檔案資料庫」:`在磁碟上建立檔案並啟用 WAL`、`重新開啟時保留已套用的 migration`
  - 「PRAGMA」:`foreign_keys 有開`
  - 「lit」:`把值包成 SQL 字面值`、`單引號加倍`、`空字串是合法的字面值,不是空字串拼接`、
    `不動中文、換行與其他字元`、`含單引號的值真的能跑完一個 migration 並原樣讀回`、
    `同一個值直接拼進 SQL 則會失敗 —— 這正是 lit 擋掉的事`
  - 「num」:`整數不經過字串形式`
- `store/test/AssetDB/Store/SchemaSpec.hs`(檔頭註明:重點不在「表建得出來」,
  而在**寫不進去的東西真的寫不進去**)
  - 「資料表」:`建出預期的表`、`migration 004 之後不再有 naming_vocab 表`
  - 「assets 的位置約束」:`接受壓縮檔內的項目`、`接受散檔`、`拒絕兩種位置同時填寫`、
    `拒絕兩種位置都不填`
  - 「外鍵約束」:`拒絕指向不存在的 pack`、`刪除 pack 時連帶刪除其 archives`
  - 「授權欄位」:`commercial 沒有預設值,漏填就寫不進去`、
    `attribution_required 同樣沒有預設值`、`commercial 只接受 0 或 1`、
    `未知的維度可以是 NULL,而且 NULL 與 0 意義不同`
  - 「素材包完備狀態」:`draft 允許授權與作者留空 —— 否則匯入會卡住`、
    `ready 但沒有授權時寫不進去`、`ready 但沒有作者時寫不進去`、`兩者皆備才能是 ready`、
    `draft 升級為 ready 時同樣受檢查`
  - 「AI 使用揭露」:`預設是 unknown,不是 none`、`只接受已知的揭露值`
  - 「已查證的授權種子資料」:`只收錄有授權全文可查的`、
    `Crusenho 是唯一要求署名的,且帶有致謝字句`、`第三方授權中只有 Idylwild 允許再散布`、
    `全部允許商用 —— 未查證的授權刻意不收錄`
  - 「列舉欄位」:`status 只接受已知值`、`archive format 只接受支援的格式`
  - 「初始資料」:`頂層分類已建立`、`每個分類都有給模型看的定義與適用範圍`、
    `視覺標註看得到的分類不含 audio 或 level`、`第二層分類的 path 是 父/子 形式`
- `store/test/AssetDB/Store/FtsSpec.hs`
  - 「SQLite 能力探測」:`編進了 FTS5`、`trigram tokenizer 可用`(驗證 schema 的
    FTS5 DDL 在本機建置的 SQLite 上真的建得起來)
