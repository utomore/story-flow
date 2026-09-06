---
id: P-006
description: 中樞快照、marker 重讀、外部工具探測與 [llm] 有無組成 DoctorView;syncHub 才回寫漂移
status: ready
updated: 2026-09-06
---
# P-006-workspace-doctor:中樞快照、marker 重讀、外部工具探測與 [llm] 有無組成 DoctorView;syncHub 才回寫漂移

## Brief
回答「這台機器現在長什麼樣」:中樞在哪、註冊表從哪一層找到、每個 vault 認不認得到、起點目錄有沒有一個中樞不認識的 vault、7-Zip 在不在、有沒有設 `[llm]`。input 是 Session 快照(P-004)、每列 marker 的重讀、起點目錄的探測、`[tools]` 覆寫與 PATH;output 是 `DoctorView` 與它拆出來的 `VaultView` 清單、`ToolStatus`。流向:中樞每列重讀 marker 得到降級清單(P-029 的 refOfEntry)→ 投影成每列的 `VaultView`(可達 = 路徑在且 marker 讀得開;id 漂移仍算可達)→ 起點探測到未註冊的 vault 就多一筆 → 三層探測 7-Zip(覆寫 → PATH → 內建候選,找到就停,每一步記進 tsSearched)→ `[llm]` 只報告有沒有,內容不外洩。整條唯讀;`Markers` 與 `ToolProbe` 兩個效果的程式,純解譯器跑在記憶體的 marker 表與可執行檔表上。真解譯器住 shell,`workspaceDoctor` 是進入點;`vaultList` / `vaultCheck` / `workspaceTools` 是同一組投影的三個小門面。它是 S3 的第三條里程碑。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `refOfEntry :: Markers :> es => VaultEntry -> Eff es (Either ScopeIssue VaultRef)` | 中樞每列重讀 marker | `Aapms.Workspace.Resolve`(願望,見 P-029-scope-resolve) | pure |
| 2 | `detectRoot :: Markers :> es => FilePath -> Eff es (Maybe FilePath)` | 起點向上探測 | `Aapms.Workspace.Effect.Markers`(願望,見 P-029-scope-resolve) | effects |
| 3 | `refAt :: Markers :> es => Hub -> FilePath -> Eff es (Either WorkspaceError VaultRef)` | 探測到的目錄讀 marker 並以 id 回填 | `Aapms.Workspace.Resolve`(願望,見 P-029-scope-resolve) | pure |
| 4 | `registeredVaultView :: [ScopeIssue] -> VaultEntry -> VaultView` | 中樞一列投影:registered 恒真,reachable = 沒有 PathMissing / MarkerBroken 指到它 | `Aapms.Service.Machine.View`(願望) | pure |
| 5 | `discoveredVaultView :: VaultRef -> VaultView` | 探測到的未註冊 vault:欄位全來自 marker,registered 假、reachable 真 | `Aapms.Service.Machine.View`(願望) | pure |
| 6 | `probes :: ToolSearchPlan -> ToolsConfig -> [FilePath]` | 三層候選清單:覆寫、PATH 每個目錄的 7z 與 7zz、內建候選;跨層去重保序 | `Aapms.Workspace.Tools.Plan`(願望) | pure |
| 7 | `isExecutable :: ToolProbe :> es => FilePath -> Eff es Bool` | 存在且可執行(目錄不算),不存在不拋 | `Aapms.Workspace.Effect.ToolProbe`(願望) | effects |
| 8 | `pathDirs :: ToolProbe :> es => Eff es [FilePath]` | PATH 拆成目錄清單 | `Aapms.Workspace.Effect.ToolProbe`(願望) | effects |
| 9 | `detectTool :: ToolProbe :> es => ToolSearchPlan -> ToolsConfig -> Eff es ToolStatus` | 依 6 的順序逐一 7,第一個命中就停;tsSearched 是走過的前綴 | `Aapms.Workspace.Tools.Plan`(願望) | pure |
| 10 | `doctorOf :: Session -> [VaultView] -> [ScopeIssue] -> ToolStatus -> DoctorView` | 六欄投影:hub 路徑與來源、註冊表來源、vaults、issues、tools、llm 有無 | `Aapms.Service.Machine.View`(願望) | pure |
| o | `runToolProbePure :: ToolWorld -> Eff (ToolProbe : es) a -> Eff es a` | 觀察:ToolProbe 的純解譯器(可執行檔集合、PATH 目錄) | `Aapms.Workspace.Effect.ToolProbe`(願望) | effects |
| o | `simulateDoctor :: MarkerWorld -> ToolWorld -> Eff '[Markers, ToolProbe] a -> a` | 觀察:兩個純解譯器跑到底 | `Aapms.Service.Machine.Internal`(願望) | pure |
| o | `markerIssues :: MarkerWorld -> Hub -> [ScopeIssue]` | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單 | `Aapms.Service.Machine.Internal`(願望) | pure |
| o | `unreachableIds :: [ScopeIssue] -> [VaultId]` | 觀察:PathMissing 與 MarkerBroken 點到的列的 id(IdDrift 不算) | `Aapms.Workspace.Types`(願望) | types |
| o | `executables :: ToolWorld -> [FilePath]` | 觀察:世界裡可執行的路徑 | `Aapms.Workspace.Types`(願望) | types |
| o | `nearestRoot :: MarkerWorld -> FilePath -> Maybe FilePath` | 觀察:參考實作,起點往上第一層有 .aapms 的 | `Aapms.Workspace.Resolve.Internal`(願望,見 P-029-scope-resolve) | pure |
| o | `worldMarker :: MarkerWorld -> FilePath -> Maybe (Either StoreError VaultMarker)` | 觀察:某路徑的 marker 讀數 | `Aapms.Workspace.Types`(願望,見 P-029-scope-resolve) | types |
| o | `sessionHub :: Session -> Hub` | 觀察:快照裡的中樞 | `Aapms.Service.Types`(願望,見 P-004-vault-scope) | types |
| o | `sessionLocation :: Session -> HubLocation` | 觀察:中樞位置 | `Aapms.Service.Types`(願望,見 P-004-vault-scope) | types |
| o | `sessionSource :: Session -> RegistrySource` | 觀察:註冊表來源 | `Aapms.Service.Types`(願望,見 P-004-vault-scope) | types |
| o | `sessionCwd :: Session -> FilePath` | 觀察:起點 | `Aapms.Service.Types`(願望,見 P-004-vault-scope) | types |
| = | `doctor :: (Markers :> es, ToolProbe :> es) => Session -> ToolSearchPlan -> Eff es DoctorView` | 純的整條:對每列 1 → 4;2 → 3 → 5;8 → 6 → 9;10(vaultViewOf 與 unregisteredView 兩個私有函數改名匯出) | `Aapms.Service.Machine.View`(願望) | pure |
| ! | `workspaceDoctor :: ServiceM DoctorView` | 進入點:以 Env 的快照、真檔案系統與 PATH 跑真解譯器 | `Aapms.Service.Machine` | shell |

