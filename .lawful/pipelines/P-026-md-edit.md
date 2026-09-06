---
id: P-026
description: Document 上的更新、插入、附加、移除節與 frontmatter 改寫,其餘節位元組不變
status: ready
updated: 2026-09-06
---
# P-026-md-edit:Document 上的更新、插入、附加、移除節與 frontmatter 改寫,其餘節位元組不變

## Brief
在一份已解析的 `Document` 上做結構化編輯,並守住「只重寫被修改的那一段」(ADR-010)。input 是一份 `Document` 加一個編輯請求(要改哪一節、改 `Meta` 那一半還是型別專屬那一半、要插在哪裡);output 是一份新的 `Document`,寫回去之後除了被指名的那一段以外逐位元組相同。流向:讀出該節目前的兩半 → 呼叫端算出新的兩半 → 只重新序列化那一段 → 其餘原始切片逐字帶過去 → 整份寫回。它是子流:P-003-node-write 與 P-008-graph-write 的寫入側引用它的 stage;解析與寫回本身住 P-025-md-document,本條只管「怎麼改」。meta 區塊在型別上切成兩半(`MetaOverride` 與 `MetaExtras`),檔案層 frontmatter 有對稱的一組(`Meta` 與 `FrontExtras`),少一半在型別上就寫不出來。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `parseDocument :: Text -> Either MdError Document` | 全文切成保留原始位元組的分節結構 | `Aapms.Md.Parse`(見 P-025-md-document) | pure |
| 2 | `overrideAt :: Id -> Document -> Either MdError MetaOverride` | 讀出某一節目前的 Meta 覆寫;沒有 meta 區塊時是 `emptyOverride` | `Aapms.Md.Render` | pure |
| 3 | `extrasOf :: Section -> MetaExtras` | 取出一節 meta 區塊裡鍵不在 `metaFieldOrder` 的頂層條目,以原始行保存 | `Aapms.Md.Render` | pure |
| 4 | `extrasAt :: Id -> Document -> Either MdError MetaExtras` | 同上,以節 id 定位,與 `overrideAt` 對稱 | `Aapms.Md.Render` | pure |
| 5 | `payloadOverride :: NewSectionPayload -> MetaOverride` | 取出新節 payload 的 Meta 那一半 | `Aapms.Md.Render` | pure |
| 6 | `payloadExtras :: NewSectionPayload -> MetaExtras` | 取出新節 payload 的型別專屬那一半,序列化成行 | `Aapms.Md.Render` | pure |
| 7 | `mergeExtras :: MetaExtras -> MetaExtras -> MetaExtras` | 合併兩組專屬條目,同鍵時第一個參數贏 | `Aapms.Md.Render` | pure |
| 8 | `renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text` | 兩半序列化成一個完整的 meta 區塊 | `Aapms.Md.Render`(見 P-025-md-document) | pure |
| 9 | `mkSection :: LineEnding -> Int -> Id -> Text -> Maybe NewSectionPayload -> Text -> Section` | 由零件組一個新的節 | `Aapms.Md.Render` | pure |
| 10 | `updateSectionExtras :: Id -> (MetaExtras -> MetaExtras) -> Document -> Either MdError Document` | 只改某一節的型別專屬條目,Meta 那一半與標題行、正文不動 | `Aapms.Md.Render` | pure |
| 11 | `updateSectionBody :: Id -> Text -> Document -> Either MdError Document` | 只換某一節的正文 | `Aapms.Md.Render` | pure |
| 12 | `renameSection :: Id -> Text -> Document -> Either MdError Document` | 只換某一節標題行的標題文字,層級與 `{#id}` 保留 | `Aapms.Md.Render` | pure |
| 13 | `replacePreamble :: Text -> Document -> Document` | 只換 frontmatter 與第一個節之間的正文 | `Aapms.Md.Render` | pure |
| 14 | `removeSection :: Id -> Document -> Either MdError Document` | 刪掉某一節連同它的 meta 區塊與正文 | `Aapms.Md.Render` | pure |
| 15 | `appendSection :: NewSection -> Document -> Either MdError Document` | 在最後一節之後追加新節;沒有節時追加在 preamble 之後 | `Aapms.Md.Render` | pure |
| 16 | `insertSection :: Id -> NewSection -> Document -> Either MdError Document` | 在指定父節點的子樹之後插入新節,成為它的最後一個子節點 | `Aapms.Md.Render` | pure |
| 17 | `frontExtrasOf :: Document -> FrontExtras` | 取出 frontmatter 裡鍵不在 `frontmatterFieldOrder` 的頂層條目 | `Aapms.Md.Render` | pure |
| 18 | `mergeFrontExtras :: FrontExtras -> FrontExtras -> FrontExtras` | `mergeExtras` 的檔案層版本,一行 wrapper | `Aapms.Md.Render` | pure |
| 19 | `packFrontExtras :: NewPackFront -> FrontExtras` | pack 的七個檔案層專屬欄位序列化成行 | `Aapms.Md.Render` | pure |
| 20 | `decodeFrontmatter :: Text -> Either Text Meta` | 改寫前先把 frontmatter 解回 Meta;讀不懂就不覆蓋 | `Aapms.Md.Yaml`(見 P-025-md-document) | pure |
| 21 | `updateFrontmatter :: (Meta -> Meta) -> Document -> Either MdError Document` | 改寫檔案層的 Meta 那一半,專屬條目與 preamble、每一節不動 | `Aapms.Md.Render` | pure |
| 22 | `updateFrontmatterExtras :: (FrontExtras -> FrontExtras) -> Document -> Either MdError Document` | 改寫檔案層的型別專屬條目,Meta 那一半一欄都不動 | `Aapms.Md.Render` | pure |
| 23 | `renderSection :: Section -> Text` | 一節的三段原始切片依序接起來 | `Aapms.Md.Render`(見 P-025-md-document) | pure |
| 24 | `renderDocument :: Document -> Text` | 整份寫回 | `Aapms.Md.Render`(見 P-025-md-document) | pure |
| o | `metaFieldOrder :: [Text]` | 觀察:節層 meta 區塊裡屬於 Meta 的鍵,同時是「哪些鍵是型別專屬條目」的唯一判準 | `Aapms.Md.Render` | pure |
| o | `frontmatterFieldOrder :: [Text]` | 觀察:檔案層 frontmatter 的固定欄位順序,判準同上 | `Aapms.Md.Render` | pure |
| = | `updateSection :: Id -> (MetaOverride -> MetaOverride) -> Document -> Either MdError Document` | 純的整條:讀出兩半、只重新序列化 Meta 那一半、專屬條目與其餘每一段逐字帶過 | `Aapms.Md.Render` | pure |

