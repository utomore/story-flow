---
id: F001
type: feature
title: conflict-types
description: 衝突報告的型別、命中層級證據與序列化,不含任何偵測邏輯
status: done
created: 2026-08-18
updated: 2026-08-19
depends-on: [entity-graph-core/F002]
related-adr: [ADR-003, ADR-005, ADR-007]
related-feature: []
---

# F001: 衝突報告型別

## 功能概述

`conflict-detection` 階段一的第一項。建立 `storyflow-conflict` 套件,並定義三層衝突偵測**共用的
資料語彙**:草稿、選項、命中、命中層級、報告,以及它們的 JSON 編碼。

**這份文檔 不含任何偵測邏輯**。沒有圖遍歷、沒有 FTS5、沒有 LLM。它只回答一個問題:
三層各自算完之後,**要用什麼形狀把結果交出來**。

先做型別的理由是 ADR-007 的三層「各自可獨立演進」——那句話只有在三層對同一組型別工作時
才成立。型別若跟著第一層一起長出來,第二、三層就會各自扭一份自己的形狀,而合流那一步
(`Conflict.Pipeline`)最後要負責把三種形狀併起來。

驗收標準:

1. `ConflictReport` 能表達三層各自的命中,而且**每一筆都說得出它是哪一層來的**
   ——第 1 層是事實、第 3 層是判斷,ADR-007 要求使用者看得出差別
2. `ByGraph` 帶的證據足以讓 `conflict-check` 直接反問「要不要建立這條 `contradicts` 關聯」,
   不必回頭再查一次圖
3. 全部型別的 `ToJSON` / `FromJSON` round-trip 不失真,且鍵名與 `StoryFlow.Core.Json`
   的既有約定一致(`Maybe` 沒值時整個鍵不出現、`Id` / `Ref` 是字串不是物件)
4. `storyflow-conflict.cabal` 的 `build-depends` **只有** `storyflow-core`,沒有
   `storyflow-service` / `storyflow-store` / `storyflow-llm`

## 相依性

`depends-on: [entity-graph-core/F002]`。

**只依賴 entity-graph-core/F002**(核心型別與型別註冊表)。本文檔 定義的每一個型別都只引用 core 的
`Meta` / `Id` / `Ref` / `LinkKind` / `Timeline`,以及它們在 `StoryFlow.Core.Json` 的既有
aeson 實例——介面表十一列的來源文檔 全部是 entity-graph-core/F002,沒有第二個。

**可否平行開發**:**可以與任何進行中的任務平行**。它不碰 `service`、不碰 `store`、不碰
`llm`,是整個 P4 裡相依最淺的一份。

這是刻意的設計選擇而不是巧合:`ContextHit` 本來可以重用 `storyflow-service` 的
`SearchHit { shMeta, shSnippet }`,那樣會少定義一個型別但把整個 `storyflow-conflict` 套件從
第一個 feature 就綁上 service-and-interfaces/F001。自訂一個三欄的 record 換來零 service 相依,划算——而且
`SearchHit` 少了「這筆是怎麼被撈出來的」那一欄,本來就不完全合用。

`storyflow-conflict` 之後仍然會依賴 `service`(`conflict-retrieval` 要用它的 `searchEntity`),
但那是下一份文檔 的事,不該提前寫進這個套件的 cabal。

## 對應的 Level 2 契約

實作 `design.md`「模組間公開介面與資料結構」章節的全部型別——`Draft`、`ConflictOpts`、
`GraphEvidence`、`HitLayer`、`ConflictHit`、`ContextHit`、`ConflictReport`——與它們的
aeson 編碼。兩個對外出口(`checkConflict`、`gatherContext`)在本規格只被型別支撐,
實作屬於後續 feature。

## 實作方式

### 一、套件與模組

新套件 `storyflow-conflict`,本文檔 只建立兩個模組:

```text
conflict/
├── storyflow-conflict.cabal
├── src/StoryFlow/Conflict/Types.hs   -- 型別
└── src/StoryFlow/Conflict/Json.hs    -- 孤兒實例,集中一處
```

`Json.hs` 獨立而不把實例寫在 `Types.hs`,理由與 `StoryFlow.Core.Json` /
`StoryFlow.Service.Json` 完全相同:CLI 的 `--json`、REST 的 body、未來 MCP 用的是同一套編碼
規則,規則只該有一份;把實例散在型別模組會讓「規則有一份」變成靠自律維持。

`build-depends` 只有 `base` / `text` / `containers` / `aeson` / `storyflow-core`。

