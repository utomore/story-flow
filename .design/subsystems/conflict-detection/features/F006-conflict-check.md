---
id: F006
type: feature
title: conflict-check
description: "三層合流的衝突報告出口:story-flow conflict check 與 POST /conflict/check"
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: [F001, F002, F003, F004, F005, llm-workshop-mcp/F001, entity-graph-core/F002, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003]
related-adr: [ADR-006, ADR-007]
related-feature: []
---

# F006: conflict check(三層合流與報告出口)

## 功能概述

`conflict-detection` 的**最後一個 feature**,也是主架構 P4 完成標準
「拿真實草稿測出既有設定的矛盾,且能說出是哪個片段的哪一段」的收尾:把 F002 的第 1 層、
F003 的第 2 層、F005 的第 3 層在 `Conflict.Pipeline` 合流成 `checkConflict`,
再以 `story-flow conflict check` 與 `POST /conflict/check` 兩種形式露出去(出口 B)。

F004 交付的出口 A(`gatherContext`)回的是「和這段草稿有關的既有片段」——**素材**;
本 feature 的出口 B 回的是「和這段草稿矛盾的是哪幾筆、憑什麼」——**報告**。
兩者不是同一件事,`ContextHit` 與 `ConflictHit` 分成兩個型別的理由就在這裡。

本 feature 同時是三個「留到最後才接」的出口的實際接收者:

- **F002 的 `unlinkedRefs`**:自 F002 就存在、至今**沒有任何生產程式碼消費者**,
  F004 的 A2 明確把它留給本 feature(`[ContextHit]` 裡沒有它的位置,`crNotes` 才有)
- **F005 的 `JudgeSkip` / `skipNote`**:F005 只提供詞彙與文案(它的 A1),
  **選用哪一個由本 feature 決定**——它才知道有沒有 `--no-llm`、才呼叫 `llmConfig` 與
  `newLlmClient`
- **F001 的 `sortHits`**:三層合流的排序約定寫在 F001,至今沒有呼叫端;本 feature 是它的
  第一個(也是唯一預期的)消費者

驗收標準(逐條對應契約卡):

1. report **每一筆都標示命中層級**——第 1 層是事實、第 3 層是判斷,使用者看得出差別
   (人類模式走 `via` 欄,`--json` 走 `layer` 標籤)
2. `crScanned` 讓使用者判斷 `top-N` 夠不夠;`crLlmUsed` 說明有沒有跑第 3 層,
   語意是**有沒有真的產出至少一筆判斷**,不是「有沒有嘗試」
3. `--no-llm` 與未設定端點**都退化成兩層**而不是整個指令失敗,且**三種退化原因是三個不同的
   `rnCode`**(`judge_disabled` / `judge_not_configured` / `judge_unreachable`)
4. 確認衝突後**提示**作者建立 `contradicts` 關聯(下次就是零成本的第 1 層命中)
5. `crNotes` 接滿三種來源:第 3 層的退化或部分失敗、第 1 層的 `unlinkedRefs`、關聯建議;
   三者以 `rnCode` 分派
6. `ConflictOpts` **五欄全部可調**:`--top-n` / `--judge-n` / `--timeline-window` /
   `--graph-depth` / `--expand-body`,外加 `--ref`(可重複)與 `--no-llm`
7. CLI 與 REST 兩種形式**回同一批結果**;`--json` 走 `service-and-interfaces` 的統一信封
8. 自動化測試 **hermetic**:`cabal test all` 不依賴任何外部端點、不發任何網路請求(D6)

明確**不做**:不自動寫入關聯,只提示;不修改任何片段;不在 CLI 層重做排序邏輯;
不實作 LLM 端點;不改第 1、2、3 層任何一層的內部邏輯(本 feature 只合流)。

## 相依性

`depends-on` 的每一項都對應「使用到的既有串接介面」表裡至少一列:

| 文檔 | 提供什麼 | 本 feature 怎麼用 |
|---|---|---|
| `F001` | `Draft` / `ConflictOpts` / `ConflictHit` / `ConflictReport` / `ReportNote` / `sortHits` / `emptyReport` | 出口的輸入輸出型別;排序約定 |
| `F002` | `graphHits` / `unlinkedRefs` | 第 1 層的命中與「完全沒有標註」的起點 |
| `F003` | `retrieveCandidates` / `RetrievalResult` / `Candidate` / `candidateConflictHit` | 第 2 層的候選、`crScanned` 的來源、候選 → `ConflictHit` 的既有轉換 |
| `F004` | `Conflict.Pipeline` 這個模組本身、`sortContextHits` 的排序紀律 | 本 feature 在同一個模組內加出口 B;去重/排序照它的形狀做 |
| `F005` | `judgeCandidatesWith` / `llmRunner` / `JudgeRunner` / `JudgeResult` / `JudgeSkip` / `skipNote` | 第 3 層的呼叫與退化詞彙 |
| `llm-workshop-mcp/F001` | `llmConfig` / `newLlmClient` / `LlmClient` / `LlmError` | 接線層建 client 與判斷退化原因 |
| `entity-graph-core/F002` | `Id` / `Ref` / `LinkKind` / `renderId` / `renderRef` / `renderLinkKind` | 命中的識別與文案 |
| `service-and-interfaces/F001` | `ServiceM` / `linkGraph` | 出口跑在 `ServiceM` 上;第 1 層的圖 |
| `service-and-interfaces/F002` | `Backend` / `BodySource` / `readBody` / 統一信封 / `renderVia` / `table` | CLI 子指令的接線與渲染 |
| `service-and-interfaces/F003` | `StoryFlowAPI` / `ToSchema` / servant handler / `servant-client` | REST 路由與 `--remote` 那一條路 |

**可否平行開發**:不能。上表的 F002 / F003 / F004 / F005 全部是本 feature 的輸入,
其中 F005 剛完成(commit `efc0646`),而本 feature 動的是同一批檔案
(`Conflict.Pipeline`、`api` / `server` / `cli` 的接線)。十項全部 `done` 且程式碼在
`feat/conflict-stage2-0013` 上,沒有紙上約定的相依,**現在就能開工**。
本 feature 之後沒有後續 feature——它是子系統的 6/6。

## 對應的 Level 2 契約

### 落在契約內的部分

| 契約來源 | 條文 | 本 feature 的落點 |
|---|---|---|
| `design.md`「對外契約」 | `checkConflict :: Maybe LlmClient -> ConflictOpts -> Draft -> ServiceM ConflictReport` | `StoryFlow.Conflict.Pipeline.checkConflict`,**簽名逐字相同** |
| 同上,對外形式表 | `story-flow conflict check --draft <檔案\|-> [--ref …] [--top-n] [--judge-n] [--timeline-window] [--graph-depth] [--expand-body] [--no-llm]` | CLI 新增 `conflict` 名詞與 `check` 動詞 |
| 同上,對外形式表 | `POST /conflict/check` | `ConflictAPI` 加第二條路由,body 是新的 `CheckReq` |
| 同上「資料流管線」 | 三層合流、去重、依命中層級與分數排序 → 出口 B | `mergeConflictHits` / `sortConflictHits` |
| 同上「內部模組劃分」 | `Conflict.Pipeline`:三層合流、去重、依命中層級排序 | 全部住在既有的 `Conflict.Pipeline` 模組,**不新增模組** |
| 同上「第 3 層的退化與部分失敗」 | 拿不到可用 client 一律退化;三種原因走 `crNotes`;逐對失敗保留已成功的;`crLlmUsed` 是「有沒有真的產出判斷」 | `JudgeStage` / `acquireJudge` / `runJudge` 三段 |
| 同上「`crNotes` 的三種來源」 | 第 3 層退化、`unlinkedRefs`、關聯建議,以 `rnCode` 分派 | `unlinkedNote` / `suggestionNote` + F005 的 `judge_*` |
| 同上「輸出契約」 | 每一筆帶 (候選片段 id, 命中層級, 理由);CLI 人類模式以不同前綴區分,`--json` 走統一信封 | `renderReport` 的 `via` 欄 + 既有 `Envelope` |
| 同上「第 3 層的候選預算」 | 送模型的是合流排序後的前 `coJudgeN` 個 | 見「三、第 3 層的輸入」與 A5 |

**新增的對外契約只有一個**:`POST /conflict/check` 的 request body 型別 `CheckReq`。
它與 F004 的 `ContextReq` 是同一種東西(REST 需要一個有名字的物件來包住兩三個參數),
放在同一個位置、用同一種寫法。

### 不在契約內、但本 feature 必須做的判斷

Level 2 的 `checkConflict` 第一個參數是 `Maybe LlmClient`,而 `Nothing` **帶不出三種退化原因
的差別**——`--no-llm`、`[llm]` 沒設定、端點連不上壓成同一個 `Nothing`,正是同一份 `design.md`
明令不准發生的事(「別讓它們塌成同一則訊息」)。處理方式見第二節與 **A1**:
契約簽名**一字不改**地保留並實作,接線層走同一個模組裡多一層的門面。
這是 F003 的 `retrieveCandidates` / `retrieveCandidatesWith` 與 F005 的 `judgeCandidates` /
`judgeCandidatesWith` 同一種「門面 + 接縫」形狀,不是契約偏離;但它是否該回寫 Level 2,
由編排者裁決(見回報)。

