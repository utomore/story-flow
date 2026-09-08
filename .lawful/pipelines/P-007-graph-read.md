---
id: P-007
description: Ref / NodeFilter 經範圍解析、跨 vault 查詢、checkMeta 警告投影成每筆帶 vault 的 NodeView / Page / LinkReport
status: ready
updated: 2026-09-06
---
# P-007-graph-read:Ref / NodeFilter 經範圍解析、跨 vault 查詢、checkMeta 警告投影成每筆帶 vault 的 NodeView / Page / LinkReport

## Brief
service 的讀取契約:把 graph-core 讀回來的 `AnyNode` 投影成三個殼共用的 `NodeView`(每筆帶 vault、檔案路徑、錨點、警告、依種類展開的 detail),並提供五個讀取操作(取一個節點、分頁列節點、子節點、關聯報告、全文搜尋)。input 是 `ReadOp` 請求與本次讀取範圍(P-004 開場、P-029 裁決出來的 vault 集合與預設 vault);output 是 `ReadResult`。流向:解析 Ref(不帶 vault 的 Ref 在範圍內命中多個 vault 回 AmbiguousRef、一個都沒有回 NodeNotFound)→ 對命中的 vault 查節點、所在檔與錨點 → `checkMeta` 只產警告 → 投影成 NodeView;列節點走 P-002 的 `filterNodes` 再分頁,總數不受分頁影響;關聯報告的出邊解不到回 Nothing 不擋;搜尋走 P-002 的 `searchVaults` 再逐筆投影。整條是 `Vaults` 效果的程式,不寫任何東西;純解譯器跑在記憶體的索引集合上。真解譯器住 shell,`runRead` 是進入點,ServiceM 的 `getNode` / `pageNodes` / `childrenView` / `linksOf` / `searchView` 是它的薄包裝。它讓 O-1 的 M-4 往前一步,對應原 service F003 與 F007。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `vaultIds :: Vaults :> es => Eff es [VaultId]` | 本次讀取範圍 | `Aapms.Store.Effect.Vaults`(願望,見 P-002-search) | effects |
| 2 | `inVault :: Vaults :> es => VaultId -> Eff '[Index] a -> Eff es (Maybe a)` | 對某個 vault 跑一段 Index 程式 | `Aapms.Store.Effect.Vaults`(願望,見 P-002-search) | effects |
| 3 | `nodeById :: Index :> es => Id -> Eff es (Maybe AnyNode)` | 一個 vault 內以 id 取節點(含正文,從檔案重讀) | `Aapms.Store.Effect.Index`(願望) | effects |
| 4 | `locateId :: Index :> es => Id -> Eff es (Maybe Located)` | 節點所在檔與錨點 | `Aapms.Store.Effect.Index`(願望,見 P-003-node-write) | effects |
| 5 | `filterNodes :: Index :> es => NodeFilter -> Eff es [IndexedNode]` | 一個 vault 內符合結構條件的全部節點,不分頁 | `Aapms.Store.Effect.Index`(願望,見 P-002-search) | effects |
| 6 | `childrenIn :: Index :> es => Id -> Eff es [AnyNode]` | 一個 vault 內 owner 是它的節點:pack 的 asset、主體的片段 | `Aapms.Store.Effect.Index`(願望) | effects |
| 7 | `referrers :: Index :> es => [Id] -> Eff es [(Id, Link)]` | 指向這些節點的關聯(入邊) | `Aapms.Store.Effect.Index`(願望,見 P-003-node-write) | effects |
| 8 | `resolveRef :: Vaults :> es => ReadCtx -> Ref -> Eff es (Either ServiceError (VaultId, AnyNode))` | 帶 vault 的只認那個 vault;不帶的先看預設 vault、再看範圍內每個 vault:多個命中 AmbiguousRef、零命中 NodeNotFound | `Aapms.Service.Read`(願望) | pure |
| 9 | `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` | 只產警告 | `Aapms.Core.Registry.Build`(見 P-021-registry-build) | pure |
| 10 | `toNodeView :: TypeRegistry -> VaultId -> Located -> AnyNode -> NodeView` | 投影:vault、Meta 原樣、路徑、錨點、警告、依建構子展開的 detail | `Aapms.Service.Read`(願望) | pure |
| 11 | `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | Level 帶樹時建樹 | `Aapms.Core.Tree`(見 P-024-level-tree) | pure |
| 12 | `preorder :: NodeTree -> [Node]` | 樹的前序 | `Aapms.Core.Tree`(見 P-024-level-tree) | pure |
| 13 | `treeView :: TypeRegistry -> VaultId -> (Id -> Maybe Located) -> NodeTree -> NodeTreeView` | 樹逐節點投影 | `Aapms.Service.Read`(願望) | pure |
| 14 | `pageOf :: NodeFilter -> [NodeView] -> Page NodeView` | 分頁:pgTotal 是全部筆數,pgItems 是切窗 | `Aapms.Service.Read`(願望) | pure |
| 15 | `searchVaults :: Vaults :> es => SearchQuery -> Eff es SearchResult` | 全文搜尋 | `Aapms.Store.Search`(願望,見 P-002-search) | pure |
| 16 | `toSearchView :: [(SearchHit, NodeView)] -> Int -> Maybe FacetCounts -> SearchView` | 命中逐筆配上 NodeView | `Aapms.Service.Read`(願望) | pure |
| 17 | `linkReport :: [(Link, Maybe NodeView)] -> [(NodeView, Link)] -> LinkReport` | 出邊(目標解不到為 Nothing)與入邊 | `Aapms.Service.Read`(願望) | pure |
| o | `simulateVaults :: Map VaultId IndexState -> Eff '[Vaults] a -> a` | 觀察:純解譯器跑到底 | `Aapms.Store.Search.Internal`(願望,見 P-002-search) | pure |
| o | `hitsOf :: Map VaultId IndexState -> [VaultId] -> Id -> [VaultId]` | 觀察:範圍內哪些 vault 有這個 id | `Aapms.Store.Types`(願望) | types |
| o | `nodeIn :: Map VaultId IndexState -> VaultId -> Id -> Maybe AnyNode` | 觀察:某 vault 裡某 id 的節點 | `Aapms.Store.Types`(願望) | types |
| o | `childrenOfIn :: Map VaultId IndexState -> VaultId -> Id -> [AnyNode]` | 觀察:某 vault 裡 owner 是它的節點 | `Aapms.Store.Types`(願望) | types |
| o | `structuralKeys :: Map VaultId IndexState -> NodeFilter -> [(VaultId, Id)]` | 觀察:逐 vault 用結構條件篩出的 (vault, id) | `Aapms.Store.Search.Internal`(願望,見 P-002-search) | pure |
| o | `rcRegistry :: ReadCtx -> TypeRegistry` | 觀察:讀取情境的註冊表 | `Aapms.Service.Types`(願望) | types |
| o | `rcVaults :: ReadCtx -> [VaultId]` | 觀察:讀取範圍 | `Aapms.Service.Types`(願望) | types |
| o | `rcDefault :: ReadCtx -> Maybe VaultId` | 觀察:不帶 vault 的 Ref 先看的那個 | `Aapms.Service.Types`(願望) | types |
| o | `nvVault :: NodeView -> VaultId` | 觀察:所在 vault | `Aapms.Service.Types`(願望) | types |
| o | `nvMeta :: NodeView -> Meta` | 觀察:Meta 原樣 | `Aapms.Service.Types`(願望) | types |
| o | `nvWarnings :: NodeView -> [MetaWarning]` | 觀察:警告 | `Aapms.Service.Types`(願望) | types |
| o | `nvDetail :: NodeView -> NodeDetail` | 觀察:依種類展開的 detail | `Aapms.Service.Types`(願望) | types |
| o | `detailPrefix :: NodeDetail -> IdPrefix` | 觀察:detail 建構子對應的 id 前綴 | `Aapms.Service.Types`(願望) | types |
| o | `detailTree :: NodeDetail -> Maybe NodeTreeView` | 觀察:Level detail 的樹 | `Aapms.Service.Types`(願望) | types |
| o | `treeIds :: NodeTreeView -> [Id]` | 觀察:樹的前序 id | `Aapms.Service.Types`(願望) | types |
| o | `pgItems :: Page NodeView -> [NodeView]` | 觀察:本頁 | `Aapms.Service.Types`(願望) | types |
| o | `pgTotal :: Page NodeView -> Int` | 觀察:總數 | `Aapms.Service.Types`(願望) | types |
| o | `lrOut :: LinkReport -> [(Link, Maybe NodeView)]` | 觀察:出邊 | `Aapms.Service.Types`(願望) | types |
| o | `lrIn :: LinkReport -> [(NodeView, Link)]` | 觀察:入邊 | `Aapms.Service.Types`(願望) | types |
| o | `svHits :: SearchView -> [SearchHitView]` | 觀察:命中 | `Aapms.Service.Types`(願望) | types |
| o | `svTotal :: SearchView -> Int` | 觀察:總數 | `Aapms.Service.Types`(願望) | types |
| o | `svFacets :: SearchView -> Maybe FacetCounts` | 觀察:facet | `Aapms.Service.Types`(願望) | types |
| o | `shvNode :: SearchHitView -> NodeView` | 觀察:命中的節點 | `Aapms.Service.Types`(願望) | types |
| o | `shvScore :: SearchHitView -> Double` | 觀察:分數 | `Aapms.Service.Types`(願望) | types |
| o | `resultNode :: ReadResult -> Maybe NodeView` | 觀察:單節點結果 | `Aapms.Service.Types`(願望) | types |
| o | `resultPage :: ReadResult -> Maybe (Page NodeView)` | 觀察:分頁結果 | `Aapms.Service.Types`(願望) | types |
| o | `resultNodes :: ReadResult -> Maybe [NodeView]` | 觀察:子節點結果 | `Aapms.Service.Types`(願望) | types |
| o | `resultLinks :: ReadResult -> Maybe LinkReport` | 觀察:關聯報告 | `Aapms.Service.Types`(願望) | types |
| o | `resultSearch :: ReadResult -> Maybe SearchView` | 觀察:搜尋結果 | `Aapms.Service.Types`(願望) | types |
| o | `wide :: SearchQuery -> SearchQuery` | 觀察:拿掉分頁 | `Aapms.Store.Types`(願望,見 P-002-search) | types |
| o | `hitKey :: SearchHit -> (VaultId, Id)` | 觀察:命中的 (vault, id) | `Aapms.Store.Types`(願望,見 P-002-search) | types |
| = | `readOp :: Vaults :> es => ReadCtx -> ReadOp -> Eff es (Either ServiceError ReadResult)` | 純的整條:GetNode → 8 → 3 / 4 → 9 → 10(帶樹 11 → 13);ListNodes → 對每個 vault 5 → 10 → 14;ChildrenOf → 8 → 6 → 10;LinksOf → 8 → 7 → 17;Search → 15 → 10 → 16 | `Aapms.Service.Read`(願望) | pure |
| ! | `runRead :: Env -> ReadOp -> IO (Either ServiceError ReadResult)` | 進入點:以 Env 的快照與 handle 快取跑真解譯器(ATTACH 各索引) | `Aapms.Service.Read`(願望) | shell |

