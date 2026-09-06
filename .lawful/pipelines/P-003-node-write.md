---
id: P-003
description: 寫入請求經樂觀鎖、位元組保留的 Markdown 編輯、寫檔前驗證、原子寫入、單檔重索引,回新 revision
status: ready
updated: 2026-09-06
---
# P-003-node-write:寫入請求經樂觀鎖、位元組保留的 Markdown 編輯、寫檔前驗證、原子寫入、單檔重索引,回新 revision

## Brief
把一個對圖譜的寫入請求落到 Markdown 檔並讓索引跟上,守住「檔案是真相、未改區塊逐位元組不動、樂觀鎖必填」(ADR-002、ADR-010、ADR-013)。input 是一個 `WriteOp`(建主題檔 / 建 Level 檔 / 建 pack 檔 / 增節 / 刪節點 / 改 Meta / 改 asset 人給欄位 / 改正文 / 加關聯 / 刪關聯 / 更新授權,十一種請求一個 sum type,每種要動既有節點的都帶 expected revision);output 是 `WriteOutcome`(新 revision、落地路徑、附帶的 `IndexIssue`)。流向:在索引裡定位節點所在檔案與錨點 → 重讀檔案 → 比對 revision → 純函數編輯 Document(只重新序列化被改的那一段)→ 寫檔前驗證(Level 樹)→ 原子寫入 → 只重索引那一份檔。整條是效果程式:`VaultFs` 多了寫檔與探測存在的操作,`Index` 多了定位、被引用查詢與配號碰撞查詢,`Clock` 給時間;純解譯器跑在記憶體上,law 全在純解譯器上驗。真解譯器住 shell,`applyWriteIO` 是唯一進入點,原本的十二個 `IO` 函數(`createTopicFile` … `allocateId`)退成它的薄包裝。它是 S1 的第三條里程碑。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `locateId :: Index :> es => Id -> Eff es (Maybe Located)` | 在索引裡找節點所在檔、錨點(檔案層主體為 Nothing)與文件種類 | `Aapms.Store.Effect.Index`(願望) | effects |
| 2 | `readMarkdown :: VaultFs :> es => FilePath -> Eff es (Either StoreError Text)` | 重讀目標檔全文(樂觀鎖的來源是檔案,不是索引) | `Aapms.Store.Effect.VaultFs`(願望,見 P-001-index-rebuild) | effects |
| 3 | `parseDocument :: Text -> Either MdError Document` | 切成分節文件 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 4 | `checkRevision :: Id -> Revision -> Revision -> Either StoreError ()` | expected 與檔案裡的 revision 不符即拒 | `Aapms.Store.Editing`(願望,自 Aapms.Store.Edit 搬出) | pure |
| 5 | `currentMetaAt :: FilePath -> DocKind -> Id -> Maybe Id -> Document -> Either StoreError Meta` | 從文件讀出目標目前的 Meta | `Aapms.Store.Editing`(願望,自 Aapms.Store.Edit 搬出) | pure |
| 6 | `currentAssetAt :: FilePath -> Id -> Document -> Either StoreError Asset` | 從 pack 檔讀出目標 asset 目前的欄位 | `Aapms.Store.Editing`(願望,自 Aapms.Store.Edit 搬出) | pure |
| 7 | `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | 改一節的 meta 區塊,其餘不動 | `Aapms.Md.Render`(見 P-026-md-edit) | pure |
| 8 | `appendSection :: NewSection -> Document -> Either MdError Document` | 檔尾追加一節 | `Aapms.Md.Render`(見 P-026-md-edit) | pure |
| 9 | `insertSection :: Id -> NewSection -> Document -> Either MdError Document` | 插在父節點的子樹之後 | `Aapms.Md.Render`(見 P-026-md-edit) | pure |
| 10 | `renderDocument :: Document -> Text` | 位元組保留地重組全文 | `Aapms.Md.Render`(見 P-025-md-document) | pure |
| 11 | `headingDepthFor :: FilePath -> Document -> Id -> Either StoreError Int` | 父節點的標題層級加一;不存在回 SectionMissing、超過 6 回 NodeDepthExceeded | `Aapms.Store.Node` | pure |
| 12 | `subtreeIds :: Document -> Id -> [Id]` | 一個節點連同子樹的 id,依文件順序 | `Aapms.Store.Node` | pure |
| 13 | `isRootNode :: FilePath -> Document -> Id -> Either StoreError Bool` | 是不是 Level 檔的根;不存在回 SectionMissing | `Aapms.Store.Node` | pure |
| 14 | `validateLevelDoc :: FilePath -> Document -> Either StoreError ()` | 寫檔前驗證:toLevel 成功且 buildTree 合法 | `Aapms.Store.Node` | pure |
| 15 | `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | Level 樹驗證 | `Aapms.Core.Tree`(見 P-024-level-tree) | pure |
| 16 | `sanitizeFileName :: Text -> Text -> Text` | 標題變成合法檔名,清空時退回第二參數 | `Aapms.Store.Editing`(願望,自 Aapms.Store.Create 搬出) | pure |
| 17 | `lookupDir :: TypeRegistry -> TypeKey -> Maybe FilePath` | 型別的落地目錄 | `Aapms.Core.Registry`(見 P-021-registry-build) | types |
| 18 | `fileExists :: VaultFs :> es => FilePath -> Eff es Bool` | 找空檔名時探測 | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 19 | `idTaken :: Index :> es => Id -> Eff es Bool` | 配號的碰撞查詢 | `Aapms.Store.Effect.Index`(願望) | effects |
| 20 | `referrers :: Index :> es => [Id] -> Eff es [(Id, Link)]` | 指向這些節點的關聯(來源 id、關聯),刪除前的被引用檢查 | `Aapms.Store.Effect.Index`(願望) | effects |
| 21 | `now :: Clock :> es => Eff es UTCTime` | 配號與 updated 欄的時間 | `Aapms.Store.Effect.Clock`(願望) | effects |
| 22 | `allocateFreshId :: Index :> es => IdPrefix -> Text -> UTCTime -> Eff es (Either StoreError Id)` | 同一個 t 之下以 salt 遞增重試到不撞號;碰撞查詢失敗即失敗 | `Aapms.Store.Editing`(願望) | pure |
| 23 | `planEdit :: TypeRegistry -> UTCTime -> Located -> Document -> WriteOp -> Either StoreError (Document, WriteOutcome)` | 既有檔的純核心:4 → 5 / 6 → 7 / 8 / 9 / 11..14 → 新 Document 與結果;失敗即 Left,文件不動 | `Aapms.Store.Editing`(願望) | pure |
| 24 | `planCreate :: TypeRegistry -> VaultId -> UTCTime -> Id -> WriteOp -> Either StoreError (FilePath, Document, WriteOutcome)` | 建新檔的純核心:落點目錄 17 → 檔名 16 → newDocument;Level 檔含唯一根 Node | `Aapms.Store.Editing`(願望) | pure |
| 25 | `writeMarkdown :: VaultFs :> es => FilePath -> Text -> Eff es (Either StoreError ())` | 原子寫入(真解譯器:暫存檔 + rename) | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 26 | `deleteMarkdown :: VaultFs :> es => FilePath -> Eff es (Either StoreError ())` | 刪整份檔(刪除檔案層主體時) | `Aapms.Store.Effect.VaultFs`(願望) | effects |
| 27 | `indexPath :: (VaultFs :> es, Index :> es) => TypeRegistry -> VaultId -> FilePath -> Eff es (Either StoreError [IndexIssue])` | 寫完只重索引這一份檔 | `Aapms.Store.Indexing`(願望,見 P-001-index-rebuild) | pure |
| 28 | `removeFile :: Index :> es => FilePath -> Eff es ()` | 刪檔後移除它的索引記錄 | `Aapms.Store.Effect.Index`(願望,見 P-001-index-rebuild) | effects |
| o | `runClockPure :: UTCTime -> Eff (Clock : es) a -> Eff es a` | 觀察:固定時間的純解譯器 | `Aapms.Store.Effect.Clock`(願望) | effects |
| o | `simulateWrite :: UTCTime -> VaultFiles -> IndexState -> Eff '[VaultFs, Index, Clock] a -> WriteRun a` | 觀察:三個純解譯器串起來跑到底,回結果、最終檔案表、最終索引 | `Aapms.Store.Editing.Internal`(願望) | pure |
| o | `runResult :: WriteRun a -> a` | 觀察:結果 | `Aapms.Store.Types`(願望) | types |
| o | `runFiles :: WriteRun a -> VaultFiles` | 觀察:最終檔案表 | `Aapms.Store.Types`(願望) | types |
| o | `runIndex :: WriteRun a -> IndexState` | 觀察:最終索引 | `Aapms.Store.Types`(願望) | types |
| o | `opTarget :: WriteOp -> Maybe Id` | 觀察:請求要動的既有節點(建檔類為 Nothing) | `Aapms.Store.Types`(願望) | types |
| o | `opRevision :: WriteOp -> Maybe Revision` | 觀察:請求帶的 expected revision | `Aapms.Store.Types`(願望) | types |
| o | `isInsertOp :: WriteOp -> Bool` | 觀察:是不是會插入新節的請求(增節、建檔) | `Aapms.Store.Types`(願望) | types |
| o | `outcomeRevision :: WriteOutcome -> Revision` | 觀察:結果的新 revision | `Aapms.Store.Types`(願望) | types |
| o | `outcomePath :: WriteOutcome -> FilePath` | 觀察:結果落地的檔 | `Aapms.Store.Types`(願望) | types |
| o | `outcomeId :: WriteOutcome -> Id` | 觀察:結果的節點 id(建檔為新檔主體) | `Aapms.Store.Types`(願望) | types |
| o | `removedIds :: WriteOutcome -> [Id]` | 觀察:刪除結果消失的 id | `Aapms.Store.Types`(願望) | types |
| o | `brokenLinks :: WriteOutcome -> [(Id, Link)]` | 觀察:刪除結果列出的斷點 | `Aapms.Store.Types`(願望) | types |
| o | `documentAt :: VaultFiles -> FilePath -> Maybe Document` | 觀察:記憶體 vault 裡某檔解析後的文件 | `Aapms.Store.Types`(願望) | types |
| o | `sectionBytes :: VaultFiles -> FilePath -> [(Id, Text)]` | 觀察:某檔每一節渲染後的位元組 | `Aapms.Store.Types`(願望) | types |
| o | `locatedFile :: IndexState -> Id -> Maybe FilePath` | 觀察:索引裡節點所在檔 | `Aapms.Store.Types`(願望) | types |
| o | `metaAt :: VaultFiles -> IndexState -> Id -> Maybe Meta` | 觀察:從檔案重讀節點目前的 Meta | `Aapms.Store.Types`(願望) | types |
| o | `assetAt :: VaultFiles -> IndexState -> Id -> Maybe Asset` | 觀察:從 pack 檔重讀 asset 目前的欄位 | `Aapms.Store.Types`(願望) | types |
| o | `licensesAt :: VaultFiles -> [License]` | 觀察:licenses.md 解出的授權清單 | `Aapms.Store.Types`(願望) | types |
| o | `assetIdsAt :: VaultFiles -> FilePath -> [Id]` | 觀察:某 pack 檔的 asset id 依文件順序 | `Aapms.Store.Types`(願望) | types |
| o | `packAt :: VaultFiles -> FilePath -> Maybe Pack` | 觀察:某 pack 檔的檔案層 Pack | `Aapms.Store.Types`(願望) | types |
| o | `levelAt :: VaultFiles -> FilePath -> Maybe (Level, [Node])` | 觀察:某 Level 檔解出的場景與節點 | `Aapms.Store.Types`(願望) | types |
| o | `packFields :: Pack -> PackFields` | 觀察:pack 七個專屬欄位 | `Aapms.Store.Types`(願望) | types |
| o | `newPackFields :: NewPack -> PackFields` | 觀察:請求裡的同七欄 | `Aapms.Store.Types`(願望) | types |
| o | `patchedName :: AssetPatch -> Maybe LogicalName -> Maybe LogicalName` | 觀察:三態補丁套在舊值上 | `Aapms.Store.Types`(願望) | types |
| o | `fileStatsOf :: IndexState -> [(FilePath, FileStat)]` | 觀察:索引記錄的每檔指紋 | `Aapms.Store.Types`(願望) | types |
| o | `levelOf :: Document -> Maybe (Level, [Node])` | 觀察:Level 檔文件解出的場景與節點 | `Aapms.Store.Types`(願望) | types |
| o | `lvlRoot :: Level -> Id` | 觀察:Level 的根 Node id | `Aapms.Core.Level` | types |
| o | `stripStamps :: Text -> Text` | 觀察:去掉 revision 與 updated 兩行 | `Aapms.Store.Types`(願望) | types |
| o | `allocateN :: Int -> IdPrefix -> Text -> UTCTime -> IndexState -> [Id]` | 觀察:同一個 t 連續配 n 次、每次寫進索引後拿到的 id | `Aapms.Store.Editing.Internal`(願望) | pure |
| = | `applyWrite :: (VaultFs :> es, Index :> es, Clock :> es) => TypeRegistry -> VaultId -> WriteOp -> Eff es (Either StoreError WriteOutcome)` | 純的整條:1 → 2 → 3 → 23 或 22 → 24 → 14 → 25 / 26 → 27 / 28 | `Aapms.Store.Editing`(願望) | pure |
| ! | `applyWriteIO :: VaultHandle -> WriteOp -> IO (Either StoreError WriteOutcome)` | 進入點:以 handle 的根目錄、連線與系統時鐘跑真解譯器 | `Aapms.Store.Write`(願望) | shell |

