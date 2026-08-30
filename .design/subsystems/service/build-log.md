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
| 階段一 | W1 | service-env-and-scope | `19eaa88` | | in-progress |
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
| (W1 spec 尚未回報) | | | | | | | |

## 自裁清單

| 來源 | 判斷點 | 採取 | 觸及符號 | 出處 | 抽查 |
|---|---|---|---|---|---|
| (W1 spec 尚未回報) | | | | | |

## 仲裁紀錄

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| (尚未進入 qa / impl 階段) | | | | | |

## 階段結果

### 階段一 骨幹

(進行中)