## Laws
- LAW-1 [relation] 每筆 NodeView 的 vault 是它實際所在的 vault,且在讀取範圍內;Meta 原樣不改寫
  - forall m in Map VaultId IndexState, ctx in ReadCtx, r in Ref, full in Bool, v in maybe [] pure (either (const Nothing) resultNode (simulateVaults m (readOp ctx (GetNode r full))))
  - |- metaVault (nvMeta v) == nvVault v and elem (nvVault v) (rcVaults ctx) and fmap anyMeta (nodeIn m (nvVault v) (metaId (nvMeta v))) == Just (nvMeta v)
- LAW-2 [relation] detail 的建構子恒對應 id 前綴;警告就是 checkMeta 的結果
  - forall m in Map VaultId IndexState, ctx in ReadCtx, r in Ref, full in Bool, v in maybe [] pure (either (const Nothing) resultNode (simulateVaults m (readOp ctx (GetNode r full)))), n in maybe [] pure (nodeIn m (nvVault v) (metaId (nvMeta v)))
  - |- detailPrefix (nvDetail v) == idPrefix (metaId (nvMeta v)) and nvWarnings v == checkMeta (rcRegistry ctx) n
- LAW-3 [relation] Level 要不要帶樹由第二參數決定;帶樹時樹的前序 id 等於 buildTree 的前序
  - forall m in Map VaultId IndexState, ctx in ReadCtx, r in Ref, v0 in maybe [] pure (either (const Nothing) resultNode (simulateVaults m (readOp ctx (GetNode r False)))), v1 in maybe [] pure (either (const Nothing) resultNode (simulateVaults m (readOp ctx (GetNode r True)))), lvl in [NLevel]
  - given idPrefix (metaId (nvMeta v0)) == PLvl
  - |- isNothing (detailTree (nvDetail v0)) and isJust (detailTree (nvDetail v1))