## 實作方式

### 一、整體資料流

```text
Draft { drText, drRefs }        ConflictOpts { coTopN, coJudgeN, coExpandBody,
        │                                       coTimelineWindow, coGraphDepth }
        │
        ├─ graphStage(第 1 層):linkGraph 取一次圖
        │     ├─ graphHits opts g drRefs      → [ConflictHit](ByGraph,chSnippet = Nothing)
        │     └─ unlinkedRefs g drRefs        → [Id](第 1 層幫不上忙的起點)
        │
        ├─ retrieveCandidates opts d(第 2 層)
        │     → RetrievalResult { rrCandidates(已排序、已截到 coTopN), rrScanned, rrKeywords }
        │     → map candidateConflictHit      → [ConflictHit](ByRetrieval,chSnippet = Just)
        │
        └─ runJudge stage opts d rrCandidates(第 3 層)
              ├─ JudgeSkipped s → JudgeResult [] 0 [skipNote s | 候選非空]
              └─ JudgeWith runner → judgeCandidatesWith(監看 LlmUnavailable)
                    → JudgeResult { jrHits(ByJudge), jrJudged, jrNotes }
                    → 一筆判斷都沒產出而原因是連不上 → judge_aborted 升格成 judge_unreachable
        ▼
  mergeConflictHits(去重)→ sortConflictHits(全序)→ crHits
  crScanned = rrScanned
  crLlmUsed = jrJudged > 0
  crNotes   = 第 1 層的 unlinkedNote ++ 第 3 層的 jrNotes ++ budgetNote ++ suggestionNote
        ▼
  ConflictReport ──► CLI `story-flow conflict check` / REST `POST /conflict/check`
```

**第 1 層在 check 這條路上不補 `Meta`**:`ConflictHit` 只有 `chTarget :: Id`
(F001 的欄位註解明說「呼叫端要細節自己去查」),所以本出口**不呼叫 `getEntity`**——
F004 的 `graphContextHits` 之所以要補,是因為 `ContextHit` 的 `xhMeta` 不是 `Maybe`。
同一個模組裡兩條路徑的差別完全來自兩個回傳型別,不是隨意的。

**`coTopN` 一樣不在合流之後再截一次**(F004 A5 已裁定):它是第 2 層的候選上限,
`retrieveCandidates` 內部已經套用;第 1 層的命中是零成本的**事實**,拿它去砍會砍掉最有價值
的那一批。

### 二、第 3 層要不要跑、為什麼不跑:`JudgeStage`

三種退化原因誰知道什麼,是這一節唯一要解決的事:

| 原因 | 誰知道 | `rnCode` |
|---|---|---|
| `--no-llm`,或 `coJudgeN <= 0` | **接線層**(旗標與 opts 在它手上) | `judge_disabled` |
| `[llm]` 段缺漏或不合法 | **接線層**(`llmConfig` 回 `Left`) | `judge_not_configured` |
| 端點連不上 | **`chat` 第一次呼叫**才知道 | `judge_unreachable` |

因此第 3 層的入口收的不是 `Maybe LlmClient`,而是一個把「跑不跑、為什麼不跑」講清楚的型別:

```haskell
-- | 第 3 層要怎麼跑:退化(帶原因),或用一個 runner 跑。
data JudgeStage
  = JudgeSkipped JudgeSkip           -- ^ 不跑,原因是這個
  | JudgeWith (JudgeRunner ServiceM) -- ^ 跑,用這個 runner
```

**一個接縫同時服務兩件事**:接線層給 `llmRunner client`,測試給假 runner
(`LlmClient` 是不透明型別、造不出指向假端點的實例——這正是 F005 留下接縫的理由)。
不必為了測試再開第三個入口。

三個門面,職責各不相同:

```haskell
-- Level 2 的對外契約,簽名逐字相同。Nothing = 呼叫端沒有給 client,
-- 一律當成 --no-llm(SkipDisabled)——那是 Maybe 唯一說得出口的原因。
checkConflict :: Maybe LlmClient -> ConflictOpts -> Draft -> ServiceM ConflictReport
checkConflict = checkConflictWith . maybe (JudgeSkipped SkipDisabled) (JudgeWith . llmRunner)

-- 三層合流的本體。第 3 層怎麼跑由呼叫端決定。
checkConflictWith :: JudgeStage -> ConflictOpts -> Draft -> ServiceM ConflictReport

-- 接線層的一行:讀設定、建 client(或決定退化原因)、跑三層。
-- CLI 與 server 各呼叫一次同一份,兩邊因此不可能長歪。
checkConflictFor :: Bool -> ConflictOpts -> Draft -> ServiceM ConflictReport
checkConflictFor noLlm opts d = acquireJudge noLlm opts >>= \s -> checkConflictWith s opts d

-- 讀 [llm] 設定並建 client,或決定退化原因。
acquireJudge :: Bool -> ConflictOpts -> ServiceM JudgeStage
```

`acquireJudge` 的三條分支:

1. `noLlm == True`,**或** `coJudgeN <= 0` → `JudgeSkipped SkipDisabled`,
   **不讀設定、不建 client**。順序是刻意的:`--judge-n 0` 加上沒設定 `[llm]` 的 Vault,
   若先讀設定就會回「你還沒設定 `[llm]`」,而使用者要的是「這次不要判斷」——那是錯的下一步
2. `llmConfig` 回 `Left e`(`LlmConfigMissing` / `LlmConfigInvalid`)→
   `JudgeSkipped (SkipNotConfigured e)`
3. `Right cfg` → `JudgeWith . llmRunner <$> liftIO (newLlmClient cfg)`。
   `newLlmClient` 是**全函式**(它的 haddock 逐字這麼寫:拿得到 `LlmConfig` 的那一刻設定就
   已經是好的了),所以這裡不包 `try`

**`llmConfig` 不碰 IO**:它是 `parseLlmConfig . cfgLlm <$> vaultConfig`,而
`vaultConfig = asks (vaultCfg . envVault)` ——設定在 `openEnv` 時就讀進 `Env` 了,
本 feature 每次呼叫的成本是一次純解析。

**遠端模式下 client 由 server 端建**:`--remote` 送出去的是 `CheckReq`(草稿、選項、
`no_llm` 三個值),`acquireJudge` 在伺服器那一端跑。與 `linkGraph` 一樣**不跨 HTTP**——
`LlmClient` 裡面是一個 `Manager`,它本來就序列化不了,而 Vault 的 `[llm]` 設定屬於
伺服器綁定的那個 Vault。

**「端點連不上」怎麼變成 `judge_unreachable`**:`judgeLoop` 遇到 `LlmUnavailable` 會中止並記
`judge_aborted`(F005),但那則訊息說的是「跑到一半斷了」。**一筆判斷都沒產出**時,事實是
「第 3 層根本沒跑起來」,那正是 `SkipUnreachable` 這個詞彙的位置。作法是用一個**監看用的
runner**把 `LlmUnavailable` 記下來(`IORef` 在 `base`,不新增相依),判斷結束後:

- `jrJudged == 0` 且監看到 `LlmUnavailable e` → 把 `judge_aborted` 那一則**換成**
  `skipNote (SkipUnreachable e)`,其餘的 note(例如前幾對的 `judge_parse_failed`)原封不動
- `jrJudged > 0` → 什麼都不換。第 3 層真的跑過了,`judge_aborted` 說的就是實情

`rnDetail` 走 `renderLlmError` 的原文,**不重寫下層訊息**(`system.md` 全域錯誤策略第 1 條)。

### 三、第 3 層的輸入:候選,以及預算

送進 `judgeCandidatesWith` 的是**第 2 層的 `rrCandidates`**(已排序、已截到 `coTopN`),
`take coJudgeN` 由 F005 的 `resolveTargets` 在它那一側套用——本 feature 不重複截斷。

契約卡寫的是「取**合流排序後**的前 N 個候選送判斷」,而本 feature 的實作是「取**第 2 層排序
後**的前 N 個」。兩者在這裡是同一件事,理由見 **A5**:第 1 層的命中是**事實**、不需要模型
複判,而且它們是 `ConflictHit` 沒有 `Meta`,拿不到 summary 也拿不到 body,送不進 prompt。

**預算被截掉的部分要說出來**:候選 12 個而 `coJudgeN = 5` 時,報告裡會有 7 筆
`ByRetrieval` 的列——使用者無法分辨它們是「模型看過、判定不矛盾」還是「根本沒送」。
這兩件事的份量完全不同,所以第 3 層真的跑過而候選數超過預算時記一則 `judge_budget`
(見第五節與 **A6**)。

### 四、合流:去重與排序

```haskell
mergeConflictHits :: [ConflictHit] -> [ConflictHit]   -- 去重 + 排序
sortConflictHits  :: [ConflictHit] -> [ConflictHit]   -- 只排序(純函式,可單獨測)
```

**去重鍵**分兩種槽:

| 命中 | 槽 | 理由 |
|---|---|---|
| `ByGraph ev` | `(chTarget, "graph:" <> from <> ":" <> kind <> ":" <> to)` | **整條證據**當鍵,與 F002 的 `dedupeFindings` 同一條紀律:同一個片段既與草稿矛盾、又出現在取代鏈上,那是**兩件事**,作者兩件都要看到 |
| `ByRetrieval` / `ByJudge` | `(chTarget, "candidate")` | 每個候選最多一列 |

