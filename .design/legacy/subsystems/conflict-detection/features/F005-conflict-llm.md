---
id: F005
type: feature
title: conflict-llm
description: 衝突偵測第 3 層:草稿與候選逐對送 LLM 判斷矛盾
status: done
created: 2026-08-20
updated: 2026-08-21
depends-on: [F001, F003, llm-workshop-mcp/F001, entity-graph-core/F002, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003]
related-adr: [ADR-007]
related-feature: []
---

# F005: 衝突偵測第 3 層(語意判斷)

## 功能概述

`conflict-detection` 階段二的第一項,也是 ADR-007 三層裡**成本最高、輸出最少**的一層。
給一段草稿與第 2 層撈出來的候選,逐對問模型「這兩段之間有沒有矛盾」,把**判斷**
(`HitLayer` 為 `ByJudge`)交出去。

第 1 層交的是**事實**(作者標註過的關聯)、第 2 層交的是**相關**(FTS5 撈到的候選),
本層交的是**判斷**——三者的可信度完全不同,而 `HitLayer` 分三個建構子的意義就在這裡。
本層因此有兩條與前兩層不同的紀律:

- **不可靠是常態而非例外**。地端 12B 模型會回 markdown code fence 包起來的 JSON、會逾時、
  會在第 N 對突然連不上。整條管線**不能因為第 3 層而失敗**——外部 Agent 靠前兩層吃飯
- **拿不到判斷時不得捏一個**。解析不出來就是該對判斷失敗,記進 `crNotes`,
  **不得捏一個信心值混進 `ByJudge`**(D5;與 F003「`shScore` 為 `Nothing` 時不得捏假分數」
  同一條紀律)

本 feature 除了 `Conflict.Judge` 本身,還**負責讓兩項剛升格為契約的型別存在**
(`design.md`「模組間公開介面與資料結構」2026-08-20 階段二裁定,見「七、本 feature 要動
F001 的模組」):`ConflictOpts.coJudgeN`、`ConflictReport.crNotes` 與新型別 `ReportNote`。
**填滿 `crNotes` 三種來源是 F006 的事**,F005 只讓型別存在,並產出第 3 層自己那幾則。

明確**不做**:不實作 LLM 端點(`llm-workshop-mcp/F001`,已 `done`);**永不自動修改資料**;
不決定命中是否成立(那是作者的判斷);不自己讀 `[llm]` 設定、不呼叫 `newLlmClient`
(F006 的接線層);不做三層合流與排序(F006);不接 CLI 與 REST(F006);
不替 `ReportNote` / `ConflictReport` 加 `ToSchema`(那要等 `POST /conflict/check` 存在,F006)。

驗收標準(逐條對應契約卡):

1. **預設只送 `summary`**,`coExpandBody` 為真時才展開 `body`;展開走 `ServiceM` 的 `getEntity`
2. 模型信心以 **0–1 的浮點**進 `ByJudge`,不在型別層壓成三級
3. `LlmClient` 不可用時整條管線**退化成前兩層**而不是整個失敗;**三種退化原因分得出來**
   (`--no-llm` / `[llm]` 沒設定 / 端點連不上),差別以 `ReportNote.rnCode` 承載
4. 每筆命中都帶**模型給的理由**;模型沒給理由就不算命中(不代筆)
5. 送模型的是**前 `coJudgeN` 個**候選,`coJudgeN` 是獨立於 `coTopN` 的旋鈕且預設保守
6. 解析前**必須剝除 markdown code fence**;剝除後仍解析不出來的,該對算**判斷失敗**並記進
   `crNotes`,**不產生任何 `ByJudge` 命中**
7. **逐對失敗保留已成功的那幾對**;`crLlmUsed` 的語意是「有沒有真的產出至少一筆判斷」,
   不是「有沒有嘗試」
8. 自動化測試**hermetic**:`cabal test all` 不依賴任何外部端點、不發任何網路請求

## 相依性

`depends-on: [F001, F003, llm-workshop-mcp/F001, entity-graph-core/F002,
service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003]`。

契約卡寫的相依是 `#3, llm-workshop-mcp #1`;查證介面表之後擴充成七項,理由逐條如下:

- **F001(conflict-types)**:`Draft` / `ConflictOpts` / `HitLayer` / `ConflictHit` /
  `ConflictReport` 由它定義,而**本 feature 要動它的兩個模組**(`Conflict.Types` /
  `Conflict.Json`,見第七節)。已 `done`
- **F003(conflict-retrieval)**:本層的輸入是它的 `Candidate`;送出去的那一段沿用它的
  `metaSnippet`(summary → title),不另立第四份規則。已 `done`
- **llm-workshop-mcp/F001(llm-endpoint)**:`LlmClient` / `chat` / `Message` / `Role` /
  `LlmError` / `renderLlmError` 全部來自它;`storyflow-llm` 套件已存在。已 `done`
- **entity-graph-core/F002(core-types-and-registry)**:`Meta` / `Entity` / `Id` /
  `renderId` 來自 core。已 `done`
- **service-and-interfaces/F001(service-contract)**:`ServiceM`(`MonadIO`)與 `getEntity` /
  `EntityView`——`coExpandBody` 展開 `body` 的唯一合法路徑。已 `done`
- **service-and-interfaces/F002(cli-embedded)**:`ConflictOpts` 多一欄會打斷
  `Cli.Options.conflictOptsP` 的位置式建構,必須跟著改(T3)。已 `done`
- **service-and-interfaces/F003(servant-api-server)**:`instance ToSchema ConflictOpts` 與
  `SchemaSpec`「`ToJSON` 與 `ToSchema` 逐欄對齊」的斷言會因 `judge_n` 而改(T3)。已 `done`

**可否平行開發**:上列七項全部 `done` 並已併入 `main`,沒有紙上約定的相依,現在就能開工。
與 F006 是一條鏈(F006 消費本 feature 的 `judgeCandidates` 與 note 詞彙),**必須序列**。

## 對應的 Level 2 契約

### 落在契約內的部分

| 契約來源 | 條目 | 本 feature 的實作 |
|---|---|---|
| `design.md`「內部模組劃分」 | `Conflict.Judge`(第 3 層):草稿 × 候選逐對送 LLM 問「是否矛盾、矛盾在哪」 | 新增 `StoryFlow.Conflict.Judge` 模組 |
| 同上「資料流管線」 | 第 3 層:`草稿 × 候選逐對送 LlmClient,優先送 summary,必要才展開 body` | 第二、三、五節逐段落實 |
| 同上「模組間公開介面」 | `Conflict.Judge → llm-workshop-mcp`:消費 `LlmClient` 的 `chat`,不實作端點 | `llmRunner` 是本模組唯一碰 `chat` 的地方 |
| 同上「模組間公開介面」 | 三層都只吐 `ConflictHit` / `ContextHit`,證據放進 `HitLayer` | `verdictHit` 產出的 `chLayer` 恆為 `ByJudge` |
| 同上「對外契約 — 第 3 層的候選預算」 | `ConflictOpts` 有一欄獨立於 `coTopN` 的 `coJudgeN`(預設保守) | T1(型別)+ T7(套用點) |
| 同上「對外契約 — 第 3 層的退化與部分失敗」 | 三種退化原因走 `crNotes`;逐對失敗保留已成功的;`crLlmUsed` 是「有沒有真的產出判斷」 | 第五、六節;`JudgeResult.jrJudged` |
| 同上「模組間公開介面與資料結構」 | `ConflictReport` 新增 `crNotes :: [ReportNote]`;新型別 `ReportNote { rnCode, rnDetail }` | T1 / T2 |

**不新增任何對外契約**:`checkConflict` 由 F006 接線,本 feature 交付的 `judgeCandidates` 是
`Conflict.Pipeline` 的內部輸入,不出現在 CLI 與 REST。

