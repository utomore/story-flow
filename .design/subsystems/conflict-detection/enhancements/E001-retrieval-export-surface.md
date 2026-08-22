---
id: E001
type: enhance
title: retrieval-export-surface
description: 收斂 Conflict.Retrieval 的匯出面,讓「換一種候選策略」真的不必動其他兩層
status: open
created: 2026-08-21
updated: 2026-08-22
depends-on: [F003, F005, F006]
related-adr: [ADR-007]
related-feature: [F003]
---

# E001: 收斂 Conflict.Retrieval 的匯出面

## 發現的來源

同一條發現橫跨兩個階段的 arch-audit:

- **階段一 A-3**(2026-08-20):`Conflict.Retrieval` 公開匯出 13 個純函式部件與 6 個調校常數
- **階段二 B-5**(2026-08-21):未處理,匯出面仍為 23 個名字

2026-08-22 走 `/enhance-design` 補完 scope、量化目標、介面變動與 TodoList。

## 現況分析

`conflict-retrieval` 契約卡寫得很清楚:

> 候選撈取策略本身是本模組的**內部抽象**,對外只露「候選」這個結果

而 `design.md` 的「內部模組劃分」把這一點列為第 2 層的設計要點:

> **第 2 層的候選撈取策略刻意設計成可替換**。ADR-007 決定先不做 embedding 語意檢索
> ……但把介面留成「策略」——未來要加只是多一個策略並在排序時合併,不必動其他兩層

`conflict/src/StoryFlow/Conflict/Retrieval.hs`(461 行)實際匯出 **23 個名字**,分五組:
門面 5、策略接縫 2、輸出轉換 3、純函式部件 7、調校常數 6。

### 逐名清點實際消費者(2026-08-22 讀原始碼所得)

`production` 欄指 `Retrieval.hs` **以外的 `src/`**:

| 名字 | production | 測試 |
|---|---|---|
| `retrieveCandidates` | `Pipeline.hs:128` | 有 |
| `RetrievalResult (..)` | `Pipeline.hs:129`(`rrCandidates`) | 有 |
| `Candidate (..)` | `Pipeline.hs:388`、`Judge.hs:53` | 有 |
| `candidateContextHit` | `Pipeline.hs:129` | 2 |
| `candidateConflictHit` | `Pipeline.hs` | 2 |
| `metaSnippet` | `Pipeline.hs`、`Judge.hs:53` | 17 |
| `retrieveCandidatesWith` | **0** | 2 |
| `KeywordStrategy (..)` | **0** | 4 |
| `defaultKeywordStrategy` | **0** | 5 |
| `CandidateOrigin (..)` | **0**(但見下) | 3 |
| `renderRetrievalReason` | **0**(僅模組內 `Retrieval.hs:448` 自用) | 6 |
| `matchedNames` | **0** | 7 |
| `segmentDraft` | **0** | 9 |
| `rankFallbackScore` | **0** | 4 |
| `withinWindow` | **0** | 9 |
| `mergeCandidates` | **0** | 6 |
| `overFetchLimit` | **0** | 4 |
| `maxKeywords` | **0** | 3(`RetrievalSpec.hs:74,78,79`) |
| `segMinLen` / `chunkLen` / `maxKeywordLen` / `overFetchFactor` / `expansionDecay` | **0** | **0** |

三個結論:

1. **production 真正用到的只有 6 個名字**。其餘 17 個中,3 個是刻意留的策略接縫
   (`retrieveCandidatesWith` / `KeywordStrategy` / `defaultKeywordStrategy`)——ADR-007 的
   embedding 策略要靠它,**不能收**;`CandidateOrigin` 是 `Candidate` 的 `caOrigin` 欄位型別
   (`Retrieval.hs:115`),匯出 `Candidate (..)` 卻不匯出它,消費者拿得到欄位卻無法 pattern
   match,**也不能收**
2. **剩下 13 個純粹是為了測試而公開**,在測試裡被用 3–17 次不等。它們不是死碼,是**測試的觀測點**
3. **五個調校常數連測試都沒引用**,現在就能收,零影響