**同一槽的勝負**:`ByJudge` 勝過 `ByRetrieval`。第 3 層的命中一定來自第 2 層的候選,
所以每一筆 judge 命中的 target 必然也有一筆 retrieval 命中;兩列並存等於同一個片段講兩次,
而「模型判定它與草稿矛盾,理由是…」嚴格涵蓋「它和草稿有共同的詞」。
**注意這與 F004 的 `mergeContextHits`「取層級較前者」方向相反**,不是筆誤:那一邊問的是
「為什麼撈到你」(graph 最強),這一邊問的是「這一筆對『矛不矛盾』說了什麼」
(judge 才說得出來)。見 **A4**。

**`chSnippet` 不跨層搬**:judge 命中的 `chSnippet` 就是送給模型看的那一段(F005 的裁定:
「使用者要複核模型的判斷時,看到的必須是模型看到的東西」),不換成 FTS5 的片段。
這也與 F004 的合併規則不同,理由同上。

**排序**沿用既有紀律(層級 → 分數遞減 → id 字典序),但主鍵的約定**不再寫第三份**:

```haskell
-- 先依次要鍵排,再交給 F001 的 sortHits ——sortOn 是穩定排序,所以主鍵覆蓋在上面,
-- 次要鍵在同層同分時決勝。層級順序的約定因此只有一份(F001),全序由這裡補足。
sortConflictHits :: [ConflictHit] -> [ConflictHit]
sortConflictHits = sortHits . sortOn (\h -> (chTarget h, hitSlot h))
```

`sortHits`(F001)只排 (層級, 分數遞減),那不是全序;第 1、2 層是確定性層,
「大致上這個順序」不夠(F003 / F004 的原話)。第三鍵 `chTarget`、第四鍵是去重槽,
輸出因此逐筆確定。**`sortHits` 至此有了它的第一個消費者**。

### 五、`crNotes` 的三種來源

`rnCode` 以**前綴分派來源**,程式化消費者一眼看得出這一則講的是哪一層:

| `rnCode` | 來源 | 何時 | `rnDetail` 要說出的下一步 |
|---|---|---|---|
| `graph_unlinked_refs` | 第 1 層 | `unlinkedRefs` 非空 | 「你引用的 ent-a、ent-b 在本 Vault 沒有任何關聯,第 1 層對它們幫不上忙;用 `story-flow link list` 確認,或補上關聯」 |
| `judge_disabled` | 第 3 層(F005 的 `skipNote`) | `--no-llm` 或 `coJudgeN <= 0`,且候選非空 | F005 原文 |
| `judge_not_configured` | 同上 | `[llm]` 段缺漏或不合法 | `renderLlmError` 原文 |
| `judge_unreachable` | 同上 | 一筆判斷都沒產出、原因是連不上 | `renderLlmError` 原文 |
| `judge_call_failed` / `judge_parse_failed` / `judge_aborted` | 第 3 層(F005 的 `judgeLoop`) | 逐對失敗 / 中止 | F005 原文,**本 feature 原樣帶過** |
| `judge_budget` | 第 3 層 | 第 3 層真的跑過,且候選數 > `coJudgeN > 0` | 「候選 12 個,只有前 5 個送了語意判斷;其餘 7 個**沒有第 3 層的結論**(不是判定為沒有矛盾),把 `--judge-n` 調大可以判更多」 |
| `link_suggested` | 關聯建議 | `crHits` 裡有 `ByJudge` 的命中 | 「第 3 層判定 ent-x、ent-y 與草稿矛盾;確認成立後替草稿對應的片段建立 `contradicts` 關聯(`story-flow link add <草稿片段 id> --kind contradicts --target ent-x`),下次這些命中就是第 1 層的零成本事實」 |

三個純函式各自可以單獨測:

```haskell
unlinkedNote   :: [Id] -> Maybe ReportNote                       -- 空清單 → Nothing
budgetNote     :: ConflictOpts -> Int -> Maybe ReportNote        -- Int = 候選數
suggestionNote :: [ConflictHit] -> Maybe ReportNote              -- 只看 ByJudge 的命中
```

**note 的順序固定**:第 1 層 → 第 3 層(F005 給什麼順序就什麼順序)→ `judge_budget` →
`link_suggested`。順序本身是輸出的一部分,兩種模式要逐字元相同。

`unlinkedNote` 的 id 順序沿用 `unlinkedRefs` 的輸出(輸入順序去重),
`suggestionNote` 的 id 順序沿用 `crHits` 排序後的順序——兩者都是確定的。

**建議只針對 `ByJudge` 的命中**:第 1 層的命中已經有關聯了(那正是它命中的原因),
建議建立一條已經存在的關聯只是雜訊;第 2 層交的是「相關」不是「矛盾」,對它建議
`contradicts` 等於替使用者下一個本 feature 沒有下的判斷。**`link_suggested` 的候選集合因此
是「judge 命中的 target,扣掉同一個 target 已經有 graph 命中的」**。

**只產生 `ReportNote`,絕對不呼叫任何寫入操作**(契約卡的硬邊界,也是 `design.md`
「永不自動修改資料」的直接要求):`checkConflict` 這條路徑上出現的 `ServiceM` 操作只有
`linkGraph` / `aliasIndex` / `searchEntity` / `linksOf` / `getEntity`(最後兩個在第 2、3 層),
全部是讀取。

### 六、REST:`POST /conflict/check`

```haskell
-- | @POST \/conflict\/check@ 的 body。
data CheckReq = CheckReq
  { ckDraft :: Draft
  , ckOpts  :: ConflictOpts   -- ^ 缺席退回 defaultConflictOpts,與 ContextReq 同一個待客之道
  , ckNoLlm :: Bool           -- ^ 缺席退回 False。遠端模式的 --no-llm 靠它過去
  }
```

JSON 鍵:`draft`(必填)/ `opts`(選配)/ `no_llm`(選配)。`ToJSON` 三個鍵都輸出,
`FromJSON` 只有 `draft` 必填——與 `ContextReq` 逐字同一種寫法。

`ToSchema CheckReq` 與它的 `ToJSON` / `FromJSON` 一起放在 `StoryFlow.Api`
(不是 `Api.Instances`):`ContextReq` 就是這樣放的,理由也一樣——`Api.Instances` 是
`StoryFlow.Api` 的**上游**,實例寫過去會造成模組環(F004 A8)。

**新增三個孤兒 `ToSchema` 進 `Api.Instances`**:`ConflictHit` / `ReportNote` /
`ConflictReport`。這三個**真的會進 `components.schemas`** ——`POST /conflict/check` 的回應
型別是 `ConflictReport`,它 `$ref` 到 `ConflictHit`,`ConflictHit` `$ref` 到 `HitLayer`。
這正是 F004 A9 那條裁定的另一半:**不為了讓某個型別出現在 components 就強制登記它**,
但路由真的觸得到的就該進去。`GraphEvidence` 仍然**不會**出現(`HitLayer` 的 wire 形狀是
攤平的,沒有任何 `$ref` 指向它),它的 `ToSchema` 實例照 F004 的裁定保留給 `SchemaSpec` 對帳。

路由**唯讀,沒有 `revision`**:整條路徑只讀不寫,樂觀鎖在這裡沒有意義,收一個不參與判斷的
必填參數就是說謊(同 `POST /conflict/context`)。方法是 `POST` 因為草稿是一段長文字,
塞不進 query parameter。

`ConflictAPI` 因此變成兩條:

```haskell
type ConflictAPI =
  "conflict" :> "context" :> Summary "…" :> ReqBody '[JSON] ContextReq :> Post '[JSON] [ContextHit]
    :<|> "conflict" :> "check" :> Summary "三層合流的衝突報告(第 3 層拿不到端點時退化成兩層)"
      :> ReqBody '[JSON] CheckReq
      :> Post '[JSON] ConflictReport
```

server 的 `conflictH` 跟著變成兩個 handler,**兩個都是一行結構**:

```haskell
conflictH st =
  (\ContextReq {..} -> run1 st (gatherContext crqOpts crqDraft))
    :<|> (\CheckReq {..} -> run1 st (checkConflictFor ckNoLlm ckOpts ckDraft))
```

`checkConflictFor` 存在的價值就在這一行:讀設定、建 client、跑三層全在 `storyflow-conflict`
裡,server 與 CLI 各自不必再寫一次(寫兩次就會長歪,那是 F004 那條「渲染器只有一份」的
同一個論證)。**`storyflow-server` / `storyflow-api` / `storyflow-cli` 因此都不必新增
`storyflow-llm` 相依**——`LlmClient` 一次都不出現在它們的型別裡。

**數字會變**:REST 路徑 15 → **16**、operation 24 → **25**。程式碼與測試照新數字改
(T7),`system.md` 與兩份 `design.md` 由編排者回寫(見 A9 與回報)。

### 七、CLI:`story-flow conflict check`

**`conflict` 是子指令群,`context` 是頂層名詞**——這不是不一致,是 `Options.hs` 既有註解
已經解釋過的立場:`context` 是給外部 Agent 用的日常入口(與 `search` 同一種形狀),
而 `conflict` 這個名詞底下放的是「做判斷」的那一組。本 feature 照那個立場做,
`conflict` 底下目前只有 `check` 一個動詞。