### 二、輸入:Draft 與 ConflictOpts

`drRefs` 是**作者或 Agent 已經知道這段草稿引用了哪些片段**。第 1 層完全靠它起步
——沒有起點就沒有圖可以遍歷。空清單是合法的:那代表只能跑第 2、3 層。

`ConflictOpts` 的四個欄位各對應 ADR-007 的一條約束:

| 欄位 | 預設 | 對應的 ADR-007 條文 |
|---|---|---|
| `coTopN` | 20 | 「top-N 的 N 要可調,且預設保守」 |
| `coExpandBody` | `False` | 「優先送 summary 而非全文,必要時才展開 body」 |
| `coTimelineWindow` | `Nothing` | 「用 timeline 過濾時序上不可能相關的片段」 |
| `coGraphDepth` | 2 | 「用關聯圖擴充一跳範圍」——留成可調;預設 2 = 最多兩跳,語意與 `Core.Graph` 的 `follow` 一致(depth 即展開輪數) |

`coTimelineWindow :: Maybe Int` 比對的是 `Timeline` 的 `tlOrder`;`Nothing` = 不做時序過濾。
只有 `tlOrder` 有值的片段才受它影響,因為 `tlLabel` 是模糊字串(「崩塌前後」),無從算距離。

### 三、輸出:HitLayer 帶完整證據

**`ByGraph` 帶的是「哪一條關聯」而不只是「哪一層」**,這是驗收標準 2 的來源:
`conflict-check` 在確認衝突後要能反問「要不要建立這條 `contradicts` 關聯」(ADR-007 影響/中立
那一條),手上必須已經有 (from, kind, to) 三元組,否則得回頭再查一次圖。

`GraphEvidence` 的形狀**刻意對齊 core 既有的輸出**:

- `contradictionPairs :: LinkGraph -> [(Id, Ref)]` 回的正是 (來源 Id, 目標 Ref)
- `supersededSet :: LinkGraph -> Set Ref` 回的是 `Ref`

所以 `geFrom :: Id`、`geTo :: Ref`,不是兩邊都用 `Id`。跨 Vault 的 target 是合法的
`Ref`(有 `refVault`),而 core 的圖遍歷明說「跨 Vault 的 target 會被收進結果,但它的關聯不在
這張圖裡」——型別要能表達那種命中,否則第 1 層得偷偷把它丟掉。

`ByJudge Double` 用 0–1 的信心值而不是列舉:模型原生給的就是機率或可轉成機率的東西,
在型別這一層先壓成三級會讓「調整閾值」變成不可能。**要不要在 CLI 顯示成三級是渲染的決定**,
不是資料的決定。

### 四、ConflictHit 與 ContextHit 是兩種東西

差別不是命名潔癖:

- `ConflictHit` 是**判斷結果**,回答「這一筆和草稿矛盾」。它只帶 `chTarget :: Id`
  ——呼叫端要細節自己去查,報告本身不該把整個 `Meta` 複製一份進去
- `ContextHit` 是**撈出來的素材**,回答「這一筆和草稿有關」。`story-flow context` 的使用者
  (通常是 claude code)要的就是內容本身,所以直接帶 `Meta`,省掉一輪往返

`chSnippet` 是 `Maybe`(第 1 層的命中沒有片段可指,它命中的是一條關聯);
`xhSnippet` 不是 `Maybe`(撈出來的東西一定有命中的那一段)。

### 五、ConflictReport

`crScanned` 讓使用者判斷 `coTopN` 夠不夠——回了 20 筆而 `crScanned` 正好是 20,代表很可能被
截斷了。`crLlmUsed` 讓客戶端知道這份報告有沒有經過第 3 層:`False` 時「沒有發現衝突」的份量
完全不同,而那個差別不該只靠使用者記得自己有沒有加 `--no-llm`。

**排序由 `Conflict.Pipeline`(後續 feature)負責**,本文檔 只定 `crHits` 是一個清單,並提供
`sortHits` 把約定實作出來:依層級(Graph → Retrieval → Judge),同層依分數遞減。

### 六、JSON 編碼

沿用 `StoryFlow.Core.Json` 的三條約定:欄位名去前綴、多字 snake_case;`Maybe` 沒值時整個鍵
不出現;`Id` / `Ref` 是字串不是物件。

`HitLayer` 是和積型別,編成**帶標籤的物件**:

```json
{"layer": "graph",     "from": "ent-7f3c", "kind": "contradicts", "to": "ent-91cc"}
{"layer": "retrieval", "score": 0.82}
{"layer": "judge",     "confidence": 0.91}
```

