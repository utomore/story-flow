---
id: F007
type: feature
title: store-fts-dual-index
description: FTS5 trigram 與 unicode61 雙索引、查詢路由、分數合併與 facet
status: done
created: 2026-08-24
updated: 2026-08-25
depends-on: [F001, F005, F006]
related-adr: [ADR-013, ADR-016]
related-feature: []
---

# F007: FTS5 雙索引與單一 vault 全文檢索

## 目的

FTS5 的 `trigram` tokenizer 對 `MATCH` 有三字元下限,而「藥水」「琳達」「金門」這類二字詞正是中文
專有名詞的主要形態——現況等於故事側與素材側的中文檢索都是壞的。ADR-016 的決策是**兩張 FTS5 表
並行**:`fts_tri`(trigram,吃原文)負責三字元以上與英文子字串,`fts_cjk`(unicode61,吃應用層預切的
unigram + bigram)負責一、二字元的中日韓查詢;兩條路都給得出 bm25 分數,所以 `LIKE` 掃描退場、
`shScore` 回歸 `Double`。

本 feature 把這件事落成:一個純的切詞/路由模組、兩張表的 schema 與列維護、以及 `search` 這個查詢
出口(含 facet)。

## 對應的 Level 2 契約

| 契約 | 條目 | 本文檔的處置 |
|---|---|---|
| E | `search :: VaultHandle -> SearchQuery -> IO SearchResult` | 逐字實作,見「介面」 |
| F | `SearchQuery` / `SearchHit` / `FacetCounts` / `SearchResult` | 逐字實作;`shScore :: Double`(ADR-016) |
| F | `NodeFilter` | **不重新定義**,沿用 F006 既有型別,`sqFilter` 直接複用 |
| 模組間公開介面 | Index → Tokenize:寫入 FTS 前把文字欄位預切成 unigram + bigram 字串 | `ftsRowOf` 是這條邊的單一入口 |
| 模組間公開介面 | Query → Tokenize:依查詢字串長度與字元類別決定走 trigram、cjk 或兩者 | `routeOf` |
| 索引結構 | `fts_tri` / `fts_cjk` / `fts_map` 三張表 | 逐字實作;另加一個 `fts_map` 的刪除觸發器(見「不可逆決定」DEC-3) |
| G | 錯誤契約 | **不新增建構子**:`search` 不會失敗(索引是衍生物,查不到就是空結果) |

未超出契約範圍。契約 E 的 `searchAcross` 與契約 G 的 `TooManyVaults` 屬 F009,本文檔不碰。

## 數據

| 型別 | 動作 | 定義 | 擁有的知識 |
|---|---|---|---|
| `FtsText` | 新增 | `{ ftTitle, ftSummary, ftBody, ftAliases, ftTags, ftName :: Text }` | 「一個節點的哪六段文字進得了全文索引」——`body` 進 FTS 但不進 `nodes`,只有這裡說得出六欄的內容與順序 |
| `FtsRow` | 新增 | `{ frNode :: Id, frTri :: FtsText, frCjk :: FtsText }` | 一個節點在兩張 FTS 表裡的完整內容;`frTri` 是原文、`frCjk` 是預切後的 n-gram 串 |
| `SearchRoute` | 新增 | `TrigramOnly \| CjkOnly \| BothIndexes` | 「這個查詢字串該查哪張表」的唯一真相 |
| `SearchQuery` | 新增 | `{ sqText :: Maybe Text, sqFilter :: NodeFilter, sqFacets :: Bool }` | 一次檢索的完整輸入 |
| `SearchHit` | 新增 | `{ shVault :: VaultId, shMeta :: Meta, shSnippet :: Text, shScore :: Double }` | 一筆命中的來源 vault、節點、片段與相關度 |
| `FacetCounts` | 新增 | `{ fcTypes, fcVaults, fcTags, fcOwners, fcLicenses :: [(Text, Int)] }` | 目前條件下五個維度各自的分佈 |
| `SearchResult` | 新增 | `{ srHits :: [SearchHit], srTotal :: Int, srFacets :: Maybe FacetCounts }` | 一次檢索的完整輸出;`srTotal` 是**未套用分頁**的總筆數 |
| `fts_tri` | 新增(表) | `FTS5(title, summary, body, aliases, tags, name) tokenize='trigram'` | 原文的三字元窗格索引 |
| `fts_cjk` | 新增(表) | `FTS5(title, summary, body, aliases, tags, name) tokenize='unicode61'` | 預切後 n-gram 串的詞索引 |
| `fts_map` | 新增(表) | `(rowid INTEGER PK, node_id TEXT UNIQUE → nodes(id) ON DELETE CASCADE)` | 節點 id ↔ 兩張 FTS 表共用 rowid 的對照 |
| `schemaVersion` | 修改 | `2` → `3` | 索引 shape 的版本;**切詞規則改版也只改這個數字**(ADR-016 第四條) |
| `indexTables` | 修改 | 尾端加 `fts_tri` / `fts_cjk` / `fts_map` | 「整庫重建要砍哪些表」的唯一清單 |

`fts_cjk` 的六欄內容是「先所有 unigram、再所有 bigram、以單一空白分隔」的同一欄混合串。unicode61 對
空白斷詞,長度 1 的 token 永遠不等於長度 2 的 token,而查詢端對同一段輸入只會產生其中一種,片語比對
因此不會跨過 unigram / bigram 的交界——不需要像 legacy assetdb 那樣拆成兩個欄位。

## 介面

