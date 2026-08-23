---
id: F001
type: feature
title: llm-endpoint
description: OpenAI 相容 LLM 端點抽象、設定載入、逾時重試與錯誤語彙
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [service-and-interfaces/F001, entity-graph-core/F004]
related-adr: [ADR-006]
related-feature: []
---

# F001: OpenAI 相容 LLM 端點抽象

## 功能概述

建立新套件 `storyflow-llm`,提供**地端與雲端共用的同一組型別與呼叫路徑**:把
`[Message]` 送到一個 OpenAI 相容的 `/chat/completions` 端點,把回覆或錯誤帶回來。
這是子系統階段一的唯一 feature,也是 `conflict-detection #5 conflict-llm` 與整個工作坊
的共同上游。

要解決的問題有三個:

1. **沒有 LLM 存取層**。`storyflow-llm` 套件目前不存在,`http-client` 雖然已經因為
   `servant-client` 進了 `storyflow-cli` 與 `storyflow-server` 的相依,但沒有任何地方
   直接打過非 servant 的 HTTP 端點
2. **設定讀不到**。Vault 的 `.storyflow/config.toml` 有 `[llm]` 段,`storyflow-store`
   從 P1 起就把它原樣捧著不解讀;但 `StoryFlow.Service.Monad` 只 re-export 不透明的
   `Vault`(沒有 `(..)`),`vaultCfg` 存取子拿不到,消費者根本讀不到那張表
3. **撞名**。`store` 的佔位型別就叫 `LlmConfig`,與 Level 2 契約的五欄 `LlmConfig`
   同名同義不同型

驗收標準(逐條對應契約卡):

| # | 驗收標準 | 怎麼算通過 |
|---|---|---|
| 1 | 地端(llama.cpp / Ollama 等)與雲端共用同一組型別與呼叫路徑 | 只有 `lcBaseUrl` / `lcApiKey` 兩個值不同,`newLlmClient` 與 `chat` 的程式路徑完全一致;manager 同時吃 `http://` 與 `https://` |
| 2 | 逾時與重試由 `LlmConfig` 控制 | `lcTimeout` 進 `responseTimeout`,`lcRetries` 決定重試次數;兩者都由 `[llm]` 段設定,測試以 stub 端點的請求計數驗證 |
| 3 | `LlmError` 能區分「連不上服務」與「模型回了但格式不對」 | 四種情境(連線被拒 / 逾時 / 非 2xx / 200 但 JSON 形狀不對)各自落到不同建構子,且**只有前兩者會被重試** |
| 4 | 設定讀 Vault 的 `.storyflow/config.toml` | 經 `ServiceM` 的 `vaultConfig` 取得 `VaultConfig`,解析 `[llm]` 段;沒有該段時回錯誤且訊息說出下一步 |

明確**不做**(契約卡的硬邊界):不引入重量級 LLM SDK(只有 `http-client` +
`http-client-tls` + `aeson`);**不組 prompt**——`chat` 收到什麼 `[Message]` 就送什麼;
**不做串流**——請求裡明寫 `"stream": false`;不定義 CLI 與 REST 出口(`vaultConfig`
連同 `linkGraph` / `aliasIndex` 一樣**只開內嵌出口**)。

## 相依性

`depends-on: [service-and-interfaces/F001, entity-graph-core/F004]`。兩條都是**程式碼級**
的相依,不是文檔約定——兩份文檔都 `done`,對應的原始碼已經在樹上讀過。

- **`service-and-interfaces/F001`**:`storyflow-llm` 的設定讀取路徑完全走 `ServiceM`
  (`vaultConfig` / `Env` / `runService`),不直接依賴 `storyflow-store`。這與
  `conflict-detection`「所有讀取經 `ServiceM`」是同一條紀律,並由本 feature 的
  `CabalSpec` 釘住。本 feature 同時**在 `storyflow-service` 裡新增 `vaultConfig`**
  ——與 `conflict-detection/F004` 新增 `linkGraph` 的作法一致:消費者負責把自己
  需要的內嵌出口做出來
- **`entity-graph-core/F004`**:`Vault` / `VaultConfig` / `cfgLlm` 與那個要改名的佔位
  型別都定義在 `store/src/StoryFlow/Store/Vault.hs`,由該文檔擁有。本 feature 會改動
  該檔(改名)並讀取它的欄位

**可否平行開發**:本 feature 是階段一唯一的項目,無同波次的平行對象。但它**擋住兩條
下游**:`conflict-detection #5 conflict-llm` 與本子系統階段二的 `F002 workshop-stages`,
兩者都要 import `LlmClient` / `chat` / `Message`。

**跨子系統的副作用**:`conflict/test/StoryFlow/Conflict/CabalSpec.hs` 的 `forbidden`
清單目前含 `storyflow-llm`。本 feature **不動它**(conflict 現在確實不該依賴 llm);
等 `conflict-detection #5` 落地時再由該 feature 明確改掉,處理方式與 F003 放行
`storyflow-service` 同一種。

## 對應的 Level 2 契約

| 契約出處 | 條目 | 本 feature 的落點 |
|---|---|---|
| `llm-workshop-mcp/design.md` 對外契約 | `data LlmConfig`(`lcBaseUrl` / `lcModel` / `lcApiKey` / `lcTimeout` / `lcRetries`) | `StoryFlow.Llm.Config` |
| 同上 | `data LlmClient`(不透明) | `StoryFlow.Llm.Client` |
| 同上 | `newLlmClient :: LlmConfig -> IO LlmClient` | `StoryFlow.Llm.Client` |
| 同上 | `chat :: LlmClient -> [Message] -> IO (Either LlmError Text)` | `StoryFlow.Llm.Client` |
| 同上 | `LlmError` 的分類(「連不上服務」vs「回了但格式不對」) | `StoryFlow.Llm.Error` |
| 同上,「模組間公開介面」 | `Workshop.Stages → Llm.Client`:只用 `chat` 的簽名 | 本 feature 提供被呼叫端;不反向依賴 workshop |
| 同上,資料結構 | `data Message = Message { msgRole :: Role, msgContent :: Text }`、`data Role = System \| User \| Assistant` | `StoryFlow.Llm.Client`(見下) |
| `service-and-interfaces/design.md` 對外契約 | `vaultConfig :: ServiceM VaultConfig`(2026-08-20 加入,**只開內嵌出口**) | `StoryFlow.Service.vaultConfig`,本 feature 實作 |

