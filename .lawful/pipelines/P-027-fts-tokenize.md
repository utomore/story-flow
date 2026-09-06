---
id: P-027
description: 文字經 CJK 判定與分詞產生雙 FTS 列與 MATCH 表達式,查詢依內容路由
status: ready
updated: 2026-09-06
---
# P-027-fts-tokenize:文字經 CJK 判定與分詞產生雙 FTS 列與 MATCH 表達式,查詢依內容路由

## Brief
把一個節點的可搜尋文字投影成兩份六欄內容,並替一次查詢決定查哪張表、產生什麼 `MATCH` 運算式(ADR-016)。input 有兩種:寫入側是一個 `AnyNode`,查詢側是一串查詢文字;output 是寫入側的 `FtsRow`(`fts_tri` 收原文、`fts_cjk` 收預切後的 unigram 加 bigram 串)與查詢側的路由加兩個運算式。流向:字元判定 → 極大中日韓連續段 → 預切成 n-gram 串 → 六欄投影 → 兩份內容;查詢側是去頭尾空白 → 依長度與字元類別路由 → 逐詞或逐段組運算式。本模組是純的,不碰 SQLite;寫入端 `Aapms.Store.Index` 與查詢端 `Aapms.Store.Query` 共用同一段切詞程式碼,那是雙索引唯一要守住的不變量。它是子流:P-001-index-rebuild 的解譯器與 P-002-search 各引用它的一端。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `isCjk :: Char -> Bool` | 中日韓字元判定,假名與諺文也算(漏收一個字元就是永遠搜不到) | `Aapms.Store.Tokenize` | pure |
| 2 | `hasCjk :: Text -> Bool` | 這段文字裡有沒有任何中日韓字元 | `Aapms.Store.Tokenize` | pure |
| 3 | `cjkRuns :: Text -> [Text]` | 極大的中日韓連續段,依出現順序;非中日韓字元是分段點 | `Aapms.Store.Tokenize` | pure |
| 4 | `cjkSegment :: Text -> Text` | 一段文字預切成「先所有 unigram、再所有 bigram」的空白分隔串 | `Aapms.Store.Tokenize` | pure |
| 5 | `rawFtsText :: AnyNode -> FtsText` | 節點投影成六欄原文,不做切詞 | `Aapms.Store.Tokenize` | pure |
| 6 | `segmentFtsText :: FtsText -> FtsText` | 六欄逐欄套用 `cjkSegment` | `Aapms.Store.Tokenize` | pure |
| 7 | `routeOf :: Text -> SearchRoute` | 依去頭尾空白後的長度與字元類別決定查哪張表 | `Aapms.Store.Tokenize` | pure |
| 8 | `usesTrigram :: SearchRoute -> Bool` | 這條路由要不要查 `fts_tri` | `Aapms.Store.Tokenize` | pure |
| 9 | `usesCjk :: SearchRoute -> Bool` | 這條路由要不要查 `fts_cjk` | `Aapms.Store.Tokenize` | pure |
| 10 | `ftsQuoted :: Text -> Text` | 把使用者輸入包成 FTS5 的字面字串,關掉運算子語意 | `Aapms.Store.Tokenize` | pure |
| 11 | `ftsPhrase :: Text -> Text` | 把已經是空白分隔的 token 串包成片語查詢,要求連續出現 | `Aapms.Store.Tokenize` | pure |
| 12 | `triMatchExpr :: Text -> Maybe Text` | `fts_tri` 的 `MATCH` 運算式:逐詞加引號後以 AND 相連 | `Aapms.Store.Tokenize` | pure |
| 13 | `cjkMatchExpr :: Text -> Maybe Text` | `fts_cjk` 的 `MATCH` 運算式:每段的 bigram 組片語,段與段之間 AND | `Aapms.Store.Tokenize` | pure |
| 14 | `matchesQuery :: Text -> AnyNode -> Bool` | 純參考實作:同一套路由規則下,這串查詢文字打不打得中這個節點 | `Aapms.Store.Tokenize`(願望) | pure |
| o | `ftTitle :: FtsText -> Text` | 觀察:六欄的標題欄 | `Aapms.Store.Tokenize` | pure |
| o | `ftSummary :: FtsText -> Text` | 觀察:六欄的總結欄 | `Aapms.Store.Tokenize` | pure |
| o | `ftBody :: FtsText -> Text` | 觀察:六欄的正文欄;Level 與 Node 恆為空字串 | `Aapms.Store.Tokenize` | pure |
| o | `ftAliases :: FtsText -> Text` | 觀察:六欄的別名欄 | `Aapms.Store.Tokenize` | pure |
| o | `ftTags :: FtsText -> Text` | 觀察:六欄的標籤欄 | `Aapms.Store.Tokenize` | pure |
| o | `ftName :: FtsText -> Text` | 觀察:六欄的邏輯名稱欄;非 asset 恆為空字串 | `Aapms.Store.Tokenize` | pure |
| o | `frNode :: FtsRow -> Id` | 觀察:這一列屬於哪個節點 | `Aapms.Store.Tokenize` | pure |
| o | `frTri :: FtsRow -> FtsText` | 觀察:寫進 `fts_tri` 的內容 | `Aapms.Store.Tokenize` | pure |
| o | `frCjk :: FtsRow -> FtsText` | 觀察:寫進 `fts_cjk` 的內容 | `Aapms.Store.Tokenize` | pure |
| o | `stripText :: Text -> Text` | 觀察:去頭尾空白,路由與運算式的判斷對象 | `Aapms.Store.Tokenize.Internal`(願望) | pure |
| o | `upperAscii :: Text -> Text` | 觀察:ASCII 大寫化,寫出「不分大小寫」用 | `Aapms.Store.Tokenize.Internal`(願望) | pure |
| o | `wordHits :: Text -> AnyNode -> Bool` | 觀察:一個詞在 trigram 路由下打不打得中這個節點 | `Aapms.Store.Tokenize.Internal`(願望) | pure |
| o | `runHits :: Text -> AnyNode -> Bool` | 觀察:一段中日韓在 cjk 路由下打不打得中這個節點 | `Aapms.Store.Tokenize.Internal`(願望) | pure |
| = | `ftsRowOf :: AnyNode -> FtsRow` | 純的整條:一個節點要寫進兩張 FTS 表的完整內容 | `Aapms.Store.Tokenize` | pure |