## Laws
- LAW-1 [invariant] 改一節的 Meta 半邊,其他每一節逐位元組不變(ADR-010)
  - forall d in Document, i in Id, f in MetaOverride -> MetaOverride, d2 in rights [updateSection i f d], j in sectionIds d
  - given j /= i
  - |- fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-2 [invariant] 被改的那一節只有 meta 區塊被重寫,標題行與正文逐位元組不變
  - forall d in Document, i in Id, f in MetaOverride -> MetaOverride, d2 in rights [updateSection i f d]
  - |- fmap secHeadingRaw (sectionById i d2) == fmap secHeadingRaw (sectionById i d) and fmap secBodyRaw (sectionById i d2) == fmap secBodyRaw (sectionById i d) and docFrontRaw d2 == docFrontRaw d and docPreamble d2 == docPreamble d
- LAW-3 [invariant] 改 Meta 半邊不吃掉型別專屬條目(GAP-2 的直接否證形式)
  - forall d in Document, i in Id, f in MetaOverride -> MetaOverride, d2 in rights [updateSection i f d]
  - |- extrasAt i d2 == extrasAt i d
- LAW-4 [identity] 第一次 updateSection 把 meta 行序重排一次,第二次起是恆等(ASM-2)
  - forall d in Document, i in Id, d2 in rights [updateSection i id d]
  - |- fmap renderDocument (updateSection i id d2) == Right (renderDocument d2)
