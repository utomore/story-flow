---
id: F004
type: feature
title: context-command
description: "前兩層合流的 context 出口:story-flow context 與 POST /conflict/context"
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001, F002, F003, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003]
related-adr: [ADR-002, ADR-005, ADR-006, ADR-007, ADR-008]
related-feature: []
---

# F004: context 出口(前兩層合流)

## 功能概述

`conflict-detection` 階段一的最後一項,也是這個階段對外真正交付的東西:把 F002 的第 1 層與
F003 的第 2 層接上 `service`,合流成 `gatherContext`,再以 CLI 與 REST 兩種形式露出去。

ADR-007 那條與三層同等重要的需求——**外部 Agent 常常只需要精準的 context,不需要 story-flow
代它判斷**——就是靠這個出口滿足的。claude code 自己有很強的判斷能力,它要的是「和這段草稿
有關的既有片段,連內容一起給我」,不是一份誰對誰錯的報告。

驗收標準(契約卡原文):

1. 在**完全沒有模型**的環境跑得完(不 import `storyflow-llm`,不發任何外部請求)
2. 每筆 `ContextHit` 帶 `Meta` 與命中片段的 snippet,外部 Agent 不必再往返一次
3. `--json` 走 `service-and-interfaces` 的統一信封 `{"ok":true,"data":…}`
4. CLI 與 REST 兩種形式**回同一批結果**

明確**不做**:不跑第 3 層;不回傳「矛盾」的判斷(那是 F006 `conflict-check`);
不改任何資料(整條路徑只有讀取)。

## 相依性

`depends-on` 的每一項都對應「使用到的既有串接介面」表裡至少一列,沒有一項是憑印象填的:

| 文檔 | 提供什麼 | 本 feature 怎麼用 |
|---|---|---|
| `F001` | `Draft` / `ConflictOpts` / `ContextHit` / `HitLayer` 與它們的 aeson 實例 | 出口的輸入輸出型別、REST body 與 CLI `--json` 的編碼 |
| `F002` | `graphHits` | 第 1 層命中的來源 |
| `F003` | `retrieveCandidates` / `Candidate` / `candidateContextHit` | 第 2 層候選的來源與它到 `ContextHit` 的轉換 |
| `entity-graph-core/F002` | `LinkGraph` / `Ref` / `Meta` | `linkGraph` 的回傳型別、正規化不變量的對象 |
| `entity-graph-core/F004` | `loadLinkGraph`、索引寫入時的 `localize` | `linkGraph` 的實作;`Ref` 正規化的真正發生處 |
| `service-and-interfaces/F001` | `ServiceM` / `Env` / `getEntity` / `linksOf` / `aliasIndex` | 出口跑在 `ServiceM` 上;第 1 層命中補 `Meta` |
| `service-and-interfaces/F002` | `Backend` / `BodySource` / `readBody` / 統一信封 / 渲染器 | CLI 子指令的接線 |
| `service-and-interfaces/F003` | `StoryFlowAPI` / `ToSchema` / servant handler / `servant-client` | REST 路由與 `--remote` 那一條路 |

**能否平行開發**:不能與 `F002` / `F003` 平行——它們是本 feature 的兩個輸入,而且改的是同一批
檔案(`build-log` 的「階段內實作序列」已經把 F002 → F003 → F004 排成序列)。兩者都已 `done`
且程式碼在本分支上,因此本 feature 現在可以直接開工。與階段二的 `F005` / `F006` 之間沒有相依
方向上的衝突,但 `F006` 依賴本 feature,不能反過來先做。

## 對應的 Level 2 契約

| 契約來源 | 條文 | 本 feature 的落點 |
|---|---|---|
| `conflict-detection/design.md` 對外契約 | `gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]` | `StoryFlow.Conflict.Pipeline.gatherContext`,簽名逐字相同 |
| 同上,對外形式表 | `story-flow context --for <檔案\|->` | CLI 新增 `context` 子指令 |
| 同上,對外形式表 | `POST /conflict/context` | `StoryFlow.Api` 新增 `ConflictAPI` 一條路由 |
| 同上,資料流管線 | 「第 1 層 + 第 2 層 → 出口 A」 | `gatherContext` 的內部順序 |
| `service-and-interfaces/design.md` 對外契約 | `linkGraph :: ServiceM LinkGraph`(2026-08-20 加入,**只開內嵌出口**) | `StoryFlow.Service.linkGraph`,本 feature 實作 |

**沒有超出範圍的新公開介面**。`Conflict.Pipeline` 的其餘匯出(`graphContextHits` /
`mergeContextHits` / `sortContextHits`)是子系統內部的中間結果,與 F002 的 `GraphFinding`、
F003 的 `Candidate` 同一種性質:給 `Conflict.Pipeline` 自己與測試用,不上 CLI 也不上 REST。
`ContextReq` 是 REST 的 body 包裝,與既有的 `NewVaultReq` / `BodyReq` 同一種性質
(`service-and-interfaces/design.md` 已把「請求 body 的小包裝」歸給 `storyflow-api`)。

**`linkGraph` 只開內嵌出口**這條約束在本 feature 一樣要守住:它不進 `StoryFlowAPI`、
不進 CLI 的指令樹。REST 那一條路走的是 `POST /conflict/context`,伺服器端自己在
`ServiceM` 裡呼叫 `linkGraph`,整張圖不會被序列化送出去。

## 實作方式

### 一、`linkGraph`:整張關聯圖的內嵌出口

```haskell
linkGraph :: ServiceM LinkGraph
linkGraph = asks envConn >>= liftIO . loadLinkGraph
```

放在 `StoryFlow.Service` 而不是 `storyflow-conflict` 自己去讀,理由是硬性的:
`loadLinkGraph :: Connection -> IO LinkGraph` 住在 `storyflow-store`,而
`conflict/test/StoryFlow/Conflict/CabalSpec.hs` 用**逐字釘住相依清單**的方式擋著
`storyflow-store` / `storyflow-md` / `storyflow-llm` / `sqlite-simple` 四個名字。
`storyflow-conflict` 拿得到整張圖的唯一合法途徑就是經 `ServiceM`。

不做過濾、不做投影:第 1 層的 `revIndex` 需要**全部**關聯(F002 實作備註 1 明說
`revIndex` 刻意不依 `LinkKind` 過濾,因為 `unlinkedRefs` 問的是「有沒有任何關聯」)。

### 二、`Ref` 正規化:查證結果是「上游已經做完了」

F002 的待確認假設 A3 與它的文檔都預告了這件事:「要根治得讓呼叫端在載入圖時把指向本 Vault 的
`Ref` 正規化成 `refVault = Nothing`,那是 #4 接線時的事」。本 feature 就是那個呼叫端,而
**逐一讀原始碼的結果是:這個正規化已經發生在更上游,本層不需要、也不應該再做一次**。

