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
| 階段一 純層 | W1 | core-unified-meta | impl-done |
| 階段一 純層 | W2 | registry-family-and-naming | impl-done |
| 階段一 純層 | W3 | manifest-schema-v2 | impl-done |
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
| core-unified-meta | F001 | F001-core-unified-meta.md | sonnet | sonnet | impl-done |
| registry-family-and-naming | F002 | F002-registry-family-and-naming.md | sonnet | sonnet | impl-done |
| manifest-schema-v2 | F003 | F003-manifest-schema-v2.md | sonnet | sonnet | impl-done |
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
| F001 A1 | `MetaWarning` 建構子清單(`MissingRequiredField` / `LinkNotAllowed` / `UnknownNodeType` / `NameKindNotAllowed`)依 F002 契約卡驗收文字反推 | 先定最小形狀,`checkMeta` 由 F002 實作 | 接受 |
| F001 A2 | 舊 `Aapms.Core.Graph` 的 `buildGraph` / `follow` / `supersededSet` / `contradictionPairs` 不在契約 B | 只留 `LinkGraph` 型別,四個函式與 GraphSpec 刪除;P5 conflict 若要再回契約 B 補 | 接受 |
| F001 A3 | `CabalSpec` 禁用清單 | 逐字抄「使用的技術」節 8 個套件名,不推理分類 | 接受 |
| F002 A1 **(已推翻)** | 契約 B 的 `parseLogicalName :: Text -> Either NameError NameParts` 沒有 `NamingVocab` 參數;契約 C 的 `NamingVocab {nvKinds, nvDomains}` 與 legacy `defaultVocab {nvStates, nvVariants}`(**編排者已回原始碼確認** legacy/assetdb/core/src/AssetDB/Naming.hs:209)是不同的兩組欄位,legacy「用 state/variant 詞彙從右往左剝」在新簽名下做不出來 | 改純位置式解析,`npVariant` / `npState` 併成 `npModifiers :: [Segment]`;逐案代 `contract/fixtures/naming-cases.txt` 13 案全過(含 legacy 演算法反而誤拒的 `spr_char_hero_attack-01_up`) | **要改**:開發者裁定需要語意區分,契約 B 已改成帶 `NamingVocab`,F002 設計與實作各重跑一輪(`ee7d091`) |
| F002 A2 | `validateLogicalName` 收 `TypeKey` 但不用它做型別專屬過濾 | 型別專屬的 `name_kinds` 檢查留在 `checkMeta`(只警告) | 接受 |
| F002 A3 | `asset-archive` 依 D5 對照表算出 `tdNameKinds` 剛好是空清單(legacy `KindPrefix` 無值對應 `KArchive`) | 比照 `allowed_links` 空清單慣例,視為「未宣告限制」 | 接受 |
| F003 A1 | `imageMeta` / `audioMeta` 簽名由 `ManifestAsset -> Maybe X` 改 `Value -> Maybe X` | 當通用函式(同時吃 `ManifestAsset.meta` 與 `Asset.astKindMeta`),歸 F003 | 接受 |
| F003 A2 **(已推翻)** | `ManifestAsset.pack` / `license` 用 `Maybe Id`(同 vault 短 id)而非 `Maybe Ref` | 專案產出後素材已複製進專案,pack / license 必同 vault | **要改**:改成 `Maybe Ref`;二輪再補正頂層清單的 id 也 vault 化(`da5b51a`) |
| F003 A3 **(影響 JSON 形狀)** | `Manifest` 頂層補 `packs` / `licenses` 去重清單(契約卡未提) | 依 system.md「專案目錄」的授權描述與舊版慣例補上 | 接受 |
| F003 A4 | `StoryManifest` 給獨立 `schemaVersion` 與版本拒絕邏輯(schema 1 時代此檔不存在) | 先給,與 assets manifest 對稱 | 接受 |
| 編排者(D5 前提修正) | D5 說「`naming.toml` 的 kinds / domains 從 `defaultVocab` 原樣落成」,但 `defaultVocab` 實際上是 states / variants,沒有 kinds / domains | kinds 由 legacy `KindPrefix` 列舉推出、domains 由 legacy 說明中的開放詞彙處理;與 A1 同一個根,閘門一起裁決 | 接受(隨 A1 一併重做,states 詞彙落成 naming.toml 37 詞) |

## 階段結果

### 階段一 純層