### 本 feature 要動 F001 的模組(Level 2 已授權)

`coJudgeN` / `crNotes` / `ReportNote` 三項都寫在 `design.md` 的「模組間公開介面與資料結構」,
但那一章的**負責模組是 `Conflict.Types` / `Conflict.Json`**,而那兩個模組屬於 F001。
本 feature 因此要動 F001 的模組——這不是偏離契約,而是契約升格後由**最早需要它的 feature**
落地(F003 動 `service-and-interfaces` 的 `SearchHit` 是同一個先例)。動了哪幾個地方見第七節,
並已列進回報。

## 實作方式

### 一、整體資料流

```text
[Candidate](第 2 層已排序;F006 合流後交進來)      ConflictOpts { coJudgeN, coExpandBody }
        │                                                    │
        ▼                                                    │
  resolveTargets:先套預算 take coJudgeN ◄────────────────────┘   ← 預算在讀資料之前
        │  (不在預算內的候選一次 getEntity 都不會發生)
        ├─ coExpandBody = False → jtText = metaSnippet caMeta(summary → title)
        └─ coExpandBody = True  → jtText = entBody(經 getEntity;空白或讀不到退回 summary)
        │
        ▼  [JudgeTarget { jtId, jtTitle, jtText, jtExpanded }]
  judgeLoop(Monad m,不讀資料、不碰 ServiceM)
        │
        │  每一對:judgeMessages → runner → Either LlmError Text
        │
        ├─ Left (LlmUnavailable _) → 記 judge_aborted,__中止剩餘的對__
        ├─ Left 其他               → 記 judge_call_failed,__繼續下一對__
        └─ Right raw
              → stripCodeFence → parseVerdict
              ├─ Left  → 記 judge_parse_failed(不產生命中、不計入 jrJudged)
              └─ Right v → jrJudged + 1
                    ├─ vdContradicts = False → 沒有命中(這是一筆有效判斷)
                    └─ vdContradicts = True  → verdictHit:ConflictHit(ByJudge vdConfidence)
        ▼
  JudgeResult { jrHits, jrJudged, jrNotes }
        │
        └─ F006:crHits ← 合流(jrHits 併入)、crLlmUsed ← jrJudged > 0、crNotes ← jrNotes ++ 其餘兩種來源
```

**兩層切分是刻意的**:`resolveTargets` 是唯一需要 `ServiceM` 的一步(它要讀 `body`),
`judgeLoop` 則對任意 `Monad m` 成立。這讓四條必測路徑(退化、部分失敗、fence 剝除、
JSON 解析失敗)**全部可以在不開 Vault、不發請求的情況下測到**(第九節),
而「第 3 層自己不讀資料」也從註解升格成型別擋得住的性質。

### 二、送出去的那一段,與候選預算

**預算先於讀取**。`take (max 0 (coJudgeN opts))` 發生在 `resolveTargets` 的**第一步**:
不在預算內的候選連 `getEntity` 都不會被呼叫。順序反過來的話,`--expand-body` 會為了
20 個候選讀 20 份正文,再丟掉 15 份。

`coJudgeN` 的預設值訂 **5**。依據是編排者實測的「地端 12B 模型一對約 7 秒」:5 對約 35 秒,
是一個指令等得起的長度;而 `coTopN` 的預設 20 全判約 140 秒,那是把 `check` 變成不能用的旗標。
`coTopN` 管**撈多廣**、`coJudgeN` 管**燒多少**,兩者混成一個旋鈕會讓「想要廣召回的 `context`」
與「想要快的 `check`」互相綁架(`design.md` 原話)。

`coJudgeN <= 0` 是**合法輸入**,行為與 `coTopN = 0` 一致:不送任何一對、不發任何請求。
但候選非空時要**說出來**——記一則 `judge_disabled`(見第六節),否則使用者會以為
「模型看過了,沒有矛盾」。

**送哪一段**:

| `coExpandBody` | `jtText` | 理由 |
|---|---|---|
| `False`(預設) | `metaSnippet (caMeta c)`(`metaSummary` 去空白後非空就用它,否則 `metaTitle`) | 契約卡的「優先送 `summary`」;沿用 F003 已經存在的那一份規則,不寫第四遍 |
| `True` | `entBody`(經 `getEntity`);去空白後為空、或 `getEntity` 失敗時退回上一列 | 展開是為了讓模型看見細節,拿到空正文就沒有展開的意義,退回 summary 比送一段空白好 |

**刻意不送 `caSnippet`**(FTS5 命中的那一段):它是為了給人看「為什麼撈到你」而截的,
上下文常常斷在句中。契約卡寫的是 summary,不是 snippet。

`jtExpanded` 記下這一對實際送的是哪一種——理由文案不需要它,但測試需要它,
而且 F006 若要在報告裡說「這一對是展開正文判斷的」也拿得到。

**草稿全文照送、不截斷**:實測端點 `n_ctx` 是 32768,而草稿是使用者自己給的一段文字。
真的塞不下時端點會回 4xx,那條路徑已經被 `judge_call_failed` 覆蓋——自己截一刀反而會
讓模型判斷一段作者沒寫過的草稿。

### 三、prompt 與 `system` role

編排者已對真端點實測:**`system` role 可用**,不必把系統訊息折進 user 訊息。

```haskell
judgeMessages :: Draft -> JudgeTarget -> [Message]
judgeMessages d t = [Message System judgeSystemPrompt, Message User (renderPairPrompt d t)]
```

`judgeSystemPrompt` 固定不變,說三件事:(a) 你是設定一致性檢查員,只判斷有沒有**事實上的**
矛盾;(b) **只輸出一個 JSON 物件**,三個鍵 `contradicts`(布林)/ `confidence`(0–1 小數)/
`reason`(繁體中文一句話);(c) 不要輸出 JSON 以外的任何文字。

第 (c) 條**明知會被違反還是要寫**——實測回的就是 ```` ```json ```` 包起來的內容。寫了能讓
乖一點的模型直接給裸 JSON,不寫則連 fence 都不一定成形。真正的防線是第四節的剝除。

`renderPairPrompt` 的形狀(固定段落標記,便於模型定位):

```text
【新草稿】
<drText>

【既有設定 ent-7f3a(標題)】
<jtText>
```

id 走 `renderId`。`drRefs` **不進 prompt**:那是第 1 層的起點,對「這兩段文字矛不矛盾」
沒有幫助,只會多燒 token。

**本模組不組通用 prompt 框架**:`storyflow-llm` 的硬邊界是「不組 prompt,那是消費者的事」,
而「消費者」就是這裡。但 prompt 也只到這裡為止——它不是對外契約,F006 不該引用它的字面。

### 四、回應解析:fence 剝除 → JSON → `Verdict`

```haskell
data Verdict = Verdict
  { vdContradicts :: Bool
  , vdConfidence  :: Double   -- ^ 已 clamp 到 [0, 1]
  , vdReason      :: Text
  }

