---
id: entity-graph-core
type: subsystem
title: entity-graph-core
description: 片段圖譜核心:型別、註冊表、Markdown 解析與可重建索引
status: active
created: 2026-08-18
updated: 2026-08-19
parent: system
related-adr: [ADR-001, ADR-002, ADR-003, ADR-004, ADR-005, ADR-008, ADR-009, ADR-010]
---

# 片段圖譜核心 子系統架構

## 定位與範圍

主架構「子系統劃分」的第一節。這個子系統把 **Markdown 檔案變成可查詢的片段圖譜**,並守住
ADR-002 的那條線:**檔案才是真相來源,SQLite 只是可以刪掉重建的衍生物**。

涵蓋 `types/registry/*.toml`、`storyflow-core`、`storyflow-types`、`storyflow-md`、
`storyflow-store` 五個元件。

**明確不做**:任何業務判斷。「這個型別的必填欄位缺了要不要擋」「關聯的目標存不存在」這類
問題屬於 `service-and-interfaces`。本子系統只負責「說出發生了什麼」(`checkEntity` 回警告清單),
不負責「決定怎麼辦」。

`storyflow-core` 是**零 IO** 的純函式層;唯一會碰 IO 的是 `storyflow-types`(讀註冊表)與
`storyflow-store`(讀寫 Vault 與索引)。

## 需求說明

主架構的核心主張是「能被關聯的最小單位是片段,不是文件」。要讓這句話成立,需要四件事:

1. **一組能表達片段的型別**,而且 Entity / Level / Node 共用同一份 `Meta` ——抽象與管理成本
   只付一次,索引表、序列化、CLI 輸出、衝突偵測全部對同一組欄位工作
2. **宣告式的型別註冊表**,讓「新增一個 Entity 型別」不必改程式(垂直切片 1)
3. **Markdown 分節格式的雙向轉換**,而且寫回時未修改的區塊要逐字保留(ADR-010)——作者的
   空行、YAML 註解、縮排風格不能被工具改掉
4. **可重建的索引**,支援中文全文檢索與樂觀鎖

## 內部模組劃分(Internal Modules)

| 元件 | 職責 | IO |
|---|---|---|
| `types/registry/*.toml` | 宣告每個 Entity 型別的名稱、欄位提示、允許的關聯、工作坊階段、`dir`、`owner_type` | 資料,非程式 |
| `storyflow-types` | 讀 TOML、解析、錯誤彙整;`defaultRegistryDir` 以 cabal `data-files` + `STORYFLOW_REGISTRY` 定位 | 唯一 IO 是讀檔 |
| `storyflow-core` | `Meta` / `Entity` / `Link` / `Level` / `Node` / `NodeKind` / `LinkKind` 型別;ID 生成(FNV-1a);樹的合法性驗證(`buildTree`);關聯遍歷;註冊表的純驗證(`checkEntity`);全系統唯一的 aeson 編碼規則 | **零 IO** |
| `storyflow-md` | Markdown 分節格式 ↔ 核心型別的雙向轉換;節層繼承規則;位元組保留的寫回 | 純函式,吃 `Text` 吐型別 |
| `storyflow-store` | Vault 定位(git 式向上搜尋)、原子檔案寫入、SQLite 索引建立與重建、FTS5 trigram、樂觀鎖、過時偵測 | 檔案 + SQLite |

**為什麼 `storyflow-types` 要獨立**:`core` 是零 IO 的硬約束,而讀 TOML 是 IO。把讀檔那幾行
放進 core 就破了那條約束,所以獨立成一個只有讀檔職責的薄套件,解析完交給 core 的純驗證函式。

## 對外契約(Public Interface & DTOs)

唯一的消費者是 `service-and-interfaces` 的 `storyflow-service`。介面分兩組:

**純型別與純函式**(`storyflow-core`)

```haskell
data Meta   -- 十四個欄位,Entity / Level / Node 共用
data Entity = Entity { entMeta :: Meta, entBody :: Text }
data Level  = Level  { lvlMeta :: Meta, lvlRoot :: Id }
data Node   = Node   { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, … }
data NodeTree = NodeTree { ntNode :: Node, ntChildren :: [NodeTree] }

parseId    :: Text -> Either IdError (IdPrefix, Id)
buildTree  :: Level -> [Node] -> Either [TreeError] NodeTree
checkEntity :: TypeRegistry -> Entity -> [EntityWarning]   -- 只回警告,不決定怎麼辦
```

**落地操作**(`storyflow-store`,全部回 `IO (Either StoreError a)`)

