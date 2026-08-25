---
id: F008
type: feature
title: store-write-operations
description: vault 的建檔、增節、改寫、刪除與短 id 配號,全部走樂觀鎖與原子寫入
status: open
created: 2026-08-24
updated: 2026-08-25
depends-on: [F004, F006]
related-adr: [ADR-010, ADR-014, ADR-022]
related-feature: []
---

# F008: store 寫入操作

## 目的

`graph-core` 到 F006 為止只會**讀**:檔案進索引、索引出查詢。這個 feature 補上反方向
——把 `service` 與 `asset-ingest` 的請求變成磁碟上的 Markdown,再讓索引跟上。

它同時是三條硬約束第一次同時落地的地方:**檔案是真相**(ADR-002,所以順序永遠是先寫檔
再更新索引)、**未修改的區塊逐字保留**(ADR-010,所以每次只重新序列化被改的那一段)、
**寫交易的持有時間以毫秒計**(ADR-022,所以檔案 IO 與序列化一律在碰索引之前完成)。

## 對應的 Level 2 契約

| 契約 | 條目 | 本 feature 的落點 |
|---|---|---|
| E(落地) | `createTopicFile` / `createLevelFile` / `createPackFile` / `addSection` | `Aapms.Store.Create` |
| E(落地) | `writeMeta` / `writeAssetFields` / `writeBody` / `addLink` / `removeLink` / `upsertLicense` / `allocateId` | `Aapms.Store.Write` |
| E(落地) | `deleteNode` | `Aapms.Store.Create` |
| D(Markdown) | `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` | 定義在 `Aapms.Md.Render`(F004 G2 重跑落地),`Aapms.Store.Create` 只 re-export |
| D(Markdown) | `insertSection`(`UnderParent` 落點用) | 由 F004 提供,本 feature 只呼叫 |
| G(錯誤) | 寫入路徑的 15 個錯誤建構子,併進**唯一**的 `StoreError` | `Aapms.Store.Error` |
| 內部模組劃分 | 「Write:建檔、增節、改寫、刪除、Node、License;樂觀鎖;`allocateId`」 | `Edit` / `Write` / `Node` / `Create` 四個檔案(下方「骨架」) |
| 資料流管線 | **寫入管線全段** | `Aapms.Store.Edit.commit` 定義那條線的順序 |
| 門面 | `Aapms.Store` re-export 契約 E 的寫入組 | `store/src/Aapms/Store.hs:32` / `:38` |

未超出範圍:本 feature 不新增任何契約 E 之外的對外函式;`Aapms.Store.Edit` /
`Aapms.Store.Node` 是內部模組,不進契約也不進門面(`WriteResult` 是例外——它是契約 E
寫入組的回傳型別,由 `Aapms.Store.Write` re-export 帶進門面)。**簽名零偏離**:
2026-08-25 的閘門把 `createPackFile` 的第三參數、`addSection` 的落點參數與
`allocateId` 的失敗通道都回寫進 design.md 契約 E,本文件與契約逐字一致。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `StoreError` | **擴充**(+15 建構子) | `Error.hs:29`,新建構子從 `Error.hs:41` 起(`NodeNotFound` … `NodeDepthExceeded`) | 寫入路徑可能發生哪些失敗,以及每一種的下一步。**不另立平行型別**(design.md 契約 G) |
| `WriteResult` | 新增 | `{ wrId :: Id, wrPath :: FilePath, wrRevision :: Revision, wrIssues :: [IndexIssue] }`,`Edit.hs:77` | 一次改寫之後,新的 revision 與索引附帶回報 |
| `Located` | 新增 | `{ locPath :: FilePath, locAnchor :: Maybe Id, locKind :: DocKind }`,`Edit.hs:113` | 索引在寫入路徑上唯一的用途:目標住在哪個檔、哪一節、那是哪種文件 |
| `NewEntity` | 新增 | `Create.hs:85` | 一份新主題檔的全部人給欄位(不含 revision / 日期——那些由本層填) |
| `NewLevel` | 新增 | `Create.hs:106` | 一份新 Level 檔 + 它的根 Node |
| `NewPack` | 新增 | `Create.hs:123` | 一份新 `pack.md` 的檔案層欄位與落點目錄 |
| `NewSection` | **沿用 md** | `md/src/Aapms/Md/Render.hs:238`,`Create.hs` 只 re-export | 一個新節的共通骨架(四種文件共用) |
| `NewSectionPayload` | **沿用 md** | `md/src/Aapms/Md/Render.hs:256` | 「這一節是哪一種節點」以及它專屬的欄位 |
| `NewAsset` | **沿用 md** | `md/src/Aapms/Md/Render.hs:272` | 一筆 asset 的檔案事實(`sha256` / `entry` 由 `asset-ingest` 算好給) |
| `NewLicense` | **沿用 md** | `md/src/Aapms/Md/Render.hs:289` | 一種授權允許什麼、要求什麼 |
| `NewNode` | **沿用 md** | `md/src/Aapms/Md/Render.hs:306` | Level 節點唯一不能由標題階層推導的事實 |
| `SectionPlacement` | 新增 | `AtEnd \| UnderParent Id`,`Create.hs:189` | 新節要落在檔尾還是某個父節點底下 |
| `AssetPatch` | 新增 | `{ apName, apLicense, apAuthor, apTags }`,兩層 `Maybe`,`Write.hs:63` | **人可以改 asset 的哪些欄位**——`sha256` / `entry` / `ext` / `meta` 不在裡面是型別層的拒絕 |
| `CreateResult` | 新增 | `{ crId, crPath, crRevision, crIssues }`,`Create.hs:158` | 剛建出來的節點的 id(呼叫端唯一拿不到其他來源的資訊) |
| `DeleteMode` | 新增 | `DeleteSafe \| DeleteForce`,`Create.hs:169` | 被指向時要擋還是照刪 |
| `DeleteResult` | 新增 | `{ drPath, drRemovedIds, drBrokenLinks, drIssues }`,`Create.hs:172` | 這次刪掉了哪些 id、打斷了哪些關聯 |

**知識歸屬的三條界線**(避免與既有模組重複持有同一個事實):

- **revision 的遞增點**只有一個:`Aapms.Core.Meta.bumpRevision`(F001)。本 feature 不自己 +1,
  只負責比對與傳遞
- **檔案落點的規則**只有一個:`Aapms.Core.Registry.lookupDir`(F002)。本 feature 不硬編任何
  型別 → 目錄的對應,唯一的例外是 `levels/`(`level` 是保留鍵,不可能在註冊表裡)
- **序列化規則**只有一份:`aapms-md`。本 feature 不自己組 YAML、不自己拼 `Section`;
  一個新節的**形狀**(`NewSection` 家族)因此也住在 md,store 只 re-export
