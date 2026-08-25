---
id: F004
type: feature
title: md-unified-sections
description: 分節引擎接統一 Meta;新增 pack.md/licenses.md 解析與位元組保留寫回
status: in-progress
created: 2026-08-23
updated: 2026-08-25
depends-on: [F001, F002]
related-adr: [ADR-002, ADR-009, ADR-010, ADR-013]
related-feature: []
---

# F004: md-unified-sections

## 目的

`aapms-md` 讓四種 Markdown 文件(主題檔 / Level 檔 / `pack.md` / `licenses.md`)共用一個分節引擎:
解析成 `aapms-core` 的節點型別,以及在**未修改的區塊逐字保留原始位元組**(ADR-010)的前提下寫回。
Markdown 檔是唯一的真相來源(ADR-002),所以本套件的正確性直接等於資料的安全性。

本次是 F004 的**重跑**(2026-08-24 開發者裁決),要修的是上一輪交付後暴露的兩件事,兩者同一個根——
`MetaOverride` 是節層 meta 區塊的**唯一**管道,而它只涵蓋 `Meta` 的十三個欄位:

1. **G1(契約變更)**:`NewSection` 只有 `nsMeta :: MetaOverride`,寫不出 asset 的 `sha256` /
   `entry` / `ext` / `meta` / `license` / `author`,也寫不出 license 的八個授權維度——`appendSection`
   因此**產不出能通過 `toPack` / `toLicenses` 驗證的完整新節**,契約 E 的 `createPackFile` /
   `addSection` 連帶做不下去。裁決:`NewSection` 的 payload 對節點種類做 sum。
2. **G2(已重現的資料遺失缺陷)**:`updateSection` 用 `renderMetaBlock` **整塊重寫** meta 區塊,而
   `renderMetaBlock` 只認得 `MetaOverride` 的欄位(`field` 的 catch-all 是 `_ -> []`)。對 `pack.md`
   的 asset 節做**任何**一次 `updateSection`,`sha256` / `entry` 等行會**靜默消失**。編排者已在 GHCi
   對 `c9f6fe4` 的程式碼重現:一個含 `sha256: deadbeef1234` / `entry: PNG/a.png` 的 asset 節,呼叫
   `updateSection aid (\o -> o { moSummary = Just "after" })` 之後那兩行不見了。依 ADR-013,`pack.md`
   是素材中繼資料的真相,這是**永久資料破壞**。缺陷能帶著通過 239 個測試,是因為 `md/test/` 沒有任何
   測試把 `updateSection` 與 `sha256` 放在一起。

解法是同一個:把 meta 區塊在型別上**切成兩半**——`MetaOverride` 那一半(鍵落在 `metaFieldOrder` 裡)
與型別專屬那一半(`MetaExtras`,其餘的頂層條目)。`renderMetaBlock` 必須同時吃兩半,少一半在型別上
就寫不出來;`updateSection` 只讓呼叫端碰前一半,後一半以原始行逐字帶過去。

### 2026-08-25 追加:`insertSection`(F008 假設 A5 的裁決)

本輪之後 `Aapms.Md.Render` 只剩 `appendSection`(追加在整份文件末尾),F004 當初移除了舊的
`insertSection`。ADR-009 說 Level 檔的樹狀結構**就是**標題階層,所以「只能追加」等價於
「在第三章第二節底下再加一個場景」做不到——契約 E 的 `addSection` 有 `SectionPlacement = AtEnd |
UnderParent Id`,`UnderParent` 那一支在 md 這一層沒有對應的函式可呼叫,F008 因此撞牆。

開發者裁決:現在就補上。契約 D 已回寫

```haskell
-- 插在指定父節點的子樹之後(= 成為它的最後一個子節點);nsLevel 必須等於父節點的 secLevel + 1
insertSection :: Id -> NewSection -> Document -> Either MdError Document
```

`appendSection` **不動**——兩者是同一個插入邏輯的兩個特化(「插在檔尾」與「插在某棵子樹之後」),
但「1,693 節的文件末尾追加一節,前面 1,693 節位元組不變」這條驗收標準直接掛在 `appendSection` 上,
把它改寫成 `insertSection` 的一個 wrapper 會讓那條標準多繞一層才驗得到。

同一次閘門另外裁決了三條假設(A8 / A9 / A10,見「已裁決紀錄」),其中 A8 帶來本輪**唯一的型別變更**:
`MdErrorKind` 追加 `HeadingTooDeep Int Int`。它擋的是「父節點已經在第 6 級,底下加不了子節點」——
Level 的章節樹夠深就會撞到,是真實的作者情境而不是程式 bug,所以不與 `HeadingSkip`(呼叫端把
`nsLevel` 算錯)共用一個建構子。

## 對應的 Level 2 契約

- **契約 D(`aapms-md`)全部**:`DocKind` / `Document` / `parseDocument` / `docKind` /
  `toTopic` / `toLevel` / `toPack` / `toLicenses` / `renderDocument` / `updateFrontmatter` /
  `overrideAt` / `updateSection` / `updateSectionBody` / `appendSection` / `insertSection` /
  `removeSection` / `newDocument`,以及 2026-08-24 回寫的 `NewSection` / `NewSectionPayload` /
  `NewAsset` / `NewLicense` / `NewNode`(`insertSection` 是 2026-08-25 回寫的)
- **「模組間公開介面」的 `aapms-md` ↔ `aapms-core`**(含 `MetaOverride` 這個 md 與 store 共用的
  「只改部分欄位」DTO)
- **契約 G 的 `MdError`**(2026-08-25 裁決 A8:`MdErrorKind` 追加 `HeadingTooDeep`,契約 G 的錯誤
  清單要跟著補);資料流管線「讀取」的 `parseDocument → docKind → to*` 一段與「寫入」的
  「aapms-md 寫回」一段;design.md 的**「節層繼承規則」表格**

**超出契約 D 逐字清單的部分**(`MetaExtras` / `extrasOf` / `extrasAt` / `mergeExtras` /
`updateSectionExtras` / `payloadOverride` / `payloadExtras`):見「待確認假設」A1,需要編排者把契約 D
補齊。不動契約 A / B / C / E / F。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `NewSection` | 修改 | `{ nsId :: Id, nsLevel :: Int, nsTitle :: Text, nsBody :: Text, nsPayload :: NewSectionPayload }` | 一個待寫入的新節有哪些欄位(`nsMeta` 拆進 payload) |
| `NewSectionPayload` | 新增 | `NSFragment MetaOverride \| NSAsset MetaOverride NewAsset \| NSLicense MetaOverride NewLicense \| NSNode MetaOverride NewNode`(封閉 sum) | 四種節點各自需要哪些欄位才寫得完整 |
| `NewAsset` | 新增 | `{ naName :: Maybe LogicalName, naSha256 :: Sha256, naEntry :: Text, naExt :: Maybe Text, naKindMeta :: Value, naLicense :: Maybe Ref, naAuthor :: Maybe Text }` | asset 的節層專屬欄位清單與必填/選填劃分(**讀寫共用同一份**) |
| `NewLicense` | 新增 | `{ nlcCommercial :: Bool, nlcAttributionRequired :: Bool, nlcCreditText :: Maybe Text, nlcModificationAllowed, nlcRedistributionAllowed, nlcResaleAllowed, nlcNftAllowed :: Maybe Bool, nlcSourceUrl :: Maybe Text }` | 節層授權八維度的清單與必填/選填劃分(讀寫共用同一份) |
| `NewNode` | 新增 | `newtype NewNode = NewNode { nnKind :: NodeKind }` | Level 節點的專屬欄位只有 `kind`(`parent`/`order`/`entities` 由推導而來,不得重複指定) |
| `MetaExtras` | 新增 | `newtype MetaExtras = MetaExtras { extraLines :: [Text] }`,每個元素是**一行、不含行尾** | 一個 meta 區塊裡**不屬於 `Meta`** 的頂層條目的**原始位元組** |
| `AssetFields` | 刪除 | — | 併入 `NewAsset`(原本只有讀方向認得這組欄位,寫方向沒有——這正是 G1/G2 的根) |
| `LicenseFields` | 刪除 | — | 併入 `NewLicense` |
| `MetaOverride` | **不動** | `Aapms.Md.Inherit:45-59`,十三個 `Maybe` 欄位 | 節層對 `Meta` 欄位的覆寫。**刻意不擴充**:它是 md 與 store 共用的節層繼承 DTO,污染它會動到 ADR-010 位元組保留所依賴的繼承規則 |
| `DocKind` / `Document` / `Section` / `MdError` | 不動 | 同上一輪 | 檔案身分、原始切片、錯誤與行號 |
| `MdErrorKind` | **追加一個建構子** | `HeadingTooDeep Int Int`(父節點層級, 算出來的層級),`md/src/Aapms/Md/Error.hs:59`(`renderMdErrorKind` 的分支在 `md/src/Aapms/Md/Error.hs:100`,本體 `undefined`,訊息原文見 L39 / E21) | 「插入的節算出來的標題層級超過 Markdown 的六級上限」。既有 15 個建構子與它們的 `renderMdErrorKind` 訊息**一個字都沒動**,追加後 `MdErrorKind` 共 **16** 個(2026-08-25 裁決 A8;計數更正見 spec-gaps G6) |