```haskell
data Command
  = …
  | -- | @conflict check --draft \<檔案|-\>@:草稿來源、已引用的片段、五欄選項、--no-llm。
    ConflictCheck BodySource [Id] ConflictOpts Bool
```

旗標面:

| 旗標 | 對應 | 說明 |
|---|---|---|
| `--draft <檔案\|->` | `BodySource` | **必填**,沒有預設。`-` 解成 stdin,其餘當檔案路徑;走既有的 `readBody`(UTF-8 強制解碼與「讀不到檔」的訊息都與 `entity set-body` / `context --for` 同一份)。**名字是 `--draft` 不是 `--for`**:契約卡逐字寫的就是 `--draft`,而 `context` 那一條逐字寫的是 `--for` |
| `--ref <id>`(可重複) | `drRefs` | 沒有它 `drRefs` 就是空的,**第 1 層在 `conflict check` 上永遠不會啟動**——與 F004 A1 是同一個洞的第二次出現。順序保留,解析器與 `context` 那一條共用 |
| `--top-n <n>` | `coTopN` | 第 2 層的候選上限 |
| `--judge-n <n>` | `coJudgeN` | 第 3 層的候選預算。**`context` 刻意不開,`check` 開** |
| `--timeline-window <n>` | `coTimelineWindow` | 不給就不做時序過濾 |
| `--graph-depth <n>` | `coGraphDepth` | 第 1 層反向遍歷深度 |
| `--expand-body` | `coExpandBody` | switch。**`context` 刻意不開,`check` 開**——它是第 3 層才用得到的東西,而本 feature 正是第 3 層的出口 |
| `--no-llm` | `acquireJudge` 的第一個參數 | switch。**不是 `ConflictOpts` 的欄位**:它是「這一次要不要跑」的執行決定,不是三層共用的選項;塞進 `ConflictOpts` 會讓 REST 的 `opts` 與 `no_llm` 兩處都能關掉第 3 層 |

`Options.hs` 既有的 `conflictOptsP` 目前把 `coJudgeN` / `coExpandBody` 兩欄寫死成 `pure`
(F004 實作備註 4 / F005 T3)。本 feature 把它拆成兩個具名解析器,**`context` 那一條的行為
一字不變**:

```haskell
contextOptsP :: Parser ConflictOpts   -- 三欄開旗標,judge 那兩欄用預設值(原 conflictOptsP)
checkOptsP   :: Parser ConflictOpts   -- 五欄全開
```

**`Backend` 多一個操作,兩路分派**(照 `gatherContextB` 的形狀):

```haskell
checkConflictB :: Backend -> Bool -> ConflictOpts -> Draft -> M ConflictReport
checkConflictB (Embedded e) noLlm o d = svc e (checkConflictFor noLlm o d)
checkConflictB (Remote   c) noLlm o d = rmt c (cCheck (CheckReq d o noLlm))
```

由 API 型別產生的 client 多一個 `cCheck :: CheckReq -> ClientM ConflictReport`,
解構鏈的最後一項從 `cContext` 變成 `(cContext :<|> cCheck)` ——少一個、多一個、順序錯了
都是編譯錯誤。

**CLI 子指令數 24 → 25**(F004 A7 已釐清:實際葉子子指令數是 24,不是架構文檔寫的那個
舊數字)。

### 八、人類模式的渲染

```haskell
renderReport :: ConflictReport -> Text
```

三段,順序固定:

```text
target     | via                        | reason                          | snippet
ent-91cc   | graph(contradicts→ent-91cc)| 你引用的 ent-7f3c 與 ent-91cc … | (無)
ent-c41d   | retrieval(0.82)            | 草稿與 ent-c41d 共同出現「琳達」 | ……
ent-8b20   | judge(0.91)                | 兩段對雙親死因的敘述不一致       | ……

掃過 12 個候選;語意判斷:有跑

注意:
  - (judge_budget) 候選 12 個,只有前 5 個送了語意判斷;…
  - (link_suggested) 第 3 層判定 ent-8b20 與草稿矛盾;確認成立後…
```

- **`via` 欄直接重用 `Cli.Render.renderVia`**(F004 已經有了):標籤走
  `Conflict.Types.layerTag`,分數固定兩位小數。「命中層級必須標示出來」這條驗收標準在人類
  模式裡就是這一欄,而且**兩種模式講的是同一個詞**
- **`crHits` 為空**時第一段印 `(沒有發現衝突)`,不印空表頭。第二、三段照印——
  「沒有發現衝突」在 `crLlmUsed = False` 時的份量完全不同,而那正是第二段要說的事
- **`chSnippet` 為 `Nothing`**(第 1 層恆為 `Nothing`)印 `(無)`;
  snippet 走既有的 `oneLine`(把換行壓成空白),表格才不會歪
- **注意事項印 `rnCode`**:它是穩定識別碼,使用者要查、要 grep、要回報 issue 的時候靠它;
  `rnDetail` 則是那一句繁中的下一步。`crNotes` 為空時整段不印
- `--json` 走既有的統一信封,`data` 就是 `ConflictReport` 的 `ToJSON`(F005 已經有了),
  **CLI 不重新編碼**

**exit code 是 0**,即使報告裡有命中:這是一份報告,不是一個判定。命中是不是真的衝突由作者
決定(`design.md`「永不自動修改資料」的同一個立場)。失敗(讀不到草稿、Vault 開不起來)
仍然照既有規則走 exit 1 / 2。

### 九、hermetic 測試的形狀(D6)

`cabal test all` **不得依賴任何外部端點、不得打網路**。三層合流的四個關鍵行為分別怎麼在零
網路下觸發:

| 行為 | 觸發方式 |
|---|---|
| 三層合流與排序 | `JudgeWith` 塞假 runner(回預先排好的 JSON),在臨時 Vault 上跑 `checkConflictWith` |
| 三種退化 | `JudgeSkipped SkipDisabled` / `SkipNotConfigured LlmConfigMissing` / `SkipUnreachable (LlmUnavailable …)` 直接餵給 `checkConflictWith` |
| 端點連不上的升格 | 假 runner **第一次呼叫就回 `Left (LlmUnavailable …)`** → `judge_aborted` 應該被換成 `judge_unreachable` |
| 部分失敗保留已成功的 | 假 runner 回 `[Right 矛盾, Left (LlmHttpStatus 500 …), Right 矛盾]` |

`acquireJudge` 的三條分支也全部測得到而不必有端點:分支 1、2 不碰網路;分支 3 只呼叫
`newLlmClient`(**建一個 `Manager`,不發任何請求**),斷言它回的是 `JudgeWith`
即可——臨時 Vault 的 `config.toml` 寫一個 `base_url = "http://127.0.0.1:1"` 就夠,
測試**不呼叫 `chat`**。