### 問題陳述

目前的消費者只有測試與 `Conflict.Pipeline` / `Conflict.Judge`,所以**還沒有真的壞掉**。
風險在於這是一條**單向的閘門**:常數或內部部件一旦被模組外引用,「換一種候選策略不需要改動
第 1、3 層」這個承諾就會悄悄失效,而失效的那一刻**不會有任何測試變紅**——它只會在未來真的要
接 embedding 策略時,以「動不了」的形式浮現。

ADR-007 明說 embedding 是被推遲、不是被否決的選項,所以這個承諾有真實的兌現日期。

階段二讓風險擴大了一點:`Conflict.Judge`(F005)現在也 import `Candidate (..)` 與 `metaSnippet`,
第 2 層的匯出面因此多了一個跨層消費者——而 `design.md` 的「模組間公開介面與資料結構」表
**沒有這一條**,它目前是一條沒人承認的隱形相依。

## Scope(涵蓋範圍)

2026-08-22 與開發者確認。

**動**:

- `conflict/src/StoryFlow/Conflict/Retrieval.hs` —— 拆成 `Retrieval.Internal`(實作,匯出全部)
  與 `Retrieval`(門面,只 re-export 契約面)
- `conflict/storyflow-conflict.cabal` —— `exposed-modules` 加 `Retrieval.Internal`
- `conflict/test/StoryFlow/Conflict/RetrievalSpec.hs`、`RetrievalEnvSpec.hs` —— 改 import
  `Internal`(這兩個是整包 import 的;其餘三個測試檔只用契約面名字,**不必動**)
- `conflict/test/StoryFlow/Conflict/CabalSpec.hs` —— 加守衛
- `.design/subsystems/conflict-detection/design.md` —— 兩張表各補一列

**不動**:

- **`Conflict.Pipeline`、`Conflict.Judge`、`Conflict.Graph`、`Conflict.Types` 一行都不改**。
  契約面保留它們用到的全部 6 個名字,所以它們感覺不到這次改動
- **任何演算法、常數值、排序規則**。這是純粹的可見度收斂,不是行為變更
- `cli/`、`server/`、`api/`、`service/` 等其他套件
- 對外契約(REST / CLI)完全相容

**排除的「順便改」**(討論中提出,開發者裁定不納入):

- **把六個調校常數收成 `RetrievalParams` 型別**:那是設計新抽象,不是收斂現有的東西。
  Internal 方案已經把它們移出契約面,達成本次目的
- **把 `Candidate` / `metaSnippet` 搬到 `Conflict.Types` 讓 Judge 不依賴 Retrieval**:契約上更
  乾淨(第 3 層不再認得第 2 層),但要動 F005 與 F006 已驗收的程式碼,scope 明顯變大。
  改為**承認它是合法的模組間介面**並補進 `design.md`
- **擴充策略接縫**(例如抽出完整的 `RetrievalStrategy` 含排序與合併):在沒有真的 embedding
  實作當對照組之前擴充它,只是猜下一個策略需要什麼形狀——**猜錯的接縫比沒有接縫更難拆**

## 改善目標

| 指標 | 現況 | 目標 | 量測方式 |
|---|---|---|---|
| `Conflict.Retrieval` 的匯出名字數 | 23 | **10** | 數匯出區塊的名字 |
| 匯出面中無 production 消費者的名字 | 17 | **4**(3 策略接縫加 `CandidateOrigin`,皆為刻意保留) | 逐名 grep |
| `src/` 中 import `Retrieval.Internal` 的檔案 | — | **0**(只有 `Retrieval.hs` 自己) | `CabalSpec` 斷言 |
| `conflict-test` examples 數 | 207 | **207 以上** | `cabal test all` |
| 全套測試 | 12 suites / 1432 / 0 failures | 不變 | `cabal test all` |
| 建置 warning | 0 | **0** | `cabal build all` |