## Laws
- LAW-1 [relation] 六欄的來源:hub 路徑與來源等於快照、註冊表來源等於快照、issues 等於逐列重讀、llm 有無等於 hubLlm 是不是 Just、tools 恰一筆
  - forall w in MarkerWorld, tw in ToolWorld, s in Session, plan in ToolSearchPlan, dv in [simulateDoctor w tw (doctor s plan)]
  - |- dvHubPath dv == hlPath (sessionLocation s) and dvHubSource dv == hlSource (sessionLocation s) and dvRegistry dv == sessionSource s and dvScopeIssues dv == markerIssues w (sessionHub s) and dvLlmConfigured dv == isJust (hubLlm (sessionHub s)) and length (dvTools dv) == 1
- LAW-2 [relation] 前 n 筆 vault 逐列對應中樞:registered 恒真,reachable 當且僅當沒有 PathMissing / MarkerBroken 點到它(id 漂移仍可達)
  - forall w in MarkerWorld, tw in ToolWorld, s in Session, plan in ToolSearchPlan, dv in [simulateDoctor w tw (doctor s plan)], n in [length (hubVaults (sessionHub s))], (v, e) in zip (take n (dvVaults dv)) (hubVaults (sessionHub s))
  - |- vvId v == veId e and vvName v == veName e and vvKind v == veKind e and vvPath v == vePath e and vvRegistered v and (vvReachable v == notElem (veId e) (unreachableIds (dvScopeIssues dv)))