- LAW-4 [relation] 不帶 vault 的 Ref:預設 vault 有就是它;否則範圍內恰一個命中就是那個、多個回 AmbiguousRef 列出全部候選、零個回 NodeNotFound
  - forall m in Map VaultId IndexState, ctx in ReadCtx, i in Id, res in [simulateVaults m (readOp ctx (GetNode (Ref Nothing i) False))], hits in [hitsOf m (rcVaults ctx) i]
  - given maybe True (isNothing . flip (nodeIn m) i) (rcDefault ctx)
  - |- ((length hits == 0) == (res == Left (NodeNotFound (Ref Nothing i)))) and ((length hits >= 2) == (res == Left (AmbiguousRef i hits))) and ((length hits == 1) => (fmap (fmap nvVault . resultNode) res == Right (Just (head hits))))
- LAW-5 [relation] 帶 vault 的 Ref 只認那個 vault:不在範圍或該 vault 沒有就是 NodeNotFound,不去別的 vault 找
  - forall m in Map VaultId IndexState, ctx in ReadCtx, w in VaultId, i in Id, res in [simulateVaults m (readOp ctx (GetNode (Ref (Just w) i) False))]
  - |- (isRight res) == (elem w (rcVaults ctx) and isJust (nodeIn m w i)) and (isRight res => fmap (fmap nvVault . resultNode) res == Right (Just w))
