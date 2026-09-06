---
id: P-009
description: argv 經 optparse 解析、Backend 分派(內嵌 / 遠端)、統一信封或人類可讀渲染,回 stdout 與 exit code 0 / 1 / 2
status: ready
updated: 2026-09-06
---
# P-009-cli-shell:argv 經 optparse 解析、Backend 分派(內嵌 / 遠端)、統一信封或人類可讀渲染,回 stdout 與 exit code 0 / 1 / 2

## Brief
`aapms` 執行檔的殼:零業務邏輯,只做「參數 → 請求 → 結果 → 輸出」。input 是 argv;output 是 stdout 的文字(`--json` 時恰好一行 JSON 信封,否則第一行是作用中的 vault 再接人類可讀渲染)與 exit code。流向:解析 argv 成 `Command`(全域旗標、名詞動詞、參數;`--vault` 與 `--remote` 互斥、用法錯誤 exit 2)→ 把 Command 翻成一個統一的 `Op`(P-007 的 ReadOp、P-008 的 GraphOp、P-005 的 LifecycleOp、P-006 的 doctor、P-001 的重建)→ `Backend` 分派:內嵌走 ServiceM,遠端走 servant-client 打同一份 API(重管線指令在遠端下拒絕,exit 2)→ 結果或錯誤(`code` 與訊息一律來自 service 的 `errorCode` / `renderServiceError`)→ 信封或渲染 → exit code(0 成功、1 業務或傳輸失敗、2 用法)。解析、翻譯、信封、渲染、exit code 判定全是純函數;`Backend` 的 `runOp` 是 shell。它是 S3 的第六條里程碑,對應原 shell F002 / F003 / F004;`aapms-mcp` 共用同一個 Backend(P-011)。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `parseArgs :: [String] -> Either UsageError Command` | optparse 的指令樹:全域旗標與名詞動詞;`--vault` 與 `--remote` 同時給是用法錯誤 | `Aapms.Cli.Options`(願望) | pure |
| 2 | `commandOp :: Command -> Either UsageError Op` | Command 翻成統一請求;缺 expected revision 之類是用法錯誤 | `Aapms.Cli.Options`(願望) | pure |
| 3 | `isPipelineOp :: Op -> Bool` | 重管線指令(asset scan / thumbs / cluster apply / pack reorganize)判定 | `Aapms.Backend.Op`(願望) | types |
| 4 | `dispatchMode :: GlobalFlags -> Op -> Either BackendError BackendMode` | 遠端模式下的重管線指令 → PipelineNotRemote;否則 Embedded 或 Remote url | `Aapms.Backend`(願望) | pure |
| 5 | `errorBodyOf :: ServiceError -> ErrorBody` | code 與訊息一律來自 service | `Aapms.Backend.Op`(願望) | types |
| 6 | `envelope :: Either ErrorBody Value -> Text` | 恰好一行 JSON:成功 `{"ok":true,"data":…}`,失敗 `{"ok":false,"error":{"code":…,"message":…}}`,兩者不共存,data 恒存在 | `Aapms.Cli.Envelope`(願望) | pure |
| 7 | `exitKindOf :: Either BackendError a -> ExitKind` | 0 / 1 / 2 的判定:用法與 PipelineNotRemote 是 2,業務與傳輸是 1 | `Aapms.Cli.Envelope`(願望) | pure |
| 8 | `exitCodeOf :: ExitKind -> Int` | ExitOk 0、ExitFailure 1、ExitUsage 2 | `Aapms.Cli.Envelope`(願望) | types |
| 9 | `activeVaultLine :: Op -> Scope -> Text` | 非 JSON 模式的第一行:寫入類印目標,查詢類印涵蓋的 vault 數與名稱 | `Aapms.Cli.Render`(願望) | pure |
| 10 | `renderResult :: OpResult -> Text` | 唯一的人類可讀渲染器:節點、清單、樹、搜尋結果、警告、ScopeIssue | `Aapms.Cli.Render`(願望) | pure |
| 11 | `renderError :: ErrorBody -> Text` | 錯誤的人類可讀輸出:訊息原樣,附 code | `Aapms.Cli.Render`(願望) | pure |
| 12 | `runOp :: Backend -> Op -> IO (Either BackendError OpResult)` | 分派:Embedded 進 ServiceM,Remote 以 servant-client 打 HTTP | `Aapms.Backend`(願望) | shell |
| o | `flagsOf :: Command -> GlobalFlags` | 觀察:全域旗標 | `Aapms.Cli.Types`(願望) | types |
| o | `gfVault :: GlobalFlags -> Maybe Text` | 觀察:--vault | `Aapms.Cli.Types`(願望) | types |
| o | `gfRemote :: GlobalFlags -> Maybe Text` | 觀察:--remote | `Aapms.Cli.Types`(願望) | types |
| o | `gfJson :: GlobalFlags -> Bool` | 觀察:--json | `Aapms.Cli.Types`(願望) | types |
| o | `isUsageError :: BackendError -> Bool` | 觀察:用法類錯誤(含 PipelineNotRemote) | `Aapms.Backend.Op`(願望) | types |
| o | `isTransportError :: BackendError -> Bool` | 觀察:傳輸錯誤 | `Aapms.Backend.Op`(願望) | types |
| o | `decodeEnvelope :: Text -> Maybe (Either ErrorBody Value)` | 觀察:信封解回來 | `Aapms.Cli.Envelope`(願望) | pure |
| o | `isOneLine :: Text -> Bool` | 觀察:沒有換行字元 | `Aapms.Cli.Envelope`(願望) | pure |
| o | `backendErrorBody :: BackendError -> ErrorBody` | 觀察:後端錯誤的 code 與訊息(用法錯誤是 usage_error) | `Aapms.Backend.Op`(願望) | types |
| o | `resultJson :: OpResult -> Value` | 觀察:結果的 JSON | `Aapms.Backend.Op`(願望) | types |
| o | `ebCode :: ErrorBody -> Text` | 觀察:code | `Aapms.Backend.Op`(願望) | types |
| o | `ebMessage :: ErrorBody -> Text` | 觀察:訊息 | `Aapms.Backend.Op`(願望) | types |
| o | `argsOf :: Command -> [String]` | 觀察:把 Command 印回 argv(往返用) | `Aapms.Cli.Options`(願望) | pure |
| = | `cliRun :: [String] -> Either BackendError OpResult -> (Text, Int)` | 純的整條:給定 argv 與後端結果,算出要印的文字與 exit code(1 → 2 → 6 / 9 / 10 / 11 → 7 → 8) | `Aapms.Cli.Main`(願望) | pure |
| ! | `cliMain :: IO ()` | 進入點:設輸出編碼、1 → 2 → 4 → 12 → cliRun → 印出並以 exit code 結束 | `Aapms.Cli.Main`(願望) | shell |

