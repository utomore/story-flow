---
id: func-0010
type: spec
title: conflict-graph
description: 衝突偵測第 1 層:順關聯圖找出確定性的矛盾與已被取代命中
status: open
created: 2026-08-18
updated: 2026-08-19
depends-on: [func-0002, func-0009]
related-adr: [adr-0005, adr-0007]
related-spec: []
---

# 衝突偵測第 1 層(圖遍歷) 功能規格

## 功能概述

`subarch-0003` 階段一的第二項。給一組「草稿已引用的片段 id」,順著關聯圖找出兩種
**完全確定性、零成本**的命中:

1. **已知矛盾**——草稿引用的片段與另一個片段已被標記 `contradicts`
2. **已被取代**——草稿引用的片段已被別的片段 `supersedes`,亦即「你正在引用一個已經被推翻的設定」

這一層是 ADR-0007 三層中唯一**不需要任何模型、也不需要檢索**的一層。它的輸出是**事實**
(作者自己標註過的關聯),不是判斷——這正是 `HitLayer` 必須把層級寫進輸出的理由。

本 spec 交付的是**純函式**:吃一張 `LinkGraph` 與一組起點 id,吐 `[ConflictHit]`。
**不碰 `service`、不碰 `store`、不開索引連線**,`storyflow-conflict` 的 `build-depends`
在本 spec 之後仍然只有 `storyflow-core`(func-0009 的 `CabalSpec` 必須保持綠燈)。
圖從哪裡來是後續 spec 的事:`storyflow-store` 已有 `loadLinkGraph`,但 `StoryFlow.Service`
目前沒有把它匯出,**補上那條 service 出口屬於 conflict-retrieval / context-command**
(subarch-0003 功能規劃 #3 / #4)。

明確**不做**:候選撈取(第 2 層)、語意判斷(第 3 層)、三層合流與排序(`Conflict.Pipeline`)、
CLI 與 REST 的接線、任何資料修改。

驗收標準:

1. 草稿引用的片段與另一端有 `contradicts` 標註時必定命中,且**不論那條關聯寫在哪一端**
2. 草稿引用的片段被 `supersedes` 時,命中回報的是**取代者**(該用哪一個),而不只是「這個過時了」;
   取代鏈遞移展開,回報鏈末端並標明跳數
3. 每一筆命中的 `chLayer` 都是 `ByGraph`,且 `GraphEvidence` 三元組足以讓後續 feature
   直接反問「要不要建立這條關聯」,不必回頭再查圖(func-0009 驗收標準 2)
4. 同一份輸入永遠得到**逐位元組相同**的輸出順序——第 1 層是確定性層,順序不確定就不可測
5. 跨 Vault 的關聯目標命中得出來,`refVault` 不遺失
6. `storyflow-conflict.cabal` 的 `build-depends` 沒有增長

## 相依性

`depends-on: [func-0002, func-0009]`。

- **func-0009(conflict-types)**:本 spec 的輸出型別 `ConflictHit` / `HitLayer` / `GraphEvidence`
  與輸入選項 `ConflictOpts` 全部由它定義,套件 `storyflow-conflict` 本身也是它建立的。
  這是一個真正的前置,不是排序偏好——**它已實作完成並併入 main**,因此本 spec 現在就能開工
- **func-0002(core-types-and-registry)**:`LinkGraph` / `Id` / `Ref` / `Link` / `LinkKind`
  與 `localRef` / `renderId` / `renderRef` 都來自 core,且**已實作完成**

**可否平行開發**:func-0009 完成之後,本 spec 可與 `conflict-retrieval`(第 2 層)**完全平行**
——兩者都只依賴 func-0009,彼此不互相引用,連合流都要等 `Conflict.Pipeline` 才發生。
與 `subarch-0004` 的任何工作也無相依(本層不碰 LLM)。

**本層對 func-0009 的一條要求,它的實作已經滿足**:`sortHits` 用 `sortOn`(穩定排序),
且 `ByGraph` 的排序鍵給 `0` 而不是捏一個假分數(func-0009 實作備註 5)。本層已經把命中排成
確定順序交出去,`Conflict.Pipeline` 合流時因此不會把 `ByGraph` 之間的相對順序打散
——驗收標準 4 在合流那一步撐得住。`ByGraph` 沒有分數,func-0009 的「同層依分數遞減」
對它本來就無從適用。

## 實作方式

### 一、模組與資料流

`storyflow-conflict` 新增一個模組,不動 func-0009 建立的兩個:

```text
conflict/src/StoryFlow/Conflict/
├── Types.hs   -- func-0009
├── Json.hs    -- func-0009
└── Graph.hs   -- 本 spec
```

```text
[Id](草稿引用的片段)          LinkGraph(整張關聯圖,由呼叫端載入)
        │                              │
        │                    ┌─────────┴──────────┐
        │                    │ revIndex           │  反向索引(只收未限定 vault 的目標)
        │                    └─────────┬──────────┘
        ├───────────────┬──────────────┤
        ▼               ▼              ▼
  contradictionFindings        supersessionFindings
  (正向 + 反向,固定一跳)      (反向 BFS,最多 coGraphDepth 跳,回鏈末端)
        └───────────────┬──────────────┘
                        ▼
                  [GraphFinding]        中間結果:帶起點、跳數、截斷旗標、關聯附註
                        │
              dedupeFindings → sortFindings
                        │
                        ▼
             renderGraphReason → [ConflictHit]
```

### 二、反向索引:為什麼一定要有

`LinkGraph = M.Map Id [Link]`,關聯只存在**來源端**(ADR-0002)。第 1 層要回答的兩個問題
都需要反著問:

- 「誰標記了與我矛盾」——`contradicts` 語意對稱,但作者只會寫在其中一端。只走正向的話,
  命中率取決於當初順手寫在哪一邊,而那是隨機的
- 「誰取代了我」——`supersedes` 是有方向的,而「我被誰取代」**只有反向查得到**

```haskell
type RevIndex = M.Map Id [(Id, Link)]   -- 目標 id → [(來源 id, 那條關聯原文)]
```

**只收 `refVault == Nothing` 的關聯**。這與 core 的 `follow` 完全同一條規則
(`isNothing (refVault r)` 才繼續展開):純函式不知道自己是哪個 Vault,把
`liftgame:ent-7f3a` 當成本地 `ent-7f3a` 反查,會在兩個 Vault 的 id 恰好相同時製造假命中。
代價是作者若把本 Vault 的參照寫成自我限定形式(`本vault名:ent-xxxx`),它不會進反向索引
——正向仍然照常命中。要根治得讓呼叫端在載入圖時把指向本 Vault 的 `Ref` 正規化成
`refVault = Nothing`,那是 #4 接線時的事,本層不猜自己的 Vault 名。

**正向不受此限**:`linkTarget` 帶著完整的 `Ref` 走進 `GraphEvidence`,跨 Vault 的命中因此
表達得出來(驗收標準 5)。`ConflictHit` 的 `chTarget :: Id` 只放 `refId`,vault 名由
`geTo` 保存,不遺失。

### 三、矛盾命中(固定一跳,雙向)

對每個起點 `x`:

- **正向**:`M.findWithDefault [] x g` 中 `linkKind == Contradicts` 的每一條 `l`
  → 命中目標 `refId (linkTarget l)`,證據 `GraphEvidence x Contradicts (linkTarget l)`
- **反向**:`revIndex` 中 `x` 的每一筆 `(src, l)` 且 `linkKind l == Contradicts`
  → 命中目標 `src`,證據 `GraphEvidence src Contradicts (linkTarget l)`
  ——**證據是關聯原文,不翻轉方向**

兩者都是 `gfHops = 1`、`gfTruncated = False`,`gfNote = linkNote l`。

**`contradicts` 不遞移**:「A 與 B 矛盾、B 與 C 矛盾」推不出「A 與 C 矛盾」,那只會製造假衝突。
因此 `coGraphDepth` **不作用在這一層的矛盾部分**。

自我關聯(`linkTarget` 就是起點自己)略過——那是資料錯誤,不是衝突。

### 四、取代命中(反向 BFS,回鏈末端)

從起點 `x` 沿 `revIndex` 的 `Supersedes` 邊逐層展開,最多 `coGraphDepth` 跳
(語意與 core 的 `follow` 一致:`depth` 是**展開輪數**,`2` = 最多兩跳)。

- **只回鏈末端**:`A supersedes B`、`B supersedes C`,草稿引用 `C` 時回報的是 `A`。
  中途的 `B` 自己也已經過時,把作者指向 `B` 是錯的
- **證據是壓縮後的結論**:多跳時 `GraphEvidence A Supersedes (localRef C)` 並非圖上任何一條
  關聯原文,而是遞移後的結論;跳數寫進 `gfHops`,理由文案會標明。單跳時它就是原文那條關聯,
  `gfNote` 也帶得出 `linkNote`(多跳時 `gfNote = Nothing`——中間那幾條附註各講各的,
  湊在一起只會誤導)
- **深度截斷**:因 `coGraphDepth` 用盡而停在一個**仍有取代者**的節點時,該節點照樣回報,
  但 `gfTruncated = True`,理由文案加註「可能還有更新的版本」。安靜地把它當末端等於說謊
- **成環保險**:`supersedes` 被寫成環是可能的(`A supersedes B` + `B supersedes A`)。
  BFS 帶 visited 集合,起點自己永遠不進結果——與 core 的 `Graph` 同一套保險
- `coGraphDepth <= 0` 時本節不產出任何命中;矛盾命中不受影響(它固定一跳,與深度無關)

ADR-0005 的「B 被 A 取代後不再當比對基準」在 core 是 `supersededSet` 的遞移閉包,本層做的是
**同一件事的反向、帶證據版本**。`supersededSet` 只回一個 `Set Ref`,說不出「誰取代的」、
「幾跳」、「哪一條關聯」——那四樣正是命中要交出去的東西,所以本層在 core 的**資料結構**上
自己走一次,而不是重寫 core 的**函式**。測試會拿 `supersededSet` 當 oracle 交叉驗證。

### 五、去重與排序(確定性的來源)

**去重鍵 `(geFrom, geKind, geTo)`**——整條證據,不是只看 target。同一個片段若既與草稿矛盾、
又出現在取代鏈上,那是**兩件事**,作者兩件都要看到。同一條證據由多個起點抵達時
(例如兩個草稿引用共用一條矛盾標註)取 `gfHops` 最小的那一筆,同跳數則取起點 id 字典序較小者。

草稿**同時引用矛盾對的兩端**時,正向與反向會產出同一條證據、但 target 互為對方;
去重後只留一筆。這不會漏資訊——理由文案本來就同時寫出兩端的 id。

**排序**(這一段就是驗收標準 4):

1. `gfHops` 遞增——確定性最高、離草稿最近的先講
2. `geKind`:`Contradicts` 先於 `Supersedes`。直接用 `LinkKind` 的 derived `Ord`
   (建構子順序即 architecture.md 的關聯詞彙表順序);測試把這個假設釘住,
   將來有人重排建構子會立刻紅燈
3. `chTarget` 的 id 字典序(`Id` 的 `Ord` 由 newtype deriving 自 `Text`)

三個鍵排完仍相同的兩筆,必然已經在去重那一步合併,因此輸出順序是**全序、可重現**。

### 六、理由文案

繁體中文,固定句型,id 一律用 `renderId` / `renderRef`(跨 Vault 目標因此顯示成 `vault:id`):

| 情況 | 文案 |
|---|---|
| 矛盾(無附註) | `你引用的 ent-7f3c 與 ent-91cc 已標記矛盾` |
| 矛盾(有附註) | `你引用的 ent-7f3c 與 ent-91cc 已標記矛盾:對雙親死因的敘述不一致` |
| 取代(一跳) | `你引用的 ent-91cc 已被 ent-7f3c 取代` |
| 取代(多跳) | `你引用的 ent-91cc 已被 ent-7f3c 取代(經 2 跳)` |
| 取代(截斷) | `你引用的 ent-91cc 已被 ent-7f3c 取代(已達深度上限 2,可能還有更新的版本)` |

矛盾的句型**對稱**、不區分正反向:方向資訊在 `GraphEvidence` 裡,勉強寫進中文句子只會讓
兩個方向讀起來像兩種不同的事實,而它們是同一件。

`chSnippet` **一律 `Nothing`**:第 1 層命中的是一條關聯,不是某一段文字(func-0009 已言明)。

### 七、空起點的回報

`unlinkedRefs` 回報「在圖上一條關聯都沒有」的起點——既不是 `LinkGraph` 的鍵(或鍵對應空清單)、
也不是任何本地關聯的目標。ADR-0007「中立」那一條說第 1 層的價值取決於作者是否勤於標註;
把「這幾個片段完全沒有標註」變成可查詢的事實,#4 的 CLI 才提醒得出來,不然
「沒有發現矛盾」與「根本沒有東西可查」對外長得一模一樣。

它**分辨不了「片段不存在」**——那需要索引,屬於 service。函式註解要寫明這條界線,
免得呼叫端拿它當存在性檢查。輸出保持輸入順序並去重。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `type LinkGraph = M.Map Id [Link]` | `core/src/StoryFlow/Core/Graph.hs` | func-0002 | 本層唯一的輸入圖結構,不另造 |
| `supersededSet :: LinkGraph -> Set Ref` | `core/src/StoryFlow/Core/Graph.hs` | func-0002 | 測試 oracle:本層回報的每個被取代端都必須落在它裡面 |
| `follow :: [LinkKind] -> Int -> Id -> LinkGraph -> Set Ref` | `core/src/StoryFlow/Core/Graph.hs` | func-0002 | 不直接呼叫;`coGraphDepth` 的「展開輪數」語意與只展開 `refVault == Nothing` 的規則都對齊它 |
| `newtype Id = Id Text`(`deriving newtype (Eq, Ord)`) | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 起點、`chTarget`、`geFrom` 的型別;排序第三鍵用它的 `Ord` |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | `geTo`;反向索引以 `refVault == Nothing` 判定本地 |
| `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 反向命中與取代命中構造 `geTo` |
| `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 理由文案 |
| `renderRef :: Ref -> Text` | `core/src/StoryFlow/Core/Id.hs` | func-0002 | 理由文案的跨 Vault 目標顯示成 `vault:id` |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` | `core/src/StoryFlow/Core/Link.hs` | func-0002 | 走訪的邊;`linkNote` 進理由文案 |
| `data LinkKind = Contradicts \| Supersedes \| … \| Custom Text`(`deriving stock (Show, Eq, Ord)`) | `core/src/StoryFlow/Core/Link.hs` | func-0002 | 過濾兩種核心關聯;排序第二鍵用它的 derived `Ord` |
| `data ConflictOpts = ConflictOpts { coTopN :: Int, coExpandBody :: Bool, coTimelineWindow :: Maybe Int, coGraphDepth :: Int }` | `conflict/src/StoryFlow/Conflict/Types.hs` | func-0009 | 本層只讀 `coGraphDepth`;整包收下是為了三層共用同一組選項 |
| `data GraphEvidence = GraphEvidence { geFrom :: Id, geKind :: LinkKind, geTo :: Ref }` | `conflict/src/StoryFlow/Conflict/Types.hs` | func-0009 | 每一筆命中的證據 |
| `data HitLayer = ByGraph GraphEvidence \| ByRetrieval Double \| ByJudge Double` | `conflict/src/StoryFlow/Conflict/Types.hs` | func-0009 | 本層一律產出 `ByGraph` |
| `data ConflictHit = ConflictHit { chTarget :: Id, chLayer :: HitLayer, chReason :: Text, chSnippet :: Maybe Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | func-0009 | 本層的最終輸出型別 |
| `data Draft = Draft { drText :: Text, drRefs :: [Id] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | func-0009 | 呼叫端傳的是 `drRefs`;本層不吃 `Draft`(第 1 層用不到 `drText`) |

> func-0009 已實作完成(`status: done`),上列四列的簽名是從
> `conflict/src/StoryFlow/Conflict/Types.hs` 讀出的**原文**,不是 spec 的紙上約定;
> `defaultConflictOpts` 的 `coGraphDepth = 2` 也已落地。本層開工時無待查證的介面。

## 新增的介面

### `StoryFlow.Conflict.Graph`

```haskell
module StoryFlow.Conflict.Graph
  ( -- * 門面
    graphHits
  , unlinkedRefs
    -- * 中間結果(供 Pipeline 與測試使用)
  , GraphFinding (..)
  , RevIndex
  , revIndex
  , contradictionFindings
  , supersessionFindings
  , dedupeFindings
  , sortFindings
  , renderGraphReason
  ) where

-- | 目標 id → [(來源 id, 那條關聯原文)]。
--   只收 @refVault == Nothing@ 的關聯:純函式不知道自己是哪個 Vault,
--   把自我限定的跨 Vault 參照當本地反查會製造假命中。規則與 Core.Graph 的 follow 一致。
type RevIndex = M.Map Id [(Id, Link)]

revIndex :: LinkGraph -> RevIndex

-- | 一筆命中的完整素材。比 ConflictHit 多的三樣東西——起點、跳數、截斷旗標
--   ——是去重、排序與理由文案需要的,壓成 ConflictHit 之後就取不回來了。
data GraphFinding = GraphFinding
  { gfStart     :: Id             -- ^ 草稿引用的哪一個片段導出這筆命中
  , gfTarget    :: Id             -- ^ 命中的另一端,對應 chTarget
  , gfEvidence  :: GraphEvidence
  , gfHops      :: Int            -- ^ 矛盾恆為 1;取代為鏈長
  , gfTruncated :: Bool           -- ^ 因 coGraphDepth 用盡而停在仍有取代者的節點
  , gfNote      :: Maybe Text     -- ^ 關聯原文的 linkNote;多跳的取代為 Nothing
  }
  deriving stock (Show, Eq)

-- | 第 1 層的矛盾部分:正向 + 反向,固定一跳,不遞移。自我關聯略過。
contradictionFindings :: LinkGraph -> RevIndex -> Id -> [GraphFinding]

-- | 第 1 層的取代部分:沿 RevIndex 的 supersedes 邊反向 BFS,最多 depth 跳,
--   只回鏈末端;帶 visited 防環;depth <= 0 回空清單。
supersessionFindings :: Int -> RevIndex -> Id -> [GraphFinding]

-- | 依 (geFrom, geKind, geTo) 去重,同鍵取最小 gfHops、再取 gfStart 字典序較小者。
dedupeFindings :: [GraphFinding] -> [GraphFinding]

-- | gfHops 遞增 → geKind(Contradicts 先於 Supersedes)→ gfTarget 字典序。
sortFindings :: [GraphFinding] -> [GraphFinding]

-- | 繁中理由文案。矛盾的句型對稱、不區分正反向;取代標明跳數與深度截斷。
renderGraphReason :: GraphFinding -> Text

-- | 第 1 層門面。輸入去重保序,輸出恆為 ByGraph、chSnippet 恆為 Nothing,
--   順序完全確定:同一份輸入永遠得到同一份輸出。
graphHits :: ConflictOpts -> LinkGraph -> [Id] -> [ConflictHit]

-- | 在圖上一條關聯都沒有的起點(第 1 層對它們完全幫不上忙)。
--   __分辨不了「片段不存在」__ ——那需要索引,屬於 service。輸出保持輸入順序並去重。
unlinkedRefs :: LinkGraph -> [Id] -> [Id]
```

`storyflow-conflict.cabal` 的 `exposed-modules` 加一行 `StoryFlow.Conflict.Graph`,
`build-depends` **不動**(`base` / `text` / `containers` / `aeson` / `storyflow-core`)。

## TodoList

- [ ] T1: `revIndex` 與 `RevIndex`:反向索引,只收 `refVault == Nothing` 的關聯  `dep: func-0009`
- [ ] T2: `contradictionFindings`:正向 + 反向、固定一跳、略過自我關聯,證據保留關聯原文方向  `dep: T1`
- [ ] T3: `supersessionFindings`:反向 BFS 最多 `coGraphDepth` 跳、只回鏈末端、`gfTruncated` 與防環  `dep: T1`
- [ ] T4: `renderGraphReason`:五種句型(矛盾 ±附註、取代 一跳/多跳/截斷),跨 Vault 目標用 `renderRef`  `dep: T2, T3`
- [ ] T5: `dedupeFindings` 與 `sortFindings`:去重鍵與三層排序鍵  `dep: T2, T3`
- [ ] T6: `graphHits` 門面(輸入去重保序 → 兩種發現 → 去重 → 排序 → `ConflictHit`)與 `unlinkedRefs`  `dep: T4, T5`
- [ ] T7: cabal `exposed-modules` 與 `test/Spec.hs` 註冊新模組,確認 `build-depends` 未增長  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `conflict/test/StoryFlow/Conflict/GraphSpec.hs` → `反向索引只認未限定 vault 的目標` | 一張含本地與跨 Vault 目標的圖,`revIndex` 只索引到前者;同一目標被多個來源指到時全部收齊且保序 |
| T2 | 同檔 → `矛盾雙向各命中一次` | `A contradicts B`:起點 A 命中 B、起點 B 也命中 A,兩者的 `gfEvidence` 都是關聯原文 `(A, Contradicts, B)`;`gfHops = 1`;自我關聯不產出命中;跨 Vault 目標的命中 `geTo` 保留 `refVault` |
| T3 | 同檔 → `取代鏈只回末端` | `A supersedes B`、`B supersedes C`,起點 C 在 `coGraphDepth = 2` 時只回 A 且 `gfHops = 2`;`coGraphDepth = 1` 時回 B 且 `gfTruncated = True`;`coGraphDepth = 0` 回空;`A supersedes B` + `B supersedes A` 的環不無窮迴圈且起點不進結果;**交叉驗證**:回報的被取代端全部落在 core 的 `supersededSet` 內 |
| T4 | 同檔 → `理由文案的五種句型` | 五列文案逐一比對;`linkNote` 有值時以 `:` 接在句尾;多跳出現「(經 N 跳)」、截斷出現「已達深度上限」;跨 Vault 目標顯示成 `vault:id` |
| T5 | 同檔 → `去重與排序是確定的` | 同一條證據由兩個起點抵達只留一筆且取最小跳數;同一 target 的矛盾與取代兩筆都留下;排序結果為 跳數 → `Contradicts` 先於 `Supersedes` → id 字典序;打亂輸入順序後輸出不變 |
| T6 | 同檔 → `門面的輸出契約` | `graphHits` 每一筆 `chLayer` 都是 `ByGraph`、`chSnippet` 恆為 `Nothing`、`chReason` 非空;重複的起點只算一次;空圖或空起點回空清單;`unlinkedRefs` 只列出零關聯的起點、保序去重,有出向或入向關聯的都不列 |
| T7 | `conflict/test/StoryFlow/Conflict/CabalSpec.hs` → `新增模組未帶進新相依` | `exposed-modules` 含 `StoryFlow.Conflict.Graph`;`build-depends` 仍不含 `storyflow-service` / `storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple`(沿用 func-0009 T1 的斷言) |

## 實作備註

(撰寫時留空)
