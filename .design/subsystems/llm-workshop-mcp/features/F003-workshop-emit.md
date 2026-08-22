---
id: F003
type: feature
title: workshop-emit
description: 工作坊每階段定案寫成多個片段 Entity,首次定案另建主題檔
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F002, entity-graph-core/F002, service-and-interfaces/F001]
related-adr: [ADR-003, ADR-005, ADR-006]
related-feature: []
---

# F003: 工作坊每階段定案寫進圖譜

## 功能概述

新增 `StoryFlow.Workshop.Emit` 模組,提供工作坊管線「定案之後」的那一段:`commitStage`
把 `Session.wsPending` 的 `StageDraft` 清單寫進 Vault,首次定案額外建立主題檔(`wsOwner`),
之後每次定案往同一份主題檔加片段。這是工作坊相對 design-studio 的關鍵差異——
**一次定案產出的是多個片段 Entity,不是一份設計文件**。

驗收標準逐條(對齊契約卡):

| # | 驗收標準 | 怎麼算通過 |
|---|---|---|
| 1 | 一次定案產出多個片段 Entity | `wsPending` 有 N 筆 `StageDraft`,`commitStage` 成功時回傳的 `[EntityView]` 含 N 筆對應的片段(首次定案再加 1 筆主體) |
| 2 | 一次工作坊 = 一份主題檔 | 首次 `commitStage`(`wsOwner == Nothing`)呼叫 `createEntity` 建主體,`type` 取 `EntityTypeSpec` 的 `etsOwnerType`(`Nothing` 則退回 `wsType`);之後每次 `commitStage`(`wsOwner == Just _`)只呼叫 `addFragment`,不再建新主體 |
| 3 | 每個片段建 `partOf` 指向主體 | 每筆 `NewFragmentReq` 的 `nfrLinks` 含 `Link PartOf (localRef ownerId) Nothing` |
| 4 | 寫入的 `source` 一律 `workshop:<型別>` | `nerSource` / `nfrSource` 皆為 `Just (Workshop (wsType session))`,`renderSource` 输出 `"workshop:" <> wsType` |
| 5 | `wsPending` 空時回 `WsNothingToCommit`,不寫出空片段 | `null (wsPending session)` 時直接 `pure (Left (WsNothingToCommit (wsId session)))`,不呼叫任何 `createEntity`/`addFragment` |
| 6 | 寫入走與 CLI 相同的 `ServiceM` 操作,落地失敗講 `ServiceError` | `createEntity`/`addFragment`/`listEntityTypes` 全部原樣呼叫 `StoryFlow.Service` 的既有函式,失敗經 `ServiceM` 原生的 `throwError` 通道浮出,不轉譯成 `WorkshopError` |

明確**不做**(契約卡的硬邊界):不直接碰 `storyflow-store`(只經 `StoryFlow.Service`);
不決定階段流程本身從哪裡來、是否已耗盡(那是 `workshop-stages` 已經在 `stepWorkshop`
用 `WsStagesExhausted` 守住的判斷,`commitStage` 不重新驗證一次);不在寫入失敗時自行重試改寫
——`ServiceError` 原樣浮上去,呼叫端決定要不要重試。

## 相依性

`depends-on: [F002, entity-graph-core/F002, service-and-interfaces/F001]`。

- **`F002`(llm-workshop-mcp,同子系統,**設計完成、程式碼尚未實作**)**:`Session` /
  `StageDraft` / `WorkshopError`(`WsNothingToCommit` 建構子與其 `renderWorkshopError` 文案
  已由 F002 定義)全部是它的產出。本 feature 依它的**設計文檔**為準(逐字引用「模組間公開
  介面與資料結構」章節的欄位),不是讀原始碼——F002 的程式碼還不存在。`Workshop.Session`
  的 `saveSession :: Session -> ServiceM (Either WorkshopError ())` 是 F002 的**套件內部**函式
  (F002 的 A3 已預期 `workshop-emit` 會在同套件內重用它,不算新公開介面),本 feature 直接
  呼叫
- **`entity-graph-core/F002`(core-types-and-registry,**done,程式碼存在**)**:已讀
  `core/src/StoryFlow/Core/Id.hs`(`Id`、`Ref`、`localRef`)、`core/src/StoryFlow/Core/Link.hs`
  (`Link(..)`、`LinkKind(PartOf, ...)`)、`core/src/StoryFlow/Core/Meta.hs`(`Status(..)`、
  `Source(..)`、`Timeline(..)`、`emptyTimeline`)、`core/src/StoryFlow/Core/Registry.hs`
  (`EntityTypeSpec(..)`,含 `etsOwnerType :: Maybe Text`)——逐一確認完整簽名,見下方介面表
