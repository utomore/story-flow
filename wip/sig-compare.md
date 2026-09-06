# 簽名對帳:37 條「對不上程式碼」逐條核對

來源:`wip/migrate-ledger.md` 的 `## 簽名對不上程式碼`(1 條「找不到」+ 36 條「不一致」)。
掃描範圍:`<pkg>/src/**/*.hs`,`legacy/`、`dist-newstyle/`、`.knot/` 已排除。
**不在 `cabal.project` 的凍結套件**:`cli/`、`api/`、`server/`、`mcp/`、`conflict/`、`llm/`、`workshop/`。

## 總結論(先看這條)

**36 條「不一致」裡沒有一條是真的簽名型別不同。** 逐條核對後,型別本體 100% 相同,
差異全部來自帳本掃描器的逐字比對把文檔那一行的**尾隨 `--` 註解**與**對齊空白**也算進去了。
可以驗證這個判準:F005 的 `## 新增的介面` 區塊裡,**帶尾隨註解的 10 條全部被標成不一致,
沒有註解的 `closeIndex :: Connection -> IO ()` 與 `currentVersion :: Connection -> IO (Maybe Int)`
(後者有對齊空白但沒註解)一條都沒被標**。workspace/F001 的骨架區塊每一行都帶 `-- :NN` 行號註解,
所以那 17 條全中。

真正需要人判的只有這幾件事(細節見下方註記):

1. `desegmentCjk` —— 唯一的「找不到」,而且文檔自己記載了撤除裁決,**不是缺口**。
2. `indexTables` / `schemaVersion` 的**值**在 F005 → F006 → 程式碼之間確實漂移(1 → 2 → 3 項;
   1 → 12 → 15 張表),但**簽名**沒變。F006 註解寫「擴充到 12 項」,程式碼是 15 項(F007 又加了三張 FTS 表)。
3. `commit` 住在 `Aapms.Store.Edit`,而該模組在 `store/aapms-store.cabal` 是 **`other-modules`**,
   不是 `exposed-modules`;`Aapms.Store` 門面也不 re-export 它。函式在模組自己的匯出清單裡,
   但**套件外拿不到**。這正是帳本 Law 草稿 LAW-1/LAW-2 在講的事。
4. `vaultCheck` / `listTypes` / `configPath` 三個撞名:帳本點到的模組是**錯的那一個**。

## 對帳表

