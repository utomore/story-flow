---
id: F008
type: feature
title: store-write-operations
description: vault 的建檔、增節、改寫、刪除與短 id 配號,全部走樂觀鎖與原子寫入
status: done
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
| D(Markdown) | `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` | 定義在 `Aapms.Md.Render`(F004 GAP-2 重跑落地),`Aapms.Store.Create` 只 re-export |
| D(Markdown) | `insertSection`(`UnderParent` 落點用) | 由 F004 提供,本 feature 只呼叫 |
| G(錯誤) | 寫入路徑的 15 個錯誤建構子,併進**唯一**的 `StoreError` | `Aapms.Store.Error` |
| 內部模組劃分 | 「Write:建檔、增節、改寫、刪除、Node、License;樂觀鎖;`allocateId`」 | `Edit` / `Write` / `Node` / `Create` 四個檔案(下方「骨架」) |
| 資料流管線 | **寫入管線全段** | `Aapms.Store.Edit.commit` 定義那條線的順序 |
| 門面 | `Aapms.Store` re-export 契約 E 的寫入組 | `store/src/Aapms/Store.hs:32` / `:38` |

未超出範圍:本 feature 不新增任何契約 E 之外的對外函式;`Aapms.Store.Edit` /
`Aapms.Store.Node` 是內部模組,不進契約也不進門面(`WriteResult` 是例外——它是契約 E
寫入組的回傳型別,由 `Aapms.Store.Write` re-export 帶進門面)。**簽名零偏離**:
2026-08-25 的閘門把 `createPackFile` 的第三參數、`addSection` 的落點參數與
`allocateId` 的失敗通道都回寫進 design.md 契約 E;同日的 GAP-8 裁決再把 `allocateId` 的
**`UTCTime` 明碼參數**回寫進去(`design.md:326`)。本文件與契約逐字一致。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `StoreError` | **擴充**(+15 建構子) | `Error.hs:29`,新建構子從 `Error.hs:41` 起(`NodeNotFound` … `NodeDepthExceeded`) | 寫入路徑可能發生哪些失敗,以及每一種的下一步。**不另立平行型別**(design.md 契約 G) |
| `WriteResult` | 新增 | `{ wrId :: Id, wrPath :: FilePath, wrRevision :: Revision, wrIssues :: [IndexIssue] }`,`Edit.hs:96` | 一次改寫之後,新的 revision 與索引附帶回報 |
| `Located` | 新增 | `{ locPath :: FilePath, locAnchor :: Maybe Id, locKind :: DocKind }`,`Edit.hs:132` | 索引在寫入路徑上唯一的用途:目標住在哪個檔、哪一節、那是哪種文件 |
| `NewEntity` | 新增 | `Create.hs:123` | 一份新主題檔的全部人給欄位(不含 revision / 日期——那些由本層填) |
| `NewLevel` | 新增 | `Create.hs:144` | 一份新 Level 檔 + 它的根 Node |
| `NewPack` | 新增 | `Create.hs:161` | 一份新 `pack.md` 的檔案層欄位與落點目錄 |
| `NewSection` | **沿用 md** | `md/src/Aapms/Md/Render.hs:238`,`Create.hs` 只 re-export | 一個新節的共通骨架(四種文件共用) |
| `NewSectionPayload` | **沿用 md** | `md/src/Aapms/Md/Render.hs:256` | 「這一節是哪一種節點」以及它專屬的欄位 |
| `NewAsset` | **沿用 md** | `md/src/Aapms/Md/Render.hs:272` | 一筆 asset 的檔案事實(`sha256` / `entry` 由 `asset-ingest` 算好給) |
| `NewLicense` | **沿用 md** | `md/src/Aapms/Md/Render.hs:289` | 一種授權允許什麼、要求什麼 |
| `NewNode` | **沿用 md** | `md/src/Aapms/Md/Render.hs:306` | Level 節點唯一不能由標題階層推導的事實 |
| `SectionPlacement` | 新增 | `AtEnd \| UnderParent Id`,`Create.hs:227` | 新節要落在檔尾還是某個父節點底下 |
| `AssetPatch` | 新增 | `{ apName, apLicense, apAuthor, apTags }`,兩層 `Maybe`,`Write.hs:96` | **人可以改 asset 的哪些欄位**——`sha256` / `entry` / `ext` / `meta` 不在裡面是型別層的拒絕 |
| `CreateResult` | 新增 | `{ crId, crPath, crRevision, crIssues }`,`Create.hs:196` | 剛建出來的節點的 id(呼叫端唯一拿不到其他來源的資訊) |
| `DeleteMode` | 新增 | `DeleteSafe \| DeleteForce`,`Create.hs:207` | 被指向時要擋還是照刪 |
| `DeleteResult` | 新增 | `{ drPath, drRemovedIds, drBrokenLinks, drIssues }`,`Create.hs:210` | 這次刪掉了哪些 id、打斷了哪些關聯 |

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
| `createTopicFile :: VaultHandle -> TypeRegistry -> NewEntity -> IO (Either StoreError CreateResult)` | 建一份新的主題檔,落點依註冊表的 `dir` | `store/src/Aapms/Store/Create.hs:245` |
| `createLevelFile :: VaultHandle -> TypeRegistry -> NewLevel -> IO (Either StoreError CreateResult)` | 建一份新的 Level 檔,連同它的根 Node | `store/src/Aapms/Store/Create.hs:308` |
| `createPackFile :: VaultHandle -> NewPack -> [NewSection] -> IO (Either StoreError CreateResult)` | 在指定目錄寫出 `pack.md`,節的順序與給定順序相同 | `store/src/Aapms/Store/Create.hs:369` |
| `data SectionPlacement = AtEnd \| UnderParent Id` | 新節落在檔尾,還是插在指定父節點底下 | `store/src/Aapms/Store/Create.hs:227` |
| `addSection :: VaultHandle -> Id -> SectionPlacement -> NewSection -> IO (Either StoreError CreateResult)` | 往既有檔案加一個節,依 `nsPayload` 分派;`UnderParent` 時 `nsLevel` 由 `headingDepthFor` 推導,不由呼叫端給 | `store/src/Aapms/Store/Create.hs:437` |
| `writeMeta :: VaultHandle -> Id -> Revision -> (MetaOverride -> MetaOverride) -> IO (Either StoreError WriteResult)` | 改一個既有節點的 `Meta` 欄位 | `store/src/Aapms/Store/Write.hs:120` |
| `writeAssetFields :: VaultHandle -> Id -> Revision -> AssetPatch -> IO (Either StoreError WriteResult)` | 改一筆 asset 的人給欄位 | `store/src/Aapms/Store/Write.hs:151` |
| `writeBody :: VaultHandle -> Id -> Revision -> Text -> IO (Either StoreError WriteResult)` | 換掉一個節點的正文 | `store/src/Aapms/Store/Write.hs:208` |
| `addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)` | 在來源節點上加一筆關聯 | `store/src/Aapms/Store/Write.hs:244` |
| `removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreError WriteResult)` | 從來源節點刪掉相符的關聯 | `store/src/Aapms/Store/Write.hs:260` |
| `upsertLicense :: VaultHandle -> License -> IO (Either StoreError WriteResult)` | 把一種授權寫進該 vault 的 `licenses.md`(有就改、沒有就新增) | `store/src/Aapms/Store/Write.hs:314` |
| `deleteNode :: VaultHandle -> Id -> Revision -> DeleteMode -> IO (Either StoreError DeleteResult)` | 刪一個節點;目標是什麼決定刪掉多少 | `store/src/Aapms/Store/Create.hs:530` |
| `allocateId :: VaultHandle -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)` | 產生一個索引裡還沒有人用的短 id;候選恆為 `newId p c t salt`,`salt` 從 0 起遞增;**碰撞查詢失敗即失敗,不靜默照發**;**時間是明碼參數**(2026-08-25 GAP-8 裁決) | `store/src/Aapms/Store/Write.hs:423` |

**`allocateId` 的時間為什麼是明碼參數**(2026-08-25 GAP-8 裁決,契約 E 已回寫,`design.md:326`):
與 `Aapms.Core.Id.newId` 一致。藏在函式內部取樣(`getCurrentTime`)的話,呼叫端就**無法
預先造出碰撞**,salt 遞增重試那個迴圈也就永遠測不到——而碰撞在正常情況下幾乎不發生,
那段程式碼可能永遠是錯的而沒人知道(這正是 qa 撞上 GAP-8、EX-6 整項停下的原因)。

