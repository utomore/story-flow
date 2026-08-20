---
id: F003
type: feature
title: conflict-retrieval
description: 衝突偵測第 2 層:關鍵詞撈候選,含 canon/timeline 過濾與一跳擴充
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003]
related-adr: [ADR-003, ADR-005, ADR-006, ADR-007]
related-feature: []
---

# F003: 衝突偵測第 2 層(候選撈取)

## 功能概述

`conflict-detection` 階段一的第三項。給一段草稿文字,回答**哪些既有的 canon 片段和它有關**
——注意是「有關」不是「矛盾」:第 2 層只負責把比對範圍從整個 Vault 收斂到 top-N,
判斷矛盾是第 3 層的事(ADR-007)。

這一層是 ADR-007 那句「大部分查詢在前兩層就結束」的承載者,也是 `story-flow context`
(F004)唯一的候選來源。它完全確定性:同一份草稿加同一份 Vault 永遠得到同一批候選,
沒有模型、沒有隨機性。

本 feature 除了 `Conflict.Retrieval` 本身,還**負責實作兩項跨子系統的契約變更**
(編排者已回寫 `service-and-interfaces/design.md`,見「對應的 Level 2 契約」):

- `SearchHit` 新增 `shScore :: Maybe Double`,以及它在 `store` 端的資料來源(FTS5 的 bm25)
- `StoryFlow.Service` 新增 `aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]`

明確**不做**:語意判斷(第 3 層)、embedding 模型與第二套索引、重複 FTS5 的兩字詞處理
(那在 `entity-graph-core` 的 `searchEntities`)、三層合流與排序(`Conflict.Pipeline`)、
CLI 與 REST 接線(F004)、任何資料修改。

驗收標準:

1. `coTopN` 控制最終候選數且預設保守(`defaultConflictOpts` 已是 20);SQL 端撈的是它的數倍
2. 只有 `metaStatus = Canon` 的片段成為比對基準(ADR-003),過濾發生在 SQL(`efStatus`)
3. 關鍵詞抽取**兩路併用**:既有 canon 名稱的反向比對 + 依標點空白切詞,合併去重
4. `coTimelineWindow` 有值時,`tlOrder` 距離超出容許範圍的候選被剔除;`tlOrder` 為 `Nothing`
   的候選不受影響(`tlLabel` 是模糊字串,算不出距離)
5. **過度撈取再截斷**:timeline 過濾在 SQL 之後、截到 `topN` 之前;`rrScanned` 記的是
   實際掃過的候選數(含被過濾掉的)
6. 候選以 `partOf` / `occursIn` 一跳擴充,擴充來的候選標得出「從誰、經哪條關聯來的」
7. `ByRetrieval` 的分數:FTS5 路徑用正規化後的 bm25;`shScore = Nothing`(LIKE 路徑)時
   **依名次推導**,且推導出的分數封頂在 0.5 以下——不與真實相關度混為一談
8. 換一種關鍵詞策略只需換 `KeywordStrategy` 一個值,第 1、3 層與 `Conflict.Pipeline` 都不動
9. `storyflow-conflict` 的 `build-depends` 長出 `storyflow-service`,但**仍然不含**
   `storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple`

## 相依性

`depends-on: [F001, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001,
service-and-interfaces/F002, service-and-interfaces/F003]`。

委派 prompt 建議的起始值是 `[F001, service-and-interfaces/F001]`;查證介面表之後**擴充成六項**,
理由逐條如下(全部由「使用到的既有串接介面」表反推,不是憑印象填的):

- **F001(conflict-types)**:`Draft` / `ConflictOpts` / `HitLayer` / `ConflictHit` / `ContextHit`
  全部由它定義,`storyflow-conflict` 套件本身也是它建立的。已 `done`
- **entity-graph-core/F002(core-types-and-registry)**:`Meta` / `Timeline` / `Status` / `isCanon` /
  `Id` / `Ref` / `Link` / `LinkKind` 都來自 core。已 `done`
- **entity-graph-core/F004(store-vault-io-and-index)**:`EntityFilter` / `emptyFilter` 是候選撈取
  的過濾詞彙;`searchEntities` 的兩條查詢路徑(FTS5 vs LIKE)是分數來源,**本 feature 會改它的
  簽名**。已 `done`
- **service-and-interfaces/F001(service-contract)**:`ServiceM` / `Env` / `searchEntity` /
  `listEntities` / `linksOf` / `getEntity` / `SearchHit` / `LinkReport`,以及本 feature 要動的
  `Service.Types` 與 `Service.Json`。已 `done`
- **service-and-interfaces/F002(cli-embedded)**:`renderSearch` 的 `SearchHit` 建構會因 `shScore`
  而改,對應測試也要改。已 `done`
- **service-and-interfaces/F003(servant-api-server)**:`instance ToSchema SearchHit` 與
  `SchemaSpec` 的「`ToJSON` 與 `ToSchema` 逐欄對齊」斷言會因 `shScore` 而改。已 `done`

**可否平行開發**:上列六項**全部已實作完成並併入 main**,沒有紙上約定的相依,本 feature 現在
就能開工。與 `F002`(conflict-graph,第 1 層)在**設計上完全平行**——兩者只共用 F001 的型別,
互不引用;但兩者改的是同一個套件的同一批檔案(`conflict/storyflow-conflict.cabal`、
`conflict/test/Spec.hs`),因此**實作要序列化**(build-log 已排 F002 → F003 → F004)。

與 `llm-workshop-mcp` 完全無相依:本層不碰 LLM。

## 對應的 Level 2 契約

### 落在契約內的部分

| 契約來源 | 條目 | 本 feature 的實作 |
|---|---|---|
| `conflict-detection/design.md`「內部模組劃分」 | `Conflict.Retrieval`(第 2 層) | 新增 `StoryFlow.Conflict.Retrieval` 模組 |
| 同上「資料流管線」 | 第 2 層:`草稿關鍵詞 + aliases → service 的 searchEntity → top-N → canon 過濾 → timeline 過濾 → partOf / occursIn 一跳擴充` | 本文檔「實作方式」逐段落實 |
| 同上「模組間公開介面」 | `Conflict.Retrieval → service-and-interfaces`:經 `ServiceM` 呼叫 `searchEntity`,不自己開索引連線 | 全部讀取走 `ServiceM`;`build-depends` 不含 `storyflow-store` |
| 同上「模組間公開介面」 | 三層都只吐 `ConflictHit` / `ContextHit`,證據放進 `HitLayer` | `candidateConflictHit` / `candidateContextHit`,`HitLayer` 恆為 `ByRetrieval` |
| `service-and-interfaces/design.md`「線上資料格式」 | `SearchHit` 自 2026-08-20 起帶 `shScore :: Maybe Double`(0–1,越大越相關;LIKE 路徑給 `Nothing`) | T1 / T2 |
| `service-and-interfaces/design.md`(編排者已回寫的 S3) | `aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]`,只開內嵌出口 | T3 |