stripCodeFence :: Text -> Text
parseVerdict   :: Text -> Either Text Verdict
```

`stripCodeFence` 的規則(去空白後判斷):

1. 內容以 ```` ``` ```` 開頭 → 丟掉**第一行整行**(它可能是 ```` ```json ````、```` ``` ````、
   ```` ```JSON ````),再丟掉尾端的 ```` ``` ```` 那一行
2. 內容裡**存在**一段 ```` ``` ```` 圍起來的區塊(模型先講了一句「以下是判斷結果:」)→
   取**第一個**區塊的內容
3. 都不是 → 原樣回傳(已去空白)

`parseVerdict` 的三步:

1. `stripCodeFence` → `eitherDecodeStrictText`(aeson 2.2.5.0 有這個出口,
   **不必為此讓 `storyflow-conflict` 長出 `bytestring` 相依**)
2. 失敗 → 取「第一個 `{` 到最後一個 `}`」的切片再 decode 一次。這一步吃掉的是
   「fence 沒成形但前後有贅字」那一類回覆,**仍然是擷取而不是編造**
3. 兩次都失敗 → `Left`,訊息帶截斷後的原文(200 字上限;端點回一整頁 HTML 時不該把終端機洗掉)

解析成功後兩條額外規則:

- **`confidence` 落在 `[0, 1]` 之外就 clamp**,不是判斷失敗。模型已經明確回答了矛盾與否,
  為了一個超界的機率丟掉整筆判斷,損失比校正大。clamp 的是**範圍**,不是把沒有的值生出來
  (見 A3)
- **`contradicts = true` 但 `reason` 去空白後為空 → 該對算判斷失敗**(`judge_parse_failed`)。
  驗收標準 4 要的是「模型給的理由」,而唯一不捏理由的作法就是沒有理由時不產生命中(見 A4)。
  `contradicts = false` 時 `reason` 可以是空的——沒有命中就沒有理由要交代

欄位缺一個、型別不對(`confidence` 給字串)一律走 `Left`。**不做同義詞容忍**
(`is_contradiction` / `score` / `explanation`):容忍表會無限長,而 prompt 已經把鍵名寫死了。

**`Verdict` 的 `FromJSON` 不進 `Conflict.Json`**。那個模組的紀律是「CLI 的 `--json`、
REST 的 body、未來 MCP 用的是同一套編碼規則,規則只該有一份」,而 `Verdict` **不是 DTO**
——它是模型回覆的線上形狀,沒有任何消費者會看見它。先例就在 `storyflow-llm`:
`ChatResponse` / `ChatChoice` 的實例私有地留在 `Llm.Client`,理由逐字相同
(「實例藏不住,一旦定義在公開型別上,OpenAI 的線上形狀就變成本套件的公開介面了」)。

### 五、逐對迴圈:成功、失敗、中止

```haskell
type JudgeRunner m = [Message] -> m (Either LlmError Text)

judgeLoop :: (Monad m) => JudgeRunner m -> Draft -> [JudgeTarget] -> m JudgeResult
```

逐對依序處理(**不併發**:地端端點通常是單一 worker,併發只會讓每一對都變慢,
而且會讓輸出順序不確定):

| runner 回什麼 | 產出 | 迴圈 |
|---|---|---|
| `Right raw`,解析成功且 `contradicts = True` | `ConflictHit`(`ByJudge vdConfidence`)、`jrJudged + 1` | 繼續 |
| `Right raw`,解析成功且 `contradicts = False` | 無命中、`jrJudged + 1` | 繼續 |
| `Right raw`,解析失敗 | `judge_parse_failed` note | 繼續 |
| `Left (LlmHttpStatus _ _)` / `Left (LlmBadResponse _)` / `Left (LlmConfig*)` | `judge_call_failed` note | 繼續 |
| `Left (LlmUnavailable _)` | `judge_aborted` note(帶「尚有 N 對未判斷」) | **中止** |

**為什麼 `LlmUnavailable` 中止而其他錯誤繼續**:`chat` 內部已經對 `LlmUnavailable` 重試過
(總嘗試 `1 + lcRetries`),走到這裡代表**服務真的不在**。繼續打剩下的對,每一對都要再等一次
`lcTimeout`(預設 60 秒)乘以重試次數——4 對就是 8 分鐘,換來的必然是 4 則一模一樣的失敗。
非連線類的錯誤則可能是這一對特有的(內容太長回 4xx、這一次回了怪形狀),值得繼續(見 A2)。

**已成功的一律保留**:中止只影響「還沒送的」,`jrHits` 與 `jrJudged` 原封不動。
地端小模型不穩是常態,已經燒掉的 token 不該因為第 N 對逾時就整批作廢(`design.md` 原話)。

`ConflictHit` 的四欄:

| 欄位 | 值 | 說明 |
|---|---|---|
| `chTarget` | `jtId` | 候選片段 |
| `chLayer` | `ByJudge vdConfidence` | 0–1 浮點,**不壓成三級**;要不要顯示成三級是渲染的決定 |
| `chReason` | `vdReason` | **模型給的原話**,不加工、不接前綴 |
| `chSnippet` | `Just jtText` | **就是送給模型看的那一段**。它誠實地反映了 `--expand-body` 的效果,而且使用者要複核模型的判斷時,看到的必須是模型看到的東西 |

`jrHits` 的順序 = 候選順序(輸入即優先序);跨層排序是 F006 的 `sortHits` 的事,本層不排。

### 六、退化的三種原因與 note 詞彙

第 3 層有三種**根本沒跑**的原因,對使用者是三個完全不同的下一步:

```haskell
data JudgeSkip
  = SkipDisabled              -- ^ --no-llm,或 coJudgeN <= 0
  | SkipNotConfigured LlmError -- ^ LlmConfigMissing / LlmConfigInvalid
  | SkipUnreachable   LlmError -- ^ 建 client 或第一次呼叫就連不上

skipNote :: JudgeSkip -> ReportNote
```

`rnCode` 一律以 `judge_` 為前綴——`ReportNote` 是三種來源共用的欄位(F006 還會加第 1 層的
`unlinkedRefs` 與關聯建議),前綴讓程式化消費者一眼分得出這一則講的是哪一層:

| `rnCode` | 何時 | `rnDetail` 要說出的下一步 |
|---|---|---|
| `judge_disabled` | `--no-llm`,或 `coJudgeN <= 0` 而候選非空 | 「這份報告只有前兩層;拿掉 `--no-llm`(或把 `--judge-n` 調大)才會跑語意判斷」 |
| `judge_not_configured` | `[llm]` 段缺漏或不合法 | `renderLlmError` 的原文(它已經說了「請加上 `[llm]` 並至少填 `base_url` 與 `model`」) |
| `judge_unreachable` | 端點連不上 | `renderLlmError` 的原文(「請確認地端服務有沒有在跑…」) |
| `judge_call_failed` | 某一對呼叫失敗(非連線類) | 帶 `renderId` 的候選 id 與 `renderLlmError` |
| `judge_parse_failed` | 剝除 fence 後仍解析不出,或 `contradicts = true` 卻沒給理由 | 帶候選 id 與截斷後的原文;明說「這一對沒有判斷結果,不是判定為沒有矛盾」 |
| `judge_aborted` | `LlmUnavailable` 中止剩餘的對 | 帶已判斷數與剩餘數 |

**誰決定用哪一個**:`JudgeSkip` 的三個建構子由 **F006** 選(它才知道有沒有 `--no-llm`、
才呼叫 `llmConfig` 與 `newLlmClient`);F005 只提供詞彙與文案,理由是 `ReportNote` 是 **DTO**
——CLI 與 REST 必須拿到逐字相同的內容,文案若寫在 CLI 的渲染層,遠端模式就會拿到不一樣的東西
(見 A1)。

`crLlmUsed = jrJudged > 0`(F006 填)。注意 `jrJudged` 數的是**成功取得判斷的對數**,
**包含判定為「不矛盾」的那些**——那也是第 3 層真的跑過的證據。全部失敗與從未啟動對使用者
是同一件事(這份報告只有前兩層),差別由 `crNotes` 承載。

### 七、本 feature 要動 F001 的模組

四處,全部是 `design.md` 已升格的契約,不是新發明:

| 檔案 | 改什麼 | 為什麼是這個位置 |
|---|---|---|
| `conflict/src/StoryFlow/Conflict/Types.hs` | `ConflictOpts` 在 `coTopN` **之後**插入 `coJudgeN :: Int` | 兩個預算旋鈕相鄰,欄位順序本身就在說「一個管撈多廣、一個管燒多少」 |
| 同上 | `defaultConflictOpts` 補 `coJudgeN = 5` | 「預設保守」的既有落點 |
| 同上 | 新增 `data ReportNote = ReportNote { rnCode :: Text, rnDetail :: Text }` 並匯出 | `design.md` 逐字定義;它是 DTO,住在型別模組 |
| 同上 | `ConflictReport` 加 `crNotes :: [ReportNote]`;`emptyReport` 補 `crNotes = []` | 同上 |
| `conflict/src/StoryFlow/Conflict/Json.hs` | `ReportNote` 的 `ToJSON` / `FromJSON`(`code` / `detail`);`ConflictOpts` 加 `judge_n`(缺席退預設);`ConflictReport` 加 `notes`(缺席退 `[]`) | 「aeson 實例集中一處」 |

**位置式建構的連帶更新**(加一欄就會斷,逐一列出免得漏):

| 檔案 | 改什麼 |
|---|---|
| `conflict/src/StoryFlow/Conflict/Json.hs` | `FromJSON ConflictOpts` / `FromJSON ConflictReport` 的 `<*>` 鏈各多一項 |
| `cli/src/StoryFlow/Cli/Options.hs` | `conflictOptsP` 補 `<*> pure (coJudgeN defaultConflictOpts)`。**`context` 不開 `--judge-n`**,理由與 `--expand-body` 完全相同:`context` 根本不跑第 3 層,給它一個沒有作用的旗標只會讓人以為有作用(`--judge-n` 由 F006 加在 `conflict check` 上) |
| `api/src/StoryFlow/Api/Instances.hs` | `ToSchema ConflictOpts` 的 `properties` 加 `judge_n`,`required` 仍是 `[]`(五欄全部選配) |
| `api/test/StoryFlow/Api/Fixtures.hs` | `sampleConflictOpts` 補 `coJudgeN`(record 建構,少一欄是 `-Wmissing-fields` 加執行期爆炸) |
| `conflict/test/.../OptsSpec.hs`、`ReportSpec.hs`、`JsonSpec.hs` | 既有斷言補新欄(見測試對照表 T1 / T2 / T3) |

`server/test/.../HandlerSpec.hs` 與 `cli/test/.../OptionsSpec.hs` 用的是
`defaultConflictOpts` 與 record accessor,**不受位置式建構影響**;查證過,只需要各補一條
新欄的斷言(T3),既有斷言一字不改。

### 八、套件邊界:放行 `storyflow-llm`

`storyflow-conflict.cabal` 的 `build-depends`(library 與 test-suite 兩段)加 `storyflow-llm`,
`exposed-modules` 加 `StoryFlow.Conflict.Judge`。`CabalSpec` 的 `forbidden` 因此從四項
**縮成三項**:`storyflow-store` / `storyflow-md` / `sqlite-simple`。

這是 `design.md`「使用到的套件」明文寫的(「加上 `llm-workshop-mcp` 的 `storyflow-llm`」),
Level 2 已授權。但**必須說清楚為什麼這不等於「所有讀取經 `ServiceM`」那條紀律鬆動**,
兩個層次的理由:

1. **`Conflict.Judge` 不讀資料**。它唯一的讀取是 `coExpandBody` 時的 `getEntity`,
   而那**正是** `ServiceM` 的出口。`storyflow-llm` 給它的是 `chat`——一個把 `[Message]` 送出去、
   把 `Text` 帶回來的函式,和 Vault 的索引沒有任何關係
2. **`storyflow-llm` 自己也被同一條紀律釘住**。它的 `.cabal` 逐字擋著
   `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite`,設定唯一的來源是
   `StoryFlow.Service.vaultConfig`,而 `StoryFlow.Llm.CabalSpec` 用測試守著這件事。
   換句話說**放行它並不會開出一條繞過 `ServiceM` 的路徑**,因為那條路徑在它那一側也不存在

被移出 `forbidden` 的名字**不是不管了**,而是換成雙向斷言:`build-depends` **必須含**
`storyflow-llm`(F003 放行 `storyflow-service` 時就是這個作法)。逐字釘住的
`libraryDeps` / `testDeps` 清單同時擋掉「趁這一次順道多一個包」——本 feature
**不新增任何其他相依**:`aeson` 的 `eitherDecodeStrictText` 讓 `bytestring` 不必進來,
`liftIO` 在 `base`,`mtl` 早就在了。

依賴方向:`storyflow-llm → storyflow-service`,`storyflow-conflict → {service, llm}`,
而 `storyflow-llm` 不依賴 `storyflow-conflict`——**無環**。

### 九、注入 runner 的測試形狀

契約卡的 D6:公開面照卡吃 `LlmClient`,內部把呼叫抽象成**可注入的函式**,
`cabal test all` 不得依賴任何外部端點。

```haskell
-- 公開面:照契約卡,吃不透明的 LlmClient
judgeCandidates     :: LlmClient        -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult
-- 接縫:換掉 runner(F006 的替身、以及整合測試)
judgeCandidatesWith :: JudgeRunner ServiceM -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult
-- 判斷迴圈:不讀資料,對任意 Monad 成立 —— 四條必測路徑全在這裡
judgeLoop :: (Monad m) => JudgeRunner m -> Draft -> [JudgeTarget] -> m JudgeResult

llmRunner :: LlmClient -> JudgeRunner ServiceM
llmRunner c = liftIO . chat c
```

`LlmClient` 是**不透明型別**,只能由 `newLlmClient` 造,而造出來的 client 一定指向某個
`base_url`——這就是「不能直接測公開面」的原因,也正是接縫存在的理由。
`judgeLoop` 的 `Monad m` 是**型別層的保證**:它拿不到 `MonadIO`,所以除了 runner 給它的東西
以外,它什麼都碰不到。

測試用的假 runner 跑在 `IO` 上、用 `IORef` 記錄呼叫(`Data.IORef` 在 `base`,
**測試套件不必新增 `mtl` 相依**):

```haskell
-- 依序回傳預先排好的回覆,並把每一次的 [Message] 記下來
stubRunner :: IORef [[Message]] -> IORef [Either LlmError Text] -> JudgeRunner IO
```

四條必測路徑分別怎麼觸發:

| 路徑 | 觸發方式 | 斷言 |
|---|---|---|
| **退化** | (a) `skipNote` 的三個建構子直接呼叫;(b) `coJudgeN = 0` 而候選非空 → `judgeCandidatesWith` 一次都不呼叫 runner | 三個 `rnCode` 兩兩不同且都以 `judge_` 開頭、`rnDetail` 都非空且說得出下一步;(b) 的呼叫記錄是 `[]`、`jrJudged = 0`、note 是 `judge_disabled` |
| **部分失敗** | 回覆序列 `[Right 合法JSON, Left (LlmHttpStatus 500 ...), Right 合法JSON]` | `jrJudged = 2`、`jrHits` 保留兩筆、`judge_call_failed` 一則且帶得出是哪一個 id;**中止路徑**另用 `[Right 合法, Left (LlmUnavailable ...), Right 合法]` → runner 只被呼叫 **2** 次、第三對沒送、`judge_aborted` 帶「尚有 1 對未判斷」、第一對的命中仍在 |
| **fence 剝除** | 回覆是 ```` ```json\n{...}\n``` ````(**實測地端 `gemma-4-12b-it` 的真實形狀**)、```` ``` ```` 無語言標記、以及「以下是結果:\n```json\n{...}\n```」三種 | 三種都解析成功並產出命中;`stripCodeFence` 對沒有 fence 的裸 JSON 回原文(去空白) |
| **JSON 解析失敗** | 回覆是純散文、缺 `confidence` 鍵、`confidence` 給字串、`contradicts = true` 但 `reason` 空白 | 四種都**不產生任何命中**、`jrJudged` 不增加、各記一則 `judge_parse_failed`;**`jrHits` 裡不存在任何信心值是編造的命中** |

真端點的驗收由編排者在閘門另外跑(D6),不進 `cabal test all`。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)` | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | 第 3 層唯一的模型呼叫;`llmRunner` 是本模組唯一碰它的地方 |
| `data LlmClient`(不透明,無匯出建構子) | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | 公開面的參數;**不透明正是接縫存在的理由**(測試造不出指向假端點的 client) |
| `newLlmClient :: LlmConfig -> IO LlmClient` | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | **本 feature 不呼叫**;列出以標明邊界(F006 的接線層) |
| `llmConfig :: ServiceM (Either LlmError LlmConfig)` | `llm/src/StoryFlow/Llm/Config.hs` | llm-workshop-mcp/F001 | 同上,**本 feature 不呼叫** |
| `data Message = Message { msgRole :: Role, msgContent :: Text }` | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | `judgeMessages` 的產出 |
| `data Role = System \| User \| Assistant` | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | **`System` 已實測可用**,不必折進 user |
| `data LlmError = LlmUnavailable Text \| LlmHttpStatus Int Text \| LlmBadResponse Text \| LlmConfigMissing \| LlmConfigInvalid Text` | `llm/src/StoryFlow/Llm/Error.hs` | llm-workshop-mcp/F001 | 中止規則只認 `LlmUnavailable`;三種退化原因對應 `LlmConfig*` 與 `LlmUnavailable` |
| `renderLlmError :: LlmError -> Text`(繁中,每一則都說出下一步) | `llm/src/StoryFlow/Llm/Error.hs` | llm-workshop-mcp/F001 | `rnDetail` 的內容來源,**不重寫下層訊息** |
| `llmErrorCode :: LlmError -> Text`(snake_case 穩定識別碼) | `llm/src/StoryFlow/Llm/Error.hs` | llm-workshop-mcp/F001 | 備用:`rnDetail` 需要機器可讀的原因時可接上;本 feature 的 `rnCode` 自成一組(見 A1) |
| `data Candidate = Candidate { caMeta :: Meta, caSnippet :: Text, caScore :: Double, caOrigin :: CandidateOrigin }` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | 本層的輸入;只讀 `caMeta` |
| `metaSnippet :: Meta -> Text`(`metaSummary` 去空白後非空就用它,否則 `metaTitle`) | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | 「優先送 summary」的既有規則,**第三個呼叫端**(前兩個是一跳擴充與第 1 層命中) |
| `retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | **本 feature 不呼叫**;候選由 F006 合流後交進來 |
| `getEntity :: Id -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | `coExpandBody` 展開 `body` 的唯一路徑;找不到時丟 `StoreFailed (EntityNotFound i)` |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | 由 `evEntity` 取 `entBody` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | entity-graph-core/F002 | `entBody` 就是「展開的 body」 |
| `newtype ServiceM a`(`deriving newtype (Monad, MonadIO, MonadReader Env, MonadError ServiceError)`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `MonadIO` 讓 `llmRunner` 把 `chat` 抬進來;`MonadError` 讓 `getEntity` 失敗吞得掉 |
| `catchError :: MonadError e m => m a -> (e -> m a) -> m a` | `mtl`(`Control.Monad.Except`) | — | 展開 `body` 失敗時退回 summary,與 F003 的 `timelineAnchors` 同一種吞法 |
| `data Meta = Meta { metaId :: Id, …, metaTitle :: Text, metaSummary :: Text, … }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | `jtId` / `jtTitle` / 預設送出去的那一段 |
| `renderId :: Id -> Text` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | prompt 與 note 文案裡的 id |
| `data Draft = Draft { drText :: Text, drRefs :: [Id] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 只讀 `drText`;`drRefs` 是第 1 層的事,不進 prompt |
| `data ConflictOpts = ConflictOpts { coTopN :: Int, coExpandBody :: Bool, coTimelineWindow :: Maybe Int, coGraphDepth :: Int }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **本 feature 加 `coJudgeN`**(改動前的現況) |
| `defaultConflictOpts :: ConflictOpts`(`coTopN = 20`、`coExpandBody = False`、`coTimelineWindow = Nothing`、`coGraphDepth = 2`) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **本 feature 補 `coJudgeN = 5`** |
| `data ConflictHit = ConflictHit { chTarget :: Id, chLayer :: HitLayer, chReason :: Text, chSnippet :: Maybe Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | `verdictHit` 的輸出;本層的 `chSnippet` 恆為 `Just` |
| `data HitLayer = ByGraph GraphEvidence \| ByRetrieval Double \| ByJudge Double` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 本層一律產出 `ByJudge`;`Double` 就是 0–1 的信心 |
| `data ConflictReport = ConflictReport { crHits :: [ConflictHit], crScanned :: Int, crLlmUsed :: Bool }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **本 feature 加 `crNotes :: [ReportNote]`**(改動前的現況) |
| `emptyReport :: ConflictReport` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **本 feature 補 `crNotes = []`** |
| `sortHits :: [ConflictHit] -> [ConflictHit]`(層級 → 分數遞減,`ByJudge` 排最後) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **本 feature 不呼叫**;跨層排序是 F006 的事 |
| `instance ToJSON ConflictOpts` / `FromJSON ConflictOpts`(`top_n` / `expand_body` / `timeline_window` / `graph_depth`,缺欄位退 `defaultConflictOpts`) | `conflict/src/StoryFlow/Conflict/Json.hs` | F001 | **本 feature 加 `judge_n`** |
| `instance ToJSON ConflictReport` / `FromJSON ConflictReport`(`hits` / `scanned` / `llm_used`) | `conflict/src/StoryFlow/Conflict/Json.hs` | F001 | **本 feature 加 `notes`** |
| `instance ToSchema ConflictOpts`(`objSchema "…" [("top_n", int), ("expand_body", bl), ("timeline_window", int), ("graph_depth", int)] []`) | `api/src/StoryFlow/Api/Instances.hs` | service-and-interfaces/F003 | **加 `judge_n` 到 `properties`**,`required` 仍是 `[]` |
| `sampleConflictOpts :: ConflictOpts`(record 建構,四欄) | `api/test/StoryFlow/Api/Fixtures.hs` | service-and-interfaces/F003 | **補 `coJudgeN`**;`SchemaSpec` 的樣本刻意把選配欄位填滿 |
| `conflictOptsP :: Parser ConflictOpts`(位置式建構,`coExpandBody` 用 `pure`) | `cli/src/StoryFlow/Cli/Options.hs` | service-and-interfaces/F002 | **補 `pure (coJudgeN defaultConflictOpts)`**;`context` 不開 `--judge-n` |
| `eitherDecodeStrictText :: FromJSON a => Text -> Either String a` | `aeson-2.2.5.0` | — | 直接吃 `Text`,**讓 `storyflow-conflict` 不必長出 `bytestring` 相依** |