**四個 create 函式的對外簽名不變**:`createTopicFile` / `createLevelFile` /
`createPackFile` / `addSection` 內部會呼叫 `allocateId`,但它們**自己取當下時間**
(`Data.Time.getCurrentTime`)再傳進去,**不把 `UTCTime` 一路往上加到契約 E 的簽名裡**。
impl 不要以為要一路加參數:可控時間源是 `allocateId` 一個人的事,建檔路徑不需要那個能力。

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
**已經是實作過的**,新的 15 個是 `undefined` —— LAW-15 的測試因此會是「6 綠 15 紅」,
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
| `(>>?) :: IO (Either StoreError a) -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)` | 失敗就短路的 IO 鏈 | `store/src/Aapms/Store/Edit.hs:109` |
| `(?>>) :: Either StoreError a -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)` | 把純函式那一段接進同一條鏈 | `store/src/Aapms/Store/Edit.hs:118` |
| `locate :: VaultHandle -> Id -> IO (Either StoreError Located)` | 說出目標住在哪個檔、哪一節、那是哪種文件 | `store/src/Aapms/Store/Edit.hs:142` |
| `readDocument :: VaultHandle -> FilePath -> IO (Either StoreError Document)` | 重讀檔案並切塊 | `store/src/Aapms/Store/Edit.hs:182` |
| `orMd :: FilePath -> Either MdError a -> Either StoreError a` | 把 md 的錯誤接上檔名 | `store/src/Aapms/Store/Edit.hs:188` |
| `checkRevision :: Id -> Revision -> Revision -> Either StoreError ()` | 比對呼叫端手上的 revision 與檔案裡的實際值 | `store/src/Aapms/Store/Edit.hs:197` |
| `commit :: VaultHandle -> FilePath -> Document -> Id -> Revision -> IO (Either StoreError WriteResult)` | 把已經算好的最終內容落地,並讓該檔的索引跟上 | `store/src/Aapms/Store/Edit.hs:211` |
| `dropFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | 移除一份檔案與它的全部索引記錄 | `store/src/Aapms/Store/Edit.hs:232` |
| `ensureDir :: VaultHandle -> FilePath -> IO ()` | 建出目標檔案所在的目錄 | `store/src/Aapms/Store/Edit.hs:245` |
| `vaultAbsPath :: VaultHandle -> FilePath -> FilePath` | Vault 相對路徑 → 絕對路徑 | `store/src/Aapms/Store/Edit.hs:249` |
| `sectionBodyRaw :: LineEnding -> Text -> Text` | 把正文包成節的正文切片形狀 | `store/src/Aapms/Store/Edit.hs:257` |

### 內部:Level 樹推導(`Aapms.Store.Node`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `headingDepthFor :: FilePath -> Document -> Id -> Either StoreError Int` | 在指定父節點底下新增子節點時,新節該用第幾級標題 | `store/src/Aapms/Store/Node.hs:43` |
| `subtreeAfter :: Document -> Id -> [Section]` | 某一節之後、屬於它子樹的所有節 | `store/src/Aapms/Store/Node.hs:55` |
| `subtreeIds :: Document -> Id -> [Id]` | 某一節與它整棵子樹的 id,依文件順序 | `store/src/Aapms/Store/Node.hs:64` |
| `isRootNode :: FilePath -> Document -> Id -> Either StoreError Bool` | 這個 id 是不是該 Level 檔的根 Node | `store/src/Aapms/Store/Node.hs:81` |
| `validateLevelDoc :: FilePath -> Document -> Either StoreError ()` | 編輯後的 Level 檔還解析得回來、樹還合法嗎 | `store/src/Aapms/Store/Node.hs:94` |

### 內部:檔名(`Aapms.Store.Create`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `sanitizeFileName :: Text -> Text -> Text` | 標題 → 檔名主幹,保留中文原字元 | `store/src/Aapms/Store/Create.hs:591` |

## Laws(行為性質)

以下 `f` 一律指契約 E 帶 `Revision` 參數的寫入介面(`writeMeta` / `writeAssetFields` /
`writeBody` / `addLink` / `removeLink` / `deleteNode`);`bytes p` 指路徑 `p` 上的檔案位元組。

- **LAW-1(樂觀鎖:不符即拒且檔案未動)**:對所有節點 `i`、所有 `r /= 檔案裡的實際 revision`,
  `f vh i r …` 回 `Left (RevisionMismatch i r 實際值)`,且呼叫前後 `bytes(該檔)` 相同。
  `checkRevision i r a` 在 `r == a` 時且僅在此時回 `Right ()`。
- **LAW-2(revision 恰好 +1,且與檔案一致)**:對所有成功的 `f vh i r …`,回傳的
  `wrRevision == Revision (n+1)`(其中 `Revision n = r`),且重新 `parseDocument` +
  `to*` 之後該節點的 `metaRevision` 等於 `wrRevision`。`CreateResult` 的 `crRevision` 同理
  (新檔為 `Revision 1`)。
- **LAW-3(位元組保留)**:對所有含節的文件 `d` 與任一目標節 `s`,`writeMeta` / `writeBody` /
  `addLink` / `removeLink` 成功之後,`d` 裡**除 `s` 以外**每一節的 `renderSection` 位元組
  與呼叫前相同;目標若是檔案層主體,則所有節都不變。
- **LAW-4(asset 唯讀欄位不變)**:對所有 `AssetPatch p` 與任一 asset `a`,`writeAssetFields`
  成功之後重新 `toPack` 取得的 `a'` 滿足 `astSha256 a' == astSha256 a`、
  `astEntry a' == astEntry a`、`astExt a' == astExt a`、`astKindMeta a' == astKindMeta a`、
  `astBody a' == astBody a`。
- **LAW-5(`AssetPatch` 的三態語意)**:對所有 `p`,寫入後 `astName a'` =
  `case apName p of Nothing -> astName a; Just v -> v`;`astLicense` / `astAuthor` /
  `metaTags` 同構(`apTags` 只有兩態:`Nothing` 不動、`Just xs` 設成 `xs`)。
- **LAW-6(`addLink` / `removeLink` 往返)**:對所有 `l` 不在節點 `i` 目前的 `metaLinks` 內,
  先 `addLink vh i r l` 再 `removeLink vh i (r+1) l` 之後,`linksFrom vh i` 的結果與最初相同,
  且檔案位元組與最初相同**除了** frontmatter / meta 區塊裡的 `revision` 與 `updated` 兩行。
- **LAW-7(`removeLink` 沒命中不寫檔)**:對所有不在節點 `i` 的 `metaLinks` 內的 `l`,
  `removeLink vh i r l` 回 `Left (LinkNotFound i l)`,且 `bytes(該檔)` 不變。
- **LAW-8(`upsertLicense` 讀回相等)**:對所有 `License l`,`upsertLicense vh l` 成功之後
  `toLicenses` 解出的那一筆 `l'` 在**除 `licMeta` 的 `metaRevision` / `metaUpdated` 與
  `licFullText` 以外**的每一欄都等於 `l`;對同一個 `licMeta` 的 id 呼叫兩次,
  `licenses.md` 的節數不變。
- **LAW-9(`createPackFile` 順序保持)**:對所有非空的 `[NewSection] xs`(每筆 payload 皆為
  `NSAsset`),產出的 `pack.md` 以 `toPack` 解析回來的 asset 清單長度等於 `length xs`,
  且第 `k` 筆的 `metaId` 等於 `nsId (xs !! k)`。
- **LAW-10(`createTopicFile` 落點)**:對所有在註冊表中 `lookupDir reg t == Just d` 的型別 `t`,
  `createTopicFile` 且 `nePath == Nothing` 時回傳的 `crPath` 以 `d <> "/"` 為前綴、以 `.md`
  結尾;`lookupDir reg t == Nothing` 時回 `Left (RegistryDirUnknown t)` 且不寫任何檔案。
- **LAW-11(`createLevelFile` 產出可解析的 Level)**:對所有 `NewLevel`,回傳的 `crPath` 以
  `levels/` 為前綴(`nlPath == Nothing` 時),且該檔 `toLevel` 成功、`lvlRoot` 等於唯一那個
  Node 的 `metaId`、`buildTree` 回 `Right`。
- **L12a(`addSection AtEnd` 追加不動前面)**:對所有含 `n` 節的文件,
  `addSection vh i AtEnd s` 成功之後前 `n` 節的 `renderSection` 位元組不變——**唯一的例外是
  插入點之前那一段的行尾**(見下方「插入點行尾的但書」),即第 `n` 節(文件原本沒有任何節時
  則是 `docPreamble`);新節排在最後;且該檔對應的 `to*`(依 `DocKind`)仍然解析成功,
  多出來的那一筆節點的 `metaId` 等於 `nsId s`。