- LAW-6 [invariant] 分頁的總數是符合條件的全部筆數,不隨 limit / offset 變;本頁是對整體切窗
  - forall m in Map VaultId IndexState, ctx in ReadCtx, f in NodeFilter, j in Int, k in Int, p in maybe [] pure (either (const Nothing) resultPage (simulateVaults m (readOp ctx (ListNodes f)))), p2 in maybe [] pure (either (const Nothing) resultPage (simulateVaults m (readOp ctx (ListNodes (f { nfOffset = j, nfLimit = k })))))
  - given j >= 0 and k >= 0
  - |- pgTotal p2 == pgTotal p and pgTotal p == length (structuralKeys m f) and map (metaId . nvMeta) (pgItems p2) == take k (drop j (map (metaId . nvMeta) (pgItems (either (const p) id (Right p)))))
- LAW-7 [relation] 子節點就是 owner 是它的那些,同一個 vault,依索引順序
  - forall m in Map VaultId IndexState, ctx in ReadCtx, w in VaultId, i in Id, vs in maybe [] pure (either (const Nothing) resultNodes (simulateVaults m (readOp ctx (ChildrenOf (Ref (Just w) i)))))
  - |- map (metaId . nvMeta) vs == map (metaId . anyMeta) (childrenOfIn m w i) and all ((== w) . nvVault) vs
- LAW-8 [relation] 關聯報告:出邊逐條對應 metaLinks,解不到目標的是 Nothing 不是錯誤;入邊是範圍內指向它的關聯
  - forall m in Map VaultId IndexState, ctx in ReadCtx, w in VaultId, i in Id, rep in maybe [] pure (either (const Nothing) resultLinks (simulateVaults m (readOp ctx (LinksOf (Ref (Just w) i))))), n in maybe [] pure (nodeIn m w i)
  - |- map fst (lrOut rep) == metaLinks (anyMeta n) and all ((== i) . refId . linkTarget . snd) (lrIn rep)
- LAW-9 [equiv] 搜尋結果就是 P-002 的命中逐筆投影:id 序列、總數、facet 都相同
  - forall m in Map VaultId IndexState, ctx in ReadCtx, q in SearchQuery, sv in maybe [] pure (either (const Nothing) resultSearch (simulateVaults m (readOp ctx (Search q)))), sr in [simulateVaults m (searchVaults q)]
  - |- map (metaId . nvMeta . shvNode) (svHits sv) == map (metaId . shMeta) (srHits sr) and svTotal sv == srTotal sr and svFacets sv == srFacets sr and map shvScore (svHits sv) == map shScore (srHits sr)