## Laws
- LAW-1 [relation] 樂觀鎖:expected revision 與檔案裡的不符即拒,檔案與索引都不動
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, op in WriteOp, i in Id, r in Revision, m in Meta, run in simulateWrite t vf ix (applyWrite reg vid op)
  - given opTarget op == Just i and opRevision op == Just r and metaAt vf ix i == Just m and r /= metaRevision m
  - |- runResult run == Left (RevisionMismatch i r (metaRevision m)) and runFiles run == vf and runIndex run == ix
- LAW-2 [relation] 成功時 revision 恰好加一,且重讀檔案得到的 revision 等於回傳的
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, op in WriteOp, i in Id, n in Int, run in simulateWrite t vf ix (applyWrite reg vid op), o in rights [runResult run]
  - given opTarget op == Just i and opRevision op == Just (Revision n)
  - |- outcomeRevision o == Revision (n + 1) and fmap metaRevision (metaAt (runFiles run) (runIndex run) i) == Just (Revision (n + 1))
- LAW-3 [invariant] 位元組保留:不插入新節的請求成功後,目標節以外每一節的位元組不變(ADR-010)
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, op in WriteOp, i in Id, p in FilePath, run in simulateWrite t vf ix (applyWrite reg vid op)
  - given opTarget op == Just i and not (isInsertOp op) and locatedFile ix i == Just p and isRight (runResult run)
  - |- filter ((/= i) . fst) (sectionBytes (runFiles run) p) == filter ((/= i) . fst) (sectionBytes vf p)