- LAW-5 [relation] 節不存在時每個編輯都回 Left,一個位元組都不動
  - forall d in Document, i in Id, f in MetaOverride -> MetaOverride, g in MetaExtras -> MetaExtras, b in Text
  - given not (i in sectionIds d)
  - |- isLeft (updateSection i f d) and isLeft (updateSectionExtras i g d) and isLeft (updateSectionBody i b d) and isLeft (renameSection i b d) and isLeft (removeSection i d) and isLeft (overrideAt i d) and isLeft (extrasAt i d)
- LAW-6 [invariant] 改型別專屬半邊,Meta 那一半、標題行、正文與其他節都不動
  - forall d in Document, i in Id, g in MetaExtras -> MetaExtras, d2 in rights [updateSectionExtras i g d], j in sectionIds d
  - given j /= i
  - |- overrideAt i d2 == overrideAt i d and fmap secHeadingRaw (sectionById i d2) == fmap secHeadingRaw (sectionById i d) and fmap secBodyRaw (sectionById i d2) == fmap secBodyRaw (sectionById i d) and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-7 [relation] extrasAt 就是該節的 extrasOf;沒有 meta 區塊時是空的一組
  - forall d in Document, i in sectionIds d
  - |- extrasAt i d == Right (fromMaybe (MetaExtras []) (fmap extrasOf (sectionById i d)))
- LAW-8 [invariant] 取出來的專屬條目不含任何 metaFieldOrder 裡的鍵
  - forall s in Section, l in extraLines (extrasOf s), k in metaFieldOrder
  - |- not (isPrefixOf (mconcat [k, ":"]) l)
- LAW-9 [relation] 刪節之後 id 清單恰好少掉那一個,其餘每一節逐位元組不變
  - forall d in Document, i in Id, d2 in rights [removeSection i d], j in sectionIds d2
  - |- sectionIds d2 == filter (/= i) (sectionIds d) and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-10 [relation] 追加的節排在最後,既有 id 的順序不變
  - forall d in Document, ns in NewSection, d2 in rights [appendSection ns d]
  - |- sectionIds d2 == concat [sectionIds d, [nsId ns]]
- LAW-11 [invariant] 追加不動既有節的標題行與 meta 區塊
  - forall d in Document, ns in NewSection, d2 in rights [appendSection ns d], j in sectionIds d
  - |- fmap secHeadingRaw (sectionById j d2) == fmap secHeadingRaw (sectionById j d) and fmap secMetaRaw (sectionById j d2) == fmap secMetaRaw (sectionById j d) and docFrontRaw d2 == docFrontRaw d
- LAW-12 [relation] nsId 與既有節撞號時追加與插入都回 Left
  - forall d in Document, pid in Id, ns in NewSection
  - given nsId ns in sectionIds d
  - |- isLeft (appendSection ns d) and isLeft (insertSection pid ns d)
- LAW-13 [relation] 插入保序:把新節拿掉之後的 id 清單與原本逐一相同
  - forall d in Document, pid in Id, ns in NewSection, d2 in rights [insertSection pid ns d]
  - |- filter (/= nsId ns) (sectionIds d2) == sectionIds d
- LAW-14 [invariant] 插入不動其他節的標題行與 meta 區塊(ADR-010)
  - forall d in Document, pid in Id, ns in NewSection, d2 in rights [insertSection pid ns d], j in sectionIds d
  - given j /= nsId ns
  - |- fmap secHeadingRaw (sectionById j d2) == fmap secHeadingRaw (sectionById j d) and fmap secMetaRaw (sectionById j d2) == fmap secMetaRaw (sectionById j d) and docFrontRaw d2 == docFrontRaw d and docPreamble d2 == docPreamble d
- LAW-15 [relation] 插入唯一可能動到的位元組是插入點之前那一段的尾端,而且只在尾端補(F008 GAP-14 裁決)
  - forall d in Document, pid in Id, ns in NewSection, d2 in rights [insertSection pid ns d], j in sectionIds d
  - given j /= nsId ns
  - |- isPrefixOf (fromMaybe "" (fmap secBodyRaw (sectionById j d))) (fromMaybe "" (fmap secBodyRaw (sectionById j d2)))
