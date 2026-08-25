---
id: F009
type: feature
title: store-multi-vault-read
description: 以 VaultSet 接起多個 vault 的索引,跨 vault 列舉、檢索與懸空引用檢查
status: open
created: 2026-08-25
updated: 2026-08-26
depends-on: [F001, F005, F006, F007]
related-adr: [ADR-014, ADR-017, ADR-022]
related-feature: []
---

# F009: 跨 vault 讀(`VaultSet`)

## 目的

ADR-017 第三條把範圍切成兩半:**查詢跨全部生效的 vault,寫入永遠單一 vault**。素材庫要解決的第一個
問題就是「一次找遍所有素材」——故事側 vault 裡的「琳達的藥水日記」與素材側 vault 裡的「魔法藥水瓶」
必須在同一次 `search` 裡一起出現、而且每筆知道自己來自哪裡。F007 交付的 `search` 只看得到一個 vault,
本 feature 把它擴成 `VaultSet`。

這條路上有一個**天生會安靜出錯**的前提:短 id 依 ADR-014 **只在 vault 內唯一**。任何以 `Id` 單獨當鍵
的合併、去重或 `Map` 索引,都會在兩個 vault 剛好有同一個短 id 時讓其中一筆消失,而結果看起來完全
正常。跨 vault 的身分一律是 `(VaultId, Id)` 這一對——本文檔的 L5 / L7 / L11 / L13 就是為了讓這件事
在測試裡被抓到而寫的。

## 對應的 Level 2 契約

| 契約 | 條目 | 本文檔的處置 |
|---|---|---|
| E | `data VaultSet` | 逐字實作;**不透明**(建構子不匯出),表示法不是契約的一部分 |
| E | `openVaultSet :: [VaultHandle] -> IO (Either StoreError VaultSet)` | 逐字實作 |
| E | `lookupRef :: VaultSet -> VaultId -> Ref -> IO (Maybe (VaultId, AnyNode))` | 逐字實作 |
| E | `listAcross :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]` | 逐字實作 |
| E | `searchAcross :: VaultSet -> SearchQuery -> IO SearchResult` | 逐字實作 |
| E | `checkReferences :: VaultSet -> VaultHandle -> IO [DanglingRef]` | 逐字實作;`DanglingRef` 的形狀由本 feature 定(D3;2026-08-26 A3 裁決後已回寫契約 E) |
| E | `closeVaultSet` / `vaultSetIds` / `maxAttachedVaults` | 逐字實作(2026-08-26 A2 裁決後已回寫契約 E) |
| E | `DanglingRef` / `DanglingReason` | 逐字實作(2026-08-26 A3 裁決後已回寫契約 E) |
| E | `NodeFilter` / `SearchQuery` / `SearchResult` / `SearchHit` / `FacetCounts` | **不重新定義**,沿用 F006 / F007 的既有型別 |
| G | `TooManyVaults Int Int` | 新增 `StoreError` 建構子與 `renderStoreError` 分支(**不另立平行錯誤型別**) |
| G | `VaultIdCollision VaultId FilePath FilePath` | 新增 `StoreError` 建構子與 `renderStoreError` 分支(2026-08-26 A5 裁決) |
| 模組間公開介面 | MultiVault → Query:`listAcross` 重用 `whereOf` 條件片段對加了 schema 前綴的 UNION 視圖執行;`searchAcross` 各 vault 各自取命中後在 Haskell 合併分數 | 逐字實作(2026-08-26 A1 分案裁決後已回寫) |
| 資料流管線 | 跨 vault 讀全段 | 逐段實作 |
| ADR-017 第四條 | 結構查詢走 SQL、全文查詢走 Haskell | 依 2026-08-26 修訂後的原文實作 |

`renderDanglingRef` 是契約 E 之外唯一新增的一條,比照 `renderIndexIssue`(見「自裁」與 D4)。

未超出契約範圍:本文檔不碰任何寫入函式、不新增任何查詢 DTO。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `VaultSet` | 新增 | 不透明。骨架的最小表示是 `VaultSet [VaultHandle] Connection`(去重後的把手清單 + 自己的讀連線),**表示法不是契約**,impl 可增刪欄位 | 「本次查詢涵蓋哪些 vault、依什麼順序」——這是跨 vault 結果裡 `VaultId` 欄位的唯一真相來源 |
| `DanglingRef` | 新增 | `{ drSource :: Id, drLink :: Link, drTarget :: Ref, drReason :: DanglingReason }` | 一筆解析不到的關聯的完整描述:誰發出的、原文長什麼樣、套上預設 vault 之後去找了哪裡、為什麼找不到 |
| `DanglingReason` | 新增 | `TargetVaultAbsent \| TargetNodeMissing` | 懸空的成因分類。分開是因為**修法不同**:前者是呼叫端的 vault 集合不完整(補一個 `--vault` 即可,資料沒問題),後者才是資料的問題 |
| `TooManyVaults` | 新增(`StoreError` 建構子) | `TooManyVaults Int Int` —— 去重後的 vault 數量、上限 | 契約 G:「跨 vault 的 `TooManyVaults` 必須列出當前數量與上限」 |
| `VaultIdCollision` | 新增(`StoreError` 建構子) | `VaultIdCollision VaultId FilePath FilePath` —— 撞號的 vault id、兩個不同的根目錄 | 「兩個不同目錄帶著同一個 vault id」這件事,以及**是哪兩個目錄**。依 ADR-017 vault 的身分就是 marker 的 id,這是資料層級的問題,不是呼叫端疏忽 |
| `maxAttachedVaults` | 新增 | `10 :: Int` | `VaultSet` 一次最多接幾個 vault 的唯一真相 |
| `whereOfIn` / `baseFromIn` | 修改(`Aapms.Store.Query`) | `whereOfIn :: Text -> NodeFilter -> (Text, [SQLData])` / `baseFromIn :: Text -> Text` —— 既有 `whereOf` / `baseFrom` 多吃一個 schema 前綴的一般化,`""` 時逐字等於原本的輸出 | 「`NodeFilter` 對應到哪一段 SQL」——這個知識**只有一份**,單一 vault 與跨 vault 共用,不會慢慢分歧 |

`drTarget` 的 `refVault` **恆為 `Just`**:它是「套用預設 vault 之後真正去找的地方」,而 `drLink` 裡的
`linkTarget` 保留檔案裡寫的原文(可能是 `Nothing`)。兩者都留著,因為診斷這種問題時「檔案裡寫了什麼」
與「程式去哪裡找」是兩個不同的問題。

## 介面

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data VaultSet` | 一組被接成整體、只供讀取的 vault | `store/src/Aapms/Store/MultiVault.hs:80` |
| `maxAttachedVaults :: Int` | 一個 `VaultSet` 最多接幾個 vault | `store/src/Aapms/Store/MultiVault.hs:87` |
| `openVaultSet :: [VaultHandle] -> IO (Either StoreError VaultSet)` | 把一組已開好的 vault 把手接成一個可跨 vault 查詢的整體;超過上限、或有兩個不同目錄帶著同一個 vault id 時失敗 | `store/src/Aapms/Store/MultiVault.hs:110` |
| `closeVaultSet :: VaultSet -> IO ()` | 釋放 `VaultSet` 自己持有的資源,不動任何 `VaultHandle` | `store/src/Aapms/Store/MultiVault.hs:119` |
| `vaultSetIds :: VaultSet -> [VaultId]` | 這個 `VaultSet` 實際涵蓋哪些 vault、依什麼順序 | `store/src/Aapms/Store/MultiVault.hs:126` |
| `lookupRef :: VaultSet -> VaultId -> Ref -> IO (Maybe (VaultId, AnyNode))` | 依 `Ref` 的 vault 欄位(缺省時用第二個參數)找出它指向的節點 | `store/src/Aapms/Store/MultiVault.hs:138` |
| `listAcross :: VaultSet -> NodeFilter -> IO [(VaultId, Meta)]` | 跨全部 vault 依條件列舉節點,每筆帶自己的 vault | `store/src/Aapms/Store/MultiVault.hs:144` |
| `searchAcross :: VaultSet -> SearchQuery -> IO SearchResult` | 跨全部 vault 全文檢索,每筆帶自己的 vault、片段與相關度 | `store/src/Aapms/Store/MultiVault.hs:158` |
| `data DanglingRef = DanglingRef { drSource :: Id, drLink :: Link, drTarget :: Ref, drReason :: DanglingReason }` | 一筆解析不到的關聯 | `store/src/Aapms/Store/MultiVault.hs:169` |
| `data DanglingReason = TargetVaultAbsent \| TargetNodeMissing` | 懸空的兩種成因 | `store/src/Aapms/Store/MultiVault.hs:186` |
| `checkReferences :: VaultSet -> VaultHandle -> IO [DanglingRef]` | 列出指定 vault 指出去、在這個 `VaultSet` 裡解析不到的全部關聯 | `store/src/Aapms/Store/MultiVault.hs:199` |
| `renderDanglingRef :: DanglingRef -> Text` | 給出一筆懸空引用的繁中訊息,說出下一步該做什麼 | `store/src/Aapms/Store/MultiVault.hs:204` |
| `TooManyVaults Int Int`(`StoreError` 建構子) | 說出「這次收到幾個 vault、上限是幾個」 | `store/src/Aapms/Store/Error.hs:76` |
| `VaultIdCollision VaultId FilePath FilePath`(`StoreError` 建構子) | 說出「哪個 vault id 撞號、是哪兩個目錄」 | `store/src/Aapms/Store/Error.hs:82` |
| `whereOfIn :: Text -> NodeFilter -> (Text, [SQLData])` | 給出一組 `NodeFilter` 對應的 SQL 條件與參數,表名帶指定的 schema 前綴 | `store/src/Aapms/Store/Query.hs:162` |
| `baseFromIn :: Text -> Text` | 給出查詢三張表的 `FROM` 子句,表名帶指定的 schema 前綴 | `store/src/Aapms/Store/Query.hs:225` |

共 **16 條**(`MultiVault` 的型別 3 + 函式 9、`StoreError` 建構子 2、`Query` 的 SQL 片段 2)。
後四條落在骨架清單之外的兩個既有檔案裡,**本次已由本 feature 寫出真正的本體**(它們是 F005 / F007
已交付程式碼的一部分,留 `undefined` 會炸掉既有的 208 條測試)——見「骨架」。

`VaultSet` 的不變量(全部由下方 Laws 釘死,這裡只列):只讀,不接管把手的生命週期;涵蓋的 vault
兩兩相異;跨 vault 的排序與分頁對合併後的整體成立;每筆結果的 `VaultId` 與該筆 `Meta` 的 `metaVault`
一致。

## Laws(行為性質)

> **記號**:`hs = [h1 … hn]` 是一組已 `openVault` 開好的把手,`vid h = vmId (vhMarker h)`,
> `Right vs = openVaultSet hs`。`wide f = f { nfLimit = N, nfOffset = 0 }`(`N` 大於任何一組樣本的
> 總筆數),`wideQ q = q { sqFilter = wide (sqFilter q) }`。
>
> **非退化前提**(下面每條 law 各自點名要用哪幾條;寫測試時**必須讓 fixture 滿足點名的那幾條**,
> 否則斷言恆真、證明不了任何事):
>
> - **P1**:`vs` 至少含**兩個** vault,且每個 vault 的索引都至少有一個符合當次過濾條件的節點
> - **P2**(排序鍵交錯):存在 vault A 的兩筆與 vault B 的一筆,使 B 的那一筆的排序鍵**落在 A 的
>   兩筆之間**(`listAcross` 的鍵是 `metaId`;`searchAcross` 的鍵是「`shScore` 遞減、`metaId` 遞增」)
> - **P3**(跨 vault 同短 id):存在一個 `Id i` 同時是 A 的節點與 B 的節點(ADR-014 明訂短 id 只在
>   vault 內唯一,這是合法狀態)
> - **P4**(三種關聯都在場):`checkReferences` 的目標 vault 裡同時有「解析得到」「目標 vault 在
>   集合裡但 id 查不到」「目標 vault 不在集合裡」三種關聯各至少一筆

**建立、上限與生命週期**

> **`openVaultSet` 的檢查順序**(2026-08-26 A5 裁決,L1 / L1b 依此分工,順序不可顛倒):
> ① 先查撞號(`vid` 相同但 `vhRoot` 不同)→ ② 再保序去重(`vid` 與 `vhRoot` 都相同)→ ③ 最後查上限。
> 先講資料問題再講範圍問題:撞號時任何 `Ref` 解析都是不確定的,先叫使用者收窄範圍等於叫他繞過去。

- **L1**(去重與上限):對所有**沒有撞號**的把手清單 `hs`(定義:任兩筆 `h`、`h'`,
  `vid h == vid h'` 蘊含 `vhRoot h == vhRoot h'`),令 `ks = nub (map vid hs)`(保序去重,同一個
  vault 只留**第一個**)。`length ks <= maxAttachedVaults` 時 `openVaultSet hs` 回 `Right vs`
  且 `vaultSetIds vs == ks`;`length ks > maxAttachedVaults` 時回
  `Left (TooManyVaults (length ks) maxAttachedVaults)`。且 `maxAttachedVaults == 10`。
  *非退化*:樣本必須同時含 `length ks == maxAttachedVaults` 與 `length ks == maxAttachedVaults + 1`
  兩組;**另外要有一組「同一個 vault(同路徑)重複到清單長度 > 上限、但 `length ks <= 上限`」**
  ——它必須成功,否則證明不了上限是以**去重後**的數量計。