| # | 文檔:函式 | 文檔簽名(逐字) | 文檔說的模組 | 程式碼簽名(逐字,多行已併成一行) | 實際模組:行 | 在匯出清單 | 診斷 |
|---|---|---|---|---|---|---|---|
| 1 | `.design/subsystems/graph-core/features/F007-store-fts-dual-index.md`:`desegmentCjk` | `desegmentCjk :: Text -> Text` | `Aapms.Store.Tokenize`(僅在「已移除」的敘述中) | (無) | (無) | — | **文檔自記已撤除,程式碼正確**。見註 1 |
| 2 | `.design/subsystems/graph-core/features/F002-registry-family-and-naming.md`:`renderFamily` | `renderFamily :: Family -> Text        -- "entity" / "asset",穩定小寫(ADR-008 風格)` | `aapms-core`(`Aapms.Core.Registry`) | `renderFamily :: Family -> Text` | `core/src/Aapms/Core/Registry.hs:63` | 是 | 型別相同;差異只是文檔的尾隨註解 |
| 3 | 同上:`reservedTypeKeys` | `reservedTypeKeys :: [TypeKey]         -- [level, asset-pack, asset-license]` | `aapms-core`(`Aapms.Core.Registry`) | `reservedTypeKeys :: [TypeKey]` | `core/src/Aapms/Core/Registry.hs:117` | 是 | 型別相同;差異只是尾隨註解。見註 2(同檔還有一條 `[Text]` 的舊簽名) |
| 4 | 同上:`maxLogicalNameLength` | `maxLogicalNameLength :: Int   -- 64` | `aapms-core`(`Aapms.Core.Naming`,新模組) | `maxLogicalNameLength :: Int` | `core/src/Aapms/Core/Naming.hs:162` | 是(`Naming.hs:40`) | 型別相同;差異只是尾隨註解 |
| 5 | `.design/subsystems/graph-core/features/F005-store-vault-handle.md`:`renderVaultKind` | `renderVaultKind :: VaultKind -> Text          -- AssetVault -> "asset", StoryVault -> "story"` | `Aapms.Store.Schema` | `renderVaultKind :: VaultKind -> Text` | `store/src/Aapms/Store/Schema.hs:66` | 是 | 型別相同;差異只是尾隨註解 |
| 6 | 同上:`parseVaultKind` | `parseVaultKind  :: Text -> Maybe VaultKind    -- 只認 "asset"/"story",其餘 Nothing` | `Aapms.Store.Schema` | `parseVaultKind :: Text -> Maybe VaultKind` | `store/src/Aapms/Store/Schema.hs:71` | 是 | 型別相同;差異是對齊空白 + 尾隨註解 |
| 7 | 同上:`createSchema` | `createSchema   :: Connection -> IO ()   -- 目前只建 meta_info 一張表` | `Aapms.Store.Schema` | `createSchema :: Connection -> IO ()` | `store/src/Aapms/Store/Schema.hs:246` | 是 | 型別相同;註解已過時(現在建 15 張表,見註 3) |
| 8 | 同上:`resetSchema` | `resetSchema    :: Connection -> IO ()   -- DROP IF EXISTS 全部 indexTables 後 createSchema` | `Aapms.Store.Schema` | `resetSchema :: Connection -> IO ()` | `store/src/Aapms/Store/Schema.hs:240` | 是 | 型別相同;註解仍成立(程式碼以 `reverse indexTables` DROP) |
| 9 | 同上:`indexTables` | `indexTables    :: [Text]                -- ["meta_info"];#6 加業務表時擴充這份清單,不是另開一份` | `Aapms.Store.Schema` | `indexTables :: [Text]` | `store/src/Aapms/Store/Schema.hs:144` | 是 | 型別相同;**值**已由 F006/F007 擴充到 15 張表。見註 3 |
| 10 | 同上:`setVaultInfo` | `setVaultInfo :: Connection -> Text -> Text -> Text -> IO ()   -- vault_id, vault_kind, vault_name` | `Aapms.Store.Schema` | `setVaultInfo :: Connection -> Text -> Text -> Text -> IO ()` | `store/src/Aapms/Store/Schema.hs:256` | 是 | 逐字相同;差異只是尾隨註解 |
| 11 | 同上:`markerDir` | `markerDir   :: FilePath -> FilePath   -- root </> ".aapms"` | `Aapms.Store.Marker` | `markerDir :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:48` | 是 | 型別相同;差異是對齊空白 + 尾隨註解 |
| 12 | 同上:`configPath` | `configPath  :: FilePath -> FilePath   -- markerDir root </> "config.toml"` | `Aapms.Store.Marker` | `configPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:51` | 是 | 型別相同。**同名的另一個在 `Aapms.Workspace.Location`,見註 4** |
| 13 | 同上:`indexDbPath` | `indexDbPath :: FilePath -> FilePath   -- markerDir root </> "index.db"` | `Aapms.Store.Marker` | `indexDbPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:54` | 是 | 型別相同;差異只是尾隨註解 |
| 14 | 同上:`trySqlite` | `trySqlite :: IO a -> IO (Either StoreError a)   -- 簽名不變,沿用舊實作` | `Aapms.Store.Error` | `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/Aapms/Store/Error.hs:207` | 是 | 逐字相同;差異只是尾隨註解 |
| 15 | `.design/subsystems/graph-core/features/F006-store-unified-index.md`:`renderIndexIssue` | `renderIndexIssue :: IndexIssue -> Text   -- 補四個新 case` | `Aapms.Store.Schema`(擴充) | `renderIndexIssue :: IndexIssue -> Text` | `store/src/Aapms/Store/Schema.hs:106` | 是 | 型別相同;程式碼確實是 5 個 case(F005 的 1 + F006 的 4) |
| 16 | 同上:`indexTables` | `indexTables :: [Text]   -- 擴充到 12 項:meta_info, files, nodes, node_aliases, node_tags, links,` `                        -- assets, packs, licenses, levels, tree_nodes, tree_node_entities` | `Aapms.Store.Schema`(擴充) | `indexTables :: [Text]` | `store/src/Aapms/Store/Schema.hs:144` | 是 | 型別相同;**F006 的「12 項」註解已被 F007 的三張 FTS 表追過,現為 15 項**。見註 3 |
| 17 | 同上:`emptyNodeFilter` | `emptyNodeFilter :: NodeFilter    -- 全部欄位取最寬鬆的預設值(nfLimit 需要一個有限預設值,` | `Aapms.Store.Query`(新模組) | `emptyNodeFilter :: NodeFilter` | `store/src/Aapms/Store/Query.hs:119` | 是 | 型別相同;差異只是跨行的尾隨註解 |
| 18 | `.design/subsystems/graph-core/features/F008-store-write-operations.md`:`commit` | `commit :: VaultHandle -> FilePath -> Document -> Id -> Revision -> IO (Either StoreError WriteResult)` | `store/src/Aapms/Store/Edit.hs:211` | `commit :: VaultHandle -> FilePath -> Document -> Id -> Revision -> IO (Either StoreError WriteResult)` | `store/src/Aapms/Store/Edit.hs:211`(宣告跨 211–219 行) | 模組匯出清單:是(`Edit.hs:53`)。**套件層:否 —— `Aapms.Store.Edit` 是 `other-modules`** | 逐字相同;唯一的落差是模組可見性。見註 5 |
| 19 | `.design/subsystems/service/features/F002-workspace-facade.md`:`vaultCheck` | `vaultCheck :: ServiceM [ScopeIssue]` | `service/src/Aapms/Service/Machine.hs:199` | `vaultCheck :: ServiceM [ScopeIssue]` | `service/src/Aapms/Service/Machine.hs:315` | 是 | **帳本點錯模組(撞名)**;真正的那個逐字相同。見註 6 |
| 20 | 同上:`listTypes` | `listTypes :: ServiceM [TypeDecl]` | `service/src/Aapms/Service/Machine.hs:224` | `listTypes :: ServiceM [TypeDecl]` | `service/src/Aapms/Service/Machine.hs:354` | 是 | **帳本點錯模組(撞名)**;文檔 SELF-2 已預告這次撞名。見註 7 |
| 21 | `.design/subsystems/workspace/features/F001-hub-registry.md`:`mkHub` | `mkHub :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text -> Hub  -- :109` | `workspace/src/Aapms/Workspace/Types.hs` | `mkHub :: [VaultEntry] -> [ProjectEntry] -> Maybe LlmSection -> ToolsConfig -> Text -> Hub` | `workspace/src/Aapms/Workspace/Types.hs:110`(宣告跨 110–116 行) | 是(`Types.hs:22`) | 逐字相同;差異是文檔的 `-- :NN` 行號註解 + 程式碼是多行寫法 |
| 22 | 同上:`hubSourceText` | `hubSourceText :: Hub -> Text                                                    -- :100` | `workspace/src/Aapms/Workspace/Types.hs` | `hubSourceText :: Text`(record 欄位,選取器型別為 `Hub -> Text`) | `workspace/src/Aapms/Workspace/Types.hs:101` | 是(`Types.hs:23`);**Hub.hs 不轉出** | 同形:文檔寫選取器型別,程式碼是 record 欄位宣告。見註 8 |
| 23 | 同上:`hubVaults` | `hubVaults   :: Hub -> [VaultEntry]                                              -- :91` | `workspace/src/Aapms/Workspace/Types.hs` | `hubVaults :: [VaultEntry]`(record 欄位,選取器型別為 `Hub -> [VaultEntry]`) | `workspace/src/Aapms/Workspace/Types.hs:92` | 是(`Types.hs:30`),且 `Hub.hs:19` 轉出 | 同註 8 |
| 24 | 同上:`hubProjects` | `hubProjects :: Hub -> [ProjectEntry]                                            -- :93` | `workspace/src/Aapms/Workspace/Types.hs` | `hubProjects :: [ProjectEntry]` | `workspace/src/Aapms/Workspace/Types.hs:94` | 是(`Types.hs:31`),且 `Hub.hs:20` 轉出 | 同註 8 |
| 25 | 同上:`hubLlm` | `hubLlm      :: Hub -> Maybe LlmSection                                          -- :95` | `workspace/src/Aapms/Workspace/Types.hs` | `hubLlm :: Maybe LlmSection` | `workspace/src/Aapms/Workspace/Types.hs:96` | 是(`Types.hs:32`),且 `Hub.hs:21` 轉出 | 同註 8 |
| 26 | 同上:`hubTools` | `hubTools    :: Hub -> ToolsConfig                                               -- :98` | `workspace/src/Aapms/Workspace/Types.hs` | `hubTools :: ToolsConfig` | `workspace/src/Aapms/Workspace/Types.hs:99` | 是(`Types.hs:33`),且 `Hub.hs:22` 轉出 | 同註 8 |
| 27 | 同上:`renderWorkspaceError` | `renderWorkspaceError :: WorkspaceError -> Text                                  -- :330` | `workspace/src/Aapms/Workspace/Types.hs` | `renderWorkspaceError :: WorkspaceError -> Text` | `workspace/src/Aapms/Workspace/Types.hs:352` | 是(`Types.hs:57`) | 逐字相同;差異只是行號註解與對齊空白 |
| 28 | 同上:`hubLocation` | `hubLocation    :: IO HubLocation                     -- :28` | `workspace/src/Aapms/Workspace/Location.hs` | `hubLocation :: IO HubLocation` | `workspace/src/Aapms/Workspace/Location.hs:33` | 是 | 逐字相同;差異只是對齊空白 + 行號註解 |
| 29 | 同上:`configPath` | `configPath     :: HubLocation -> FilePath            -- :35   <hlPath>/config.toml` | `workspace/src/Aapms/Workspace/Location.hs` | `configPath :: HubLocation -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:48` | 是 | **帳本點錯模組(撞名)**;文檔第 841 行自己就寫明兩者同名不同義。見註 4 |
| 30 | 同上:`thumbCacheDir` | `thumbCacheDir  :: HubLocation -> FilePath            -- :40   <hlPath>/cache/thumbs` | `workspace/src/Aapms/Workspace/Location.hs` | `thumbCacheDir :: HubLocation -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:53` | 是 | 逐字相同;差異只是對齊空白 + 註解 |
| 31 | 同上:`thumbCachePath` | `thumbCachePath :: HubLocation -> Sha256 -> FilePath  -- :47   <thumbCacheDir>/<take 2 h>/<h>.png` | `workspace/src/Aapms/Workspace/Location.hs` | `thumbCachePath :: HubLocation -> Sha256 -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:60` | 是 | 逐字相同;差異只是註解 |
| 32 | 同上:`loadHub` | `loadHub :: HubLocation -> IO (Either WorkspaceError Hub)          -- :53` | `workspace/src/Aapms/Workspace/Hub.hs` | `loadHub :: HubLocation -> IO (Either WorkspaceError Hub)` | `workspace/src/Aapms/Workspace/Hub.hs:81` | 是(`Hub.hs:15`) | 逐字相同;差異只是註解 |
| 33 | 同上:`saveHub` | `saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())    -- :62` | `workspace/src/Aapms/Workspace/Hub.hs` | `saveHub :: HubLocation -> Hub -> IO (Either WorkspaceError ())` | `workspace/src/Aapms/Workspace/Hub.hs:225` | 是(`Hub.hs:16`) | 逐字相同;差異只是註解 |
| 34 | 同上:`upsertVault` | `upsertVault   :: VaultEntry   -> Hub -> Hub                       -- :67` | `workspace/src/Aapms/Workspace/Hub.hs` | `upsertVault :: VaultEntry -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:489` | 是(`Hub.hs:25`) | 型別相同;差異只是對齊空白 + 註解 |
| 35 | 同上:`removeVault` | `removeVault   :: VaultId      -> Hub -> Hub                       -- :71` | `workspace/src/Aapms/Workspace/Hub.hs` | `removeVault :: VaultId -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:499` | 是(`Hub.hs:26`) | 型別相同;差異只是對齊空白 + 註解 |
| 36 | 同上:`upsertProject` | `upsertProject :: ProjectEntry -> Hub -> Hub                       -- :76` | `workspace/src/Aapms/Workspace/Hub.hs` | `upsertProject :: ProjectEntry -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:510` | 是(`Hub.hs:27`) | 型別相同;差異只是對齊空白 + 註解 |
| 37 | 同上:`removeProject` | `removeProject :: Id           -> Hub -> Hub                       -- :80` | `workspace/src/Aapms/Workspace/Hub.hs` | `removeProject :: Id -> Hub -> Hub` | `workspace/src/Aapms/Workspace/Hub.hs:520` | 是(`Hub.hs:28`) | 型別相同;差異只是對齊空白 + 註解 |

