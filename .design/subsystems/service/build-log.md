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
| 階段一 | W1 | service-env-and-scope | (3d 委派 qa/impl 前填) | | spec 委派中 |
| 階段一 | W2 | workspace-facade | | | 未開始 |
| 階段二 | W3–W6 | node-read / node-write / asset-naming / level-and-node | | | 本次不跑 |
| 階段三 | W7 | search-facade ∥ index-ops | | | 本次不跑 |

**波次怎麼切的**:依「功能規劃」的「依賴」欄拓撲排序。`#2 workspace-facade` 依賴 `#1`,所以
不同波。階段二的 `#5 asset-naming` 與 `#6 level-and-node` 彼此不依賴、理論上同波,但兩者的
負責模組都含 **Write**,骨架檔案會重疊,依 `/subsys-build` 步驟 1 第 5 點拆成 W5 / W6。

**跨子系統依賴**:`graph-core`(9/9 features done)與 `workspace`(6/6 done)都已完成,沒有
「要等還是照介面約定先做」的問題。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | `aapms-service.cabal` 與 `cabal.project` 誰維護 | **編排者單線維護**,不屬任何 feature 的寫入白名單(沿用 workspace 的 D2、graph-core E001 的教訓) | 全部 8 個 feature |
| D2 | 舊 `service-and-interfaces` 的 3266 行程式碼怎麼處置 | **搬去 `legacy/service-and-interfaces/`** 當移植參考,附 README 寫明新設計已否決它的哪些核心選擇;不刪除 | W1(骨架路徑撞名的來源) |
| D3 | 這次跑到第幾階段 | **只跑階段一**(W1 + W2)。地基的契約如果在實作上站不住,現在發現比跑完八個再發現便宜一個數量級 | 全部 |
| D4 | **閘門密度** | **嚴格** —— 每一波的 spec 批准閘門都停,議程空著也停。理由:第一次展開這個子系統,契約卡從未經過實作檢驗 | 全部 |
| D5 | 本套件設不設門面模組(`Aapms.Service`) | **不設**,模組全部 exposed,界線由 `exposed-modules` 守。依據:`design.md`「內部模組劃分」列的七個模組裡沒有門面,而 workspace 與 graph-core E001 之後都是這個形狀。(legacy 有 `Aapms.Service` 門面,不沿用) | 全部 |
| D6 | `service/test/Spec.hs` 的維護 | **手寫彙總器,編排者建檔**,qa 每波自己把 `describe` 加進去並在回報列出要加進 `.cabal` `other-modules` 的模組名。理由:graph-core E001 踩過「新模組沒接進 `Spec.hs` 就整批不執行,而輸出看起來全綠」 | 全部 |

## 配號表

| feature | id | 檔名 | 骨架檔案 | spec 模型 | qa 模型 | impl 模型 | 狀態 |
|---|---|---|---|---|---|---|---|
| service-env-and-scope | F001 | F001-service-env-and-scope.md | `service/src/Aapms/Service/Types.hs`、`service/src/Aapms/Service/Monad.hs`、`service/src/Aapms/Service/Scope.hs` | opus | sonnet | sonnet | spec 委派中 |
| workspace-facade | F002 | F002-workspace-facade.md | `service/src/Aapms/Service/Machine.hs` | opus | sonnet | sonnet | 未開始 |

**骨架檔案不重疊**:W1 與 W2 各自一波,不平行,但仍逐波指派 —— `Types.hs` 由 F001 建骨架,
F002 起「各自擴充建構子」的部分屬後續波次,由編排者在該波的白名單裡明確授權,不由 subagent
自行認定。

## 待確認假設彙總