**「頂層條目」的定義**(`MetaExtras` 與 `extrasOf` 共用,是本 feature 唯一的新語法規則):meta 區塊
fence 之間的行,依序切成條目;一個條目 = **第 0 欄起以 `<鍵>:` 開頭的那一行** + 其後所有「縮排行或
空行」。條目的**鍵**是該行 `:` 之前的文字。鍵落在 `metaFieldOrder` 裡的是 `Meta` 欄位,其餘是型別
專屬條目。`meta:` 這種區塊風格的巢狀值因此整段留得住。

## 介面

### 契約 D:讀取方向

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `parseDocument :: Text -> Either MdError Document` | 把一份 Markdown 文字切成保留原始位元組的分節結構,並判定它是四種文件的哪一種 | `md/src/Aapms/Md/Parse.hs:52` |
| `docKind :: Document -> DocKind` | 回報這份文件的身分 | `md/src/Aapms/Md/Document.hs:81` |
| `toTopic :: Document -> Either MdError (Entity, [Entity])` | 把主題檔解讀成主體與它的片段 | `md/src/Aapms/Md/Parse.hs:124` |
| `toLevel :: Document -> Either MdError (Level, [Node])` | 把 Level 檔解讀成 Level 與它的節點 | `md/src/Aapms/Md/Parse.hs:140` |
| `toPack :: Document -> Either MdError (Pack, [Asset])` | 把 `pack.md` 解讀成 Pack 與它的素材 | `md/src/Aapms/Md/Parse.hs:224` |
| `toLicenses :: Document -> Either MdError [License]` | 把 `licenses.md` 解讀成一組授權(容器本身不是節點) | `md/src/Aapms/Md/Parse.hs:279` |

### 契約 D:寫回方向

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `renderDocument :: Document -> Text` | 把分節結構還原成 Markdown 文字 | `md/src/Aapms/Md/Render.hs:87` |
| `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document` | 改寫檔案層 frontmatter | `md/src/Aapms/Md/Render.hs:436` |
| `overrideAt :: Id -> Document -> Either MdError MetaOverride` | 讀出某節目前的 `Meta` 覆寫 | `md/src/Aapms/Md/Render.hs:115` |
| `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | 改寫某節的 `Meta` 欄位;**該節的型別專屬條目、標題行、正文與其他節皆不動** | `md/src/Aapms/Md/Render.hs:103` |
| `updateSectionBody :: Id -> Text -> Document -> Either MdError Document` | 只換某節的正文 | `md/src/Aapms/Md/Render.hs:353` |
| `appendSection :: NewSection -> Document -> Either MdError Document` | 在文件最後一節之後追加一個新節;沒有節時追加在 preamble 之後 | `md/src/Aapms/Md/Render.hs:321` |
| `insertSection :: Id -> NewSection -> Document -> Either MdError Document` | 在指定父節點的**子樹之後**插入新節(= 成為它的**最後一個**子節點);`nsLevel` 必須等於父節點的 `secLevel + 1`,且不得 > 6 | `md/src/Aapms/Md/Render.hs:482` |
| `removeSection :: Id -> Document -> Either MdError Document` | 刪掉某節連同它的 meta 區塊與正文 | `md/src/Aapms/Md/Render.hs:343` |
| `newDocument :: DocKind -> Meta -> Text -> Document` | 從零產生一份只有 frontmatter 與正文、還沒有任何節的文件 | `md/src/Aapms/Md/Render.hs:458` |

### 契約 D 之外(本次新增,待編排者補進契約 D,見 A1)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `newtype MetaExtras = MetaExtras { extraLines :: [Text] }` | 一組型別專屬條目的原始行 | `md/src/Aapms/Md/Render.hs:145` |
| `extrasOf :: Section -> MetaExtras` | 取出某節 meta 區塊裡的型別專屬條目 | `md/src/Aapms/Md/Render.hs:155` |
| `extrasAt :: Id -> Document -> Either MdError MetaExtras` | 同上,以節 id 定位(與 `overrideAt` 對稱) | `md/src/Aapms/Md/Render.hs:160` |
| `mergeExtras :: MetaExtras -> MetaExtras -> MetaExtras` | 合併兩組專屬條目,同鍵時**第一個參數贏** | `md/src/Aapms/Md/Render.hs:168` |
| `updateSectionExtras :: Id -> (MetaExtras -> MetaExtras) -> Document -> Either MdError Document` | 改寫某節的型別專屬條目;**該節的 `Meta` 欄位、標題行、正文與其他節皆不動** | `md/src/Aapms/Md/Render.hs:177` |
| `payloadOverride :: NewSectionPayload -> MetaOverride` | 取出 payload 的 `Meta` 那一半 | `md/src/Aapms/Md/Render.hs:291` |
| `payloadExtras :: NewSectionPayload -> MetaExtras` | 取出 payload 的型別專屬那一半 | `md/src/Aapms/Md/Render.hs:306` |
| `renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text` | 把兩半序列化成一個完整的 ` ```meta ` 區塊 | `md/src/Aapms/Md/Render.hs:564` |
| `mkSection :: LineEnding -> Int -> Id -> Text -> Maybe NewSectionPayload -> Text -> Section` | 由零件組一個新的節 | `md/src/Aapms/Md/Render.hs:419` |

### 既有匯出(本次未改動,登記以求介面表完整)

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `renderSection :: Section -> Text` | 把一個節還原成 Markdown 文字 | `md/src/Aapms/Md/Render.hs:91` |
| `renameSection :: Id -> Text -> Document -> Either MdError Document` | 只換某節標題行的標題文字(層級與 `{#id}` 保留) | `md/src/Aapms/Md/Render.hs:376` |
| `replacePreamble :: Text -> Document -> Document` | 只換 frontmatter 與第一個節之間的正文 | `md/src/Aapms/Md/Render.hs:399` |
| `renderFrontmatter :: Meta -> LineEnding -> Text` | 把完整 `Meta` 序列化成 frontmatter 內容(不含 `---` 界線) | `md/src/Aapms/Md/Render.hs:505` |
| `frontmatterFieldOrder :: [Text]` | frontmatter 的固定欄位順序 | `md/src/Aapms/Md/Render.hs:476` |
| `metaFieldOrder :: [Text]` | ` ```meta ` 區塊裡屬於 `Meta` 的那一半的固定欄位順序,同時是「哪些鍵不是型別專屬條目」的唯一判準 | `md/src/Aapms/Md/Render.hs:538` |

## Laws(行為性質)

以下 `d` 一律指任一由 `parseDocument` 成功解析出的 `Document`,`i` 指 `d` 裡任一節的 `secId`,
`f :: MetaOverride -> MetaOverride`、`g :: MetaExtras -> MetaExtras` 為任意函數。

**ADR-010 位元組保留**

- **L1**:對所有能被 `parseDocument` 成功解析的文字 `t`,`renderDocument <$> parseDocument t == Right t`。
- **L2**:對所有 `d`、`i`、`f`,若 `updateSection i f d == Right d'`,則對 `d'` 中每一個 `secId /= i`
  的節,`renderSection` 的結果與 `d` 中同 id 的節逐位元組相同;`i` 那一節的 `secHeadingRaw` 與
  `secBodyRaw` 也逐位元組相同。
- **L3**:對所有 `d`、`i`、`g`,`updateSectionExtras i g d` 滿足與 L2 完全相同的保留條件。

**G2:型別專屬條目的保留(本次重跑的核心)**

- **L4**:對所有 `d`、`i`、`f`,若 `updateSection i f d == Right d'`,則
  `extrasAt i d' == extrasAt i d`(行的內容逐字相同,順序相同,不多不少)。
- **L5**:對所有能被 `toPack` 成功解析的 `d`、任一 `i`、任一 `f`,令
  `Right d' = updateSection i f d`、`Right (_, as) = toPack d`、
  `Right (_, as') = (parseDocument (renderDocument d') >>= toPack)`,則 `as` 與 `as'` 逐項的
  `astSha256` / `astEntry` / `astExt` / `astName` / `astKindMeta` / `astLicense` / `astAuthor`
  對應相等。(這是已重現缺陷的直接否證形式。)
- **L6**:對所有能被 `toLicenses` 成功解析的 `d`、任一 `i`、任一 `f`,`updateSection` 再
  `renderDocument` → `parseDocument` → `toLicenses` 之後,每個 `License` 的八個維度
  (`licCommercial` / `licAttributionRequired` / `licCreditText` / `licModificationAllowed` /
  `licRedistributionAllowed` / `licResaleAllowed` / `licNftAllowed` / `licSourceUrl`)與變換前相等。