## Laws
- LAW-1 [invariant] 切出來的每個 token 只由中日韓字元組成,長度是 1 或 2
  - forall t in Text, tok in words (cjkSegment t)
  - |- all isCjk tok and elem (length tok) [1, 2]
- LAW-2 [relation] 每個中日韓字元都以一個長度 1 的 token 依原文順序出現
  - forall t in Text
  - |- mconcat (filter ((== 1) . length) (words (cjkSegment t))) == filter isCjk t
- LAW-3 [relation] 長度 2 的 token 一定落在某一個中日韓連續段裡,不跨段
  - forall t in Text, tok in filter ((== 2) . length) (words (cjkSegment t))
  - |- any (isInfixOf tok) (cjkRuns t)
- LAW-4 [relation] bigram 的個數是每一段長度減一的總和
  - forall t in Text
  - |- length (filter ((== 2) . length) (words (cjkSegment t))) == sum (map pred (map length (cjkRuns t)))
- LAW-5 [relation] 不含中日韓字元的文字切出來是空的,分段也是空的
  - forall t in Text
  - given not (hasCjk t)
  - |- cjkSegment t == "" and cjkRuns t == []
- LAW-6 [equiv] hasCjk 就是「有中日韓字元」,也等價於分段非空
  - forall t in Text
  - |- hasCjk t == any isCjk t and hasCjk t == not (null (cjkRuns t))
- LAW-7 [relation] 六欄是純投影:標題與總結逐字,別名與標籤以單一空白接起來
  - forall n in AnyNode
  - |- ftTitle (rawFtsText n) == metaTitle (anyMeta n) and ftSummary (rawFtsText n) == metaSummary (anyMeta n) and ftAliases (rawFtsText n) == unwords (metaAliases (anyMeta n)) and ftTags (rawFtsText n) == unwords (metaTags (anyMeta n))
- LAW-8 [relation] 一列的兩份內容:trigram 側是原文,cjk 側是逐欄預切,列的身分是節點 id
  - forall n in AnyNode
  - |- frNode (ftsRowOf n) == metaId (anyMeta n) and frTri (ftsRowOf n) == rawFtsText n and frCjk (ftsRowOf n) == segmentFtsText (rawFtsText n)
