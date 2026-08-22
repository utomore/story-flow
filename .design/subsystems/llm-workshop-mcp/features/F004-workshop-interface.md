---
id: F004
type: feature
title: workshop-interface
description: 工作坊的 CLI 子指令與 REST 路由(薄包裝,不含工作坊邏輯)
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, F002, F003, service-and-interfaces/F002, service-and-interfaces/F003]
related-adr: [ADR-006, ADR-011]
related-feature: []
---

# F004: workshop-interface

## 功能概述

把 `startWorkshop` / `loadSession` / `stepWorkshop` / `commitStage` 四個已定義的工作坊操作,
以 CLI 子指令(`workshop start` / `step` / `commit`)與三條 REST 路由(`POST /workshop`、
`POST /workshop/:id/step`、`POST /workshop/:id/commit`)兩種形式暴露出去。本 feature 落在
`service-and-interfaces` 的地盤(`storyflow-cli` / `storyflow-api` / `storyflow-server`),
是 ADR-011 定義的「介面包裝層」對 `llm-workshop-mcp` 新增的一條相依邊——正常成長,不是架構違規。

驗收標準(逐字取自契約卡):CLI 與 REST 行為一致;`--json` 走統一信封;錯誤沿用
`errorCode` 與 `renderServiceError`(ServiceM 外層失敗)、`WorkshopError` 在這一層折成使用者
看得懂的訊息(`renderWorkshopError` / `workshopErrorCode`,對 `LlmError` 沿用
`renderLlmError` / `llmErrorCode` 的原文);session id 在兩種介面裡是同一個東西(同一份
`.storyflow/workshops/<id>.json`);`workshop start` 把 session id 印出來,`--json` 模式下在信封裡。

明確不做:不含工作坊邏輯(薄包裝);不新增業務操作;不為工作坊另立一套錯誤語彙;不做
`workshop rm`(D6);不碰 `storyflow-service` 的 `CabalSpec` 逐字清單(service-and-interfaces/B001)。

## 相依性

- **F001**(`llm-endpoint`,已完成):直接呼叫它的 `LlmConfig` / `newLlmClient` /
  `llmConfig :: ServiceM (Either LlmError LlmConfig)` / `LlmError` / `renderLlmError` /
  `llmErrorCode`,在介面層自己建 `LlmClient`(見「實作方式」)
- **F002**(`workshop-stages`)、**F003**(`workshop-emit`):本 feature 包的四個操作
  (`startWorkshop` / `loadSession` / `stepWorkshop` / `commitStage`)與 `Session` /
  `StageDraft` / `WorkshopError` 的形狀由這兩份文檔定義。**兩者的程式碼此刻都還不存在**,
  本文檔的介面表因此完全依 `design.md` 的「對外契約」與「模組間公開介面與資料結構」逐字對照,
  不依 F002 / F003 的 feature 文檔(尚在同步修訂)
- **service-and-interfaces/F002**(`cli-embedded`):本 feature 在既有的 `StoryFlow.Cli.Options` /
  `.Backend` / `.Error` / `.Render` / `StoryFlow.Cli` 五個模組上加東西,新增的 `Command`
  建構子、`Backend` 操作、`CliError` 建構子、render 函式都疊在它已建立的骨架上
- **service-and-interfaces/F003**(`servant-api-server`):本 feature 在既有的 `StoryFlow.Api` /
  `StoryFlow.Api.Instances` / `StoryFlow.Server` / `StoryFlow.Server.Error` /
  `StoryFlow.Server.State` 上加東西,新路由併入既有 `StoryFlowAPI`、新 handler 併入既有
  `handlers`、CLI 遠端分派沿用既有 `Backend` 的 `Remote` 建構子與 `servant-client`

**可否平行開發**:不可。必須等 F002 / F003 的公開介面(型別簽名與模組路徑)實際落地編譯通過,
本 feature 才能真的動工——目前的 `depends-on` 是**文檔級**相依(介面表照 `design.md` 逐字對照,
不是照原始碼查證,因為原始碼還不存在)。

**不算進 `depends-on` 的一筆引用**:「使用到的既有串接介面」表最後一列引用了
`conflict-detection`(已完成)的 `acquireJudge`/`checkConflictB`/`conflictH` 三處程式碼,但那是
**設計手法的抄寫對象**(任務指示明確要求「照抄那條路徑」),本 feature 不 import
`storyflow-conflict`、不呼叫它的任何函式,運行期與編譯期都沒有相依——因此不列進
`depends-on`,對帳時不算差異。

## 對應的 Level 2 契約

實作 `.design/subsystems/llm-workshop-mcp/design.md`「對外契約」的：

- 對外形式表工作坊那一列:CLI `story-flow workshop start --type <型別> [--constraint <id>]…` /
  `step` / `commit`;REST `POST /workshop`、`POST /workshop/:id/step`、`POST /workshop/:id/commit`
- 「兩種介面都以 `loadSession` 取回 session,不自己管存檔時機」——`step` 與 `commit` 在介面層
  的接線一律是 `loadSession sid >>= ...`,存檔時機完全交給 `startWorkshop` / `stepWorkshop` /
  `commitStage` 三者自己(它們在成功後各自寫出快照)
- 「誰負責寫快照」段:介面層**不寫檔**,只呼叫上述四個操作
- 「LlmConfig 與 storyflow-store 的佔位型別」與「LlmClient 從哪來」:比照
  `.design/subsystems/service-and-interfaces/design.md`「模組間公開介面與資料結構」與
  `api/src/StoryFlow/Api.hs` 的 `ConflictAPI` 註解、`conflict/src/StoryFlow/Conflict/Pipeline.hs`
  的 `acquireJudge`——`LlmClient` 不跨 HTTP,伺服器與 CLI 內嵌模式各自讀自己綁定的 Vault 的
  `[llm]` 設定並建 client

