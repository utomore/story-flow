---
id: P-005
description: init / add / forget 請求經前置檢查、marker 建立、撞號比對、AdoptNotice 得到寫回中樞的新 Hub 與 VaultEntry
status: ready
updated: 2026-09-06
---
# P-005-vault-lifecycle:init / add / forget 請求經前置檢查、marker 建立、撞號比對、AdoptNotice 得到寫回中樞的新 Hub 與 VaultEntry

## Brief
工具自己的狀態怎麼建立、納管、撤除:中樞的建立、vault 的 init(含 `--adopt`)/ add / forget、專案的 register / forget、中樞與 marker 的漂移修正、purge。input 是一個 `LifecycleOp` 請求加上目前的中樞快照;output 是 `LifecycleOutcome`(新的 Hub 值、被加入或移除的那一列、AdoptNotice、報告)。流向:名稱與目錄的前置檢查(順序固定,任一失敗零副作用)→ 建 marker 與空索引(graph-core 的 `initVaultAtWith`)→ 與中樞既有列比對撞號(撞了回滾 marker)→ AdoptExisting 時列出舊系統的 marker 目錄(只報告不刪)→ Hub 值上加或減一列(P-028)→ 原子寫回 `config.toml`。中樞檔、vault 目錄、marker、時鐘是四個效果(`HubFile`、`VaultDir`、`Markers`、`Clock`),純解譯器跑在記憶體的中樞文字與目錄樹上;真解譯器住 shell,`runLifecycle` 是唯一進入點,原本的 `setupHub` / `initVault` / `initVaultWith` / `addVault` / `forgetVault` / `purge` / `checkVaults` / `syncHub` / `registerProject` / `forgetProject` 退場,呼叫端(service 門面與測試)改接 `runLifecycle`。它是 S3 的第二條里程碑;service 的 `vaultInit` 等門面(P-006)只做投影。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `hubPath :: HubFile :> es => Eff es HubLocation` | 中樞在哪 | `Aapms.Workspace.Effect.HubFile`(願望,見 P-004-vault-scope) | effects |
| 2 | `hubExists :: HubFile :> es => Eff es Bool` | config.toml 存不存在(setup 不解析既有檔) | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 3 | `writeHub :: HubFile :> es => Text -> Eff es (Either WorkspaceError ())` | 原子寫回 config.toml | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 4 | `ensureCacheDir :: HubFile :> es => Eff es (Either WorkspaceError Bool)` | 建 cache/thumbs,回有沒有真的建;建不出來回 `HubWriteFailed`(真解譯器),純解譯器恆 `Right` | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 5 | `purgeHubFiles :: HubFile :> es => Eff es (Bool, Int)` | 刪 config.toml 與縮圖快取,回刪了沒、刪幾張 | `Aapms.Workspace.Effect.HubFile`(願望) | effects |
| 6 | `canonicalPath :: Markers :> es => FilePath -> Eff es FilePath` | 正規化目錄 | `Aapms.Workspace.Effect.Markers`(願望,見 P-029-scope-resolve) | effects |
| 7 | `dirExists :: Markers :> es => FilePath -> Eff es Bool` | 目錄存不存在 | `Aapms.Workspace.Effect.Markers`(願望,見 P-029-scope-resolve) | effects |
| 8 | `readMarkerAt :: Markers :> es => FilePath -> Eff es (Either StoreError VaultMarker)` | 讀 marker 取權威身分 | `Aapms.Workspace.Effect.Markers`(願望,見 P-029-scope-resolve) | effects |
| 9 | `listEntries :: VaultDir :> es => FilePath -> Eff es [FilePath]` | 目錄第一層的名字(空目錄判定、舊 marker 探測都只看這一層) | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| 10 | `markerDirExists :: VaultDir :> es => FilePath -> Eff es Bool` | `.aapms` 這個路徑存不存在(目錄或檔案都算佔用) | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| 11 | `initMarker :: VaultDir :> es => FilePath -> VaultKind -> Text -> UTCTime -> Eff es (Either StoreError VaultMarker)` | 建 `.aapms/config.toml` 與空索引(graph-core 的 initVaultAtWith) | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| 12 | `removeMarkerDir :: VaultDir :> es => FilePath -> Eff es ()` | 撞號回滾:刪掉剛建的 `.aapms/` | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| 13 | `removeIndexDb :: VaultDir :> es => FilePath -> Eff es Bool` | 刪 index.db,本來就沒有回 False 不算失敗 | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| 14 | `now :: Clock :> es => Eff es UTCTime` | 配號的時間 | `Aapms.Store.Effect.Clock`(願望,見 P-003-node-write) | effects |
| 15 | `checkInit :: Text -> InitMode -> FilePath -> Bool -> Bool -> [FilePath] -> Either WorkspaceError Text` | 前置檢查依序:名稱去空白非空 → `.aapms` 未被佔用 → Fresh 要空、Adopt 要存在;通過回去空白後的名稱 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 16 | `legacyMarkers :: FilePath -> [FilePath] -> [FilePath]` | 目錄第一層裡的 `.assetdb` / `.storyflow`,固定順序,不遞迴 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 17 | `collisionOf :: Hub -> VaultMarker -> FilePath -> Maybe WorkspaceError` | 新 marker 的 id 撞到中樞既有列(路徑不同)就是 VaultIdCollision 三個值 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 18 | `entryOf :: VaultMarker -> FilePath -> VaultEntry` | marker 投影成中樞的一列 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 19 | `upsertVault :: VaultEntry -> Hub -> Hub` | 以 id 為鍵加或換一列,保序 | `Aapms.Workspace.Hub`(見 P-028-hub-config) | pure |
| 20 | `removeVault :: VaultId -> Hub -> Hub` | 以 id 刪一列 | `Aapms.Workspace.Hub`(見 P-028-hub-config) | pure |
| 21 | `upsertProject :: ProjectEntry -> Hub -> Hub` | 專案列加或換 | `Aapms.Workspace.Hub`(見 P-028-hub-config) | pure |
| 22 | `removeProject :: Id -> Hub -> Hub` | 專案列刪 | `Aapms.Workspace.Hub`(見 P-028-hub-config) | pure |
| 23 | `renderHub :: Hub -> Text` | Hub 值渲染回 TOML,保留註解與空行 | `Aapms.Workspace.Hub`(願望,見 P-028-hub-config) | pure |
| 24 | `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | forget 的 selector 規則 | `Aapms.Workspace.Resolve`(願望,見 P-029-scope-resolve) | pure |
| 25 | `lookupProject :: Hub -> Text -> Either WorkspaceError ProjectEntry` | 專案 selector:先 id 再 name,逐字,撞名 Ambiguous | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 26 | `allocateProjectId :: [ProjectEntry] -> Text -> UTCTime -> Id` | prj- 短 id,撞既有就 salt 遞增,純函數 | `Aapms.Workspace.Lifecycle.Plan`(願望,自 Aapms.Workspace.Projects 搬出) | pure |
| 27 | `refOfEntry :: Markers :> es => VaultEntry -> Eff es (Either ScopeIssue VaultRef)` | checkVaults / syncHub 對每列重讀 marker | `Aapms.Workspace.Resolve`(願望,見 P-029-scope-resolve) | pure |
| 28 | `syncEntry :: VaultEntry -> VaultMarker -> VaultEntry` | 只以 marker 修 name 與 kind,id 與 path 不動 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| 29 | `parseHubText :: FilePath -> Text -> Either WorkspaceError Hub` | 寫回後讀得回來的對照 | `Aapms.Workspace.Hub`(願望,見 P-028-hub-config) | pure |
| o | `runVaultDirPure :: VaultWorld -> Eff (VaultDir : es) a -> Eff es (a, VaultWorld)` | 觀察:VaultDir 的純解譯器,回最終目錄樹 | `Aapms.Workspace.Effect.VaultDir`(願望) | effects |
| o | `simulateLifecycle :: UTCTime -> HubWorld -> VaultWorld -> Hub -> Eff '[HubFile, VaultDir, Markers, Clock] a -> LifecycleRun a` | 觀察:四個純解譯器跑到底,回結果、最終中樞文字、最終目錄樹 | `Aapms.Workspace.Lifecycle.Internal`(願望) | pure |
| o | `lcResult :: LifecycleRun a -> a` | 觀察:結果 | `Aapms.Workspace.Types`(願望) | types |
| o | `lcHubText :: LifecycleRun a -> Maybe Text` | 觀察:最終中樞文字(沒有檔就 Nothing) | `Aapms.Workspace.Types`(願望) | types |
| o | `lcVaults :: LifecycleRun a -> VaultWorld` | 觀察:最終目錄樹 | `Aapms.Workspace.Types`(願望) | types |
| o | `hubWorldAfter :: LifecycleRun a -> HubWorld` | 觀察:跑完之後的中樞世界(拿來接著跑下一個請求) | `Aapms.Workspace.Types`(願望) | types |
| o | `hubTextIn :: HubWorld -> Maybe Text` | 觀察:起始中樞文字 | `Aapms.Workspace.Types`(願望,見 P-004-vault-scope) | types |
| o | `hubLocationIn :: HubWorld -> HubLocation` | 觀察:中樞位置 | `Aapms.Workspace.Types`(願望,見 P-004-vault-scope) | types |
| o | `cacheDirIn :: HubWorld -> Bool` | 觀察:快取目錄存不存在 | `Aapms.Workspace.Types`(願望,見 P-004-vault-scope) | types |
| o | `thumbsIn :: HubWorld -> [FilePath]` | 觀察:快取目錄下的縮圖檔 | `Aapms.Workspace.Types`(願望,見 P-004-vault-scope) | types |
| o | `vwEntries :: VaultWorld -> FilePath -> [FilePath]` | 觀察:目錄第一層 | `Aapms.Workspace.Types`(願望) | types |
| o | `vwMarkerDir :: VaultWorld -> FilePath -> Bool` | 觀察:`.aapms` 路徑被佔用 | `Aapms.Workspace.Types`(願望) | types |
| o | `vwMarker :: VaultWorld -> FilePath -> Maybe (Either StoreError VaultMarker)` | 觀察:marker 讀數 | `Aapms.Workspace.Types`(願望) | types |
| o | `driftAt :: VaultWorld -> VaultEntry -> Maybe VaultId` | 觀察:這一列的路徑上 marker 讀得到且 id 與中樞記的不同時,回實際住在那裡的 id;讀不到或相符回 Nothing(刪 index.db 前的守門) | `Aapms.Workspace.Types`(願望) | types |
| o | `vwHasIndex :: VaultWorld -> FilePath -> Bool` | 觀察:index.db 在不在 | `Aapms.Workspace.Types`(願望) | types |
| o | `vwDirExists :: VaultWorld -> FilePath -> Bool` | 觀察:目錄在不在 | `Aapms.Workspace.Types`(願望) | types |
| o | `vwWithout :: [FilePath] -> VaultWorld -> VaultWorld` | 觀察:拿掉這些路徑後的目錄樹(比較「其餘不動」用) | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeHub :: LifecycleOutcome -> Maybe Hub` | 觀察:結果裡的新 Hub 值 | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeEntry :: LifecycleOutcome -> Maybe VaultEntry` | 觀察:被加入或移除的 vault 列 | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeNotice :: LifecycleOutcome -> Maybe AdoptNotice` | 觀察:AdoptNotice | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeProject :: LifecycleOutcome -> Maybe ProjectEntry` | 觀察:被加入或移除的專案列 | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeIssues :: LifecycleOutcome -> [ScopeIssue]` | 觀察:syncHub 的漂移紀錄 | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomeSetup :: LifecycleOutcome -> Maybe SetupReport` | 觀察:setup 報告 | `Aapms.Workspace.Types`(願望) | types |
| o | `outcomePurge :: LifecycleOutcome -> Maybe PurgeReport` | 觀察:purge 報告 | `Aapms.Workspace.Types`(願望) | types |
| o | `isRefNotRegistered :: ScopeIssue -> Bool` | 觀察:是不是 RefVaultNotRegistered | `Aapms.Workspace.Types`(願望,見 P-029-scope-resolve) | types |
| o | `checkVaultsOf :: VaultWorld -> Hub -> [ScopeIssue]` | 觀察:參考實作,中樞順序逐列重讀 marker 的降級清單 | `Aapms.Workspace.Lifecycle.Internal`(願望) | pure |
| = | `applyLifecycle :: (HubFile :> es, VaultDir :> es, Markers :> es, Clock :> es) => Hub -> LifecycleOp -> Eff es (Either WorkspaceError LifecycleOutcome)` | 純的整條:依請求走 15 → 11 → 17 → 16 → 19..22 → 23 → 3 等路徑 | `Aapms.Workspace.Lifecycle.Plan`(願望) | pure |
| ! | `runLifecycle :: HubLocation -> Hub -> LifecycleOp -> IO (Either WorkspaceError LifecycleOutcome)` | 進入點:以中樞位置、目錄與系統時鐘跑真解譯器 | `Aapms.Workspace.Lifecycle`(願望) | shell |

