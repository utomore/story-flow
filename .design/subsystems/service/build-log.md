---
id: service-build
type: build-log
title: service-build
description: service 子系統的委派展開紀錄,本次只跑階段一(骨幹)
status: in-progress
created: 2026-08-30
updated: 2026-08-30
parent: service
---

# service 委派展開紀錄

## 排程

本次只跑**階段一**(2026-08-30 開發者裁決)。階段二 / 三的五個 feature 留待下一次
`/subsys-build service`(接續模式)。

| 階段 | 波次 | features | 骨架快照 | 白名單對帳 | 狀態 |
|---|---|---|---|---|---|
| 階段一 | WAVE-1 | service-env-and-scope | `fd65e0c`(輪 1)、`eb73830`(輪 2) | **OK**(輪 1、輪 2 各對一次,皆無違規) | **done**(2026-08-30,`aapms-service-test` 62/0) |
| 階段一 | WAVE-2 | workspace-facade | `dfd0b0e` | **OK**(2026-08-30,無違規) | **done**(`aapms-service-test` 120/0) |
| 階段二 | WAVE-3–WAVE-6 | node-read / node-write / asset-naming / level-and-node | | | 本次不跑 |
| 階段三 | WAVE-7 | search-facade ∥ index-ops | | | 本次不跑 |

**波次怎麼切的**:依「功能規劃」的「依賴」欄拓撲排序。`#2 workspace-facade` 依賴 `#1`,所以
不同波。階段二的 `#5 asset-naming` 與 `#6 level-and-node` 彼此不依賴、理論上同波,但兩者的
負責模組都含 **Write**,骨架檔案會重疊,依 `/subsys-build` 步驟 1 第 5 點拆成 WAVE-5 / WAVE-6。

**跨子系統依賴**:`graph-core`(9/9 features done)與 `workspace`(6/6 done)都已完成,沒有
「要等還是照介面約定先做」的問題。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| DEC-1 | `aapms-service.cabal` 與 `cabal.project` 誰維護 | **編排者單線維護**,不屬任何 feature 的寫入白名單(沿用 workspace 的 DEC-2、graph-core E001 的教訓) | 全部 8 個 feature |
| DEC-2 | 舊 `service-and-interfaces` 的 3266 行程式碼怎麼處置 | **搬去 `legacy/service-and-interfaces/`** 當移植參考,附 README 寫明新設計已否決它的哪些核心選擇;不刪除 | WAVE-1(骨架路徑撞名的來源) |
| DEC-3 | 這次跑到第幾階段 | **只跑階段一**(WAVE-1 + WAVE-2)。地基的契約如果在實作上站不住,現在發現比跑完八個再發現便宜一個數量級 | 全部 |
| DEC-4 | **閘門密度** | **嚴格** —— 每一波的 spec 批准閘門都停,議程空著也停。理由:第一次展開這個子系統,契約卡從未經過實作檢驗 | 全部 |
| DEC-5 | 本套件設不設門面模組(`Aapms.Service`) | **不設**,模組全部 exposed,界線由 `exposed-modules` 守。依據:`design.md`「內部模組劃分」列的七個模組裡沒有門面,而 workspace 與 graph-core E001 之後都是這個形狀。(legacy 有 `Aapms.Service` 門面,不沿用) | 全部 |
| DEC-6 | `service/test/Spec.hs` 的維護 | **手寫彙總器,編排者建檔**,qa 每波自己把 `describe` 加進去並在回報列出要加進 `.cabal` `other-modules` 的模組名。理由:graph-core E001 踩過「新模組沒接進 `Spec.hs` 就整批不執行,而輸出看起來全綠」 | 全部 |

## 配號表