證據鏈(三處,全部讀過原文):

1. `store/src/StoryFlow/Store/Index.hs` 的 `insertLinks` 在寫進 `links` 表之前套用
   `localize :: Vault -> Ref -> Ref`,把 `refVault == Just (vaultName v)` 的目標改成 `Nothing`。
   `links` 表的三個寫入點(Entity / Level / Node)**全部**經過 `insertLinks`,沒有第四條路徑
2. `store/src/StoryFlow/Store/Row.hs` 的 `linkFields` 註解把它寫成表的不變量:
   「`dst_vault` 由呼叫端正規化——指向本 Vault 的參照一律存 `NULL`」
3. `store/src/StoryFlow/Store/Query.hs` 的 `linksTo` **已經依賴**這個不變量:查本地 id 用的是
   `WHERE dst = ? AND dst_vault IS NULL`。而 `loadLinkGraph` 讀的是同一張表

因此 `linkGraph` 交出去的圖,本 Vault 的目標已經全是 `refVault = Nothing`。**本 feature 的作法
是把這個不變量寫進 `linkGraph` 的文件註解,並用一條測試釘住它,而不是在 `Conflict.Pipeline`
再掃一遍圖。** 這與這個 codebase 一貫的紀律一致:`searchEntity` 對兩字詞的 `LIKE` 分流也是
「這裡不重複那個判斷」。在 service 再做一次等於同一條規則有兩份,而其中一份會先過期。

`Env` 的 `envVault` 因此**用不到**——這是好消息而不是遺漏:需要用到它,就代表有一條繞過索引
的路徑存在。

連帶結果:**F002 的 A3 自動變成正確的**。`unlinkedRefs` 唯一會漏掉的情形,是一個本地 id 只被
寫成 `<本vault>:<id>` 的關聯指到——而那種關聯在索引裡已經是 `NULL`,所以它進得了 `revIndex`。
真正剩下的「只被 `shared-lore:ent-e5` 這種**別的 Vault** 的參照指到」則本來就該被列為零關聯,
那個判斷是對的。

### 三、第 1 層命中怎麼變成 `ContextHit`

型別上的落差是真的:`graphHits` 吐的 `ConflictHit` 只有 `chTarget :: Id`、
`chSnippet :: Maybe Text`(第 1 層恆為 `Nothing`),而 `ContextHit` 的 `xhMeta :: Meta` 與
`xhSnippet :: Text` 兩個都不是 `Maybe`。補法:

```text
graphHits opts g (drRefs d)
  → 對每筆 chTarget 呼叫 getEntity(service)
      → 成功:xhMeta = entMeta (evEntity …);xhVia = chLayer(恆為 ByGraph 證據)
      → 失敗(EntityNotFound / 任何 ServiceError):catchError 吞掉,整筆丟棄
  → xhSnippet = metaSnippet:metaSummary 去空白後非空就用它,否則退回 metaTitle
```

三個判斷各有理由:

- **補 `Meta` 走 `getEntity`**:它是 service 唯一的單筆讀取出口,而且 F003 的
  `expandOneHop` 補擴充候選的 `Meta` 走的就是它。兩處用同一條路徑,行為(含錯誤時的
  `catchError`)才會一致
- **查不到就丟棄**,不捏一個空 `Meta`:`ContextHit` 的 `xhMeta` 不是 `Maybe` 是刻意的
  (F001),硬塞一個佔位 `Meta` 會讓外部 Agent 拿到一個 id 是 `ent-00000000` 的東西。
  這種情形本身是資料錯誤(關聯指向不存在的片段),而 F002 的 `unlinkedRefs` 註解已經明說
  「**分辨不了「片段不存在」**:那需要索引,屬於 service」——本層有索引,而它給的答案就是
  「查不到」。把它變成使用者看得見的提示是 `F006 conflict-check` 的事(見「待確認假設 A2」)
- **snippet 用 `metaSnippet`**:第 1 層命中的是**一條關聯**,不是某一段文字,所以它沒有
  FTS5 給的 snippet。`metaSummary` 是這個片段身上最接近「一句話說明」的東西——這正是
  F003 的 `expandOneHop` 對一跳擴充候選採取的同一條規則。因此本 feature 把 F003 內部那個
  `snippetOf` 提升成 `Conflict.Retrieval` 的公開純函式 `metaSnippet :: Meta -> Text`,
  兩處共用一份,而不是抄第二遍

**理由文案沒有遺失**:`ContextHit` 沒有 `reason` 欄位,但 `xhVia = ByGraph (GraphEvidence
from kind to)` 帶著造成命中的完整三元組,JSON 出去就是
`{"layer":"graph","from":…,"kind":…,"to":…}`。`renderGraphReason` 產出的那句繁中本來就只是
這個三元組的**渲染**,人類模式要它時由 CLI 自己組(見第六節),不必也不該塞進 DTO。

### 四、合流、去重與排序

```haskell
gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]
gatherContext opts d = do
  gs <- graphContextHits opts d
  rr <- retrieveCandidates opts d
  pure (mergeContextHits (gs ++ map candidateContextHit (rrCandidates rr)))
```

`mergeContextHits :: [ContextHit] -> [ContextHit]` 是**純函式**(可單獨測,不必開 Vault):

- **去重鍵是 `metaId . xhMeta`**。同一個片段既被作者標了 `contradicts`、又被關鍵詞撈到,
  對使用者來說是一筆,不是兩筆
- **合併規則**:`xhVia` 取層級較前的那一筆(graph → retrieval);`xhSnippet` 取**來自
  `ByRetrieval` 的那一筆**(它是 FTS5 真正命中的那一段,比退化成 summary 的好),沒有就
  保留既有的。這讓「兩層都命中」的片段同時拿到最強的層級標示與最好的片段
- **排序鍵**:`(層級序, Down 分數, metaId)`。層級序 graph = 0、retrieval = 1,與
  `Conflict.Types.sortHits` 的約定同一個方向(第 1 層是事實,排前面);分數 `ByGraph` 一律
  取 0(它是事實不是程度),`ByRetrieval s` 取 `s`;第三鍵是 id 字典序,讓輸出成為**全序**
  ——第 1、2 層都是確定性層,「大致上這個順序」不夠

**`coTopN` 不再截一次**。它是第 2 層的候選上限,`retrieveCandidates` 內部已經套用了;第 1 層
的命中是零成本的事實,數量本來就受作者標註量約束,拿 topN 去砍它會砍掉最有價值的那一批。

**空輸入**:`drRefs` 為空清單是合法輸入(F001 明說),此時 `graphHits` 回空、只有第 2 層有
結果;`drText` 為空則第 2 層抽不出關鍵詞,兩層都空,`gatherContext` 回 `[]` 而不是報錯。