## Laws
- LAW-1 [identity] setup 冪等:第二次什麼都不建,報告兩個 Bool 都是 False,中樞文字與目錄樹不變
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, run1 in simulateLifecycle t hw vw h (applyLifecycle h SetupHub), hw2 in [hubWorldAfter run1], run2 in simulateLifecycle t hw2 (lcVaults run1) h (applyLifecycle h SetupHub)
  - |- isRight (lcResult run1) and fmap outcomeSetup (lcResult run2) == Right (Just (SetupReport (hlPath (hubLocationIn hw)) False False)) and lcHubText run2 == lcHubText run1 and lcVaults run2 == lcVaults run1
- LAW-2 [invariant] setup 完全不碰既有中樞檔:有檔就不改任何位元組,也不解析它
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, run in simulateLifecycle t hw vw h (applyLifecycle h SetupHub)
  - given isJust (hubTextIn hw)
  - |- lcHubText run == hubTextIn hw and isRight (lcResult run)
- LAW-3 [relation] init 的前置檢查順序固定(名稱 → 已佔用 → 目錄狀態),任一失敗結果就是 checkInit 的錯誤,且零副作用
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, k in VaultKind, name in Text, mode in InitMode, run in simulateLifecycle t hw vw h (applyLifecycle h (InitVault d k name mode)), err in lefts [checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)]
  - |- lcResult run == Left err and lcHubText run == hubTextIn hw and lcVaults run == vw