- LAW-4 [invariant] 改 asset 人給欄位不動唯讀欄位:sha256、entry、ext、kind meta、正文
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, r in Revision, patch in AssetPatch, a in Asset, run in simulateWrite t vf ix (applyWrite reg vid (WriteAssetFields i r patch)), a2 in maybe [] pure (assetAt (runFiles run) (runIndex run) i)
  - given assetAt vf ix i == Just a and isRight (runResult run)
  - |- astSha256 a2 == astSha256 a and astEntry a2 == astEntry a and astExt a2 == astExt a and astKindMeta a2 == astKindMeta a and astBody a2 == astBody a
- LAW-5 [relation] AssetPatch 三態:Nothing 不動、Just v 設成 v
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, r in Revision, patch in AssetPatch, a in Asset, run in simulateWrite t vf ix (applyWrite reg vid (WriteAssetFields i r patch))
  - given assetAt vf ix i == Just a and isRight (runResult run)
  - |- fmap astName (assetAt (runFiles run) (runIndex run) i) == Just (patchedName patch (astName a))
- LAW-6 [roundtrip] 先加關聯再刪同一條,節點的關聯與檔案位元組(去掉 revision 與 updated 兩行)回到原狀
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, n in Int, l in Link, m in Meta, p in FilePath, run1 in simulateWrite t vf ix (applyWrite reg vid (AddLink i (Revision n) l)), run2 in simulateWrite t (runFiles run1) (runIndex run1) (applyWrite reg vid (RemoveLink i (Revision (n + 1)) l))
  - given metaAt vf ix i == Just m and metaRevision m == Revision n and notElem l (metaLinks m) and locatedFile ix i == Just p and isRight (runResult run1)
  - |- fmap metaLinks (metaAt (runFiles run2) (runIndex run2) i) == Just (metaLinks m) and fmap stripStamps (fmap snd (lookup p (toList (runFiles run2)))) == fmap stripStamps (fmap snd (lookup p (toList vf)))