**不改任何資料**:整條路徑只呼叫 `linkGraph` / `getEntity` / `aliasIndex` / `searchEntity` /
`linksOf` 五個讀取操作,沒有任何 `ServiceM` 寫入。

### 五、REST:`POST /conflict/context`

新增一條路由與一個 body 包裝型別,都放 `storyflow-api`(它是 server 與 `cli --remote`
**共用的**契約,住在別處就會讓其中一端依賴另一端):

```haskell
data ContextReq = ContextReq { crqDraft :: Draft, crqOpts :: ConflictOpts }

type ConflictAPI =
  "conflict" :> "context"
    :> Summary "只跑前兩層,把相關片段連內容一起撈出來(不做矛盾判斷)"
    :> ReqBody '[JSON] ContextReq
    :> Post '[JSON] [ContextHit]

type StoryFlowAPI = VaultAPI :<|> EntityAPI :<|> LinkAPI :<|> LevelAPI :<|> NodeAPI :<|> MiscAPI :<|> ConflictAPI
```

- body 形狀 `{"draft": {"text": …, "refs": […]}, "opts": {…}}`;`opts` **缺席時退回**
  `defaultConflictOpts`,與 `Conflict.Json` 的 `FromJSON ConflictOpts` 逐欄退預設是同一個
  待客之道(客戶端只想調 `top_n` 時不必寫齊四欄)
- **沒有 `revision`**:這是唯讀端點。`api/test/…/ApiSpec.hs` 的 `readOnlyRoutes` 斷言
  「唯讀端點沒有 revision」,新路由要加進那張表
- handler 一行:`(\ContextReq{..} -> run1 st (gatherContext crqOpts crqDraft))`,
  與既有 handler 同一種形狀,不含業務判斷
- **`storyflow-api` 與 `storyflow-server` 因此各長出一個 `storyflow-conflict` 相依**。
  這符合 `system.md` 的依賴方向圖(`storyflow-conflict` 在 `storyflow-api` 的上游),
  且兩個套件的 `CabalSpec` 禁用清單裡都沒有它——擋的是 `servant-server` / `servant-client` /
  `warp` / 落地層,而 `storyflow-conflict` 一個都不是

`ToSchema` 這一側要補五個型別(`Draft` / `ConflictOpts` / `GraphEvidence` / `HitLayer` /
`ContextHit`)加上 `ContextReq`。`HitLayer` 是**和積型別**,而 `api` 既有的
`SchemaSpec.aligns` 是「樣本 JSON 的鍵集合 == schema 的 properties 鍵集合」,對和積型別必然
不成立(一個樣本只走得到一個建構子)。作法:

- schema 宣告成聯集物件——properties 有 `layer` / `from` / `kind` / `to` / `score` /
  `confidence` 六個鍵,`required` 只有 `layer`,description 說明它是帶 `layer` 標籤的和
- 測試改用**子集**斷言:三個建構子的樣本各自的 JSON 鍵集合都是 schema properties 的子集,
  且每個樣本都含 `layer`。既有的 `aligns` 一個字都不改,新增一個 `alignsSubset` 給和積用

### 六、CLI:`story-flow context --for <檔案|->`

指令樹上是一個**頂層名詞**(與 `search` 同一種形狀,`design.md` 的對外形式表寫的就是
`story-flow context --for`,不是 `story-flow conflict context`)。

```text
story-flow [--json] context --for <檔案|-> [--ref <id>]… [--top-n <n>]
                            [--timeline-window <n>] [--graph-depth <n>]
```

- `--for` 吃 `BodySource`:`-` 解成 `BodyStdin`,其餘解成 `BodyFile`。**沿用既有的
  `BodySource` 與 `readBody`**(`entity set-body` 的 `-` 就是這條路),連 UTF-8 強制解碼與
  「讀不到檔」的錯誤訊息都一起沿用。`--for` 是**必填**的,沒有預設
- `--ref` 可重複,對應 `drRefs`。**契約卡沒寫這個旗標,但沒有它第 1 層永遠不會啟動**
  ——`graphHits` 完全靠 `drRefs` 起步(見待確認假設 A1)
- 三個數值旗標對應 `ConflictOpts` 的三欄;`coExpandBody` 是第 3 層的東西,**不開旗標**
- 人類模式:`renderContext :: [ContextHit] -> Text`,走既有的 `table` 排版工具
  (`id | type | status | title | via | snippet`),空清單印 `(沒有相關的片段)`。`via` 欄由
  `xhVia` 就地渲染:`graph(contradicts→ent-91cc)` / `retrieval(0.82)`,標籤字串取
  `Conflict.Types.layerTag`,不另寫一份
- `--json`:`plain (renderContext hs) hs`,`data` 就是 `[ContextHit]` 的 aeson 編碼
  (`Conflict.Json` 的孤兒實例,CLI 只要 `import StoryFlow.Conflict.Json ()`),
  外層信封由既有的 `emit` 產生 —— **CLI 不重新編碼**

### 七、`--remote` 那一條路:兩種形式怎麼回同一批結果

這正是 `service-and-interfaces/F002` 已經解掉的問題,本 feature 只要照著它的結構接:
分派發生在**操作**這一層而不是指令這一層。

```haskell
gatherContextB :: Backend -> ConflictOpts -> Draft -> M [ContextHit]
gatherContextB (Embedded e) o d = svc e (gatherContext o d)
gatherContextB (Remote c)   o d = rmt c (cContext (ContextReq d o))
```

`cContext :: ContextReq -> ClientM [ContextHit]` 由 `client (Proxy :: Proxy StoryFlowAPI)`
產生(`Backend.hs` 既有的那一大組解構要多接一個)。兩條路徑**回的是同一個型別
`[ContextHit]`**:內嵌直接拿到,遠端由 `servant-client` 依同一份 API 型別解碼;
`handle` 只看得到 `gatherContextB`,渲染器只有一份。驗收標準 4 因此是**結構上成立**的,
不是靠對照測試碰運氣——但仍然有一條對照測試守著(T14),與 `ParitySpec` 同一個作法。

伺服器端 `gatherContext` 一樣跑在 `ServiceM` 上,只是 `Env` 是伺服器自己那一份。
`--remote` 與 `--vault` 不能併用這條既有規則自動適用(`withBackend` 已經擋了)。

### 八、錯誤處理

| 情形 | 行為 |
|---|---|
| `--for` 指的檔案讀不到 / stdin 讀不到 | `CliInput`,沿用 `readUtf8` 既有訊息與 exit 1 |
| `--ref` 給了不存在的 id | 不失敗:第 1 層在圖上查不到就沒有命中;第 2 層的 `timelineAnchors` 已經逐個 `catchError` 吞掉(F003 既有行為) |
| 第 1 層命中的 target 在索引裡查不到 | 該筆丟棄(第三節);其餘結果照常回 |
| 索引尚未建立 / Vault 定位失敗 | `openEnv` 既有的 `ServiceError`,信封與 exit code 沿用 |
| 遠端連不上 / 伺服器回業務錯誤 | `CliRemote` 既有分類,code 與 message 與內嵌模式字元級相同 |

