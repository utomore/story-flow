---
id: P-004
description: 中樞 config.toml、型別註冊表、--vault 旗標與起點目錄經探測與裁決得到本次生效的讀 / 寫 / 管線 vault 集合
status: frozen
updated: 2026-09-06
---
# P-004-vault-scope:中樞 config.toml、型別註冊表、--vault 旗標與起點目錄經探測與裁決得到本次生效的讀 / 寫 / 管線 vault 集合

## Brief
一次執行的開場:把這台機器的狀態(中樞註冊表、型別註冊表)與這次指令的旗標(`--vault`、起點目錄)組成一份不可變的 `Session` 快照,再依操作類別裁決生效的 vault 集合。input 是中樞 `config.toml` 的文字、`types/registry/*.toml` 的文字、selector 字串、起點目錄;output 是 `Session`(中樞快照、註冊表、命名詞彙、註冊表來源、selector、cwd)與每次操作的 `Scope`。流向:定位中樞 → 讀 → 解析成 Hub(失敗即失敗,不退回空中樞)→ 三層定位註冊表 → 讀全部 TOML → 解析並驗證成 TypeRegistry 與 NamingVocab → 組成 Session;之後每個操作以 Session 加 `ScopeKind` 走 P-029-scope-resolve 的裁決。整條是 `HubFile` / `RegistryFs` / `Markers` 三個效果的程式,不碰索引;`Env` 的可變部分(handle 快取、鎖)是 shell 的事,`openEnv` 是進入點,`withRead` / `withWrite` / `withPipeline` 在 shell 裡用 Session 跑裁決再開 handle。它讓 O-1 的 M-3 往前一步,P-005 到 P-011 都從這裡開場。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `hubPath :: HubFile :> es => Eff es HubLocation` | AAPMS_HOME 或平台預設,記下來源 | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 2 | `readHub :: HubFile :> es => Eff es (Either WorkspaceError Text)` | 讀這個效果所綁的中樞檔全文;不存在回 `HubNotFound`,路徑是 `hubConfigPath` 算出的 config.toml | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 3 | `parseHubText :: FilePath -> Text -> Either WorkspaceError Hub` | TOML 文字解析成 Hub,格式錯即失敗 | `Aapms.Workspace.Hub`(願望,見 P-028-hub-config) | pure |
| 4 | `locateRegistryDir :: RegistryFs :> es => Eff es (Either RegistryError (FilePath, RegistrySource))` | 環境變數 → 執行檔旁 → cabal data-files,取第一個存在的 | `Aapms.Types.Effect.RegistryFs`(願望) | effects |
| 5 | `readRegistryFiles :: RegistryFs :> es => FilePath -> Eff es (Either RegistryError [(FilePath, Text)])` | 讀目錄下全部 TOML(含 naming.toml) | `Aapms.Types.Effect.RegistryFs`(願望) | effects |
| 6 | `parseRegistryFiles :: [(FilePath, Text)] -> Either RegistryError ([TypeDecl], NamingVocab)` | TOML 文字 → 宣告清單與命名詞彙,欄位不合規即失敗 | `Aapms.Types.Parse`(願望) | pure |
| 7 | `buildRegistry :: [TypeDecl] -> Either [RegistryError] TypeRegistry` | 宣告清單驗證成註冊表 | `Aapms.Core.Registry`(見 P-021-registry-build) | types |
| 8 | `resolveScope :: Markers :> es => Hub -> ScopeKind -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError Scope)` | 依操作類別裁決生效集合 | `Aapms.Workspace.Resolve`(願望,見 P-029-scope-resolve) | pure |
| 9 | `scopeOf :: Markers :> es => Session -> ScopeKind -> Eff es (Either ServiceError Scope)` | 用 Session 的快照跑 8,WorkspaceError 原樣包成 WorkspaceFailed | `Aapms.Service.Session`(願望) | pure |
| o | `simulateScope :: MarkerWorld -> Eff '[Markers] a -> a` | 觀察:P-029 的純解譯器跑到底 | `Aapms.Workspace.Resolve.Internal`(願望,見 P-029-scope-resolve) | pure |
| o | `runHubFilePure :: HubWorld -> Eff (HubFile : es) a -> Eff es (a, HubWorld)` | 觀察:HubFile 的純解譯器(固定位置、一份或沒有的中樞文字),回最終中樞世界 | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| o | `runRegistryFsPure :: RegistryWorld -> Eff (RegistryFs : es) a -> Eff es a` | 觀察:RegistryFs 的純解譯器(三層各自有沒有、目錄裡的檔) | `Aapms.Types.Effect.RegistryFs`(願望) | effects |
| o | `simulateSession :: HubWorld -> RegistryWorld -> Eff '[HubFile, RegistryFs] a -> a` | 觀察:兩個純解譯器跑到底 | `Aapms.Service.Session.Internal`(願望) | pure |
| o | `hubTextIn :: HubWorld -> Maybe Text` | 觀察:世界裡有沒有中樞文字 | `Aapms.Workspace.Types`(願望) | types |
| o | `hubLocationIn :: HubWorld -> HubLocation` | 觀察:世界裡的中樞位置 | `Aapms.Workspace.Types`(願望) | types |
| o | `hubConfigPath :: HubLocation -> FilePath` | 觀察:中樞位置底下的 config.toml 路徑(`hlPath </> "config.toml"`);純與真解譯器的 `HubNotFound` 都印它 | `Aapms.Workspace.Types`(願望) | types |
| o | `cacheDirIn :: HubWorld -> Bool` | 觀察:世界裡縮圖快取目錄存不存在;`ensureCacheDir` 的純語意(不在就建、回有沒有建) | `Aapms.Workspace.Types`(願望) | types |
| o | `thumbsIn :: HubWorld -> [FilePath]` | 觀察:世界裡快取目錄下的縮圖檔;`purgeHubFiles` 的純語意(刪中樞檔與全部縮圖,回 (中樞檔本來在不在, 縮圖張數)) | `Aapms.Workspace.Types`(願望) | types |
| o | `registryDirIn :: RegistryWorld -> Maybe (FilePath, RegistrySource)` | 觀察:三層裡第一個存在的 | `Aapms.Types.Source`(願望) | types |
| o | `registryFilesIn :: RegistryWorld -> [(FilePath, Text)]` | 觀察:那個目錄裡的 TOML | `Aapms.Types.Source`(願望) | types |
| o | `sessionHub :: Session -> Hub` | 觀察:快照裡的中樞 | `Aapms.Service.Types`(願望) | types |
| o | `sessionLocation :: Session -> HubLocation` | 觀察:中樞位置與來源 | `Aapms.Service.Types`(願望) | types |
| o | `sessionRegistry :: Session -> TypeRegistry` | 觀察:註冊表 | `Aapms.Service.Types`(願望) | types |
| o | `sessionNaming :: Session -> NamingVocab` | 觀察:命名詞彙 | `Aapms.Service.Types`(願望) | types |
| o | `sessionSource :: Session -> RegistrySource` | 觀察:註冊表來自哪一層 | `Aapms.Service.Types`(願望) | types |
| o | `sessionSelector :: Session -> Maybe Text` | 觀察:原樣捧著的 --vault | `Aapms.Service.Types`(願望) | types |
| o | `sessionCwd :: Session -> FilePath` | 觀察:起點目錄 | `Aapms.Service.Types`(願望) | types |
| o | `isRegistryUnavailable :: ServiceError -> Bool` | 觀察:是不是 RegistryUnavailable | `Aapms.Service.Types`(願望) | types |
| = | `openSession :: (HubFile :> es, RegistryFs :> es) => Maybe Text -> FilePath -> Eff es (Either ServiceError Session)` | 純的整條:1 → 2 → 3 → 4 → 5 → 6 → 7 → Session | `Aapms.Service.Session`(願望) | pure |
| ! | `openEnv :: Maybe Text -> FilePath -> IO (Either ServiceError Env)` | 進入點:跑真解譯器得到 Session,加上 handle 快取與全域鎖成 Env | `Aapms.Service.Monad` | shell |