**不新增任何對外契約**:`checkConflict` / `gatherContext` 兩個出口由 F004 / F006 接線,本 feature
交付的 `retrieveCandidates` 是 `Conflict.Pipeline` 的內部輸入,不出現在 CLI 與 REST。

### 超出契約、需要編排者裁決的一項

`entity-graph-core/design.md`「對外契約 — 落地操作」第 79 行目前寫的是:

```haskell
searchEntities   :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]
```

要讓 `SearchHit.shScore` 有東西可裝,這個簽名必須變成回三元組(見 T1)。**這是
`entity-graph-core` 的 Level 2 契約變更**,而編排者的 S2 只回寫了 `service-and-interfaces` 的
`design.md`。依委派模式第 4、6 條,本 feature **不自行修改 `design.md`**:設計照 S2 的決定寫完,
但實作開工前需要編排者補寫 `entity-graph-core/design.md`(見「待確認假設」A1 與回報)。

## 實作方式

### 一、整體資料流

```text
Draft { drText, drRefs }              ConflictOpts { coTopN, coTimelineWindow }
        │                                      │
        ▼                                      │
  aliasIndex (efStatus = Just Canon)           │   ← S3 的新出口
        │  [(Id, [Text])] = id → title : aliases
        ▼                                      │
  KeywordStrategy(可替換的策略接縫)            │
   ├─ (a) matchedNames:既有名稱出現在草稿裡?  │
   └─ (b) segmentDraft:依標點/空白切詞         │
        │  合併去重、上限 maxKeywords           │
        ▼                                      │
  每個關鍵詞一次 searchEntity                   │
    filter = emptyFilter { efStatus = Just Canon
                         , efLimit  = Just (coTopN * overFetchFactor) }   ← 過度撈取
        │  [SearchHit]:shMeta / shSnippet / shScore
        ▼
  mergeCandidates:依 metaId 去重,同 id 取最高分
        │  [Candidate](caOrigin = FromKeyword kw)
        ▼
  timelineAnchors ← drRefs 的 tlOrder(經 getEntity,查不到的略過)
  withinWindow 過濾                              ← 過濾在 SQL 之後、截斷之前
        │
        ▼
  一跳擴充:對存活候選跑 linksOf,取 partOf / occursIn 的本地目標
        │  目標的 Meta 經 getEntity 取得,非 canon 者丟棄
        │  分數 = 母候選分數 * expansionDecay(恆低於母候選)
        ▼
  合併 → 依 (分數遞減, id 字典序) 排序 → take coTopN
        │
        ▼
  RetrievalResult { rrCandidates, rrScanned, rrKeywords }
        │              ▲
        │              └─ rrScanned = 掃過的相異 id 數(含被 timeline 剔除的)
        ├─ candidateContextHit → ContextHit(F004 的 context 出口)
        └─ candidateConflictHit → ConflictHit(F006 合流用,HitLayer = ByRetrieval)
```

### 二、`shScore` 的資料來源(store → service → 三個介面)

**store 端**。`ftsQuery` 目前是 `ORDER BY rank` 但 `SELECT` 沒把 rank 取出來,所以分數在 SQL
裡算完就丟掉了。改法是 `SELECT` 加一欄 `bm25(entities_fts)`,`likeQuery` 對應位置 `SELECT NULL`
——兩條路徑因此共用同一個 row 型別 `(Text, Text, Maybe Double)`,`run` 不必分岔。

`entities_fts` 是**一般 FTS5 表**(`Store.Schema` 明說不是 contentless),`bm25()` 與 `rank`
都可用,這一點已由既有 schema 保證。

正規化:bm25 回的是**負值,越負越相關**,而契約要的是「0–1 越大越相關」。

```haskell
-- | bm25 → (0,1) 的單調遞增壓縮。
--   rel = max 0 (negate raw);score = rel / (1 + rel)
normalizeBm25 :: Double -> Double
```

選這個式子而不是「結果集內 min-max」的理由:min-max 會讓**每一次查詢的最高分都恰好是 1.0**,
不同查詢之間的分數就完全不可比,而第 2 層要把多個關鍵詞的結果合併排序——那正需要跨查詢可比。
`rel / (1 + rel)` 是純函式、與結果集無關、保序,且永遠落在開區間 (0,1)。

**LIKE 路徑一律 `Nothing`**。那條查詢是 `ORDER BY e.id`,連名次都不是相關度名次;合成一個分數
會讓兩種完全不同的東西在型別上長得一模一樣(build-log S2 的原話)。

**service 端**。`searchEntity` 把三元組攤進 `SearchHit`,不做任何加工。

**三個介面的連帶更新**(build-log S2 的「連帶影響」,逐一列出免得漏):

| 檔案 | 改什麼 |
|---|---|
| `service/src/StoryFlow/Service/Types.hs` | `SearchHit` 加 `shScore :: Maybe Double` |
| `service/src/StoryFlow/Service/Json.hs` | `ToJSON` 用既有的 `optional "score"`(沒值時整個鍵不出現);`FromJSON` 用 `.:? "score"` |
| `api/src/StoryFlow/Api/Instances.hs` | `ToSchema SearchHit` 的 `properties` 加 `score`,**required 不加**(它是選配) |
| `api/test/StoryFlow/Api/Fixtures.hs` | `sampleSearchHit` 補 `Just 0.87` ——`SchemaSpec` 的樣本刻意要把選配欄位填滿,否則鍵集合比對會假性不一致 |
| `cli/src/StoryFlow/Cli/Render.hs` | `renderSearch` 的 pattern 改成帶三欄;**人類模式的表格不加 score 欄**(S2 只要求 `--json`,多一欄會把本來就很寬的表格擠爆) |
| `cli/test/StoryFlow/Cli/RenderSpec.hs`、`service/test/.../JsonSpec.hs`、`store/test/.../SearchSpec.hs`、`store/test/.../EndToEndSpec.hs` | 建構子與 accessor 跟著改(細節見測試對照表 T2) |

`server/test/.../HandlerSpec.hs` 與 `service/test/.../EntityReadSpec.hs` 用的是 record accessor
(`shSnippet` / `shMeta`),**不受影響**;查證過,不必改。

### 三、`aliasIndex`(S3)

```haskell
aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]
```

每一筆是 `(metaId, metaTitle : metaAliases)` ——標題排第一,因為它是最常被寫進草稿的名稱。
實作**建在既有的 `listEntities` 之上**,不新增 store 查詢:`listEntities` 已經 `ORDER BY e.id`,
輸出順序天然確定;而 S3 在 build-log 裡的「傳輸量小得多」論據只對 REST 成立,而這個出口
**明確不開 CLI 與 REST**(見 A2)。

吃 `EntityFilter` 是為了沿用既有詞彙:呼叫端傳 `emptyFilter { efStatus = Just Canon }`,
`Conflict.Retrieval` 因此不必自己發明一組過濾參數。

空字串名稱要濾掉(`metaAliases` 允許使用者寫空項),否則 `T.isInfixOf ""` 對任何草稿都成立,
每個片段都會變成關鍵詞命中。

