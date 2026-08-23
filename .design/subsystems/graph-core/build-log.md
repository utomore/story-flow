---
id: graph-core-build
type: build-log
title: graph-core-build
description: 依 Level 2 功能規劃委派展開 graph-core 的九個 feature(主架構 P1)
status: in-progress
created: 2026-08-23
updated: 2026-08-23
parent: graph-core
---

# graph-core 委派展開紀錄

## 排程

跨子系統依賴:無(地基)。知識圖對帳:圖建於 `8138707`、與 HEAD 差異只有 `codegraph.json`,視為新鮮;
圖顯示 graph-core 無跨界邊,是因為只有本子系統填了 `code-paths`——實際上 service / conflict / cli /
workshop / api / server 都 import 舊 `Aapms.Core.*` / `Aapms.Store.*`,處置見 D1。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 純層 | W1 | core-unified-meta | design-done |
| 階段一 純層 | W2 | registry-family-and-naming | design-done |
| 階段一 純層 | W3 | manifest-schema-v2 | pending |
| 階段二 解析與落地 | W4 | md-unified-sections ‖ store-vault-handle | pending |
| 階段二 解析與落地 | W5 | store-unified-index | pending |
| 階段三 檢索與寫入 | W6 | store-fts-dual-index ‖ store-write-operations | pending |
| 階段三 檢索與寫入 | W7 | store-multi-vault-read | pending |

## 委派決策記錄

(批次澄清 2026-08-23。契約類的答案已回寫 `design.md`:具名純量全部 newtype、`AiDisclosure` 四值、
`lookupRef` 加 `VaultId` 參數、`nfStatus = []` 排除 missing、`licenses.md` 檔案層是容器、reference 依路徑。)

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | core 型別一改,下游(service / conflict / llm / workshop / cli / api / server / mcp / contract)編不過,P0 契約測試(走 `aapms` 執行檔)跑不動 | **凍結下游**:這 9 個套件暫時從 `cabal.project` 拿掉,P1 只建 graph-core 四套件;契約測試到 P3 重建 service / shell 時回來,P1 以 graph-core 自己的 roundtrip / rebuild 等價測試當安全網。subagent 不碰 graph-core 以外的程式碼 | 全部 feature;由編排者在 W1 前改 `cabal.project` 並單獨 commit |
| D2 | 這次跑到第幾階段 | 三個階段全部,每階段閘門照停 | 排程 |
| D3 | 契約 E 引用但未定義形狀的 DTO(`NewEntity` / `NewLevel` / `NewPack` / `NewAsset` / `NewSection` / `MetaOverride` / `AssetPatch` / `CreateResult` / `WriteResult` / `DeleteResult` / `DeleteMode` / `IndexIssue` / `DanglingRef` / `LinkGraph` / `MetaWarning` / `TreeError`) | 現有的沿用並改接統一 `Meta`;新的由對應 feature 依契約卡文字定形狀、標為待確認假設;編排者在階段閘門把定稿回填契約 E | F001 / F004 / F005 / F006 / F008 / F009 |
| D4 | F007 驗收「6,783 筆 asset 的索引體積」沒有 fixture | **等 P2 真資料**,P1 不合成大 fixture;契約卡已改註。F004 的「1,693 節末尾追加」仍由測試內產生器合成(便宜) | F007(一條驗收標 pending)、F004 |
| D5 | `naming.toml` 初始詞彙與八種 asset 型別的 `name_kinds` 來源 | 從 `legacy/assetdb/core/src/AssetDB/Naming.hs` 的 `defaultVocab` 原樣落成 TOML,不增不減;`name_kinds` 依原 `AssetKind` 對應 | F002 |
| D6 | `core/` `md/` `store/` 現有單元測試的處置 | 隨模組重寫、舊的刪(ADR-018 第二條);各 feature 依自己的 1-to-1 測試表寫新 Spec,被取代的舊 Spec 刪掉,不留編不過的檔 | 全部 feature |
| D7 | F001 設計回報:契約 C 把 `TypeRegistry` 放 `aapms-types`,但 `checkMeta`(core)要吃它而 types 已依賴 core → 相依環 | **編排者裁決(未經開發者,閘門再確認)**:純型別 `Family` / `TypeDecl` / `TypeRegistry` / `NamingVocab` / `lookupType` 定義在 `aapms-core`,`aapms-types` 只有 `locateRegistry` / `loadRegistry` 與 TOML 解析並 re-export。與「內部模組劃分」表和現有程式碼一致,已回寫契約 C | F001 / F002 |

**澄清後仍懸著、交給 subagent 當待確認假設的點**(開發者已知):

