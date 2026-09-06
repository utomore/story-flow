# migrate from-dev-flow 帳本

來源:../../../AppData/Local/Temp/claude/C--Users-User-Documents-alchbees-dev-story-flow/f9dc6b80-ac61-4eb8-9f7f-6cc94d233f18/scratchpad/design-nolegacy · 文檔 32 份(F 29、E 0、B 2、G-* 1)· ADR 22 份原樣搬 · 程式碼模組 138 個

## 里程碑候選(從開發階段表來;每個階段的垂直切片是一條或多條里程碑 pipeline,切法由人定)
| 階段 | 里程碑 | 狀態 |
|---|---|---|
| **S0** 讓名與合樹 | `cabal build all` 綠;契約測試綠;零邏輯改動 | 已達成 |
| **S1** graph-core | `rm index.db` → rebuild 兩種 vault 都等價;「藥水」搜得到;`aapms-core` 零重量級相依 | 已達成 |
| **S2** 真資料進場(取消) | — | 已達成 |
| **S3** 骨幹 | 兩種 vault 都能經統一外殼 CRUD、search 一次回兩種;`--remote` 行為一致;OpenAPI 輸出 | 進行中 |
| **S4** 素材管線 | 搬動與刪除 pack 不留幽靈;`asset scan` 對真 vault(27 個 pack、6,783 筆資源)跑得完,`rm index.db` → rebuild 等價 | 未開始 |
| **S5** 智慧 | 衝突偵測候選集含 asset;`ai classify` 與 `workshop` 共用端點 | 未開始 |
| **S6** 連動 | 「建專案 → 挑 Level → 自動帶素材 → 擋授權」一條龍 | 未開始 |
| **S7** 收尾 | 縮圖瀏覽可用;從乾淨機器跑 `aapms workspace setup` 到 `project new` | 未開始 |

## 文檔對帳
| 文檔 | 類別 | status | 文檔簽名數量 | Code 簽名數量 | 型別 | Law 條數 | 可機械翻成三行 | Example 數 | 主要模組 |
|---|---|---|---|---|---|---|---|---|---|
| G-B001-contract-rules-frozen-out-of-build | G-B | done | 0 | 0 | 0 | 0 | 0 | 0 | — |
| graph-core/B001-fixture-vault-layout | B | done | 0 | 0 | 0 | 0 | 0 | 0 | — |
| graph-core/B002-init-vault-at-leaks-io-exceptions | B | done | 0 | 0 | 0 | 0 | 0 | 0 | — |
| graph-core/F001-core-unified-meta | F | done | 7 | 7 | 0 | 0 | 0 | 0 | Aapms.Core.Id |
| graph-core/F002-registry-family-and-naming | F | done | 22 | 19 | 0 | 0 | 0 | 0 | Aapms.Core.Naming |
| graph-core/F003-manifest-schema-v2 | F | done | 5 | 5 | 0 | 0 | 0 | 0 | Aapms.Core.Manifest |
| graph-core/F004-md-unified-sections | F | done | 22 | 22 | 1 | 0 | 0 | 29 | Aapms.Md.Render |
| graph-core/F005-store-vault-handle | F | done | 20 | 10 | 0 | 0 | 0 | 6 | Aapms.Store.Schema |
| graph-core/F006-store-unified-index | F | done | 17 | 14 | 1 | 4 | 0 | 6 | Aapms.Store.Query |
| graph-core/F007-store-fts-dual-index | F | done | 20 | 19 | 0 | 0 | 0 | 14 | Aapms.Store.Tokenize |
| graph-core/F008-store-write-operations | F | done | 28 | 27 | 2 | 0 | 0 | 22 | Aapms.Store.Edit |
| graph-core/F009-store-multi-vault-read | F | done | 11 | 11 | 3 | 0 | 0 | 17 | Aapms.Store.MultiVault |
| service/F001-service-env-and-scope | F | done | 23 | 23 | 3 | 0 | 0 | 32 | Aapms.Service.Monad |
| service/F002-workspace-facade | F | done | 16 | 14 | 6 | 0 | 0 | 30 | Aapms.Service.Machine |
| service/F003-node-read | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| service/F004-node-write | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| service/F005-asset-naming | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| service/F006-level-and-node | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| service/F007-search-facade | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| service/F008-index-ops | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F001-api-types-and-openapi | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F002-backend-dispatch | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F003-cli-options-and-envelope | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F004-cli-render | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F005-http-server | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| shell/F006-mcp-adapter | F | planned | 0 | 0 | 0 | 0 | 0 | 0 | — |
| workspace/F001-hub-registry | F | done | 17 | 0 | 0 | 0 | 0 | 29 | Aapms.Workspace.Types |
| workspace/F002-vault-discovery | F | done | 4 | 4 | 0 | 0 | 0 | 24 | Aapms.Workspace.Discovery |
| workspace/F003-scope-resolution | F | done | 3 | 3 | 0 | 0 | 0 | 36 | Aapms.Workspace.Scope |
| workspace/F004-vault-lifecycle | F | done | 8 | 8 | 0 | 0 | 0 | 45 | Aapms.Workspace.Lifecycle |
| workspace/F005-project-registry | F | done | 3 | 3 | 0 | 0 | 0 | 31 | Aapms.Workspace.Projects |
| workspace/F006-machine-tools | F | done | 2 | 2 | 1 | 0 | 0 | 17 | Aapms.Workspace.Tools |