**`Message` / `Role` 寫在 workshop 的資料結構那一段,但住在 `storyflow-llm`**:
`chat` 的簽名要用它們,而依賴方向是 `workshop → llm`。型別若住在 `storyflow-workshop`,
`storyflow-llm` 就得反過來依賴 workshop,`conflict-detection` 第 3 層也會被迫把整個工作坊
拖進來。`design.md` 把它們寫在那一節是**敘事上的分組**,不是套件歸屬。

**沒有超出契約的新公開介面**。`Llm.Config` 的載入函式(`parseLlmConfig` / `llmConfig`)
落在契約卡「負責模組 `Llm.Config`」與驗收標準「設定讀 Vault 的 `.storyflow/config.toml`」
之內;`StoryFlow.Llm.Error` 是為了讓 `Llm.Client` 與 `Llm.Config` 共用錯誤型別而不互相
import 的內部模組切分(Level 3 自主權);`store` 佔位型別的改名是 Level 3——`LlmConfig`
與 `VaultConfig` 兩個名字不出現在任何 design 文檔裡。

## 實作方式

### 一、套件骨架

新增 `llm/storyflow-llm.cabal`,`common warnings` / `common lang` **逐字照抄**
`conflict/storyflow-conflict.cabal` 那一組(`-Wall -Wcompat`;GHC2021 +
`DerivingStrategies` / `LambdaCase` / `OverloadedStrings` / `RecordWildCards` /
`StrictData`)。`cabal.project` 的 `packages:` 加一行 `llm/`(排在 `conflict/` 之後),
並補一段與其它套件同樣的:

```
package storyflow-llm
  ghc-options: -Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns
```

`allow-newer` **不動**。`http-client` 已經是既有相依(`storyflow-cli` 的 library、
`storyflow-server` 的 test-suite),`http-client-tls-0.3.6.4` 已在本機以
GHC 9.14.1 + 現行 `allow-newer`(只開 `*:base` / `*:template-haskell` / `*:ghc-prim`)
實際建置通過,**不是阻塞項**。

模組:

| 模組 | 內容 | 為什麼是這個切法 |
|---|---|---|
| `StoryFlow.Llm` | 門面,re-export 下面三個 | 與 `StoryFlow.Store` / `StoryFlow.Service` 同一種形狀:消費者只 import 一個名字 |
| `StoryFlow.Llm.Error` | `LlmError` / `renderLlmError` / `llmErrorCode` | Client 與 Config **都要用它**;放在任一邊都會讓另一邊反向 import |
| `StoryFlow.Llm.Config` | `LlmConfig` 五欄、`parseLlmConfig`、`llmConfig`、預設常數 | 契約卡的 `Llm.Config` |
| `StoryFlow.Llm.Client` | `Message` / `Role` / `LlmClient` / `newLlmClient` / `chat`,以及 OpenAI wire 形狀的私有編解碼 | 契約卡的 `Llm.Client` |

OpenAI 的請求/回應 JSON 形狀是**私有**的:它不是本子系統的 DTO,沒有任何消費者需要
看見它。因此不另開 `Llm.Json`(那是 `Conflict.Json` / `Service.Json` 的用途——那兩個
放的是**公開** DTO 的實例)。

`build-depends`(library)——**刻意不含 `storyflow-core`**:這一層完全不認得
`Entity` / `Meta` / `Id`,它只把 `[Message]` 搬進去、把 `Text` 搬出來:

```
, aeson
, base              >=4.14 && <5
, bytestring
, containers
, http-client
, http-client-tls
, http-types
, storyflow-service
, text
, toml-reader
```

`containers` 與 `toml-reader` 是為了拆 `[llm]` 那張表(`TOML.Table = Map Text Value`);
`storyflow-service` 是設定的唯一來源。**`storyflow-store` / `storyflow-md` /
`sqlite-simple` / `direct-sqlite` 一個都不准進來**,理由與 `storyflow-conflict` 完全相同:
「所有讀取經 `ServiceM`」這條界線靠的正是這幾個名字不出現。

`build-depends`(test-suite)——`warp` / `wai` **只准出現在這裡**:

```
, aeson
, base
, bytestring
, containers
, directory
, filepath
, hspec
, http-client
, http-types
, storyflow-llm
, storyflow-service
, temporary
, text
, toml-reader
, wai
, warp
```

`http-client` 在測試裡是給 T9 直接探測「那個埠真的拒絕連線」用的;`wai` + `warp` 起 stub
端點。測試底稿設 `STORYFLOW_VAULTS` / `STORYFLOW_REGISTRY` 兩個環境變數時**用字面字串**
(與 `conflict/test/.../Fixtures.hs` 的作法一致),因此 `storyflow-types` 不必進相依。

### 二、`store` 佔位型別改名

`store/src/StoryFlow/Store/Vault.hs` 的

```haskell
newtype LlmConfig = LlmConfig {llmTable :: TOML.Table}
```

改名為

```haskell
-- | @[llm]@ 那張表,__原樣捧著不解讀__。形狀由 storyflow-llm 定義(P5)。
newtype LlmSection = LlmSection {llmSectionTable :: TOML.Table}
  deriving stock (Show, Eq)
```

波及的位置**只有四處**(全樹 grep 過):

| 檔案 | 改什麼 |
|---|---|
| `store/src/StoryFlow/Store/Vault.hs` L12 | 模組匯出清單 `LlmConfig (..)` → `LlmSection (..)` |
| 同檔 L69 | `cfgLlm :: Maybe LlmConfig` → `Maybe LlmSection` |
| 同檔 L73–75 | 型別定義與註解(註解改寫成「形狀由 `storyflow-llm` 定」) |
| 同檔 L172 | `parseConfig` 裡的 `Just (LlmConfig t)` → `Just (LlmSection t)` |
| `store/test/StoryFlow/Store/VaultSpec.hs` L99 | `llmTable` → `llmSectionTable` |

`store/src/StoryFlow/Store.hs` 是 `module StoryFlow.Store.Vault` 的整模組 re-export,
**不用改**;`parseConfig` 收 `[llm]` 的邏輯(`M.lookup "llm" tbl` 命中 `TOML.Table t`
才給 `Just`)也**不用改**——它本來就只認「有沒有這張表」。