## 逐條註記

### 註 1 —— `desegmentCjk`(第 1 列):文檔自己記了撤除裁決,不是缺口

`F007-store-fts-dual-index.md:107-109` 的修訂記錄逐字如下:

> **2026-08-24 修訂(spec-gaps GAP-4 / GAP-5 的裁決)**:`desegmentCjk :: Text -> Text` 已從介面**移除**。
> 它唯一的消費者是 `search` 的 CJK 片段還原路徑,而該路徑依 ASM-3 改走 `fts_tri` 的原文之後,這個函式
> 不再有任何呼叫端;連帶撤掉 LAW-4(見「Laws」)。介面因此是 20 條,不是 21 條。

同檔 `:291` 的骨架表也註明「(2026-08-24 修訂:`desegmentCjk` 已移除,見 ASM-3 / LAW-4)」,
`:125-130` 的 LAW-4 以刪除線保留並附撤銷理由,`:376` 的 GAP-4/GAP-5 裁決逐字寫
「**`desegmentCjk` 整個撤除**(已從 `Tokenize.hs` 的介面與骨架移除),**`LAW-4` 撤銷**」。

程式碼側唯一提到它的地方是 `store/src/Aapms/Store/Tokenize.hs:190` 的 Haddock 註解
(說明「需要給人看的連續文字時,一律從 `fts_tri` 的原文取」),沒有任何宣告,
`Aapms.Store.Tokenize` 的匯出清單也沒有它。**文檔與程式碼一致;帳本的掃描器只是抓到了修訂記錄裡的那行簽名。**

