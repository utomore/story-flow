---
id: subarch-0002
type: subarch
title: service-and-interfaces
description: 業務契約層與它的三種薄包裝:CLI、REST API 與伺服器
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0002, adr-0005, adr-0006, adr-0008, adr-0009]
---

# 業務契約與介面 子系統架構

## 定位與範圍

主架構「子系統劃分」的第二節。這個子系統是 ADR-0006 的實體化:**所有業務操作只定義一次**,
CLI、REST server 與未來的 MCP adapter 全部是同一份契約的薄包裝。

涵蓋 `storyflow-service`、`storyflow-api`、`storyflow-server`、`storyflow-cli` 四個元件。

**明確不做**:落地細節(那是 `subarch-0001`)、衝突偵測(`subarch-0003`)、LLM 與工作坊
(`subarch-0004`)。`service` 不 import `conflict` 也不 import `llm` ——後兩者是**它的消費者**,
不是它的相依。

**這一層存在的價值不是「多一層」**,而是讓三種介面的行為由型別強制一致:邏輯只有一份,
不可能悄悄長歪。

## 需求說明

主架構的核心功能清單第 4 項是「API 優先:REST/JSON 是唯一的業務契約,CLI 與 MCP adapter
都是薄客戶端」。要讓這句話成立而不是口號,需要:

1. **一個業務層**,把「型別驗證有人呼叫」「Connection / Vault / 註冊表收進 Env」
   「錯誤講業務語彙」「組合操作有歸屬」四件 `store` 沒做的事補上
2. **樂觀鎖在兩種模式下都生效**——遠端模式恰恰是多客戶端並發真的會發生的那一種,所以
   `expected revision` 是必填,不留逃生口
3. **錯誤語彙三邊一致**:同一個失敗在 CLI 的 `--json`、REST 的 body、未來 MCP 的回報裡
   必須是同一個 code 與同一句訊息,否則 AI Agent 要為每個介面各學一次
4. **CLI 的兩種模式輸出完全相同**,而且是結構上成立,不是靠對照測試碰運氣

## 架構規劃

| 元件 | 職責 | 關鍵約束 |
|---|---|---|
| `storyflow-service` | `ServiceM = ReaderT Env (ExceptT ServiceError IO)`;23 個業務操作;`ServiceError` 與 `errorCode` / `renderServiceError`;View 與請求型別;集中的 aeson 實例 | 不含 HTTP 與終端輸出,`build-depends` 就是那條界線的證明 |
| `storyflow-api` | **只有** servant API 型別、`FromHttpApiData` / `ToHttpApiData`、`ToSchema`、`storyFlowOpenApi` | 不含 `servant-server` / `servant-client` / `warp` ——它是兩個消費端共用的契約 |
| `storyflow-server` | servant handler(每個一行)、`MVar Env` 序列化、Bearer token middleware、warp 啟動;執行檔 `story-flow-serve` | 不 import `storyflow-store`;handler 內無業務判斷 |
| `storyflow-cli` | optparse 指令樹、`Backend` 抽象(內嵌 / 遠端)、渲染器、統一信封;執行檔 `story-flow` | 不 import `storyflow-store`、`storyflow-server` 與 `warp` |

**為什麼 API 型別要獨立成套件**:`cli --remote` 需要 API 型別去產生 `servant-client`。型別若
住在 server 裡,CLI 就得依賴 server,連帶把整套 HTTP 伺服器拖進一個預設根本不開伺服器的
執行檔。這也是為什麼 `story-flow serve` 最後做成**獨立執行檔 `story-flow-serve`** 而不是
CLI 的子指令(func-0008 實作備註 1)。

## 對外介面

三個出入口,對應三種使用者。

**內嵌(供本專案其他子系統與測試)**

```haskell
data Env  -- Vault + Connection + TypeRegistry
newtype ServiceM a
openEnv    :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))
runService :: Env -> ServiceM a -> IO (Either ServiceError a)

-- 23 個業務操作,例如:
createEntity :: NewEntityReq -> ServiceM EntityView
updateEntity :: Id -> Int -> EntityPatch -> ServiceM EntityView   -- expected revision 必填
addNode      :: Id -> Id -> Int -> NewNodeReq -> ServiceM LevelView

-- 錯誤:機器看 code、人看 message,三種介面共用
errorCode           :: ServiceError -> Text   -- snake_case 穩定識別碼
renderServiceError  :: ServiceError -> Text   -- 繁中,每則都說出下一步
```

**REST(供外部 Agent 與 `subarch-0004` 的 MCP adapter)**

14 條路徑、23 個 operation,覆蓋 `ServiceM` 的每一個操作。`revision` 是必填的 query
parameter。錯誤 body 一律 `{"error":{"code":…,"message":…}}`,`code` 就是 `errorCode`。
OpenAPI 3 文件由同一份型別推導:`story-flow-serve --openapi > openapi.json`。

**CLI(供作者)**

`story-flow [--vault <名稱>|--remote <url>] [--json] <名詞> <動詞>`,21 個子指令。
exit code:`0` 成功、`1` 業務或傳輸失敗、`2` 用法錯誤。

## 使用的技術

沿用主架構。子系統特有的三個決定:

- **`mtl` 的 `ReaderT` + `ExceptT`**:業務操作是**組合**的,手工串 `Either` 會讓每個函式的
  主體被 `case` 淹沒,而錯誤處理正是最不該被淹沒的部分