### 四、關鍵詞抽取(D2:兩路併用)

策略接縫:

```haskell
newtype KeywordStrategy = KeywordStrategy
  { runKeywordStrategy :: [(Id, [Text])] -> Text -> [Text] }
```

這就是 ADR-007「第 2 層的介面刻意設計成候選撈取策略可替換」與驗收標準 8 的落點:未來要加
embedding,是多一個 `KeywordStrategy`(或在它之後多一路合併),第 1、3 層與 `Conflict.Pipeline`
完全不動。

**(a) 反向比對 `matchedNames`**:走 `aliasIndex` 的每一個名稱,長度 ≥ 2 且 `T.isInfixOf` 草稿
的收進來。這是 ADR-007「比對到的 aliases」的字面意思——精準、零誤判,而且中文完全不受
斷詞問題影響。順序沿用 `aliasIndex`(id 字典序)以保證確定性。

**(b) 切詞 `segmentDraft`**:以 `not . isAlphaNum` 為切點切草稿。`Data.Char.isAlphaNum` 對中日韓
表意文字回 `True`(它們的 general category 是 `OtherLetter`),對全形標點與全形空白回 `False`
——所以同一條規則同時處理了中文標點與英文空白,不必自己列標點表。

- 長度 < `segMinLen`(2)的片段丟掉:一個字的召回率等於雜訊
- 長度 > `maxKeywordLen`(8)的片段切成 `chunkLen`(4)的**不重疊**塊,尾巴不足 2 字的丟掉。
  沒有標點的長串中文(「琳達在埃提亞崩塌之後失去雙親」)否則會變成一個誰都命不中的巨型
  phrase query。切成任意邊界的 4 字塊仍然有效,因為索引是 **trigram**:`提亞崩塌` 的 trigram
  是 `提亞崩` / `亞崩塌`,照樣命中含「埃提亞崩塌」的正文
- 去重保序

**合併**:`matchedNames` 在前(精準的先撈)、`segmentDraft` 在後,去重後截到 `maxKeywords`(16)。
截斷上限是成本閘門:每個關鍵詞是一次 SQL,沒有上限的話一段長草稿可以打出上百次查詢
(見 A3)。

只做其中一路都不合格,理由已寫在契約卡:只切詞則中文沒有空白、品質全看作者標點;只比對
alias 則作者沒寫 alias 的片段完全撈不到,等於把 ADR-007 的緩解措施當成唯一手段。

### 五、候選撈取與分數(C5:過度撈取再截斷)

每個關鍵詞一次:

```haskell
searchEntity kw emptyFilter { efStatus = Just Canon
                            , efLimit  = Just (coTopN opts * overFetchFactor) }
```

`overFetchFactor = 4`。`EntityFilter` 沒有 timeline 欄位,timeline 過濾只能發生在 SQL 之後
——先撈 `topN` 再過濾,會讓「開了 timeline window 之後候選憑空少一截」,而調大 `topN` 也未必
補得回來(契約卡原話)。

`efStatus = Just Canon` 是**在 SQL 裡**過濾的,不是撈回來再篩:`whereOf` 已經支援
`AND e.status = ?`,讓 SQLite 做這件事比撈回一堆 draft 再丟掉便宜得多,而且 `efLimit` 才不會
被 draft 片段吃掉名額。

**分數取用**:

```haskell
-- | shScore 有值就用;Nothing(LIKE 路徑)依名次推導。
--   1 / (k + 2):k = 0 給 0.5,之後遞減。封頂 0.5 是刻意的——
--   LIKE 路徑的名次是 id 字典序,它不知道自己有多相關,不該壓過任何一個真實的 bm25 高分。
rankFallbackScore :: Int -> Double
rankFallbackScore k = 1 / fromIntegral (k + 2)
```

**合併去重** `mergeCandidates`:依 `metaId` 去重,同 id 取**最高分**那一筆(連同它的 snippet 與
來源關鍵詞)。分數相同時取關鍵詞順序較前的——關鍵詞順序本身確定,合併因此也確定。

### 六、timeline 過濾

`ConflictOpts.coTimelineWindow :: Maybe Int` 是「比對 `tlOrder` 的容許距離」,但 **`Draft` 沒有
timeline 欄位**——距離要對誰算?本設計取**草稿已引用片段的 `tlOrder` 當基準點**
(`drRefs` → `getEntity` → `metaTimeline` → `tlOrder`),這是草稿身上唯一的時序線索(見 A4)。

```haskell
timelineAnchors :: [Id] -> ServiceM [Int]     -- 查不到的 id 略過,不讓整條管線失敗
withinWindow :: Maybe Int -> [Int] -> Meta -> Bool
```

保留規則(任一成立就留下):

1. `coTimelineWindow == Nothing` ——沒開過濾
2. 基準點為空 ——`drRefs` 是空的、或它們都沒有 `tlOrder`。**沒有基準就不過濾**,
   而不是全部剔除:後者會讓一個沒填 timeline 的 Vault 在使用者加了 `--timeline-window` 之後
   靜默回空清單
3. 候選的 `tlOrder == Nothing` ——`tlLabel` 是模糊字串(「崩塌前後」),算不出距離
   (F001 的欄位註解已經言明)
4. 存在某個基準點 `a` 使 `abs (cand - a) <= w`

`getEntity` 對不存在的 id 丟 `StoreFailed (EntityNotFound _)`;`timelineAnchors` 用
`catchError` 逐個吞掉——`drRefs` 由呼叫端(作者或 Agent)提供,裡面有一個打錯的 id 不該讓
整個 `context` 指令失敗。這是本模組唯一需要 `mtl` 的地方。

### 七、一跳擴充

對**通過 timeline 過濾的**候選跑 `linksOf`,取 `lrOutgoing` 中 `linkKind` 為 `PartOf` 或
`OccursIn` 的關聯(建構子拼法已查證:`StoryFlow.Core.Link` 的 `PartOf` / `OccursIn`):

- **只取本地目標**(`refVault == Nothing`)。跨 Vault 的目標要開第二個索引連線,而 `ServiceM`
  這一層明說跨 Vault 只存不解析(`requireLocalRef` 的註解),硬撈只會拿到 `EntityNotFound`
- **只取正向**(`lrOutgoing`)。ADR-007 寫的是「候選的 `partOf` / `occursIn` 目標一併帶進來」
  ——反向是「誰屬於這個候選」,那是另一個問題,而且一個角色主體的反向 `partOf` 可能有幾十筆,
  會直接把 `topN` 淹掉
- 目標的 `Meta` 經 `getEntity` 取得;**非 `Canon` 的丟棄**(驗收標準 2 對擴充候選同樣成立),
  查不到的略過
- 已經在候選集合裡的目標不重複加入
- 分數 = 母候選分數 × `expansionDecay`(0.5)。擴充候選**恆低於它的母候選**:它不是被草稿的
  詞彙命中的,只是「和被命中的東西有結構關係」,排在母候選前面沒有道理(見 A5)