| feature | id | 檔名 | 骨架檔案 | spec 模型 | qa 模型 | impl 模型 | 狀態 |
|---|---|---|---|---|---|---|---|
| service-env-and-scope | F001 | F001-service-env-and-scope.md | `service/src/Aapms/Service/Types.hs`、`service/src/Aapms/Service/Monad.hs`、`service/src/Aapms/Service/Scope.hs` | opus | sonnet | sonnet | **impl-done**(62/0 綠) |
| workspace-facade | F002 | F002-workspace-facade.md | `service/src/Aapms/Service/Machine.hs` | opus | sonnet | sonnet | **impl-done**(120/0 綠) |

**骨架檔案不重疊**:WAVE-1 與 WAVE-2 各自一波,不平行,但仍逐波指派 —— `Types.hs` 由 F001 建骨架,
F002 起「各自擴充建構子」的部分屬後續波次,由編排者在該波的白名單裡明確授權,不由 subagent
自行認定。

## 待確認假設彙總

| 來源 | 類型 | 契約錨點 | 波及 feature | 假設 / 決定 | 可逆性 | 閘門裁決 | 回寫位置 |
|---|---|---|---|---|---|---|---|
| F001 不可逆-2 | 不可逆決定 | 契約 A 的 `runService` | F001–F008 | 鎖的臨界區是**整個 `runService`**;否決「鎖在 `handleFor`」(只保護三件事裡的一件)與「各操作各自宣告」(漏包不會有編譯錯誤) | 難逆 | **接受,但要補一條防死鎖的 law** —— 巢狀 `runService` 會死鎖而 spec 原本沒有任何條文擋它,F002–F008 都會在 `ServiceM` 裡組合別的操作 | F001 spec 新增一條 law + example(定向重跑) |
| F001 不可逆-1 | 不可逆決定 | 契約 A 的 `Env` / `ServiceM` | F001–F008 | 兩者都不透明,建構子與欄位不匯出 | 難逆 | 接受 | 不回寫(spec 原文已載明) |
| F001 不可逆-3 | 不可逆決定 | 契約 F 的 `errorCode` | F001–F008 + shell | `code` 由建構子名的 snake_case **規則**產生,不是人工對照表 | 難逆 | 接受 | 不回寫 |
| F001 不可逆-4 | 不可逆決定 | 契約 F 的 `renderServiceError` | F001–F008 + shell | 訊息逐字委派下層 `render*`,本層不加前綴 | 可逆 | 接受(已知代價:ASM-1 裁決後 `RegistryUnavailable` 與 `RegistryLoadFailed` 對同一酬載渲染成相同文字,EX-23 明文驗) | 不回寫 |
| F001 不可逆-5 | 不可逆決定 | 模組間公開介面的 `handleFor` | F001–F008 | handle 快取的鍵是 marker 的 `VaultId`,不是路徑 | 難逆 | **未上裁決議程** —— ADR-017 已定「vault 的身分就是 marker 裡的 id」,替代方案沒有選擇餘地,依 `/subsys-build` 3c(2) 的規則不佔議程,只呈報 | 不回寫 |
| F001 依賴邊-1 | 新增依賴邊 | `aapms-service` → `aapms-types` | F001–F008 | 契約 A 要求 `openEnv` 載入型別註冊表,而 `loadRegistry` 住在 `aapms-types`;`design.md:28` 的相依行漏列 | 可逆 | **納進 `design.md` 的宣告** | `design.md:28`(diff 已呈報) |
| F001 ASM-1 | 待確認假設 | 契約 F 的 `RegistryUnavailable` / `RegistryLoadFailed` | F001 + shell | 兩個建構子都收 `RegistryError`。**`LoadError` 這個型別在整棵樹上不存在**(編排者掃過 core/types/md/store/workspace 五個套件,零命中),`loadRegistry` 回單一個 `RegistryError` 不是清單 —— 這一格無論如何都得改 | 可逆(shell 接上前) | 接受暫採 a | `design.md` 契約 F(diff 已呈報) |
| F001 ASM-2 | 待確認假設 | 「模組間公開介面」表(缺 `Machine / Read / Write → Monad` 那一列) | F001–F008 | 一組九個 `ServiceM` 動作(八個 `ask*` + `reloadHub`),`Env` 維持不透明 | 有條件可逆 | 接受暫採 a | `design.md`「模組間公開介面」新增一列(diff 已呈報) |
| F001 ASM-3 | 待確認假設 | 模組間公開介面的 `handleFor` + 契約 C 的 `viIssues` | F001, F002 | `handleFor` 簽名不動,另加 `indexIssuesFor :: VaultId -> ServiceM [IndexIssue]`;`Env` 多一格存第一次開啟的副產物 | 可逆 | 接受暫採 a | `design.md`「模組間公開介面」的 `Scope → Monad` 列(diff 已呈報) |
| F001 EX-28(WAVE-2 撞到) | spec bug | F001 的 EX-28 預期輸出欄 | F001–F008 | EX-28 把「`deriving` 起頭恰好 2 行」這個**會隨每一波成長的量**寫成定值(WAVE-1 三個檔的快照數),F002 的六個 View 型別加進來後變 8 行、測試轉紅。**LAW-25 這條 law 本身沒被違反** | 可逆 | **改成不隨波次成長的寫法** —— 只留 LAW-25 真正要求的三件事(instance 0 行、`StandaloneDeriving` 0 行、含 `Monad` 的 deriving 恰好 1 行且逐字相符) | F001 spec 的 EX-28 列 + 實作備註「修訂 REG-3」;`NestedRunServiceSpec.hs` 刪一行斷言。修完 **62/0 綠** |
| F002 ASM-2 | 待確認假設 | 契約 C 的 `workspaceSetup` / `SetupView.svHubCreated` + 契約 A 的 `openEnv` | F002 + shell | `workspaceSetup :: ServiceM SetupView` **在目前形狀下執行不到**:`openEnv` 對中樞不存在就回 `Left`,所以任何 `ServiceM` 動作跑得到時中樞必定已存在,`svHubCreated` 恒 `False`;而 `shell` 依 ADR-015 不能自己建中樞 → 「乾淨機器的第一次 setup」沒有人做得了 | 契約形狀變更 | **改成不需 `Env` 的頂層函式**:`Maybe Text -> FilePath -> IO (Either ServiceError SetupView)`,與 `openEnv` 同層 | `design.md` 契約 C(diff 已呈報) |
| F002 ASM-1 | 待確認假設 | 「內部模組劃分」表的 Types 列與 Machine 列 | F002–F008 | 六個 View 型別住 `Types.hs` 還是 `Machine.hs`:契約卡說負責模組是 Machine,模組劃分表說 View 型別歸 Types。**F003 的 `NodeView` 會撞到同一格** | 可逆 | **搬回 `Types.hs`**,`Machine.hs` 原地 re-export。契約卡的「負責模組」指誰實作操作,不是型別住哪 | `design.md` 內部模組劃分表 Types 列(diff 已呈報) |
| F002 ASM-3 | 待確認假設 | 契約 C 的 `vaultInit` / `VaultView`;workspace 契約 D 的 `AdoptNotice` | F002 + shell | `vaultInit` 丟棄 `AdoptNotice`(workspace 掃到的舊 `.assetdb/` / `.storyflow/` 標記,只報告不刪除),`VaultView` 六欄裝不下 | 可逆 | **改回 `ServiceM (VaultView, AdoptNotice)`** —— 丟棄等於 workspace 掃出來的東西在這一層被揉掉,而且沒有任何測試會因此紅(與 graph-core 的 GAP-2 / GAP-17 同一個形狀) | `design.md` 契約 C(diff 已呈報) |
| F002 ASM-4 | 待確認假設 | 契約 C 的 `vaultInfo` / `viCounts`;模組間公開介面的 `Scope → Monad` | F002 | `vaultInfo` 用的是 `--vault` 解出的讀取範圍而非自己的參數 → `--vault story vault info assets` **靜默**回 `viCounts == []` | 可逆(簽名不動) | **模組間公開介面表補 `Machine → Monad: handleFor`**,讓 `vaultInfo` 對自己的參數取 handle | `design.md`「模組間公開介面」新增一列(diff 已呈報) |
| F002 依賴邊-1 | 新增依賴邊 | `Machine → aapms-store`(查詢組,只讀) | F002 | 契約 C 的 `viCounts` 要開索引才算得出節點數,本機管線也寫著「需要節點數時才 `withRead` 開索引」,但表上只有 `Read / Write → aapms-store` | 可逆 | **納進 `design.md` 的宣告**(契約與管線自己就要求了,原表漏列) | `design.md`「模組間公開介面」新增一列(diff 已呈報) |
| F002 SELF-1(編排者升級) | 待確認假設 | 契約 C 的 `DoctorView.dvRegistry`;`design.md`「一律 re-export 不重新定義」 | F002 + shell | Machine 的 re-export 排除 `RegistrySource` —— **GHC 硬限制**:`Aapms.Workspace.Types.HubSource` 與 `Aapms.Types.Loader.RegistrySource` 各有一個 `FromEnv` 建構子,同模組匯出兩個是 conflicting exports | 難逆(動已交付契約) | **把衝突根除:上游改建構子名**。⚠️ 動的是 `aapms-workspace` / `aapms-types` 的已交付契約,`/subsys-build` 的邊界不委派 enhance → **另開文檔,不在本波**;F002 先照現況走(不 re-export),spec 記「待上游 enhance」 | **未回寫,待另開 enhance**(建議走 `/spec-design enhance`,改哪一邊由開發者定 scope) |
| F002 阻塞-1 | 阻塞項授權 | 契約 F 的 `ServiceError` 建構子 | F002 | `UnknownType Text` 不存在,驗收標準 7 / LAW-24 / EX-23 全擋住;**qa 的測試檔沒有它連編都編不過**。`Types.hs` 不在 F002 白名單 | 可逆 | **授權 F002 動 `Types.hs`**,限定只加 `UnknownType Text` 與它在 `errorCode` / `renderServiceError` 的兩個分支(契約卡本來就寫「Types(建立骨架,後續 feature 各自擴充建構子)」) | 不回寫(規格在 F002 spec 內) |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| F001 SELF-1 | `Env` 的鎖與快取用什麼具體 cell 型別 | `envLock :: MVar ()` + 三格 `IORef`;不用 `TVar`(`withMVar` 給例外安全的釋放,而鎖既然全程序列化,快取用 `IORef` 就夠) | `Env`、`envLock`、`envHubRef`、`envHandles`、`envIndexIssues`、`runService`、`closeEnv`、`handleFor`、`reloadHub`、`indexIssuesFor` | 自報 | 2026-08-30 編排者升級篩:**維持自裁**。`Monad.hs` 的匯出清單是 `Env`(不帶 `(..)`),建構子與欄位未外露,cell 型別在任何簽名上都看不到 |
| F001 SELF-2 | `ServiceM` 的包裝與實例 | `newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)`,`deriving newtype`,**建構子不匯出** | `ServiceM`、`runService`、`throwService`、`liftStore`、`liftWorkspace`、`MonadIO` | 自報 | 2026-08-30 編排者升級篩:**維持自裁**。疊法由 `design.md`「使用的技術」明文指定;匯出清單確認 `ServiceM` 不帶 `(..)`,建構子未外露 |
| F001 SELF-3 | handle 快取的鍵用 marker 的 `VaultId` 而不是路徑 | 用 `VaultId`(ADR-017 已定 vault 的身分就是 marker 裡的 id) | `envHandles`、`envIndexIssues`、`handleFor`、`VaultId`、`vmId`、`vrMarker` | 自報 | 2026-08-30:**維持自裁**,但同一個判斷在 spec 裡也寫成了「不可逆決定 #5」並經閘門呈報(不佔議程,理由見待確認假設彙總) |
| F001 SELF-4 | `Env` **不**存註冊表目錄路徑,只存 `RegistrySource` | 只存 `RegistrySource`(`DoctorView` 只有 `dvRegistry :: RegistrySource` 一欄,沒有路徑欄) | `Env`、`envRegistrySource`、`askRegistrySource`、`locateRegistry` | 自報 | 2026-08-30 編排者升級篩:`askRegistrySource` 命中 ASM-2 的存取器組,**已由 ASM-2 上閘門並裁決**,不重複列為升級 |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| F001 | **0**(qa 紅綠基線) | — | 「1-to-1 測試對照表」的紅綠預期欄 | **驗過,0 條「該紅卻綠」** | 在骨架快照 `fd65e0c` 的 worktree 上跑 qa 的 53 條:**50 紅 / 3 綠**。綠的恰好是 LAW-23 / EX-24 / EX-25(對 `service/src/` 原始碼文字的靜態斷言,依 `spec-roles.md` 交付判準第二列本來就該綠),其餘 50 條全部打到 `undefined`。**qa 自己跑出來的 53/53 全綠不算數** —— 它跑的時候 impl 已經併發填完本體,qa 如實回報了這件事、沒有為了湊綠動任何斷言 |
| F001 | 1 | (非紅燈:契約被悄悄擴大) | 無對應條文 —— spec 的資料流寫了「結束時(**含例外**)`closeVaultSet`」,卻沒給任何機制 | **spec bug** | impl 在 `Monad.hs:140` 自加 `deriving newtype instance MonadError ServiceError ServiceM` + `StandaloneDeriving` pragma,讓 `Scope.hs` 能用 mtl 的 `catchError` 寫收尾。**instance 全域可見、匯出清單藏不住**,等於給 F002–F008 與三個殼一條沒登記的公開 API,與不可逆決定 #1(`ServiceM` 不透明)衝突。**測試 53/53 全綠,一條都不會紅** —— 抓到它的是骨架快照比對,不是測試。2026-08-30 開發者裁決:**改成不暴露 instance 的收尾組合子**(Monad 匯出一個範圍受控的組合子,內部自己拆 newtype;`ServiceM` 對外仍只有 `Functor/Applicative/Monad/MonadIO`)。spec 定向修訂中,之後 impl 重跑一輪、qa 補新 law 的測試 |