- LAW-9 [relation] 預切是逐欄套用同一個 cjkSegment
  - forall ft in FtsText
  - |- ftTitle (segmentFtsText ft) == cjkSegment (ftTitle ft) and ftSummary (segmentFtsText ft) == cjkSegment (ftSummary ft) and ftBody (segmentFtsText ft) == cjkSegment (ftBody ft) and ftAliases (segmentFtsText ft) == cjkSegment (ftAliases ft) and ftTags (segmentFtsText ft) == cjkSegment (ftTags ft) and ftName (segmentFtsText ft) == cjkSegment (ftName ft)
- LAW-10 [relation] 路由只看去頭尾空白後的字串:含中日韓才查 cjk,不含中日韓或長度三個字元以上才查 trigram
  - forall t in Text
  - |- usesTrigram (routeOf t) == (not (hasCjk (stripText t)) or length (stripText t) >= 3) and usesCjk (routeOf t) == hasCjk (stripText t)
- LAW-11 [relation] 兩個 MATCH 運算式的有無與路由一致
  - forall t in Text
  - |- isJust (cjkMatchExpr t) == usesCjk (routeOf t) and isJust (triMatchExpr t) == not (null (stripText t))
- LAW-12 [relation] 字面字串首尾加雙引號、內部雙引號加倍;片語是空白正規化後的字面字串
  - forall t in Text
  - |- isPrefixOf "\"" (ftsQuoted t) and isSuffixOf "\"" (ftsQuoted t) and ftsPhrase t == ftsQuoted (unwords (words t))
- LAW-13 [relation] 去頭尾空白後為空的查詢誰都不命中
  - forall t in Text, n in AnyNode
  - given null (stripText t)
  - |- not (matchesQuery t n)
- LAW-14 [relation] 一個詞命中 = 它不分大小寫是六欄原文之一的子字串,且長度至少三個字元
  - forall w in Text, n in AnyNode
  - |- wordHits w n == (length w >= 3 and any (isInfixOf (upperAscii w)) (map upperAscii [ftTitle (rawFtsText n), ftSummary (rawFtsText n), ftBody (rawFtsText n), ftAliases (rawFtsText n), ftTags (rawFtsText n), ftName (rawFtsText n)]))
- LAW-15 [relation] 一段中日韓命中 = 它以連續子字串出現在六欄原文之一
  - forall r in Text, n in AnyNode
  - |- runHits r n == any (isInfixOf r) [ftTitle (rawFtsText n), ftSummary (rawFtsText n), ftBody (rawFtsText n), ftAliases (rawFtsText n), ftTags (rawFtsText n), ftName (rawFtsText n)]
- LAW-16 [equiv] 只查 trigram 時,命中就是「查詢的每一個詞都命中」
  - forall t in Text, n in AnyNode
  - given usesTrigram (routeOf t)
  - given not (usesCjk (routeOf t))
  - |- matchesQuery t n == (not (null (stripText t)) and all (flip wordHits n) (words (stripText t)))
- LAW-17 [equiv] 只查 cjk 時,命中就是「查詢的每一個中日韓連續段都命中」
  - forall t in Text, n in AnyNode
  - given usesCjk (routeOf t)
  - given not (usesTrigram (routeOf t))
  - |- matchesQuery t n == all (flip runHits n) (cjkRuns (stripText t))
- LAW-18 [equiv] 兩張都查時,任一邊命中就算命中
  - forall t in Text, n in AnyNode
  - given usesCjk (routeOf t)
  - given usesTrigram (routeOf t)
  - |- matchesQuery t n == (all (flip wordHits n) (words (stripText t)) or all (flip runHits n) (cjkRuns (stripText t)))
- LAW-19 [invariant] 純 ASCII 的查詢不分大小寫
  - forall t in Text, n in AnyNode
  - given not (hasCjk t)
  - |- matchesQuery t n == matchesQuery (upperAscii t) n
- LAW-20 [bound] 純 ASCII 的一、二字元查詢在雙索引下必定不命中(trigram 的三字元下限;ADR-016 第二條讓 LIKE 退場的已知代價)
  - forall t in Text, n in AnyNode
  - given not (hasCjk t)
  - given not (null (stripText t))
  - given length (stripText t) < 3
  - |- not (matchesQuery t n)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `cjkSegment ""`、`cjkSegment "hello"`、`cjkSegment "金"` | `""`、`""`、`"金"`;前兩者的 `cjkRuns` 是 `[]`,`hasCjk` 為 `False` | LAW-5、LAW-6 |