| 簽名 | 語意(做什麼) | 骨架位置 |
|---|---|---|
| `isCjk :: Char -> Bool` | 這個字元是不是中日韓字元(含假名與諺文) | `store/src/Aapms/Store/Tokenize.hs:63` |
| `hasCjk :: Text -> Bool` | 這段文字裡有沒有任何中日韓字元 | `store/src/Aapms/Store/Tokenize.hs:67` |
| `cjkRuns :: Text -> [Text]` | 取出所有極大的中日韓連續段,依出現順序 | `store/src/Aapms/Store/Tokenize.hs:74` |
| `rawFtsText :: AnyNode -> FtsText` | 把一個節點投影成進全文索引的六段文字 | `store/src/Aapms/Store/Tokenize.hs:109` |
| `segmentFtsText :: FtsText -> FtsText` | 對六個欄位逐一套用 `cjkSegment` | `store/src/Aapms/Store/Tokenize.hs:113` |
| `ftsRowOf :: AnyNode -> FtsRow` | 給出一個節點在兩張 FTS 表裡的完整內容 | `store/src/Aapms/Store/Tokenize.hs:117` |
| `cjkSegment :: Text -> Text` | 把文字預切成 unigram + bigram 的空白分隔串,非中日韓字元丟棄 | `store/src/Aapms/Store/Tokenize.hs:135` |
| `usesTrigram :: SearchRoute -> Bool` | 這條路由要不要查 `fts_tri` | `store/src/Aapms/Store/Tokenize.hs:162` |
| `usesCjk :: SearchRoute -> Bool` | 這條路由要不要查 `fts_cjk` | `store/src/Aapms/Store/Tokenize.hs:166` |
| `routeOf :: Text -> SearchRoute` | 依查詢字串的長度與字元類別決定走哪張(或哪兩張)表 | `store/src/Aapms/Store/Tokenize.hs:171` |
| `triMatchExpr :: Text -> Maybe Text` | 給出 `fts_tri` 的 `MATCH` 運算式;查詢為空時沒有 | `store/src/Aapms/Store/Tokenize.hs:175` |
| `cjkMatchExpr :: Text -> Maybe Text` | 給出 `fts_cjk` 的 `MATCH` 運算式;查詢不含中日韓字元時沒有 | `store/src/Aapms/Store/Tokenize.hs:183` |
| `ftsQuoted :: Text -> Text` | 把輸入包成 FTS5 的字面字串,關掉全部運算子語意 | `store/src/Aapms/Store/Tokenize.hs:194` |
| `ftsPhrase :: Text -> Text` | 把空白分隔的 token 串包成要求連續出現的片語查詢 | `store/src/Aapms/Store/Tokenize.hs:199` |
| `schemaVersion :: Int` | 索引 shape 的版本號,值為 `3` | `store/src/Aapms/Store/Schema.hs:78` |
| `indexTables :: [Text]` | 整庫重建要砍掉重建的全部表名 | `store/src/Aapms/Store/Schema.hs:143` |
| `insertFtsRows :: Connection -> [FtsRow] -> IO ()` | 把一批節點的全文內容寫進兩張 FTS 表,同一個節點已有內容時取代 | `store/src/Aapms/Store/Schema.hs:386` |
| `emptySearchQuery :: SearchQuery` | 沒有文字條件、最寬鬆結構條件、不算 facet 的檢索 | `store/src/Aapms/Store/Query.hs:484` |
| `search :: VaultHandle -> SearchQuery -> IO SearchResult` | 在單一 vault 內依文字與結構條件找出節點,附片段、相關度與(選用的)分面計數 | `store/src/Aapms/Store/Query.hs:522` |

型別定義的骨架位置:`FtsText` `Tokenize.hs:84`、`FtsRow` `Tokenize.hs:98`、`SearchRoute` `Tokenize.hs:151`、
`SearchQuery` `Query.hs:472`、`SearchHit` `Query.hs:489`、`FacetCounts` `Query.hs:501`、
`SearchResult` `Query.hs:511`。

> **2026-08-24 修訂(spec-gaps GAP-4 / GAP-5 的裁決)**:`desegmentCjk :: Text -> Text` 已從介面**移除**。
> 它唯一的消費者是 `search` 的 CJK 片段還原路徑,而該路徑依 ASM-3 改走 `fts_tri` 的原文之後,這個函式
> 不再有任何呼叫端;連帶撤掉 LAW-4(見「Laws」)。介面因此是 20 條,不是 21 條。

`search` 的行為約定(全部由下方 Laws 釘死,這裡只列不變量):結果不失敗;沒有文字條件時退化成
`listNodes`;有文字條件時每筆命中都有正的相關度與非空片段;兩張表都命中的節點只回一筆;`srTotal`
不受分頁影響;facet 計數排除該 facet 自己的條件。

## Laws(行為性質)

> **2026-08-24 修訂**:LAW-4 與 LAW-23 已撤銷(開發者裁決,spec-gaps GAP-3 / GAP-4 / GAP-5),原文以刪除線保留並附
> 撤銷理由,**編號不重編**(其餘 law 與其測試不受影響)。**生效的是 22 條**:LAW-1–LAW-3、LAW-5–LAW-22、LAW-24。

**切詞(純函式)**