未超出 Level 2 範圍:本 feature 沒有新增業務操作,只新增「介面包裝層」的公開面(CLI 指令樹的
分支、REST 路由的分支),這正是 ADR-011 允許且預期的成長方式。

## 實作方式

### 資料流(對照 design.md 的工作坊管線「外部入口」段)

```
CLI 參數(optparse)/ REST 請求 body(servant)
  → 介面層解碼:WorkshopStart(type, constraints) / WorkshopStep(sid, input) / WorkshopCommit(sid)
  → Backend 分派(僅 CLI):Embedded 直接進 ServiceM;Remote 以 servant-client 打 HTTP,
    在伺服器端回到同一條路(與既有操作同一種分派形狀)
  → start:startWorkshop type constraints
  → step:  loadSession sid → acquireLlmClient(讀 [llm] 設定建 LlmClient,或短路成 WsLlmFailed)
           → stepWorkshop client session input
  → commit:loadSession sid → commitStage session
  → 任一步的 Left WorkshopError 一律短路,不繼續往下呼叫
  → 出口渲染:CLI 統一信封 {"ok":true,"data":…} / REST JSON body;
    WorkshopError 在這裡才折成 code/message(CLI 走 CliError,REST 走新的
    toWorkshopServerError);ServiceM 外層的 ServiceError 仍走既有的
    CliService / toServerError,沒有變動
```

### `LlmClient` 的建立(接線層,CLI 與 server 各自一份,刻意不共用)

比照 `conflict/src/StoryFlow/Conflict/Pipeline.hs` 的 `acquireJudge`,但更簡單(工作坊沒有
「不跑第 3 層」的退化選項——`design.md` 明寫「工作坊沒有 conflict-detection 第 3 層那種
退化成前兩層的逃生口」)：

```haskell
acquireLlmClient :: ServiceM (Either WorkshopError LlmClient)
acquireLlmClient =
  llmConfig >>= \case
    Left e   -> pure (Left (WsLlmFailed e))
    Right cfg -> Right <$> liftIO (newLlmClient cfg)
```

`llmConfig :: ServiceM (Either LlmError LlmConfig)` 與 `newLlmClient :: LlmConfig -> IO LlmClient`
都是 F001 已完成的公開介面(`llm/src/StoryFlow/Llm.hs` 的門面清單)。

**為什麼在 cli 與 server 兩處各寫一次,不抽成 storyflow-workshop 的共用函式**:
`acquireJudge` 之所以能被 CLI 與 server 共用一次呼叫,是因為它本來就住在兩者都已依賴的
`storyflow-conflict` 裡(第 3 層的「接線層」,F006 的產物)。工作坊沒有對應的既有接線層
函式——`stepWorkshop` 的簽名直接吃 `LlmClient` 參數,把「怎麼建它」丟給呼叫端。往
`storyflow-workshop` 加一個新的公開函式會動到 F002 / F003 的地盤,而契約卡的「明確不做」
寫著「不新增業務操作」;把四行 glue code 複製兩份,換來的是不越界。這與 D 段沒有牴觸:
`checkConflictB` 與 `conflictH` 同樣各自寫一次 `acquireJudge noLlm o >>= checkConflict stage o d`
的**組合**,只是它們共用的 `acquireJudge` 本身已經存在;工作坊這裡連「本身」都要新寫。

### WorkshopError 在這一層折成 code / message

- **CLI 內嵌模式**:`CliError` 新增 `CliWorkshop WorkshopError` 建構子,
  `cliErrorCode (CliWorkshop e) = workshopErrorCode e`、
  `cliErrorMessage (CliWorkshop e) = renderWorkshopError e`,`isUsageError` 落在既有的
  `_ -> False`(exit 1,業務失敗)
- **CLI 遠端模式**:**不需要新程式碼**。既有的 `classify :: ClientError -> RemoteError` 與
  `remoteErrorCode (RemoteStatus _ code _) = code` 已經是「原樣取出伺服器給的 code」,
  不管那個 code 來自 `errorCode`(ServiceError)還是 `workshopErrorCode`(WorkshopError)
  ——伺服器錯誤 body 的形狀從頭到尾只有一種 `{"error":{"code":…,"message":…}}`
- **REST**:`StoryFlow.Server.Error` 新增 `toWorkshopServerError :: WorkshopError -> ServerError`
  與 `statusForWorkshopCode :: Text -> ServerError`,分派鍵一樣走**字串**(`workshopErrorCode`
  的回傳值),不 pattern match `WorkshopError` 的建構子——與既有 `toServerError` /
  `statusForCode` 的紀律完全一致(server 不因此需要認識 `WorkshopError` 的建構子集合會不會
  增減)
- `StoryFlow.Server.State` 新增一個泛型的 `runEither`,把「跑 ServiceM(Either e a)→視情況
  丟 ServerError→回 a」這個形狀抽出來,`run1` 的行為不變(可選擇讓 `run1` 呼叫
  `runEither` 的特例,或維持獨立——兩者行為等價,留給實作階段挑一個):

  ```haskell
  runEither :: AppState -> (e -> ServerError) -> ServiceM (Either e a) -> Handler a
  runEither st toErr op = do
    r <- liftIO (withEnvLocked st (\env -> runService env op))
    case r of
      Left se -> throwError (toServerError se)
      Right (Left e)  -> throwError (toErr e)
      Right (Right a) -> pure a
  ```

  `workshopH` 用 `runEither st toWorkshopServerError`。

### CLI 指令樹

`workshop` 是頂層名詞(與 `context` / `search` 同一種形狀,不是掛在別的名詞底下):

```
story-flow workshop start --type <型別> [--constraint <id>]…
story-flow workshop step <session-id> (--input <文字> | --input-file <檔案> | -)
story-flow workshop commit <session-id>
```

`step` 的輸入採「字面 / 檔案 / stdin 三選一、必填」,形狀與既有 `bodyReqP`
(`entity set-body`)、`draftP` / `forP`(`context` / `conflict check`)一致——這一輪要對模型
說的話沒有理由比正文或草稿短,讀檔與讀 stdin 是 IO 的界線也要守住(`parseCli` 保持純函式)。
旗標名用 `--input` / `--input-file` 而不是沿用 `--body`,因為語意是「對話輸入」不是「正文」。