- `caOrigin = FromExpansion 母候選id 關聯種類`,理由文案因此說得出「從誰、經哪條關聯來的」

擴充只做**一跳**,不遞迴:`coGraphDepth` 是第 1 層的參數,第 2 層的「一跳」是 ADR-007 寫死的。

### 八、截斷、`rrScanned` 與輸出

排序鍵:`caScore` 遞減 → `metaId` 字典序。第二鍵讓輸出成為全序,同一份輸入永遠同一份輸出
(第 2 層與第 1 層一樣是確定性層)。排完 `take (coTopN opts)`。

`rrScanned` = **掃過的相異片段 id 數**,包含:SQL 撈回來的全部(含後來被 timeline 剔除的)

- 擴充帶進來的。它就是使用者判斷 `topN` 夠不夠的依據——回了 20 筆而 `rrScanned` 是 20,
代表很可能被截斷了(F001 對 `crScanned` 的註解),而回了 20 筆但 `rrScanned` 是 180,代表
過濾與截斷都在正常運作。F004 / F006 把它填進 `ConflictReport.crScanned`。

`coTopN <= 0` 時回空候選,但 `rrScanned` 照樣記錄掃過的數量——「你把上限設成 0」和
「什麼都沒撈到」是兩件事。

### 九、理由文案與兩種輸出

繁體中文,固定句型,id 一律走 `renderId`:

| 來源 | `chReason` |
|---|---|
| 關鍵詞命中 | `草稿與 ent-1001 共同出現「織紋刀」` |
| 一跳擴充 | `ent-1002 經 ent-1001 的 partOf 關聯一跳帶入` |

**文案不得出現「矛盾」二字**:第 2 層交出來的是「相關」,不是判斷。把候選講成矛盾,
`HitLayer` 分三層的意義就沒了(ADR-007:第 1 層是事實、第 3 層是判斷,使用者需要知道差別)。

- `candidateContextHit`:`ContextHit (caMeta) (caSnippet) (ByRetrieval caScore)` ——F004 的
  context 出口直接吃這個,`Meta` 帶著走,外部 Agent 不必再往返一次
- `candidateConflictHit`:`ConflictHit (metaId caMeta) (ByRetrieval caScore) reason (Just caSnippet)`
  ——第 2 層有片段可指,所以 `chSnippet` 是 `Just`(對比第 1 層恆為 `Nothing`)

### 十、套件邊界

`storyflow-conflict.cabal` 的 `build-depends` 加 `storyflow-service` 與 `mtl`
(`catchError`),`exposed-modules` 加 `StoryFlow.Conflict.Retrieval`。

`CabalSpec` 目前的 `forbidden` 含 `storyflow-service`,**必須跟著改**。那份測試的模組註解
早就預告了這一刻:

> 為什麼值得釘:`storyflow-conflict` 後續會依賴 `service`(第 2 層要用它的 `searchEntity`),
> 那時這條測試要**被明確改掉**,而不是某次順手加相依就悄悄失去了「型別層不綁實作進度」
> 這個性質。

此刻放行的理由是**它已經不再是「型別套件」**:F001 的斷言守的是「型別不被綁到某一層的實作
進度上」,而第 2 層本來就是實作,它的存在前提就是 service 已經到位(service-and-interfaces
全部 `done`)。放行的同時要把**剩下四項守得更緊**:`storyflow-store` / `storyflow-md` /
`storyflow-llm` / `sqlite-simple` 一個都不准進來——「所有讀取經 `ServiceM`」這條子系統界線
(`design.md` 兩處明寫)靠的正是這四個名字不出現。

