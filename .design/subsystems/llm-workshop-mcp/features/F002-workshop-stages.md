---
id: F002
type: feature
title: workshop-stages
description: 依型別註冊表 stages 驅動的工作坊狀態機與 session 快照
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001]
related-adr: [ADR-003, ADR-005, ADR-006]
related-feature: []
---

# F002: 依型別註冊表驅動的工作坊階段狀態機

## 功能概述

新建套件 `storyflow-workshop`,提供工作坊管線「定案之前」的那一段:`startWorkshop`
建立一次工作坊、`stepWorkshop` 送一輪對話給地端/雲端模型並把回覆解析成片段草稿、
`loadSession` 讓中斷後的工作坊接得回去。驗收標準逐條:

| # | 驗收標準 | 怎麼算通過 |
|---|---|---|
| 1 | 階段清單完全來自型別註冊表的 `stages`,新增一個型別不改工作坊的程式 | `wsStages` 由 `listEntityTypes` 找到的 `EntityTypeSpec.etsStages` 直接指定,程式裡沒有任何寫死的階段名字或型別鍵 |
| 2 | 硬約束片段以 `summary` 進 prompt | `stepWorkshop` 組 system message 時,`wsConstraints` 逐一經 `getEntity` 取 `metaSummary`,不送 `entBody` |
| 3 | `Session` 是可序列化的快照,落在 `.storyflow/workshops/<id>.json`,中斷後 `loadSession` 接得回去 | 三個寫入操作(`startWorkshop`/`stepWorkshop`,以及未來 `commitStage`)各自在成功後寫出快照;`loadSession` 讀同一個檔案能重建出等價的 `Session` |
| 4 | 對話歷程不進圖譜 | `wsHistory` 只落在 `.storyflow/workshops/`(索引掃描略過 `.` 開頭路徑),不呼叫任何 `createEntity`/`addFragment` |
| 5 | `stepWorkshop` 從模型回覆解析約定 JSON 存進 `wsPending`,解析失敗時保留上一次成功的值、回覆照樣給人看 | 模型回覆不含合法 JSON(或根本没有)時 `wsPending` 不變,但 `wsHistory` 與快照仍然更新,回傳的 `Text` 仍是這次的原始回覆 |
| 6 | `LlmError` 原樣浮上來,不折成泛用失敗 | `chat` 回 `Left e` 時 `stepWorkshop` 直接回 `Left e`(同一個建構子與內容),不寫快照、`Session` 不變 |

明確**不做**(契約卡的硬邊界):不寫圖譜(`commitStage`/`NewEntityReq` 是 `workshop-emit`
的事,F002 完全不 import `createEntity`/`addFragment`);不定義 CLI 與 REST 形狀(那是
`workshop-interface`);不自己實作 LLM 端點(`chat` 是 `storyflow-llm` 的既有介面,原樣呼叫)。

## 相依性

`depends-on: [F001, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001]`。
四條全是**程式碼級**相依——四份文檔皆 `done`,對應原始碼已在樹上讀過。

- **`F001`(llm-workshop-mcp,同子系統)**:`storyflow-llm` 的門面 `StoryFlow.Llm` 提供
  `LlmClient` / `newLlmClient` / `chat` / `Message` / `Role` / `LlmError` / `renderLlmError` /
  `llmErrorCode`。F002 只呼叫 `chat`,不建立 `LlmClient`(那是呼叫端——`workshop-interface`
  ——的事:`stepWorkshop` 的簽名直接吃 `LlmClient` 參數)
- **`entity-graph-core/F002`(core-types-and-registry)**:`Id`(`wsConstraints` / `wsOwner` /
  `wsCommitted` 的元素型別)、`Entity` / `Meta`(讀 `metaSummary` 組 prompt)、
  `EntityTypeSpec`(`etsStages` 就是階段清單來源,`etsKey` 用來比對型別)全部定義在這裡。
  該文檔明寫「工作坊階段的實際執行(P5,本規格只把 `stages` 當資料存下來)」——F002 正是
  把那份資料變成行為的地方
- **`entity-graph-core/F004`(store-vault-io-and-index)**:`store/src/StoryFlow/Store/Vault.hs`
  的 `initVault` 是本 feature 唯一直接改動的 `storyflow-store` 原始碼(`.storyflow/.gitignore`
  多寫一行 `workshops/`,見「實作方式」第五節與 D6/S5)。這是**原始碼編輯**,不是
  `storyflow-workshop.cabal` 的相依——套件邊界測試(T11)仍然擋著 `storyflow-store`
- **`service-and-interfaces/F001`(service-contract)**:`ServiceM` / `Env` / `runService` /
  `ServiceError` / `getEntity` / `listEntityTypes` / `vaultInfo` 全部定義在
  `service/src/StoryFlow/Service*.hs`。F002 也**擴充**這個檔案(`ServiceError` 新增五個
  建構子,見「新增的介面」與「待確認假設」A1)——與 F001(llm-endpoint)當年直接在
  `StoryFlow.Service` 加 `vaultConfig` 是同一種先例

