---
language: haskell
updated: 2026-09-06
---
# aapms:素材與故事設定共用一份片段圖譜的工作室資產管理工具

## 目的
替單人工作室 alchbees 與它接入的 AI Agent(claude code / codex)管理兩種資料:已存在的素材(壓縮檔裡的位元組)與還沒做出來的故事設定(Entity 片段、Level 場景樹)。兩者是同一張片段圖譜上的節點,共用一份 `Meta`、一種有方向的關聯、一張索引、一組指令;一份 servant 契約產出 CLI / HTTP / MCP 三個殼。檔案是真相(Markdown 與壓縮檔),SQLite 只是索引,任何 vault 都能 `rm index.db` 後等價重建。不做:遊戲執行期的載入器與對話引擎、多人協作與權限、即時同步;Web 前端只在最後一期接回。
發佈驗收(原 S7,不是資料流,不建 pipeline):縮圖瀏覽可用;從乾淨機器跑 `aapms workspace setup` 到 `project new` 一路通。

## 語言與工具
- 建置:`cabal build all`
- 測試(整套):`cabal test all --test-show-details=direct`
- 測試(子集):`cabal test <套件>-test --test-show-details=direct --test-options='-m P-00x'`(stage 住哪個套件就跑哪個;hspec 的 `-m` 以歸屬字串 `P-00x` 選)
- IO 模組追加:`Database.SQLite.Simple`、`Database.SQLite3`、`System.FilePath.Windows`、`Control.Exception`、`UnliftIO.*`
- 效果型別追加:`ServiceM`、`Connection`、`VaultHandle`
- 忽略目錄:`legacy`、`.knot`、`conflict`、`llm`、`workshop`、`cli`、`api`、`server`、`mcp`
  (後七個是凍結的舊 story-flow 套件,不在 cabal.project;各殼與領域 pipeline build 時重建後逐一移出本清單)

## 邊界
- types:`Aapms.Core.*` 的值型別、強型別 id、關聯詞彙、smart constructor 與存取子(遊戲本體只 import 這一層,零重量級相依);`Aapms.Md.Document` / `Aapms.Md.Error`;各套件的錯誤 ADT 與 View 型別;servant 路由型別。
- effects:effectful 的效果描述(`Eff es`,不帶 `IOE`):`Index`(索引列的讀寫)、`VaultFs`(vault 目錄裡 Markdown 與 marker 的讀寫)、`HubFile`(中樞 config.toml 的讀寫)、`Clock`、`ToolProbe`(外部工具探測);每個效果配一個純解譯器 `run<Effect>Pure`(記憶體 `Map`)當觀察點。現況為零,由各里程碑 build 時立(ADR-023)。
- pure:`Aapms.Core.Naming` / `Registry` / `Tree`、`Aapms.Md.*`、`Aapms.Store.Tokenize`,以及各里程碑的 `=` 列:重建規劃、寫入規劃、範圍裁決、生命週期前置檢查、View 投影、CLI 解析與信封。
- shell:真解譯器(sqlite、directory、http-client、typed-process)與進入點:`Aapms.Store.*` 的 IO 面、`Aapms.Types.Loader`、`Aapms.Workspace.*` 的 IO 面、`Aapms.Service.*`(`ServiceM` 是 `ReaderT Env (ExceptT ServiceError IO)`,屬 shell)、三個殼的 `Main`。