- LAW-16 [identity] blankTail 冪等:原本就以空行結尾的節,插入之後正文一個位元組都不動
  - forall d in Document, pid in Id, ns in NewSection, d2 in rights [insertSection pid ns d], j in sectionIds d
  - given j /= nsId ns
  - given isSuffixOf (mconcat [renderLineEnding (docEnding d), renderLineEnding (docEnding d)]) (fromMaybe "" (fmap secBodyRaw (sectionById j d)))
  - |- fmap secBodyRaw (sectionById j d2) == fmap secBodyRaw (sectionById j d)
- LAW-17 [relation] 新節的 meta 區塊由兩半組出來;payload 為 Nothing 時完全不產生區塊
  - forall le in LineEnding, n in Int, i in Id, title in Text, p in NewSectionPayload, b in Text
  - |- secMetaRaw (mkSection le n i title (Just p) b) == Just (mconcat [renderLineEnding le, renderMetaBlock (payloadOverride p) (payloadExtras p) le]) and secMetaRaw (mkSection le n i title Nothing b) == Nothing
- LAW-18 [relation] NSNode 的 kind 以 NewNode 為唯一真相來源,不管原本的 moKind 是什麼(ASM-3)
  - forall ov in MetaOverride, n in NewNode
  - |- moKind (payloadOverride (NSNode ov n)) == Just (nnKind n)
- LAW-19 [identity] 其餘三個建構子的 payloadOverride 原樣回傳自己帶的 MetaOverride
  - forall ov in MetaOverride, a in NewAsset, l in NewLicense
  - |- payloadOverride (NSFragment ov) == ov and payloadOverride (NSAsset ov a) == ov and payloadOverride (NSLicense ov l) == ov
- LAW-20 [invariant] payload 產生的專屬條目與 metaFieldOrder 的鍵不相交
  - forall p in NewSectionPayload, l in extraLines (payloadExtras p), k in metaFieldOrder
  - |- not (isPrefixOf (mconcat [k, ":"]) l)
- LAW-21 [relation] 合併是聯集:第一個參數的條目依原序在前,第二個參數中鍵未被覆蓋的依原序在後
  - forall a in MetaExtras, b in MetaExtras
  - |- isPrefixOf (extraLines a) (extraLines (mergeExtras a b)) and all (flip elem (concat [extraLines a, extraLines b])) (extraLines (mergeExtras a b))
- LAW-22 [identity] 與空的一組合併,兩個方向都是恆等
  - forall a in MetaExtras
  - |- mergeExtras a (MetaExtras []) == a and mergeExtras (MetaExtras []) a == a
- LAW-23 [equiv] 檔案層的合併就是節層的合併,不得有第二份實作(ASM-11)
  - forall a in FrontExtras, b in FrontExtras
  - |- mergeFrontExtras a b == FrontExtras (mergeExtras (unFrontExtras a) (unFrontExtras b))
- LAW-24 [invariant] pack 的七個檔案層欄位與 frontmatterFieldOrder 的鍵不相交
  - forall npf in NewPackFront, l in extraLines (unFrontExtras (packFrontExtras npf)), k in frontmatterFieldOrder
  - |- not (isPrefixOf (mconcat [k, ":"]) l)
- LAW-25 [invariant] 改檔案層的 Meta 半邊不吃掉檔案層的專屬條目(GAP-17,GAP-2 的檔案層鏡像)
  - forall d in Document, f in Meta -> Meta, d2 in rights [updateFrontmatter f d]
  - |- frontExtrasOf d2 == frontExtrasOf d
- LAW-26 [invariant] 改檔案層不動 preamble 與任何一節
  - forall d in Document, f in Meta -> Meta, d2 in rights [updateFrontmatter f d], j in sectionIds d
  - |- docPreamble d2 == docPreamble d and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-27 [identity] 檔案層的欄位順序只重排一次:第二次 updateFrontmatter id 是恆等
  - forall d in Document, d2 in rights [updateFrontmatter id d]
  - |- fmap renderDocument (updateFrontmatter id d2) == Right (renderDocument d2)
