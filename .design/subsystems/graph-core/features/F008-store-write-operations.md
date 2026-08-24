---
id: F008
type: feature
title: store-write-operations
description: vault 的建檔、增節、改寫、刪除與短 id 配號,全部走樂觀鎖與原子寫入
status: open
created: 2026-08-24
updated: 2026-08-24
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
| D(Markdown) | `NewSection` / `NewSectionPayload` 的新形狀(2026-08-24 G1 裁決) | `Aapms.Store.Create`(暫居,見待確認假設 A4) |
| G(錯誤) | 寫入路徑的錯誤建構子與 `render*` 繁中訊息 | `Aapms.Store.Edit`(暫居,見待確認假設 A2) |
| 內部模組劃分 | 「Write:建檔、增節、改寫、刪除、Node、License;樂觀鎖;`allocateId`」 | 四個檔案(下方「骨架」) |
| 資料流管線 | **寫入管線全段** | `Aapms.Store.Edit.commit` 定義那條線的順序 |

未超出範圍:本 feature 不新增任何契約 E 之外的對外函式;`Aapms.Store.Edit` /
`Aapms.Store.Node` 是內部模組,不進契約。**一處簽名偏離**(`createPackFile` 的第三參數)
見待確認假設 A1。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `StoreWriteError` | 新增 | 16 個建構子,見 `Edit.hs:80` | 寫入路徑可能發生哪些失敗,以及每一種的下一步 |
| `WriteResult` | 新增 | `{ wrId :: Id, wrPath :: FilePath, wrRevision :: Revision, wrIssues :: [IndexIssue] }` | 一次改寫之後,新的 revision 與索引附帶回報 |
| `Located` | 新增 | `{ locPath :: FilePath, locAnchor :: Maybe Id, locKind :: DocKind }` | 索引在寫入路徑上唯一的用途:目標住在哪個檔、哪一節、那是哪種文件 |
| `NewEntity` | 新增 | `Create.hs:74` | 一份新主題檔的全部人給欄位(不含 revision / 日期——那些由本層填) |
| `NewLevel` | 新增 | `Create.hs:95` | 一份新 Level 檔 + 它的根 Node |
| `NewPack` | 新增 | `Create.hs:112` | 一份新 `pack.md` 的檔案層欄位與落點目錄 |
| `NewSection` | 新增 | `{ nsId, nsLevel, nsTitle, nsBody, nsPayload }` | 一個新節的共通骨架(四種文件共用) |
| `NewSectionPayload` | 新增 | `NSFragment` / `NSAsset` / `NSLicense` / `NSNode`,各帶 `MetaOverride` | 「這一節是哪一種節點」以及它專屬的欄位 |
| `NewAsset` | 新增 | asset 專屬七欄,`Create.hs:176` | 一筆 asset 的檔案事實(`sha256` / `entry` 由 `asset-ingest` 算好給) |
| `NewLicense` | 新增 | 八個授權維度,`Create.hs:195` | 一種授權允許什麼、要求什麼 |
| `NewNode` | 新增 | `{ nnKind :: NodeKind }` | Level 節點唯一不能由標題階層推導的事實 |
| `AssetPatch` | 新增 | `{ apName, apLicense, apAuthor, apTags }`,兩層 `Maybe` | **人可以改 asset 的哪些欄位**——`sha256` / `entry` / `ext` / `meta` 不在裡面是型別層的拒絕 |
| `CreateResult` | 新增 | `{ crId, crPath, crRevision, crIssues }` | 剛建出來的節點的 id(呼叫端唯一拿不到其他來源的資訊) |
| `DeleteMode` | 新增 | `DeleteSafe \| DeleteForce` | 被指向時要擋還是照刪 |
| `DeleteResult` | 新增 | `{ drPath, drRemovedIds, drBrokenLinks, drIssues }` | 這次刪掉了哪些 id、打斷了哪些關聯 |

**知識歸屬的三條界線**(避免與既有模組重複持有同一個事實):

- **revision 的遞增點**只有一個:`Aapms.Core.Meta.bumpRevision`(F001)。本 feature 不自己 +1,
  只負責比對與傳遞
- **檔案落點的規則**只有一個:`Aapms.Core.Registry.lookupDir`(F002)。本 feature 不硬編任何
  型別 → 目錄的對應,唯一的例外是 `levels/`(`level` 是保留鍵,不可能在註冊表裡)