## 階段結果

### 階段一閘門結果(2026-08-30)

**閘門結論:通過,就此停下**(開發者裁決,與 DEC-3 一致)。階段二 / 三的六個 feature 留待下一次
`/subsys-build service`(接續模式,從 WAVE-3 起)。

**完成**:`F001` / `F002` 兩份 `status: done`;**介面 49/49 已實作**,`service/src` 未實作標記清零。
`aapms-service` 從無到有:Laws 52 條、Examples 62 個、**測試 120 / 0**。

**測試**(編排者獨立重跑,非採信回報):`aapms-core` 224 / `aapms-types` 42 / `aapms-md` 327 /
`aapms-store` 294 / `aapms-workspace` 310(3 pending)/ `aapms-service` **120** /
`aapms-contract-rules` 6,合計 **1323 examples、0 failures**,零回歸。

**qa 紅綠基線**:三次快照驗證,**「該紅卻綠」與「該綠卻紅」皆 0**。
**白名單對帳**:三次全 OK,零違規、零新增未追蹤檔。

**契約裁決**:15 條經閘門逐條裁決(不可逆決定 5 / 新增依賴邊 2 / 契約假設 7 / 阻塞項授權 1),
**無「快速檔逕行採用」、無「空議程自動放行」**——嚴格檔的代價與收穫都兌現了。
**自裁 9 條**,編排者降級 0、升級 2;抽查 4 條**全部成立**。

