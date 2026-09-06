---
id: P-029
description: Hub、selector、各 marker 的讀數與 cwd 經純裁決得到 ReadScope / WriteScope / PipelineScope 與 ScopeIssue
status: frozen
updated: 2026-09-06
---
# P-029-scope-resolve:Hub、selector、各 marker 的讀數與 cwd 經純裁決得到 ReadScope / WriteScope / PipelineScope 與 ScopeIssue

## Brief
回答「這次指令對哪些 vault 生效」,是「讀跨、寫單一」的裁決點(ADR-008、ADR-017)。input 是中樞快照 `Hub`、`--vault` 的原始字串、起點目錄、以及每個候選路徑的 marker 讀數;output 是 `ReadScope`(全部生效的 vault 與降級紀錄)、`WriteScope`(一個寫入目標加它的讀取範圍)或 `PipelineScope`(kind 相符的那些)。流向:selector 解析(先比 id 再比 name)或向上探測 `.aapms/` → 對每個候選重讀 marker 取權威身分(路徑不見 / marker 壞 / id 漂移進 `ScopeIssue` 不中止)→ `refs` 廣度優先遞移展開(visited 擋環,展開進來的唯讀)→ 保序去重。marker 的讀取、目錄存在與否、路徑正規化、向上探測是 `Markers` 效果的四個操作,純解譯器跑在一張「路徑 → marker 讀數」的表上;它不開索引、不寫任何檔。它是 P-004-vault-scope 的裁決段,P-005 / P-006 / P-007 / P-008 都靠它決定範圍。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `lookupSelector :: Hub -> Text -> Either WorkspaceError VaultEntry` | selector 先比 id 再比 name,逐字精確,撞名回 Ambiguous | `Aapms.Workspace.Resolve`(願望,自 Aapms.Workspace.Discovery 搬出) | pure |
| 2 | `readMarkerAt :: Markers :> es => FilePath -> Eff es (Either StoreError VaultMarker)` | 讀一個 vault 根目錄的 marker | `Aapms.Workspace.Effect.Markers`(願望) | effects |
| 3 | `dirExists :: Markers :> es => FilePath -> Eff es Bool` | 路徑是不是既存目錄 | `Aapms.Workspace.Effect.Markers`(願望) | effects |
| 4 | `canonicalPath :: Markers :> es => FilePath -> Eff es FilePath` | 正規化(解 symlink、Windows 短檔名) | `Aapms.Workspace.Effect.Markers`(願望) | effects |
| 5 | `detectRoot :: Markers :> es => FilePath -> Eff es (Maybe FilePath)` | 從起點向上找最近一層有 `.aapms/` 目錄的 | `Aapms.Workspace.Effect.Markers`(願望) | effects |
| 6 | `refOfEntry :: Markers :> es => VaultEntry -> Eff es (Either ScopeIssue VaultRef)` | 對中樞一列重讀 marker:路徑不見 → VaultPathMissing、壞 → VaultMarkerBroken、id 不符 → VaultIdDrift,依此順序 | `Aapms.Workspace.Resolve`(願望) | pure |
| 7 | `refAt :: Markers :> es => Hub -> FilePath -> Eff es (Either WorkspaceError VaultRef)` | 對一個路徑讀 marker 並以 id 回填中樞那一列;讀不到一律 MarkerUnreadable | `Aapms.Workspace.Resolve`(願望) | pure |
| 8 | `expandRefGraph :: Markers :> es => Hub -> VaultRef -> Eff es ([VaultRef], [ScopeIssue])` | 自種子沿 vmRefs 廣度優先展開,visited 擋環;未註冊目標 → RefVaultNotRegistered 一次;不可達的不展開它的 refs | `Aapms.Workspace.Resolve`(願望) | pure |
| 9 | `scopeRead :: Markers :> es => Hub -> Maybe Text -> Eff es (Either WorkspaceError ReadScope)` | 無 selector = 全部已註冊(不展開);有 = 種子 ∪ refs* | `Aapms.Workspace.Resolve`(願望) | pure |
| 10 | `scopeWrite :: Markers :> es => Hub -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError WriteScope)` | 目標來自 selector 或探測,恒不來自 refs;目標的失敗是硬錯 | `Aapms.Workspace.Resolve`(願望) | pure |
| 11 | `scopePipeline :: Markers :> es => Hub -> VaultKind -> Maybe Text -> Eff es (Either WorkspaceError PipelineScope)` | 無 selector = 全部已註冊且 kind 相符;有 = 恰好一個,kind 不符回 VaultKindMismatch | `Aapms.Workspace.Resolve`(願望) | pure |
| o | `runMarkersPure :: MarkerWorld -> Eff (Markers : es) a -> Eff es a` | 觀察:Markers 的純解譯器,跑在記憶體的路徑表上,正規化是恆等 | `Aapms.Workspace.Effect.Markers`(願望) | effects |
| o | `simulateScope :: MarkerWorld -> Eff '[Markers] a -> a` | 觀察:純解譯器跑到底 | `Aapms.Workspace.Resolve.Internal`(願望) | pure |
| o | `worldMarker :: MarkerWorld -> FilePath -> Maybe (Either StoreError VaultMarker)` | 觀察:某路徑在世界裡的 marker 讀數 | `Aapms.Workspace.Types`(願望) | types |
| o | `worldDirs :: MarkerWorld -> [FilePath]` | 觀察:世界裡存在的目錄 | `Aapms.Workspace.Types`(願望) | types |
| o | `refIds :: [VaultRef] -> [VaultId]` | 觀察:每個 ref 的 marker id | `Aapms.Workspace.Types`(願望) | types |
| o | `scopeRefs :: Scope -> [VaultRef]` | 觀察:三種 scope 的 vault 清單(寫入 scope 是目標開頭的 wsRead) | `Aapms.Workspace.Types`(願望) | types |
| o | `scopeIssues :: Scope -> [ScopeIssue]` | 觀察:三種 scope 的降級紀錄 | `Aapms.Workspace.Types`(願望) | types |
| o | `isRefNotRegistered :: ScopeIssue -> Bool` | 觀察:是不是 RefVaultNotRegistered | `Aapms.Workspace.Types`(願望) | types |
| o | `selectorHits :: Hub -> Text -> [VaultEntry]` | 觀察:生效的命中集合(id 命中非空就是它,否則是 name 命中),順序同 hubVaults | `Aapms.Workspace.Types`(願望) | types |
| o | `readableIds :: MarkerWorld -> Hub -> [VaultId]` | 觀察:中樞順序下 marker 讀得到且 id 相符的列 | `Aapms.Workspace.Resolve.Internal`(願望) | pure |
| o | `reachable :: MarkerWorld -> Hub -> VaultId -> [VaultId]` | 觀察:參考實作,自種子沿 refs 的 BFS 可達集合(首次入隊序,種子第一,不可達的不展開) | `Aapms.Workspace.Resolve.Internal`(願望) | pure |
| o | `nearestRoot :: MarkerWorld -> FilePath -> Maybe FilePath` | 觀察:參考實作,起點往上第一層有 .aapms 目錄的 | `Aapms.Workspace.Resolve.Internal`(願望) | pure |
| = | `resolveScope :: Markers :> es => Hub -> ScopeKind -> Maybe Text -> FilePath -> Eff es (Either WorkspaceError Scope)` | 純的整條:依 ScopeKind 走 9 / 10 / 11 | `Aapms.Workspace.Resolve`(願望) | pure |

