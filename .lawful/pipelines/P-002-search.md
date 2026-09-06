---
id: P-002
description: 查詢字串經 CJK 分詞路由到 trigram 與 unicode61 雙 FTS,跨 vault 合併去重排序分頁,每筆帶 vault
status: ready
updated: 2026-09-06
---
# P-002-search:查詢字串經 CJK 分詞路由到 trigram 與 unicode61 雙 FTS,跨 vault 合併去重排序分頁,每筆帶 vault

## Brief
回答「這組 vault 裡哪些節點符合這段文字與這些結構條件」,一次回 asset 與 entity 兩種,每筆帶來源 vault(ADR-016、ADR-017)。input 是 `SearchQuery`(可選的文字條件、`NodeFilter` 結構條件、要不要 facet)與本次生效的 vault 集合;output 是 `SearchResult`(命中清單、總數、facet)。流向:路由判定 → 對每個 vault 查雙 FTS 與結構條件 → 兩張表的命中取分數較大者去重 → 取片段 → 跨 vault 合併 → 排序 → 切窗 → facet 合併。整條是效果程式:`Index` 效果負責一個 vault 內的 FTS 命中與結構過濾(P-001-index-rebuild 同一個效果多兩個查詢操作),`Vaults` 效果負責「對集合裡某個 vault 跑一段 Index 程式」;純解譯器用 P-027-fts-tokenize 的 `matchesQuery` 當參考實作,law 全在記憶體裡跑。真解譯器(sqlite 的 `MATCH` 與 `bm25()`、`ATTACH` 多個索引)住 shell,`searchAcross` 是進入點;單 vault 的 `search` 是同一組解譯器的另一個 shell 入口。它是 S1 的第二條里程碑。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `routeOf :: Text -> SearchRoute` | 查詢字串走 trigram、CJK 或兩張表 | `Aapms.Store.Tokenize`(見 P-027-fts-tokenize) | pure |
| 2 | `matchesQuery :: Text -> AnyNode -> Bool` | 純參考:這段文字在同一套路由規則下命不命中這個節點 | `Aapms.Store.Tokenize`(願望,見 P-027-fts-tokenize) | pure |
| 3 | `passesFilter :: NodeFilter -> FileIndex -> IndexedNode -> Bool` | 結構條件的純判定,吃節點所在的檔與索引節點:prefix、type、status、tags 全部命中、owner(`inOwner`)、license、只要已命名、reference(`fiReference`)預設不列 | `Aapms.Store.Filter`(願望) | pure |
| 4 | `ftsMatch :: Index :> es => SearchRoute -> Text -> NodeFilter -> Eff es [(Id, Double)]` | 一個 vault 內依路由查雙 FTS,結構條件同時套用,回命中與正分數;純解譯器以 2 與 3 判定、分數 1.0 | `Aapms.Store.Effect.Index`(願望) | effects |
| 5 | `filterNodes :: Index :> es => NodeFilter -> Eff es [AnyNode]` | 一個 vault 內符合結構條件的全部節點,不分頁 | `Aapms.Store.Effect.Index`(願望) | effects |
| 6 | `mergeScores :: [(Id, Double)] -> [(Id, Double)] -> [(Id, Double)]` | 兩張表都命中時取分數較大者,去重 | `Aapms.Store.Search`(願望) | pure |
| 7 | `snippetFrom :: Text -> [Text] -> Text` | 從該節點 fts_tri 六欄原文取窗:先找整串、再找個別詞、都沒有取第一個非空欄開頭 | `Aapms.Store.Search`(願望,取代 Aapms.Store.Query 私有的 snippetOf) | pure |
| 8 | `rankHits :: [SearchHit] -> [SearchHit]` | 分數遞減、同分 id 遞增、再同 vault 遞增 | `Aapms.Store.Search`(願望) | pure |
| 9 | `pageHits :: NodeFilter -> [SearchHit] -> [SearchHit]` | 依 nfOffset / nfLimit 對整體切窗 | `Aapms.Store.Search`(願望) | pure |
| 10 | `facetsIn :: Index :> es => VaultId -> SearchQuery -> Eff es FacetCounts` | 單 vault 的五維 facet,每一維排除自己的條件、保留其餘條件與文字條件 | `Aapms.Store.Search`(願望) | pure |
| 11 | `mergeFacetCounts :: [FacetCounts] -> FacetCounts` | 跨 vault 同值求和、濾掉計數 0、計數遞減同計數值遞增 | `Aapms.Store.Search`(願望,取代 Aapms.Store.MultiVault 私有的 mergeFacets) | pure |
| 12 | `searchVault :: Index :> es => VaultId -> SearchQuery -> Eff es SearchResult` | 單 vault 整條:1 → 4 / 5 → 6 → 7 → 8 → 9,facet 走 10 | `Aapms.Store.Search`(願望) | pure |
| 13 | `vaultIds :: Vaults :> es => Eff es [VaultId]` | 集合裡的 vault,保序 | `Aapms.Store.Effect.Vaults`(願望) | effects |
| 14 | `inVault :: Vaults :> es => VaultId -> Eff '[Index] a -> Eff es (Maybe a)` | 對集合裡某個 vault 跑一段 Index 程式;不在集合回 Nothing | `Aapms.Store.Effect.Vaults`(願望) | effects |
| o | `runVaultsPure :: Map VaultId IndexState -> Eff (Vaults : es) a -> Eff es a` | 觀察:Vaults 的純解譯器,每個 vault 一份記憶體索引 | `Aapms.Store.Effect.Vaults`(願望) | effects |
| o | `simulateVaults :: Map VaultId IndexState -> Eff '[Vaults] a -> a` | 觀察:純解譯器跑到底 | `Aapms.Store.Search.Internal`(願望) | pure |
| o | `hitsPerVault :: Map VaultId IndexState -> SearchQuery -> [SearchHit]` | 觀察:逐 vault 各跑一次 searchVault,把 hits 串接 | `Aapms.Store.Search.Internal`(願望) | pure |
| o | `structuralKeys :: Map VaultId IndexState -> NodeFilter -> [(VaultId, Id)]` | 觀察:逐 vault 用 passesFilter 篩出的 (vault, id) | `Aapms.Store.Search.Internal`(願望) | pure |
| o | `hitKey :: SearchHit -> (VaultId, Id)` | 觀察:命中的 (vault, id) | `Aapms.Store.Types`(願望) | types |
| o | `nodeKey :: (VaultId, AnyNode) -> (VaultId, Id)` | 觀察:節點的 (vault, id) | `Aapms.Store.Types`(願望) | types |
| o | `visibleNodes :: NodeFilter -> Map VaultId IndexState -> [(VaultId, AnyNode)]` | 觀察:記憶體索引集合裡逐檔逐節點以 passesFilter 判定後留下的節點 | `Aapms.Store.Search.Internal`(願望) | pure |
| o | `keysOf :: Map VaultId IndexState -> [VaultId]` | 觀察:記憶體索引集合裡的 vault id | `Aapms.Store.Types`(願望) | types |
| o | `wide :: SearchQuery -> SearchQuery` | 觀察:拿掉分頁(offset 0、limit 大於任何樣本總數) | `Aapms.Store.Types`(願望) | types |
| o | `page :: Int -> Int -> SearchQuery -> SearchQuery` | 觀察:設 offset j、limit k | `Aapms.Store.Types`(願望) | types |
| o | `withTypes :: [TypeKey] -> SearchQuery -> SearchQuery` | 觀察:換掉 nfTypes | `Aapms.Store.Types`(願望) | types |
| o | `withTags :: [Text] -> SearchQuery -> SearchQuery` | 觀察:換掉 nfTags | `Aapms.Store.Types`(願望) | types |
| = | `searchVaults :: Vaults :> es => SearchQuery -> Eff es SearchResult` | 純的整條:13 → 對每個 vault 14(12)→ 合併 hits → 8 → 9;srTotal 加總;facet 11 | `Aapms.Store.Search`(願望) | pure |
| ! | `searchAcross :: VaultSet -> SearchQuery -> IO SearchResult` | 進入點:以 VaultSet 的連線(ATTACH 各索引)跑真解譯器 | `Aapms.Store.MultiVault` | shell |