- LAW-7 [relation] 刪不存在的關聯:回 LinkNotFound 且不寫檔
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, l in Link, m in Meta, run in simulateWrite t vf ix (applyWrite reg vid (RemoveLink i (metaRevision m) l))
  - given metaAt vf ix i == Just m and notElem l (metaLinks m)
  - |- runResult run == Left (LinkNotFound i l) and runFiles run == vf
- LAW-8 [roundtrip] 更新授權後重讀相等(除 revision、updated 與全文以外),對同一個 id 做兩次節數不變
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, l in License, run1 in simulateWrite t vf ix (applyWrite reg vid (UpsertLicense l)), run2 in simulateWrite t (runFiles run1) (runIndex run1) (applyWrite reg vid (UpsertLicense l)), l2 in filter ((== metaId (licMeta l)) . metaId . licMeta) (licensesAt (runFiles run1))
  - given isRight (runResult run1)
  - |- licCommercial l2 == licCommercial l and licAttributionRequired l2 == licAttributionRequired l and licCreditText l2 == licCreditText l and licSourceUrl l2 == licSourceUrl l and length (licensesAt (runFiles run2)) == length (licensesAt (runFiles run1))
- LAW-9 [invariant] 建 pack 檔時 asset 節順序等於給定順序
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, np in NewPack, xs in [NewSection], run in simulateWrite t vf ix (applyWrite reg vid (CreatePack np xs)), o in rights [runResult run]
  - |- assetIdsAt (runFiles run) (outcomePath o) == map nsId xs