- **L7**:對所有節 `s`,`extraLines (extrasOf s)` 恰好是 `s` 的 meta 區塊中**鍵不在 `metaFieldOrder`**
  的頂層條目的所有行,逐字相同、相對順序與原文相同;且其中不含任何鍵在 `metaFieldOrder` 中的條目。
- **L8**:對所有 `d`、`i`,`updateSection i id d >>= updateSection i id` 與 `updateSection i id d`
  產生的 `renderDocument` 結果相同(冪等)。

**meta 區塊的序列化**

- **L9**:對所有 `ov`、`ex`、`le`,`renderMetaBlock ov ex le` 的行序列 =
  `["```meta"] ++ M ++ extraLines ex ++ ["```"]`,每行以 `renderLineEnding le` 結尾;其中 `M` 是
  「`ov` 中值為 `Just` 的欄位依 `metaFieldOrder` 的順序各自產生的行」(`Nothing` 的欄位不產生行,
  `moLinks = Just (_:_)` 產生 `links:` 加每個關聯一行)。也就是說:**`extraLines ex` 逐字、逐序、
  原封不動地出現在區塊的最後一段**。(`M` 與 `ex` 的鍵不重複,不是本函式的責任而是它的前提——由
  L7 與 L11 保證所有 `MetaExtras` 的來源都滿足它。)
- **L10**:對所有 `ov`、`le`,`renderMetaBlock ov (MetaExtras []) le` 與上一輪
  `renderMetaBlock ov le` 的輸出逐位元組相同(**回歸 law**:兩半設計不得改變只有 `Meta` 欄位時的排版)。
- **L11**:對所有 `p :: NewSectionPayload`,`extraLines (payloadExtras p)` 中每個條目的鍵都**不在**
  `metaFieldOrder` 裡(兩半的鍵集合不相交)。
- **L12**:對所有 `a`、`b :: MetaExtras`,`mergeExtras a b` 的鍵集合 = `a` 的鍵 ∪ `b` 的鍵;同鍵的
  條目逐字取自 `a`;`b` 中鍵未被覆蓋的條目逐字保留;順序是「`a` 的條目依原序在前,`b` 剩下的依原序在後」。

**G1:payload 寫得出完整的新節**

- **L13**:對所有 `pack.md` 的 `d`、任一未撞號的 `PAst` 前綴 `i`、任一 `NewAsset na`、任一含
  `moType = Just t` 的 `ov`,令
  `Right d' = appendSection (NewSection i 2 title body (NSAsset ov na)) d`,則
  `parseDocument (renderDocument d') >>= toPack` 成功,且新增那一筆 `Asset` 滿足
  `astSha256 = naSha256 na`、`astEntry = naEntry na`、`astExt = naExt na`、`astName = naName na`、
  `astKindMeta = naKindMeta na`、`astLicense = naLicense na`、`astAuthor = naAuthor na`。
- **L14**:同 L13 的形式,`NSLicense ov nl` 追加進 `licenses.md` 之後 `toLicenses` 解回的新 `License`,
  八個維度逐一等於 `nl` 的對應欄位。
- **L15**:同 L13 的形式,`NSNode ov (NewNode k)` 追加進 Level 檔之後 `toLevel` 解回的新 `Node`
  滿足 `nodKind == k`,**不論 `moKind ov` 是什麼**(`NewNode` 是 `kind` 的唯一真相來源)。
- **L16**:對所有 `p`,`moKind (payloadOverride p)` 在 `p` 為 `NSNode _ n` 時等於 `Just (nnKind n)`,
  其餘三個建構子時等於該建構子所帶 `MetaOverride` 的 `moKind`;`payloadOverride` 不改動其他十二個欄位。

**追加與刪除**

- **L17**:對所有 `d` 與 `nsId` 未出現在 `d` 的 `NewSection ns`,`appendSection ns d == Right d'` 且
  `d'` 中原有每一節的 `secHeadingRaw` 與 `secMetaRaw` 逐位元組不變;`secBodyRaw` 僅最後一節可能在
  **尾端**補上行尾/空行,其餘節逐位元組不變;新節排在最後。
- **L18**:對所有 `d` 與 `nsId ns` 已存在於 `d` 的 `ns`,
  `appendSection ns d == Left (mdError 1 (DuplicateSectionId (nsId ns)))`。
- **L19**:對所有 `d`、`i`,`removeSection i d == Right d'` 時 `sectionIds d'` = `sectionIds d` 去掉 `i`,
  且 `d'` 中每一節的 `renderSection` 與 `d` 中同 id 的節逐位元組相同;`i` 不存在時回
  `Left (mdError 1 (UnknownSectionId i))`。
- **L20**:對所有 `d`、`i`、`body`,`updateSectionBody i body d == Right d'` 時,`d'` 中 `i` 那一節的
  `secHeadingRaw` 與 `secMetaRaw` 逐位元組不變,其他節的 `renderSection` 逐位元組不變。
- **L21**:對所有 `le`、`level`、`i`、`title`、`p`、`body`,
  `mkSection le level i title (Just p) body` 產生的 `Section` 的 `secMetaRaw` 等於
  `renderLineEnding le <> renderMetaBlock (payloadOverride p) (payloadExtras p) le`;
  `Nothing` 時 `secMetaRaw == Nothing`。

**解析與繼承**

- **L22**:對所有能解析的 `t`,`docKind` 只由檔案層 `type` 決定:`"level"` → `LevelDoc`、
  `"asset-pack"` → `PackDoc`、`"asset-license"` → `LicenseDoc`、其餘(含缺 `type`、`type` 不是字串)
  一律 `TopicDoc`。
- **L23**(節層繼承規則,design.md 表格):對所有檔案層 `Meta` `front` 與任一節,解出的節 `Meta` 滿足
  `metaVault` / `metaStatus` / `metaTimeline` / `metaSource` / `metaCreated` / `metaUpdated` 在節層未寫
  時等於 `front` 的對應值;`metaTags == nub (metaTags front ++ 節層 tags)`;`metaSummary` /
  `metaAliases` / `metaLinks` 節層未寫時為空、`metaRevision` 節層未寫時為 `Revision 1`(皆不繼承);
  `metaId` / `metaTitle` 取自節本身。
- **L24**:對所有 `pack.md` 的節,節層未寫 `type` 時 `toPack` 回
  `Left (MdError _ (SectionFieldMissing secId "type"))`;對主題檔 / Level 檔 / `licenses.md` 的節,
  節層未寫 `type` 時繼承檔案層的 `metaType`。
- **L25**:對所有 `d`、`k`、`m`、`b`,`docKind (newDocument k m b) == k`;且
  `parseDocument (renderDocument (newDocument k m b))` 成功。
- **L26**:對所有 `d` 與任一 `f :: Meta -> Meta`,`updateFrontmatter f d == Right d'` 時 `d'` 的
  `docPreamble` 與每一節的 `renderSection` 逐位元組不變。
- **L27**:對所有 `d`、`i`,`overrideAt i d` 與「`d` 中 `i` 那一節的 meta 區塊解出的 `MetaOverride`」
  相同;節沒有 meta 區塊時為 `emptyOverride`;節不存在時回 `Left (mdError 1 (UnknownSectionId i))`。

**在父節點底下插入(2026-08-25 裁決)**

以下這一組的共同記號:`p` 是 `d` 中任一節,`pid = secId p`,`j` 是 `p` 在 `docSections d` 中的索引
(0 起算)。`p` 的**子樹**定義為 `subtree p d = takeWhile ((> secLevel p) . secLevel) (drop (j + 1)
(docSections d))`——`p` 之後、`secLevel` 一路都大於 `secLevel p` 的**最長前綴**;**插入索引**
`k = j + 1 + length (subtree p d)`。「合法插入」指同時滿足三個前置條件:`pid` 出現在 `sectionIds d`、
`nsId ns` **未**出現在 `sectionIds d`、`nsLevel ns == secLevel p + 1` 且 `nsLevel ns <= 6`。

- **L32**(插入位置):對所有 `d`、`p`、合法插入的 `ns`,`insertSection pid ns d == Right d'` 且
  `sectionIds d'` 恰好是 `sectionIds d` 在索引 `k` 處插入 `nsId ns`(其餘元素順序不變)。特別地,
  `p` 至少有一個子節點時,`d'` 中緊接在新節**之前**的那一節**不是** `p`,而是 `subtree p d` 的最後
  一個節——「插在父節點正後方」會變成插在既有子節點**之前**,那不是本函式的語意。