**驗收標準**:上表全數達成,且 `Pipeline.hs` / `Judge.hs` / `Graph.hs` / `Types.hs` 的
`git diff` 為空。

## 相依性

`depends-on: [F003, F005, F006]` —— 三份皆 `done`:

- **F003**(conflict-retrieval):本次收斂的就是它建立的模組,匯出面是它定的
- **F005**(conflict-llm):`Judge.hs` 是 `Candidate (..)` / `metaSnippet` 的跨層消費者,
  契約面必須保留這兩個名字才不會動到它
- **F006**(conflict-check):`Pipeline.hs` 是最大的消費者,同上

**可平行開發**:可以。本次只動 `conflict` 套件內部的可見度,不碰任何其他子系統;
`llm-workshop-mcp` 已 5/5 完成,無進行中的任務會踩到同一批檔案。

**一致性檢查的一處刻意分歧**(2026-08-22):「使用到的既有串接介面」表十列的來源文檔全是
`F003`,反推的候選 `depends-on` 只有 `[F003]`,比 frontmatter 少兩個。**不刪 F005 / F006**
——那張表列的是「本次**用到**的介面」,而 F005 / F006 是「本次**不能弄壞**的消費者」。契約面
之所以是 10 個名字而不是 6 個,正是因為要讓 `Judge.hs`(F005)與 `Pipeline.hs`(F006)一行
都不必改;拿掉這兩個相依,「為什麼 `metaSnippet` 必須留在契約面」就沒有出處了。

## 改善方案

### 一、拆 `Retrieval.Internal`

`Retrieval.hs` 的 461 行實作**整份搬到** `conflict/src/StoryFlow/Conflict/Retrieval/Internal.hs`,
匯出全部部件。模組 haddock 開頭要寫明它的定位:

> 本模組是 `Conflict.Retrieval` 的實作,**不是契約**。它匯出全部部件供同套件的測試觀測;
> `src/` 底下除了 `Retrieval.hs` 之外**不准有任何檔案 import 它**(由 `CabalSpec` 釘住)。
> 要用第 2 層請走 `Conflict.Retrieval`。

`Retrieval.hs` 縮成純 re-export 門面,**逐項列舉**(不用整包 re-export)——與 `StoryFlow.Llm`
在 F001 閘門裁決後採用的形狀一致,理由相同:整包 re-export 會讓公開面由「某個名字剛好被哪個
內部模組匯出」決定,而不是由文檔決定。

### 二、契約面的 10 個名字

門面 4 個:`retrieveCandidates`、`RetrievalResult (..)`、`Candidate (..)`、`CandidateOrigin (..)`。

策略接縫 3 個(ADR-007 的 embedding 由此接入):`retrieveCandidatesWith`、`KeywordStrategy (..)`、
`defaultKeywordStrategy`。

輸出轉換 2 個(`Pipeline` 用):`candidateContextHit`、`candidateConflictHit`。

跨層共用 1 個(`Pipeline` 與 `Judge` 用,本次補進 `design.md` 的模組間介面表):`metaSnippet`。

### 三、下放到 Internal 的 13 個名字

`renderRetrievalReason`、`matchedNames`、`segmentDraft`、`rankFallbackScore`、`withinWindow`、
`mergeCandidates`、`overFetchLimit`、`segMinLen`、`chunkLen`、`maxKeywordLen`、`maxKeywords`、
`overFetchFactor`、`expansionDecay`。

`renderRetrievalReason` 雖然在 `Retrieval.hs:448` 被 `candidateConflictHit` 內部使用,但那是
**模組內呼叫**,搬進 Internal 之後兩者仍在同一個模組,不受影響。

### 四、測試改線

只有兩個檔案改 import,**一條斷言都不改**:

- `RetrievalSpec.hs:11`:`import StoryFlow.Conflict.Retrieval` 改為 `...Retrieval.Internal`
- `RetrievalEnvSpec.hs:12`:同上