- **LAW-1**:對所有 `t`,`T.words (cjkSegment t)` 的每個 token 都只由 `isCjk` 為真的字元組成,且長度是 1 或 2
- **LAW-2**:對所有 `t`,`T.filter isCjk t` 的每個字元都以一個長度 1 的 token 出現在 `cjkSegment t` 裡,順序與原文相同
- **LAW-3**:對所有 `t`,`cjkSegment t` 裡長度 2 的 token 多重集合,等於「對 `cjkRuns t` 的每一段取相鄰重疊字元對」的多重集合(所以「台灣 日本」不產生「灣日」)
- ~~**LAW-4**:對所有 `t`,`desegmentCjk (cjkSegment t) == T.unwords (cjkRuns t)`~~
  **(2026-08-24 撤銷,開發者裁決;spec-gaps GAP-4 / GAP-5)**——「先所有 unigram、再所有 bigram」的表示法
  本來就不是為了可逆而設計的:當同一個字元的重複剛好落在兩個 `cjkRuns` 段的邊界上,`cjkSegment`
  對兩個 `cjkRuns` 不同的輸入會給出**逐字元相同**的輸出,任何確定性的 `desegmentCjk` 都不可能同時
  等於兩個不同的 `T.unwords (cjkRuns _)`,這條 law 在數學上不可滿足。它原本的唯一用途是替 ASM-3 的
  snippet 還原背書,而 ASM-3 已改走 `fts_tri` 的原文,`desegmentCjk` 連同這條 law 一併退場。
  **qa 不再需要 LAW-4 的測試**(編號保留為空位,不重編其餘 law)
- **LAW-5**:對所有不含中日韓字元的 `t`(含空字串),`cjkSegment t == ""` 且 `hasCjk t == False`
- **LAW-6**:對所有 `t`,`hasCjk t == T.any isCjk t == not (null (cjkRuns t))`

**六欄投影**

- **LAW-7**:對所有 `n`,`rawFtsText n` 的 `ftTitle` / `ftSummary` 逐字等於 `metaTitle` / `metaSummary (anyMeta n)`,`ftAliases` / `ftTags` 等於 `T.unwords` 的 `metaAliases` / `metaTags`;`ftName` 非空 ⟺ `n` 是 `NAsset` 且其 `astName` 為 `Just`;`ftBody` 對 `NLevel` / `NNode` 恆為 `""`
- **LAW-8**:對所有 `n`,`frTri (ftsRowOf n) == rawFtsText n` 且 `frCjk (ftsRowOf n) == segmentFtsText (rawFtsText n)`;`segmentFtsText` 的每一欄等於對應欄套用 `cjkSegment` 的結果(寫入與查詢共用同一段切詞程式碼,這是雙索引唯一要守住的不變量)

**路由與運算式**

- **LAW-9**:對所有 `t`,令 `s = T.strip t`,則 `usesTrigram (routeOf t) == (not (hasCjk s) || T.length s >= 3)`,且 `usesCjk (routeOf t) == hasCjk s`
- **LAW-10**:對所有 `t`,`isJust (cjkMatchExpr t) == usesCjk (routeOf t)`,且 `isJust (triMatchExpr t) == not (T.null (T.strip t))`
- **LAW-11**:對所有 `t`,`ftsQuoted t` 的首尾各是一個 `"`,中間內容等於 `t` 把每個 `"` 換成 `""` 的結果;且 `ftsPhrase t == ftsQuoted (T.unwords (T.words t))`

**`search`**

- **LAW-12**:對所有 `q`,若 `sqText q` 是 `Nothing` 或去掉頭尾空白後為空字串,則 `map shMeta (srHits r) == listNodes vh (sqFilter q)`,且 `srHits r` 每筆 `shScore == 0`、`shSnippet == ""`
- **LAW-13**:對所有有文字條件的 `q`,`srHits r` 的每一筆 `shScore > 0`
- **LAW-14**:對所有 `q`,`srHits r` 的 `metaId . shMeta` 兩兩相異;且有文字條件時 `shScore` 非遞增,分數相同的相鄰兩筆 `metaId` 遞增(結果完全決定於輸入,同一份索引重複查詢逐筆相同)
- **LAW-15**:對所有 `q` 與任意 `nfLimit` / `nfOffset`,`srTotal r` 相同;且 `srTotal r >= length (srHits r)`、`length (srHits r) <= nfLimit (sqFilter q)`
- **LAW-16**:對所有 `q`,`sqFacets q == False` ⟺ `srFacets r == Nothing`;`sqFacets q == True` 時 `srFacets r == Just fc`,且 `fcVaults fc` 恰有一筆,其值是本 vault 的 `vmId`、計數是 `srTotal r`
- **LAW-17**:對所有 `q` 與任意 `ts` / `tags` / `o` / `lic`,`fcTypes` 不因 `nfTypes` 改變、`fcTags` 不因 `nfTags` 改變、`fcOwners` 不因 `nfOwner` 改變、`fcLicenses` 不因 `nfLicense` 改變(facet 計數排除該 facet 自己的條件,否則選了一個值之後就換不掉)
- **LAW-18**:對所有 `sqText == Nothing` 的 `q`,`fcTags` 的每一筆 `(tag, n)` 滿足 `n == length (listNodes vh (sqFilter q) { nfTags = [tag] })`(facet 受**其他**條件影響);`fcTypes` / `fcOwners` / `fcLicenses` 同理
- **LAW-19**:對所有 `q`,`srHits r` 每一筆的 `shVault` 等於 `vmId (vhMarker vh)`
- **LAW-20**:對所有檔案 `f` 與查詢 `q`,連續 `indexFile vh f` 兩次之後 `search vh q` 的結果,與只做一次時相同(FTS 不留重複列)
- **LAW-21**:對所有檔案 `f`,`unindexFile vh f` 之後,`f` 裡的任何節點都不再出現在任何 `search vh q` 的 `srHits` 中
- **LAW-22**(ADR-016 第四條):把 `meta_info` 的 `schema_version` 改成任何不等於 `schemaVersion` 的值,再 `openVault` + `rebuildIndex`,則對所有 `q`,`search vh q` 的結果與改動前相同,且 `openVault` 回報的 `IndexIssue` 含一筆 `SchemaRebuilt`(索引是衍生物;切詞規則改版只靠這條路徑生效,不寫遷移)
- ~~**LAW-23**:`store/src` 底下所有 `.hs` 原始碼都不含 `LIKE` 這個 SQL 關鍵字(不分大小寫的獨立詞)~~
  **(2026-08-24 撤銷,開發者裁決;spec-gaps GAP-3)**——用文字掃描斷言「某個關鍵字不在原始碼裡」
  分不出註解與程式碼,這正是它撞到骨架自身 Haddock 註解的原因;而且它斷言的是**原始碼的字面**,
  不是任何可觀察的行為,不屬於 law 的範疇。它想保證的事(沒有第三條掃描路徑)已由 **LAW-9 / LAW-10**
  涵蓋:查詢一定走 trigram 或 cjk 兩條 FTS 路徑之一,兩條路的成立與否完全由 `routeOf` /
  `triMatchExpr` / `cjkMatchExpr` 決定,沒有留給子字串掃描的位置。ADR-016 第二條由 LAW-9 / LAW-10 背書。
  **qa 不再需要 LAW-23 的測試**(編號保留為空位,不重編其餘 law)