- **L33**(ADR-010 位元組保留):同 L32 的前提,`d'` 中每一個 `secId /= nsId ns` 的節,其
  `secHeadingRaw` 與 `secMetaRaw` 與 `d` 中同 id 的節**逐位元組相同**;`secBodyRaw` 也逐位元組相同,
  **唯一例外**是索引 `k - 1` 的那一節(即 `subtree p d` 的最後一節,子樹為空時就是 `p` 自己)——而
  且**只有當它還沒有以空行結尾時**,才在**尾端**補齊。規則與 `appendSection` 共用同一個
  `blankTail`(`md/src/Aapms/Md/Render.hs:438`),而 `blankTail` 是**冪等**的:原文已以兩個行尾結尾
  時**原樣回傳**、以一個行尾結尾時補一個、空字串補一個、其餘補兩個。所以插入點前一節的位元組
  **不是必然會動**——絕大多數格式正常的檔案上它一個位元組都不動。`docFrontRaw` 與 `docPreamble`
  一律逐位元組不變。
- **L34**(新節的內容):同 L32 的前提,`d'` 中 `nsId ns` 那一節的 `secHeadingRaw` / `secMetaRaw` /
  `secLevel` / `secTitle` / `secId` 與
  `mkSection (docEnding d) (nsLevel ns) (nsId ns) (nsTitle ns) (Just (nsPayload ns)) (nsBody ns)`
  相同(新節的 meta 區塊因此同樣由 `payloadOverride` 與 `payloadExtras` 兩半組出來);`secBodyRaw`
  在新節**不是** `d'` 的最後一節時等於 `blankTail (docEnding d) (nsBody ns)`——同樣是冪等的,
  `nsBody ns` 已以空行結尾時原樣採用;新節是最後一節時等於 `nsBody ns`。
- **L35**(可解析):同 L32 的前提,若 `parseDocument (renderDocument d)` 成功,則
  `parseDocument (renderDocument d')` 也成功,解出的 `Document` 的 `sectionIds` 與 `d'` 相同,且
  `nsId ns` 那一節解回來的 `secLevel == nsLevel ns`、`secTitle == nsTitle ns`、`secId == nsId ns`。
  依 `docKind d` 對應的 `to*`(`toTopic` / `toLevel` / `toPack` / `toLicenses`)在變換前成功時,
  變換後也成功,且新節點的 `metaId` 等於 `nsId ns`。
- **L36**(樹合法性與父子關係):對所有 `toLevel` 成功的 Level 檔 `d`、其中任一節 `p`、任一合法插入
  且 `nsPayload ns == NSNode ov (NewNode k')` 的 `ns`,令 `Right d' = insertSection pid ns d`、
  `Right (lvl, ns0) = toLevel d`、`Right (lvl', ns1) = (parseDocument (renderDocument d') >>= toLevel)`,
  則:(a) `lvl' == lvl`;(b) `ns1` 中 `metaId . nodMeta == nsId ns` 的那一個節點滿足
  `nodParent == Just pid`、`nodKind == k'`,且 `nodOrder` 等於「`ns0` 中 `nodParent == Just pid` 的
  節點數 + 1」(= 成為 `p` 的最後一個子節點);(c) `ns0` 的每一個節點在 `ns1` 中都有對應且
  `nodMeta` / `nodParent` / `nodOrder` / `nodKind` / `nodEntities` 逐一相等(插入不重編任何既有節點的
  `order`);(d) `Aapms.Core.Tree.buildTree lvl' ns1` 成功。
- **L37**(退化為 `appendSection`):對所有 `d` 與 `d` 的**最後一節** `p`,任一合法插入的 `ns`,
  `renderDocument <$> insertSection pid ns d == renderDocument <$> appendSection ns d`。
  (父節點是最後一節時它的子樹必為空,插入索引就是檔尾。)
- **L38**(錯誤路徑,含檢查順序):對所有 `d`、`pid`、`ns`,`insertSection pid ns d` 依**下列順序**
  取第一個成立的分支,四者都不成立才回 `Right`(`p` 指 `pid` 那一節):
  1. `pid` 不在 `sectionIds d` → `Left (mdError 1 (UnknownSectionId pid))`
  2. `nsId ns` 已在 `sectionIds d` → `Left (mdError 1 (DuplicateSectionId (nsId ns)))`
  3. `nsLevel ns /= secLevel p + 1` → `Left (mdError 1 (HeadingSkip (secLevel p) (nsLevel ns)))`
  4. `nsLevel ns > 6` → `Left (mdError 1 (HeadingTooDeep (secLevel p) (nsLevel ns)))`

  **3 在 4 之前**,所以第 4 條只有在 `nsLevel ns == secLevel p + 1 && nsLevel ns > 6` 時才觸發,
  也就是**父節點恰好在第 6 級**——那正是它要表達的事(父節點已經到底,底下加不了子節點)。
  兩者拆開的理由(2026-08-25 裁決 A8):第 3 條在正常流程永遠不該觸發(契約 E 明訂 `nsLevel` 由
  store 的 `headingDepthFor` 推導、不由呼叫端給),它觸發就是程式 bug,不需要專用的使用者訊息;
  第 4 條是**真實的作者情境**——Level 的章節樹夠深就會撞到,而且有明確的下一步可以講。
  非擋不可的理由:層級 > 6 的標題 `Aapms.Md.Lexer.parseHeadingLine` 根本不當標題看
  (`md/src/Aapms/Md/Lexer.hs:99`),插下去會被靜默併進前一節的正文——擋在這裡比讓資料悄悄變形好。
- **L39**(`HeadingTooDeep` 的訊息):對所有 `parent`、`cur`,
  `renderMdError (mdError l (HeadingTooDeep parent cur))` 的結果以 `第 <l> 行:` 開頭,且訊息中
  同時出現 `T.replicate cur "#"`、`T.replicate parent "#"` 與**下一步的指引文字**
  「請改插到較淺的父節點底下,或先把這條分支中間的層級壓平」(契約 G:每個建構子的 `render*`
  訊息要說出下一步該做什麼)。既有 15 個建構子的訊息**逐字不變**(回歸 law)。

**既有匯出的回歸 law(行為不得改變)**

- **L28**:對所有 `d`、`i`、`title`,`renameSection i title d == Right d'` 時 `d'` 中 `i` 那一節的
  `secMetaRaw` 與 `secBodyRaw` 逐位元組不變、`secId` 不變、`secLevel` 不變、`secTitle == title`,
  其他節的 `renderSection` 逐位元組不變。
- **L29**:對所有 `d`、`body`,`replacePreamble body d` 之後每一節的 `renderSection` 與 `docFrontRaw`
  逐位元組不變,且 `parseDocument (renderDocument (replacePreamble body d))` 成功。
- **L30**:對所有 `m :: Meta`、`le`,`renderFrontmatter m le` 產生的行,其鍵依序恰好是
  `frontmatterFieldOrder`(每個欄位都輸出,`links` 為多行);且
  `decodeFrontmatter (renderFrontmatter m le) == Right m`(往返不失真)。
