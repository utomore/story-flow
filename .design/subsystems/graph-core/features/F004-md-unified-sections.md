---
id: F004
type: feature
title: md-unified-sections
description: 分節引擎接統一 Meta;新增 pack.md/licenses.md 解析與位元組保留寫回
status: open
created: 2026-08-23
updated: 2026-08-23
depends-on: [F001, F002]
related-adr: [ADR-002, ADR-009, ADR-010, ADR-013]
related-feature: []
---

# F004: md-unified-sections

## 功能概述

`aapms-md` 目前只認得故事側兩種文件(主題檔 / Level 檔),而且吃的是 F001 統一 `Meta` 之前的舊型別
形狀——`Aapms.Md.Inherit` 有 12 處欄位型別對不上現在的 `Meta`(`TypeKey` vs `Text`、`VaultId` vs
`Text`、`Revision` vs `Int`),整個套件目前編不過。本 feature 要做兩件事:

1. **接上統一 `Meta`**:修好 `aapms-md` 的型別錯誤,讓它對齊 F001/F002 定案的 `Meta` / `Asset` /
   `Pack` / `License` / `Entity` / `Level` / `Node`。
2. **擴充成四種文件共用一個分節引擎**:在既有的主題檔 / Level 檔之外,新增 `pack.md`(容器 =
   `Pack`,節 = `Asset`)與 `licenses.md`(容器只是 Meta 容器不是節點,節 = `License`)的解析與
   位元組保留寫回,並落地 design.md「節層繼承規則」表格(pack.md 的節層 `type` 不繼承且缺漏是
   錯誤,其餘三種文件繼承)。

驗收標準(照契約卡逐字):

- 四種文件 roundtrip(解析 → 寫回 → 再解析)不失真;未修改區塊位元組相同
- 繼承規則照 design.md 表格:pack.md 的節層 `type` 不繼承且缺漏是錯誤
- `toPack` 把檔案層轉成 `Pack`、每節轉成 `Asset`
- `toLicenses` 每節一個 `License`,八個維度缺漏為 `Nothing` 而非錯誤(`commercial` 與
  `attribution_required` 除外,缺漏是錯誤)
- `appendSection` 在 1,693 節的文件末尾追加一節,前面 1,693 節位元組不變(D4:測試內生成器合成,
  不需要真實大檔)
- `MdError` 指出行號

## 相依性

`depends-on: [F001, F002]`:

- **F001**:直接的程式碼相依,理由見下方「使用到的既有串接介面」表——本 feature 的每一個函式都
  消費 F001 在 `aapms-core` 定義的 `Meta` / `Entity` / `Asset` / `Pack` / `License` / `Level` /
  `Node` / `Id` / `Ref` / `Link` / `TypeKey` / `VaultId` / `Revision` 與 `Aapms.Core.Json` 編碼
  規則