- **序列化規則**只有一份:`aapms-md`。本 feature 不自己組 YAML、不自己拼 `Section`

## 介面

「骨架位置」的行號是建檔當下的導航線索;一致性以簽名原文為準。

### 契約 E:寫入組

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `createTopicFile :: VaultHandle -> TypeRegistry -> NewEntity -> IO (Either StoreWriteError CreateResult)` | 建一份新的主題檔,落點依註冊表的 `dir` | `store/src/Aapms/Store/Create.hs:259` |
| `createLevelFile :: VaultHandle -> TypeRegistry -> NewLevel -> IO (Either StoreWriteError CreateResult)` | 建一份新的 Level 檔,連同它的根 Node | `store/src/Aapms/Store/Create.hs:270` |
| `createPackFile :: VaultHandle -> NewPack -> [NewSection] -> IO (Either StoreWriteError CreateResult)` | 在指定目錄寫出 `pack.md`,節的順序與給定順序相同 | `store/src/Aapms/Store/Create.hs:286` |
| `addSection :: VaultHandle -> Id -> NewSection -> IO (Either StoreWriteError CreateResult)` | 往既有檔案的檔尾追加一個節,依 `nsPayload` 分派 | `store/src/Aapms/Store/Create.hs:310` |
| `writeMeta :: VaultHandle -> Id -> Revision -> (MetaOverride -> MetaOverride) -> IO (Either StoreWriteError WriteResult)` | 改一個既有節點的 `Meta` 欄位 | `store/src/Aapms/Store/Write.hs:83` |
| `writeAssetFields :: VaultHandle -> Id -> Revision -> AssetPatch -> IO (Either StoreWriteError WriteResult)` | 改一筆 asset 的人給欄位 | `store/src/Aapms/Store/Write.hs:95` |
| `writeBody :: VaultHandle -> Id -> Revision -> Text -> IO (Either StoreWriteError WriteResult)` | 換掉一個節點的正文 | `store/src/Aapms/Store/Write.hs:109` |
| `addLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreWriteError WriteResult)` | 在來源節點上加一筆關聯 | `store/src/Aapms/Store/Write.hs:123` |
| `removeLink :: VaultHandle -> Id -> Revision -> Link -> IO (Either StoreWriteError WriteResult)` | 從來源節點刪掉相符的關聯 | `store/src/Aapms/Store/Write.hs:134` |
| `upsertLicense :: VaultHandle -> License -> IO (Either StoreWriteError WriteResult)` | 把一種授權寫進該 vault 的 `licenses.md`(有就改、沒有就新增) | `store/src/Aapms/Store/Write.hs:151` |
| `deleteNode :: VaultHandle -> Id -> Revision -> DeleteMode -> IO (Either StoreWriteError DeleteResult)` | 刪一個節點;目標是什麼決定刪掉多少 | `store/src/Aapms/Store/Create.hs:333` |
| `allocateId :: VaultHandle -> IdPrefix -> Text -> IO Id` | 產生一個索引裡還沒有人用的短 id | `store/src/Aapms/Store/Write.hs:166` |

### 契約 G:錯誤

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `data StoreWriteError` | 寫入路徑的失敗原因 | `store/src/Aapms/Store/Edit.hs:80` |
| `renderStoreWriteError :: StoreWriteError -> Text` | 把失敗原因說成繁中訊息,每一則說出下一步 | `store/src/Aapms/Store/Edit.hs:117` |