測試套件同樣受限(`dependencyLines` 掃的是整份 `.cabal` 的相依行,不分 library 與 test-suite)。
所幸不成問題:`service` 自己的測試底稿證明了**只靠 `storyflow-service` 就能建出臨時 Vault**
——`createVault` / `openEnv` / `runService` 都在門面上,`storyflow-store` 一次都不必露臉。
本 feature 的整合測試照抄那個作法(`temporary` + `directory` + `filepath`)。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `searchEntity :: Text -> EntityFilter -> ServiceM [SearchHit]` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 第 2 層唯一的候選來源;**本 feature 會改它的回傳內容(多一欄分數)** |
| `listEntities :: EntityFilter -> ServiceM [Meta]` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | `aliasIndex` 建在它之上;`ORDER BY e.id` 保證輸出順序確定 |
| `linksOf :: Id -> ServiceM LinkReport` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 一跳擴充讀候選的正向關聯 |
| `getEntity :: Id -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | timeline 基準點與擴充目標的 `Meta`;找不到時丟 `StoreFailed (EntityNotFound i)` |
| `data SearchHit = SearchHit { shMeta :: Meta, shSnippet :: Text }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | **本 feature 加 `shScore :: Maybe Double`**(S2) |
| `data LinkReport = LinkReport { lrOutgoing :: [Link], lrIncoming :: [(Id, Link)] }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | 擴充只用 `lrOutgoing` |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | 由 `evEntity` 取 `entMeta` 拿 `Meta` |
| `newtype ServiceM a`(`deriving newtype (Monad, MonadIO, MonadReader Env, MonadError ServiceError)`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 本模組全部操作跑在它裡面;`MonadError` 讓 `catchError` 吞得掉單一 `drRef` 的 `EntityNotFound` |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))` / `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` / `closeEnv :: Env -> IO ()` | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 整合測試建臨時環境(不必碰 `storyflow-store`) |
| `createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 同上 |
| `instance ToJSON SearchHit` / `instance FromJSON SearchHit`(含 `optional :: ToJSON a => Key -> Maybe a -> [Pair]`) | `service/src/StoryFlow/Service/Json.hs` | service-and-interfaces/F001 | `shScore` 的編碼;`optional` 就是「`Maybe` 沒值時整個鍵不出現」的既有實作 |
| `instance ToSchema SearchHit`(`objSchema "檢索命中:Meta + 命中片段" [("meta", mS), ("snippet", txt)] ["meta", "snippet"]`) | `api/src/StoryFlow/Api/Instances.hs` | service-and-interfaces/F003 | 加 `score` 到 `properties`,`required` 不動 |
| `renderSearch :: [SearchHit] -> Text` | `cli/src/StoryFlow/Cli/Render.hs` | service-and-interfaces/F002 | pattern 從 `SearchHit m s` 改成帶三欄;人類模式欄位不變 |
| `data EntityFilter = EntityFilter { efType :: Maybe Text, efStatus :: Maybe Status, efTag :: Maybe Text, efLimit :: Maybe Int }` | `store/src/StoryFlow/Store/Query.hs` | entity-graph-core/F004 | 候選撈取的 canon 過濾與過度撈取上限;`aliasIndex` 的參數型別 |
| `emptyFilter :: EntityFilter` | `store/src/StoryFlow/Store/Query.hs` | entity-graph-core/F004 | 過濾條件的起點 |
| `searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]` | `store/src/StoryFlow/Store/Query.hs` | entity-graph-core/F004 | **本 feature 改成 `IO [(Meta, Text, Maybe Double)]`**;FTS5 路徑(`>= 3` 字元,`MATCH` + `ORDER BY rank`)帶 bm25,LIKE 路徑(`< 3` 字元,`ORDER BY e.id`)給 `Nothing` |
| `whereOf :: Text -> EntityFilter -> (Text, [SQLData])` | `store/src/StoryFlow/Store/Query.hs` | entity-graph-core/F004 | 私有函式,不直接呼叫;`efStatus` 之所以能在 SQL 裡過濾 canon 就是它產出的 `AND e.status = ?` |
| `limitOf :: EntityFilter -> (Text, [SQLData])` | `store/src/StoryFlow/Store/Query.hs` | entity-graph-core/F004 | 同上;`efLimit` → `LIMIT ?`,過度撈取靠它 |
| `data Meta = Meta { metaId :: Id, …, metaTitle :: Text, metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], … }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | 候選的載體;`metaTitle` / `metaAliases` 餵 `aliasIndex` |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | timeline 過濾只看 `tlOrder`;`tlLabel` 算不出距離 |
| `data Status = Draft \| Canon \| Deprecated` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | `efStatus = Just Canon` |
| `isCanon :: Meta -> Bool` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | 擴充目標的 canon 檢查(它已經在 core,不自己寫一次 `== Canon`) |
| `data LinkKind = Contradicts \| Supersedes \| DerivedFrom \| PartOf \| Involves \| OccursIn \| References \| ConvergesTo \| Custom Text` | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | 一跳擴充只認 `PartOf` / `OccursIn`(建構子拼法以此為準) |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | 擴充走的邊 |
| `renderLinkKind :: LinkKind -> Text` | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | 擴充的理由文案顯示 `partOf` / `occursIn` |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | 擴充只取 `refVault == Nothing` 的目標 |
| `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | 理由文案 |
| `data Draft = Draft { drText :: Text, drRefs :: [Id] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 本層吃 `drText`(關鍵詞)與 `drRefs`(timeline 基準點) |
| `data ConflictOpts = ConflictOpts { coTopN :: Int, coExpandBody :: Bool, coTimelineWindow :: Maybe Int, coGraphDepth :: Int }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 本層只讀 `coTopN` 與 `coTimelineWindow` |
| `defaultConflictOpts :: ConflictOpts`(`coTopN = 20`、`coTimelineWindow = Nothing`) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 「預設保守」的既有落點,本層不另訂預設 |
| `data HitLayer = ByGraph GraphEvidence \| ByRetrieval Double \| ByJudge Double` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 本層一律產出 `ByRetrieval` |
| `data ConflictHit = ConflictHit { chTarget :: Id, chLayer :: HitLayer, chReason :: Text, chSnippet :: Maybe Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | `candidateConflictHit` 的輸出;本層的 `chSnippet` 恆為 `Just` |
| `data ContextHit = ContextHit { xhMeta :: Meta, xhSnippet :: Text, xhVia :: HitLayer }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | `candidateContextHit` 的輸出,F004 的 context 出口直接吃它 |

> 上表每一列的簽名都是從來源檔案讀出的**原文**。三處標示「本 feature 會改」的,列的是**改動前**
> 的現況——改動後的形狀寫在「新增的介面」。

## 新增的介面

### `StoryFlow.Service`(service-and-interfaces 的契約,S2 / S3)

```haskell
-- Service/Types.hs:多一欄,其餘不動
data SearchHit = SearchHit
  { shMeta    :: Meta
  , shSnippet :: Text
  , shScore   :: Maybe Double
  -- ^ 0–1,越大越相關。FTS5 路徑帶正規化後的 bm25;
  --   中文兩字詞走的 LIKE 路徑是 @ORDER BY e.id@,沒有相關度可言,一律 @Nothing@。
  }

-- Service.hs:新增一個內嵌出口,加進 module 的匯出清單(Entity 那一節)
-- | 片段 id → 它的 metaTitle 與 metaAliases。
--   給衝突偵測第 2 層做「既有名稱有沒有出現在草稿裡」的反向比對用。
--   呼叫端傳 @emptyFilter { efStatus = Just Canon }@ 取比對基準。
--   __只開內嵌出口__:不接 CLI、不接 REST。
aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]
```

### `StoryFlow.Store.Query`(entity-graph-core,S2 的資料來源)

```haskell
-- | FTS5 檢索,回傳 (Meta, 命中片段, 相關度)。
--   相關度只有 MATCH 路徑給得出來(bm25 正規化到 0–1);LIKE 路徑一律 Nothing。
searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text, Maybe Double)]

-- | bm25(負值、越負越相關)→ (0,1) 的單調遞增壓縮:rel = max 0 (negate raw); rel / (1 + rel)。
--   刻意不用結果集內 min-max ——那會讓每次查詢的最高分都是 1.0,跨查詢完全不可比,
--   而第 2 層要把多個關鍵詞的結果合併排序。
normalizeBm25 :: Double -> Double
```

### `StoryFlow.Conflict.Retrieval`(本 feature 的主體)

```haskell
module StoryFlow.Conflict.Retrieval
  ( -- * 門面
    retrieveCandidates
  , retrieveCandidatesWith
  , RetrievalResult (..)
  , Candidate (..)
  , CandidateOrigin (..)

    -- * 策略接縫
  , KeywordStrategy (..)
  , defaultKeywordStrategy

    -- * 輸出轉換
  , candidateContextHit
  , candidateConflictHit
  , renderRetrievalReason

    -- * 純函式部件(供 Pipeline 與測試使用)
  , matchedNames
  , segmentDraft
  , rankFallbackScore
  , withinWindow
  , mergeCandidates
  , overFetchLimit

    -- * 調校常數
  , segMinLen, chunkLen, maxKeywordLen, maxKeywords
  , overFetchFactor, expansionDecay
  ) where

-- | 這一筆候選是怎麼進來的。壓成 ConflictHit 之後就取不回來了,
--   而理由文案、排序與測試都需要它。
data CandidateOrigin
  = FromKeyword Text          -- ^ 由哪個關鍵詞撈到
  | FromExpansion Id LinkKind -- ^ 由哪個候選、經哪條一跳關聯帶入
  deriving stock (Show, Eq)

-- | 一個候選片段。帶 Meta 而不只帶 id:context 出口要的就是內容本身。
data Candidate = Candidate
  { caMeta    :: Meta
  , caSnippet :: Text
  , caScore   :: Double        -- ^ 0–1,越大越相關
  , caOrigin  :: CandidateOrigin
  }
  deriving stock (Show, Eq)

-- | 第 2 層的完整結果。
data RetrievalResult = RetrievalResult
  { rrCandidates :: [Candidate] -- ^ 已排序、已截到 coTopN
  , rrScanned    :: Int         -- ^ 掃過的相異片段數(含被 timeline 剔除的)→ ConflictReport.crScanned
  , rrKeywords   :: [Text]      -- ^ 實際用了哪些關鍵詞(CLI 說得出「我拿什麼去找」)
  }
  deriving stock (Show, Eq)