- **LAW-24**:對所有純 ASCII 的查詢字串 `t`,`search` 對 `t` 與對 `T.toUpper t` 回相同的 `srHits`

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| EX-1 | `cjkSegment "金門建築"` | `"金 門 建 築 金門 門建 建築"` | 單一長段:unigram 在前、bigram 在後 |
| EX-2 | `cjkSegment "台灣 日本"` | `"台 灣 日 本 台灣 日本"` | bigram 不跨越非中日韓字元 |
| EX-3 | `cjkSegment "hello"`、`cjkSegment ""`、`cjkSegment "金"` | `""`、`""`、`"金"` | 純 ASCII / 空字串 / 單字元(不產生 bigram) |
| EX-4 | `routeOf "藥水"`、`routeOf "travel-book"`、`routeOf "藥水 potion"` | `CjkOnly`、`TrigramOnly`、`BothIndexes` | 三條路由各一 |
| EX-5 | `ftsQuoted "blue-potion"`、`ftsQuoted "他說\"好\""` | `"\"blue-potion\""`、`"\"他說\"\"好\"\"\""` | `-` 不被當成 NOT;雙引號加倍跳脫 |
| EX-6 | 對含「魔法藥水瓶」的 asset 的 vault,`search` 文字條件為 `"藥水"` | 命中該節點,`shScore > 0`,`shSnippet` 含「藥水」 | **二字中文命中(契約卡驗收標準)** |
| EX-7 | 對 `title` 為「琳達」的角色主體,文字條件為 `"琳達"` | 命中,`shScore > 0` | **二字中文命中(契約卡驗收標準)** |
| EX-8 | 對 `name` 為 `ui_gui_travel-book-frame_001` 的 asset,文字條件為 `"travel-book"` | 命中該 asset | 英文子字串走 trigram,`-` 不被當運算子 |
| EX-9 | 文字條件為 `"魔法藥水"`(四字) | 命中,`shScore > 0`,`routeOf` 為 `BothIndexes` | 三字以上中文走 trigram 並有分數 |
| EX-10 | 一個節點的 `title` 同時含「藥水」與 `potion`,文字條件為 `"藥水 potion"` | `srHits` 只有一筆該節點 | 兩張表都命中時以分數合併去重 |
| EX-11 | 任一有資料的 vault,`sqFacets = True` | `srFacets == Just fc`;`fcVaults` 恰一筆,`fcTypes` / `fcTags` / `fcOwners` / `fcLicenses` 皆非空 | facet 五個維度都有 |
| EX-12 | `emptySearchQuery`(`sqText = Nothing`、`sqFacets = False`) | `map shMeta srHits == listNodes vh emptyNodeFilter`;每筆 `shScore == 0`、`shSnippet == ""`;`srFacets == Nothing` | 退化成純結構查詢 |
| EX-13 | 文字條件為 `"這個詞不存在於任何節點"` | `srHits == []`、`srTotal == 0`、不是錯誤 | 空結果不是錯誤 |
| EX-14 | 文字條件為 `"ui"`(純 ASCII 二字) | `srHits == []` | `LIKE` 退場的已知代價:trigram 三字元下限,`fts_cjk` 不收非中日韓內容 |

## 依賴

`depends-on: [F001, F005, F006]`。

- **F006**:交付了 `NodeFilter` / `listNodes` / `indexFile` / `unindexFile` / `rebuildIndex` 與
  `nodes` + 專屬表的 schema,本 feature 全部建立在它們之上;`search` 的結構條件與 `listNodes` 同語意
  (LAW-12 / LAW-18 直接拿它當對照基準)
- **F005**:`VaultHandle` / `VaultMarker` / `openVault` / `IndexIssue` 是 `search` 與 LAW-22 的直接輸入
- **F001**:`AnyNode` / `anyMeta` / `Meta` / `Entity` / `Asset` / `Pack` / `License` / `LogicalName` /
  `Id` 是 `rawFtsText` 六欄投影的直接輸入