- LAW-28 [invariant] 改檔案層的專屬條目,Meta 那一半一欄都不動,preamble 與每一節逐位元組不變
  - forall d in Document, g in FrontExtras -> FrontExtras, d2 in rights [updateFrontmatterExtras g d], j in sectionIds d
  - |- decodeFrontmatter (docFrontRaw d2) == decodeFrontmatter (docFrontRaw d) and docPreamble d2 == docPreamble d and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-29 [invariant] 只換正文:該節的標題行與 meta 區塊、其他節逐位元組不變
  - forall d in Document, i in Id, b in Text, d2 in rights [updateSectionBody i b d], j in sectionIds d
  - given j /= i
  - |- fmap secHeadingRaw (sectionById i d2) == fmap secHeadingRaw (sectionById i d) and fmap secMetaRaw (sectionById i d2) == fmap secMetaRaw (sectionById i d) and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-30 [invariant] 只換標題文字:層級與 id 不變,meta 區塊與正文、其他節逐位元組不變
  - forall d in Document, i in Id, title in Text, d2 in rights [renameSection i title d], j in sectionIds d
  - given j /= i
  - |- fmap secTitle (sectionById i d2) == Just title and fmap secLevel (sectionById i d2) == fmap secLevel (sectionById i d) and fmap secId (sectionById i d2) == fmap secId (sectionById i d) and fmap secMetaRaw (sectionById i d2) == fmap secMetaRaw (sectionById i d) and fmap secBodyRaw (sectionById i d2) == fmap secBodyRaw (sectionById i d) and fmap renderSection (sectionById j d2) == fmap renderSection (sectionById j d)
- LAW-31 [invariant] 只換 preamble:frontmatter 與每一節逐位元組不變
  - forall d in Document, b in Text, j in sectionIds d
  - |- docFrontRaw (replacePreamble b d) == docFrontRaw d and fmap renderSection (sectionById j (replacePreamble b d)) == fmap renderSection (sectionById j d) and sectionIds (replacePreamble b d) == sectionIds d
- LAW-32 [total] 每一種編輯的結果都還解析得回來,解出的 id 清單與編輯後相同
  - forall d in Document, ns in NewSection, d2 in rights [appendSection ns d]
  - given isRight (parseDocument (renderDocument d))
  - |- fmap sectionIds (parseDocument (renderDocument d2)) == Right (sectionIds d2)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `pack.md` 的 asset 節含 `sha256: deadbeef1234` 與 `entry: PNG/a.png`,呼叫 `updateSection aid (\o -> o { moSummary = Just "after" })` 再 `renderDocument` | 輸出仍逐字含那兩行;`extrasAt aid` 前後相同;`summary` 改成 `after`;標題行與正文逐位元組不變 | LAW-2、LAW-3 |
