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

> 本文檔是對 2026-08-22 契約變更後的**重寫**,取代舊版。舊版的兩條「待確認假設」
> (A1:擴充 `ServiceError`;A2:沿用 `vaultInfo` 拿 vault root)已被開發者**推翻**,
> 結論已寫進 `design.md` 的「對外契約」章節,本文檔逐字照新契約重寫,不再是那兩條
> 假設的延伸。

## 功能概述

新建套件 `storyflow-workshop`,提供工作坊管線「定案之前」的那一段:`startWorkshop`
建立一次工作坊、`stepWorkshop` 送一輪對話給地端/雲端模型並把回覆解析成片段草稿、
`loadSession` 讓中斷後的工作坊接得回去。三者與 `WorkshopError` 一起,是本 feature
的全部對外面。

驗收標準逐條:

| # | 驗收標準 | 怎麼算通過 |
|---|---|---|
| 1 | 階段清單完全來自型別註冊表的 `stages`,新增一個型別不改工作坊的程式 | `wsStages` 由 `listEntityTypes` 找到的 `EntityTypeSpec.etsStages` 直接指定,程式裡沒有任何寫死的階段名字或型別鍵 |
| 2 | 硬約束片段以 `summary` 進 prompt | `stepWorkshop` 組 system message 時,`wsConstraints` 逐一經 `getEntity` 取 `metaSummary`,不送 `entBody` |
| 3 | `Session` 是可序列化的快照,落在 `.storyflow/workshops/<id>.json`,中斷後 `loadSession` 接得回去 | 三個寫入操作(`startWorkshop`/`stepWorkshop`,以及未來 `commitStage`)各自在成功後寫出快照;`loadSession` 讀同一個檔案能重建出等價的 `Session`;快照路徑經新增的 `vaultRoot :: ServiceM FilePath` 取得 |
| 4 | 對話歷程不進圖譜 | `wsHistory` 只落在 `.storyflow/workshops/`(索引掃描略過 `.` 開頭路徑),不呼叫任何 `createEntity`/`addFragment` |
| 5 | `stepWorkshop` 從模型回覆解析約定 JSON 存進 `wsPending`,解析失敗時保留上一次成功的值、回覆照樣給人看 | 模型回覆不含合法 JSON(或根本没有)時 `wsPending` 不變,但 `wsHistory` 與快照仍然更新,回傳的 `Text` 仍是這次的原始回覆 |
| 6 | `LlmError` 由 `WsLlmFailed` 原樣包住浮上來,不攤平也不折成泛用失敗 | `chat` 回 `Left e` 時 `stepWorkshop` 回 `Right (Left (WsLlmFailed e))`(`e` 同一個建構子與內容),不寫快照、`Session` 不變 |

明確**不做**(契約卡的硬邊界):不寫圖譜(`commitStage`/`NewEntityReq` 是 `workshop-emit`
的事,F002 完全不 import `createEntity`/`addFragment`);不定義 CLI 與 REST 形狀(那是
`workshop-interface`);不自己實作 LLM 端點(`chat` 是 `storyflow-llm` 的既有介面,原樣呼叫);
**不往 `storyflow-service` 的 `ServiceError` 加 `Workshop*` 建構子**。

## 相依性

`depends-on: [F001, entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001]`。
四條全是**程式碼級**相依——四份文檔皆 `done`,對應原始碼已在樹上讀過。

- **`F001`(llm-workshop-mcp,同子系統)**:`storyflow-llm` 的門面 `StoryFlow.Llm` 提供
  `LlmClient` / `newLlmClient` / `chat` / `Message` / `Role` / `LlmError` / `renderLlmError` /
  `llmErrorCode`。F002 呼叫 `chat`,不建立 `LlmClient`(那是呼叫端——`workshop-interface`
  ——的事:`stepWorkshop` 的簽名直接吃 `LlmClient` 參數);`WorkshopError` 的
  `WsLlmFailed` 建構子原樣包住 `LlmError`,`renderWorkshopError` 對它取
  `renderLlmError`、`workshopErrorCode` 對它取 `llmErrorCode`
- **`entity-graph-core/F002`(core-types-and-registry)**:`Id`(`wsConstraints` / `wsOwner` /
  `wsCommitted` 的元素型別)、`Entity` / `Meta`(讀 `metaSummary` 組 prompt)、
  `EntityTypeSpec`(`etsStages` 就是階段清單來源,`etsKey` 用來比對型別)、
  `fnv1a64`(session id 產生的雜湊原語)全部定義在這裡
- **`entity-graph-core/F004`(store-vault-io-and-index)**:`store/src/StoryFlow/Store/Vault.hs`
  的 `initVault` 是本 feature 唯一直接改動的 `storyflow-store` 原始碼(`.storyflow/.gitignore`
  多寫一行 `workshops/`,見「實作方式」第三節與 D6/S5)。這是**原始碼編輯**,不是
  `storyflow-workshop.cabal` 的相依——套件邊界測試(T12)仍然擋著 `storyflow-store`。
  同一份檔案的 `vaultRoot :: Vault -> FilePath`(`Vault` 記錄欄位存取子)只作為**命名
  衝突查證**——`storyflow-workshop` 不依賴它、不 import `storyflow-store`
- **`service-and-interfaces/F001`(service-contract)**:`ServiceM` / `Env` / `runService` /
  `ServiceError` / `getEntity` / `listEntityTypes` 全部定義在 `service/src/StoryFlow/Service*.hs`。
  F002 也**擴充**這個檔案——但只加一個內嵌出口 `vaultRoot :: ServiceM FilePath`(見
  「新增的介面」第二節,`service-and-interfaces/design.md` 已於 2026-08-22 記下這個契約),
  **不再**加任何 `ServiceError` 建構子(舊版的 A1 已被推翻)