- **錯誤型別**只有一個:`Aapms.Store.Error.StoreError`。本 feature 往它加建構子,
  不另立 `StoreWriteError` 再橋接(design.md 契約 G)
- **父子關係的標題層級**只有一個推導點:`Aapms.Store.Node.headingDepthFor`。
  `addSection` 的 `UnderParent` 因此**不看呼叫端給的 `nsLevel`**

## 介面

「骨架位置」的行號是建檔當下的導航線索;一致性以簽名原文為準。

### 契約 E:寫入組

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `createTopicFile :: VaultHandle -> TypeRegistry -> NewEntity -> IO (Either StoreError CreateResult)` | 建一份新的主題檔,落點依註冊表的 `dir` | `store/src/Aapms/Store/Create.hs:207` |
| `createLevelFile :: VaultHandle -> TypeRegistry -> NewLevel -> IO (Either StoreError CreateResult)` | 建一份新的 Level 檔,連同它的根 Node | `store/src/Aapms/Store/Create.hs:218` |
| `createPackFile :: VaultHandle -> NewPack -> [NewSection] -> IO (Either StoreError CreateResult)` | 在指定目錄寫出 `pack.md`,節的順序與給定順序相同 | `store/src/Aapms/Store/Create.hs:234` |
| `data SectionPlacement = AtEnd \| UnderParent Id` | 新節落在檔尾,還是插在指定父節點底下 | `store/src/Aapms/Store/Create.hs:189` |
| `addSection :: VaultHandle -> Id -> SectionPlacement -> NewSection -> IO (Either StoreError CreateResult)` | 往既有檔案加一個節,依 `nsPayload` 分派;`UnderParent` 時 `nsLevel` 由 `headingDepthFor` 推導,不由呼叫端給 | `store/src/Aapms/Store/Create.hs:267` |
| `writeMeta :: VaultHandle -> Id -> Revision -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)` | 改一個既有節點的 `Meta` 欄位 | `store/src/Aapms/Store/Write.hs:87` |
| `writeAssetFields :: VaultHandle -> Id -> Revision -> AssetPatch -> IO (Either StoreError WriteResult)` | 改一筆 asset 的人給欄位 | `store/src/Aapms/Store/Write.hs:99` |
| `writeBody :: VaultHandle -> Id -> Revision -> Text -> IO (Either StoreError WriteResult)` | 換掉一個節點的正文 | `store/src/Aapms/Store/Write.hs:113` |
| `addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)` | 在來源節點上加一筆關聯 | `store/src/Aapms/Store/Write.hs:127` |
| `removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)` | 從來源節點刪掉相符的關聯 | `store/src/Aapms/Store/Write.hs:138` |
| `upsertLicense :: VaultHandle -> License -> IO (Either StoreError WriteResult)` | 把一種授權寫進該 vault 的 `licenses.md`(有就改、沒有就新增) | `store/src/Aapms/Store/Write.hs:155` |
| `deleteNode :: VaultHandle -> Id -> Revision -> DeleteMode -> IO (Either StoreError DeleteResult)` | 刪一個節點;目標是什麼決定刪掉多少 | `store/src/Aapms/Store/Create.hs:291` |
| `allocateId :: VaultHandle -> IdPrefix -> Text -> IO (Either StoreError Id)` | 產生一個索引裡還沒有人用的短 id;**碰撞查詢失敗即失敗,不靜默照發** | `store/src/Aapms/Store/Write.hs:171` |

### 契約 G:錯誤

`StoreError` 是 `aapms-store` 的**唯一**錯誤型別(design.md 契約 G);本 feature 往它
**加 15 個建構子**,不另立平行型別。

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data StoreError`(21 建構子:F005 的 6 + 本 feature 的 15) | 落地層的全部失敗原因 | `store/src/Aapms/Store/Error.hs:29`(新建構子自 `:41` 起) |
| `renderStoreError :: StoreError -> Text` | 把失敗原因說成繁中訊息,每一則說出下一步 | `store/src/Aapms/Store/Error.hs:80` |

**本 feature 擴大了 `renderStoreError` 的責任範圍**:它現在必須涵蓋 `StoreError` 的
**全部 21 個建構子**。F005 的 6 個(`VaultMarkerMissing` / `VaultMarkerInvalid` /
`VaultAlreadyInitialized` / `FileReadFailed` / `FileWriteFailed` / `SqliteError`)在骨架裡
**已經是實作過的**,新的 15 個是 `undefined` —— L15 的測試因此會是「6 綠 15 紅」,
不是全紅,這是預期的。

### 契約 E:門面

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `module Aapms.Store` re-export `Aapms.Store.Create` | 建檔 / 增節 / 刪除 / `SectionPlacement` / 輸入與結果 DTO | `store/src/Aapms/Store.hs:32` |
| `module Aapms.Store` re-export `Aapms.Store.Write` | 改寫 / 配號 / `AssetPatch` / `WriteResult` | `store/src/Aapms/Store.hs:38` |

`Aapms.Store.Edit` 與 `Aapms.Store.Node` 是內部模組,**不進門面**;`WriteResult`(定義在
`Edit.hs`)由 `Aapms.Store.Write` 的匯出清單帶出來——它是契約 E 寫入組的回傳型別,
門面少了它等於少一半簽名。

### 內部:寫入紀律(`Aapms.Store.Edit`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `(>>?) :: IO (Either StoreError a) -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)` | 失敗就短路的 IO 鏈 | `store/src/Aapms/Store/Edit.hs:90` |
| `(?>>) :: Either StoreError a -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)` | 把純函式那一段接進同一條鏈 | `store/src/Aapms/Store/Edit.hs:99` |
| `locate :: VaultHandle -> Id -> IO (Either StoreError Located)` | 說出目標住在哪個檔、哪一節、那是哪種文件 | `store/src/Aapms/Store/Edit.hs:123` |
| `readDocument :: VaultHandle -> FilePath -> IO (Either StoreError Document)` | 重讀檔案並切塊 | `store/src/Aapms/Store/Edit.hs:129` |
| `orMd :: FilePath -> Either MdError a -> Either StoreError a` | 把 md 的錯誤接上檔名 | `store/src/Aapms/Store/Edit.hs:133` |
| `checkRevision :: Id -> Revision -> Revision -> Either StoreError ()` | 比對呼叫端手上的 revision 與檔案裡的實際值 | `store/src/Aapms/Store/Edit.hs:142` |
| `commit :: VaultHandle -> FilePath -> Document -> Id -> Revision -> IO (Either StoreError WriteResult)` | 把已經算好的最終內容落地,並讓該檔的索引跟上 | `store/src/Aapms/Store/Edit.hs:154` |
| `dropFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | 移除一份檔案與它的全部索引記錄 | `store/src/Aapms/Store/Edit.hs:167` |
| `ensureDir :: VaultHandle -> FilePath -> IO ()` | 建出目標檔案所在的目錄 | `store/src/Aapms/Store/Edit.hs:175` |
| `vaultAbsPath :: VaultHandle -> FilePath -> FilePath` | Vault 相對路徑 → 絕對路徑 | `store/src/Aapms/Store/Edit.hs:179` |
| `sectionBodyRaw :: LineEnding -> Text -> Text` | 把正文包成節的正文切片形狀 | `store/src/Aapms/Store/Edit.hs:187` |