## Laws
- LAW-1 [equiv] 跨 vault 的命中等於各 vault 各自命中的聯集,四欄逐欄相同;合併只影響排序與分頁
  - forall m in Map VaultId IndexState, q in SearchQuery
  - |- rankHits (srHits (simulateVaults m (searchVaults (wide q)))) == rankHits (hitsPerVault m (wide q))
- LAW-2 [relation] 沒有文字條件時退化成結構查詢:命中就是 passesFilter 篩出的節點,分數 0、片段空
  - forall m in Map VaultId IndexState, q in SearchQuery, hits in srHits (simulateVaults m (searchVaults (wide q)))
  - given isNothing (sqText q)
  - |- (sort (map hitKey hits) == sort (structuralKeys m (sqFilter q))) and all (== 0) (map shScore hits) and all null (map shSnippet hits)
- LAW-3 [bound] 有文字條件時每筆分數為正
  - forall m in Map VaultId IndexState, q in SearchQuery, t in Text, hits in srHits (simulateVaults m (searchVaults (wide q)))
  - given sqText q == Just t and not (null (words t))
  - |- all (> 0) (map shScore hits)
- LAW-4 [equiv] 有文字條件時,命中集合等於逐節點以 matchesQuery 與 passesFilter 判定的純參考
  - forall m in Map VaultId IndexState, q in SearchQuery, t in Text, hits in srHits (simulateVaults m (searchVaults (wide q)))
  - given sqText q == Just t and not (null (words t))
  - |- sort (map hitKey hits) == sort (map nodeKey (filter (matchesQuery t . snd) (visibleNodes (sqFilter q) m)))