**可否平行開發**:F002 是階段二第一個項目,`design.md` 的功能規劃列著 `workshop-emit`
(#3)依賴 `#2`(本 feature)、`workshop-interface`(#4)依賴 `#3`。三者是**序列**,
F002 完成前 `workshop-emit` 無法動工(`commitStage` 的簽名吃 `Session`,而 `Session`
的型別、`WorkshopError` 的定義都由 F002 給出)。F002 與階段三的 `mcp-adapter` 互不相依,
理論上可平行,但 `mcp-adapter` 依賴 `service-and-interfaces` 而非本子系統,實際排程由
編排者決定。

## 對應的 Level 2 契約

| 契約出處 | 條目 | 本 feature 的落點 |
|---|---|---|
| `llm-workshop-mcp/design.md` 對外契約 | `data WorkshopError = WsSessionNotFound Text \| WsSnapshotCorrupt FilePath Text \| WsSnapshotWriteFailed FilePath Text \| WsNoStages Text \| WsStagesExhausted Text \| WsNothingToCommit Text \| WsLlmFailed LlmError` | `StoryFlow.Workshop.Error.WorkshopError`(七個建構子**全部**定義在本 feature;`WsNothingToCommit` F002 不產生,留給 F003 的 `commitStage`) |
| 同上 | `renderWorkshopError :: WorkshopError -> Text` / `workshopErrorCode :: WorkshopError -> Text` | `StoryFlow.Workshop.Error` |
| 同上 | `startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)` | `StoryFlow.Workshop.Stages.startWorkshop` |
| 同上 | `loadSession :: Text -> ServiceM (Either WorkshopError Session)` | `StoryFlow.Workshop.Session.loadSession` |
| 同上 | `stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))` | `StoryFlow.Workshop.Stages.stepWorkshop` |
| 「模組間公開介面與資料結構」 | `data Session = Session {..}`(含 `wsOwner` / `wsPending`) | `StoryFlow.Workshop.Session` |
| 同上 | `data StageDraft = StageDraft {..}` | `StoryFlow.Workshop.Session` |
| 同上 | `Workshop.Stages → Llm.Client`:只用 `chat` 的簽名 | `stepWorkshop` 呼叫 `StoryFlow.Llm.chat`,不知道後端是地端還是雲端 |
| 同上 | `Workshop.Stages → Workshop.Session`:讀寫 `Session`,狀態只在這裡變動 | `startWorkshop` / `stepWorkshop` 呼叫 `Workshop.Session` 的 `loadSession` / `saveSession` / id 產生,不自己組快照的 bytes |
| 「Session 快照的落地位置」批次澄清 | 落 `.storyflow/workshops/<id>.json`,三個寫入操作各自在成功後寫出快照;vault root 走新增的 `vaultRoot`,不沿用 `vaultInfo` | `Workshop.Session.saveSession`,由 `startWorkshop` / `stepWorkshop` 在成功路徑呼叫 |
| 「工作坊的錯誤語彙」批次澄清(F002 的 A1 裁決) | 不擴充 `ServiceError`;`storyflow-workshop` 自己一套 `WorkshopError`;`ServiceM` 本身的 `ServiceError` 通道仍用於業務層落地失敗(型別未知、硬約束不存在) | `startWorkshop` 對「型別不在註冊表」與「硬約束 id 不存在」原樣走 `ServiceM` 的 `throwError` / 既有的 `getEntity`,不轉譯成 `WorkshopError` |
| 「硬約束怎麼進 prompt」 | `wsConstraints` 以 `summary` 進 system message | `stepWorkshop` 組 prompt 的私有函式 |

**沒有超出契約的新公開介面**。有一處**擴充既有套件的公開面**:`storyflow-service`
新增內嵌出口 `vaultRoot :: ServiceM FilePath`(2026-08-22 已寫進
`service-and-interfaces/design.md`,操作數 26 → 27,只開內嵌出口,不接 CLI 與 REST——
本文檔**不**改那份文檔,詳見「新增的介面」)。`storyflow-store` 的 `initVault` 有一處
**內容改動**(不改介面簽名,只改它寫出的 `.gitignore` 內容)。

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
| `StoryFlow.Workshop.Error` | `WorkshopError`、`renderWorkshopError`、`workshopErrorCode` | 契約定義了完整的錯誤語彙,但契約卡的「負責模組」只列 `Workshop.Session` / `Workshop.Stages` 兩個名字——與 `llm-endpoint`(F001)同一個先例:那份契約卡也只列 `Llm.Client` / `Llm.Config`,`LlmError` 卻獨立成 `StoryFlow.Llm.Error`(已讀過原始碼確認)。錯誤型別獨立成模組是這個子系統一貫的切法,不是本 feature 發明的 |
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
`Control.Monad.Except.throwError`——**用途窄化**:新契約下 `WorkshopError` 一律經
`Either` 回傳,`throwError` 只在「型別不在註冊表」(重用既有的 `ServiceError` 建構子
`UnknownType`)這一種情況下還會被呼叫,其餘全部改成 `pure (Left ...)`(見第六、八節)。
`time` 給 `Data.Time.getCurrentTime`(session id 產生用)。`directory` / `filepath` 給快照的
目錄建立與原子寫入(`storyflow-workshop` 不依賴 `storyflow-store`,所以不能用它的
`atomicWriteText`,自己用 `directory` 的 `renamePath` 寫一份同構的邏輯,見第五節)。

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

### 二、`storyflow-service`:新增 `vaultRoot :: ServiceM FilePath`

**這個函式現在不存在**,由本 feature 加。理由與 `vaultConfig`(F001 已加)完全一樣:
`storyflow-workshop` 不能依賴 `storyflow-store`,而快照路徑需要 vault root——`vaultRoot`
就是這條路徑唯一合法的內嵌出口。**不沿用 `vaultInfo`**:它的實作是
`listEntities conn emptyFilter` 再 `length`(見 `service/src/StoryFlow/Service.hs:146-150`,
已讀過原始碼),為了 `vvEntityCount` 每次都要把整個 Vault 的 Entity 列一遍,而快照
**每一 step 寫一次**,這個代價不值得。

```haskell
vaultRoot :: ServiceM FilePath
vaultRoot = asks (S.vaultRoot . envVault)
```

**命名衝突**(已讀 `store/src/StoryFlow/Store/Vault.hs`,`vaultRoot :: Vault -> FilePath`
是 `Vault` record 的欄位存取子,由 `StoryFlow.Store` re-export):`service/src/StoryFlow/Service.hs`
目前 `import StoryFlow.Store hiding (addFragment, addNode, deleteEntity, deleteLevel,
listEntities, listLevels, removeNode)`**沒有**隱藏 `vaultRoot`,而 `createVault` /
`listVaults` / `vaultInfo` 三處都直接呼叫裸的 `vaultRoot v`(已讀過)。加一個同名的
頂層綁定會撞名,處理方式:

1. `hiding` 清單追加 `vaultRoot`
2. 既有三個呼叫點(`createVault` 兩處、`vaultInfo` 一處)改成 `S.vaultRoot v`
   (`import qualified StoryFlow.Store as S` 已經存在,不必新增 import)
3. 匯出清單的「Vault」小節加入 `vaultRoot`(排在 `vaultConfig`之後)

**不需要任何新相依**:`Vault` 型別與它的欄位存取子已經在 `storyflow-store` 裡,
`service/storyflow-service.cabal` 的 `build-depends` 一個字都不用改——
`service/test/StoryFlow/Service/CabalSpec.hs` 的逐字守衛(`libraryInternal`)因此不受影響。

### 三、`store` 的 `initVault`:`.gitignore` 多一行

`store/src/StoryFlow/Store/Vault.hs` 的 `initVault`(已讀過)目前寫
`atomicWriteText (storyflowDir root </> ".gitignore") "index.db\n"`。改成
`"index.db\nworkshops/\n"`(D6/S5)。簽名不變,只改內容——這不是相依關係的擴張,
`storyflow-workshop.cabal` 仍然禁止 `storyflow-store`。

### 四、`Workshop.Error`:`WorkshopError` 與渲染

```haskell
data WorkshopError
  = WsSessionNotFound Text
  | WsSnapshotCorrupt FilePath Text
  | WsSnapshotWriteFailed FilePath Text
  | WsNoStages Text
  | WsStagesExhausted Text
  | WsNothingToCommit Text
  | WsLlmFailed LlmError
  deriving stock (Show, Eq)
```

逐字等於 `design.md` 對外契約的定義。**F002 只產生前五個與 `WsLlmFailed`**(`WsNothingToCommit`
是 `commitStage`/F003 的事);`renderWorkshopError` / `workshopErrorCode` 仍然要對全部七個
建構子窮盡(`-Wall` 的 `-Wincomplete-uni-patterns`/`case` 完整性要求),F002 因此**定義好
`WsNothingToCommit` 的渲染文案**,F003 直接沿用不必再改這個模組。

`renderServiceError` / `errorCode`(`StoryFlow.Service.Error`,已讀過)是形狀範本:

```haskell
renderWorkshopError :: WorkshopError -> Text
renderWorkshopError = \case
  WsSessionNotFound sid ->
    "找不到 session「" <> sid <> "」的快照;請確認 id 是否打錯,或用 `workshop start` 開新的"
  WsSnapshotCorrupt path detail ->
    "快照檔 " <> T.pack path <> " 讀得到但不是合法的 Session JSON:" <> detail
      <> ";如果不是手動改壞的,請回報這個問題"
  WsSnapshotWriteFailed path detail ->
    "寫入快照 " <> T.pack path <> " 失敗:" <> detail <> ";請檢查磁碟空間與寫入權限"
  WsNoStages ty ->
    "型別「" <> ty <> "」在型別註冊表裡沒有宣告任何 stages,無法開始工作坊;"
      <> "請先在 types/registry/ 補上 stages"
  WsStagesExhausted sid ->
    "session「" <> sid <> "」的階段已經走完,不能再 step;請改用 `workshop commit` 定案"
  WsNothingToCommit sid ->
    "session「" <> sid <> "」目前沒有待定案的草稿;請先 `workshop step` 讓模型產出草稿"
  WsLlmFailed e -> renderLlmError e

workshopErrorCode :: WorkshopError -> Text
workshopErrorCode = \case
  WsSessionNotFound _ -> "workshop_session_not_found"
  WsSnapshotCorrupt _ _ -> "workshop_snapshot_corrupt"
  WsSnapshotWriteFailed _ _ -> "workshop_snapshot_write_failed"
  WsNoStages _ -> "workshop_no_stages"
  WsStagesExhausted _ -> "workshop_stages_exhausted"
  WsNothingToCommit _ -> "workshop_nothing_to_commit"
  WsLlmFailed e -> llmErrorCode e
```

`WsLlmFailed` 的兩個函式都**往內取** `renderLlmError` / `llmErrorCode`,與 `ServiceError`
的 `errorCode` 對 `StoreFailed` 往內取 `storeErrorCode` 同一個做法(已讀過
`service/src/StoryFlow/Service/Error.hs` 確認這個先例)。

### 五、`Workshop.Session`:`Session` / `StageDraft` 與 JSON 編碼

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
`FromJSON Id`(`StoryFlow.Core.Json`,字串編碼,已讀過確認存在),`storyflow-workshop`
依賴 `storyflow-core` 所以這個孤兒實例本來就在作用域裡,不必也不該重新定義一次。

**`Message` / `Role` 不加孤兒實例**:`StoryFlow.Llm.Client` 的原始碼與 haddock(已讀過)
明講「刻意不定義 `ToJSON` / `FromJSON` 實例在公開型別上」——`Session` 的 `ToJSON` 因此
**手動**把 `wsHistory` 轉成 `[Value]`(每個 `Message` → `object ["role" .= <text>, "content"
.= msgContent m]`,`<text>` 是套件內部私有的 `System` / `User` / `Assistant` → `"system"` /
`"user"` / `"assistant"` 對照,與 `Llm.Client` 內部的 `roleWire` 同樣的字串但各自一份),
`FromJSON` 反向解析同一組字串,不認得的值當 `FromJSON` 失敗。

### 六、`Workshop.Session`:快照路徑、原子寫入、`loadSession`

快照路徑:`root </> ".storyflow" </> "workshops" </> (T.unpack sid <> ".json")`,`root`
由**新增的** `vaultRoot :: ServiceM FilePath`(見第二節)取得。路徑字串用字面組
(`".storyflow"` / `"workshops"`),不 import `storyflow-store` 的 `storyflowDir` ——與
`llm/test/StoryFlow/Llm/Fixtures.hs` 的 `appendConfig` 同一個理由:那個套件的相依清單
裡沒有 `storyflow-store`,本套件也沒有。

**錯誤通道的形狀變了**:`ServiceM` 只認得 `MonadError ServiceError`,`WorkshopError`
不是它的例外型別,因此 `saveSession` / `loadSession` **不能** `throwError`,失敗一律
`pure (Left ...)`:

```haskell
saveSession :: Session -> ServiceM (Either WorkshopError ())
```

1. 經 `vaultRoot` 取 `root`,組出 `workshops/` 目錄與目標檔路徑
2. `liftIO (createDirectoryIfMissing True workshopsDir)`——第一次寫快照時這個目錄還不存在
3. 同目錄開暫存檔(`directory` 的 `openBinaryTempFile` 風格,與
   `StoryFlow.Store.Atomic.atomicWriteText` 同一個原子寫入手法,已讀過該檔案確認:
   暫存檔與目標檔同一個目錄,寫完 `hFlush` / `hClose` 再 `renamePath` 覆蓋),寫入
   `Data.Aeson.encode session`(UTF-8 位元組,`aeson` 內建不加 BOM)
4. 整段 IO(含步驟 2、3)用 `Control.Exception.try` 包住;任何 `IOException` →
   `pure (Left (WsSnapshotWriteFailed path (顯示例外訊息)))`;成功 → `pure (Right ())`

這是**同構**於 `StoryFlow.Store.Atomic.atomicWriteText` 的邏輯,而不是呼叫它——後者定義在
`storyflow-store`,本套件的相依清單擋著這個名字。兩份實作各自完整、互不依賴,是刻意付的
小額重複,換來的是套件邊界測試(T12)能繼續逐字釘住「library 不含 store」。

```haskell
loadSession :: Text -> ServiceM (Either WorkshopError Session)
```

1. 經 `vaultRoot` 組出同一條路徑
2. `liftIO (doesFileExist path)`;`False` → `pure (Left (WsSessionNotFound sid))`
3. 讀檔 → `Data.Aeson.eitherDecodeStrict'`(或等效的嚴格版本)解析成 `Session`;`Left err`
   → `pure (Left (WsSnapshotCorrupt path (T.pack err)))`;`Right s` → `pure (Right s)`

**`Workshop.Session` 的 session id 產生**(`newSessionId :: Text -> [Id] -> ServiceM Text`,
供 `startWorkshop` 呼叫,不變於舊版設計):

`Session` 的 `wsId :: Text` 不是 `StoryFlow.Core.Id.Id`——後者的建構子只認得四個封閉前綴
(`ent` / `lvl` / `nod` / `vlt`,`StoryFlow.Core.Id.IdPrefix`,已讀過),工作坊 session 不是
這四種實體之一,`mkId` 用不上。改用 `Core.Id` **有匯出**的雜湊原語 `fnv1a64 :: BS.ByteString
-> Word64`(已讀過確認匯出)自己組:對 `(型別鍵, 硬約束 id 清單, 目前時間, salt)` 串成的
位元組雜湊、取低 32 位、十六進位定寬 8 碼,前綴 `wksp-`(`wksp-3f9a2c10` 這種形狀)。
碰撞處理:算出候選 id 後檢查 `.storyflow/workshops/<candidate>.json` 是否已存在,存在就
`salt + 1` 重算,最多重試一個保守上限(例如 5 次)後仍碰撞就視為異常(兜底,回
`WsSnapshotWriteFailed` 用一個固定的「session id 產生失敗」訊息;理論上不會發生)。

### 七、`Workshop.Stages`:`startWorkshop`

```haskell
startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)
```

1. `listEntityTypes >>= \specs -> case find ((== ty) . etsKey) specs of ...`——找不到 →
   `throwError (UnknownType ty)`。**這一步走 `ServiceM` 原生的 `ServiceError` 通道,不是
   `WorkshopError`**——`design.md` 明講「型別未知」是業務層失敗,`UnknownType` 是
   `storyflow-service` 的 `createEntity` 對同一種情況已經在用的建構子(重用,不新增)
2. 找到但 `null (etsStages spec)` → `pure (Left (WsNoStages ty))`——這一步才是
   `WorkshopError`:「工作坊自己的失敗」,驗收標準 1 的反面
3. 逐一對 `constraints` 呼叫 `getEntity`(丟棄回傳值,只驗證存在)——目標不存在時
   `getEntity` 已經會丟 `StoreFailed (EntityNotFound i)`,同樣走 `ServiceError` 通道,
   不需要另外處理。及早失敗(建立 session 時就驗,不留到第一次 `stepWorkshop` 才發現
   某個 id 打錯了),見「待確認假設」A1
4. 呼叫 `Workshop.Session` 的 id 產生,組出初始 `Session`:`wsStages = etsStages spec`、
   `wsCurrent = 0`、`wsHistory = []`、`wsOwner = Nothing`、`wsPending = []`、
   `wsCommitted = []`
5. `saveSession` 寫出快照——`Left werr` → `pure (Left werr)`(**原樣往上浮**,不再包一層);
   `Right ()` → `pure (Right session)`

`ServiceM (Either WorkshopError Session)` 因此有**兩層**失敗:外層(`runService` 才看得到的
`ServiceError`,步驟 1、3)是業務層失敗;內層(`Left` 值,步驟 2、5)是工作坊自己的失敗。
兩者互不轉譯,各自原樣浮上去。

### 八、`Workshop.Stages`:prompt 組裝

私有函式,組出這一輪要送給 `chat` 的 `[Message]`,**與舊版設計不變**(A1/A2 兩條裁決不
影響這一節):

```haskell
buildMessages :: Session -> [(Id, Text)] -> Text -> [Message]
```

第二個參數是**已經取好**的硬約束 `(Id, summary)` 清單。System message 依序排:

1. 開場一句:「你正在引導使用者完成『{型別}』的第 {N}/{總數} 個階段:『{階段名}』。」
   (`N` = `wsCurrent + 1`,`階段名` = `wsStages !! wsCurrent`)
2. 硬約束區塊(有的話):逐條「【既有設定 {id}(只有 summary)】{summary}」——與
   `Conflict.Judge.renderPairPrompt`(已讀過)同一個「id + 內容」的呈現方式,但這裡
   只送 `summary`(驗收標準 2)
3. 格式指示:要求模型在對使用者的自然語言回覆之外,**另外**用一個 ` ```json ` 圍起來的
   區塊附上目前這個階段可以定案的片段草稿,陣列形狀 `[{"title":…, "summary":…, "body":…,
   "tags":[…]}]`;沒有想清楚就附 `[]`;可以附多個

Messages 全體 = `[Message System systemPrompt] ++ wsHistory session ++ [Message User input]`
——`wsHistory` 只存使用者/模型的往返,system message 每次呼叫時重新組(硬約束的 summary
可能隨時間被改過,現讀現送比存一份舊的更正確)。

### 九、`Workshop.Stages`:`stepWorkshop`

```haskell
stepWorkshop :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))
```

1. `wsCurrent session >= length (wsStages session)` → `pure (Left (WsStagesExhausted
   (wsId session)))`——防禦性檢查:正常流程下 `startWorkshop` 已擋掉零階段的型別,但一個
   已經被 `commitStage`(F003)推到最後一階之後的 `Session` 仍可能被呼叫端誤傳進來
2. 逐一對 `wsConstraints session` 呼叫 `getEntity`,取 `metaSummary . entMeta . evEntity`
   組成 `(Id, Text)` 清單(重用 `startWorkshop` 已經驗證過存在,但**不快取**——見「待確認
   假設」A1,現讀現送)。這一步若某個 id 已被刪除,`getEntity` 一樣走 `ServiceError`
   原生通道
3. `buildMessages session constraintSummaries input` 組出 `[Message]`
4. `liftIO (chat client messages)`
5. `Left e` → `pure (Left (WsLlmFailed e))`。**不寫快照、`Session` 不變**——這一步什麼都
   沒發生,`wsHistory` 不該記一輪沒有下文的失敗嘗試
6. `Right reply`:
   a. `newHistory = wsHistory session ++ [Message User input, Message Assistant reply]`
   b. 對 `reply` 跑 JSON 擷取(見下),成功 → `newPending`;失敗 → 沿用
      `wsPending session`(驗收標準 5)
   c. `newSession = session { wsHistory = newHistory, wsPending = newPending }`
   d. `saveSession newSession` ——`Left werr` → `pure (Left werr)`(原樣浮上去);
      `Right ()` → `pure (Right (newSession, reply))`——`reply` 是**原始**回覆,不剝 JSON、
      不做任何加工

**JSON 擷取**(`extractDrafts :: Text -> Maybe [StageDraft]`,純函式,與
`Conflict.Judge.parseVerdict`——已讀過——同一套立場但獨立實作,不同套件、不同 schema,
`storyflow-workshop` 不依賴 `storyflow-conflict`,只重用做法):

1. 在 `reply` 裡找**第一段** ` ``` ` 圍起來的區塊(邏輯與 `Judge.locateFence` /
   `dropLangTagLine` 同構:語言標記行整行丟掉;找不到 fence 就退回整段文字本身)