## 使用到的既有串接介面

每一列的簽名都是從來源檔案讀出的**原文**。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `graphHits :: ConflictOpts -> LinkGraph -> [Id] -> [ConflictHit]` | `conflict/src/StoryFlow/Conflict/Graph.hs` | `F002` | 第 1 層命中 |
| `unlinkedRefs :: LinkGraph -> [Id] -> [Id]` | `conflict/src/StoryFlow/Conflict/Graph.hs` | `F002` | 本次**不接**(見 A2),但正規化不變量的正確性論證引用它 |
| `retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | `F003` | 第 2 層候選 |
| `data RetrievalResult = RetrievalResult { rrCandidates :: [Candidate], rrScanned :: Int, rrKeywords :: [Text] }` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | `F003` | 取 `rrCandidates`;`rrScanned` / `rrKeywords` 屬 `ConflictReport`,本出口不用 |
| `data Candidate = Candidate { caMeta :: Meta, caSnippet :: Text, caScore :: Double, caOrigin :: CandidateOrigin }` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | `F003` | 候選的載體 |
| `candidateContextHit :: Candidate -> ContextHit` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | `F003` | 第 2 層到出口型別的既有轉換,直接用 |
| `data ConflictHit = ConflictHit { chTarget :: Id, chLayer :: HitLayer, chReason :: Text, chSnippet :: Maybe Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | 第 1 層輸出的形狀 |
| `data ContextHit = ContextHit { xhMeta :: Meta, xhSnippet :: Text, xhVia :: HitLayer }` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | 出口的元素型別 |
| `data ConflictOpts = ConflictOpts { coTopN :: Int, coExpandBody :: Bool, coTimelineWindow :: Maybe Int, coGraphDepth :: Int }` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | CLI 旗標與 REST body 的來源 |
| `defaultConflictOpts :: ConflictOpts` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | CLI 與 REST 的預設值 |
| `data Draft = Draft { drText :: Text, drRefs :: [Id] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | 出口的輸入 |
| `data HitLayer = ByGraph GraphEvidence \| ByRetrieval Double \| ByJudge Double` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | 排序鍵與 `via` 欄的渲染 |
| `layerTag :: HitLayer -> Text` | `conflict/src/StoryFlow/Conflict/Types.hs` | `F001` | CLI `via` 欄的標籤,不另寫字串 |
| `instance ToJSON ContextHit` / `instance FromJSON ContextHit`(`StoryFlow.Conflict.Json`,孤兒實例模組) | `conflict/src/StoryFlow/Conflict/Json.hs` | `F001` | `--json` 與 REST body 的編碼 |
| `getEntity :: Id -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | `service-and-interfaces/F001` | 第 1 層命中補 `Meta` |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` | `service/src/StoryFlow/Service/Types.hs` | `service-and-interfaces/F001` | 由它取 `entMeta . evEntity` |
| `aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]` | `service/src/StoryFlow/Service.hs` | `service-and-interfaces/F001` | 間接:`retrieveCandidates` 內部使用 |
| `searchEntity :: Text -> EntityFilter -> ServiceM [SearchHit]` | `service/src/StoryFlow/Service.hs` | `service-and-interfaces/F001` | 間接:同上 |
| `linksOf :: Id -> ServiceM LinkReport` | `service/src/StoryFlow/Service.hs` | `service-and-interfaces/F001` | 間接:一跳擴充 |
| `data Env = Env { envVault :: Vault, envConn :: Connection, envTypes :: TypeRegistry }` | `service/src/StoryFlow/Service/Monad.hs` | `service-and-interfaces/F001` | `linkGraph` 由它取 `envConn` |
| `newtype ServiceM a`(`ReaderT Env (ExceptT ServiceError IO)`,`deriving newtype MonadError / MonadReader / MonadIO`) | `service/src/StoryFlow/Service/Monad.hs` | `service-and-interfaces/F001` | 出口的 monad |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | `service/src/StoryFlow/Service/Monad.hs` | `service-and-interfaces/F001` | CLI 內嵌路徑與測試 |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))` | `service/src/StoryFlow/Service/Monad.hs` | `service-and-interfaces/F001` | 測試建臨時 Vault |
| `loadLinkGraph :: Connection -> IO LinkGraph` | `store/src/StoryFlow/Store/Query.hs` | `entity-graph-core/F004` | `linkGraph` 的實作(經 `StoryFlow.Store` 再匯出) |
| `localize :: Vault -> Ref -> Ref`(private,`insertLinks` 內套用) | `store/src/StoryFlow/Store/Index.hs` | `entity-graph-core/F004` | **`Ref` 正規化的真正發生處**;本 feature 只釘住它的結果,不呼叫 |
| `type LinkGraph = M.Map Id [Link]` | `core/src/StoryFlow/Core/Graph.hs` | `entity-graph-core/F002` | `linkGraph` 的回傳型別 |
| `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` | `core/src/StoryFlow/Core/Id.hs` | `entity-graph-core/F002` | 正規化不變量的斷言對象 |
| `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | `entity-graph-core/F002` | 測試裡構造本地參照 |
| `data Meta`(`metaId` / `metaTitle` / `metaSummary` / `metaStatus` 等十四欄) | `core/src/StoryFlow/Core/Meta.hs` | `entity-graph-core/F002` | `xhMeta` 的內容與 `metaSnippet` |
| `data BodySource = BodyLiteral Text \| BodyFile FilePath \| BodyStdin` | `cli/src/StoryFlow/Cli/Options.hs` | `service-and-interfaces/F002` | `--for <檔案\|->` 的解析結果 |
| `data Command = … \| EntitySetBody Selector (Maybe Int) BodySource \| …` | `cli/src/StoryFlow/Cli/Options.hs` | `service-and-interfaces/F002` | 要多一個建構子 |
| `parseCli :: [String] -> ParserResult (GlobalOpts, Command)` | `cli/src/StoryFlow/Cli/Options.hs` | `service-and-interfaces/F002` | 指令樹的進入點 |
| `data Backend = Embedded Env \| Remote ClientEnv` | `cli/src/StoryFlow/Cli/Backend.hs` | `service-and-interfaces/F002` | 兩條路徑的分派 |
| `type M = ExceptT CliError IO` | `cli/src/StoryFlow/Cli/Backend.hs` | `service-and-interfaces/F002` | 指令執行環境 |
| `table :: [Text] -> [[Text]] -> Text` / `displayWidth :: Text -> Int` | `cli/src/StoryFlow/Cli/Render.hs` | `service-and-interfaces/F002` | `renderContext` 的排版 |
| `data Envelope a = Ok a \| Err Text Text` / `encodeEnvelope :: ToJSON a => Envelope a -> Text` | `cli/src/StoryFlow/Cli/Render.hs` | `service-and-interfaces/F002` | `--json` 統一信封 |
| `readBody :: CliIO -> BodySource -> M Text`(private,`StoryFlow.Cli`) | `cli/src/StoryFlow/Cli.hs` | `service-and-interfaces/F002` | 讀 `--for` 指的檔案或 stdin |
| `type StoryFlowAPI = VaultAPI :<\|> EntityAPI :<\|> LinkAPI :<\|> LevelAPI :<\|> NodeAPI :<\|> MiscAPI` | `api/src/StoryFlow/Api.hs` | `service-and-interfaces/F003` | 要多接一個子 API |
| `newtype BodyReq = BodyReq { brBody :: Text }`(body 包裝的既有範例,含 `ToJSON` / `FromJSON` / `ToSchema` 三件套) | `api/src/StoryFlow/Api.hs` | `service-and-interfaces/F003` | `ContextReq` 照它的形狀寫 |
| `storyFlowOpenApi :: OpenApi`(含 `applyTagsFor . subOperations`) | `api/src/StoryFlow/Api.hs` | `service-and-interfaces/F003` | 新子 API 要掛 tag |
| `objSchema :: Text -> [(Text, Referenced Schema)] -> [Text] -> Schema` / `named :: Text -> Schema -> NamedSchema`(private 工具) | `api/src/StoryFlow/Api/Instances.hs` | `service-and-interfaces/F003` | 新 `ToSchema` 沿用同一組工具 |
| `handlers :: AppState -> Server StoryFlowAPI` | `server/src/StoryFlow/Server.hs` | `service-and-interfaces/F003` | 要多接一個 handler |
| `run1 :: AppState -> ServiceM a -> Handler a` | `server/src/StoryFlow/Server/State.hs` | `service-and-interfaces/F003` | handler 的一行結構 |

## 新增的介面

```haskell
-- service/src/StoryFlow/Service.hs —— 實作 service-and-interfaces/design.md 已載明的契約
-- 只開內嵌出口:不進 StoryFlowAPI、不進 CLI 指令樹。
--
-- 不變量:回傳的圖裡,指向本 Vault 的目標一律 refVault = Nothing
-- (索引寫入時由 StoryFlow.Store.Index.localize 正規化;linksTo 已依賴同一條)。
linkGraph :: ServiceM LinkGraph

