---
id: P-001
description: vault 裡的 Markdown 與 marker 經解析、驗證、列轉換整檔替換進索引;rm index.db 後重建與原索引等價
status: ready
updated: 2026-09-06
---
# P-001-index-rebuild:vault 裡的 Markdown 與 marker 經解析、驗證、列轉換整檔替換進索引;rm index.db 後重建與原索引等價

## Brief
把一個 vault 目錄裡的每份 `.md` 變成可查詢的圖譜,並守住「檔案是真相、索引可丟」(ADR-002、ADR-013)。input 是 vault 相對路徑下的 Markdown 檔與它們的 mtime / size;output 是索引狀態(每個檔案一組節點、包含關係、文件種類、檔案指紋)與一份 `IndexIssue` 清單。流向:列出 Markdown → 讀檔與取 stat → 解析成 Document → 依種類轉成節點 → 樹驗證與 Meta 警告 → 組成該檔的 FileIndex → 整檔替換進索引;過時刷新走同一條,只多一步「比對指紋找出過時與消失的檔」。整條是 effectful 的效果程式(`VaultFs` 讀檔、`Index` 寫索引),law 全部用純解譯器跑在記憶體裡;真解譯器(directory / sqlite)住 shell,`rebuildIndex` 是進入點,`refreshStale` / `indexFile` / `unindexFile` 三個既有的 shell 入口跑同一組解譯器。它是 S1 的第一條里程碑;`openVault` 在 schema_version 不符時呼叫它整庫重建。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `listMarkdown :: VaultFs :> es => Eff es [FilePath]` | 列出 vault 下全部 `.md` 的相對路徑,略過 `.` 開頭目錄,已排序 | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 2 | `statFile :: VaultFs :> es => FilePath -> Eff es (Either StoreError FileStat)` | 取一個檔的 mtime 與 size 當指紋 | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 3 | `readMarkdown :: VaultFs :> es => FilePath -> Eff es (Either StoreError Text)` | 讀一個檔的全文 | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 4 | `parseDocument :: Text -> Either MdError Document` | 全文解析成分節文件 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 5 | `toTopic :: Document -> Either MdError (Entity, [Entity])` | 主題檔轉成主體與片段 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 6 | `toLevel :: Document -> Either MdError (Level, [Node])` | Level 檔轉成場景與節點 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 7 | `toPack :: Document -> Either MdError (Pack, [Asset])` | pack 檔轉成 pack 與 asset | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 8 | `toLicenses :: Document -> Either MdError [License]` | 授權檔轉成授權節點 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 9 | `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | Level 樹驗證,不合法整檔不進 | `Aapms.Core.Tree`(見 P-024-level-tree) | pure |
| 10 | `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` | 對每個節點只產警告,不擋 | `Aapms.Core.Registry.Build`(見 P-021-registry-build) | pure |
| 11 | `indexDocument :: TypeRegistry -> VaultId -> FilePath -> FileStat -> Text -> Either IndexIssue (FileIndex, [IndexIssue])` | 一份檔的純核心:4 → 5..8 → 9 / 10 → 該檔的 FileIndex;解析或樹失敗回 Left(ParseFailed / TreeInvalid),警告進 issues | `Aapms.Store.Indexing`(願望) | pure |
| 12 | `replaceFile :: Index :> es => FileIndex -> Eff es ()` | 以檔案為單位整檔替換索引裡的記錄 | `Aapms.Store.Effect.Index`(願望) | effects |
| 13 | `removeFile :: Index :> es => FilePath -> Eff es ()` | 移除一個檔案的全部記錄 | `Aapms.Store.Effect.Index`(願望) | effects |
| 14 | `fileStats :: Index :> es => Eff es (Map FilePath FileStat)` | 索引裡記錄的每個檔的指紋 | `Aapms.Store.Effect.Index`(願望) | effects |
| 15 | `staleFiles :: Map FilePath FileStat -> Map FilePath FileStat -> ([FilePath], [FilePath])` | (磁碟指紋, 索引指紋) → (要重索引的, 磁碟上已消失的) | `Aapms.Store.Indexing`(願望) | pure |
| 16 | `indexPath :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> FilePath -> Eff es (Either StoreError [IndexIssue])` | 單檔:2 → 3 → 11 → 12;解析失敗的檔回 issues 不進索引 | `Aapms.Store.Indexing`(願望) | pure |
| 17 | `refresh :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])` | 過時刷新:1 → 2 → 14 → 15 → 對過時的 16、消失的 13(removeFile) | `Aapms.Store.Indexing`(願望) | pure |
| o | `runVaultFsPure :: VaultFiles -> Eff (VaultFs : es) a -> Eff es a` | 觀察:VaultFs 的純解譯器,跑在記憶體裡的檔案表上 | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| o | `runIndexPure :: IndexState -> Eff (Index : es) a -> Eff es (a, IndexState)` | 觀察:Index 的純解譯器,回最終索引狀態;以 P-027 的 `matchesQuery` 與 P-002 的 `passesFilter` 當參考實作,所以住 pure | `Aapms.Store.Simulate`(願望) | pure |
| o | `simulate :: VaultFiles -> IndexState -> Eff '[VaultFs, Index] a -> (a, IndexState)` | 觀察:兩個純解譯器串起來跑到底 | `Aapms.Store.Indexing.Internal`(願望) | pure |
| o | `emptyIndex :: IndexState` | 觀察:空索引 | `Aapms.Store.Types`(願望) | types |
| o | `vaultPaths :: VaultFiles -> [FilePath]` | 觀察:記憶體 vault 裡的路徑,已排序 | `Aapms.Store.Types`(願望) | types |
| o | `fileAt :: VaultFiles -> FilePath -> (FileStat, Text)` | 觀察:記憶體 vault 裡某路徑的指紋與內容 | `Aapms.Store.Types`(願望) | types |
| o | `statsDistinguish :: VaultFiles -> VaultFiles -> Bool` | 觀察:兩份 vault 同路徑內容不同時指紋也不同 | `Aapms.Store.Types`(願望) | types |
| o | `indexedPaths :: IndexState -> [FilePath]` | 觀察:索引裡有記錄的路徑 | `Aapms.Store.Types`(願望) | types |
| o | `indexedNodes :: IndexState -> [AnyNode]` | 觀察:索引裡全部節點 | `Aapms.Store.Types`(願望) | types |
| o | `indexedIds :: IndexState -> [Id]` | 觀察:索引裡全部節點的 id | `Aapms.Store.Types`(願望) | types |
| o | `assetNames :: IndexState -> [LogicalName]` | 觀察:索引裡已命名 asset 的邏輯名稱 | `Aapms.Store.Types`(願望) | types |
| o | `warnedIds :: [IndexIssue] -> [Id]` | 觀察:MetaWarningsFound 點到的節點 id | `Aapms.Store.Types`(願望) | types |
| o | `clashesEarlier :: TypeRegistry -> VaultId -> VaultFiles -> FilePath -> Bool` | 觀察:這個檔某個已命名 asset 的邏輯名稱,已被路徑字母序更前、純核心成功的檔用掉(撞名回滾的判準) | `Aapms.Store.Indexing.Internal`(願望) | pure |
| = | `rebuild :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> Eff es (Either StoreError [IndexIssue])` | 純的整條:清空索引,1 → 對每個路徑 16,收集 issues | `Aapms.Store.Indexing`(願望) | pure |
| ! | `rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])` | 進入點:以 handle 的根目錄與連線跑真解譯器(directory、sqlite) | `Aapms.Store.Index` | shell |
| ! | `refreshIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])` | 進入點:以 handle 的根目錄與連線跑真解譯器,走 17(過時刷新)而不是全量;開 vault 時用它 | `Aapms.Store.Index` | shell |