- **L1b**(撞號):對所有存在兩筆 `h`、`h'` 使 `vid h == vid h'` 且 `vhRoot h /= vhRoot h'` 的 `hs`,
  `openVaultSet hs` 回 `Left (VaultIdCollision v p q)`,其中 `v` 是撞號的 vault id,`p` / `q` 是那
  兩筆的 `vhRoot`(依它們在 `hs` 中出現的先後)。**撞號優先於上限**:即使原始清單長度已經超過
  `maxAttachedVaults`,回的仍是 `VaultIdCollision` 而不是 `TooManyVaults`。
  *非退化*:樣本要同時含「撞號且清單長度 `<=` 上限」與「撞號且清單長度 `>` 上限」兩組——只有後者
  在場才證明得了優先順序;而且撞號的那兩個 vault **各自的索引都要非空**,否則「少了一個 vault 的
  東西」這個症狀在測試裡看不出來。
- **L2**:對所有 `hs`、所有 `h ∈ hs`、所有 `f`:`closeVaultSet vs` 之後 `listNodes h f` 的結果與
  `openVaultSet hs` 之前逐筆相同,且其後的 `closeVault h` 仍正常完成。
  *非退化*:P1(每個 vault 的索引非空——兩邊都是 `[]` 的話這條恆真)。
- **L3**:對所有 `h ∈ hs`、所有 `f` 與 `q`:在 `openVaultSet hs` 之後、以及任意次數的 `listAcross` /
  `searchAcross` / `lookupRef` / `checkReferences` 之後,`listNodes h f` 與 `search h q` 的結果都與
  `openVaultSet` 之前逐筆相同(`VaultSet` 不改變單一 vault 的讀取行為)。
  *非退化*:P1;且 `q` 的樣本要有文字條件(只測 `sqText = Nothing` 等於沒測到 FTS 那條路)。

**`listAcross`**

- **L4**(過濾語意只有一份):對所有 `f`,`listAcross vs (wide f)` 的**多重集合**等於
  `concat [ [(vid h, m) | m <- listNodes h (wide f)] | h <- hs ]` 的多重集合。
  *非退化*:P1;且樣本必須讓 `nfPrefixes` / `nfTypes` / `nfStatus` / `nfTags` / `nfOwner` /
  `nfLicense` / `nfNamedOnly` / `nfIncludeReference` **各至少有一組非預設值**且該值真的篩掉了東西
  ——全預設的 `f` 只證明得了「兩邊都沒過濾」。
  **`nfTags` 與 `nfIncludeReference` 這兩項要另外安排 fixture**。理由:整段 WHERE 裡有
  **兩處**直接寫出表名(其餘全用 `n` / `a` / `p` 別名),schema 前綴漏掉時它們會拿**別的
  vault** 的那張表來篩這個 vault 的節點;而只要**只有一個 vault 有那種資料**,對的實作與錯的
  實作就會給出**相同答案**,fixture 抓不到:
  1. **`nfTags` → `node_tags` 存在性子查詢**。兩個 vault **各自都要有標籤,而且標籤集合要能
     分辨**(例:A 的節點帶 `["琳達"]`、B 的節點帶 `["藥水"]`)。見 E17
  2. **`nfIncludeReference` → `packs` 的 reference 子查詢**。兩個 vault **各自都要有**一個位於
     `library/reference/` 底下的 pack 與它底下的 asset。而且 `nfIncludeReference` 的預設值是
     `False`,這條路是**預設路徑**。見 E16
- **L5**(全域排序):對所有 `f`,`listAcross vs (wide f)` 相鄰的兩筆 `(v1, m1)`、`(v2, m2)` 滿足
  `metaId m1 < metaId m2`,或 `metaId m1 == metaId m2 && v1 < v2`。
  *非退化*:P2 + P3。少了 P2,「各 vault 各自排完再接」也會滿足這條。
- **L6**(分頁是對整體切窗):對所有 `f` 與所有 `j >= 0`、`k >= 0`,
  `listAcross vs f { nfOffset = j, nfLimit = k } == take k (drop j (listAcross vs (wide f)))`。
  *非退化*:P2;且 `(j, k)` 的樣本必須含「視窗**跨越** vault 邊界」與「視窗**完全落在後一個
  vault 的節點上**」兩種——只取 `j = 0` 的話「各自排完再接」在前綴上可能剛好一致。
- **L7**(vault 欄一致):對所有 `f`,`listAcross vs f` 的每一筆 `(v, m)` 滿足 `metaVault m == v`,
  且 `v ∈ vaultSetIds vs`。
  *非退化*:P1。單一 vault 下這條永遠成立,證明不了「`Meta` 是用哪個 vault hydrate 出來的」。

**`searchAcross`**

- **L8**(逐 vault 等價,四欄逐欄相同):對所有 `q`,令 `q' = (wideQ q) { sqFacets = False }`,則
  `srHits (searchAcross vs q')` 的多重集合等於 `concat [ srHits (search h q') | h <- hs ]` 的多重
  集合,比較的是 `shVault` / `shMeta` / `shSnippet` / `shScore` **四欄全部**。
  (相關度與片段逐 vault 計算:各 vault 的 bm25 只看自己的索引,合併只影響排序與分頁。)
  *非退化*:P1;且樣本必須含一個「在**兩個** vault 都有命中」的 `sqText`,以及一個 `sqText = Nothing`
  的樣本。
- **L9**(全域排序):`srHits (searchAcross vs q')` 相鄰兩筆 `a`、`b` 滿足
  `shScore a > shScore b`,或分數相同且 `metaId (shMeta a) < metaId (shMeta b)`,或兩者都相同且
  `shVault a < shVault b`。
  *非退化*:P2 的分數版(A 的一筆分數落在 B 的兩筆之間)+ P3。
- **L10**(分頁與 `srTotal`):對所有 `q` 與所有 `j`、`k`,令
  `qjk = q { sqFilter = (sqFilter q) { nfOffset = j, nfLimit = k } }`,則
  `srHits (searchAcross vs qjk) == take k (drop j (srHits (searchAcross vs (wideQ q))))`;
  `srTotal (searchAcross vs qjk) == srTotal (searchAcross vs (wideQ q))`;且
  `srTotal (searchAcross vs (wideQ q)) == sum [ srTotal (search h (wideQ q)) | h <- hs ]`。
  *非退化*:P2;`(j, k)` 的樣本要求同 L6。
- **L11**(vault 欄一致,檢索側):對所有 `q`,`srHits (searchAcross vs q)` 的每一筆 `x` 滿足
  `metaVault (shMeta x) == shVault x` 且 `shVault x ∈ vaultSetIds vs`。
  *非退化*:P1。