> 編排者在委派時指定 `depends-on: [F006]`(取自 `design.md` 功能規劃的「依賴」欄)。依
> `conventions` 的「反推 depends-on」機械檢查,下方「使用到的既有介面」表另外指得出 F005 與 F001
> 的**直接**呼叫,故補上;作法與 F006 自己列 `[F001, F004, F005]` 一致。編排者若要維持路線圖的
> 顆粒度,改回 `[F006]` 即可,兩者都不影響波次排程(F006 已在 WAVE-5 完成)。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data VaultHandle = VaultHandle { vhMarker :: VaultMarker, vhRoot :: FilePath, vhConn :: Connection, vhRegistry :: TypeRegistry }` | `store/src/Aapms/Store/Marker.hs:73` | F005 | `search` 從 `vhConn` 查索引、從 `vhMarker` 取 `shVault` |
| `data VaultMarker = VaultMarker { vmId :: VaultId, vmKind :: VaultKind, vmName :: Text, vmRefs :: [VaultId] }` | `store/src/Aapms/Store/Marker.hs:57` | F005 | `shVault` 與 `fcVaults` 的來源 |
| `openVault :: TypeRegistry -> FilePath -> IO (Either StoreError (VaultHandle, [IndexIssue]))` | `store/src/Aapms/Store/Marker.hs:182` | F005 | LAW-22 取得重建後的 handle 與 `SchemaRebuilt` |
| `data NodeFilter = NodeFilter { nfPrefixes, nfTypes, nfStatus, nfTags, nfOwner, nfLicense, nfNamedOnly, nfIncludeReference, nfLimit, nfOffset }` | `store/src/Aapms/Store/Query.hs:78` | F006 | `sqFilter` 直接複用,語意不變 |
| `emptyNodeFilter :: NodeFilter` | `store/src/Aapms/Store/Query.hs:95` | F006 | `emptySearchQuery` 的結構條件 |
| `listNodes :: VaultHandle -> NodeFilter -> IO [Meta]` | `store/src/Aapms/Store/Query.hs:176` | F006 | LAW-12 / LAW-18 的對照基準 |
| `indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])` | `store/src/Aapms/Store/Index.hs:147` | F006 | FTS 寫入的觸發點(需加一處呼叫,見「骨架」) |
| `unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())` | `store/src/Aapms/Store/Index.hs:154` | F006 | LAW-21;刪除靠既有的外鍵級聯 + 新的觸發器 |
| `rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])` | `store/src/Aapms/Store/Index.hs:382` | F006 | LAW-20 / LAW-22 |
| `data IndexIssue = SchemaRebuilt { irOldVersion :: Maybe Int, irNewVersion :: Int } \| ...` | `store/src/Aapms/Store/Schema.hs:84` | F005 / F006 | LAW-22 |
| `data AnyNode = NEntity Entity \| NAsset Asset \| NPack Pack \| NLicense License \| NLevel Level \| NNode Node` | `core/src/Aapms/Core/AnyNode.hs:19` | F001 | `rawFtsText` 的輸入 |
| `anyMeta :: AnyNode -> Meta` | `core/src/Aapms/Core/AnyNode.hs:28` | F001 | 六欄投影裡 title / summary / aliases / tags 的來源 |
| `data Meta = Meta { metaId :: Id, ... }` | `core/src/Aapms/Core/Meta.hs:123` | F001 | `shMeta`、`frNode` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/Aapms/Core/Entity.hs:12` | F001 | `ftBody` |
| `data Asset = Asset { ..., astName :: Maybe LogicalName, ..., astBody :: Text }` | `core/src/Aapms/Core/Asset.hs:35` | F001 | `ftName` / `ftBody` |
| `data Pack = Pack { ..., pckBody :: Text }` | `core/src/Aapms/Core/Pack.hs:36` | F001 | `ftBody` |
| `data License = License { ..., licFullText :: Maybe Text }` | `core/src/Aapms/Core/License.hs:13` | F001 | `ftBody` |
| `newtype LogicalName = LogicalName Text` | `core/src/Aapms/Core/Asset.hs:26` | F001 | `ftName` |
| `newtype Id = Id Text` | `core/src/Aapms/Core/Id.hs:86` | F001 | `frNode` |

### 依賴方向

- **依賴誰**:`Aapms.Store.Tokenize` → `aapms-core`(`AnyNode` / `Id` / `Meta` 與各節點型別);
  `Aapms.Store.Schema` → `Aapms.Store.Tokenize` + `sqlite-simple`;`Aapms.Store.Query` →
  `Aapms.Store.Tokenize` + 既有的 `Marker` / `Row`;`Aapms.Store.Index` → `Aapms.Store.Tokenize`
- **誰會依賴它**:`Aapms.Store`(門面 re-export `Query`,`search` 因此自動對外);F009 的 MultiVault
  會以同一組 SQL 片段做 `*Across`;更上層是 `service` 的 search 端點與 `conflict` 第 2 層
- **新增的依賴邊**(一條都不能漏):
  1. `Aapms.Store.Tokenize` → `Aapms.Core.AnyNode`(新模組)
  2. `Aapms.Store.Tokenize` → `Aapms.Core.Id`(新模組)
  3. `Aapms.Store.Schema` → `Aapms.Store.Tokenize`
  4. `Aapms.Store.Query` → `Aapms.Store.Tokenize`(impl 階段建立)
  5. `Aapms.Store.Index` → `Aapms.Store.Tokenize`(impl 階段建立;`Index → Schema` 是既有邊)
  沒有任何新的套件層相依:`aapms-store` 的 `build-depends` 不變,`aapms-core` 也不受影響
- **可否與其他進行中任務平行開發**:可以。F008(`Create` / `Edit` / `Node` / `Write` 四個模組)與本
  feature 只在 `Aapms.Store.Index` 上有交集,而本 feature 只在 `indexOne` 加一處呼叫、不改任何既有
  簽名。`aapms-store.cabal` 是兩者的共用檔,由編排者單線改

## 不可逆決定

- **DEC-1:`shScore` 是 `Double` 且有文字條件時恆為正**。定義為 `negate (bm25 ...)`——SQLite 的
  `bm25()` 對命中列恆為負(其 idf 有 `1e-6` 下限,不會出現 0),取負號後恆為正,`0` 因此可以無歧義地
  保留給「沒有文字條件」。
  *否決:沿用 `Maybe Double`*——那是 2026-08-22 版為 `LIKE` 給不出分數而設的,ADR-016 已讓 `LIKE`
  退場;留著會讓 `conflict` 第 2 層與每個上層呼叫端永遠多處理一個不可能發生的 `Nothing`。
  *否決:直接把 `bm25()` 的負值攤出去*——「愈小愈相關」會讓每個消費端都得記住這個反直覺的方向,
  排序寫錯不會被型別擋住。