- **L31**:對所有 `Section` `s`,`renderSection s == secHeadingRaw s <> fromMaybe "" (secMetaRaw s) <> secBodyRaw s`。

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| E1 | `pack.md` 的 asset 節含 `sha256: deadbeef1234` 與 `entry: PNG/a.png`,呼叫 `updateSection aid (\o -> o { moSummary = Just "after" })`,再 `renderDocument` | 輸出文字仍含 `sha256: deadbeef1234` 與 `entry: PNG/a.png` 兩行(逐字);`toPack` 解回的 `astSha256` / `astEntry` 不變;`summary` 改成 `after` | **已重現缺陷的回歸例**(G2) |
| E2 | 只有 frontmatter、沒有任何節的 `pack.md`,`appendSection (NewSection ast-0001 2 "圖示" "" (NSAsset ov na)) d` | 產生一個節;`renderDocument` → `parseDocument` → `toPack` 成功且 `[Asset]` 長度為 1 | 空文件 / 單一元素 |
| E3 | `pack.md` 的節沒有寫 `type`,呼叫 `toPack` | `Left (MdError line (SectionFieldMissing secId "type"))` | pack.md 的節層 `type` 不繼承 |
| E4 | `licenses.md` 的節沒有寫 `commercial`,呼叫 `toLicenses` | `Left (MdError line (SectionFieldMissing secId "commercial"))` | 八維度中兩個必填的例外路徑 |
| E5 | 1,693 節的合成 `pack.md`,`appendSection` 追加第 1,694 節 | 前 1,693 節的 `renderSection` 逐位元組不變(僅第 1,693 節的 `secBodyRaw` 尾端可能補空行);新節在最後;結果能再 `parseDocument` + `toPack` | 極值(D4:測試內生成器合成,不需要真實大檔) |
| E6 | 節的 meta 區塊含註冊表宣告的自訂欄位 `battle_power: 9000`,呼叫 `updateSection i (\o -> o { moStatus = Just Canon })` | `battle_power: 9000` 逐字保留 | **未知欄位**也要保留(不只型別專屬那幾個) |
| E7 | asset 節,呼叫 `updateSectionExtras aid (mergeExtras (payloadExtras (NSAsset emptyOverride na')))`,其中 `na'` 只改 `naLicense` | `license` 那一行換成新值;`sha256` / `entry` / `meta` 逐字不變;`overrideAt aid` 的結果與呼叫前相同;正文與標題行逐位元組不變 | 型別專屬半邊的編輯路徑(契約 E 的 `writeAssetFields` 靠它) |
| E8 | 節的 meta 區塊含區塊風格的巢狀值 `meta:` + 兩行縮排的 `width:` / `height:`,呼叫任一 `updateSection` | 三行整段逐字保留、順序不變 | 多行頂層條目 |
| E9 | `appendSection` 的 `nsId` 與既有節撞號 | `Left (MdError 1 (DuplicateSectionId nsId))` | 例外路徑 |
| E10 | 五份 frontmatter:`type: level` / `type: asset-pack` / `type: asset-license` / `type: character` / 完全沒有 `type` | `docKind` 依序為 `LevelDoc` / `PackDoc` / `LicenseDoc` / `TopicDoc` / `TopicDoc` | 四種身分 + 未知 fallback |
| E11 | Level 檔:`## 第三章 {#nod-0003}` 底下依序有 `### 第一節 {#nod-0010}`、`### 第二節 {#nod-0011}`,而 `nod-0011` 底下還有 `#### 場景 A {#nod-0020}`;檔尾另有 `## 第四章 {#nod-0004}`。對 `nod-0003` 呼叫 `insertSection` 插入 `nsLevel = 3` 的 `nod-0030`(payload `NSNode ov (NewNode KScene)`) | `sectionIds` = `[…, nod-0003, nod-0010, nod-0011, nod-0020, nod-0030, nod-0004]`——新節排在 `nod-0020` **之後**、`nod-0004` **之前**;`toLevel` 解回的 `nod-0030` 的 `nodParent == Just nod-0003`、`nodOrder == 3`、`nodKind == KScene`;`nod-0010` / `nod-0011` / `nod-0020` / `nod-0004` 的 `nodParent` 與 `nodOrder` 不變 | **「子樹之後」而非「父節點正後方」**(本次裁決的核心) |
| E12 | 同 E11 的檔(`nod-0020` 的正文**已經**以空行結尾,是格式正常的檔案),插入之後逐節比對位元組 | **每一節**(含 `nod-0020` 自己)的 `renderSection` 逐位元組不變;`docFrontRaw` / `docPreamble` 不變。再取一份 `nod-0020` 正文**沒有**以空行結尾的變體,則只有 `nod-0020` 的 `secBodyRaw` 尾端補齊,其餘仍逐位元組不變 | ADR-010 位元組保留;`blankTail` 冪等,格式正常的檔案上插入點也一個位元組都不動 |
| E13 | 1,693 節的合成 Level 檔,對**中間**某個有子樹的節呼叫 `insertSection` | 除插入點前一節的正文尾端外,其餘 1,692 節的 `renderSection` 逐位元組不變;結果能再 `parseDocument` + `toLevel`,產出的 `[Node]` 餵給 `Aapms.Core.Tree.buildTree` 成功 | 極值(與 E5 對稱,測試內生成器合成) |
| E14 | 父節點是文件的**最後一節** `p`(level 2),`nsLevel = 3` | `renderDocument` 的結果與同一個 `ns` 走 `appendSection` **逐位元組相同** | 退化為 `appendSection`(L37) |
| E15 | 新節插在中間,`nsBody = "內文"`(不以行尾結尾) | 下一節的標題**不會**黏在 `內文` 後面;`renderDocument` → `parseDocument` 解回的節數 = 原節數 + 1,且新節的 `secTitle` 正確 | 新節這一側的行尾補齊(L34) |
| E16 | 對不存在的父節點 id `nod-9999` 呼叫 `insertSection` | `Left (MdError 1 (UnknownSectionId nod-9999))` | 例外路徑:父節點不存在 |
| E17 | 父節點是 `## {#nod-0003}`(level 2),傳入 `nsLevel = 4` | `Left (MdError 1 (HeadingSkip 2 4))` | 例外路徑:`nsLevel /= secLevel(父) + 1` |
| E18 | 父節點是 `###### {#nod-0006}`(level 6),傳入 `nsLevel = 7`(第 3 條檢查 `7 == 6 + 1` 會過) | `Left (MdError 1 (HeadingTooDeep 6 7))`;文件未產生 | 例外路徑:算出來的層級 > 6(2026-08-25 新增的建構子) |
| E19 | 父節點存在,但 `nsId` 與既有節撞號**且** `nsLevel` 也錯(例如父在 level 2、`nsLevel = 5`) | `Left (MdError 1 (DuplicateSectionId nsId))`——撞號優先於層級 | 多重錯誤時的檢查順序(L38) |
| E20 | 父節點是 `###### {#nod-0006}`(level 6),傳入 `nsLevel = 9`(第 3 條檢查就不過) | `Left (MdError 1 (HeadingSkip 6 9))`,**不是** `HeadingTooDeep` | 第 3 條先於第 4 條:呼叫端算錯 `nsLevel` 與「父節點已到底」是兩件事 |
| E21 | `renderMdError (MdError 12 (HeadingTooDeep 6 7))` | `第 12 行:標題層級 #######(第 7 級)超過 Markdown 的六級上限,父節點 ###### 已經在第 6 級,底下加不了子節點了:請改插到較淺的父節點底下,或先把這條分支中間的層級壓平` | 契約 G:訊息要說出**下一步**(L39) |
| E22 | 既有 15 個 `MdErrorKind` 建構子各取一個代表值,呼叫 `renderMdError` | 訊息與上一輪**逐字相同** | **回歸例**:追加建構子不得動到既有訊息 |

## 依賴

`depends-on: [F001, F002]`(維持不變)。

- **F001**:直接的程式碼相依。下表每一列都是 `aapms-core` 在 F001 定案的型別與編碼規則,本 feature
  的每一個函式都消費它們;`NewAsset` / `NewLicense` 的欄位形狀更是逐欄照抄 `Asset` / `License`。
- **F002**:**沒有直接的函式呼叫**(`aapms-md` 不 import `aapms-types`,`docKind` 只比對字面
  `type` 字串,不查 `TypeRegistry`),因此不出現在下表——該表只列有實際簽名可查證的呼叫。相依是
  「共用資料結構」性質的:`docKind` 硬編碼的三個字面值(`level` / `asset-pack` / `asset-license`)
  與 F002 驗收標準「這三個保留鍵出現在註冊表是載入錯誤」是**同一份保留鍵清單的兩處體現**,F002 若
  增減保留鍵,`docKind` 的分類規則(L22)要跟著改。另外「meta 區塊的未知鍵一律保留」(L7)這條規則
  存在的理由,正是 F002 的註冊表可以宣告任意欄位。