| EX-2 | `cjkSegment "金門建築"` | `"金 門 建 築 金門 門建 建築"`——unigram 在前、bigram 在後 | LAW-1、LAW-2、LAW-4 |
| EX-3 | `cjkSegment "台灣 日本"` | `"台 灣 日 本 台灣 日本"`——不產生「灣日」 | LAW-3、LAW-4 |
| EX-4 | `cjkSegment "藥水"` | `"藥 水 藥水"`;長度 1 的 token 串起來是 `"藥水"` | LAW-1、LAW-2 |
| EX-5 | `routeOf "藥水"`、`routeOf "travel-book"`、`routeOf "藥水 potion"`、`routeOf "   "` | `CjkOnly`、`TrigramOnly`、`BothIndexes`、`TrigramOnly`;`usesTrigram` / `usesCjk` 依序是 (F,T) / (T,F) / (T,T) / (T,F) | LAW-10 |
| EX-6 | `triMatchExpr "   "`、`cjkMatchExpr "travel-book"`、`triMatchExpr "藥水"` | `Nothing`、`Nothing`、`Just`——與 `routeOf` 的三條路由一致 | LAW-11 |
| EX-7 | `ftsQuoted "blue-potion"`、`ftsQuoted "他說\"好\""`、`ftsPhrase "  金門   門建  "` | `"\"blue-potion\""`、`"\"他說\"\"好\"\"\""`、`"\"金門 門建\""` | LAW-12 |
| EX-8 | `NLevel` 與 `NNode` 兩個節點 | `ftBody (rawFtsText n) == ""`;非 asset 的 `ftName` 也是 `""` | LAW-7 |
| EX-9 | `title` 為「琳達」、`aliases` 為 `["Linda", "琳"]`、`tags` 為 `["角色", "主角"]` 的 Entity | `ftTitle == "琳達"`、`ftAliases == "Linda 琳"`、`ftTags == "角色 主角"` | LAW-7 |
| EX-10 | `name` 為 `ui_gui_travel-book-frame_001` 的 asset,`ftsRowOf n` | `frNode` 是該 asset 的 `metaId`;`frTri` 逐欄等於 `rawFtsText n`;`frCjk` 的每一欄等於對應欄的 `cjkSegment`(純 ASCII 的 `ftName` 因此是 `""`) | LAW-8、LAW-9 |
| EX-11 | 含「魔法藥水瓶」的 asset,查詢 `"藥水"` | `routeOf` 是 `CjkOnly`;`matchesQuery "藥水" n` 為 `True`(二字中文命中,契約卡驗收標準) | LAW-13、LAW-17 |
| EX-12 | `title` 為「琳達」的角色主體,查詢 `"琳達"` 與 `"  琳達  "` | 兩者都命中,結果相同(判斷對象是去頭尾空白後的字串) | LAW-17 |
| EX-13 | 查詢 `""` 與 `"   "` 對任何節點 | `matchesQuery` 一律 `False` | LAW-13 |
| EX-14 | `name` 為 `ui_gui_travel-book-frame_001` 的 asset,查詢 `"travel-book"` 與 `"TRAVEL-BOOK"` | 兩者都命中且結果相同(英文子字串走 trigram,`-` 不被當成運算子) | LAW-14、LAW-16、LAW-19 |
| EX-15 | 查詢 `"ui"`(純 ASCII 二字) | `matchesQuery` 為 `False`——trigram 的三字元下限,`fts_cjk` 不收非中日韓內容 | LAW-20 |
| EX-16 | 查詢 `"travel-book frame"`,節點只有 `travel-book` 沒有 `frame` | 不命中——每個詞都要出現 | LAW-14、LAW-16 |
| EX-17 | 一個節點的 `title` 同時含「藥水」與 `potion`,查詢 `"藥水 potion"` | `routeOf` 是 `BothIndexes`;`matchesQuery` 為 `True` | LAW-18 |
| EX-18 | 查詢 `"魔法藥水"`(四字),節點含「魔法藥水瓶」 | `routeOf` 是 `BothIndexes`;cjk 那一側命中,因此整體命中 | LAW-18 |
| EX-19 | 查詢 `"金門建築"`,一個節點含「金門」與不相鄰的「建築」 | 不命中——每一段中日韓要以連續子字串出現 | LAW-15、LAW-17 |
| EX-20 | 查詢 `"台灣 建築"`,節點含「台灣」與「建築」兩段但不相鄰 | 命中——各段之間是 AND,段內才要求連續 | LAW-15、LAW-17 |