`start` 印出 session id:人類模式的一行文字裡含 `wsId`;`--json` 模式下 `data` 就是完整的
`Session`,`data.id`(假設欄位名依全系統慣例由 `wsId` 去前綴而來,見「待確認假設」A1)自然
帶著它。

### REST 路由與 DTO

```haskell
-- StoryFlow.Api 新增(與 ContextReq / CheckReq 同一處,同一種寫法)

data WorkshopStartReq = WorkshopStartReq
  { wsrType :: Text
  , wsrConstraints :: [Id]   -- 缺席時退回 []
  }

newtype WorkshopStepReq = WorkshopStepReq { wsiInput :: Text }

-- stepWorkshop 回 (Session, Text) 的 tuple,REST/CLI 的 --json 都需要把兩者
-- 一起交出去(reply 是給人看的那段回覆,不進 Session 本體,見 design.md
-- 「階段定案的來源」段)。這兩個 wrapper 由本 feature 定義、擁有:
data WorkshopStepResp = WorkshopStepResp
  { wssSession :: Session
  , wssReply   :: Text
  }

data WorkshopCommitResp = WorkshopCommitResp
  { wcrSession  :: Session
  , wcrEntities :: [EntityView]
  }

type WorkshopAPI =
  "workshop"
    :> Summary "開一個新工作坊,依型別的階段清單逐階段對話"
    :> ReqBody '[JSON] WorkshopStartReq
    :> Post '[JSON] Session
    :<|> "workshop"
      :> Capture "id" Text   -- session id 是 Session 的 wsId,純 Text,不是 core 的 Id
      :> "step"
      :> Summary "把這一輪的輸入送進目前階段,模型的回覆存回 session"
      :> ReqBody '[JSON] WorkshopStepReq
      :> Post '[JSON] WorkshopStepResp
    :<|> "workshop"
      :> Capture "id" Text
      :> "commit"
      :> Summary "把目前階段最後一次成功解析的草稿定案,寫進圖譜"
      :> Post '[JSON] WorkshopCommitResp

type StoryFlowAPI =
  VaultAPI :<|> EntityAPI :<|> LinkAPI :<|> LevelAPI :<|> NodeAPI :<|> MiscAPI
    :<|> ConflictAPI :<|> WorkshopAPI
```

`Capture "id" Text` 而不是 `Capture "id" Id`:session id(`Session` 的 `wsId`)是
`design.md` 明寫的 `Text`,不是 core 的 `<prefix>-<hex>` 格式(不是 Entity / Level / Node /
Vault 之一),沿用 `Id` 的 `FromHttpApiData` 會擋掉合法的 session id。三條路由都**沒有
`revision` query parameter**——session 不是走樂觀鎖的資源,`commitStage` 內部寫圖譜時的
樂觀鎖屬於 `entity`/`level`/`node` 那些既有端點的職責,不是 workshop 端點自己的。

`storyFlowOpenApi` 的 `applyTagsFor` 鏈加一行:
`. applyTagsFor (subOperations (Proxy :: Proxy WorkshopAPI) storyFlowAPI) ["workshop"]`。

### Backend(內嵌／遠端兩路分派,沿用「操作層三行」的形狀)

```haskell
startWorkshopB :: Backend -> Text -> [Id] -> M Session
startWorkshopB (Embedded e) ty cs = svcWs e (startWorkshop ty cs)
startWorkshopB (Remote c) ty cs   = rmt c (cWorkshopStart (WorkshopStartReq ty cs))

stepWorkshopB :: Backend -> Text -> Text -> M WorkshopStepResp
stepWorkshopB (Embedded e) sid input = svcWs e (stepFlow sid input)
stepWorkshopB (Remote c) sid input   = rmt c (cWorkshopStep sid (WorkshopStepReq input))

commitStageB :: Backend -> Text -> M WorkshopCommitResp
commitStageB (Embedded e) sid = svcWs e (commitFlow sid)
commitStageB (Remote c) sid   = rmt c (cWorkshopCommit sid)

-- 私有:內嵌路徑的接線,loadSession → acquireLlmClient → stepWorkshop,
-- 三步都可能短路成 Left WorkshopError。
stepFlow :: Text -> Text -> ServiceM (Either WorkshopError WorkshopStepResp)
commitFlow :: Text -> ServiceM (Either WorkshopError WorkshopCommitResp)
acquireLlmClient :: ServiceM (Either WorkshopError LlmClient)

-- 私有:把 Either WorkshopError a 攤平成 M a,ServiceError 走既有的
-- CliService,WorkshopError 走新的 CliWorkshop——與既有 svc 的差別只有多攤一層。
svcWs :: Env -> ServiceM (Either WorkshopError a) -> M a
```

`client` 衍生區塊追加三個函式簽名並併入最後的模式比對:
```haskell
cWorkshopStart  :: WorkshopStartReq -> ClientM Session
cWorkshopStep   :: Text -> WorkshopStepReq -> ClientM WorkshopStepResp
cWorkshopCommit :: Text -> ClientM WorkshopCommitResp
```

### Server handler

```haskell
handlers st =
  vaultH st :<|> entityH st :<|> linkH st :<|> levelH st :<|> nodeH st
    :<|> miscH st :<|> conflictH st :<|> workshopH st

workshopH :: AppState -> Server WorkshopAPI
workshopH st =
  (\WorkshopStartReq {..} -> runEither st toWorkshopServerError (fmap Right' <$> ...))
    -- 實際寫法見下:start 沒有 Either 短路的必要包裝差異,直接用 runEither
```

更精確地寫(避免上面那行的偽碼誤導):