## Laws
- LAW-1 [relation] 中樞載不起來即失敗,不退回空中樞
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath
  - given isNothing (hubTextIn hw)
  - |- simulateSession hw rw (openSession sel cwd) == Left (WorkspaceFailed (HubNotFound (hubConfigPath (hubLocationIn hw))))
- LAW-2 [relation] 中樞格式錯即失敗,錯誤原樣包成 WorkspaceFailed
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath, txt in maybe [] pure (hubTextIn hw), err in lefts [parseHubText (hlPath (hubLocationIn hw)) txt]
  - |- simulateSession hw rw (openSession sel cwd) == Left (WorkspaceFailed err)
- LAW-3 [relation] 註冊表三層都定位不到即失敗,是 RegistryUnavailable 不是 RegistryLoadFailed
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath, txt in maybe [] pure (hubTextIn hw)
  - given isRight (parseHubText (hlPath (hubLocationIn hw)) txt) and isNothing (registryDirIn rw)
  - |- either isRegistryUnavailable (const False) (simulateSession hw rw (openSession sel cwd))
- LAW-4 [relation] 註冊表目錄找到了但內容不合規即失敗,是 RegistryLoadFailed
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath, txt in maybe [] pure (hubTextIn hw), err in lefts [parseRegistryFiles (registryFilesIn rw)]
  - given isRight (parseHubText (hlPath (hubLocationIn hw)) txt) and isJust (registryDirIn rw)
  - |- simulateSession hw rw (openSession sel cwd) == Left (RegistryLoadFailed err)