- **L12**(facet):對所有 `q`,`sqFacets q == False` ⟺ `srFacets == Nothing`。`sqFacets q == True`
  時 `srFacets == Just fc`,且:
  1. `fcVaults fc` 恰好是「命中數 > 0 的那些 vault」各一筆,每筆的計數等於該 vault 單獨
     `srTotal (search h (wideQ q))`,且 `sum (map snd (fcVaults fc)) == srTotal`
  2. `fcTypes` / `fcTags` / `fcOwners` / `fcLicenses` 的每一筆 `(v, n)`,`n` 等於**各 vault 對同一個
     值的計數之和**
  3. 四個維度都維持 F007 L17 的性質:`fcTypes` 不因 `nfTypes` 改變、`fcTags` 不因 `nfTags` 改變、
     `fcOwners` 不因 `nfOwner` 改變、`fcLicenses` 不因 `nfLicense` 改變
  *非退化*:P1;**至少一個 type 與一個 tag 要在兩個 vault 都出現**(fixture 的共同標籤
  `"canon"` 就是為此)——否則「求和」與「取其中一個」給出相同答案,子句 2 證明不了任何事;
  **另外要有一組「某個 vault 對這個 `q` 完全沒有命中」的樣本**——單一 vault 的
  `Aapms.Store.Query.search` 在零命中時 `fcVaults` 仍會回 `[(vid, 0)]`,合併時沒把計數 0 的濾掉
  就會在側欄列出一個空 vault,而這在「兩個 vault 都有命中」的樣本下看不出來。

> **facet 走哪一條**(對應 A1 的 `searchAcross` 走 Haskell):跨 vault 的 facet 是
> **逐 vault 呼叫公開的 `Aapms.Store.Query.search h q { sqFacets = True }` 拿到各自的
> `FacetCounts`,再在 Haskell 合併**(同值求和、濾掉計數 0、依「計數遞減、同計數值遞增」重排)。
> **不重用、也不修改 `Query.hs` 的私有 `computeFacets`**——它裡面有 `FROM node_tags` 之類的
> 裸表名,而它是單一 vault 專用的函式,`searchAcross` 碰不到它,維持原樣。
> 子句 3(facet 排除自己的條件)因此是 F007 L17 的直接後果:每個 vault 各自已經排除過,求和
> 保持這個性質。



**`lookupRef`**

- **L13**(帶 vault 的 `Ref` 只認自己那個 vault):對所有 `h ∈ hs`、所有 `Id i`、所有
  `v ∈ vaultSetIds vs`:
  `lookupRef vs v (Ref (Just (vid h)) i)` 的結果等於 `fmap ((,) (vid h)) <$> lookupNode h i`。
  *非退化*:P3;且 `v` 的樣本必須同時含 `v == vid h` 與 `v /= vid h`。
- **L14**(預設 vault):對所有 `v ∈ vaultSetIds vs` 與所有 `i`,
  `lookupRef vs v (Ref Nothing i) == lookupRef vs v (Ref (Just v) i)`。
  *非退化*:P3(否則「忽略 `refVault` 一律全 vault 掃描」也會滿足)。
- **L15**(vault 不在集合裡):對所有不屬於 `vaultSetIds vs` 的 `w`、所有 `v ∈ vaultSetIds vs`、
  所有 `i`,`lookupRef vs v (Ref (Just w) i) == Nothing`。
  *非退化*:`i` 必須是**在 `vs` 的某個 vault 裡真的存在**的 id——否則 `Nothing` 只是因為那個 id
  根本不存在。

**`checkReferences`**

- **L16**(完整且不多報):對所有 `vs` 與所有 `h`(`h` **不必**屬於 `hs`),
  `checkReferences vs h` 的結果(視為集合)等於

  ```
  [ DanglingRef { drSource = s, drLink = l, drTarget = t, drReason = r }
  | (s, ls) <- Map.toList  <$> loadLinkGraph h
  , l       <- ls
  , let t = case linkTarget l of Ref mv i -> Ref (Just (fromMaybe (vid h) mv)) i
  , Just r  <- [reasonOf t] ]
  ```

  其中 `reasonOf (Ref (Just w) i)`
  = `Just TargetVaultAbsent`(`w ∉ vaultSetIds vs`)
  / `Just TargetNodeMissing`(`w ∈ vaultSetIds vs` 且 `lookupRef vs (vid h) (Ref (Just w) i)` 是
    `Nothing`)
  / `Nothing`(其餘)。
  `drLink` 逐欄等於 `loadLinkGraph h` 給的那一筆(含 `linkNote` 與可能為 `Nothing` 的
  `refVault`),`drTarget` 的 `refVault` 恆為 `Just`。
  *非退化*:P4——三種關聯都要在場。只有「全部解析得到」的 fixture 會讓 `[] == []` 恆真;只有懸空
  的 fixture 證明不了它會放過正常的關聯。
- **L17**(`renderDanglingRef`):對所有 `d`,`renderDanglingRef d` 非空;含 `renderId (drSource d)`
  這個子字串;含 `renderRef (drTarget d)` 這個子字串;且把訊息以 `;` / `;` / `,` / `,` / `。`
  切成子句後,至少有一段(去頭尾空白)以「請」起頭(與 F008 L15 對 `renderStoreError` 同一個判準)。
  且 `TargetVaultAbsent` 與 `TargetNodeMissing` 兩種成因的訊息**不相等**。
  *非退化*:樣本要含兩種 `drReason` 各至少一筆。

**退化情形**

- **L18**(空集合):`openVaultSet []` 回 `Right vs`,`vaultSetIds vs == []`,且對所有 `f` / `q` /
  `v` / `r` / `h`:`listAcross vs f == []`;`searchAcross vs q` 回
  `SearchResult { srHits = [], srTotal = 0, srFacets = <依 sqFacets 決定> }`;
  `lookupRef vs v r == Nothing`;`checkReferences vs h` 的每一筆 `drReason` 都是 `TargetVaultAbsent`。
  *非退化*:最後一句要求 `h` 的索引裡**至少有一筆關聯**(沒有關聯時 `[] == []` 恆真)。
- **L19**(單一 vault 退化成 F006 / F007):對所有 `f` 與 `q`,`openVaultSet [h]` 之後
  `map snd <$> listAcross vs f == listNodes h f`(逐筆同序),且
  `searchAcross vs q == search h q`(逐欄相同,含 `srTotal` 與 `srFacets`)。
  *非退化*:`h` 的索引非空,且 `q` 的樣本要含有文字條件與 `sqFacets = True` 各一組;`f` 的樣本要
  含 `nfIncludeReference = False` 且 `h` 底下有 reference pack 的一組(理由同 L4)。

**新增的兩個 `StoreError` 建構子**

- **L20**:`renderStoreError (TooManyVaults n limit)` 非空,含 `show n` 與 `show limit` 兩個數字的
  文字,且切成子句後至少有一段以「請」起頭;`renderStoreError (VaultIdCollision v p q)` 非空,含
  `v` 的文字與 `p`、`q` 兩個路徑字串,且同樣有以「請」起頭的子句。兩則訊息互不相等。
  (判準與 F008 L15 相同:以 `;` / `;` / `,` / `,` / `。` 切子句,去頭尾空白後比對開頭。)
  *非退化*:`n /= limit` 且 `p /= q`——兩個數字相同、兩個路徑相同時,只印其中一個也會通過。

## Examples