- LAW-5 [invariant] 命中的 (vault, id) 兩兩相異
  - forall m in Map VaultId IndexState, q in SearchQuery, hits in srHits (simulateVaults m (searchVaults q))
  - |- nub (map hitKey hits) == map hitKey hits
- LAW-6 [invariant] 命中已排序:分數遞減、同分 id 遞增、再同 vault 遞增
  - forall m in Map VaultId IndexState, q in SearchQuery, hits in srHits (simulateVaults m (searchVaults q))
  - |- rankHits hits == hits
- LAW-7 [relation] 分頁是對整體切窗,不是各 vault 各切再接
  - forall m in Map VaultId IndexState, q in SearchQuery, j in Int, k in Int
  - given j >= 0 and k >= 0
  - |- srHits (simulateVaults m (searchVaults (page j k q))) == take k (drop j (srHits (simulateVaults m (searchVaults (wide q)))))
- LAW-8 [invariant] 總數不隨分頁變,且等於不分頁時的命中數
  - forall m in Map VaultId IndexState, q in SearchQuery, j in Int, k in Int
  - given j >= 0 and k >= 0
  - |- srTotal (simulateVaults m (searchVaults (page j k q))) == length (srHits (simulateVaults m (searchVaults (wide q))))
- LAW-9 [relation] 每筆的 shVault 等於它 meta 的 vault,且在集合裡
  - forall m in Map VaultId IndexState, q in SearchQuery, h in srHits (simulateVaults m (searchVaults q))
  - |- metaVault (shMeta h) == shVault h and elem (shVault h) (keysOf m)
- LAW-10 [relation] facet 只在要求時出現;fcVaults 的計數加總等於總數
  - forall m in Map VaultId IndexState, q in SearchQuery, r in simulateVaults m (searchVaults (wide q))
  - |- (isJust (srFacets r) == sqFacets q) and maybe True ((== srTotal r) . sum . map snd . fcVaults) (srFacets r)