### 註 2 —— `reservedTypeKeys`(第 3 列):同一份文檔裡有兩條簽名

`F002-registry-family-and-naming.md` 的「使用到的既有介面」節(`:108`)寫的是**改寫前**的舊簽名:

```
- `reservedTypeKeys :: [Text]` `= ["level"]` —— `core/src/Aapms/Core/Registry.hs:81-82`
```

而「新增的介面」節(`:452`)寫的才是本 feature 交付的版本:`reservedTypeKeys :: [TypeKey]`。
`:388` 另有一行「`reservedTypeKeys = ["level", "asset-pack", "asset-license"]`(原本只有 `"level"`)」。
程式碼 `Registry.hs:117-118` 是後者:

```haskell
reservedTypeKeys :: [TypeKey]
reservedTypeKeys = [TypeKey "level", TypeKey "asset-pack", TypeKey "asset-license"]
```

**要抄的是 `[TypeKey]` 那一條。** `maxLogicalNameLength`(第 4 列)同樣有兩處:
`:163` 是 legacy 出處的引用(`legacy/assetdb/core/src/AssetDB/Naming.hs:125-126`(不變)),
`:491` 是新介面;兩處型別相同,不衝突。

### 註 3 —— `indexTables` / `schemaVersion`:唯一真的漂移,但漂的是**值**不是簽名