真端點的驗收由編排者在階段閘門另外跑(D6),不進 `cabal test all`。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `gatherContext :: ConflictOpts -> Draft -> ServiceM [ContextHit]` | `conflict/src/StoryFlow/Conflict/Pipeline.hs` | F004 | 出口 A,本 feature **不改它**;出口 B 加在同一個模組 |
| `graphContextHits :: ConflictOpts -> Draft -> ServiceM [ContextHit]` | `conflict/src/StoryFlow/Conflict/Pipeline.hs` | F004 | **本 feature 不呼叫**(出口 B 不補 `Meta`);列出以標明兩條路徑的差別 |
| `sortContextHits :: [ContextHit] -> [ContextHit]`(排序鍵 `(層級序, Down 分數, metaId)`) | `conflict/src/StoryFlow/Conflict/Pipeline.hs` | F004 | `sortConflictHits` 照它的形狀做(全序、三鍵) |
| `mergeContextHits :: [ContextHit] -> [ContextHit]` | `conflict/src/StoryFlow/Conflict/Pipeline.hs` | F004 | 去重/合併的既有形狀;`mergeConflictHits` 的勝負規則**方向相反**,理由見 A4 |
| `graphHits :: ConflictOpts -> LinkGraph -> [Id] -> [ConflictHit]` | `conflict/src/StoryFlow/Conflict/Graph.hs` | F002 | 第 1 層命中(`ByGraph`、`chSnippet = Nothing`) |
| `unlinkedRefs :: LinkGraph -> [Id] -> [Id]` | `conflict/src/StoryFlow/Conflict/Graph.hs` | F002 | **本 feature 是它的第一個生產程式碼消費者** → `graph_unlinked_refs` |
| `retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | 第 2 層 |
| `data RetrievalResult = RetrievalResult { rrCandidates :: [Candidate], rrScanned :: Int, rrKeywords :: [Text] }` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | `rrCandidates` 進第 3 層與合流;`rrScanned` → `crScanned` |
| `data Candidate = Candidate { caMeta :: Meta, caSnippet :: Text, caScore :: Double, caOrigin :: CandidateOrigin }` | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | 第 3 層的輸入 |
| `candidateConflictHit :: Candidate -> ConflictHit`(`chSnippet` 恆為 `Just`) | `conflict/src/StoryFlow/Conflict/Retrieval.hs` | F003 | 候選 → 第 2 層命中,**F003 就是為本 feature 的合流留的** |
| `judgeCandidatesWith :: JudgeRunner ServiceM -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | 第 3 層的實際入口(監看 runner 套在它外面) |
| `judgeCandidates :: LlmClient -> ConflictOpts -> Draft -> [Candidate] -> ServiceM JudgeResult` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | **本 feature 不直接呼叫**:要監看 `LlmUnavailable` 才升格得出 `judge_unreachable`,所以走 `judgeCandidatesWith` + `llmRunner`(見 A2) |
| `type JudgeRunner m = [Message] -> m (Either LlmError Text)` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | `JudgeStage` 的 `JudgeWith` 帶的就是它;測試的注入點 |
| `llmRunner :: LlmClient -> JudgeRunner ServiceM` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | 唯一真的呼叫 `chat` 的地方 |
| `data JudgeResult = JudgeResult { jrHits :: [ConflictHit], jrJudged :: Int, jrNotes :: [ReportNote] }` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | `crHits` / `crLlmUsed`(`jrJudged > 0`)/ `crNotes` |
| `data JudgeSkip = SkipDisabled \| SkipNotConfigured LlmError \| SkipUnreachable LlmError` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | 三種退化原因的詞彙,**選用哪一個是本 feature 的決定**(F005 A1) |
| `skipNote :: JudgeSkip -> ReportNote` | `conflict/src/StoryFlow/Conflict/Judge.hs` | F005 | 三則退化 note 的文案來源,**不重寫** |
| `data ConflictHit = ConflictHit { chTarget :: Id, chLayer :: HitLayer, chReason :: Text, chSnippet :: Maybe Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | `crHits` 的元素 |
| `data HitLayer = ByGraph GraphEvidence \| ByRetrieval Double \| ByJudge Double` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 去重槽與排序的依據 |
| `data GraphEvidence = GraphEvidence { geFrom :: Id, geKind :: LinkKind, geTo :: Ref }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 第 1 層去重鍵的三欄 |
| `sortHits :: [ConflictHit] -> [ConflictHit]`(層級 → 分數遞減,穩定排序) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | **主鍵的唯一約定處**;`sortConflictHits` 疊在它上面補全序 |
| `data ConflictReport = ConflictReport { crHits :: [ConflictHit], crScanned :: Int, crLlmUsed :: Bool, crNotes :: [ReportNote] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001(F005 加了 `crNotes`) | 出口 B 的回傳型別 |
| `data ReportNote = ReportNote { rnCode :: Text, rnDetail :: Text }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001(F005 加) | 三種來源共用的附帶訊息 |
| `emptyReport :: ConflictReport`(四欄都空) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 空輸入的基準;測試的對照 |
| `data ConflictOpts = ConflictOpts { coTopN :: Int, coJudgeN :: Int, coExpandBody :: Bool, coTimelineWindow :: Maybe Int, coGraphDepth :: Int }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001(F005 加 `coJudgeN`) | 五欄全部由 CLI 旗標可調 |
| `defaultConflictOpts :: ConflictOpts`(`20 / 5 / False / Nothing / 2`) | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | CLI 旗標的預設值、REST `opts` 缺席的退路 |
| `data Draft = Draft { drText :: Text, drRefs :: [Id] }` | `conflict/src/StoryFlow/Conflict/Types.hs` | F001 | 出口的輸入 |
| `instance ToJSON ConflictReport` / `FromJSON ConflictReport`(`hits` / `scanned` / `llm_used` / `notes`) | `conflict/src/StoryFlow/Conflict/Json.hs` | F001(F005 加 `notes`) | REST 回應與 CLI `--json`,**本 feature 不改** |
| `llmConfig :: ServiceM (Either LlmError LlmConfig)` | `llm/src/StoryFlow/Llm/Config.hs` | llm-workshop-mcp/F001 | `acquireJudge` 分支 2 的判斷依據 |
| `newLlmClient :: LlmConfig -> IO LlmClient`(**全函式**) | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | `acquireJudge` 分支 3;不包 `try` |
| `data LlmError = LlmUnavailable Text \| LlmHttpStatus Int Text \| LlmBadResponse Text \| LlmConfigMissing \| LlmConfigInvalid Text` | `llm/src/StoryFlow/Llm/Error.hs` | llm-workshop-mcp/F001 | 退化原因的分類;監看只認 `LlmUnavailable` |
| `renderLlmError :: LlmError -> Text` | `llm/src/StoryFlow/Llm/Error.hs` | llm-workshop-mcp/F001 | 經 `skipNote` 進 `rnDetail`,**不重寫下層訊息** |
| `data LlmClient`(不透明,無匯出建構子) | `llm/src/StoryFlow/Llm/Client.hs` | llm-workshop-mcp/F001 | `checkConflict` 的契約參數;**不透明正是 `JudgeStage` 存在的理由** |
| `linkGraph :: ServiceM LinkGraph` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 第 1 層的圖,**一次呼叫同時餵 `graphHits` 與 `unlinkedRefs`** |
| `vaultConfig :: ServiceM VaultConfig`(`asks (vaultCfg . envVault)`) | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | **本 feature 不直接呼叫**;列出以說明 `llmConfig` 不碰 IO |
| `newtype ServiceM a`(`MonadIO` / `MonadError ServiceError` / `MonadReader Env`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `MonadIO` 讓 `newLlmClient` 與監看用的 `IORef` 抬得進來 |
| `renderId :: Id -> Text` / `renderRef :: Ref -> Text` / `renderLinkKind :: LinkKind -> Text` | `core/src/StoryFlow/Core/Id.hs`、`Link.hs` | entity-graph-core/F002 | 去重槽的字串鍵與 note 文案 |
| `data ContextReq = ContextReq { crqDraft :: Draft, crqOpts :: ConflictOpts }`(+`ToJSON`/`FromJSON`/`ToSchema` 都在 `Api.hs`) | `api/src/StoryFlow/Api.hs` | F004 | `CheckReq` 的範本,逐字照抄它的放法 |
| `type ConflictAPI = "conflict" :> "context" :> Summary … :> ReqBody '[JSON] ContextReq :> Post '[JSON] [ContextHit]` | `api/src/StoryFlow/Api.hs` | F004 | 本 feature 在它上面 `:<|>` 第二條 |
| `objSchema :: Text -> [(Text, Referenced Schema)] -> [Text] -> Schema` / `named :: Text -> Schema -> NamedSchema` | `api/src/StoryFlow/Api/Instances.hs` | service-and-interfaces/F003 | 三個新 `ToSchema` 的寫法 |
| `instance ToSchema HitLayer`(聯集物件,`required = ["layer"]`) | `api/src/StoryFlow/Api/Instances.hs` | F004 | `ConflictHit` 的 `layer` 欄 `$ref` 到它 |
| `instance ToSchema GraphEvidence` | `api/src/StoryFlow/Api/Instances.hs` | F004 | **仍然不進 components**(F004 A9 的裁定不變) |
| `run1 :: AppState -> ServiceM a -> Handler a` | `server/src/StoryFlow/Server/State.hs` | service-and-interfaces/F003 | `checkH` 走它(需要目前 Vault 的 `Env`) |
| `conflictH :: AppState -> Server ConflictAPI` | `server/src/StoryFlow/Server.hs` | F004 | 本 feature 把它從一個 handler 變成兩個 |
| `gatherContextB :: Backend -> ConflictOpts -> Draft -> M [ContextHit]` | `cli/src/StoryFlow/Cli/Backend.hs` | F004 | `checkConflictB` 的範本(兩路分派) |
| `data Backend = Embedded Env \| Remote ClientEnv` | `cli/src/StoryFlow/Cli/Backend.hs` | service-and-interfaces/F002 | 兩條執行路徑 |
| `contextP :: Parser Command`(`Context <$> forP <*> many refOpt <*> conflictOptsP`) | `cli/src/StoryFlow/Cli/Options.hs` | F004 | `conflict check` 的範本;`refOpt` 直接共用 |
| `conflictOptsP :: Parser ConflictOpts`(三欄開旗標,`coJudgeN` / `coExpandBody` 走 `pure`) | `cli/src/StoryFlow/Cli/Options.hs` | F004 / F005 | 拆成 `contextOptsP`(行為一字不變)與 `checkOptsP`(五欄全開) |
| `renderContext :: [ContextHit] -> Text` | `cli/src/StoryFlow/Cli/Render.hs` | F004 | `renderReport` 的範本 |
| `renderVia :: HitLayer -> Text`(`graph(contradicts→ent-91cc)` / `retrieval(0.82)` / `judge(0.91)`) | `cli/src/StoryFlow/Cli/Render.hs` | F004 | **直接重用**,人類模式的「命中層級」就是這一欄 |
| `table :: [Text] -> [[Text]] -> Text`(CJK 全形寬度對齊) | `cli/src/StoryFlow/Cli/Render.hs` | service-and-interfaces/F002 | 命中表格 |
| `readBody :: CliIO -> BodySource -> M Text`(UTF-8 強制解碼) | `cli/src/StoryFlow/Cli.hs` | service-and-interfaces/F002 | `--draft` 的檔案 / stdin 讀取 |
| `data Envelope a = Ok a \| Err Text Text` / `encodeEnvelope` | `cli/src/StoryFlow/Cli/Render.hs` | service-and-interfaces/F002 | `--json` 的統一信封,**CLI 不重新編碼** |
| `conflictRoutes :: [(Text, Text)]`(F004 A11 刻意拆出來的獨立表) | `api/test/StoryFlow/Api/ApiSpec.hs` | F004 | 加一列,**既有 23 條一字不動** |

> 上表每一列的簽名都是從來源檔案讀出的**原文**。

## 新增的介面

### `StoryFlow.Conflict.Pipeline`(F004 的模組,本 feature 加出口 B)

```haskell
module StoryFlow.Conflict.Pipeline
  ( -- * 出口(Level 2 對外契約)
    gatherContext
  , checkConflict

    -- * 接線層(CLI / REST 共用同一份)
  , checkConflictFor
  , checkConflictWith
  , JudgeStage (..)
  , acquireJudge

    -- * 中間結果(供測試使用)
  , graphContextHits
  , graphStage
  , mergeContextHits
  , sortContextHits
  , mergeConflictHits
  , sortConflictHits
  , unlinkedNote
  , budgetNote
  , suggestionNote
  ) where