用 `layer` 當標籤而不是 aeson 預設的和積編碼:預設會產出 `{"ByGraph": {...}}` 這種帶
Haskell 建構子名的形狀,而 API 契約不該洩漏實作語言的識別字。標籤值用小寫單字,與
`errorCode` 的 snake_case 風格一致。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newtype Id = Id Text` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | `chTarget` / `geFrom` / `drRefs` 的型別 |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | `geTo` ——跨 Vault 的關聯目標必須表達得出來 |
| `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | 測試裡構造本 Vault 的 `GraphEvidence` |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | `GraphEvidence` 三個欄位就是它攤平後的形狀 |
| `data LinkKind`(`Contradicts` / `Supersedes` / … / `Custom Text`) | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | `geKind` ——第 1 層命中的是哪一種關聯 |
| `data Meta = Meta { metaId :: Id, metaVault :: Text, metaType :: Text, metaTitle :: Text, metaSummary :: Text, metaTags :: [Text], metaStatus :: Status, metaTimeline :: Timeline, metaAliases :: [Text], metaLinks :: [Link], metaSource :: Source, metaRevision :: Int, metaCreated :: Day, metaUpdated :: Day }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | `ContextHit` 直接帶它,`context` 指令的使用者要的就是內容 |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | `coTimelineWindow` 比對的是 `tlOrder`;`tlLabel` 模糊,無從算距離 |
| `ToJSON` / `FromJSON` 實例(`Id` / `Ref` / `Meta` / `Link` / `LinkKind` / `Status` / `Timeline`) | `core/src/StoryFlow/Core/Json.hs` | entity-graph-core/F002 | 本文檔 的編碼直接站在它們上面,不重新定義 |
| `type LinkGraph = M.Map Id [Link]` | `core/src/StoryFlow/Core/Graph.hs` | entity-graph-core/F002 | 不直接引用,但 `GraphEvidence` 的形狀對齊它的兩個輸出 |
| `contradictionPairs :: LinkGraph -> [(Id, Ref)]` | `core/src/StoryFlow/Core/Graph.hs` | entity-graph-core/F002 | **`geFrom :: Id` / `geTo :: Ref` 就是照這個回傳型別定的** |
| `supersededSet :: LinkGraph -> Set Ref` | `core/src/StoryFlow/Core/Graph.hs` | entity-graph-core/F002 | 同上:`supersedes` 的命中目標是 `Ref` 而非 `Id` |
| `follow :: [LinkKind] -> Int -> Id -> LinkGraph -> Set Ref` | `core/src/StoryFlow/Core/Graph.hs` | entity-graph-core/F002 | `coGraphDepth` 對應它的 `Int` 參數,預設值要與它的語意一致 |

## 新增的介面

### `StoryFlow.Conflict.Types`

```haskell
-- | 待檢查的草稿。drRefs 是已知它引用了哪些片段,第 1 層靠它起步。
data Draft = Draft
  { drText :: Text
  , drRefs :: [Id]
  }

-- | 三層共用的選項。每一欄都對應 ADR-007 的一條約束。
data ConflictOpts = ConflictOpts
  { coTopN           :: Int        -- ^ 第 2 層的候選上限,預設保守
  , coExpandBody     :: Bool       -- ^ 第 3 層是否展開 body(預設只送 summary)
  , coTimelineWindow :: Maybe Int  -- ^ tlOrder 的容許距離;Nothing = 不做時序過濾
  , coGraphDepth     :: Int        -- ^ 第 1 層的遍歷深度,對應 Core.Graph 的 follow
  }

defaultConflictOpts :: ConflictOpts   -- topN=20 / expandBody=False / window=Nothing / depth=2

-- | 第 1 層的證據:哪一條關聯造成這次命中。
--   形狀對齊 Core.Graph 的 contradictionPairs :: LinkGraph -> [(Id, Ref)]。
data GraphEvidence = GraphEvidence
  { geFrom :: Id
  , geKind :: LinkKind
  , geTo   :: Ref
  }

-- | 命中層級。第 1 層是事實,第 3 層是判斷 —— 這個區分必須出現在輸出裡(ADR-007)。
data HitLayer
  = ByGraph GraphEvidence
  | ByRetrieval Double   -- ^ FTS5 相關度
  | ByJudge Double       -- ^ 模型信心 0–1

-- | 判斷結果:這一筆和草稿矛盾。只帶 id,細節由呼叫端自己查。
data ConflictHit = ConflictHit
  { chTarget  :: Id
  , chLayer   :: HitLayer
  , chReason  :: Text
  , chSnippet :: Maybe Text   -- ^ 第 1 層沒有片段可指,它命中的是一條關聯
  }