## Laws
- LAW-1 [invariant] 三種 scope 的 vault 清單以 marker id 保序去重
  - forall w in MarkerWorld, h in Hub, k in ScopeKind, sel in Maybe Text, start in FilePath, sc in rights [simulateScope w (resolveScope h k sel start)]
  - |- nub (refIds (scopeRefs sc)) == refIds (scopeRefs sc)
- LAW-2 [relation] marker 是真相:清單裡每個 ref 的 marker 逐欄等於世界裡那個路徑的讀數
  - forall w in MarkerWorld, h in Hub, k in ScopeKind, sel in Maybe Text, start in FilePath, sc in rights [simulateScope w (resolveScope h k sel start)], r in scopeRefs sc
  - |- worldMarker w (vrPath r) == Just (Right (vrMarker r))
- LAW-3 [relation] selector 先比 id 再比 name,id 命中時 name 不算數
  - forall h in Hub, s in Text, e in VaultEntry
  - given elem e (hubVaults h) and veId e == VaultId s
  - |- either (const True) ((== VaultId s) . veId) (lookupSelector h s)
- LAW-4 [relation] selector 命中集合恰一個回它、兩個以上回 Ambiguous 並逐列列出、都沒有回 NotFound
  - forall h in Hub, s in Text, hits in [selectorHits h s]
  - |- ((length hits == 0) == (lookupSelector h s == Left (VaultSelectorNotFound s))) and ((length hits == 1) == (lookupSelector h s == Right (head hits))) and ((length hits >= 2) == (lookupSelector h s == Left (VaultSelectorAmbiguous s hits)))