- LAW-4 [relation] init 成功:marker 讀回的 id / kind / 去空白的 name 就是回傳那一列,索引已建,中樞只多這一列
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, k in VaultKind, name in Text, mode in InitMode, run in simulateLifecycle t hw vw h (applyLifecycle h (InitVault d k name mode)), o in rights [lcResult run], e in maybe [] pure (outcomeEntry o), h2 in maybe [] pure (outcomeHub o), m in rights (maybe [] pure (vwMarker (lcVaults run) d))
  - |- veId e == vmId m and veKind e == k and veName e == vmName m and vePath e == d and vwHasIndex (lcVaults run) d and hubVaults h2 == hubVaults h ++ [e] and hubProjects h2 == hubProjects h and hubLlm h2 == hubLlm h and hubTools h2 == hubTools h
- LAW-5 [relation] id 決定性且可算:同一個時間與名稱建出的 marker id 等於 newId PVlt name t 0
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, k in VaultKind, name in Text, mode in InitMode, run in simulateLifecycle t hw vw h (applyLifecycle h (InitVault d k name mode)), o in rights [lcResult run], e in maybe [] pure (outcomeEntry o), stripped in rights [checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)]
  - |- veId e == VaultId (renderId (newId PVlt stripped t 0))
- LAW-6 [relation] 撞號:新 marker 的 id 等於中樞既有列(路徑不同)就回 VaultIdCollision 三個值,剛建的 .aapms 回滾,中樞不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, k in VaultKind, name in Text, mode in InitMode, old in hubVaults h, stripped in rights [checkInit name mode d (vwMarkerDir vw d) (vwDirExists vw d) (vwEntries vw d)], run in simulateLifecycle t hw vw h (applyLifecycle h (InitVault d k name mode))
  - given veId old == VaultId (renderId (newId PVlt stripped t 0)) and vePath old /= d
  - |- lcResult run == Left (VaultIdCollision (veId old) (vePath old) d) and not (vwMarkerDir (lcVaults run) d) and lcHubText run == hubTextIn hw