-- | 撈出來的素材:這一筆和草稿有關。直接帶 Meta,省掉一輪往返。
data ContextHit = ContextHit
  { xhMeta    :: Meta
  , xhSnippet :: Text
  , xhVia     :: HitLayer
  }

data ConflictReport = ConflictReport
  { crHits    :: [ConflictHit]
  , crScanned :: Int   -- ^ 掃過幾個候選,讓使用者判斷 topN 夠不夠
  , crLlmUsed :: Bool  -- ^ 有沒有跑第 3 層;False 時「沒發現衝突」的份量不同
  }

emptyReport :: ConflictReport

-- | 排序約定的實作:依層級(Graph → Retrieval → Judge),同層依分數遞減。
sortHits :: [ConflictHit] -> [ConflictHit]

-- | 命中層級的名稱,渲染與 JSON 標籤共用一份。
layerTag :: HitLayer -> Text   -- ^ "graph" / "retrieval" / "judge"
```

全部型別 `deriving stock (Show, Eq)`。

### `StoryFlow.Conflict.Json`

```haskell
-- 孤兒實例集中一處(理由同 StoryFlow.Core.Json)。
module StoryFlow.Conflict.Json () where

instance ToJSON Draft          ; instance FromJSON Draft
instance ToJSON ConflictOpts   ; instance FromJSON ConflictOpts
instance ToJSON GraphEvidence  ; instance FromJSON GraphEvidence
instance ToJSON HitLayer       ; instance FromJSON HitLayer   -- 帶 "layer" 標籤
instance ToJSON ConflictHit    ; instance FromJSON ConflictHit
instance ToJSON ContextHit     ; instance FromJSON ContextHit
instance ToJSON ConflictReport ; instance FromJSON ConflictReport
```

## TodoList

- [x] T1: 建立 `conflict/storyflow-conflict.cabal` 與 `cabal.project` 項目;`build-depends` 只有 `base` / `text` / `containers` / `aeson` / `storyflow-core`  `dep: -`
- [x] T2: `StoryFlow.Conflict.Types`:`Draft` 與 `ConflictOpts`,含 `defaultConflictOpts`  `dep: T1`
- [x] T3: `StoryFlow.Conflict.Types`:`GraphEvidence` 與 `HitLayer`,形狀對齊 `Core.Graph` 的 `contradictionPairs` / `supersededSet`  `dep: T2, entity-graph-core/F002`
- [x] T4: `StoryFlow.Conflict.Types`:`ConflictHit` / `ContextHit` / `ConflictReport` 與 `emptyReport`  `dep: T3`
- [x] T5: `layerTag` 與 `sortHits`(層級序 Graph → Retrieval → Judge,同層分數遞減)  `dep: T4`
- [x] T6: `StoryFlow.Conflict.Json`:全部 `ToJSON` / `FromJSON`,`HitLayer` 以 `layer` 標籤編碼  `dep: T5`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `conflict/test/.../CabalSpec.hs` → `型別套件不依賴任何實作端` | 讀 `storyflow-conflict.cabal`,斷言 `build-depends` 不含 `storyflow-service` / `storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple`;含 `storyflow-core` |
| T2 | `conflict/test/.../OptsSpec.hs` → `預設值對應 ADR-007 的約束` | `defaultConflictOpts` 的四個欄位分別是 20 / `False` / `Nothing` / 2;`Draft` 的 `drRefs` 允許空清單且那是合法輸入 |
| T3 | `conflict/test/.../EvidenceSpec.hs` → `GraphEvidence 表達得出 core 的兩種輸出` | 拿 `contradictionPairs` 形狀的 `(Id, Ref)` 樣本能直接組出 `GraphEvidence`;`geTo` 帶 `refVault` 的跨 Vault 目標構造得出來且欄位不失真 |
| T4 | `conflict/test/.../ReportSpec.hs` → `三種命中與空報告` | 三個 `HitLayer` 建構子各組一筆 `ConflictHit`;第 1 層的 `chSnippet` 可為 `Nothing`;`emptyReport` 的 `crHits` 為空、`crScanned` 為 0 |
| T5 | `conflict/test/.../SortSpec.hs` → `排序約定` | 混合三層的清單經 `sortHits` 後順序是 Graph → Retrieval → Judge;同層依分數遞減;`layerTag` 對三個建構子回 `"graph"` / `"retrieval"` / `"judge"` |
| T6 | `conflict/test/.../JsonSpec.hs` → `編碼約定與 round-trip` | 七個型別各自 `decode . encode == Just x`;`HitLayer` 編出的物件含 `layer` 鍵、值等於 `layerTag`,且**不含**任何 Haskell 建構子名;`chSnippet` 為 `Nothing` 時該鍵整個不出現;`Id` / `Ref` 編成字串不是物件 |

## 實作備註

實作完全照文檔進行,沒有偏離規格方案。以下是規格沒寫死、實作時補上的決定,以及一處
需要開發者知道的取捨。

### 1. 落地位置

```text
conflict/
├── storyflow-conflict.cabal
├── src/StoryFlow/Conflict/Types.hs
├── src/StoryFlow/Conflict/Json.hs
└── test/
    ├── Spec.hs
    └── StoryFlow/Conflict/{Cabal,Opts,Evidence,Report,Sort,Json}Spec.hs + Fixtures.hs
