---
id: G-E002
type: enhance
title: standalone-distribution
description: 執行檔可獨立發佈:--version、執行檔旁的 registry/ 查找、doctor 診斷、發佈 zip
status: in-progress
created: 2026-08-23
updated: 2026-08-23
depends-on: [entity-graph-core/F002, entity-graph-core/F004, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003, llm-workshop-mcp/F001, llm-workshop-mcp/F005]
related-adr: [ADR-005, ADR-006]
related-feature: [entity-graph-core/F002, service-and-interfaces/F001, service-and-interfaces/F002, service-and-interfaces/F003, llm-workshop-mcp/F005]
subsystems: [entity-graph-core, service-and-interfaces, llm-workshop-mcp]
---

# G-E002: 執行檔可獨立發佈

## 現況分析

2026-08-23 實測三種拿到執行檔的方式(全部從 repo 外的乾淨目錄跑 `story-flow --json type list`):

| 拿到的方式 | 結果 | 原因 |
|---|---|---|
| `cabal install exe:story-flow` | **能跑**,零設定 | `storyflow-types.cabal:12` 宣告 `data-files: registry/*.toml`,安裝時五個 TOML 被複製進 `C:\cabal\store\ghc-9.14.1-bd8b\storyflow-typ_-0.1.0.0-<hash>\share\registry\`,執行檔烙印這個絕對路徑 |
| 從 `dist-newstyle/` 直接跑 dev build | `registry_unavailable` | dev build 沒經過安裝步驟,`Paths_storyflow_types` 烙印的 `C:\cabal\x86_64-windows-ghc-9.14.1-bd8b\storyflow-types-0.1.0.0` **不存在** |
| 只把 `story-flow.exe` 複製到別台機器 | `registry_unavailable` | 烙印的是本機 cabal store 的絕對路徑,別台機器沒有 |

第三種是真正的缺口:**現在沒有「一個 zip 解開就能跑」的發佈形式**。

### 三個觸點的程式碼現況

**註冊表定位**(`types/src/StoryFlow/Types/Loader.hs:63-72`):

```haskell
defaultRegistryDir :: IO (Maybe FilePath)
defaultRegistryDir =
  lookupEnv registryEnvVar >>= \case
    Just p | not (null p) -> existing p
    _ -> do
      base <- try getDataDir :: IO (Either IOException FilePath)
      either (const (pure Nothing)) (existing . (</> "registry")) base
