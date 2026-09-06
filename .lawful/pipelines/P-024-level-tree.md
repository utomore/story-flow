---
id: P-024
description: Level 的 Node 清單經五條不變量驗證建成嚴格樹,再據以前序走訪、取子樹、追路徑與查合流
status: frozen
updated: 2026-09-06
---
# P-024-level-tree:Level 的 Node 清單經五條不變量驗證建成嚴格樹,再據以前序走訪、取子樹、追路徑與查合流

## Brief
把一份 Level 檔攤平的 `Node` 清單還原成場景樹,並在還原之前守住 ADR-004 的「Level 是嚴格樹」:每個 Node 恰有一個父節點(根除外)、不成環、同層兄弟以 `order` 排序。input 是一個 `Level`(帶它宣告的根 id)與它的 `Node` 清單;output 是 `NodeTree`,或一次列完的 `[TreeError]`。流向:一次驗完六類不變量 → 建樹並把同層兄弟依 `order` 排好 → 前序走訪 / 取子樹 / 追根到節點的路徑 / 依演出種類篩選 / 收集關聯到的 Entity / 列出合流標註。分支合流以 `convergesTo` 標註,**不參與結構**,因此走訪永遠只看父子邊。它是子流:P-001-index-rebuild 的第 9 步引用 `buildTree`,樹不合法整檔不進索引;`TreeError` 與 `renderTreeError` 的宣告住 types 層的 `Aapms.Core.Level`,`Aapms.Core.Tree` 原樣 re-export。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `preorder :: NodeTree -> [Node]` | 前序走訪,同層依 `order`(建樹時已排好) | `Aapms.Core.Tree` | pure |
| 2 | `subtreeAt :: Id -> NodeTree -> Maybe NodeTree` | 取出以某個節點為根的子樹 | `Aapms.Core.Tree` | pure |
| 3 | `pathTo :: Id -> NodeTree -> Maybe [Node]` | 根到指定節點的完整路徑,含頭尾 | `Aapms.Core.Tree` | pure |
| 4 | `nodesOfKind :: NodeKind -> NodeTree -> [Node]` | 依演出種類篩出節點 | `Aapms.Core.Tree` | pure |
| 5 | `entitiesIn :: NodeTree -> [Ref]` | 子樹內所有 Node 關聯到的 Entity,依前序去重 | `Aapms.Core.Tree` | pure |
| 6 | `convergenceReport :: NodeTree -> [(Id, Ref, Bool)]` | 列出所有 `convergesTo` 標註,以及它指的 Node 在不在本 Level 內 | `Aapms.Core.Tree` | pure |
| o | `ntNode :: NodeTree -> Node` | 觀察:一棵(子)樹的根節點本身 | `Aapms.Core.Tree` | pure |
| o | `ntChildren :: NodeTree -> [NodeTree]` | 觀察:一棵(子)樹的子樹清單,已依 `order` 排好 | `Aapms.Core.Tree` | pure |
| = | `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | 純的整條:一次驗完全部不變量,全過才建得出樹 | `Aapms.Core.Tree` | pure |

## Laws
- LAW-1 [invariant] 建得起來的樹恰好裝下全部節點,一個不多一個不少
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], n in ns
  - |- n in preorder t and length (preorder t) == length ns
- LAW-2 [invariant] 樹裡每個 id 只出現一次:重複 id 與成環的輸入建不成樹
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns]
  - |- nub (map metaId (map nodMeta (preorder t))) == map metaId (map nodMeta (preorder t))
- LAW-3 [identity] 根之上沒有東西:以根為起點取子樹就是整棵樹
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns]
  - |- subtreeAt (metaId (nodMeta (head (preorder t)))) t == Just t
- LAW-4 [relation] 每個節點都追得出一條從同一個根起頭、到它自己為止的路徑
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], n in preorder t
  - |- fmap head (pathTo (metaId (nodMeta n)) t) == Just (head (preorder t)) and fmap last (pathTo (metaId (nodMeta n)) t) == Just n
- LAW-5 [relation] 樹裡的每個節點都找得到自己的子樹,而且那棵子樹的根就是它
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], n in preorder t
  - |- fmap ntNode (subtreeAt (metaId (nodMeta n)) t) == Just n
- LAW-6 [commute] 同層順序只由 order 決定,與節點在檔案裡的出現順序無關
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns]
  - |- buildTree lvl (reverse ns) == Right t
- LAW-7 [invariant] 樹的形狀只由節點決定,Level 只負責把關根的宣告
  - forall lvl1 in Level, lvl2 in Level, ns in [Node], t1 in rights [buildTree lvl1 ns], t2 in rights [buildTree lvl2 ns]
  - |- t1 == t2
- LAW-8 [relation] nodesOfKind 恰好是前序裡那個演出種類的節點,不多也不少
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], k in NodeKind, n in preorder t
  - |- (n in nodesOfKind k t) == (nodKind n == k)
- LAW-9 [relation] 子樹裡的 Entity 是整棵樹的子集,而且清單本身已去重
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], n in preorder t, s in catMaybes [subtreeAt (metaId (nodMeta n)) t], r in entitiesIn s
  - |- r in entitiesIn t and nub (entitiesIn t) == entitiesIn t
- LAW-10 [relation] 合流報告的第三欄就是「目標是本 vault 且在本 Level 內」
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], (i, r, ok) in convergenceReport t
  - |- ok == (refVault r == Nothing and refId r in map metaId (map nodMeta (preorder t)))
- LAW-11 [relation] 一棵子樹的根就是它的 ntNode,它的每個子樹的根都在自己的前序裡
  - forall lvl in Level, ns in [Node], t in rights [buildTree lvl ns], n in preorder t, s in catMaybes [subtreeAt (metaId (nodMeta n)) t], c in ntChildren s
  - |- head (preorder s) == ntNode s and ntNode c in preorder s
- LAW-12 [total] 任何 Level 與節點清單丟給 buildTree 都有值,不拋例外
  - forall lvl in Level, ns in [Node]
  - |- total (buildTree lvl ns)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 教室場景 fixture:`classroomLevel` 與九個 Node | 建樹成功;`preorder` 依序為 `nod-0001, 0002, 0004, 0005, 0007, 0009, 0008, 0010, 0003`,共九個 | LAW-1、LAW-2 |
| EX-2 | 把同一組節點清單反轉後再建樹 | 與 EX-1 建出的樹相等——同層順序只由 `order` 決定,不由檔案裡的出現順序決定 | LAW-6 |
| EX-3 | `subtreeAt (idOf "nod-0002")`;再對 `nod-9999` 取一次 | 前者是七個節點、根為 `nod-0002` 的子樹;後者 `Nothing` | LAW-5 |
| EX-4 | `subtreeAt (idOf "nod-0001")`(根自己) | `Just` 整棵樹 | LAW-3 |
| EX-5 | `pathTo (idOf "nod-0005")`;再對根自己追一次 | `Just [nod-0001, nod-0002, nod-0004, nod-0005]`;根的路徑只有它自己(邊界:長度 1) | LAW-4 |
| EX-6 | 根的 `ntChildren` | 兩棵子樹,根依序是 `nod-0002`(order 1)與 `nod-0003`(order 2) | LAW-11 |
| EX-7 | `nodesOfKind KBranch`;`nodesOfKind KScene` | `[nod-0007, nod-0008]`;`[nod-0001]`(只有根) | LAW-8 |
| EX-8 | `entitiesIn classroomTree`(琳達在兩個節點上出現);`entitiesIn` 對 `nod-0003` 的子樹 | 琳達只算一次;葉節點的子樹回 `[]`(邊界:空清單) | LAW-9 |
| EX-9 | `convergenceReport`:`nod-0009` 合流到 `nod-0010`;再把目標換成 `nod-9999` 與 `vlt-a0c4e1f8:nod-0010` | 依序 `True`、`False`、`False`——跨 vault 一律視為不存在 | LAW-10 |
| EX-10 | 把 `nod-0004` 的父節點改成 `nod-0009`(A → B → A 的環) | `Left`,錯誤含 `Cycle [nod-0004, nod-0009, nod-0007, nod-0005]`(以最小 id 起始);不拋例外 | LAW-2、LAW-12 |
| EX-11 | 把 `nod-0003` 的父節點改成不存在的 `nod-9999`(跳級) | `Left`,錯誤含 `OrphanNode (nod-0003) (nod-9999)` | LAW-12 |
| EX-12 | 把 `nod-0003` 的父節點改成 `Nothing`(兩個根);另一組把 `nod-0001` 掛到 `nod-0003` 底下(一個根都沒有) | 依序 `Left [… MultipleRoots [nod-0001, nod-0003] …]` 與 `Left [… NoRoot …]` | LAW-3、LAW-12 |
| EX-13 | 同一個父節點底下兩個子節點的 `order` 都是 1 | `Left`,錯誤含 `DuplicateOrder (nod-0001) 1 [nod-0002, nod-0003]` | LAW-6、LAW-12 |
| EX-14 | 同一個 id 出現兩次 | `Left`,錯誤含 `DuplicateNodeId (nod-0003)` | LAW-2、LAW-12 |
| EX-15 | `lvlRoot` 宣告成 `nod-0002`,實際的根是 `nod-0001` | `Left`,錯誤含 `RootMismatch (nod-0002) (nod-0001)` | LAW-7、LAW-12 |
| EX-16 | 一次改壞兩處:`nod-0003` 指向不存在的父節點,同時 `nod-0004` 變成第二個根 | 兩則錯誤都在同一個清單裡,不是只回第一個 | LAW-12 |

## 決定
- **一次回報全部錯誤,不是第一個。** 否決:遇到第一條不變量壞掉就中止。理由:作者手改 Markdown 的標題層級後常一次壞好幾處,一次列完比修一個跑一次有用得多
- **六類不變量各對應一組 `TreeError` 建構子:單一根、根與 Level 宣告相符、父節點必須存在、不成環、同層 `order` 唯一、id 不重複。** 否決:只擋成環。理由:F001 契約卡的「拒絕成環、跳級、多重父節點」三項就是 `Cycle` / `OrphanNode` / `MultipleRoots`,跳級是作者跳過中間標題層級的具體樣子
- **`convergesTo` 是標註不是結構,走訪演算法永遠只看父子邊。** 否決:讓合流參與樹的形狀。理由:ADR-004;合流一旦進結構,樹就不再是樹,而懸空的合流也就沒有地方被發現
- **跨 vault 的 `convergesTo` 目標一律視為不存在。** 否決:跨 vault 也算命中。理由:它不可能指向本 Level 內的 Node,報告要回答的正是「本 Level 內找不找得到」
- **環的節點序列旋轉成以最小 id 起始。** 否決:照走訪起點原樣輸出。理由:同一個環從不同節點出發要得到相同的錯誤值,否則錯誤清單會隨節點在檔案裡的順序而變
- **`TreeError` 與 `renderTreeError` 住 types 層的 `Aapms.Core.Level`,建樹演算法住 pure 層的 `Aapms.Core.Tree`,後者原樣 re-export。** 否決:錯誤 ADT 跟著演算法住。理由:落地層的 `StoreError` 與 `IndexIssue` 都把 `TreeError` 捧在建構子裡,型別層不該為了一個錯誤 ADT 去依賴一個做推導的模組
- **錯誤訊息一律指向「去改哪一個標題」,不描述資料結構。** 否決:輸出結構化的節點關係。理由:讀訊息的是作者,不是程式
- **六個走訪函式留著,不是新增的對外介面。** 否決:精簡到只剩 `buildTree`。理由:它們是既有功能沿用,`aapms level lint` 與日後的衝突偵測子系統都要用;F001 契約 B 沒列它們,但也沒說要拿掉
- **樹不合法時整份 Level 檔不進索引。** 否決:能建多少算多少、壞掉的節點略過。理由:與 P-001-index-rebuild 的「整檔要嘛全進要嘛不進」同一個模型,不另發明部分成功

## 修訂記錄
無