| 來源 | `schemaVersion` | `indexTables` 的項數 |
|---|---|---|
| F005 文檔 | `schemaVersion = 1` | `["meta_info"]`,1 項 |
| F006 文檔 | `schemaVersion = 2` | 註解寫「擴充到 12 項」 |
| 程式碼 `Schema.hs` | `schemaVersion = 3`(`:80`) | **15 項**(`:144-160`) |

程式碼的 15 項:`meta_info`, `files`, `nodes`, `node_aliases`, `node_tags`, `links`,
`assets`, `packs`, `licenses`, `levels`, `tree_nodes`, `tree_node_entities`, `fts_tri`, `fts_cjk`, `fts_map`。

多出來的三張是 F007 加的 FTS 表。`Schema.hs` 的模組 Haddock(`:7-14`)自己說明了這條沿革:
「graph-core/F006 把業務表(`nodes` 等 11 張)接上,`schemaVersion` 因此從 F005 的 1 改成 2 …
graph-core/F007 再加三張 FTS 相關的表(`fts_tri` / `fts_cjk` / `fts_map`)與一個觸發器,
`schemaVersion` 因此 2 → 3」。

F005/F006 兩份文檔都預告了這種擴充是預期行為(F005:「#6 加業務表時擴充這份清單,不是另開一份」),
所以這是 **doc stale (code newer),而且是文檔自己授權的漸進擴充**,不是違例。
但 F006 的「12 項」註解與 F007 的實際結果對不上,抄簽名時**不要連註解一起抄**。

`createSchema` 的 F005 註解「目前只建 meta_info 一張表」同理已過時。

### 註 4 —— `configPath` 撞名(第 12、29 列)

程式碼有兩個:

| 模組 | 簽名 | 位置 | 語意 |
|---|---|---|---|
| `Aapms.Store.Marker` | `configPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:51` | **vault 的** `<root>/.aapms/config.toml` |
| `Aapms.Workspace.Location` | `configPath :: HubLocation -> FilePath` | `workspace/src/Aapms/Workspace/Location.hs:48` | **中樞的** `<hlPath>/config.toml` |

兩者都在各自模組的匯出清單裡,兩者都在 `cabal.project` 內的套件。

帳本第 117 行把 workspace/F001 的 `configPath` 標成「程式碼在 Aapms.Store.Marker」——**點錯了**。
F001 文檔在「使用到的既有介面」表(`:358`)確實引用了 Store.Marker 的那一個,但只是為了劃清界線,
原文逐字:

> `configPath :: FilePath -> FilePath`(`markerDir root </> "config.toml"`)…… 同上——**vault 的** `config.toml`;
> `Aapms.Workspace.Location.configPath` 是**中樞的**,兩者同名,同時 import 要 qualified

同檔 `:841` 的「已知風險」也寫「`Aapms.Workspace.Location.configPath` 與 `Aapms.Store.Marker.configPath` 同名不同義」。
`Hub.hs:52` 的 `import Aapms.Workspace.Location (configPath)` 確認用的是中樞那一個。

### 註 5 —— `commit`(第 18 列):簽名一致,但模組不對外

程式碼 `store/src/Aapms/Store/Edit.hs:211-219` 的宣告是多行帶 Haddock 的寫法:

```haskell
commit
  :: VaultHandle
  -> FilePath
  -- ^ Vault 相對路徑
  -> Document
  -> Id
  -- ^ 這次寫入的主體 id(回傳用)
  -> Revision
  -- ^ 寫入後的新 revision
  -> IO (Either StoreError WriteResult)
```

併成一行後與文檔 `F008-store-write-operations.md:165` 的簽名**逐字相同**,連文檔標的行號 `:211` 都對得上。

`commit` 在 `Aapms.Store.Edit` 自己的匯出清單裡(`Edit.hs:53`),但:

- `store/aapms-store.cabal:37-41` 把 `Aapms.Store.Edit` 放在 **`other-modules`**(`exposed-modules` 有 11 個模組,不含它)。
- `Aapms.Store` 門面(`store/src/Aapms/Store.hs:31-41`)re-export 九個模組,**不含 `Aapms.Store.Edit`**;
  模組 Haddock `:27-29` 說明「`Aapms.Store.Edit`(寫入紀律)與 `Aapms.Store.Node`(Level 樹的純推導)是 graph-core/F008 的內部模組,不進門面」。
- `Aapms.Store.Create` 與 `Aapms.Store.Write` 只是 `import` 它(`Create.hs:100-111`、`Write.hs:65-79`),**沒有 re-export `commit`**。

所以套件外看不到 `commit`。這與 F008 骨架表(`:658`)的宣告一致,也正是帳本 Law 草稿 LAW-1/LAW-2 想釘的事。
**若下游 pipeline 要把 `commit` 當 stage 暴露,得先決定要不要把 `Aapms.Store.Edit` 移進 `exposed-modules`。**

### 註 6 —— `vaultCheck` 撞名(第 19 列):唯一的另一個命中在**凍結套件**裡

| 模組 | 簽名 | 位置 | 在匯出清單 | 在 `cabal.project` |
|---|---|---|---|---|
| `Aapms.Service.Machine` | `vaultCheck :: ServiceM [ScopeIssue]` | `service/src/Aapms/Service/Machine.hs:315` | **是**(`Machine.hs:75`) | 是 |
| `Aapms.Cli.Doctor` | `vaultCheck :: Either ServiceError (VaultView, VaultConfig) -> VaultCheck` | `cli/src/Aapms/Cli/Doctor.hs:170` | **否**(私有 helper) | **否 —— `cli/` 已凍結,不建置** |

帳本標「程式碼在 Aapms.Cli.Doctor」是抓到了凍結的舊碼。真正對應文檔的那一個在 `Aapms.Service.Machine`,
**簽名逐字相同**。文檔在契約表(`:126`)寫「交付,簽名逐字」,在骨架表(`:456`)標位置
`service/src/Aapms/Service/Machine.hs:199`(impl 填完本體後行號下移到 315,文檔 `:366` 自己聲明
「行號是**建檔當下**的導航線索,impl 填完本體後必然往下移;一致性檢查一律比對**簽名原文**」)。

### 註 7 —— `listTypes` 撞名(第 20 列):文檔早就預告了這次撞名

| 模組 | 簽名 | 位置 | 在匯出清單 |
|---|---|---|---|
| `Aapms.Service.Machine` | `listTypes :: ServiceM [TypeDecl]` | `service/src/Aapms/Service/Machine.hs:354` | 是(`Machine.hs:84`) |
| `Aapms.Core.Registry` | `listTypes :: TypeRegistry -> [TypeDecl]` | `core/src/Aapms/Core/Registry.hs:159` | 是(`Registry.hs:26`) |

兩者都是活的、都在 `cabal.project` 內。文檔 `F002-workspace-facade.md:328-329` 的 SELF-2 逐字:

> - **`listTypes`**:本模組的 `listTypes :: ServiceM [TypeDecl]` 與
>   `Aapms.Core.Registry.listTypes :: TypeRegistry -> [TypeDecl]` 同名。作法是 **qualified import**

程式碼 `Machine.hs:352-357` 照做了,Haddock 也寫「__與 `Aapms.Core.Registry.listTypes` 同名__:
本層的版本不收參數,註冊表來自 `Aapms.Service.Monad.askRegistry`。取用下層那一個時必須 qualified。」
帳本標「程式碼在 Aapms.Core.Registry」是撞到了下層那一個。

同一份文檔 `:413` 也把 Registry 的那一條列在「使用到的既有介面」表裡,逐字:
`| `listTypes :: TypeRegistry -> [TypeDecl]`(依 `tdKey` 排序) | `core/src/Aapms/Core/Registry.hs:159` | `graph-core/F002` | 本層 `listTypes` 的唯一來源(qualified) |`
—— 行號 `:159` 與現在的程式碼**完全吻合**。

### 註 8 —— `hubVaults` / `hubProjects` / `hubLlm` / `hubTools` / `hubSourceText`(第 22–26 列):record 欄位 vs 選取器型別

這五個在程式碼裡不是獨立的頂層函式,而是 `data Hub` 的 record 欄位
(`workspace/src/Aapms/Workspace/Types.hs:91-107`):

```haskell
data Hub = Hub
  { hubVaults :: [VaultEntry]
  , hubProjects :: [ProjectEntry]
  , hubLlm :: Maybe LlmSection
  , hubTools :: ToolsConfig
  , hubSourceText :: Text
  }
  deriving stock (Show, Eq)
```

`Hub` 的**建構子不匯出**,匯出的是型別 + `mkHub` + 五個選取器(`Types.hs:20-33`)。
選取器的實際型別就是文檔寫的 `Hub -> [VaultEntry]` 等,所以**語意零差異**;
帳本標不一致只是因為欄位宣告那一行的字面是 `hubVaults :: [VaultEntry]`,少了 `Hub ->`。

`Aapms.Workspace.Hub` 另外轉出四個 getter(`Hub.hs:19-22`),**但不轉出 `hubSourceText` 也不轉出 `mkHub`**
—— 與文檔 `:462-463` 的註記(「自 Aapms.Workspace.Types 轉出…… hubVaults / hubProjects / hubLlm / hubTools」)一致。

這個設計有明文決策,`F001-hub-registry.md:728-757` 的 ASM-1:

> - ASM-1: `Hub` 做成**不透明型別**並在 `Types.hs` 額外匯出 `mkHub` 與 `hubSourceText` 兩個
>   …… 暫採:a(`Hub` 不透明,`Types.hs` 匯出 `Hub` / `mkHub` / `hubSourceText` / 四個 getter)

以及 `:649-651`:

> 骨架裡唯一不是 `undefined` 的本體是 `mkHub = Hub`(`Types.hs:116`)。這是刻意的:
> `mkHub` 之所以存在,只是因為 ASM-1 決定不匯出 `Hub` 的建構子,它的定義**就是**那個建構子本身

程式碼 `Types.hs:110-117` 正是如此(`mkHub = Hub`)。**ASM-1 仍是「暫採」的待確認假設,尚未裁決。**

### 額外:workspace/F001 的簽名在文檔裡出現兩次,兩處措辭不同

- 契約區塊(`:88-110`、`:152-160`):`hubLocation :: IO HubLocation`、`loadHub     :: HubLocation -> IO (Either WorkspaceError Hub)`、
  `hubVaults   :: Hub -> [VaultEntry]` …… 不帶行號註解。
- 骨架區塊(`:370-462`,按檔案分節):同樣的簽名 + `-- :NN` 行號註解。

兩處型別一字不差,上表引用的是**骨架區塊**的版本(帶行號註解那一份)。
若下一步要逐字複製到 pipeline 的 Stages,**建議取契約區塊的版本並自行去掉對齊空白**,
因為骨架區塊的 `-- :NN` 是建檔當下的行號,文檔 `:366` 已聲明它必然過時:

> 行號是**建檔當下**的導航線索,impl 填完本體後必然往下移;一致性檢查一律比對**簽名原文**。