- **`service-and-interfaces/F001`(service-contract,**done,程式碼存在**)**:已讀
  `service/src/StoryFlow/Service.hs` 與 `service/src/StoryFlow/Service/Types.hs`,確認
  `createEntity` / `addFragment` / `listEntityTypes` 的完整簽名與樂觀鎖行為,見下方介面表

**不依賴 `F001`(llm-endpoint)**:`commitStage` 的簽名沒有 `LlmClient` 參數(契約卡與
design.md 都明寫),不呼叫 `chat`,因此不需要 `StoryFlow.Llm`。

**可否平行開發**:不行。`commitStage` 的參數型別 `Session` 與回傳的 `WorkshopError` 都由
F002 定義,F002 的程式碼一天不存在,本 feature 就編譯不起來。`design.md` 的功能規劃也明寫
`workshop-emit`(#3)依賴 `#2`。

## 對應的 Level 2 契約

| 契約出處 | 條目 | 本 feature 的落點 |
|---|---|---|
| `llm-workshop-mcp/design.md` 對外契約 | `commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))` | `StoryFlow.Workshop.Emit.commitStage` |
| 「模組間公開介面與資料結構」 | `Workshop.Emit → service-and-interfaces`:經 `ServiceM` 以 `NewEntityReq` 寫入,與 CLI 用同一組操作 | `commitStage` 呼叫 `StoryFlow.Service` 的 `createEntity` / `addFragment` / `listEntityTypes`,不 import `storyflow-store` |
| 「一次工作坊 = 一份主題檔」批次澄清 | 首次 `commitStage` 用 `createEntity` 建主體(`type` 取 `owner_type`,沒宣告用型別鍵本身)記進 `wsOwner`;之後每階段 `addFragment` 加節;每個片段 `partOf` 指向主體;`source` 一律 `workshop:<型別>` | `commitStage` 的第一、二步(見「實作方式」) |
| 「工作坊的錯誤語彙」批次澄清 | `ServiceM` 的 `ServiceError` 通道仍用於業務層落地失敗;`WorkshopError` 只講工作坊自己的失敗 | `createEntity`/`addFragment`/`listEntityTypes` 的失敗原樣走 `throwError`,`commitStage` 不 `catchError` 攔截、不轉譯 |
| F002「Session 快照的落地位置」與「誰負責寫快照」 | `commitStage` 成功後要在成功之後寫出新快照 | `commitStage` 最後一步呼叫 F002 的 `saveSession`,`Left` 原樣浮上去、`Right` 才回傳 `(newSession, views)` |

**沒有超出契約的新公開介面**——只新增 `commitStage` 一個函式,簽名逐字等於 design.md。

## 實作方式

### 一、`wsPending` 是空的:及早擋下

```haskell
commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))
commitStage session
  | null (wsPending session) = pure (Left (WsNothingToCommit (wsId session)))
  | otherwise = ...
```

不呼叫 `createEntity`/`addFragment`,一個位元組都不寫——與 F002 `createEntity` 的
「驗證發生在寫檔之前」同一個精神。

### 二、決定主體 id:首次建立、之後沿用

```haskell
resolveOwner :: Session -> ServiceM Id
resolveOwner session = case wsOwner session of
  Just oid -> pure oid
  Nothing -> do
    specs <- listEntityTypes
    spec <- case find ((== wsType session) . etsKey) specs of
      Just s -> pure s
      Nothing -> throwError (UnknownType (wsType session))
    let ownerType = fromMaybe (wsType session) (etsOwnerType spec)
        seed = head (wsPending session)
    view <- createEntity
      NewEntityReq
        { nerType = ownerType
        , nerTitle = sdTitle seed
        , nerSummary = sdSummary seed
        , nerBody = ""
        , nerTags = []
        , nerAliases = []
        , nerStatus = Draft
        , nerTimeline = emptyTimeline
        , nerLinks = []
        , nerSource = Workshop (wsType session)
        }
    pure (evId view)
```

- `listEntityTypes` 找 `wsType` 對應的 `EntityTypeSpec`——`wsType` 理論上一定在註冊表裡
  (`startWorkshop` 已驗證過),這裡的 `Nothing` 分支是防禦性的,重用 F002 在 `startWorkshop`
  已經在用的 `UnknownType`(`ServiceError` 的既有建構子,不新增)
- **`ownerType` 不一定是註冊表的 key**(`character` / `item` / `lore` / `plot` 都不是,只有
  `dialogue` 是——見「待確認假設」的討論)。`createEntity` 內部的 `requireKnownType` 用
  `lookupType` **或** `lookupDir` 判斷,`lookupDir` 會掃描 `etsOwnerType` 命中,所以這種
  「型別鍵不在註冊表、但有其他型別宣告 `owner_type` 指它」的情況本來就過得了關(已讀
  `service/src/StoryFlow/Service.hs` 的 `requireKnownType` 確認)。`checkEntity` 對這種
  未註冊的 key 只產生 `UnknownEntityType` **警告**(不是 `MissingRequiredField`,不會
  擋寫入)——這與人類作者手寫 `type: character` 檔案層 frontmatter 時的既有行為一致
  (system.md 的範例檔本來就長這樣),不是本 feature 引入的新狀況
- `seed = head (wsPending session)`:借用第一筆 `StageDraft` 的 `sdTitle` / `sdSummary` 當
  主體的標題與總結(見「待確認假設」A1)。`nerBody = ""`——正文留白,內容仍以片段承載
- `nerStatus = Draft`、`nerSource = Workshop (wsType session)`——見「待確認假設」A2 的
  status 判斷

### 三、把 `wsPending` 逐筆寫成片段

```haskell
commitDrafts :: Id -> Session -> ServiceM [EntityView]
commitDrafts ownerId session = mapM one (wsPending session)
  where
    one d =
      addFragment ownerId
        NewFragmentReq
          { nfrTitle = sdTitle d
          , nfrSummary = sdSummary d
          , nfrBody = sdBody d
          , nfrType = Just (wsType session)
          , nfrTags = sdTags d
          , nfrAliases = []
          , nfrStatus = Just Draft
          , nfrTimeline = Nothing
          , nfrLinks = [Link PartOf (localRef ownerId) Nothing]
          , nfrSource = Just (Workshop (wsType session))
          }
```

- **`nfrType = Just (wsType session)`,不留 `Nothing`**:留白會讓片段繼承主體的
  `metaType`(`fragmentMeta` 的 `fromMaybe (metaType main) nfrType`,已讀
  `service/src/StoryFlow/Service.hs` 確認)——主體的 type 是 `owner_type`(如
  `character`),片段要的是型別鍵本身(如 `character-fragment`),兩者不同,必須明寫
- **`partOf` 直接放進 `nfrLinks`,不呼叫 `addLink`**:已讀 `addLink :: Id -> Int -> Link ->
  ServiceM EntityView`(`service/src/StoryFlow/Service.hs`)確認它存在且能建 `partOf`,
  但它要求呼叫端自己讀最新 revision 當 `expected`,而 `NewFragmentReq` 本來就有 `nfrLinks`
  欄位——建立當下直接夾帶連結,省掉「建立 → 讀 revision → 再 addLink」多一次往返與多一次
  revision bump。這是查證後發現的簡化,契約卡原本提示要查 `addLink` 是對的方向,但實際
  落地更輕量
- `nfrStatus = Just Draft`、`nfrSource = Just (Workshop (wsType session))`——status 判斷見
  「待確認假設」A2
- `addFragment` 的 revision 由它自己讀(已讀確認:`main <- getEntity i` 內部重讀
  `metaRevision`),`commitDrafts` 不必自己管樂觀鎖

### 四、組新 `Session`、寫快照、回傳

```haskell
commitStage session
  | null (wsPending session) = pure (Left (WsNothingToCommit (wsId session)))
  | otherwise = do
      ownerId <- resolveOwner session
      views <- commitDrafts ownerId session
      let newSession =
            session
              { wsOwner = Just ownerId
              , wsPending = []
              , wsCommitted = wsCommitted session ++ map evId views
              , wsCurrent = wsCurrent session + 1
              }
      saveSession newSession >>= \case
        Left werr -> pure (Left werr)
        Right () -> pure (Right (newSession, views))
```

- **`wsCurrent` 前進一格**:design.md 的資料流管線把「進入下一階段,直到 stages 走完」
  緊接在 `commitStage` 那一行之後,而 F002 的三個對外函式(`startWorkshop` /
  `stepWorkshop` / `loadSession`)沒有一個會修改 `wsCurrent`——不做的話工作坊會卡死在同一
  階段。這條在下方「待確認假設」A3 展開討論(它與契約卡「明確不做:不決定階段流程」的
  字面有張力,但沒有其他函式能做這件事)
- **`wsCommitted` 只累加片段 id,不含 `ownerId`**:`wsOwner` 已經單獨追蹤主體,
  `wsCommitted` 的欄位語意是「已定案寫出去的**片段**」(design.md 逐字),owner 不是片段
- `views`(回傳的 `[EntityView]`)**含主體**(首次定案時)**與全部片段**——見「待確認
  假設」A4
- `saveSession` 失敗 → `Left werr` 原樣浮上去,`newSession` 不會被回傳(呼叫端手上的
  `Session` 仍是呼叫前那份)。此時 Vault 裡已經寫入的 Entity(owner 與/或部分片段)
  **不會被回滾**——見「待確認假設」A5

### 五、⚠️ 已發現的契約缺口:`lore-fragment` / `plot-fragment` 的 `timeline` 必填

**這不是實作選擇,是查證時發現的真實阻塞**,寫在這裡讓編排者知道,不藏進「待確認假設」
輕輕帶過:

- `types/registry/lore-fragment.toml` 與 `types/registry/plot-fragment.toml`(已讀)都宣告
  `[[fields]] name = "timeline" required = true`
- `StageDraft`(F002 逐字定義,Level 2 鎖定)只有 `sdTitle` / `sdSummary` / `sdBody` /
  `sdTags` 四個欄位,**沒有 timeline**
- 因此對這兩種型別跑工作坊,`commitDrafts` 組出的 `NewFragmentReq` 一律 `nfrTimeline =
  Nothing`,片段繼承主體的 `metaTimeline`——而主體的 `metaTimeline` 也是
  `emptyTimeline`(`resolveOwner` 沒有任何資料來源可以填它)。`checkEntity` 的
  `fieldPresent "timeline"` 因此恆為 `False`,`validateForWrite` 必定丟
  `ValidationFailed`——**`lore-fragment` 與 `plot-fragment` 這兩種型別的工作坊,
  `commitStage` 會 100% 失敗,不是邊界情況**
- 本 feature**沒有**在自己的範圍內修補這個缺口:唯一乾淨的修法是替 `StageDraft` 加一個
  `sdTimeline :: Maybe Timeline` 欄位,但 `StageDraft` 是 F002 逐字鎖定的 Level 2 資料結構,
  修改它是上層契約變動,不是本 feature 的實作自主權範圍。硬塞一個假的 timeline
  (例如固定字串)會汙染真實資料,且違背這個系統一貫「不捏假資料」的立場
- **建議編排者**:回頭修 `llm-workshop-mcp/design.md` 與 F002,替 `StageDraft` 加
  `sdTimeline :: Maybe Timeline`(`Nothing` 時沿用目前的「不填」行為,兩個必填型別由使用者
  /模型在該階段的回覆裡額外給),或另外決定這兩個型別暫不支援工作坊(移除它們的
  `stages` 宣告)。這件事應該在 F002 實作前一併处理,否則 F003 完成後會有一個「寫了
  但兩種型別必定失敗」的空實作

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `createEntity :: NewEntityReq -> ServiceM EntityView` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 首次 `commitStage` 建主題檔 |
| `addFragment :: Id -> NewFragmentReq -> ServiceM EntityView` | 同上 | service-and-interfaces/F001 | 逐筆把 `StageDraft` 寫成片段;revision 由它自己重讀,呼叫端不必管樂觀鎖 |
| `listEntityTypes :: ServiceM [EntityTypeSpec]` | 同上 | service-and-interfaces/F001 | 找 `wsType` 對應的 `EntityTypeSpec`,讀 `etsOwnerType` |
| `addLink :: Id -> Int -> Link -> ServiceM EntityView`(**已查證,本 feature 不使用**) | 同上 | service-and-interfaces/F001 | 確認存在且能建 `partOf`,但 `NewEntityReq`/`NewFragmentReq` 已有 `nerLinks`/`nfrLinks`,建立當下直接夾帶連結更輕量,不必「建立→讀 revision→再 addLink」 |
| `data NewEntityReq = NewEntityReq { nerType, nerTitle, nerSummary, nerBody, nerTags, nerAliases, nerStatus :: Status, nerTimeline :: Timeline, nerLinks :: [Link], nerSource :: Source }` | `service/src/StoryFlow/Service/Types.hs` | service-and-interfaces/F001 | `resolveOwner` 組主體的建立請求 |
| `data NewFragmentReq = NewFragmentReq { nfrTitle, nfrSummary, nfrBody, nfrType :: Maybe Text, nfrTags, nfrAliases, nfrStatus :: Maybe Status, nfrTimeline :: Maybe Timeline, nfrLinks :: [Link], nfrSource :: Maybe Source }` | 同上 | service-and-interfaces/F001 | `commitDrafts` 組每筆片段的建立請求;逐欄核對過與 `StageDraft` 的對應 |
| `data EntityView = EntityView { evEntity :: Entity, evPath :: FilePath, evAnchor :: Maybe Text, evWarnings :: [Text] }` / `evId :: EntityView -> Id` / `evRevision :: EntityView -> Int` | 同上 | service-and-interfaces/F001 | `createEntity`/`addFragment` 的回傳型別;`evId` 取新片段/主體的 id 存進 `wsOwner`/`wsCommitted` |
| `newtype ServiceM a`(`ReaderT Env (ExceptT ServiceError IO)`) / `throwError`(經 `MonadError ServiceError`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `commitStage` 跑在它上面;`resolveOwner` 的防禦性 `UnknownType` 分支重用既有的 `throwError` |
| `data ServiceError = ... | UnknownType Text | ValidationFailed (Maybe Id) [EntityWarning] | ...`(既有建構子,本 feature 不新增) | `service/src/StoryFlow/Service/Error.hs` | service-and-interfaces/F001 | `resolveOwner` 重用 `UnknownType`;`createEntity`/`addFragment` 內部可能丟 `ValidationFailed`(如 lore-fragment/plot-fragment 的 timeline 缺口),原樣浮上去 |
| `data EntityTypeSpec = EntityTypeSpec { etsKey :: Text, etsOwnerType :: Maybe Text, ... }` | `core/src/StoryFlow/Core/Registry.hs` | entity-graph-core/F002 | `resolveOwner` 找 `wsType` 對應的宣告,讀 `etsOwnerType`(確認為 `Maybe Text`,`Nothing` 時退回 `wsType`) |
| `lookupType` / `lookupDir` / `checkEntity`(讀作**行為佐證**,`Workshop.Emit` 不直接呼叫——它們是 `createEntity` 內部用的) | 同上 | entity-graph-core/F002 | 確認「owner_type 不是註冊表 key 時仍能建立」這個行為的根據(`lookupDir` 會掃 `etsOwnerType`) |
| `data Status = Draft \| Canon \| Deprecated` | `core/src/StoryFlow/Core/Meta.hs` | entity-graph-core/F002 | `nerStatus`/`nfrStatus` 填 `Draft`(見待確認假設 A2) |
| `data Source = Human \| Agent Text \| Workshop Text` / `renderSource :: Source -> Text`(`Workshop t -> "workshop:" <> t`) | 同上 | entity-graph-core/F002 | `nerSource`/`nfrSource` 填 `Workshop (wsType session)`,確認渲染結果逐字等於契約要求的 `workshop:<型別>` |
| `data Timeline = Timeline { tlLabel :: Maybe Text, tlOrder :: Maybe Int }` / `emptyTimeline` | 同上 | entity-graph-core/F002 | `nerTimeline = emptyTimeline`(主體無時間軸資料來源);confirmed 這是「見五、契約缺口」問題的根源 |
| `data Link = Link { linkKind :: LinkKind, linkTarget :: Ref, linkNote :: Maybe Text }` / `data LinkKind = ... \| PartOf \| ...` | `core/src/StoryFlow/Core/Link.hs` | entity-graph-core/F002 | `nfrLinks = [Link PartOf (localRef ownerId) Nothing]` |
| `data Id`(不透明)/ `data Ref = Ref { refVault :: Maybe Text, refId :: Id }` / `localRef :: Id -> Ref` | `core/src/StoryFlow/Core/Id.hs` | entity-graph-core/F002 | `partOf` 目標一律本 Vault,`localRef` 組 `Ref` |
| `data Session = Session { wsId, wsType, wsConstraints, wsStages, wsCurrent, wsHistory, wsOwner :: Maybe Id, wsPending :: [StageDraft], wsCommitted :: [Id] }` | 尚未實作,以 `llm-workshop-mcp/design.md`「模組間公開介面與資料結構」為準 | F002 | `commitStage` 的參數與回傳的一部分;逐欄讀寫 `wsOwner`/`wsPending`/`wsCommitted`/`wsCurrent` |
| `data StageDraft = StageDraft { sdTitle, sdSummary, sdBody :: Text, sdTags :: [Text] }` | 同上 | F002 | `resolveOwner`/`commitDrafts` 的輸入,逐欄映射到 `NewEntityReq`/`NewFragmentReq` |
| `data WorkshopError = ... \| WsNothingToCommit Text \| ...`(七個建構子,本 feature 只產生 `WsNothingToCommit`) | 同上 | F002 | `commitStage` 的錯誤通道 |
| `saveSession :: Session -> ServiceM (Either WorkshopError ())`(套件內部函式) | 同上 | F002 | `commitStage` 成功寫完 Entity 後,寫出新快照 |

## 新增的介面

```haskell
-- storyflow-workshop : StoryFlow.Workshop.Emit ------------------------------
commitStage :: Session -> ServiceM (Either WorkshopError (Session, [EntityView]))
```

`resolveOwner` / `commitDrafts` 是模組內部私有函式,不對外公開(Level 3 實作自主權)。

## TodoList

- [ ] T1: 新增 `StoryFlow.Workshop.Emit` 模組骨架,加進 `workshop/storyflow-workshop.cabal` 的 `exposed-modules`(緊接 F002 已建好的三個模組之後,library `build-depends` 不需要新增任何套件——`storyflow-core`/`storyflow-service` 已在 F002 的清單內)  `dep: -`
- [ ] T2: `commitStage` 第一步:`wsPending` 為空 → `pure (Left (WsNothingToCommit (wsId session)))`,不呼叫任何 service 操作  `dep: T1`
- [ ] T3: `resolveOwner`:`wsOwner` 已有值直接沿用;`Nothing` 時 `listEntityTypes` 找 `wsType` 的 `EntityTypeSpec`(找不到 → `throwError (UnknownType _)`),取 `etsOwnerType`(`Nothing` 退回 `wsType`),借用 `head (wsPending session)` 的 `sdTitle`/`sdSummary` 組 `NewEntityReq`(`nerStatus = Draft`、`nerSource = Workshop wsType`、`nerBody = ""`)呼叫 `createEntity`  `dep: T2`
- [ ] T4: `commitDrafts`:對 `wsPending` 逐筆組 `NewFragmentReq`(`nfrType = Just wsType`、`nfrStatus = Just Draft`、`nfrSource = Just (Workshop wsType)`、`nfrLinks = [Link PartOf (localRef ownerId) Nothing]`)呼叫 `addFragment`,收集 `[EntityView]`  `dep: T3`
- [ ] T5: 組新 `Session`(`wsOwner`/`wsPending = []`/`wsCommitted` 累加片段 id/`wsCurrent + 1`),呼叫 `saveSession`;`Left` 原樣浮上去,`Right` 回傳 `(newSession, views)`  `dep: T4`
- [ ] T6: 測試底稿重用 F002 的 `StoryFlow.Workshop.Fixtures`(`withVault`/`runS`/`orDie` 或其等效函式,建臨時 Vault 只靠 `storyflow-service` 的 `createVault`/`openEnv`/`runService`,D8 先例)  `dep: T1`
- [ ] T7: 套件邊界測試延伸:`StoryFlow.Workshop.CabalSpec` 加一條斷言 `Workshop.Emit` 在 `exposed-modules`,且 library 的 `build-depends` 仍逐字等於 F002 釘住的清單(本 feature 未新增任何套件)  `dep: T1`

## 1-to-1 測試對照表

測試框架沿用 F002 的 hspec 形狀(`workshop/test/Spec.hs` 手動 `describe`),新增檔案放
`workshop/test/StoryFlow/Workshop/EmitSpec.hs`。

| Todo | 測試 | 說明 |
|------|------|------|
| T2 | `StoryFlow.Workshop.EmitSpec`「wsPending 為空」 | 對 `wsPending = []` 的 `Session` 呼叫 `commitStage`,`runService` 接:外層 `Right (Left (WsNothingToCommit sid))`;Vault 裡沒有新增任何 Entity(呼叫前後 `listEntities emptyFilter` 筆數相等) |
| T3 | `StoryFlow.Workshop.EmitSpec`「首次定案建主體」 | 對 `wsOwner = Nothing`、`wsPending` 非空的 `character-fragment` 型 `Session` 呼叫 `commitStage`:回傳的 `Session` 的 `wsOwner` 為 `Just _`;`getEntity` 該 id 拿到 `metaType == "character"`(取 `etsOwnerType`)、`metaStatus == Draft`、`metaSource == Workshop "character-fragment"`;對 `dialogue`(無 `owner_type`)型 `Session` 重跑一次,`metaType == "dialogue"`(退回型別鍵本身) |
| T4 | `StoryFlow.Workshop.EmitSpec`「片段逐筆建立」 | `wsPending` 含 3 筆 `StageDraft` 時,回傳的 `[EntityView]`(扣掉首次定案的主體那 1 筆)有 3 筆,各自 `metaType == wsType`、`metaStatus == Draft`、`metaSource == Workshop wsType`、`metaLinks` 含 `Link PartOf (localRef ownerId) Nothing` |
| T5 | `StoryFlow.Workshop.EmitSpec`「session 狀態更新與快照」 | 成功 `commitStage` 後:`wsPending' == []`、`wsCommitted'` 比呼叫前多 3 筆(新片段 id,不含 owner id)、`wsCurrent' == wsCurrent + 1`;`loadSession` 讀回的快照與回傳的 `newSession` 相等;對同一個已有 `wsOwner` 的 `Session` 再跑一次 `commitStage`,不會產生第二個主體(`wsOwner` 不變) |
| T5 | `StoryFlow.Workshop.EmitSpec`「lore-fragment 的已知缺口」 | 對 `lore-fragment` 型的 `Session`(`wsPending` 非空但沒有 timeline 來源)呼叫 `commitStage`,`runService` 接得到外層 `Left (StoreFailed _)` 或 `Left (ValidationFailed _ _)`(依 `checkEntity` 實際回傳的建構子斷言);這條測試**記錄已知限制**,不是要求它成功——標題與斷言內容以「這是目前會失敗」為准,待上層修 `StageDraft` 後再改成期待成功 |
| T6 | `StoryFlow.Workshop.EmitSpec`「底稿本身可用」 | `withVault`(或等效函式)建出的 `Env` 能被 `runS`/`runService` 直接用於 `listEntityTypes`、`createEntity`;呼叫前後之間互不污染(兩個 `it` 各自的臨時 Vault 互相看不到對方建立的 Entity) |
| T7 | `StoryFlow.Workshop.CabalSpec`(擴充 F002 的版本) | `StoryFlow.Workshop.Emit` 出現在 `exposed-modules`;`build-depends` 逐字比對仍等於 F002 定的清單,無新增套件 |

## 待確認假設

- A1:主體(`wsOwner`)的 `title` / `summary` / `body` 從哪裡來——`Session` 沒有獨立的
  「主題名稱」欄位,`startWorkshop :: Text -> [Id] -> ...` 的簽名也沒有標題參數。
  → 採取:借用**首次 `commitStage` 時 `wsPending` 的第一筆 `StageDraft`**的 `sdTitle` /
  `sdSummary` 當主體的對應欄位,`nerBody` 留空字串(正文由片段承載,不重複塞一次)。
  那筆 `StageDraft` 仍然照樣以 `addFragment` 建成一個獨立片段,不因為被借用當主體標頭就
  跳過。→ 影響:若判斷錯誤(例如應該用型別的 `etsName` 當通用預設標題、或
  `workshop-interface`〔尚未展開〕該多開一個「工作坊標題」輸入參數並經 `startWorkshop`
  傳進來),需要修改 `resolveOwner` 的欄位來源,以及可能回頭改 `startWorkshop` 的簽名
  (那是 Level 2 契約變動,不是本 feature 能單方面決定的)。
- A2:片段與主體的 `status` 預設 `Draft` 還是 `Canon`——`StageDraft` 刻意不含 `status`,
  契約沒有明訂哪一個。→ 採取:一律 `Draft`。依據:(1) ADR-003「只有 canon 參與衝突偵測的
  比對基準」;(2) system.md 資料流 A 的既有先例——外部 Agent 寫入一樣先 `status=draft`,
  作者確認後才手動改 `canon`;(3) 已讀 `conflict/src/StoryFlow/Conflict/Retrieval.hs` 確認
  `canonFilter = emptyFilter {efStatus = Just Canon}`(第 2 層候選)與 `expandOneHop` 的
  `isCanon m` 過濾(一跳擴充)——工作坊產出未經作者複核就直接進 `canon`,會讓地端模型的
  草稿立刻污染衝突偵測的比對基準,與「AI 產出先 draft 後 canon」的既有原則矛盾。
  → 影響:若判斷錯誤(例如工作坊的定位是「作者親自逐階段確認過的內容,可信度等同人類手寫」
  而非「AI 產出待審」),`resolveOwner`/`commitDrafts` 的 `Draft` 改 `Canon` 即可,是局部改動。
- A3:`commitStage` 是否要把 `wsCurrent` 前進一格。契約卡「明確不做」寫著「不決定階段流程
  (那是 workshop-stages)」,但 F002 的三個對外函式(`startWorkshop`/`stepWorkshop`/
  `loadSession`)沒有一個會修改 `wsCurrent`,而 design.md 資料流管線把「進入下一階段,
  直到 stages 走完」緊接在 `commitStage` 那一行之後。若 `commitStage` 不做,`wsCurrent`
  永遠停在同一格,工作坊會卡死在第一階段,`stepWorkshop` 也永遠問同一句開場白。
  → 採取:`commitStage` 成功寫完片段後把 `wsCurrent` +1 一起存進快照;把「不決定階段流程」
  理解成「不重新判斷/驗證 stages 從哪裡來、是否已耗盡」(那些邏輯在 F002 `stepWorkshop` 的
  `WsStagesExhausted` 檢查裡),而不是「連 +1 都不能做」——沒有其他函式能做這件事。
  → 影響:若判斷錯誤,「前進到下一階段」要移到 `workshop-interface`(尚未展開)在呼叫
  `commitStage` 成功後自己讀 `Session` 改欄位再存檔,但 `saveSession` 目前只在
  `Workshop.Session` 模組內部可見(F002 的 A3 未決定要不要外露),那條路目前打不通,
  間接支持「這件事只能是 `commitStage` 做」的判斷。
- A4:`commitStage` 回傳的 `[EntityView]` 是否包含主體(首次定案時)。契約卡驗收標準只講
  「多個片段 Entity」。→ 採取:**含**——首次定案時 `[EntityView]` = 主體 + 全部片段;之後
  定案只有片段。理由:呼叫端(`workshop-interface`)大概率要把「這次定案新建了什麼」完整
  顯示給使用者,主體是這次呼叫真正新建的東西之一,漏掉它使用者反而要另外查
  `wsOwner`。→ 影響:若判斷錯誤(應該只回片段,主體另外用 `wsOwner` 讓呼叫端自行
  `getEntity`),`commitStage` 的最後一步把 `views` 換成只有 `commitDrafts` 的結果即可,
  是局部改動,不影響其餘邏輯。
- A5:單次 `commitStage` 內多筆寫入(建主體 + N 筆 `addFragment`)不是交易性的
  ——`ServiceM` 沒有跨檔案的 rollback 機制,`storyflow-store` 也沒有暴露補償刪除的組合
  操作。若第 k 筆 `addFragment` 失敗(例如某筆 `StageDraft` 的 `summary` 是空字串觸發
  `ValidationFailed`),前面已成功建立的主體與 k-1 筆片段**留在 Vault 上不會被回滾**,
  而呼叫端拿到的是 `Left ServiceError`、手上的 `Session` 仍是呼叫前那份(`wsOwner` 可能
  還是 `Nothing`)。→ 採取:**不處理**,原樣接受這個風險——依據契約卡「明確不做:不在
  寫入失敗時自行重試改寫」,補償邏輯屬於另一種形式的「自行改寫」,且會把
  `Workshop.Emit` 拖進遠比「呼叫幾個既有函式」複雜的狀態管理。留下的孤兒 Entity 使用者
  能在 Vault 裡直接看到並手動刪除(「檔案才是真相來源」的既有精神)。→ 影響:若這個風險
  被判定不可接受,需要在 F003 之上(`workshop-interface` 或更上層)加一層「失敗後掃描並
  清理本次 session 遺留的孤兒 Entity」的邏輯,或者 `storyflow-store`/`storyflow-service`
  補一個跨檔案的批次寫入原語——兩者都是本 feature 範圍外的新契約。

## 實作備註

(開發過程中與設計的偏差記錄於此,撰寫時留空)