- **F002**:沒有直接的函式呼叫(`aapms-md` 不 import `aapms-types`,`docKind` 只比對字面
  `type` 字串,不查 `TypeRegistry`)——但 `docKind` 硬編碼的三個字面值("level"/"asset-pack"/
  "asset-license")與 F002 的 `registry-family-and-naming` 驗收標準「`asset-pack` / `asset-license`
  / `level` 出現在註冊表是載入錯誤」是**同一份保留鍵清單**的兩處體現:F002 若增減保留鍵,
  `docKind` 的分類規則要跟著改。這是「共用資料結構」性質的相依(design.md 功能規劃表本身也把
  md-unified-sections 列為依賴 #1、#2),不是呼叫關係,故不出現在「使用到的既有串接介面」表——
  該表只列有實際簽名可查證的函式呼叫。

不依賴 F003(`Manifest`):`aapms-md` 不產生、不讀 manifest。

**不可與 store-vault-handle(#5)/store-unified-index(#6)/store-write-operations(#8)平行**:
`aapms-store` 的六個模組(`Edit.hs` / `Create.hs` / `Node.hs` / `Query.hs` / `Index.hs` /
`Write.hs`)全部 `import Aapms.Md`,而本 feature 會改動 `parseDocument` 的簽名(拿掉 `FilePath`、
`[MdError]` 改單一 `MdError`)、把 `insertSection` 換成 `appendSection`(吃新的 `NewSection` DTO)、
把 `replaceSectionBody` 改名 `updateSectionBody`、拿掉 `MdWarning`。store 那六個模組現在編不過
(不只因為 `aapms-md` 編不過,`aapms-core` 的 F001 型別重塑它也還沒接上),本 feature 完成後它們
依然編不過——這是預期中的階段性狀態(見「明確不做」與下方風險段),`#5`/`#6`/`#8` 要接上新介面時
才會動 store 的程式碼。

## 對應的 Level 2 契約

實作 design.md「對外契約」契約 D 全部(`aapms-md`)、「模組間公開介面」的
`aapms-md` ↔ `aapms-core`(含 `MetaOverride`)、契約 G 的 `MdError`;資料流管線「讀取」的
`parseDocument → docKind → to*` 一段與「寫入」的「md 寫回」一段;「節層繼承規則」表格。

不動契約 A / B / C / E / F(`aapms-core` 的型別與函式、`aapms-types` 的註冊表、`aapms-store` 的
落地函式)——本 feature 只改 `aapms-md` 這一個套件的公開介面。

## 實作方式

### 1. 修正 `MetaOverride` 與 `Render.hs` 的型別對齊(T1、T2)

`Aapms.Md.Inherit.MetaOverride` 目前是:

```haskell
data MetaOverride = MetaOverride
  { moKind :: Maybe NodeKind
  , moType :: Maybe Text        -- 應為 Maybe TypeKey
  , moVault :: Maybe Text       -- 應為 Maybe VaultId
  , ...
  , moRevision :: Maybe Int     -- 應為 Maybe Revision
  , ... }
```

改成 `moType :: Maybe TypeKey`、`moVault :: Maybe VaultId`、`moRevision :: Maybe Revision`。
`TypeKey` / `VaultId` / `Revision` 三者都已在 `Aapms.Core.Json` 有 `FromJSON` 實例(字串 / 字串 /
數字),`MetaOverride` 手寫的 `FromJSON` 實例(`o .:? "type"` 等)完全不用改——aeson 會自動用對的
實例解碼。`emptyOverride`、`overrideOf`、`applyOverride`、`inheritMeta` 四處建構跟著把
`Just metaType`/`Just metaVault`/`Just metaRevision`(以及 `maybe 1 id moRevision` 要改成
`maybe (Revision 1) id moRevision`)的型別對齊。

`Render.hs` 序列化這三個欄位時目前直接對 `Text`/`Int` 呼叫 `scalar`/`show`(`renderFrontmatter` 的
`"type: " <> scalar (metaType m)`、`"vault: " <> scalar (metaVault m)`、
`"revision: " <> T.pack (show (metaRevision m))`,以及 `renderMetaBlock` 的對應三行)。
`TypeKey`/`VaultId`/`Revision` 都是 `deriving stock (Show)` 的 newtype(建構子有 export),
直接 `show` 會印成 `TypeKey "asset-pack"` 而不是 `asset-pack`,`Revision` 同理。六處都要先
pattern match 解開 newtype(`let TypeKey t = metaType m in scalar t` 這種寫法)才能餵給既有的
`scalar`/`flowScalar`。

### 2. 移除 `MdWarning`,警告改交給 `checkMeta`(T3)

design.md 的讀取管線寫得很明白:「`aapms-core` 純驗證:`buildTree`(Level)、`checkMeta`(每個
節點,只產警告)」——警告的唯一來源是 F002 的 `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]`
(`core/src/Aapms/Core/Meta.hs:128`,型別在同檔 183-192 行)。契約 D 的四個 `to*` 函式簽名也印證
這件事:`toTopic :: Document -> Either MdError (Entity, [Entity])` 這類簽名裡沒有警告的位置。

現有的 `Aapms.Md.Error.MdWarning`(`MissingSummary` / `CustomLinkKind` / `EmptyBody`,
`md/src/Aapms/Md/Error.hs:103-118`)與 `Inherit.hs` 產生警告的那兩行(167-169)因此整組移除;
`Parse.hs` 現有的 `parseEntityFile :: Document -> Either [MdError] (EntityFile, [MdWarning])`
與 `parseLevelFile` 同理拿掉回傳的 `[MdWarning]`。這是一個會改變行為的決定,列進「待確認假設」。

### 3. `MdError` 拿掉檔案路徑(T4)

契約 D 的 `parseDocument :: Text -> Either MdError Document` 沒有 `FilePath` 參數,`docKind`
一系列函式也都只吃 `Document`。現有 `MdError` 帶 `errPath :: FilePath`
(`md/src/Aapms/Md/Error.hs:26`),但契約沒有任何函式能把路徑餵進來——`Document`
(`md/src/Aapms/Md/Document.hs:54-67`)自己的 `docPath` 欄位目前也只能由呼叫端在 `parseDocument`
時傳入,新契約下沒有這個管道。`mkDocument`(即將改名 `newDocument`)原本就把 `docPath` 留空,
註解寫「要用於錯誤訊息時由呼叫端填」——也就是說現有程式碼已經承認路徑是呼叫端的責任,只是舊契約
把它硬塞進 `parseDocument` 的參數。新契約把這個責任徹底移交出去:`MdError` 拿掉 `errPath`,只剩
`errLine :: Int` 與 `errKind :: MdErrorKind`;`Document` 拿掉 `docPath`。`renderMdError` 的輸出
從 `<path>:<line>: <msg>` 改成 `第 <line> 行:<msg>`。之後 `aapms-store`(#5/#6,不在本 feature
範圍)在 `indexFile :: VaultHandle -> FilePath -> IO (...)` 已經知道檔案路徑,要顯示給使用者時
自己接上路徑即可。

`Lexer.hs`/`Parse.hs`/`Render.hs` 全部建構 `MdError` 的地方(約 20 處呼叫點,`MdError path line
kind` 或 `mdError path line kind`)要把 `path` 參數拿掉。

### 4. `parseDocument` 改單一錯誤,`Document` 內部快取 `DocKind`(T5、T6)

契約:`parseDocument :: Text -> Either MdError Document`、`docKind :: Document -> DocKind`——
注意 `docKind` **不是** `Either MdError DocKind`,代表它不會失敗。但 `docKind` 的判定規則
(design.md:「`docKind` 只看檔案層 `type`:`level` → `LevelDoc`、`asset-pack` → `PackDoc`、
`asset-license` → `LicenseDoc`、其餘一律 `TopicDoc`」)要讀 frontmatter 的 YAML 才知道
`type` 是什麼字串,而 YAML 有可能解不開。兩個事實合起來只有一種讀法:**`parseDocument` 必須在
解析階段就把 frontmatter 的 YAML 解到能讀出 `type`,`DocKind` 隨著 `Document` 一起算好存進去**;
`docKind` 只是回傳這個內部欄位的存取器,不會、也不需要重新解析。frontmatter YAML 解不開時
`parseDocument` 直接回 `Left (MdError _ (FrontmatterYaml _))`。

`parseDocument` **不需要**在這個階段驗證 `Meta` 的六個必填欄位(`id`/`vault`/`type`/`title`/
`created`/`updated`)全部到齊——那是語意層的事,留給 `toTopic`/`toLevel`/`toPack`/`toLicenses`
各自檢查(沿用既有 `Aapms.Md.Yaml.requiredFrontFields` 與 `missingFields`,
`md/src/Aapms/Md/Yaml.hs:69-75`)。`parseDocument` 只要 frontmatter 是合法 YAML、且能讀出
`type`(缺 `type` 或型別不是字串一律當 `TopicDoc`,因為 design.md 說「其餘一律 `TopicDoc`」,
`type` 本身要不要存在留給後面的必填欄位檢查)。

原本 `lexDocument`(`Lexer.hs:139-160`)以 `Either [MdError] Document` 回報**全部**結構錯誤
(標題缺 id、id 重複、meta 區塊沒收尾等);新契約要求單一 `MdError`。做法:內部仍然照舊蒐集
所有結構錯誤(這是實作細節,不影響公開型別),對外把清單依 `errLine` 排序後只回傳第一筆
(`Left . minimumBy (comparing errLine)`)。這個「只回報第一個錯誤」的行為改變,連同上面的
`MdWarning` 移除一起列進「待確認假設」。

### 5. `newDocument` 取代 `mkDocument`(T7)

契約:`newDocument :: DocKind -> Meta -> Text -> Document`。現有 `mkDocument :: LineEnding ->
Meta -> Text -> Document`(`Render.hs:258-269`)吃的是 `LineEnding` 不是 `DocKind`。新文件一律
固定用 `LF`(呼叫端要 `CRLF` 的情境——沿用既有檔案的風格——本來就是走 `updateFrontmatter`/
`updateSection` 之類的編輯路徑,不會呼叫 `newDocument`);傳入的 `DocKind` 存進上一節的內部快取
欄位,讓新建的 `Document` 呼叫 `docKind` immediately 就拿得到正確答案,不必先 `renderDocument`
再 `parseDocument` 繞一圈。

### 6. `toTopic` / `toLevel`(T8)

分別是現有 `parseEntityFile`(`Parse.hs:127-152`)/ `parseLevelFile`(`Parse.hs:158-196`)去掉
`[MdWarning]` 回傳值後的改名版,回傳型別從 `EntityFile { efMain, efFragments }` /
`LevelFile { lfLevel, lfNodes }` 兩個中介 record 改成契約要求的 tuple `(Entity, [Entity])` /
`(Level, [Node])`。內部邏輯(標題階層即樹、`buildTree` 不在這裡呼叫、Node 的 `entities` 由
`involves`/`references` 推導)不變,只是套上第 1、2 節修好的型別與 `inheritMeta` 新簽名
(見下一節,`typeInherits = True`)。

### 7. `toPack`(T9)

```
toPack :: Document -> Either MdError (Pack, [Asset])
```

檔案層:pack.md 的 frontmatter **直接解成 `Pack`**,不是先解成 `Meta` 再另外處理 pack 專屬欄位——
`Aapms.Core.Json` 的 `FromJSON Pack` 實例(`core/src/Aapms/Core/Json.hs:282-293`)本來就是把
`parseMetaFields o`(Meta 的六個必填 + 其餘欄位)與 `vendor`/`archive`/`sha256`/`license`/
`author`/`source_url`/`ai_disclosure` 這些 pack 專屬欄位攤平在同一層物件解出來,而 pack.md 的
frontmatter 形狀(system.md 的範例)正好就是這個攤平形狀。沿用 `Parse.hs` 現有的
`frontValue`/`missingFields`(`Yaml.hs:69-75`)先驗六個必填欄位,再 `fromValue v :: Either Text
Pack`。

每一節:先驗 `secId` 前綴是 `PAst`(沿用既有 `prefixErrors`,`Parse.hs:119-123`,把預期前綴從
`PEnt`/`PNod` 換成 `PAst`);`type` **不繼承**——`inheritMeta` 需要一個「type 是否繼承」的旗標
(design.md 節層繼承規則表格,pack.md 那一列),缺漏時回 `SectionFieldMissing secId "type"`(新
增的 `MdErrorKind` 建構子,見下)。除了 `Meta` 的欄位外,asset 專屬欄位(`name`/`sha256`/`entry`/
`ext`/`meta`/`license`/`author`)要從**同一份**節 meta YAML `Value` 另外解一次——它們不在
`MetaOverride` 裡(`MetaOverride` 只管 `Meta` 的欄位,`moKind` 是 Node 專屬的既有先例,asset 專屬
欄位比照辦理,獨立一個小 record 解碼,不塞進 `MetaOverride`,避免這個 DTO 為了三種文件各自的
專屬欄位越長越雜)。`sha256`/`entry` 對應 `Asset` 的非 `Maybe` 欄位(`Aapms.Core.Asset.Asset`,
`core/src/Aapms/Core/Asset.hs:35-46`),缺漏是錯誤;`name`/`ext`/`meta`/`license`/`author` 缺漏
是 `Nothing`/`Null`,與 `Aapms.Core.Json` 的 `FromJSON Asset` 實例(`Json.hs:244-255`)用的
`.:?`/`.:` 規則完全一致(等於把該實例「拆成兩半」用:一半走 `MetaOverride`+`inheritMeta`,一半
走這個新的小型別)。

不像 `toLevel` 呼叫 `structure`(`Parse.hs:220-240`)驗證標題跳級,`toPack` 跟現有的
`parseEntityFile` 一樣是**攤平**清單:pack.md 的每個節都是同一層的 asset,不管標題用 `##` 還是
`###`,`Section` 順序直接映成 `[Asset]` 的順序,不做樹狀驗證。

### 8. `toLicenses`(T10)

```
toLicenses :: Document -> Either MdError [License]
```

design.md 明講「licenses.md 的檔案層是容器不是節點」——檔案層只解到 `Meta`(用既有
`frontMeta`/`fromValue v :: Either Text Meta` 那條路,跟 TopicDoc/LevelDoc 一樣,**不是**
`toPack` 那種直接解成完整節點型別的路),這個 `Meta` 只用來當節層繼承的來源,不出現在
`toLicenses` 的回傳值裡。

每一節:先驗 `secId` 前綴是 `PLic`;`type` **繼承**——design.md 的節層繼承規則表格只列出兩欄
(「主題檔 / Level 檔」與「pack.md」),licenses.md 沒有單獨一欄。讀法只有一種說得通:表格說
「四種文件共用,差異只在一列」,那一列就是 pack.md 那一欄,licenses.md 因此併入「主題檔 /
Level 檔」那一欄——container 的 `type` 固定是 `asset-license`,每個 `License` 節點的型別概念上
本來就跟容器一致(不像 Pack 的節是各種 `asset-image`/`asset-audio`,型別本來就該跟容器不同),
繼承或要求逐節重寫沒有實質差異,選繼承跟另外三種文件的規則一致、程式碼路徑最少分岔。

除了 `Meta` 欄位外,授權八維度(`commercial`/`attribution_required`/`credit_text`/
`modification_allowed`/`redistribution_allowed`/`resale_allowed`/`nft_allowed`/`source_url`)
從同一份節 YAML `Value` 另外解——比照 `toPack` 的做法,獨立一個小 record,`commercial`/
`attribution_required` 用 `.:`(缺漏是錯誤),其餘六個用 `.:?`(缺漏是 `Nothing`)。這與
`Aapms.Core.Json` 的 `FromJSON License` 實例(`Json.hs:310-322`)的必填/選填劃分完全一致
(該實例的 `full_text` 欄位不在節層——`License` 的 `licFullText` 供全域授權登記用,節層 meta
不需要重複貼授權全文,沿用同一套「缺漏 `Nothing`」規則自然涵蓋)。跟 `toPack` 一樣是攤平清單,
不驗證標題階層。

### 9. `MdErrorKind` 新增建構子(T11)

```haskell
SectionFieldMissing Id Text   -- 節 id, 缺少的必填欄位名(如 "type"、"commercial")
```

供 `toPack`(節缺 `type`)與 `toLicenses`(節缺 `commercial`/`attribution_required`)共用。
`renderMdErrorKind` 補一行:`"節 " <> renderId i <> " 缺少必填欄位 " <> f`。既有的
`RequiredFieldMissing Text` 維持專指「檔案層 frontmatter 缺欄位」的語意,不覆用。

### 10. `NewSection` 與 `appendSection`(T12)

```haskell
data NewSection = NewSection
  { nsId    :: Id
  , nsLevel :: Int
  , nsTitle :: Text
  , nsMeta  :: MetaOverride
  , nsBody  :: Text
  }

appendSection :: NewSection -> Document -> Either MdError Document
```

`nsId` 由呼叫端(`aapms-store` 的 `allocateId`,契約 E,#8 的範圍)先配好再傳進來——`aapms-md`
不知道怎麼配 id,契約 B 的 `newId`/`allocateId` 也都不在 `aapms-md` 能呼叫的範圍內。取代現有的
`insertSection :: Maybe Id -> Section -> Document -> Either MdError Document`
(`Render.hs:107-118`):`insertSection` 的 `Maybe Id` 是「插在哪一節之後」,`Nothing` 代表插在
**最前面**;而契約的 `appendSection`(顧名思義)固定「插在文件**最後**一節之後,沒有任何節時插在
最前面(preamble 之後)」——語意变窄但直接對上驗收標準的「在 1,693 節的文件末尾追加一節」。實作
上是 `insertSection` 邏輯的一個特化:算出 `docSections` 最後一個的 `secId`(或沒有節時走
`Nothing` 分支),用 `mkSection`(`Render.hs:210-221`,拿掉 `LineEnding` 參數改吃 `Document` 的
`docEnding`)由 `NewSection` 組出 `Section`,重複 id 時回 `Left (MdError _ (DuplicateSectionId
nsId))`。

`appendSection` 完全不驗證標題層級是否合理(例如 Level 文件插入一個層級不連續的節)——跟 `toPack`/
`toLicenses`/`toTopic` 一樣,樹狀合法性是 `aapms-core` 的 `buildTree` 在下一次 `toLevel` 時才會
抓到(`MdErrorKind` 的 `HeadingSkip`/`HeadingAboveRoot` 屬於 `structure` 這個既有機制,不歸
`appendSection` 管)。

### 11. `updateSectionBody` 改名(T13)

現有 `replaceSectionBody :: Id -> Text -> Document -> Either MdError Document`
(`Render.hs:148-162`)簽名已經跟契約一致,純改名成 `updateSectionBody`,邏輯不動。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: VaultId, metaType :: TypeKey, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Maybe Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Revision, metaCreated :: Day, metaUpdated :: Day }` | `core/src/Aapms/Core/Meta.hs:123-139` | F001 | `MetaOverride`/`inheritMeta`/`applyOverride`/frontmatter 序列化的基礎型別 |
| `newtype TypeKey = TypeKey Text`(建構子 export) | `core/src/Aapms/Core/Meta.hs:45-47` | F001 | `moType`/`metaType` 的正確型別 |
| `newtype Revision = Revision Int`(建構子 export) | `core/src/Aapms/Core/Meta.hs:50-52` | F001 | `moRevision`/`metaRevision` 的正確型別 |
| `data Status = Draft \| Canon \| Deprecated \| Missing` | `core/src/Aapms/Core/Meta.hs:57-62` | F001 | `moStatus`/`metaStatus`,`FromJSON`/`ToJSON` 已在 `Json.hs` | 
| `data Source = Human \| Agent Text \| Workshop Text \| Scan \| Ai Text` | `core/src/Aapms/Core/Meta.hs:80-90` | F001 | `moSource`/`metaSource` |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` | `core/src/Aapms/Core/Meta.hs:112-116` | F001 | `moTimeline`/`metaTimeline` |
| `newtype Id`(不透明)、`parseId :: Text -> Either IdError (IdPrefix, Id)`、`renderId :: Id -> Text`、`idPrefix :: Id -> IdPrefix` | `core/src/Aapms/Core/Id.hs:86-141` | F001 | 節標題 `{#id}` 解析、`secId`、`appendSection` 的 `nsId` |
| `newtype VaultId = VaultId Text`(建構子 export) | `core/src/Aapms/Core/Id.hs:148-150` | F001 | `moVault`/`metaVault` 的正確型別 |
| `data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`parseRef`、`renderRef :: Ref -> Text` | `core/src/Aapms/Core/Id.hs:156-182` | F001 | `Link` 的 target、`astLicense`/`pckLicense` |
| `data IdPrefix = PEnt \| PAst \| PPck \| PLic \| PLvl \| PNod \| PVlt \| PPrj`、`renderIdPrefix` | `core/src/Aapms/Core/Id.hs:46-66` | F001 | `prefixErrors` 對 `PAst`(pack.md)/`PLic`(licenses.md)的驗證 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }`、`data LinkKind = ... \| Uses \| Depicts \| Custom Text`、`renderLinkKind` | `core/src/Aapms/Core/Link.hs:28-58,75-87` | F001 | `moLinks`/`metaLinks`,`Render.hs` 的 `linkLine` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/Aapms/Core/Entity.hs:12-17` | F001 | `toTopic` 的回傳型別 |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }`、`data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }`、`data NodeKind = KScene \| ... \| KBranch`、`renderNodeKind`、`parseNodeKind` | `core/src/Aapms/Core/Level.hs:19-71` | F001 | `toLevel` 的回傳型別、`moKind` |
| `data Asset = Asset { astMeta :: Meta, astName :: Maybe LogicalName, astSha256 :: Sha256, astEntry :: Text, astExt :: Maybe Text, astKindMeta :: Value, astLicense :: Maybe Ref, astAuthor :: Maybe Text, astBody :: Text }`、`newtype Sha256`、`newtype LogicalName` | `core/src/Aapms/Core/Asset.hs:17-46` | F001 | `toPack` 每節轉出的 `Asset`;`astSha256`/`astEntry` 非 `Maybe`,決定哪些欄位缺漏是錯誤 |
| `data Pack = Pack { pckMeta :: Meta, pckVendor :: Maybe Text, pckArchive :: Maybe FilePath, pckSha256 :: Maybe Sha256, pckLicense :: Maybe Ref, pckAuthor :: Maybe Author, pckSourceUrl :: Maybe Text, pckAiDisclosure :: AiDisclosure, pckBody :: Text }`、`data Author`、`data AiDisclosure` | `core/src/Aapms/Core/Pack.hs:19-47` | F001 | `toPack` 的檔案層回傳型別 |
| `data License = License { licMeta :: Meta, licCommercial :: Bool, licAttributionRequired :: Bool, licCreditText :: Maybe Text, licModificationAllowed :: Maybe Bool, licRedistributionAllowed :: Maybe Bool, licResaleAllowed :: Maybe Bool, licNftAllowed :: Maybe Bool, licSourceUrl :: Maybe Text, licFullText :: Maybe Text }` | `core/src/Aapms/Core/License.hs:13-25` | F001 | `toLicenses` 每節轉出的型別;`licCommercial`/`licAttributionRequired` 非 `Maybe`,決定哪些欄位缺漏是錯誤 |
| `instance FromJSON Meta`(`o .: "id"` 等六個必填 + 其餘 `.:?`) | `core/src/Aapms/Core/Json.hs:154,177-193` | F001 | `frontMeta` 解檔案層(TopicDoc/LevelDoc/LicenseDoc 容器) |
| `instance FromJSON Pack`(`parseMetaFields o` + pack 專屬欄位攤平在同一物件) | `core/src/Aapms/Core/Json.hs:282-293` | F001 | `toPack` 解檔案層,直接 `fromValue v :: Either Text Pack` |
| `instance FromJSON Asset` / `instance FromJSON License`(必填/選填欄位劃分) | `core/src/Aapms/Core/Json.hs:244-255,310-322` | F001 | `toPack`/`toLicenses` 節層專屬欄位解碼的必填/選填規則參照(不能直接重用,因為節 YAML 沒有 `id`/`title`/`created`/`updated`,見實作方式第 7、8 節) |
| `instance FromJSON TypeKey` / `FromJSON VaultId` / `FromJSON Revision` / `FromJSON Status` / `FromJSON Source` / `FromJSON Timeline` / `FromJSON Link` / `FromJSON NodeKind` | `core/src/Aapms/Core/Json.hs:58-68,82-92,101-104,128-139,141-149,94-98` | F001 | `MetaOverride`(修正型別後)、`Meta` 本身的 `FromJSON` 全部靠這些實例;`aapms-md` 不必自己寫解碼 |

## 新增的介面

```haskell
-- Aapms.Md.Document -----------------------------------------------------

data DocKind = TopicDoc | LevelDoc | PackDoc | LicenseDoc
  deriving stock (Show, Eq)

data Document   -- 不透明;內部欄位由實作決定,不再含 docPath

-- Aapms.Md.Error ----------------------------------------------------------

data MdError = MdError { errLine :: Int, errKind :: MdErrorKind }
  deriving stock (Show, Eq)

mdError :: Int -> MdErrorKind -> MdError

data MdErrorKind
  = NoFrontmatter
  | UnterminatedFrontmatter
  | FrontmatterYaml Text
  | SectionYaml Id Text
  | HeadingWithoutId Text
  | DuplicateSectionId Id
  | IdPrefixMismatch Id Text
  | HeadingSkip Int Int
  | HeadingAboveRoot Int Int
  | UnterminatedMetaBlock
  | MissingNodeKind Id
  | RootMismatch Id Id
  | RequiredFieldMissing Text        -- 檔案層 frontmatter 缺欄位
  | SectionFieldMissing Id Text      -- 新增:節缺少必填欄位(pack 的 type、license 的兩個必填維度)
  | UnknownSectionId Id
  deriving stock (Show, Eq)

renderMdError :: MdError -> Text     -- "第 <line> 行:<訊息>",不再含檔名

-- Aapms.Md.Inherit --------------------------------------------------------

data MetaOverride = MetaOverride
  { moKind :: Maybe NodeKind
  , moType :: Maybe TypeKey          -- 修正:原為 Maybe Text
  , moVault :: Maybe VaultId         -- 修正:原為 Maybe Text
  , moSummary :: Maybe Text
  , moTags :: Maybe [Text]
  , moStatus :: Maybe Status
  , moTimeline :: Maybe Timeline
  , moAliases :: Maybe [Text]
  , moLinks :: Maybe [Link]
  , moSource :: Maybe Source
  , moRevision :: Maybe Revision     -- 修正:原為 Maybe Int
  , moCreated :: Maybe Day
  , moUpdated :: Maybe Day
  }
  deriving stock (Show, Eq)
  -- FromJSON 實例不變(逐欄 .:?),型別隨欄位改變自動吃到正確的 core 實例

-- Aapms.Md.Parse ----------------------------------------------------------

parseDocument :: Text -> Either MdError Document
docKind       :: Document -> DocKind

toTopic    :: Document -> Either MdError (Entity, [Entity])
toLevel    :: Document -> Either MdError (Level, [Node])
toPack     :: Document -> Either MdError (Pack, [Asset])
toLicenses :: Document -> Either MdError [License]

-- Aapms.Md.Render -----------------------------------------------------------

renderDocument    :: Document -> Text
updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document
updateSection     :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document
updateSectionBody :: Id -> Text -> Document -> Either MdError Document          -- 改名自 replaceSectionBody
appendSection     :: NewSection -> Document -> Either MdError Document          -- 取代 insertSection
removeSection     :: Id -> Document -> Either MdError Document
newDocument       :: DocKind -> Meta -> Text -> Document                        -- 取代 mkDocument

data NewSection = NewSection
  { nsId    :: Id
  , nsLevel :: Int
  , nsTitle :: Text
  , nsMeta  :: MetaOverride
  , nsBody  :: Text
  }
  deriving stock (Show, Eq)
```

## TodoList

- [ ] T1: `MetaOverride` 的 `moType`/`moVault`/`moRevision` 改型別為 `TypeKey`/`VaultId`/`Revision`,
      `emptyOverride`/`overrideOf`/`applyOverride` 三處建構跟著改  `dep: -`
- [ ] T2: `Render.hs` 的 `renderFrontmatter`/`renderMetaBlock` 對 `type`/`vault`/`revision` 六處
      序列化改成先 pattern match 解開 newtype 再交給 `scalar`/`flowScalar`  `dep: T1`
- [ ] T3: `inheritMeta` 簽名加「type 是否繼承」旗標,回傳改 `Either MdErrorKind Meta`;移除
      `Aapms.Md.Error` 的 `MdWarning`/`renderMdWarning` 與 `Inherit.hs` 產生警告的兩行  `dep: T1`
- [ ] T4: `MdError` 拿掉 `errPath`(改雙參數 `errLine`/`errKind`);`Document` 拿掉 `docPath`;
      `Lexer.hs`/`Parse.hs`/`Render.hs` 全部建構 `MdError`/`mdError` 的呼叫點改新簽名  `dep: T3`
- [ ] T5: `parseDocument :: Text -> Either MdError Document`(拿掉 `FilePath`;結構錯誤內部仍蒐集
      全部、對外取行號最小的一筆);`Document` 內部快取 `DocKind`(frontmatter YAML 解不出時回
      `FrontmatterYaml`)  `dep: T4`
- [ ] T6: `docKind :: Document -> DocKind` 改為讀取內部快取欄位的存取器;`DocKind` 新增
      `PackDoc`/`LicenseDoc`  `dep: T5`
- [ ] T7: `newDocument :: DocKind -> Meta -> Text -> Document` 取代 `mkDocument`(固定 `LF`,把
      傳入的 `DocKind` 存進內部快取欄位)  `dep: T6`
- [ ] T8: `parseEntityFile`/`parseLevelFile` 改名 `toTopic`/`toLevel`,回傳型別改 tuple、拿掉
      `[MdWarning]`,套用 T3 的 `inheritMeta`(`typeInherits = True`)  `dep: T3, T5`
- [ ] T9: 新增 `toPack`——容器 `fromValue v :: Either Text Pack`;每節驗 `PAst` 前綴、
      `inheritMeta`(`typeInherits = False`,缺漏回 `SectionFieldMissing`),另解一組 asset 專屬
      欄位(`sha256`/`entry` 缺漏是錯誤,其餘缺漏是 `Nothing`)  `dep: T3, T4`
- [ ] T10: 新增 `toLicenses`——容器只解 `Meta`(不進回傳值);每節驗 `PLic` 前綴、`inheritMeta`
      (`typeInherits = True`),另解一組 license 8 維度(`commercial`/`attribution_required` 必填,
      其餘 6 個缺漏是 `Nothing`)  `dep: T3, T4`
- [ ] T11: `MdErrorKind` 新增 `SectionFieldMissing Id Text`,`renderMdErrorKind` 補訊息  `dep: T4`
- [ ] T12: `NewSection` DTO + `appendSection` 取代 `insertSection`(插在最後一節之後,無節時插最前;
      重複 id 回 `DuplicateSectionId`)  `dep: T4`
- [ ] T13: `replaceSectionBody` 改名 `updateSectionBody`(簽名邏輯不變)  `dep: -`
- [ ] T14: `Fixtures.hs` 補 `packMd`/`licensesMd`(逐字取自 system.md/design.md 範例)與 1,693 節
      合成器(D4:測試內產生器合成,不需要真實大檔)  `dep: T9, T10`
- [ ] T15: 依 1-to-1 測試表重整 `md/test/`——刪除 `MdWarning` 相關斷言(`InheritSpec`/
      `ParseEntitySpec`/`ParseLevelSpec`),修正 `EditSpec`/`InheritSpec` 裡 5 處
      `moVault = Just "..."`/`moType = Just "..."` 字面量(改包 `VaultId`/`TypeKey`),新增
      `ParsePackSpec`/`ParseLicenseSpec`/`AppendSectionSpec`  `dep: T2, T6, T7, T8, T9, T10, T11, T12, T13, T14`
- [ ] T16: `cabal test aapms-md` 全綠;記錄 `aapms-store` 六個模組(`import Aapms.Md`)在本 feature
      完成後依然編不過屬預期(D1,#5/#6/#8 才會接上新介面),回報進交付說明  `dep: T15`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_metaOverride_roundtrip | `overrideOf`/`applyOverride` 對 `moVault`/`moType`/`moRevision` 往返不失真(型別正確) |
| T2 | test_render_meta_scalars_unwrapped | `renderFrontmatter`/`renderMetaBlock` 印出的 `vault`/`type`/`revision` 是純量文字(如 `asset-pack`/`4`),不是 newtype 的 derived `Show`(`TypeKey "asset-pack"`/`Revision 4`) |
| T3 | test_toTopic_no_warning_channel | `toTopic`/`toLevel` 的回傳型別不含警告(編譯期即保證);另測 `inheritMeta` 對 `typeInherits=False` 且缺 `type` 時回 `Left (SectionFieldMissing ...)` |
| T4 | test_mderror_no_path | `renderMdError` 輸出「第 N 行:訊息」不含檔名;`Document` 型別不再有 `docPath` 欄位(編譯期保證) |
| T5 | test_parseDocument_single_error | 故意造兩個結構錯誤(標題缺 `{#id}` 在第 5 行、重複 id 在第 10 行),`parseDocument` 回傳 `errLine = 5` 的那個 |
| T6 | test_docKind_four_kinds | 四種 frontmatter(角色檔/`level`/`asset-pack`/`asset-license`)`docKind` 各自對應四個建構子;未知 `type` 回 `TopicDoc` |
| T7 | test_newDocument_pack_kind | `newDocument PackDoc meta body` 建出的 `Document`,`docKind` 回 `PackDoc`;`renderDocument` 產物能再被 `parseDocument` 解回、`docKind` 仍是 `PackDoc` |
| T8 | test_toTopic_toLevel_roundtrip | 沿用既有 `lindaMd`/`classroomMd` fixture,`toTopic`/`toLevel` 的欄位(id/summary 不繼承、tags 聯集、links)與改名前的 `parseEntityFile`/`parseLevelFile` 行為等價 |
| T9 | test_toPack_inherit_and_required | `packMd` fixture:容器解出的 `Pack` 欄位正確;asset 節缺 `type` 回 `SectionFieldMissing`;缺 `sha256`/`entry` 回錯誤;`vault`/`status` 從容器繼承、`tags` 聯集去重 |
| T10 | test_toLicenses_eight_dims | `licensesMd` fixture:每節一個 `License`;缺 `commercial`/`attribution_required` 回 `SectionFieldMissing`;其餘六維缺漏是 `Nothing`;容器本身不出現在回傳的 `[License]` 裡 |
| T11 | test_sectionFieldMissing_message | `renderMdError` 對 `SectionFieldMissing lic-xxxx "commercial"` 印出節 id 與行號 |
| T12 | test_appendSection_1693 | 合成器造 1,693 節的 `packMd`,`appendSection` 加一節後:前 1,693 節逐位元組不變、新節在最後、重複 id 回 `DuplicateSectionId`、結果能再被 `parseDocument` + `toPack` 解回 |
| T13 | test_updateSectionBody_rename | `updateSectionBody` 只改正文,標題行與 meta 區塊逐位元組不變(沿用既有 `replaceSectionBody` 的斷言,呼叫點改新名) |
| T14 | test_fixtures_parse_ok | `packMd`/`licensesMd`/合成器產出的文字都能被 `parseDocument` 成功解析(不進一步斷言內容,只確認 fixture 本身合法,供 T9/T10/T12 使用) |
| T15 | test_full_roundtrip_four_kinds | 四種 fixture(`lindaMd`/`classroomMd`/`packMd`/`licensesMd`)各自「解析 → `renderDocument` → 再解析」逐位元組相等(未修改情形,P0 契約測試精神的套件內版本) |
| T16 | cabal test aapms-md exit 0 | 全套件測試通過;`aapms-store` 不在本次驗證範圍,於回報中明記現況 |

## 待確認假設

- A1:`toTopic`/`toLevel`/`toPack`/`toLicenses` 移除 `MdWarning` 通道(`MissingSummary`/
  `CustomLinkKind`/`EmptyBody` 三種既有品質警告不再產生)。依據:契約 D 的四個 `to*` 簽名都是
  `Either MdError (...)`,沒有警告的位置;design.md 讀取管線明寫警告只來自 `aapms-core` 的
  `checkMeta`。影響:若判斷錯誤,需要在 `MdError`(或另一個型別)裡重新開一個警告通道,
  `toTopic`/`toLevel`/`toPack`/`toLicenses` 四個簽名都要加回傳值,是一次會動到 Level 2 契約的改動,
  需要開 `/subsys-design` 更新模式而非本 feature 自行加回。
- A2:`parseDocument` 由「一次回報全部結構錯誤(`[MdError]`)」改成「只回報行號最小的一個
  (`MdError`)」。依據:契約 D 的 `parseDocument :: Text -> Either MdError Document` 是單一
  `MdError`,`Render.hs` 既有的編輯函式(`updateSection`/`removeSection`)本來就是這個單一錯誤的
  形狀,採同一慣例。影響:若判斷錯誤(開發者其實要保留「一次列完全部錯誤」的 UX),需要在
  `MdErrorKind` 加一個聚合建構子(如 `ManyErrors [MdError]`)包住清單,`renderMdError` 對它逐筆
  串接輸出,不需要改動任何函式簽名,是低成本的修正。
- A3:`MdError` 徹底拿掉 `errPath`/`Document` 拿掉 `docPath`,檔名由 `aapms-store` 在回報給使用者
  時自行接上。依據:契約 D 所有函式簽名都沒有 `FilePath` 的位置,現有 `mkDocument` 的註解本來就
  承認路徑是「呼叫端要用於錯誤訊息時自己填」。影響:若判斷錯誤(`aapms-store` 其實預期
  `MdError` 自帶檔名),`store-vault-handle`(#5)或 `store-unified-index`(#6)實作時會需要一個
  「幫 `MdError` 補上檔名」的轉接函式,屬於低成本、局部的修正,不影響 `aapms-md` 內部邏輯。
- A4:`licenses.md` 的節層 `type` 繼承(與主題檔/Level 檔同一列,不與 pack.md 同列)。依據:
  design.md「節層繼承規則」表格只列兩欄,licenses.md 沒有專屬欄位,且每個 `License` 節點在概念上
  本來就與容器同型別(不像 Asset 對 Pack 型別必然不同)。影響:若判斷錯誤,`toLicenses` 需要改成
  `typeInherits = False`(要求每節顯式寫 `type: asset-license`),是 `Inherit.hs` 內部一個布林參數
  的改動,不影響公開簽名。
- A5:沿用既有 `Aapms.Md.Render.overrideAt :: Id -> Document -> Either MdError MetaOverride`
  (`Render.hs:78-81`)不變,即使它不在契約 D 的逐字清單裡。依據:它是 F001 之前既有程式碼(不是
  本 feature 新增),`aapms-store` 的 `Edit.hs` 依賴它先看目前值再決定要不要改
  (見該函式註解),移除會讓 store 一側多一段重複解碼邏輯;`moKind` 也是同類「契約清單外但已被
  認可的既有補充」先例。影響:若判斷錯誤(架構要求嚴格只暴露契約逐字清單),`/subsys-build` 的
  `arch-audit feature` 審查會抓到這條額外公開介面,屆時把它改成非 export 的內部函式即可,
  `aapms-store` 屆時要用時再另開介面請示 `/subsys-design`。

## 實作備註