## 分組建議(同一組合成一條子流 pipeline;要不要合、叫什麼,人定)
- **Aapms.Core** → 建議 `lawful claim core`:graph-core/F001-core-unified-meta、graph-core/F002-registry-family-and-naming、graph-core/F003-manifest-schema-v2
  - Stages 候選:`anyMeta`、`prefixOf`、`newId`、`parseId`、`parseRef`、`renderRef`、`buildTree`、`renderFamily`、`parseFamily`、`reservedTypeKeys`、`buildRegistry`、`lookupType`、`listTypes`、`lookupDir`、`checkMeta`、`renderRegistryError`、`segmentText`、`mkSegment`、`renderNameError`、`maxLogicalNameLength`、`indexSegment`、`isIndexShaped`、`mkLogicalName`、`parseLogicalName`、`validateLogicalName`、`renderParts`、`locateRegistry`、`loadRegistry`、`loadRegistryFrom`、`currentSchemaVersion`、`currentStoryManifestSchemaVersion`、`manifestIndex`、`imageMeta`、`audioMeta`
- **Aapms.Md** → 建議 `lawful claim md`:graph-core/F004-md-unified-sections
  - Stages 候選:`parseDocument`、`docKind`、`toTopic`、`toLevel`、`toPack`、`toLicenses`、`renderDocument`、`updateFrontmatter`、`overrideAt`、`updateSection`、`updateSectionBody`、`appendSection`、`insertSection`、`removeSection`、`newDocument`、`extrasOf`、`extrasAt`、`mergeExtras`、`updateSectionExtras`、`payloadOverride`、`payloadExtras`、`renderMetaBlock`
- **Aapms.Service** → 建議 `lawful claim service`:service/F001-service-env-and-scope、service/F002-workspace-facade
  - Stages 候選:`errorCode`、`renderServiceError`、`openEnv`、`runService`、`closeEnv`、`withEnv`、`askHubLocation`、`askHub`、`reloadHub`、`askRegistry`、`askNaming`、`askRegistrySource`、`askSelector`、`askCwd`、`handleFor`、`indexIssuesFor`、`throwService`、`liftStore`、`liftWorkspace`、`finallyService`、`withRead`、`withWrite`、`withPipeline`、`workspaceSetup`、`workspaceDoctor`、`workspaceTools`、`workspacePurge`、`vaultInit`、`vaultAdd`、`vaultList`、`vaultInfo`、`vaultForget`、`vaultCheck`、`projectRegister`、`projectList`、`projectForget`、`listTypes`、`showType`、`thumbPath`
- **Aapms.Store** → 建議 `lawful claim store`:graph-core/F005-store-vault-handle、graph-core/F006-store-unified-index、graph-core/F007-store-fts-dual-index、graph-core/F008-store-write-operations、graph-core/F009-store-multi-vault-read
  - Stages 候選:`renderVaultKind`、`parseVaultKind`、`schemaVersion`、`renderIndexIssue`、`closeIndex`、`createSchema`、`resetSchema`、`currentVersion`、`indexTables`、`setVaultInfo`、`readMarker`、`initVaultAt`、`openVault`、`closeVault`、`markerDir`、`configPath`、`indexDbPath`、`renderStoreError`、`trySqlite`、`initVaultAtWith`、`indexFile`、`unindexFile`、`rebuildIndex`、`refreshStale`、`emptyNodeFilter`、`lookupNode`、`lookupByName`、`listNodes`、`childrenOf`、`linksFrom`、`linksTo`、`loadLinkGraph`、`vaultMarkdownFiles`、`statOf`、`isCjk`、`hasCjk`、`cjkRuns`、`rawFtsText`、`segmentFtsText`、`ftsRowOf`、`cjkSegment`、`usesTrigram`、`usesCjk`、`routeOf`、`triMatchExpr`、`cjkMatchExpr`、`ftsQuoted`、`ftsPhrase`、`insertFtsRows`、`emptySearchQuery`、`search`、`createTopicFile`、`createLevelFile`、`createPackFile`、`addSection`、`writeMeta`、`writeAssetFields`、`writeBody`、`addLink`、`removeLink`、`upsertLicense`、`deleteNode`、`allocateId`、`locate`、`readDocument`、`orMd`、`checkRevision`、`commit`、`dropFile`、`ensureDir`、`vaultAbsPath`、`sectionBodyRaw`、`headingDepthFor`、`subtreeAfter`、`subtreeIds`、`isRootNode`、`validateLevelDoc`、`sanitizeFileName`、`maxAttachedVaults`、`openVaultSet`、`closeVaultSet`、`vaultSetIds`、`lookupRef`、`listAcross`、`searchAcross`、`checkReferences`、`renderDanglingRef`、`whereOfIn`、`baseFromIn`