**仲裁**:2 輪,歸因 **spec bug 3 / impl 錯 0 / qa 誤讀 0**。

**本階段最重要的發現:五條「測試永遠不會紅」的契約缺陷**,沒有一條是測試抓到的——

| | 缺陷 | 怎麼被發現的 |
|---|---|---|
| WAVE-1 | `ServiceM` 被加了未登記的 `MonadError` 實例(全域可見、匯出清單藏不住) | **骨架快照比對**(測試 53/53 全綠) |
| WAVE-2 | `workspaceSetup` 在 `ServiceM` 裡**執行不到**,`svHubCreated` 恒 `False`,「乾淨機器的第一次 setup」沒人做得了 | spec subagent 讀契約 A 時推出來的 |
| WAVE-2 | `vaultInit` 丟棄 `AdoptNotice`,workspace 掃出來的舊 marker 在這一層被揉掉 | 同上 |
| WAVE-2 | EX-10 的預期依賴「這台機器剛好沒裝 7-Zip」 | **qa 寫不出斷言而撞牆** |
| WAVE-2 | X19b 的預期依賴「只在資源生命週期第一次發生的事件」 | 同上 |

前三條是**契約被悄悄擴大或悄悄縮小**,後兩條是**驗收標準寫得出來但驗不到**(`contract-readiness.md`
的 ASM-9,與 graph-core 的 GAP-5 同一個根)。加上跨波次的那條(F001 的 EX-28 把會隨波次成長的量寫成定值),
**這一階段的六條缺陷全部落在契約邊界上,全部逃得過測試**。