- LAW-5 [invariant] selector 逐字精確:結果裡的列,id 字串或 name 逐字等於 s
  - forall h in Hub, s in Text, e in rights [lookupSelector h s]
  - |- veId e == VaultId s or veName e == s
- LAW-6 [relation] selector 只看 [[vaults]]:換掉 projects / llm / tools / 原文,結果不變
  - forall h in Hub, h2 in Hub, s in Text
  - given hubVaults h == hubVaults h2
  - |- lookupSelector h s == lookupSelector h2 s
- LAW-7 [equiv] 向上探測命中最近一層,到根都沒有就是 Nothing
  - forall w in MarkerWorld, d in FilePath
  - |- simulateScope w (detectRoot d) == nearestRoot w d
- LAW-8 [identity] 探測命中的那一層自己再探測還是它
  - forall w in MarkerWorld, d in FilePath, p in maybe [] pure (simulateScope w (detectRoot d))
  - |- simulateScope w (detectRoot p) == Just p
- LAW-9 [relation] 對中樞一列重讀 marker 的三種降級互斥且依序:路徑不見、marker 壞、id 漂移
  - forall w in MarkerWorld, e in VaultEntry, r in simulateScope w (refOfEntry e)
  - |- either (const True) ((== veId e) . vmId . vrMarker) r and (isLeft r == (maybe True (either (const True) ((/= veId e) . vmId)) (worldMarker w (vePath e))))
- LAW-10 [relation] 無 selector 的讀取範圍 = 中樞順序下 marker 讀得到且 id 相符的每一列,與起點無關,不展開 refs
  - forall w in MarkerWorld, h in Hub, start in FilePath, start2 in FilePath, rs in rights [simulateScope w (scopeRead h Nothing)]
  - |- refIds (rsVaults rs) == readableIds w h and simulateScope w (resolveScope h ForRead Nothing start) == simulateScope w (resolveScope h ForRead Nothing start2) and all (not . isRefNotRegistered) (rsIssues rs)
- LAW-11 [equiv] 有 selector 的讀取範圍 = 種子 ∪ refs 的遞移閉包,BFS 首次入隊序,種子第一,對環安全
  - forall w in MarkerWorld, h in Hub, s in Text, e in rights [lookupSelector h s], rs in rights [simulateScope w (scopeRead h (Just s))]
  - given isRight (simulateScope w (refOfEntry e))
  - |- refIds (rsVaults rs) == reachable w h (veId e)
- LAW-12 [relation] selector 解不開就是硬錯,原樣透傳
  - forall w in MarkerWorld, h in Hub, s in Text
  - given isLeft (lookupSelector h s)
  - |- fmap (const ()) (simulateScope w (scopeRead h (Just s))) == fmap (const ()) (lookupSelector h s)
- LAW-13 [relation] 種子自己不可達仍是 Right:空清單、恰好那一則 issue、不展開
  - forall w in MarkerWorld, h in Hub, s in Text, e in rights [lookupSelector h s], iss in lefts [simulateScope w (refOfEntry e)]
  - |- simulateScope w (scopeRead h (Just s)) == Right (ReadScope [] [iss])