**完成**:F001 / F002 / F003 三個 feature 全部 `status: done`,Todo 41/41(18 + 14 + 9)。
commit:`d5a9564`(F001)、`25de0e8`(F002)、`1a7c934`(F003),設計三筆在 `6a0c54b` / `b827bd1` / `2cc2076`。

**測試**(編排者獨立重跑,非採信回報):`cabal test aapms-core` **216 examples / 0 failures**、
`cabal test aapms-types` **41 / 0**。每個 feature 都沒有打破前一個的測試(150 → 197 → 216)。

**arch-audit subsys graph-core 發現**:

1. (中)`cabal build all` 目前**紅**:`md/` 與 `store/` 仍在 `cabal.project` 內,`Aapms.Md.Inherit`
   有 12 處 `Meta` 欄位型別不符。這是 D1 凍結範圍外的預期後果(F004 接手),但代表**階段一結束時
   全樹不是可建置狀態**,與 system.md「每期結束都是可建置狀態」的措辭有出入(P1 尚未結束,
   屬期中狀態)
2. (中)P0 契約測試(ADR-018 的安全網)在 D1 凍結期間**完全不跑**——CLI 信封、索引等價、
   OpenAPI golden 到 P3 才會回來。P1 期間唯一的網是 graph-core 自己的 257 個測試
3. (低)`design.md` 契約 C 的標題仍是「註冊表(`aapms-types`)」,但依 D7 型別已歸 `aapms-core`
   (段落內文已註明)。建議閘門後把標題改成「註冊表(型別在 `aapms-core`,載入在 `aapms-types`)」
4. (低)F001 在 `CabalSpec` 立了「`Aapms.Core.Registry` 不得存在」的斷言,F002 依契約 C 正當地
   重建該模組並改掉斷言。兩個 feature 的契約卡都沒預告這件事,屬契約卡顆粒度問題,不是缺陷

**契約符合度對帳**:契約 A 的 `Meta` 十四欄、五個 newtype 純量、`AiDisclosure` 四值、
`Asset` / `Pack` / `License` 欄位,與契約 B / C 的 14 條函式簽名**逐條與 design.md 相符**,無漂移;
`aapms-core` 的 `build-depends` 維持 `aeson / base / bytestring / containers / text / time`,零 IO 相依。

**程式碼知識圖**:未更新——`knot extract` 需要 `cabal build all` 成功,目前紅(見發現 1)。
`codegraph.json` 仍停在 `8138707`,**描述的是改名後、重建前的程式碼**,本次閘門未採信它的任何結論。

**閘門結論**(2026-08-23,開發者裁決):**通過,兩條假設被推翻並已重工完成**。

- 11 條待確認假設:9 條接受、2 條推翻(F002 A1、F003 A2),見上方彙總表
- 開發者另給出一條長期適用的方針:**重構不必遷就 legacy 的舊格式與舊資料**,素材原始檔可以全部重新
  下載,設計自由度大。因此 F002 沒有「還原 legacy 的兩張詞彙表」,而是設計成只查一張 `nvStates`
  ——變體天生開放,封閉清單列不完(這正是 legacy 會誤拒 `spr_char_hero_attack-01_up` 的原因)
- 重工結果:`ee7d091`(F002 命名文法)、`da5b51a`(F003 manifest 引用 vault 化 + 契約回填)
- **重工後測試**(編排者獨立重跑):`cabal test aapms-core` **224 examples / 0 failures**、
  `cabal test aapms-types` **42 / 0**;`contract/fixtures/naming-cases.txt` 13 案例全過
- 發現 3(契約 C 標題)已隨回填一併處理;發現 1、2 是 D1 的已知代價,F004 完成後 `cabal build all`
  有機會回綠,屆時才能重建程式碼知識圖
- 遺留的小不一致(不阻塞,留給 P6 `project` 消費時再看):manifest 裡節點**自身身分**有兩種寫法
  ——asset 是 `"id": "ast-…"` + 並列的 `"vault"` 欄位,pack / license 是 `"id": "<vault>:<id>"`。
  引用圖本身已一致,這只是身分欄位的表達不對稱

**F002 / F003 重工後的假設**(新增,下個閘門一併看):F002 A4(`spr_char_up` 這種 subject 本身是
state 詞時,剝除要有「不剝到清空」的 guard)、A5(round trip 只保證 `parse → render` 方向)、
A6(`checkMeta` 無 `NamingVocab` 參數,`badNameKind` 直接切第一段文字取 kind)。

### 階段二 解析與落地

(未開始)

### 階段三 檢索與寫入

(未開始)