| EX-2 | 只有一節的主題檔,對該節 `updateSection i id`,再對結果 `updateSection i id` | 第一次可能重排 meta 行序(專屬條目移到 Meta 欄位之後),第二次的 `renderDocument` 與第一次逐位元組相同 | LAW-4 |
| EX-3 | 三節的主題檔,對中間那一節 `updateSection` | 另外兩節的 `renderSection` 逐位元組不變;`docFrontRaw` / `docPreamble` 不變 | LAW-1、LAW-2 |
| EX-4 | 對不存在的節 id `ent-9999` 呼叫七個編輯入口 | 每一個都回 `Left (MdError 1 (UnknownSectionId ent-9999))` | LAW-5 |
| EX-5 | asset 節,`updateSectionExtras aid (mergeExtras (payloadExtras (NSAsset emptyOverride na')))`,`na'` 只改 `naLicense` | `license` 那一行換成新值;`sha256` / `entry` / `meta` 逐字不變;`overrideAt aid` 與呼叫前相同;標題行與正文不變 | LAW-6、LAW-21 |
| EX-6 | 節的 meta 區塊完全沒有寫任何欄位,以及節根本沒有 meta 區塊 | 兩者的 `extrasAt` 都是 `Right (MetaExtras [])`;後者的 `overrideAt` 是 `Right emptyOverride` | LAW-7 |
| EX-7 | 節的 meta 區塊含 `summary: x`、`sha256: deadbeef1234` 與註冊表宣告的 `battle_power: 9000` | `extraLines (extrasOf s)` 是 `["sha256: deadbeef1234", "battle_power: 9000"]`,不含 `summary` 那一行 | LAW-8 |
| EX-8 | 節的 meta 區塊含區塊風格的巢狀值 `meta:` 加兩行縮排的 `width:` / `height:`,呼叫任一 `updateSection` | 三行整段逐字保留、順序不變 | LAW-3、LAW-8 |
| EX-9 | 三節的文件,`removeSection` 掉中間那一節 | `sectionIds` 由三個變兩個且恰好少掉它;剩下兩節的 `renderSection` 逐位元組不變 | LAW-9 |
| EX-10 | 只有 frontmatter、沒有任何節的 `pack.md`,`appendSection (NewSection ast-0001 2 "圖示" "" (NSAsset ov na)) d` | 產生一個節且排在最後;`renderDocument` → `parseDocument` → `toPack` 成功且 `[Asset]` 長度為 1 | LAW-10、LAW-32 |
| EX-11 | 1,693 節的合成 `pack.md`,`appendSection` 追加第 1,694 節 | 前 1,693 節的 `secHeadingRaw` 與 `secMetaRaw` 逐位元組不變;新節在最後 | LAW-10、LAW-11 |
| EX-12 | `appendSection` 的 `nsId` 與既有節撞號;同一個 `ns` 走 `insertSection` | 兩者都是 `Left (MdError 1 (DuplicateSectionId nsId))` | LAW-12 |
| EX-13 | Level 檔:`## 第三章 {#nod-0003}` 底下依序有 `### 第一節 {#nod-0010}`、`### 第二節 {#nod-0011}`,`nod-0011` 底下還有 `#### 場景 A {#nod-0020}`;檔尾另有 `## 第四章 {#nod-0004}`。對 `nod-0003` 插入 `nsLevel = 3` 的 `nod-0030` | `sectionIds` 為 `[…, nod-0003, nod-0010, nod-0011, nod-0020, nod-0030, nod-0004]`——新節在 `nod-0020` 之後、`nod-0004` 之前;拿掉 `nod-0030` 後與原本逐一相同 | LAW-13 |
| EX-14 | 同 EX-13 的檔,`nod-0020` 的正文已經以空行結尾 | 每一節(含 `nod-0020` 自己)的 `renderSection` 逐位元組不變;`docFrontRaw` / `docPreamble` 不變 | LAW-14、LAW-16 |
| EX-15 | 同 EX-13,但 `nod-0020` 的正文只有單一行尾、沒有空行 | 只有 `nod-0020` 的 `secBodyRaw` 在尾端補齊,舊正文仍是新正文的前綴;其餘每一節逐位元組不變 | LAW-14、LAW-15 |
| EX-16 | `mkSection LF 2 ast-0001 "圖示" (Just (NSAsset ov na)) "內文"`,以及同一組零件的 `Nothing` | 前者的 `secMetaRaw` 是 `Just` 且等於行尾接 `renderMetaBlock (payloadOverride p) (payloadExtras p) LF`;後者是 `Nothing` | LAW-17 |
| EX-17 | `payloadOverride (NSNode ov (NewNode KScene))`,其中 `moKind ov == Just KDialogue` | `moKind` 是 `Just KScene`;其餘十二欄與 `ov` 相同 | LAW-18 |
| EX-18 | `payloadOverride (NSFragment ov)` / `(NSAsset ov na)` / `(NSLicense ov nl)` | 三者都逐欄等於 `ov` | LAW-19 |
| EX-19 | `payloadExtras (NSAsset emptyOverride na)`,`na` 的 `naName` / `naExt` / `naLicense` / `naAuthor` 皆為 `Nothing`、`naKindMeta` 為 `Null` | 只產生 `sha256:` 與 `entry:` 兩行,沒有任何鍵落在 `metaFieldOrder` 裡 | LAW-20 |
| EX-20 | `mergeExtras (MetaExtras ["license: lic-0002"]) (MetaExtras ["sha256: deadbeef1234", "license: lic-0001"])` | `["license: lic-0002", "sha256: deadbeef1234"]`——同鍵第一個參數贏,其餘依原序在後 | LAW-21 |
| EX-21 | `mergeExtras a (MetaExtras [])` 與 `mergeExtras (MetaExtras []) a`,`a` 為 EX-20 的第二個參數 | 兩者都逐字等於 `a` | LAW-22 |
| EX-22 | 任取 EX-20 那組 `a` / `b`,比對 `mergeFrontExtras (FrontExtras a) (FrontExtras b)` 與 `FrontExtras (mergeExtras a b)` | 兩者相等 | LAW-23 |
| EX-23 | `npf = NewPackFront (Just "Kenney") (Just "ui-pack.zip") (Just (Sha256 "deadbeef1234")) (Just lic0001) (Just kenney) (Just "https://kenney.nl/assets/ui-pack") AiNone` | `packFrontExtras npf` 的七行鍵依序是 `vendor` / `archive` / `sha256` / `license` / `author` / `source_url` / `ai_disclosure`,一個都不在 `frontmatterFieldOrder` 裡 | LAW-24 |
| EX-24 | 七欄全部是 `Nothing` / `AiUnknown` 的 `npf` | `packFrontExtras npf == FrontExtras (MetaExtras [])` | LAW-24 |
| EX-25 | EX-23 的檔案,`updateFrontmatter (\mm -> mm { metaSummary = "after" })` 再 `renderDocument` | 輸出仍逐字含那七行;`toPack` 的七欄不變;`summary` 改成 `after`;`docPreamble` 與每一節逐位元組不變 | LAW-25、LAW-26 |
| EX-26 | 主題檔的 frontmatter 含註冊表宣告的 `battle_power: 9000`,`updateFrontmatter (\mm -> mm { metaStatus = Canon })`,再 `updateFrontmatter id` | `battle_power: 9000` 逐字保留(排在 `links:` 之後);第二次的輸出逐位元組不變 | LAW-25、LAW-27 |
| EX-27 | EX-23 的檔案,`updateFrontmatterExtras (mergeFrontExtras (packFrontExtras npf'))`,`npf'` 只改 `npfLicense` | `license:` 那一行換成新值;`vendor` / `archive` / `sha256` 逐字不變;`decodeFrontmatter (docFrontRaw d')` 與呼叫前相同;`docPreamble` 與每一節不變 | LAW-28 |
| EX-28 | frontmatter 的 YAML 壞掉(`title: [unclosed`),呼叫 `updateFrontmatter id` 與 `updateFrontmatterExtras id` | 兩者都是 `Left (MdError 1 (FrontmatterYaml _))`,`docFrontRaw` 一個位元組都沒動 | LAW-25、LAW-28 |
| EX-29 | 兩節的文件,`updateSectionBody i "新正文"`,新正文不以行尾結尾且後面還有下一節 | 該節的標題行與 meta 區塊不變、另一節逐位元組不變;下一節的標題不會黏在正文後面 | LAW-29、LAW-32 |
| EX-30 | `renameSection ent-7f3a "琳達(改)"`,原標題行是 `## 琳達 {#ent-7f3a}\r\n` | `secTitle` 換成新值,`secLevel` 仍是 2、`secId` 不變、該行行尾仍是 CRLF;meta 區塊與正文、其他節逐位元組不變 | LAW-30 |
| EX-31 | `replacePreamble "新的主體正文" d`,`d` 有兩節 | `docFrontRaw` 與兩節的 `renderSection` 逐位元組不變;`sectionIds` 不變 | LAW-31 |