- LAW-11 [invariant] fcTypes 不因 nfTypes 改變(facet 排除自己的條件,選了一個值之後還換得掉)
  - forall m in Map VaultId IndexState, q in SearchQuery, ts in [TypeKey], r in simulateVaults m (searchVaults (wide q)), r2 in simulateVaults m (searchVaults (wide (withTypes ts q)))
  - given sqFacets q
  - |- fmap fcTypes (srFacets r2) == fmap fcTypes (srFacets r)
- LAW-12 [invariant] fcTags 不因 nfTags 改變
  - forall m in Map VaultId IndexState, q in SearchQuery, tags in [Text], r in simulateVaults m (searchVaults (wide q)), r2 in simulateVaults m (searchVaults (wide (withTags tags q)))
  - given sqFacets q
  - |- fmap fcTags (srFacets r2) == fmap fcTags (srFacets r)
- LAW-13 [relation] 只認集合裡的 vault:inVault 對集合外的 vault 回 Nothing,對集合內的回 Just
  - forall m in Map VaultId IndexState, v in VaultId
  - |- isJust (simulateVaults m (inVault v (pure ()))) == member v m

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 一個 vault 裡有 asset 標題「魔法藥水瓶」,`sqText = Just "藥水"` | 命中該節點,`shScore > 0`,`shSnippet` 含「藥水」 | LAW-3、LAW-4 |
| EX-2 | asset 的 `name` 為 `ui_gui_travel-book-frame_001`,`sqText = Just "travel-book"` | 命中該 asset;`-` 不被當運算子 | LAW-4 |
| EX-3 | `sqText = Just "ui"`(純 ASCII 二字) | `srHits == []`、`srTotal == 0`,不是錯誤 | LAW-4 |
| EX-4 | 一個節點的 `title` 同時含「藥水」與 `potion`,`sqText = Just "藥水 potion"` | 只有一筆該節點 | LAW-5 |
| EX-5 | `emptySearchQuery`(無文字、無 facet) | hits 的 meta 集合等於結構篩選;每筆 `shScore == 0`、`shSnippet == ""`;`srFacets == Nothing` | LAW-2、LAW-10 |
| EX-6 | `sqText = Just "   "`(只有空白) | 與 EX-5 相同,視同沒有文字條件 | LAW-2 |
| EX-7 | vault A 有 id `ent-00000001`、`ent-00000003`,vault B 有 `ent-00000002`,無文字條件,`page 1 1` | 唯一一筆是 B 的 `ent-00000002`(視窗跨過 vault 邊界) | LAW-6、LAW-7、LAW-8 |
| EX-8 | 同一個 id `ent-0000abcd` 同時在 A 與 B | 兩筆都在,`shVault` 分別是 A 與 B,相鄰時 A 在前 | LAW-5、LAW-6、LAW-9 |
| EX-9 | 兩個 vault 都有 tag `canon` 各 2 個節點,`sqFacets = True` | `fcTags` 裡 `("canon", 4)`;`fcVaults` 兩筆計數相加等於 `srTotal` | LAW-10 |
| EX-10 | 同 EX-9,再對 `withTypes ["character-fragment"]` 查一次 | `fcTypes` 與不加型別條件時逐筆相同 | LAW-11 |
| EX-11 | 同 EX-9,再對 `withTags ["canon"]` 查一次 | `fcTags` 與不加標籤條件時逐筆相同 | LAW-12 |
| EX-12 | `inVault "vlt-deadbeef" (pure ())`,集合裡沒有這個 vault | `Nothing` | LAW-13 |
| EX-13 | `sqText = Just "這個詞不存在於任何節點"` | `srHits == []`、`srTotal == 0` | LAW-1、LAW-4 |
| EX-14 | 兩個 vault 各對「琳達」命中一筆,不分頁 | `rankHits` 後與逐 vault 各查再串接的結果相同 | LAW-1 |