- LAW-10 [relation] 建主題檔的落點由註冊表決定:型別有 dir 就以它為前綴、以 .md 結尾;沒有就 RegistryDirUnknown 且不寫任何檔
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, ne in NewEntity, run in simulateWrite t vf ix (applyWrite reg vid (CreateTopic ne))
  - given nePath ne == Nothing
  - |- maybe (runResult run == Left (RegistryDirUnknown (neType ne)) and runFiles run == vf) (const (all (isSuffixOf ".md") (map outcomePath (rights [runResult run])))) (lookupDir reg (neType ne))
- LAW-11 [relation] 建 Level 檔產出可解析且樹合法的檔,根就是唯一那個 Node
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, nl in NewLevel, run in simulateWrite t vf ix (applyWrite reg vid (CreateLevel nl)), o in rights [runResult run], (lvl, nodes) in maybe [] pure (levelAt (runFiles run) (outcomePath o))
  - |- length nodes == 1 and isRight (buildTree lvl nodes) and lvlRoot lvl == metaId (nodMeta (head nodes))
- LAW-12 [relation] 檔尾增節:新節排最後,前面每一節位元組不變(唯一例外是插入點前一段補齊的行尾)
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, s in NewSection, p in FilePath, run in simulateWrite t vf ix (applyWrite reg vid (AddSection i AtEnd s)), d0 in maybe [] pure (documentAt vf p), d1 in maybe [] pure (documentAt (runFiles run) p)
  - given locatedFile ix i == Just p and isRight (runResult run)
  - |- sectionIds d1 == sectionIds d0 ++ [nsId s] and map fst (init (sectionBytes (runFiles run) p)) == map fst (sectionBytes vf p) and init (init (sectionBytes (runFiles run) p)) == init (sectionBytes vf p)
- LAW-13 [relation] 父節點下增節:新節排在父的子樹之後,層級等於父加一,與請求裡的 nsLevel 無關;插入點之後每一節位元組不變
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, par in Id, s in NewSection, p in FilePath, run in simulateWrite t vf ix (applyWrite reg vid (AddSection i (UnderParent par) s)), d0 in maybe [] pure (documentAt vf p), d1 in maybe [] pure (documentAt (runFiles run) p), k in [length (subtreeIds d0 par)], j in maybe [] pure (elemIndex par (sectionIds d0)), sec in maybe [] pure (sectionById (nsId s) d1), psec in maybe [] pure (sectionById par d0)
  - given locatedFile ix i == Just p and isRight (runResult run)
  - |- sectionIds d1 == take (j + k) (sectionIds d0) ++ [nsId s] ++ drop (j + k) (sectionIds d0) and secLevel sec == secLevel psec + 1 and drop (j + k + 1) (sectionBytes (runFiles run) p) == drop (j + k) (sectionBytes vf p)
- LAW-14 [relation] 父節點下增節的兩條失敗路徑不寫檔:父不在檔裡回 SectionMissing;父已是第 6 層回 NodeDepthExceeded
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, par in Id, s in NewSection, p in FilePath, run in simulateWrite t vf ix (applyWrite reg vid (AddSection i (UnderParent par) s)), d0 in maybe [] pure (documentAt vf p)
  - given locatedFile ix i == Just p and isLeft (headingDepthFor p d0 par)
  - |- fmap (const ()) (runResult run) == fmap (const ()) (headingDepthFor p d0 par) and runFiles run == vf
- LAW-15 [relation] 刪除:Safe 模式被引用即拒且不動;Force 模式消失集合等於子樹、斷點恰是指向它們的關聯;根 Node 兩種模式都拒
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, r in Revision, p in FilePath, d0 in maybe [] pure (documentAt vf p), victims in [subtreeIds d0 i], runS in simulateWrite t vf ix (applyWrite reg vid (DeleteNode i r DeleteSafe)), runF in simulateWrite t vf ix (applyWrite reg vid (DeleteNode i r DeleteForce)), o in rights [runResult runF]
  - given locatedFile ix i == Just p and isRootNode p d0 i == Right False and fmap metaRevision (metaAt vf ix i) == Just r
  - |- removedIds o == victims and (isLeft (runResult runS) == not (null (brokenLinks o))) and (isLeft (runResult runS) => runFiles runS == vf)