-- conflict/src/StoryFlow/Conflict/Retrieval.hs —— 由既有 private snippetOf 提升
-- metaSummary 去空白後非空就用它,否則退回 metaTitle。
metaSnippet :: Meta -> Text

-- conflict/src/StoryFlow/Conflict/Pipeline.hs(新模組)
--
-- Level 2 對外契約的那一個:
gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]

-- 子系統內部的中間結果,供 Pipeline 自己與測試使用(不上 CLI、不上 REST):
graphContextHits :: ConflictOpts -> Draft -> ServiceM [ContextHit]
mergeContextHits :: [ContextHit] -> [ContextHit]   -- 去重 + 合併 + 排序,純函式
sortContextHits  :: [ContextHit] -> [ContextHit]   -- (層級序, Down 分數, metaId)

-- api/src/StoryFlow/Api.hs —— REST body 的小包裝,與 NewVaultReq / BodyReq 同一種性質
data ContextReq = ContextReq
  { crqDraft :: Draft
  , crqOpts  :: ConflictOpts   -- JSON 缺席時退回 defaultConflictOpts
  }

type ConflictAPI =
  "conflict" :> "context"
    :> Summary "只跑前兩層,把相關片段連內容一起撈出來(不做矛盾判斷)"
    :> ReqBody '[JSON] ContextReq
    :> Post '[JSON] [ContextHit]

-- api/src/StoryFlow/Api/Instances.hs —— ToSchema(孤兒實例,集中一處)
instance ToSchema Draft
instance ToSchema ConflictOpts
instance ToSchema GraphEvidence
instance ToSchema HitLayer      -- 聯集物件,required 只有 layer
instance ToSchema ContextHit

-- cli/src/StoryFlow/Cli/Options.hs
data Command = … | Context BodySource [Id] ConflictOpts

-- cli/src/StoryFlow/Cli/Backend.hs
gatherContextB :: Backend -> ConflictOpts -> Draft -> M [ContextHit]