2. 對取到的內容跑 `Data.Aeson.eitherDecodeStrictText :: Text -> Either String [StageDraft]`
3. 失敗時退回「第一個 `[` 到最後一個 `]`」的切片再 decode 一次(`Judge.sliceBraces` 的方括號
   版本)
4. 兩次都失敗 → `Nothing`。**不捏假資料**,呼叫端(`stepWorkshop` 第 6b 步)在 `Nothing` 時
   原樣保留舊的 `wsPending`
5. 解出空陣列 `[]` **算成功**——`newPending = []`,不是「保留舊值」

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)` | `llm/src/StoryFlow/Llm/Client.hs` | F001 | `stepWorkshop` 唯一的模型呼叫 |
| `data LlmClient`(不透明) | 同上 | F001 | `stepWorkshop` 的參數型別,原樣轉呼叫 |
| `data Message = Message { msgRole :: Role, msgContent :: Text }` / `data Role = System \| User \| Assistant` | 同上 | F001 | `wsHistory` 的元素型別;prompt 組裝的輸出型別 |
| `data LlmError = LlmUnavailable Text \| LlmHttpStatus Int Text \| LlmBadResponse Text \| LlmConfigMissing \| LlmConfigInvalid Text` | `llm/src/StoryFlow/Llm/Error.hs` | F001 | `WsLlmFailed` 原樣包住的內容 |
| `renderLlmError :: LlmError -> Text` / `llmErrorCode :: LlmError -> Text` | 同上 | F001 | `renderWorkshopError` / `workshopErrorCode` 對 `WsLlmFailed` 往內取用,不重寫訊息 |
| `newtype ServiceM a`(`ReaderT Env (ExceptT ServiceError IO)`,`MonadReader Env` / `MonadError ServiceError` / `MonadIO`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `startWorkshop` / `stepWorkshop` / `loadSession` / `saveSession` 全部跑在它上面;`WorkshopError` 走 `Either`,不是它的例外型別 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | 同上 | service-and-interfaces/F001 | 測試執行三個公開函式;回傳型別因此是 `IO (Either ServiceError (Either WorkshopError a))` 兩層 |
| `data Env = Env { envVault :: Vault, envConn :: Connection, envTypes :: TypeRegistry }` | 同上 | service-and-interfaces/F001 | 測試底稿建 `Env`(經 `openEnv`,不直接建構) |
| `openEnv` / `closeEnv` / `vaultsEnvVar` | 同上 | service-and-interfaces/F001 | 測試底稿的臨時 Vault 生命週期,與 `llm/test/.../Fixtures.hs` 同一套 |
| `listEntityTypes :: ServiceM [EntityTypeSpec]` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | `startWorkshop` 找型別、讀 `etsStages` |
| `getEntity :: Id -> ServiceM EntityView` | 同上 | service-and-interfaces/F001 | 驗證硬約束存在(`startWorkshop`)、取 `summary`(`stepWorkshop`);失敗時走 `ServiceM` 原生的 `ServiceError`(`StoreFailed (EntityNotFound _)`) |
| `createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)` | 同上 | service-and-interfaces/F001 | 測試底稿建臨時 Vault |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | `getEntity` 的回傳型別,取 `evEntity` 再往下鑽 |
| `data ServiceError = StoreFailed StoreError \| RegistryUnavailable Text \| RegistryLoadFailed [LoadError] \| ValidationFailed (Maybe Id) [EntityWarning] \| UnknownType Text \| DanglingLinkTarget Ref \| CrossVaultUnsupported Ref \| LevelTreeInvalid Id [TreeError]`(既有八個建構子,**本 feature 不新增任何建構子**) | `service/src/StoryFlow/Service/Error.hs` | service-and-interfaces/F001 | `startWorkshop` 重用 `UnknownType`;`getEntity` 內部重用 `StoreFailed (EntityNotFound _)` |
| `data Entity = Entity { entMeta :: Meta, entBody :: Text }` | `core/src/StoryFlow/Core/Entity.hs` | entity-graph-core/F002 | `evEntity` 的型別,取 `entMeta` |
| `data Meta = Meta { metaSummary :: Text, … }` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | 取硬約束的 `summary` |
| `data Id`(不透明)/ `renderId :: Id -> Text` / `parseId :: Text -> Either IdError (IdPrefix, Id)` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | `wsConstraints` / `wsOwner` / `wsCommitted` 的元素型別;JSON 編碼沿用 `Core.Json` 既有的 `Id` 實例 |
| `fnv1a64 :: BS.ByteString -> Word64` | 同上 | entity-graph-core/F002 | session id 產生的雜湊原語 |
| `data EntityTypeSpec = EntityTypeSpec { etsKey :: Text, etsStages :: [Text], … }` | `core/src/StoryFlow/Core/Registry.hs` | entity-graph-core/F002 | `startWorkshop` 找型別、讀 `stages` |
| `instance ToJSON Id` / `instance FromJSON Id` | `core/src/StoryFlow/Core/Json.hs` | entity-graph-core/F002 | `Session` 的 `wsConstraints` / `wsOwner` / `wsCommitted` 編解碼直接沿用,不重新定義 |
| `atomicWriteText`(讀作**做法**範本,不是被呼叫的函式——`storyflow-workshop` 不依賴 `storyflow-store`) | `store/src/StoryFlow/Store/Atomic.hs` | entity-graph-core/F004 | `saveSession` 的原子寫入邏輯**同構**於它:暫存檔同目錄、`hFlush`/`hClose`/`renamePath`、失敗清暫存檔 |
| `initVault :: FilePath -> Text -> IO (Either StoreError Vault)`(內部寫 `.storyflow/.gitignore` 的那一段) | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | 本 feature**改動**這裡的 `.gitignore` 內容(D6/S5),不是呼叫它 |
| `vaultRoot :: Vault -> FilePath`(`Vault` record 欄位存取子;讀作**命名衝突查證**,不是被呼叫的函式) | 同上 | entity-graph-core/F004 | 確認新增 `StoryFlow.Service.vaultRoot` 時,`Service.hs` 既有的 `import StoryFlow.Store` 需要處理同名衝突(見「實作方式」第二節) |
| `renderPairPrompt` / `locateFence` / `dropLangTagLine` / `sliceBraces` / `stripCodeFence`(讀作**做法**範本,不是被呼叫的函式——`storyflow-workshop` 不依賴 `storyflow-conflict`) | `conflict/src/StoryFlow/Conflict/Judge.hs` | - | prompt 呈現與 JSON 擷取的演算法先例,`extractDrafts` 與 `buildMessages` 各自獨立實作同一套邏輯 |

## 新增的介面

```haskell
-- storyflow-workshop : StoryFlow.Workshop.Error -----------------------------
data WorkshopError
  = WsSessionNotFound Text              -- loadSession 找不到這個 session id 的快照檔
  | WsSnapshotCorrupt FilePath Text     -- 快照檔在,但不是合法的 Session JSON
  | WsSnapshotWriteFailed FilePath Text -- 寫快照時的 IO 失敗(磁碟滿、權限…)
  | WsNoStages Text                     -- 型別沒有宣告任何 stages(startWorkshop)
  | WsStagesExhausted Text              -- session 已經沒有下一階段(stepWorkshop)
  | WsNothingToCommit Text              -- wsPending 是空的(commitStage,F003 產生;
                                         -- 本 feature 只定義建構子與渲染,不產生它)
  | WsLlmFailed LlmError                -- 模型那一跳,原樣包住不攤平
  deriving stock (Show, Eq)