- **L12b(`addSection (UnderParent p)` 只在插入點動刀,層級由父節點決定)**:對所有 Level 檔
  與其中的非根節點 `p`,設 `k = length (subtreeAfter doc p)`、`p` 在文件裡是第 `j` 節,則
  `addSection vh i (UnderParent p) s` 成功之後:
  1. 新節排在第 `j + k + 1` 個位置(= `p` 的子樹之後,成為它的最後一個子節點);
  2. 該位置**之前與之後**的每一節的 `renderSection` 位元組都與呼叫前相同(ADR-010),
     **唯一的例外是插入點之前那一節**——即第 `j + k` 節(`p` 的子樹的最後一節;子樹為空
     時就是 `p` 自己)**的行尾**,見下方「插入點行尾的但書」。插入點**之後**的每一節
     (含 EX-12 的 `nod-b`)一律逐位元組不變,沒有例外;
  3. 重新解析後,`nodParent` 該新節等於 `p`,且新節那一行的 `secLevel` 等於
     `secLevel p + 1` ——**與呼叫端傳進來的 `nsLevel s` 無關**(store 以
     `headingDepthFor` 覆寫);
  4. `toLevel` 成功且 `buildTree` 回 `Right`。

  **插入點行尾的但書**(2026-08-25 開發者裁決,與 F004 的 ASM-10 同一個根,措辭逐字對齊):
  `addSection` 兩條路徑的序列化都由 `aapms-md` 提供(`appendSection` /
  `insertSection`,F004),而它們共用同一個 `blankTail`
  (`md/src/Aapms/Md/Render.hs:438`)。規則是:**插入一節之後,其餘每一節位元組不變——
  唯一的例外是插入點之前那一段的行尾:它還沒有以空行結尾時會被補齊**
  (`blankTail` **冪等**,已經是空行結尾就原樣不動,一個位元組都不補),`appendSection`
  走的是同一條規則。**被動到的是插入點,而不是「未經修改的區塊」,不違反 ADR-010**。
  兩個可機械判定的推論,qa 據此寫斷言:
  - 插入點之前那一段**原本就以空行結尾**時,全檔逐位元組不變(除新節本身);
  - 原本沒有以空行結尾時,那一段的差異**只允許出現在尾端**、且**只允許是補上行尾**
    ——`T.stripEnd` 之後與呼叫前逐位元組相同。

  這個但書只涵蓋**插入點之前那一段**;`docFrontRaw`、`docPreamble`(它不是插入點前一段時)
  與插入點之後的每一節,一律逐位元組不變。LAW-3 / LAW-6 / LAW-16 講的都是**沒有插入**的路徑
  (`writeMeta` / `writeBody` / `addLink` / `removeLink` 與各條失敗路徑),不走
  `appendSection` / `insertSection`,因此**不適用**這個但書,那裡的「位元組不變」仍是無條件的。
- **L12c(`UnderParent` 的兩條失敗路徑不寫檔)**:`p` 不在目標檔案裡時
  `addSection vh i (UnderParent p) s` 回 `Left (SectionMissing _ p)`;`p` 的 `secLevel`
  已經是 6 時回 `Left (NodeDepthExceeded p 7)`。兩者的 `bytes(該檔)` 都與呼叫前相同
  (兩條檢查都在 `commit` 之前)。
- **LAW-13(`deleteNode` 的兩種模式)**:對所有目標 `i`,設 `victims` 為 `subtreeIds` 決定的
  消失集合(檔案層主體則為檔內全部節點 id):
  `DeleteSafe` 時若存在任一 `v ∈ victims` 被 `linksTo` 找得到,回 `Left (ReferencedBy i _)`
  且 `bytes(該檔)` 不變;`DeleteForce` 時成功,`drRemovedIds == victims`,而
  `drBrokenLinks` 恰好是所有指向 `victims` 的 `(來源, 關聯)`。目標是根 Node 時一律回
  `Left (CannotDeleteRootNode i)`,兩種模式皆然。
- **LAW-14(`allocateId` 互異,且成功時才給 id)**:對所有 `(prefix, content)`、**任一固定的
  `t :: UTCTime`** 與所有 `n`,在索引可用的前提下以**同一個 `t`** 連續呼叫
  `allocateId vh prefix content t` `n` 次、每次把結果寫進索引之後,`n` 次呼叫**全部**回
  `Right`,取出的 `n` 個 `Id` 兩兩相異,且每一個的 `Aapms.Core.Id.idPrefix` 都等於 `prefix`。
  **`t` 必須固定**(2026-08-25 GAP-8 裁決收緊):`newId` 是純函式,四個參數裡只要 `t` 每次不同,
  就算 salt 恆為 0 也幾乎必然得到互異的 id——那樣這條 law 測到的是時鐘在走,不是 salt 在遞增。
  固定 `t` 之後 `(prefix, content, t)` 三者相同,唯一能讓 `n` 個結果互異的機制就只剩 salt 遞增,
  這條 law 才真的逼出重試迴圈。
- **L14b(碰撞查詢失敗即失敗)**:索引查詢無法完成時(例如 `nodes` 表被移除),
  `allocateId vh p c t` 回 `Left (SqliteError _)`,**不回 `Right`**。理由見「不可逆決定 6」:
  照發一個未經碰撞檢查的 id 會讓重複的身分落地到檔案(ADR-013 檔案是真相),事後只能靠
  `rebuildIndex` 撞 `nodes.id` 主鍵才發現,修復要人工改檔案裡的 id 與所有指向它的關聯。
- **LAW-15(錯誤訊息說出下一步,涵蓋全部建構子)**:對所有 `StoreError e`,`renderStoreError e`
  非空,且含至少一個以「請」起頭的子句(system.md 全域錯誤處理策略第 2 條)。
  **範圍是 `StoreError` 的全部 21 個建構子**,不只本 feature 新增的 15 個——F005 的 6 個
  (`VaultMarkerMissing` / `VaultMarkerInvalid` / `VaultAlreadyInitialized` / `FileReadFailed` /
  `FileWriteFailed` / `SqliteError`)骨架裡已經實作,測試對它們應該是**綠的**;新的 15 個是
  `undefined`,應該**全紅**。
  **唯一的例外是 `SqliteError`**(2026-08-25 GAP-7 裁決):它的 F005 既有訊息
  `"索引操作失敗 —— " <> msg <> ";可以嘗試重新開啟 vault"` 用「可以嘗試」收尾,不含以「請」
  起頭的子句,與這條判準字面不符。裁決是**改訊息、不放寬判準**——**這是 impl 這一輪要改的一則
  既有訊息**,新原文與授權範圍見 Laws 之後的「`SqliteError` 的訊息要改」,測試見 EX-17。
- **LAW-16(先寫檔、再更新索引)**:對所有成功或以 `IndexUpdateFailed` 收場的寫入,磁碟上的目標
  檔案內容已經是新內容(`readTextFile` 讀得到);反之,任何以 `RevisionMismatch` /
  `MdWriteFailed` / `TreeInvalidOnWrite` / `ReferencedBy` / `LinkNotFound` /
  `BadSectionPayload` / `SectionMissing` / `NodeDepthExceeded` 收場的呼叫,檔案位元組不變。
- **LAW-17(ADR-022 寫鎖預算,結構約束)**:`Aapms.Store.{Edit,Write,Node,Create}` 四個模組的
  **程式碼**(排除 `--` 註解與 haddock)中,只有**兩個機械可判定**的子句:
  1. `withTransaction` 出現 **0 次**,也不出現字面量 `"BEGIN"` / `"COMMIT"`;
  2. `Database.SQLite.Simple` 只在 `Aapms.Store.Edit` 與 `Aapms.Store.Write` 被 import
     (定位查詢與配號查詢)。

  可稽核形式:掃這四個檔案的關鍵字與 import 行即可判定,不需要執行。
  **原本的第三個子句已從本 law 移除**(2026-08-25 GAP-12 裁決):「所有檔案 IO 與所有 md 序列化
  都不在任何 SQLite 呼叫的括號內」改列為 `/arch-audit subsys graph-core` 在階段閘門的**人工
  檢查項**,見「實作備註」。理由:ADR-022 原文把 **code review 與靜態檢測並列**,沒有要求後者
  涵蓋全部;而「X 是否巢狀在 Y 的括號內」是**語法樹層級**的問題,文字掃描在真實的多行
  `do` / `let` / 縮排下會同時製造偽陽性(只是剛好在附近)與偽陰性(經一層 helper 間接呼叫)。
  這與 F007 的 GAP-3 是同一個根——當時的結論也是「要保證的是可觀察行為,不是原始碼字面」。
  與其留一條驗不準的 law 讓人以為有把關,不如明說它靠人看。
- **LAW-18(索引只重讀該檔)**:對所有成功的寫入,`files` 表中**除目標檔外**每一列的
  `(path, mtime, size)` 與呼叫前相同。
- **LAW-19(`sectionBodyRaw` 的形狀)**:對所有非空白的 `t`,`sectionBodyRaw le t` 以
  `renderLineEnding le` 開頭且以之結尾,且 `T.strip (sectionBodyRaw le t) == T.strip t`。