> **Fixture 前提**(E1–E12 共用,**每一條都是斷言成立的必要條件,合成 fixture 時不得省略**):
>
> - **F-A**(story vault):marker `vmId = VaultId "vlt-aaaa0001"`、`vmKind = StoryVault`。含一份
>   主題檔,主體節點 id `ent-00000001`、`metaTitle = "琳達的藥水日記"`;同檔另有兩個片段
>   `ent-00000005`(`metaTitle` 不含「藥水」)與 `ent-00000007`
> - **F-B**(asset vault):marker `vmId = VaultId "vlt-bbbb0002"`、`vmKind = AssetVault`。含
>   `library/packs/potions/pack.md`:pack `pck-00000001`、asset `ast-00000002`
>   (`metaTitle = "魔法藥水瓶"`);**另含一份主題檔**,其主體節點 id **逐字等於**
>   `ent-00000001`、`metaTitle = "B 庫的同號節點"`,再一個片段 `ent-00000003`
> - **兩個 vault 的 `vmId` 相異**(`openVaultSet` 的去重與 `shVault` 有意義的前提)
> - **`ent-00000001` 在兩個 vault 都存在**(P3)。ADR-014 明訂短 id 只在 vault 內唯一,ADR-017 第一
>   條明訂 `kind` 是運維分界不是資料模型分界,所以 asset vault 裡有主題檔是合法的
> - **id 交錯**(P2):排序後是 `A:ent-…01` < `B:ent-…01` < `B:ent-…03` < `A:ent-…05` < `A:ent-…07`
> - **兩個 vault 各自都有一個 reference pack**(在自己的 `library/reference/` 底下)與它底下的
>   asset。這是 L4 / L19 的 `nfIncludeReference` 那一半成立的必要條件:reference 排除子句是整段
>   WHERE 裡**兩處直接寫出表名**之一,只有一邊有 reference pack 的話,schema 前綴漏掉與沒漏掉
>   會給出相同答案
> - **兩個 vault 各自都有標籤,而且標籤集合可分辨**:F-A 的 `ent-00000001` 帶
>   `metaTags = ["琳達", "canon"]`、F-B 的 `ast-00000002` 帶 `metaTags = ["藥水", "canon"]`。
>   兩邊各有一個**只有自己有**的標籤(L4 / E17 的 `nfTags` 那一半要靠它:另一處直接寫出表名的
>   地方是 `node_tags` 子查詢,只有一邊有標籤的話對錯實作給出相同答案),外加一個**兩邊都有**的
>   標籤 `"canon"`(L12 的 facet 求和要靠它:兩邊沒有共同值的話,「求和」與「取其中一個」給出
>   相同答案)。兩個要求同時成立,缺一條都會讓對應的 law 變成恆真
> - 兩個 vault 都跑過 `rebuildIndex`,`listNodes` 各自回得出東西
> - `vsAB` 表示 `openVaultSet [hA, hB]` 成功後的那個 `VaultSet`

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| E1 | `searchAcross vsAB (emptySearchQuery { sqText = Just "藥水" })` | `srHits` 恰兩筆:一筆 `shVault == VaultId "vlt-aaaa0001"` 且 `metaId (shMeta) == ent-00000001`,一筆 `shVault == VaultId "vlt-bbbb0002"` 且 `metaId (shMeta) == ast-00000002`;兩筆都 `shScore > 0`、`shSnippet` 含「藥水」、`metaVault (shMeta) == shVault`;`srTotal == 2` | **契約卡驗收 1**:一次回兩種 vault、每筆 `shVault` 正確 |
| E2 | `listAcross vsAB emptyNodeFilter { nfLimit = 10 }`,再取 `listAcross vsAB emptyNodeFilter { nfOffset = 1, nfLimit = 2 }` | 第一次(只看 `ent-` 的部分)依序是 `[(A, ent-…01), (B, ent-…01), (B, ent-…03), (A, ent-…05), (A, ent-…07)]`;第二次是 `[(B, ent-…01), (B, ent-…03)]` | **契約卡驗收 2**:排序與分頁跨 vault。「各自排完再接」會給 `[A01, A05, A07, B01, B03]`,第二次會是 `[(A, ent-…05), (A, ent-…07)]` —— 兩種作法在這裡給出完全不同的答案 |
| E3 | `lookupRef vsAB (VaultId "vlt-aaaa0001") (Ref Nothing (Id "ent-00000001"))` 與 `lookupRef vsAB (VaultId "vlt-bbbb0002") (Ref Nothing (Id "ent-00000001"))` | 前者 `Just (VaultId "vlt-aaaa0001", n)` 且 `metaTitle (anyMeta n) == "琳達的藥水日記"`;後者 `Just (VaultId "vlt-bbbb0002", n')` 且 `metaTitle (anyMeta n') == "B 庫的同號節點"` | **契約卡驗收 3**:不帶 vault 的 `Ref` 以呼叫端指定的預設 vault 解析(前提:同一短 id 在兩個 vault 都存在) |
| E4 | `lookupRef vsAB (VaultId "vlt-aaaa0001") (Ref (Just (VaultId "vlt-bbbb0002")) (Id "ent-00000001"))` | `Just (VaultId "vlt-bbbb0002", n')`,`metaTitle (anyMeta n') == "B 庫的同號節點"` | 帶 vault 的 `Ref` 覆蓋預設 vault |
| E5 | `lookupRef vsAB (VaultId "vlt-aaaa0001") (Ref (Just (VaultId "vlt-cccc0003")) (Id "ent-00000001"))`,其中 `vlt-cccc0003` 不在集合裡 | `Nothing` | 目標 vault 不在集合裡(id 本身在兩個 vault 都存在,所以 `Nothing` 只可能來自 vault 路由) |
| E6 | `openVaultSet` 對 11 個 `vmId` 兩兩相異的把手;再對其中任意 10 個 | 前者 `Left (TooManyVaults 11 10)`;後者 `Right vs` 且 `length (vaultSetIds vs) == 10` | **契約卡驗收 4**:第 11 個 vault 回 `TooManyVaults` 並列出 10 |
| E7 | `openVaultSet [hA, hB, hA2]`,其中 `hA2` 是對**同一個路徑** F-A 再 `openVault` 一次(`vmId` 與 `vhRoot` 都相同、`Connection` 不同) | `Right vs`,`vaultSetIds vs == [VaultId "vlt-aaaa0001", VaultId "vlt-bbbb0002"]` | 同一路徑重複傳 → 保序去重,同 vault 只留第一個 |
| E8 | F-A 的 `ent-00000001` 有三筆關聯:① `uses` → `vlt-bbbb0002:ast-00000002`(存在)② `references` → `ent-0000dead`(不帶 vault,F-A 裡沒這個 id)③ `derivedFrom` → `vlt-cccc0003:ent-00000001`(該 vault 不在集合裡)。呼叫 `checkReferences vsAB hA` | 恰兩筆:`DanglingRef ent-00000001 <②的 Link 原文> (Ref (Just (VaultId "vlt-aaaa0001")) (Id "ent-0000dead")) TargetNodeMissing` 與 `DanglingRef ent-00000001 <③的 Link 原文> (Ref (Just (VaultId "vlt-cccc0003")) (Id "ent-00000001")) TargetVaultAbsent`;①不出現 | **契約卡驗收 5**:兩種懸空都找得到,而且解析得到的那一筆不會被誤報 |
| E9 | 對 E8 的兩筆各呼叫 `renderDanglingRef` | 兩則訊息都非空、互不相等;各含 `"ent-00000001"`;第一則含 `"vlt-aaaa0001:ent-0000dead"`、第二則含 `"vlt-cccc0003:ent-00000001"`;兩則都有以「請」起頭的子句 | 錯誤/問題訊息的契約 G 判準 |
| E10 | `openVaultSet []` 之後 `listAcross vs emptyNodeFilter`、`searchAcross vs emptySearchQuery`、`lookupRef vs (VaultId "vlt-aaaa0001") (Ref Nothing (Id "ent-00000001"))`、`checkReferences vs hA` | `[]`;`SearchResult [] 0 Nothing`;`Nothing`;`checkReferences` 對 `hA` 的**每一筆**關聯各回一筆,`drReason` 全是 `TargetVaultAbsent`(以 E8 的 fixture 就是三筆) | 空集合不是錯誤;空集合下「本 vault 自己」也不在集合裡 |
| E11 | `openVaultSet [hA]` 之後 `listAcross vs emptyNodeFilter` 與 `searchAcross vs (emptySearchQuery { sqText = Just "藥水", sqFacets = True })` | `map snd` 逐筆等於 `listNodes hA emptyNodeFilter`、每筆 `fst == VaultId "vlt-aaaa0001"`;`searchAcross` 逐欄等於 `search hA` 的同一個查詢(含 `srTotal` 與 `srFacets`) | 單一 vault 退化成 F006 / F007 的行為 |
| E12 | `searchAcross vsAB (emptySearchQuery { sqText = Just "藥水", sqFacets = True })` | `fcVaults == [(VaultId 的文字 "vlt-aaaa0001", 1), ("vlt-bbbb0002", 1)]`(計數相同時以值遞增),和等於 `srTotal == 2`;`closeVaultSet` 之後 `listNodes hA emptyNodeFilter` 與呼叫前逐筆相同,`closeVault hA` 正常完成 | facet 的 vault 維度跨 vault;`VaultSet` 不接管把手的生命週期 |
| E13 | 把 F-A 的整個目錄**複製**成 `F-A'`(marker 逐位元組相同,所以 `vmId` 也是 `vlt-aaaa0001`),`openVault` 之後 `openVaultSet [hA, hB, hA']` | `Left (VaultIdCollision (VaultId "vlt-aaaa0001") <hA 的 vhRoot> <hA' 的 vhRoot>)`;**不是** `Right`、也**不是**去重後的成功 | **A5 裁決**:兩個不同目錄帶同一個 vault id 是資料問題,靜默去重會讓「搜尋結果少了一個 vault」沒有人發現 |
| E14 | 對 11 個 `vmId` 相異的把手清單,把其中一個換成 F-A 的複製(於是清單長度 > 上限**且**撞號) | `Left (VaultIdCollision …)`,不是 `Left (TooManyVaults …)` | 撞號優先於上限(L1b):先講資料問題,再講範圍問題 |
| E15 | `renderStoreError (TooManyVaults 11 10)` 與 `renderStoreError (VaultIdCollision (VaultId "vlt-aaaa0001") "C:/a" "C:/b")` | 兩則都非空、互不相等;第一則含 `"11"` 與 `"10"`,第二則含 `"vlt-aaaa0001"`、`"C:/a"`、`"C:/b"`;兩則都有以「請」起頭的子句 | 契約 G:兩個數字 / 兩個路徑都要列出來,且每則說出下一步 |
| E16 | 兩個 vault 各自的 `library/reference/` 底下各有一個 pack。`listAcross vsAB emptyNodeFilter`(`nfIncludeReference` 預設 `False`),再與 `nfIncludeReference = True` 比較 | 預設時**兩個 vault 的 reference pack 與它們底下的 asset 都不出現**;改成 `True` 時兩邊的都出現。兩次結果的差集恰好是兩個 vault 的 reference 節點聯集 | WHERE 裡**兩處寫出表名之一**(`packs` 的 reference 子查詢);schema 前綴漏掉時會拿 A 的 reference 清單去篩 B 的節點,而它走的是預設路徑 |
| E17 | 標籤如 fixture 前提(A:`["琳達", "canon"]`,B:`["藥水", "canon"]`)。依序 `listAcross vsAB emptyNodeFilter { nfTags = ["琳達"] }`、`nfTags = ["藥水"]`、`nfTags = ["canon"]`、`nfTags = ["琳達", "藥水"]` | 第一次**只回** `[(VaultId "vlt-aaaa0001", <ent-00000001 的 Meta>)]`;第二次**只回** `[(VaultId "vlt-bbbb0002", <ast-00000002 的 Meta>)]`;第三次**兩筆都回**(各一);第四次回 `[]`(`nfTags` 的多個標籤是 AND,沒有節點同時帶兩個) | WHERE 裡**兩處寫出表名之二**(`node_tags` 存在性子查詢);schema 前綴漏掉時會拿 B 的標籤表去篩 A 的節點——**兩邊都要有標籤且各有一個只有自己有的標籤,只有一邊有的話對錯實作給出相同答案**;第三次是共同標籤的對照 |

## 依賴

`depends-on: [F001, F005, F006, F007]`(功能規劃的「依賴」欄寫 `#7`;下方「使用到的既有介面」表另外
指得出對 F006 / F005 / F001 的直接呼叫,依 `conventions` 的「反推 depends-on」機械檢查補上,作法與
F007 一致)。

- **F007**:`SearchQuery` / `SearchHit` / `FacetCounts` / `SearchResult` / `search` / `emptySearchQuery`
  是 `searchAcross` 的形狀與對照基準(L8 / L10 / L12 / L19);`Aapms.Store.Tokenize` 的 `routeOf` /
  `triMatchExpr` / `cjkMatchExpr` 是 UNION 路徑重用的查詢路由