## Laws
- LAW-1 [identity] 重建冪等:對已重建的索引再重建,結果與索引都不變
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, (r1, ix1) in simulate vf emptyIndex (rebuild reg vid)
  - |- simulate vf ix1 (rebuild reg vid) == (r1, ix1)
- LAW-2 [equiv] rm index.db 等價:從任何舊索引重建,與從空索引重建得到同一個索引(ADR-013)
  - forall vf in VaultFiles, ix0 in IndexState, reg in TypeRegistry, vid in VaultId
  - |- snd (simulate vf ix0 (rebuild reg vid)) == snd (simulate vf emptyIndex (rebuild reg vid))
- LAW-3 [equiv] 全量重建等於逐檔索引
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId
  - |- snd (simulate vf emptyIndex (rebuild reg vid)) == snd (simulate vf emptyIndex (mapM_ (indexPath reg vid) (vaultPaths vf)))
- LAW-4 [identity] 檔案沒變時刷新是恆等,且不回報任何問題
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, (r1, ix1) in simulate vf emptyIndex (rebuild reg vid)
  - |- simulate vf ix1 (refresh reg vid) == (Right [], ix1)
- LAW-5 [equiv] 增量刷新等於重建:檔案集合任意變動後,刷新得到的索引與從空重建相同
  - forall vf1 in VaultFiles, vf2 in VaultFiles, reg in TypeRegistry, vid in VaultId, (r1, ix1) in simulate vf1 emptyIndex (rebuild reg vid)
  - given statsDistinguish vf1 vf2
  - |- snd (simulate vf2 ix1 (refresh reg vid)) == snd (simulate vf2 emptyIndex (rebuild reg vid))