```

`cabal.project` 兩處同步:`packages:` 加 `conflict/`(排在 `service/` 之後、`cli/` 之前,
與四層順序一致),以及一組 `package storyflow-conflict` 的 `ghc-options`(與其他八個套件同一組
警告旗標)。

### 2. library 的 build-depends 與 test-suite 的不同

驗收標準 4 管的是 **library**:它的 `build-depends` 就是規格指定的
`base` / `text` / `containers` / `aeson` / `storyflow-core`,沒有第六個。

test-suite 另外需要 `bytestring` / `directory`(`CabalSpec` 要以 UTF-8 讀 `.cabal` 檔)與
`time`(fixture 的 `Meta` 需要 `Day`)。這些是測試相依,不影響「型別層不綁實作進度」那個性質
——`CabalSpec` 本身只掃以逗號開頭的相依行,library 與 test-suite 的都掃,禁用清單
(`storyflow-service` / `storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple`)
兩邊都不得出現。

**待開發者裁示**:`containers` 是規格指定的,但這兩個模組目前沒有 import 它(`Set` / `Map`
要到第 1 層 `Conflict.Graph` 才會用上)。維持宣告以符合規格;若偏好零未用相依,下一份文檔
動工時再加回即可。

### 3. FromJSON 的缺欄位行為(規格未指定,實作補上)

規格只要求 round-trip 不失真,沒說解碼端遇到缺欄位該怎麼辦。實作一律採「有預設就退回預設」:

- `ConflictOpts` 的四個欄位各自退回 `defaultConflictOpts` 的那一欄 —— 客戶端只想調 `top_n`
  時不該被迫把四欄寫齊,而這正是 `defaultConflictOpts` 存在的理由
- `Draft` 的 `refs` 缺省為 `[]`(空清單本來就是合法輸入)、`ConflictHit` 的 `reason` 缺省為
  `""`、`ConflictReport` 的三欄退回 `emptyReport` 的值

必填的只有真正無從預設的欄位:`Draft.text`、`GraphEvidence` 三欄、`HitLayer` 的 `layer` 標籤
與其對應的值、`ConflictHit.target`、`ContextHit.meta` / `via`。

`layer` 標籤認不得時**解析失敗**而不是退回某一層 —— 未知層級靜默變成 `retrieval` 會讓
「第 1 層是事實、第 3 層是判斷」這個區分在解碼端失守。已由測試釘住。

### 4. `ByGraph` 的證據攤平在同一層

`{"layer":"graph","from":…,"kind":…,"to":…}`,而不是巢狀的
`{"layer":"graph","evidence":{…}}`。依規格「六、JSON 編碼」的範例逐字實作。

### 5. `sortHits` 對第 1 層的處理

`ByGraph` 沒有分數(它是事實,不是程度),排序鍵給 0;`sortOn` 是穩定排序,因此同為第 1 層的
多筆命中維持傳入的相對順序,而不是靠一個假分數決定誰先誰後。已由測試釘住。

### 6. 測試 fixture 不共用 core 的

`core` 的 `StoryFlow.Core.Fixtures` 是它自己 test-suite 的模組,不對外 expose。抄三個小函式
(`idOf` / `refOf` / `metaOf`)比為此拆一個共用測試套件划算。

### 7. 驗證結果

```text
cabal build all                             通過,storyflow-conflict 零警告
cabal test all --test-show-details=direct   9 個 test suite 全數 PASS
  storyflow-conflict-test  26 examples, 0 failures   ← 本文檔 新增
  其餘八個                  912 examples, 0 failures  ← 無回歸
```