-- | 第 3 層要怎麼跑:退化(帶原因),或用一個 runner 跑。
--
-- 一個接縫同時服務接線層與測試:接線層給 @llmRunner client@,測試給假 runner
-- ——'StoryFlow.Llm.LlmClient' 是不透明型別,造不出指向假端點的實例。
data JudgeStage
  = JudgeSkipped JudgeSkip
  | JudgeWith (JudgeRunner ServiceM)

-- | Level 2 的對外契約,簽名逐字相同。
--   @Nothing@ = 呼叫端沒有給 client,一律當成 --no-llm(SkipDisabled)。
checkConflict :: Maybe LlmClient -> ConflictOpts -> Draft -> ServiceM ConflictReport

-- | 三層合流的本體:第 1 層 + 第 2 層 + 第 3 層 → 去重 → 排序 → ConflictReport。
checkConflictWith :: JudgeStage -> ConflictOpts -> Draft -> ServiceM ConflictReport

-- | 接線層的一行(Bool = --no-llm)。CLI 與 server 各呼叫一次同一份。
checkConflictFor :: Bool -> ConflictOpts -> Draft -> ServiceM ConflictReport

-- | 讀 [llm] 設定並建 client,或決定退化原因。
--   --no-llm 或 coJudgeN <= 0 時__不讀設定、不建 client__。
acquireJudge :: Bool -> ConflictOpts -> ServiceM JudgeStage

-- | 第 1 層在 check 這條路上的產物:命中(不補 Meta)與完全沒有關聯的起點。
--   __linkGraph 只取一次__,兩個問題共用同一張圖。
graphStage :: ConflictOpts -> Draft -> ServiceM ([ConflictHit], [Id])

-- | 依 (chTarget, 去重槽) 去重後排序。ByGraph 的槽是整條證據,
--   ByRetrieval / ByJudge 共用一個槽且 ByJudge 勝出。
mergeConflictHits :: [ConflictHit] -> [ConflictHit]

-- | 全序:層級 → 分數遞減 → chTarget → 去重槽。主鍵走 F001 的 sortHits。
sortConflictHits :: [ConflictHit] -> [ConflictHit]

-- | 第 1 層:草稿引用了但沒有任何本地關聯的片段。空清單 → Nothing。
unlinkedNote :: [Id] -> Maybe ReportNote

-- | 第 3 層:候選數超過 coJudgeN 預算時,說出「其餘的沒有第 3 層的結論」。
budgetNote :: ConflictOpts -> Int -> Maybe ReportNote

-- | 關聯建議:只針對 ByJudge 的命中,且扣掉已經有 ByGraph 命中的 target。
suggestionNote :: [ConflictHit] -> Maybe ReportNote
```

`rnCode` 新增三個(F005 的六個 `judge_*` 不動):

| `rnCode` | 來源 |
|---|---|
| `graph_unlinked_refs` | 第 1 層 |
| `judge_budget` | 第 3 層的預算截斷 |
| `link_suggested` | 關聯建議 |

### `StoryFlow.Api`

```haskell
-- | @POST \/conflict\/check@ 的 body。opts 與 no_llm 都可以缺席。
data CheckReq = CheckReq
  { ckDraft :: Draft
  , ckOpts  :: ConflictOpts
  , ckNoLlm :: Bool
  }
  deriving stock (Show, Eq)

instance ToJSON   CheckReq   -- {"draft": …, "opts": …, "no_llm": false}
instance FromJSON CheckReq   -- 只有 draft 必填
instance ToSchema CheckReq   -- 與 ContextReq 同一處(模組環,F004 A8)

type ConflictAPI =
  "conflict" :> "context" :> … :> Post '[JSON] [ContextHit]
    :<|> "conflict"
      :> "check"
      :> Summary "三層合流的衝突報告(第 3 層拿不到端點時退化成兩層,不讓指令失敗)"
      :> ReqBody '[JSON] CheckReq
      :> Post '[JSON] ConflictReport
```

### `StoryFlow.Api.Instances`(孤兒 `ToSchema`,路由真的觸得到)

```haskell
instance ToSchema ConflictHit     -- target / layer($ref HitLayer) / reason / snippet
instance ToSchema ReportNote      -- code / detail
instance ToSchema ConflictReport  -- hits / scanned / llm_used / notes
```

### `StoryFlow.Cli.Options` / `Backend` / `Render`

```haskell
data Command = … | ConflictCheck BodySource [Id] ConflictOpts Bool

contextOptsP :: Parser ConflictOpts   -- 原 conflictOptsP,行為一字不變
checkOptsP   :: Parser ConflictOpts   -- 五欄全開

checkConflictB :: Backend -> Bool -> ConflictOpts -> Draft -> M ConflictReport