| 來源 | 類型 | 契約錨點 | 波及 feature | 假設 / 決定 | 可逆性 | 閘門裁決 | 回寫位置 |
|---|---|---|---|---|---|---|---|
| F001 不可逆-2 | 不可逆決定 | 契約 A 的 `runService` | F001–F008 | 鎖的臨界區是**整個 `runService`**;否決「鎖在 `handleFor`」(只保護三件事裡的一件)與「各操作各自宣告」(漏包不會有編譯錯誤) | 難逆 | **接受,但要補一條防死鎖的 law** —— 巢狀 `runService` 會死鎖而 spec 原本沒有任何條文擋它,F002–F008 都會在 `ServiceM` 裡組合別的操作 | F001 spec 新增一條 law + example(定向重跑) |
| F001 不可逆-1 | 不可逆決定 | 契約 A 的 `Env` / `ServiceM` | F001–F008 | 兩者都不透明,建構子與欄位不匯出 | 難逆 | 接受 | 不回寫(spec 原文已載明) |
| F001 不可逆-3 | 不可逆決定 | 契約 F 的 `errorCode` | F001–F008 + shell | `code` 由建構子名的 snake_case **規則**產生,不是人工對照表 | 難逆 | 接受 | 不回寫 |
| F001 不可逆-4 | 不可逆決定 | 契約 F 的 `renderServiceError` | F001–F008 + shell | 訊息逐字委派下層 `render*`,本層不加前綴 | 可逆 | 接受(已知代價:A1 裁決後 `RegistryUnavailable` 與 `RegistryLoadFailed` 對同一酬載渲染成相同文字,X23 明文驗) | 不回寫 |
| F001 不可逆-5 | 不可逆決定 | 模組間公開介面的 `handleFor` | F001–F008 | handle 快取的鍵是 marker 的 `VaultId`,不是路徑 | 難逆 | **未上裁決議程** —— ADR-017 已定「vault 的身分就是 marker 裡的 id」,替代方案沒有選擇餘地,依 `/subsys-build` 3c(2) 的規則不佔議程,只呈報 | 不回寫 |
| F001 依賴邊-1 | 新增依賴邊 | `aapms-service` → `aapms-types` | F001–F008 | 契約 A 要求 `openEnv` 載入型別註冊表,而 `loadRegistry` 住在 `aapms-types`;`design.md:28` 的相依行漏列 | 可逆 | **納進 `design.md` 的宣告** | `design.md:28`(diff 已呈報) |
| F001 A1 | 待確認假設 | 契約 F 的 `RegistryUnavailable` / `RegistryLoadFailed` | F001 + shell | 兩個建構子都收 `RegistryError`。**`LoadError` 這個型別在整棵樹上不存在**(編排者掃過 core/types/md/store/workspace 五個套件,零命中),`loadRegistry` 回單一個 `RegistryError` 不是清單 —— 這一格無論如何都得改 | 可逆(shell 接上前) | 接受暫採 a | `design.md` 契約 F(diff 已呈報) |
| F001 A2 | 待確認假設 | 「模組間公開介面」表(缺 `Machine / Read / Write → Monad` 那一列) | F001–F008 | 一組九個 `ServiceM` 動作(八個 `ask*` + `reloadHub`),`Env` 維持不透明 | 有條件可逆 | 接受暫採 a | `design.md`「模組間公開介面」新增一列(diff 已呈報) |
| F001 A3 | 待確認假設 | 模組間公開介面的 `handleFor` + 契約 C 的 `viIssues` | F001, F002 | `handleFor` 簽名不動,另加 `indexIssuesFor :: VaultId -> ServiceM [IndexIssue]`;`Env` 多一格存第一次開啟的副產物 | 可逆 | 接受暫採 a | `design.md`「模組間公開介面」的 `Scope → Monad` 列(diff 已呈報) |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| F001 S1 | `Env` 的鎖與快取用什麼具體 cell 型別 | `envLock :: MVar ()` + 三格 `IORef`;不用 `TVar`(`withMVar` 給例外安全的釋放,而鎖既然全程序列化,快取用 `IORef` 就夠) | `Env`、`envLock`、`envHubRef`、`envHandles`、`envIndexIssues`、`runService`、`closeEnv`、`handleFor`、`reloadHub`、`indexIssuesFor` | 自報 | 2026-08-30 編排者升級篩:**維持自裁**。`Monad.hs` 的匯出清單是 `Env`(不帶 `(..)`),建構子與欄位未外露,cell 型別在任何簽名上都看不到 |
| F001 S2 | `ServiceM` 的包裝與實例 | `newtype ServiceM a = ServiceM (ReaderT Env (ExceptT ServiceError IO) a)`,`deriving newtype`,**建構子不匯出** | `ServiceM`、`runService`、`throwService`、`liftStore`、`liftWorkspace`、`MonadIO` | 自報 | 2026-08-30 編排者升級篩:**維持自裁**。疊法由 `design.md`「使用的技術」明文指定;匯出清單確認 `ServiceM` 不帶 `(..)`,建構子未外露 |
| F001 S3 | handle 快取的鍵用 marker 的 `VaultId` 而不是路徑 | 用 `VaultId`(ADR-017 已定 vault 的身分就是 marker 裡的 id) | `envHandles`、`envIndexIssues`、`handleFor`、`VaultId`、`vmId`、`vrMarker` | 自報 | 2026-08-30:**維持自裁**,但同一個判斷在 spec 裡也寫成了「不可逆決定 #5」並經閘門呈報(不佔議程,理由見待確認假設彙總) |
| F001 S4 | `Env` **不**存註冊表目錄路徑,只存 `RegistrySource` | 只存 `RegistrySource`(`DoctorView` 只有 `dvRegistry :: RegistrySource` 一欄,沒有路徑欄) | `Env`、`envRegistrySource`、`askRegistrySource`、`locateRegistry` | 自報 | 2026-08-30 編排者升級篩:`askRegistrySource` 命中 A2 的存取器組,**已由 A2 上閘門並裁決**,不重複列為升級 |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| (尚未進入 qa / impl 階段) | | | | | |

## 階段結果

### 階段一 骨幹

(進行中)
