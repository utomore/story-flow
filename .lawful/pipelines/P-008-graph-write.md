---
id: P-008
description: 圖譜寫入請求 ADT 經型別與關聯目標驗證、Level 樹合法性、落地寫入,回新 revision 的 NodeView
status: ready
updated: 2026-09-06
---
# P-008-graph-write:圖譜寫入請求 ADT 經型別與關聯目標驗證、Level 樹合法性、落地寫入,回新 revision 的 NodeView

## Brief
service 的寫入契約:三個殼送來的十四種寫入請求(建 entity、加片段、改 Meta、改正文、刪節點、加 / 刪關聯、asset 命名、改 asset 人給欄位、更新授權、建 Level、刪 Level、加 / 刪 Node)在這裡做業務驗證,再交給 P-003-node-write 落地,最後重投影成 NodeView。input 是 `GraphOp` 請求與寫入情境(P-004 開場、P-029 裁決出的寫入目標與讀取範圍);output 是 `WriteReport`(新 revision 的 NodeView,或刪除報告)。流向:解析目標 Ref(只在寫入目標 vault 裡找)→ 驗證(型別要在註冊表、必填欄位、關聯目標在讀取範圍內且存在、asset 邏輯名稱全域唯一、Level 樹合法)→ 翻成 P-003 的 `WriteOp`(建檔類先配號)→ 在目標 vault 跑 `applyWrite` → StoreError 翻成 ServiceError(RevisionMismatch → RevisionConflict)→ 重讀成 NodeView。整條是 `Vaults` 與 `Clock` 效果的程式;純解譯器跑在記憶體的「每個 vault 一份檔案表加索引」上。真解譯器住 shell,`runGraphWrite` 是進入點,ServiceM 的十四個門面是薄包裝。它讓 O-1 的 M-4 往前一步,對應原 service F004 / F005 / F006。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|
| 1 | `inVaultRW :: Vaults :> es => VaultId -> Eff '[VaultFs, Index, Clock] a -> Eff es (Maybe a)` | 對集合裡某個 vault 跑一段可寫的程式;不在集合回 Nothing | `Aapms.Store.Effect.Vaults`(願望) | effects |
| 2 | `inVault :: Vaults :> es => VaultId -> Eff '[Index] a -> Eff es (Maybe a)` | 只讀地看別的 vault(關聯目標存在與否) | `Aapms.Store.Effect.Vaults`(願望,見 P-002-search) | effects |
| 3 | `nodeById :: Index :> es => Id -> Eff es (Maybe AnyNode)` | 取節點 | `Aapms.Store.Effect.Index`(願望,見 P-007-graph-read) | effects |
| 4 | `assetByName :: Index :> es => LogicalName -> Eff es (Maybe Id)` | 邏輯名稱是否已被某個 asset 用掉 | `Aapms.Store.Effect.Index`(願望) | effects |
| 5 | `lookupType :: TypeRegistry -> TypeKey -> Maybe TypeDecl` | 型別要在註冊表裡 | `Aapms.Core.Registry`(見 P-021-registry-build) | types |
| 6 | `checkMeta :: TypeRegistry -> AnyNode -> [MetaWarning]` | 必填欄位與關聯種類的檢查;寫入路徑把警告當錯誤 | `Aapms.Core.Registry.Build`(見 P-021-registry-build) | pure |
| 7 | `validateLinks :: Vaults :> es => [VaultId] -> [Link] -> Eff es (Either ServiceError ())` | 每條關聯的目標:vault 不在讀取範圍 → LinkTargetOutOfScope;在範圍但節點不存在 → DanglingLinkTarget | `Aapms.Service.Write`(願望) | pure |
| 8 | `validateOp :: TypeRegistry -> GraphOp -> Either ServiceError ()` | 純的部分:型別存在(UnknownType)、名稱非空、必填欄位 | `Aapms.Service.Write`(願望) | pure |
| 9 | `allocateFreshId :: Index :> es => IdPrefix -> Text -> UTCTime -> Eff es (Either StoreError Id)` | 建檔類先配號 | `Aapms.Store.Editing`(願望,見 P-003-node-write) | pure |
| 10 | `toWriteOp :: TypeRegistry -> Maybe Id -> GraphOp -> Either ServiceError WriteOp` | 服務層請求翻成落地層請求(建檔類帶配到的 id) | `Aapms.Service.Write`(願望) | pure |
| 11 | `applyWrite :: (VaultFs :> es, Index :> es, Clock :> es) => TypeRegistry -> VaultId -> WriteOp -> Eff es (Either StoreError WriteOutcome)` | 落地 | `Aapms.Store.Editing`(願望,見 P-003-node-write) | pure |
| 12 | `liftStoreError :: Ref -> StoreError -> ServiceError` | RevisionMismatch → RevisionConflict、TreeInvalidOnWrite → LevelTreeInvalid、其餘 StoreFailed 原件 | `Aapms.Service.Write`(願望) | pure |
| 13 | `toNodeView :: TypeRegistry -> VaultId -> Located -> AnyNode -> NodeView` | 重讀後投影 | `Aapms.Service.Read`(願望,見 P-007-graph-read) | pure |
| 14 | `locateId :: Index :> es => Id -> Eff es (Maybe Located)` | 重讀時定位 | `Aapms.Store.Effect.Index`(願望,見 P-003-node-write) | effects |
| o | `simulateGraph :: UTCTime -> Map VaultId (VaultFiles, IndexState) -> Eff '[Vaults, Clock] a -> GraphRun a` | 觀察:純解譯器跑到底,回結果與最終的每個 vault 的檔案表與索引 | `Aapms.Service.Write.Internal`(願望) | pure |
| o | `grResult :: GraphRun a -> a` | 觀察:結果 | `Aapms.Service.Types`(願望) | types |
| o | `grWorld :: GraphRun a -> Map VaultId (VaultFiles, IndexState)` | 觀察:最終世界 | `Aapms.Service.Types`(願望) | types |
| o | `wcRegistry :: WriteCtx -> TypeRegistry` | 觀察:註冊表 | `Aapms.Service.Types`(願望) | types |
| o | `wcTarget :: WriteCtx -> VaultId` | 觀察:寫入目標 | `Aapms.Service.Types`(願望) | types |
| o | `wcRead :: WriteCtx -> [VaultId]` | 觀察:讀取範圍(目標第一) | `Aapms.Service.Types`(願望) | types |
| o | `opTargetRef :: GraphOp -> Maybe Ref` | 觀察:請求要動的既有節點 | `Aapms.Service.Types`(願望) | types |
| o | `opExpected :: GraphOp -> Maybe Revision` | 觀察:請求帶的 expected revision | `Aapms.Service.Types`(願望) | types |
| o | `opLinks :: GraphOp -> [Link]` | 觀察:請求裡要驗證的關聯 | `Aapms.Service.Types`(願望) | types |
| o | `opType :: GraphOp -> Maybe TypeKey` | 觀察:請求宣告的型別 | `Aapms.Service.Types`(願望) | types |
| o | `reportNode :: WriteReport -> Maybe NodeView` | 觀察:成功後的 NodeView | `Aapms.Service.Types`(願望) | types |
| o | `reportRemoved :: WriteReport -> [Ref]` | 觀察:刪除報告消失的 Ref | `Aapms.Service.Types`(願望) | types |
| o | `isLevelTreeInvalid :: ServiceError -> Bool` | 觀察:是不是 LevelTreeInvalid | `Aapms.Service.Types`(願望) | types |
| o | `nodeIn :: Map VaultId IndexState -> VaultId -> Id -> Maybe AnyNode` | 觀察:某 vault 某 id 的節點 | `Aapms.Store.Types`(願望,見 P-007-graph-read) | types |
| o | `indexOf :: Map VaultId (VaultFiles, IndexState) -> Map VaultId IndexState` | 觀察:只取索引 | `Aapms.Service.Types`(願望) | types |
| o | `assetNamed :: Map VaultId IndexState -> [VaultId] -> LogicalName -> Maybe (VaultId, Id)` | 觀察:哪個 vault 的哪個 asset 已用這個名字 | `Aapms.Service.Types`(願望) | types |
| o | `nvMeta :: NodeView -> Meta` | 觀察:Meta | `Aapms.Service.Types`(願望,見 P-007-graph-read) | types |
| o | `nvVault :: NodeView -> VaultId` | 觀察:vault | `Aapms.Service.Types`(願望,見 P-007-graph-read) | types |
| = | `graphWrite :: (Vaults :> es, Clock :> es) => WriteCtx -> GraphOp -> Eff es (Either ServiceError WriteReport)` | 純的整條:8 → 目標解析(只看 wcTarget)→ 7 → 4 → 9 → 10 → 1(11)→ 12 → 14 / 3 → 13 | `Aapms.Service.Write`(願望) | pure |
| ! | `runGraphWrite :: Env -> GraphOp -> IO (Either ServiceError WriteReport)` | 進入點:以 Env 的快照與 handle 快取跑真解譯器 | `Aapms.Service.Write`(願望) | shell |