### 三、`StoryFlow.Service.vaultConfig`

```haskell
vaultConfig :: ServiceM VaultConfig
vaultConfig = asks (vaultCfg . envVault)
```

匯出清單裡加在「沿用 `store` 的定義(不重造)」那一組:`VaultConfig (..)` 與
`LlmSection (..)`;`vaultConfig` 本身放在 `-- * Vault` 那一節,旁邊補上與 `linkGraph` /
`aliasIndex` 同樣語氣的 haddock:**只開內嵌出口,不進 `StoryFlowAPI`、不進 CLI 指令樹**
——Vault 設定不是作者用指令查的東西,是子系統之間的讀取。

`storyflow-service.cabal` 的 `build-depends` **一個字都不會變**(`vaultCfg` 來自已經在
相依裡的 `storyflow-store`),既有的 `StoryFlow.Service.CabalSpec` 自動守住。唯一要改的是
test-suite 的 `other-modules` 多一行 `StoryFlow.Service.VaultConfigSpec`(T4 的測試住在
`service` 的 test-suite,不是 `llm` 的——被測的是 service 的匯出面),而它需要的
`containers` 已經在 service 的測試相依裡。

### 四、`LlmError` 與它的兩個渲染器

```haskell
data LlmError
  = -- | 連不上服務:連線被拒、DNS 解不出、逾時。__可重試__
    LlmUnavailable Text
  | -- | 服務回了,但狀態碼不是 2xx。狀態碼 + 回應內文(截斷)
    LlmHttpStatus Int Text
  | -- | 回了 2xx,但 JSON 不是 OpenAI 相容的形狀。__重試不會變對__
    LlmBadResponse Text
  | -- | Vault 的 config.toml 沒有 [llm] 段
    LlmConfigMissing
  | -- | [llm] 段在,但鍵缺漏 / 型別不對 / 認不得
    LlmConfigInvalid Text
  deriving stock (Show, Eq)

renderLlmError :: LlmError -> Text     -- 繁中,每一則說出下一步
llmErrorCode  :: LlmError -> Text      -- snake_case 穩定識別碼
```

**風格與 `ServiceError` 一致但型別獨立**——`system.md` 的全域錯誤處理策略是「每一層有
自己的錯誤型別,上層不重寫下層的訊息」。`LlmError` 因此**不進** `ServiceError`,
也不被 `errorCode` 認領;之後 `workshop` / `conflict` 第 3 層要把它端到 CLI/REST 時,
由那一層決定怎麼翻譯。

`LlmUnavailable` 帶 `Text` 而不是 `SomeException`:`SomeException` 沒有 `Eq`,而測試要
`shouldBe` 得動。訊息內容是 `HttpExceptionContent` 的 `show`。

codes:`llm_unavailable` / `llm_http_status` / `llm_bad_response` / `llm_config_missing` /
`llm_config_invalid`。

`renderLlmError` 的下一步必須具體,例如:

- `LlmConfigMissing` →「這個 Vault 的 `.storyflow/config.toml` 沒有 `[llm]` 段;請加上
  `[llm]` 並至少填 `base_url` 與 `model`」——**不猜地端預設值**:給一組預設值看似方便,
  但連不上時使用者看到的是「連線失敗」而不是「你還沒設定」,那是兩個完全不同的下一步
- `LlmUnavailable` →「連不上 `<base_url>`;請確認地端服務有沒有在跑,或把 `[llm]` 的
  `base_url` 改成正確的位址」
- `LlmBadResponse` →「端點回了 200 但內容不是 OpenAI 相容的 chat completion;請確認
  `base_url` 指向的是 `/v1` 這一層」

### 五、`LlmConfig` 與 `[llm]` 段的解析

```haskell
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text     -- 例:http://127.0.0.1:8080/v1
  , lcModel   :: Text
  , lcApiKey  :: Maybe Text
  , lcTimeout :: Int      -- 毫秒
  , lcRetries :: Int      -- 「額外」嘗試次數;總嘗試 = 1 + lcRetries
  }
  deriving stock (Show, Eq)

parseLlmConfig :: Maybe LlmSection -> Either LlmError LlmConfig
llmConfig      :: ServiceM (Either LlmError LlmConfig)
```

`[llm]` 段的形狀:

```toml
[llm]
base_url   = "http://127.0.0.1:8080/v1"   # 必填
model      = "qwen2.5-14b-instruct"       # 必填
api_key    = "sk-..."                     # 選配,地端通常不用
timeout_ms = 60000                        # 選配,預設 60000
retries    = 1                            # 選配,預設 1
```

規則:

- **`Nothing`(沒有 `[llm]` 段)→ `LlmConfigMissing`**,不猜預設值(批次澄清的裁定)
- `base_url` / `model` 缺漏或不是字串 → `LlmConfigInvalid`,訊息指名是哪個鍵
- `timeout_ms` / `retries` 不是整數、或是負數 → `LlmConfigInvalid`(`retries = 0` 合法,
  代表「不重試」;`timeout_ms = 0` 不合法)
- **未知鍵一律 `LlmConfigInvalid`**,訊息列出允許的鍵。理由與
  `StoryFlow.Types.Loader` 的「不容忍未知鍵」同一條:打錯 `timeou_ms` 若被默默忽略,
  使用者會以為自己設過了。`store` 的 `parseConfig` 對最上層寬鬆,那是因為那一層根本
  不解讀;這一層解讀了,就要負責講錯字
- **`base_url` 在解析時就驗**:`Network.HTTP.Client.parseRequest` 的
  `MonadThrow` 可以跑在 `Maybe` 裡,所以 `parseLlmConfig` 用
  `parseRequest (chatEndpoint cfg) :: Maybe Request` 做純驗證,不合法就 `LlmConfigInvalid`。
  設定錯誤在**載入時**爆掉,不是等到第一次 `chat` 才爆

`llmConfig` 只是 `parseLlmConfig . cfgLlm <$> vaultConfig` 的薄包裝。回傳
`ServiceM (Either LlmError LlmConfig)` 而**不是**丟 `ServiceError`:錯誤語彙屬於這一層,
往 `ServiceError` 塞建構子等於讓下層知道上層的事。

### 六、`LlmClient` 與 `chat`