- **F006**:`NodeFilter` / `emptyNodeFilter` / `listNodes` / `lookupNode` / `loadLinkGraph` 與
  `nodes` + 專屬表的 schema;`Aapms.Store.Row` 的列 → `Meta` 轉換
- **F005**:`VaultHandle` / `VaultMarker` / `openVault` / `closeVault` / `indexDbPath` 與
  `StoreError` / `trySqlite`
- **F001**:`Ref` / `VaultId` / `Id` / `Link` / `LinkGraph` / `Meta` / `AnyNode` 與 `renderRef` /
  `renderId`

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection, vhRegistry :: TypeRegistry }` | `store/src/Aapms/Store/Marker.hs:73` | F005 | `openVaultSet` 的輸入;`vhRoot` 推得出各 vault 的 `index.db` 路徑 |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57` | F005 | `vaultSetIds`、去重的鍵、每筆結果的 `VaultId` |
| `indexDbPath :: FilePath -> FilePath` | `store/src/Aapms/Store/Marker.hs:52` | F005 | `ATTACH` 的檔案路徑(`\<root\>/.aapms/index.db`) |
| `openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))` | `store/src/Aapms/Store/Marker.hs:182` | F005 | Examples 的 fixture 建立 |
| `closeVault :: VaultHandle -> IO ()` | `store/src/Aapms/Store/Marker.hs:192` | F005 | L2:`closeVaultSet` 之後仍要能單獨關 |
| `data StoreError = VaultMarkerMissing FilePath \| … \| NodeDepthExceeded Id Int` | `store/src/Aapms/Store/Error.hs:29` | F005 | `TooManyVaults` 是它的**新建構子**(契約 G:唯一錯誤型別)。型別由 F005 建、F006 / F008 各自擴充過建構子,本 feature 依賴的是**型別本身**,沒有呼叫任何 F006 / F008 新增的建構子 |
| `renderStoreError :: StoreError -> Text` | `store/src/Aapms/Store/Error.hs:91` | F005 | 本次補上 `TooManyVaults` 與 `VaultIdCollision` 兩個分支(A4 / A5 裁決) |
| `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/Aapms/Store/Error.hs:207` | F005 | `openVaultSet` 的 `ATTACH` 例外收斂(套件與 SQLite 之間的唯一邊界) |
| `data NodeFilter = NodeFilter { nfPrefixes :: [IdPrefix], nfTypes :: [TypeKey], nfStatus :: [Status], nfTags :: [Text], nfOwner :: Maybe Id, nfLicense :: Maybe Ref, nfNamedOnly :: Bool, nfIncludeReference :: Bool, nfLimit :: Int, nfOffset :: Int }` | `store/src/Aapms/Store/Query.hs:102` | F006 | `listAcross` 的輸入,語意不變 |
| `emptyNodeFilter :: NodeFilter` | `store/src/Aapms/Store/Query.hs:119` | F006 | Examples 的基準過濾條件 |
| `listNodes :: VaultHandle -> NodeFilter -> IO [Meta]` | `store/src/Aapms/Store/Query.hs:240` | F006 | L4 / L19 的對照基準 |
| `lookupNode :: VaultHandle -> Id -> IO (Maybe AnyNode)` | `store/src/Aapms/Store/Query.hs:325` | F006 | L13:`lookupRef` 路由到目標 vault 之後就是它 |
| `loadLinkGraph :: VaultHandle -> IO LinkGraph` | `store/src/Aapms/Store/Query.hs:525` | F006 | L16:`checkReferences` 要走過的那一份關聯清單 |
| `whereOf :: NodeFilter -> (Text, [SQLData])` | `store/src/Aapms/Store/Query.hs:143` | F006 / F007 | 單一 vault 的三個呼叫端(`listNodes` / `structuralIds` / `ftsHits`)用它;本次改成 `whereOfIn ""` 的特化,**呼叫端一行未動、產生的 SQL 逐字相同** |
| `baseFrom :: Text` | `store/src/Aapms/Store/Query.hs:220` | F006 | 同上,本次改成 `baseFromIn ""` 的特化 |
| `data SearchQuery = SearchQuery { sqText :: Maybe Text, sqFilter :: NodeFilter, sqFacets :: Bool }` | `store/src/Aapms/Store/Query.hs:536` | F007 | `searchAcross` 的輸入 |
| `emptySearchQuery :: SearchQuery` | `store/src/Aapms/Store/Query.hs:548` | F007 | Examples 的基準查詢 |
| `data SearchHit = SearchHit { shVault :: VaultId, shMeta :: Meta, shSnippet :: Text, shScore :: Double }` | `store/src/Aapms/Store/Query.hs:558` | F007 | 跨 vault 的每筆結果;`shVault` 這一欄本來就是為了 F009 而存在 |
| `data FacetCounts = FacetCounts { fcTypes, fcVaults, fcTags, fcOwners, fcLicenses :: [(Text, Int)] }` | `store/src/Aapms/Store/Query.hs:570` | F007 | L12 |
| `data SearchResult = SearchResult { srHits :: [SearchHit], srTotal :: Int, srFacets :: Maybe FacetCounts }` | `store/src/Aapms/Store/Query.hs:580` | F007 | `searchAcross` 的輸出 |
| `search :: VaultHandle -> SearchQuery -> IO SearchResult` | `store/src/Aapms/Store/Query.hs:591` | F007 | L8 / L10 / L12 / L19 的對照基準 |
| `routeOf :: Text -> SearchRoute` | `store/src/Aapms/Store/Tokenize.hs:228` | F007 | 跨 vault 的 FTS 路由與單 vault 用同一份判斷 |
| `triMatchExpr :: Text -> Maybe Text` | `store/src/Aapms/Store/Tokenize.hs:241` | F007 | 同上 |
| `cjkMatchExpr :: Text -> Maybe Text` | `store/src/Aapms/Store/Tokenize.hs:256` | F007 | 同上 |
| `usesTrigram :: SearchRoute -> Bool` / `usesCjk :: SearchRoute -> Bool` | `store/src/Aapms/Store/Tokenize.hs:215` / `:221` | F007 | 同上 |
| `hydrateMeta :: VaultId -> Connection -> NodeRow -> IO Meta` | `store/src/Aapms/Store/Row.hs:239` | F006 | **L7 / L11 的關鍵**:第一個參數決定 `metaVault`,跨 vault 時必須是**該列真正來自的 vault** |
| `nodeColumns :: Text` | `store/src/Aapms/Store/Row.hs:137` | F006 | UNION 各 vault 的 `nodes` 表時的欄位清單 |
| `sText :: Text -> SQLData` / `inList :: Int -> Text` | `store/src/Aapms/Store/Row.hs:515` / `:552` | F006 | SQL 參數拼裝 |
| `renderIndexIssue :: IndexIssue -> Text` | `store/src/Aapms/Store/Schema.hs:106` | F005 / F006 | `renderDanglingRef` 的先例(「回報型 DTO 也有 render」) |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }` | `core/src/Aapms/Core/Id.hs:156` | F001 | `lookupRef` 的輸入、`drTarget` |
| `newtype VaultId = VaultId Text` | `core/src/Aapms/Core/Id.hs:148` | F001 | 跨 vault 身分的一半 |
| `newtype Id = Id Text` | `core/src/Aapms/Core/Id.hs:86` | F001 | 跨 vault 身分的另一半 |
| `renderRef :: Ref -> Text` | `core/src/Aapms/Core/Id.hs:181` | F001 | L17 / E9 的訊息內容 |
| `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:123` | F001 | 同上 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/Aapms/Core/Link.hs:53` | F001 | `drLink` |
| `type LinkGraph = M.Map Id [Link]` | `core/src/Aapms/Core/Link.hs:172` | F001 | `checkReferences` 的走訪對象 |
| `data AnyNode = NEntity Entity \| NAsset Asset \| NPack Pack \| NLicense License \| NLevel Level \| NNode Node` | `core/src/Aapms/Core/AnyNode.hs:19` | F001 | `lookupRef` 的輸出 |
| `anyMeta :: AnyNode -> Meta` | `core/src/Aapms/Core/AnyNode.hs:28` | F001 | E3 / E4 的斷言 |
| `data Meta = Meta { metaId :: Id, metaVault :: VaultId, … }` | `core/src/Aapms/Core/Meta.hs:123` | F001 | `listAcross` 的輸出;`metaVault` 是 L7 / L11 的斷言對象 |

### 依賴方向

- **依賴誰**:`Aapms.Store.MultiVault` → `Aapms.Store.Marker`(`VaultHandle`)、`Aapms.Store.Query`
  (`NodeFilter` / `SearchQuery` / `SearchResult`,以及 impl 階段的 `listNodes` / `lookupNode` /
  `loadLinkGraph` / `search`)、`Aapms.Store.Error`(`StoreError`)、`aapms-core`
  (`Id` / `Link` / `Meta` / `AnyNode`)、`sqlite-simple`(`Connection`)
- **誰會依賴它**:`Aapms.Store`(門面 re-export);更上層是 `service` 的查詢端點(ADR-017「查詢預設
  跨全部 vault」)與 `conflict`;`workspace` **不**依賴它——它只負責把路徑交出來
- **新增的依賴邊**(一條都不能漏):
  1. `Aapms.Store.MultiVault` → `Aapms.Store.Marker`(新模組)
  2. `Aapms.Store.MultiVault` → `Aapms.Store.Query`(新模組;design.md「模組間公開介面」已登記
     「MultiVault → Query」這條邊)
  3. `Aapms.Store.MultiVault` → `Aapms.Store.Error`(新模組)
  4. `Aapms.Store.MultiVault` → `Aapms.Core.{AnyNode, Id, Link, Meta}`(新模組)
  5. `Aapms.Store` → `Aapms.Store.MultiVault`(門面 re-export)
  6. (impl 階段還會新增,都在既有 `build-depends` 內、都不成環)
     `Aapms.Store.MultiVault` → `Aapms.Store.Row`(列 → `Meta`)與
     `Aapms.Store.MultiVault` → `Aapms.Store.Tokenize`(FTS 路由)
  沒有任何**套件層**的新相依:`aapms-store` 的 `build-depends` 不變