### 內部:寫入紀律(`Aapms.Store.Edit`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `(>>?) :: IO (Either StoreWriteError a) -> (a -> IO (Either StoreWriteError b)) -> IO (Either StoreWriteError b)` | 失敗就短路的 IO 鏈 | `store/src/Aapms/Store/Edit.hs:139` |
| `(?>>) :: Either StoreWriteError a -> (a -> IO (Either StoreWriteError b)) -> IO (Either StoreWriteError b)` | 把純函式那一段接進同一條鏈 | `store/src/Aapms/Store/Edit.hs:148` |
| `locate :: VaultHandle -> Id -> IO (Either StoreWriteError Located)` | 說出目標住在哪個檔、哪一節、那是哪種文件 | `store/src/Aapms/Store/Edit.hs:172` |
| `readDocument :: VaultHandle -> FilePath -> IO (Either StoreWriteError Document)` | 重讀檔案並切塊 | `store/src/Aapms/Store/Edit.hs:178` |
| `orMd :: FilePath -> Either MdError a -> Either StoreWriteError a` | 把 md 的錯誤接上檔名 | `store/src/Aapms/Store/Edit.hs:182` |
| `checkRevision :: Id -> Revision -> Revision -> Either StoreWriteError ()` | 比對呼叫端手上的 revision 與檔案裡的實際值 | `store/src/Aapms/Store/Edit.hs:191` |
| `commit :: VaultHandle -> FilePath -> Document -> Id -> Revision -> IO (Either StoreWriteError WriteResult)` | 把已經算好的最終內容落地,並讓該檔的索引跟上 | `store/src/Aapms/Store/Edit.hs:203` |
| `dropFile :: VaultHandle -> FilePath -> IO (Either StoreWriteError ())` | 移除一份檔案與它的全部索引記錄 | `store/src/Aapms/Store/Edit.hs:216` |
| `ensureDir :: VaultHandle -> FilePath -> IO ()` | 建出目標檔案所在的目錄 | `store/src/Aapms/Store/Edit.hs:224` |
| `vaultAbsPath :: VaultHandle -> FilePath -> FilePath` | Vault 相對路徑 → 絕對路徑 | `store/src/Aapms/Store/Edit.hs:228` |
| `sectionBodyRaw :: LineEnding -> Text -> Text` | 把正文包成節的正文切片形狀 | `store/src/Aapms/Store/Edit.hs:236` |

### 內部:Level 樹推導(`Aapms.Store.Node`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `headingDepthFor :: FilePath -> Document -> Id -> Either StoreWriteError Int` | 在指定父節點底下新增子節點時,新節該用第幾級標題 | `store/src/Aapms/Store/Node.hs:41` |
| `subtreeAfter :: Document -> Id -> [Section]` | 某一節之後、屬於它子樹的所有節 | `store/src/Aapms/Store/Node.hs:47` |
| `subtreeIds :: Document -> Id -> [Id]` | 某一節與它整棵子樹的 id,依文件順序 | `store/src/Aapms/Store/Node.hs:54` |
| `isRootNode :: FilePath -> Document -> Id -> Either StoreWriteError Bool` | 這個 id 是不是該 Level 檔的根 Node | `store/src/Aapms/Store/Node.hs:60` |
| `validateLevelDoc :: FilePath -> Document -> Either StoreWriteError ()` | 編輯後的 Level 檔還解析得回來、樹還合法嗎 | `store/src/Aapms/Store/Node.hs:69` |

### 內部:檔名(`Aapms.Store.Create`)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `sanitizeFileName :: Text -> Text -> Text` | 標題 → 檔名主幹,保留中文原字元 | `store/src/Aapms/Store/Create.hs:348` |

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
- **L12(`addSection` 追加不動前面)**:對所有含 `n` 節的文件,`addSection` 成功之後前 `n` 節的
  `renderSection` 位元組不變,新節排在最後;且該檔對應的 `to*`(依 `DocKind`)仍然解析成功,
  多出來的那一筆節點的 `metaId` 等於 `nsId`。
- **L13(`deleteNode` 的兩種模式)**:對所有目標 `i`,設 `victims` 為 `subtreeIds` 決定的
  消失集合(檔案層主體則為檔內全部節點 id):
  `DeleteSafe` 時若存在任一 `v ∈ victims` 被 `linksTo` 找得到,回 `Left (ReferencedBy i _)`
  且 `bytes(該檔)` 不變;`DeleteForce` 時成功,`drRemovedIds == victims`,而
  `drBrokenLinks` 恰好是所有指向 `victims` 的 `(來源, 關聯)`。目標是根 Node 時一律回
  `Left (CannotDeleteRootNode i)`,兩種模式皆然。
- **L14(`allocateId` 互異)**:對所有 `(prefix, content)` 與所有 `n`,連續呼叫 `allocateId`
  `n` 次、每次把結果寫進索引之後,得到的 `n` 個 `Id` 兩兩相異,且每一個的
  `Aapms.Core.Id.idPrefix` 都等於 `prefix`。
- **L15(錯誤訊息說出下一步)**:對所有 `StoreWriteError e`,`renderStoreWriteError e` 非空,
  且含至少一個以「請」起頭的子句(system.md 全域錯誤處理策略第 2 條)。