- LAW-3 [relation] 未註冊那一筆:起點探測命中一個中樞沒有的 vault 時恰多一筆(registered 假、欄位來自 marker、reachable 真),否則沒有
  - forall w in MarkerWorld, tw in ToolWorld, s in Session, plan in ToolSearchPlan, dv in [simulateDoctor w tw (doctor s plan)], n in [length (hubVaults (sessionHub s))], extra in [drop n (dvVaults dv)]
  - |- length extra <= 1 and all (not . vvRegistered) extra and all vvReachable extra and ((length extra == 1) == maybe False (either (const False) (flip notElem (map veId (hubVaults (sessionHub s))) . vmId)) (maybe Nothing (worldMarker w) (nearestRoot w (sessionCwd s))))
- LAW-4 [invariant] 診斷不外洩 [llm] 內容:DoctorView 只有一個 Bool,沒有任何欄位裝得下鍵值
  - forall w in MarkerWorld, tw in ToolWorld, s in Session, plan in ToolSearchPlan, dv in [simulateDoctor w tw (doctor s plan)]
  - |- dvLlmConfigured dv == isJust (hubLlm (sessionHub s))
- LAW-5 [relation] 工具探測:tsSearched 是候選清單的前綴,命中的在最後且是第一個可執行的;三層都不合格時走完整清單、tsPath 為 Nothing、tsOrigin 為 NotFound
  - forall tw in ToolWorld, plan in ToolSearchPlan, cfg in ToolsConfig, ts in [simulateDoctor mempty tw (detectTool plan cfg)], ps in [probes plan cfg]
  - |- isPrefixOf (tsSearched ts) ps and (tsPath ts == find (flip elem (executables tw)) ps) and (isNothing (tsPath ts) == (tsOrigin ts == NotFound)) and (isNothing (tsPath ts) => tsSearched ts == ps) and maybe True (== last (tsSearched ts)) (tsPath ts)
- LAW-6 [relation] 覆寫合格時後兩層完全不參與:結果與 plan 無關
  - forall tw in ToolWorld, plan in ToolSearchPlan, plan2 in ToolSearchPlan, p in FilePath
  - given elem p (executables tw)
  - |- simulateDoctor mempty tw (detectTool plan (ToolsConfig (Just p))) == ToolStatus "7-Zip" (Just p) FromToolsConfig [p] and simulateDoctor mempty tw (detectTool plan2 (ToolsConfig (Just p))) == ToolStatus "7-Zip" (Just p) FromToolsConfig [p]
- LAW-7 [invariant] 候選清單依序、跨層去重、逐字不正規化;第二層是名稱外層目錄內層(7z 全部再 7zz 全部)
  - forall plan in ToolSearchPlan, cfg in ToolsConfig
  - |- nub (probes plan cfg) == probes plan cfg and isPrefixOf (maybe [] pure (tcSevenZip cfg)) (probes plan cfg)
- LAW-8 [invariant] 診斷唯讀:世界不變(純解譯器裡世界不可變,真解譯器由 shell 內部測試守)且對任何輸入都有值
  - forall w in MarkerWorld, tw in ToolWorld, s in Session, plan in ToolSearchPlan
  - |- total (simulateDoctor w tw (doctor s plan))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 中樞 VA(story)、VB(asset)都讀得到;起點在外面 | `dvVaults` 兩筆,registered 與 reachable 皆真;`dvScopeIssues == []`;`dvLlmConfigured == False` | LAW-1、LAW-2 |