- **LAW-20(`sanitizeFileName` 的值域)**(2026-08-25 GAP-13 裁決後改寫措辭,策略不變):
  **非法字元一律是「替換成 `-`」,不是「移除」**——EX-11 的逐字例子
  (`sanitizeFileName "第一章: 序幕 " fb == "第一章- 序幕"`)是這件事唯一的權威來源。
  對所有 `t` 與**合法的 `fb`**(非空、不含非法字元、不以空白或 `.` 開頭或結尾;慣例上是該節點
  的短 id,見 EX-11。`fb` 是呼叫端給的退路,`sanitizeFileName` 不淨化它,所以這條 law 對
  `fb` 的量詞就限在這個範圍內),令 `r = sanitizeFileName t fb`:
  1. **(值域)** `r` 非空、不含 `< > : " / \ | ? *` 與控制字元、不以空白或 `.` 開頭或結尾;
  2. **(清空退回)** `t` **被清空**時 `r == fb`。「被清空」的**機械定義**(在輸入端就判定得出來,
     不必先算出結果):**`t` 的每一個字元都是空白或 `.`**(空字串亦然)。等價說法:把 `t` 的非法
     字元替換成 `-` 之後,**去掉頭尾的空白與 `.`** 就沒東西剩下——`-` 既不是空白也不是 `.`,
     所以只要 `t` 含任何一個非法字元或任何一個「非空白非 `.`」的合法字元,它就**不算被清空**;
  3. **(非法字元不算被清空)** 因此 `t` 只由非法字元組成時 `r` 是**對應數量的 `-`**,**不是** `fb`
     ——`sanitizeFileName "<" fb == "-"`(見 **EX-20**);`sanitizeFileName "   " fb == fb`、
     `sanitizeFileName "..." fb == fb`(見 **EX-19**);
  4. **(保持)** `t` 只含合法字元、且**不以空白或 `.` 開頭或結尾**時 `r == t`
     (末尾的 `.` 也會被去掉——Windows 不接受以句點結尾的檔名,所以「無頭尾空白」這半句
     必須連 `.` 一起說,否則 `"a.b."` 會是這條的反例)。
- **LAW-21(`headingDepthFor`)**:對所有存在於 `doc` 的父節點 `p`,`headingDepthFor` 的結果等於
  `secLevel p + 1`;該值大於 6 時回 `Left (NodeDepthExceeded p 值)`;`p` 不在 `doc` 裡時回
  `Left (SectionMissing _ p)`。
- **LAW-22(`subtreeIds` 與 `subtreeAfter` 一致)**:對所有 `doc` 與 `i`,
  `subtreeIds doc i == i : map secId (subtreeAfter doc i)`;`subtreeAfter` 的每一節的
  `secLevel` 都嚴格大於 `i` 那一節的 `secLevel`。
- **LAW-23(`validateLevelDoc` 等價於兩段驗證)**:對所有 `doc`,`validateLevelDoc rel doc` 回
  `Right ()` 當且僅當 `toLevel doc` 成功且 `buildTree` 回 `Right`;前者失敗回
  `MdWriteFailed`,後者失敗回 `TreeInvalidOnWrite`。
- **LAW-24(`isRootNode` 的三種結果)**(2026-08-25 GAP-9 裁決補入):對所有 Level 檔的 `Document doc`、
  它的 vault 相對路徑 `path` 與任一 `Id i`,`isRootNode path doc i` 恰好落在三種情形之一:
  1. `i` 存在於 `doc` **且**是該 Level 檔的根 Node(frontmatter 的 `root` / 文件裡第一個節)
     → `Right True`;
  2. `i` 存在於 `doc` **但不是**根 → `Right False`;
  3. `i` **不在** `doc` 裡(`sectionById i doc == Nothing`)→ `Left (SectionMissing path i)`。

  第三種**不是** `Right False`:與同一模組、同一份 spec 的 `headingDepthFor` 對稱(LAW-21 明訂
  父節點不存在時回 `Left (SectionMissing _ p)`)。「查無此節」與「這個節不是根」是**兩件不同
  的事**,合一會讓呼叫端分不出來——`deleteNode` 會把一個根本不存在的 id 當成「可以刪的非根
  節點」繼續往下走,錯誤就往下游飄,直到某個更遠的地方才以另一種面貌爆開。
  三種結果各一個具體例子見 **EX-18**。
- **LAW-25(`createPackFile` 的 pack 專屬欄位往返)**(2026-08-25 GAP-17 裁決補入,**現在會紅**,
  見下方「阻塞:LAW-25 依賴 F004 的檔案層 extras」):對所有 `NewPack np` 與所有 `[NewSection] xs`,
  `createPackFile vh np xs` 成功之後,重讀 `crPath` 這個檔案並 `parseDocument` + `toPack`,
  解出的 `Pack p` 在**七個 pack 專屬欄位**上逐欄等於傳進去的 `np`:

  | `Pack` 的欄位 | 等於 `NewPack` 的 |
  |---|---|
  | `pckVendor p` | `npVendor np` |
  | `pckArchive p` | `npArchive np` |
  | `pckSha256 p` | `npSha256 np` |
  | `pckLicense p` | `npLicense np` |
  | `pckAuthor p` | `npAuthor np` |
  | `pckSourceUrl p` | `npSourceUrl np` |
  | `pckAiDisclosure p` | `npAiDisclosure np` |

  七欄**逐欄相等**,包含 `Nothing` 的情形(`npVendor == Nothing` 時 `pckVendor` 也必須是
  `Nothing`),所以七欄全給 `Nothing` / `AiUnknown` 的輸入**不足以**驗證這條 law:qa 要用
  **七欄都給非預設值**的 `NewPack` 當主要案例(見 **EX-22**),否則斷言恆真。
  **這條 law 為什麼非有不可**:GAP-17 之所以能潛伏到 impl 階段才被人讀出來(`createPackFile`
  一個 pack 專屬欄位都沒寫進檔案,重讀後全部變 `Nothing` / `AiUnknown`),唯一的原因就是
  **沒有任何斷言在看這件事**——EX-3 只驗 `crPath` 與 asset 節順序,測試套件因此全線是綠的,
  而磁碟上的 `pack.md` 已經在遺失資料。依 ADR-013,`pack.md` 是素材中繼資料的**真相**,
  這條往返不能只靠「實作記得寫」。
- **L-**:`(>>?)` / `(?>>)` 無獨立 law:它們是 `Either` 的短路組合子,性質等同 `Either` 的
  monad 律,而「失敗就不繼續」這件事已由 LAW-1 與 LAW-16 的「檔案不變」觀察到。
- **L-**:`orMd` / `vaultAbsPath` / `ensureDir` / `readDocument` / `locate` / `dropFile` 無獨立
  law:它們是純粹的包裝與定位,沒有任何從公開介面觀察得到、而不被 LAW-10 / LAW-13 / LAW-16 覆蓋的行為。

### `SqliteError` 的訊息要改(2026-08-25 GAP-7 裁決)

**這是 impl 這一輪要改的一則既有訊息**,不是新增分支。`Aapms.Store.Error.renderStoreError`
對 `SqliteError` 的 F005 既有實作是:

```haskell
SqliteError msg ->
  "索引操作失敗 —— " <> msg <> ";可以嘗試重新開啟 vault"
```

「可以嘗試」不是以「請」起頭的子句,與 LAW-15 字面不符。裁決是**改訊息、不放寬 LAW-15**。新原文:

```haskell
SqliteError msg ->
  "索引操作失敗 —— " <> msg <> ";請嘗試重新開啟 vault"
```

理由:21 則訊息只有**一種形狀**,新建構子一律照辦,LAW-15 這條機械斷言才維持銳利。放寬成
「請 / 改用 / 可以 / 才」四選一的話,日後新加的訊息只要沒講下一步、但戴一個「可以」就混得
過去——那條 law 就從「每一則都說出下一步」退化成「每一則都戴了某個副詞」。

**impl 這一輪對 `Error.hs` 的授權範圍**(超出即偏離):

- **要做**:填 `renderStoreError` 的 **15 個 `undefined` 分支**(`NodeNotFound` …
  `NodeDepthExceeded`);
