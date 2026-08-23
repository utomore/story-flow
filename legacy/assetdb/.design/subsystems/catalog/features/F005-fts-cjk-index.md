---
id: F005
type: feature
title: fts-cjk-index
description: FTS5 trigram 與自製 CJK bigram 雙索引的展開、全量重建與落後偵測
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F004]
related-adr: [ADR-001]
---

# F005: FTS5 雙索引與中日韓 n-gram

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

SQLite 的 FTS5 給的兩個 tokenizer 都無法單獨處理中文:`unicode61` 把整段中文當成
**一個** token(搜「金門」搜不到「金門建築」);`trigram` 可以中文子字串搜尋,
但 FTS5 規定 `MATCH` 的查詢**至少三個字元** —— 而中文雙字詞(金門、行銷、廟宇、素材)
極其常見。這是實測撞到的硬限制,不是理論推測。

解法是自己控制 token 流:把中日韓序列展開成重疊 n-gram、以空白分隔後寫進一張
`unicode61` 索引。`unicode61` 遇空白斷詞而中日韓字元本身不是分隔符,所以
「金門 門建 建築」正好是三個 token,雙字詞查詢變成精確比對。兩張索引共用 rowid,
結果可以直接聯集。

unigram 與 bigram 必須**分成兩欄**:bigram 比對倚賴片語查詢(要求 token 連續出現),
混入 unigram 會打亂相對位置而比對失敗。

## 落地位置

- `store/src/AssetDB/Store/Tokenize.hs` —— 中日韓判定、n-gram 展開(索引側)、
  查詢運算式產生(查詢側)、FTS5 字串跳脫
- `store/src/AssetDB/Store/Index.hs` —— 兩張 assets 索引的全量重建、筆數統計、落後偵測
- `store/src/AssetDB/Store/Schema.hs` —— `assets_fts` / `assets_cjk` / `notes_fts` /
  `notes_cjk` 四張 contentless FTS5 虛擬表的 DDL
- 共用此模組的下游(不屬本 feature):`ingest/src/AssetDB/Ingest/Notes.hs`
  填充 `notes_fts` / `notes_cjk`;`store/src/AssetDB/Store/Search.hs` 走查詢側(F006)

## 對外行為

對齊 design.md「對外契約」的 `AssetDB.Store.Tokenize` 與 `AssetDB.Store.Index` 兩節:

- `isCJK :: Char -> Bool`:涵蓋平假名/片假名、統一表意文字與擴充 A–F、相容表意文字、
  諺文音節。刻意寬鬆 —— 多收一個字元只是多幾個 token,漏掉一個字元就是永遠搜不到。
- `hasCJK :: Text -> Bool`。
- `CjkIndex { cjkUni, cjkBi }` 對應 `assets_cjk` 的兩個欄位;`cjkIndex :: Text -> CjkIndex`。
- `cjkUnigrams`:取出所有中日韓字元以空白分隔(`"1990 年代金門"` → `"年 代 金 門"`)。
- `cjkBigrams`:每段中日韓連續序列各自展開成重疊雙字元。**長度 1 的序列不產生 bigram**
  (由 unigram 欄負責);**不跨越非中日韓字元**(`"台灣 日本"` 不會產生「灣日」,
  那是語意上不存在的組合)。
- `cjkMatchExpr :: Text -> Maybe Text`:查詢側。不含中日韓字元時回 `Nothing`(該走 trigram);
  單字走 `uni` 欄、雙字以上走 `bi` 欄的片語比對;多段中日韓輸入各段之間以 `AND` 連接,
  段內才用片語(取全部 bigram 做單一片語會過度嚴格)。
- `ftsQuoted`:讓 `*` `:` `^` `-` `(` `)` `"` 失去運算子意義(使用者搜「blue-potion」時
  那個減號不該被解讀成 NOT),內部雙引號以重複跳脫。
- `ftsPhrase`:把已是空白分隔的 token 串包成片語查詢。
- `reindexFts :: Connection -> IO Int`:**全量**重建 `assets_fts` 與 `assets_cjk`。
  來源是 `assets ⋈ packs ⋈ authors ⋈ asset_tags ⋈ tags`,索引邏輯名稱、廠商原始檔名、
  壓縮檔內路徑、標籤、素材包名、作者;`status='archived'` 的資源不進索引;
  沒有中日韓字元的資源**不寫入** `assets_cjk`。回傳寫入列數。
- `ftsRowCount :: Connection -> IO (Int, Int)`:`(assets_fts, assets_cjk)` 兩張表的筆數。
- `ftsStale :: Connection -> IO Bool`:contentless FTS 無法自我檢查,只能比對筆數;
  不是嚴謹的一致性檢查,但足以抓到「掃描完忘記重建索引」這個實際會發生的情況。

不變量:**寫入側與查詢側必須共用 `AssetDB.Store.Tokenize`**。這是雙索引設計唯一
需要守住的一致性。

## 驗收依據

- `store/test/AssetDB/Store/TokenizeSpec.hs`
  - 「cjkBigrams」表格案例:`展開 "金門建築"`、`展開 "金門"`、`展開 "金"`(單字不產生
    bigram)、`展開 "hello world"`、`展開 "1990 年代文化風格"`、`展開 "台灣 日本"`、
    `展開 "福岡廟宇"`、`展開 "ひらがな"`;另有 `不跨越非中日韓字元`、
    `n 個字產生 n-1 個 bigram`
  - 「cjkUnigrams」:`取出所有中日韓字元`、`純 ASCII 回空字串`
  - 「cjkIndex」:`兩欄一起產生`
  - 「cjkMatchExpr」:`單字走 unigram 欄`、`雙字走 bigram 欄`、`長詞是 bigram 片語`、
    `多段中日韓以 AND 連接,段內才用片語`、
    `純 ASCII 回 Nothing —— 那種查詢該走 trigram 索引`、`中英混合只取中日韓部分`
  - 「hasCJK」:`認得中文`、`認得中英混合`、`純 ASCII 回 False`
  - 「ftsQuoted」:`包起來讓運算子失效`、`內部雙引號以重複跳脫`、`星號不再是萬用字元`
  - 「ftsPhrase」:`正規化空白`
- `store/test/AssetDB/Store/FtsSpec.hs`
  - 「SQLite 能力探測」:`編進了 FTS5`、`trigram tokenizer 可用`
  - 「assets_fts(trigram)」:`以完整詞搜尋`、
    `以子字串搜尋 —— 這是 trigram 相對於 unicode61 的主要好處`、
    `跨欄位:打作者名找得到素材`、`打廠商原始檔名也找得到`、
    `查詢裡的減號不會被當成 NOT 運算子`、`搜不到的東西回空`
  - 「中文搜尋」:`三字以上:trigram 就夠了`、`中文子字串:trigram`、
    `兩字詞:trigram 搜不到 —— 這是它的硬限制`、`兩字詞:bigram 索引找得到`、
    `bigram 索引也吃得下長詞`、`單字查詢走 unigram 欄`、
    `片語查詢不會誤中不相鄰的組合`、`多段查詢以 AND 連接`、
    `中日韓查詢不會誤中純 ASCII 資料`
- `store/test/AssetDB/Store/SearchSpec.hs`
  - 「索引維護」:`重建後筆數與資源相符`、`只有含中日韓字元的資源才進 bigram 索引`、
    `偵測得出索引落後`
