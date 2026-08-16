---
id: adr-0009
type: adr
title: level-markdown-heading-hierarchy
description: Level 場景樹以 Markdown 標題階層表達父子與順序
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0009: Level 檔以 Markdown 標題階層表達樹結構

## 狀態(Status)

accepted

## 背景(Context)

ADR-0002 決定 Markdown 是真相來源,ADR-0004 決定 Level 是嚴格樹。但兩者交會處有一塊空白:
`levels/教室.md` 這份檔案**長什麼樣**?

Entity 的分節格式已經有明確範例(節標題帶 `{#ent-xxxx}` + ` ```meta ` 區塊),但 Entity 是
**平的**——一份檔案裡的片段彼此沒有階層。Node 不是,它必須表達 `parent` 與 `order`。

這兩個欄位有一個共同特性:**它們是最容易寫錯、也最容易被工具重算的欄位**。作者在對話節點
中間插入一個新節點時,後面所有兄弟的 `order` 都要往後推;搬動一棵子樹時,所有 `parent`
都要改。如果這兩個欄位是手寫的 YAML,作者每次調整劇情結構都要做一次心算,而且錯了不會有
任何提示,直到 `buildTree` 報 `OrphanNode` 為止。

## 決策(Decision)

**Level 檔的 Markdown 標題階層直接就是 Node 的樹結構,文件順序直接就是 `order`。**

- 全檔最淺的標題層級是根 Node(`parent = Nothing`)
- 層級 +1 即子節點,父節點是它前面最近的、層級小 1 的節
- 同一父節點下的第 n 個子節點,`order = n`(從 1 起算)
- `kind` 必填,寫在該節的 ` ```meta ` 區塊
- Node 指向的 Entity **由 `involves` / `references` 關聯推導**,不另設 `entities` 欄位
- 跳級(`##` 之後直接 `####`)是錯誤,不猜測作者意圖
- `convergesTo` 只是 `meta` 裡的一筆 `links`,不影響結構(ADR-0004)

作者因此**永遠不必手寫 `parent` 與 `order`**。插入一個節點就是插入一段 Markdown;
把一棵子樹往下降一層就是多加一個 `#`。

檔案層 frontmatter 的 `type: level` 是判別依據——解析器據此決定走 Entity 解析還是 Level
解析。`level` 因此是保留的型別鍵,不可出現在 `types/registry/`。

## 考慮過的替代方案(Alternatives Considered)

- **內文放一個 ` ```tree ` YAML 區塊描述整棵樹**:解析最單純(丟給 YAML 解析器就好),
  結構最明確。但整棵樹擠在一個 YAML 區塊裡,`git diff` 會因為縮排變動而整段標紅;而且
  這等於在 Markdown 檔裡塞一份 YAML 文件,作者失去了用 Markdown 寫作的體驗——場景描述、
  演出說明這些**該用文字寫的東西**沒有地方放。
- **平的節 + 顯式 `parent` / `order` 欄位**(與 Entity 檔完全同構):格式一致、解析器可
  共用、搬動節點時不必改標題層級。但這正是上面說的痛點:兩個最易錯的欄位交給手寫,
  而且錯誤只會在 `buildTree` 時才浮現。一致性買到的好處遠小於這個代價。
- **一個 Node 一個檔案**:定位最直接。但一個場景會有數十個 Node,檔案數量爆炸,而且
  「一份檔案看完整個場景」這個核心寫作體驗完全消失——這與 ADR-0002 否決「一片段一檔」
  的理由相同。
- **另設 `entities` 欄位而非用關聯推導**:語意上更直白。但同一件事(Node 指向 Entity)
  會有兩種寫法,解析器要處理兩者衝突時誰贏,而 `Link` 已經能完整表達方向與語意。

## 影響(Consequences)

**正面**

- 作者調整劇情結構的成本降到「編輯 Markdown 標題」,`parent` / `order` 永遠自動正確
- `git diff` 在插入節點時只顯示新增的那幾行,不會因為後續兄弟的 `order` 全變而整片標紅
- 場景描述與演出說明有自然的地方寫(節的正文),不必擠進 YAML
- Entity 檔與 Level 檔共用同一套 lexer(frontmatter + 節標題 + `meta` 區塊 + 正文),
  只有解讀階段分岔

**負面 / 成本**

- 樹很深時標題層級會用完:Markdown 只有 `#` 到 `######` 六級,根用 `##` 的話最深只能到
  第 5 層。教室場景的例子已經用到第 5 層(`nod-0007`)。**這是本決策最實質的限制**。
  緩解:根可以用 `#`(得七層);真的不夠時把子樹拆成另一個 Level 並以關聯串接。
  若實際使用中頻繁撞到上限,本 ADR 應被 supersede
- 標題文字同時是 Node 的 `title`,作者無法讓兩者不同
- 搬動子樹時要重新調整一整段的標題層級,純文字編輯器沒有自動化;P2 的 CLI 應提供
  `level move` 指令代勞

**中立**

- 跳級報錯而非猜測,作者第一次寫時會撞到一次;錯誤訊息必須明說「`##` 之後不能直接接 `####`」