```haskell
resolveVaultWith :: FilePath -> Maybe Text -> FilePath -> IO (Either StoreError Vault)
openVaultIndex   :: Vault -> IO (Either StoreError (Connection, [IndexIssue]))
lookupEntity     :: Connection -> Id -> IO (Maybe Entity)
listEntities     :: Connection -> EntityFilter -> IO [Meta]
searchEntities   :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]
createEntityFile :: Connection -> Vault -> TypeRegistry -> NewEntity -> IO (Either StoreError CreateResult)
writeEntityPatch :: Connection -> Vault -> Id -> Int -> Maybe Text -> (MetaOverride -> MetaOverride) -> …
rebuildIndex     :: Connection -> Vault -> IO (Either StoreError [IndexIssue])
```

**錯誤契約**:`StoreError` 的每個建構子都有 `renderStoreError` 的繁中訊息,而且每一則都
**說出下一步該做什麼**。上層(`service`)原樣包成 `StoreFailed` 不重寫。

## 資料流管線(Data Flow Pipeline)

兩條方向相反的管線,共用同一組型別;`storyflow-core` 在兩條裡都只做純計算。

**讀取(檔案 → 可查詢的圖譜)**

```text
Vault 定位(自工作目錄向上搜尋 .storyflow/,或查全域註冊表)
  → 掃描 Vault 的 *.md,files 表比對 mtime / size 找出過時的檔
  → storyflow-md 解析:檔案層 frontmatter + 節層 meta 區塊 → Document
  → 節層繼承規則套用 → Entity / Level / Node
  → storyflow-core 純驗證:buildTree 的樹合法性、checkEntity 的註冊表警告
  → 寫進 SQLite:entities / entity_aliases / entity_tags / links / levels / nodes / entities_fts
  → 查詢出口:lookupEntity / listEntities / searchEntities(兩字元以下改走 LIKE)
```

**寫入(請求 → 檔案 → 索引)**

```text
NewEntity / MetaOverride(來自 service-and-interfaces)
  → 讀回目標檔案,比對 expected revision(樂觀鎖),不符即拒絕
  → storyflow-md 寫回:未修改的區塊逐字保留,只重新序列化被改的 meta 區塊
  → 原子寫入(暫存檔 + rename)
  → 以 file_path 級聯刪除該檔的舊記錄後整檔重建索引
  → 回傳 CreateResult / 新的 revision;索引更新失敗回 IndexUpdateFailed(檔案已落地)
```

順序固定是**先寫檔、再更新索引**;最壞情況是索引落後,而那可以 `index rebuild` 修好。

## 使用的技術

沿用主架構:Haskell GHC 9.14.1 / cabal(ADR-001)。子系統特有的:

- **`direct-sqlite` 開 `+fulltextsearch`**:FTS5 與中文檢索所需的 trigram tokenizer 只存在
  於 FTS5,而 `direct-sqlite` 預設不編入
- **`toml-reader`**:純 Haskell、無 C 相依,讀型別註冊表
- **`HsYAML` + `HsYAML-aeson`**:只用於**解析方向**;寫回的 `meta` 區塊序列化自己寫
  (固定欄位順序),這是 ADR-010 位元組保留的前提
- **`Win32`**(僅 Windows):原子寫入的 rename 覆蓋既有檔案

## 架構圖

```text
                 ┌──────────────────────────┐
   對外入口 ───► │  types/registry/*.toml   │  宣告式型別註冊表
                 └────────────┬─────────────┘
                              │ 讀檔(唯一 IO)
                 ┌────────────┴─────────────┐
                 │  storyflow-types         │  TOML 解析 + 錯誤彙整
                 │  defaultRegistryDir      │  data-files / STORYFLOW_REGISTRY
                 └────────────┬─────────────┘
                              │ TypeRegistry
   ┌──────────────┐  ┌────────┴─────────────┐
   │storyflow-md  │  │  storyflow-core      │
   │              │  │                      │
   │ parse   ─────┼─►│  Meta / Entity /     │
   │ render  ◄────┼──┤  Level / Node        │  零 IO
   │ inherit      │  │  buildTree           │  可完全單元測試
   │ 位元組保留    │  │  checkEntity(只警告)│
   └──────┬───────┘  └────────┬─────────────┘
          │  Document ↔ 型別    │  純型別
          └─────────┬───────────┘
          ┌─────────┴────────────────────────┐
          │  storyflow-store                 │
          │                                  │
          │  Vault 定位(git 式向上搜尋)      │
          │  ┌────────────┐  ┌────────────┐  │
          │  │ 檔案(真相)│─►│ SQLite 索引│  │  files 表比對 mtime/size
          │  │ 原子寫入   │  │ FTS5 trigram│ │  → 過時就重讀該檔
          │  └────────────┘  └────────────┘  │
          │  樂觀鎖:寫入前重讀檔案比對 revision │
          └─────────┬────────────────────────┘
                    │
                    ▼  對外介面:StoreError / Connection / Vault
              storyflow-service(service-and-interfaces)
```