- **要做**:把 `SqliteError` 這一則既有訊息改成上面的新原文;
- **不得做**:F005 其餘 **5 則**既有訊息(`VaultMarkerMissing` / `VaultMarkerInvalid` /
  `VaultAlreadyInitialized` / `FileReadFailed` / `FileWriteFailed`)**一個字都不得更動**
  ——它們是 F005 的回歸基準,EX-16 與 `Aapms.Store.ErrorSpec` 兩邊都在看。

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| EX-1 | 註冊表中 `character` 的 `dir = "characters"`;`createTopicFile vh reg (NewEntity{neType="character", neTitle="琳達", nePath=Nothing, …})` | `Right CreateResult{crPath = "characters/琳達.md", crRevision = Revision 1}`,檔案存在且 `toTopic` 解得 `metaTitle == "琳達"` | 正常路徑;中文檔名;註冊表落點 |
| EX-2 | `createLevelFile vh reg (NewLevel{nlTitle="第一章", nlRootTitle="序幕", nlRootKind=…, nlPath=Nothing})` | `Right CreateResult{crPath = "levels/第一章.md"}`;`toLevel` 回一個 `Level` 與恰好一個 `Node`,`lvlRoot == metaId(該 Node)`,根節點標題層級為 2 | Level 檔一定要有根 Node |
| EX-3 | `createPackFile vh pack [sA, sB, sC]`(三筆 `NSAsset`,`nsId` 分別 `ast-0000000a/b/c`) | `Right CreateResult{crPath = "<npDir>/pack.md"}`;`toPack` 回的 asset 順序為 `a, b, c` | 節順序 = 給定順序 |
| EX-4 | 既有 asset `ast-1` 的 `sha256 = "aa…"`;`writeAssetFields vh ast-1 r (AssetPatch{apName = Just (Just n'), apLicense = Nothing, apAuthor = Just Nothing, apTags = Nothing})` | `Right WriteResult{…}`;重讀後 `astName == Just n'`、`astAuthor == Nothing`、`astSha256 == "aa…"` 未變、`astLicense` 未變 | 三態語意 + 唯讀欄位 |
| EX-5 | 檔案裡 `revision: 3`;`writeMeta vh i (Revision 2) f` | `Left (RevisionMismatch i (Revision 2) (Revision 3))`,檔案位元組與呼叫前逐字相同 | 樂觀鎖失敗路徑 |
| EX-6 | 固定 `t = UTCTime (fromGregorian 2026 8 25) 0`、`p = PEnt`、`c = "琳達"`;先把 `Aapms.Core.Id.newId p c t 0` 與 `newId p c t 1` 兩個 id **用同一個 `t`** 算出來寫進索引的 `nodes` 表;然後 `allocateId vh p c t` | `Right (newId p c t 2)` ——**恰好等於** salt = 2 的那一個,且與預先插入的兩個都不同 | 人為製造碰撞;salt 遞增迴圈的唯一入口(2026-08-25 GAP-8 裁決後可精確重現) |
| EX-7 | 節點 `i` 的 `links` 不含 `l`;`removeLink vh i r l` | `Left (LinkNotFound i l)`,檔案位元組不變 | 刪不存在的關聯 |
| EX-8 | Level 檔的根 Node `nod-root`;`deleteNode vh nod-root r DeleteForce` | `Left (CannotDeleteRootNode nod-root)`,檔案不變 | 根節點刪不得;`DeleteForce` 也擋 |
| EX-9 | `pack.md` 裡有 `sha256` / `entry` 的 asset 節;`writeBody vh ast-1 r "新的說明"` | `Right`;重讀後該 asset 的 `astBody == "新的說明"`,`astSha256` / `astEntry` 仍在且未變,其他節位元組不變 | 改正文不得吃掉 payload 欄位 |
| EX-10 | 目標檔是 `pack.md`(`PackDoc`);`addSection vh pck-1 AtEnd s`,其中 `nsPayload = NSFragment ov` | `Left (BadSectionPayload (nsId s) PackDoc)`,檔案不變 | payload 與文件種類不符;`AtEnd` 也擋 |
| EX-11 | `sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91"` | `"第一章- 序幕"`(冒號換 `-`、去尾端空白) | 檔名淨化;非 ASCII 保留 |
| EX-12 | Level 檔:`## 序幕`(`nod-root`)、`### 開場`(`nod-a`)、`### 收束`(`nod-b`);`addSection vh lvl-1 (UnderParent nod-a) s`,其中 `nsPayload = NSNode ov (NewNode KScene)`、`nsLevel = 2`(故意給錯) | `Right CreateResult{crId = nsId s}`;重讀後新節的標題是 `#### …`(**4 級,由 `secLevel nod-a + 1` 推導,不是呼叫端給的 2**),文件順序為 `序幕 / 開場 / 新節 / 收束`,`nodParent` 該新節 `== nod-a`,`nod-b` 那一節的位元組未變(它在插入點**之後**,不受 L12b 的行尾但書影響);`nod-a` 的正文若在 fixture 裡**已經**以空行結尾,它也逐位元組不變 | `UnderParent` 正常路徑;`nsLevel` 由 store 推導;插入點之後不動,插入點之前只可能補行尾 |
| EX-13 | 同上的 Level 檔;`addSection vh lvl-1 (UnderParent nod-zzz) s`(`nod-zzz` 不在檔案裡) | `Left (SectionMissing "levels/第一章.md" nod-zzz)`,檔案位元組不變 | `UnderParent` 的父節點不存在 |
| EX-14 | Level 檔裡 `nod-deep` 的標題是 `###### 最深`(6 級);`addSection vh lvl-1 (UnderParent nod-deep) s` | `Left (NodeDepthExceeded nod-deep 7)`,檔案位元組不變 | Markdown 只有六級標題 |
| EX-15 | 索引的 `nodes` 表被 `DROP` 掉;`allocateId vh PEnt "琳達" t`(`t` 任意固定值) | `Left (SqliteError _)`,**不是 `Right`** | 碰撞查詢失敗即失敗,不靜默照發 |
| EX-16 | `renderStoreError (VaultMarkerMissing "/tmp/v")`(F005 的既有建構子) | 非空,且含以「請」起頭的子句 | LAW-15 的範圍含 F005 原有的 6 個建構子(骨架已實作,應為綠) |
| EX-17 | `renderStoreError (SqliteError "no such table: nodes")` | `"索引操作失敗 —— no such table: nodes;請嘗試重新開啟 vault"` ——**逐字**,含以「請」起頭的子句 | GAP-7 裁決:這是 impl 這一輪**要改的一則既有訊息**;改之前這條是紅的,改完轉綠 |
| EX-18 | Level 檔:`## 序幕`(`nod-root`,frontmatter 的 `root`)、`### 開場`(`nod-a`);依序 `isRootNode "levels/第一章.md" doc nod-root`、`… doc nod-a`、`… doc nod-zzz`(不在檔案裡) | 依序 `Right True`、`Right False`、`Left (SectionMissing "levels/第一章.md" nod-zzz)` | LAW-24 的三種結果各一;第三種**不是** `Right False`(與 `headingDepthFor` 對稱) |
| EX-19 | `sanitizeFileName "   " "ent-7f3b2a91"`;以及 `sanitizeFileName "..." "ent-7f3b2a91"` | 兩者皆為 `"ent-7f3b2a91"` | LAW-20 第 2 條:**只有**「每個字元都是空白或 `.`」才算被清空 → 退回 `fb` |
| EX-20 | `sanitizeFileName "<" "ent-7f3b2a91"`;以及 `sanitizeFileName "<>?" "ent-7f3b2a91"` | 依序 `"-"`、`"---"` ——**不是** `"ent-7f3b2a91"` | LAW-20 第 3 條:非法字元是**替換**成 `-`,替換後非空就不退回 `fb`(GAP-13 裁決的分岔點) |
| EX-21 | `sanitizeFileName "琳達 的筆記" "ent-7f3b2a91"` | `"琳達 的筆記"`(逐字不變,含中間那個空白) | LAW-20 第 4 條:只含合法字元、無頭尾空白與 `.` 時原樣回傳;中文與詞中空白都保留 |
| EX-22 | `createPackFile vh np [sA]`,其中 `np` 的七個 pack 專屬欄位**全給非預設值**:`npVendor = Just "Kenney"`、`npArchive = Just "packs/kenney-ui.zip"`、`npSha256 = Just (Sha256 "aa11…")`、`npLicense = Just (localRef lic-0000000a)`、`npAuthor = Just (Author "Kenney" (Just "https://kenney.nl") Nothing)`、`npSourceUrl = Just "https://kenney.nl/assets/ui-pack"`、`npAiDisclosure = AiNone` | `Right CreateResult{crPath = "<npDir>/pack.md"}`;重讀該檔 `toPack` 之後,`pckVendor` / `pckArchive` / `pckSha256` / `pckLicense` / `pckAuthor` / `pckSourceUrl` / `pckAiDisclosure` **七欄逐欄等於**上面給的值 | LAW-25 的具體案例。**這一條現在是紅的**,而且會一直紅到 F004 的檔案層 extras 落地為止(見「阻塞」)——紅燈就是它的工作 |

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
| `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/Aapms/Store/Error.hs:180` | F005 | 定位查詢與配號查詢的 SQLite 邊界;`allocateId` 的失敗通道就是它回的 `SqliteError` |
| `indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])` | `store/src/Aapms/Store/Index.hs:148` | F006 | 寫檔之後只重讀該檔 |
| `unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | `store/src/Aapms/Store/Index.hs:155` | F006 | 刪整份檔案時清索引 |
| `data IndexIssue` | `store/src/Aapms/Store/Schema.hs:85` | F006 | `WriteResult` / `CreateResult` 的附帶回報 |
| `linksTo :: VaultHandle -> Ref -> IO [(Meta, Link)]` | `store/src/Aapms/Store/Query.hs:454` | F006 | `deleteNode` 的被引用檢查 |
| `parseDocument :: Text -> Either MdError Document` | `md/src/Aapms/Md/Parse.hs:52` | F004 | 重讀後切塊 |
| `toTopic :: Document -> Either MdError (Entity, [Entity])` | `md/src/Aapms/Md/Parse.hs:124` | F004 | 取得主題檔目前的 `Meta`(比對 revision)與寫檔前的自我驗證 |
| `toLevel :: Document -> Either MdError (Level, [Node])` | `md/src/Aapms/Md/Parse.hs:140` | F004 | Level 檔同上;`validateLevelDoc` 的第一段(**2026-08-25 補登**:`Aapms.Store.Node` 因此直接 import `Aapms.Md.Parse`,只用 `toLevel`——見「新增的依賴邊」④) |
| `toPack :: Document -> Either MdError (Pack, [Asset])` | `md/src/Aapms/Md/Parse.hs:224` | F004 | `pack.md` 同上;`writeAssetFields` 讀出目前的 asset 欄位 |
| `toLicenses :: Document -> Either MdError [License]` | `md/src/Aapms/Md/Parse.hs:279` | F004 | `licenses.md` 同上;`upsertLicense` 判斷該 id 是否已存在 |
| `renderDocument :: Document -> Text` | `md/src/Aapms/Md/Render.hs:90` | F004 | 位元組保留的重組 |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:106` | F004 | 節層 meta 改寫(**GAP-2 重跑後型別專屬條目原封不動**) |
| `overrideAt :: Id -> Document -> Either MdError MetaOverride` | `md/src/Aapms/Md/Render.hs:123` | F004 | 先看目前值再決定要不要改(`removeLink` 沒命中要中止) |
| `newtype MetaExtras` / `extrasOf :: Section -> MetaExtras` / `extrasAt :: Id -> Document -> Either MdError MetaExtras` / `mergeExtras` | `md/src/Aapms/Md/Render.hs:163` / `:173` / `:202` / `:212` | F004(GAP-2) | 節層 meta 區塊的另一半:型別專屬條目以原始行保存 |
| `updateSectionExtras :: Id -> (MetaExtras -> MetaExtras) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:225` | F004(GAP-2) | `writeAssetFields` / `upsertLicense` 改 `sha256` 以外的專屬欄位唯一走得通的路 |
| `payloadOverride :: NewSectionPayload -> MetaOverride` / `payloadExtras :: NewSectionPayload -> MetaExtras` | `md/src/Aapms/Md/Render.hs:344` / `:363` | F004(GAP-2) | 把一個 payload 拆成 meta 區塊的兩半 |
| `renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text` | `md/src/Aapms/Md/Render.hs:714` | F004(GAP-2) | 兩半都要,少一半在型別上就寫不出來 |
| `updateSectionBody :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:491` | F004 | 節層換正文 |
| `renameSection :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:514` | F004 | 節層換標題 |
| `replacePreamble :: Text -> Document -> Document` | `md/src/Aapms/Md/Render.hs:537` | F004 | 檔案層主體換正文 |
| `removeSection :: Id -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:481` | F004 | 刪一節 / 刪子樹 |
| `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:586` | F004 | 檔案層 meta 與 revision 遞增 |
| `newDocument :: DocKind -> Meta -> Text -> Document` | `md/src/Aapms/Md/Render.hs:608` | F004 | 從零建一份新檔 |
| `appendSection :: NewSection -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:414` | F004 | `addSection AtEnd` / `createPackFile` 的追加一節 |
| `insertSection :: Id -> NewSection -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:477` | F004 | `addSection (UnderParent p)`:插在 `p` 的子樹之後;`nsLevel` 必須等於 `secLevel p + 1`(由 `headingDepthFor` 算好再交給它) |
| `data NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` | `md/src/Aapms/Md/Render.hs:238` / `:256` / `:272` / `:289` / `:306` | F004(GAP-1) | 一個新節的形狀;`Aapms.Store.Create` 只 re-export |
| `data MetaOverride` | `md/src/Aapms/Md/Inherit.hs:45` | F004 | 節層覆寫 DTO,md 與 store 共用 |
| `overrideOf :: Meta -> MetaOverride` / `applyOverride :: MetaOverride -> Meta -> Meta` | `md/src/Aapms/Md/Inherit.hs:107` / `:130` | F004 | 檔案層主體與節共用同一個修改函式 |
| `data Document`(欄位 `docFrontRaw` / `docPreamble` / `docSections` / `docEnding` / `docFinalNL` / `docKind`)、`data Section`、`sectionById :: Id -> Document -> Maybe Section` | `md/src/Aapms/Md/Document.hs:71` / `:88` / `:106` | F004 | 子樹推導與位元組保留的觀察點 |
| `data MdError = MdError { errLine :: Int, errKind :: MdErrorKind }` | `md/src/Aapms/Md/Error.hs:22` | F004 | 包進 `MdWriteFailed` |
| `newId :: IdPrefix -> Text -> UTCTime -> Int -> Id` | `core/src/Aapms/Core/Id.hs:103` | F001 | `allocateId` 的純函式核心;salt 由本層遞增,**`UTCTime` 由 `allocateId` 的呼叫端一路傳進來**(GAP-8 裁決後 `allocateId` 也是明碼時間) |
| `parseId :: Text -> Either IdError (IdPrefix, Id)` / `renderId :: Id -> Text` | `core/src/Aapms/Core/Id.hs:127` / `:123` | F001 | 索引列與 id 之間的轉換 |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }` / `localRef :: Id -> Ref` | `core/src/Aapms/Core/Id.hs:156` / `:163` | F001 | 被引用檢查的查詢鍵 |
| `buildTree :: Level -> [Node] -> Either [TreeError] NodeTree` | `core/src/Aapms/Core/Tree.hs:86` | F001 | `validateLevelDoc` 的第二段(**2026-08-25 補登**:`Aapms.Store.Node` 因此直接 import `Aapms.Core.Tree`,只用 `buildTree`——見「新增的依賴邊」④) |
| `bumpRevision :: Day -> Meta -> Meta` | `core/src/Aapms/Core/Meta.hs:165` | F001 | 全系統唯一的 revision 遞增點 |
| `idPrefix :: Id -> IdPrefix` | `core/src/Aapms/Core/Id.hs:139` | F001 | `allocateId` 的回傳驗證(LAW-14) |
| `data Meta`(14 欄)、`newtype Revision = Revision Int`、`data Status` / `Source` / `Timeline`、`newtype TypeKey = TypeKey Text` | `core/src/Aapms/Core/Meta.hs:123` / `:50` / `:57` / `:80` / `:112` / `:45` | F001 | 寫入 DTO 的欄位型別 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }`(derives `Eq`) | `core/src/Aapms/Core/Link.hs:53` | F001 | `addLink` / `removeLink` 的比對單位 |
| `data TreeError`(7 建構子) | `core/src/Aapms/Core/Tree.hs:40` | F001 | 包進 `TreeInvalidOnWrite` |
| `data Asset`(9 欄)、`newtype Sha256 = Sha256 Text`、`newtype LogicalName = LogicalName Text` | `core/src/Aapms/Core/Asset.hs:35` / `:18` / `:26` | F001 | `NewAsset` / `AssetPatch` 的欄位型別;LAW-4 / LAW-5 的觀察點 |
| `data Pack`、`data Author`、`data AiDisclosure` | `core/src/Aapms/Core/Pack.hs:36` / `:27` / `:19` | F001 | `NewPack` 的欄位型別 |
| `data License`(八個授權維度 + `licFullText`) | `core/src/Aapms/Core/License.hs:13` | F001 | `upsertLicense` 的輸入 |
| `data NodeKind` | `core/src/Aapms/Core/Level.hs:27` | F001 | `NewNode` / `NewLevel` 的欄位型別 |
| `data TypeRegistry`、`lookupDir :: TypeRegistry -> TypeKey -> Maybe FilePath` | `core/src/Aapms/Core/Registry.hs:167` | F002 | 建檔落點 |
| `sectionIds :: Document -> [Id]` | `md/src/Aapms/Md/Document.hs:111` | F004 | **2026-08-25 補登**(見「新增的依賴邊」④):`deleteNode` 對**檔案層主體**的目標要取「檔內全部節點 id」當 `victims`(LAW-13),這是唯一的管道;`Aapms.Store.Create` 因此 import `Aapms.Md.Document` |
| `data Entity`(`entMeta :: Meta`) | `core/src/Aapms/Core/Entity.hs:12` / `:13` | F001 | **2026-08-25 補登**:從重讀的檔案取出目標**目前真正的 `Meta`**(不可逆決定 2)——`toTopic` 回的是 `Entity`,要拿 `Meta` 就得拆它。集中在 `Aapms.Store.Edit.currentMetaAt` |
| `data Level`(`lvlMeta :: Meta`)、`data Node`(`nodMeta :: Meta`) | `core/src/Aapms/Core/Level.hs:19` / `:20` / `:54` / `:55` | F001 | **2026-08-25 補登**:同上,`toLevel` 回的 `(Level, [Node])` 的 `Meta` 出口 |
| `pckMeta :: Pack -> Meta`(`data Pack` 的欄位) | `core/src/Aapms/Core/Pack.hs:36` | F001 | **2026-08-25 補登**:同上,`toPack` 回的 `Pack` 的 `Meta` 出口 |
| `astMeta :: Asset -> Meta`(`data Asset` 的欄位) | `core/src/Aapms/Core/Asset.hs:36` | F001 | **2026-08-25 補登**:同上,asset 節的 `Meta` 出口;`Aapms.Store.Edit.currentAssetAt` 另外要整個 `Asset`(LAW-4 / LAW-5 的唯讀欄位比對) |
| `licMeta :: License -> Meta`(`data License` 的欄位) | `core/src/Aapms/Core/License.hs:14` | F001 | **2026-08-25 補登**:同上;`upsertLicense` 的樂觀鎖比對值也取自它(不可逆決定 5) |

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
    `Aapms.Store.{Edit,Error,Marker}`、**`Data.Time`**(`UTCTime`,GAP-8 之後 `allocateId` 的簽名
    就用得到,不再是只有本體用得到)
  - `Aapms.Store.Node` → `Aapms.Core.Id`、`Aapms.Md.Document`、`Aapms.Store.Error`
    (不再需要 `Aapms.Store.Edit`——錯誤型別搬走之後它只剩純推導)
  - `Aapms.Store.Create` → `Aapms.Core.{Asset,Id,Level,Link,Meta,Pack,Registry}`、
    **`Aapms.Md.Render`**(re-export `NewSection` 家族)、`Aapms.Store.{Error,Marker,Schema}`
  - `Aapms.Store`(門面)→ `Aapms.Store.{Create,Write}`
  - 實作階段還會新增(骨架未 import,因為只有本體用得到):
    `Aapms.Store.Edit` → `Aapms.Store.{Atomic,Index}`、`Aapms.Md.{Parse,Render}`、
    `Database.SQLite.Simple`;`Aapms.Store.Create` → `Aapms.Store.{Edit,Node,Write,Query}`、
    `Aapms.Md.{Parse,Render}`、`System.Directory`、`System.FilePath`;
    `Aapms.Store.Write` → `Aapms.Store.Edit`(已有)、`Aapms.Md.{Parse,Render}`;
    `Aapms.Store.Create` 另需 `Data.Time`(四個 create 函式自己取 `getCurrentTime` 再傳給
    `allocateId`)
  - ④ **impl 實際補上、上面兩份清單漏列的邊**(2026-08-25 登記,逐條已對原始碼的 import
    行覆核;每一條的簽名與用途見上方「使用到的既有介面」表對應列)。**都在
    `aapms-store` 對 `aapms-core` / `aapms-md` 既有 `build-depends` 之內,不新增套件層的邊;
    被 import 的模組沒有一個 import 任何 `Aapms.Store.*`,不成環**:

    | 模組 | 補上的 import | 為什麼非它不可 |
    |---|---|---|
    | `Aapms.Store.Node` | `Aapms.Md.Parse`(只用 `toLevel`)、`Aapms.Core.Tree`(只用 `buildTree`) | **LAW-23 就是拿這兩個函式定義 `validateLevelDoc`** 的(「`toLevel` 成功且 `buildTree` 回 `Right`」)。只用原本授權的三個依賴,就只能在 `Node.hs` 自己重寫一份等價的樹驗證——違反「序列化規則只有一份」與「父子關係只有一個推導點」 |
    | `Aapms.Store.Edit` | `Aapms.Core.{Asset,Entity,Level,License,Pack}`、`Aapms.Md.Parse` | 不可逆決定 2 要求樂觀鎖比對的 `Meta` 取自**重讀的檔案**,唯一管道是 `toTopic` / `toLevel` / `toPack` / `toLicenses`,而拆出它們回傳值裡的 `Meta` 需要那五個 core 模組。這段邏輯集中在 `Edit` 的 `currentMetaAt` / `currentAssetAt`(`Edit.hs:271` / `:294`),`Write` 與 `Create` 共用,不寫兩份——與 `Edit.hs` 本來的定位「所有寫入路徑共用的那一條紀律」一致 |
    | `Aapms.Store.Create` | `Aapms.Md.Document`(`Document` / `DocKind` / `sectionIds`) | `deleteNode` 的目標是**檔案層主體**時,`victims` 是「檔內全部節點 id」(LAW-13),`sectionIds` 是唯一的管道 |

    另有兩條純屬同一批 import 的細項,一併登記:`Aapms.Store.Write` →
    `Aapms.Md.Document`(`DocKind` / `Document`)、`Aapms.Store.Create` →
    `Aapms.Md.Inherit`(`emptyOverride`)與 `System.Directory`(`doesFileExist`,
    推導路徑撞名時遞增)。

    **待編排者回寫 `design.md`**:上表三列正是 GAP-15 / GAP-16 要求補進 design.md「新增的依賴邊」
    的內容。委派模式下本角色不得寫 `design.md`,所以只登記在這裡;**GAP-15 / GAP-16 兩條 gap 的
    狀態行也不由本輪回填**。
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