**留給後續的四條**(不阻擋,已列進偏離清單):

1. **`RegistrySource` 的 `FromEnv` 撞名**:WAVE-2 的 SELF-1 裁決是「上游改建構子名」根除,但那動 `aapms-workspace`
   / `aapms-types` 的已交付契約,`/subsys-build` 不委派 enhance → **另開文檔**,scope 由開發者定。
   在那之前 F002 不 re-export `RegistrySource`,`shell` 要 `dvRegistry` 得自己 import `aapms-types`,
   而那條邊還沒進 `system.md` 的通訊拓撲
2. **知識圖含凍結舊碼的幽靈邊**:圖顯示 `shell → service` 30 條,全部來自 `api/src/Aapms/Api.hs`
   —— 但 `api/` 被 `cabal.project` 註解掉、編不過,那是 knot 從舊 `.hie` 快取抽到的。
   `legacy/service-and-interfaces`(112 節點)與 `legacy/assetdb`(122 節點)同樣在圖裡。
   **下一次 `/arch-audit system` 會據此判出不存在的跨子系統依賴** → 建議建圖時排除 `legacy/` 與凍結目錄
3. **graph-core 的三處 `IOException` 逸出**(`ensureDir` / `vaultMarkdownFiles` / `toVaultRelative`+`openVault`),
   2026-08-30 `/arch-audit subsys graph-core` 的發現 1,是否開 B003 待裁