### 內部:Level 樹推導(`Aapms.Store.Node`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `headingDepthFor :: FilePath -> Document -> Id -> Either StoreError Int` | 在指定父節點底下新增子節點時,新節該用第幾級標題 | `store/src/Aapms/Store/Node.hs:41` |
| `subtreeAfter :: Document -> Id -> [Section]` | 某一節之後、屬於它子樹的所有節 | `store/src/Aapms/Store/Node.hs:47` |
| `subtreeIds :: Document -> Id -> [Id]` | 某一節與它整棵子樹的 id,依文件順序 | `store/src/Aapms/Store/Node.hs:54` |
| `isRootNode :: FilePath -> Document -> Id -> Either StoreError Bool` | 這個 id 是不是該 Level 檔的根 Node | `store/src/Aapms/Store/Node.hs:60` |
| `validateLevelDoc :: FilePath -> Document -> Either StoreError ()` | 編輯後的 Level 檔還解析得回來、樹還合法嗎 | `store/src/Aapms/Store/Node.hs:69` |

### 內部:檔名(`Aapms.Store.Create`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `sanitizeFileName :: Text -> Text -> Text` | 標題 → 檔名主幹,保留中文原字元 | `store/src/Aapms/Store/Create.hs:306` |

## Laws(行為性質)

以下 `f` 一律指契約 E 帶 `Revision` 參數的寫入介面(`writeMeta` / `writeAssetFields` /
`writeBody` / `addLink` / `removeLink` / `deleteNode`);`bytes p` 指路徑 `p` 上的檔案位元組。

- **L1(樂觀鎖:不符即拒且檔案未動)**:對所有節點 `i`、所有 `r /= 檔案裡的實際 revision`,
  `f vh i r …` 回 `Left (RevisionMismatch i r 實際值)`,且呼叫前後 `bytes(該檔)` 相同。
  `checkRevision i r a` 在 `r == a` 時且僅在此時回 `Right ()`。
- **L2(revision 恰好 +1,且與檔案一致)**:對所有成功的 `f vh i r …`,回傳的
  `wrRevision == Revision (n+1)`(其中 `Revision n = r`),且重新 `parseDocument` +
  `to*` 之後該節點的 `metaRevision` 等於 `wrRevision`。`CreateResult` 的 `crRevision` 同理
  (新檔為 `Revision 1`)。
- **L3(位元組保留)**:對所有含節的文件 `d` 與任一目標節 `s`,`writeMeta` / `writeBody` /
  `addLink` / `removeLink` 成功之後,`d` 裡**除 `s` 以外**每一節的 `renderSection` 位元組
  與呼叫前相同;目標若是檔案層主體,則所有節都不變。
- **L4(asset 唯讀欄位不變)**:對所有 `AssetPatch p` 與任一 asset `a`,`writeAssetFields`
  成功之後重新 `toPack` 取得的 `a'` 滿足 `astSha256 a' == astSha256 a`、
  `astEntry a' == astEntry a`、`astExt a' == astExt a`、`astKindMeta a' == astKindMeta a`、
  `astBody a' == astBody a`。
- **L5(`AssetPatch` 的三態語意)**:對所有 `p`,寫入後 `astName a'` =
  `case apName p of Nothing -> astName a; Just v -> v`;`astLicense` / `astAuthor` /
  `metaTags` 同構(`apTags` 只有兩態:`Nothing` 不動、`Just xs` 設成 `xs`)。
- **L6(`addLink` / `removeLink` 往返)**:對所有 `l` 不在節點 `i` 目前的 `metaLinks` 內,
  先 `addLink vh i r l` 再 `removeLink vh i (r+1) l` 之後,`linksFrom vh i` 的結果與最初相同,
  且檔案位元組與最初相同**除了** frontmatter / meta 區塊裡的 `revision` 與 `updated` 兩行。
- **L7(`removeLink` 沒命中不寫檔)**:對所有不在節點 `i` 的 `metaLinks` 內的 `l`,
  `removeLink vh i r l` 回 `Left (LinkNotFound i l)`,且 `bytes(該檔)` 不變。
- **L8(`upsertLicense` 讀回相等)**:對所有 `License l`,`upsertLicense vh l` 成功之後
  `toLicenses` 解出的那一筆 `l'` 在**除 `licMeta` 的 `metaRevision` / `metaUpdated` 與
  `licFullText` 以外**的每一欄都等於 `l`;對同一個 `licMeta` 的 id 呼叫兩次,
  `licenses.md` 的節數不變。
- **L9(`createPackFile` 順序保持)**:對所有非空的 `[NewSection] xs`(每筆 payload 皆為
  `NSAsset`),產出的 `pack.md` 以 `toPack` 解析回來的 asset 清單長度等於 `length xs`,
  且第 `k` 筆的 `metaId` 等於 `nsId (xs !! k)`。
- **L10(`createTopicFile` 落點)**:對所有在註冊表中 `lookupDir reg t == Just d` 的型別 `t`,
  `createTopicFile` 且 `nePath == Nothing` 時回傳的 `crPath` 以 `d <> "/"` 為前綴、以 `.md`
  結尾;`lookupDir reg t == Nothing` 時回 `Left (RegistryDirUnknown t)` 且不寫任何檔案。
- **L11(`createLevelFile` 產出可解析的 Level)**:對所有 `NewLevel`,回傳的 `crPath` 以
  `levels/` 為前綴(`nlPath == Nothing` 時),且該檔 `toLevel` 成功、`lvlRoot` 等於唯一那個
  Node 的 `metaId`、`buildTree` 回 `Right`。
- **L12a(`addSection AtEnd` 追加不動前面)**:對所有含 `n` 節的文件,
  `addSection vh i AtEnd s` 成功之後前 `n` 節的 `renderSection` 位元組不變,新節排在最後;
  且該檔對應的 `to*`(依 `DocKind`)仍然解析成功,多出來的那一筆節點的 `metaId` 等於 `nsId s`。