renderWorkshopError :: WorkshopError -> Text
workshopErrorCode   :: WorkshopError -> Text

-- storyflow-workshop : StoryFlow.Workshop.Session ----------------------------
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

loadSession :: Text -> ServiceM (Either WorkshopError Session)
-- saveSession 與 session id 產生是套件內部(Stages 呼叫),不在此列出公開名字,
-- 留給實作階段決定要不要對套件外開放(見「待確認假設」A3)

-- storyflow-workshop : StoryFlow.Workshop.Stages ----------------------------
startWorkshop :: Text -> [Id] -> ServiceM (Either WorkshopError Session)
stepWorkshop  :: LlmClient -> Session -> Text -> ServiceM (Either WorkshopError (Session, Text))

-- storyflow-service : StoryFlow.Service(新增內嵌出口,不進 CLI 與 REST)------
vaultRoot :: ServiceM FilePath
-- asks (S.vaultRoot . envVault);「S」為既有的 `import qualified StoryFlow.Store as S`。
-- 需同步把 `import StoryFlow.Store hiding (...)` 的隱藏清單加上 vaultRoot,
-- 並把既有三個呼叫點(createVault ×2、vaultInfo ×1)改成 S.vaultRoot(見實作方式第二節)
```

## TodoList

- [ ] T1: 建 `workshop/storyflow-workshop.cabal`(common 段照抄 conflict)、`cabal.project` 加 `workshop/` 與 ghc-options 段、三個模組骨架(`Workshop.Error` / `Workshop.Session` / `Workshop.Stages`)  `dep: -`
- [ ] T2: `storyflow-service` 新增內嵌出口 `vaultRoot :: ServiceM FilePath`(處理與 `StoryFlow.Store.Vault` 的 `vaultRoot` 存取子的命名衝突:`hiding` 清單加它、既有三個呼叫點改 `S.vaultRoot`、匯出清單加入)  `dep: -`
- [ ] T3: `store` 的 `initVault`:`.storyflow/.gitignore` 內容加一行 `workshops/`(D6/S5)  `dep: -`
- [ ] T4: `Workshop.Error`:`WorkshopError` 七個建構子、`renderWorkshopError`、`workshopErrorCode`(對 `WsLlmFailed` 往內取 `renderLlmError` / `llmErrorCode`)  `dep: T1`
- [ ] T5: `Workshop.Session`:`Session` / `StageDraft` 型別與 JSON 編碼(含 `Message`/`Role` 的私有 JSON 轉換,不對 `storyflow-llm` 的型別加孤兒實例)  `dep: T1`
- [ ] T6: `Workshop.Session`:快照路徑(經新增的 `vaultRoot` 取 root)、目錄建立、`saveSession :: Session -> ServiceM (Either WorkshopError ())`(暫存檔 + rename 的原子寫入)、`loadSession :: Text -> ServiceM (Either WorkshopError Session)`(缺檔 → `WsSessionNotFound`;JSON 壞掉 → `WsSnapshotCorrupt`)  `dep: T4, T5, T2`
- [ ] T7: `Workshop.Session`:session id 產生(`fnv1a64` 雜湊 + 以快照檔是否已存在做碰撞重試)  `dep: T5`
- [ ] T8: `Workshop.Stages`:`startWorkshop`(型別不存在 → `throwError (UnknownType _)`;空 `stages` → `pure (Left (WsNoStages _))`;硬約束 id 不存在 → 走 `getEntity` 原生的 `StoreFailed (EntityNotFound _)`;建初始 `Session` → `saveSession`,失敗原樣浮上去)  `dep: T6, T7, T4`
- [ ] T9: `Workshop.Stages`:system prompt 組裝(階段說明 + 硬約束 summary + JSON 陣列格式指示)  `dep: T8`
- [ ] T10: `Workshop.Stages`:`stepWorkshop`(越界 → `pure (Left (WsStagesExhausted _))`;`chat` 的 `Left e` → `pure (Left (WsLlmFailed e))` 且不寫快照;`Right` 時更新 `wsHistory`、解析回覆的 JSON 陣列成功則整批替換 `wsPending`、失敗則保留舊值、`saveSession` 失敗原樣浮上去)  `dep: T9`
- [ ] T11: 測試底稿 `StoryFlow.Workshop.Fixtures`(warp stub 端點、`withDeadPort`、臨時 Vault:`createVault`/`openEnv`/`runService`)  `dep: T1`
- [ ] T12: 套件邊界測試 `StoryFlow.Workshop.CabalSpec`(build-depends 逐字釘住、禁用清單、`cabal.project` 已登錄、三個模組都在 `exposed-modules`)  `dep: T1`

## 1-to-1 測試對照表

測試框架 **hspec**;`workshop/test/Spec.hs` 照 `conflict/test/Spec.hs` 的形狀(`hSetEncoding
stdout utf8` + 手動 `describe "Tn …"`,不用 `hspec-discover`)。T2 的測試落在
`service/test/StoryFlow/Service/`,比照既有 `VaultConfigSpec.hs` 的形狀新增一份
`VaultRootSpec.hs`。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.Workshop.CabalSpec`(「模組」小節) | `StoryFlow.Workshop.Error` / `StoryFlow.Workshop.Session` / `StoryFlow.Workshop.Stages` 都在 `exposed-modules` |
| T2 | `StoryFlow.Service.VaultRootSpec` | `runService env vaultRoot` 回傳的路徑,以 `normalise` 比對後等於 `createVault` 建立時給的臨時目錄;該路徑底下 `.storyflow` 子目錄存在(佐證取到的是含 `.storyflow/` 的那一層) |
| T3 | `StoryFlow.Store.InitSpec`(擴充既有測試「`.storyflow/.gitignore` 含 index.db」那一條) | `initVault` 後 `storyflowDir dir </> ".gitignore"` 的內容同時含 `index.db` 與 `workshops/` 兩行 |
| T4 | `StoryFlow.Workshop.ErrorSpec` | 七個建構子的 `workshopErrorCode` 互不重複、全為 snake_case;`renderWorkshopError` 每一則非空;`WsLlmFailed e` 的 `renderWorkshopError` 等於 `renderLlmError e` 的原文、`workshopErrorCode (WsLlmFailed e)` 等於 `llmErrorCode e`(逐一對 `LlmError` 的五個建構子驗證) |
| T5 | `StoryFlow.Workshop.SessionJsonSpec` | `Session` 與 `StageDraft` 各自 encode → decode round-trip 相等(含 `wsOwner = Nothing` 時鍵不出現、`wsOwner = Just _` 時鍵出現);`wsHistory` 的三種 `Role` 都能正確編解碼且互不混淆 |
| T6 | `StoryFlow.Workshop.SessionIOSpec` | `saveSession` 回 `Right ()` 後檔案存在於 `.storyflow/workshops/<id>.json`;`loadSession` 讀回的 `Session` 與寫入前相等(`Right`);`loadSession` 對不存在的 id 回 `Left (WsSessionNotFound _)`;把快照檔內容改成不合法 JSON 後 `loadSession` 回 `Left (WsSnapshotCorrupt _ _)` |
| T7 | `StoryFlow.Workshop.SessionIdSpec` | 連續產生 50 個 id 全部不重複;預先在 `workshops/` 目錄放一個與「即將產生的候選 id」同名的空檔(以雜湊輸入回推構造碰撞),驗證函式會跳過它、拿到不同的 id |
| T8 | `StoryFlow.Workshop.StartSpec` | 對真實型別(`character-fragment`,`stages` 非空)呼叫 `startWorkshop`,用 `runService` 接:成功 → 外層 `Right (Right session)`,`wsStages` 等於註冊表的 `etsStages`、`wsCurrent == 0`、快照檔已寫出;型別不存在 → 外層 `Left (UnknownType _)`(`ServiceError`,不是 `WorkshopError`);硬約束 id 不存在 → 外層 `Left (StoreFailed (EntityNotFound _))`;`etsStages` 為空的型別(用型別註冊表載入的假型別或 stub 驗證)→ 外層 `Right (Left (WsNoStages _))` |
| T9 | `StoryFlow.Workshop.PromptSpec` | 純函式測試(不必真的呼叫模型):組出的 system message 含目前階段名與 `N/總數`;硬約束的 `(id, summary)` 逐條出現在文字裡;含 JSON 陣列格式指示(斷言字串含 `title` / `summary` / `body` / `tags` 四個鍵名) |
| T10 | `StoryFlow.Workshop.StepSpec` | 對 stub 端點,用 `runService` 接:回覆含合法 JSON 陣列(一個或多個 draft)→ 外層 `Right (Right (session', reply))`,`wsPending` 等於解析結果、`wsHistory` 增加兩則、快照被更新;回覆是純自然語言(無 JSON)→ `wsPending` 與呼叫前相等、但 `wsHistory` 與快照仍更新、`reply` 等於 stub 的原始回覆;`withDeadPort` → 外層 `Right (Left (WsLlmFailed (LlmUnavailable _)))` 且快照檔內容與呼叫前逐位元組相同(未被覆寫)、傳入的 `Session` 值本身不變;`wsCurrent = length wsStages` 的 session → 外層 `Right (Left (WsStagesExhausted _))` |
| T11 | `StoryFlow.Workshop.StubSpec` | 底稿自己的契約(照抄 F001 的 T9):`withStub` 起得來、回得出設定好的內文;`withDeadPort` 給的埠在區塊內用(透過 `chat` 間接)驗證為連線被拒 |
| T12 | `StoryFlow.Workshop.CabalSpec`(主體) | `build-depends` 逐字等於設計裡的兩份清單;library 不含 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite` / `servant` / `warp`;`storyflow-core` / `storyflow-llm` / `storyflow-service` 都在 library;`warp` / `wai` 只出現在 test-suite;`cabal.project` 含 `workshop/` 且含 `package storyflow-workshop` 段 |

## 待確認假設

- A1:硬約束 id 的存在性檢查時機與是否快取。→ 採取:`startWorkshop` 用 `getEntity` 逐一驗證
  一次(及早失敗,經 `ServiceM` 原生的 `ServiceError` 通道);`stepWorkshop` 每次呼叫**重新**
  `getEntity` 取最新的 `summary`,不快取在 `Session` 裡。理由:「使用者中途編輯了硬約束片段的
  summary」是完全合理的情境,現讀現送比較正確;而 `startWorkshop` 及早驗證能讓打錯 id 的
  使用者在建立 session 的當下就發現,而不是講到一半才炸開。→ 影響:若判斷錯誤,
  `startWorkshop` 改成不驗證(信任呼叫端),或 `stepWorkshop` 改成用 session 建立時快取的
  summary(需要在 `Session` 加一個內部欄位,但 `Session` 的欄位是 Level 2 契約鎖定的九個,
  加欄位就是偏離契約,代價明顯更高——這也是選擇「現讀不快取」的加分理由之一)。
- A2:`Session.wsId` 的產生方式(前綴 `wksp-` + `fnv1a64` 雜湊 + 檔案存在性碰撞重試)。
  → 採取:重用 `Core.Id` 已匯出的 `fnv1a64` 原語但不重用 `mkId`(它的 `IdPrefix` 是封閉的
  四個實體前綴,工作坊 session 不是其中之一)。→ 影響:若未來認為工作坊 session 也該進
  `Core.Id.IdPrefix` 的封閉集合(讓 session id 與 Entity id 同一套格式與驗證),那是
  `entity-graph-core` 的 Level 2 變動,不是本 feature 能單方面決定的。
- A3:`Workshop.Session` 是否對套件外公開 `saveSession` 與 id 產生函式。→ 採取:「新增的
  介面」只列 `loadSession`(Level 2 明文要求的三個公開函式之一),`saveSession` 與 id 產生
  留在模組內(是否加進 `exposed` 的匯出清單由實作階段決定,反正 `StoryFlow.Workshop.Session`
  整個模組本來就在 `exposed-modules` 裡,`workshop-emit`〔F003〕在同一個套件內,天然拿得到)。
  → 影響:若 F003 的 `commitStage` 需要重用這兩個函式(幾乎必然,因為它也要在成功後寫出
  快照,而且要沿用「`WorkshopError` 走 `Either`,不 `throwError`」這個新形狀),它會是
  「同套件內部呼叫」而不是「新的公開介面」,不影響本文檔已定的公開面。

## 實作備註

(開發過程中與設計的偏差記錄於此,撰寫時留空)