```haskell
workshopH :: AppState -> Server WorkshopAPI
workshopH st =
  (\WorkshopStartReq {..} -> runEither st toWorkshopServerError (startWorkshop wsrType wsrConstraints))
    :<|> (\sid WorkshopStepReq {..} -> runEither st toWorkshopServerError (stepFlow sid wsiInput))
    :<|> (\sid -> runEither st toWorkshopServerError (commitFlow sid))
```

`stepFlow` / `commitFlow` / `acquireLlmClient` 在 server 這一側**重複定義一份**(與 CLI 的
`Backend.hs` 那份程式碼相同,理由見「實作方式」的 `LlmClient` 小節)。

### CLI 渲染(人類可讀)

```haskell
renderWorkshopStarted :: Session -> Text
-- "已建立工作坊 <wsId>(型別 <wsType>,目前第 <wsCurrent+1>/<length wsStages> 階段)"

renderWorkshopCommit :: WorkshopCommitResp -> Text
-- "已定案 <length wcrEntities> 個片段" ++
-- 依 wsCurrent (wcrSession r) 是否已達 length (wsStages (wcrSession r))
-- 印「工作坊已完成全部階段」或「進入第 N 階段」

-- step 的人類輸出就是 wssReply 本身(給人看的那段模型回覆),不另外包裝
```

`Session` 的欄位存取(`wsId` / `wsType` / `wsCurrent` / `wsStages`)直接引用 `design.md`
「模組間公開介面與資料結構」給的 Haskell record,不是猜測。

### CLI 指令分派(`StoryFlow.Cli` 的 `handle`)