```

兩層:環境變數 → cabal data 目錄。**沒有「執行檔旁邊」這一層**。`entity-graph-core/design.md:47` 與 `:143` 把這個定位方式寫進了模組表與架構圖(「以 cabal `data-files` + `STORYFLOW_REGISTRY` 定位」),所以改查找順序要回寫 Level 2。

找不到時的訊息(`service/src/StoryFlow/Service/Monad.hs:131-146`)只講這兩個地方:「隨執行檔安裝的 registry/ 目錄不在,而環境變數 STORYFLOW_REGISTRY 也沒有設定;請把它指向原始碼樹的 types/registry/」—— 對拿到 zip 的人來說,「原始碼樹」是不存在的東西。

**版本**:四份 `.cabal` 都是 `version: 0.1.0.0`,但**沒有任何執行檔能印出它**。`cli/src/StoryFlow/Cli/Options.hs:134` 的 `pinfo` 是 `helper <*> (globalP, commandP)`,沒有 `--version`;`storyflow-cli.cabal` 的 `other-modules` 也沒列 `Paths_storyflow_cli`。`server/app/Main.hs:32` 用 optparse 的 `execParser`;`mcp/app/Main.hs:13` 是手刻的 argv 掃描(llm-workshop-mcp/F005 的 A7 裁決)—— 三個執行檔是三種寫法。

**診斷**:沒有任何指令能回答「這個 CLI 在這裡跑得起來嗎」。`vault info` 要先有 Vault;`type list` 成功時不說註冊表從哪來;全域 `vaults.toml` 壞掉時(2026-08-22 發現中文 Vault 名會寫壞它)要到 `--vault` 定址或起 server 才會爆。

`Cli.hs:95-96` 的 `VaultInit` / `VaultList` 走 `direct` 不開 Vault —— 這是「不需要 Vault 的指令」的既有範本。

**`cli` 看不到 `store`**:找 Vault 不開索引的 `resolveVaultWith`(`store/src/StoryFlow/Store/Vault.hs:118`)只在 `store`,`service` 沒 re-export,而 `cli` 的 `CabalSpec` 禁止依賴 `storyflow-store`。`doctor` 要報告 Vault 位置與 `[llm]` 有無,得由 `service` 開一個新的內嵌出口 —— 與 `vaultConfig`(F001 階段一)、`vaultRoot`(F002 階段二)完全同一種先例。

## Scope(涵蓋範圍)

2026-08-23 與開發者討論定案。

**動**:

| 子系統 | 套件 / 檔案 | 改什麼 |
|---|---|---|
| entity-graph-core | `types/src/StoryFlow/Types/Loader.hs` | 查找順序加「執行檔旁的 `registry/`」,並讓呼叫端知道**從哪一層**找到的 |
| service-and-interfaces | `service/src/StoryFlow/Service/Monad.hs` | `registryHint` 改講三個地方;新增內嵌出口 `locateVault`(找 Vault 不開索引) |
| service-and-interfaces | `cli/src/StoryFlow/Cli/Options.hs`、`Cli.hs`、`Cli/Render.hs` | `--version`;新指令 `doctor` |
| service-and-interfaces | `server/app/Main.hs` | `--version` |
| llm-workshop-mcp | `mcp/app/Main.hs`、`mcp/src/StoryFlow/Mcp/Config.hs` | `--version` |
| — | `scripts/release.ps1`、`scripts/release.sh`、發佈 README | 產出發佈資料夾並壓縮 |
| — | 三個套件的 `.cabal` | `other-modules` / `autogen-modules` 加 `Paths_<pkg>` |

**不動**:

- **不做互動式首次引導**。第一個跑這個 CLI 的是 Claude Code,stdin 不是 TTY;`--json` 與 MCP 的 stdout 都是協定通道,一行引導文字就破了(ADR-006「API 優先」)
- **不做 `registry set` 之類的持久化設定**,不新增任何全域設定檔。環境變數已經是無狀態的覆寫機制;多一個全域檔就多一個會壞、會過期的地方(`vaults.toml` 才剛發現會被寫壞)
- **不動 `cabal.project`**(含 `allow-newer`)
- **不動 REST**:`doctor` 只有 CLI,沒有 `GET /doctor`。它診斷的是**這台機器**(執行檔、環境變數、本機檔案),跨 HTTP 沒有意義
- **不動 `vault init` 的行為**、不動註冊表的 TOML 格式、不動任何型別宣告
- **不改版本號**:四份 `.cabal` 維持 `0.1.0.0`,版本號由開發者指定

**排除的「順便改」**(討論中提出,另開文檔):

- 2026-08-22 smoke test 找到的三個 bug(中文 Vault 名寫壞 `vaults.toml`、給人看的輸出在 Windows 是 CP950、`vault init .` 把相對路徑寫進全域註冊表)→ 各走 `/bugfix`。`doctor` 的全域註冊表檢查會**指出**第一個,但修它不在本文檔
- `G-E001`(拆 `service-and-interfaces`)→ 獨立提案,見「相依性」

## 改善目標

| 指標 | 現況 | 目標 | 量測方式 |
|---|---|---|---|
| 複製執行檔 + `registry/` 到乾淨目錄,不設環境變數 | `registry_unavailable` | **`doctor` exit 0,`type list` 回 5 個型別** | 測試用 `withSystemTempDirectory` 模擬執行檔旁目錄 |
| `--version` | 三個執行檔都沒有 | 三個都有,**輸出格式相同**:`<執行檔名> <版本>` 一行 | 三條測試各自斷言 |
| 註冊表找不到的訊息 | 講兩個地方 | 講**三個**地方,且不再提「原始碼樹」 | 斷言訊息含三個關鍵字 |
| `doctor` 在沒有 Vault 的目錄 | 指令不存在 | 跑得起來,Vault 那一節報「找不到」而非整個失敗 | 測試 |
| `doctor` 對壞掉的 `vaults.toml` | 無從得知 | 全域註冊表那一節報出解析錯誤與檔案路徑 | 測試餵一份壞檔 |
| 發佈腳本 | 無 | 產出 `story-flow-<版本>-<平台>/`,內含**恰好**:3 個執行檔、`registry/` 五個 TOML、`README.md`;並壓成 zip | 測試列舉目錄內容逐字比對 |
| 全套測試 | 12 suites / 1435 / 0 failures | suites 不變、examples 不減、0 failures | `cabal test all` |
| 建置 warning | 0 | 0 | `cabal build all` |

**驗收標準**:上表全數達成,且 `cabal.project` 的 `git diff` 為空。

## 相依性

`depends-on` 七份皆 `done`,由「使用到的既有串接介面」表反推(一致性檢查補了 `entity-graph-core/F004` 與 `service-and-interfaces/F001` 兩份——第一版漏列):

- **entity-graph-core/F002**:`Types.Loader` 的 `defaultRegistryDir` / `loadRegistry` / `renderLoadError` 是它建的;本次改它的查找順序
- **entity-graph-core/F004**:`resolveVaultWith` 與 `VaultConfig` —— `locateVault` 包的就是它
- **service-and-interfaces/F001**:`vaultsFile` / `listVaults` 與 `Monad.hs` 的 `registryHint` —— `doctor` 第 4 項與訊息改寫都在它的地盤
- **service-and-interfaces/F002**:CLI 內嵌模式、`GlobalOpts` / `Command` / `direct` 分派、統一信封 —— `doctor` 與 `--version` 長在這上面
- **service-and-interfaces/F003**:`story-flow-serve` 執行檔與它的 `pinfo` —— 加 `--version`
- **llm-workshop-mcp/F001**:`parseLlmConfig` —— `doctor` 用它判斷 `[llm]` 段解不解得開(不連線)
- **llm-workshop-mcp/F005**:`story-flow-mcp` 執行檔與它手刻的 argv 掃描 —— 加 `--version`

**與 `G-E001` 的關係**:`G-E001`(拆 `service-and-interfaces` 為契約層與介面包裝層)今天建檔、`open`。本文檔**不依賴它**,兩者可平行;但若 G-E001 先落地,本文檔 frontmatter 的 `subsystems` 與上表的子系統名要跟著改(`service-and-interfaces` 會拆成兩個 slug)。本文檔動到的 `service/` 屬契約層、`cli/` / `server/` 屬介面層,拆完之後剛好一邊一半。

**可平行開發**:可以。沒有進行中的 feature 會碰 `Loader.hs` / `Options.hs` / 三個 `Main.hs`。

## 改善方案

### 一、註冊表查找:三層,並說出是哪一層

`Types.Loader` 新增:

```haskell
-- | 註冊表是從哪一層找到的。doctor 要說得出來,錯誤訊息也要列得出找過哪裡。
data RegistrySource
  = FromEnv            -- STORYFLOW_REGISTRY
  | BesideExecutable   -- <執行檔所在目錄>/registry/
  | FromDataDir        -- cabal data-files(cabal install 之後)
  deriving stock (Show, Eq)