- LAW-14 [relation] 寫入目標恒不來自 refs:有 selector 就是它命中的列,沒有就是探測命中那一層
  - forall w in MarkerWorld, h in Hub, s in Text, start in FilePath, e in rights [lookupSelector h s], ws in rights [simulateScope w (scopeWrite h (Just s) start)], ws2 in rights [simulateScope w (scopeWrite h Nothing start)], p in maybe [] pure (nearestRoot w start), m in rights (maybe [] pure (worldMarker w p))
  - |- vmId (vrMarker (wsTarget ws)) == veId e and vmId (vrMarker (wsTarget ws2)) == vmId m
- LAW-15 [relation] 寫入的讀取範圍 = 目標排第一,其餘與對同一個種子做讀取展開相同
  - forall w in MarkerWorld, h in Hub, sel in Maybe Text, start in FilePath, ws in rights [simulateScope w (scopeWrite h sel start)]
  - |- head (refIds (wsRead ws)) == vmId (vrMarker (wsTarget ws)) and refIds (wsRead ws) == reachable w h (vmId (vrMarker (wsTarget ws)))
- LAW-16 [relation] 沒有 selector 且探測不到就是 NoWriteTarget,帶正規化後的起點
  - forall w in MarkerWorld, h in Hub, start in FilePath
  - given isNothing (nearestRoot w start)
  - |- simulateScope w (scopeWrite h Nothing start) == Left (NoWriteTarget start)
- LAW-17 [relation] 寫入目標的失敗是硬錯不是降級:marker 讀不到 → MarkerUnreadable;selector 的 id 與 marker 不符 → WriteTargetIdDrift
  - forall w in MarkerWorld, h in Hub, s in Text, start in FilePath, e in rights [lookupSelector h s], err in lefts (maybe [] pure (worldMarker w (vePath e)))
  - |- simulateScope w (scopeWrite h (Just s) start) == Left (MarkerUnreadable (vePath e) err)
- LAW-18 [relation] 探測命中一個中樞沒有的 vault 仍可寫:vrEntry 為 Nothing,且它排第一
  - forall w in MarkerWorld, h in Hub, start in FilePath, p in maybe [] pure (nearestRoot w start), m in rights (maybe [] pure (worldMarker w p)), ws in rights [simulateScope w (scopeWrite h Nothing start)]
  - given notElem (vmId m) (map veId (hubVaults h))
  - |- vrEntry (wsTarget ws) == Nothing and head (refIds (wsRead ws)) == vmId m
- LAW-19 [invariant] selector 勝過探測:有 selector 時結果與起點無關
  - forall w in MarkerWorld, h in Hub, s in Text, start in FilePath, start2 in FilePath
  - |- simulateScope w (scopeWrite h (Just s) start) == simulateScope w (scopeWrite h (Just s) start2)
- LAW-20 [relation] 無 selector 的管線範圍 = 讀取範圍裡 kind 相符的,issues 與讀取範圍逐欄相同
  - forall w in MarkerWorld, h in Hub, k in VaultKind, ps in rights [simulateScope w (scopePipeline h k Nothing)], rs in rights [simulateScope w (scopeRead h Nothing)]
  - |- psRuns ps == filter ((== k) . vmKind . vrMarker) (rsVaults rs) and psIssues ps == rsIssues rs
- LAW-21 [relation] 有 selector 的管線範圍恰好一個、不展開;kind 不符回 VaultKindMismatch 三個值
  - forall w in MarkerWorld, h in Hub, k in VaultKind, s in Text, e in rights [lookupSelector h s], r in rights [simulateScope w (refOfEntry e)]
  - |- ((vmKind (vrMarker r) == k) => (simulateScope w (scopePipeline h k (Just s)) == Right (PipelineScope [r] []))) and ((vmKind (vrMarker r) /= k) => (simulateScope w (scopePipeline h k (Just s)) == Left (VaultKindMismatch (vmId (vrMarker r)) k (vmKind (vrMarker r)))))