- LAW-16 [relation] 根 Node 刪不得,兩種模式皆然
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, i in Id, r in Revision, mode in DeleteMode, p in FilePath, d0 in maybe [] pure (documentAt vf p), run in simulateWrite t vf ix (applyWrite reg vid (DeleteNode i r mode))
  - given locatedFile ix i == Just p and isRootNode p d0 i == Right True
  - |- runResult run == Left (CannotDeleteRootNode i) and runFiles run == vf
- LAW-17 [invariant] 同一個時間連續配號 n 次全部成功且兩兩相異、前綴正確(salt 遞增是唯一機制)
  - forall n in Int, pre in IdPrefix, c in Text, t in UTCTime, ix in IndexState, ids in [allocateN n pre c t ix]
  - given n >= 0
  - |- length ids == n and nub ids == ids and all ((== pre) . idPrefix) ids
- LAW-18 [invariant] 任何失敗都不動檔案與索引(先寫檔再索引;純解譯器裡索引不會失敗,所以失敗就是全不動)
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, op in WriteOp, run in simulateWrite t vf ix (applyWrite reg vid op)
  - given isLeft (runResult run)
  - |- runFiles run == vf and runIndex run == ix
- LAW-19 [invariant] 成功時索引只重讀目標檔:其他檔的指紋不變
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, op in WriteOp, run in simulateWrite t vf ix (applyWrite reg vid op), o in rights [runResult run]
  - |- filter ((/= outcomePath o) . fst) (fileStatsOf (runIndex run)) == filter ((/= outcomePath o) . fst) (fileStatsOf ix)
- LAW-20 [relation] 建 pack 檔的七個 pack 專屬欄位往返逐欄相等
  - forall t in UTCTime, vf in VaultFiles, ix in IndexState, reg in TypeRegistry, vid in VaultId, np in NewPack, xs in [NewSection], run in simulateWrite t vf ix (applyWrite reg vid (CreatePack np xs)), o in rights [runResult run]
  - |- fmap packFields (packAt (runFiles run) (outcomePath o)) == Just (newPackFields np)
- LAW-21 [relation] 檔名淨化的值域:非法字元換成 -,只由空白與 . 組成才退回第二參數,合法且無頭尾空白與 . 時原樣
  - forall s in Text, fb in Text
  - given not (null fb)
  - |- (all (flip elem [' ', '.']) s => sanitizeFileName s fb == fb) and (not (any (flip elem "<>:\"/\\|?*") s) and not (null s) and notElem (head s) [' ', '.'] and notElem (last s) [' ', '.'] => sanitizeFileName s fb == s)
- LAW-22 [relation] 子樹 id 與標題層級一致:subtreeIds 以自己開頭,其後每一節層級都嚴格大於自己
  - forall d in Document, i in Id, sec in maybe [] pure (sectionById i d), rest in [drop 1 (subtreeIds d i)]
  - |- head (subtreeIds d i) == i and all (maybe False ((> secLevel sec) . secLevel)) (map (flip sectionById d) rest)
- LAW-23 [equiv] 寫檔前驗證等價於兩段:toLevel 成功且 buildTree 合法
  - forall p in FilePath, d in Document
  - |- isRight (validateLevelDoc p d) == maybe False (isRight . uncurry buildTree) (levelOf d)
- LAW-24 [relation] isRootNode 三種結果:是根、不是根、不在檔裡(不在檔裡是 SectionMissing 不是 False)
  - forall p in FilePath, d in Document, i in Id
  - |- (isNothing (sectionById i d)) == (isRootNode p d i == Left (SectionMissing p i))
- LAW-25 [total] 純核心對任何請求與文件都有值,不拋例外
  - forall reg in TypeRegistry, t in UTCTime, loc in Located, d in Document, op in WriteOp
  - |- total (planEdit reg t loc d op)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 檔案裡 `revision: 3`,`WriteMeta i (Revision 2) (emptyOverride { moSummary = Just "x" })` | `Left (RevisionMismatch i (Revision 2) (Revision 3))`,檔案與索引不動 | LAW-1、LAW-18 |