## Laws
- LAW-1 [roundtrip] 解析得開的 argv,印回去再解析得到同一個 Command
  - forall args in [String], c in rights [parseArgs args]
  - |- parseArgs (argsOf c) == Right c
- LAW-2 [relation] --vault 與 --remote 同時給是用法錯誤;用法錯誤的 exit code 恒為 2
  - forall args in [String]
  - given elem "--vault" args and elem "--remote" args
  - |- isLeft (parseArgs args) and snd (cliRun args (Right undefined)) == 2
- LAW-3 [relation] 遠端模式下的重管線指令被 dispatchMode 拒絕,是用法類錯誤
  - forall gf in GlobalFlags, op in Op, url in Text
  - given gfRemote gf == Just url and isPipelineOp op
  - |- either isUsageError (const False) (dispatchMode gf op)
- LAW-4 [roundtrip] 信封恰好一行 JSON,解得回原值;成功與失敗的鍵不共存
  - forall r in Either ErrorBody Value
  - |- decodeEnvelope (envelope r) == Just r and isOneLine (envelope r)
- LAW-5 [relation] 失敗信封的 code 與訊息逐字等於 service 的 errorCode 與 renderServiceError
  - forall e in ServiceError
  - |- ebCode (errorBodyOf e) == errorCode e and ebMessage (errorBodyOf e) == renderServiceError e
- LAW-6 [relation] exit code 三分:成功 0、業務或傳輸失敗 1、用法 2,兩者不互換
  - forall r in Either BackendError OpResult
  - |- (isRight r => exitCodeOf (exitKindOf r) == 0) and (either isUsageError (const False) r => exitCodeOf (exitKindOf r) == 2) and (either (not . isUsageError) (const False) r => exitCodeOf (exitKindOf r) == 1)