- LAW-7 [relation] AdoptExisting 不動既有內容,AdoptNotice 恰是第一層的舊 marker 目錄,固定順序不遞迴
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, k in VaultKind, name in Text, run in simulateLifecycle t hw vw h (applyLifecycle h (InitVault d k name AdoptExisting)), o in rights [lcResult run], n in maybe [] pure (outcomeNotice o)
  - |- anLegacyMarkers n == legacyMarkers d (vwEntries vw d) and vwWithout [d] (lcVaults run) == vwWithout [d] vw and vwEntries (lcVaults run) d == vwEntries vw d ++ [".aapms"]
- LAW-8 [relation] add 成功:身分一律來自 marker,以 id 為鍵 upsert(同 id 再 add 只換 path 不長第二列),vault 目錄不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, run in simulateLifecycle t hw vw h (applyLifecycle h (AddVault d)), m in rights (maybe [] pure (vwMarker vw d))
  - |- fmap (fmap hubVaults . outcomeHub) (lcResult run) == Right (Just (hubVaults (upsertVault (entryOf m d) h))) and fmap outcomeEntry (lcResult run) == Right (Just (entryOf m d)) and lcVaults run == vw
- LAW-20 [relation] add 讀不到 marker 是 MarkerUnreadable 原件,零副作用
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, run in simulateLifecycle t hw vw h (applyLifecycle h (AddVault d)), err in lefts (maybe [] pure (vwMarker vw d))
  - |- lcResult run == Left (MarkerUnreadable d err) and lcHubText run == hubTextIn hw and lcVaults run == vw
- LAW-21 [relation] forget 的 DeleteIndex 先驗身分:目標路徑的 marker 讀得到且 id 與中樞不同就拒,回 DeleteTargetIdDrift,中樞與目錄樹零副作用
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, s in Text, e in rights [lookupSelector h s], actual in maybe [] pure (driftAt vw e), run in simulateLifecycle t hw vw h (applyLifecycle h (ForgetVault s DeleteIndex))
  - |- lcResult run == Left (DeleteTargetIdDrift (veId e) (vePath e) actual) and lcHubText run == hubTextIn hw and lcVaults run == vw
- LAW-22 [relation] purge AllVaults 全有或全無:任一列漂移就整個拒,回第一列漂移的 DeleteTargetIdDrift,中樞檔、縮圖與每個 index.db 都不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, e in take 1 (filter (isJust . driftAt vw) (hubVaults h)), actual in maybe [] pure (driftAt vw e), run in simulateLifecycle t hw vw h (applyLifecycle h (Purge PurgeAllVaults))
  - |- lcResult run == Left (DeleteTargetIdDrift (veId e) (vePath e) actual) and lcHubText run == hubTextIn hw and lcVaults run == vw
- LAW-9 [relation] forget:selector 規則同 lookupSelector,解不開零副作用;KeepIndex 只動中樞,DeleteIndex 只多刪 index.db;回傳被移除的那一列
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, s in Text, di in DeleteIndex, run in simulateLifecycle t hw vw h (applyLifecycle h (ForgetVault s di))
  - given di == KeepIndex or all (isNothing . driftAt vw) (rights [lookupSelector h s])
  - |- either (const (fmap (const ()) (lcResult run) == fmap (const ()) (lookupSelector h s) and lcHubText run == hubTextIn hw and lcVaults run == vw)) (const (fmap outcomeEntry (lcResult run) == fmap Just (lookupSelector h s) and fmap (fmap hubVaults . outcomeHub) (lcResult run) == fmap (Just . hubVaults . flip removeVault h . veId) (lookupSelector h s))) (lookupSelector h s)