-- cli/src/StoryFlow/Cli/Render.hs
renderContext :: [ContextHit] -> Text
```

## TodoList

- [x] T1: `StoryFlow.Service` 新增 `linkGraph :: ServiceM LinkGraph`(取 `envConn` → `loadLinkGraph`),加進匯出清單,並在 haddock 寫明「本 Vault 的目標一律 `refVault = Nothing`」這條由索引保證的不變量 `dep: -`
- [x] T2: `Conflict.Retrieval` 把 `expandOneHop` 內的 `snippetOf` 提升為公開的 `metaSnippet :: Meta -> Text` 並加進匯出清單,原處改為呼叫它 `dep: -`
- [x] T3: 新模組 `StoryFlow.Conflict.Pipeline`,實作 `graphContextHits`:`linkGraph` → `graphHits` → 逐筆 `getEntity` 補 `Meta`(`catchError` 查不到就丟棄)→ `metaSnippet` 補 snippet `dep: T1, T2`
- [x] T4: `mergeContextHits` / `sortContextHits` 兩個純函式:依 `metaId` 去重、`xhVia` 取層級較前者、`xhSnippet` 取 `ByRetrieval` 那一筆、排序鍵 `(層級序, Down 分數, metaId)` `dep: T2`
- [x] T5: `gatherContext` 門面:第 1 層 + 第 2 層 → `mergeContextHits`;不再套 `coTopN`;空 `drRefs` / 空 `drText` 都不報錯 `dep: T3, T4`
- [x] T6: `conflict/storyflow-conflict.cabal` 的 `exposed-modules` 加入 `StoryFlow.Conflict.Pipeline`,`build-depends` **一個字不動**;更新 `Conflict.CabalSpec` 加上對應斷言 `dep: T5`
- [x] T7: `storyflow-api` 新增 `ContextReq`(含 `ToJSON` / `FromJSON`)與 `ConflictAPI`,併入 `StoryFlowAPI` 並掛 `conflict` tag;`storyflow-api.cabal` 加 `storyflow-conflict`,`Api.CabalSpec` 的 `required` 補上它 `dep: T5`
- [x] T8: `StoryFlow.Api.Instances` 補六個 `ToSchema`(`Draft` / `ConflictOpts` / `GraphEvidence` / `HitLayer` / `ContextHit` / `ContextReq`),`HitLayer` 用聯集物件 + `required = ["layer"]`;`Api.Fixtures` 補樣本 `dep: T7`
- [x] T9: 更新 `Api.ApiSpec`(operation 23→24、`expectedRoutes` 加 `/conflict/context` post、`readOnlyRoutes` 加它)與 `Api.OpenApiSpec`(paths 14→15、ops 23→24、`expectedSchemas` 補新型別) `dep: T8`
- [x] T10: `storyflow-server` 新增 `conflictH` 一行 handler 併進 `handlers`;`storyflow-server.cabal` 加 `storyflow-conflict`,`Server.CabalSpec` 的 `required` 補上它 `dep: T7`
- [x] T11: CLI `Options`:`Command` 加 `Context BodySource [Id] ConflictOpts`,新增頂層 `context` 子指令與 `--for` / `--ref` / `--top-n` / `--timeline-window` / `--graph-depth` 五個旗標 `dep: -`
- [x] T12: CLI `Backend`:`cContext` client 函式(解構多接一項)與 `gatherContextB` 兩條分派 `dep: T7, T11`
- [x] T13: CLI `Render.renderContext` + `StoryFlow.Cli.handle` 接線(`--for` 走既有 `readBody`),`--json` 走既有信封;`storyflow-cli.cabal` 加 `storyflow-conflict`,`Cli.CabalSpec` 的 `required` 補上它 `dep: T12`
- [x] T14: 端到端對照:同一個臨時 Vault、同一份草稿,內嵌與 `--remote` 兩種形式的 stdout 與 `--json` 信封逐字元相等 `dep: T10, T13`

## 1-to-1 測試對照表

測試框架 **hspec**。既有檔案就地擴充,新檔案要同步登記進對應 `.cabal` 的 `other-modules`。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `service/test/StoryFlow/Service/LinkGraphSpec.hs`(新檔) | ① 建三個片段兩條關聯,`linkGraph` 回的 `Map` 鍵與每個桶的 `linkTarget` 與寫進去的一致;② **正規化**:以 `addLink` 掛一條 target 為 `Ref (Just <本vault名>) i` 的關聯,`linkGraph` 回的那條 `refVault` 是 `Nothing`;③ 零關聯的 Vault 回空 `Map` |
| T2 | `conflict/test/StoryFlow/Conflict/RetrievalSpec.hs`(擴充) | `metaSnippet`:summary 非空取 summary、summary 全為空白取 title、兩者皆空回空字串;且一跳擴充候選的 `caSnippet` 與 `metaSnippet` 逐字相同(證明只有一份規則) |
| T3 | `conflict/test/StoryFlow/Conflict/PipelineSpec.hs`(新檔)`describe "第 1 層命中補 Meta"` | 建 `A contradicts B`,以 `drRefs = [A]` 呼叫 `graphContextHits`:回一筆,`metaId (xhMeta …) == B`、`xhVia` 是 `ByGraph`(`geFrom`/`geKind`/`geTo` 三欄正確)、`xhSnippet == metaSnippet` 的結果;再把關聯指向一個不存在的 id,斷言該筆被丟棄且不拋錯 |
| T4 | `conflict/test/StoryFlow/Conflict/MergeSpec.hs`(新檔,純函式) | ① 同 id 的 graph + retrieval 合成一筆,`xhVia` 是 `ByGraph`、`xhSnippet` 取 retrieval 那一筆;② 排序:graph 全部排在 retrieval 之前,同層依分數遞減,同分依 id 字典序;③ 打亂輸入順序後輸出逐筆相同(全序) |
| T5 | `conflict/test/StoryFlow/Conflict/PipelineSpec.hs``describe "gatherContext"` | 臨時 Vault 上跑完整出口:兩層的命中都出現在結果裡;`drRefs = []` 時只剩第 2 層且不報錯;`drText = ""` 且 `drRefs = []` 時回 `[]`;第 2 層候選數 > `coTopN` 時**第 1 層命中不被截掉**;跑完後每個片段的 `metaRevision` 不變(不改任何資料) |
| T6 | `conflict/test/StoryFlow/Conflict/CabalSpec.hs`(擴充) | `exposed-modules` 含 `StoryFlow.Conflict.Pipeline`;`libraryDeps` 逐字清單**維持七項不變**;`forbidden` 四項仍然不出現 |
| T7 | `api/test/StoryFlow/Api/HttpDataSpec.hs`(擴充,`ContextReq` round-trip)+ `api/test/StoryFlow/Api/CabalSpec.hs`(擴充) | `ContextReq` 的 `toJSON` / `parseJSON` round-trip 不失真;`opts` 鍵缺席時解出 `defaultConflictOpts`;`.cabal` 含 `storyflow-conflict` 且禁用清單七項仍然不出現 |
| T8 | `api/test/StoryFlow/Api/SchemaSpec.hs`(擴充) | `Draft` / `ConflictOpts` / `GraphEvidence` / `ContextHit` / `ContextReq` 走既有 `aligns`;`HitLayer` 走新增的 `alignsSubset`:三個建構子的樣本 JSON 鍵集合都是 schema properties 的子集,且都含 `layer` |
| T9 | `api/test/StoryFlow/Api/ApiSpec.hs` 與 `OpenApiSpec.hs`(擴充) | operation 數 24、paths 數 15;`expectedRoutes` 與實際路由逐條相符且含 `("/conflict/context","post")`;該路由在 `readOnlyRoutes` 裡(沒有 `revision`);它的 `summary` 非空;`components.schemas` 含 `ContextReq` / `ContextHit` / `HitLayer` / `Draft` / `ConflictOpts` / `GraphEvidence` |
| T10 | `server/test/StoryFlow/Server/HandlerSpec.hs`(擴充)+ `CabalSpec.hs`(擴充) | 對真伺服器 `POST /conflict/context` 送 `{"draft":{"text":…,"refs":[…]}}`(不帶 `opts`),回 200 且 body 解得成 `[ContextHit]`;`storyflow-server.cabal` 含 `storyflow-conflict`、仍不含落地層 |
| T11 | `cli/test/StoryFlow/Cli/OptionsSpec.hs`(擴充) | `context --for draft.md` 解成 `Context (BodyFile "draft.md") [] defaultConflictOpts`;`--for -` 解成 `BodyStdin`;`--ref` 可重複且順序保留;`--top-n` / `--timeline-window` / `--graph-depth` 各自落進 `ConflictOpts` 對應欄;**缺 `--for` 是用法錯誤**(exit 2) |
| T12 | `cli/test/StoryFlow/Cli/ContextCmdSpec.hs`(新檔)`describe "兩條後端路徑"` | 內嵌模式 `context --for <檔>` exit 0 且 `--json` 的 `data` 解得成陣列;`--remote` 模式同一條指令同樣 exit 0 且解得開(對應 `RemoteCmdSpec` 的作法) |
| T13 | `cli/test/StoryFlow/Cli/ContextCmdSpec.hs``describe "輸出"` + `Cli.CabalSpec`(擴充) | 人類模式印出 `id / type / status / title / via / snippet` 表頭且 `via` 欄含 `graph(` 與 `retrieval(`;沒有命中時印 `(沒有相關的片段)`;`--json` 是合法信封 `{"ok":true,"data":[…]}` 且 `data` 每筆含 `meta` / `snippet` / `via`;`--for -` 從 stdin 讀得到(走 `captureIn`);`storyflow-cli.cabal` 的 library 含 `storyflow-conflict`、仍不含 `warp` / `storyflow-server` / 落地層 |
| T14 | `cli/test/StoryFlow/Cli/ContextCmdSpec.hs``describe "內嵌與遠端回同一批結果"` | `withCliServer` 綁同一個臨時 Vault,同一份草稿檔各跑一次:人類模式 stdout 逐字元相等,`--json` 信封逐字元相等,exit code 相等 |

## 待確認假設

- A1: 契約卡的 CLI 形式只寫了 `story-flow context --for <檔案|->`,沒有任何帶 `drRefs` 的旗標,
  但 `graphHits` 完全靠 `drRefs` 起步——照字面實作的話,CLI 這條路的第 1 層**永遠不會有輸出**,
  驗收標準「第 1 層 + 第 2 層 → 出口 A」在 CLI 上等於只有第 2 層
  → 採取:加 `--ref <id>`(可重複)對應 `drRefs`,並一併加 `--top-n` / `--timeline-window` /
  `--graph-depth` 三個對應 `ConflictOpts` 的旗標(`coExpandBody` 是第 3 層的,不開)。
  Level 2 只釘住了 `--for`,新增旗標不改任何型別與路由,落在實作自主權內
  → 影響:若編排者認為 `context` 應該保持極簡、`drRefs` 只走 REST,砍掉 `--ref` 與另外三個
  旗標即可(`Options.hs` 一處、`ContextCmdSpec` 一條測試),`Conflict.Pipeline` 與 REST 不動
- A2: F002 交付的 `unlinkedRefs`(「這幾個片段完全沒有標註,第 1 層幫不上忙」)在
  `[ContextHit]` 這個回傳型別裡**沒有位置**,而它正是第 1 層對使用者最有用的提示之一
  → 採取:本 feature **不接** `unlinkedRefs`。理由是 CLI/REST 一致性:遠端模式的 CLI 拿不到
  `ServiceM`,只能從 REST 的回應取資料,而回應是 `[ContextHit]`;內嵌模式多印一行警告會讓
  兩種形式的輸出不一致,直接違反驗收標準 4
  → 影響:提示要在 `F006 conflict-check` 補(`ConflictReport` 有 `crScanned` / `crLlmUsed`
  那一類欄位可以擴充),或由編排者裁定在 Level 2 給 `gatherContext` 換一個帶警告的回傳型別
  ——後者是契約變更,本 feature 不擅自做
- A3: 第 1 層命中的 snippet 沒有任何契約規定;`xhSnippet` 不是 `Maybe`,而第 1 層命中的是
  一條關聯、不是一段文字
  → 採取:用 `metaSnippet`(summary,空則 title),與 F003 對一跳擴充候選的既有規則同一份
  → 影響:若認為第 1 層應該把 `renderGraphReason` 那句繁中放進 `xhSnippet`,改
  `graphContextHits` 一行即可;但那會讓 `xhSnippet` 在不同層級指涉不同的東西(內容 vs 理由),
  而理由已經以結構化形式在 `xhVia` 裡了
- A4: 兩層都命中同一個片段時的合併規則,契約沒寫
  → 採取:`xhVia` 取層級較前者(graph),`xhSnippet` 取來自 `ByRetrieval` 的那一筆
  → 影響:若認為應該保留兩筆(讓使用者看到「這個片段既有已標註的矛盾、又被關鍵詞撈到」),
  改 `mergeContextHits` 的去重鍵為 `(metaId, layerTag)` 即可,排序與其餘不動
- A5: `coTopN` 是否也該截斷合流後的總清單,契約沒寫
  → 採取:**不截**。`coTopN` 是第 2 層的候選上限(F001 的欄位註解明說),第 1 層是零成本的
  事實,拿它去砍會砍掉最有價值的那一批
  → 影響:若要改成「總清單上限」,在 `gatherContext` 末端加一個 `take` 即可,但 T5 那條
  「第 1 層命中不被截掉」的測試要跟著改
- A6: `POST /conflict/context` 讓 `storyflow-api` 與 `storyflow-server` 各長出一個
  `storyflow-conflict` 相依,而這兩個套件的 Level 2 描述都寫著「只有型別 / 薄包裝」
  → 採取:照做。`system.md` 的依賴方向圖裡 `storyflow-conflict` 就在 `storyflow-api` 的上游,
  兩個 `CabalSpec` 的禁用清單也都沒有它;`storyflow-api` 依賴 `storyflow-service`(業務型別)
  已是既成事實,再多一個提供 DTO 的上游套件是同一種性質
  → 影響:若編排者認為 `ContextHit` 這類 DTO 不該讓 api 依賴整個 `storyflow-conflict`,
  替代方案是把三個 DTO 搬進 `storyflow-service`——那是跨兩個子系統的契約變更,本 feature 不做
- A7: `service-and-interfaces` 的 Level 2 與 `system.md` 都寫著「14 條路徑 / 23 個 operation」與
  「21 個子指令」,本 feature 會讓它們變成 15 / 24 / 22
  → 採取:程式碼與測試照新數字更新(T9、T11),**架構文檔一個字都不改**(委派模式不得寫
  `design.md` / `system.md`)
  → 影響:編排者需要在階段閘門回寫兩份架構文檔的這三個數字,否則 `/arch-audit` 會抓到不一致
  → **實作時的修正**:路徑與 operation 的預測是對的(14 → 15、23 → 24,兩處測試斷言都已更新)。
  但「21 個子指令」這個數字**在本 feature 動工前就已經與程式碼對不上**:實際的葉子子指令數是
  **23**(vault 3 + index 2 + type 1 + entity 7 + search 1 + link 3 + level 4 + node 2),加上
  `context` 之後是 **24**。這不是本 feature 造成的漂移,而是既有的;沒有任何測試釘住這個數字,
  所以它一路漂到現在。編排者回寫時要用 23 → 24,不是 21 → 22
- A8: T8 要求「`StoryFlow.Api.Instances` 補**六個** `ToSchema`」,但 `ContextReq` 定義在
  `StoryFlow.Api`,而 `StoryFlow.Api` 是 `StoryFlow.Api.Instances` 的**下游**(前者 import 後者)
  ——實例寫進 `Instances` 會造成模組環
  → 採取:五個孤兒實例(`Draft` / `ConflictOpts` / `GraphEvidence` / `HitLayer` / `ContextHit`)
  照 T8 放進 `Api.Instances`;`ContextReq` 的 `ToSchema` 與它的 `ToJSON` / `FromJSON` 一起放在
  `StoryFlow.Api`,與既有的 `NewVaultReq` / `BodyReq` 完全同一種放法
  → 影響:無外部可見差異。要真的把它搬進 `Instances`,得先把 `ContextReq` 本身搬過去,
  那會讓 `Api.hs` 不再是「請求 body 小包裝的唯一定義處」
- A9: T9 要求 `components.schemas` 含 `GraphEvidence`,但 `HitLayer` 的 wire 形狀是**攤平**的
  (`layer` + 三欄),沒有任何 `$ref` 指向 `GraphEvidence` ——照直覺實作的話它根本不會進 components,
  `OpenApiSpec` 那條就會紅
  → **採取(2026-08-20 階段閘門裁定:不接受孤兒 schema,拿掉)**:`components.schemas`
  **不含** `GraphEvidence`。`ToSchema HitLayer` 裡那行只為登記而存在的
  `declareSchemaRef (Proxy :: Proxy GraphEvidence)` 已移除,`OpenApiSpec` 的 `expectedSchemas`
  也同步移除該項——components 只留路由真的觸得到的 schema
  → **`ToSchema GraphEvidence` 實例本身保留不刪**:它仍受 `SchemaSpec` 的 `aligns` 對帳
  (證明與 `ToJSON GraphEvidence` 逐欄相符),且 `conflict-check`(F006)若出現真的巢狀
  `$ref` 它就會自動進 components
  → 影響:讀 OpenAPI 的 Agent 在 `HitLayer` 的聯集物件裡只看得到攤平的 `from` / `kind` / `to`,
  看不出這三欄是一組;這個資訊由 `HitLayer` 的 schema description 承擔
- A10: T2 的後半「一跳擴充候選的 `caSnippet` 與 `metaSnippet` 逐字相同」原本要寫在
  `RetrievalSpec`(純函式那一檔),但 `expandOneHop` 是 `Conflict.Retrieval` 的**私有**函式,
  在那一檔裡只能自己組一個假候選——那證明的是假候選長什麼樣,不是「規則只有一份」
  → 採取:`metaSnippet` 本身的三條分支留在 `RetrievalSpec`;「兩處同一個答案」那一條移到
  `RetrievalEnvSpec`(T8 一跳擴充那一節),拿真的跑出來的擴充候選比對
  → 影響:無。兩條測試都在 `storyflow-conflict` 的 suite 裡,只是分屬純函式檔與整合檔
- A11: `Api.ApiSpec` 的 `expectedRoutes` 註解明說它是「service-and-interfaces/F001 那份業務操作
  清單的**獨立副本**」,而 `POST /conflict/context` 對應的不是 service 的業務操作,是
  `conflict-detection` 的對外契約 `gatherContext`
  → 採取:新增一張獨立的 `conflictRoutes` 表接在後面,不把它混進那 23 條。operation 數的斷言
  改寫成「service 的 23 個 + conflict 的 1 個」
  → 影響:階段二加 `POST /conflict/check` 時往 `conflictRoutes` 加一列即可,兩份來源清單各自
  對得上帳

## 實作備註

1. **`linkGraph` 的不變量測試釘住的是「上游」而不是自己**。
   `service/test/StoryFlow/Service/LinkGraphSpec.hs` 有五條,其中三條是不變量本身:以帶著本
   Vault 前綴的 `Ref` 寫進去(`addLink` 一條、`createEntity` 的 `nerLinks` 一條),讀回來時
   `refVault` 都是 `Nothing`;跨 Vault 的前綴則照樣保留。第三條是刻意的**對照組**——`localize`
   只壓掉「等於本 Vault 名稱」的那一種,若哪天它變成無差別壓平,第 1 層就會把
   `shared-lore:ent-xxxx` 當本地 id 反查而製造假命中,這條測試會先紅。
   `Conflict.Pipeline` 因此一行正規化都沒寫。

2. **`graphContextHits` 的丟棄行為有兩條測試,不只一條**。
   除了「關聯指向不存在的片段 → 該筆丟棄且不拋錯」,另有一條「存在的與不存在的混在一起 →
   只丟掉查不到的那一筆」。只驗前者的話,一個「任何一筆查不到就整批回 `[]`」的實作也會通過。
   懸空關聯是用 `createEntity` 的 `nerLinks` 建出來的:目標存在性只在 `addLink` 驗
   (`requireTargetExists`),建檔那條路徑不驗——這也正是真實世界裡懸空關聯出現的方式。

3. **`mergeContextHits` 的合併是三選一,不是二選一**。
   `xhVia` 取層級較前者、`xhSnippet` 取來自 `ByRetrieval` 的那一筆——這兩條規則的**贏家可能
   不是同一筆**(graph + retrieval 時,via 來自 graph 而 snippet 來自 retrieval)。實作因此不是
   「挑一筆留下」,而是逐欄組一筆新的。`MergeSpec` 對兩種輸入順序各驗一次,確保結果與
   `M.insertWith` 的參數順序無關。

4. **`ConflictOpts` 的四欄裡只有三欄開旗標**。
   `coExpandBody` 是第 3 層(LLM)控制 token 成本的手段,而 `context` 根本不跑第 3 層;給它一個
   沒有作用的旗標比不給更糟。CLI 那一欄走 `pure (coExpandBody defaultConflictOpts)`。

5. **`renderVia` 的分數固定兩位小數**(`showFFloat (Just 2)`)。
   `table` 的欄寬由最寬的儲存格決定,浮點的完整尾數會讓 `via` 欄的寬度隨資料跳動;而 T14 的
   逐字元比對要的是穩定的輸出。要看完整分數的人走 `--json`——那裡是原始的 `Double`。

6. **T14 的四條裡有一條是空清單**。
   「兩種形式回同一批結果」最容易破的地方不是有結果的時候,而是沒有結果的時候:內嵌可能印
   `(沒有相關的片段)` 而遠端印空表格。所以空草稿那一條與有命中的那三條同等重要。

7. **`cabal test all` 全綠**:9 個 suite、**1103 examples、0 failures**
   (types 29 / core 166 / md 189 / api 62 / conflict 139 / service 94 / store 166 / server 63 /
   cli 195)。相對於本 feature 動工前的 1030 examples,新增 73 條。
   `storyflow-conflict` 的 `build-depends` **逐字未變**(七項),`CabalSpec` 的雙向斷言仍然成立。