| EX-2 | 同上但 `Revision 3` | `Right`,`outcomeRevision == Revision 4`,重讀 `metaRevision == Revision 4`,其他節位元組不變 | LAW-2、LAW-3 |
| EX-3 | pack 檔 asset `sha256 = "aa…"`,`WriteAssetFields i r (AssetPatch (Just (Just n')) Nothing (Just Nothing) Nothing)` | 重讀 `astName == Just n'`、`astAuthor == Nothing`、`astSha256` 未變、`astLicense` 未變 | LAW-4、LAW-5 |
| EX-4 | 節點 links 不含 l:`AddLink i r l` 再 `RemoveLink i (r+1) l` | links 回到原狀;檔案去掉 revision / updated 兩行後逐位元組相同 | LAW-6 |
| EX-5 | 節點 links 不含 l:`RemoveLink i r l` | `Left (LinkNotFound i l)`,檔案不變 | LAW-7 |
| EX-6 | `UpsertLicense lic`(id `lic-0000000a`)兩次 | 第一次後重讀八欄相等;第二次後 `licenses.md` 節數不變 | LAW-8 |
| EX-7 | `CreatePack np [sA, sB, sC]`(id `ast-0000000a/b/c`) | `assetIdsAt` 為 `[a, b, c]` | LAW-9 |
| EX-8 | 註冊表 `character` 的 dir 是 `characters`,`CreateTopic (neTitle = "琳達", nePath = Nothing)` | `outcomePath == "characters/琳達.md"`,`outcomeRevision == Revision 1`;型別 `ghost` 沒有 dir 時 `Left (RegistryDirUnknown "ghost")` 且不寫檔 | LAW-10 |
| EX-9 | `CreateLevel (nlTitle = "第一章", nlRootTitle = "序幕", nlPath = Nothing)` | `outcomePath == "levels/第一章.md"`,恰一個 Node,`lvlRoot` 等於它,`buildTree` Right | LAW-11 |
| EX-10 | 三節的主題檔,`AddSection i AtEnd s` | `sectionIds` 變成原本三個加 `nsId s`;前三節位元組不變(插入點前一段補齊空行時只差尾端) | LAW-12 |
| EX-11 | Level 檔 `nod-root` > `nod-a` > `nod-a1`,`nod-b`;`AddSection i (UnderParent nod-a) s` | 新節在 `nod-a1` 之後、`nod-b` 之前,層級為 `nod-a` 加一(請求給 `nsLevel = 9` 也一樣);`nod-b` 位元組不變 | LAW-13 |
| EX-12 | `UnderParent nod-zzz`(不在檔裡);`UnderParent nod-deep`(層級 6) | 依序 `Left (SectionMissing p nod-zzz)`、`Left (NodeDepthExceeded nod-deep 7)`,檔案不變 | LAW-14 |
| EX-13 | `nod-a` 被 `ent-x` 以 `involves` 引用:`DeleteNode nod-a r DeleteSafe` 與 `DeleteForce` | Safe 回 `Left (ReferencedBy nod-a _)` 檔案不變;Force 回 `removedIds == [nod-a, nod-a1]`、`brokenLinks == [(ent-x, involves→nod-a)]` | LAW-15 |
| EX-14 | `DeleteNode nod-root r DeleteForce` | `Left (CannotDeleteRootNode nod-root)`,檔案不變 | LAW-16 |
| EX-15 | 固定 t,先把 `newId PEnt "琳達" t 0` 與 salt 1 寫進索引,再 `allocateN 1 PEnt "琳達" t ix` | 恰等於 `newId PEnt "琳達" t 2` | LAW-17 |
| EX-16 | 成功的 `WriteBody` | 索引裡除目標檔外每檔指紋不變 | LAW-19 |
| EX-17 | `CreatePack np [sA]`,np 七欄全給非預設值(vendor Kenney、archive、sha256、license、author、sourceUrl、`AiNone`) | 重讀 `packFields == newPackFields np` | LAW-20 |
| EX-18 | `sanitizeFileName "第一章: 序幕 " fb`、`"   "`、`"..."`、`"<"`、`"<>?"`、`"琳達 的筆記"` | 依序 `"第一章- 序幕"`、`fb`、`fb`、`"-"`、`"---"`、`"琳達 的筆記"` | LAW-21 |
| EX-19 | 四節文件 `nod-root(2) > nod-a(3) > nod-a1(4), nod-b(3)`,`subtreeIds d nod-a` | `[nod-a, nod-a1]`,`nod-a1` 層級 4 > 3 | LAW-22 |
| EX-20 | Level 檔成環(`nod-b` 的 parent 是自己) | `validateLevelDoc` 回 `Left (TreeInvalidOnWrite …)`,與 `buildTree` 的 Left 一致 | LAW-23 |
| EX-21 | `isRootNode p d nod-root`、`nod-a`、`nod-zzz` | `Right True`、`Right False`、`Left (SectionMissing p nod-zzz)` | LAW-24 |
| EX-22 | `planEdit reg t loc d op`,d 是任意亂文件、op 任意 | 求值到底不拋例外 | LAW-25 |