- LAW-10 [relation] forget 的 DeleteIndex 只刪那個 vault 的 index.db,其餘目錄樹不動;KeepIndex 連它也不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, s in Text, e in rights [lookupSelector h s], runK in simulateLifecycle t hw vw h (applyLifecycle h (ForgetVault s KeepIndex)), runD in simulateLifecycle t hw vw h (applyLifecycle h (ForgetVault s DeleteIndex))
  - |- lcVaults runK == vw and not (vwHasIndex (lcVaults runD) (vePath e)) and vwWithout [vePath e] (lcVaults runD) == vwWithout [vePath e] vw and vwMarker (lcVaults runD) (vePath e) == vwMarker vw (vePath e)
- LAW-11 [equiv] checkVaults 等於中樞順序逐列重讀 marker 的降級清單,不展開 refs,不寫任何東西
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, run in simulateLifecycle t hw vw h (applyLifecycle h CheckVaults), o in rights [lcResult run]
  - |- outcomeIssues o == checkVaultsOf vw h and all (not . isRefNotRegistered) (outcomeIssues o) and lcHubText run == hubTextIn hw and lcVaults run == vw
- LAW-12 [relation] syncHub 只以 marker 修 name / kind,issues 等於 checkVaults;沒有漂移就不寫檔;vault 目錄永不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, run in simulateLifecycle t hw vw h (applyLifecycle h SyncHub), o in rights [lcResult run], h2 in maybe [] pure (outcomeHub o), e in hubVaults h, m in rights (maybe [] pure (vwMarker vw (vePath e)))
  - given vmId m == veId e
  - |- elem (syncEntry e m) (hubVaults h2) and outcomeIssues o == checkVaultsOf vw h and lcVaults run == vw and ((h2 == h) => (lcHubText run == hubTextIn hw))
- LAW-13 [relation] purge:HubOnly 刪 config.toml 與縮圖不碰 vault;AllVaults 只多刪每個 vault 的 index.db;永不刪 library 與 .md;再跑一次回 PurgeReport False 0 []
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, scope in PurgeScope, run in simulateLifecycle t hw vw h (applyLifecycle h (Purge scope)), o in rights [lcResult run], rep in maybe [] pure (outcomePurge o), run2 in simulateLifecycle t (hubWorldAfter run) (lcVaults run) h (applyLifecycle h (Purge scope))
  - given scope == PurgeHubOnly or all (isNothing . driftAt vw) (hubVaults h)
  - |- isNothing (lcHubText run) and (prHubRemoved rep == isJust (hubTextIn hw)) and ((scope == PurgeHubOnly) => (lcVaults run == vw and prVaultIndexesRemoved rep == [])) and ((scope == PurgeAllVaults) => (vwWithout (map vePath (hubVaults h)) (lcVaults run) == vwWithout (map vePath (hubVaults h)) vw and all (not . vwHasIndex (lcVaults run)) (map vePath (hubVaults h)))) and fmap outcomePurge (lcResult run2) == Right (Just (PurgeReport False 0 []))
- LAW-14 [relation] 專案登錄:空名 InvalidName、路徑不是目錄 ProjectPathMissing、同一路徑第二次 ProjectAlreadyRegistered,三者零副作用;成功只多一列專案
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, d in FilePath, name in Text, run in simulateLifecycle t hw vw h (applyLifecycle h (RegisterProject d name)), o in rights [lcResult run], p in maybe [] pure (outcomeProject o), h2 in maybe [] pure (outcomeHub o)
  - |- (null (words name) => lcResult run == Left (InvalidName name)) and (not (vwDirExists vw d) => (isLeft (lcResult run) and lcHubText run == hubTextIn hw)) and (elem d (map pePath (hubProjects h)) => isLeft (lcResult run)) and (isRight (lcResult run) => (pePath p == d and hubProjects h2 == hubProjects h ++ [p] and hubVaults h2 == hubVaults h))
- LAW-15 [invariant] 專案 id 形狀 prj- 加八位十六進位,不撞既有,同輸入同結果
  - forall existing in [ProjectEntry], nm in Text, t in UTCTime
  - |- idPrefix (allocateProjectId existing nm t) == PPrj and notElem (allocateProjectId existing nm t) (map peId existing) and allocateProjectId existing nm t == allocateProjectId existing nm t
- LAW-16 [relation] 專案撤除:selector 先 id 後 name 逐字、撞名 Ambiguous、解不開零副作用;成功只少那一列,專案目錄不動
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, s in Text, run in simulateLifecycle t hw vw h (applyLifecycle h (ForgetProject s))
  - |- either (const (fmap (const ()) (lcResult run) == fmap (const ()) (lookupProject h s) and lcHubText run == hubTextIn hw)) (const (fmap outcomeProject (lcResult run) == fmap Just (lookupProject h s) and fmap (fmap hubProjects . outcomeHub) (lcResult run) == fmap (Just . hubProjects . flip removeProject h . peId) (lookupProject h s))) (lookupProject h s) and lcVaults run == vw