- **L12b(`addSection (UnderParent p)` 只在插入點動刀,層級由父節點決定)**:對所有 Level 檔
  與其中的非根節點 `p`,設 `k = length (subtreeAfter doc p)`、`p` 在文件裡是第 `j` 節,則
  `addSection vh i (UnderParent p) s` 成功之後:
  1. 新節排在第 `j + k + 1` 個位置(= `p` 的子樹之後,成為它的最後一個子節點);
  2. 該位置**之前與之後**的每一節的 `renderSection` 位元組都與呼叫前相同(ADR-010);
  3. 重新解析後,`nodParent` 該新節等於 `p`,且新節那一行的 `secLevel` 等於
     `secLevel p + 1` ——**與呼叫端傳進來的 `nsLevel s` 無關**(store 以
     `headingDepthFor` 覆寫);
  4. `toLevel` 成功且 `buildTree` 回 `Right`。
- **L12c(`UnderParent` 的兩條失敗路徑不寫檔)**:`p` 不在目標檔案裡時
  `addSection vh i (UnderParent p) s` 回 `Left (SectionMissing _ p)`;`p` 的 `secLevel`
  已經是 6 時回 `Left (NodeDepthExceeded p 7)`。兩者的 `bytes(該檔)` 都與呼叫前相同
  (兩條檢查都在 `commit` 之前)。
- **L13(`deleteNode` 的兩種模式)**:對所有目標 `i`,設 `victims` 為 `subtreeIds` 決定的
  消失集合(檔案層主體則為檔內全部節點 id):
  `DeleteSafe` 時若存在任一 `v ∈ victims` 被 `linksTo` 找得到,回 `Left (ReferencedBy i _)`
  且 `bytes(該檔)` 不變;`DeleteForce` 時成功,`drRemovedIds == victims`,而
  `drBrokenLinks` 恰好是所有指向 `victims` 的 `(來源, 關聯)`。目標是根 Node 時一律回
  `Left (CannotDeleteRootNode i)`,兩種模式皆然。
- **L14(`allocateId` 互異,且成功時才給 id)**:對所有 `(prefix, content)` 與所有 `n`,在索引
  可用的前提下連續呼叫 `allocateId` `n` 次、每次把結果寫進索引之後,`n` 次呼叫**全部**回
  `Right`,取出的 `n` 個 `Id` 兩兩相異,且每一個的 `Aapms.Core.Id.idPrefix` 都等於 `prefix`。
- **L14b(碰撞查詢失敗即失敗)**:索引查詢無法完成時(例如 `nodes` 表被移除),
  `allocateId vh p c` 回 `Left (SqliteError _)`,**不回 `Right`**。理由見「不可逆決定 6」:
  照發一個未經碰撞檢查的 id 會讓重複的身分落地到檔案(ADR-013 檔案是真相),事後只能靠
  `rebuildIndex` 撞 `nodes.id` 主鍵才發現,修復要人工改檔案裡的 id 與所有指向它的關聯。
- **L15(錯誤訊息說出下一步,涵蓋全部建構子)**:對所有 `StoreError e`,`renderStoreError e`
  非空,且含至少一個以「請」起頭的子句(system.md 全域錯誤處理策略第 2 條)。
  **範圍是 `StoreError` 的全部 21 個建構子**,不只本 feature 新增的 15 個——F005 的 6 個
  (`VaultMarkerMissing` / `VaultMarkerInvalid` / `VaultAlreadyInitialized` / `FileReadFailed` /
  `FileWriteFailed` / `SqliteError`)骨架裡已經實作,測試對它們應該是**綠的**;新的 15 個是
  `undefined`,應該**全紅**。
- **L16(先寫檔、再更新索引)**:對所有成功或以 `IndexUpdateFailed` 收場的寫入,磁碟上的目標
  檔案內容已經是新內容(`readTextFile` 讀得到);反之,任何以 `RevisionMismatch` /
  `MdWriteFailed` / `TreeInvalidOnWrite` / `ReferencedBy` / `LinkNotFound` /
  `BadSectionPayload` / `SectionMissing` / `NodeDepthExceeded` 收場的呼叫,檔案位元組不變。
- **L17(ADR-022 寫鎖預算,結構約束)**:`Aapms.Store.{Edit,Write,Node,Create}` 四個模組的
  **程式碼**(排除 `--` 註解與 haddock)中,`withTransaction` 出現 **0 次**,也不出現字面量
  `"BEGIN"` / `"COMMIT"`;`Database.SQLite.Simple` 只在 `Aapms.Store.Edit` 與
  `Aapms.Store.Write` 被 import(定位查詢與配號查詢),且所有檔案 IO
  (`readTextFile` / `atomicWriteText` / `removeFile` / `createDirectoryIfMissing`)與所有
  md 序列化都不在任何 SQLite 呼叫的括號內。可稽核形式:讀這四個檔案的原始碼即可判定,
  不需要執行(ADR-022:「交易區塊內有沒有 IO 或重運算,是可以在 code review 與靜態檢測中
  機械判斷的事實」)。
- **L18(索引只重讀該檔)**:對所有成功的寫入,`files` 表中**除目標檔外**每一列的
  `(path, mtime, size)` 與呼叫前相同。
- **L19(`sectionBodyRaw` 的形狀)**:對所有非空白的 `t`,`sectionBodyRaw le t` 以
  `renderLineEnding le` 開頭且以之結尾,且 `T.strip (sectionBodyRaw le t) == T.strip t`。
- **L20(`sanitizeFileName` 的值域)**:對所有 `t` 與非空的 `fb`,結果不含
  `< > : " / \ | ? *` 與控制字元,不以空白或 `.` 開頭或結尾;`t` 被清空時結果等於 `fb`;
  `t` 只含合法字元且無頭尾空白時結果等於 `t`。
- **L21(`headingDepthFor`)**:對所有存在於 `doc` 的父節點 `p`,`headingDepthFor` 的結果等於
  `secLevel p + 1`;該值大於 6 時回 `Left (NodeDepthExceeded p 值)`;`p` 不在 `doc` 裡時回
  `Left (SectionMissing _ p)`。
- **L22(`subtreeIds` 與 `subtreeAfter` 一致)**:對所有 `doc` 與 `i`,
  `subtreeIds doc i == i : map secId (subtreeAfter doc i)`;`subtreeAfter` 的每一節的
  `secLevel` 都嚴格大於 `i` 那一節的 `secLevel`。
- **L23(`validateLevelDoc` 等價於兩段驗證)**:對所有 `doc`,`validateLevelDoc rel doc` 回
  `Right ()` 當且僅當 `toLevel doc` 成功且 `buildTree` 回 `Right`;前者失敗回
  `MdWriteFailed`,後者失敗回 `TreeInvalidOnWrite`。
- **L-**:`(>>?)` / `(?>>)` 無獨立 law:它們是 `Either` 的短路組合子,性質等同 `Either` 的
  monad 律,而「失敗就不繼續」這件事已由 L1 與 L16 的「檔案不變」觀察到。