- **DEC-2:兩張表都命中時,`shScore` 取兩者的較大值,不是相加**。
  *否決:相加*——分數會取決於「這個查詢剛好命中幾張索引」,而那是純粹的實作產物;同一份文字用
  中文查與用英文查會拿到不可比的分數級距,排序穩定性反而更差。這條可逆(改公式即可),但它是
  對外可觀察的行為,列在這裡讓改動必須是有意識的。
- **DEC-3:`fts_cjk` 的六欄各自是「unigram + bigram」的單一混合串,且以 `fts_map` + 觸發器維護列生命
  週期**。
  *否決:legacy assetdb 的「unigram 一欄、bigram 一欄」*——那是為了避免片語比對跨越兩種 n-gram,
  但只要查詢端對同一段輸入不混用兩種(見 LAW-10),同一欄就不會有這個問題;而 design.md 的索引結構
  已經把 `fts_cjk` 定成與 `fts_tri` 相同的六欄,拆欄會讓兩張表的欄位對應不再一對一。
  *否決:讓 `Index` 逐一 `DELETE FROM fts_*`*——FTS5 虛擬表沒有外鍵,是整份 schema 裡唯一不受
  `files → nodes` 級聯保護的東西;把清理散在三、四個呼叫點上,總有一天會漏掉一個(`refreshStale`
  的檔案消失路徑最容易漏)。以 `fts_map` 承接級聯、再由觸發器補最後一段,刪除路徑一行都不用改。
  代價:必須開 `PRAGMA recursive_triggers = ON`(外鍵級聯造成的刪除預設不觸發 trigger)。
- **DEC-4:`schemaVersion` 2 → 3,不寫遷移**。ADR-013 / ADR-016 第四條的既定作法;切詞規則日後改版
  也只 bump 這個數字。
  *否決:寫 migration 把舊索引升級*——索引是衍生物,重建成本遠低於維護一條會隨切詞規則一起長的
  遷移序列。
- **DEC-5:facet 計數排除該 facet 自己的條件**(LAW-17)。
  *否決:一律套用完整條件*——當下少寫一個「條件可逐項組裝」的結構,但選了一個 tag 之後 tag 側欄
  只會剩那一個值,使用者換不掉;三個月後要補這件事,得把已經拼成單一字串的 WHERE 子句拆回可
  組裝的資料,而那時 `searchAcross`(F009)也已經建立在同一段程式碼上。
- **DEC-6:`shSnippet` 的唯一來源是 `fts_tri` 的原文,不論命中來自哪張表**(2026-08-24 開發者裁決,
  spec-gaps GAP-5;ASM-3 是它的完整敘述)。
  *否決:`fts_cjk` 命中時用該表的 `snippet()` 再還原*——`fts_cjk` 存的是「先所有 unigram、再所有
  bigram」的 token 串,而 `snippet()` 回的是**一段視窗**,不是某個 `t` 的完整 `cjkSegment` 輸出;
  還原函式的定義域從一開始就對不上,EX-6 觀察到的「魔法藥 水 瓶」是這個定義域錯配的必然結果,
  不是實作瑕疵。
  *否決:改 `cjkSegment` 的輸出格式讓它可逆*(例如在 bigram 區塊前插一個邊界標記)——那會動到
  EX-1–EX-3 已釘死的字面輸出、動到已寫入的索引內容(要 bump `schemaVersion`),而且是為了一個
  **只有呈現層在用**的需求去改**索引的表示法**,方向相反。
  代價:CJK-only 的查詢在 `fts_tri` 上沒有 `MATCH`,片段要從欄位內容自行取窗,不能用 FTS5 的
  `snippet()` 輔助函式。這條可逆(換回 `snippet()` 只影響片段的字面),但它是對外可觀察的行為。

## 骨架

| 檔案 | 內容 |
|---|---|
| `store/src/Aapms/Store/Tokenize.hs` | **新建**。`FtsText` / `FtsRow` / `SearchRoute` 三個型別;`isCjk` / `hasCjk` / `cjkRuns` / `rawFtsText` / `segmentFtsText` / `ftsRowOf` / `cjkSegment` / `usesTrigram` / `usesCjk` / `routeOf` / `triMatchExpr` / `cjkMatchExpr` / `ftsQuoted` / `ftsPhrase` 的簽名,本體全為 `undefined`。純模組,不 import SQLite。(2026-08-24 修訂:`desegmentCjk` 已移除,見 ASM-3 / LAW-4) |
| `store/src/Aapms/Store/Schema.hs` | `schemaVersion` 改 `3`;`indexTables` 尾端加三張表;`schemaDDL` 加 `fts_tri` / `fts_cjk` / `fts_map` 與 `fts_map_after_delete` 觸發器;`prepareConnection` 加 `PRAGMA recursive_triggers = ON`;新增 `insertFtsRows` 簽名(本體 `undefined`) |
| `store/src/Aapms/Store/Query.hs` | 新增 `SearchQuery` / `SearchHit` / `FacetCounts` / `SearchResult` 四個型別與 `emptySearchQuery` / `search` 的簽名(本體 `undefined`),並加進模組匯出清單 |

**骨架之外、impl 必須做的兩處接線**(不在本次寫入的檔案清單裡,由編排者協調):