- LAW-17 [invariant] 任何 Left 都不動中樞檔(全部請求)
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, op in LifecycleOp, run in simulateLifecycle t hw vw h (applyLifecycle h op)
  - given isLeft (lcResult run)
  - |- lcHubText run == hubTextIn hw
- LAW-18 [relation] 寫回的中樞讀得回來:成功且有新 Hub 時,最終中樞文字解析出來就是那個 Hub 的三段
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, op in LifecycleOp, run in simulateLifecycle t hw vw h (applyLifecycle h op), o in rights [lcResult run], h2 in maybe [] pure (outcomeHub o), txt in maybe [] pure (lcHubText run), h3 in rights [parseHubText (hlPath (hubLocationIn hw)) txt]
  - |- hubVaults h3 == hubVaults h2 and hubProjects h3 == hubProjects h2 and hubTools h3 == hubTools h2
- LAW-19 [total] 對任何世界與請求都有值
  - forall t in UTCTime, hw in HubWorld, vw in VaultWorld, h in Hub, op in LifecycleOp
  - |- total (simulateLifecycle t hw vw h (applyLifecycle h op))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 空的中樞目錄 H;`SetupHub` 兩次 | 第一次 `SetupReport H True True`;第二次 `SetupReport H False False`,中樞文字與目錄樹不變 | LAW-1 |
| EX-2 | H/config.toml 是解不開的 `id = "vlt-`;`SetupHub` | `Right`,`spHubCreated == False`,該檔逐位元組不變,不是 HubUnreadable | LAW-2 |
| EX-3 | `InitVault V AssetVault "   " FreshVault`(V 不存在) | `Left (InvalidName "   ")`,V 仍不存在,中樞不變 | LAW-3 |
| EX-4 | V 已有 `.aapms`(目錄或檔案都算);Fresh 與 Adopt 各一次 | 都是 `Left (VaultAlreadyInitialized V)`,`.aapms` 不變 | LAW-3 |
| EX-5 | V 存在含 `a.md`,Fresh;V 不存在,Adopt | 依序 `Left (VaultDirNotEmpty V)`、`Left (VaultDirMissing V)`,零副作用 | LAW-3 |
| EX-6 | V 空目錄,`InitVault V StoryVault "  Lore  " FreshVault`,固定 t | marker `vmName == "Lore"`、`vmKind == StoryVault`;`veId == VaultId (renderId (newId PVlt "Lore" t 0))`;index.db 存在;`hubVaults` 多這一列,其餘三段不變 | LAW-4、LAW-5 |
| EX-7 | 中樞已有 `veId == newId PVlt "Lore" t 0` 的列在 O;同 t 對 V 做 init | `Left (VaultIdCollision id O V)`,V/.aapms 不存在,中樞不變 | LAW-6 |
| EX-8 | V 含 `library/x.png`、`notes.md`、`.assetdb/`、`sub/.storyflow/`;Adopt | `AdoptNotice [V/.assetdb]`(子目錄不算);V 其餘檔案不變,只多 `.aapms` | LAW-7 |
| EX-9 | V 是已 init 的 vault(id vlt-7f3b2a91、name real);`AddVault V` 兩次;再對舊位置 O 的同 id 列 | 一列 `VaultEntry vlt-7f3b2a91 "real" AssetVault V`;第二次仍一列;O 那列被換成 V | LAW-8 |
| EX-10 | `AddVault X`,X 不存在 | `Left (MarkerUnreadable X (VaultMarkerMissing …))`,中樞不變 | LAW-20 |
| EX-11 | 兩列同名 lore;`ForgetVault "lore" KeepIndex`;`ForgetVault "nope" DeleteIndex` | 依序 `Left (VaultSelectorAmbiguous …)`、`Left (VaultSelectorNotFound "nope")`,沒有任何檔被刪 | LAW-9 |
| EX-12 | 三列中間那列 forget,KeepIndex 與 DeleteIndex 各一次;第三次 index.db 事先不在 | Keep:中樞剩兩列順序不變、index.db 還在;Delete:index.db 不在、config.toml 與 library 不變;第三次仍 Right | LAW-9、LAW-10 |
| EX-13 | 三列:正常、路徑不見、id 漂移;`CheckVaults` | `[VaultPathMissing e2 p2, VaultIdDrift e3 id]`,順序同中樞;refs 指向未註冊者不產生 RefVaultNotRegistered | LAW-11 |
| EX-14 | 某列 name stale / kind story,marker 是 real / asset;`SyncHub`;另一組全一致 | 該列變 real / asset,id 與 path 不變;全一致時中樞文字不變、issues 空 | LAW-12 |
| EX-15 | 中樞列兩個 vault,H 有 config.toml、兩張縮圖、notes.txt;`Purge PurgeHubOnly` 與 `PurgeAllVaults`;再各跑一次 | HubOnly:`PurgeReport True 2 []`,vault 不動;AllVaults:`prVaultIndexesRemoved` 是兩個 `<vault 根>/.aapms/index.db`(graph-core 的 `indexDbPath`),library 與 .md 不變;第二次 `PurgeReport False 0 []` | LAW-13 |
| EX-16 | `RegisterProject P "demo"`;再 `RegisterProject P "demo2"`;`RegisterProject Q "x"`(Q 不存在);`RegisterProject P "  "` | 第一次成功多一列;第二次 `Left (ProjectAlreadyRegistered id P)`;第三次 `Left (ProjectPathMissing "x" Q)`;第四次 `Left (InvalidName "  ")` | LAW-14 |
| EX-17 | `allocateProjectId [] "demo" t`;既有列含它的結果再算一次 | `prj-` 加八位十六進位;第二次不等於第一次 | LAW-15 |
| EX-18 | `ForgetProject "demo"`、`ForgetProject "nope"`、兩列同名時 `ForgetProject "dup"` | 依序成功少一列、NotFound、Ambiguous;專案目錄不動 | LAW-16 |
| EX-19 | 任一 Left 的請求 | 中樞文字與起始相同 | LAW-17 |
| EX-20 | EX-6 成功後把最終中樞文字 parseHubText | 三段等於回傳的 Hub | LAW-18 |
| EX-21 | 亂造的世界與請求 | 不拋例外 | LAW-19 |
| EX-22 | 中樞列 A(id `vlt-0000000a`,路徑 P);世界裡 P 的 marker 讀得到但 id 是 `vlt-0000000b`;`ForgetVault "A" DeleteIndex` | `Left (DeleteTargetIdDrift vlt-0000000a P vlt-0000000b)`;中樞文字不變、P 的 index.db 仍在 | LAW-21 |
| EX-23 | 中樞兩列,第二列的路徑上 marker id 漂移;`Purge PurgeAllVaults` | `Left (DeleteTargetIdDrift …)` 指向第二列;中樞檔、縮圖、兩個 index.db 都還在 | LAW-22 |