- LAW-10 [total] 讀取對任何索引集合與請求都有值,不拋例外
  - forall m in Map VaultId IndexState, ctx in ReadCtx, op in ReadOp
  - |- total (simulateVaults m (readOp ctx op))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 範圍 A、B;A 有 `ent-0001`;`GetNode (Ref Nothing ent-0001) False` | `nvVault == A`,`nvMeta` 等於索引裡的 Meta,`nvDetail` 是 `DEntity` | LAW-1、LAW-2、LAW-4 |
| EX-2 | A、B 都有 `ent-0002`,無預設 vault | `Left (AmbiguousRef ent-0002 [A, B])` | LAW-4 |
| EX-3 | 同 EX-2 但預設 vault 是 B | `nvVault == B` | LAW-4 |
| EX-4 | 範圍只有 A;`GetNode (Ref (Just B) ent-0001) False` | `Left (NodeNotFound (Ref (Just B) ent-0001))` | LAW-5 |
| EX-5 | `GetNode lvl False` 與 `True`,Level 有三個 Node | 前者 `dvTree == Nothing`;後者樹的前序 id 三個,順序同 `buildTree` | LAW-3 |
| EX-6 | A 有 5 個 entity、B 有 3 個;`ListNodes` 預設,再 `nfOffset = 6, nfLimit = 2` | 第一次 `pgTotal == 8`、8 筆;第二次 `pgTotal == 8`、2 筆是整體的第 7、8 筆 | LAW-6 |
| EX-7 | pack `pck-0001` 有兩個 asset;`ChildrenOf` | 兩筆,`nvVault` 同 pack | LAW-7 |
| EX-8 | 節點有兩條出邊,一條指向不存在的 id;`LinksOf` | `lrOut` 兩筆,第二筆的 NodeView 是 `Nothing`;不是錯誤 | LAW-8 |
| EX-9 | `Search (sqText = Just "藥水")` | `svHits` 的 id 序列、`svTotal`、`svFacets` 與 P-002 對同一查詢的結果相同 | LAW-9 |
| EX-10 | 範圍解析帶 ScopeIssue(某 vault 路徑不見) | 讀取仍成功,只涵蓋讀得到的 vault | LAW-10 |
| EX-11 | 亂造的索引集合與請求 | 不拋例外 | LAW-10 |

## 決定
- **五個讀取操作收成 `ReadOp` / `ReadResult`,一列 `=`;ServiceM 的門面是薄包裝。** 否決:五條 pipeline。理由:共用 Ref 解析與 NodeView 投影,一條 `!` 對三個殼。證據:ADR-023-effectful-effects-layer
- **不帶 vault 的 Ref:先看預設 vault(寫入目標或 `--vault` 指的那個),沒有再看範圍內每個 vault;多個命中是 AmbiguousRef 列出全部候選,不猜。** 否決:取第一個。理由:短 id 只在 vault 內唯一(ADR-014),猜錯就寫錯地方
- **NodeView 的 Meta 原樣,本層不改寫任何欄位;警告只由 checkMeta 產生。** 否決:本層補預設值。理由:契約層不做業務判斷以外的事
- **detail 依 AnyNode 建構子展開成六種,Level 的樹只在要求時建。** 否決:一律帶樹。理由:列 100 個 Level 不該建 100 棵樹
- **分頁總數是全部筆數,不受 `nfLimit` 預設的 1000 影響。** 否決:總數就是本頁。理由:殼要顯示「第 x / y 頁」
- **關聯報告的出邊解不到回 Nothing,讀取不擋懸空。** 否決:回錯誤。理由:懸空是寫入路徑該擋的事;讀的時候使用者要看得到「這條斷了」
- **搜尋只做投影,命中、排序、分頁、facet 全由 P-002 決定。** 否決:service 再排一次。理由:一份規則
- **ScopeIssue 不中止讀取。** 否決:任何 issue 都失敗。理由:一個 vault 搬走不該讓其他 vault 查不到;issue 由 doctor 報告(P-006)
- **本層不開索引以外的東西;正文從檔案重讀是 `Index` 效果 `nodeById` 的真解譯器內部的事。** 否決:NodeView 不帶正文。理由:`entity show` 要顯示正文

## 修訂記錄
無