## Laws
- LAW-1 [relation] 型別不在註冊表即 UnknownType,零副作用
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, kt in Text, run in simulateGraph t w (graphWrite ctx op)
  - given opType op == Just (TypeKey kt) and isNothing (lookupType (wcRegistry ctx) (TypeKey kt))
  - |- grResult run == Left (UnknownType kt) and grWorld run == w
- LAW-2 [relation] 關聯目標:vault 不在讀取範圍 → LinkTargetOutOfScope;在範圍但不存在 → DanglingLinkTarget;兩者零副作用
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, l in opLinks op, run in simulateGraph t w (graphWrite ctx op), tv in [fromMaybe (wcTarget ctx) (refVault (linkTarget l))]
  - given isRight (validateOp (wcRegistry ctx) op)
  - |- (notElem tv (wcRead ctx) => (grResult run == Left (LinkTargetOutOfScope (linkTarget l)) and grWorld run == w)) and ((elem tv (wcRead ctx) and isNothing (nodeIn (indexOf w) tv (refId (linkTarget l)))) => (grResult run == Left (DanglingLinkTarget (linkTarget l)) and grWorld run == w))
- LAW-3 [relation] 樂觀鎖不符即 RevisionConflict 三個值,零副作用
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, r in maybe [] pure (opTargetRef op), e in maybe [] pure (opExpected op), n in maybe [] pure (nodeIn (indexOf w) (wcTarget ctx) (refId r)), run in simulateGraph t w (graphWrite ctx op)
  - given e /= metaRevision (anyMeta n) and isRight (validateOp (wcRegistry ctx) op)
  - |- grResult run == Left (RevisionConflict r e (metaRevision (anyMeta n))) and grWorld run == w