-- | 候選撈取策略。ADR-007 的「策略可替換」就是這個型別:
--   未來的 embedding 檢索從這裡進,第 1、3 層不動。
newtype KeywordStrategy = KeywordStrategy
  { runKeywordStrategy :: [(Id, [Text])] -> Text -> [Text] }

-- | 兩路併用:反向名稱比對(精準)在前,切詞(補召回)在後,合併去重、截到 maxKeywords。
defaultKeywordStrategy :: KeywordStrategy

-- | 既有名稱(title / aliases)出現在草稿裡的那些。長度 < 2 與空字串一律略過。
matchedNames :: [(Id, [Text])] -> Text -> [Text]

-- | 依「非 isAlphaNum」切草稿;丟掉 < segMinLen 的片段;
--   > maxKeywordLen 的片段切成 chunkLen 的不重疊塊;去重保序。
segmentDraft :: Text -> [Text]

-- | shScore 為 Nothing 時的名次回退:1 / (k + 2),k 為 0-based 名次。
--   封頂 0.5 是刻意的,不與真實的 bm25 分數混為一談。
rankFallbackScore :: Int -> Double

-- | timeline 過濾。window 為 Nothing、基準點為空、或候選沒有 tlOrder 時一律保留。
withinWindow :: Maybe Int -> [Int] -> Meta -> Bool

-- | 依 metaId 去重,同 id 取最高分;分數相同取先出現者。輸入順序即優先序。
mergeCandidates :: [Candidate] -> [Candidate]

-- | 過度撈取的 SQL 上限:coTopN * overFetchFactor(下限 1)。
overFetchLimit :: Int -> Int

-- | 第 2 層門面。全部讀取經 ServiceM,不開索引連線。
--   輸出依 (分數遞減, id 字典序) 全序排列並截到 coTopN,同一輸入永遠同一輸出。
retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult

-- | 換策略用的版本;retrieveCandidates = retrieveCandidatesWith defaultKeywordStrategy。
retrieveCandidatesWith :: KeywordStrategy -> ConflictOpts -> Draft -> ServiceM RetrievalResult

-- | 繁中理由文案。__不出現「矛盾」二字__:第 2 層交的是「相關」,不是判斷。
renderRetrievalReason :: Candidate -> Text

-- | 給 F004 的 context 出口:HitLayer 為 ByRetrieval,Meta 直接帶走。
candidateContextHit :: Candidate -> ContextHit