- **不依賴 F003**(`Manifest`):`aapms-md` 不產生、不讀 manifest。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Meta = Meta { metaId :: Id, metaVault :: VaultId, metaType :: TypeKey, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Maybe Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Revision, metaCreated :: Day, metaUpdated :: Day }` | `core/src/Aapms/Core/Meta.hs:123-138` | F001 | `MetaOverride` / `inheritMeta` / frontmatter 序列化的基礎型別 |
| `newtype TypeKey = TypeKey Text`、`newtype Revision = Revision Int`、`data Status`、`data Source`、`data Timeline`(建構子皆 export) | `core/src/Aapms/Core/Meta.hs:45-116` | F001 | `MetaOverride` 各欄位的型別;`renderMetaBlock` 序列化前解開 newtype |
| `newtype Id`(不透明)、`renderId :: Id -> Text`、`idPrefix :: Id -> IdPrefix`、`parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/Aapms/Core/Id.hs:86-141` | F001 | 節標題 `{#id}`、`secId`、`nsId` |
| `newtype VaultId = VaultId Text`、`data Ref = Ref { refVault :: Maybe VaultId, refId :: Id }`、`renderRef :: Ref -> Text`、`data IdPrefix = PEnt \| PAst \| PPck \| PLic \| PLvl \| PNod \| PVlt \| PPrj`、`renderIdPrefix` | `core/src/Aapms/Core/Id.hs:46-182` | F001 | `moVault`、`naLicense`、`prefixErrorsE` 對 `PAst` / `PLic` 的驗證 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }`、`data LinkKind`、`renderLinkKind :: LinkKind -> Text` | `core/src/Aapms/Core/Link.hs:28-87` | F001 | `moLinks`、`linkLine` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/Aapms/Core/Entity.hs:12-17` | F001 | `toTopic` 的回傳型別 |
| `data Level = Level { lvlMeta :: Meta, lvlRoot :: Id }`、`data Node = Node { nodMeta :: Meta, nodLevel :: Id, nodParent :: Maybe Id, nodOrder :: Int, nodKind :: NodeKind, nodEntities :: [Ref] }`、`data NodeKind = KScene \| KCast \| KCamera \| KInteraction \| KDialogue \| KBranch`、`renderNodeKind :: NodeKind -> Text` | `core/src/Aapms/Core/Level.hs:19-71` | F001 | `toLevel` 的回傳型別、`NewNode`、`moKind` 的序列化 |
| `data Asset = Asset { astMeta :: Meta, astName :: Maybe LogicalName, astSha256 :: Sha256, astEntry :: Text, astExt :: Maybe Text, astKindMeta :: Value, astLicense :: Maybe Ref, astAuthor :: Maybe Text, astBody :: Text }`、`newtype Sha256 = Sha256 Text`、`newtype LogicalName = LogicalName Text` | `core/src/Aapms/Core/Asset.hs:17-46` | F001 | `toPack` 的回傳型別;**`NewAsset` 的欄位形狀逐欄照抄它**(扣掉 `astMeta` 與 `astBody`),`astSha256` / `astEntry` 非 `Maybe` 決定了 `naSha256` / `naEntry` 也非 `Maybe` |
| `data Pack = Pack { pckMeta :: Meta, pckVendor :: Maybe Text, pckArchive :: Maybe FilePath, pckSha256 :: Maybe Sha256, pckLicense :: Maybe Ref, pckAuthor :: Maybe Author, pckSourceUrl :: Maybe Text, pckAiDisclosure :: AiDisclosure, pckBody :: Text }` | `core/src/Aapms/Core/Pack.hs:19-47` | F001 | `toPack` 的檔案層回傳型別 |
| `data License = License { licMeta :: Meta, licCommercial :: Bool, licAttributionRequired :: Bool, licCreditText :: Maybe Text, licModificationAllowed :: Maybe Bool, licRedistributionAllowed :: Maybe Bool, licResaleAllowed :: Maybe Bool, licNftAllowed :: Maybe Bool, licSourceUrl :: Maybe Text, licFullText :: Maybe Text }` | `core/src/Aapms/Core/License.hs:13-25` | F001 | `toLicenses` 的回傳型別;**`NewLicense` 的欄位形狀照抄它**(扣掉 `licMeta` 與 `licFullText`) |
| `instance FromJSON Meta` / `Pack` / `Asset` / `License` / `TypeKey` / `VaultId` / `Revision` / `Status` / `Source` / `Timeline` / `Link` / `NodeKind` | `core/src/Aapms/Core/Json.hs:49-322` | F001 | 全系統唯一的 aeson 編碼規則;`NewAsset` / `NewLicense` 的 `FromJSON` 逐欄借用這些實例 |

### 依賴方向

- **依賴誰**:`aapms-md` → `aapms-core`(唯一的套件相依,本次**不新增任何 build-depends**;
  `Data.Aeson` 已是既有相依)
- **誰會依賴它**:`aapms-store`(`Index.hs` / `Query.hs` 走讀取方向,`Create.hs` / `Write.hs` /
  `Node.hs` / `Edit.hs` 走寫回方向)。`insertSection` 的唯一已知呼叫端是契約 E 的
  `addSection … (UnderParent pid) …`(F008 / store-write-operations):契約 E 明寫「`UnderParent` 時
  `nsLevel` 由 `headingDepthFor` 推導,不由呼叫端給」,所以 L38 第 3 條的層級檢查在正常路徑上永遠
  不會觸發——它擋的是 store 那邊推導錯了的情況,是防線不是主要流程
- **新增的依賴邊**:
  - **模組內部**:`Aapms.Md.Parse` → `Aapms.Md.Render`(取用 `NewAsset` / `NewLicense` 與其
    `FromJSON` 實例)。方向不可反轉:`Aapms.Md.Render` **不得** import `Aapms.Md.Parse`,否則成環
  - **套件之間**:無新增
- **可否與其他進行中任務平行開發**:**不可與 F007 / F008 平行**。`aapms-store` 的 `Create.hs`
  目前自己定義了一組同名的 `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` /
  `NewNode`(`store/src/Aapms/Store/Create.hs:137-216`),與本 feature 定義在 `Aapms.Md.Render` 的
  是**同一組 DTO 的兩份定義**——契約 D 說它們屬於 `aapms-md`。收斂方式見「建議編排者做的上層動作」。
  與 F001 / F002 / F003 無衝突(不碰 `core/` 與 `types/`)。

## 不可逆決定

1. **`NewSectionPayload` 是封閉 sum,且屬於 `aapms-md` 的對外 DTO**(2026-08-24 開發者裁決,
   design.md 契約 D 已回寫)。
   - 否決「把 asset / license 欄位塞進 `MetaOverride`」:那個型別是 md 與 store 共用的**節層繼承
     DTO**,ADR-010 的位元組保留依賴它的繼承規則;為了三種文件各自的專屬欄位把它撐大,等於讓
     `inheritMeta` 的每一欄都要回答「這一欄對另外三種文件是什麼意思」。
   - 否決「每種文件一個 `addSection*`」:store 的單一入口會變成四個,新增節點種類要改四處;封閉
     sum 讓編譯器替我們列出所有待處理處(與契約 A 的 `AnyNode`、`LinkKind` 同一個模式)。
2. **meta 區塊在型別上切成兩半,型別專屬那一半以原始行保存**。
   - 否決「解成 `Value` 再重編」:引號、數字格式與縮排都會被改寫,ADR-010 的位元組保留在**被編輯的
     那一節**上就沒了,而作者手寫的 `meta:` 巢狀值會被重排。
   - 否決「只保留已知的型別專屬欄位(asset 七個 + license 八個)」:型別註冊表可以宣告任意欄位
     (`Aapms.Md.Inherit` 的既有註解已明說「未知欄位一律忽略不報錯」),那些欄位照樣會被吃掉——
     同一個 bug 換一批欄位重演。以「不在 `metaFieldOrder` 裡」為判準,一條規則涵蓋全部。
3. **型別專屬條目排在 `Meta` 欄位之後**(`pack.md` / `licenses.md` 一經編輯,meta 區塊的行序就固定
   成這個樣子,是會進 git 歷史的格式決定)。
   - 否決「回到原位」:要多存一份位置資訊,而位置本身不是資料;且 `appendSection` 產生的新節沒有
     「原位」可言,兩條路徑會產生不同排版,`git diff` 反而更髒。
4. **`NewAsset` / `NewLicense` 讀寫共用同一個型別與同一份 `FromJSON`**(刪掉 `AssetFields` /
   `LicenseFields`)。
   - 否決「讀一份、寫一份」:必填 / 選填的劃分會分歧,而 G1 與 G2 正是「讀方向認得、寫方向不認得」
     這個分歧的兩個症狀。共用一份之後,「解得回來的形狀」與「寫得出去的形狀」在型別上是同一個。

## 骨架

| 檔案 | 內容 |
|---|---|
| `md/src/Aapms/Md/Render.hs` | `MetaExtras` / `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` 型別與 `FromJSON NewAsset` / `FromJSON NewLicense` 實例;`extrasOf` / `extrasAt` / `mergeExtras` / `updateSectionExtras` / `payloadOverride` / `payloadExtras` 新簽名;`updateSection` / `reserialize` / `renderMetaBlock` / `mkSection` / `appendSection` 改簽名或改行為,本體為 `undefined`;匯出清單重整。**2026-08-25 追加**:`insertSection` 的簽名與匯出(`md/src/Aapms/Md/Render.hs:482`),本體 `undefined` |
| `md/src/Aapms/Md/Parse.hs` | 刪除 `AssetFields` / `LicenseFields` 及其實例,改用 `Aapms.Md.Render` 的 `NewAsset` / `NewLicense`;`toPack` / `toLicenses` / `licenseFieldsOf` 的欄位名機械性更名(行為不變) |
| `md/src/Aapms/Md/Error.hs` | **2026-08-25 裁決 A8**:`MdErrorKind` 追加 `HeadingTooDeep Int Int` 建構子與其 haddock(`:53-59`);`renderMdErrorKind` 對應分支本體 `undefined`(`:100`),訊息原文由 impl 照 L39 / E21 轉錄。既有 15 個建構子與它們的訊息**一個字都沒動** |
| `md/src/Aapms/Md/Inherit.hs` | **未改動**(刻意):`MetaOverride` 是 md 與 store 共用的節層繼承 DTO,污染它會動到 ADR-010 的前提 |

**本體為 `undefined` 的函數**(impl 只准替換這些,不得改動任何簽名與型別):
`updateSection`、`reserialize`(私有)、`extrasOf`、`extrasAt`、`mergeExtras`、
`updateSectionExtras`、`payloadOverride`、`payloadExtras`、`appendSection`、`mkSection`、
`renderMetaBlock`,以及 **2026-08-25 追加的 `insertSection`(`Render.hs`)與 `renderMdErrorKind` 的
`HeadingTooDeep` 分支(`Error.hs`)**。