- **L-**:`orMd` / `vaultAbsPath` / `ensureDir` / `readDocument` / `locate` / `dropFile` 無獨立
  law:它們是純粹的包裝與定位,沒有任何從公開介面觀察得到、而不被 L10 / L13 / L16 覆蓋的行為。

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| E1 | 註冊表中 `character` 的 `dir = "characters"`;`createTopicFile vh reg (NewEntity{neType="character", neTitle="琳達", nePath=Nothing, …})` | `Right CreateResult{crPath = "characters/琳達.md", crRevision = Revision 1}`,檔案存在且 `toTopic` 解得 `metaTitle == "琳達"` | 正常路徑;中文檔名;註冊表落點 |
| E2 | `createLevelFile vh reg (NewLevel{nlTitle="第一章", nlRootTitle="序幕", nlRootKind=…, nlPath=Nothing})` | `Right CreateResult{crPath = "levels/第一章.md"}`;`toLevel` 回一個 `Level` 與恰好一個 `Node`,`lvlRoot == metaId(該 Node)`,根節點標題層級為 2 | Level 檔一定要有根 Node |
| E3 | `createPackFile vh pack [sA, sB, sC]`(三筆 `NSAsset`,`nsId` 分別 `ast-0000000a/b/c`) | `Right CreateResult{crPath = "<npDir>/pack.md"}`;`toPack` 回的 asset 順序為 `a, b, c` | 節順序 = 給定順序 |
| E4 | 既有 asset `ast-1` 的 `sha256 = "aa…"`;`writeAssetFields vh ast-1 r (AssetPatch{apName = Just (Just n'), apLicense = Nothing, apAuthor = Just Nothing, apTags = Nothing})` | `Right WriteResult{…}`;重讀後 `astName == Just n'`、`astAuthor == Nothing`、`astSha256 == "aa…"` 未變、`astLicense` 未變 | 三態語意 + 唯讀欄位 |
| E5 | 檔案裡 `revision: 3`;`writeMeta vh i (Revision 2) f` | `Left (RevisionMismatch i (Revision 2) (Revision 3))`,檔案位元組與呼叫前逐字相同 | 樂觀鎖失敗路徑 |
| E6 | 索引裡已存在 `newId p c t 0` 與 `newId p c t 1` 兩個 id;`allocateId vh p c` | `Right i`,且 `i` 與那兩個都不同(實作上即 salt = 2 的那一個) | 人為製造碰撞 |
| E7 | 節點 `i` 的 `links` 不含 `l`;`removeLink vh i r l` | `Left (LinkNotFound i l)`,檔案位元組不變 | 刪不存在的關聯 |
| E8 | Level 檔的根 Node `nod-root`;`deleteNode vh nod-root r DeleteForce` | `Left (CannotDeleteRootNode nod-root)`,檔案不變 | 根節點刪不得;`DeleteForce` 也擋 |
| E9 | `pack.md` 裡有 `sha256` / `entry` 的 asset 節;`writeBody vh ast-1 r "新的說明"` | `Right`;重讀後該 asset 的 `astBody == "新的說明"`,`astSha256` / `astEntry` 仍在且未變,其他節位元組不變 | 改正文不得吃掉 payload 欄位 |
| E10 | 目標檔是 `pack.md`(`PackDoc`);`addSection vh pck-1 AtEnd s`,其中 `nsPayload = NSFragment ov` | `Left (BadSectionPayload (nsId s) PackDoc)`,檔案不變 | payload 與文件種類不符;`AtEnd` 也擋 |
| E11 | `sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91"` | `"第一章- 序幕"`(冒號換 `-`、去尾端空白) | 檔名淨化;非 ASCII 保留 |
| E12 | Level 檔:`## 序幕`(`nod-root`)、`### 開場`(`nod-a`)、`### 收束`(`nod-b`);`addSection vh lvl-1 (UnderParent nod-a) s`,其中 `nsPayload = NSNode ov (NewNode KScene)`、`nsLevel = 2`(故意給錯) | `Right CreateResult{crId = nsId s}`;重讀後新節的標題是 `#### …`(**4 級,由 `secLevel nod-a + 1` 推導,不是呼叫端給的 2**),文件順序為 `序幕 / 開場 / 新節 / 收束`,`nodParent` 該新節 `== nod-a`,`nod-b` 那一節的位元組未變 | `UnderParent` 正常路徑;`nsLevel` 由 store 推導;插入點前後都不動 |
| E13 | 同上的 Level 檔;`addSection vh lvl-1 (UnderParent nod-zzz) s`(`nod-zzz` 不在檔案裡) | `Left (SectionMissing "levels/第一章.md" nod-zzz)`,檔案位元組不變 | `UnderParent` 的父節點不存在 |
| E14 | Level 檔裡 `nod-deep` 的標題是 `###### 最深`(6 級);`addSection vh lvl-1 (UnderParent nod-deep) s` | `Left (NodeDepthExceeded nod-deep 7)`,檔案位元組不變 | Markdown 只有六級標題 |
| E15 | 索引的 `nodes` 表被 `DROP` 掉;`allocateId vh PEnt "琳達"` | `Left (SqliteError _)`,**不是 `Right`** | 碰撞查詢失敗即失敗,不靜默照發 |
| E16 | `renderStoreError (VaultMarkerMissing "/tmp/v")`(F005 的既有建構子) | 非空,且含以「請」起頭的子句 | L15 的範圍含 F005 原有的 6 個建構子(骨架已實作,應為綠) |

## 依賴