- **既有模組被動到的兩處**(都不新增 import 方向):
  - `Aapms.Store.Error` 的 import 從 `Aapms.Core.Id (Id, renderId, renderRef)` 擴成
    `(Id, VaultId (..), renderId, renderRef)`——`Aapms.Core.Id` 本來就已經是它的相依,**不是新的邊**。
    契約 G 的前提維持成立:`Error.hs` 依舊**不 import 任何 `Aapms.Store.*`**
  - `Aapms.Store.Query` 只多了兩個匯出符號(`whereOfIn` / `baseFromIn`),**沒有新增任何 import**
- **可否與其他進行中任務平行開發**:可以,但 W7 只有這一個 feature。它是 `aapms-store` 內部依賴圖的
  新葉子(除了門面之外沒有人 import 它),不動任何既有簽名

## 不可逆決定

- **D1:跨 vault 的身分是 `(VaultId, Id)` 這一對,不是 `Id`**。`listAcross` 回 `[(VaultId, Meta)]`、
  `SearchHit` 帶 `shVault`、`lookupRef` 回 `(VaultId, AnyNode)`,而排序的最後一段 tie-break 是
  `VaultId`(L5 / L9)。
  *否決:合併時以 `Id` 去重*——這正是 F007 單一 vault 版 `mergeHits` 的作法(同一個節點在兩張 FTS
  表都命中時取分數大的那筆),把它原樣搬到跨 vault 就會在兩個 vault 有同一個短 id 時**吃掉一筆**。
  ADR-014 明訂短 id 只在 vault 內唯一,這不是罕見情況而是預期狀態。代價:每個消費端都要帶著 vault
  一起傳,不能只傳 id。
  *否決:改用全域唯一 id(ULID)*——assetdb ADR-012 選 `ATTACH` 的理由之一就是這個,而 ADR-014 已
  以「結果帶 vault 欄位」取代它;改回去要動全部檔案的 frontmatter。
- **D2:`VaultSet` 不接管 `VaultHandle` 的生命週期**(L2)。`closeVaultSet` 只放掉自己持有的資源。
  *否決:`closeVaultSet` 連帶關掉每個把手*——當下少寫一行,但呼叫端(`service`)的把手是長生命週期
  的、可能同時被寫入路徑用著;一個查詢結束就把寫入用的連線關掉,是會在併發下才炸開的那種錯。
  *否決:`openVaultSet` 自己 `openVault`*——那會讓本模組需要知道 vault 的路徑與 `TypeRegistry`,
  等於把 `workspace` 的職責吸進來(契約卡「明確不做」第一條)。
- **D3:上限是 10 個 vault,超過即失敗,不做分批查詢**(L1)。
  *否決:超過上限時自動分批查詢再合併*——契約卡「明確不做」寫明「不做超過上限的分批查詢(Level 3
  之後視需要開 E)」。當下成本是使用者在第 11 個 vault 撞牆;三個月後的代價則相反:分批之後
  `srTotal`、facet 與分頁都要自己再合併一次,而那正是 SQL 層 UNION 幫忙做掉的事,寫早了會是兩份
  邏輯。ADR-017 也明說這屬 Level 2 之後的事,錯誤訊息才是 Level 1 契約。
- **D4:`DanglingReason` 是封閉的兩值 sum,不是自由文字**。
  *否決:`drReason :: Text`*——上層(`service` 的 `doctor`)要依成因決定怎麼講、要不要擋;文字化的
  成因會逼每個消費端做字串比對,而新增第三種成因時編譯器不會列出待處理處。與契約 A 的 `AnyNode` /
  `LinkKind` 同一個模式。
- **D5:`drTarget` 存的是「套用預設 vault 之後」的目標,`drLink` 保留檔案原文**。
  *否決:只留其中一個*——只留原文的話,診斷時看不出程式究竟去哪個 vault 找(不帶 vault 的 `Ref`
  最常見);只留解析後的話,就對不回檔案裡那一行,修的人不知道要改什麼。多一個欄位換掉一整輪
  「這筆到底怎麼來的」的追查。

## 骨架

| 檔案 | 內容 |
|---|---|
| `store/src/Aapms/Store/MultiVault.hs` | **新建**。`VaultSet`(不透明)/ `DanglingRef` / `DanglingReason` 三個型別;`maxAttachedVaults` / `openVaultSet` / `closeVaultSet` / `vaultSetIds` / `lookupRef` / `listAcross` / `searchAcross` / `checkReferences` / `renderDanglingRef` 九個簽名,本體全為 `undefined` |
| `store/aapms-store.cabal` | `exposed-modules` **只加一行** `Aapms.Store.MultiVault` |
| `store/src/Aapms/Store.hs` | 門面 **只加** `module Aapms.Store.MultiVault` 的 re-export 與對應 import;順手修掉已過時的模組 haddock 一句 |
| `store/src/Aapms/Store/Error.hs` | **加兩個 `StoreError` 建構子**(`TooManyVaults` / `VaultIdCollision`)與 `renderStoreError` 的兩個分支。**寫真正的訊息、不留 `undefined`**——它是 F005 已交付的程式碼,`renderStoreError` 留洞會炸掉既有測試 |
| `store/src/Aapms/Store/Query.hs` | **只做行為不變的機械一般化**:`whereOf` → `whereOfIn ""`、`baseFrom` → `baseFromIn ""`,兩個 `*In` 版本多吃一個 schema 前綴並加進匯出清單。**寫真正的本體**(同上理由) |

**`Query.hs` 這一處為什麼是行為不變的**(交付時已機械驗證,見「實作備註」):`whereOf` / `baseFrom`
的**名稱與型別一字未改**,三個既有呼叫端(`listNodes` / `structuralIds` / `ftsHits`)一行未動;
兩者現在定義成對應 `*In` 版本套用 `""`,而 `*In` 版本只在**表名前面**插入那個前綴字串,`""` 時
產生的 SQL 逐字元相同。`search` / `listNodes` / `sortHits` / `takePage` 的邏輯完全沒碰。

## 已裁決紀錄(原「待確認假設」)

> 六條假設於 **2026-08-26 的 spec 閘門全部裁決完畢**,契約 E / 契約 G / 資料流管線 /
> 「模組間公開介面」/ **ADR-017 第四條**都已由編排者回寫。下方**保留提報時的原文供追溯**,
> 每條前面加一行「**裁決**」;A1 **部分推翻**、A5 **推翻**,理由記在各自的裁決行裡。
> 本節不再有待辦——qa 與 impl 以裁決行為準,原文只是脈絡。

- **【裁決:部分推翻 → 分案】** 開發者查證後指出情況比提報的更嚴重:**ADR-017 第四條**原文
  「排序、分頁、facet 在 SQL 層完成」與程式碼不符,而它沒被發現是因為**只對跨 vault 提要求**,
  單一 vault 的偏離沒有人擋。裁決把這條拆成兩半:
  **`listAcross` 走 SQL**(重用 `whereOf` 條件片段對加了 schema 前綴的 UNION 視圖執行,與
  `listNodes` 一致)、**`searchAcross` 走 Haskell**(兩張 FTS 表 × N 個 vault 的 bm25 分數在
  Haskell 合併去重後排序分頁,與 `search` 一致)。理由:分數合併推進 SQL 做得到,但會把 SQL 組裝
  弄髒,收益只在命中數極大時才出現。ADR-017 第四條已附修訂說明,`design.md` 的跨 vault 讀管線與
  「模組間公開介面」已回寫。
  → 本 feature 因此獲授權對 `Query.hs` 做**行為完全不變的機械一般化**(見「骨架」與「實作備註」);
  **提報時的傾向 a「全部走 SQL」被收窄成只有 `listAcross`**,Laws 與 Examples 一條都不用改
  (它們約束的全是可觀察行為,本來就不管在哪一層合併)。
