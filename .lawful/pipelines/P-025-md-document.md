---
id: P-025
description: Markdown 文字解析成分節 Document 並渲染回去,未改區塊逐位元組相同;節層繼承檔案層
status: frozen
updated: 2026-09-06
---
# P-025-md-document:Markdown 文字解析成分節 Document 並渲染回去,未改區塊逐位元組相同;節層繼承檔案層

## Brief
把一份 Markdown 文字變成四種文件共用的分節結構,再把它一位元組不差地寫回去(ADR-010、ADR-002)。input 是一份 `.md` 的全文;output 是 `Document`(frontmatter、preamble、每一節的三段原始切片、行尾風格、檔案身分)與依身分解讀出來的核心節點(`Entity` / `Level` 與 `Node` / `Pack` 與 `Asset` / `License`)。流向:全文切塊並判定身分 → 節層繼承檔案層 → 依身分轉成節點型別;寫回方向是 frontmatter 序列化 → meta 區塊序列化 → 一節接一節 → 整份接起來。它是子流:P-001-index-rebuild 的 4 到 8 步、P-003-node-write 的讀取側都引用它的 stage,編輯操作另立 P-026-md-edit。`docKind` / `sectionById` / `sectionIds` / `detectLineEnding` / `renderLineEnding` 住 `Aapms.Md.Document`(types),law 直接引用,不列成觀察點。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `parseDocument :: Text -> Either MdError Document` | 全文切成保留原始位元組的分節結構,並由檔案層 `type` 判定身分 | `Aapms.Md.Parse` | pure |
| 2 | `inheritMeta :: Bool -> Meta -> Id -> Text -> MetaOverride -> Either MdErrorKind Meta` | 檔案層 Meta + 節 id + 節標題 + 節層覆寫 → 節的 Meta | `Aapms.Md.Inherit` | pure |
| 3 | `toTopic :: Document -> Either MdError (Entity, [Entity])` | 主題檔解讀成主體與它的片段 | `Aapms.Md.Parse` | pure |
| 4 | `toLevel :: Document -> Either MdError (Level, [Node])` | Level 檔解讀成場景與節點,標題階層即樹(ADR-009) | `Aapms.Md.Parse` | pure |
| 5 | `toPack :: Document -> Either MdError (Pack, [Asset])` | `pack.md` 解讀成 Pack 與它的素材 | `Aapms.Md.Parse` | pure |
| 6 | `toLicenses :: Document -> Either MdError [License]` | `licenses.md` 每一節解讀成一種授權,容器本身不是節點 | `Aapms.Md.Parse` | pure |
| 7 | `overrideOf :: Meta -> MetaOverride` | 完整 Meta 展開成每一欄都是 `Just` 的覆寫 | `Aapms.Md.Inherit` | pure |
| 8 | `applyOverride :: MetaOverride -> Meta -> Meta` | 覆寫疊回一份完整 Meta,`Nothing` 的欄位保留原值 | `Aapms.Md.Inherit` | pure |
| 9 | `renderFrontmatter :: Meta -> LineEnding -> Text` | 完整 Meta 序列化成 frontmatter 內容(不含 `---` 界線) | `Aapms.Md.Render` | pure |
| 10 | `renderMetaBlock :: MetaOverride -> MetaExtras -> LineEnding -> Text` | Meta 那一半與型別專屬那一半序列化成一個完整的 meta 區塊 | `Aapms.Md.Render` | pure |
| 11 | `renderSection :: Section -> Text` | 一節的三段原始切片依序接起來 | `Aapms.Md.Render` | pure |
| 12 | `newDocumentWith :: DocKind -> Meta -> FrontExtras -> Text -> Document` | 從零產生一份帶檔案層專屬欄位、還沒有任何節的文件 | `Aapms.Md.Render` | pure |
| 13 | `newDocument :: DocKind -> Meta -> Text -> Document` | 同上,沒有檔案層專屬欄位時的特化 | `Aapms.Md.Render` | pure |
| o | `decodeFrontmatter :: Text -> Either Text Meta` | 觀察:frontmatter 文字解回檔案層 Meta,往返 law 的另一端 | `Aapms.Md.Yaml` | pure |
| = | `renderDocument :: Document -> Text` | 純的整條:四段原始切片依序接起來,只有兩條 `---` 界線由它重生 | `Aapms.Md.Render` | pure |