```haskell
WorkshopStart ty cs -> do
  s <- startWorkshopB b ty cs
  pure (plain (renderWorkshopStarted s) s)
WorkshopStep sid bs -> do
  input <- readBody io bs
  r <- stepWorkshopB b sid input
  pure (Out (wssReply r) [] (toJSON r))
WorkshopCommit sid -> do
  r <- commitStageB b sid
  pure (plain (renderWorkshopCommit r) r)
```

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)` | (尚未實作;簽名引自 `design.md`) | F002 | `workshop start` 的內嵌實作 |
| `loadSession :: Text -> ServiceM (Either WorkshopError Session)` | (尚未實作) | F002 | `step` / `commit` 內嵌路徑取回 session,不自管存檔時機 |
| `stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))` | (尚未實作) | F002 | `workshop step` 的內嵌實作 |
| `commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))` | (尚未實作) | F003 | `workshop commit` 的內嵌實作 |
| `data Session = Session { wsId, wsType, wsConstraints, wsStages, wsCurrent, wsHistory, wsOwner, wsPending, wsCommitted }` | (尚未實作) | F002 | REST 回應型別、CLI 渲染取值 |
| `data StageDraft = StageDraft { sdTitle, sdSummary, sdBody, sdTags, sdTimeline }` | (尚未實作) | F002 | `Session` 的 `wsPending` 欄位型別,需要 `ToSchema` |
| `data WorkshopError = WsSessionNotFound … \| WsLlmFailed LlmError` (8 個建構子) | (尚未實作) | F002 | CLI/REST 錯誤折譯的輸入 |
| `renderWorkshopError :: WorkshopError -> Text` / `workshopErrorCode :: WorkshopError -> Text` | (尚未實作) | F002 | CLI `CliWorkshop` 的 message/code;REST `toWorkshopServerError` 的分派鍵 |
| `data Message = Message { msgRole :: Role, msgContent :: Text }` / `data Role = System \| User \| Assistant` | (尚未實作) | F002 | `Session.wsHistory` 的元素型別,需要 `ToSchema` |
| `llmConfig :: ServiceM (Either LlmError LlmConfig)` | `llm/src/StoryFlow/Llm/Config.hs:157` | F001 | `acquireLlmClient` 讀 Vault 的 `[llm]` 設定 |
| `newLlmClient :: LlmConfig -> IO LlmClient` | `llm/src/StoryFlow/Llm/Client.hs`(門面 `llm/src/StoryFlow/Llm.hs:35`) | F001 | `acquireLlmClient` 建立 client |
| `data LlmClient`(不透明) | `llm/src/StoryFlow/Llm.hs:33` | F001 | `stepWorkshop` 的第一個參數 |
| `renderLlmError :: LlmError -> Text` / `llmErrorCode :: LlmError -> Text` | `llm/src/StoryFlow/Llm/Error.hs:50,74` | F001 | `WsLlmFailed` 折譯時沿用的原文(不重寫) |
| `Command`、`GlobalOpts`、`BodySource(..)`、`bodyStdinArg`、`typeOptReq`、`readWith`、`txtOption` | `cli/src/StoryFlow/Cli/Options.hs` | service-and-interfaces/F002 | `workshop` 子指令的解析骨架與共用小工具 |
| `Backend(..)`、`M`、`runM`、`throw`、`svc`、`rmt`、`classify` | `cli/src/StoryFlow/Cli/Backend.hs:110-200` | service-and-interfaces/F003 | 雙模式分派骨架;`svcWs` 是 `svc` 的多攤一層版本 |
| `CliError(..)`、`cliErrorCode`、`cliErrorMessage`、`isUsageError` | `cli/src/StoryFlow/Cli/Error.hs:130-161` | service-and-interfaces/F002 | 新增 `CliWorkshop` 建構子的宿主(注意:實際上是 5 個既有建構子,`design.md` 契約卡寫的「四個建構子」與程式碼不符,見待確認假設 A3) |
| `Envelope(..)`、`encodeEnvelope`、`plain`、`table`、`tshow` | `cli/src/StoryFlow/Cli/Render.hs` | service-and-interfaces/F002 | `--json` 信封與人類可讀渲染的共用工具 |
| `dispatch`、`handle`、`Out(..)`、`readBody`、`emit` | `cli/src/StoryFlow/Cli.hs` | service-and-interfaces/F002 | 指令派送與輸出的既有骨架,`workshop` 三指令疊上去 |
| `ContextReq`、`CheckReq` 的 `ToJSON`/`FromJSON`/`ToSchema` 寫法 | `api/src/StoryFlow/Api.hs:149-216` | service-and-interfaces/F003 | `WorkshopStartReq`/`WorkshopStepReq`/`WorkshopStepResp`/`WorkshopCommitResp` 的範本 |
| `StoryFlowAPI`、`storyFlowAPI`、`storyFlowOpenApi`、`applyTagsFor` 鏈 | `api/src/StoryFlow/Api.hs:394-427` | service-and-interfaces/F003 | `WorkshopAPI` 併入契約與 OpenAPI tag |
| `Api.Instances` 的 `ToSchema` 寫法(`strSchema`/`enumSchema`/`objSchema`/`named`) | `api/src/StoryFlow/Api/Instances.hs:133-153` | service-and-interfaces/F003 | `Session`/`StageDraft`/`Message`/`Role` 的 `ToSchema` 範本 |
| `handlers`、`vaultH`…`conflictH`、`app`、`bearerAuth` | `server/src/StoryFlow/Server.hs` | service-and-interfaces/F003 | `workshopH` 疊上去的既有骨架 |
| `AppState`、`run1`、`runIO`、`withEnvLocked` | `server/src/StoryFlow/Server/State.hs` | service-and-interfaces/F003 | `runEither` 的範本(`run1` 的邏輯原樣搬過來多一個 case 分支) |
| `toServerError`、`statusForCode`、`errorBody`、`knownCodes` | `server/src/StoryFlow/Server/Error.hs` | service-and-interfaces/F003 | `toWorkshopServerError`/`statusForWorkshopCode`/`knownWorkshopCodes` 的範本 |
| `acquireJudge`、`checkConflictB`、`conflictH` 的接線寫法 | `conflict/src/StoryFlow/Conflict/Pipeline.hs:375-381`、`cli/src/StoryFlow/Cli/Backend.hs:368-370`、`server/src/StoryFlow/Server.hs:199-202` | conflict-detection(已完成) | `LlmClient` 不跨 HTTP 的範本(逐字抄的對象,見任務指示) |

## 新增的介面

全部落在 `design.md` 對外契約的「工作坊那一列」內,沒有新增業務操作:

- CLI:`story-flow workshop start --type <型別> [--constraint <id>]…`、
  `story-flow workshop step <session-id> (--input <文字>|--input-file <檔案>|-)`、
  `story-flow workshop commit <session-id>`
- REST:`POST /workshop`(body `WorkshopStartReq`,回 `Session`)、
  `POST /workshop/:id/step`(body `WorkshopStepReq`,回 `WorkshopStepResp`)、
  `POST /workshop/:id/commit`(無 body,回 `WorkshopCommitResp`)
- DTO(`storyflow-api` 擁有):`WorkshopStartReq`、`WorkshopStepReq`、`WorkshopStepResp`、
  `WorkshopCommitResp`,四者的 `ToJSON`/`FromJSON`/`ToSchema` 都在 `StoryFlow.Api`(與
  `ContextReq`/`CheckReq` 同一處,理由相同:避免 `Api.Instances` 反向 import `Api`)
- `Session`/`StageDraft`/`Message`/`Role` 的 `ToSchema`(`storyflow-api` 擁有,新增到
  `StoryFlow.Api.Instances`)——**邊界判斷**:這四個型別的 `ToJSON`/`FromJSON` 歸
  `storyflow-workshop`(比照 `storyflow-conflict` 的 `Draft`/`ConflictOpts` 等——快照要序列化
  自己就得有 aeson 實例,不能等 `storyflow-api` 才生出來);但 `ToSchema` 需要 `openapi3`,
  而 `storyflow-workshop` 不該為了 OpenAPI 文件背上這個相依(比照 `storyflow-conflict` 不依賴
  `openapi3`、`ToSchema` 全部集中在 `StoryFlow.Api.Instances` 的既有分工)。這條邊界因此**不是
  本 feature 新發明**,是既有分工的延伸
- 錯誤映射:`toWorkshopServerError`、`statusForWorkshopCode`、`knownWorkshopCodes`
  (`StoryFlow.Server.Error`);`runEither`(`StoryFlow.Server.State`);`CliWorkshop`
  (`StoryFlow.Cli.Error` 的 `CliError` 新建構子)

### WorkshopError 的狀態碼與 code 映射表(本 feature 設計,分派鍵是字串)

| WorkshopError 建構子 | 提議的 `workshopErrorCode`(F002 需採用或本表回頭校正) | HTTP 狀態碼 | 理由 |
|---|---|---|---|
| `WsSessionNotFound` | `workshop_session_not_found` | 404 | 資源不存在,同 `entity_not_found` |
| `WsSnapshotCorrupt` | `workshop_snapshot_corrupt` | 500 | 磁碟上的資料壞了,不是客戶端的錯,同 `parse_failed` |
| `WsSnapshotWriteFailed` | `workshop_snapshot_write_failed` | 500 | 寫入失敗,同 `file_write_failed` |
| `WsNoStages` | `workshop_no_stages` | 422 | 型別存在但註冊表沒宣告 stages,語法對語意不成立 |
| `WsStagesExhausted` | `workshop_stages_exhausted` | 409 | 目前狀態不允許這個操作,同 `stale_revision` |
| `WsNothingToCommit` | `workshop_nothing_to_commit` | 409 | 目前狀態不允許 commit,同上一類 |
| `WsMissingRequiredField` | `workshop_missing_required_field` | 422 | 語法對、語意不成立,同 `validation_failed` |
| `WsLlmFailed LlmError` | **原樣沿用 `llmErrorCode`**(不折成單一代碼,同 `StoreFailed` 沿用 `storeErrorCode` 的既有紀律) | 見下 | 「上層不重寫下層的訊息」 |

`LlmError` 的 5 個既有 code(`llm/src/StoryFlow/Llm/Error.hs:74-80`)第一次跨過 HTTP,狀態碼由
本 feature 決定:

| `llmErrorCode` | HTTP 狀態碼 | 理由 |
|---|---|---|
| `llm_unavailable` | 503 | 連不上,可重試,同 HTTP 語意的 Service Unavailable |
| `llm_http_status` | 502 | 上游(LLM 端點)回了一個錯誤狀態碼,本服務是那個上游的閘道 |
| `llm_bad_response` | 502 | 上游回了 2xx 但形狀不對,同上一類的「上游行為異常」 |
| `llm_config_missing` | 422 | 這個 Vault 沒設定,語法對語意不成立 |
| `llm_config_invalid` | 422 | 設定在但不合法,同上一類 |

`unknown_type`(型別根本不在註冊表裡)**不經過這張表**:`startWorkshop` 若對不存在的型別
直接透過 `ServiceM` 外層拋 `ServiceError` 的 `UnknownType`(既有的 400 映射已經涵蓋),
`WsNoStages` 只處理「型別存在、但沒有 stages 宣告」這個更窄的情況——這個判斷寫在
`WorkshopError` 的建構子註解裡(`design.md`:「這個型別的註冊表宣告沒有 stages」,隱含型別
本身是找得到的)。

## TodoList

- [x] T1: `StoryFlow.Cli.Options` 加 `workshop` 名詞群(`start`/`step`/`commit` 三個子指令、
      三個 `Command` 建構子、`workshopInputP`/`sessionIdArg` 等解析小工具) `dep: -`
- [x] T2: `StoryFlow.Cli.Error` 加 `CliWorkshop WorkshopError` 建構子與三個總和函式的分支
      `dep: -`
- [x] T3: `StoryFlow.Api` 加 `WorkshopStartReq`/`WorkshopStepReq`/`WorkshopStepResp`/
      `WorkshopCommitResp` 四個型別(含 `ToJSON`/`FromJSON`/`ToSchema`)與 `WorkshopAPI`、
      併入 `StoryFlowAPI`、`storyFlowOpenApi` 的 tag 鏈 `dep: -`
- [x] T4: `StoryFlow.Api.Instances` 加 `Session`/`StageDraft`/`Message`/`Role` 的 `ToSchema`
      `dep: T3`
- [x] T5: `StoryFlow.Server.Error` 加 `toWorkshopServerError`/`statusForWorkshopCode`/
      `knownWorkshopCodes` `dep: -`
- [x] T6: `StoryFlow.Server.State` 加 `runEither`(泛型化 `run1` 的邏輯) `dep: -`
- [x] T7: `StoryFlow.Cli.Backend` 加 `startWorkshopB`/`stepWorkshopB`/`commitStageB`、私有的
      `stepFlow`/`commitFlow`/`acquireLlmClient`/`svcWs`,`client` 衍生區塊加三個 `cWorkshop*`
      函式 `dep: T1, T2, T3`
- [x] T8: `StoryFlow.Server` 加 `workshopH`(含私有 `stepFlow`/`commitFlow`/`acquireLlmClient`
      的伺服器端版本),`handlers` 串上它 `dep: T3, T5, T6`
- [x] T9: `StoryFlow.Cli.Render` 加 `renderWorkshopStarted`/`renderWorkshopCommit` `dep: -`
- [x] T10: `StoryFlow.Cli`(`Cli.hs`)的 `handle` 加三個 `Command` 分支,接上 T7/T9 的產物
      `dep: T7, T9`
- [x] T11: `cli/storyflow-cli.cabal`(library)加 `storyflow-workshop`、`storyflow-llm`;
      `api/storyflow-api.cabal` 加 `storyflow-workshop`;`server/storyflow-server.cabal`
      (library)加 `storyflow-workshop`、`storyflow-llm`;三份對應 test-suite 的
      `build-depends` 同步加 `storyflow-workshop`(cli/server 另加 `storyflow-llm`,供測試
      直接建 `LlmConfig`/`LlmClient` 測試替身) `dep: -`
- [x] T12: 三份 `CabalSpec.hs`(`cli`/`api`/`server`)的 `required` 清單加
      `"storyflow-workshop"`(cli/server 另加 `"storyflow-llm"`) `dep: T11`
- [x] T13: `api/test/StoryFlow/Api/ApiSpec.hs`:`expectedRoutes` 加 `workshopRoutes`
      (3 條),operation 數斷言 25 → 28,`readOnlyRoutes`/`revisionRoutes` 不含 workshop
      三條(三條都不帶 `revision`) `dep: T3`
- [x] T14: `api/test/StoryFlow/Api/SchemaSpec.hs` 加 `Session`/`StageDraft`/`Message`/`Role`/
      `WorkshopStartReq`/`WorkshopStepReq`/`WorkshopStepResp`/`WorkshopCommitResp` 的
      `aligns` 案例(`Role` 是列舉字串,不對齊 `aligns`,改驗 schema 的 `enum_`) `dep: T4`
- [x] T15: 新建 `server/test/StoryFlow/Server/WorkshopErrorMapSpec.hs`(仿
      `ErrorMapSpec.hs` 的表格式斷言:12 個 code 對狀態碼、錯誤 body 形狀、
      `knownWorkshopCodes` 無重複且涵蓋 `sampleWorkshopErrors` 產出的全部 code) `dep: T5`
- [x] T16: 新建 `server/test/StoryFlow/Server/WorkshopHandlerSpec.hs`(仿 `HandlerSpec.hs`
      T9:三條路由各跑一次成功案例 + `workshop_session_not_found` 的錯誤案例;成功案例的
      `step`/`commit` 需要一個本機的假 OpenAI 相容端點,測試自建 warp 假伺服器並把臨時
      Vault 的 `.storyflow/config.toml` 指過去) `dep: T8`
- [x] T17: 新建 `cli/test/StoryFlow/Cli/WorkshopCmdSpec.hs`(仿 `ContextCmdSpec.hs`:內嵌模式
      三個指令的成功案例、`--json` 信封、`start` 印出 id、`WsSessionNotFound` 的錯誤 code/
      message、exit code 1) `dep: T10`
- [x] T18: `cli/test/StoryFlow/Cli/OptionsSpec.hs` 加 `workshop start`/`step`/`commit` 的
      解析案例(`--constraint` 可重複、`--input`/`--input-file`/`-` 三選一、缺 `--type` 是
      用法錯誤) `dep: T1`
- [x] T19: `cli/test/StoryFlow/Cli/RemoteCmdSpec.hs` 加 workshop 三指令的遠端路徑案例
      (exit 0、`--json` 的 `data` 解得開) `dep: T7`
- [x] T20: `cli/test/StoryFlow/Cli/RenderSpec.hs` 加 `renderWorkshopStarted`/
      `renderWorkshopCommit` 的案例 `dep: T9`
- [x] T21: `cli/test/StoryFlow/Cli/ParitySpec.hs` 加「CLI 開的 session,REST 用同一個 id
      接得到 step」與「REST 開的,CLI 接得到 commit」兩個跨介面案例,以及
      `workshop step 不存在的 id` 的錯誤 code/message 兩邊相同 `dep: T10, T8`
- [x] T22: `cli/test/Spec.hs` 加 import 與 `spec` 呼叫(`WorkshopCmdSpec`);
      `server/test/Spec.hs` 加 `WorkshopErrorMapSpec`/`WorkshopHandlerSpec`;三份
      `.cabal` 的 test-suite `other-modules` 同步 `dep: T15, T16, T17`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Cli.OptionsSpec`(T18 新增案例) | `workshop` 三個子指令解析成正確的 `Command` |