renderReport :: ConflictReport -> Text   -- 命中表格 + 摘要行 + 注意事項
```

**不新增任何套件相依**:`storyflow-conflict` 的 `build-depends` 一字不動
(`storyflow-llm` 自 F005 起就在了);`storyflow-api` / `-server` / `-cli` 也一字不動
——`LlmClient` 一次都不出現在它們的型別裡。`IORef` 在 `base`。
**不新增任何模組**:出口 B 住在既有的 `Conflict.Pipeline`。

## TodoList

- [x] T1: `Conflict.Pipeline` 加 `graphStage`:`linkGraph` **取一次**,同時餵 `graphHits` 與 `unlinkedRefs`;第 1 層命中**不補 `Meta`**(出口 B 的 `ConflictHit` 只要 `Id`) `dep: F002, F004`
- [x] T2: `mergeConflictHits` / `sortConflictHits` 兩個純函式:去重槽(`ByGraph` 帶整條證據、`ByRetrieval`/`ByJudge` 共用一槽且 judge 勝出)、排序疊在 F001 的 `sortHits` 上補成全序 `dep: T1`
- [x] T3: `unlinkedNote` / `budgetNote` / `suggestionNote` 三個純函式與三個新 `rnCode`;`suggestionNote` 只看 `ByJudge` 且扣掉已有 `ByGraph` 命中的 target `dep: T1`
- [x] T4: `JudgeStage` 型別、`acquireJudge`(三條分支,`--no-llm` 或 `coJudgeN <= 0` 時不讀設定)、`runJudge`(監看 `LlmUnavailable`,`jrJudged == 0` 時把 `judge_aborted` 換成 `judge_unreachable`) `dep: F005`
- [x] T5: 門面 `checkConflictWith` / `checkConflict` / `checkConflictFor`:合流三層、`crScanned = rrScanned`、`crLlmUsed = jrJudged > 0`、`crNotes` 依固定順序組裝;更新 `Conflict.Pipeline` 的模組 haddock(「完全沒有模型」現在是 `gatherContext` 這條路徑的性質,不是整個模組的) `dep: T2, T3, T4`
- [x] T6: `storyflow-api`:`CheckReq`(`ToJSON`/`FromJSON`/`ToSchema` 都在 `Api.hs`)、`ConflictAPI` 加第二條路由;`Api.Instances` 加 `ConflictHit` / `ReportNote` / `ConflictReport` 三個 `ToSchema`;`Api.Fixtures` 補對應樣本(`chSnippet` 用 `Just`,`aligns` 要鍵集合相等) `dep: T5`
- [x] T7: `Api.ApiSpec`:`conflictRoutes` 加 `("/conflict/check", "post")`、`readOnlyRoutes` 加同一條、operation 數 24 → 25(既有 23 條業務路由一字不動);`Api.OpenApiSpec`:paths 15 → 16、ops 24 → 25、`expectedSchemas` 補四個新型別 `dep: T6`
- [x] T8: `storyflow-server`:`conflictH` 拆成 `context` 與 `check` 兩個一行 handler;`server/test/.../Fixtures.hs` 的 client record 24 → 25 個呼叫函式 `dep: T6`
- [x] T9: CLI `Options`:`Command` 加 `ConflictCheck`;`conflict` 子指令群 + `check` 動詞;`--draft`(必填)/ `--ref`(共用 `refOpt`)/ `--no-llm`;`conflictOptsP` 拆成 `contextOptsP`(行為不變)與 `checkOptsP`(五欄全開) `dep: -`
- [x] T10: CLI `Backend`:`cCheck` client 函式(解構鏈最後一項變成 `cContext :<|> cCheck`)與 `checkConflictB` 兩路分派 `dep: T6, T9`
- [x] T11: CLI `Render.renderReport`(命中表格重用 `renderVia` / `table` / `oneLine`、摘要行、注意事項段)+ `StoryFlow.Cli.handle` 接線(`--draft` 走既有 `readBody`,`--json` 走既有信封,exit code 恆為 0) `dep: T10`
- [x] T12: 測試模組註冊與 hermetic 驗證:`conflict/test/Spec.hs` 與 `.cabal` 的 `other-modules` 加 `CheckSpec` / `CheckEnvSpec`;`build-depends` 一字不動;整個測試套件不呼叫 `chat`、不發任何請求 `dep: T5, T11`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `conflict/test/StoryFlow/Conflict/CheckEnvSpec.hs` → `第 1 層在 check 這條路上` | 臨時 Vault:`A contradicts B`、`C supersedes D`、外加一個完全沒有關聯的 `E`。`graphStage opts (Draft "" [a, e])` 的命中含 `B` 且 `chLayer` 是 `ByGraph`(證據三欄正確)、`chSnippet == Nothing`;第二個元素含 `E` 而**不含 `A`**;`drRefs` 為空時兩者都是 `[]`;**斷言整條路徑不補 `Meta`**——用 `createEntity` 的 `nerLinks` 建一條指向**不存在的 id** 的 `contradicts`(F004 實作備註 2 說明過懸空關聯就是這樣出現的),`graphStage` 照樣回得出那筆命中,而同一份 Vault 上的 `graphContextHits` 會把它丟掉 |
| T2 | `conflict/test/StoryFlow/Conflict/CheckSpec.hs` → `合流的去重與排序` | 同一個 target 的兩條 graph 證據(contradicts + supersedes)**不被合併**;同一個 target 的 retrieval + judge **合併成一筆且留下 judge**(`chReason` 是模型原話、`chSnippet` 是 judge 那一筆);排序結果逐筆等於 `[graph…, retrieval 高分, retrieval 低分, judge…]`;同分同層時依 `chTarget` 字典序;**打亂輸入順序跑兩次,輸出逐筆相同**(全序) |
| T3 | 同檔 → `crNotes 的三種來源` | `unlinkedNote [] == Nothing`;`unlinkedNote [a, b]` 的 `rnCode == "graph_unlinked_refs"` 且 `rnDetail` 含兩個 `renderId`;`budgetNote` 在 `候選 <= coJudgeN` 或 `coJudgeN <= 0` 時是 `Nothing`,超過時 `rnCode == "judge_budget"` 且 detail 說得出「不是判定為沒有矛盾」;`suggestionNote` 對只有 graph / 只有 retrieval 的命中回 `Nothing`,對有 judge 命中的回 `link_suggested` 且 detail 含 `contradicts` 與該 target 的 id,**已經有 graph 命中的 target 不出現在建議裡** |
| T4 | 同檔 + `CheckEnvSpec.hs` → `第 3 層的三種退化與連不上的升格` | `JudgeSkipped` 三個建構子分別產出 `judge_disabled` / `judge_not_configured` / `judge_unreachable`,**三個 code 兩兩不同**,後兩者的 detail 含 `renderLlmError` 的內容;候選為空時**不產生**退化 note;假 runner 第一次就回 `Left (LlmUnavailable …)` → `crNotes` 含 `judge_unreachable` 且**不含** `judge_aborted`、`crLlmUsed == False`;第三對才連不上(前兩對成功)→ 保留 `judge_aborted`、**不升格**、`crLlmUsed == True`;`acquireJudge True opts` 與 `acquireJudge False opts {coJudgeN = 0}` 都回 `JudgeSkipped SkipDisabled` 且**沒有 `[llm]` 段的 Vault 也不會變成 `judge_not_configured`**;沒有 `[llm]` 段時 `acquireJudge False opts` 回 `JudgeSkipped (SkipNotConfigured LlmConfigMissing)`;有合法 `[llm]` 段時回 `JudgeWith`(**不呼叫 `chat`**) |
| T5 | `CheckEnvSpec.hs` → `三層合流的門面` | 臨時 Vault + 假 runner:報告同時含三層的命中;`crScanned == rrScanned`(與直接呼叫 `retrieveCandidates` 的值相等);`crLlmUsed` 在「至少一對成功」時 `True`、在「全部解析失敗」時 `False`(此時 `crNotes` 有 `judge_parse_failed`);`checkConflict Nothing` 等價於 `checkConflictWith (JudgeSkipped SkipDisabled)`;空草稿 + 空 `drRefs` 回 `crHits == []` 且不報錯;**note 順序**逐筆等於「第 1 層 → 第 3 層 → budget → suggestion」;整條路徑**沒有任何寫入**(跑完後 `linksOf` 的結果與跑之前逐筆相同) |
| T6 | `api/test/StoryFlow/Api/SchemaSpec.hs` → `ConflictHit` / `ReportNote` / `ConflictReport` / `CheckReq` | 四個型別各一條 `aligns`(`ToJSON` 的鍵集合與 `ToSchema` 的 `properties` 相等);`CheckReq` 的 `required` 只有 `draft`;`api/test/.../HttpDataSpec.hs` 補「`opts` 與 `no_llm` 都缺席時退回 `defaultConflictOpts` 與 `False`」與 `CheckReq` 的 round-trip |
| T7 | `api/test/StoryFlow/Api/ApiSpec.hs` + `OpenApiSpec.hs` → `路由與文件的數字` | `length allOperations == 25`;`conflictRoutes` 恰兩列且 `expectedRoutes` 與實際路由排序後相等;`/conflict/check` 的 post **沒有 `revision` 參數**;`IOM.size (doc ^. paths) == 16`;`components.schemas` 含 `CheckReq` / `ConflictHit` / `ReportNote` / `ConflictReport`,**仍然不含 `GraphEvidence`**(F004 A9 的裁定不變);新 operation 有非空 `summary` |
| T8 | `server/test/StoryFlow/Server/HandlerSpec.hs` → `POST /conflict/check` | 沒有 `[llm]` 段的臨時 Vault:`no_llm = False` 時回 200、`llm_used == False`、`notes` 含 `judge_not_configured`(**指令沒有失敗**);`no_llm = True` 時 `notes` 含 `judge_disabled`;`opts` 缺席的 body 解得出來且行為等同 `defaultConflictOpts`;報告裡有第 1、2 層的命中且 `layer` 標籤正確 |
| T9 | `cli/test/StoryFlow/Cli/OptionsSpec.hs` → `conflict check 的旗標面` | `conflict check --draft d.md` 解得出 `ConflictCheck (BodyFile "d.md") [] defaultConflictOpts False`;`--draft -` 解成 `BodyStdin`;`--ref` 兩次順序保留、不合法 id 的錯誤訊息說得出格式;五個旗標各給一次時五欄都對得上;`--expand-body` 與 `--no-llm` 是 switch;**缺 `--draft` 時解析失敗且訊息含 `draft`**;`context` 那一條的既有斷言**一字不改仍通過**(含「`--judge-n` 讓 `context` 解析失敗」) |
| T10 | `cli/test/StoryFlow/Cli/RemoteCmdSpec.hs` → `conflict check 的遠端路徑` | 對真的跑起來的伺服器發 `--remote conflict check`,回得出與內嵌模式相同的報告;`--no-llm` 真的傳到伺服器(回應的 `notes` 是 `judge_disabled` 而不是 `judge_not_configured`) |
| T11 | `cli/test/StoryFlow/Cli/RenderSpec.hs` → `renderReport` | 三層各一筆的報告:`via` 欄逐字等於 `renderVia` 的輸出;`chSnippet == Nothing` 印 `(無)`;`crHits` 為空印 `(沒有相關的片段)` 以外的固定字串 `(沒有發現衝突)` 且摘要行照印;摘要行含 `crScanned` 的數字與「有跑 / 沒有跑」;`crNotes` 為空時**不印**「注意」段,非空時每則一行且含 `rnCode`;snippet 裡的換行被壓成空白(表格不歪) |
| T12 | `conflict/test/Spec.hs` + `cli/test/StoryFlow/Cli/EndToEndSpec.hs` → `hermetic 與兩種模式對照` | `Spec.hs` 註冊 `CheckSpec` / `CheckEnvSpec`;整個 `storyflow-conflict` 測試套件裡 `chat` 出現 0 次(grep 斷言),`cabal test all` 在**沒有任何端點在跑**的機器上全綠;端到端:同一個臨時 Vault、同一份草稿,內嵌與 `--remote` 兩種形式的 stdout 與 `--json` 信封**逐字元相等**,而且**空報告那一組也要相等** |

## 待確認假設

- A1: Level 2 的 `checkConflict :: Maybe LlmClient -> …` 用 `Nothing` 表達「不跑第 3 層」,但
  `Nothing` **帶不出三種退化原因的差別**,而同一份 `design.md` 又明令三者要是三個不同的
  `rnCode` → 採取:**契約簽名一字不改地保留並實作**(`Nothing` = `--no-llm` = `SkipDisabled`,
  與「特別注意 5」一致),接線層改走同一個模組裡的 `checkConflictFor` / `checkConflictWith`
  ——與 F003 的 `retrieveCandidates` / `retrieveCandidatesWith`、F005 的 `judgeCandidates` /
  `judgeCandidatesWith` 是同一種「門面 + 接縫」形狀 → 影響:代價是 `checkConflict` 這個**契約
  函式在生產路徑上沒有呼叫端**(只有測試),正是 `unlinkedRefs` 那種味道。若編排者要消除它,
  合理的修法是把 Level 2 的契約簽名改成帶得出原因的形狀(例如 `Either JudgeSkip LlmClient`,
  或直接把 `checkConflictFor` 的 `Bool` 版本升格為契約),那是 **Level 2 契約變更,本 feature
  不擅自做**
- A2: 「端點連不上」要怎麼變成 `judge_unreachable`。F005 的 `judgeLoop` 遇到 `LlmUnavailable`
  只會記 `judge_aborted`,而且**不把 `LlmError` 帶出來**;`newLlmClient` 又是全函式,建 client
  這一步不會失敗 → 採取:用一個**監看用的 runner** 記下 `LlmUnavailable`(`IORef`,在 `base`),
  `jrJudged == 0` 時把 `judge_aborted` 那一則換成 `skipNote (SkipUnreachable e)`,
  `jrJudged > 0` 時不換 → 影響:若編排者認為 `judge_aborted` 已經足以表達「連不上」,
  刪掉監看與升格即可(`runJudge` 退回直接呼叫 `judgeCandidates`,T4 的兩條斷言跟著改),
  代價是使用者看不到 `renderLlmError` 那句「請確認地端服務有沒有在跑」的下一步
- A3: `crHits` 要不要含第 2 層的 `ByRetrieval` 命中——它們是「相關」不是「矛盾」,全放進來會
  讓報告看起來像 `context` → 採取:**含**。依據有三:`design.md` 的資料流寫「三層合流」;
  `sortHits` / `sortContextHits` 的層級序涵蓋三層;而 F003 特地匯出了
  `candidateConflictHit` 並註明「給三層合流用」——那個函式除了本 feature 沒有別的消費者 →
  影響:若要改成「只回第 1、3 層的命中」,`checkConflictWith` 少一段 `map
  candidateConflictHit` 即可,但 `--no-llm` 的報告會變成永遠只有第 1 層,而 `crScanned` 也就
  失去了「判斷 top-N 夠不夠」的用處
- A4: 同一個 target 同時被第 2 層與第 3 層命中時,合併留哪一筆。F004 的
  `mergeContextHits` 留的是**層級較前**的那一筆(graph),照抄的話會留下 retrieval 而丟掉
  judge 的理由 → 採取:**留 `ByJudge`**(方向與 F004 相反)。那一邊問的是「為什麼撈到你」,
  這一邊問的是「這一筆對矛不矛盾說了什麼」,而只有 judge 說得出來;`chSnippet` 也留 judge 的
  (F005:使用者複核模型判斷時看到的必須是模型看到的東西)→ 影響:若要兩筆都留,
  去重槽改成 `(chTarget, layerTag)` 即可,代價是每一個被判定矛盾的片段在報告裡出現兩次
- A5: 契約卡說第 3 層送的是「**合流排序後**的前 `coJudgeN` 個候選」,但第 1 層的命中是
  `ConflictHit`(沒有 `Meta`,拿不到 summary / body),送不進 prompt,而且它們是**事實**、
  不需要模型複判 → 採取:第 3 層吃的是**第 2 層排序後**的 `rrCandidates`,`take coJudgeN` 沿用
  F005 的 `resolveTargets`(與 F005 A5 的裁定一致)→ 影響:若第 1 層的命中也該送模型複判,
  第 3 層要改吃 `[(ConflictHit, Meta)]`,`resolveTargets` 的簽名、F005 的 T7 與本 feature 的
  T4 / T5 全部跟著改
- A6: `judge_budget` 這則 note 不在契約卡列的三種來源裡 → 採取:**加**。理由是不加的話,
  候選 12 個而 `--judge-n 5` 的報告裡會有 7 筆 `ByRetrieval` 的列,使用者分不出它們是「模型
  判定不矛盾」還是「根本沒送」,而這兩件事的份量完全不同;它仍然屬於契約卡的第 (a) 類
  (第 3 層的「部分」覆蓋)→ 影響:若編排者認為這是範圍蔓延,刪掉 `budgetNote` 與 T3 / T5 的
  對應斷言即可,其餘不動
- A7: `--no-llm` 要不要變成 `ConflictOpts` 的第六欄 → 採取:**不要**。它是「這一次要不要跑」
  的執行決定,不是三層共用的選項;塞進 `ConflictOpts` 會讓 REST 的 `opts.no_llm` 與
  `CheckReq.no_llm` 兩處都能關掉第 3 層,而 `ConflictOpts` 的 JSON 是 `context` 也在用的
  → 影響:若編排者要它進 `ConflictOpts`,`CheckReq` 少一欄、`acquireJudge` 少一個參數,
  但 `Conflict.Json` 的 `ConflictOpts` 編碼會多一個 `context` 用不到的鍵,而那正是 F004 / F005
  兩次都拒絕過的事(「給一個沒有作用的旗標只會讓人以為有作用」)
- A8: `Conflict.Pipeline` 的模組 haddock 目前逐字寫著「**完全沒有模型**:不 import
  `storyflow-llm`」,而本 feature 讓同一個模組 import 它 → 採取:**把那條性質收窄成
  `gatherContext` 這條路徑的性質**並改寫模組 haddock(出口 A 仍然不呼叫任何 LLM 相關函式,
  這一點由 T5 之外的既有 `PipelineSpec` 整檔跑得完繼續證明)→ 影響:若編排者認為出口 B 該
  住在新模組(例如 `Conflict.Check`),`design.md`「內部模組劃分」那張表要多一列——那是
  Level 2 變更,而契約卡寫的負責模組是 `Conflict.Pipeline`,所以本 feature 照卡做
- A9: 本 feature 讓 REST 路徑 15 → 16、operation 24 → 25、CLI 子指令 24 → 25,而
  `system.md` 與兩份 `design.md` 都寫著舊數字 → 採取:程式碼與測試照新數字改(T7、T9),
  **架構文檔一個字都不改**(委派模式不得寫 `design.md` / `system.md`)→ 影響:編排者需要在
  階段閘門回寫三處:`system.md`「系統對外介面」表的 REST 那一列(「15 條路徑 / 24 個
  operation」)與 MCP 那一列(「24 個 operation」);`service-and-interfaces/design.md` 的
  「15 條路徑、24 個 operation」與「24 個子指令」;以及同檔 `servant-api-server` 契約卡裡
  「第 15 條 `POST /conflict/context` 屬 `conflict-detection/F004`」那一句要補上第 16 條。
  **CLI 子指令數沒有測試釘住**(`OptionsSpec` 是逐指令的解析測試,不是計數),所以那個數字
  只會在文檔裡漂,不會有紅燈提醒

## 實作備註

- `cabal build all`:零 error、零 warning(`-Wall -Wcompat`)。
- `cabal test all`:**10/10 suites PASS、1266 examples、0 failures**
  (起點基準是 10/10、1208 examples;本 feature 淨增 58 個 examples)。
  各 suite:core 166 / md 189 / types 29 / api 71 / service 97 /
  conflict 207 / llm 62 / store 167 / server 66 / cli 212。
  `conflict` 套件從 178 → 207(+29,對應 T1–T5、T12 新增的
  `CheckSpec` / `CheckEnvSpec`);`api` 從 62 → 71(+9,T6/T7);
  `server` 從 63 → 66(+3,T8);`cli` 從 195 → 212(+17,T9–T11)。
- 實測數字(非推算):
  - REST 路徑數 **16**、REST operation 數 **25**
    (`Api.OpenApiSpec`、`Api.ApiSpec` 兩條測試釘住)。
  - CLI 葉子子指令數 **25**(`vault` 3 + `index` 2 + `type` 1 +
    `entity` 7 + 頂層 `search` 1 + `link` 3 + `level` 4 + `node` 2 +
    頂層 `context` 1 + `conflict check` 1 = 25;逐一數過
    `StoryFlow.Cli.Options` 的 `cmd` 定義得出,**沒有測試釘住這個數字**,
    後續若再加子指令容易在文檔裡漂而不會有紅燈提醒,見 A9)。
- hermetic(D6):`conflict/test` 全程用假 `JudgeRunner` 或直接餵 `JudgeStage`,
  未 import 任何 `Network.*` 模組、未呼叫 `newLlmClient` / `chat`;
  `cabal test all` 在沒有任何端點在跑的機器上全綠。
- 三種退化原因(`judge_disabled` / `judge_not_configured` / `judge_unreachable`)
  與 `judge_budget` / `link_suggested` / `graph_unlinked_refs` 三個新
  `rnCode` 均由 `CheckSpec` / `CheckEnvSpec` 逐條釘住,`rnCode` 兩兩不同。
- **待編排者裁決**(見「待確認假設」A1、A9):
  - Level 2 `checkConflict :: Maybe LlmClient -> …` 在生產路徑上沒有呼叫端
    (只有測試呼叫),接線層一律走 `checkConflictFor` / `checkConflictWith`；
    是否要把契約簽名改成帶得出退化原因的形狀,由編排者裁決。
  - `system.md`、`service-and-interfaces/design.md`、
    `conflict-detection/design.md` 三處的 REST 路徑數(15→16)、
    operation 數(24→25)與 CLI 子指令數(24→25)尚未回寫,
    委派模式下本次不動架構文檔,由編排者在階段閘門統一回寫。