## 決定
- **十個生命週期操作收成 `LifecycleOp` 一個 sum、一列 `!`;`HubFile` / `VaultDir` / `Markers` / `Clock` 四個效果。** 否決:每個函數一條 pipeline。理由:全部走「前置檢查 → 改 Hub 值 → 原子寫回」同一條紀律。證據:ADR-023-effectful-effects-layer
- **marker 是真相,`VaultEntry` 是它的投影;身分一律來自 marker,中樞的 name / kind 只是快取。** 否決:init 時以呼叫端給的值寫中樞。理由:ADR-017
- **前置檢查順序固定:名稱 → 已佔用 → 目錄狀態;任一失敗零副作用。** 否決:先建 marker 再檢查。理由:失敗要能重跑,不留半成品
- **撞號時回滾剛建的 `.aapms/`,回 VaultIdCollision 三個值(id、既有路徑、這次路徑)。** 否決:讓兩列同 id 並存。理由:id 是鍵,撞號的中樞解不開任何 Ref
- **時間走 `Clock` 效果,`simulateLifecycle` 收明碼時間;id 可由 `newId PVlt name t 0` 算出(LAW-5),撞號在純側以明碼時間精確構造(LAW-6)。舊的 `initVaultWith` 明碼時間進入點隨退場波刪除。** 否決:內部取樣;shell 另留明碼時間進入點。理由:撞號要能在測試裡精確構造(原 workspace E001 / graph-core E002)
- **AdoptExisting 只在第一層找 `.assetdb` / `.storyflow`,固定順序,只報告不刪。** 否決:遞迴、或自動刪舊 marker。理由:舊系統的資料是使用者的
- **add 以 id 為鍵:同一個 vault 搬了位置再 add,只換 path 不長第二列。** 否決:以路徑為鍵。理由:ADR-017 搬動 vault 只改 path
- **forget 的 DeleteIndex 只刪 index.db,本來就沒有不算失敗;KeepIndex 連它都不動。** 否決:連 `.aapms/` 一起刪。理由:marker 是 vault 的身分,forget 是「中樞不再認得它」不是「它不再是 vault」
- **syncHub 方向只有 marker → 中樞,沒有漂移就不寫;checkVaults 不寫任何東西也沒有失敗通道。** 否決:反向修 marker。理由:中樞是快取
- **purge 永不刪 `library/` 與任何 `.md`;AllVaults 只多刪 index.db。** 否決:purge 連 vault 一起清。理由:索引可丟,檔案是真相
- **專案「同一個路徑」以正規化後逐字等於既有列原文判定,不對既有列重新正規化。** 否決:每次比對都重新正規化既有列。理由:既有列寫進去時已經正規化過(原 workspace F005 ASM-6)
- **`vePath` 一律是 `canonicalizePath` 的結果,不是 `makeAbsolute`。** 否決:純字串絕對化。理由:symlink 與 Windows 短檔名要解掉,兩個入口共用同一條(原 workspace GAP-6 選 (c),由 LAW-4 的 `vePath e == d` 在正規化後的世界裡承接)
- **`initVault` 的簽名逐字由 `lint sig` 對帳,不再另寫「簽名逐字等於」的 law。** 否決:文字比對簽名的測試。理由:工具已經做這件事(原 workspace GAP-7)
- **`initVaultAt` 不逸出 IOException:建目錄失敗回 `VaultInitFailed`,不留半成品。** 否決:在 workspace 這層補例外邊界。理由:修 graph-core 的源頭(原 graph-core B002)。這條住 VaultDir 的真解譯器,由 shell 內部測試守
- **檔案系統足跡(只碰 config.toml、cache/thumbs、`.aapms/`、index.db)由 shell 內部測試守,不掛 law。** 否決:寫成 law。理由:純解譯器的世界只裝這幾樣,在純側恆真