4. **`Index.hs:146` 的 ADR-022 違反**(CJK 預切在 SQLite 交易內求值,且被一句錯的註解掩護),同上發現 2

### 階段一 骨幹

**WAVE-2 `workspace-facade`(F002):done**(2026-08-30)

- **介面 23/23 已實作**(6 個 View 型別 + `UnknownType` + 16 個 `Machine.hs` 函式,另有 10 項 re-export);Laws 27 條、Examples 30 個
- **測試**:`aapms-service-test` **120 examples / 0 failures**(F001 的 62 + F002 的 58)
- **qa 紅綠基線**(骨架快照 `dfd0b0e`,編排者實跑):120 條 → **54 紅 / 66 綠**。F002 的 58 條裡 54 紅、4 綠;4 綠**逐條驗證過身分**(單獨 `--match L26` 與 `--match L27` 各回 2/0),恰為骨架自身承載的兩組靜態斷言。**該紅卻綠 0、該綠卻紅 0**
- **白名單對帳**:OK,13 條路徑全部落在 impl 白名單 / qa 測試檔 / 編排者單線寫的檔案
- **仲裁**:1 輪。歸因分佈 **spec bug 2 / impl 錯 0 / qa 誤讀 0**,兩條都是 example 的預期依賴**環境或時序的偶然**:
  - **GAP-1 / EX-10**:假設「`[tools]` 未設 + `PATH` 清空」就會 `NotFound`,但 `detectSevenZip` 第三層查內建安裝路徑候選,裝了 7-Zip 的機器上永遠造不出來 → 裁決改成斷言「三層都試過」(`tsSearched` 非空)
  - **GAP-2 / X19b**:期待 `viIssues` 非空,但 `SchemaRebuilt` 只在索引檔生命週期第一次開啟時產生,而建索引的唯一合法路徑本身就是那第一次 → 裁決改成與 EX-18 同一判準、不強制非空
  - 這與 graph-core 的 **GAP-5**、`contract-readiness.md` 的 **ASM-9(可測性)** 是同一個根:**寫得出來但驗不到的驗收標準等於沒有**。教訓已寫進 F002 的實作備註