| T2 | `StoryFlow.Cli.WorkshopCmdSpec`(T17) | `CliWorkshop` 的 code/message/exit code 透過端到端案例間接驗證 |
| T3 | `StoryFlow.Api.ApiSpec`(T13)、`StoryFlow.Api.SchemaSpec`(T14) | 路由存在、`ToJSON`/`ToSchema` 逐欄對齊 |
| T4 | `StoryFlow.Api.SchemaSpec`(T14) | `Session`/`StageDraft`/`Message`/`Role` schema 對齊 |
| T5 | `StoryFlow.Server.WorkshopErrorMapSpec`(T15) | 12 個 code 的狀態碼映射與錯誤 body 形狀 |
| T6 | `StoryFlow.Server.WorkshopHandlerSpec`(T16) | `runEither` 的行為由三條路由的端到端案例間接驗證 |
| T7 | `StoryFlow.Cli.WorkshopCmdSpec`(T17)、`RemoteCmdSpec`(T19) | 內嵌與遠端兩條路徑都跑得通 |
| T8 | `StoryFlow.Server.WorkshopHandlerSpec`(T16) | handler 端到端成功與錯誤案例 |
| T9 | `StoryFlow.Cli.RenderSpec`(T20) | 兩個 render 函式的輸出文字 |
| T10 | `StoryFlow.Cli.WorkshopCmdSpec`(T17) | `handle` 的三個新分支 |
| T11 | 三份 `CabalSpec.hs`(T12 的斷言依附在這裡) | `build-depends` 真的加上了 |
| T12 | `StoryFlow.Cli.CabalSpec` / `StoryFlow.Api.CabalSpec` / `StoryFlow.Server.CabalSpec` | `required` 清單命中 |
| T13 | `StoryFlow.Api.ApiSpec` | operation 數 28、`workshopRoutes` 三條逐一比對、無 `revision` |
| T14 | `StoryFlow.Api.SchemaSpec` | 見上 |
| T15 | `StoryFlow.Server.WorkshopErrorMapSpec` | 見上 |
| T16 | `StoryFlow.Server.WorkshopHandlerSpec` | 見上 |
| T17 | `StoryFlow.Cli.WorkshopCmdSpec` | 見上 |
| T18 | `StoryFlow.Cli.OptionsSpec` | 見上 |
| T19 | `StoryFlow.Cli.RemoteCmdSpec` | 見上 |
| T20 | `StoryFlow.Cli.RenderSpec` | 見上 |
| T21 | `StoryFlow.Cli.ParitySpec` | CLI/REST 同一個 session id 互通、錯誤兩邊一致 |
| T22 | 全部測試套件能編譯並跑起來(`cabal test all`) | Spec.hs 與 cabal 的 `other-modules` 沒有漏接 |