| EX-2 | 多一列 VC 指向不存在的路徑 | VC 那筆 `vvReachable == False`,其餘真;`dvScopeIssues` 恰一則 `VaultPathMissing` | LAW-2 |
| EX-3 | VA 的 marker id 改成別的值 | `dvScopeIssues` 恰一則 `VaultIdDrift`;VA 那筆 `vvReachable` 仍為 True | LAW-2 |
| EX-4 | 從中樞刪掉 VA 那列,起點在 VA 底下 | `dvVaults` 第二筆 `vvRegistered == False`、`vvId == VA`、reachable 真;起點在外面時沒有這一筆 | LAW-3 |
| EX-5 | 中樞有 `[llm]`,`api_key = "SENTINEL"` | `dvLlmConfigured == True`,DoctorView 沒有任何欄位含該字串 | LAW-4 |
| EX-6 | `[tools]` 未設,PATH 兩個目錄,內建候選兩個,世界裡只有內建第二個可執行 | `tsSearched` 是完整候選清單的前綴到它為止,`tsOrigin == FromCandidate`;全部不可執行時 `tsPath == Nothing`、`tsOrigin == NotFound`、`tsSearched` 等於整份清單 | LAW-5 |
| EX-7 | `[tools] seven_zip = "C:/x/7z.exe"` 可執行,兩份不同的 plan | 兩次都是 `ToolStatus "7-Zip" (Just "C:/x/7z.exe") FromToolsConfig ["C:/x/7z.exe"]` | LAW-6 |
| EX-8 | PATH 目錄 d1、d2,同一個路徑也出現在內建候選 | `probes` 第二段依序 `d1/7z.exe, d2/7z.exe, d1/7zz.exe, d2/7zz.exe`,重複的只在第一次出現 | LAW-7 |
| EX-9 | 亂造的世界與快照 | 不拋例外 | LAW-8 |

## 決定
- **doctor 是 `Markers` 與 `ToolProbe` 兩個效果的程式,投影全在純函數;`vaultList` / `vaultCheck` / `workspaceTools` 是同一組投影的小門面,不各開 pipeline。** 否決:三條 pipeline。理由:它們只是 DoctorView 的三個欄位。證據:ADR-023-effectful-effects-layer
- **doctor 住 service 而不是 workspace:它組合的全部來自 workspace 與 graph-core,不 import 任何領域子系統。** 否決:放 workspace。理由:「彙總這台機器的狀態」在現行拓撲下只有 service 能放(system.md 2026-08-29 補充)
- **id 漂移不算不可達:reachable 只看路徑在不在、marker 讀不讀得開。** 否決:漂移也算不可達。理由:漂移是身分問題,由 syncHub 修;路徑在、檔案在,人看得到它
- **`[llm]` 只報告有沒有,鍵與值一律不進診斷輸出。** 否決:列出端點。理由:api_key 會跟著出來;鍵與語意屬 ai 子系統
- **7-Zip 三層探測:覆寫合格就停,不合格不中止往下;合格 = 存在且可執行,目錄不算;PATH 名稱只有 7z 與 7zz,不展開 PATHEXT。** 否決:找到全部再挑。理由:tsSearched 要能告訴使用者「我看過哪裡」,找到就停最好讀
- **sidecar 缺席不是錯誤:`NotFound` 是正常結果,沒有失敗通道。** 否決:回 Left。理由:sidecar 只影響預覽與縮圖,不影響索引(system.md)
- **診斷唯讀:不建 .aapms、不開 index.db、不修補 marker、不寫中樞;漂移要 syncHub(P-005)才回寫。** 否決:doctor 順手修。理由:讀與寫分開,人先看報告再決定
- **`vaultInfo` 的節點計數與索引問題屬 P-007-graph-read(要開索引),不在本條。** 否決:併進 doctor。理由:doctor 不開索引

## 修訂記錄
無