## 修訂記錄
- REV-1(2026-09-06,依 qa 提問 GAP-1「EX-15 的 `PurgeReport True 2 []` 需要『H 有兩張縮圖』,`HubWorld` 表達不出」與 GAP-2「LAW-13 的 run2 起始中樞世界仍是 hw,與 `prHubRemoved rep == isJust (hubTextIn hw)` 互斥」):`HubWorld` 依 P-004-vault-scope REV-2 加 `cacheDirIn` / `thumbsIn` 兩個觀察點,EX-15 與 LAW-1 的 `spCacheCreated` 由它們定義;LAW-13 的 run2 改從 `hubWorldAfter run` 起跑(與 LAW-1 同形)
  - 動到:LAW-13 的 forall、觀察點 `cacheDirIn` / `thumbsIn`(引用)
  - 保護:LAW-1 到 LAW-12、LAW-14 到 LAW-20、全部 EX
  - 重委派:qa(LAW-13、EX-15、`HubWorld` 產生器);impl 尚未派
- REV-2(2026-09-06,依 impl 提問 GAP-1「`checkInit` 收不到 vault 根目錄,但它要回的 `VaultAlreadyInitialized` / `VaultDirNotEmpty` / `VaultDirMissing` 都捧著那個路徑;第五個參數是第一層裸名還原不出路徑,而 LAW-3 要求整條結果逐值等於它的錯誤」與「EX-15 的 `prVaultIndexesRemoved` 路徑形狀原文沒定」):第 15 列 `checkInit` 在 `InitMode` 之後加 `FilePath`(vault 根目錄);LAW-3 的呼叫式同步;EX-15 明寫 `<vault 根>/.aapms/index.db`。另 qa 重派時一併處理:EX-20 的世界要用絕對路徑(P-028-hub-config 的 `parseHubText` 只收絕對 `path`),LAW-20 的 `cover` 門檻貼著實測值會隨種子翻紅
  - 動到:Stages 第 15 列、LAW-3 / LAW-5 / LAW-6 的 forall(呼叫式補 d)、EX-15
  - 保護:LAW-1、LAW-2、LAW-4 到 LAW-20、其餘 EX
  - 重委派:impl(`checkInit` 與 `applyLifecycle` 的呼叫點);qa(LAW-3、EX-15、EX-20 的世界、LAW-20 的 cover)
- REV-3(2026-09-06,依 shell 波 impl 提問 GAP-2「`ensureCacheDir` 沒有失敗通道,真解譯器建目錄失敗只能讓例外逸出」):第 4 列改成 `Eff es (Either WorkspaceError Bool)`;`SetupHub` 路徑上 `Left` 就是整條的錯誤(與 `writeHub` 同形)
  - 動到:Stages 第 4 列
  - 保護:LAW-1 到 LAW-20、全部 EX(沒有 law 直接引用 `ensureCacheDir`)
  - 重委派:impl(`HubFile` 的 op、兩個解譯器、`applyLifecycle` 的 SetupHub);qa 無
- REV-4(2026-09-06,依退場波 impl 提問「`DeleteTargetIdDrift` 在 ForgetVault / Purge 沒有任何通道,舊 WAVE-4 裁決 B『刪索引前先驗身分』在搬遷時從 law 消失」;開發者裁決補回守門):加觀察點 `driftAt`;LAW-9 / LAW-13 加 given 排除漂移;新增 LAW-21(forget 的 DeleteIndex 漂移即拒、零副作用)與 LAW-22(purge AllVaults 全有或全無);EX-22 / EX-23
  - 動到:LAW-9、LAW-13 的 given;LAW-21、LAW-22、EX-22、EX-23、觀察點 `driftAt`(新增)
  - 保護:LAW-1 到 LAW-8、LAW-10 到 LAW-12、LAW-14 到 LAW-20、EX-1 到 EX-21
  - 重委派:impl(`driftAt`、`applyLifecycle` 的 ForgetVault / Purge);qa(LAW-9、LAW-13、LAW-21、LAW-22、EX-22、EX-23)