## 決定
- **`fts_cjk` 的每一欄是「先所有 unigram、再所有 bigram」的單一混合串,不拆成兩欄。** 否決:legacy assetdb 的「unigram 一欄、bigram 一欄」。理由:只要查詢端對同一段輸入不混用兩種長度的 token(LAW-11 / LAW-17),同一欄就不會有片語跨界的問題;拆欄會讓兩張表的六欄不再一對一
- **這個表示法是單向的,沒有反函式,不做 `desegmentCjk`。** 否決:加一個還原函式。理由:同一個字元的重複剛好落在兩個 `cjkRuns` 段的邊界上時,兩個分段不同的輸入會給出逐字元相同的輸出,任何確定性的還原都不可能同時等於兩個答案——這條性質在數學上不可滿足。需要給人看的連續文字時一律從 `fts_tri` 的原文取
- **片段(`shSnippet`)的唯一來源是 `fts_tri` 的原文,不論命中來自哪張表。** 否決:`fts_cjk` 命中時用該表的視窗片段再還原。理由:`snippet()` 回的是一段視窗而不是某段文字完整的 `cjkSegment` 輸出,還原函式的定義域從一開始就對不上;為了一個只有呈現層在用的需求去改索引的表示法,方向相反
- **切詞規則改版只靠 bump `schemaVersion` 整庫重建,不寫任何遷移程式。** 否決:寫 migration 把舊索引升級。理由:索引是衍生物,重建成本遠低於維護一條會隨切詞規則一起長的遷移序列。證據:ADR-016-fts5-dual-index-cjk
- **中日韓判定寧可多收不可漏收,假名與諺文都算。** 否決:只收 CJK 統一表意文字。理由:判斷錯的代價不對稱——多收一個字元只是多幾個 token,漏掉一個字元就是永遠搜不到
- **`cjkRuns` 以非中日韓字元分段,bigram 不跨段。** 否決:整串一起取相鄰字元對。理由:「台灣 日本」會產生「灣日」,搜「灣日」會誤中一筆語意上不存在的結果
- **FTS 列的落地(`insertFtsRows`)歸宣告表結構的 `Aapms.Store.Schema`,本模組維持純的。** 否決:FTS 列維護獨立成一個模組。理由:`fts_map` 的觸發器本來就是 DDL 的一部分,宣告表結構的人一併負責它的列生命週期;寫入端的單一入口由 `ftsRowOf` 承接,預切仍只有一份
- **外鍵級聯造成的刪除靠 `PRAGMA recursive_triggers = ON` 觸發 `fts_map` 的 DELETE 觸發器,並在查詢側同時以 `fts_map` INNER JOIN `nodes` 過濾。** 否決:讓寫入端在三、四個呼叫點各自 `DELETE FROM fts_*`。理由:FTS5 虛擬表沒有外鍵,把清理散開總有一天會漏掉一個;雙保險讓孤兒列只浪費空間、不會答錯
- **純 ASCII 的一、二字元查詢必定空結果,接受並寫成 law 與 example,不特例處理。** 否決:讓 `cjkSegment` 也收錄非中日韓的詞。理由:那是 `Tokenize` 內部的改動加一次 `schemaVersion` bump,現在還沒有證據說這個召回缺口不可接受
- **`matchesQuery` 是願望 stage:一個純的參考 oracle,不碰 SQLite。** 否決:只用真的 `search` 驗雙索引的行為。理由:路由與命中規則是純性質,現在靠 SQLite 才驗得到等於把 law 綁在一個 IO 邊界上;有了 oracle,P-002-search 的 `search` 才有「慢但一定對」的對照組
- **兩張表都命中時 `shScore` 取兩者的較大值,不是相加。** 否決:相加。理由:分數會取決於「這個查詢剛好命中幾張索引」,而那是純粹的實作產物;同一份文字用中文查與用英文查會拿到不可比的分數級距。這條決定由 P-002-search 承接落地
- **`shScore` 是 `Double` 且有文字條件時恆為正,`0` 保留給「沒有文字條件」。** 否決:沿用 `Maybe Double`。理由:那是為 `LIKE` 給不出分數而設的,ADR-016 已讓 `LIKE` 退場;留著會讓每個上層呼叫端永遠多處理一個不可能發生的 `Nothing`。這條決定由 P-002-search 承接落地
- **facet 計數排除該 facet 自己的條件。** 否決:一律套用完整條件。理由:選了一個 tag 之後 tag 側欄只會剩那一個值,使用者換不掉。這條決定由 P-002-search 承接落地

## 修訂記錄
無
