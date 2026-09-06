---
id: ADR-016
type: adr
title: fts5-dual-index-cjk
description: FTS5 以 trigram 與 unicode61 雙索引並行,讓中文二字詞可命中且有相關度分數
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-016: FTS5 雙索引,中文二字詞要能搜到

## 狀態(Status)

accepted

## 背景(Context)

FTS5 的 trigram tokenizer 對查詢有**三字元下限**。story-flow 只用 trigram,「藥水」「金門」
「琳達」這類二字詞 `MATCH` 永遠不命中;system.md 2026-08-22 版的處置是「兩字元以下改走 `LIKE`
掃描」,並因此讓 `conflict` 第 2 層的相關度分數變成 `Maybe Double`——`LIKE` 給不出分數。那條
契約外溢到了跨子系統的 DTO 形狀。

assetdb 從第一天就面對同一個問題(素材標籤大量是二字中文),做法是另建一張 `unicode61` 索引
加自製 unigram / bigram 切詞(`Store/Tokenize.hs`),兩張索引並行,已在 6,783 筆真實資料上驗證。

合併後索引只有一份(ADR-013),兩種 vault 的中文檢索必須同一套;而故事側的角色名、道具名
幾乎全是二字詞,現況等於故事側的中文檢索是壞的——沒人發現是因為沒人測過二字詞。

## 決策(Decision)

**一、兩張 FTS5 虛擬表並行,同一份來源文字**:

| 索引 | tokenizer | 負責 |
|---|---|---|
| trigram | `trigram` | 三字元以上的查詢,含英文子字串;給 bm25 相關度 |
| cjk | `unicode61` + 應用層 unigram/bigram 預切 | 一、二字元的中日韓查詢;同樣給 bm25 |

查詢依長度與字元類別路由到其中一張或兩張,結果以相關度合併。兩條路都有分數,**`conflict` 第 2 層
的相關度回歸 `Double`**,`Maybe Double` 那條契約撤銷。

**二、`LIKE` 掃描退場。** 它是 trigram 下限的權宜之計,有了 cjk 索引就沒有存在理由。

**三、`direct-sqlite` 必須 `+fulltextsearch`**,兩邊的 `cabal.project` 本來就這樣設,維持。

**四、索引是衍生物。** 切詞規則改版只需要 bump `schema_version` 讓索引整庫重建,不需要遷移。

## 考慮過的替代方案(Alternatives Considered)

- **只用 trigram + `LIKE` 退路**(story-flow 現況):簡單。放棄的理由是二字詞查詢沒有分數、
  沒有排序,而二字詞正是中文專有名詞的主要形態。
- **只用 unicode61 + 自製切詞**:一張索引。放棄的理由是英文子字串與三字以上中文的召回率不如
  trigram,且 assetdb 的實測是兩張並行效果最好。
- **引入 ICU 或 jieba 類分詞**:語意切詞最準。放棄的理由是多一個 C 相依(ICU)或一份大字典(jieba),
  違反「`aapms-core` 零重量級相依」與單一執行檔發佈;bigram 對專有名詞召回已經夠用,精度交給
  相關度排序。

## 影響(Consequences)

**正面**

- 「藥水」「琳達」在兩種 vault 都搜得到,且有排序
- `conflict` 的 `ByRetrieval` 契約變簡單(`Double`)
- 檢索實作只有一份,素材與故事共用

**負面 / 成本**

- 索引體積約 1.5–2 倍(兩張 FTS 表);對 KB 級 story vault 無感,對 asset vault 是 MB 級
- 切詞預處理在寫入路徑多一步,仍在寫交易之外完成(寫鎖預算規則)
- S1 必須補二字詞的測試——story-flow 現有測試集沒有這一類