- LAW-22 [relation] 有 selector 但不可達:管線範圍是 Right 加一則 issue,不是 VaultKindMismatch
  - forall w in MarkerWorld, h in Hub, k in VaultKind, s in Text, e in rights [lookupSelector h s], iss in lefts [simulateScope w (refOfEntry e)]
  - |- simulateScope w (scopePipeline h k (Just s)) == Right (PipelineScope [] [iss])
- LAW-23 [invariant] 未註冊的 refs 目標降級為一則 RefVaultNotRegistered,同一個目標只一則
  - forall w in MarkerWorld, h in Hub, s in Text, rs in rights [simulateScope w (scopeRead h (Just s))], bad in [filter isRefNotRegistered (rsIssues rs)]
  - |- nub bad == bad
- LAW-24 [invariant] 不判 ATTACH 上限:讀得到幾個就回幾個,沒有數量相關的錯誤
  - forall w in MarkerWorld, h in Hub
  - |- isRight (simulateScope w (scopeRead h Nothing)) and length (readableIds w h) == length (maybe [] rsVaults (either (const Nothing) Just (simulateScope w (scopeRead h Nothing))))
- LAW-25 [total] 對任何世界與輸入裁決都有值、都終止
  - forall w in MarkerWorld, h in Hub, k in ScopeKind, sel in Maybe Text, start in FilePath
  - |- total (simulateScope w (resolveScope h k sel start))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | 中樞 A、B、C、D、M(marker 壞)、P(路徑不見)、Z(id 漂移);`scopeRead h Nothing` | `rsVaults` 的 id 依序 A、B、C、D;`rsIssues` 為 `[VaultMarkerBroken m err, VaultPathMissing p path, VaultIdDrift z (VaultId "vlt-99998888")]` | LAW-1、LAW-2、LAW-9、LAW-10 |
| EX-2 | A 的 refs 指 B、B 指 C、C 指 A;`scopeRead h (Just "a")` | A、B、C,成環仍終止且不重複;issues 空 | LAW-11 |
| EX-3 | 菱形 A → B、C;B → D;C → D;`scopeRead h (Just "a")` | A、B、C、D,D 只一次 | LAW-1、LAW-11 |
| EX-4 | `scopeRead h (Just "vlt-aaaa1111")` 與 `(Just "a")` | 逐欄相同 | LAW-3、LAW-11 |
| EX-5 | 中樞兩列 name 都是 `dup`;`lookupSelector h "dup"` | `Left (VaultSelectorAmbiguous "dup" [兩列])`;`" dup"`、`"DUP"` 都是 NotFound | LAW-4、LAW-5 |
| EX-6 | 換掉 projects / llm / tools 再查同一個 selector | 結果不變 | LAW-6 |
| EX-7 | 世界裡 `T/a/.aapms` 與 `T/a/deep/.aapms` 都存在;`detectRoot "T/a/deep/deeper"` | `Just "T/a/deep"`(最近一層);`detectRoot "T2"` 為 Nothing;`detectRoot "T/a/deep"` 為自己 | LAW-7、LAW-8 |
| EX-8 | `scopeRead h (Just "nope")` | `Left (VaultSelectorNotFound "nope")` | LAW-12 |
| EX-9 | `scopeRead h (Just "m")`(種子 marker 壞) | `Right (ReadScope [] [VaultMarkerBroken m err])` | LAW-13 |
| EX-10 | `scopeWrite h Nothing "T/a/deep/deeper"` | 目標 A;wsRead 依序 A、B、C;issues 空 | LAW-14、LAW-15 |
| EX-11 | `scopeWrite h Nothing "T2"` | `Left (NoWriteTarget "T2")` | LAW-16 |
| EX-12 | `scopeWrite h (Just "p") "T/a"` | `Left (MarkerUnreadable path err)` | LAW-17 |
| EX-13 | `scopeWrite h Nothing "T/e/x"`,E 不在中樞 | 目標的 `vrEntry == Nothing`,wsRead 第一個是 E | LAW-18 |
| EX-14 | `scopeWrite h (Just "b") "T/a/deep"` 與起點改 `"T2"` | 逐欄相同,目標 B,A 只以唯讀身分經 refs 進來 | LAW-19、LAW-15 |
| EX-15 | `scopePipeline h AssetVault Nothing`,B 是 story | A、C、D;issues 與 EX-1 相同 | LAW-20 |
| EX-16 | `scopePipeline h AssetVault (Just "a")`;`(Just "b")`;`(Just "m")` | 依序 `Right (PipelineScope [A] [])`、`Left (VaultKindMismatch b AssetVault StoryVault)`、`Right (PipelineScope [] [VaultMarkerBroken m err])` | LAW-21、LAW-22 |
| EX-17 | A 的 refs 指 B 與 `vlt-ffff0000`(未註冊),兩個來源都列它;`scopeRead h (Just "a")` | issues 含恰一則 `RefVaultNotRegistered a (VaultId "vlt-ffff0000")` | LAW-23 |
| EX-18 | 11 個都讀得到的 vault;`scopeRead h Nothing` | Right,長度 11,沒有錯誤 | LAW-24 |
| EX-19 | 任意亂造的世界與中樞 | 求值到底不拋例外、終止 | LAW-25 |