- **A1**:design.md「模組間公開介面」寫「MultiVault → Query:`*Across` 以同一組 SQL 片段對 UNION 後
  的視圖執行」,但**那組片段目前重用不了**——已打開 `store/src/Aapms/Store/Query.hs` 逐行確認:
  `whereOf`(`:131`)與 `baseFrom`(`:182`)都**不在模組匯出清單**(`:24-47`)裡,`ftsHits`
  (`:653`)、`metasFor`(`:209`)、`structuralIds`(`:623`)、`computeFacets`(`:764`)也一樣。
  更進一步:`whereOf` 產生的條件只用 `n.` / `a.` / `p.` 這三個**別名**,所以它本身可以逐字重用;
  但 `baseFrom` 是寫死的 `FROM nodes n LEFT JOIN assets a … LEFT JOIN packs p …`,`ATTACH` 之後
  需要的是 `FROM v1.nodes n LEFT JOIN v1.assets a …`,它必須變成吃一個 schema 前綴的函式。
  - 層級自答:出現在邊界上?**會**(`Aapms.Store.Query` 的匯出清單就是模組邊界,design.md 也把
    這條邊寫進了「模組間公開介面」);改錯驚動其他模組?**要**(`Query.hs` 不在本次骨架清單裡)
  - 選項:
    a) **編排者把 `whereOf` 匯出、並把 `baseFrom` 改成 `baseFromIn :: Text -> Text`(吃 schema
       前綴,`""` 或 `"main."` 時退化成現況)**——當下成本:改 `Query.hs` 的匯出清單一行 + 一個
       字串函式加參數 + 三處既有呼叫點跟著改(`listNodes` / `structuralIds` / `ftsHits`),
       F007 的 111 條測試不受影響(對外行為不變);三個月後的代價:`Aapms.Store.Query` 多兩個
       公開符號,日後改 `NodeFilter` 語意時要記得兩個消費端(但它們共用同一段程式碼,不會分歧)
    b) **MultiVault 自己複製一份 WHERE 組裝**——當下成本:零,完全不動 `Query.hs`;三個月後的
       代價:`nfStatus = []` 排除 missing、`nfIncludeReference` 的兩段 NULL 處理、
       `nfLicense` 同時比 `a.license` 與 `p.license` 這些**語意**會有兩份實作,改一邊忘另一邊時
       單 vault 與跨 vault 的過濾結果會**靜默分歧**——正是本子系統已被咬過兩次(G2 / G17)的
       那種缺陷形態。L4 是為了抓它而寫的,但 law 抓得到的是「已經分歧了」,不是「不會分歧」
    c) **不做 SQL 層 UNION**:`listAcross` / `searchAcross` 逐 vault 呼叫既有的 `listNodes` /
       `search`,再在 Haskell 做全域合併、排序、分頁與 facet 合併——當下成本:最低,不動
       `Query.hs` 也不用 `ATTACH`,而且 F007 的單 vault `search` **本來就是**在 Haskell 排序分頁
       (`sortHits` `:616` / `takePage` `:619`);三個月後的代價:違反 ADR-017 第四條的字面
       (「一個連線 ATTACH 多個索引再 UNION,排序、分頁、facet 在 SQL 層完成」),要改 ADR;
       且每個 vault 都要撈回 `nfOffset + nfLimit` 筆再丟掉,vault 一多就是 N 倍的往返
  - 傾向:**a**。理由:它是三者中唯一同時滿足「NodeFilter 語意只有一份」與「ADR-017 的 ATTACH
    路徑」的作法,而付出的只是 `Query.hs` 的一行匯出加一個參數。**b 的代價我不接受**——本子系統
    這一波兩次最嚴重的資料遺失(G2 / G17)都是「同一件事有兩個地方在做,其中一個忘了跟上」,
    不該再開第三個。**c 的前提要講清楚**:它不是錯的,`search` 現在確實在 Haskell 排序;但
    `listNodes` 的 `ORDER BY / LIMIT / OFFSET` 是在 SQL(`Query.hs:194`),c 會讓 `listAcross`
    與 `listNodes` 走上兩種不同的分頁機制,而 ADR-017 第四條是 accepted 狀態,推翻它要走 ADR
    更新,不是一個 feature 自己決定得了的。
    可逆性:**可逆**——三者的對外簽名完全相同(`VaultSet` 不透明,差別全在它裡面),換作法只改
    `MultiVault.hs` 的本體與(選項 a 時)`Query.hs` 的匯出清單,Laws / Examples 一條都不用改
  - 暫採:**a**。spec 與骨架照 a 寫(骨架的 `VaultSet` 保留一個 `Connection` 欄位給 `ATTACH` 用)
    → 影響:若裁決是 c,骨架的 `VaultSet` 少一個欄位(本 spec 已明文授權 impl 增刪它的欄位),
    `closeVaultSet` 變成 no-op,其餘一律不動;若裁決是 b,`Query.hs` 不動,MultiVault 內部多一份
    WHERE 組裝,並建議在 `/arch-audit subsys graph-core` 加一個「兩份 WHERE 組裝是否仍等價」的
    人工檢查項

- **【裁決:接受(選項 a)】** 三條都補,已回寫契約 E:`closeVaultSet :: VaultSet -> IO ()`、
  `vaultSetIds :: VaultSet -> [VaultId]`、`maxAttachedVaults :: Int`。落在 L1 / L1b / L2 / L18 與
  E6 / E7 / E10 / E12 / E13 / E14。
- **A2**:契約 E 只列了 `VaultSet` / `openVaultSet` / `lookupRef` / `listAcross` / `searchAcross` /
  `checkReferences` 六條,沒有 `closeVaultSet`、`vaultSetIds`、`maxAttachedVaults`。但
  `openVaultSet` 若自己持有一個 `ATTACH` 過的連線,少了對稱的關閉在 Windows 上會鎖住
  `index.db`(暫存目錄刪不掉,測試會在 teardown 失敗);而 `VaultSet` 不透明,少了 `vaultSetIds`
  就**沒有任何公開介面觀察得到去重與上限到底怎麼作用**,L1 / E6 / E7 寫不出斷言。
  - 層級自答:出現在邊界上?**會**(三條都是對外的公開介面);改錯驚動其他模組?**要**
    (`service` 會照著用)
  - 選項:
    a) **三條都補上**——當下成本:契約 E 多三行;三個月後的代價:公開面多三個符號,但每一個都
       有明確的必要性(資源、可觀察性、上限的唯一真相),之後想拿掉任何一個都是破壞性變更
    b) **只補 `closeVaultSet`,`vaultSetIds` / `maxAttachedVaults` 不開**——當下成本:公開面最小;
       三個月後的代價:「去重與上限」變成沒有測試守著的行為(qa 只能從 `TooManyVaults` 的
       `Int` 欄位間接推,而那條路只在**失敗**時走得到,成功路徑的去重完全觀察不到),等於把
       L1 的一半交給實作自由心證
    c) **改讓 `openVaultSet` 回 `(VaultSet, [VaultId])`**——當下成本:不新增函式;三個月後的
       代價:`VaultId` 清單與 `VaultSet` 從此可以不同步(呼叫端會把它存起來、傳來傳去),
       同一個事實有兩個持有者,違反知識歸屬
  - 傾向:**a**。`maxAttachedVaults` 尤其必要:上限這個數字若只寫在 `openVaultSet` 內部,L1 就得
    把 `10` 這個字面量抄進測試,契約一改測試不會紅、只會靜默地測錯的東西。可逆性:
    **有條件可逆**——三條都是**新增**,拿掉才是破壞性的;條件是 `service` 尚未開始使用
    (P3 才會有消費者,現在拿掉零成本)
  - 暫採:a → 影響:若裁決是 b,骨架刪掉 `vaultSetIds` / `maxAttachedVaults` 兩條簽名,L1 要改寫成
    只斷言 `TooManyVaults` 的兩個 `Int` 欄位、E7(去重)整條刪掉

- **【裁決:接受(選項 a),已回寫契約 E】**
  `data DanglingRef = DanglingRef { drSource :: Id, drLink :: Link, drTarget :: Ref, drReason :: DanglingReason }`、
  `data DanglingReason = TargetVaultAbsent | TargetNodeMissing`。落在 L16 / L17 與 E8 / E9。
- **A3**:契約 E 只寫 `checkReferences :: VaultSet -> VaultHandle -> IO [DanglingRef]`,
  **`DanglingRef` 的形狀沒有定義**(build-log D3 已記過這件事:新的 DTO 由對應 feature 依契約卡
  文字定形狀、標為待確認假設,編排者在閘門把定稿回填契約 E)。契約卡的文字是「找出指向不存在
  節點與不存在 vault 的**兩種**懸空」。
  - 層級自答:出現在邊界上?**會**(它是契約 E 的回傳型別);改錯驚動其他模組?**要**
    (`service` 的 `doctor` 會消費它)
  - 選項:
    a) **`{ drSource, drLink, drTarget, drReason }` 四欄 + 封閉的 `DanglingReason` 兩值**
       (見「不可逆決定」D4 / D5)——當下成本:四個欄位;三個月後的代價:`drLink` 與 `drTarget`
       有部分重疊(後者是前者套用預設 vault 的結果),看起來冗餘
    b) **`{ drSource, drTarget, drReason }` 三欄**(丟掉 `drLink`)——當下成本:少一欄;三個月後
       的代價:上層拿不到 `linkKind` 與 `linkNote`,而「哪一種關聯斷了」正是 `doctor` 要講給人聽
       的第一件事;要補回去時 `service` 已經在用這個型別了
    c) **`(Id, Ref)` 的 pair,不開新型別**——當下成本:零;三個月後的代價:成因分不出來
       (契約卡明訂兩種),而 pair 沒有欄位名,加第三個資訊就要改成 triple,每個消費端都得改
  - 傾向:**a**。`drLink` 與 `drTarget` 的重疊是刻意的:診斷這種問題時「檔案裡寫了什麼」與
    「程式去哪裡找」是兩個不同的問題,合成一個就有一半答不出來。可逆性:**有條件可逆**——
    加欄位可逆,刪欄位不可逆;條件同 A2(P3 之前沒有消費者)
  - 暫採:a → 影響:若裁決是 b/c,骨架的 `data DanglingRef` 改欄位,L16 / L17 與 E8 / E9 跟著改,
    其餘 law 不受影響

- **【裁決:接受(選項 a 的變體)——`Error.hs` 這一輪授權給本 feature 自己改】** 結論與選項 a 相同
  (建構子進 `StoreError`、不另立平行型別),只是動手的人從編排者改成本 feature。已加
  `TooManyVaults Int Int` 與 `renderStoreError` 分支,訊息列出兩個數字且含以「請」起頭的子句。
  落在 L1 / L20 與 E6 / E14 / E15。
- **A4**:`TooManyVaults` 依契約 G 必須是 `StoreError` 的**新建構子**(「`StoreError` 是
  `aapms-store` 的唯一錯誤型別,由各 feature 擴充,不得另立平行型別再橋接」),但
  `store/src/Aapms/Store/Error.hs` **不在本次的骨架檔案清單裡**。這與 F008 A2 是同一個情況——
  當時 subagent 另立了 `StoreWriteError` 再橋接,已於 2026-08-25 被推翻。
  - 層級自答:出現在邊界上?**會**;改錯驚動其他模組?**要**
  - 選項:
    a) **由編排者在 `Error.hs` 加 `TooManyVaults Int Int` 與 `renderStoreError` 的分支**——當下
       成本:編排者改一個檔(兩處);三個月後的代價:無,這正是契約 G 規定的作法
    b) **本 feature 自己去改 `Error.hs`**——當下成本:零;三個月後的代價:違反委派的檔案清單
       (W7 只有一個 feature、沒有平行寫入的風險,但規則是規則,而且 `Error.hs` 是全套件共用檔)
    c) **另立 `MultiVaultError` 再橋接**——當下成本:零;三個月後的代價:**已被開發者推翻過一次**
       (F008 A2),`service` 會看到兩種錯誤形狀、兩套 `render*`
  - 傾向:**a**。這一條沒有真正的取捨,只是「誰動手」;c 已有前例判死。可逆性:**可逆**
  - 暫採:a。骨架**不 import** `TooManyVaults`,所以現在編得過;L1 / E6 在建構子落地前寫不出來
    → 影響:若編排者選 b,把 `Error.hs` 加進骨架清單再委派一次即可,spec 一字不改