## 待確認假設

- A1:`Session`/`StageDraft`/`Message`/`Role`/`WorkshopError` 的**JSON 欄位命名**(例如
  `wsId` → `"id"`)採用全系統既有慣例(`StoryFlow.Core.Json`/`StoryFlow.Conflict.Json` 說明的
  「去 Haskell 前綴、多字 snake_case、`Maybe` 沒值時整個鍵不出現」),但這三個型別的
  `ToJSON`/`FromJSON` 實際定義在 F002/F003(尚未實作)→ 採取:本文檔的 `ToSchema` 與 CLI 渲染
  按這個慣例假設欄位名 → 影響:若 F002/F003 實際採用不同欄位名,`Api.Instances` 的
  `ToSchema Session`/`StageDraft`/`Message`/`Role` 要跟著改,`SchemaSpec` 的 `aligns` 測試會
  在實作階段立刻抓到落差(不會靜默通過)
- A2:`workshopErrorCode` 的 7 個非 `WsLlmFailed` 建構子字串(如 `workshop_session_not_found`)
  是本文檔**提議**的,F002 的實際實作尚未存在 → 採取:server/CLI 的分派鍵一律走字串比對
  (不 pattern match 建構子),與既有 `errorCode`/`statusForCode` 同一紀律,即使 F002 最終選
  了不同字串,`statusForWorkshopCode` 與 `knownWorkshopCodes` 只需要同步改字串常數,不動任何
  分派邏輯 → 影響:F002 實作時應優先採用本表提議的字串(減少一次同步);若 F002 已有更好的
  理由用別的字串,回頭改本文檔與 `StoryFlow.Server.Error` 即可,屬局部改動
