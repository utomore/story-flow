---
id: F006
type: feature
title: store-unified-index
description: 一份 SQLite schema、files 過時偵測、整檔替換、rebuildIndex 與單 vault 查詢
status: done
created: 2026-08-23
updated: 2026-08-24
depends-on: [F001, F004, F005]
related-adr: [ADR-002, ADR-013, ADR-022]
related-feature: []
---

# F006: 一份 schema、`rebuildIndex`、單 vault 查詢(store-unified-index)

## 功能概述

實作 graph-core 讀取管線「files 表比對」到「整檔替換進索引」的整段,以及查詢出口的非全文部分。
本 feature 把 F005 留下的「只有 `meta_info` 一張表」的空殼索引,擴充成 design.md「索引結構」表
描述的完整落地(`files` / `nodes` + 六張專屬表 + `links` + 兩張樹表,**不含**兩張 FTS 表),並在
其上實作 `rebuildIndex` / `refreshStale` / `indexFile` / `unindexFile` 四個索引維護函式,與
`lookupNode` / `lookupByName` / `listNodes` / `childrenOf` / `linksFrom` / `linksTo` /
`loadLinkGraph` 六個單一 vault 查詢函式(`search` 屬 #7,不在本 feature)。

驗收標準(逐字抄自契約卡):

- 對 story vault 與 asset vault 各一個測試 fixture,`rebuildIndex` 兩次結果相同
- `rm index.db` 後 `openVault` + `rebuildIndex` 與刪除前的 `listNodes` / `linksFrom` 結果相同
  (P0 契約測試精神,套件內版本——見「待確認假設」A8 說明與真正的 contract/ 套件測試的關係)
- `childrenOf pck` 回該 pack 全部 asset、`childrenOf ent`(主體)回其片段
- `files` 表以 mtime / size 偵測外部改動並只重讀那個檔
- `checkMeta` 的警告與 `buildTree` 的錯誤進 `IndexIssue`,不中斷整批
- 單一 vault 內 `assets.name` 重複是 `IndexIssue` 錯誤
- `pack.md` 條目為 `missing` 狀態的 asset 仍在索引、`listNodes` 預設不回

**A1 已由開發者裁決並落地(2026-08-23 階段二),不再是阻塞項**:契約 E 改成
`openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))`,
`VaultHandle` 新增 `vhRegistry :: TypeRegistry` 欄位(design.md 契約 E 已同步更新)。`checkMeta`
因此在 `rebuildIndex` / `refreshStale` / `indexFile` 內部直接從 `vhRegistry vh` 取得
`TypeRegistry` 呼叫得動,`IndexIssue` 擴充 `MetaWarningsFound FilePath Id [MetaWarning]`
承載警告(**不擋索引**,節點正常寫入)。這條驗收標準與 `buildTree` 的錯誤(`TreeInvalid`)兩者
都**完整實作**,細節見下方「實作方式」與「實作備註」。

## 相依性

`depends-on: [F001, F004, F005]`(委派 prompt 給的是 `[F004, F005]`;經下方「使用到的既有串接
介面」表反推,`F001` 也直接被逐條使用——`Meta` / `Id` / `Ref` / `Link` / `AnyNode` / `Asset` /
`Pack` / `License` / `Level` / `Node` / `Entity` / `Tree.buildTree` 全部來自 F001 定義的
`aapms-core` 模組,不是透過 F004/F005 間接曝露的型別。這與 F004/F005 自己的慣例一致——兩者都在
`depends-on` 明列直接呼叫的 F001,不只列直接的上游 feature。回報時會把這條修正告知編排者)。

- **F001**:契約 A/B 的全部節點型別、`Id`/`Ref`/`Link`、`AnyNode`、`Tree.buildTree`——索引表結構
  與查詢的回傳型別全部是它
- **F004**:契約 D 全部——`parseDocument` / `docKind` / `toTopic` / `toLevel` / `toPack` /
  `toLicenses`,讀取管線的解析段落
- **F005**:`VaultHandle` / `openIndexAt` / `IndexIssue`(擴充,不重新定義)/ `indexTables`
  (擴充)/ `StoreError`(沿用既有建構子,不新增)/ `Atomic.readTextFile`

**不依賴** F002(`aapms-types`/registry 載入層):`checkMeta` 定義在 `aapms-core`(`Aapms.Core.
Registry`),不在 `aapms-types`——本 feature 呼叫 `checkMeta` 完全靠既有的 `aapms-core`
build-depends 就叫得動,`vhRegistry` 由呼叫端(F005 的 `openVault`)先載入好再收進
`VaultHandle`,本 feature 不做任何 TOML 載入,因此 `aapms-store` 的 `build-depends` 仍然不加
`aapms-types`。不依賴 F003(`Manifest`):索引不產生、不讀 manifest。

`store-fts-dual-index`(#7)、`store-write-operations`(#8)、`store-multi-vault-read`(#9)依賴
本 feature,但本 feature 不依賴它們。

## 對應的 Level 2 契約

實作 design.md「對外契約」契約 E 的 `rebuildIndex` / `refreshStale` / `indexFile` /
`unindexFile` / `lookupNode` / `lookupByName` / `listNodes` / `childrenOf` / `linksFrom` /
`linksTo` / `loadLinkGraph`;契約 F 的 `NodeFilter`;「模組間公開介面」段落的**索引結構**(除兩張
FTS 表與 `fts_map` 之外全部);資料流管線「讀取」段落從「files 表比對」到「整檔替換進索引」,
以及「查詢出口」的非全文部分(`lookupNode` / `listNodes`,不含 `search`)。

擴充(不重新定義)F005 留下的 `IndexIssue`(契約 G「骨架」原則,A6);擴充(不重新定義)F005
的 `indexTables`。**不動** `openVault` / `initVaultAt` / `closeVault` / `VaultHandle` 的欄位組成
——這些是 F005 已交付的契約 E 子集,本 feature 只讀不改。

**不做**(契約卡逐字):不建 FTS 表、不做全文檢索(#7);不做任何寫入(#8);不跨 vault(#9)。

## 實作方式

### 0. `checkMeta` 整合(A1 已解除,兩條驗收標準都完整實作)

`checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`(`core/src/Aapms/Core/Registry.hs:180`)
需要的 `TypeRegistry` 現在由 `VaultHandle` 直接攜帶(`vhRegistry`,D9 裁決,F005 落地
`store/src/Aapms/Store/Marker.hs:73-78`):`rebuildIndex` / `refreshStale` / `indexFile` 內部
一律用 `vhRegistry vh` 呼叫 `checkMeta`,簽名維持「只吃 `VaultHandle`(+`FilePath`)」不變
——`TypeRegistry` 不需要再額外傳一次。

落地方式(`store/src/Aapms/Store/Index.hs` 的 `planWrite`/`metaIssues`):對一份文件解析出的
**每一個節點**(主體、片段、pack 容器、asset、license、Level 容器、Level 的 Node)組成
`AnyNode`,呼叫 `checkMeta (vhRegistry vh) node`;有警告的節點轉成
`IndexIssue` 的 `MetaWarningsFound FilePath Id [MetaWarning]`(擴充,不重新定義,契約 G「骨架」
原則,A6)。**警告不擋索引**——`checkMeta` 本身的契約是「只回警告,不決定要不要擋」,節點正常
寫入 `nodes`/專屬表,警告只是附帶在 `indexFile`/`rebuildIndex`/`refreshStale` 的回傳清單裡。

`buildTree :: Level -> [Node] -> Either [TreeError] NodeTree`(`core/src/Aapms/Core/Tree.hs:86`)
是純函式,`toLevel` 解出 `(Level, [Node])` 後直接呼叫,失敗轉成 `IndexIssue` 的 `TreeInvalid`
建構子(整檔不進索引,與 `checkMeta` 警告的「不擋索引」語意不同——兩者是不同層級的問題:
`buildTree` 失敗代表結構性資料損毀,`checkMeta` 警告只是型別宣告層面的提示)。

### 1. Schema 擴充(`Aapms.Store.Schema`)

延續 F005 的 `indexTables` / `schemaDDL` 擴充模式(注釋已明寫「F006 加業務表時擴充這份清單,
不是另開一份」),依 design.md「索引結構」段落逐字落地(**不含** `fts_tri` / `fts_cjk` /
`fts_map`):

```text
files(path PK, mtime, size, doc_kind)
nodes(id PK, prefix, type, title, summary, status, timeline, timeline_order, source,
      revision, created, updated, file_path, section_anchor, owner)
node_aliases(node_id, alias)  node_tags(node_id, tag)
links(src, dst_vault, dst, kind, note, file_path)
assets(id PK→nodes, name UNIQUE, sha256, entry, ext, meta_json, license, author)
packs(id PK→nodes, vendor, archive, sha256, license, author_json, source_url, ai_disclosure,
      is_reference)
licenses(id PK→nodes, commercial, attribution_required, credit_text, modification_allowed,
         redistribution_allowed, resale_allowed, nft_allowed, source_url)
levels(id PK→nodes, root)
tree_nodes(id PK→nodes, level_id, parent_id, order_idx, kind)
tree_node_entities(node_id, ref)
```

外鍵全部 `ON DELETE CASCADE`,以 `nodes.file_path REFERENCES files(path)` 為根:刪一筆 `files`
連帶砍光該檔的 `nodes` 與全部專屬表/`links`/`node_aliases`/`node_tags`;`tree_node_entities`
掛在 `tree_nodes(id)` 底下。`PRAGMA foreign_keys = ON` 已由 F005 的 `prepareConnection` 開啟
(`store/src/Aapms/Store/Schema.hs:111`),`unindexFile` 因此只需要 `DELETE FROM files`,其餘
全靠級聯——與 ADR-002 對 `.storyflow` 舊模型的既有設計一致,只是表更多。

`assets.license` / `packs.license` 存 `renderRef`(`core/src/Aapms/Core/Id.hs:181`)輸出的單一
文字欄位(`Nothing` → `NULL`),不像 `links` 拆 `dst_vault`/`dst` 兩欄——design.md「索引結構」
逐字只列一個 `license` 欄位,兩種形狀刻意不同,照抄。`packs.author_json` / `assets.meta_json`
存 JSON 文字(`aeson` 編碼 `Author` / `astKindMeta :: Value`)。`files.doc_kind` 存
`"topic"` / `"level"` / `"pack"` / `"license"` 四個字面字串——`Aapms.Md.Document.DocKind`
本身沒有匯出的文字轉換函式,這是 store 自己的持久化編碼,不是對外契約(待確認假設 A6)。

`schemaVersion` 從 F005 的 `1` 改成 `2`(schema 形狀變了,依 ADR-013「`schema_version` 不符即
整庫重建」,不寫 migration,舊索引檔直接被下一次 `openIndexAt` 判定不符並重建)。

`IndexIssue` 擴充**四個**建構子(不動 `SchemaRebuilt`;A1 解除後比原設計多一個
`MetaWarningsFound`,承載 `checkMeta` 的警告):

```haskell
data IndexIssue
  = SchemaRebuilt { irOldVersion :: Maybe Int, irNewVersion :: Int }   -- F005
  | ParseFailed FilePath MdError        -- 整檔解析失敗,不進索引
  | TreeInvalid FilePath [TreeError]    -- LevelDoc 的 buildTree 失敗,不進索引
  | DuplicateAssetName FilePath LogicalName  -- 與既有索引的 name 衝突,整檔不進索引
  | MetaWarningsFound FilePath Id [MetaWarning]  -- checkMeta 警告,不擋索引(A1)
  deriving stock (Show, Eq)
```

`renderIndexIssue` 補四個 case,風格與既有 `SchemaRebuilt` 一致(中文、可操作);
`MetaWarning` 本身沒有 `aapms-core` 匯出的 render 函式(`Aapms.Core.Registry` 只匯出
`checkMeta`),`renderIndexIssue` 因此自帶一個內部的 `renderMetaWarning`。

### 2. 內部列轉換模組(`Aapms.Store.Row`,新)

比照 legacy `Row.hs` 的理由(集中寫入與讀出的欄位規則,避免 `Index` 與 `Query` 各寫一份、
「刪掉 index.db 重建後等價」這條保證要求兩邊完全一致):

- `nodeColumnList :: [Text]`——對照 `nodes` 表的 15 欄(id/prefix/type/title/summary/status/
  timeline/timeline_order/source/revision/created/updated/file_path/section_anchor/owner)
- `nodeFields :: Meta -> IdPrefix -> FilePath -> Maybe Text -> Maybe Id -> [SQLData]`——把一個
  `Meta` + 它的 prefix + 檔案路徑 + section anchor(`Nothing` = 檔案層容器)+ owner 轉成一列
- `NodeRow` 型別 + `FromRow` 實例(對照 15 欄)、`hydrateMeta :: Connection -> NodeRow -> IO Meta`
  ——回填 `node_aliases` / `node_tags` / `links`(以 `id` 查 3 張附屬表,同一個節點只查一次,
  比照 legacy `hydrate` 的做法避免 N+1)
- 六個專屬表各自的 row 型別與 `FromRow`:`AssetRow` / `PackRow` / `LicenseRow` / `LevelRow` /
  `TreeNodeRow`(對照 design.md 逐欄)
- `renderDocKind` / `parseDocKind :: DocKind <-> Text`(待確認假設 A6)
- `SQLData` 輔助沿用 legacy `Row.hs` 的 `sText` / `sInt` / `sMaybeText` / `sMaybeInt` / `dayText`
  形狀(legacy 檔案本身在 T1 的委派決策下不重用,只重用**寫法**)

### 3. `Aapms.Store.Index`(新,取代 legacy `Index.hs` 這份素材)

**檔案掃描**:`vaultMarkdownFiles`-等價的內部函式,沿用 legacy 的規則(`store/src/Aapms/Store/
Index.hs:88-102`,ADR-002 對 `.storyflow` 已驗證的邏輯):走訪 `vhRoot`,略過任何以 `.` 開頭的
目錄名(`.aapms/`、`.git/`、編輯器暫存),只收 `.md`,排序後回傳 vault 相對路徑——排序是
「重建後逐筆相同」的前提。

**單檔索引(`indexOne`,內部)**:讀檔(`Atomic.readTextFile`,I/O 失敗直接 `Left StoreError`,
不算 `IndexIssue`)→ `statOf`(mtime 奈秒 + size,legacy 手法沿用,`Index.hs:362-372`)→
`parseDocument`(失敗 → `Right [ParseFailed path e]`,不進索引,不是 `StoreError`)→ `docKind`
判別 → 依四種身分呼叫 `toTopic` / `toLevel` / `toPack` / `toLicenses`(失敗同樣是
`ParseFailed`)→ 對 `LevelDoc` 額外呼叫 `buildTree`(失敗 → `TreeInvalid`,**其餘三種文件不呼叫
`buildTree`**,它只對 Level 有意義)→ 對文件內每個節點呼叫 `checkMeta (vhRegistry vh)`,有警告
的收集成 `MetaWarningsFound`(A1,不影響是否寫入)→ 組出待寫入的列 → 一個 SQLite transaction
內:先刪掉這個 `file_path` 既有的 `files` 列(級聯清掉舊資料,見上方 Schema 一節),寫入新
`files` 列,寫入 `nodes` + 對應專屬表 + `links`;若途中撞到 `assets.name UNIQUE` 衝突,**整個
transaction 回滾**、回報 `DuplicateAssetName`(待確認假設 A2:granularity 是整檔,不是單筆
asset——與 `ParseFailed`/`TreeInvalid` 同一個「整檔不進索引」的失敗模型一致,`indexFile`/
`rebuildIndex` 因此永遠回報「這個檔案有沒有進索引」而不必再分兩層)。

**實作備註(`buildTree` 實際可觸發的路徑)**:`toLevel` 自己的 `structure`/`rootId` 已經把「標題
跳級」「root 與第一節不符」擋在 `MdError`(→`ParseFailed`)那一層——由合法標題巢狀結構長出來的
`[Node]` 天生滿足 `buildTree` 的五條不變量,`OrphanNode`/`Cycle`/`MultipleRoots`/`DuplicateOrder`/
`DuplicateNodeId` 因此在 `toLevel` 輸出上實務不可能發生。真正會讓 `buildTree` 失敗的路徑是
「frontmatter 宣告了 `root`,但檔案裡一個節都沒有」——`rootId` 對 `(Just root, [])` 直接放行,
`buildTree` 收到空節點清單才回報 `NoRoot`。`TreeInvalid` 因此保留為防禦性檢查(涵蓋 `toLevel`
未來變動的情況),不是死碼。

**`indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])`**:接受絕對路徑
或 vault 相對路徑(對照 F005 `openVault`/`initVaultAt` 用 `makeAbsolute` 正規化的慣例),呼叫
`indexOne`。回傳的 `[IndexIssue]` 有兩種情況:整檔不進索引時恰有一筆(`ParseFailed`/
`TreeInvalid`/`DuplicateAssetName`);檔案已正常進索引時是零到多筆 `MetaWarningsFound`(每個有
警告的節點一筆)。

**`unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())`**:正規化路徑後
`DELETE FROM files WHERE path = ?`,交給外鍵級聯清掉其餘全部。找不到該路徑的記錄不是錯誤
(冪等)。

**`rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])`**:`DELETE FROM files`
(單一陳述式本身即原子操作,不需另包 transaction;級聯清空全部業務表,`meta_info` 不動)→
`vaultMarkdownFiles` 掃出排序後的清單 → 依序 `indexOne`,任何 `StoreError`(SQLite 層、檔案
I/O)直接中止並回傳 `Left`;每筆 `IndexIssue`(含 `MetaWarningsFound`)收集但不中止,對應驗收
標準「不中斷整批」。

**`refreshStale :: VaultHandle -> IO (Either StoreError [IndexIssue])`**:`SELECT path, mtime,
size FROM files` 與磁碟現況(`vaultMarkdownFiles` + 逐檔 `statOf`)比對,兩者的差集決定「過時
或新增」(需要重新 `indexOne`)與「消失」(需要 `unindexFile`)兩組路徑;消失的先處理(各自
獨立的小 transaction 亦可,不影響本 ADR-022 寫鎖預算——每個動作都是純 SQL,交易外只有比對用的
`stat` 呼叫),過時/新增的逐一 `indexOne`。這是驗收標準「`files` 表以 mtime / size 偵測外部
改動並只重讀那個檔」的落地。

**ADR-022(寫鎖預算)合規性**:`indexOne` 的交易內只有已經算好的 `SQLData` 的 `INSERT`/`DELETE`
——讀檔(`Atomic.readTextFile`)、`stat`、`parseDocument`/`toTopic`等純函式解析全部在交易**外**
先算完,交易內不重算、不做檔案 IO。`rebuildIndex`/`refreshStale` 的每個檔案各自開一個短交易
(不是整個 vault 一個大交易),符合「持有時間以毫秒計」。

### 4. `Aapms.Store.Query`(新,取代 legacy `Query.hs` 這份素材)

**`NodeFilter` → SQL**:`nfPrefixes`/`nfTypes` 有值時 `IN (...)`;`nfStatus = []` 時
`status <> 'missing'`,非空時 `IN (...)`(design.md 契約 F 下方已定案的語意,逐字落地);
`nfTags` 非空時每個 tag 各自一個 `EXISTS (... node_tags ...)`,多個 tag 是 **AND**(待確認假設
A4,契約未明定);`nfOwner` 是 `owner = ?`;`nfLicense` 是 `assets.license = ? OR packs.license =
?`(LEFT JOIN 兩張表,因為只有這兩種節點有 license 欄位);`nfNamedOnly` LEFT JOIN `assets` 並
`assets.name IS NOT NULL`(非 asset 節點的 join 結果 name 恆 NULL,天然被排除);
`nfIncludeReference = False`(預設)時排除「自己是 `packs.is_reference` 的節點」**以及**「
`owner` 指向這種 pack 的節點」(待確認假設 A3:適用範圍包含 pack 本身,不只它的 asset)。
`nfLimit`/`nfOffset` 直接映射 SQL `LIMIT`/`OFFSET`。

**`listNodes :: VaultHandle -> NodeFilter -> IO [Meta]`**:組出上述 WHERE 子句,`SELECT id FROM
nodes ...`,再用 `Row.hydrateMeta` 批次(比照 legacy `metasInOrder` 一次撈三張附屬表、按 id 分組,
避免 N+1)組回 `[Meta]`。

**`lookupNode :: VaultHandle -> Id -> IO (Maybe AnyNode)`**:`SELECT prefix FROM nodes WHERE id
= ?` 決定分支:
- `PEnt`:`hydrateMeta` 出 `Meta`;`section_anchor` 為 `NULL` 時是主體,回讀檔案
  (`vhRoot </> file_path`)重新 `parseDocument` + `toTopic`,取 `fst`(主體 `Entity`)的 body;
  否則 `toTopic` 取 `snd` 依 id 找片段的 body。**只有 body 需要回讀檔案**——`Meta`/`tags`/
  `aliases`/`links` 全部已在索引裡(design.md「`body` 進 FTS 但不進 `nodes`:正文只有檔案有」,
  索引其餘欄位不受此限)
- `PAst`:回讀檔案 + `toPack`,依 id 在 `[Asset]` 裡找到對應的 body,其餘欄位(`name`/`sha256`/
  `entry`/`ext`/`meta`/`license`/`author`)直接從 `assets` 表讀(不必回讀檔案就能得到,只有
  `astBody` 需要)
- `PPck`:同上,取 `toPack` 的 `fst`(容器 `Pack`)的 body
- `PLic`:`License` 沒有 body 欄位,純索引查詢(`licenses` 表 + `hydrateMeta`),**不回讀檔案**
- `PLvl`:`Level` 沒有 body,純索引查詢(`levels` 表 + `hydrateMeta`)
- `PNod`:`Node` 沒有 body,純索引查詢(`tree_nodes` 表 + `tree_node_entities` + `hydrateMeta`)
- `PVlt`/`PPrj`:不是本子系統管的節點種類(vault/project 是 `workspace`/`project` 子系統的東西,
  不會出現在 `nodes` 表),`lookupNode` 對這兩種 prefix 的 id 回 `Nothing`

（待確認假設 A5:`PEnt`/`PAst`/`PPck` 每次 `lookupNode` 都重新讀檔+解析整份檔案才能取得 body,
與 legacy `lookupEntity` 同一個成本模型,不是本 feature 的效能退化——索引故意不重複存 body。）

**`lookupByName :: VaultHandle -> LogicalName -> IO (Maybe Asset)`**:`SELECT id FROM assets
WHERE name = ?`,查到就走上面 `PAst` 分支同一條路徑組回 `Asset`;查不到 `Nothing`。

**`childrenOf :: VaultHandle -> Id -> IO [Meta]`**:`SELECT id FROM nodes WHERE owner = ?`,
`hydrateMeta` 组回 `[Meta]`。`owner` 只在片段(`toTopic` 的 `[Entity]`,owner = 主體 id)與
asset(`toPack` 的 `[Asset]`,owner = pack id)兩種情境被填,`toLevel`/`toLicenses` 產出的節點
`owner` 恆 `NULL`——Level/Node 的包含關係走 `tree_nodes` 的 `level_id`/`parent_id`,不是本函式
的職責(那是 `aapms-core` 的 `NodeTree`/`buildTree` 走訪,不在契約 E 的查詢函式清單內)。

**`linksFrom :: VaultHandle -> Id -> IO [Link]`**:`SELECT dst_vault, dst, kind, note FROM links
WHERE src = ? ORDER BY rowid`,組回 `[Link]`。

**`linksTo :: VaultHandle -> Ref -> IO [(Meta, Link)]`**:注意契約簽名回傳 `(Meta, Link)` 不是
`(Id, Link)`(與 legacy `Query.hs:237` 的 `(Id, Link)` 不同,見待確認假設 A7)——依 `Ref` 的
`refVault` 決定 `dst_vault IS NULL`(本 vault)或 `dst_vault = ?`(帶 vault 前綴,理論上本 feature
只索引單一 vault,`dst_vault` 非 NULL 的記錄本來就存在——那是指向**別的** vault 的 link,只在
`links` 表被動記錄,查詢時原樣比對即可,不代表本 feature 做跨 vault 讀)查出 `src` 清單,逐一
`hydrateMeta` 組回 `(Meta, Link)`。

**`loadLinkGraph :: VaultHandle -> IO LinkGraph`**:`SELECT src, dst_vault, dst, kind, note FROM
links ORDER BY rowid`,以 `src` 分組成 `M.Map Id [Link]`(`LinkGraph` 的定義,
`core/src/Aapms/Core/Link.hs:172`),不需要 hydrate Meta——`conflict` 子系統只需要圖的邊。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: VaultId, metaType :: TypeKey, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Maybe Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Revision, metaCreated :: Day, metaUpdated :: Day }` | `core/src/Aapms/Core/Meta.hs:123-139` | F001 | 索引表的核心欄位來源、`listNodes`/`lookupNode` 的回傳基礎 |
| `metaFieldNames :: [Text]` | `core/src/Aapms/Core/Meta.hs:146-162` | F001 | 對照確認 `nodeColumnList` 沒有漏掉或多出欄位(僅供交叉檢查,非執行期依賴) |
| `data Status = Draft \| Canon \| Deprecated \| Missing`、`renderStatus`、`parseStatus` | `core/src/Aapms/Core/Meta.hs:57-77` | F001 | `nodes.status` 的欄位型別;`nfStatus`/`Missing` 過濾語意 |
| `data Source = Human \| Agent Text \| Workshop Text \| Scan \| Ai Text`、`renderSource`、`parseSource` | `core/src/Aapms/Core/Meta.hs:80-107` | F001 | `nodes.source` |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` | `core/src/Aapms/Core/Meta.hs:112-116` | F001 | `nodes.timeline`/`timeline_order` |
| `newtype TypeKey = TypeKey Text`、`newtype Revision = Revision Int` | `core/src/Aapms/Core/Meta.hs:45-52` | F001 | `nodes.type`/`nodes.revision` 解開 newtype 寫入 |
| `newtype Id`(不透明)、`parseId`、`renderId`、`idPrefix :: Id -> IdPrefix` | `core/src/Aapms/Core/Id.hs:86-141` | F001 | 全部表的主鍵格式;`lookupNode` 依 `idPrefix` 分支 |
| `data IdPrefix = PEnt \| PAst \| PPck \| PLic \| PLvl \| PNod \| PVlt \| PPrj`、`renderIdPrefix`、`parseIdPrefix` | `core/src/Aapms/Core/Id.hs:46-78` | F001 | `nodes.prefix` 欄位、`lookupNode`/`NodeFilter.nfPrefixes` |
| `newtype VaultId = VaultId Text` | `core/src/Aapms/Core/Id.hs:148-150` | F001 | `nodes.file_path` 解讀無關,但 `Meta.metaVault` 型別 |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`parseRef`、`renderRef` | `core/src/Aapms/Core/Id.hs:156-182` | F001 | `links.dst_vault`/`dst`、`assets.license`/`packs.license`、`linksTo`/`nfLicense` 的參數型別 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }`、`renderLinkKind`、`parseLinkKind` | `core/src/Aapms/Core/Link.hs:28-95` | F001 | `links` 表欄位與 `linksFrom`/`linksTo`/`loadLinkGraph` 的回傳型別 |
| `type LinkGraph = M.Map Id [Link]` | `core/src/Aapms/Core/Link.hs:172` | F001 | `loadLinkGraph` 回傳型別 |
| `data AnyNode = NEntity Entity \| NAsset Asset \| NPack Pack \| NLicense License \| NLevel Level \| NNode Node`、`anyMeta`、`prefixOf` | `core/src/Aapms/Core/AnyNode.hs:19-46` | F001 | `lookupNode` 的回傳型別 |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/Aapms/Core/Entity.hs:12-17` | F001 | `lookupNode` 的 `NEntity` 分支 |
| `data Asset = Asset { astMeta, astName :: Maybe LogicalName, astSha256 :: Sha256, astEntry :: Text, astExt :: Maybe Text, astKindMeta :: Value, astLicense :: Maybe Ref, astAuthor :: Maybe Text, astBody :: Text }`、`newtype Sha256`、`newtype LogicalName` | `core/src/Aapms/Core/Asset.hs:17-46` | F001 | `assets` 表欄位、`lookupNode`/`lookupByName` 的 `NAsset`/回傳型別 |
| `data Pack = Pack { pckMeta, pckVendor :: Maybe Text, pckArchive :: Maybe FilePath, pckSha256 :: Maybe Sha256, pckLicense :: Maybe Ref, pckAuthor :: Maybe Author, pckSourceUrl :: Maybe Text, pckAiDisclosure :: AiDisclosure, pckBody :: Text }`、`data Author`、`data AiDisclosure` | `core/src/Aapms/Core/Pack.hs:19-47` | F001 | `packs` 表欄位、`lookupNode` 的 `NPack` 分支 |
| `data License = License { licMeta, licCommercial :: Bool, licAttributionRequired :: Bool, licCreditText :: Maybe Text, licModificationAllowed :: Maybe Bool, licRedistributionAllowed :: Maybe Bool, licResaleAllowed :: Maybe Bool, licNftAllowed :: Maybe Bool, licSourceUrl :: Maybe Text, licFullText :: Maybe Text }` | `core/src/Aapms/Core/License.hs:13-25` | F001 | `licenses` 表欄位、`lookupNode` 的 `NLicense` 分支 |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }` | `core/src/Aapms/Core/Level.hs:19-24` | F001 | `levels` 表欄位、`lookupNode` 的 `NLevel` 分支 |
| `data Node = Node { nodMeta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }`、`data NodeKind`、`renderNodeKind`、`parseNodeKind` | `core/src/Aapms/Core/Level.hs:26-71` | F001 | `tree_nodes`/`tree_node_entities` 表欄位、`lookupNode` 的 `NNode` 分支 |
| `data NodeTree`、`data TreeError`、`buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/Aapms/Core/Tree.hs:33-91`(型別)、`86` (簽名) | F001 | `indexOne` 對 `LevelDoc` 的驗證,失敗轉 `IndexIssue` 的 `TreeInvalid` |
| `data DocKind = TopicDoc \| LevelDoc \| PackDoc \| LicenseDoc` | `md/src/Aapms/Md/Document.hs:68-69` | F004 | `indexOne` 依此分支呼叫對應的 `to*`;`files.doc_kind` 的來源型別 |
| `data Document`、`docKind :: Document -> DocKind` | `md/src/Aapms/Md/Document.hs:71-86` | F004 | `parseDocument` 的回傳型別、分支依據 |
| `parseDocument :: Text -> Either MdError Document` | `md/src/Aapms/Md/Parse.hs:51` | F004 | `indexOne`/`lookupNode` 讀檔後的第一步 |
| `toTopic :: Document -> Either MdError (Entity, [Entity])` | `md/src/Aapms/Md/Parse.hs:123` | F004 | `indexOne` 對 `TopicDoc`;`lookupNode` 的 `PEnt` 分支回讀 body |
| `toLevel :: Document -> Either MdError (Level, [Node])` | `md/src/Aapms/Md/Parse.hs:139` | F004 | `indexOne` 對 `LevelDoc`,結果餵給 `buildTree` |
| `toPack :: Document -> Either MdError (Pack, [Asset])` | `md/src/Aapms/Md/Parse.hs:243` | F004 | `indexOne` 對 `PackDoc`;`lookupNode`/`lookupByName` 的 `PAst`/`PPck` 分支回讀 body |
| `toLicenses :: Document -> Either MdError [License]` | `md/src/Aapms/Md/Parse.hs:319` | F004 | `indexOne` 對 `LicenseDoc` |
| `data MdError = MdError { errLine :: Int, errKind :: MdErrorKind }` | `md/src/Aapms/Md/Error.hs:23-27` | F004 | `IndexIssue` 的 `ParseFailed` 建構子攜帶的錯誤型別 |
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection }` | `store/src/Aapms/Store/Marker.hs:66-70` | F005 | 全部十個契約 E 函式的第一個參數;直接用 `vhConn`/`vhRoot` |
| `data VaultMarker = VaultMarker { vmId, vmKind, vmName, vmRefs }` | `store/src/Aapms/Store/Marker.hs:56-62` | F005 | 讀 `vhMarker` 判斷 vault 身分(目前 F006 不需要,留供 #9 之類的未來擴充) |
| `openIndexAt :: FilePath -> VaultId -> VaultKind -> Text -> IO (Either StoreError (Connection, [IndexIssue]))` | `store/src/Aapms/Store/Schema.hs:90-95`(簽名) | F005 | 不直接呼叫(`openVault`/`initVaultAt` 已呼叫過),但本 feature 擴充它內部用到的 `ensureSchema`/`resetSchema`/`createSchema`/`indexTables` |
| `data IndexIssue = SchemaRebuilt { irOldVersion :: Maybe Int, irNewVersion :: Int }` | `store/src/Aapms/Store/Schema.hs:66-71` | F005 | 本 feature 擴充的既有型別(A6 原則) |
| `indexTables :: [Text]` | `store/src/Aapms/Store/Schema.hs:81-82` | F005 | 本 feature 擴充的既有清單 |
| `resetSchema :: Connection -> IO ()`、`createSchema :: Connection -> IO ()`、`currentVersion :: Connection -> IO (Maybe Int)` | `store/src/Aapms/Store/Schema.hs:157-169,127-138` | F005 | 依賴新 `schemaDDL`/`indexTables` 自動涵蓋新表,函式本身不改 |
| `data StoreError = VaultMarkerMissing FilePath \| VaultMarkerInvalid FilePath Text \| VaultAlreadyInitialized FilePath \| FileReadFailed FilePath Text \| FileWriteFailed FilePath Text \| SqliteError Text`、`renderStoreError`、`trySqlite` | `store/src/Aapms/Store/Error.hs:17-65` | F005 | `indexFile`/`rebuildIndex`/`refreshStale` 的錯誤通道;本 feature **不新增**建構子(內容層失敗一律走 `IndexIssue`,不是 `StoreError`) |
| `readTextFile :: FilePath -> IO (Either StoreError Text)` | `store/src/Aapms/Store/Atomic.hs:35-42` | F005 | `indexOne`/`lookupNode` 讀檔 |
| `Database.SQLite.Simple`(`Connection`/`query`/`query_`/`execute`/`execute_`/`withTransaction`/`lastInsertRowId`) | `sqlite-simple` 套件(既有 build-depends) | - | `Index`/`Query`/`Row` 三個新模組的 SQL 執行 |

## 新增的介面

```haskell
-- Aapms.Store.Schema(擴充)

schemaVersion :: Int
schemaVersion = 2                -- 從 F005 的 1 改;shape 變了,依 ADR-013 整庫重建,不寫 migration

data IndexIssue
  = SchemaRebuilt { irOldVersion :: Maybe Int, irNewVersion :: Int }   -- F005,不動
  | ParseFailed FilePath MdError
  | TreeInvalid FilePath [TreeError]
  | DuplicateAssetName FilePath LogicalName
  | MetaWarningsFound FilePath Id [MetaWarning]   -- A1 解除後新增,不擋索引
  deriving stock (Show, Eq)

renderIndexIssue :: IndexIssue -> Text   -- 補四個新 case

indexTables :: [Text]   -- 擴充到 12 項:meta_info, files, nodes, node_aliases, node_tags, links,
                        -- assets, packs, licenses, levels, tree_nodes, tree_node_entities


-- Aapms.Store.Index(新模組)

indexFile    :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])
unindexFile  :: VaultHandle -> FilePath -> IO (Either StoreError ())
rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])
refreshStale :: VaultHandle -> IO (Either StoreError [IndexIssue])


-- Aapms.Store.Query(新模組)

data NodeFilter = NodeFilter
  { nfPrefixes :: [IdPrefix]
  , nfTypes :: [TypeKey]
  , nfStatus :: [Status]
  , nfTags :: [Text]
  , nfOwner :: Maybe Id
  , nfLicense :: Maybe Ref
  , nfNamedOnly :: Bool
  , nfIncludeReference :: Bool
  , nfLimit :: Int
  , nfOffset :: Int
  }
  deriving stock (Show, Eq)

emptyNodeFilter :: NodeFilter    -- 全部欄位取最寬鬆的預設值(nfLimit 需要一個有限預設值,
                                  -- 見待確認假設 A9);契約 F 沒有明列這個輔助值,但 NodeFilter
                                  -- 全欄必填,呼叫端需要一個起點,比照 F005 對 IndexIssue 的
                                  -- 態度,補一個最小合理的建構輔助

lookupNode   :: VaultHandle -> Id -> IO (Maybe AnyNode)
lookupByName :: VaultHandle -> LogicalName -> IO (Maybe Asset)
listNodes    :: VaultHandle -> NodeFilter -> IO [Meta]
childrenOf   :: VaultHandle -> Id -> IO [Meta]
linksFrom    :: VaultHandle -> Id -> IO [Link]
linksTo      :: VaultHandle -> Ref -> IO [(Meta, Link)]
loadLinkGraph :: VaultHandle -> IO LinkGraph


-- Aapms.Store.Row(新模組,內部使用,不經 Aapms.Store 門面 re-export)

-- 節點列的欄位清單、SQLData 轉換、Meta 的 hydrate、DocKind 文字編碼、六個專屬表的 row 型別。
-- 不承諾對外介面(對照 legacy Row.hs 頂部註解的既有慣例),Index/Query 內部共用避免寫入與
-- 讀出的欄位規則漂移。__實作備註__:cabal 層級放在 exposed-modules(不是 other-modules)
-- 只是為了讓 T2 的 row-roundtrip 測試能從 test-suite 白箱直接 import——other-modules 對
-- 同一個 package 的 test-suite component 也不可見,這是 Cabal 的套件邊界,不是模組內容的
-- 邊界。「不對外承諾介面」的約束由 Aapms.Store 門面**不** re-export 它來體現,不是靠
-- exposed-modules 藏起來;下游套件(service/asset-ingest)理論上叫得到,但沒有文件說它是
-- 穩定介面。


-- Aapms.Store(門面模組,擴充 re-export)

module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Error
  , module Aapms.Store.Marker
  , module Aapms.Store.Schema
  , module Aapms.Store.Index    -- 新增
  , module Aapms.Store.Query    -- 新增
  ) where
```

`Aapms.Store.Row` **不**加進門面——它是內部列轉換,`service`/`asset-ingest` 不應該直接碰
`SQLData`/`FromRow` 這層,只透過 `Index`/`Query` 的函式互動。

## TodoList

- [x] T1: `Aapms.Store.Schema` 擴充:`indexTables`/`schemaDDL` 加 11 張業務表(含 `ON DELETE
  CASCADE` 外鍵)、`schemaVersion` 改 2、`IndexIssue` 加**四個**建構子(A1 解除後多一個
  `MetaWarningsFound`)、`renderIndexIssue` 補四個 case  `dep: -`
- [x] T2: 新建 `Aapms.Store.Row`:`nodeColumnList`/`nodeFields`/`NodeRow`/`hydrateMeta`、六個
  專屬表的 row 型別與 `FromRow` 實例、`renderDocKind`/`parseDocKind`、`SQLData` 輔助
  `dep: T1`
- [x] T3: 新建 `Aapms.Store.Index`:內部檔案掃描(`vaultMarkdownFiles` 等價,略過 `.` 開頭目錄、
  只收 `.md`、排序)與 `statOf`(mtime 奈秒 + size)  `dep: T1`
- [x] T4: `Aapms.Store.Index`:`indexOne`(內部)——讀檔 → `parseDocument` → `docKind` 分支 →
  `to*` → `LevelDoc` 額外 `buildTree` → 對每個節點 `checkMeta` → 一個 transaction 內刪舊插新;
  `assets.name` 衝突整檔回滾回報 `DuplicateAssetName`  `dep: T2, T3`
- [x] T5: `Aapms.Store.Index`:`indexFile`/`unindexFile` 依 `indexOne`/`DELETE FROM files`
  組出  `dep: T4`
- [x] T6: `Aapms.Store.Index`:`rebuildIndex`(清空業務表 → 排序掃描 → 逐檔 `indexOne` → 收集
  `IndexIssue`,`StoreError` 直接中止)  `dep: T4, T5`
- [x] T7: `Aapms.Store.Index`:`refreshStale`(`files` 表 vs 磁碟現況的 mtime/size 差集 →
  消失的 `unindexFile`、過時/新增的 `indexOne`)  `dep: T4, T5`
- [x] T8: 新建 `Aapms.Store.Query`:`NodeFilter`、`emptyNodeFilter`、WHERE 子句組裝(`nfStatus =
  []` 排除 missing、`nfTags` AND、`nfNamedOnly`/`nfIncludeReference`/`nfLicense` 的 JOIN 邏輯)、
  `listNodes`  `dep: T2`
- [x] T9: `Aapms.Store.Query`:`lookupNode`(依 prefix 分七支,`PEnt`/`PAst`/`PPck` 回讀檔案取
  body,其餘純索引)  `dep: T2, T8`
- [x] T10: `Aapms.Store.Query`:`lookupByName`(查 `assets.name` → 走 `PAst` 同一條路徑)
  `dep: T9`
- [x] T11: `Aapms.Store.Query`:`childrenOf`(`owner = ?` 查詢)  `dep: T2`
- [x] T12: `Aapms.Store.Query`:`linksFrom`/`linksTo`/`loadLinkGraph`  `dep: T2`
- [x] T13: `store/aapms-store.cabal`:library `exposed-modules` 加 `Aapms.Store.Index`/
  `Aapms.Store.Query`/`Aapms.Store.Row`(實作備註:Row 也放 exposed-modules,不是
  other-modules——test-suite 是獨立 component,other-modules 對它不可見,見上方「新增的介面」
  Row 段落的說明);`build-depends` 加回 `aapms-md`(F005 移除的那條,本 feature 需要
  `parseDocument`/`to*`)與 `aeson`(Row 的 JSON 編解碼需要);test-suite 對應更新;`Aapms.Store`
  門面加兩個 re-export  `dep: T1-T12`
- [x] T14: `store/test/Aapms/Store/Fixtures.hs` 擴充:story vault 與 asset vault 各一份最小但
  完整的 fixture(story:一份主題檔含片段 + 一份 Level 檔含至少兩個 Node;asset:一份 `pack.md`
  含至少兩個 asset(其一 `status: missing`)+ 一份 `licenses.md`),以及把 fixture 文字寫進臨時
  vault 目錄的輔助函式  `dep: T13`
- [x] T15: 改寫 `store/test/Aapms/Store/IndexSpec.hs`/`RebuildSpec.hs`/`StaleSpec.hs`:
  `rebuildIndex` 兩次結果相同、`rm index.db` 後重建與刪除前 `listNodes`/`linksFrom` 相同、
  `refreshStale` 只重讀改動過的檔、`ParseFailed`/`TreeInvalid`/`DuplicateAssetName` 不中斷整批
  `dep: T14`
- [x] T16: 改寫 `store/test/Aapms/Store/QuerySpec.hs`/`NodeSpec.hs`:`lookupNode` 七種 prefix
  分支、`lookupByName`、`childrenOf`(pack→asset、主體→片段)、`linksFrom`/`linksTo`/
  `loadLinkGraph`、`NodeFilter` 各欄位(含 `nfStatus=[]` 排除 missing、`missing` asset 仍在索引)
  `dep: T14`
- [x] T17: `store/test/Spec.hs` 註冊新 Spec;`cabal build aapms-store`/`cabal test aapms-store`
  全綠;`cabal build all`/`cabal test all` 全綠(四個套件基線數字維持,`aapms-store` 從
  40/0 增至 73/0)  `dep: T15, T16`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_schema_has_all_tables | `openIndexAt` 建出的資料庫含 12 張表(`sqlite_master` 查詢),`schema_version = 2`(`SchemaSpec.hs`) |
| T1 | test_index_issue_render_new_cases | `renderIndexIssue` 對 `ParseFailed`/`TreeInvalid`/`DuplicateAssetName`/`MetaWarningsFound` 輸出非空、含中文、指出檔案路徑(`SchemaSpec.hs`) |
| T2 | test_row_roundtrip | 對合成的 `Meta`(含 tags/aliases/links/timeline)寫入 `nodes`+附屬表後 `hydrateMeta` 讀回,欄位相等(`RowSpec.hs`,新增檔案——原表未列 T2 的所在檔案,補上) |
| T2 | test_dockind_text_roundtrip | `parseDocKind . renderDocKind` 對四種 `DocKind` 是 identity(`RowSpec.hs`) |
| T3 | test_scan_skips_dot_dirs_and_non_md | 臨時目錄含 `.aapms/`、`.git/`、`foo.txt`、`bar.md`,掃描只回 `bar.md`(`IndexSpec.hs`) |
| T4 | test_indexOne_topic | story fixture 的主題檔索引後,`nodes` 有主體(owner NULL)+ 片段(owner = 主體 id) |
| T4 | test_indexOne_pack | asset fixture 的 pack.md 索引後,`nodes`/`assets` 有 pack(owner NULL)+ 全部 asset(owner = pack id),含 `status = missing` 的那筆 |
| T4 | test_indexOne_level_tree_invalid | **實作備註**:`toLevel` 自己的 `structure`/`rootId` 已把「跳級」「root 不符第一節」擋在 `MdError` 那層,由合法標題長出的 `[Node]` 天生滿足 `buildTree` 的不變量——真正能讓 `buildTree` 失敗的只有「frontmatter 宣告 `root` 但檔案零個 Node」。測試改用這個 fixture,索引結果含 `TreeInvalid`,`nodes` 沒有該檔案的殘留 |
| T4 | test_indexOne_parse_failed | 造一個 YAML 壞掉的檔案,索引結果含 `ParseFailed`,`nodes` 沒有殘留 |
| T4 | test_indexOne_duplicate_asset_name | 兩個不同檔案的 asset 撞同一個 `name`,後索引的那個檔案整檔回滾並回 `DuplicateAssetName`,先索引的那個保留 |
| T5 | test_indexFile_reindex_replaces | 對已索引的檔案改內容後重新 `indexFile`,舊記錄被整檔替換而非疊加 |
| T5 | test_unindexFile_cascades | `unindexFile` 後該檔案的 `nodes`/`assets`/`links`/`node_tags` 等全部記錄消失,`files` 也消失 |
| T5 | test_unindexFile_idempotent | 對不存在的路徑呼叫 `unindexFile` 不報錯 |
| T6 | test_rebuild_idempotent | 對兩個 fixture vault 各跑兩次 `rebuildIndex`,兩次的 `listNodes emptyNodeFilter`/`linksFrom`/`childrenOf` 結果相同 |
| T6 | test_rebuild_not_aborted_by_content_issues | fixture 混入一個解析失敗的檔案,`rebuildIndex` 仍把其餘檔案正確索引且回傳含該筆 `IndexIssue` |
| T7 | test_rm_index_db_rebuild_equivalent | P0 契約測試精神(套件內版本):索引後拍下 `listNodes`/`linksFrom` 快照,`rm index.db` → `openVault` → `rebuildIndex`,快照相同 |
| T7 | test_refresh_stale_only_rereads_changed | 索引後只改一個檔案的 mtime/size,`refreshStale` 只重讀那一個,其餘檔案的 `nodes.revision` 等欄位不變(可由 rowid 或內容比對驗證未被觸碰) |
| T7 | test_refresh_stale_removes_gone_files | 索引後刪除磁碟上一個檔案,`refreshStale` 把該檔案的記錄移除 |
| T8 | test_nodeFilter_status_default_excludes_missing | `nfStatus = []` 的 `listNodes` 不回 `status = missing` 的 asset,`nfStatus = [Missing]` 才回 |
| T8 | test_nodeFilter_named_only | `nfNamedOnly = True` 只回 `assets.name` 非 NULL 的節點 |
| T8 | test_nodeFilter_include_reference | pack 路徑含 `library/reference/` 的 fixture(`is_reference = True`),預設 `listNodes` 排除該 pack 與其 asset,`nfIncludeReference = True` 才回 |
| T8 | test_nodeFilter_prefixes_types_tags | 組合 `nfPrefixes`/`nfTypes`/`nfTags` 驗證交集語意 |
| T9 | test_lookupNode_all_prefixes | 對 fixture 裡的 `ent`/`ast`/`pck`/`lic`/`lvl`/`nod` 六種 id 呼叫 `lookupNode`,回傳對應的 `AnyNode` 建構子且欄位(含回讀的 body)正確;`vlt-`/`prj-` 開頭的 id 回 `Nothing` |
| T10 | test_lookupByName | 已命名的 asset 查得到,未命名(`astName = Nothing`)或不存在的名稱回 `Nothing` |
| T11 | test_childrenOf_pack_and_entity | `childrenOf` 對 pack id 回全部 asset、對主體 entity id 回全部片段,對一個沒有子節點的 id 回 `[]` |
| T12 | test_linksFrom_linksTo_loadLinkGraph | fixture 建兩條關聯,`linksFrom` 依來源查、`linksTo` 依目標查(含 `Meta` 正確)、`loadLinkGraph` 回傳的 map 與兩者一致 |
| T13 | test_cabal_wiring | `aapms-store.cabal` 原始碼含 `Aapms.Store.Index`/`Query`/`Row`/`aapms-md`;`Aapms.Store` 門面可 import 到 `rebuildIndex`/`listNodes`(`Aapms/StoreSpec.hs`) |
| T14 | test_fixtures_parse | 兩個 fixture vault 的全部檔案能被 `parseDocument`+對應 `to*` 成功解析(供其餘測試使用的前提健檢) |
| T15 | (併入上方 T3/T4/T5/T6/T7 各條,`IndexSpec.hs`/`RebuildSpec.hs`/`StaleSpec.hs` 是這些測試實際所在檔案) | - |
| T16 | (併入上方 T8/T9/T10/T11/T12 各條,`QuerySpec.hs`/`NodeSpec.hs` 是這些測試實際所在檔案) | - |
| T17 | cabal test aapms-store exit 0 | 全套件測試通過(75 examples, 0 failures);`Spec.hs` 註冊新 Spec 且不含已刪除的舊 `describe` |

## 待確認假設

- **A1(已由開發者裁決並落地,不再是待確認項,保留記錄供追溯)**:設計階段原判斷契約 E 給定的
  四個索引函式簽名沒有 `TypeRegistry` 的位置,`checkMeta` 型別上叫不動,列為阻塞項。開發者在
  委派實作前已裁決:契約 E 改為 `openVault :: TypeRegistry -> FilePath -> IO (Either StoreError
  (VaultHandle, [IndexIssue]))`,`VaultHandle` 新增 `vhRegistry :: TypeRegistry`(commit
  `5de2727` 改契約、`8ae2c31` 落地,design.md 已同步)。`rebuildIndex`/`refreshStale`/
  `indexFile`/`unindexFile` 簽名因此維持不變(仍只吃 `VaultHandle`(+`FilePath`)),內部直接從
  `vhRegistry vh` 取得 `TypeRegistry` 呼叫 `checkMeta`。本 feature 依此**完整實作**:`IndexIssue`
  加第四個建構子 `MetaWarningsFound FilePath Id [MetaWarning]`,`indexOne` 對文件內每個節點跑
  `checkMeta`,有警告的收進回傳清單(不擋索引)。測試見 T1(`renderIndexIssue`)與 T4(fixture
  用空 `testRegistry`,天生對每個節點觸發 `UnknownNodeType` 警告,是驗證「警告進 `IndexIssue`
  且不擋索引」最直接的素材,不需要額外合成)
- A2(`assets.name` 重複時哪一筆保留名字,委派決策記錄明列的待決點):**採取**——granularity
  是整檔:先被索引到的檔案(`rebuildIndex` 依排序後的路徑逐一處理,因此是路徑字母序最先者)
  保留 `name`,之後任何檔案的 asset 撞到同一個 `name` 時,那個檔案的整個 `indexOne` transaction
  回滾、回報 `DuplicateAssetName`,不寫入部分資料。依據:與 `ParseFailed`/`TreeInvalid` 同一個
  「整檔要嘛全進索引要嘛不進」的失敗模型一致,不需要在 `Asset` 之外再發明「部分成功」的語意。
  **影響**:若編排者預期是「單筆 asset 略過、pack 內其餘 asset 照常索引」的更細粒度,
  `indexOne` 對 `PackDoc` 分支要拆成逐 asset 各自小 transaction,是局部實作調整,不影響
  `IndexIssue`/函式簽名
- A3(`nfIncludeReference` 的排除範圍):**採取**——`False`(預設)時排除 `is_reference` 的
  pack 節點**本身**,以及 `owner` 指向該 pack 的全部 asset。依據:design.md 的舉例(「找 GUI
  框時不該跳出參考資料夾的廟宇照片」)是講 asset,但同一個 pack 節點若被 `listNodes` 直接
  列出也同樣不該出現在預設結果裡,兩者是同一條「reference 資料夾預設不可見」規則的一體兩面。
  **影響**:若編排者只要排除 asset、pack 節點本身仍要可見,WHERE 子句拿掉「排除 pack 本身」
  那一段即可,局部調整不影響簽名
- A4(`nfTags` 多個 tag 的組合語意):**採取** AND(節點必須同時擁有全部指定的 tag)。依據:
  契約 F 沒有明定,`nfTags :: [Text]` 的型別本身不排除 AND 或 OR;沿用 legacy `Query.hs`(單一
  `efTag` 只有一個,沒有先例)與一般標籤過濾的直覺慣例(AND 縮小範圍更符合「篩選」語意)。
  **影響**:若編排者要 OR 語意,WHERE 子句改成單一 `EXISTS (... tag IN (...))`,局部調整
- A5(`lookupNode` 對 `PEnt`/`PAst`/`PPck` 每次呼叫都重新讀檔+解析整份檔案取得 body):
  **採取**,與 legacy `lookupEntity` 同一個成本模型。依據:design.md 明寫「`body` 進 FTS 但不進
  `nodes`:正文只有檔案有」,索引故意不重複存 body,而 F006 不建 FTS 表(#7 的範圍),所以除了
  回讀檔案沒有第二條路。**影響**:若某個大 pack.md(1,693 節)的單一 asset 查詢因此變慢到
  無法接受,#7 落地 FTS 後可以考慮用 FTS 的 content 欄位當快取,但那是效能優化,不影響本
  feature 的正確性
- A6(`files.doc_kind` 的文字編碼):**採取**——store 自訂 `"topic"`/`"level"`/`"pack"`/
  `"license"` 四個字面字串,不使用 `Aapms.Md.Document.DocKind` 的 `Show` 實例(那會印成
  `TopicDoc` 而非小寫)。依據:`DocKind` 沒有匯出的文字轉換函式,design.md 也沒有規定
  `doc_kind` 欄位的確切文字值,這是索引表的內部持久化細節。**影響**:純命名選擇,不影響任何
  對外契約,即使改了也只是 `Row` 模組內部的兩個函式
- A7(`linksTo` 的回傳型別 `[(Meta, Link)]` 需要對每個來源 `hydrateMeta`,比 legacy 的
  `[(Id, Link)]` 貴):**採取**,契約 E 字面就是 `(Meta, Link)`,沒有偏離空間。**影響**:無
  (照契約做,不是待確認的判斷,列在此處只為了提醒不要在實作時誤抄 legacy 的 `Id` 版簽名)
- A8(「`rm index.db` 後 `openVault` + `rebuildIndex` 與刪除前的 `listNodes`/`linksFrom` 結果
  相同(P0 契約測試)」與 `contract/test/Aapms/Contract/IndexEquivalenceSpec.hs` 的關係):
  **採取**——本 feature 的 T7/`test_rm_index_db_rebuild_equivalent` 是**套件內**(`aapms-store`
  測試,直接呼叫 Haskell 函式)版本,不是跑 `contract/` 那份透過 `aapms` CLI 執行檔的黑盒測試。
  依據:`contract/test/Aapms/Contract/IndexEquivalenceSpec.hs` 呼叫的是 `aapms`/`aapms-serve`
  執行檔(`shell` 子系統,P3 才會存在),本 feature 只到 `aapms-store` 這一層,沒有 CLI 可跑。
  **影響**:P3 `shell` 落地後,`contract/` 那份測試會是本 feature 這條驗收標準的**真正**端到端
  驗證;若屆時發現行為對不上,是那個時間點才會發現的問題,不是本 feature 現在能預先擋下的
- A9(`emptyNodeFilter` 這個輔助值不在契約 F 的逐字清單內):**採取**,新增一個最小合理的
  `NodeFilter` 建構捷徑(全部欄位取最寬鬆值,`nfLimit` 給一個大但有限的預設值如 1000,理由是
  `Int` 型別的 `nfLimit` 沒有「無限」的自然值,SQL `LIMIT` 也不接受省略此欄位的語意)。
  依據:`NodeFilter` 全欄必填(不是 `Maybe` 包起來的可選 record),`listNodes`/`childrenOf` 等
  函式的測試與未來 `service` 呼叫端都需要一個起點,比照 F005 對 `IndexIssue`「契約給骨架、
  由後續 feature 依需要擴充」的精神,這是最小夠用的補充,不是新的公開資料結構。**影響**:若
  `/arch-audit feature` 認為這個輔助值超出契約 F 逐字範圍,把它改成非 export 的測試專用工具
  函式(只留在 `Fixtures.hs`),不影響 `NodeFilter` 本身的形狀
- A10(design.md「索引結構」的 `nodes` 表 15 欄裡沒有 `vault` 欄,但 `Meta.metaVault` 是必填
  欄位,`hydrateMeta`/`listNodes`/`lookupNode` 讀回 `Meta` 時要填什麼):**採取**——不逐列存
  `vault`,一律用呼叫端手上那個 `VaultHandle` 自己的身分(`vmId (vhMarker vh)`,零額外 IO,永遠
  可得)回填每一筆 hydrate 出來的 `Meta.metaVault`。依據:design.md 的 `nodeColumnList`/`nodes`
  表逐欄都沒有 `vault`,F006 doc 自己的 Row 段落也白紙黑字寫 15 欄不含它,這不是我自由選的形狀,
  是既有文檔的既定欄位清單;而 md fixture(`Aapms.Md.Fixtures.vaultOf`)已經明寫「frontmatter 的
  `vault:` 只是自由文字標籤,不強制等於 vault 自己的 `vlt-` id」,兩者本來就是不同概念,用
  vault 自己的穩定身分填,兩次 rebuild(含 `rm index.db` 後)永遠一致,P0 契約測試因此不受影響。
  **影響**:若之後某 feature 需要「這個節點檔案 frontmatter 當初宣告的 vault 標籤」(而非它
  實際所在的 vault),要幫 `nodes` 表加回一欄,是純 schema 擴充,不影響本 feature 其餘介面;
  細節見 `Aapms.Store.Row` 模組頂端的 Haddock

## 實作備註

**檔案清單**(新增\/大改):
- `store/src/Aapms/Store/Schema.hs`(擴充:12 表 DDL、`schemaVersion=2`、`IndexIssue` 4 個新建構子)
- `store/src/Aapms/Store/Row.hs`(改寫:節點列轉換,`vault` 欄位處理見待確認假設 A10)
- `store/src/Aapms/Store/Index.hs`(改寫:`indexFile`/`unindexFile`/`rebuildIndex`/`refreshStale`
  + `checkMeta`/`buildTree` 整合)
- `store/src/Aapms/Store/Query.hs`(改寫:`NodeFilter`/`emptyNodeFilter`/`lookupNode` 七支/
  `lookupByName`/`listNodes`/`childrenOf`/`linksFrom`/`linksTo`/`loadLinkGraph`)
- `store/src/Aapms/Store.hs`(門面擴充 re-export `Index`/`Query`)
- `store/aapms-store.cabal`(`exposed-modules` 加 `Index`/`Query`/`Row`;`build-depends` 加
  `aeson`/`aapms-md`;test-suite `other-modules` 加 6 個新 Spec)
- `store/test/Aapms/Store/Fixtures.hs`(擴充:story vault\/asset vault 範例檔案組、
  `withStoryVault`\/`withAssetVault`\/`withIndexedStoryVault`\/`withIndexedAssetVault`、`typeOf`)
- 新增測試:`IndexSpec.hs`(T3/T4/T5/T14)、`RebuildSpec.hs`(T6)、`StaleSpec.hs`(T7)、
  `QuerySpec.hs`(T8/T12)、`NodeSpec.hs`(T9/T10/T11)、`RowSpec.hs`(T2,原表未列所在檔案,
  補一個新檔)
- 改動既有測試:`store/test/Aapms/Store/MarkerSpec.hs`(`indexTables` 的舊斷言「只有
  `meta_info`」改成「12 張表」)、`store/test/Aapms/StoreSpec.hs`(cabal 範圍斷言反過來:F006
  加回的模組改成「應該出現」,F008 範圍的模組仍「不應該出現」;門面測試補 `rebuildIndex`/
  `listNodes`)、`store/test/Spec.hs`(註冊 6 個新 Spec)

**與文檔的偏差**(均在實作自主權範圍內,記錄供追溯,不需要回頭改 design.md):
- `Aapms.Store.Row` 放進 cabal 的 `exposed-modules`(文檔原寫 `other-modules`)——原因是
  `other-modules` 對同一個套件的 test-suite component 也不可見,T2 的白箱測試需要直接
  `import Aapms.Store.Row`。`Aapms.Store` 門面依然不 re-export 它,「不對外承諾介面」的約束靠
  這一點體現,不是靠 Cabal 可見性
- `Row.hs` 的 `hydrateMeta` 簽名是 `VaultId -> Connection -> NodeRow -> IO Meta`(文檔原寫
  `Connection -> NodeRow -> IO Meta`),多一個 `VaultId` 參數——見待確認假設 A10,`nodes` 表不存
  `vault` 欄,hydrate 時要有個來源填 `Meta.metaVault`。`Row` 是內部模組,此簽名改動在實作自主權
  範圍內

**測試結果**:`cabal test aapms-store`——**75 examples, 0 failures**(基線 40 → 75,新增 35
筆測試,含 T2 的 `RowSpec.hs` 2 筆是文檔對照表沒有原列的新增檔案)。`cabal build all`/
`cabal test all` 全綠:`aapms-core` 224/0、`aapms-types` 42/0、`aapms-md` 239/0(三者基線數字
維持不變,未受影響)。

**未實作\/延後項目**:無。TodoList 17 項全數完成,契約卡兩條驗收標準(`checkMeta` 警告與
`buildTree` 錯誤都進 `IndexIssue`)均已落地並有對應測試。