```haskell
data Message = Message { msgRole :: Role, msgContent :: Text }
  deriving stock (Show, Eq)

data Role = System | User | Assistant
  deriving stock (Show, Eq)

data LlmClient                                    -- 不透明,不匯出建構子
newLlmClient :: LlmConfig -> IO LlmClient
chat :: LlmClient -> [Message] -> IO (Either LlmError Text)
```

`LlmClient` 內部是 `Manager` + `LlmConfig`。`newLlmClient` 是**全函式**(契約簽名沒有
錯誤通道),只做一件事:

```haskell
newTlsManagerWith tlsManagerSettings
  { managerResponseTimeout = responseTimeoutMicro (lcTimeout cfg * 1000) }
```

用 `http-client-tls` 的 manager 而不是 `defaultManagerSettings`:同一個 manager 要同時
吃地端的 `http://127.0.0.1:8080` 與雲端的 `https://...`,這正是驗收標準 1 說的「同一組
呼叫路徑」。Manager 建一次、隨 `LlmClient` 一起被消費者持有並重用——`http-client` 的
連線池就在它裡面。

`chat` 的一次嘗試:

1. `parseRequest (chatEndpoint cfg)`,其中
   `chatEndpoint = 去掉 lcBaseUrl 尾端的 "/" <> "/chat/completions"`
2. 設 `method = "POST"`、`Content-Type: application/json`、
   `Authorization: Bearer <key>`(**只有 `lcApiKey` 是 `Just` 時才加這個 header**)、
   `responseTimeout = responseTimeoutMicro (lcTimeout * 1000)`(request 上也設一次,
   讓 `LlmConfig` 是唯一的權威來源,不受 manager 是否被共用影響)
3. body:`{"model": …, "messages": [{"role": …, "content": …}], "stream": false}`。
   `stream` **明寫 false**:不做串流是硬邊界,而有些端點的預設值不是 false
4. `try (httpLbs req mgr) :: IO (Either HttpException (Response LBS.ByteString))`
5. 分類(見下)

`role` 的線上編碼是 `"system"` / `"user"` / `"assistant"`(OpenAI 的字串),與 Haskell
建構子名的大小寫不同,所以自己寫 `ToJSON`,不用 generic。

**錯誤分類**(建構子名逐字取自 `http-client-0.7.19` 的
`Network.HTTP.Client.Types`):

| 來源 | 判斷 | 結果 |
|---|---|---|
| `HttpExceptionRequest _ (ConnectionFailure _)` | 連不上 | `LlmUnavailable` |
| `HttpExceptionRequest _ ConnectionTimeout` | 連不上 | `LlmUnavailable` |
| `HttpExceptionRequest _ ResponseTimeout` | 等不到回應 | `LlmUnavailable` |
| `HttpExceptionRequest _ NoResponseDataReceived` / `ConnectionClosed` / `InternalException _` | 傳輸中斷 | `LlmUnavailable` |
| `InvalidUrlException _ _` | `base_url` 不合法 | `LlmConfigInvalid`(理論上已在解析時擋掉,這裡是兜底) |
| 其餘 `HttpExceptionContent` | — | `LlmUnavailable`(保守:傳輸層的問題一律當「服務不可用」) |
| `Right resp`,`statusCode ∉ [200..299]` | 服務回了但不成功 | `LlmHttpStatus` |
| `Right resp`,2xx 但 `decode` 失敗或沒有 `choices[0].message.content` | 形狀不對 | `LlmBadResponse` |

**注意**:`parseRequest` 產生的 `Request` 其 `checkResponse` 是 no-op,所以非 2xx
**不會**丟 `StatusCodeException`,而是正常回一個 `Response`。狀態碼要自己看
(`statusCode . responseStatus`)。`StatusCodeException` 仍然列在分類表裡當兜底。

`choices` 為空陣列 → `LlmBadResponse`(端點回了合法 JSON 但沒有任何回覆,消費者拿不到
`Text`)。`content` 是空字串 → **`Right ""`**:空回覆是模型的合法輸出,不是格式錯誤。

### 七、重試

總嘗試次數是 `1 + lcRetries`,而且**只有在這一次的結果是 `LlmUnavailable` 時才會有下一次**。

- **只重試 `LlmUnavailable`**(批次澄清的裁定):模型回了但格式不對,重試也不會變對;
  非 2xx 通常是設定問題(401 是 api_key、404 是 base_url),重試只是把同一個錯誤做四遍
- **不做退避睡眠**:連線被拒是立刻失敗的,而逾時已經等過 `lcTimeout` 了,再加睡眠只會
  讓一個本來就慢的失敗更慢