- LAW-4 [relation] 目標只在寫入目標 vault 裡找:不在那裡就是 NodeNotFound,即使讀取範圍的別的 vault 有同 id
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, r in maybe [] pure (opTargetRef op), run in simulateGraph t w (graphWrite ctx op)
  - given isNothing (nodeIn (indexOf w) (wcTarget ctx) (refId r)) and isRight (validateOp (wcRegistry ctx) op)
  - |- grResult run == Left (NodeNotFound r) and grWorld run == w
- LAW-5 [relation] 成功時回的 NodeView 就是重讀目標 vault 得到的節點,revision 比請求的多一
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, n in Int, run in simulateGraph t w (graphWrite ctx op), rep in rights [grResult run], v in maybe [] pure (reportNode rep)
  - given opExpected op == Just (Revision n)
  - |- nvVault v == wcTarget ctx and fmap anyMeta (nodeIn (indexOf (grWorld run)) (wcTarget ctx) (metaId (nvMeta v))) == Just (nvMeta v) and metaRevision (nvMeta v) == Revision (n + 1)
- LAW-6 [invariant] 寫入只動目標 vault:讀取範圍裡其他 vault 的檔案表與索引不變
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, run in simulateGraph t w (graphWrite ctx op), v in wcRead ctx
  - given v /= wcTarget ctx
  - |- lookup v (toList (grWorld run)) == lookup v (toList w)
- LAW-7 [relation] asset 命名全域唯一:名稱已被讀取範圍內任一 asset 用掉即 LogicalNameTaken 帶擁有者,零副作用
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, r in Ref, e in Revision, nm in LogicalName, run in simulateGraph t w (graphWrite ctx (OpSetAssetName r e nm)), (ov, oi) in maybe [] pure (assetNamed (indexOf w) (wcRead ctx) nm)
  - given oi /= refId r
  - |- grResult run == Left (LogicalNameTaken nm (Ref (Just ov) oi)) and grWorld run == w
- LAW-8 [relation] 刪除報告消失的 Ref 等於 P-003 的 removedIds 加上目標 vault
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, r in Ref, e in Revision, mode in DeleteMode, run in simulateGraph t w (graphWrite ctx (OpDelete r e mode)), rep in rights [grResult run], x in reportRemoved rep
  - |- refVault x == Just (wcTarget ctx) and isNothing (nodeIn (indexOf (grWorld run)) (wcTarget ctx) (refId x))
- LAW-9 [relation] Level 樹不合法即 LevelTreeInvalid 帶目標 id 與錯誤清單,零副作用
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, run in simulateGraph t w (graphWrite ctx op), err in lefts [grResult run]
  - given isLevelTreeInvalid err
  - |- grWorld run == w