**`HeadingTooDeep` 的 `renderMdErrorKind` 分支也是 `undefined`**(`md/src/Aapms/Md/Error.hs:100`,
2026-08-25 編排者裁決)。建構子定義與它的 haddock(`:53-59`)**保留**——那是型別,屬骨架。

理由是**這條測試要有真正的紅綠**。錯誤訊息的原文確實就是規格(契約 G 要求每個建構子的 `render*`
訊息說出下一步該做什麼),但正因為如此才更不該由設計寫進骨架:L39 / E21 逐字斷言那串訊息,若訊息由
設計寫進 `Error.hs`、同一串字又由設計寫進本文檔、再由 qa 從本文檔抄進測試,三個地方是**同一個來源**,
那條斷言**恆真**,驗證不了任何東西(`spec-roles.md`:「該紅卻綠的測試一律退回重寫」)。留 `undefined`
之後這條鏈才成立——impl 從 spec 轉錄一次進 `Error.hs`、qa 從 spec 轉錄一次進斷言,**兩次獨立轉錄**;
impl 少一個全形冒號、漏掉「請改插到較淺的父節點底下」那個子句,E21 就會紅。那一次紅燈就是它的價值。

**impl 這一輪要改 `Error.hs`,但只准填 `HeadingTooDeep _ _ ->` 那一個分支的本體**(逐字照 L39 / E21
的訊息原文轉錄);既有 15 個分支的本體、`MdError` / `MdErrorKind` 的型別定義與 `mdError` /
`renderMdError` 一律不得更動。

**2026-08-25 這一輪只有 `insertSection` 是紅的**:上一輪的十一個函數本體已交付並全綠(285 examples /
0 failures 是本輪的基準線),impl 這一輪只需要填 `insertSection` 一個本體。`appendSection` 不得改寫成
`insertSection` 的 wrapper(理由見「目的」段);`Aapms.Md.Render` **不得** import `Aapms.Md.Parse`
(會成環),所以「父節點的子樹」只能由 `docSections` 的 `secLevel` 直接算,不得借用
`Aapms.Md.Parse.structure`。`md/aapms-md.cabal` 不動:`Aapms.Md` 以 `module Aapms.Md.Render` 整模組
re-export,新匯出自動涵蓋。

**未改動、行為與上一輪相同的匯出**:`renderDocument` / `renderSection` / `overrideAt` /
`updateSectionBody` / `removeSection` / `renameSection` / `replacePreamble` / `updateFrontmatter` /
`renderFrontmatter` / `frontmatterFieldOrder` / `newDocument` / `metaFieldOrder`,以及
`Aapms.Md.Document` / `Aapms.Md.Error` / `Aapms.Md.Lexer` / `Aapms.Md.Yaml` 全部。

## 待確認假設

- **A1**:新增七個契約 D 逐字清單之外的公開介面(`MetaExtras` / `extrasOf` / `extrasAt` /
  `mergeExtras` / `updateSectionExtras` / `payloadOverride` / `payloadExtras`),並把
  `renderMetaBlock` / `mkSection` 的簽名改成吃兩半。→ 採取:照做,並請編排者把它們補進 design.md
  契約 D。依據:(a) 只要 `renderMetaBlock` 還存在一個「只吃 `MetaOverride`」的公開版本,G2 就只是
  被繞過而不是被消滅——型別上必須寫不出來;(b) 契約 E 的 `writeAssetFields` / `upsertLicense` 要改的
  正是型別專屬那一半,而 `(MetaOverride -> MetaOverride)` 表達不了,不補這條路 F008 會再撞一次牆。
  → 影響:若編排者判定 md 的公開面必須嚴格等於契約 D 逐字清單,`extrasAt` / `mergeExtras` /
  `updateSectionExtras` / `payloadOverride` / `payloadExtras` 可改成非 export 的內部函式,但
  `MetaExtras` 與 `renderMetaBlock` 的新簽名不能退回——那是缺陷修復本身。屆時 F008 需要另一條寫入
  型別專屬欄位的管道,要回 `/subsys-design` 更新契約 D。
- **A2**:型別專屬條目一律排在 `Meta` 欄位之後,因此**第一次** `updateSection` 會重排既有檔案 meta
  區塊的行序(資料不變,排版變)。→ 採取:接受,並以 L8(冪等)保證只重排一次。依據:見「不可逆
  決定」第 3 條。→ 影響:若判斷錯誤(要求既有檔案的行序原樣不動),`MetaExtras` 要改成帶「原本
  夾在哪兩個 `Meta` 欄位之間」的位置資訊,`renderMetaBlock` 的合併規則跟著改;`appendSection` 產生
  的新節仍需要一套預設順序,兩條路徑會分岔。
- **A3**:`NSNode` 的 `nnKind` 是 `kind` 的唯一真相來源,`payloadOverride` 一律以它覆蓋 `moKind`。
  → 採取:照做(L16)。依據:契約 D 的 `NSNode` 同時帶 `MetaOverride` 與 `NewNode`,兩者都能表達
  `kind`,不指定優先權就是兩個真相來源。→ 影響:若判斷錯誤(要求 `moKind` 優先或兩者必須一致),
  是 `payloadOverride` 一個函式的改動,不影響任何簽名。
- **A4**:`MetaExtras` 是 `[Text]`(原始行)而不是結構化的鍵值對。→ 採取:照做。依據:見「不可逆
  決定」第 2 條。→ 影響:呼叫端(F008)要改某一欄時,必須靠 `payloadExtras` 產生新條目再
  `mergeExtras`,不能直接改一個欄位的值;若判斷錯誤,`MetaExtras` 要改成 `[(Text, Text)]` 之類的
  結構,`extrasOf` 與 `mergeExtras` 的簽名跟著改,且會失去「作者手寫格式原樣保留」這條性質。
- **A5**:`renderMetaBlock` 中 `metaFieldOrder` 每一欄怎麼寫成一行,抽成私有的
  `metaFieldLines :: MetaOverride -> Text -> [Text]`,並**保留上一輪已交付的本體**(不是 `undefined`)。
  → 採取:照做。依據:那是已上線、已被 EditSpec 逐行斷言過的序列化規則(引號、流式風格、newtype
  解包),本次的變更是「多接一半」而不是「重寫排版」;讓 impl 從零重推有回歸風險,L10 也正是為了
  釘住它。→ 影響:若編排者認定 spec 角色不得留下任何非 `undefined` 的本體,把它改成 `undefined`
  即可,L10 會抓到任何排版漂移。
- **A6**:`NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` / `MetaExtras`
  全部定義在 `Aapms.Md.Render`,而不是新開一個 `Aapms.Md.Section` 模組。→ 採取:照做。依據:委派
  指示要求 `md/aapms-md.cabal` 不得改動,新模組加不進 `exposed-modules` 就編不過;`NewSection` 上一
  輪本來就住在 `Aapms.Md.Render`。→ 影響:代價是 `Aapms.Md.Render` 裡出現了兩個 `FromJSON` 實例
  (解碼職責通常在 `Aapms.Md.Yaml` / `Aapms.Md.Parse` 那一側)。若編排者願意動 cabal,把這六個型別
  與兩個實例搬到 `Aapms.Md.Section` 是純機械搬移,`Aapms.Md.Parse` → `Aapms.Md.Render` 那條新的
  模組內相依也會一併消失。
- **A7**:`aapms-store` 的 `Aapms.Store.Create`(`store/src/Aapms/Store/Create.hs:137-216`)已經有一組
  同名同形的 `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode`。→ 採取:
  **不碰 store**(委派指示明令),在 `aapms-md` 定義正本時**逐欄採用與 store 完全相同的欄位名**
  (`naName` / `naSha256` / …、`nlcCommercial` / …、`nnKind`),讓收斂成本降到「刪掉 store 那段、
  改成 re-export」。依據:契約 D 說這組 DTO 屬於 `aapms-md`;兩份定義同時存在時,store 一旦
  `import Aapms.Md` 就會產生名稱衝突。→ 影響:編排者需要在 F007 / F008 收斂時裁決由誰刪除;在那之前
  `aapms-store` 仍然編得過(它目前不 import `Aapms.Md.Render`)。

## 已裁決紀錄(2026-08-25 spec 閘門)

A8 / A9 / A10 是 2026-08-25 這一輪提上閘門的三條待確認假設,**已由開發者裁決**。原文逐字保留供追溯,
每條開頭補上裁決結果與理由;spec 的 Laws、Examples 與骨架已依裁決改寫。