**可否平行開發**:F002 是階段二第一個項目,`design.md` 的功能規劃列著 `workshop-emit`(#3)
依賴 `#2`(本 feature)、`workshop-interface`(#4)依賴 `#3`。三者是**序列**,F002 完成前
`workshop-emit` 無法動工(`commitStage` 的簽名吃 `Session`,而 `Session` 的型別由 F002 定義)。
F002 與階段三的 `mcp-adapter` 互不相依,理論上可平行,但 `mcp-adapter` 依賴
`service-and-interfaces` 而非本子系統,實際排程由編排者決定。

## 對應的 Level 2 契約

| 契約出處 | 條目 | 本 feature 的落點 |
|---|---|---|
| `llm-workshop-mcp/design.md` 對外契約 | `startWorkshop :: Text -> [Id] -> ServiceM Session` | `StoryFlow.Workshop.Stages.startWorkshop` |
| 同上 | `loadSession :: Text -> ServiceM Session` | `StoryFlow.Workshop.Session.loadSession` |
| 同上 | `stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either LlmError (Session, Text))` | `StoryFlow.Workshop.Stages.stepWorkshop` |
| 「模組間公開介面與資料結構」 | `data Session = Session {..}` | `StoryFlow.Workshop.Session` |
| 同上 | `data StageDraft = StageDraft {..}` | `StoryFlow.Workshop.Session` |
| 同上 | `Workshop.Stages → Llm.Client`:只用 `chat` 的簽名 | `stepWorkshop` 呼叫 `StoryFlow.Llm.chat`,不知道後端是地端還是雲端 |
| 同上 | `Workshop.Stages → Workshop.Session`:讀寫 `Session`,狀態只在這裡變動 | `startWorkshop` / `stepWorkshop` 呼叫 `Workshop.Session` 的 `loadSession` / `saveSession` / id 產生,不自己組快照的 bytes |
| 「Session 快照的落地位置」批次澄清 | 落 `.storyflow/workshops/<id>.json`,三個寫入操作各自在成功後寫出快照 | `Workshop.Session.saveSession`,由 `startWorkshop` / `stepWorkshop` 在成功路徑呼叫 |
| 「`stepWorkshop` 的錯誤通道」批次澄清 | 回 `ServiceM (Either LlmError (Session, Text))`,`LlmError` 原樣浮上來 | `stepWorkshop` 對 `chat` 的 `Left` 原樣回傳,不落 `ServiceM` 的 `throwError` |
| 「硬約束怎麼進 prompt」 | `wsConstraints` 以 `summary` 進 system message | `stepWorkshop` 組 prompt 的私有函式 |

**沒有超出契約的新公開介面**,但有兩處**擴充既有套件的公開面**(皆有 F001 先例可循,詳見
「新增的介面」與「待確認假設」A1):`storyflow-service` 的 `ServiceError` 新增五個建構子;
`storyflow-store` 的 `initVault` 內容改動(不改介面簽名,只改它寫出的 `.gitignore` 內容)。

## 實作方式

### 一、套件骨架

新增 `workshop/storyflow-workshop.cabal`,`common warnings` / `common lang` 逐字照抄
`conflict/storyflow-conflict.cabal` 那一組(`-Wall -Wcompat`;GHC2021 +
`DerivingStrategies` / `LambdaCase` / `OverloadedStrings` / `RecordWildCards` /
`StrictData`)。`cabal.project` 的 `packages:` 加一行 `workshop/`(排在 `llm/` 之後),並補一段
與其它十個套件同樣格式的:

```
package storyflow-workshop
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns
```

`allow-newer` 不動——本 feature 沒有引入任何新的第三方套件版本壓力(`aeson` / `directory` /
`filepath` / `mtl` / `time` 全部是既有相依裡已經在用的版本)。

模組:

| 模組 | 內容 | 為什麼是這個切法 |
|---|---|---|
| `StoryFlow.Workshop.Session` | `Session` / `StageDraft`、兩者的 `ToJSON`/`FromJSON`、快照路徑、`saveSession` / `loadSession`、session id 產生 | 契約卡「負責模組」之一;「Workshop.Stages → Workshop.Session:讀寫 Session,狀態只在這裡變動」——快照的讀寫邏輯因此收斂在這一個模組,`Stages` 不碰檔案系統 |
| `StoryFlow.Workshop.Stages` | `startWorkshop`、`stepWorkshop`、prompt 組裝、模型回覆的 JSON 解析 | 契約卡「負責模組」之二;是唯一呼叫 `StoryFlow.Llm.chat` 的模組 |

不設 `StoryFlow.Workshop` 門面:`design.md` 的模組表沒有列出門面名字,`storyflow-conflict`
也沒有門面(只有 `storyflow-llm` / `storyflow-service` / `storyflow-store` 三個既有套件有),
本 feature 不無中生有一個契約沒要求的公開名字。

`build-depends`(library)——**與 `storyflow-conflict` 同一條紀律,外加擋 `servant` /
`warp`**(D9 指名 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite` 不准進
library;`servant` / `warp` 是比照 `storyflow-llm` 的既有紀律,理由相同——這一層不定義 CLI
與 REST 出口):

```
, aeson
, base              >=4.14 && <5
, bytestring
, directory
, filepath
, mtl
, storyflow-core
, storyflow-llm
, storyflow-service
, text
, time
```

`storyflow-core` 是**刻意含入**的(與 `storyflow-llm` 刻意不含它相反):本套件要處理 `Id` /
`Entity` / `Meta` / `EntityTypeSpec`,不像 `storyflow-llm` 只搬 `[Message]`。`mtl` 給
`Control.Monad.Except.throwError`(型別未知、越界、快照壞掉時丟 `ServiceError`)。`time` 給
`Data.Time.getCurrentTime`(session id 產生用)。`directory` / `filepath` 給快照的目錄建立與
原子寫入(`storyflow-workshop` 不依賴 `storyflow-store`,所以不能用它的 `atomicWriteText`,
自己用 `directory` 的 `renamePath` 寫一份同構的邏輯,見第三節)。

`build-depends`(test-suite)——沿用 F001 的 D8 先例,warp 起真的本機 stub 端點:

```
, aeson
, base
, bytestring
, directory
, filepath
, hspec
, storyflow-core
, storyflow-llm
, storyflow-service
, storyflow-workshop
, temporary
, text
, wai
, warp
```

### 二、`Workshop.Session`:`Session` / `StageDraft` 與 JSON 編碼

```haskell
data Session = Session
  { wsId          :: Text
  , wsType        :: Text
  , wsConstraints :: [Id]
  , wsStages      :: [Text]
  , wsCurrent     :: Int
  , wsHistory     :: [Message]
  , wsOwner       :: Maybe Id
  , wsPending     :: [StageDraft]
  , wsCommitted   :: [Id]
  }
  deriving stock (Show, Eq)

data StageDraft = StageDraft
  { sdTitle   :: Text
  , sdSummary :: Text
  , sdBody    :: Text
  , sdTags    :: [Text]
  }
  deriving stock (Show, Eq)
```

逐字等於 `design.md`「模組間公開介面與資料結構」的定義。`wsOwner` / `wsCommitted` 由
`commitStage`(`workshop-emit`,F003)寫入;F002 只負責在 `startWorkshop` 把它們初始化成
`Nothing` / `[]`,`stepWorkshop` 完全不碰這兩欄。

**JSON 編碼**(`instance ToJSON Session` / `FromJSON Session`、`StageDraft` 同理,直接寫在
`Workshop.Session`,不另開 `.Json` 模組——目前唯一的消費者就是這個套件自己,`workshop-interface`
未來若要序列化給 REST/CLI,再決定要不要拆,那是它的 Level 3 自主權):

```json
{
  "id": "...",
  "type": "character",
  "constraints": ["ent-7f3a"],
  "stages": ["定位", "外貌與舉止", "動機與過往", "關係網"],
  "current": 1,
  "history": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "owner": "ent-9c21",
  "pending": [
    {"title": "外貌", "summary": "...", "body": "...", "tags": ["外觀"]}
  ],
  "committed": []
}
```

`owner` 為 `Nothing` 時整個鍵不出現(沿用 `Core.Json` / `Service.Json` 的「`Maybe` 沒值鍵不
出現」約定)。`Id` 直接用 `aeson`——`storyflow-core` 已經有 `instance ToJSON Id` /
`FromJSON Id`(`StoryFlow.Core.Json`,字串編碼),`storyflow-workshop` 依賴 `storyflow-core`
所以這個孤兒實例本來就在作用域裡,不必也不該重新定義一次。

**`Message` / `Role` 不加孤兒實例**:`StoryFlow.Llm.Client` 的原始碼與 haddock 明講「OpenAI 的
線上形狀是私有的……刻意不定義 `ToJSON` / `FromJSON` 實例在公開型別上」——這是 F001 刻意守住
的邊界(一旦有人在別的套件對 `Role` / `Message` 定義孤兒實例,`storyflow-llm` 未來自己想加
編碼時就會撞衝突實例)。`Session` 的 `ToJSON` 因此**手動**把 `wsHistory` 轉成
`[Value]`(每個 `Message` → `object ["role" .= <text>, "content" .= msgContent m]`,`<text>`
是套件內部私有的 `System` / `User` / `Assistant` → `"system"` / `"user"` / `"assistant"` 對照,
與 `Llm.Client` 內部的 `roleWire` 同樣的字串但各自一份——兩邊都是三行的窮盡 `case`,重複的
代價遠低於跨套件孤兒實例衝突的代價),`FromJSON` 反向解析同一組字串,不認得的值當
`FromJSON` 失敗。

### 三、`Workshop.Session`:快照路徑、原子寫入、`loadSession`

快照路徑:`vaultRoot </> ".storyflow" </> "workshops" </> (T.unpack sid <> ".json")`。
`vaultRoot` 由 `vaultInfo :: ServiceM VaultView` 的 `vvRoot` 取得(見「使用到的既有串接介面」
——這是待確認假設 A2 的結論:F002 不新增任何 `ServiceM` 函式來拿 vault root,直接複用已存在
的 `vaultInfo`)。路徑字串用字面組(`".storyflow"` / `"workshops"`),不 import
`storyflow-store` 的 `storyflowDir` ——與 `llm/test/StoryFlow/Llm/Fixtures.hs` 的
`appendConfig` 同一個理由:那個套件的相依清單裡沒有 `storyflow-store`,本套件也沒有。

`saveSession :: Session -> ServiceM ()`:

1. 經 `vaultInfo` 取 `vvRoot`,組出 `workshops/` 目錄與目標檔路徑
2. `liftIO (createDirectoryIfMissing True workshopsDir)`——第一次寫快照時這個目錄還不存在
3. 同目錄開暫存檔(`directory` 的 `openBinaryTempFile` 風格,與
   `StoryFlow.Store.Atomic.atomicWriteText` 同一個原子寫入手法:暫存檔與目標檔同一個目錄,
   寫完 `hFlush` / `hClose` 再 `renamePath` 覆蓋),寫入 `Data.Aeson.encode session`(UTF-8
   位元組,`aeson` 內建不加 BOM)
4. IO 例外一律 `try` 起來,失敗轉成 `WorkshopSnapshotWriteFailed path (顯示例外訊息)`
   丟進 `ServiceM`(見「新增的介面」)

這是**同構**於 `StoryFlow.Store.Atomic.atomicWriteText` 的邏輯,而不是呼叫它——後者定義在
`storyflow-store`,本套件的相依清單擋著這個名字。兩份實作各自完整、互不依賴,是刻意付的
小額重複,換來的是套件邊界測試(T11)能繼續逐字釘住「library 不含 store」。

`loadSession :: Text -> ServiceM Session`:

1. 組出同一條路徑
2. `liftIO (doesFileExist path)`;`False` → `throwError (WorkshopSessionNotFound sid)`
3. 讀檔 → `Data.Aeson.eitherDecodeStrict'`(或等效的嚴格版本)解析成 `Session`;`Left err`
   → `throwError (WorkshopSnapshotCorrupt path (T.pack err))`;`Right s` → `pure s`

**`Workshop.Session` 的 session id 產生**(`newSessionId :: Text -> [Id] -> ServiceM Text`,
供 `startWorkshop` 呼叫):

`Session` 的 `wsId :: Text` 不是 `StoryFlow.Core.Id.Id`——後者的建構子只認得四個封閉前綴
(`ent` / `lvl` / `nod` / `vlt`,`StoryFlow.Core.Id.IdPrefix`),工作坊 session 不是這四種
實體之一,`mkId` 用不上。改用 `Core.Id` **有匯出**的雜湊原語 `fnv1a64 :: BS.ByteString ->
Word64` 自己組:對 `(型別鍵, 硬約束 id 清單, 目前時間, salt)` 串成的位元組雜湊、取低 32 位、
十六進位定寬 8 碼,前綴 `wksp-`(`wksp-3f9a2c10` 這種形狀,人類讀得出是工作坊 session 而不是
某個 Entity)。碰撞處理與 `store` 的作法同一個精神:算出候選 id 後檢查
`.storyflow/workshops/<candidate>.json` 是否已存在,存在就 `salt + 1` 重算,最多重試一個
保守上限(例如 5 次)後仍碰撞就視為異常(`WorkshopSnapshotWriteFailed` 兜底,理論上不會發生
——同一毫秒 + 同一組輸入 + 5 次 salt 全部碰撞的機率可忽略)。

### 四、`Workshop.Stages`:`startWorkshop`

```haskell
startWorkshop :: Text -> [Id] -> ServiceM Session
```

1. `listEntityTypes >>= \specs -> case find ((== ty) . etsKey) specs of ...`——找不到 →
   `throwError (UnknownType ty)`(**重用**既有建構子,不新增:`storyflow-service` 的
   `createEntity` 對「型別不在註冊表」用的就是這個建構子,語意完全對得上)
2. 找到但 `null (etsStages spec)` → `throwError (WorkshopNoStages ty)`(新建構子,見「新增的
   介面」)——驗收標準 1 的反面:一個型別宣告了零個階段,工作坊沒有東西可以引導,必須在
   建立 session 之前就失敗,不留一個永遠卡在 `wsCurrent = 0` 又沒有下一步的空殼
3. 逐一對 `constraints` 呼叫 `getEntity`(丟棄回傳值,只驗證存在)——目標不存在時
   `getEntity` 已經會丟 `StoreFailed (EntityNotFound i)`,不需要另外處理。這是**及早失敗**
   的選擇(建立 session 時就驗,不留到第一次 `stepWorkshop` 才發現某個 id 打錯了),見
   「待確認假設」A3
4. 呼叫 `Workshop.Session` 的 id 產生,組出初始 `Session`:`wsStages = etsStages spec`、
   `wsCurrent = 0`、`wsHistory = []`、`wsOwner = Nothing`、`wsPending = []`、
   `wsCommitted = []`
5. `saveSession` 寫出快照,回傳這個 `Session`

### 五、`Workshop.Stages`:prompt 組裝

私有函式,組出這一輪要送給 `chat` 的 `[Message]`:

```haskell
buildMessages :: Session -> [(Id, Text)] -> Text -> [Message]
```

第二個參數是**已經取好**的硬約束 `(Id, summary)` 清單(呼叫端在取 constraint summary 時
可能失敗,見下)。System message 依序排:

1. 開場一句:「你正在引導使用者完成『{型別}』的第 {N}/{總數} 個階段:『{階段名}』。」
   （`N` = `wsCurrent + 1`,`階段名` = `wsStages !! wsCurrent`)
2. 硬約束區塊(有的話):逐條「【既有設定 {id}({無標題,只有 summary,因此不含 title})】
   {summary}」——與 `Conflict.Judge.renderPairPrompt` 同一個「id + 內容」的呈現方式,但這裡
   只送 `summary`(驗收標準 2),不像 `Judge` 有 `--expand-body` 選項送全文
3. 格式指示:要求模型在對使用者的自然語言回覆之外,**另外**用一個 ` ```json ` 圍起來的
   區塊附上目前這個階段可以定案的片段草稿,陣列形狀 `[{"title":…, "summary":…, "body":…,
   "tags":[…]}]`;沒有想清楚就附 `[]`;可以附多個(一個階段可能拆成多個片段)

Messages 全體 = `[Message System systemPrompt] ++ wsHistory session ++ [Message User input]`
——`wsHistory` 只存使用者/模型的往返,system message 每次呼叫時重新組(硬約束的 summary
可能隨時間被改過,現讀現送比存一份舊的更正確)。

### 六、`Workshop.Stages`:`stepWorkshop`

```haskell
stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either LlmError (Session, Text))
```

1. `wsCurrent session >= length (wsStages session)` → `throwError (WorkshopStagesExhausted
   (wsId session))`(新建構子)——防禦性檢查:正常流程下 `startWorkshop` 已擋掉零階段的
   型別,但一個已經被 `commitStage`(F003)推到最後一階之後的 `Session` 仍可能被呼叫端誤傳
   進來,這裡要講得出「為什麼不能再 `step`」而不是讓 `!!` 丟出陣列越界的例外
2. 逐一對 `wsConstraints session` 呼叫 `getEntity`,取 `metaSummary . entMeta . evEntity`
   組成 `(Id, Text)` 清單(重用 `startWorkshop` 已經驗證過存在,但**不快取**——見「待確認
   假設」A3,現讀現送)
3. `buildMessages session constraintSummaries input` 組出 `[Message]`
4. `liftIO (chat client messages)`
5. `Left e` → 直接 `pure (Left e)`。**不寫快照、`Session` 不變**——這一步什麼都沒發生,
   `wsHistory` 不該記一輪沒有下文的失敗嘗試
6. `Right reply`:
   a. `newHistory = wsHistory session ++ [Message User input, Message Assistant reply]`
   b. 對 `reply` 跑 JSON 擷取(見下),成功 → `newPending`;失敗 → 沿用
      `wsPending session`(驗收標準 5)
   c. `newSession = session { wsHistory = newHistory, wsPending = newPending }`
   d. `saveSession newSession`
   e. `pure (Right (newSession, reply))`——`reply` 是**原始**回覆,不剝 JSON、不做任何加工

**JSON 擷取**(`extractDrafts :: Text -> Maybe [StageDraft]`,純函式,與
`Conflict.Judge.parseVerdict` 同一套立場但獨立實作——不同套件、不同 schema,`storyflow-
workshop` 不依賴 `storyflow-conflict`,不能重用它的程式碼,只重用做法):

1. 在 `reply` 裡找**第一段** ` ``` ` 圍起來的區塊(邏輯與 `Judge.locateFence` /
   `dropLangTagLine` 同構:語言標記行〔如 `json`〕整行丟掉;找不到 fence 就退回整段文字
   本身)
2. 對取到的內容跑 `Data.Aeson.eitherDecodeStrictText :: Text -> Either String [StageDraft]`
3. 失敗時退回「第一個 `[` 到最後一個 `]`」的切片再 decode 一次(`Judge.sliceBraces` 的方括號
   版本——草稿陣列的最外層是 `[`,不是 `{`)
4. 兩次都失敗 → `Nothing`。**不捏假資料**,呼叫端(`stepWorkshop` 第 6b 步)在 `Nothing` 時
   原樣保留舊的 `wsPending`
5. 解出空陣列 `[]` **算成功**——`newPending = []`,不是「保留舊值」。模型明確表示「這階段
   還沒有東西可以定案」與「這次回覆解析失敗」是兩種不同的事,前者要能清空舊草稿(否則
   使用者刪掉一個草稿想法後,舊的還賴在 `wsPending` 裡)

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)` | `llm/src/StoryFlow/Llm/Client.hs` | F001 | `stepWorkshop` 唯一的模型呼叫 |
| `data LlmClient`(不透明) | 同上 | F001 | `stepWorkshop` 的參數型別,原樣轉呼叫 |
| `data Message = Message { msgRole :: Role, msgContent :: Text }` / `data Role = System \| User \| Assistant` | 同上 | F001 | `wsHistory` 的元素型別;prompt 組裝的輸出型別 |
| `data LlmError = LlmUnavailable Text \| LlmHttpStatus Int Text \| LlmBadResponse Text \| LlmConfigMissing \| LlmConfigInvalid Text` | `llm/src/StoryFlow/Llm/Error.hs` | F001 | `stepWorkshop` 的錯誤通道,原樣浮上來 |
| `renderLlmError :: LlmError -> Text` / `llmErrorCode :: LlmError -> Text` | 同上 | F001 | 不在 F002 直接用(F002 不渲染錯誤,那是 `workshop-interface` 的事),但確認存在以佐證「`LlmError` 原樣浮上來後有渲染出口」 |
| `newtype ServiceM a`(`ReaderT Env (ExceptT ServiceError IO)`,`MonadReader Env` / `MonadError ServiceError` / `MonadIO`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `startWorkshop` / `stepWorkshop` / `loadSession` / `saveSession` 全部跑在它上面 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | 同上 | service-and-interfaces/F001 | 測試執行三個公開函式 |
| `data Env = Env { envVault :: Vault, envConn :: Connection, envTypes :: TypeRegistry }` | 同上 | service-and-interfaces/F001 | 測試底稿建 `Env`(經 `openEnv`,不直接建構) |
| `openEnv` / `closeEnv` / `vaultsEnvVar` | 同上 | service-and-interfaces/F001 | 測試底稿的臨時 Vault 生命週期,與 `llm/test/.../Fixtures.hs` 同一套 |
| `listEntityTypes :: ServiceM [EntityTypeSpec]` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | `startWorkshop` 找型別、讀 `etsStages` |
| `getEntity :: Id -> ServiceM EntityView` | 同上 | service-and-interfaces/F001 | 驗證硬約束存在(`startWorkshop`)、取 `summary`(`stepWorkshop`) |
| `vaultInfo :: ServiceM VaultView` | 同上 | service-and-interfaces/F001 | 取得 `vvRoot` 組快照路徑(見待確認假設 A2) |
| `createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)` | 同上 | service-and-interfaces/F001 | 測試底稿建臨時 Vault |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | `getEntity` 的回傳型別,取 `evEntity` 再往下鑽 |
| `data VaultView = VaultView { vvName :: Text, vvRoot :: FilePath, vvEntityCount :: Maybe Int }` | 同上 | service-and-interfaces/F001 | `vaultInfo` 的回傳型別,取 `vvRoot` |
| `data ServiceError = StoreFailed StoreError \| RegistryUnavailable Text \| RegistryLoadFailed [LoadError] \| ValidationFailed (Maybe Id) [EntityWarning] \| UnknownType Text \| DanglingLinkTarget Ref \| CrossVaultUnsupported Ref \| LevelTreeInvalid Id [TreeError]`(F002 新增五個建構子,見下) | `service/src/StoryFlow/Service/Error.hs` | service-and-interfaces/F001 | `startWorkshop` 重用 `UnknownType`;三個函式共用新建構子的錯誤通道 |
| `renderServiceError :: ServiceError -> Text` / `errorCode :: ServiceError -> Text` | 同上 | service-and-interfaces/F001 | 新建構子的渲染與代碼比照既有風格(繁中說下一步 + snake_case) |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | entity-graph-core/F002 | `evEntity` 的型別,取 `entMeta` |
| `data Meta = Meta { metaSummary :: Text, … }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | 取硬約束的 `summary` |
| `data Id`(不透明)/ `renderId :: Id -> Text` / `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | `wsConstraints` / `wsOwner` / `wsCommitted` 的元素型別;JSON 編碼沿用 `Core.Json` 既有的 `Id` 實例 |
| `fnv1a64 :: BS.ByteString -> Word64` | 同上 | entity-graph-core/F002 | session id 產生的雜湊原語 |
| `data EntityTypeSpec = EntityTypeSpec { etsKey :: Text, etsStages :: [Text], … }` | `core/src/StoryFlow/Core/Registry.hs` | entity-graph-core/F002 | `startWorkshop` 找型別、讀 `stages` |
| `instance ToJSON Id` / `instance FromJSON Id` | `core/src/StoryFlow/Core/Json.hs` | entity-graph-core/F002 | `Session` 的 `wsConstraints` / `wsOwner` / `wsCommitted` 編解碼直接沿用,不重新定義 |
| `atomicWriteText`(讀作**做法**範本,不是被呼叫的函式——`storyflow-workshop` 不依賴 `storyflow-store`) | `store/src/StoryFlow/Store/Atomic.hs` | entity-graph-core/F004 | `saveSession` 的原子寫入邏輯**同構**於它:暫存檔同目錄、`hFlush`/`hClose`/`renamePath`、失敗清暫存檔 |
| `initVault :: FilePath -> Text -> IO (Either StoreError Vault)`(內部寫 `.storyflow/.gitignore` 的那一段) | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | 本 feature**改動**這裡的 `.gitignore` 內容(D6/S5),不是呼叫它 |
| `renderPairPrompt` / `locateFence` / `dropLangTagLine` / `sliceBraces` / `stripCodeFence`(讀作**做法**範本,不是被呼叫的函式——`storyflow-workshop` 不依賴 `storyflow-conflict`) | `conflict/src/StoryFlow/Conflict/Judge.hs` | - | prompt 呈現與 JSON 擷取的演算法先例,`extractDrafts` 與 `buildMessages` 各自獨立實作同一套邏輯 |

## 新增的介面

```haskell
-- storyflow-workshop : StoryFlow.Workshop.Session --------------------------
data Session = Session
  { wsId          :: Text
  , wsType        :: Text
  , wsConstraints :: [Id]
  , wsStages      :: [Text]
  , wsCurrent     :: Int
  , wsHistory     :: [Message]
  , wsOwner       :: Maybe Id
  , wsPending     :: [StageDraft]
  , wsCommitted   :: [Id]
  }
  deriving stock (Show, Eq)