## 對外 I/O
| 名稱 | 方向 | 型別 / 效果 ADT | shell 模組 | 進入哪條 pipeline |
|---|---|---|---|---|
| vault marker `.aapms/config.toml` | in | `VaultMarker` | `Aapms.Store.Marker` | P-001-index-rebuild |
| vault 的 Markdown 檔 | in | `Document` | `Aapms.Store.Index` | P-001-index-rebuild |
| `index.db` 索引列與問題清單 | out | `IndexIssue` | `Aapms.Store.Index` | P-001-index-rebuild |
| 全文查詢 | in | `SearchQuery` | `Aapms.Store.MultiVault` | P-002-search |
| 命中(每筆帶 vault) | out | `SearchHit` | `Aapms.Store.MultiVault` | P-002-search |
| 寫入請求(新節 / 覆寫 / 關聯 / 授權 / 刪除) | in | `NewSection` | `Aapms.Store.Write` | P-003-node-write |
| Markdown 寫回與索引更新結果 | out | `WriteResult` | `Aapms.Store.Write` | P-003-node-write |
| 中樞 `config.toml` | in | `Hub` | `Aapms.Workspace.Hub` | P-004-vault-scope |
| 型別註冊表 `types/registry/*.toml` | in | `TypeRegistry` | `Aapms.Types.Loader` | P-004-vault-scope |
| `--vault` 旗標與起點目錄 | in | `VaultRef` | `Aapms.Workspace.Scope` | P-004-vault-scope |
| 本次生效的 vault 集合 | out | `ReadScope` | `Aapms.Workspace.Scope` | P-004-vault-scope |
| vault init / add / forget 請求 | in | `InitMode` | `Aapms.Workspace.Lifecycle` | P-005-vault-lifecycle |
| 中樞 `config.toml` 寫回與新 vault 的 marker | out | `VaultEntry` | `Aapms.Workspace.Lifecycle` | P-005-vault-lifecycle |
| 外部工具探測(7-Zip、PATH) | in | `ToolStatus` | `Aapms.Workspace.Tools` | P-006-workspace-doctor |
| doctor 報告 | out | `DoctorView` | `Aapms.Service.Machine` | P-006-workspace-doctor |
| 節點讀取請求 | in | `NodeFilter` | `Aapms.Service.Read` | P-007-graph-read |
| `NodeView` / `Page` | out | `NodeView` | `Aapms.Service.Read` | P-007-graph-read |
| 圖譜寫入請求(含 expected revision) | in | `WriteReq` | `Aapms.Service.Write` | P-008-graph-write |
| 新 revision 的 `NodeView` | out | `NodeView` | `Aapms.Service.Write` | P-008-graph-write |
| argv | in | `Command` | `Aapms.Cli.Main` | P-009-cli-shell |
| stdout 信封與 exit code | out | `Envelope` | `Aapms.Cli.Main` | P-009-cli-shell |
| HTTP request(servant 路由) | in | `Api` | `Aapms.Server.Main` | P-010-http-shell |
| HTTP response 與錯誤 body | out | `ErrorBody` | `Aapms.Server.Main` | P-010-http-shell |
| stdin JSON-RPC | in | `RpcRequest` | `Aapms.Mcp.Main` | P-011-mcp-shell |
| stdout JSON-RPC 結果 | out | `RpcResponse` | `Aapms.Mcp.Main` | P-011-mcp-shell |
| `library/` 下的壓縮檔(不解壓) | in | `ArchiveEntry` | `Aapms.Ingest.Scan` | P-012-asset-scan |
| `pack.md` 與索引 | out | `Pack` | `Aapms.Ingest.Scan` | P-012-asset-scan |
| 壓縮檔內的影像位元組 | in | `Sha256` | `Aapms.Ingest.Thumbs` | P-013-thumb-cache |
| 全局縮圖快取 `cache/thumbs/<aa>/<sha>.png` | out | `ThumbPath` | `Aapms.Ingest.Thumbs` | P-013-thumb-cache |
| 未命名 asset 的檔名 | in | `ClusterRule` | `Aapms.Ingest.Cluster` | P-014-name-cluster |
| 命名規則與套用結果(`--confirm` 才寫) | out | `LogicalName` | `Aapms.Ingest.Cluster` | P-014-name-cluster |
| vault 目錄快照 | in | `ReorgPlan` | `Aapms.Reorg.Plan` | P-015-pack-reorganize |
| 搬遷執行與對帳報告 | out | `ReorgReport` | `Aapms.Reorg.Plan` | P-015-pack-reorganize |
| 新劇情草稿 | in | `Draft` | `Aapms.Conflict.Check` | P-016-conflict-check |
| 衝突報告(指到片段) | out | `ConflictReport` | `Aapms.Conflict.Check` | P-016-conflict-check |
| OpenAI 相容端點 | out | `ChatRequest` | `Aapms.Llm.Client` | P-017-ai-classify |
| 分類建議(暫存,`confirm` 才寫) | out | `Suggestion` | `Aapms.Ai.Classify` | P-017-ai-classify |
| 工作坊回合輸入 | in | `WorkshopSession` | `Aapms.Workshop.Run` | P-018-workshop |
| 逐階段產出的片段 | out | `NewSection` | `Aapms.Workshop.Run` | P-018-workshop |
| 專案產出請求(Level → Entity → Asset) | in | `ProjectRequest` | `Aapms.Project.Export` | P-019-project-export |
| `assets/manifest.json`、`Assets.hs`、`story/manifest.json` | out | `Manifest` | `Aapms.Project.Export` | P-019-project-export |

## Pipelines
| 全名 | 類別 |
|---|---|
| P-001-index-rebuild | 里程碑 |
| P-002-search | 里程碑 |
| P-003-node-write | 里程碑 |
| P-004-vault-scope | 里程碑 |
| P-005-vault-lifecycle | 里程碑 |
| P-006-workspace-doctor | 里程碑 |
| P-007-graph-read | 里程碑 |
| P-008-graph-write | 里程碑 |
| P-009-cli-shell | 里程碑 |
| P-010-http-shell | 里程碑 |
| P-011-mcp-shell | 里程碑 |
| P-012-asset-scan | 里程碑 |
| P-013-thumb-cache | 里程碑 |
| P-014-name-cluster | 里程碑 |
| P-015-pack-reorganize | 里程碑 |
| P-016-conflict-check | 里程碑 |
| P-017-ai-classify | 里程碑 |
| P-018-workshop | 里程碑 |
| P-019-project-export | 里程碑 |
| P-020-core-identity | 子流 |
| P-021-registry-build | 子流 |
| P-022-logical-name | 子流 |
| P-023-manifest-codec | 子流 |
| P-024-level-tree | 子流 |
| P-025-md-document | 子流 |
| P-026-md-edit | 子流 |
| P-027-fts-tokenize | 子流 |
| P-028-hub-config | 子流 |
| P-029-scope-resolve | 子流 |