2026-08-24 骨架留下的 ASM-1–ASM-6 六條全數結案,結論如下;**契約已由編排者回寫進 design.md,
契約是唯一真相**。

| # | 原假設 | 裁決 | 落點 |
|---|---|---|---|
| ASM-1 | `createPackFile` 第三參數改 `[NewSection]`(偏離當時的契約 E) | **接受**,回寫契約 E | `design.md:317`;`Create.hs:369` |
| ASM-2 | 在 `Aapms.Store.Edit` 定義暫居的 `StoreWriteError`,以 `WriteStore` 為橋 | **推翻**:15 個建構子併進 `StoreError`,刪 `WriteStore` 與 `renderStoreWriteError` | 見「不可逆決定 8」;`Error.hs:29` / `:80` |
| ASM-3 | `allocateId :: … -> IO Id`,查詢失敗視同查不到 | **推翻**:改 `IO (Either StoreError Id)`,查詢失敗即失敗 | 見「不可逆決定 6」;`Write.hs:423` |
| ASM-4 | `NewSection` 家族暫居 `Aapms.Store.Create` | **推翻**:F004 GAP-2 重跑已把它們放進 `Aapms.Md.Render`,store 改成 re-export | `Create.hs` 匯出清單;`md/src/Aapms/Md/Render.hs:238` 起 |
| ASM-5 | `addSection` 只能追加檔尾,`nsLevel` 由呼叫端給 | **推翻**:加 `SectionPlacement`;`UnderParent` 時 `nsLevel` 由 `headingDepthFor` 推導 | 見「不可逆決定 7」;`Create.hs:227` / `:437` |
| ASM-6 | 門面不 re-export 本 feature 的模組 | **補上**:`Aapms.Store` re-export `Create` 與 `Write`(`Edit` / `Node` 仍為內部模組) | `store/src/Aapms/Store.hs:32` / `:38` |