- LAW-7 [relation] --json 模式下輸出恰好是信封那一行,沒有作用中 vault 的提示行
  - forall args in [String], c in rights [parseArgs args], r in Either BackendError OpResult
  - given gfJson (flagsOf c)
  - |- fst (cliRun args r) == envelope (either (Left . backendErrorBody) (Right . resultJson) r)
- LAW-8 [relation] 非 JSON 模式的成功輸出以作用中 vault 那一行開頭
  - forall args in [String], c in rights [parseArgs args], res in OpResult, sc in Scope
  - given not (gfJson (flagsOf c))
  - |- isPrefixOf (activeVaultLine (either (const undefined) id (commandOp c)) sc) (fst (cliRun args (Right res)))
- LAW-9 [total] 任何 argv 都有值,不拋例外
  - forall args in [String]
  - |- total (parseArgs args)

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `["--vault","a","--remote","http://x"]` | 用法錯誤,exit 2 | LAW-2 |
| EX-2 | `["entity","new","--type","character","--title","琳達"]` | 解析成 Command,`argsOf` 再解析相同 | LAW-1 |
| EX-3 | `--remote http://x asset scan` | `PipelineNotRemote "asset scan"`,exit 2 | LAW-3、LAW-6 |
| EX-4 | `envelope (Right (Array []))`;`envelope (Left (ErrorBody "unknown_type" "…"))` | `{"ok":true,"data":[]}`;`{"ok":false,"error":{"code":"unknown_type","message":"…"}}`,各一行,解得回來 | LAW-4 |
| EX-5 | `errorBodyOf (UnknownType "ghost")` | code `unknown_type`,訊息含「type list」 | LAW-5 |
| EX-6 | 傳輸失敗 `TransportError "connection refused"` | exit 1,不是 2 | LAW-6 |
| EX-7 | `--json vault list` 成功 | 輸出只有一行,`{"ok":true,"data":[…]}` | LAW-7 |
| EX-8 | `vault list`(非 JSON)涵蓋兩個 vault | 第一行 `vaults: 2 (assets, story)` 之類的提示 | LAW-8 |
| EX-9 | 亂造的 argv | 不拋例外 | LAW-9 |
| EX-10 | `entity update ent-1 --title x`(缺 `--revision`) | 用法錯誤,exit 2 | LAW-2 |

## 決定
- **`Op` 是三個殼共用的統一請求型別(ReadOp / GraphOp / LifecycleOp / doctor / 重建),分派落在操作層,指令層看不見 Embedded / Remote。** 否決:每個指令自己 case 兩個建構子。理由:兩種模式輸出相同是結構上成立的,不靠對照測試(原 shell 契約 E)
- **`Backend` 與 `Op` 住新套件 `aapms-backend`,不住 `aapms-api` 也不住 `aapms-cli`。** 否決:住 cli 讓 mcp 依賴 cli。理由:Backend 需要 servant-client 與 service,api 只能有型別;mcp 依賴 cli 會拖進 optparse(原 system.md 2026-08-29)
- **exit 2 只由本層產生(用法錯誤、旗標互斥、遠端下的重管線);1 一律源自 service 或傳輸。** 否決:傳輸失敗算 2。理由:AI Agent 用 exit code 決定「改寫指令」還是「重試」
- **`--json` 時不得輸出任何非 JSON 的行,包含作用中 vault 提示。** 否決:提示印到 stderr。理由:一行就是契約,不留解析歧義
- **批次與管線類動作預設只預覽、`--confirm` 才寫入;單筆 CRUD 不走這條。** 否決:所有會改狀態的動作都要 confirm。理由:單筆已由必填的 expected revision 擋著(原 system.md 2026-08-29 校正);「預覽還是寫入」由該操作自己收模式參數,不是殼的分支
- **`code` 與訊息只有一個來源:service 的 errorCode / renderServiceError;殼只新增 `usage_error` 一種。** 否決:殼改寫訊息。理由:三個殼一組訊息
- **輸出編碼由 shell 的 main 設(hSetEncoding utf8 加 Windows console code page),不進 law。** 否決:寫成 law。理由:那是平台副作用(原 service-and-interfaces B002)
- **非 JSON 模式的第一行是作用中的 vault。** 否決:不印。理由:ADR-008 / ADR-017 的誤操作緩解

## 修訂記錄
無