> 上表每一列的簽名都是從來源檔案讀出的**原文**。標示「本 feature 加 / 補」的,
> 列的是**改動前**的現況——改動後的形狀寫在「新增的介面」。

## 新增的介面

### `StoryFlow.Conflict.Types`(F001 的模組,契約已升格)

```haskell
data ConflictOpts = ConflictOpts
  { coTopN           :: Int
  , coJudgeN         :: Int
  -- ^ __第 3 層的候選預算__:合流排序後送模型判斷的前 N 個。
  --   獨立於 'coTopN' ——那個管「撈多廣」,這個管「燒多少」。
  --   <= 0 代表不跑第 3 層(合法輸入,但候選非空時要記一則 judge_disabled)。
  , coExpandBody     :: Bool
  , coTimelineWindow :: Maybe Int
  , coGraphDepth     :: Int
  }

-- | coJudgeN = 5:地端 12B 模型實測一對約 7 秒,五對約 35 秒。
--   coTopN 的 20 全判約 140 秒,那不是一個指令等得起的長度。
defaultConflictOpts :: ConflictOpts

-- | 報告附帶的提示。__不是命中__,所以不進 crHits ——它說的是
--   「這份報告本身有什麼要注意的」。放進 DTO 而非只在 CLI 渲染,
--   是因為 CLI 與 REST 必須拿到同一批結果。
data ReportNote = ReportNote
  { rnCode   :: Text   -- ^ 穩定識別碼,給程式化消費者分派,不隨文案改動
  , rnDetail :: Text   -- ^ 繁中訊息,每一則都說出下一步
  }
  deriving stock (Show, Eq)

data ConflictReport = ConflictReport
  { crHits    :: [ConflictHit]
  , crScanned :: Int
  , crLlmUsed :: Bool   -- ^ 第 3 層有沒有__真的產出至少一筆判斷__(不是「有沒有嘗試」)
  , crNotes   :: [ReportNote]
  }

emptyReport :: ConflictReport   -- ^ crNotes = []
```