**寫入的固定順序**:先寫檔、再更新索引。反過來的話索引會指向不存在的內容;這個順序下
最壞情況是索引落後,而那可以 `index rebuild` 修好(`IndexUpdateFailed` 的訊息就是這樣寫的)。

## 模組間公開介面與資料結構

模組之間只靠三組東西互相調用,再往下是各模組的實作自主權:

| 呼叫方向 | 介面 |
|---|---|
| `storyflow-types` → `storyflow-core` | 解析完的 `TypeRegistry` 交給 `checkEntity` 等純驗證函式 |
| `storyflow-md` ↔ `storyflow-core` | `Document` ↔ `Entity` / `Level` / `Node`:解析吐核心型別,寫回吃核心型別 |
| `storyflow-store` → `storyflow-md` / `storyflow-core` | 落地層呼叫解析與寫回,並以 `buildTree` / `parseId` 驗證後才進索引 |

資料格式本身:

詳見主架構「資料結構的框架格式」一節(統一 `Meta`、核心關聯詞彙、Markdown 分節格式、
Level 標題階層、SQLite 索引結構)。本子系統**擁有**那些格式的定義與實作,主架構只是描述它們。

三條本子系統獨有的約束:

1. **節層繼承**:`id` / `title` / `summary` / `aliases` / `links` / `revision` **不繼承**,
   `tags` 聯集去重,其餘繼承檔案層。`summary` 不繼承是因為繼承主體的總結等於餵給衝突偵測假資訊
2. **`entities_fts` 不是 contentless**:contentless 的 FTS5 表不支援 `snippet()` 也不支援
   刪除單列,兩者都是必須的。代價是 body 在索引裡多存一份 —— 索引本來就可丟棄,划算
3. **中文二字詞**:trigram 以三字元為索引單位,兩字詞 `MATCH` 一定不命中,所以
   `searchEntities` 對兩字元以下的查詢改走 `LIKE` 掃描

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `base` / `text` / `bytestring` / `containers` | 基礎 |
| `aeson` | `meta` 區塊與索引序列化的唯一編碼規則 |
| `sqlite-simple` + `direct-sqlite` (`+fulltextsearch`) | SQLite 與 FTS5 trigram |
| `toml-reader` | 型別註冊表與 Vault 設定 |
| `HsYAML` + `HsYAML-aeson` | frontmatter 與 `meta` 區塊的解析(只有解析方向) |
| `directory` / `filepath` / `time` | 檔案落地、mtime/size 過時偵測 |
| `Win32`(僅 Windows) | 原子寫入的 rename |
| `hspec` / `temporary` | 測試與臨時 Vault |

## 開發階段

對應主架構的 **P0 與 P1**,已全部完成。內部里程碑就是下面五個 feature。

## 功能規劃

### 階段一:P0 骨架

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 1 | project-skeleton | cabal 多套件骨架、`-Wall` 設定、hspec 骨架、FTS5 smoke test | - | F001 |

### 階段二:P1 核心與落地

| # | feature | 一句話說明 | 依賴 | doc |
|---|---------|-----------|------|------|
| 2 | core-types-and-registry | 統一 `Meta` 與五個核心型別的純函式層與型別註冊表 | #1 | F002 |
| 3 | markdown-section-format | Markdown 分節格式與核心型別的雙向解析與寫回 | #2 | F003 |
| 4 | store-vault-io-and-index | Vault 原子寫入與 SQLite 可重建索引及 FTS5 檢索 | #2, #3 | F004 |
| 5 | store-write-operations | 補齊建檔、增節、改寫、刪除與 Level 節點的落地寫入 | #4 | F005 |

小結:共 **5 個 features、2 個階段**,全部已完成(`F001` ~ `F005` 皆 done)。
子系統可交付:`index rebuild` 後與重建前等價、round-trip 測試不失真,兩條驗收標準都通過。

## Feature 契約卡

功能規劃的每一列一張卡。五個 feature 都已實作完成,卡片依既有實作回填,作用是讓「這個
feature 的邊界在哪」不必回頭讀程式碼——後續的優化與修復也以卡上的邊界為準。

### project-skeleton

- **階段**:階段一(P0 骨架)
- **負責模組**:五個元件的 cabal 骨架(`storyflow-core` / `storyflow-types` / `storyflow-md` /
  `storyflow-store` 的套件定義與測試進入點),不含任何模組內容