- **L16(先寫檔、再更新索引)**:對所有成功或以 `IndexUpdateFailed` 收場的寫入,磁碟上的目標
  檔案內容已經是新內容(`readTextFile` 讀得到);反之,任何以 `RevisionMismatch` /
  `MdWriteFailed` / `TreeInvalidOnWrite` / `ReferencedBy` / `LinkNotFound` /
  `BadSectionPayload` 收場的呼叫,檔案位元組不變。
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
| E6 | 索引裡已存在 `newId p c t 0` 與 `newId p c t 1` 兩個 id;`allocateId vh p c` | 回傳的 `Id` 與那兩個都不同(實作上即 salt = 2 的那一個) | 人為製造碰撞 |
| E7 | 節點 `i` 的 `links` 不含 `l`;`removeLink vh i r l` | `Left (LinkNotFound i l)`,檔案位元組不變 | 刪不存在的關聯 |
| E8 | Level 檔的根 Node `nod-root`;`deleteNode vh nod-root r DeleteForce` | `Left (CannotDeleteRootNode nod-root)`,檔案不變 | 根節點刪不得;`DeleteForce` 也擋 |
| E9 | `pack.md` 裡有 `sha256` / `entry` 的 asset 節;`writeBody vh ast-1 r "新的說明"` | `Right`;重讀後該 asset 的 `astBody == "新的說明"`,`astSha256` / `astEntry` 仍在且未變,其他節位元組不變 | 改正文不得吃掉 payload 欄位 |
| E10 | 目標檔是 `pack.md`(`PackDoc`);`addSection vh pck-1 s`,其中 `nsPayload = NSFragment ov` | `Left (BadSectionPayload (nsId s) PackDoc)`,檔案不變 | payload 與文件種類不符 |
| E11 | `sanitizeFileName "第一章: 序幕 " "ent-7f3b2a91"` | `"第一章- 序幕"`(冒號換 `-`、去尾端空白) | 檔名淨化;非 ASCII 保留 |

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
| `data StoreError` | `store/src/Aapms/Store/Error.hs:17` | F005 | 經 `WriteStore` 原樣往上帶 |
| `trySqlite :: IO a -> IO (Either StoreError a)` | `store/src/Aapms/Store/Error.hs:56` | F005 | 定位查詢與配號查詢的 SQLite 邊界 |
| `indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])` | `store/src/Aapms/Store/Index.hs:147` | F006 | 寫檔之後只重讀該檔 |
| `unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | `store/src/Aapms/Store/Index.hs:154` | F006 | 刪整份檔案時清索引 |
| `data IndexIssue` | `store/src/Aapms/Store/Schema.hs:70` | F006 | `WriteResult` / `CreateResult` 的附帶回報 |
| `linksTo :: VaultHandle -> Ref -> IO [(Meta, Link)]` | `store/src/Aapms/Store/Query.hs:439` | F006 | `deleteNode` 的被引用檢查 |
| `parseDocument :: Text -> Either MdError Document` | `md/src/Aapms/Md/Parse.hs:51` | F004 | 重讀後切塊 |
| `toTopic :: Document -> Either MdError (Entity, [Entity])` | `md/src/Aapms/Md/Parse.hs:123` | F004 | 取得主題檔目前的 `Meta`(比對 revision)與寫檔前的自我驗證 |
| `toLevel :: Document -> Either MdError (Level, [Node])` | `md/src/Aapms/Md/Parse.hs:139` | F004 | Level 檔同上;`validateLevelDoc` 的第一段 |
| `toPack :: Document -> Either MdError (Pack, [Asset])` | `md/src/Aapms/Md/Parse.hs:243` | F004 | `pack.md` 同上;`writeAssetFields` 讀出目前的 asset 欄位 |
| `toLicenses :: Document -> Either MdError [License]` | `md/src/Aapms/Md/Parse.hs:319` | F004 | `licenses.md` 同上;`upsertLicense` 判斷該 id 是否已存在 |
| `renderDocument :: Document -> Text` | `md/src/Aapms/Md/Render.hs:56` | F004 | 位元組保留的重組 |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:67` | F004 | 節層 meta 改寫 |
| `overrideAt :: Id -> Document -> Either MdError MetaOverride` | `md/src/Aapms/Md/Render.hs:84` | F004 | 先看目前值再決定要不要改(`removeLink` 沒命中要中止) |
| `updateSectionBody :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:171` | F004 | 節層換正文 |
| `renameSection :: Id -> Text -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:194` | F004 | 節層換標題 |
| `replacePreamble :: Text -> Document -> Document` | `md/src/Aapms/Md/Render.hs:217` | F004 | 檔案層主體換正文 |
| `removeSection :: Id -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:161` | F004 | 刪一節 / 刪子樹 |
| `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:262` | F004 | 檔案層 meta 與 revision 遞增 |
| `newDocument :: DocKind -> Meta -> Text -> Document` | `md/src/Aapms/Md/Render.hs:284` | F004 | 從零建一份新檔 |
| `appendSection :: NewSection -> Document -> Either MdError Document` | `md/src/Aapms/Md/Render.hs:126` | F004 | 追加一節(**需改形狀**,見待確認假設 A4) |
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
  - `Aapms.Store.Edit` → `Aapms.Core.{Id,Link,Meta,Tree}`、`Aapms.Md.{Document,Error}`、
    `Aapms.Store.{Error,Marker,Schema}`
  - `Aapms.Store.Write` → `Aapms.Core.{Asset,Id,License,Link,Meta}`、`Aapms.Md.Inherit`、
    `Aapms.Store.{Edit,Marker}`
  - `Aapms.Store.Node` → `Aapms.Core.Id`、`Aapms.Md.Document`、`Aapms.Store.Edit`
  - `Aapms.Store.Create` → `Aapms.Core.{Asset,Id,Level,Link,Meta,Pack,Registry}`、
    `Aapms.Md.Inherit`、`Aapms.Store.{Edit,Marker,Schema}`
  - 實作階段還會新增(骨架未 import,因為只有本體用得到):
    `Aapms.Store.Edit` → `Aapms.Store.{Atomic,Index}`、`Aapms.Md.{Parse,Render}`、
    `Database.SQLite.Simple`;`Aapms.Store.Create` → `Aapms.Store.{Node,Write,Query}`、
    `Aapms.Md.{Parse,Render}`、`System.Directory`、`System.FilePath`;
    `Aapms.Store.Write` → `Aapms.Store.Edit`(已有)、`Aapms.Md.{Parse,Render}`、`Data.Time`
  - **模組內部順序**:`Edit → {Write, Node} → Create`,無環
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