`depends-on: [F004, F006]`(與 design.md 功能規劃 #8 的「依賴」欄一致)。F004 給 md 的寫回
介面(寫入管線的「md 寫回」一段);F006 給 `indexFile` / `unindexFile`、定位用的索引結構與
`linksTo`(被引用檢查)。

下表另外用到 **F001**(`Meta` / `Id` / `Link` / `Tree` / `Asset` / `Pack` / `License` 型別、
`newId`、`bumpRevision`、`buildTree`)、**F002**(`lookupDir`)與 **F005**
(`VaultHandle` / `atomicWriteText` / `readTextFile` / `StoreError` / `trySqlite`);三者**不**
另外列進 `depends-on`,因為它們已經是 F004(依賴 #1、#2)與 F006(依賴 #1、#4、#5)的
遞移相依——本 feature 沒有繞過那兩份文檔直接抵達的相依邊。所有簽名都已從原始碼讀出。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection, vhRegistry :: TypeRegistry }` | `store/src/Aapms/Store/Marker.hs:73` | F005 | 所有寫入的第一個參數;`vhRoot` 組絕對路徑、`vhConn` 定位與配號 |
| `atomicWriteText :: FilePath -> Text -> IO (Either StoreError ())` | `store/src/Aapms/Store/Atomic.hs:44` | F005 | 寫檔那一步(暫存檔 + rename) |
| `readTextFile :: FilePath -> IO (Either StoreError Text)` | `store/src/Aapms/Store/Atomic.hs:35` | F005 | 重讀檔案做樂觀鎖比對 |
| `data StoreError` / `renderStoreError :: StoreError -> Text` | `store/src/Aapms/Store/Error.hs:29` / `:80` | F005 | **本 feature 擴充它**(+15 建構子),不另立平行型別 |
| `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/Aapms/Store/Error.hs:121` | F005 | 定位查詢與配號查詢的 SQLite 邊界;`allocateId` 的失敗通道就是它回的 `SqliteError` |
| `indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])` | `store/src/Aapms/Store/Index.hs:147` | F006 | 寫檔之後只重讀該檔 |
| `unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | `store/src/Aapms/Store/Index.hs:154` | F006 | 刪整份檔案時清索引 |
| `data IndexIssue` | `store/src/Aapms/Store/Schema.hs:70` | F006 | `WriteResult` / `CreateResult` 的附帶回報 |
| `linksTo :: VaultHandle -> Ref -> IO [(Meta, Link)]` | `store/src/Aapms/Store/Query.hs:439` | F006 | `deleteNode` 的被引用檢查 |
| `parseDocument :: Text -> Either MdError Document` | `md/src/Aapms/Md/Parse.hs:52` | F004 | 重讀後切塊 |
| `toTopic :: Document -> Either MdError (Entity, [Entity])` | `md/src/Aapms/Md/Parse.hs:124` | F004 | 取得主題檔目前的 `Meta`(比對 revision)與寫檔前的自我驗證 |
| `toLevel :: Document -> Either MdError (Level, [Node])` | `md/src/Aapms/Md/Parse.hs:140` | F004 | Level 檔同上;`validateLevelDoc` 的第一段 |
| `toPack :: Document -> Either MdError (Pack, [Asset])` | `md/src/Aapms/Md/Parse.hs:224` | F004 | `pack.md` 同上;`writeAssetFields` 讀出目前的 asset 欄位 |
| `toLicenses :: Document -> Either MdError [License]` | `md/src/Aapms/Md/Parse.hs:279` | F004 | `licenses.md` 同上;`upsertLicense` 判斷該 id 是否已存在 |
| `renderDocument :: Document -> Text` | `md/src/Aapms/Md/Render.hs:90` | F004 | 位元組保留的重組 |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:106` | F004 | 節層 meta 改寫(**G2 重跑後型別專屬條目原封不動**) |
| `overrideAt :: Id -> Document -> Either MdError MetaOverride` | `md/src/Aapms/Md/Render.hs:123` | F004 | 先看目前值再決定要不要改(`removeLink` 沒命中要中止) |
| `newtype MetaExtras` / `extrasOf :: Section -> MetaExtras` / `extrasAt :: Id -> Document -> Either MdError MetaExtras` / `mergeExtras` | `md/src/Aapms/Md/Render.hs:163` / `:173` / `:202` / `:212` | F004(G2) | 節層 meta 區塊的另一半:型別專屬條目以原始行保存 |
| `updateSectionExtras :: Id -> (MetaExtras -> MetaExtras) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:225` | F004(G2) | `writeAssetFields` / `upsertLicense` 改 `sha256` 以外的專屬欄位唯一走得通的路 |
| `payloadOverride :: NewSectionPayload -> MetaOverride` / `payloadExtras :: NewSectionPayload -> MetaExtras` | `md/src/Aapms/Md/Render.hs:344` / `:363` | F004(G2) | 把一個 payload 拆成 meta 區塊的兩半 |
| `renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text` | `md/src/Aapms/Md/Render.hs:714` | F004(G2) | 兩半都要,少一半在型別上就寫不出來 |
| `updateSectionBody :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:491` | F004 | 節層換正文 |
| `renameSection :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:514` | F004 | 節層換標題 |
| `replacePreamble :: Text -> Document -> Document` | `md/src/Aapms/Md/Render.hs:537` | F004 | 檔案層主體換正文 |
| `removeSection :: Id -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:481` | F004 | 刪一節 / 刪子樹 |
| `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:586` | F004 | 檔案層 meta 與 revision 遞增 |
| `newDocument :: DocKind -> Meta -> Text -> Document` | `md/src/Aapms/Md/Render.hs:608` | F004 | 從零建一份新檔 |
| `appendSection :: NewSection -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:414` | F004 | `addSection AtEnd` / `createPackFile` 的追加一節 |
| `insertSection :: Id -> NewSection -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:477` | F004 | `addSection (UnderParent p)`:插在 `p` 的子樹之後;`nsLevel` 必須等於 `secLevel p + 1`(由 `headingDepthFor` 算好再交給它) |
| `data NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` | `md/src/Aapms/Md/Render.hs:238` / `:256` / `:272` / `:289` / `:306` | F004(G1) | 一個新節的形狀;`Aapms.Store.Create` 只 re-export |
| `data MetaOverride` | `md/src/Aapms/Md/Inherit.hs:45` | F004 | 節層覆寫 DTO,md 與 store 共用 |
| `overrideOf :: Meta -> MetaOverride` / `applyOverride :: MetaOverride -> Meta -> Meta` | `md/src/Aapms/Md/Inherit.hs:107` / `:130` | F004 | 檔案層主體與節共用同一個修改函式 |
| `data Document`(欄位 `docFrontRaw` / `docPreamble` / `docSections` / `docEnding` / `docFinalNL` / `docKind`)、`data Section`、`sectionById :: Id -> Document -> Maybe Section` | `md/src/Aapms/Md/Document.hs:71` / `:88` / `:106` | F004 | 子樹推導與位元組保留的觀察點 |
| `data MdError = MdError { errLine :: Int, errKind :: MdErrorKind }` | `md/src/Aapms/Md/Error.hs:22` | F004 | 包進 `MdWriteFailed` |
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103` | F001 | `allocateId` 的純函式核心;salt 由本層遞增 |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` / `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:127` / `:123` | F001 | 索引列與 id 之間的轉換 |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }` / `localRef :: Id -> Ref` | `core/src/Aapms/Core/Id.hs:156` / `:163` | F001 | 被引用檢查的查詢鍵 |
| `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/Aapms/Core/Tree.hs:86` | F001 | `validateLevelDoc` 的第二段 |
| `bumpRevision :: Day -> Meta -> Meta` | `core/src/Aapms/Core/Meta.hs:165` | F001 | 全系統唯一的 revision 遞增點 |
| `idPrefix :: Id -> IdPrefix` | `core/src/Aapms/Core/Id.hs:139` | F001 | `allocateId` 的回傳驗證(L14) |
| `data Meta`(14 欄)、`newtype Revision = Revision Int`、`data Status` / `Source` / `Timeline`、`newtype TypeKey = TypeKey Text` | `core/src/Aapms/Core/Meta.hs:123` / `:50` / `:57` / `:80` / `:112` / `:45` | F001 | 寫入 DTO 的欄位型別 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }`(derives `Eq`) | `core/src/Aapms/Core/Link.hs:53` | F001 | `addLink` / `removeLink` 的比對單位 |
| `data TreeError`(7 建構子) | `core/src/Aapms/Core/Tree.hs:40` | F001 | 包進 `TreeInvalidOnWrite` |
| `data Asset`(9 欄)、`newtype Sha256 = Sha256 Text`、`newtype LogicalName = LogicalName Text` | `core/src/Aapms/Core/Asset.hs:35` / `:18` / `:26` | F001 | `NewAsset` / `AssetPatch` 的欄位型別;L4 / L5 的觀察點 |
| `data Pack`、`data Author`、`data AiDisclosure` | `core/src/Aapms/Core/Pack.hs:36` / `:27` / `:19` | F001 | `NewPack` 的欄位型別 |
| `data License`(八個授權維度 + `licFullText`) | `core/src/Aapms/Core/License.hs:13` | F001 | `upsertLicense` 的輸入 |
| `data NodeKind` | `core/src/Aapms/Core/Level.hs:27` | F001 | `NewNode` / `NewLevel` 的欄位型別 |
| `data TypeRegistry`、`lookupDir :: TypeRegistry -> TypeKey -> Maybe FilePath` | `core/src/Aapms/Core/Registry.hs:167` | F002 | 建檔落點 |

### 依賴方向

- **依賴誰**:`aapms-md`(全部寫回介面)、`aapms-core`(型別、`newId`、`bumpRevision`、
  `buildTree`、`lookupDir`)、`aapms-store` 內的 `Marker` / `Atomic` / `Error` / `Schema` /
  `Index` / `Query`
- **誰會依賴它**:`service`(全部)、`asset-ingest`(`createPackFile` / `addSection` /
  `writeAssetFields` / `deleteNode` / `allocateId`);同子系統內 F009(`store-multi-vault-read`)
  **不**依賴它——`VaultSet` 只開讀取
- **新增的依賴邊**(本次新增的 import 方向,一條都不漏):
  - `Aapms.Store.Error` → `Aapms.Core.{Id,Link,Meta,Tree}`、`Aapms.Md.{Document,Error}`
    (2026-08-25:錯誤建構子要說得出「哪個節點、哪一筆關聯、哪一種文件」)。
    **它不 import 任何 `Aapms.Store.*`**,所以是 `aapms-store` 內部依賴圖的葉子,無模組環;
    套件層也不新增邊——`aapms-store` 對 `aapms-core` / `aapms-md` 的 `build-depends` 早就有
  - `Aapms.Store.Edit` → `Aapms.Core.{Id,Meta}`、`Aapms.Md.{Document,Error}`、
    `Aapms.Store.{Error,Marker,Schema}`
  - `Aapms.Store.Write` → `Aapms.Core.{Asset,Id,License,Link,Meta}`、`Aapms.Md.Inherit`、
    `Aapms.Store.{Edit,Error,Marker}`
  - `Aapms.Store.Node` → `Aapms.Core.Id`、`Aapms.Md.Document`、`Aapms.Store.Error`
    (不再需要 `Aapms.Store.Edit`——錯誤型別搬走之後它只剩純推導)
  - `Aapms.Store.Create` → `Aapms.Core.{Asset,Id,Level,Link,Meta,Pack,Registry}`、
    **`Aapms.Md.Render`**(re-export `NewSection` 家族)、`Aapms.Store.{Error,Marker,Schema}`
  - `Aapms.Store`(門面)→ `Aapms.Store.{Create,Write}`
  - 實作階段還會新增(骨架未 import,因為只有本體用得到):
    `Aapms.Store.Edit` → `Aapms.Store.{Atomic,Index}`、`Aapms.Md.{Parse,Render}`、
    `Database.SQLite.Simple`;`Aapms.Store.Create` → `Aapms.Store.{Edit,Node,Write,Query}`、
    `Aapms.Md.{Parse,Render}`、`System.Directory`、`System.FilePath`;
    `Aapms.Store.Write` → `Aapms.Store.Edit`(已有)、`Aapms.Md.{Parse,Render}`、`Data.Time`
  - **模組內部順序**:`Error → Edit → {Write, Node} → Create → Aapms.Store`,無環
- **可否與其他進行中任務平行開發**:可以。F007(`store-fts-dual-index`)只碰
  `Tokenize` / `Query` / `Schema`,與本 feature 的四個檔案不重疊。**唯一的交會點**是
  `Aapms.Store.Query.linksTo`(本 feature 的 `deleteNode` 要用)與
  `Aapms.Store.Schema.IndexIssue`(結果型別的欄位),兩者都在契約 E / F 內,F007 不應改動。

## 不可逆決定

1. **寫入順序固定為「檔案 → 索引」,不做兩段式提交。**
   否決的替代方案:先寫索引再寫檔(索引比檔案新,`rebuildIndex` 反而會把新資料洗掉——
   索引是衍生物,ADR-013);或用一個跨越檔案 IO 的 SQLite 交易把兩者綁起來(直接違反
   ADR-022,寫鎖會被持有到檔案 IO 結束)。代價是索引可能落後,`IndexUpdateFailed` 明說
   「資料已寫入,索引需重建」——這是可修復的狀態,反過來不是。

2. **樂觀鎖比對的來源是「重讀的檔案」,不是索引。**
   否決的替代方案:比對索引裡的 `nodes.revision`(省一次讀檔)。作者用編輯器直接改過而
   索引還沒 refresh 時,索引的 revision 是舊的,樂觀鎖會放行一次覆蓋——那正是這個機制要
   防的事。索引在寫入路徑上只做定位。

3. **`writeAssetFields` 對 `sha256` / `entry` / `ext` / `meta` 的拒絕是型別層的,不是執行期檢查。**
   否決的替代方案:讓 `AssetPatch` 帶這四欄並在執行期回 `AssetFieldReadOnly`(呼叫端會
   先寫程式再被擋,而且每加一個唯讀欄位就要記得補一條檢查)。型別層拒絕的代價是
   「掃描器要改 sha256 怎麼辦」必須另有出口——出口是 `deleteNode` + `addSection`,那也是
   語意上正確的:檔案換了就是換了一筆 asset。

4. **`DeleteSafe` 不自動清掉指向被刪目標的關聯。**
   否決的替代方案:連帶改寫所有來源檔案(多檔寫入沒有交易保證,改到一半失敗會留下不一致);
   或直接允許孤兒關聯而不提示(呼叫端無從得知資料變殘)。現在的做法把決定權交回作者:
   `DeleteSafe` 擋、`DeleteForce` 刪並列出斷點。

5. **`upsertLicense` 的 expected revision 取自傳入的 `License` 自己的 `metaRevision`。**
   否決的替代方案:改簽名多收一個 `Revision` 參數(偏離契約 E);或不做樂觀鎖(授權是
   全 vault 共用的資料,靜默覆蓋的傷害面比單一節點大得多)。完整的 `License` 本來就帶著
   revision,拿它比對不需要新增任何管道。

6. **`allocateId` 帶失敗通道:碰撞查詢失敗即失敗,不靜默照發**(2026-08-25 開發者裁決,
   已回寫契約 E)。
   否決的替代方案:查詢出錯時視同「查不到」並回傳當前候選(省一條 `Either`)。代價不對稱:
   靜默照發會把一個**未經碰撞檢查的 id** 寫進 Markdown,而依 ADR-013 **檔案是真相**——
   重複的身分就這樣落地了。它不會在 `commit` 的 `IndexUpdateFailed` 現形(那只說索引沒跟上,
   沒說 id 撞了),只能等到某次 `rebuildIndex` 撞 `nodes.id` 主鍵才發現,而那時的修復是
   人工改檔案裡的 id **與所有指向它的關聯**。多一節 `>>?` 短路,換掉一種需要人工考古的
   資料損壞。

7. **`addSection` 的落點用封閉 sum `SectionPlacement`,不是 `Maybe Id`**(2026-08-25 開發者
   裁決,已回寫契約 E)。
   否決的替代方案:`Maybe Id`(`Nothing` = 檔尾)。落點種類日後若要再長(「插在某個兄弟
   之前」、「插在第 n 個子節點的位置」),`Maybe` 加不進第三種,只能再改一次簽名而編譯器
   不會提醒任何一處呼叫端;封閉 sum 加建構子時編譯器會列出所有待處理處——與 `AnyNode` /
   `NewSectionPayload` / `DeleteMode` 同一個模式。
   **`UnderParent` 的 `nsLevel` 由 store 以 `headingDepthFor` 推導,不看呼叫端給的值**:
   呼叫端自己算標題層級,等於讓父子關係有兩個真相來源(ADR-009 是「標題階層即樹」,
   標題層級**就是**父子關係本身)。

8. **`StoreError` 是 `aapms-store` 的唯一錯誤型別;本 feature 擴充它,不另立
   `StoreWriteError` 再橋接**(design.md 契約 G,2026-08-25 落實)。
   否決的替代方案:寫入路徑自己一個錯誤型別、以 `WriteStore StoreError` 為橋(骨架
   2026-08-24 的暫居形狀)。代價是 `service` 會看到兩種形狀、兩套 `render*`、每次跨層都要
   翻譯一次,而這 15 個建構子與既有 6 個**沒有任何名稱衝突**,合併是零語意變更的操作。
   代價在 `Error.hs` 這一側:它現在依賴 `aapms-core` 與 `aapms-md` 的型別;可接受的理由是
   它**不 import 任何 `Aapms.Store.*`**,仍是內部依賴圖的葉子,而套件層的 `build-depends`
   本來就有那兩個。

## 已裁決的假設(2026-08-25 閘門)

2026-08-24 骨架留下的 A1–A6 六條全數結案,結論如下;**契約已由編排者回寫進 design.md,
契約是唯一真相**。

| # | 原假設 | 裁決 | 落點 |
|---|---|---|---|
| A1 | `createPackFile` 第三參數改 `[NewSection]`(偏離當時的契約 E) | **接受**,回寫契約 E | `design.md:317`;`Create.hs:234` |
| A2 | 在 `Aapms.Store.Edit` 定義暫居的 `StoreWriteError`,以 `WriteStore` 為橋 | **推翻**:15 個建構子併進 `StoreError`,刪 `WriteStore` 與 `renderStoreWriteError` | 見「不可逆決定 8」;`Error.hs:29` / `:80` |
| A3 | `allocateId :: … -> IO Id`,查詢失敗視同查不到 | **推翻**:改 `IO (Either StoreError Id)`,查詢失敗即失敗 | 見「不可逆決定 6」;`Write.hs:171` |
| A4 | `NewSection` 家族暫居 `Aapms.Store.Create` | **推翻**:F004 G2 重跑已把它們放進 `Aapms.Md.Render`,store 改成 re-export | `Create.hs` 匯出清單;`md/src/Aapms/Md/Render.hs:238` 起 |
| A5 | `addSection` 只能追加檔尾,`nsLevel` 由呼叫端給 | **推翻**:加 `SectionPlacement`;`UnderParent` 時 `nsLevel` 由 `headingDepthFor` 推導 | 見「不可逆決定 7」;`Create.hs:189` / `:267` |
| A6 | 門面不 re-export 本 feature 的模組 | **補上**:`Aapms.Store` re-export `Create` 與 `Write`(`Edit` / `Node` 仍為內部模組) | `store/src/Aapms/Store.hs:32` / `:38` |

本次修訂**沒有新的待確認假設**。

## 骨架

| 檔案 | 內容 |
|---|---|
| `store/src/Aapms/Store/Error.hs` | `StoreError` **+15 建構子**(`NodeNotFound` … `NodeDepthExceeded`);`renderStoreError` 的 15 個新分支為 `undefined`,F005 原有的 6 個維持已實作 |
| `store/src/Aapms/Store/Edit.hs` | `WriteResult`、`Located`、`(>>?)` / `(?>>)`、`locate` / `readDocument` / `orMd` / `checkRevision` / `commit` / `dropFile` / `ensureDir` / `vaultAbsPath` / `sectionBodyRaw`(**不再定義錯誤型別**) |
| `store/src/Aapms/Store/Write.hs` | `AssetPatch`;re-export `WriteResult`;`writeMeta` / `writeAssetFields` / `writeBody` / `addLink` / `removeLink` / `upsertLicense` / `allocateId` |
| `store/src/Aapms/Store/Node.hs` | `headingDepthFor` / `subtreeAfter` / `subtreeIds` / `isRootNode` / `validateLevelDoc`(全部純函式) |
| `store/src/Aapms/Store/Create.hs` | `NewEntity` / `NewLevel` / `NewPack` / `SectionPlacement` / `CreateResult` / `DeleteMode` / `DeleteResult`;**re-export** `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode`(定義在 `Aapms.Md.Render`);`createTopicFile` / `createLevelFile` / `createPackFile` / `addSection` / `deleteNode` / `sanitizeFileName` |
| `store/src/Aapms/Store.hs` | 門面 re-export `Aapms.Store.Create` 與 `Aapms.Store.Write` |

本 feature 的所有函數本體皆為 `undefined`(`renderStoreError` 只有本 feature 新增的 15 個
分支是 `undefined`,F005 的 6 個是既有實作,不動)。型別檢查方式與結果見回報。

## 實作備註

(撰寫時留空)