-- | 給 F006 合流用:chSnippet 恆為 Just(第 2 層有片段可指,對比第 1 層恆為 Nothing)。
candidateConflictHit :: Candidate -> ConflictHit
```

`storyflow-conflict.cabal`:`exposed-modules` 加 `StoryFlow.Conflict.Retrieval`;
`build-depends` 加 `storyflow-service` 與 `mtl`;測試套件加 `storyflow-service`、`temporary`、
`directory`、`filepath`。**`storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple`
一個都不加**。

## TodoList

- [x] T1: `store` 的 `searchEntities` 改回三元組:`ftsQuery` 的 `SELECT` 加 `bm25(entities_fts)`、`likeQuery` 對應位置給 `NULL`;新增並匯出 `normalizeBm25`  `dep: entity-graph-core/F004`
- [x] T2: `SearchHit` 加 `shScore`,並更新 `Service.hs` 的組裝、`Service/Json.hs` 的 `ToJSON`/`FromJSON`、`api` 的 `ToSchema` 與 `sampleSearchHit`、`cli` 的 `renderSearch`,以及 store/service/cli 三個套件既有的 `SearchHit` 斷言  `dep: T1`
- [x] T3: `StoryFlow.Service` 新增 `aliasIndex`(建在 `listEntities` 之上,濾掉空字串名稱),加進門面匯出清單;不接 CLI、不接 REST  `dep: service-and-interfaces/F001`
- [x] T4: `storyflow-conflict.cabal` 加 `storyflow-service` / `mtl` 與測試相依;`CabalSpec` 的 `forbidden` 移除 `storyflow-service` 並改成「必須含 service、仍然不含其餘四項」的雙向斷言  `dep: T3`
- [x] T5: `matchedNames` / `segmentDraft` / `defaultKeywordStrategy`:兩路併用、合併去重、`maxKeywords` 截斷  `dep: T4`
- [x] T6: 候選撈取:逐關鍵詞 `searchEntity`(`efStatus = Just Canon` + `overFetchLimit`)、`rankFallbackScore` 回退、`mergeCandidates` 去重取最高分  `dep: T2, T5`
- [x] T7: `timelineAnchors`(`drRefs` → `getEntity`,單一 id 查不到用 `catchError` 吞掉)與 `withinWindow` 過濾;`rrScanned` 的計數含被剔除者  `dep: T6`
- [x] T8: 一跳擴充:`linksOf` 取 `PartOf` / `OccursIn` 的本地正向目標、非 canon 丟棄、分數乘 `expansionDecay`、`caOrigin = FromExpansion`  `dep: T7`
- [x] T9: `retrieveCandidatesWith` / `retrieveCandidates` 門面:排序(分數遞減 → id 字典序)、`take coTopN`、`coTopN <= 0` 的行為、`RetrievalResult` 組裝  `dep: T8`
- [x] T10: `renderRetrievalReason` 兩種句型與 `candidateContextHit` / `candidateConflictHit` 轉換  `dep: T9`
- [x] T11: 模組註冊(cabal `exposed-modules`、`conflict/test/Spec.hs`)與策略可替換性:換一個 `KeywordStrategy` 即改變候選集合,其餘模組零改動  `dep: T9`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `store/test/StoryFlow/Store/SearchSpec.hs` → `MATCH 路徑帶得出相關度,LIKE 路徑不編分數` | 三字元以上的查詢每一筆 `Just s` 且 `0 < s < 1`;結果順序與分數遞減一致(`ORDER BY rank` 沒被打破);二字詞查詢(「織紋」)每一筆都是 `Nothing`;`normalizeBm25` 對更負的輸入回更大的值、對 `0` 回 `0`;既有的七條斷言改用三元組 accessor 後全部照舊通過 |
| T2 | `service/test/StoryFlow/Service/JsonSpec.hs` → `SearchHit 的 score 有值才出現` | `Just 0.8` round-trip 不失真且 JSON 含 `score` 鍵;`Nothing` 時**整個鍵不出現**(既有約定)且 round-trip 仍回 `Nothing`;連帶:`api` 的 `SchemaSpec` 「SearchHit」一條(樣本改成 `Just`)、`cli` 的 `RenderSpec` 表頭一條、`service` 的 `EntityReadSpec` / `EndToEndSpec` 全部保持綠燈 |
| T3 | `service/test/StoryFlow/Service/AliasIndexSpec.hs` → `aliasIndex 回 title 與 aliases 且吃得到 EntityFilter` | 建三個片段(canon 兩個、draft 一個,其中一個有 aliases),`efStatus = Just Canon` 時 draft 那個不出現;每一筆第一個元素是 `metaTitle`;空字串 alias 被濾掉;輸出依 id 排序(重跑兩次結果相同) |
| T4 | `conflict/test/StoryFlow/Conflict/CabalSpec.hs` → `第 2 層放行 service,其餘四項仍然擋住` | `build-depends` **含** `storyflow-service`;`storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple` 一個都不出現(整份 `.cabal`,含 test-suite);`exposed-modules` 含 `StoryFlow.Conflict.Retrieval` |
| T5 | `conflict/test/StoryFlow/Conflict/RetrievalSpec.hs` → `關鍵詞兩路併用` | `matchedNames`:名稱出現在草稿才收、單字名稱與空字串不收、同名只收一次;`segmentDraft`:中文標點與英文空白都是切點、單字片段丟掉、超長無標點中文切成 4 字塊且尾巴不足 2 字被丟、去重保序;`defaultKeywordStrategy`:名稱在前切詞在後、去重、總數不超過 `maxKeywords` |
| T6 | 同檔 → `分數取用與候選合併` | `rankFallbackScore 0 == 0.5` 且遞減、恆 `<= 0.5`;`mergeCandidates` 同 id 取最高分並保留該筆的 snippet 與 origin、分數相同取先出現者、不同 id 全部保留且保序;`overFetchLimit 20 == 80`、`overFetchLimit 0 == 1` |
| T7 | 同檔 → `timeline 過濾的四條保留規則` | `window = Nothing` 全保留;基準點為空時全保留(**不是全部剔除**);候選 `tlOrder = Nothing` 保留;`window = 2` 且基準 `10` 時 `tlOrder = 12` 保留、`13` 剔除;多個基準點取「任一符合即保留」。整合面:`conflict/test/StoryFlow/Conflict/RetrievalEnvSpec.hs` → `rrScanned 含被 timeline 剔除的候選`(開 window 後 `rrCandidates` 變少但 `rrScanned` 不變),且 `drRefs` 帶一個不存在的 id 時不失敗 |
| T8 | `RetrievalEnvSpec.hs` → `partOf / occursIn 一跳擴充` | 建「琳達」主體 + `partOf` 指向它的片段 + `occursIn` 指向地點,草稿只命中片段時擴充目標出現在候選裡且 `caOrigin` 是 `FromExpansion`;`involves` / `references` 的目標**不**被帶入;draft 狀態的擴充目標被丟棄;跨 Vault 的 `linkTarget` 不被展開;擴充候選的分數嚴格小於它的母候選;不遞迴(兩跳外的片段不出現) |
| T9 | `RetrievalEnvSpec.hs` → `topN 控制輸出且排序確定` | 灌 8 個都會命中的 canon 片段,`coTopN = 3` 時 `rrCandidates` 恰 3 筆而 `rrScanned >= 8`;連跑兩次結果逐筆相同(全序);分數遞減、同分依 id 字典序;`coTopN = 0` 回空候選但 `rrScanned > 0`;`rrKeywords` 非空且與 `defaultKeywordStrategy` 的輸出一致 |
| T10 | `RetrievalSpec.hs` → `理由文案與兩種輸出轉換` | 關鍵詞句型含 `renderId` 的 id 與加了引號的關鍵詞;擴充句型含母候選 id 與 `renderLinkKind` 的關聯名;**兩種句型都不含「矛盾」**;`candidateContextHit` 的 `xhVia` 是 `ByRetrieval caScore` 且 `xhMeta` 原樣帶出;`candidateConflictHit` 的 `chTarget` 是 `metaId caMeta`、`chSnippet` 是 `Just` |
| T11 | `RetrievalEnvSpec.hs` → `換策略只換一個值` | 用一個回傳固定關鍵詞的 stub `KeywordStrategy` 跑 `retrieveCandidatesWith`,候選集合與 `defaultKeywordStrategy` 不同、`rrKeywords` 等於 stub 的輸出;回傳空清單的 stub 得到空候選且 `rrScanned == 0`;`conflict/test/Spec.hs` 註冊了兩個新 spec 模組 |

## 待確認假設

- A1: `store` 的 `searchEntities` 簽名寫在 `entity-graph-core/design.md` 第 79 行,而編排者的 S2 只回寫了 `service-and-interfaces/design.md`;讓 `shScore` 有資料來源必須改動它 → 採取:設計照 S2 的決定寫完(T1),但**不自行修改 `design.md`**(委派模式第 4 條),改記進回報請編排者裁決 → 影響:若編排者裁決不改 `entity-graph-core` 的契約,`shScore` 就只能在 service 層合成,而那正是 S2 明確禁止的;屆時 T1 / T2 全部作廢,`ByRetrieval` 只能一律走 `rankFallbackScore`
- A2: S3 的理由寫「走專用出口而非 `listEntities` 全撈 `Meta`:只傳字串,傳輸量小得多」,但這個出口明確不開 REST,內嵌路徑沒有傳輸成本 → 採取:`aliasIndex` **建在既有的 `listEntities` 之上**,不新增 store 查詢,少改一個子系統的契約 → 影響:若之後決定開 REST 出口,或 Vault 大到「撈全部 `Meta` 只為了拿名稱」變成瓶頸,要回頭在 `store` 加一條只查 `entities.title` + `entity_aliases` 的查詢(屆時又是一次 `entity-graph-core` 契約變更)
- A3: `design.md`「內部模組劃分」表把第 2 層的成本寫成「一次 SQL」,但 `searchEntity` 一次只吃一個關鍵詞字串,而 D2 要求兩路關鍵詞併用 → 採取:**每個關鍵詞一次 SQL**,並用 `maxKeywords = 16` 封頂(最壞 16 次查詢 + 每個存活候選一次 `linksOf` + 每個擴充目標一次 `getEntity`) → 影響:若「一次 SQL」是硬性成本上限,得改成讓 `searchEntity` 吃一組關鍵詞(那是 `service-and-interfaces` 的契約變更),或放棄切詞那一路(那會違反 D2)
- A4: `ConflictOpts.coTimelineWindow` 是「比對 `tlOrder` 的容許距離」,但 `Draft` 沒有 timeline 欄位,契約沒說距離要對誰算 → 採取:以 **`drRefs` 對應片段的 `tlOrder` 為基準點**(草稿身上唯一的時序線索);基準點為空時**不過濾**而非全部剔除 → 影響:若正確語意是「由使用者顯式給一個時間點」,`Draft` 或 `ConflictOpts` 要多一個欄位(F001 的型別變更),`withinWindow` 的簽名跟著改;`drRefs` 為空的草稿目前等於關掉 timeline 過濾
- A5: 一跳擴充帶進來的候選沒有任何檢索分數可言,但它得和關鍵詞候選一起排序、一起受 `coTopN` 約束 → 採取:分數 = 母候選分數 × `expansionDecay = 0.5`,並讓 `coTopN` 約束**合併後的最終清單**(擴充只填關鍵詞候選沒用完的名額) → 影響:若擴充候選應該獨立於 `topN` 之外(亦即最終筆數可以超過 `topN`),`retrieveCandidates` 的截斷點與 F004 / F006 對 `topN` 的說明都要改;若衰減係數不該固定,它要升格成 `ConflictOpts` 的一欄
- A6: 「一跳擴充」ADR-007 寫的是「候選的 `partOf` / `occursIn` 目標一併帶進來」,沒說要不要反向 → 採取:**只取正向**(`lrOutgoing`) → 影響:若反向也該納入(「誰屬於這個候選」),`linksOf` 的 `lrIncoming` 也要處理,而一個角色主體的反向 `partOf` 可能有幾十筆,`topN` 的預算與擴充的分數衰減都要重新設計
- A7(實作時新增): 一跳擴充帶進來的候選**要不要也受 timeline 過濾**?本文檔第一節的管線把 timeline 過濾排在擴充**之前**,而第七節列出的擴充規則(本地、正向、canon、不重複、衰減)沒有 timeline 這一條 → 採取:照管線順序實作,**擴充候選不受 timeline 過濾**;但擴充的「已見過」集合用的是**掃過的全部候選**(含被 timeline 剔除的),所以被時序剔除的片段**不會**從擴充那條路偷偷回來 → 影響:若正確語意是「擴充目標也必須落在 window 內」,`expandOneHop` 要多吃一組基準點並在加入前再過一次 `withinWindow`,而 `rrScanned` 的計數方式也要跟著調整(目前擴充只計入實際加入的那些)
- A8(實作時新增): `ContextHit.xhSnippet` 不是 `Maybe`,但擴充候選**不是被檢索命中的**,手上沒有 FTS5 給的 snippet → 採取:用 `metaSummary`,總結為空字串時退回 `metaTitle`(型別註冊表把 `summary` 列為必填,所以實務上幾乎總是有值) → 影響:若 context 出口要求「snippet 必須是正文裡真正出現過的一段」,擴充候選就得多讀一次 body 並自己截段(多一次 `getEntity` 的 body 讀檔),或者 `ContextHit` 要能表達「這一筆沒有片段可指」

## 實作備註

11 個 Todo 全部完成,九個測試套件全綠(合計 1030 examples、0 failures)。

### 與設計文檔的差異

沒有偏離「新增的介面」與「對應的 Level 2 契約」的任何一條。三處值得記錄的實作決定:

1. **`mergeCandidates` 的輸出位置**:同 id 取最高分時,那一筆放在該 id **第一次出現**的位置,
   而不是高分那筆出現的位置。文檔只要求「輸入順序即優先序」,兩種都符合;選第一次出現是因為
   它讓「不同 id 全部保留且保序」這句話在有重複的輸入上仍然成立
2. **一跳擴充的排除集合**用的是**掃過的全部候選**而不只是通過 timeline 過濾的那些
   (見 A7)。否則一個剛被時序剔除的片段,會因為某個存活候選指向它而立刻回到清單裡
3. **擴充候選的 snippet** 取 `metaSummary`,為空時退回 `metaTitle`(見 A8)

### 既有測試的修改(逐條說明為什麼)

每一條都是**因為型別變了而必須改**,沒有為了變綠而放寬語意;三處反而收得更緊。

| 檔案 | 改動 | 為什麼 |
|---|---|---|
| `store/test/.../SearchSpec.hs` | `ident` 改吃三元組;新增 `metaOf` / `snippetOf` / `scoreOf` 三個 accessor;`map snd hits` → `map snippetOf hits`;`map (metaStatus . fst)` → `map (metaStatus . metaOf)` | `searchEntities` 的回傳從二元組變三元組(T1)。既有七條斷言的**語意一字未改** |
| `store/test/.../EndToEndSpec.hs` | `snapshot` 的 `[metaTitle m \| (m, _) <- hits]` → `(m, _, _)` | 同上;快照比對的內容不變 |
| `service/test/.../JsonSpec.hs` | `roundTrip (SearchHit sampleMeta "……織紋……")` → 拆成 `Just 0.8` 與 `Nothing` 兩條 | `SearchHit` 多一欄(T2)。**收得更緊**:原本一條變兩條,選配欄位的兩種狀態都要 round-trip |
| `cli/test/.../RenderSpec.hs` | `SearchHit linda "……第七織手……"` → 補 `(Just 0.42)`,並加一條「表頭不含 score」 | 建構子多一欄。**收得更緊**:原本只斷言表頭有 `snippet`,現在同時釘住「人類模式不印 score」——那是 S2 只要求 `--json` 的直接後果 |
| `api/test/.../Fixtures.hs` | `sampleSearchHit` 補 `Just 0.87` | `SchemaSpec` 的樣本刻意把選配欄位填滿,否則「`Maybe` 沒值就整個鍵不出現」會讓鍵集合比對假性不一致。`SchemaSpec` 本身**一字未改**,它自動涵蓋了新的 `score` 欄 |
| `conflict/test/.../CabalSpec.hs` | `forbidden` 移除 `storyflow-service`;`libraryDeps` / `testDeps` 逐字清單更新;新增「必須含 service」與「exposed-modules 含 Retrieval」兩條 | F001 的模組註解預告的那一刻(T4)。**收得更緊**:單向的「不含」變成雙向的「必須含 service、仍然不含其餘四項」,逐字釘住的相依清單同時擋掉「趁這次順道多一個包」 |

`server/test/.../HandlerSpec.hs` 與 `service/test/.../EntityReadSpec.hs` 用的是 record accessor
(`shMeta` / `shSnippet`),**確實不受影響,一字未改**——文檔的查證結論正確。

### 測試數量前後對照

| 套件 | 前 | 後 | 差 |
|---|---|---|---|
| storyflow-types | 29 | 29 | — |
| storyflow-core | 166 | 166 | — |
| storyflow-md | 189 | 189 | — |
| storyflow-api | 51 | 51 | — |
| storyflow-service | 83 | 88 | +5(`AliasIndexSpec` 4 條 + `JsonSpec` 的 score 1 條) |
| storyflow-store | 162 | 166 | +4(T1 的四條相關度斷言) |
| storyflow-server | 60 | 60 | — |
| storyflow-cli | 172 | 172 | — |
| storyflow-conflict | 62 | 109 | +47(`RetrievalSpec` 24 + `RetrievalEnvSpec` 15 + `CabalSpec` 兩條新斷言 + 原有的 6 條保留) |

### 給編排者的兩件事

1. **`entity-graph-core/design.md` 第 79 行仍是舊簽名**(A1)。程式碼已經照 S2 的決定改成
   `searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text, Maybe Double)]`,
   並新增匯出 `normalizeBm25`;依委派模式第 4 條,本 feature 不自行修改 `design.md`
2. `service-and-interfaces/design.md` 的 `aliasIndex` 與 `SearchHit.shScore` 編排者已回寫,
   程式碼與那份契約逐字一致