- LAW-6 [relation] 一個檔在不在索引裡,由它自己的純核心成敗與「邏輯名稱有沒有被字母序更前的檔佔走」決定;單檔失敗不中斷其他檔
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, p in vaultPaths vf, (st, txt) in fileAt vf p, (r, ix) in simulate vf emptyIndex (rebuild reg vid)
  - |- elem p (indexedPaths ix) == (isRight (indexDocument reg vid p st txt) and not (clashesEarlier reg vid vf p))
- LAW-7 [invariant] 索引裡每個節點的 vault 欄等於重建時給的 vault id,不信檔案自己寫的
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, (r, ix) in simulate vf emptyIndex (rebuild reg vid), n in indexedNodes ix
  - |- metaVault (anyMeta n) == vid
- LAW-8 [invariant] 一個 vault 內已命名 asset 的邏輯名稱唯一
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, (r, ix) in simulate vf emptyIndex (rebuild reg vid)
  - |- nub (assetNames ix) == assetNames ix
- LAW-9 [total] 單檔純核心對任何文字都有值,不拋例外
  - forall reg in TypeRegistry, vid in VaultId, p in FilePath, st in FileStat, txt in Text
  - |- total (indexDocument reg vid p st txt)
- LAW-10 [identity] 指紋相同時沒有過時也沒有消失
  - forall m in Map FilePath FileStat
  - |- staleFiles m m == ([], [])
- LAW-11 [relation] 過時 = 磁碟上指紋與索引不同或索引沒有;消失 = 索引有而磁碟沒有
  - forall disk in Map FilePath FileStat, rec in Map FilePath FileStat, p in FilePath, (todo, gone) in staleFiles disk rec
  - |- ((p in todo) == (member p disk and (lookup p disk /= lookup p rec))) and ((p in gone) == (member p rec and not (member p disk)))
- LAW-12 [relation] 警告不擋索引:被 MetaWarningsFound 點到的節點仍在索引裡
  - forall vf in VaultFiles, reg in TypeRegistry, vid in VaultId, (r, ix) in simulate vf emptyIndex (rebuild reg vid), issues in rights [r], i in warnedIds issues
  - |- i in indexedIds ix

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 空 vault:`simulate mempty emptyIndex (rebuild reg vid)` | `(Right [], emptyIndex)`;再跑一次相同 | LAW-1、LAW-2 |
| EX-2 | 一份主題檔 `characters/琳達.md`(主體加兩個片段) | `indexedPaths` 為 `["characters/琳達.md"]`,`indexedNodes` 三個,與逐檔 `indexPath` 相同 | LAW-3、LAW-6 |
| EX-3 | Level 檔有兩個最淺層級的節(`## nod-a` 與 `## nod-b` 同層,兩個根) | 該檔不在 `indexedPaths`,issues 含 `TreeInvalid`(`MultipleRoots`);同 vault 另一份主題檔照進 | LAW-6 |
| EX-4 | 兩份 pack 檔各有一個 asset,邏輯名稱同為 `ui_gui_frame_001`,路徑字母序 `a/pack.md` 在前 | 只有 `a/pack.md` 在索引,issues 含 `DuplicateAssetName "b/pack.md"`;`assetNames` 只有一個 | LAW-8 |
| EX-5 | 主題檔的 `type` 是註冊表沒有的 `ghost` | issues 含 `MetaWarningsFound`,該節點 id 仍在 `indexedIds` | LAW-12 |
| EX-6 | 重建後把 `lore/history.md` 的正文改一字並讓 size 變 | `refresh` 後的索引與對新 vault 從空重建相同;issues 為 `Right []` | LAW-5 |
| EX-7 | `disk` 有 a(指紋 1)、b(指紋 2)、c;`rec` 有 a(指紋 1)、b(指紋 9)、d | `staleFiles disk rec == (["b", "c"], ["d"])` | LAW-11 |
| EX-8 | `indexDocument reg vid "x.md" st "---\nid: [broken"` | `Left (ParseFailed …)`,不拋例外 | LAW-9 |
| EX-9 | 主題檔 frontmatter 寫 `vault: vlt-00000000`,重建時 vid 為 `vlt-7f3b2a91` | 索引裡該節點 `metaVault` 為 `vlt-7f3b2a91` | LAW-7 |
| EX-10 | `staleFiles m m`,m 有三個檔 | `([], [])` | LAW-10 |
| EX-11 | 重建後不動任何檔再 `refresh` | `(Right [], ix1)` | LAW-4 |