- **`MVar Env` 而非連線池**:`sqlite-simple` 的 `Connection` 不保證多執行緒安全,而 warp 是
  多執行緒的。單一連線加互斥鎖讓「先寫檔、再更新索引」在**請求之間**也是原子的;代價是
  吞吐量,而單人工作室的吞吐量不是瓶頸
- **認證是 WAI middleware,不在路由型別裡**:`AuthProtect` 會讓 `servant-client` 多一層
  `AuthenticatedRequest` 包裝、OpenAPI 多一個安全定義。middleware 讓路由型別完全不知道有
  認證這回事,client 只要在 Manager 上加一個 header

## 架構圖

```text
                    subarch-0001 的 storyflow-store / storyflow-core
                                        │
                         ┌──────────────┴───────────────┐
                         │  storyflow-service           │  ★ 唯一業務契約
                         │                              │
                         │  ServiceM = ReaderT Env      │  Env = Vault+Conn+Registry
                         │             (ExceptT Err IO) │
                         │  23 個業務操作                │  型別驗證在這裡被呼叫
                         │  ServiceError / errorCode    │  錯誤語彙的唯一來源
                         └───┬──────────────────────┬───┘
                             │                      │
                   ┌─────────┘                      └─────────┐
                   │                                          │
       ┌───────────┴────────────┐              ┌──────────────┴──────────┐
       │  storyflow-api         │              │  storyflow-cli          │
       │  servant 型別(只有型別)│              │                         │
       │  ToSchema / HttpApiData│              │  Options(optparse)      │
       │  storyFlowOpenApi      │              │  Backend ─┬─ Embedded ───┼──► service
       └───┬────────────────┬───┘              │           └─ Remote ────┼──┐
           │                └──────────────────┼──► servant-client       │  │
           │                                   │  Render(唯一的渲染器)   │  │
   ┌───────┴──────────────┐                    └─────────────────────────┘  │
   │  storyflow-server    │                         exe: story-flow         │
   │                      │                                                 │
   │  handler(每個一行)  │◄────────────────────── HTTP ────────────────────┘
   │  MVar Env(序列化)   │
   │  bearerAuth(middleware)│
   │  toServerError       │  code 字串分派狀態碼,不碰 StoreError 建構子
   └──────────────────────┘
        exe: story-flow-serve                    對外:REST + OpenAPI
```

**兩種模式輸出相同是結構上成立的**:`Backend` 的分派落在「操作」層(23 個三行的分派函式),
指令層完全看不見兩個建構子,而渲染器只有一份。遠端路徑由 `servant-client` 依同一份 API
型別解碼回同一批 View 型別。

## 資料結構的框架格式

本子系統不擁有落地格式(那是 `subarch-0001`),它擁有**線上格式**:

- **View 型別**:`EntityView`(Entity + 路徑 + 錨點 + 警告)、`LevelView`(Level + 樹 + 路徑)、
  `VaultView` / `SearchHit` / `LinkReport` / `IndexReport` / `DeleteReport`
- **請求型別**:`NewEntityReq` / `NewFragmentReq` / `NewLevelReq` / `NewNodeReq` / `EntityPatch`
- **CLI 的統一信封**:`{"ok":true,"data":…}` / `{"ok":false,"error":{"code":…,"message":…}}`
  ——AI Agent 只需 parse 一種形狀
- **REST 的錯誤 body**:`{"error":{"code":…,"message":…}}`,與信封的 `error` 同形

`ToSchema` 與 `ToJSON` **逐欄對齊**,有測試拿樣本值的 JSON 鍵集合比對 schema 的 `properties`
——兩者分開手寫是 OpenAPI 文件說謊最常見的來源。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `mtl` | `ServiceM` 的 `ReaderT` + `ExceptT` |
| `servant` | API 型別即契約 |
| `servant-server` + `warp` + `wai` + `http-types` | REST 伺服器(只有 `storyflow-server`) |
| `servant-client` + `http-client` | CLI 的遠端模式(只有 `storyflow-cli`) |
| `servant-openapi3` + `openapi3` + `insert-ordered-containers` + `lens` | OpenAPI 3 推導 |
| `optparse-applicative` | CLI 指令解析 |
| `aeson` | 全部 body 的編解碼(沿用 core 的規則) |
| `hspec` / `temporary` / `async` | 測試、臨時 Vault、並發測試 |

## 開發階段

對應主架構的 **P2 與 P3**,已全部完成。

## 功能規劃

### 階段一:P2 業務契約與內嵌 CLI

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | service-contract | 以 `ServiceM` 定義五種實體的唯一業務契約 | subarch-0001 全部 | func-0006 |
| 2 | cli-embedded | `story-flow` 指令的內嵌模式,全指令支援統一信封的 `--json` | #1 | func-0007 |

### 階段二:P3 API 契約、伺服器與遠端 CLI

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | servant-api-server | servant REST API、OpenAPI 文件與 CLI 的遠端模式 | #1, #2 | func-0008 |

小結:共 **3 個 features、2 個階段**,全部已完成(`func-0006` ~ `func-0008` 皆 done)。
子系統可交付:P2 的「純 CLI 從零建出教室與琳達」與 P3 的「Agent 只靠 API 文件就能建/查
片段與關聯」兩條驗收標準都通過。

**已知的後續工作**(不構成新 feature,記在這裡免得被忘記):跨 Vault 的讀寫目前一律回
`501 cross_vault_unsupported`;要做的話會是本子系統的新 feature,而不是 `subarch-0001` 的。