## Laws
- LAW-1 [roundtrip] 解析得開的文字原樣寫回,逐位元組相同(ADR-010)
  - forall t in Text
  - given isRight (parseDocument t)
  - |- fmap renderDocument (parseDocument t) == Right t
- LAW-2 [invariant] 寫回是四段原始切片依序接起來,只有兩條 --- 界線由 renderDocument 重生
  - forall d in Document
  - |- renderDocument d == mconcat ["---", docFrontRaw d, "---", docPreamble d, mconcat (map renderSection (docSections d))]
- LAW-3 [invariant] 一節就是標題行、meta 區塊與正文三段原始切片
  - forall s in Section
  - |- renderSection s == mconcat [secHeadingRaw s, fromMaybe "" (secMetaRaw s), secBodyRaw s]
- LAW-4 [total] 解析對任何文字都有值,不拋例外
  - forall t in Text
  - |- total (parseDocument t)
- LAW-5 [relation] 行尾風格與檔尾換行由全檔多數決定,解析出來就是原文的事實
  - forall t in Text
  - given isRight (parseDocument t)
  - |- fmap docEnding (parseDocument t) == Right (detectLineEnding t) and fmap docFinalNL (parseDocument t) == Right (isSuffixOf "\n" t)
- LAW-6 [total] 從零產生的文件一定解析得回來
  - forall k in DocKind, m in Meta, b in Text
  - |- isRight (parseDocument (renderDocument (newDocument k m b)))
- LAW-7 [relation] 檔案身分只由檔案層 type 決定:三個保留鍵各對一種,其餘一律 TopicDoc
  - forall k in DocKind, m in Meta, b in Text
  - |- fmap docKind (parseDocument (renderDocument (newDocument k m b))) == Right (fromMaybe TopicDoc (lookup (metaType m) [(TypeKey "level", LevelDoc), (TypeKey "asset-pack", PackDoc), (TypeKey "asset-license", LicenseDoc)]))
- LAW-8 [identity] 沒有檔案層專屬欄位時 newDocument 就是 newDocumentWith 的特化
  - forall k in DocKind, m in Meta, b in Text
  - |- newDocument k m b == newDocumentWith k m (FrontExtras (MetaExtras [])) b
- LAW-9 [roundtrip] frontmatter 序列化再解回來不失真
  - forall m in Meta, le in LineEnding
  - |- decodeFrontmatter (renderFrontmatter m le) == Right m
- LAW-10 [invariant] meta 區塊以行尾收尾,型別專屬條目的每一行逐字都在裡面(GAP-2)
  - forall ov in MetaOverride, ex in MetaExtras, le in LineEnding
  - |- isSuffixOf (renderLineEnding le) (renderMetaBlock ov ex le) and all (flip isInfixOf (renderMetaBlock ov ex le)) (extraLines ex)
- LAW-11 [relation] 節的 tags 是檔案層與節層的聯集去重
  - forall front in Meta, i in Id, title in Text, ov in MetaOverride
  - |- fmap metaTags (inheritMeta True front i title ov) == Right (nub (concat [metaTags front, fromMaybe [] (moTags ov)]))
- LAW-12 [relation] 節層未寫時 vault / status / source / created / updated / timeline 一律繼承檔案層
  - forall front in Meta, i in Id, title in Text
  - |- fmap metaVault (inheritMeta True front i title emptyOverride) == Right (metaVault front) and fmap metaStatus (inheritMeta True front i title emptyOverride) == Right (metaStatus front) and fmap metaSource (inheritMeta True front i title emptyOverride) == Right (metaSource front) and fmap metaCreated (inheritMeta True front i title emptyOverride) == Right (metaCreated front) and fmap metaUpdated (inheritMeta True front i title emptyOverride) == Right (metaUpdated front) and fmap metaTimeline (inheritMeta True front i title emptyOverride) == Right (metaTimeline front)
- LAW-13 [relation] summary / aliases / links 不繼承,未寫為空;revision 不繼承,未寫是 1
  - forall front in Meta, i in Id, title in Text
  - |- fmap metaSummary (inheritMeta True front i title emptyOverride) == Right "" and fmap metaAliases (inheritMeta True front i title emptyOverride) == Right [] and fmap metaLinks (inheritMeta True front i title emptyOverride) == Right [] and fmap metaRevision (inheritMeta True front i title emptyOverride) == Right (Revision 1)
- LAW-14 [relation] 節的 id 與標題取自節本身,永遠不繼承
  - forall front in Meta, i in Id, title in Text, ov in MetaOverride
  - |- fmap metaId (inheritMeta True front i title ov) == Right i and fmap metaTitle (inheritMeta True front i title ov) == Right title