## 決定
- **`Index` 效果多兩個查詢操作 `ftsMatch` / `filterNodes`,跨 vault 靠 `Vaults` 效果的 `inVault` 對每個 vault 各跑一次,合併在 Haskell 做。** 否決:一個帶 VaultId 參數的大效果、或在 SQL 層 UNION 後合併分數。理由:P-001 的 `Index` 保持單 vault 不必 REV;分數合併推進 SQL 做得到但把 SQL 組裝弄髒(原 F009 ASM-1)。證據:ADR-023-effectful-effects-layer
- **純解譯器的分數是常數 1.0,真解譯器的分數是 sqlite `bm25()` 取負。** 否決:在純解譯器重做 bm25。理由:law 只用到「正」與「排序鍵」,不用到分數值;bm25 的絕對值是 sqlite 的實作細節
- **`shScore` 是 `Double` 且有文字條件時恆正,0 保留給沒有文字條件。** 否決:`Maybe Double`。理由:`LIKE` 已退場(ADR-016),`Nothing` 是不可能發生的分支
- **兩張表都命中時取較大分數,不相加。** 否決:相加。理由:相加讓分數取決於命中幾張索引,那是實作產物
- **facet 每一維排除自己的條件。** 否決:一律套完整條件。理由:選了一個 tag 之後側欄只剩那一個值,使用者換不掉
- **片段一律取自 fts_tri 的原文,與命中來自哪張表無關。** 否決:fts_cjk 命中時用它的 `snippet()` 再還原。理由:fts_cjk 存的是 n-gram 串,視窗不是原文子字串;`desegmentCjk` 因此整個撤除(原 F007 GAP-4 / GAP-5)
- **純 ASCII 一、二字元查詢恆空,寫成 example 不特例。** 否決:短查詢走子字串掃描。理由:trigram 三字元下限是物理限制,子字串掃描給不出分數且違反 ADR-016
- **真解譯器 `openVaultSet` 的檢查順序:先撞號、再保序去重、最後上限 `maxAttachedVaults == 10`,超過回使用者看得懂的 `TooManyVaults`。** 否決:先查上限。理由:撞號時任何 Ref 解析都不確定,先叫使用者收窄範圍等於叫他繞過去(原 F009 ASM-5)。這條住 shell,由 shell 的內部測試守,不掛 law
- **LAW-4 同時是 sqlite 解譯器的驗收:conductor 對真解譯器也跑一份同歸屬的測試。** 否決:只在純解譯器上驗。理由:純解譯器用 `matchesQuery` 定義 `ftsMatch`,只在純側跑等於套套邏輯;sqlite 側跑才證明兩個解譯器一致
- **索引更新後搜尋不留重複列、卸載檔案後其節點不再命中、schema 改版整庫重建後結果不變,由 P-001-index-rebuild 的 LAW-1 / LAW-2 與 `Index` 效果的狀態模型承接,本條不重複寫。** 否決:在這裡再寫三條 IO law(原 F007 LAW-20 / 21 / 22)。理由:它們講的是索引狀態,不是查詢

## 修訂記錄
- REV-1(2026-09-06,依 qa 提問 GAP-1「`passesFilter` 的簽名只吃 `NodeFilter` 與 `AnyNode`,而 `AnyNode` / `Meta` 上沒有任何 reference 標記」;開發者裁決結構條件的純判定吃完整上下文):第 3 列改成 `passesFilter :: NodeFilter -> FileIndex -> IndexedNode -> Bool`,owner 看 `inOwner`、reference 看 `fiReference`;觀察點 `allNodesIn` 換成 `visibleNodes :: NodeFilter -> Map VaultId IndexState -> [(VaultId, AnyNode)]`(pure,`Aapms.Store.Search.Internal`);LAW-4 的 `|-` 改用 `visibleNodes`;LAW-2 文字不變但定義域放開(`fiReference` 不再固定 False)
  - 動到:Stages 第 3 列、觀察點 `allNodesIn` → `visibleNodes`、LAW-4
  - 保護:LAW-1、LAW-3、LAW-5 到 LAW-13
  - 重委派:qa(LAW-2、LAW-4);骨架的簽名由 conductor 同步改,impl 尚未派