- 回傳的是**最後一次**的錯誤,不是第一次——最後一次才反映當下的狀態
- `lcRetries = 0` 就是「不重試」,是合法設定

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Vault = Vault { vaultName :: Text, vaultRoot :: FilePath, vaultCfg :: VaultConfig }` | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | `vaultConfig` 由 `envVault` 取 `vaultCfg` |
| `data VaultConfig = VaultConfig { cfgName :: Text, cfgReferences :: [Text], cfgLlm :: Maybe LlmConfig }` | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | `cfgLlm` 就是 `[llm]` 那張表;第三欄的型別由本 feature 改名為 `Maybe LlmSection` |
| `newtype LlmConfig = LlmConfig {llmTable :: TOML.Table}` | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | **本 feature 改名為 `LlmSection` / `llmSectionTable`**;表本身原樣交給 `parseLlmConfig` |
| `parseConfig :: FilePath -> Text -> Either StoreError VaultConfig`(私有;`llm` 由 `M.lookup "llm" tbl` 命中 `TOML.Table t` 時包成 `Just`) | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | 確認 `[llm]` 只被「有沒有這張表」判斷,內容完全不解讀 |
| `configPath :: FilePath -> FilePath`(`= storyflowDir root </> "config.toml"`) | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | 測試底稿寫 `[llm]` 段時定位設定檔 |
| `storyflowDir :: FilePath -> FilePath`(`= root </> ".storyflow"`) | `store/src/StoryFlow/Store/Vault.hs` | entity-graph-core/F004 | 同上 |
| `module StoryFlow.Store ( module StoryFlow.Store.Vault, … )`(整模組 re-export) | `store/src/StoryFlow/Store.hs` | entity-graph-core/F004 | 改名會自動穿透門面,`Store.hs` 不必改 |
| `data Env = Env { envVault :: Vault, envConn :: Connection, envTypes :: TypeRegistry }` | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `vaultConfig` 的取值來源 |
| `newtype ServiceM a`(`ReaderT Env (ExceptT ServiceError IO)`,newtype-derive `MonadReader Env` / `MonadError ServiceError` / `MonadIO`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | `vaultConfig` 與 `llmConfig` 跑在它上面 |
| `runService :: Env -> ServiceM a -> IO (Either ServiceError a)` | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 測試執行 `llmConfig` |
| `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError (Env, [IndexIssue]))` | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 測試底稿建 `Env`;**設定在這一步才被讀進 `Vault`**,所以測試必須先寫 `[llm]` 段再 `openEnv` |
| `closeEnv :: Env -> IO ()` | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 測試底稿的 `bracket` 收尾 |
| `vaultsEnvVar :: String`(`= "STORYFLOW_VAULTS"`) | `service/src/StoryFlow/Service/Monad.hs` | service-and-interfaces/F001 | 測試把全域註冊表指到臨時目錄,不碰使用者真正的 `vaults.toml` |
| `createVault :: FilePath -> Text -> IO (Either ServiceError VaultView)` | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | 測試底稿建臨時 Vault(只靠 service 門面,`storyflow-store` 不露臉) |
| `linkGraph :: ServiceM LinkGraph` / `aliasIndex :: EntityFilter -> ServiceM [(Id, [Text])]`(haddock 明寫「只開內嵌出口」) | `service/src/StoryFlow/Service.hs` | service-and-interfaces/F001 | `vaultConfig` 逐字沿用它們的形狀與註解語氣 |
| `renderServiceError :: ServiceError -> Text` / `errorCode :: ServiceError -> Text` | `service/src/StoryFlow/Service/Error.hs` | service-and-interfaces/F001 | `renderLlmError` / `llmErrorCode` 的**風格範本**(繁中說下一步 + snake_case),不是被呼叫者 |
| `type TOML.Table = Map Text TOML.Value`;`data TOML.Value = Table Table \| Array [Value] \| String Text \| Integer Integer \| Float Double \| Boolean Bool \| …` | toml-reader-0.3.0.0 | - | `parseLlmConfig` 拆 `[llm]` 表;取值寫法(`M.lookup` + 建構子比對)照抄 `types/src/StoryFlow/Types/Loader.hs` 的 `reqString` / `optBool` |
| `httpLbs :: Request -> Manager -> IO (Response LBS.ByteString)` | http-client-0.7.19 | - | `chat` 的唯一 HTTP 呼叫 |
| `parseRequest :: MonadThrow m => String -> m Request` | http-client-0.7.19 | - | 組請求;`m ~ Maybe` 時就是 `base_url` 的純驗證 |
| `responseTimeoutMicro :: Int -> ResponseTimeout` / `managerResponseTimeout :: ManagerSettings -> ResponseTimeout` | http-client-0.7.19 | - | `lcTimeout`(毫秒)× 1000 進逾時設定 |
| `responseStatus :: Response body -> Status` / `responseBody :: Response body -> body` | http-client-0.7.19 | - | 取狀態碼與回應內文 |
| `data HttpException = HttpExceptionRequest Request HttpExceptionContent \| InvalidUrlException String String` | http-client-0.7.19 | - | `chat` 的 `try` 目標 |
| `data HttpExceptionContent = StatusCodeException … \| ResponseTimeout \| ConnectionTimeout \| ConnectionFailure SomeException \| NoResponseDataReceived \| ConnectionClosed \| InternalException SomeException \| …` | http-client-0.7.19 | - | 錯誤分類表逐個建構子比對 |
| `tlsManagerSettings :: ManagerSettings` / `newTlsManagerWith :: MonadIO m => ManagerSettings -> m Manager` | http-client-tls-0.3.6.4 | - | 同一個 manager 吃 http 與 https |
| `statusCode :: Status -> Int` | http-types | - | 2xx 判斷 |
| `testWithApplication :: IO Application -> (Port -> IO a) -> IO a` | warp-3.4.15(`Network.Wai.Handler.Warp`) | - | 測試起本機 stub 端點;`server` / `cli` 的測試已經用同一個函式 |
| `type Application = Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived`;`responseLBS :: Status -> ResponseHeaders -> LBS.ByteString -> Response`;`strictRequestBody :: Request -> IO LBS.ByteString`;`requestHeaders`(wai) | wai | - | stub 端點的處理常式:讀請求、計數、依情境回應 |

## 新增的介面

```haskell
-- storyflow-llm : StoryFlow.Llm.Error --------------------------------------
data LlmError
  = LlmUnavailable Text      -- 連不上服務(連線被拒 / DNS / 逾時)。可重試
  | LlmHttpStatus Int Text   -- 服務回了非 2xx:狀態碼 + 截斷後的內文
  | LlmBadResponse Text      -- 2xx 但不是 OpenAI 相容的形狀。重試無用
  | LlmConfigMissing         -- Vault 的 config.toml 沒有 [llm] 段
  | LlmConfigInvalid Text    -- [llm] 段有,但鍵缺漏 / 型別不對 / 認不得
  deriving stock (Show, Eq)

renderLlmError :: LlmError -> Text    -- 繁中,每一則說出下一步
llmErrorCode  :: LlmError -> Text     -- snake_case 穩定識別碼

-- storyflow-llm : StoryFlow.Llm.Config -------------------------------------
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text
  , lcModel   :: Text
  , lcApiKey  :: Maybe Text
  , lcTimeout :: Int          -- 毫秒
  , lcRetries :: Int          -- 額外嘗試次數;總嘗試 = 1 + lcRetries
  }
  deriving stock (Show, Eq)

defaultLlmTimeoutMs :: Int                                    -- 60000
defaultLlmRetries   :: Int                                    -- 1
parseLlmConfig :: Maybe LlmSection -> Either LlmError LlmConfig
llmConfig      :: ServiceM (Either LlmError LlmConfig)

-- storyflow-llm : StoryFlow.Llm.Client -------------------------------------
data Role = System | User | Assistant
  deriving stock (Show, Eq)

data Message = Message { msgRole :: Role, msgContent :: Text }
  deriving stock (Show, Eq)

data LlmClient                                   -- 不透明
newLlmClient :: LlmConfig -> IO LlmClient
chat :: LlmClient -> [Message] -> IO (Either LlmError Text)