- LAW-15 [relation] type 是否繼承由旗標決定:pack.md 的節不繼承,缺漏是錯誤
  - forall front in Meta, i in Id, title in Text
  - |- fmap metaType (inheritMeta True front i title emptyOverride) == Right (metaType front) and isLeft (inheritMeta False front i title emptyOverride)
- LAW-16 [identity] 展開再套回同一份 Meta 是恆等
  - forall m in Meta
  - |- applyOverride (overrideOf m) m == m
- LAW-17 [relation] 套回是逐欄覆蓋,id 與 title 表達不了因此原樣保留
  - forall a in Meta, b in Meta
  - |- metaSummary (applyOverride (overrideOf a) b) == metaSummary a and metaTags (applyOverride (overrideOf a) b) == metaTags a and metaId (applyOverride (overrideOf a) b) == metaId b and metaTitle (applyOverride (overrideOf a) b) == metaTitle b
- LAW-18 [relation] 主題檔的片段與節一一對應,依文件順序
  - forall d in Document
  - given isRight (toTopic d)
  - |- fmap (map (metaId . entMeta)) (fmap snd (toTopic d)) == Right (sectionIds d)
- LAW-19 [relation] Level 檔的節點與節一一對應,依文件順序
  - forall d in Document
  - given isRight (toLevel d)
  - |- fmap (map (metaId . nodMeta)) (fmap snd (toLevel d)) == Right (sectionIds d)
- LAW-20 [relation] pack.md 的 asset 與節一一對應,依文件順序
  - forall d in Document
  - given isRight (toPack d)
  - |- fmap (map (metaId . astMeta)) (fmap snd (toPack d)) == Right (sectionIds d)
- LAW-21 [relation] licenses.md 每一節一個授權,容器本身不是節點
  - forall d in Document
  - given isRight (toLicenses d)
  - |- fmap (map (metaId . licMeta)) (toLicenses d) == Right (sectionIds d)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 空檔案 `""`,以及只有 `"---\n"` 一行的檔案 | 兩者都是 `Left`(`NoFrontmatter` / `UnterminatedFrontmatter`),不拋例外 | LAW-4 |