1. `store/src/Aapms/Store/Index.hs` 的 `indexOne`:在既有的 `withTransaction` 之內、`action conn rel`
   之後,呼叫 `insertFtsRows (vhConn vh) (map ftsRowOf anyNodes)`。`anyNodes` 是 `planWrite` 內部
   **已經算出來**的那份清單(目前只餵給 `metaIssues`),把它一併回傳即可;純函式的預切在交易外
   算完再進交易寫,符合 ADR-022。刪除路徑(`unindexFile` / `refreshStale` 的檔案消失 /
   `rebuildIndex` 的 `DELETE FROM files`)**一行都不用改**——級聯加觸發器已經涵蓋。
2. `store/aapms-store.cabal`:`exposed-modules` 加 `Aapms.Store.Tokenize`(見回報)。

## 待確認假設

- **ASM-1**:design.md 把 FTS 列維護的歸屬留白——「Tokenize」的職責寫的是「CJK unigram / bigram 預切、
  查詢路由判斷」(純),「Schema」是「索引表結構、`schema_version`、整庫重建」。
  → **採取**:`insertFtsRows` 放 `Schema`(宣告表結構的人一併負責它的列生命週期,而且 `fts_map` 的
  觸發器本來就是 DDL 的一部分),`Tokenize` 維持純。「模組間公開介面」的 Index → Tokenize 由
  `ftsRowOf` 承接,Index 仍是發起方、預切仍只有一份。
  → **影響**:若編排者認為 FTS 列維護該獨立成一個模組(如 `Aapms.Store.Fts`),要搬的是
  `insertFtsRows` 一個函式與三段 DDL,`Tokenize` 與 `Query` 不受影響。
- **ASM-2**:`PRAGMA recursive_triggers = ON` 讓外鍵級聯觸發 `fts_map` 的 DELETE 觸發器——這條已在本機
  以 `files → nodes → fts_map → fts_tri` 的最小範例實測通過(GHC 9.14.1 + `direct-sqlite`
  `+fulltextsearch`),不是文件推論。
  → **採取**:依賴它,並在 `search` 側**同時**以 `fts_map` INNER JOIN `nodes` 過濾,使得即使有孤兒
  FTS 列也不會出現在結果裡(只會浪費空間,不會答錯)。
  → **影響**:若日後換 SQLite 版本導致觸發器不再被叫起,正確性仍然成立,只需補一次
  `rebuildIndex` 前的整批清空。
- **ASM-3**(2026-08-24 依開發者裁決改寫,原版見 spec-gaps GAP-5):契約 F 沒有規定 `snippet` 的形狀。
  → **採取**:純文字、不含任何標記(不選 HTML 或其他標記語言,那是呈現層的事),省略號 `…`;
  **`shSnippet` 一律取自該節點在 `fts_tri` 裡的內容,與這一筆命中來自哪張表無關**。`fts_tri` 存的是
  **原文**(trigram tokenizer 不做應用層預切),取出來就是連續、人看得懂的文字;`fts_cjk` 存的是
  預切後的 n-gram 串,它的視窗片段**不是原文的子字串**(會是「魔法藥 水 瓶」這種東西),不能拿來
  當 `shSnippet`。
  → **spec 對片段的要求只有兩條**(其餘屬實作層級):
  1. 有文字條件且該節點命中時,`shSnippet` 非空;沒有文字條件時為 `""`(LAW-12)
  2. 查詢字串(去頭尾空白後)在該節點的 `fts_tri` 原文六欄中確實出現時,`shSnippet` **必須包含它**
     ——EX-6 的「`shSnippet` 含『藥水』」由這一條保證
  → **視窗的挑法屬實作層級**:先找完整查詢字串、再找個別詞、都對不上時取第一個非空欄位的開頭,
  長度取多少,都由 impl 決定。CJK-only 的查詢(如二字詞)在 `fts_tri` 上沒有 `MATCH`,FTS5 的
  `snippet()` 輔助函式因此不可用,片段要由 `fts_tri` 的欄位內容自行取窗——這是「不論命中來自哪張表
  都從 `fts_tri` 取」的直接後果,不是額外的設計負擔。
  → **影響**:`desegmentCjk` 因此失去唯一的消費者,已從介面與骨架移除,LAW-4 一併撤銷(見「Laws」)。
  若上層要高亮,改的是 `SearchHit` 加一個欄位,不動查詢結構。
- **ASM-4**:純 ASCII 的一、二字元查詢(EX-14)在雙索引下必定空結果——trigram 有三字元下限,`fts_cjk`
  不收非中日韓內容,而 `LIKE` 已依 ADR-016 第二條退場。
  → **採取**:接受並寫成 Example,不特例處理。
  → **影響**:若之後判定這是不可接受的召回缺口,選項是讓 `cjkSegment` 也收錄非中日韓的**詞**
  (unicode61 對 `_` / `-` 斷詞,`ui_gui_...` 會產生 `ui` token),那是 `Tokenize` 內部的改動 +
  一次 `schemaVersion` bump,不動任何介面。
- **ASM-5**:契約卡的「索引體積對 6,783 筆 asset 在可接受範圍」依 DEC-4 等 S2 真資料進場再驗,S1 不合成
  大 fixture。本文檔沒有對應的 Law 或 Example。

## 實作備註

- `Tokenize.hs` / `Schema.hs` / `Query.hs` 三個骨架檔案的全部 `undefined`(共 18 處:
  Tokenize 15、Schema(`insertFtsRows`)1、Query(`emptySearchQuery`/`search`)2)已换成本體。
  `cabal build aapms-store`(含 lib + test 執行檔連結)通過,`-Wall -Wcompat` 無警告。
  未跑 `cabal test`(依角色隔離,測試是 qa 的產出)