本次修訂**沒有新的待確認假設**。

## 已裁決的 spec-gaps(2026-08-25)

qa 交付 F008 測試時開的四條 gap(`spec-gaps.md` 的 GAP-7 / GAP-8 / GAP-9 / GAP-12)與 impl 交付時開的
三條(GAP-13 / GAP-14 / GAP-17)全數結案,本次修訂就是把裁決落實進 spec。
GAP-15 / GAP-16(依賴邊漏列)由編排者另行處置,本次只把 impl 實際補上的 import 登記進「依賴」段。

| # | gap | 裁決 | 落點 |
|---|---|---|---|
| GAP-13 | LAW-20 的「`t` 被清空時結果等於 `fb`」與 EX-11 的逐字例子(冒號**替換**成 `-`)對「只含非法字元的輸入」給出不同答案 | **保留替換策略與 EX-11 的逐字例子**(逐字例子是最難被誤讀的 spec),**改 LAW-20 的措辭**:「被清空」只指「去掉頭尾空白與 `.` 之後為空」,不含「輸入只由非法字元組成」。`"<"` 的正確結果是 `"-"`,`"   "` 才是 `fb` | **LAW-20 改寫**(四條子句,附機械定義);**新增 EX-19 / EX-20 / EX-21** |
| GAP-14 | L12a / L12b 的「位元組不變」是無條件全稱,但 `appendSection` / `insertSection` 的 `blankTail` 會補插入點前一段的行尾 | **照 F004 的 ASM-10 收窄措辭改**:唯一的例外是插入點之前那一段的行尾,還沒以空行結尾時會被補齊(`blankTail` 冪等);被動到的是插入點而不是「未經修改的區塊」,不違反 ADR-010 | **L12a / L12b 改寫** + 新增「插入點行尾的但書」;EX-12 補註 |
| GAP-17 | `createPackFile` 把 `NewPack` 的七個 pack 專屬欄位一個都沒寫進檔案,重讀後全解成 `Nothing` / `AiUnknown`,而**測試套件全綠**(沒有任何斷言在看) | **重新打開 F004**,替 `aapms-md` 補檔案層 extras 寫入管道(對稱節層的 `MetaExtras`),F008 的 `createPackFile` 接上它 | **新增 LAW-25**;**新增 EX-22**;「阻塞:LAW-25 依賴 F004 的檔案層 extras」 |
| GAP-7 | `SqliteError` 的既有訊息不含以「請」起頭的子句,與 LAW-15 字面不符 | **不放寬 LAW-15,改訊息**;由 impl 這一輪改掉,F005 其餘 5 則不得更動 | LAW-15;「`SqliteError` 的訊息要改」;EX-17 |
| GAP-8 | `allocateId` 沒有時間注入點,EX-6「人為製造碰撞」無法從公開介面重現 | **時間改成明碼參數**(契約 E 已回寫,`design.md:326`);四個 create 函式的對外簽名不變 | 介面表 `allocateId`;LAW-14 收緊;L14b;EX-6;EX-15;`Write.hs:423` |
| GAP-9 | `isRootNode` 對「id 不在文件裡」沒有任何 law 定義行為 | **回 `Left (SectionMissing path id)`**,與 `headingDepthFor`(LAW-21)對稱 | **新增 LAW-24**;**新增 EX-18**;`Node.hs:81` 的 haddock |
| GAP-12 | LAW-17 第三個子句(檔案 IO / md 序列化不在 SQLite 呼叫的括號內)不是機械可判定 | **從 law 移除**,降級為 `/arch-audit subsys graph-core` 的人工檢查項 | LAW-17 只剩兩個子句;「實作備註」的 arch-audit 檢查項 |