## 決定
- **十一種寫入收成一個 `WriteOp` sum type、一個 `WriteOutcome`、一條進入點;原本十二個 `IO` 函數退成薄包裝。** 否決:每個函數各自一條 pipeline、或各自一列 `!`。理由:里程碑恰好一列 `!`,而它們走的是同一條紀律(定位 → 重讀 → 樂觀鎖 → 純編輯 → 驗證 → 寫檔 → 單檔索引);sum type 讓 shell 的三個殼(CLI / HTTP / MCP)對同一個請求型別編解碼。證據:ADR-023-effectful-effects-layer
- **`WriteMeta` 帶 `MetaOverride` 值(合併語意:Just 的欄位覆蓋),不再帶 `MetaOverride -> MetaOverride` 函數。** 否決:保留函數參數。理由:請求要能序列化、能比較、能被產生器縮小;任意函數三者都做不到,而 service 的 `NodePatch` 本來就是資料
- **寫入順序固定「檔案 → 索引」,不做兩段式提交;索引失敗回 `IndexUpdateFailed` 明說資料已寫入。** 否決:先索引再寫檔、或跨檔案 IO 的 SQLite 交易。理由:索引是衍生物(ADR-013),寫鎖不得跨檔案 IO(ADR-022)
- **樂觀鎖的來源是重讀的檔案,不是索引。** 否決:比對索引裡的 revision。理由:作者用編輯器直接改過而索引還沒 refresh 時,索引會放行一次覆蓋
- **`AssetPatch` 型別上就不含 sha256 / entry / ext / kind meta;要換位元組就刪節再增節。** 否決:執行期回 `AssetFieldReadOnly`。理由:型別層拒絕不必記得補檢查
- **`DeleteSafe` 被引用即拒、`DeleteForce` 刪並列出斷點,不自動改寫來源檔。** 否決:連帶改寫所有來源檔。理由:多檔寫入沒有交易保證
- **`UpsertLicense` 的 expected revision 取自傳入 `License` 自己的 `metaRevision`。** 否決:多收一個參數。理由:完整的 License 本來就帶著 revision
- **`allocateId` 帶失敗通道:碰撞查詢失敗即失敗,不靜默照發;時間是明碼參數。** 否決:查詢失敗視同查不到。理由:未經碰撞檢查的 id 一旦落地,只能等 `rebuildIndex` 撞主鍵才發現(原 F008 GAP-8 裁決)
- **增節落點是封閉 sum `SectionPlacement`;`UnderParent` 的層級由 `headingDepthFor` 推導,不看請求的 `nsLevel`。** 否決:`Maybe Id`。理由:標題階層即樹(ADR-009),父子關係只有一個真相來源
- **插入點前一段的行尾補齊是唯一允許的「非目標節位元組變動」,`blankTail` 冪等。** 否決:無條件全稱。理由:被動到的是插入點不是未修改區塊(原 F008 GAP-14 裁決)
- **`isRootNode` 對不在檔裡的 id 回 `SectionMissing`,不是 `Right False`。** 否決:合一。理由:與 `headingDepthFor` 對稱,錯誤不往下游飄(原 GAP-9)
- **`sanitizeFileName` 非法字元替換成 `-`,只有全空白與 `.` 才退回 fallback。** 否決:移除非法字元。理由:EX-18 的逐字例子是權威(原 GAP-13)
- **`StoreError` 是 store 唯一的錯誤型別,每則訊息含以「請」起頭的下一步;`SqliteError` 的訊息已改成「請嘗試重新開啟 vault」。** 否決:寫入路徑自己一個錯誤型別。理由:三個殼只看一組 code 與訊息;這條由 `Aapms.Store.Types` 的內部測試守,不掛 law(訊息是中文字面,寫不進 ASCII 的 `|-` 行)
- **ADR-022 寫鎖預算的結構約束(寫入模組不開 `withTransaction`、只有定位與配號碰 sqlite)住 shell 解譯器,由內部測試與人工檢查守。** 否決:寫成 law。理由:它是原始碼結構,不是可觀察行為(原 F008 GAP-12)
- **建 pack 檔的七個 pack 專屬欄位往返是 law(LAW-20),不能只靠實作記得寫。** 否決:只驗路徑與節順序。理由:pack.md 是素材中繼資料的真相(ADR-013),原 F008 GAP-17 就是沒人在看才漏掉

## 修訂記錄
無