- **A8 → 裁決:一半照做,一半推翻。`nsLevel` 不符**維持** `HeadingSkip`;「算出來的層級 > 6」
  **新增** `HeadingTooDeep Int Int`(父節點層級, 算出來的層級)。**
  - **理由(開發者)**:兩條路徑**性質不同**,不該共用一個建構子。`nsLevel` 不符在正常流程永遠不該
    觸發(契約 E 明訂 `nsLevel` 由 store 的 `headingDepthFor` 推導、不由呼叫端給),它觸發就是 store
    有 bug,不需要專用的使用者訊息;而「層級 > 6」是**真實的使用者情境**(Level 的章節樹夠深就會
    撞到),而且有明確的下一步可以講。契約 G 要求每個建構子的 `render*` 訊息說出下一步該做什麼,
    拿 `HeadingSkip`(語意是「標題從第 a 級跳到第 b 級」)去表達「太深了」,說出來的事跟實際發生的
    事不符。
  - **落實**:`md/src/Aapms/Md/Error.hs:59` 追加建構子、`:100` 追加 `renderMdErrorKind` 分支(本體 `undefined`,訊息原文寫在 L39 / E21 由 impl 轉錄)(既有 15 個建構子與其訊息
    逐字未動);L38 拆成四條檢查、新增 L39 釘住訊息;E18 改回 `HeadingTooDeep`、新增 E20(第 3 條先於
    第 4 條)/ E21(訊息原文)/ E22(既有訊息回歸)。
  - **我原本的分析(逐字保留)**:「`insertSection` 的三條錯誤路徑**沿用既有的 `MdErrorKind`
    建構子**(`UnknownSectionId` / `DuplicateSectionId` / `HeadingSkip`),不新增建構子。契約 D 只
    寫了『`nsLevel` 必須等於父節點的 `secLevel + 1`』,沒說違反時回哪一個錯誤值。」以下是當時附上的
    選項與代價,裁決選了我列的 **b 的一半**——只為「層級 > 6」新增,`nsLevel` 不符維持既有建構子:
  - 層級自答:出現在邊界上?**會**(`MdError` 是契約 G 的對外型別,`aapms-store` 要 pattern match
    並轉譯成使用者訊息);改錯驚動其他模組?**要**(store 的錯誤轉譯與 F008 的 `addSection`)
  - 選項:a) 沿用三個既有建構子——當下成本 0(本次委派明令只准改 `Render.hs`,`Error.hs` 動不了),
    三個月後代價:`HeadingSkip prev cur` 的訊息是「標題層級跳級:`###` 之後不能直接接 `#####`」,
    在「層級比父節點淺」(父在 level 3、`nsLevel = 2`)這種情況下措辭不精確;而且「層級不符」與
    「層級 > 6」兩種不同的失敗原因回**同一個值**,呼叫端分不開,只能靠數字自己推。
    b) 新增 `HeadingDepthMismatch Int Int`(期望層級, 實際層級)與 `HeadingTooDeep Int`——當下成本:
    要改 `md/src/Aapms/Md/Error.hs` 的 `MdErrorKind` 與 `renderMdErrorKind`(本次委派禁止),且
    `aapms-store` 若對 `MdErrorKind` 有窮舉 `case` 會一起編不過;三個月後代價:錯誤訊息精確、呼叫端
    分得開,代價只是 `MdErrorKind` 多兩個建構子。
  - 傾向:a。前提是「本次的檔案範圍只有 `Render.hs`」——這是委派指示給的硬約束,不是我的判斷;
    另外 `HeadingSkip 6 7` 這個特例的訊息「`######` 之後不能直接接 `#######`」讀起來其實是對的,
    只有「比父節點淺」那個特例措辭歪掉。可逆性:**有條件可逆**——新增建構子是加法,`insertSection`
    只有一行 `Left (…)` 要換;條件是「已經流到使用者眼前的錯誤訊息措辭可以改」。
  - 暫採:a → 影響:若裁決要新增建構子,改 `Error.hs` 的 `MdErrorKind` + `renderMdErrorKind`,並把
    本文檔 L38 第 3 條與 E17 / E18 的預期值換掉;`insertSection` 的**簽名不變**。
- **A9 → 裁決:接受,照做。**「與 `appendSection` 一致,而且你論證的前提成立(`allocateId` 查的是會
  過時的索引)。」L38 第 2 條與 E19 維持原樣。以下為原文逐字保留:
- **A9**(2026-08-25):`insertSection` **也檢查 `nsId` 撞號**,回 `DuplicateSectionId`。契約 D 的原文
  只約束 `nsLevel`,沒提撞號。
  - 層級自答:出現在邊界上?**會**(公開函式的前置條件);改錯驚動其他模組?**要**(F008 的
    `addSection` 要據此決定要不要自己先查一次)
  - 選項:a) 檢查——當下成本 0(`appendSection` 已有同一個 guard);三個月後代價:與
    `appendSection`(L18)對稱,兩條插入路徑的前置條件一致,呼叫端只要記一條規則。
    b) 不檢查,讓撞號的文件產生出來——當下成本 0;三個月後代價:`lexDocument` 會在**下一次讀檔**
    才報 `DuplicateSectionId`,而那時檔案已經落盤、可能已經進 git;依 ADR-002 Markdown 是唯一真相,
    產生一份自己解不回來的真相是最貴的一種錯。
  - 傾向:a。依賴的前提要講明:契約 E 的 `allocateId` 會 salt 遞增重試到不撞,看起來 md 這層是重複
    檢查——但 `allocateId` 查的是**索引**,而索引會過時(`refreshStale` 存在正是因為如此),所以這層
    檢查不是冗餘的。可逆性:**可逆**(拿掉一個 guard,沒有格式或訊息殘留)。
  - 暫採:a → 影響:若裁決不檢查,刪掉 L38 第 2 條與 E19,`insertSection` 簽名不變。
- **A10 → 裁決:接受,但措辭收窄。**開發者讀過 `md/src/Aapms/Md/Render.hs:438` 的 `blankTail`,指出
  它是**冪等**的——文字已經以空行結尾時原樣回傳。所以正確的說法不是「插入**必然**動到位元組」,而是
  「**只有當插入點之前那一段還沒有以空行結尾時**,才會補齊行尾」;而且這不是 `insertSection` 新引入
  的讓步,`appendSection` 早就走同一個 `blankTail`,它的 haddock 也早就論證過「被動到的是插入點,
  不是未經修改的區塊」。**我下面原文中「必然」這個字用錯了**,L33 / L34 已改成收窄版本,E12 也改成
  正例(格式正常的檔案上插入點一個位元組都不動)+ 變體的兩段式。以下為原文逐字保留:
- **A10**(2026-08-25):插入**必然**動到兩段位元組:(i) 插入點**之前**那一節(`p` 的子樹最後一節,
  子樹為空時就是 `p` 自己)的 `secBodyRaw` 尾端補到剛好隔一個空行;(ii) 新節**不是**最後一節時,
  它自己的 `secBodyRaw` 也要補,否則下一節的標題會黏在新節正文最後一行後面。委派指示的驗收標準是
  「插入一節之後,其他每一節的位元組必須逐字不變」,(i) 是這句話的例外。
  - 層級自答:出現在邊界上?**會**(ADR-010 的驗收標準與 P0 契約測試直接觀察輸出位元組);
    改錯驚動其他模組?**要**(會進 git 歷史的排版決定,與「不可逆決定」第 3 條同一類)
  - 選項:a) 照 `appendSection` 的既有規則,兩處都用同一個 `blankTail` 補到「剛好隔一個空行」——
    當下成本 0;三個月後代價:插入點前一節的**尾端**位元組會變(只在尾端加空白字元),ADR-010 的
    驗收標準要寫成「除插入點外逐字不變」,而不是無條件的「每一節逐字不變」。
    b) 一個位元組都不補,原樣接起來——當下成本 0;三個月後代價:前一節正文沒有結尾換行時,新節的
    標題會黏在它最後一行後面,`parseDocument` 直接解不回來(entity-graph-core/F003 已經踩過這個坑,
    `blankTail` 的註解就是它的墓碑);而且工具產生的段落與作者手寫的長得不一樣,而 Vault 是給人看的
    git repo。
  - 傾向:a,且**兩條插入路徑共用同一個 `blankTail`**——`appendSection` 與 `insertSection` 若產生不同
    排版,同一份檔案的 `git diff` 會依「這一節是怎麼加進來的」而不同,那是最難查的那種不一致。
    可逆性:**有條件可逆**——換一個 pad 函式是一行的事,但**已經寫出去的檔案不會回頭重排**,條件是
    「接受歷史檔案殘留舊排版」(與 A2 同一個性質)。
  - 暫採:a → 影響:若裁決要求「一個位元組都不補」,L33 的例外條款與 L34 的 `blankTail` 條款拿掉,
    `insertSection` 得自己處理黏行問題(等於把 F003 的坑再挖一次);簽名不變。

## 實作備註

(撰寫時留空;開發過程中與設計的偏差記錄於此)