locateRegistry :: IO (Maybe (RegistrySource, FilePath))
```

查找順序固定為 **env → 執行檔旁 → cabal data 目錄**:

- 環境變數有值但目錄不存在 → **維持現行語意,直接回 `Nothing`,不往下退**(`Loader.hs:56-62` 的理由:打錯的環境變數靜默載入另一份註冊表,比報錯更難查)
- 執行檔旁:`takeDirectory <$> getExecutablePath`,再 `</> "registry"`;目錄存在才算。放在 cabal data 目錄**之前**:同一台機器上有舊的 cabal 安裝時,zip 解開的那份要用自己帶的註冊表
- `defaultRegistryDir` **簽名不變**,改為 `fmap snd <$> locateRegistry`;既有呼叫端零影響

`registryHint`(`service`)改為列三個地方:環境變數(設了的話說指到哪、為什麼不行)、執行檔旁(說出實際查過的路徑)、cabal 安裝目錄。結尾的建議改成「把 `registry/` 放到執行檔旁邊,或設 `STORYFLOW_REGISTRY`」—— 不再提原始碼樹。

### 二、`--version`:三個執行檔,同一個格式

輸出一行:`<執行檔名> <版本>`,例如 `story-flow 0.1.0.0`。版本讀各自套件 cabal 自動產生的 `Paths_<pkg>.version`(`Data.Version.showVersion`),**單一來源是 `.cabal` 的 `version` 欄**,程式碼裡不寫第二份。三個套件的 library 段要把 `Paths_storyflow_cli` / `Paths_storyflow_server` / `Paths_storyflow_mcp` 加進 `other-modules` 與 `autogen-modules`。

- `story-flow` 與 `story-flow-serve`:optparse 的 `infoOption`(所有版本都有,不賭 `simpleVersioner`),掛在各自的 `pinfo` 上
- `story-flow-mcp`:手刻掃描多認一個 `--version`,印出後 exit 0,**在進入 JSON-RPC 迴圈之前**。這是 CLI 式呼叫,不是 session,不違反「stdout 只有 JSON-RPC」

### 三、`doctor`:五項「讀不連」的診斷

新 `Command` 建構子 `Doctor`,走 `direct`(不開 Vault,照 `VaultList` 的範本);**不支援 `--remote`**(它診斷本機)。五項依序:

| # | 項目 | 怎麼查 | 報什麼 |
|---|---|---|---|
| 1 | 版本 | `Paths_storyflow_cli.version` | `story-flow 0.1.0.0` |
| 2 | 型別註冊表 | `locateRegistry` → `loadRegistry` | 從哪一層(三選一)、路徑、載到幾個型別;載入失敗列 `renderLoadError` |
| 3 | Vault | `locateVault (goVault g) cwd` | 名稱、根目錄;找不到時說從哪個目錄往上找過、或 `--vault` 名在註冊表裡對不到 |
| 4 | 全域註冊表 | `listVaults` | 檔案路徑、幾個 Vault;解析失敗原樣帶 `renderServiceError`(**這一項會指出中文名寫壞檔案的 bug**) |
| 5 | `[llm]` | 第 3 項拿到的 `VaultConfig` 的 `cfgLlm` → `parseLlmConfig` | 沒有 / 有且解得開(列 `base_url` 與 `model`)/ 有但解不開(原樣帶 `renderLlmError`);第 3 項失敗就標「無法檢查」 |

**退出碼**:第 2 項失敗 → exit 1(沒有註冊表什麼都不能做);其餘四項是資訊,不影響退出碼。第 3 項找不到 Vault **不是失敗** —— 使用者可能正要 `vault init`。

**輸出**:`--json` 走統一信封,`data` 是五個鍵的物件(`version` / `registry` / `vault` / `vault_registry` / `llm`),每個子物件有 `ok :: Bool` 與各自欄位,鍵名 snake_case。給人看的版本每項一行,前綴 `[ok]` / `[!!]` / `[--]`(無法檢查)—— 用 ASCII 不用符號,因為給人看的那條路徑目前在 Windows 是 CP950(另案的 bug),符號會先壞。

`service` 新增內嵌出口:

```haskell
locateVault :: Maybe Text -> FilePath -> IO (Either ServiceError (VaultView, VaultConfig))
```

找到就回 `VaultView`(`vvEntityCount = Nothing`,因為刻意不開索引)與設定;內部是 `vaultsFile` + `resolveVaultWith`,與 `openEnv` 前兩步相同。只開內嵌出口、不上 REST,理由與 `vaultConfig` / `vaultRoot` 相同:這是子系統之間的讀取,不是作者的指令。

### 四、發佈腳本

`scripts/release.ps1` 與 `release.sh` 做同一件事:

1. `cabal install exe:story-flow exe:story-flow-serve exe:story-flow-mcp --installdir=<out> --install-method=copy --overwrite-policy=always`
2. `<out>` 命名為 `story-flow-<版本>-<平台>/`,版本從 `story-flow --version` 的輸出取(不從 `.cabal` 自己 parse —— 那是第二份規則),平台寫死 `windows-x64` / `linux-x64` / `macos-arm64` 依腳本判斷
3. 複製 `types/registry/*.toml` → `<out>/registry/`
4. 寫 `<out>/README.md`:怎麼跑、三個執行檔各是什麼、`registry/` 要跟執行檔放一起、什麼時候才需要 `STORYFLOW_REGISTRY`、第一步建議跑 `story-flow doctor`
5. 壓成 `<out>.zip`

腳本**不吞 stderr 當失敗**(`scripts/check.ps1` 有這個毛病,不重蹈)。失敗就停,不產出半個 zip。

## 使用到的既有串接介面

每一列的簽名逐條讀自來源檔案:

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `defaultRegistryDir :: IO (Maybe FilePath)` | `types/src/StoryFlow/Types/Loader.hs:63` | `entity-graph-core/F002` | 保留簽名,改為 `locateRegistry` 的投影 |
| `registryEnvVar :: String` | `Loader.hs:50` | `entity-graph-core/F002` | 查找第一層與訊息 |
| `loadRegistry :: FilePath -> IO (Either [LoadError] TypeRegistry)` | `Loader.hs:109` | `entity-graph-core/F002` | `doctor` 第 2 項 |
| `renderLoadError :: LoadError -> Text` | `Loader.hs:91` | `entity-graph-core/F002` | `doctor` 第 2 項的錯誤列表 |
| `resolveVaultWith :: FilePath -> Maybe Text -> FilePath -> IO (Either StoreError Vault)` | `store/src/StoryFlow/Store/Vault.hs:118` | `entity-graph-core/F004` | `locateVault` 內部用;`cli` 看不到它 |
| `vaultsFile :: IO FilePath` | `service/src/StoryFlow/Service/Monad.hs:93` | `service-and-interfaces/F001` | `locateVault` 與 `doctor` 第 4 項 |
| `listVaults :: IO (Either ServiceError [VaultView])` | `service/src/StoryFlow/Service.hs:141` | `service-and-interfaces/F001` | `doctor` 第 4 項;它已經會解析 `vaults.toml` |
| `data VaultConfig = VaultConfig { cfgName :: Text, cfgReferences :: [Text], cfgLlm :: Maybe LlmSection }` | `store/src/StoryFlow/Store/Vault.hs:65` | `entity-graph-core/F004` | `locateVault` 回傳;`doctor` 第 5 項取 `cfgLlm` |
| `parseLlmConfig :: Maybe LlmSection -> Either LlmError LlmConfig` | `llm/src/StoryFlow/Llm/Config.hs:86` | `llm-workshop-mcp/F001` | `doctor` 第 5 項 |
| `parseCli :: [String] -> ParserResult (GlobalOpts, Command)` | `cli/src/StoryFlow/Cli/Options.hs:131` | `service-and-interfaces/F002` | `--version` 與 `doctor` 掛進這棵樹 |
| `dispatch :: CliIO -> GlobalOpts -> Command -> IO ExitCode` | `cli/src/StoryFlow/Cli.hs:93` | `service-and-interfaces/F002` | `Doctor` 走 `direct` 分支 |
| `pinfo :: ParserInfo Opts` | `server/app/Main.hs:53` | `service-and-interfaces/F003` | `story-flow-serve --version` 掛在這上面 |
| `resolveConfig :: [Text] -> IO (Either Text Config)` | `mcp/src/StoryFlow/Mcp/Config.hs:28` | `llm-workshop-mcp/F005` | 手刻 argv 掃描;`--version` 在它之前攔截 |

## 介面變動

**新增**:

| 介面 | 層級 | 說明 |
|---|---|---|
| `Types.Loader.RegistrySource`、`locateRegistry :: IO (Maybe (RegistrySource, FilePath))` | Level 3(但 `entity-graph-core/design.md:47,143` 的描述要更新) | 三層查找並回報來源 |
| `Service.locateVault :: Maybe Text -> FilePath -> IO (Either ServiceError (VaultView, VaultConfig))` | **Level 2**,`service-and-interfaces` 內嵌出口(操作數 27 → 28) | 找 Vault 不開索引 |
| CLI `--version`、`doctor` | **Level 2**,`service-and-interfaces/design.md` 對外形式表(葉子指令 25 → 26) | — |
| `story-flow-serve --version`、`story-flow-mcp --version` | Level 3 | — |
| `scripts/release.ps1` / `.sh` | — | 發佈 |

**修改**:`registryHint` 的訊息內容(不是簽名)。

**移除**:無。

**受影響的呼叫端**:`defaultRegistryDir` 簽名不變,`Monad.hs:126` 的 `loadTypeRegistry` 零改動。`resolveVaultWith` 多一個呼叫端(`locateVault`),簽名不變。

**對外契約(REST / MCP)**:零變動。`doctor` 刻意不上 REST。

## TodoList

- [x] T1: `Types.Loader` 新增 `RegistrySource` 與 `locateRegistry`,查找順序 env → 執行檔旁 → data 目錄;`defaultRegistryDir` 改為投影,簽名不變  `dep: -`
- [x] T2: `service` 的 `registryHint` 改講三個地方,結尾建議不再提原始碼樹  `dep: T1`
- [x] T3: `service` 新增內嵌出口 `locateVault`,門面逐項列舉匯出;`service` 的 `CabalSpec` 逐字清單**不動**  `dep: -`
- [x] T4: 三個套件的 `.cabal` 加 `Paths_<pkg>` 進 `other-modules` / `autogen-modules`;三份 `CabalSpec` 逐字清單同步(若有釘住 modules)  `dep: -`
- [x] T5: `story-flow --version`(`infoOption` 掛 `pinfo`),輸出 `story-flow <版本>`  `dep: T4`
- [x] T6: `story-flow-serve --version`,同格式  `dep: T4`
- [x] T7: `story-flow-mcp --version`,手刻掃描多認一個旗標,JSON-RPC 迴圈之前印出並 exit 0  `dep: T4`
- [ ] T8: `Command` 加 `Doctor`、`Options.hs` 加 `doctor` 子指令、`dispatch` 走 `direct`;`--remote` 併用時回 `CliUsage`  `dep: T3, T5`
- [ ] T9: `doctor` 五項診斷的組裝與 `DoctorReport` 型別;退出碼規則  `dep: T1, T8`
- [ ] T10: `doctor` 的兩種輸出:`--json` 信封(snake_case 五鍵)與給人看的 `[ok]` / `[!!]` / `[--]` 行  `dep: T9`
- [ ] T11: `scripts/release.ps1` 與 `release.sh`:安裝三個執行檔、複製 `registry/`、寫 README、壓 zip;不吞 stderr  `dep: T5, T6, T7`
- [ ] T12: 回寫 `entity-graph-core/design.md`(模組表與架構圖的定位描述)與 `service-and-interfaces/design.md`(`locateVault` 內嵌出口、葉子指令數、對外形式表加 `doctor` 與 `--version`)  `dep: T3, T8`
- [ ] T13: 全套驗收:`cabal build all` 零 warning、`cabal test all` suites 不變且 examples 不減、`cabal.project` 的 `git diff` 為空  `dep: T10, T11, T12`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `types-test`:三條 —— 環境變數優先且指到不存在目錄時回 `Nothing` 不退;`withSystemTempDirectory` 放一個 `registry/` 並以假的執行檔路徑注入,回 `BesideExecutable`;兩者都沒有時回 `FromDataDir` 或 `Nothing` | 執行檔路徑要可注入(`locateRegistryWith :: IO FilePath -> IO (...)`),否則測不到第二層 |
| T2 | `service-test`:訊息含「STORYFLOW_REGISTRY」「執行檔」「cabal」三個關鍵字,且**不含**「原始碼樹」 | 回歸:舊訊息的斷言若有就改掉,並在實作備註記下 |
| T3 | `service-test`:`locateVault` 在臨時 Vault 回 `Right`,`vvEntityCount` 是 `Nothing`;在非 Vault 目錄回 `Left (StoreFailed (VaultNotFound _))`;**不建立 `index.db`**(斷言檔案不存在) | 「不開索引」是可測的 |
| T4 | 三份 `CabalSpec`:`autogen-modules` 含對應的 `Paths_` | — |
| T5 | `cli-test`:`runCliWith` 餵 `["--version"]`,stdout 恰好一行 `story-flow <showVersion version>`,exit 0 | 版本字串與 `Paths_` 比對,不寫死 |
| T6 | `server-test`:同上,`story-flow-serve` | — |
| T7 | `mcp-test`:`["--version"]` → stdout 一行,**不進入 `processLine`**;另斷言 `["--url", ...]` 正常路徑不受影響 | 回歸 |
| T8 | `cli-test`:`parseCli ["doctor"]` 得 `Doctor`;`["--remote", "x", "doctor"]` 得 `CliUsage`,exit 2 | — |
| T9 | `cli-test`:四個情境 —— (a) 註冊表找不到 → exit 1 且第 2 項 `ok = false`;(b) 註冊表在、無 Vault → exit 0 且第 3 項 `ok = false` 第 5 項標無法檢查;(c) 完整 Vault 無 `[llm]` → 第 5 項「沒有」;(d) 餵一份含未引號中文 key 的 `vaults.toml` → 第 4 項 `ok = false` 且訊息含檔案路徑 | (d) 就是 2026-08-22 那個 bug 的可觀測形式 |
| T10 | `cli-test`:`--json` 的 `data` 恰好五個鍵,全 snake_case;給人看的版本每行以 `[ok]` / `[!!]` / `[--]` 開頭,五行 | — |
| T11 | `cli-test`(或獨立 spec):在臨時目錄跑 `release.sh`(Windows 用 `release.ps1`),列舉產出目錄:恰好 3 個執行檔 + `registry/` 下 5 個 `.toml` + `README.md`;zip 存在 | 腳本測試要 skip 在沒有 `cabal` 的環境,並明說 skip |
| T12 | `/arch-audit subsys` 對兩個子系統不再回報 `locateVault` / `doctor` 未登記 | 文檔與程式碼對帳 |
| T13 | `cabal build all` + `cabal test all` + `git diff --stat cabal.project` 為空 | — |

## 實作備註

(實作時填寫:與設計的偏差、量化結果)