- **契約變更**:`design.md` 動五處 —— 契約 C 的 `workspaceSetup`(移出 `ServiceM`)與 `vaultInit`(加回傳值)、內部模組劃分 Types 列(全部 View 型別住這裡)、模組間公開介面表新增 `Machine → aapms-store` 與 `Machine → Monad`
- **未結項**:`RegistrySource` 的 `FromEnv` 撞名待上游 enhance(見待確認假設彙總 F002 SELF-1),F002 暫不 re-export 它

**WAVE-1 `service-env-and-scope`(F001):done**(2026-08-30)

- **介面 26/26 已實作**(Types 3 + Monad 20 + Scope 3);Laws 25 條、Examples 32 個
- **測試**:`aapms-service-test` **62 examples / 0 failures**(全新套件)。完整套件 core 224 / types 42 /
  md 327 / store 294 / workspace 310(3 pending)/ contract-rules 6,**全部 0 failures,零回歸**
- **qa 紅綠基線**(編排者在骨架快照上驗,兩輪各一次):
  - 輪 1 @ `fd65e0c`:53 條 → **50 紅 / 3 綠**,該紅卻綠 **0**
  - 輪 2 @ `eb73830`:62 條 → **14 紅 / 48 綠**,該紅卻綠 **0**。14 條紅全部可追到當時的兩個
    `undefined`(`finallyService`、`finallyCloseVaultSet`);綠的是 LAW-23 與 LAW-25 兩組靜態斷言
  - **兩輪的 qa 都是在 impl 已經併發填完之後才跑測試的**,自己看到的都是全綠;兩次都如實回報、
    沒有為了湊綠刪測試或放寬斷言。鑑別力是編排者在快照上補回來的
- **白名單對帳**:輪 1、輪 2 各跑一次(`git diff --name-only <快照>` + `git ls-files --others --exclude-standard`),
  **皆 OK**,每條路徑都落在 impl 白名單 / qa 測試檔 / 編排者單線寫的檔案
- **仲裁**:1 輪(上限 3)。歸因分佈 **spec bug 1 / impl 錯 0 / qa 誤讀 0**
- **契約變更**:`design.md` 動了四處 —— 相依行補 `aapms-types`、契約 F 的兩個 `RegistryError`、
  模組間公開介面表補 `indexIssuesFor` 與新增 `Machine / Read / Write → Monad` 一列(含 `finallyService`
  與「刻意不給 `MonadError` 實例」的理由)
- **本波最有價值的產出是兩條靜態 law**:**LAW-23** 擋巢狀 `runService` 死鎖、**LAW-25** 擋任何人再給
  `ServiceM` 加 instance。兩條都掃整個 `service/src/`,**F002–F008 每一波新增的模組自動落入**,
  不需要有人記得