- **Aapms.Workspace** → 建議 `lawful claim workspace`:workspace/F001-hub-registry、workspace/F002-vault-discovery、workspace/F003-scope-resolution、workspace/F004-vault-lifecycle、workspace/F005-project-registry、workspace/F006-machine-tools
  - Stages 候選:`mkHub`、`hubSourceText`、`hubVaults`、`hubProjects`、`hubLlm`、`hubTools`、`renderWorkspaceError`、`hubLocation`、`configPath`、`thumbCacheDir`、`thumbCachePath`、`loadHub`、`saveHub`、`upsertVault`、`removeVault`、`upsertProject`、`removeProject`、`detectVault`、`lookupSelector`、`readVaultRef`、`readVaultRefAt`、`resolveRead`、`resolveWrite`、`resolvePipeline`、`setupHub`、`initVault`、`addVault`、`forgetVault`、`purge`、`checkVaults`、`syncHub`、`initVaultWith`、`registerProject`、`forgetProject`、`allocateProjectId`、`detectSevenZip`、`detectSevenZipIn`
- **graph-core(簽名對不到程式碼)**:graph-core/B001-fixture-vault-layout、graph-core/B002-init-vault-at-leaks-io-exceptions
- **service(簽名對不到程式碼)**:service/F003-node-read、service/F004-node-write、service/F005-asset-naming、service/F006-level-and-node、service/F007-search-facade、service/F008-index-ops
- **shell(簽名對不到程式碼)**:shell/F001-api-types-and-openapi、shell/F002-backend-dispatch、shell/F003-cli-options-and-envelope、shell/F004-cli-render、shell/F005-http-server、shell/F006-mcp-adapter
- **全域(簽名對不到程式碼)**:G-B001-contract-rules-frozen-out-of-build