`CheckEnvSpec.hs`(qualified,只用 `retrieveCandidates` / `rrScanned`)、`JudgeEnvSpec.hs`
(`Candidate (..)` / `CandidateOrigin (FromKeyword)` / `metaSnippet`)、`PipelineSpec.hs`
(`metaSnippet`)三個檔案用到的名字全在契約面內,**不動**。

### 五、守衛

`CabalSpec.hs` 加兩條斷言:

1. `exposed-modules` 含 `StoryFlow.Conflict.Retrieval.Internal`
2. **`conflict/src/` 底下除 `Retrieval.hs` 外,沒有任何檔案出現 `Retrieval.Internal` 字串**
   ——這是本次優化唯一的長期保護。沒有它,下一個 feature 隨手 import Internal 就把閘門重新打開,
   而且一樣不會有測試變紅

## 使用到的既有串接介面

本次是可見度重構,不新增任何外部串接。下表是**被收斂的匯出面**中留在契約線上的簽名,
逐條讀自 `conflict/src/StoryFlow/Conflict/Retrieval.hs`:

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `retrieveCandidates :: ConflictOpts -> Draft -> ServiceM RetrievalResult` | `Retrieval.hs:318` | `F003` | 第 2 層門面,`Pipeline.hs:128` 唯一入口 |
| `retrieveCandidatesWith :: KeywordStrategy -> ConflictOpts -> Draft -> ServiceM RetrievalResult` | `Retrieval.hs:322` | `F003` | 策略接縫,ADR-007 的 embedding 由此接入 |
| `newtype KeywordStrategy = KeywordStrategy { runKeywordStrategy :: [(Id, [Text])] -> Text -> [Text] }` | `Retrieval.hs:141` | `F003` | 可替換的切詞與比對策略 |
| `defaultKeywordStrategy :: KeywordStrategy` | `Retrieval.hs:192` | `F003` | 現行的反向名稱比對加切詞 |
| `data Candidate = Candidate { caMeta :: Meta, caSnippet :: Text, caScore :: Double, caOrigin :: CandidateOrigin }` | `Retrieval.hs:110` | `F003` | 候選片段;`Pipeline` 與 `Judge` 共用 |
| `data CandidateOrigin = FromKeyword Text \| FromExpansion Id LinkKind` | `Retrieval.hs:99` | `F003` | `caOrigin` 的型別 |
| `data RetrievalResult = RetrievalResult { rrCandidates :: [Candidate], rrScanned :: Int, rrKeywords :: [Text] }` | `Retrieval.hs:120` | `F003` | 第 2 層完整結果 |
| `candidateContextHit :: Candidate -> ContextHit` | `Retrieval.hs:433` | `F003` | `context` 出口的轉換 |
| `candidateConflictHit :: Candidate -> ConflictHit` | `Retrieval.hs:443` | `F003` | `conflict check` 出口的轉換 |
| `metaSnippet :: Meta -> Text` | `Retrieval.hs:249` | `F003` | 片段摘要;`Judge.hs:53` 組 prompt 時也用 |

## 介面變動

**新增模組**:`StoryFlow.Conflict.Retrieval.Internal`(`exposed-modules`)。模組切分本身屬
Level 3,但因為它承載了「哪些名字是契約」這個 Level 2 的區分,`design.md` 的「內部模組劃分」
表一併補列。

**移除公開**(`Conflict.Retrieval` 不再匯出,改由 `Internal` 提供):13 個名字,見「改善方案 三」。

**受影響的呼叫端**:

| 呼叫端 | 影響 | 處理 |
|---|---|---|
| `Pipeline.hs` / `Judge.hs` / `Graph.hs` / `Types.hs` | **無** | 用到的 6 個名字全在契約面 |
| `RetrievalSpec.hs` / `RetrievalEnvSpec.hs` | import 換模組 | 改一行,斷言不動 |
| `CheckEnvSpec.hs` / `JudgeEnvSpec.hs` / `PipelineSpec.hs` | **無** | 用到的名字全在契約面 |
| `cli` / `server` / `api` | **無** | 從未 import `Conflict.Retrieval` |