-- instance ToJSON Session / instance FromJSON Session

data StageDraft = StageDraft
  { sdTitle   :: Text
  , sdSummary :: Text
  , sdBody    :: Text
  , sdTags    :: [Text]
  }
  deriving stock (Show, Eq)
-- instance ToJSON StageDraft / instance FromJSON StageDraft

loadSession :: Text -> ServiceM Session
-- saveSession 與 session id 產生是套件內部(Stages 呼叫),不在此列出公開名字,
-- 留給實作階段決定要不要對套件外開放(commitStage / F003 屆時若要重用,
-- 由那個 feature 決定是否需要它們穿透門面)

-- storyflow-workshop : StoryFlow.Workshop.Stages ----------------------------
startWorkshop :: Text -> [Id] -> ServiceM Session
stepWorkshop  :: LlmClient -> Session -> Text -> ServiceM (Either LlmError (Session, Text))

-- storyflow-service : StoryFlow.Service.Error(擴充,見待確認假設 A1)--------
data ServiceError
  = ⋯                                   -- 既有八個建構子不變
  | WorkshopSessionNotFound Text        -- loadSession 找不到這個 session id 的快照檔
  | WorkshopSnapshotCorrupt FilePath Text   -- 快照檔在,但不是合法的 Session JSON
  | WorkshopSnapshotWriteFailed FilePath Text  -- 寫快照時的 IO 失敗(磁碟滿、權限…)
  | WorkshopNoStages Text               -- 型別沒有宣告任何 stages(startWorkshop)
  | WorkshopStagesExhausted Text        -- session 已經沒有下一階段(stepWorkshop)