| EX-2 | `parseDocument "---\nid: [broken"` | `Left (MdError 1 (UnterminatedFrontmatter))`;`total` 成立 | LAW-4 |
| EX-3 | 只有 frontmatter、沒有任何節的 `pack.md` 全文 | `renderDocument` 的結果與原文逐位元組相同;`sectionIds` 為 `[]` | LAW-1、LAW-2 |
| EX-4 | 一份「frontmatter 界線用 LF、正文用 CRLF」的混合行尾主題檔 | `renderDocument` 逐位元組相同;`docEnding` 為 `CRLF`(多數決),`docFinalNL` 為 `True` | LAW-1、LAW-5 |
| EX-5 | 檔尾沒有換行的主題檔 | `docFinalNL` 為 `False`;寫回仍逐位元組相同 | LAW-5 |
| EX-6 | 一節的 `Section`:標題行 `## 琳達 {#ent-7f3a}\n`、meta 區塊、正文 | `renderSection` 等於三段接起來;整份 `renderDocument` 等於 `---` + frontRaw + `---` + preamble + 各節 | LAW-2、LAW-3 |
| EX-7 | 五份 frontmatter:`type: level` / `type: asset-pack` / `type: asset-license` / `type: character` / 完全沒有 `type` | `docKind` 依序為 `LevelDoc` / `PackDoc` / `LicenseDoc` / `TopicDoc` / `TopicDoc` | LAW-7 |
| EX-8 | `newDocument PackDoc m "素材包說明"`,再 `renderDocument` → `parseDocument` | 解析成功;與 `newDocumentWith PackDoc m (FrontExtras (MetaExtras [])) "素材包說明"` 逐位元組相同 | LAW-6、LAW-8 |
| EX-9 | `renderFrontmatter m LF`,`m` 的 `metaTimeline` 為 `Nothing`、`metaTags` 為 `[]` | 十四欄全部輸出(`tags: []`、`timeline: null`);`decodeFrontmatter` 解回等於 `m` | LAW-9 |
| EX-10 | `renderMetaBlock emptyOverride (MetaExtras ["sha256: deadbeef1234", "entry: PNG/a.png"]) LF` | 輸出以 ``` ```meta ``` 起、以 ``` ``` ``` 與換行收,中間逐字含那兩行 | LAW-10 |
| EX-11 | 檔案層 `tags: [世界觀, 埃提亞]`,節層 `tags: [埃提亞, 主角]` | 節的 `metaTags` 為 `["世界觀", "埃提亞", "主角"]`(聯集去重,檔案層在前) | LAW-11 |
| EX-12 | 節的 meta 區塊完全沒有寫任何欄位(`emptyOverride`) | `metaVault` / `metaStatus` / `metaSource` / `metaCreated` / `metaUpdated` / `metaTimeline` 等於檔案層;`metaSummary == ""`、`metaAliases == []`、`metaLinks == []`、`metaRevision == Revision 1` | LAW-12、LAW-13 |
| EX-13 | `inheritMeta True front ent-7f3a "琳達" emptyOverride` | `metaId == ent-7f3a`、`metaTitle == "琳達"`,與 `front` 的 `metaId` / `metaTitle` 無關 | LAW-14 |
| EX-14 | 同一組 `front` 與 `emptyOverride`,`typeInherits` 分別是 `True` 與 `False` | `True` 時 `metaType` 等於檔案層;`False` 時是 `Left (SectionFieldMissing secId "type")` | LAW-15 |
| EX-15 | `pack.md` 的節沒有寫 `type`,呼叫 `toPack` | `Left (MdError line (SectionFieldMissing secId "type"))` | LAW-15、LAW-20 |
| EX-16 | 任一份完整 `Meta` `m`,`applyOverride (overrideOf m) m` | 逐欄等於 `m` | LAW-16 |
| EX-17 | `a` 與 `b` 是兩份 `Meta`,`applyOverride (overrideOf a) b` | `summary` / `tags` 取自 `a`,`id` / `title` 仍是 `b` 的 | LAW-17 |
| EX-18 | 主題檔 `characters/琳達.md`:主體加兩個片段 `ent-0001` / `ent-0002` | `toTopic` 的片段依序是 `[ent-0001, ent-0002]`,與 `sectionIds` 相同 | LAW-18 |
| EX-19 | Level 檔:`## 第三章 {#nod-0003}` 之下依序有 `### 第一節 {#nod-0010}` 與 `### 第二節 {#nod-0011}`,frontmatter 沒有寫 `root` | `toLevel` 的節點依序是 `[nod-0003, nod-0010, nod-0011]`,與 `sectionIds` 相同;`root` 以第一個節 `nod-0003` 填入 | LAW-19 |
| EX-20 | `pack.md` 兩個 asset 節 `ast-0001` / `ast-0002` | `toPack` 的 `[Asset]` 長度 2,`metaId` 依序等於 `sectionIds` | LAW-20 |
| EX-21 | `licenses.md` 的節沒有寫 `commercial`,以及一份三節都寫齊的 `licenses.md` | 前者 `Left (MdError line (SectionFieldMissing secId "commercial"))`;後者 `[License]` 長度 3 且 `metaId` 依序等於 `sectionIds` | LAW-21 |
| EX-22 | 主題檔在第一個帶 `{#id}` 的標題之前另有一個沒有 id 的 `## 前言` | 該標題留在 `docPreamble` 裡,不開新節;`sectionIds` 不含它;寫回逐位元組相同 | LAW-1、LAW-2 |