-- storyflow-llm : StoryFlow.Llm --------------------------------------------
-- 門面,re-export 上面三個模組

-- storyflow-service : StoryFlow.Service ------------------------------------
vaultConfig :: ServiceM VaultConfig               -- 只開內嵌出口
-- 並在「沿用 store 的定義(不重造)」那一組加上:
--   VaultConfig (..)
--   LlmSection (..)

-- storyflow-store : StoryFlow.Store.Vault(改名,Level 3)---------------------
newtype LlmSection = LlmSection { llmSectionTable :: TOML.Table }
  deriving stock (Show, Eq)
```

## TodoList

- [x] T1: 建 `llm/storyflow-llm.cabal`(common 段照抄 conflict)、`cabal.project` 加 `llm/` 與 ghc-options 段、`StoryFlow.Llm` 門面模組  `dep: -`
- [x] T2: `StoryFlow.Llm.Error`:`LlmError` 五個建構子、`renderLlmError`、`llmErrorCode`  `dep: T1`
- [x] T3: `store` 的佔位 `LlmConfig` 改名 `LlmSection`(型別、匯出清單、`cfgLlm` 欄位型別、`parseConfig` 的建構、store 測試)  `dep: -`
- [x] T4: `StoryFlow.Service` 新增 `vaultConfig :: ServiceM VaultConfig`,並在「沿用 store 的定義」那組 re-export `VaultConfig (..)` / `LlmSection (..)`  `dep: T3`
- [x] T5: `StoryFlow.Llm.Config`:`LlmConfig` 五欄、預設常數、`parseLlmConfig`(含必填/型別/未知鍵/`base_url` 驗證)、`llmConfig`  `dep: T2, T4`
- [x] T6: `StoryFlow.Llm.Client`:`Role` / `Message` 與它們的 wire 編碼、`LlmClient`、`newLlmClient`、`chat` 的成功路徑(組 URL、header、`stream:false`、取 `choices[0].message.content`)  `dep: T5`
- [x] T7: `chat` 的錯誤分類:`HttpException` → `LlmUnavailable` / `LlmConfigInvalid`;非 2xx → `LlmHttpStatus`;2xx 形狀不對 → `LlmBadResponse`  `dep: T6`
- [x] T8: 重試:總嘗試 `1 + lcRetries`,**只在 `LlmUnavailable` 時續試**,無退避睡眠,回傳最後一次的錯誤  `dep: T7`
- [x] T9: 測試底稿 `StoryFlow.Llm.Fixtures`:warp stub 端點(可設定回應內文/狀態碼/延遲,並以 `IORef` 計請求數)、`withDeadPort`、臨時 Vault + `[llm]` 段的 `withLlmVault`  `dep: T6`
- [x] T10: 套件邊界測試:`build-depends` 逐字釘住、禁用清單、`cabal.project` 已登錄 `llm/`  `dep: T1`

## 1-to-1 測試對照表

測試框架 **hspec**;`llm/test/Spec.hs` 照 `conflict/test/Spec.hs` 的形狀
(`hSetEncoding stdout utf8` + 手動 `describe "Tn …"`,不用 `hspec-discover`)。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `StoryFlow.LlmSpec` | **只 import `StoryFlow.Llm` 一個模組**就走完 `parseLlmConfig` → `newLlmClient` → `chat`(打 stub)一輪。與 `Service.FacadeSpec` 同一種證明:消費者不必知道套件內部分了幾個模組 |
| T2 | `StoryFlow.Llm.ErrorSpec` | 五個建構子的 `llmErrorCode` 互不重複、全為 snake_case;`renderLlmError` 每一則非空,且 `LlmConfigMissing` 的訊息同時含 `.storyflow/config.toml` 與 `[llm]`(「說出下一步」的可測形式) |
| T3 | `StoryFlow.Store.VaultSpec`(改既有那一條) | `[llm]` 段仍被原樣讀進 `Maybe LlmSection`,`llmSectionTable` 取得的表與寫進去的鍵值相同;另讀 `store/src/StoryFlow/Store/Vault.hs` 原始碼斷言字串 `LlmConfig` **不再出現**(改名若只加不減,行為測試看不出來) |
| T4 | `StoryFlow.Service.VaultConfigSpec` | 本檔**只 import `StoryFlow.Service`**(證明 `VaultConfig (..)` / `LlmSection (..)` 確實 re-export 了):新建 Vault 跑 `runService env vaultConfig` 拿到 `cfgName == "liftgame"`、`cfgReferences == []`、`cfgLlm == Nothing`;先寫 `[llm]` 段再 `openEnv` 則拿到 `Just`,`llmSectionTable` 裡有 `model` 鍵 |
| T5 | `StoryFlow.Llm.ConfigSpec` | 純函式部分:完整段解析出五欄;省略 `api_key`/`timeout_ms`/`retries` 時分別得到 `Nothing` / `defaultLlmTimeoutMs` / `defaultLlmRetries`;缺 `base_url` 或 `model` → `LlmConfigInvalid` 且訊息指名該鍵;`timeout_ms = "60000"`(字串)、`retries = -1`、未知鍵 `endpoint`、`base_url = "不是網址"` 四種各回 `LlmConfigInvalid`;`Nothing` → `LlmConfigMissing`。整合部分:在真 Vault 上 `runService env llmConfig` 拿到 `Right`,沒有 `[llm]` 段的 Vault 拿到 `Left LlmConfigMissing` |
| T6 | `StoryFlow.Llm.ClientSpec` | 對 stub 端點:`chat` 回 `Right` 且內容等於 stub 的 `choices[0].message.content`;stub 收到的請求 —— 路徑是 `/v1/chat/completions`(`base_url` 帶或不帶尾斜線結果相同)、body 的 `model` 等於 `lcModel`、`messages` 的 `role` 依序是 `system`/`user`/`assistant`、`stream` 是 `false`;`lcApiKey = Just "sk-x"` 時有 `Authorization: Bearer sk-x`,`Nothing` 時**沒有**該 header;`choices[0].message.content` 為 `""` 時回 `Right ""` |
| T7 | `StoryFlow.Llm.ErrorClassSpec` | 四種情境各驗一次:(a) `withDeadPort` 的埠 → `Left (LlmUnavailable _)`;(b) stub 延遲 800ms 而 `lcTimeout = 150` → `Left (LlmUnavailable _)`;(c) stub 回 500 與回 401 → `Left (LlmHttpStatus 500 _)` / `Left (LlmHttpStatus 401 _)`;(d) stub 回 200 但 body 是 `{"ok":true}`、以及 `{"choices":[]}` → 兩者都 `Left (LlmBadResponse _)` |
| T8 | `StoryFlow.Llm.RetrySpec` | (a) stub 延遲 800ms、`lcTimeout = 150`、`lcRetries = 1` → 結果是 `LlmUnavailable`,且 stub 的請求計數 **= 2**;(b) stub 回壞 JSON、`lcRetries = 3` → 結果是 `LlmBadResponse`,且請求計數 **= 1**(格式錯不重試);(c) `lcRetries = 0` + 逾時 → 計數 = 1 |
| T9 | `StoryFlow.Llm.StubSpec` | 底稿自己的契約:`withStub` 起得來、回得出設定好的內文、計數從 0 起算並隨請求遞增;`withDeadPort` 給的埠在區塊內用 `httpLbs` 打會拿到 `ConnectionFailure`(這是 T7(a) 賴以成立的前提,不能只是「大概沒人在那個埠上」) |
| T10 | `StoryFlow.Llm.CabalSpec` | `storyflow-llm.cabal` 的 `build-depends` 逐字等於設計裡那份清單(擋住順手多一個包);library 段不含 `storyflow-store` / `storyflow-md` / `sqlite-simple` / `direct-sqlite` / `servant` / `warp`(`warp` 只准出現在 test-suite);`storyflow-service` 必須在;`cabal.project` 含 `llm/` 且含 `package storyflow-llm` 段 |

**逾時與連線被拒怎麼可靠地做出來又不讓測試變慢**(D2 的核心關切):

- **逾時**:stub 的處理常式先 `threadDelay` 再回應。`lcTimeout` 設 **150 ms**、
  stub 睡 **800 ms**——差距夠大,慢機器上也不會偶發地「剛好沒逾時」;而測試實際只花
  `1 + lcRetries` 個 150 ms。stub 那條執行緒還在睡不影響斷言,`testWithApplication`
  離開區塊時會把它收掉;客戶端提前斷線對 warp 而言是正常事件,不會變成應用層例外
- **連線被拒**:`withDeadPort` 先用 `testWithApplication` 起一個 stub 拿到 warp 配給的
  埠號,**離開區塊讓它關掉**,再把那個埠號交給 act。聽取用的 socket 關閉後沒有
  `TIME_WAIT`,連過去就是 `ConnectionFailure`,而且**立刻**失敗(不必等逾時)。
  T9 把這個前提本身變成一條斷言,不讓它變成隱性假設
- **不用固定埠號**:任何寫死的埠都可能被別的東西佔著,那正是最典型的偶發失敗

## 待確認假設

- A1: `lcTimeout :: Int` 的**單位**在 Level 2 契約沒寫。→ 採取:**毫秒**,`[llm]` 的鍵
  叫 `timeout_ms`,預設 60000。理由:秒為單位時最小只能設 1 秒,逾時測試就得等 1 秒
  以上;毫秒讓測試用 150 ms 跑完,而設定檔寫 `60000` 也讀得懂。→ 影響:改單位要同時
  動鍵名、預設值常數與 `responseTimeoutMicro` 的換算。
- A2: `design.md` 寫「Vault 沒有 `[llm]` 段時 **`newLlmClient` 回錯誤**」,但契約的
  `newLlmClient :: LlmConfig -> IO LlmClient` **沒有錯誤通道**。→ 採取:錯誤由
  `Llm.Config` 的載入階段(`parseLlmConfig` / `llmConfig`)產生,`newLlmClient` 維持
  契約簽名並保持為全函式;裁定的精神(不猜預設值、訊息說出下一步)完整保留。
  → 影響:若要讓 `newLlmClient` 自己回錯誤,Level 2 的簽名要改成
  `LlmConfig -> IO (Either LlmError LlmClient)`,`design.md` 對外契約要跟著改。
- A3: `LlmError` 除了契約點名的兩類之外,另加 `LlmHttpStatus` 與兩個設定類建構子。
  → 採取:加。理由:401(api_key 錯)與 200-但-形狀不對的**下一步不同**,而契約的
  分類理由本身就是「兩者的下一步不同」;設定錯誤更是第三種下一步。→ 影響:若要求
  嚴格只有兩類,`LlmHttpStatus` 併進 `LlmBadResponse`、設定錯誤另立型別。
- A4: `[llm]` 段的鍵名 `base_url` / `model` / `api_key` / `timeout_ms` / `retries`,
  且**未知鍵視為錯誤**。→ 採取:如上。鍵名對齊欄位名的 snake_case,與註冊表 TOML
  的 `allowed_links` / `owner_type` 同一種風格;嚴格未知鍵沿用
  `StoryFlow.Types.Loader` 的既有立場。注意 `store/test/.../VaultSpec.hs` 的例子用的是
  `endpoint`,那只是「原樣捧著」的佔位示範,不構成鍵名約定。→ 影響:改鍵名要同步改
  文檔;目前沒有任何真實 Vault 依賴這些鍵。
- A5: `defaultLlmTimeoutMs = 60000`、`defaultLlmRetries = 1`。→ 採取:如上
  (契約卡說「預設保守」)。地端 7B 模型答一段話常常十幾秒,60 秒留了餘裕;重試 1 次
  足以吃掉「服務剛好在重啟」這種瞬時失敗。→ 影響:只改兩個常數。
- A6: `llmConfig` 回 `ServiceM (Either LlmError LlmConfig)` 而不是丟 `ServiceError`。
  → 採取:回 `Either`。理由:`system.md` 的「每一層有自己的錯誤型別,上層不重寫下層的
  訊息」——`storyflow-llm` 在 `service` **之上**,往 `ServiceError` 加建構子等於讓下層
  認識上層。→ 影響:若改成丟 `ServiceError`,`StoryFlow.Service.Error` 要動,而那會讓
  `errorCode` 多出 LLM 的代碼。
- A7: `LlmConfigMissing` 的訊息只寫相對路徑 `.storyflow/config.toml`,不帶 Vault 絕對
  路徑。→ 採取:如上。理由:`vaultConfig` 只回 `VaultConfig`,拿不到 `vaultRoot`;為了
  一句訊息去 re-export `Vault (..)` 會把 service 的匯出面撐大,而整個 `ServiceM` 呼叫
  本來就已經限定在單一 Vault 內,不會有歧義。→ 影響:要帶絕對路徑就得再開一個出口
  (或讓 `vaultConfig` 回 `(FilePath, VaultConfig)`)。
- A8: 改名後的型別叫 `LlmSection`,存取子 `llmSectionTable`(委派 prompt 建議 `LlmSection`,
  存取子名未指定)。→ 採取:如上,不沿用 `llmTable`——欄位名跟著型別名走比較好認。
  → 影響:改名波及 store 原始碼 4 處 + store 測試 1 處 + service re-export;
  `entity-graph-core/features/F004-store-vault-io-and-index.md` 第 134 / 172 行的敘述
  會與程式碼漂移,是否加註由編排者決定(委派模式不改別人的文檔)。
- A9: `chatEndpoint :: LlmConfig -> String`(去掉 `base_url` 尾斜線再接
  `/chat/completions`)是「新增的介面」清單沒有列到的一個名字,而它**住在
  `Llm.Config` 並被匯出**,原本因此也穿透了門面。→ **2026-08-20 階段閘門裁定:
  要求它退出公開面**。實際作法分兩半:(a) `chatEndpoint` **仍住在 `Llm.Config`**
  並繼續被 `Llm.Client` import——它有**兩個**呼叫端(`parseLlmConfig` 用它做
  `base_url` 的純驗證,見第五節的 `parseRequest (chatEndpoint cfg) :: Maybe Request`;
  `chat` 用它組請求),放進 `Llm.Client` 會讓 `Llm.Config` 反向 import `Llm.Client`,
  而為了藏它讓兩邊各寫一份 URL 規則等於同一條規則有兩份,兩種代價都不接受;
  (b) 門面 `StoryFlow.Llm` 從 `module X` 整包 re-export 改成**逐項列舉的匯出清單**,
  內容等於「新增的介面」章節列的那些名字,`chatEndpoint` 不在其中。
  → 影響:公開面不再由「某個名字剛好被哪個內部模組匯出」決定,而是由文檔決定;
  代價是**以後每加一個公開名字要改兩個地方**(內部模組的匯出清單,以及門面),
  這一點已寫進 `StoryFlow.Llm` 的 haddock。驗證方式:`cabal repl` 下
  `import StoryFlow.Llm` 後 `:t chatEndpoint` 回 `Variable not in scope`,而
  `import StoryFlow.Llm.Config`(套件內模組)後仍拿得到。

## 實作備註

**全部 10 項 Todo 完成,10 個 1-to-1 測試全部落地,`cabal test all` 10/10 suites PASS
(1169 examples, 0 failures)。**

### 契約落點與偏差

沒有偏離 Level 2 契約。`newLlmClient :: LlmConfig -> IO LlmClient` 維持契約簽名且是
**全函式**(A2 的裁定),設定錯誤全部在 `parseLlmConfig` / `llmConfig` 那一步產生;
`chat` 的簽名逐字如契約。`Message` / `Role` 如文檔的判斷住在 `storyflow-llm`。

公開面**逐字等於**「新增的介面」清單的 15 個名字:門面 `StoryFlow.Llm` 用逐項列舉匯出而非
整包 re-export(2026-08-20 閘門裁定 A9)。`chatEndpoint` 仍住在 `Llm.Config` 供套件內部共用,
URL 規則只有一份,但不再穿透門面。

### 值得記下來的三件事

1. **`http-client-tls-0.3.6.4` 不是阻塞項,已實測**。在 GHC 9.14.1 + 現行
   `allow-newer`(只開 `*:base` / `*:template-haskell` / `*:ghc-prim`)下,連同
   `tls-1.9.0` / `crypton-connection-0.4.5` / `crypton-x509-*` 一整串相依都裝得起來,
   **`cabal.project` 的 `allow-newer` 一個字都沒動**。`CabalSpec` 另加一條斷言把
   「沒有為了它放寬 allow-newer」釘住
2. **非 2xx 不會丟例外**。`parseRequest` 產生的 `Request` 其 `checkResponse` 是 no-op,
   所以 500 / 401 是正常回一個 `Response`,狀態碼由 `readResponse` 自己看
   (`statusCode . responseStatus`)。文檔已經預告了這一點,實作與測試都照著做
3. **stub 的請求計數必須在 `threadDelay` 之前遞增**。逾時測試的客戶端會在 stub 還在睡
   的時候就斷線,計數若放在回應之後就永遠數不到那一次,T8 的「請求計數 = 2」會變成
   恆為 0。這是實作底稿時真正踩到的唯一一個陷阱,已寫進 `Fixtures.hs` 的註解

### 測試的穩定性

逾時測試用 `lcTimeout = 150ms` 對 stub `threadDelay 800ms`,差距 5 倍以上;
`withDeadPort` 用「起 warp 拿埠 → 離開區塊關掉 → 用那個埠」,連過去立刻是
`ConnectionFailure`,不必等逾時。**沒有任何固定長 sleep,也沒有寫死的埠號**。
`storyflow-llm-test` 整套跑完 5.0 秒(其中大半是兩次 Vault 整合測試的 `openEnv`)。

### 既有測試的修改(兩處,都不是為了讓測試變綠)

| 檔案 | 改動 | 為什麼 |
|---|---|---|
| `store/test/StoryFlow/Store/VaultSpec.hs` | `llmTable` → `llmSectionTable`;**另加**一條讀原始碼斷言 `LlmConfig` 不再出現 | 前者是改名的必然波及;後者是 T3 明列的測試——改名若只加不減(留一個 deprecated 別名),行為測試看不出來,而兩個同名同義不同型的 `LlmConfig` 同時存在正是本 feature 要消滅的問題 |
| `service/test/Spec.hs` + `storyflow-service.cabal` | 掛上新的 `StoryFlow.Service.VaultConfigSpec` | T4 的測試住在 `service` 的 test-suite,因為被測的是 **service 的匯出面** |

**沒有任何既有斷言被放寬或刪除。** `storyflow-conflict` 一個字都沒動——它的
`forbidden` 清單仍然含 `storyflow-llm`,那是刻意的(conflict 現在還不該依賴 llm)。