- LAW-10 [invariant] 任何 Left 世界不變
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp, run in simulateGraph t w (graphWrite ctx op)
  - given isLeft (grResult run)
  - |- grWorld run == w
- LAW-11 [total] 對任何世界與請求都有值
  - forall t in UTCTime, w in Map VaultId (VaultFiles, IndexState), ctx in WriteCtx, op in GraphOp
  - |- total (simulateGraph t w (graphWrite ctx op))

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|
| EX-1 | `OpCreateEntity (neType = "ghost", …)`,註冊表沒有 ghost | `Left (UnknownType "ghost")`,世界不變 | LAW-1 |
| EX-2 | 關聯指向 `vlt-cccc:ent-1`,C 不在讀取範圍;另一條指向範圍內 B 沒有的 `ent-9` | 依序 `Left (LinkTargetOutOfScope …)`、`Left (DanglingLinkTarget …)` | LAW-2 |
| EX-3 | 目標 revision 3,`OpSetBody r (Revision 2) "x"` | `Left (RevisionConflict r (Revision 2) (Revision 3))` | LAW-3 |
| EX-4 | 目標 A 沒有 `ent-7`,B 有;`OpSetBody (Ref Nothing ent-7) …` | `Left (NodeNotFound (Ref Nothing ent-7))` | LAW-4 |
| EX-5 | `OpUpdateMeta r (Revision 3) (mpTitle = Just "新標題")` | `reportNode` 的 `metaTitle == "新標題"`、`metaRevision == Revision 4`,重讀相同;B 的世界不變 | LAW-5、LAW-6 |
| EX-6 | B 的 asset 已叫 `ui_gui_frame_001`;對 A 的 asset `OpSetAssetName … "ui_gui_frame_001"` | `Left (LogicalNameTaken name (Ref (Just B) that))` | LAW-7 |
| EX-7 | `OpDelete nod-a r DeleteForce`,子樹兩個 | `reportRemoved` 兩個 Ref 都帶 A,重讀都不在 | LAW-8 |
| EX-8 | `OpAddNode parent (nnKind …)` 讓樹成環 | `Left (LevelTreeInvalid lvl [Cycle …])`,世界不變 | LAW-9、LAW-10 |
| EX-9 | `OpCreateEntity` 合法 | `reportNode` 的 `metaRevision == Revision 1`,detail 是 DEntity | LAW-5 |
| EX-10 | 亂造的世界與請求 | 不拋例外 | LAW-11 |

## 決定
- **十四種寫入收成 `GraphOp` / `WriteReport`,一列 `=`;`Vaults` 效果多一個可寫的 `inVaultRW`。** 否決:改 P-002 的 `inVault` 簽名。理由:讀的程式不該拿到寫的能力;兩個操作各自最小權限。證據:ADR-023-effectful-effects-layer
- **業務驗證在這裡,不在 graph-core:型別存在、必填欄位、關聯目標在範圍內且存在、asset 名稱全域唯一。** 否決:store 自己驗。理由:store 不知道「讀取範圍」與「全部已註冊 vault」,那是 workspace 的裁決
- **`checkMeta` 的警告在寫入路徑當錯誤(ValidationFailed),在讀取路徑只是警告。** 否決:寫入也只警告。理由:新寫進去的東西不該一開始就殘缺;既有檔案手改壞了則不能讓它讀不到
- **目標只在寫入目標 vault 裡找;關聯目標可以在讀取範圍的任何 vault。** 否決:目標也跨 vault 找。理由:寫單一(ADR-017)
- **asset 名稱唯一性用「全部已註冊 vault」的範圍查,不只讀取範圍。** 否決:只查目標 vault。理由:名稱是 `Assets.hs` 的 key,跨 vault 撞名會讓專案產出撞 key(原 service F005)
- **StoreError 翻譯只做三件:RevisionMismatch → RevisionConflict、TreeInvalidOnWrite → LevelTreeInvalid、其餘原件包成 StoreFailed;訊息不重寫。** 否決:每個建構子重寫訊息。理由:上層不重寫下層的訊息(system.md 全域錯誤策略)
- **`expected revision` 每種動既有節點的請求都必填,沒有例外。** 否決:單筆 CRUD 免帶。理由:樂觀鎖是並發的唯一防線(ADR-022 之外的第 6 條)
- **`reindex` / `refreshIndex`(原 F008 index-ops)不在本條:它們是 P-001-index-rebuild 的 shell 門面,經 `withPipeline` 對 kind 相符的每個 vault 跑一次。** 否決:併進 GraphOp。理由:重建不是圖譜寫入,沒有 revision、沒有目標節點

## 修訂記錄
無