-- renderServiceError / errorCode 各加五個 case,風格與既有八則一致
--   (workshop_session_not_found / workshop_snapshot_corrupt /
--    workshop_snapshot_write_failed / workshop_no_stages / workshop_stages_exhausted)

-- store/src/StoryFlow/Store/Vault.hs(內容變動,簽名不變,見 D6/S5)---------
-- initVault 寫出的 .storyflow/.gitignore 內容由 "index.db\n" 改為 "index.db\nworkshops/\n"
```

## TodoList

- [ ] T1: 建 `workshop/storyflow-workshop.cabal`(common 段照抄 conflict)、`cabal.project` 加 `workshop/` 與 ghc-options 段、兩個模組骨架  `dep: -`
- [ ] T2: `storyflow-service` 的 `ServiceError` 新增五個建構子與對應的 `renderServiceError` / `errorCode`  `dep: -`
- [ ] T3: `store` 的 `initVault`:`.storyflow/.gitignore` 內容加一行 `workshops/`(D6/S5)  `dep: -`
- [ ] T4: `Workshop.Session`:`Session` / `StageDraft` 型別與 JSON 編碼(含 `Message`/`Role` 的私有 JSON 轉換,不對 `storyflow-llm` 的型別加孤兒實例)  `dep: T1`
- [ ] T5: `Workshop.Session`:快照路徑(經 `vaultInfo` 取 `vvRoot`)、目錄建立、`saveSession`(暫存檔 + rename 的原子寫入)、`loadSession`(缺檔 → `WorkshopSessionNotFound`;JSON 壞掉 → `WorkshopSnapshotCorrupt`)  `dep: T4, T2`
- [ ] T6: `Workshop.Session`:session id 產生(`fnv1a64` 雜湊 + 以快照檔是否已存在做碰撞重試)  `dep: T4`
- [ ] T7: `Workshop.Stages`:`startWorkshop`(`listEntityTypes` 找型別 → 空 `stages` 回 `WorkshopNoStages` → 驗證每個硬約束 id 存在 → 建初始 `Session` → `saveSession`)  `dep: T5, T6, T2`
- [ ] T8: `Workshop.Stages`:system prompt 組裝(階段說明 + 硬約束 summary + JSON 陣列格式指示)  `dep: T7`
- [ ] T9: `Workshop.Stages`:`stepWorkshop`(越界 → `WorkshopStagesExhausted`;`chat` 的 `Left` 原樣回傳且不寫快照;`Right` 時更新 `wsHistory`、解析回覆的 JSON 陣列成功則整批替換 `wsPending`、失敗則保留舊值、`saveSession`)  `dep: T8`
- [ ] T10: 測試底稿 `StoryFlow.Workshop.Fixtures`(warp stub 端點、`withDeadPort`、臨時 Vault:`createVault`/`openEnv`/`runService`)  `dep: T1`
- [ ] T11: 套件邊界測試 `StoryFlow.Workshop.CabalSpec`(build-depends 逐字釘住、禁用清單、`cabal.project` 已登錄、兩個模組都在 `exposed-modules`)  `dep: T1`

## 1-to-1 測試對照表

測試框架 **hspec**;`workshop/test/Spec.hs` 照 `conflict/test/Spec.hs` 的形狀(`hSetEncoding
stdout utf8` + 手動 `describe "Tn …"`,不用 `hspec-discover`)。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Workshop.CabalSpec`(「模組」小節) | `StoryFlow.Workshop.Session` 與 `StoryFlow.Workshop.Stages` 都在 `exposed-modules` |
| T2 | `StoryFlow.Service.ErrorSpec`(擴充既有檔案) | 五個新建構子的 `errorCode` 互不重複、全為 snake_case;`renderServiceError` 每一則非空且各自提到對應的下一步(如 `WorkshopSessionNotFound` 的訊息含 `workshop start`) |
| T3 | `StoryFlow.Store.InitSpec`(擴充既有測試「`.storyflow/.gitignore` 含 index.db」那一條) | `initVault` 後 `storyflowDir dir </> ".gitignore"` 的內容同時含 `index.db` 與 `workshops/` 兩行 |
| T4 | `StoryFlow.Workshop.SessionJsonSpec` | `Session` 與 `StageDraft` 各自 encode → decode round-trip 相等(含 `wsOwner = Nothing` 時鍵不出現、`wsOwner = Just _` 時鍵出現);`wsHistory` 的三種 `Role` 都能正確編解碼且互不混淆 |
| T5 | `StoryFlow.Workshop.SessionIOSpec` | `saveSession` 後檔案存在於 `.storyflow/workshops/<id>.json`;`loadSession` 讀回的 `Session` 與寫入前相等;`loadSession` 對不存在的 id 回 `Left (WorkshopSessionNotFound _)`;把快照檔內容改成不合法 JSON 後 `loadSession` 回 `Left (WorkshopSnapshotCorrupt _ _)` |
| T6 | `StoryFlow.Workshop.SessionIdSpec` | 連續產生 50 個 id 全部不重複;預先在 `workshops/` 目錄放一個與「即將產生的候選 id」同名的空檔(以雜湊輸入回推構造碰撞),驗證函式會跳過它、拿到不同的 id |
| T7 | `StoryFlow.Workshop.StartSpec` | 對真實型別(`character-fragment`,`stages` 非空)呼叫 `startWorkshop` 成功:`wsStages` 等於註冊表的 `etsStages`、`wsCurrent == 0`、快照檔已寫出;型別不存在 → `Left (UnknownType _)`;硬約束 id 不存在 → `Left (StoreFailed (EntityNotFound _))`;（用型別註冊表載入的假型別或 stub 驗證)`etsStages` 為空的型別 → `Left (WorkshopNoStages _)` |
| T8 | `StoryFlow.Workshop.PromptSpec` | 純函式測試(不必真的呼叫模型):組出的 system message 含目前階段名與 `N/總數`;硬約束的 `(id, summary)` 逐條出現在文字裡;含 JSON 陣列格式指示(斷言字串含 `title` / `summary` / `body` / `tags` 四個鍵名) |
| T9 | `StoryFlow.Workshop.StepSpec` | 對 stub 端點:回覆含合法 JSON 陣列(一個或多個 draft)→ `wsPending` 等於解析結果、`wsHistory` 增加兩則、快照被更新;回覆是純自然語言(無 JSON)→ `wsPending` 與呼叫前相等、但 `wsHistory` 與快照仍更新、回傳的 `Text` 等於 stub 的原始回覆;`withDeadPort` → `Left (LlmUnavailable _)` 且快照檔內容與呼叫前逐位元組相同(未被覆寫)、`Session` 的 `wsHistory` 長度不變;`wsCurrent = length wsStages` 的 session → `Left` 不對,是 `ServiceM` 的 `throwError (WorkshopStagesExhausted _)`(用 `runService` 接住,斷言整個呼叫回 `Left (WorkshopStagesExhausted _)` 而非 `Right (Left _)`) |
| T10 | `StoryFlow.Workshop.StubSpec` | 底稿自己的契約(照抄 F001 的 T9):`withStub` 起得來、回得出設定好的內文;`withDeadPort` 給的埠在區塊內用（透過 `chat` 間接)驗證為連線被拒 |
| T11 | `StoryFlow.Workshop.CabalSpec`(主體) | `build-depends` 逐字等於設計裡的兩份清單;library 不含 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite` / `servant` / `warp`;`storyflow-core` / `storyflow-llm` / `storyflow-service` 都在 library;`warp` / `wai` 只出現在 test-suite;`cabal.project` 含 `workshop/` 且含 `package storyflow-workshop` 段 |

## 待確認假設

- A1:`ServiceError`(`storyflow-service`,屬 `service-and-interfaces` 子系統的 Level 2 契約)
  需要新增五個建構子(`WorkshopSessionNotFound` / `WorkshopSnapshotCorrupt` /
  `WorkshopSnapshotWriteFailed` / `WorkshopNoStages` / `WorkshopStagesExhausted`),
  但契約卡與 `design.md` 都沒有明講這件事;修改另一個子系統的 Level 2 契約超出本 feature
  的委派範圍。→ 採取:比照 F001(llm-endpoint)當年直接在 `StoryFlow.Service` 加
  `vaultConfig` 的先例——`startWorkshop` / `loadSession` / `stepWorkshop` 的簽名對「型別未知
  以外的業務錯誤」只有 `ServiceM` 內建的 `ServiceError` 一條通道可用(`LlmError` 那條通道
  按契約只給模型呼叫失敗用),而現有八個建構子沒有一個語意對得上「session 找不到」/
  「快照壞掉」/「快照寫入失敗」/「型別沒有階段」/「階段已經走完」,所以視為buildable 的
  必要條件,把它設計進本文檔的 TodoList(T2)。→ 影響:編排者若認為這個擴充應該先走
  `service-and-interfaces` 自己的一輪委派(而非由本 feature 直接動它的原始碼),T2 要改成
  「等待該子系統補上這五個建構子」而不是本 feature 自己實作,T5/T7/T9 的 `dep:` 要跟著調整;
  `service-and-interfaces/design.md` 需要回填這五個建構子的存在(比照
  `llm-workshop-mcp/design.md` 當初記 `vaultConfig` 的方式)。
- A2:`storyflow-workshop` 不能依賴 `storyflow-store`,但快照路徑需要 vault root。
  → 採取:重用既有的 `vaultInfo :: ServiceM VaultView`(`vvRoot`),**不**新增一個更輕量的
  `ServiceM FilePath` 函式。理由:`vaultInfo` 內部會多跑一次 `listEntities`(取
  `vvEntityCount`),對單人小型 Vault 而言這一次 SQLite 查詢的成本可忽略,而少一個
  「建議修改的 Level 2 契約」項目比省一次查詢更值得——A1 已經有一個跨子系統擴充案要編排者
  裁決,不必再加第二個。→ 影響:若未來 Vault 規模大到 `listEntities` 變成量測得到的成本,
  可以再提案加一個輕量的 `vaultRoot :: ServiceM FilePath`(或等效)到 `StoryFlow.Service`,
  屆時只需要改 `Workshop.Session` 內部一行,不影響本文檔任何公開介面。
- A3:硬約束 id 的存在性檢查時機與是否快取。→ 採取:`startWorkshop` 用 `getEntity` 逐一驗證
  一次(及早失敗);`stepWorkshop` 每次呼叫**重新** `getEntity` 取最新的 `summary`,不快取
  在 `Session` 裡。理由:`design.md` 沒有明講這兩件事,但「使用者中途編輯了硬約束片段的
  summary」是完全合理的情境,現讀現送比較正確;而 `startWorkshop` 及早驗證能讓打錯 id 的
  使用者在建立 session 的當下就發現,而不是講到一半才炸開。→ 影響:若判斷錯誤,
  `startWorkshop` 改成不驗證(信任呼叫端),或 `stepWorkshop` 改成用 session 建立時快取的
  summary(需要在 `Session` 加一個內部欄位,但 `Session` 的欄位已經是 Level 2 契約鎖定的
  九個,加欄位就是偏離契約,因此這個方向的修正代價明顯更高——這也是選擇「現讀不快取」的
  加分理由之一)。
- A4:`Session.wsId` 的產生方式(前綴 `wksp-` + `fnv1a64` 雜湊 + 檔案存在性碰撞重試)。
  → 採取:如「實作方式」第三節,重用 `Core.Id` 已匯出的 `fnv1a64` 原語但不重用 `mkId`(它
  的 `IdPrefix` 是封閉的四個實體前綴,工作坊 session 不是其中之一)。→ 影響:若未來認為
  工作坊 session 也該進 `Core.Id.IdPrefix` 的封閉集合(讓 session id 與 Entity id 同一套
  格式與驗證),那是 `entity-graph-core` 的 Level 2 變動,不是本 feature 能單方面決定的。
- A5:`Workshop.Session` 是否對套件外公開 `saveSession` 與 id 產生函式。→ 採取:「新增的
  介面」只列 `loadSession`(Level 2 明文要求的三個公開函式之一),`saveSession` 與 id 產生
  留在模組內(是否加進 `exposed` 的匯出清單由實作階段決定,反正 `StoryFlow.Workshop.Session`
  整個模組本來就在 `exposed-modules` 裡,`workshop-emit`〔F003〕在同一個套件內,天然拿得到)。
  → 影響:若 F003 的 `commitStage` 需要重用這兩個函式(幾乎必然,因為它也要在成功後寫出
  快照),它會是「同套件內部呼叫」而不是「新的公開介面」,不影響本文檔已定的公開面。

## 實作備註

(開發過程中與設計的偏差記錄於此,撰寫時留空)
