---
id: subarch-0001
type: subarch
title: entity-graph-core
description: 片段圖譜核心:型別、註冊表、Markdown 解析與可重建索引
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0001, adr-0002, adr-0003, adr-0004, adr-0005, adr-0008, adr-0009, adr-0010]
---

# 片段圖譜核心 子系統架構

## 定位與範圍

主架構「子系統劃分」的第一節。這個子系統把 **Markdown 檔案變成可查詢的片段圖譜**,並守住
ADR-0002 的那條線:**檔案才是真相來源,SQLite 只是可以刪掉重建的衍生物**。

涵蓋 `types/registry/*.toml`、`storyflow-core`、`storyflow-types`、`storyflow-md`、
`storyflow-store` 五個元件。

**明確不做**:任何業務判斷。「這個型別的必填欄位缺了要不要擋」「關聯的目標存不存在」這類
問題屬於 `subarch-0002`。本子系統只負責「說出發生了什麼」(`checkEntity` 回警告清單),
不負責「決定怎麼辦」。

`storyflow-core` 是**零 IO** 的純函式層;唯一會碰 IO 的是 `storyflow-types`(讀註冊表)與
`storyflow-store`(讀寫 Vault 與索引)。

## 需求說明

主架構的核心主張是「能被關聯的最小單位是片段,不是文件」。要讓這句話成立,需要四件事:

1. **一組能表達片段的型別**,而且 Entity / Level / Node 共用同一份 `Meta` ——抽象與管理成本
   只付一次,索引表、序列化、CLI 輸出、衝突偵測全部對同一組欄位工作
2. **宣告式的型別註冊表**,讓「新增一個 Entity 型別」不必改程式(垂直切片 1)
3. **Markdown 分節格式的雙向轉換**,而且寫回時未修改的區塊要逐字保留(ADR-0010)——作者的
   空行、YAML 註解、縮排風格不能被工具改掉
4. **可重建的索引**,支援中文全文檢索與樂觀鎖

## 架構規劃

| 元件 | 職責 | IO |
|---|---|---|
| `types/registry/*.toml` | 宣告每個 Entity 型別的名稱、欄位提示、允許的關聯、工作坊階段、`dir`、`owner_type` | 資料,非程式 |
| `storyflow-types` | 讀 TOML、解析、錯誤彙整;`defaultRegistryDir` 以 cabal `data-files` + `STORYFLOW_REGISTRY` 定位 | 唯一 IO 是讀檔 |
| `storyflow-core` | `Meta` / `Entity` / `Link` / `Level` / `Node` / `NodeKind` / `LinkKind` 型別;ID 生成(FNV-1a);樹的合法性驗證(`buildTree`);關聯遍歷;註冊表的純驗證(`checkEntity`);全系統唯一的 aeson 編碼規則 | **零 IO** |
| `storyflow-md` | Markdown 分節格式 ↔ 核心型別的雙向轉換;節層繼承規則;位元組保留的寫回 | 純函式,吃 `Text` 吐型別 |
| `storyflow-store` | Vault 定位(git 式向上搜尋)、原子檔案寫入、SQLite 索引建立與重建、FTS5 trigram、樂觀鎖、過時偵測 | 檔案 + SQLite |

**為什麼 `storyflow-types` 要獨立**:`core` 是零 IO 的硬約束,而讀 TOML 是 IO。把讀檔那幾行
放進 core 就破了那條約束,所以獨立成一個只有讀檔職責的薄套件,解析完交給 core 的純驗證函式。

## 對外介面

唯一的消費者是 `subarch-0002` 的 `storyflow-service`。介面分兩組:

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

## 使用的技術

沿用主架構:Haskell GHC 9.14.1 / cabal(ADR-0001)。子系統特有的:

- **`direct-sqlite` 開 `+fulltextsearch`**:FTS5 與中文檢索所需的 trigram tokenizer 只存在
  於 FTS5,而 `direct-sqlite` 預設不編入
- **`toml-reader`**:純 Haskell、無 C 相依,讀型別註冊表
- **`HsYAML` + `HsYAML-aeson`**:只用於**解析方向**;寫回的 `meta` 區塊序列化自己寫
  (固定欄位順序),這是 ADR-0010 位元組保留的前提
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
              storyflow-service(subarch-0002)
```

**寫入的固定順序**:先寫檔、再更新索引。反過來的話索引會指向不存在的內容;這個順序下
最壞情況是索引落後,而那可以 `index rebuild` 修好(`IndexUpdateFailed` 的訊息就是這樣寫的)。

## 資料結構的框架格式

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

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | project-skeleton | cabal 多套件骨架、`-Wall` 設定、hspec 骨架、FTS5 smoke test | - | func-0001 |

### 階段二:P1 核心與落地

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 2 | core-types-and-registry | 統一 `Meta` 與五個核心型別的純函式層與型別註冊表 | #1 | func-0002 |
| 3 | markdown-section-format | Markdown 分節格式與核心型別的雙向解析與寫回 | #2 | func-0003 |
| 4 | store-vault-io-and-index | Vault 原子寫入與 SQLite 可重建索引及 FTS5 檢索 | #2, #3 | func-0004 |
| 5 | store-write-operations | 補齊建檔、增節、改寫、刪除與 Level 節點的落地寫入 | #4 | func-0005 |

小結:共 **5 個 features、2 個階段**,全部已完成(`func-0001` ~ `func-0005` 皆 done)。
子系統可交付:`index rebuild` 後與重建前等價、round-trip 測試不失真,兩條驗收標準都通過。