### `StoryFlow.Conflict.Json`(F001 的模組)

```haskell
-- {"code": "judge_parse_failed", "detail": "…"}
instance ToJSON   ReportNote
instance FromJSON ReportNote

-- ConflictOpts 多一個 judge_n(缺席退 defaultConflictOpts 的那一欄)
-- ConflictReport 多一個 notes(缺席退 [];舊客戶端的 payload 不會壞)
```

### `StoryFlow.Conflict.Judge`(本 feature 的主體)

```haskell
module StoryFlow.Conflict.Judge
  ( -- * 門面
    judgeCandidates
  , judgeCandidatesWith
  , JudgeResult (..)

    -- * 注入接縫(D6:公開面吃 LlmClient,內部吃可替換的 runner)
  , JudgeRunner
  , llmRunner
  , judgeLoop

    -- * 送出去的那一段
  , JudgeTarget (..)
  , resolveTargets

    -- * 退化的詞彙(F006 決定用哪一個)
  , JudgeSkip (..)
  , skipNote

    -- * 逐對判斷的純函式部件
  , Verdict (..)
  , judgeSystemPrompt
  , renderPairPrompt
  , judgeMessages
  , stripCodeFence
  , parseVerdict
  , verdictHit
  ) where

-- | 送給模型的那一對裡,__候選那一半__。
data JudgeTarget = JudgeTarget
  { jtId       :: Id
  , jtTitle    :: Text
  , jtText     :: Text  -- ^ 實際送出去的內容:預設 summary,coExpandBody 時是 body
  , jtExpanded :: Bool  -- ^ 這一對送的是不是展開的 body
  }
  deriving stock (Show, Eq)

-- | 模型回覆解析後的結果。__不是 DTO__:沒有任何消費者看得見它,
--   所以它的 FromJSON 私有地留在本模組,不進 Conflict.Json
--   (先例:storyflow-llm 的 ChatResponse / ChatChoice)。
data Verdict = Verdict
  { vdContradicts :: Bool
  , vdConfidence  :: Double  -- ^ 已 clamp 到 [0, 1]
  , vdReason      :: Text
  }
  deriving stock (Show, Eq)

-- | 第 3 層的完整結果。
data JudgeResult = JudgeResult
  { jrHits   :: [ConflictHit]  -- ^ HitLayer 恆為 ByJudge;只有判定為矛盾的才成為命中
  , jrJudged :: Int            -- ^ __成功取得判斷的對數__(含判定為不矛盾的)→ crLlmUsed = jrJudged > 0
  , jrNotes  :: [ReportNote]   -- ^ 逐對失敗、中止、預算為零 → ConflictReport.crNotes
  }
  deriving stock (Show, Eq)

-- | 第 3 層沒有跑起來的三種原因。__三個不同的 rnCode__,因為對使用者是三個不同的下一步。
data JudgeSkip
  = SkipDisabled                -- ^ --no-llm,或 coJudgeN <= 0
  | SkipNotConfigured LlmError  -- ^ LlmConfigMissing / LlmConfigInvalid
  | SkipUnreachable   LlmError  -- ^ 建 client 或第一次呼叫就連不上
  deriving stock (Show, Eq)

skipNote :: JudgeSkip -> ReportNote

-- | 呼叫模型的接縫。__型別參數是 Monad 而不是 IO__:judgeLoop 因此碰不到 IO,
--   除了 runner 給它的東西以外什麼都做不了。
type JudgeRunner m = [Message] -> m (Either LlmError Text)

-- | 唯一真的呼叫 chat 的地方。
llmRunner :: LlmClient -> JudgeRunner ServiceM

-- | 候選 → 送出去的那一段。__先套 coJudgeN 預算,再讀 body__
--   (不在預算內的候選連 getEntity 都不會發生)。
resolveTargets :: ConflictOpts -> [Candidate] -> ServiceM [JudgeTarget]

-- | 逐對判斷。__不讀資料__,所以對任意 Monad 成立,四條必測路徑都可在零 IO 下觸發。
--   LlmUnavailable 中止剩餘的對(chat 已經重試過,再打只會把每一對都等一次逾時);
--   其餘錯誤逐對記錄並繼續。已成功的一律保留。
judgeLoop :: (Monad m) => JudgeRunner m -> Draft -> [JudgeTarget] -> m JudgeResult

-- | 公開面:照契約卡吃不透明的 LlmClient。
judgeCandidates :: LlmClient -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult

-- | 換 runner 用的版本;judgeCandidates = judgeCandidatesWith . llmRunner。
judgeCandidatesWith :: JudgeRunner ServiceM -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult

-- | 固定的系統訊息:只判斷事實矛盾、只輸出一個 JSON 物件、三個鍵、reason 用繁中一句話。
judgeSystemPrompt :: Text

-- | 使用者訊息:【新草稿】…【既有設定 <id>(<標題>)】…。drRefs 不進 prompt。
renderPairPrompt :: Draft -> JudgeTarget -> Text

-- | [Message System judgeSystemPrompt, Message User (renderPairPrompt d t)]
--   ——system role 已對真端點實測可用。
judgeMessages :: Draft -> JudgeTarget -> [Message]

-- | 剝除 markdown code fence。實測地端 gemma-4-12b-it 回的是 ```json 包起來的內容,
--   直接 decode 會__每一對都失敗__。沒有 fence 時回原文(已去空白)。
stripCodeFence :: Text -> Text