## 決定
- **兩個效果 `VaultFs` 與 `Index`,各配純解譯器;`rebuild` / `refresh` / `indexPath` 是效果程式,不碰 IO。** 否決:保留 `rebuildIndex` 的 IO 本體當唯一實作。理由:里程碑的端到端 law 要在純解譯器上跑,qa 不碰 sqlite 與檔案系統。證據:ADR-023-effectful-effects-layer、SPK-001-effectful
- **`FileIndex` 只裝圖譜事實(節點、包含關係、文件種類、指紋),FTS 列由解譯器呼叫 P-027-fts-tokenize 推導。** 否決:`FileIndex` 帶 FTS 列。理由:types 層不能 import pure 層的分詞器;搜尋的純參考實作在 P-002-search 直接對節點文字做
- **整檔替換,不逐節 diff:一份 `.md` 的節點一起進退。** 否決:算出哪一節被改。理由:正確性遠比省那點成本重要,檔案級重索引本來就便宜
- **單檔解析或樹驗證失敗只進 `IndexIssue`,不中斷整批;`StoreError`(sqlite)才中止。** 否決:任何失敗都中止。理由:作者手改壞一份檔不該讓整個索引建不起來
- **邏輯名稱撞名時整檔回滾,路徑字母序先到者保留名字。** 否決:逐 asset 略過。理由:與解析失敗同一個「整檔要嘛全進要嘛不進」模型,不另發明部分成功
- **每個節點的 `metaVault` 由呼叫端給的 `VaultId` 回填,不逐列存 frontmatter 的 `vault:`。** 否決:信檔案。理由:vault 的身分是 marker 裡的 id(ADR-017),檔案搬到別的 vault 不該帶著舊身分
- **警告不擋:`checkMeta` 的結果進 `MetaWarningsFound`,節點照進索引。** 否決:有警告就不進。理由:`checkMeta` 的契約是只回警告
- **shell 的 sqlite 解譯器每個檔一個短交易,解析全部在交易外(ADR-022)。** 否決:整個 vault 一個大交易。理由:寫鎖持有時間以毫秒計
- **套件內以純解譯器驗 rm index.db 等價即為 S1 驗收;真 vault 的端到端另由 contract 套件承接。** 否決:S1 就合成 6,783 筆的大 fixture。理由:等價是純性質,規模是效能題
- **cabal 的模組可見度不寫成 law,交給模組表與 `lint boundary`;`BoundarySpec` 留作內部測試。** 否決:把 exposed-modules 清單寫成 `|-` 行。理由:那是關於檔案的斷言,不是任何 stage 的性質

## 修訂記錄
- REV-1(2026-09-06,依 qa 提問 GAP-1「兩份 pack 撞名的 vault 上,LAW-6 的左邊是 False、右邊是 True」與 GAP-2「EX-8 的 `Left (ParseFailed …)` 不是 `StoreError` 的建構子」,以及 impl 對 P-002-search 提的「effects 層的純解譯器不得 import pure 層的參考實作」):第 11 列 `indexDocument` 的錯誤型別改成 `IndexIssue`(單檔純核心的失敗就是一則索引問題,與第 16 列「解析失敗的檔回 issues」同一語彙);LAW-6 改成雙條件並加觀察點 `clashesEarlier`,把「撞名回滾」的決定寫進 law;觀察點 `runIndexPure` 依 rules/boundary.md「效果的判定」(純解譯器住 effects 或 pure)搬到 pure 層的 `Aapms.Store.Simulate`,簽名不變
  - 動到:Stages 第 11 列、觀察點 `runIndexPure` 的模組與層、觀察點 `clashesEarlier`(新增)、LAW-6
  - 保護:LAW-1 到 LAW-5、LAW-7 到 LAW-12
  - 重委派:qa(LAW-6、EX-8);impl 尚未派,骨架簽名由 conductor 同步
- REV-2(2026-09-06,依 impl 回報「EX-3 的『以自己為 parent(成環)』在已 frozen 的 P-025-md-document 裡造不出來:`toLevel` 依 ADR-009 由標題階層推導 parent,`Cycle` 在這條流上不可達」;conductor 歸因為 example 寫錯):EX-3 的輸入改成可達的樹違規——兩個最淺層級的節(`MultipleRoots`),後件不變
  - 動到:EX-3
  - 保護:LAW-1 到 LAW-12、其餘 EX
  - 重委派:qa(EX-3)
- REV-3(2026-09-06,依 store shell 波與 P-003 波之後的盤點:第 17 列 `refresh` 只有純的整條,沒有 shell 進入點,開 vault 時的過時刷新仍走舊 `Aapms.Store.Index.refreshStale` 的直接 IO 路徑,等於同一件事兩份實作):加 `!` 列 `refreshIndex`,接到第 17 列;舊路徑退場
  - 動到:Stages 加一列 `!`(`refreshIndex`)
  - 保護:LAW-1 到 LAW-12、全部 EX
  - 重委派:impl(`refreshIndex` 與呼叫端改接);qa 無(`!` 列不入 law)