- LAW-5 [relation] 成功時快照逐欄來自各步驟:中樞等於解析結果、註冊表等於建構結果、selector 與 cwd 原樣、來源等於定位結果
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath, s in rights [simulateSession hw rw (openSession sel cwd)], txt in maybe [] pure (hubTextIn hw), h in rights [parseHubText (hlPath (hubLocationIn hw)) txt], (decls, vocab) in rights [parseRegistryFiles (registryFilesIn rw)], reg in rights [buildRegistry decls], (dir, src) in maybe [] pure (registryDirIn rw)
  - |- sessionHub s == h and sessionLocation s == hubLocationIn hw and listTypes (sessionRegistry s) == listTypes reg and sessionNaming s == vocab and sessionSource s == src and sessionSelector s == sel and sessionCwd s == cwd
- LAW-6 [equiv] 每次操作的裁決就是 P-029 的裁決,WorkspaceError 原樣包成 WorkspaceFailed
  - forall w in MarkerWorld, s in Session, k in ScopeKind
  - |- simulateScope w (scopeOf s k) == either (Left . WorkspaceFailed) Right (simulateScope w (resolveScope (sessionHub s) k (sessionSelector s) (sessionCwd s)))
- LAW-7 [total] 開場對任何世界與輸入都有值
  - forall hw in HubWorld, rw in RegistryWorld, sel in Maybe Text, cwd in FilePath
  - |- total (simulateSession hw rw (openSession sel cwd))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 世界裡沒有中樞檔,位置 `%APPDATA%/aapms/config.toml` | `Left (WorkspaceFailed (HubNotFound "…/config.toml"))` | LAW-1 |
| EX-2 | 中樞文字是 `[[vaults]]\nid = 3`(id 不是字串) | `Left (WorkspaceFailed (HubMalformed path "…"))`,與 `parseHubText` 回的逐欄相同 | LAW-2 |
| EX-3 | 中樞正常,三層都沒有註冊表目錄 | `Left (RegistryUnavailable …)` | LAW-3 |
| EX-4 | 中樞正常,註冊表目錄在 `AAPMS_REGISTRY`,但 `character.toml` 缺 `family` | `Left (RegistryLoadFailed …)`,與 `parseRegistryFiles` 回的相同 | LAW-4 |
| EX-5 | 中樞兩個 vault、註冊表五份 TOML 完整,`sel = Just "a"`,`cwd = "T/x"` | `Right s`,`sessionHub s` 兩列、`listTypes (sessionRegistry s)` 五筆、`sessionSource s == FromEnv`、selector 與 cwd 原樣 | LAW-5 |
| EX-6 | 同 EX-5 的 Session,`scopeOf s ForRead` | 與 `resolveScope hub ForRead (Just "a") "T/x"` 相同的 ReadScope | LAW-6 |
| EX-7 | 同 EX-5 的 Session,`scopeOf s (ForPipeline AssetVault)`,a 是 story | `Left (WorkspaceFailed (VaultKindMismatch a AssetVault StoryVault))` | LAW-6 |
| EX-8 | 任意亂造的兩個世界與輸入 | 求值到底不拋例外 | LAW-7 |