- A3:契約卡寫「`CliError` 的四個建構子」,但 `cli/src/StoryFlow/Cli/Error.hs` 目前實際是
  **五個**(`CliService`/`CliRemote`/`CliResolve`/`CliInput`/`CliUsage`,`CliInput` 是後來加的)
  → 採取:以程式碼為準,`CliWorkshop` 是加入既有五個之後的第六個 → 影響:無,純粹是契約卡的
  過期描述,不影響本 feature 的設計
- A4:`WorkshopStepReq`/`WorkshopStepResp`/`WorkshopCommitResp`/`WorkshopStartReq` 這四個
  wrapper 型別是否該改放 `storyflow-workshop`(比照 `Session` 本身)而不是 `storyflow-api`
  →採取:放 `storyflow-api`,理由是它們是 **HTTP 傳輸層才需要的形狀**(把 tuple 拆平、把
  `type`/`constraints` 包成有名字的物件),`ServiceM` 的操作簽名完全不需要它們,與
  `NewVaultReq`/`ContextReq`/`CheckReq` 屬於同一類「REST 專屬的請求/回應包裝」→ 影響:低,
  即使日後想搬,四個型別內部只是欄位重排,不影響 CLI/REST 的外部行為
- A5:`workshop step` 的 `--input`/`--input-file` 旗標名與 `commit`/`start` 的確切選項在
  `design.md` 契約卡裡沒有逐字給出(卡上只寫了 `start --type [--constraint]…`)→ 採取:比照
  `context`/`conflict check` 既有的「三選一必填正文來源」慣例設計,`--constraint` 沿用
  `context` 的 `--ref` 同一種 `Id` 讀取邏輯只是換旗標名 → 影響:若開發者對旗標命名有不同偏好,
  純粹是 `Options.hs` 內部改字串,不影響其餘介面表的設計
- A6:`StoryFlow.Api.Instances` 需要對 `Session`/`StageDraft`/`Message`/`Role` 四個型別加
  `ToSchema`(T4),但 `Message` 落地時**沒有** `Data.Aeson.ToJSON` 實例——`StoryFlow.Llm.Client`
  刻意不定義它(門面之外的內部細節),`Session` 的 `wsHistory` 是靠
  `StoryFlow.Workshop.Session` 內部未匯出的 `messageJson`/`roleWire` 手動編碼,不是走
  `ToJSON Message` → 採取:`SchemaSpec` 對 `Message` 的驗證改成拿 `sampleSession` 實際
  `toJSON` 出來的 `history` 陣列第一筆物件的鍵集合,與 `Message` 的 `schemaKeys` 比對(不是
  標準的 `aligns`,因為沒有 `ToJSON Message` 可比);`Role` 則依 T14 原定的作法驗 `enum_`
  → 影響:低,`Api.Instances` 的 `ToSchema Message`/`ToSchema Role` 本身逐欄對齊落地的
  wire 格式,只是驗證手法換了一種,不影響 REST 契約本身
- A7:F004 文檔原本沒列出 `storyflow-api` 需要 `storyflow-llm`(T11 只寫了
  `api/storyflow-api.cabal` 加 `storyflow-workshop`)→ 採取:實作時發現
  `StoryFlow.Api.Instances` 對 `Message`/`Role` 寫 `ToSchema` 一定要 import
  `StoryFlow.Llm` 的型別本身,`storyflow-api` 因此補上 `storyflow-llm`(library 與
  test-suite 都補),並同步把它加進 `StoryFlow.Api.CabalSpec` 的 `required` 清單
  → 影響:純粹是 build-depends 的必要補充,不是新的公開介面,`storyflow-llm` 與
  `storyflow-conflict` 同一種「上游型別套件、不是實作端」的性質,沒有把 `servant-server`/
  `servant-client`/`warp` 帶進 `storyflow-api`

## 實作備註

- T13 之外還有一處既有測試因為新增路由而必須同步更新,但 F004 文檔與任務指示都沒有點名它:
  `api/test/StoryFlow/Api/OpenApiSpec.hs` 的「paths 數等於實際的路徑數」斷言原本釘死
  `16` 條路徑、`25` 個 operation,新增三條 workshop 路由後改成 `19`/`28`;
  `expectedSchemas` 清單也補上 `WorkshopStartReq`/`WorkshopStepReq`/`WorkshopStepResp`/
  `WorkshopCommitResp`/`Session`/`StageDraft`/`Message`/`Role` 八個新具名 schema。這條斷言
  與 `ApiSpec.hs` 的 operation 數斷言是同一件事的兩個獨立副本(刻意不共用來源,兩邊對不上
  時才有東西可比),因此兩邊都要動,不只 T13 點名的那一個
- T16 的「本機的假 OpenAI 相容端點」需要能在請求送出**之前**把臨時 Vault 的
  `.storyflow/config.toml` 寫入 `[llm]` 段,而既有的 `StoryFlow.Server.Fixtures.withServer`
  不會把 Vault 根目錄交出去(只給 `ClientEnv`)。新增了 `withServerDir`(與 `withServer` 同一份
  邏輯,多回傳 `FilePath`)並把它加進 Fixtures 的匯出清單;同時把 `Api` 記錄型別與 `client`
  的模式比對延伸三個工作坊欄位(`cWorkshopStart`/`cWorkshopStep`/`cWorkshopCommit`),供
  `WorkshopHandlerSpec` 直接用 `api` 呼叫——與既有 25 個欄位同一種寫法
- `cli/storyflow-cli.cabal` 的 test-suite 原本沒有 `http-types`,但 `WorkshopCmdSpec`/
  `RemoteCmdSpec`/`ParitySpec` 都需要起本機的 warp stub(`Network.HTTP.Types.Status`),因此
  補上這一項套件相依(純測試相依,不影響 library 的邊界)