- **【裁決:推翻(提報時傾向 a「一律保序去重」)→ 依成因分成兩種**】 開發者指出提報**沒有把兩種
  成因分開**:
  ① **同一個路徑被傳兩次**是無害的呼叫端疏忽(預設 vault 又被顯式指定一次)→ **保序去重**,上限以
  去重後的數量計;
  ② **兩個不同路徑帶著相同 `vmId`** 則依 ADR-017「vault 的身分就是 marker 裡的 id」,代表有人複製
  了整個 vault 目錄,此時任何跨 vault 的 `Ref` 解析都是**不確定的** → **回錯並列出兩個路徑**。
  一律去重會把 ② 一起吞掉,症狀是「搜尋結果少了一個 vault 的東西」——而這個子系統已經被安靜的
  資料問題咬過兩次(G2 / G17),兩次都不是測試抓到的。
  → 落地:`StoreError` 新增 `VaultIdCollision VaultId FilePath FilePath`(撞號的 id + 兩個
  `vhRoot`)與 `renderStoreError` 分支;`openVaultSet` 的檢查順序定為
  **撞號 → 去重 → 上限**(撞號優先於上限:先講資料問題,再講範圍問題)。
  落在 **L1**(去重與上限)/ **L1b**(撞號)/ **L20**(訊息)與 **E7**(同路徑重複 → 去重)/
  **E13**(異路徑撞號 → 錯)/ **E14**(撞號優先於上限)/ **E15**(訊息)。契約 G 已回寫。
- **A5**:契約沒說 `openVaultSet` 收到**兩個 `vmId` 相同的把手**(同一個 vault 被 `openVault` 兩次)
  時該怎麼辦。這在 `workspace` 交出「本次生效的 vault」清單時是會發生的(中樞註冊表有別名、
  向上探測與 `--vault` 同時命中同一個 vault)。
  - 層級自答:出現在邊界上?**會**(它決定 `openVaultSet` 接受什麼);改錯驚動其他模組?**要**
  - 選項:
    a) **保序去重、同 `vmId` 只留第一個,上限以去重後的數量計**(L1 / E7)——當下成本:一次
       `nub`;三個月後的代價:呼叫端傳 11 個把手卻成功了會有一瞬間的困惑,但 `vaultSetIds` 講得
       出實際涵蓋哪些,不是靜默的
    b) **視為錯誤**(新增第二個建構子)——當下成本:多一個建構子與一則訊息;三個月後的代價:
       `workspace` 每次都得先自己去重,而那件事本模組做起來更便宜、也更不容易漏
    c) **原樣接受,同一個 vault 掛兩次**——當下成本:零;三個月後的代價:`ATTACH` 的 schema 別名
       撞名(要嘛失敗、要嘛加編號),而且每筆結果會**出現兩次**——典型的「安靜地錯掉」
  - 傾向:**a**。c 直接排除(重複結果不會被任何現有斷言擋下);b 與 a 的差別只在「誰去重」,
    而 a 讓 `vaultSetIds` 成為唯一真相。可逆性:**可逆**(改的是 `openVaultSet` 的一行與 L1 的措辭)
  - 暫採:a → 影響:若裁決是 b,L1 的第二個子句改成「有重複 `vmId` 時回 `Left <新建構子>`」、
    E7 改成期望 `Left`,並要在 `Error.hs` 再加一個建構子(併進 A4 一起處理)

- **【裁決:接受(選項 a)】** 同一個值跨 vault **求和**。落在 L12 子句 2 與 E12。
- **A6**:契約 F 的 `FacetCounts` 是為單一 vault 定的(F007 L16:`fcVaults` 恰有一筆)。跨 vault 時
  `fcVaults` 顯然要每個有命中的 vault 各一筆,但**另外四個維度**(`fcTypes` / `fcTags` /
  `fcOwners` / `fcLicenses`)的跨 vault 語意契約沒寫。
  - 層級自答:出現在邊界上?**會**(`searchAcross` 的回傳內容);改錯驚動其他模組?**要**
    (`service` 的側欄直接顯示它)
  - 選項:
    a) **同一個值跨 vault 求和**(L12 子句 2):`type = "character"` 在 A 有 3 筆、B 有 2 筆 →
       `("character", 5)`——當下成本:合併時多一次 `Map.unionWith (+)`;三個月後的代價:
       側欄看不出「這 5 筆分佈在哪些 vault」,但 `fcVaults` 那一維本來就是回答這個問題的
    b) **以 `(vault, 值)` 為鍵不求和**——當下成本:相同;三個月後的代價:`fcTypes` 的型別
       `[(Text, Int)]` 沒有地方放 vault,只能把 vault 塞進那個 `Text`(`"vlt-…:character"`),
       等於在字串裡編碼結構——本子系統在 ADR-014 已經拒絕過同一種作法
    c) **跨 vault 時不算這四個維度**(只給 `fcVaults`)——當下成本:最低;三個月後的代價:
       ADR-017 第四條明寫 facet 要在跨 vault 路徑上成立,而「跨 vault 才是查詢的預設範圍」
       (ADR-017 第三條)——等於預設路徑上沒有 facet
  - 傾向:**a**。b 被 ADR-014「不要把結構編進字串」的同一個理由擋掉;c 讓 facet 在預設路徑上消失。
    可逆性:**可逆**(改的是合併函式,型別不動)
  - 暫採:a → 影響:若裁決是 c,L12 的子句 2 與 3 刪掉、E12 只驗 `fcVaults`

## 實作備註

**spec 階段已落地的三處既有檔案改動**(2026-08-26,裁決後授權範圍內):

- `Aapms.Store.Error`:加 `TooManyVaults Int Int` 與 `VaultIdCollision VaultId FilePath FilePath`
  兩個建構子與 `renderStoreError` 的兩個分支(真正的訊息,不是 `undefined`)。import 由
  `Aapms.Core.Id (Id, renderId, renderRef)` 擴成 `(Id, VaultId (..), renderId, renderRef)`
  ——`Aapms.Core.Id` 本來就是相依,`Error.hs` **仍然不 import 任何 `Aapms.Store.*`**(契約 G 的前提)
- `Aapms.Store.Query`:`whereOf` / `baseFrom` 的**名稱與型別一字未改**,改成
  `whereOf = whereOfIn ""` / `baseFrom = baseFromIn ""`;新增的 `whereOfIn :: Text -> NodeFilter -> (Text, [SQLData])`
  與 `baseFromIn :: Text -> Text` 只在**表名前面**插入前綴字串,並加進匯出清單。三個既有呼叫端
  (`listNodes` / `structuralIds` / `ftsHits`)**一行未動**,`search` / `sortHits` / `takePage`
  完全沒碰。
  **機械驗證**(`cabal repl lib:aapms-store`):
  `baseFromIn "" == "FROM nodes n LEFT JOIN assets a ON a.id = n.id LEFT JOIN packs p ON p.id = n.id"`
  回 `True`(逐字等於 F006 交付的原字串);`fst (whereOfIn "" emptyNodeFilter)` 的
  reference 子句是 `… NOT IN (SELECT id FROM packs WHERE is_reference = 1)`(無前綴,同原文),
  `whereOfIn "v1."` 則是 `… FROM v1.packs …`
- **落地時發現、值得記下的一點**:授權原文是「匯出 `whereOf`」,但**照字面只匯出是不夠的**——
  `whereOf` 的條件裡有**兩處直接寫出表名**的子查詢(其餘全用 `n` / `a` / `p` 別名),跨 vault 時
  它們會解析到 `main` 的那張表(或根本沒有這張表),等於拿**別的 vault** 的資料來篩這個 vault
  的節點:
  1. `tagClause` 的 `SELECT 1 FROM node_tags nt …`(`nfTags`)
  2. `referenceClause` 的 `SELECT id FROM packs WHERE is_reference = 1`(`nfIncludeReference`,
     **預設值就是 `False`,所以這條是預設路徑**)
  兩處都做了與 `baseFrom` **同形**的前綴一般化,`""` 時輸出逐字不變。L4 的非退化條件與 E16 / E17
  就是為了讓這件事在測試裡被抓到而寫的
- **掃描方式的修正(值得記下的教訓)**:第一輪我是**用讀的**判斷「哪裡寫出表名」,只找到
  `referenceClause` 一處,漏了 `tagClause`——判準(別名安全、裸表名危險)是對的,執行判準的方式
  錯了。改用機械掃描之後兩處都跳出來:

  ```
  awk 'NR>=<函式起始行> && NR<=<函式結束行>' store/src/Aapms/Store/Query.hs \
    | grep -nE "FROM [A-Za-z_]+|JOIN [A-Za-z_]+"
  ```

  同一條指令對 `baseFromIn` 跑一次,確認三張表都已前綴化。`Query.hs` 其餘的裸表名都在**單一
  vault 專用**的函式裡(`childrenOf` / `metasFor` / `lookupNode` / `computeFacets` 等),
  `listAcross` 不重用它們,**維持原樣不動**

以下兩項是**明確不由測試涵蓋、留給 `/arch-audit subsys graph-core` 人工檢查**的
結構約束,依 F007 G3 與 F008 G12 的裁決先例——文字掃描分不出語法結構,不寫成 law:

- **「`VaultSet` 只開讀取,任何寫入函式不接受它」**(契約卡驗收 6):這是**型別層級**的事實
  ——契約 E 的每個寫入函式都收 `VaultHandle`,沒有任何一個收 `VaultSet`,寫錯編譯就不過。
  沒有對應的 law:可觀察行為上沒有東西好斷言,而用文字掃描「原始碼裡有沒有出現某某」正是
  F007 G3 / F008 G12 兩度驗不準的作法。`/arch-audit` 檢查:`MultiVault.hs` 沒有 import
  `Aapms.Store.Write` / `Aapms.Store.Create` / `Aapms.Store.Edit`,且 `VaultSet` 沒有匯出任何
  取得 `VaultHandle` 的存取子
- **ADR-022 寫鎖預算**:`openVaultSet` 的 `ATTACH` 與各 `*Across` 全是讀,不開寫交易;
  `/arch-audit` 檢查 `MultiVault.hs` 不出現 `withTransaction`