## Law 草稿(四格 → 三行;`<…>` 是人要補的)
### graph-core/F006-store-unified-index
- LAW-1 [<種類>] `aapms-store.cabal` 的 library `exposed-modules` **不含** `Aapms.Store.Edit`、  ← 需形式化
  - forall <變數待補>
  - given <無(無條件成立)>
  - |- <aapms-store.cabal ; exposed-modules … 需形式化:`aapms-store.cabal` library stanza 的 `exposed-modules` 清單裡找不到 m(以原始檔>
- LAW-2 [<種類>] 上述四個模組**都出現在** library 的 `other-modules`  ← 需形式化
  - forall <變數待補>
  - given <無(無條件成立)>
  - |- <aapms-store.cabal ; other-modules … 需形式化:`aapms-store.cabal` library stanza 的 `other-modules` 清單裡找得到 m;與 LAW-1 合起來>
- LAW-3 [<種類>] `aapms-store-test` 的 `build-depends` **不含** `aapms-store`,且它的 `hs-source-dirs`  ← 需形式化
  - forall <變數待補>
  - given <讀的是 `aapms-store-test` 這個 stanza,不是 library stanza>
  - |- <aapms-store-test ; build-depends ; aapms-store ; hs-source-dirs … 需形式化:`aapms-store-test` 的 `build-depends` 不出現 `aapms-store`;`hs-source-dirs` 同時>
- LAW-4 [<種類>] `store/src/Aapms/Store/Index.hs` 的模組匯出清單**不含** `vaultMarkdownFiles` 與 `statOf`  ← 需形式化
  - forall <變數待補>
  - given <`Aapms.Store.Index` 本身仍列在 `exposed-modules`(它是公開模組)>
  - |- <Aapms.Store.Index ; Index.hs … 需形式化:`Aapms.Store.Index` 的模組匯出清單(`Index.hs` 檔頭那一段)裡找不到 x>

## 簽名對不上程式碼
- 找不到:graph-core/F007-store-fts-dual-index:`desegmentCjk`
- 不一致:graph-core/F002-registry-family-and-naming:`renderFamily`(程式碼在 Aapms.Core.Registry)
- 不一致:graph-core/F002-registry-family-and-naming:`reservedTypeKeys`(程式碼在 Aapms.Core.Registry)
- 不一致:graph-core/F002-registry-family-and-naming:`maxLogicalNameLength`(程式碼在 Aapms.Core.Naming)
- 不一致:graph-core/F005-store-vault-handle:`renderVaultKind`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`parseVaultKind`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`createSchema`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`resetSchema`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`indexTables`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`setVaultInfo`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F005-store-vault-handle:`markerDir`(程式碼在 Aapms.Store.Marker)
- 不一致:graph-core/F005-store-vault-handle:`configPath`(程式碼在 Aapms.Store.Marker)
- 不一致:graph-core/F005-store-vault-handle:`indexDbPath`(程式碼在 Aapms.Store.Marker)
- 不一致:graph-core/F005-store-vault-handle:`trySqlite`(程式碼在 Aapms.Store.Error)
- 不一致:graph-core/F006-store-unified-index:`renderIndexIssue`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F006-store-unified-index:`indexTables`(程式碼在 Aapms.Store.Schema)
- 不一致:graph-core/F006-store-unified-index:`emptyNodeFilter`(程式碼在 Aapms.Store.Query)
- 不一致:graph-core/F008-store-write-operations:`commit`(程式碼在 Aapms.Store.Edit)
- 不一致:service/F002-workspace-facade:`vaultCheck`(程式碼在 Aapms.Cli.Doctor)
- 不一致:service/F002-workspace-facade:`listTypes`(程式碼在 Aapms.Core.Registry)
- 不一致:workspace/F001-hub-registry:`mkHub`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubSourceText`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubVaults`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubProjects`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubLlm`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubTools`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`renderWorkspaceError`(程式碼在 Aapms.Workspace.Types)
- 不一致:workspace/F001-hub-registry:`hubLocation`(程式碼在 Aapms.Workspace.Location)
- 不一致:workspace/F001-hub-registry:`configPath`(程式碼在 Aapms.Store.Marker)
- 不一致:workspace/F001-hub-registry:`thumbCacheDir`(程式碼在 Aapms.Workspace.Location)
- 不一致:workspace/F001-hub-registry:`thumbCachePath`(程式碼在 Aapms.Workspace.Location)
- 不一致:workspace/F001-hub-registry:`loadHub`(程式碼在 Aapms.Workspace.Hub)
- 不一致:workspace/F001-hub-registry:`saveHub`(程式碼在 Aapms.Workspace.Hub)
- 不一致:workspace/F001-hub-registry:`upsertVault`(程式碼在 Aapms.Workspace.Hub)
- 不一致:workspace/F001-hub-registry:`removeVault`(程式碼在 Aapms.Workspace.Hub)
- 不一致:workspace/F001-hub-registry:`upsertProject`(程式碼在 Aapms.Workspace.Hub)
- 不一致:workspace/F001-hub-registry:`removeProject`(程式碼在 Aapms.Workspace.Hub)

## 退場清單(內容已在程式碼或 pipeline 的 Brief 裡,不搬)
- subsystems/graph-core/build-log.md
- subsystems/graph-core/design.md
- subsystems/graph-core/spec-gaps.md
- subsystems/service/build-log.md
- subsystems/service/design.md
- subsystems/service/spec-gaps.md
- subsystems/shell/design.md
- subsystems/workspace/build-log.md
- subsystems/workspace/design.md
- subsystems/workspace/spec-gaps.md
- bugfixes/G-B001-contract-rules-frozen-out-of-build.md:B 的重現測試改標 `"P-00x#LAW-n"`,law 沒寫到的補 law
- subsystems/graph-core/bugfixes/B001-fixture-vault-layout.md:B 的重現測試改標 `"P-00x#LAW-n"`,law 沒寫到的補 law
- subsystems/graph-core/bugfixes/B002-init-vault-at-leaks-io-exceptions.md:B 的重現測試改標 `"P-00x#LAW-n"`,law 沒寫到的補 law

## 人要判的
1. 分組:9 組要不要合、各叫什麼;哪幾組是同一條里程碑的 stage
2. 里程碑切法:8 個階段各切成幾條里程碑 pipeline
3. law 形式化:4 條 law 的觀察點是散文,要改寫成只引用 Stages 簽名與 types 匯出的 `|-` 行
4. 簽名:1 條找不到、36 條不一致,誰對誰錯
5. 待確認假設:45 條還在檔上,決定了寫進「決定」,沒決定的開 GAP
6. planned 的 12 份:變 draft pipeline 還是變別條的願望 stage