## 決定
- **開場拆成純的 `Session` 快照與 shell 的 `Env`:Session 住 types,Env 只多 handle 快取與全域鎖。** 否決:把 IORef 與 MVar 留在同一個型別裡讓純程式帶著走。理由:快照是一次載入的不變量,可變狀態是 shell 的資源生命週期(原 service F001「Env 為什麼不透明」)
- **中樞載不起來、註冊表定位不到、註冊表不合規三者都是硬錯,不退回預設值。** 否決:空註冊表或空中樞繼續跑。理由:設定錯誤即失敗,空註冊表會把設定錯誤偽裝成資料錯誤(system.md 全域錯誤策略第 3 條)
- **`RegistryUnavailable` 與 `RegistryLoadFailed` 是兩個建構子。** 否決:合一。理由:code 要分得出「去裝 / 去設環境變數」與「型別宣告寫錯了」
- **開場不開任何索引;handle 在第一次 `withRead` / `withWrite` 才開,由 shell 快取。** 否決:開場就開全部 vault。理由:`vault list` 這種指令根本不需要索引(原 service F001 LAW-1)
- **selector 在這一層不解讀,原樣交給 P-029。** 否決:service 自己比對 id / name。理由:裁決點只有一個,在 workspace
- **註冊表與命名詞彙來自同一次載入,Session 一起帶。** 否決:拆開存。理由:拆開會允許兩者來自不同次載入
- **`ServiceM` 的一把全域鎖、`closeEnv` 冪等、`withEnv` 等於 open 加 close、handle 快取命中不再開檔,全是 shell 的資源紀律,由 shell 內部測試守,不掛 law。** 否決:寫成 law。理由:它們講的是 IORef 與 MVar,不是純的量
- **同一個 `ServiceM` 動作不得自己呼叫 `runService`(會死結)由 shell 內部測試以原始碼文字守。** 否決:執行期偵測。理由:契約沒有任何一條需要巢狀
- **解凍紀錄:2026-09-06 為 REV-1�REV-2�REV-3� 解凍,重委派全綠後重新凍結。**

## 修訂記錄
- REV-1(2026-09-06,依骨架回報「`runHubFilePure` 不回最終世界,但 P-005-vault-lifecycle 的 `simulateLifecycle` 要交出 `lcHubText` 與 `hubWorldAfter`」;rules/boundary.md「效果的判定」:law 拿純解譯器的結果寫,有寫入的效果其純解譯器必須交出最終狀態,與 `runVaultDirPure` 同形):`runHubFilePure` 改回 `Eff es (a, HubWorld)`
  - 動到:觀察點 `runHubFilePure` 的簽名
  - 保護:LAW-1 到 LAW-7
  - 重委派:無(尚未派 qa / impl;骨架簽名已同步)
- REV-2(2026-09-06,依 P-005-vault-lifecycle 的 qa 提問 GAP-1「`HubWorld` 只有 `hubTextIn` 與 `hubLocationIn`,純世界裡表達不出縮圖張數,`purgeHubFiles` 第二個分量在純解譯器裡沒有來源」,以及同一份回報「`spCacheCreated` 也沒有欄位可依」):`HubWorld` 加兩個欄位 `cacheDirIn :: Bool` 與 `thumbsIn :: [FilePath]`,`runHubFilePure` 對 `ensureCacheDir` / `purgeHubFiles` 的純語意由它們定義
  - 動到:觀察點 `cacheDirIn`、`thumbsIn`(新增);`HubWorld` 的形狀
  - 保護:LAW-1 到 LAW-7
  - 重委派:impl(`runHubFilePure` 兩個 op);qa(`HubWorld` 產生器跟著型別走)
- REV-3(2026-09-06,依 shell 波 impl 提問 GAP-1「`readHub` 的路徑參數在純解譯器裡只是 `HubNotFound` 的標籤,`openSession` 傳的是 `hlPath`(中樞根目錄),真實的檔是 `hlPath </> config.toml`,兩種讀法對不起來」):`readHub` 拿掉路徑參數——`HubFile` 效果綁的就是一個中樞,讀哪個檔由它的資源決定;`HubNotFound` 兩邊都印 `hubConfigPath`(新觀察點,types)
  - 動到:Stages 第 2 列、觀察點 `hubConfigPath`(新增)、LAW-1 的 `|-`
  - 保護:LAW-2 到 LAW-7
  - 重委派:impl(`HubFile` 效果的 op、兩個解譯器、`openSession` 的呼叫點);qa(LAW-1)