## 決定
- **meta 區塊在型別上切成兩半:`MetaOverride` 那一半(鍵落在 `metaFieldOrder` 裡)與型別專屬那一半(`MetaExtras`,其餘的頂層條目),`renderMetaBlock` 必須同時吃兩半。** 否決:整塊由 `MetaOverride` 重寫。理由:舊版對 `pack.md` 的 asset 節做任何一次 `updateSection` 都會靜默刪掉 `sha256` / `entry`,依 ADR-013 那是素材中繼資料的真相,等於永久資料破壞;少一半在型別上就寫不出來,缺陷才不會換一批欄位重演。證據:ADR-010-byte-preserving-roundtrip
- **判準是「鍵不在 `metaFieldOrder` 裡」,不是列舉已知的 asset 七欄與 license 八欄。** 否決:列舉法。理由:型別註冊表可以宣告任意欄位,列舉會讓同一個 bug 換一批欄位重演;一條規則涵蓋全部
- **型別專屬條目以原始行保存,不解成 `Value` 再重編。** 否決:結構化的鍵值對。理由:解碼再編碼一定會動到引號、數字格式與縮排,作者手寫的 `meta:` 巢狀值會被重排;代價是呼叫端要改某一欄時得用 `payloadExtras` 產生新條目再 `mergeExtras`,不能直接改一個值
- **型別專屬條目一律排在 `Meta` 欄位之後,不回原位;第一次 `updateSection` 因此會重排既有檔案的 meta 行序一次。** 否決:記住原本夾在哪兩個欄位之間。理由:回原位要多存一份位置資訊,而位置本身不是資料;`appendSection` 產生的新節也沒有「原位」可言,兩條路徑會產生不同排版,`git diff` 反而更髒。以冪等(LAW-4)保證只重排一次
- **檔案層的載體是 `FrontExtras`,即 `MetaExtras` 的 newtype:切段、取鍵、合併的機制共用一份,型別分得開。** 否決:兩層共用同一個 `MetaExtras`。理由:共用擋不住「把節層 extras 餵進檔案層」,而那種混用不會編譯錯誤——多餘的鍵解析時一律忽略,症狀是安靜的髒資料;本子系統已被「安靜的資料遺失」咬過兩次,兩次都不是測試抓到的。落實成 `mergeFrontExtras` 是一行 wrapper,並由 LAW-23 逐字釘住它等於 `mergeExtras`
- **`insertSection` 插在父節點的子樹之後,新節成為它的最後一個子節點。** 否決:插在父節點正後方。理由:那會變成插在既有子節點之前;ADR-009 說 Level 的樹狀結構就是標題階層,「插在樹的哪個位置」等價於「插在檔案的哪一行」
- **`appendSection` 不改寫成 `insertSection` 的 wrapper。** 否決:合併成一個函式。理由:「1,693 節的文件末尾追加一節,前面 1,693 節位元組不變」這條驗收標準直接掛在 `appendSection` 上,改寫會讓那條標準多繞一層才驗得到
- **插入點之前那一段的行尾用同一個 `blankTail` 補到剛好隔一個空行,而且它是冪等的。** 否決:一個位元組都不補。理由:前一節正文沒有結尾換行時新節的標題會黏上去,寫出一份自己解不回來的真相是最貴的一種錯;被動到的是插入點而不是「未經修改的區塊」,不違反 ADR-010,這一點由 F008 的 GAP-14 裁決確認並收窄了「位元組不變」的措辭
- **`insertSection` 的四條例外路徑依「父節點不存在 → 撞號 → 層級不符 → 層級超過六級」的順序取第一個成立的。** 否決:層級檢查優先。理由:層級不符在正常流程永遠不該觸發(`nsLevel` 由呼叫端的 `headingDepthFor` 推導),它觸發是程式 bug;而「父節點已經在第 6 級」是真實的作者情境,要有自己的下一步指引
- **`NewSectionPayload` 是封閉 sum,`NSNode` 的 `nnKind` 是 `kind` 的唯一真相來源。** 否決:把 asset / license 欄位塞進 `MetaOverride`,或讓 `moKind` 優先。理由:`MetaOverride` 是 md 與 store 共用的節層繼承 DTO,污染它會動到位元組保留所依賴的繼承規則;`NSNode` 同時帶得出 `kind` 的兩個地方不指定優先權就是兩個真相來源
- **檔案層 frontmatter 是整段重新序列化,不逐欄改寫;作者寫在 frontmatter 裡的 YAML 註解會被抹掉。** 否決:做一個保留式的 YAML 編輯器。理由:Haskell 生態沒有現成的,等於自己寫一個 YAML 子集的編輯器,而它買到的額外價值範圍極小;節層的位元組保留不受影響,而那才是 ADR-010 真正在保護的東西。證據:ADR-010-byte-preserving-roundtrip

## 修訂記錄
無