## 待確認假設

- **A1**:契約 E 寫 `createPackFile :: VaultHandle -> NewPack -> [NewAsset] -> …`,但 G1 之後
  `NewAsset` 只剩 asset 專屬七欄,組不出節的標題(`nsTitle`)與節層 meta(`type` 在 pack.md
  不繼承、缺漏是錯誤)。→ **採取**:第三參數改為 `[NewSection]`,每筆 payload 必須是
  `NSAsset`,否則 `BadSectionPayload`。→ **影響**:若編排者裁決保留 `[NewAsset]`,則
  `NewAsset` 要加回 `naTitle` / `naOverride` / `naBody` 三欄,`NSAsset` 的 `MetaOverride`
  參數變成冗餘,契約 D 要跟著改。**建議回寫 design.md 契約 E 這一行。**

- **A2**:契約 E 寫 `IO (Either StoreError a)`,但本 feature 的骨架路徑清單不含
  `store/src/Aapms/Store/Error.hs`,加不了建構子。→ **採取**:在
  `Aapms.Store.Edit` 定義 `StoreWriteError`,以 `WriteStore StoreError` 為橋,十二條簽名
  一律回 `Either StoreWriteError a`。→ **影響**:編排者把這 15 個新建構子併進
  `StoreError`(`Error.hs` 的 haddock 本來就寫「F008 往這個型別加建構子」)之後,
  把四個檔案裡的 `StoreWriteError` 全域換成 `StoreError`、刪掉 `WriteStore` 與
  `renderStoreWriteError`(併進 `renderStoreError`)即可,語意一個字都不變。
  **這件事最好在委派 qa / impl 之前做完**,否則兩邊會針對暫居型別寫程式。

- **A3**:`allocateId` 的契約簽名是 `IO Id`,沒有失敗通道,但碰撞檢查要查索引。→ **採取**:
  查詢失敗視同「查不到」並回傳當前候選 id。→ **影響**:若編排者要求配號在索引壞掉時也必須
  失敗,簽名要改成 `IO (Either StoreWriteError Id)`(契約 E 偏離)。目前的判斷理由是:索引
  壞掉這件事會在緊接著的 `commit` 以 `IndexUpdateFailed` 現形,不需要兩條路徑各報一次。