## 決定
- **裁決是 `Markers` 效果的程式,只有讀 marker、目錄存在、正規化、向上探測四個操作,純解譯器跑在路徑表上。** 否決:保留 `resolveRead` 等三個 IO 函數當唯一實作。理由:F003 的 24 條 law 有 20 條講的是純判定,卻只能靠真檔案系統的 fixture 驗;抽成效果後 qa 不碰磁碟。證據:ADR-023-effectful-effects-layer
- **三種 scope 收成一個 `Scope` sum 與 `ScopeKind`,一列 `=`。** 否決:三條 pipeline。理由:三者共用 selector、重讀 marker、refs 展開,只在最後一步分流
- **marker 是真相,中樞的 name / kind 是快取;比對只看 id 不看路徑。** 否決:信中樞。理由:ADR-017,搬動 vault 只改 path
- **不可達(路徑不見 / marker 壞 / id 漂移)在讀取與管線範圍是降級不中止;在寫入目標是硬錯。** 否決:一律降級。理由:寫錯地方的傷害不可逆,整道指令該停(原 F003 LAW-13,WAVE-3 閘門)
- **id 漂移的節點不展開它的 refs。** 否決:marker 讀得到就展開。理由:身分不確定時任何以它為起點的關係都不確定
- **未註冊的 refs 目標降級為 RefVaultNotRegistered 一則,不中止、不進結果。** 否決:硬錯。理由:一個壞掉的 refs 不該讓整個範圍解不開(ADR-017 補充)
- **不判 ATTACH 上限;`TooManyVaults` 屬 graph-core。** 否決:在這裡數。理由:上限是 sqlite 的物理限制,不是裁決的語意
- **selector 逐字精確,不 trim、不忽略大小寫、先 id 後 name,撞到就 Ambiguous。** 否決:模糊比對。理由:歧義要浮出來給人決定(原 F002 ASM-2)
- **`lookupSelector` 與 refs 展開自 `Aapms.Workspace.Discovery` / `Scope` 搬進純的 `Aapms.Workspace.Resolve`;真解譯器住 `Aapms.Workspace.Effect.Markers.IO`,`resolveRead` 等三個 IO 函數退成薄包裝。** 否決:原地不動。理由:純判定不該住 shell 模組
- **真解譯器不動檔案系統(不建 .aapms、不開 index.db、不修補 marker、不寫中樞)由 shell 的內部測試守。** 否決:寫成 law。理由:純解譯器裡世界是不可變的,這條在純側恆真
- **`MarkerWorld` 的世界不變量:路徑不是既存目錄(不在 `worldDirs`)時,該路徑的 marker 讀數一定是 `Left`。** 否決:讓「目錄不存在但 marker 可讀」的世界也合法。理由:stage 6 的 `refOfEntry` 先看路徑在不在,LAW-9 的右半只看 `worldMarker`,兩者要對得起來這條就必須成立;純解譯器與產生器都遵守它,真解譯器天然成立(沒有目錄就沒有檔)。(qa 基線時發現,2026-09-06)

## 修訂記錄
無