**Level 2 契約變動(需回寫 `design.md`,開發者已同意)**:

1. 「模組間公開介面與資料結構」表**新增一列**:`Conflict.Judge` / `Conflict.Pipeline` 到
   `Conflict.Retrieval` —— 共用 `Candidate (..)` 與 `metaSnippet`;第 2 層的候選型別是三層
   之間的資料介面,不是內部細節
2. 「內部模組劃分」表補列 `Conflict.Retrieval.Internal`

**對外契約(REST / CLI)**:完全相容,零變動。

## TodoList

- [ ] T1: 建 `conflict/src/StoryFlow/Conflict/Retrieval/Internal.hs`,461 行實作整份搬入並匯出全部部件;模組 haddock 寫明「這是實作不是契約」與 `src/` 的 import 禁令  `dep: -`
- [ ] T2: `Retrieval.hs` 縮成逐項列舉的 re-export 門面,只匯出契約面 10 個名字  `dep: T1`
- [ ] T3: `storyflow-conflict.cabal` 的 `exposed-modules` 加 `StoryFlow.Conflict.Retrieval.Internal`  `dep: T1`
- [ ] T4: `RetrievalSpec.hs` 與 `RetrievalEnvSpec.hs` 改 import `Internal`,**斷言一條不改**  `dep: T2, T3`
- [ ] T5: `CabalSpec.hs` 加斷言:`exposed-modules` 含 `Retrieval.Internal`  `dep: T3`
- [ ] T6: `CabalSpec.hs` 加斷言:`conflict/src/` 底下除 `Retrieval.hs` 外無任何檔案出現 `Retrieval.Internal`,並附變造重現  `dep: T3`
- [ ] T7: `design.md` 的「內部模組劃分」表補 `Conflict.Retrieval.Internal`  `dep: T2`(「模組間公開介面與資料結構」表的 `Candidate` / `metaSnippet` 那一列**已於設計階段補上**——它描述的是今天就成立的現況,不必等實作)
- [ ] T8: 全套驗收:`cabal build all` 零 warning、`cabal test all` 12 suites 全綠且 examples 不減,且四個不動檔案的 `git diff` 為空  `dep: T4, T5, T6`

## 1-to-1 測試對照表

回歸測試優先:T4 之前 `conflict-test` 的 207 條全部必須是綠的,那就是保護現有行為的基線。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `conflict-test` 既有 207 條全綠(回歸基線) | 搬檔不改行為;搬完先跑一次確認基線沒動 |
| T2 | `RetrievalSpec` / `RetrievalEnvSpec` 在 T4 之前**編譯失敗**即為預期 | 門面收斂真的生效的證明——收完之後整包 import 拿不到內部部件 |
| T3 | `CabalSpec` 的「`exposed-modules` 含 `Retrieval.Internal`」(T5 新增的那條) | 套件宣告與實際模組對得上 |
| T4 | `conflict-test` 全部重新轉綠,**examples 數不少於 207** | 覆蓋一條不掉是本次的硬性驗收 |
| T5 | 同 T3 | 與 T3 共用同一條斷言,T3 是它的被測對象 |
| T6 | `CabalSpec` 的「`src/` 只有 `Retrieval.hs` 能 import `Internal`」;並以**變造字串重現**(在假的來源清單裡塞一個 `Pipeline.hs` 引用 `Internal`,守衛必須指得出來) | 沒有重現測試的守衛不算守衛——與 `service` 的 B001 同一個做法 |
| T7 | `/arch-audit subsys conflict-detection` 不再回報匯出面與模組表的落差 | 文檔與程式碼對帳。模組表在實作後才補,因為 `Retrieval.Internal` 此刻還不存在,先寫進去等於讓文檔描述不存在的東西 |
| T8 | `cabal build all` 加 `cabal test all` 加四個檔案的 `git diff` 為空 | 「不動 Pipeline / Judge / Graph / Types」這條 scope 紀律的可測形式 |

## 實作備註

(實作時填寫:與設計的偏差、量化結果)