- **A4**:`NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` 的**永久
  歸屬是 `aapms-md`**(契約 D 就寫在 md 那一節),但 `md/` 不在骨架清單裡。→ **採取**:
  暫時定義在 `Aapms.Store.Create`。→ **影響**:md 補上這些型別之後,`Aapms.Store.Create`
  刪掉本地定義、改成 re-export md 的同名同欄位型別即可,契約 E 的簽名不變。
  **在那之前 `addSection` / `createPackFile` 實作不完**——見下方「阻塞」。

- **A5**:`addSection` 對 `LevelDoc` 只能**追加在文件末尾**(F004 的 `appendSection` 語意;
  F004 已移除舊的 `insertSection`)。→ **採取**:`nsLevel` 由呼叫端給,寫檔前以
  `validateLevelDoc` 把關;想在文件中段的某個父節點底下插入,目前做不到。→ **影響**:
  若 `service` 需要「在指定父節點底下新增子節點」,md 要補回 `insertSection`,或本 feature
  另開 E 文檔。`Aapms.Store.Node.headingDepthFor` 已經先把「父節點 → 標題層級」這段推導留好。

- **A6**:`Aapms.Store` 門面(`store/src/Aapms/Store.hs`)沒有 re-export 本 feature 的四個
  模組,而該檔不在骨架清單裡。→ **採取**:不動它,qa / impl 直接 import
  `Aapms.Store.{Create,Write}`。→ **影響**:編排者若希望門面完整,加兩行 re-export 即可。

## 阻塞

**`addSection` / `createPackFile` 的實作在 `aapms-md` 改動落地之前完成不了**,理由不是
分工而是資料會遺失:

1. `Aapms.Md.Render.renderMetaBlock` 只輸出 `metaFieldOrder`(`MetaOverride` 的十三個欄位)。
   asset 的 `sha256` / `entry` / `ext` / `meta` / `license` / `author` 與 license 的八個授權
   維度都住在**同一個 ` ```meta ` 區塊**裡(見 `md/src/Aapms/Md/Parse.hs` 的 `AssetFields` /
   `LicenseFields`),因此新節寫不出這些欄位,`toPack` / `toLicenses` 解不回來。
2. 更嚴重的是既有節:`updateSection` 的 `reserialize` 用 `renderMetaBlock` **整塊重寫** meta
   區塊,而 `currentOverride` 解出的 `MetaOverride` 不含那些欄位——所以**目前任何對 pack.md
   asset 節或 licenses.md license 節的 `updateSection`,都會靜默刪掉 `sha256` / `entry` /
   八個授權維度**。`writeMeta` / `writeBody` / `addLink` / `removeLink` 全部踩在這條線上
   (L4 / E9 直接在測這件事)。

需要的 md 改動列在下方回報;在它落地之前,本 feature 的 impl 只能完成
`createTopicFile` / `createLevelFile` / `writeBody`(檔案層主體那條)/ `deleteNode` /
`allocateId` 與 `Edit` / `Node` 的內部函式。

## 骨架

| 檔案 | 內容 |
|---|---|
| `store/src/Aapms/Store/Edit.hs` | `StoreWriteError`(16 建構子)、`renderStoreWriteError`、`WriteResult`、`Located`、`(>>?)` / `(?>>)`、`locate` / `readDocument` / `orMd` / `checkRevision` / `commit` / `dropFile` / `ensureDir` / `vaultAbsPath` / `sectionBodyRaw` |
| `store/src/Aapms/Store/Write.hs` | `AssetPatch`;`writeMeta` / `writeAssetFields` / `writeBody` / `addLink` / `removeLink` / `upsertLicense` / `allocateId` |
| `store/src/Aapms/Store/Node.hs` | `headingDepthFor` / `subtreeAfter` / `subtreeIds` / `isRootNode` / `validateLevelDoc`(全部純函式) |
| `store/src/Aapms/Store/Create.hs` | `NewEntity` / `NewLevel` / `NewPack` / `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` / `CreateResult` / `DeleteMode` / `DeleteResult`;`createTopicFile` / `createLevelFile` / `createPackFile` / `addSection` / `deleteNode` / `sanitizeFileName` |

四個檔案的所有函數本體皆為 `undefined`。型別檢查方式與結果見回報。

## 實作備註

(撰寫時留空)