- **實作的 Level 2 介面**:無新增。本項不產出任何「對外契約」或「模組間公開介面」的條目,
  只建立它們之後要住進去的套件與測試骨架
- **資料流管線段落**:不走管線。它是建置期的前置條件
- **驗收標準**:`cabal build all` 與 `cabal test all` 綠燈;FTS5 trigram smoke test 通過
  (證明 `direct-sqlite` 的 `+fulltextsearch` 生效);`scripts/check.ps1` / `check.sh` exit 0
- **明確不做**:不寫任何業務邏輯與型別定義;不建 P4/P5 才需要的套件

### core-types-and-registry

- **階段**:階段二(P1 核心與落地)
- **負責模組**:`storyflow-core`(零 IO)、`storyflow-types`(唯一 IO 是讀 TOML)
- **實作的 Level 2 介面**:「對外契約」的純型別與純函式那一組——`Meta`、`Entity`、`Level`、
  `Node`、`NodeTree`、`parseId`、`buildTree`、`checkEntity`;「模組間公開介面」的
  `storyflow-types` → `storyflow-core`(`TypeRegistry` 交給純驗證)
- **資料流管線段落**:讀取管線的「`storyflow-core` 純驗證」一段,以及註冊表載入(管線的前置)
- **驗收標準**:Entity / Level / Node 共用同一份 `Meta`;ID 以 FNV-1a 生成且碰撞時由呼叫端
  以 salt 遞增重試;`buildTree` 拒絕成環、跳級與多重父節點;`checkEntity` 只回警告清單、
  不做任何決定;註冊表載入失敗讓程序失敗,**不退回空註冊表**
- **明確不做**:不碰檔案系統(`storyflow-types` 讀註冊表除外);不解析 Markdown;
  不決定「警告要不要擋下操作」——那是 `service-and-interfaces`

### markdown-section-format

- **階段**:階段二(P1 核心與落地)
- **負責模組**:`storyflow-md`(純函式,吃 `Text` 吐型別)
- **實作的 Level 2 介面**:「模組間公開介面」的 `storyflow-md` ↔ `storyflow-core`
  (`Document` ↔ `Entity` / `Level` / `Node`,含節層繼承與寫回)
- **資料流管線段落**:讀取管線的「解析 → 節層繼承」一段,與寫入管線的「位元組保留寫回」一段
- **驗收標準**:round-trip(解析 → 寫回 → 再解析)不失真;節層繼承精確照
  `id`/`title`/`summary`/`aliases`/`links`/`revision` 不繼承、`tags` 聯集去重的規則;
  未修改的區塊逐字保留原始位元組(ADR-010);Level 檔以標題階層推導 `parent` 與 `order`
- **明確不做**:不碰檔案系統與索引;不驗證關聯目標是否存在(那需要圖,屬於 store 與 service)

### store-vault-io-and-index

- **階段**:階段二(P1 核心與落地)
- **負責模組**:`storyflow-store`
- **實作的 Level 2 介面**:「對外契約」的落地操作組——`resolveVaultWith`、`openVaultIndex`、
  `lookupEntity`、`listEntities`、`searchEntities`、`writeEntityPatch`、`rebuildIndex`,
  以及 `StoreError` / `renderStoreError` 的錯誤契約
- **資料流管線段落**:讀取管線的全段(Vault 定位 → 過時偵測 → 索引 → 查詢出口),
  與寫入管線的「原子寫入 → 更新索引」
- **驗收標準**:`index rebuild` 後與重建前等價;`files` 表以 mtime / size 偵測外部改動並重讀;
  兩字元以下的查詢改走 `LIKE`(trigram 一定不命中);樂觀鎖比對 `revision`,不符即拒絕;
  每個 `StoreError` 的繁中訊息都說出下一步
- **明確不做**:不做業務判斷;不決定警告要不要擋;不定義 CLI / REST 的任何形狀

### store-write-operations

- **階段**:階段二(P1 核心與落地)
- **負責模組**:`storyflow-store` 的寫入面(建檔、增節、改寫、刪除、Level 節點)
- **實作的 Level 2 介面**:「對外契約」落地操作組的寫入半邊——`createEntityFile` 與
  `writeEntityPatch` 的完整能力,加上節與 Node 的新增/刪除
- **資料流管線段落**:寫入管線的全段
- **驗收標準**:能從零建出主題檔與節(依註冊表的 `dir` 決定落點);刪除後索引無殘留;
  Level 節點的新增依標題階層寫回且 `order` 自動重算;所有寫入都經原子寫入與樂觀鎖
- **明確不做**:不新增查詢介面;不碰 `service`;不處理跨 Vault 寫入