## 骨架

| 檔案 | 內容 |
|---|---|
| `store/src/Aapms/Store/Error.hs` | `StoreError` **+15 建構子**(`NodeNotFound` … `NodeDepthExceeded`);`renderStoreError` 的 15 個新分支為 `undefined`,F005 原有的 6 個維持已實作。**impl 這一輪除了填那 15 個分支,還要改 `SqliteError` 這一則既有訊息**(GAP-7 裁決,原文見 Laws 之後的「`SqliteError` 的訊息要改」),其餘 5 則不得更動 |
| `store/src/Aapms/Store/Edit.hs` | `WriteResult`、`Located`、`(>>?)` / `(?>>)`、`locate` / `readDocument` / `orMd` / `checkRevision` / `commit` / `dropFile` / `ensureDir` / `vaultAbsPath` / `sectionBodyRaw`(**不再定義錯誤型別**) |
| `store/src/Aapms/Store/Write.hs` | `AssetPatch`;re-export `WriteResult`;`writeMeta` / `writeAssetFields` / `writeBody` / `addLink` / `removeLink` / `upsertLicense` / `allocateId` |
| `store/src/Aapms/Store/Node.hs` | `headingDepthFor` / `subtreeAfter` / `subtreeIds` / `isRootNode` / `validateLevelDoc`(全部純函式) |
| `store/src/Aapms/Store/Create.hs` | `NewEntity` / `NewLevel` / `NewPack` / `SectionPlacement` / `CreateResult` / `DeleteMode` / `DeleteResult`;**re-export** `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode`(定義在 `Aapms.Md.Render`);`createTopicFile` / `createLevelFile` / `createPackFile` / `addSection` / `deleteNode` / `sanitizeFileName` |
| `store/src/Aapms/Store.hs` | 門面 re-export `Aapms.Store.Create` 與 `Aapms.Store.Write` |

本 feature 的所有函數本體皆為 `undefined`(`renderStoreError` 只有本 feature 新增的 15 個
分支是 `undefined`,F005 的 6 個是既有實作,只有 `SqliteError` 那一則要由 impl 依 GAP-7 裁決改
文字)。型別檢查方式與結果見回報。

## 實作備註

### 阻塞:LAW-25 / EX-22 依賴 F004 的檔案層 extras(2026-08-25 GAP-17 裁決)

**這一條現在會紅,而且應該紅到 F004 那一半落地為止。** 不要把它寫弱、標成 pending、
或在 impl 那一輪為了轉綠而繞路——紅燈就是這條 law 的工作。

- **缺什麼**:`Aapms.Md.Render` 對外的 frontmatter 寫入介面(`newDocument` /
  `updateFrontmatter` 與 `frontmatterFieldOrder`)只吃 `Meta` 的 14 個欄位,**檔案層沒有
  節層 `MetaExtras` 的對應物**;而 `Aapms.Core.Json` 的 `FromJSON Pack` 把 `vendor` /
  `archive` / `sha256` / `license` / `author` / `source_url` / `ai_disclosure` 與 `Meta`
  **攤平在同一層** frontmatter 解碼。所以 `createPackFile` 現在沒有任何管道把
  `NewPack` 的七個專屬欄位寫進檔案。
- **裁決**(2026-08-25 開發者):**重新打開 F004**,替 `aapms-md` 補上**檔案層 extras** 的
  寫入管道(對稱節層的 `MetaExtras` / `payloadExtras` / `mergeExtras`);`createPackFile` 接上它。
  **修法不在 F008 的授權範圍內**:`md/` 由 F004 那一輪改,本文件**不假設**它最後的簽名長什麼樣。
- **對三個角色的指示**:
  - **qa**:照 LAW-25 / EX-22 寫斷言,**不因為現在做不到就放寬**。它現在紅、F004 落地前一直紅;
    這正是 GAP-17 潛伏那麼久的原因的反面。
  - **impl**:`createPackFile` 在 F004 的檔案層 extras 介面出現之前**完成不了**——不要用
    「先寫 `Meta`、事後再補一次 `updateFrontmatter`」之類的繞路把它弄綠(那條路一樣寫不進
    `Meta` 以外的欄位),也不要自己在 store 這一側手拼 frontmatter YAML(違反「序列化規則
    只有一份」的知識歸屬)。停在這一項,其餘照做完。
  - **編排者**:F004 交付檔案層 extras 之後,**再委派一輪 F008 impl** 接上它;在那之前
    LAW-25 / EX-22 的紅燈是**預期的**,不進仲裁迴圈的三輪上限,也不得歸因成 impl 錯或 qa 誤讀。

### arch-audit 的人工檢查項:寫鎖預算的巢狀約束(2026-08-25 GAP-12 裁決)

LAW-17 原本的**第三個子句**已從 law 移除,改列在這裡,由
**`/arch-audit subsys graph-core` 在階段閘門人工檢查**(不是 qa 的自動化測試)。

**要檢查什麼**——在 `Aapms.Store.{Edit,Write,Node,Create}` 四個檔案裡:

1. 所有**檔案 IO**(`readTextFile` / `atomicWriteText` / `removeFile` /
   `createDirectoryIfMissing`,含它們的間接呼叫者)**不得**出現在任何 SQLite 呼叫
   (`query` / `query_` / `execute` / `execute_` / `withTransaction` / `trySqlite` 包住的區塊)
   的動態範圍內;
2. 所有 **md 序列化**(`renderDocument` / `renderSection` / `renderMetaBlock` / `appendSection` /
   `insertSection` / `updateSection*` / `updateFrontmatter` …)同樣不得落在 SQLite 呼叫的
   動態範圍內;
3. 判準是**動態範圍**而不是「同一行」:經一層 helper 函式間接呼叫也算違規,所以要看的是
   呼叫圖,不是字面位置。可行的看法:沿 `Aapms.Store.Edit.commit` 與
   `Aapms.Store.Write.allocateId` 這兩條唯一碰 SQLite 的路徑往下讀,確認 `trySqlite` 的
   lambda 裡只有 SQL,沒有讀寫檔、沒有 render。

**為什麼靠人看**:ADR-022 原文把 **code review 與靜態檢測並列**,沒有要求後者涵蓋全部;
而「X 是否巢狀在 Y 的括號內」是語法樹層級的問題,文字掃描在真實的多行 `do` / `let` / 縮排
排版下會同時製造偽陽性與偽陰性。與其留一條驗不準的 law 讓人以為有把關(F007 的 GAP-3 已經
示範過那種假把關的代價),不如明說它靠人看。LAW-17 保留的兩個子句仍然是機械可判定的,
由 qa 的 `WriteLockBudgetSpec` 覆蓋。