- marker 目錄:契約卡寫 `.aapms/`,`system.md` 進度註記說 `.storyflow/` 留到 P3 改——D1 凍結下游後 CLI 不跑,store 直接寫 `.aapms/`,P3 的 workspace / shell 接新名
- 現有 `.storyflow/config.toml` 裡的 LLM 設定(`model` / `api_key` …)不在新 marker 的四個欄位裡;歸 P5 `ai` 決定去處,graph-core 不搬
- `metaTimeline :: Maybe Timeline`(契約)取代現有 `Timeline` + `emptyTimeline` 哨兵——契約為準
- `TooManyVaults` 門檻:SQLite 允許 main + 10 attached,契約卡寫「第 11 個 vault 回錯並列出 10」——以契約卡為準(10 個 vault),subagent 記假設
- 單一 vault 內 `assets.name` 重複如何落 `IndexIssue`(哪一筆保留 name)——F006 決定並記假設

## 配號表

(features/ 為空,依功能規劃順序預先配滿九個號;平行執行不得自行配號;委派模型固定 `sonnet`)

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| core-unified-meta | F001 | F001-core-unified-meta.md | sonnet | sonnet | design-done |
| registry-family-and-naming | F002 | F002-registry-family-and-naming.md | sonnet | sonnet | design-done |
| manifest-schema-v2 | F003 | F003-manifest-schema-v2.md | sonnet | sonnet | pending |
| md-unified-sections | F004 | F004-md-unified-sections.md | sonnet | sonnet | pending |
| store-vault-handle | F005 | F005-store-vault-handle.md | sonnet | sonnet | pending |
| store-unified-index | F006 | F006-store-unified-index.md | sonnet | sonnet | pending |
| store-fts-dual-index | F007 | F007-store-fts-dual-index.md | sonnet | sonnet | pending |
| store-write-operations | F008 | F008-store-write-operations.md | sonnet | sonnet | pending |
| store-multi-vault-read | F009 | F009-store-multi-vault-read.md | sonnet | sonnet | pending |

模型欄是閘門的診斷依據:委派模型固定 `sonnet`,所以品質有問題時歸因得回契約卡寫得夠不夠,不會混進模型差異。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | `MetaWarning` 建構子清單(`MissingRequiredField` / `LinkNotAllowed` / `UnknownNodeType` / `NameKindNotAllowed`)依 F002 契約卡驗收文字反推 | 先定最小形狀,`checkMeta` 由 F002 實作 | 待閘門 |
| F001 A2 | 舊 `Aapms.Core.Graph` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 不在契約 B | 只留 `LinkGraph` 型別,四個函式與 GraphSpec 刪除;P5 conflict 若要再回契約 B 補 | 待閘門 |
| F001 A3 | `CabalSpec` 禁用清單 | 逐字抄「使用的技術」節 8 個套件名,不推理分類 | 待閘門 |
| F002 A1 **(要裁決)** | 契約 B 的 `parseLogicalName :: Text -> Either NameError NameParts` 沒有 `NamingVocab` 參數;契約 C 的 `NamingVocab {nvKinds, nvDomains}` 與 legacy `defaultVocab {nvStates, nvVariants}`(**編排者已回原始碼確認** legacy/assetdb/core/src/AssetDB/Naming.hs:209)是不同的兩組欄位,legacy「用 state/variant 詞彙從右往左剝」在新簽名下做不出來 | 改純位置式解析,`npVariant` / `npState` 併成 `npModifiers :: [Segment]`;逐案代 `contract/fixtures/naming-cases.txt` 13 案全過(含 legacy 演算法反而誤拒的 `spr_char_hero_attack-01_up`) | 待閘門 |
| F002 A2 | `validateLogicalName` 收 `TypeKey` 但不用它做型別專屬過濾 | 型別專屬的 `name_kinds` 檢查留在 `checkMeta`(只警告) | 待閘門 |
| F002 A3 | `asset-archive` 依 D5 對照表算出 `tdNameKinds` 剛好是空清單(legacy `KindPrefix` 無值對應 `KArchive`) | 比照 `allowed_links` 空清單慣例,視為「未宣告限制」 | 待閘門 |
| 編排者(D5 前提修正) | D5 說「`naming.toml` 的 kinds / domains 從 `defaultVocab` 原樣落成」,但 `defaultVocab` 實際上是 states / variants,沒有 kinds / domains | kinds 由 legacy `KindPrefix` 列舉推出、domains 由 legacy 說明中的開放詞彙處理;與 A1 同一個根,閘門一起裁決 | 待閘門 |

## 階段結果

### 階段一 純層

(未開始)

### 階段二 解析與落地

(未開始)

### 階段三 檢索與寫入

(未開始)