- 骨架清單外的接線(委派已授權的那一處)已完成:`Index.hs` 的 `planWrite` 回傳型別加一個
  `[AnyNode]` 元素(`anyNodes`,原本已算出只餵給 `metaIssues`),`indexOne` 的
  `withTransaction` 內、`action conn rel` 之後呼叫
  `insertFtsRows (vhConn vh) (map ftsRowOf anyNodes)`。除此之外沒有再碰
  `Index.hs`/`Create.hs`/`Edit.hs`/`Node.hs`/`Write.hs`
- `triMatchExpr`:逐詞加雙引號(`ftsQuoted`)後以 `AND` 相連(要求每個詞都出現,不要求相鄰)。
  `cjkMatchExpr`:每個中日韓連續段用該段的 bigram 組成片語(`ftsPhrase`),段與段之間 `AND`;
  長度 1 的段(無 bigram)直接用該字元本身當作已加引號的詞。兩者皆屬純實作層級的演算法選擇,
  只受 LAW-9–LAW-11 與 EX-4/EX-5/EX-8–EX-10 約束,spec 未逐字規定拼法
- `search` 的合併/排序/分頁策略:文字比對統一先算出 `[(節點, 分數, 片段)]`(無文字條件時分數
  皆為 0、片段皆為空,對照 `listNodes` 語意),兩張表都命中時取分數較大者(DEC-2),再依
  「分數遞減、id 遞增」排序(LAW-14)後套用 `nfLimit`/`nfOffset`。Facet 的五個維度各自忽略自己
  的過濾條件(DEC-5)、保留其餘結構條件與文字條件重新算候選集,再依維度分組計數
- **GAP-3 / LAW-23(2026-08-24 開發者裁決後已 resolved)**:上一輪 impl 曾把
  `Query.hs:16` 模組 Haddock 裡的獨立詞 `LIKE` 改寫掉,讓 LAW-23 字面上勉強成立,但 GAP-3 問的語意
  問題(「原始碼」算不算含 Haddock 註解)本身沒解掉。開發者裁決直接**撤掉 LAW-23**——它想保證的
  「沒有子字串模糊比對路徑」已由 LAW-9\/LAW-10 的路由 law 涵蓋,不需要再靠文字掃描斷言。spec 的
  Laws 段已刪除線標記 LAW-23 並附撤銷理由;模組 Haddock 現在改成引用 LAW-9\/LAW-10。GAP-3 狀態
  resolved,不再是待辦
- **GAP-4\/GAP-5(2026-08-24 開發者裁決後已 resolved)**:上一輪 impl 曾發現 `L4`
  (`desegmentCjk (cjkSegment t) == T.unwords (cjkRuns t)` 對所有 `t`)在數學上不可能對所有
  輸入成立(`cjkSegment` 的「先 unigram 再 bigram」表示法本來就不可逆),已實作一個貪婪還原
  演算法當權宜之計並記錄 spec-gaps GAP-4;同時 GAP-5 指出 ASM-3 原本要求的「`fts_cjk` 命中時把
  `snippet()` 經 `desegmentCjk` 還原」在數學上也行不通(`snippet()` 給的是片段視窗,不是完整
  `cjkSegment` 輸出,片段輸入下 `desegmentCjk` 給出 `"魔法藥 水 瓶"` 這種接不回去的結果)。
  開發者裁決:**`desegmentCjk` 整個撤除**(已從 `Tokenize.hs` 的介面與骨架移除),**`L4` 撤銷**,
  **ASM-3 改寫**成本文檔目前的版本——`shSnippet` 一律取自 `fts_tri` 的原文,與命中來自哪張表無關。
  本輪 impl(定點重填 `ftsHits`)依新 ASM-3\/DEC-6 落實:`ftsHits` 只負責 `MATCH` 與結構過濾,片段
  由新增的私有 helper `ftsTriSnippets`(批次查 `fts_tri` 六欄原文,避免 N+1)與 `snippetOf`
  (純函式:找得到 `queryText` 就以出現位置裁窗、找不到就退回第一個非空欄位開頭,兩側裁斷處補
  `…`)算出。`cabal repl` 手動驗證過 EX-6 情境(`fts_tri` 存 `"魔法藥水瓶"`、查詢 `"藥水"` 經
  `fts_cjk` 命中):`shSnippet` 得到完整的 `"魔法藥水瓶"`,含查詢字串。GAP-4\/GAP-5 狀態 resolved
- **實作筆記(本輪新增)**:`ftsHits` 原本嘗試在同一句 SQL 裡把 `MATCH` 查詢與 `fts_tri` 的片段
  來源接成一次 JOIN(`table` 上跑 `MATCH`\/`bm25()`,另外再 `JOIN fts_tri ft` 取六欄原文);
  `table == "fts_tri"` 時這是對同一張虛擬表接兩次。`cabal repl` 實測 SQLite 回報
  `ambiguous column name`(FTS5 的 `MATCH`\/`bm25()` 認的是隱藏欄位的表名,不是 SQL 別名,把
  同一張表接兩次會讓這個隱藏欄位撞名;連 `WHERE m MATCH ?` 這種把主查詢也改用別名的寫法都不
  行,SQLite 回報 `no such column: m`——這個 SQLite\/FTS5 build 的 `MATCH` 只認得到字面表名)。
  改成兩次獨立查詢:`ftsHits` 只查 `MATCH` + 結構條件拿 `(id, score)`,片段交給
  `ftsTriSnippets` 對命中的 id 集合單獨查一次 `fts_tri`(不牽涉 `MATCH`,沒有自我 JOIN 問題)。
  這屬純實作層級的 SQL 寫法選擇,不影響 'ftsHits' 對外的行為契約
- 依規則本 impl 不寫、不讀任何 `store/test/` 底下的檔案;上面提到的 `cabal build` 會連帶連結
  `aapms-store-test` 執行檔(該套件的預設 build target 行為),但沒有執行測試、也沒有開檔看
  測試內容