## 決定
- **未經修改的區塊逐字保留原始位元組,`Section` 因此存三段原始文字切片而不是解讀後的 `Meta`。** 否決:語意等價(`parse (render (parse f)) == parse f`)。理由:作者的 YAML 註解、欄位順序與空白風格會在每一次程式寫入時被正規化,`git diff` 上改一個欄位會顯示整份檔案都變了。證據:ADR-010-byte-preserving-roundtrip
- **兩條 `---` 界線只有 `---` 三個字元本身由 `renderDocument` 重生,每一段切片含自己結尾的行尾字元。** 否決:界線行整行存起來。理由:這樣「frontmatter 用 LF、正文用 CRLF」的混合檔位元組相等是結構上保證的,不必靠 `docEnding` 猜;代價是界線行只接受剛好 `---`
- **`docKind` 在 `parseDocument` 階段就算好存進 `Document`,存取子只讀快取。** 否決:`docKind` 存取子每次重解 frontmatter。理由:判定要讀 YAML 而 YAML 可能解不開,存取子的型別 `Document -> DocKind` 沒有回報錯誤的位置
- **四種文件共用一個分節引擎與一個 `Document` 型別,身分由檔案層 frontmatter 的 `type` 判別。** 否決:每種文件一個解析器。理由:分節、行號、位元組保留這三件事對四種文件完全相同,分開就是同一份規則四份實作
- **`type` 是否繼承由呼叫端傳入的旗標決定,不由 `inheritMeta` 自己看檔案身分。** 否決:`inheritMeta` 多吃一個 `DocKind`。理由:繼承規則是純粹的欄位合併,認得檔案身分等於把文件種類的知識散進 `Aapms.Md.Inherit`
- **`summary` 與 `revision` 不繼承,缺 `summary` 不再產生警告,只是空字串。** 否決:繼承主體的 summary。理由:片段的一句話總結是衝突偵測撈 context 的主要輸入,繼承等於製造假資訊;`revision` 繼承會讓多個片段共用同一個 revision,樂觀鎖失去意義
- **`tags` 是聯集去重而不是覆寫。** 否決:節層覆寫檔案層。理由:檔案層放共通標籤、節層放專屬標籤是最自然的用法,純覆寫會逼作者在每一節重寫共通標籤
- **`MdError` 只回報第一個錯誤(依節的文件順序,也就是行號由小到大),不回清單。** 否決:一次列完全部。理由:契約 D 的每個函式簽名都是單一 `MdError`;錯誤清單的合併順序本身又是一條要維護的規則
- **`renderFrontmatter` 與 `newDocument` 保留為「沒有檔案層專屬欄位」的特化,不改簽名吃兩半。** 否決:比照節層把它們改成只有兩半版本。理由:四種文件裡有三種的 frontmatter 確實只有 `Meta`,單半版本有真實用途;真正危險的整段重新序列化(`updateFrontmatter`,見 P-026-md-edit)已經被強制走兩半版本
- **解析方向用 HsYAML,序列化方向自己寫(固定欄位順序、流式 `links`)。** 否決:用 YAML 編碼器。理由:只有被修改的區塊需要重寫,格式完全由我們決定,引入編碼器反而要對抗它的排版偏好。證據:ADR-010-byte-preserving-roundtrip
- **渲染器對任意 `Text` 負責:控制字元由 `quote` 跳脫,不把限制推給 `Meta` 的欄位。** 否決:LAW-9 加 given「文字欄位不含控制字元」;`Meta` 文字欄位改 smart constructor。理由:round-trip 是序列化器自己的契約,收窄 law 會讓 law 說的比程式保證的少;「標題不能有 U+2028」不是業務規則,不該由型別替使用者決定資料域(GAP-1 裁決,2026-09-06)。
- **`Source` 的 payload 是非空的 `SourceName`,非法狀態不可表達。** 否決:LAW-9 加 given「payload 非空」;`parseSource` 接受空 payload。理由:型別留下的自由度該用型別收掉,而且沒有任何生產碼在建構這三個建構子,現在改代價最低;「沒名字的 agent」成為合法檔案內容語意可疑(GAP-2 裁決,2026-09-06)。
- **解凍紀錄:2026-09-06 為 REV-1� 解凍,重委派全綠後重新凍結。**

## 修訂記錄
- REV-1(2026-09-06,依 impl 提問 GAP-1「`quote` 只跳脫 `"` `\` `\n` `\r` `\t`,其他 C0 控制字元與 U+2028 / U+2029 原樣輸出」與 GAP-2「`Agent ""` 渲染成 `source: "agent:"` 之後讀不回來」;開發者裁決兩條都收在程式碼側,LAW-9 的域不動):`quote` 把所有 C0 / C1 控制字元、DEL、U+2028 / U+2029,以及 impl 全 BMP 掃描實測 HsYAML 讀不回來的 U+FEFF / U+FFFE / U+FFFF 跳脫成 `\xNN` / `\uNNNN`;`Source` 的 payload 由裸 `Text` 收成非空的 `SourceName`(smart constructor `mkSourceName`),`Agent ""` 寫不出來
  - 動到:無(簽名與 law 都不變;變的是 `Aapms.Md.Render` 的 `quote` 本體與 types 層 `Aapms.Core.Meta` 的 `Source` 形狀)
  - 保護:LAW-1 到 LAW-21 全部
  - 重委派:impl(`quote`、`Source`);qa(LAW-9 的 `Meta` 產生器要蓋到控制字元與 `SourceName`)