-- | 剝 fence → decode;失敗再試「第一個 { 到最後一個 }」的切片;
--   兩次都失敗回 Left(訊息帶截斷後的原文)。
--   confidence 超出 [0,1] 就 clamp;contradicts = true 但 reason 空白視為解析失敗。
parseVerdict :: Text -> Either Text Verdict

-- | 判定為矛盾的 Verdict → ConflictHit。
--   chLayer = ByJudge vdConfidence、chReason = 模型原話、chSnippet = Just jtText
--   (就是模型看到的那一段)。
verdictHit :: JudgeTarget -> Verdict -> ConflictHit
```

**匯出面的節制**(階段一 arch-audit A-3 的教訓):本模組**不匯出任何調校常數**——
唯一的旋鈕 `coJudgeN` 住在 `ConflictOpts` 裡,是契約的一部分;截斷長度、fence 標記那些
是私有的。匯出清單裡 F006 真正會用到的只有 `judgeCandidates` / `JudgeResult` /
`JudgeSkip` / `skipNote` 四項,其餘是測試的觀測點,並且每一個都對應驗收標準的一條。

`storyflow-conflict.cabal`:`exposed-modules` 加 `StoryFlow.Conflict.Judge`;
library 與 test-suite 的 `build-depends` 各加 `storyflow-llm`。
**`storyflow-store` / `storyflow-md` / `sqlite-simple` 一個都不加,也不加 `bytestring`。**

## TodoList

- [x] T1: `Conflict.Types`:`ConflictOpts` 在 `coTopN` 後插入 `coJudgeN`、`defaultConflictOpts` 補 `coJudgeN = 5`;新增並匯出 `ReportNote (..)`;`ConflictReport` 加 `crNotes`、`emptyReport` 補 `[]`  `dep: F001`
- [x] T2: `Conflict.Json`:`ReportNote` 的 `ToJSON` / `FromJSON`(`code` / `detail`);`ConflictOpts` 加 `judge_n`(缺席退預設);`ConflictReport` 加 `notes`(缺席退 `[]`)  `dep: T1`
- [x] T3: 擴欄的連帶更新:`api` 的 `ToSchema ConflictOpts` 加 `judge_n`(`required` 不動)與 `sampleConflictOpts` 補欄;`cli` 的 `conflictOptsP` 補 `pure (coJudgeN defaultConflictOpts)`(不開 `--judge-n`);conflict 既有三個 spec 的建構與斷言更新  `dep: T2`
- [x] T4: `storyflow-conflict.cabal` library 與 test-suite 加 `storyflow-llm`、`exposed-modules` 加 `StoryFlow.Conflict.Judge`;`CabalSpec` 的 `forbidden` 縮成三項、新增「必須含 `storyflow-llm`」的正向斷言、`libraryDeps` / `testDeps` 逐字清單更新  `dep: T1`
- [x] T5: `Verdict` 與解析:`stripCodeFence` 三條規則、`parseVerdict`(fence → decode → `{`…`}` 切片回退 → decode)、confidence clamp、`contradicts = true` 但理由空白視為解析失敗  `dep: T4`
- [x] T6: prompt:`judgeSystemPrompt`(只輸出 JSON、三個鍵、繁中一句話理由)、`renderPairPrompt`(固定段落標記、id 走 `renderId`、`drRefs` 不進)、`judgeMessages`(`System` + `User` 兩則)  `dep: T4`
- [x] T7: `JudgeTarget` 與 `resolveTargets`:先套 `coJudgeN` 預算再解析文字;預設 `metaSnippet`,`coExpandBody` 時經 `getEntity` 取 `entBody`,空白或讀不到用 `catchError` 退回 summary;`jtExpanded` 如實記錄  `dep: T4`
- [x] T8: `JudgeRunner` 與 `judgeLoop`:逐對呼叫、`jrJudged` 計數、`verdictHit` 組裝命中、`judge_call_failed` / `judge_parse_failed` note、`LlmUnavailable` 中止並記 `judge_aborted`、已成功的一律保留  `dep: T5, T6`
- [x] T9: `JudgeSkip` / `skipNote`:三個 `judge_` 前綴的代碼與繁中文案(`renderLlmError` 的原文進 `rnDetail`)  `dep: T1`
- [x] T10: 門面 `llmRunner` / `judgeCandidatesWith` / `judgeCandidates`;`coJudgeN <= 0` 而候選非空時記 `judge_disabled` 且一次都不呼叫 runner  `dep: T7, T8, T9`
- [x] T11: 模組註冊(`conflict/test/Spec.hs` 加 `JudgeSpec` / `JudgeEnvSpec`)與 hermetic 驗證:`judgeLoop` 的 `Monad m` 拿不到 `MonadIO`,整個測試套件零網路請求  `dep: T10`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `conflict/test/StoryFlow/Conflict/OptsSpec.hs` → `coJudgeN 是獨立於 coTopN 的預算旋鈕` + `ReportSpec.hs` → `emptyReport 的 crNotes 是空清單` | `coJudgeN defaultConflictOpts == 5` 且 `/= coTopN defaultConflictOpts`(兩個旋鈕不是同一個值);record update 只改 `coJudgeN` 時 `coTopN` 不動;`ReportNote` 的兩欄 `Show`/`Eq` 可用;`crNotes emptyReport == []`;既有的 `emptyReport` 三條斷言一字不改仍通過 |
| T2 | `conflict/test/StoryFlow/Conflict/JsonSpec.hs` → `judge_n 與 notes 的編解碼` | `ReportNote "judge_parse_failed" "…"` round-trip 不失真,JSON 鍵是 `code` / `detail`;`ConflictOpts` 的 JSON 含 `judge_n`,缺 `judge_n` 時解出 `defaultConflictOpts` 的值;`ConflictReport` 的 JSON 含 `notes`,**缺 `notes` 的舊 payload 解得出來且 `crNotes == []`**;帶 notes 的 report round-trip 不失真 |
| T3 | `api/test/StoryFlow/Api/SchemaSpec.hs` → `ConflictOpts`(既有斷言,自動涵蓋新欄)+ `cli/test/StoryFlow/Cli/OptionsSpec.hs` → `context 不開 --judge-n` | `SchemaSpec` 的「`ToJSON` 與 `ToSchema` 逐欄對齊」在 `sampleConflictOpts` 補欄後仍綠(漏掉 `properties` 就會紅);`OptionsSpec` 斷言 `coJudgeN o == coJudgeN defaultConflictOpts`,且 `--judge-n 3` 讓 `context` 解析**失敗**(未知旗標);`api/test/HttpDataSpec.hs` 的「`opts` 缺席退 `defaultConflictOpts`」一字不改仍通過 |
| T4 | `conflict/test/StoryFlow/Conflict/CabalSpec.hs` → `第 3 層放行 llm,其餘三項仍然擋住` | `build-depends` **含** `storyflow-llm`(library 與 test-suite 各一次);`storyflow-store` / `storyflow-md` / `sqlite-simple` 整份 `.cabal` 一個都不出現;**`bytestring` 不在 library 段**;`exposed-modules` 含 `StoryFlow.Conflict.Judge`;`libraryDeps ++ testDeps` 逐字相符(擋掉順道多一個包) |
| T5 | `conflict/test/StoryFlow/Conflict/JudgeSpec.hs` → `fence 剝除與 JSON 解析` | `stripCodeFence`:```` ```json ````、無語言標記的 ```` ``` ````、前面有贅句的 fence、沒有 fence 的裸 JSON 四種輸入的輸出逐字正確;`parseVerdict`:合法 JSON 解得出三欄;`confidence = 1.4` clamp 成 `1.0`、`-0.3` clamp 成 `0.0`;純散文 / 缺 `confidence` / `confidence` 是字串 / `contradicts = true` 但 `reason` 空白**四種都回 `Left`**;`contradicts = false` 且 `reason` 空白**是合法的**;`Left` 的訊息帶得出原文片段且長度受限 |
| T6 | 同檔 → `prompt 的形狀` | `judgeMessages` 恰兩則、第一則 `msgRole == System`、第二則 `msgRole == User`;`judgeSystemPrompt` 含三個鍵名(`contradicts` / `confidence` / `reason`)與「只輸出」字樣;`renderPairPrompt` 含 `drText`、含 `renderId jtId`、含 `jtTitle`、含 `jtText`,且**不含 `drRefs` 的任何 id** |
| T7 | `conflict/test/StoryFlow/Conflict/JudgeEnvSpec.hs` → `送出去的那一段:summary 與 body` | 臨時 Vault 建三個 canon 片段(summary 與 body 內容可區分);`coExpandBody = False` 時每個 `jtText == metaSnippet caMeta` 且 `jtExpanded == False`;`= True` 時 `jtText == entBody` 且 `jtExpanded == True`;正文為空白的片段在 `= True` 下退回 summary 且 `jtExpanded == False`;`coJudgeN = 2` 而候選 5 個時 `resolveTargets` 只回 2 筆**且順序是輸入的前兩筆**;`coJudgeN = 0` 回 `[]` |
| T8 | `JudgeSpec.hs` → `逐對迴圈:成功、部分失敗、中止` | 三對回覆 `[Right 矛盾, Right 不矛盾, Right 矛盾]` → `jrHits` 2 筆、`jrJudged == 3`、`jrNotes == []`、命中順序等於輸入順序;`[Right 矛盾, Left (LlmHttpStatus 500 _), Right 矛盾]` → `jrHits` 2 筆、`jrJudged == 2`、一則 `judge_call_failed` 且 `rnDetail` 含第二個候選的 id、runner 被呼叫 **3** 次;`[Right 矛盾, Left (LlmUnavailable _), Right 矛盾]` → runner 只被呼叫 **2** 次、`jrHits` 1 筆、一則 `judge_aborted` 且 `rnDetail` 說得出剩 1 對;`[Right 純散文]` → `jrHits == []`、`jrJudged == 0`、一則 `judge_parse_failed`;命中的 `chLayer` 全是 `ByJudge`、`chReason` 等於模型原話、`chSnippet == Just jtText` |
| T9 | 同檔 → `退化的三種原因分得出來` | `skipNote` 三個建構子的 `rnCode` 兩兩不同、都以 `judge_` 開頭、逐字等於 `judge_disabled` / `judge_not_configured` / `judge_unreachable`;`rnDetail` 都非空;`SkipNotConfigured LlmConfigMissing` 的 detail 含 `renderLlmError LlmConfigMissing` 的內容(**不重寫下層訊息**);`SkipUnreachable` 的 detail 含 `renderLlmError` 的內容 |
| T10 | `JudgeEnvSpec.hs` → `門面與零預算` | `judgeCandidatesWith` 用假 runner 跑真 `ServiceM`:候選 3 個、`coJudgeN = 2` 時 runner 恰被呼叫 2 次;`coJudgeN = 0` 而候選非空時 runner **一次都沒被呼叫**、`jrJudged == 0`、`jrNotes` 恰一則 `judge_disabled`;候選為空清單時 runner 沒被呼叫且 `jrNotes == []`(沒有候選不是退化);`judgeCandidates` 與 `judgeCandidatesWith . llmRunner` 的型別相容(編譯即證明,不打真端點) |
| T11 | `conflict/test/Spec.hs` + `JudgeSpec.hs` → `hermetic` | `Spec.hs` 註冊 `JudgeSpec` / `JudgeEnvSpec` 兩個模組;整個 conflict 測試套件不 import `Network.*`、不呼叫 `newLlmClient`(以 grep 斷言守住:測試檔裡 `newLlmClient` 出現 0 次);`cabal test all` 在**沒有任何端點在跑**的機器上全綠 |

## 待確認假設

- A1: `ReportNote` 的文案該寫在哪一層——`conflict-llm` 契約卡說「不自己讀 `[llm]` 設定與建 `LlmClient`」,而 `conflict-check` 契約卡說「把 `LlmError` 翻成 `crNotes` 的文案發生在接線層」 → 採取:**詞彙(`JudgeSkip` 的三個建構子、`rnCode` 常數、`skipNote` 的文案)寫在 F005**,**選用哪一個由 F006 決定**(它才知道有沒有 `--no-llm`、才呼叫 `llmConfig`)。理由是 `ReportNote` 是 DTO,CLI 與 REST 必須拿到逐字相同的內容,文案寫在 CLI 渲染層會讓遠端模式拿到不一樣的東西 → 影響:若編排者裁定文案屬於接線層,把 `skipNote` 搬去 `Conflict.Pipeline`(仍在 `storyflow-conflict` 內,不是 CLI),F005 只留 `JudgeSkip` 型別與三個 `rnCode` 常數,T9 跟著移位
- A2: 逐對判斷途中遇到 `LlmUnavailable` 時,要繼續打完剩下的對還是中止?契約卡只說「保留已經成功的那幾對」 → 採取:**`LlmUnavailable` 中止剩餘的對並記 `judge_aborted`,其餘錯誤逐對記錄並繼續**。依據是 `chat` 內部已經對 `LlmUnavailable` 重試過,走到這裡代表服務真的不在;繼續打會讓每一對再等一次 `lcTimeout`(預設 60 秒)× 重試次數,換來必然相同的失敗 → 影響:若正確語意是「每一對都要試」,拿掉中止規則即可(迴圈其餘部分不變),但 `--judge-n 20` 加上端點掛掉會讓一個指令跑二十幾分鐘;`judge_aborted` 這個 `rnCode` 也會一併消失
- A3: 模型回的 `confidence` 落在 `[0, 1]` 之外時,算解析失敗還是校正?契約卡只說「信心以 0–1 的浮點進 `ByJudge`」 → 採取:**clamp 到 `[0, 1]`,不算失敗**。clamp 的是範圍,不是把沒有的值生出來——模型已經明確回答了矛盾與否,為一個超界的機率丟掉整筆判斷,損失比校正大 → 影響:若「超界代表模型根本沒讀懂 schema」才是正確解讀,把它併進 `parseVerdict` 的 `Left` 分支即可(T5 多一條斷言),代價是地端小模型的有效判斷率會下降
- A4: `contradicts = true` 但模型沒給 `reason`(缺鍵或空字串)時怎麼辦 → 採取:**該對算判斷失敗**(`judge_parse_failed`),不產生命中。驗收標準 4 要「每筆命中都帶模型給的理由」,而唯一不代筆的作法就是沒有理由時不產生命中;`contradicts = false` 時 `reason` 可以是空的 → 影響:若可以接受「有命中但理由欄是空的」,改成照樣產生命中即可,但 CLI 的報告會出現一筆說不出所以然的矛盾,而第 3 層本來就是最需要被複核的一層
- A5: 契約卡說送模型的是「**合流排序後**的前 `coJudgeN` 個」,但合流是 F006 的事,而第 1 層的命中是**事實**、不需要判斷,且它們是 `ConflictHit` 而非 `Candidate`(沒有 `Meta`,拿不到 summary / body) → 採取:`judgeCandidates` 吃 **`[Candidate]`**(第 2 層已排序的候選),`take coJudgeN` 在本層;「合流排序」對第 3 層而言等於「第 2 層的排序」,F006 若要重排只需重排傳進來的清單 → 影響:若第 1 層的命中也該送模型複判,本層要改吃 `[ConflictHit]` 外加一張 `Id -> Meta` 的查表(或改吃 `[(ConflictHit, Meta)]`),`resolveTargets` 的簽名與 T7 全部跟著改
- A6: `coJudgeN` 的預設值契約只說「保守」,沒給數字 → 採取:**5**(實測一對約 7 秒 → 約 35 秒);與 `coTopN = 20` 明顯不同,讓「兩個旋鈕不是同一個東西」在預設值上就看得出來 → 影響:純數值,改一行即可;但 T1 的斷言逐字釘住 5,調整時要一起改
- A7: 送出去的那一段用 `metaSnippet`(summary → title)還是 `caSnippet`(FTS5 命中的片段) → 採取:**`metaSnippet`**——契約卡寫的是「優先送 `summary`」,而 `caSnippet` 是為了給人看「為什麼撈到你」而截的,常常斷在句中;同時這也讓「沒有片段可指時拿什麼當代表」這條規則在整個子系統只有一份 → 影響:若模型判斷需要看見真正被命中的那一段,`JudgeTarget` 要多帶一欄(或 `jtText` 改成 summary + snippet 兩段拼接),prompt 與 T6 / T7 跟著改
