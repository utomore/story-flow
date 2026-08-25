---
id: graph-core-build
type: build-log
title: graph-core-build
description: 依 Level 2 功能規劃委派展開 graph-core 的九個 feature(主架構 P1)
status: in-progress
created: 2026-08-23
updated: 2026-08-25
parent: graph-core
---

# graph-core 委派展開紀錄

## 排程

跨子系統依賴:無(地基)。知識圖:F005 完成後 `cabal build all` 回綠,已於 `b44f2aa` 重建(2311 nodes、9579 edges),取代原本停在 `8138707` 的舊圖;
圖顯示 graph-core 無跨界邊,是因為只有本子系統填了 `code-paths`——實際上 service / conflict / cli /
workshop / api / server 都 import 舊 `Aapms.Core.*` / `Aapms.Store.*`,處置見 D1。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一 純層 | W1 | core-unified-meta | impl-done |
| 階段一 純層 | W2 | registry-family-and-naming | impl-done |
| 階段一 純層 | W3 | manifest-schema-v2 | impl-done |
| 階段二 解析與落地 | W4 | md-unified-sections ‖ store-vault-handle | impl-done |
| 階段二 解析與落地 | W5 | store-unified-index | impl-done |
| 階段三 檢索與寫入 | W6 | store-fts-dual-index ‖ store-write-operations | **impl-done**(F007 / F008;F004 因 A5 與 G17 兩度重開,亦已 done)|
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
| D8 | F005 設計回報:`aapms-store` 的 12 個模組裡有 7 個(`Create` / `Edit` / `Index` / `Node` / `Query` / `Row` / `Write`)已編不過(import 已刪的 `Aapms.Core.Graph`、已改名的 `mkId`、已換 API 的 `validateRegistry`),它們分屬 F006 / F008 / F009,F005 卻因此拿不到綠燈 | **編排者裁決**:`aapms-store` 以**模組為單位**逐步復原——F005 只把 `Marker` / `Atomic` / `Schema` / `Error` 留在 `.cabal` 的 `exposed-modules`,其餘 7 個**檔案留在磁碟當素材、暫時移出 cabal**,由 F006 / F008 / F009 各自改寫後加回。這是 D1(套件層凍結)的同一個作法降到模組層,ADR-018「重建核心,舊程式碼當素材搬」也是這個意思。**F005 不得移除 `aapms-md` 的 build-depends**——實作順序改成 F004 先跑,md 修好後 store 就有可用的相依 | F005 / F006 / F008 / F009 |
| D9 | F006 設計回報:`design.md` **自己前後矛盾**——資料流管線(第 340 行)與模組間公開介面(第 375 行)都寫索引時要跑 `checkMeta`,F006 契約卡也把「`checkMeta` 的警告進 `IndexIssue`」列為驗收,但契約 E 的 `rebuildIndex` / `refreshStale` / `indexFile` 簽名沒有 `TypeRegistry`,F005 交付的 `VaultHandle` 也沒帶 → 型別上叫不動。**編排者另查出 subagent 沒提到的一點**:契約 E 的 `openVault` 自己就要做過時刷新,它同樣需要註冊表,所以只補三個函式參數仍會漏 | **開發者裁決:A —— 註冊表放進 `VaultHandle`**,`openVault :: TypeRegistry -> FilePath -> IO ...`。理由:`openVault` 遲早要它,分次加簽名只會逐次長胖;註冊表載入失敗即程序失敗(契約 C),由 `openVault` 收下代表順序被型別釘死。已回寫契約 E。**F005 需小幅重工**(handle 加欄位、`openVault` 加參數、測試跟著改),F006 尚未實作故無浪費 | F005 / F006 / F007 / F008 / F009 |
| D10 | 階段三改用 0.8.7 的三角色流程(spec / qa / impl),qa 只讀 spec 寫測試且**不得自行引入相依**。專案目前只有 hspec,沒有 property-based 框架(`legacy/assetdb` 用過 QuickCheck) | **開發者裁決:引入 hedgehog**。四個 test-suite 加相依,law 寫成 property。不影響 production library 的零相依斷言(`boundary-rules.md`:測試不在依賴圖裡) | F007 / F008 / F009 的 qa |
| G1 | F004 實作時回報:契約 E 的 `NewSection` 只有 `nsMeta :: MetaOverride`,而 `MetaOverride` 沒有 asset 的 `sha256` / `entry` / … 也沒有 license 的八個維度 → `appendSection` / `addSection` 寫不出能通過 `toPack` / `toLicenses` 驗證的完整新節,擋住 F008 的驗收 | **開發者裁決:A —— `NewSection` 改成對節點種類做 sum**(`NewSectionPayload` = `NSFragment` / `NSAsset` / `NSLicense` / `NSNode`,封閉建構子),`addSection` 維持單一入口。與契約 A 的 `AnyNode` / `LinkKind` 同模式。**不採**塞進 `MetaOverride`——那是 md 與 store 共用的節層繼承 DTO,污染它會動到 ADR-010 的前提。已回寫契約 D | F004(既有 `NewSection` 要改)/ F008 |
| D7 | F001 設計回報:契約 C 把 `TypeRegistry` 放 `aapms-types`,但 `checkMeta`(core)要吃它而 types 已依賴 core → 相依環 | **編排者裁決(未經開發者,閘門再確認)**:純型別 `Family` / `TypeDecl` / `TypeRegistry` / `NamingVocab` / `lookupType` 定義在 `aapms-core`,`aapms-types` 只有 `locateRegistry` / `loadRegistry` 與 TOML 解析並 re-export。與「內部模組劃分」表和現有程式碼一致,已回寫契約 C | F001 / F002 |
| D11 | F008 spec 查出:`service/src/Aapms/Service.hs:130` 有 `import Aapms.Store.Edit (Located (..), locate, locateNode)`,而 `locateNode` 不存在,且 `Edit` 是 F008 明訂的**內部模組** | `cabal.project` 目前把 `service/` 註解掉(D1 凍結),不影響 P1 建置。**記在這裡:P3 重建 `service` 時這一行要改成走 `Aapms.Store` 門面**,不得直接摸內部模組 | P3 `service` |
| D12 | 兩個 spec subagent 都回報 `codegraph.json` 過時:仍列出 `1f004f2` 已刪的 D8 遺留測試檔,`StoreError` 也還是 6 個建構子 | **委派 qa / impl 之前由編排者跑一次 `knot extract`**,否則 qa 的導航會查到不存在的測試檔。圖過期時任何基於它的結論不採信 | W6 qa / impl |

**澄清後仍懸著、交給 subagent 當待確認假設的點**(開發者已知):

- marker 目錄:契約卡寫 `.aapms/`,`system.md` 進度註記說 `.storyflow/` 留到 P3 改——D1 凍結下游後 CLI 不跑,store 直接寫 `.aapms/`,P3 的 workspace / shell 接新名
- 現有 `.storyflow/config.toml` 裡的 LLM 設定(`model` / `api_key` …)不在新 marker 的四個欄位裡;歸 P5 `ai` 決定去處,graph-core 不搬
- `metaTimeline :: Maybe Timeline`(契約)取代現有 `Timeline` + `emptyTimeline` 哨兵——契約為準
- `TooManyVaults` 門檻:SQLite 允許 main + 10 attached,契約卡寫「第 11 個 vault 回錯並列出 10」——以契約卡為準(10 個 vault),subagent 記假設
- 單一 vault 內 `assets.name` 重複如何落 `IndexIssue`(哪一筆保留 name)——F006 決定並記假設

## 配號表

(fan out 前預先分配;平行執行不得自行配號或自選骨架路徑。**骨架檔案**同一波內不得重疊;
**模型欄**固定 spec `opus`、qa 與 impl `sonnet`,品質有問題時歸因得回 spec 寫得夠不夠。

階段一、二在 0.8.6 舊流程下完成——當時沒有骨架與 qa/impl 分離,同一個 subagent 既寫實作也寫測試,
模型一律 `sonnet`。階段三起改用 0.8.7 的三角色流程。)

| feature | id | 檔名 | 骨架檔案 | spec 模型 | qa 模型 | impl 模型 | 狀態 |
|---|---|---|---|---|---|---|---|
| core-unified-meta | F001 | F001-core-unified-meta.md | (舊流程) | sonnet | — | sonnet | impl-done |
| registry-family-and-naming | F002 | F002-registry-family-and-naming.md | (舊流程) | sonnet | — | sonnet | impl-done |
| manifest-schema-v2 | F003 | F003-manifest-schema-v2.md | (舊流程) | sonnet | — | sonnet | impl-done |
| md-unified-sections | F004 | F004-md-unified-sections.md | md/src/Aapms/Md/{Render,Parse,Error}.hs | opus | sonnet | sonnet | **impl-done**(共三輪:G1+G2 修復 → A5 加 `insertSection` → G17 加檔案層 `FrontExtras`)|
| store-vault-handle | F005 | F005-store-vault-handle.md | (舊流程) | sonnet | — | sonnet | impl-done |
| store-unified-index | F006 | F006-store-unified-index.md | (舊流程) | sonnet | — | sonnet | impl-done |
| store-fts-dual-index | F007 | F007-store-fts-dual-index.md | store/src/Aapms/Store/Tokenize.hs(新)、Query.hs、Schema.hs | opus | sonnet | sonnet | impl-done |
| store-write-operations | F008 | F008-store-write-operations.md | store/src/Aapms/Store/Write.hs、Create.hs、Edit.hs、Node.hs、Error.hs、Store.hs | opus | sonnet | sonnet | **impl-done** |
| store-multi-vault-read | F009 | F009-store-multi-vault-read.md | store/src/Aapms/Store/MultiVault.hs(新) | opus | sonnet | sonnet | pending |

`aapms-store.cabal` 是 W6 兩個 feature 的共用檔(都要加模組),**由編排者單線改**,不讓平行的 spec
subagent 同時碰;骨架的整波編譯檢查也由編排者跑。

## 自裁清單

(spec subagent 判定為「實作層級」而自行決定、**不上閘門**的事;出處標「編排者降級」者是
subagent 原本要上閘門、經編排者重跑層級兩問後降下來的。供事後抽查:抽查發現裁錯層級
(其實動到了邊界),代表層級門檻要收緊。「抽查」欄留白 = 還沒查過。)

| 來源 | 判斷 | 抽查 |
|---|---|---|
| F004 S1 | `insertSection` 放在既有的 `Aapms.Md.Render`,不新開模組(`Aapms.Md` 以整模組 re-export,cabal 不用改) | |
| F004 S2 | 骨架本體寫成 point-free 的 `insertSection = undefined` | |
| F004 S3 | 「父節點的子樹」以 `secLevel` 前綴定義,不借用 `Aapms.Md.Parse.structure`(後者會造成 import 成環) | |
| F004 S4 | 多重錯誤同時成立時固定成「父節點不存在 → 撞號 → 層級」的檢查順序(釘死 qa 才寫得出斷言) | |
| F008 S1 | `renderStoreError` 的 15 個新建構子分支寫成 `Ctor _ -> undefined`,F005 已實作的 6 個分支原樣保留 | |
| F008 S2 | `WriteResult (..)` 由 `Aapms.Store.Write` re-export 隨門面出去(subagent 自答「邊界 會」,但契約 E 已寫 `… -> IO (Either StoreError WriteResult)`,門面缺它等於契約簽名寫不出來,屬契約遵循而非新決定) | |
| F008 S3 | `Node.hs` / `Create.hs` 的 `import Aapms.Store.Edit` 改成 `import Aapms.Store.Error`,`Node` 因此不再依賴 `Edit` | |
| F008 S4 | `Create.hs` 的 `NewSection` 家族區段用純 `--` 註解而非 haddock named chunk | |

## 仲裁紀錄

(每一輪紅燈的裁決;這張表是事後判斷「spec 哪裡寫不清楚」的唯一資料。同一 feature 上限 3 輪。
階段一、二在舊流程下沒有 qa/impl 分離,因此沒有仲裁紀錄。)

| feature | 輪次 | 失敗的測試 | 對應的 spec 條文 | 歸因 | 處置 |
|---|---|---|---|---|---|
| F007 | 1 | `SearchSpec.hs:163` E6:`shSnippet` 應含「藥水」,實得 `"魔法藥 水 瓶"` | E6 + A3 + L4 | **spec bug** | 停下,回報開發者。**編排者實測歸因**:`desegmentCjk(完整 cjkSegment 輸出)` 正確還原且 **L4 成立**;但 FTS5 的 `snippet()` 回的是**片段**(欄位的一段視窗),不是完整的 `cjkSegment t`——L4 對片段沒有定義任何行為,A3 卻要求把 `snippet()` 的輸出餵給它。impl 滿足了所有 law,qa 逐字轉錄 E6,兩邊都沒錯,是 spec 把函式用在定義域外 |
| F007 | 2 | (無新紅燈) | — | — | spec 修訂後重跑:**111 examples / 0 failures**。E6 由修正 spec(snippet 改取 `fts_tri` 原文)而非弱化斷言達成 |
| F004 | 1 | `L9` / `L10`(`renderMetaBlock` 行序列與行數) | L9 原文 | **qa 誤讀** | qa 自行歸因並修正:L9 原文明寫 `moLinks = Just (_:_)` 產生「`links:` 加每個關聯一行」,但 qa 的計數 helper 把每個有值欄位一律算 1 行,漏算這條例外。改 `fieldLineCount` 後兩條轉綠,其餘 283 個 example 未動 |
| F004 | 1(W6) | `InsertSectionSpec.hs:467` E13:1,693 節 Level 檔插入後 `buildTree` 回 `MultipleRoots` | E13 原文 | **qa 誤讀** | 斷言逐字轉錄 E13 沒錯,但 `synthLevelMd` 合成出 1,692 個同層 `##` 章節 = 1,692 個 root。`buildTree`(`core/src/Aapms/Core/Tree.hs:100-104`)明訂恰好一個 root(ADR-004 嚴格樹、契約 A 的 `lvlRoot` 單數、回傳單一 `NodeTree`),回 `MultipleRoots` 是正確行為。E13 的前提「合法 Level 檔」從未被滿足。退回 qa 改 fixture 成單根,三段斷言不得弱化 |
| F004 | 1(W6) | `RegressionLawsSpec.hs:236` L30:`metaTitle = "0o0"` 時 `decodeFrontmatter (renderFrontmatter m le) /= Right m` | L30 原文 | **impl 錯** | `looksNumeric`(`Render.hs:820-825`)的字元白名單 `+-.eExXaAbBcCdDfF_` 涵蓋 `0x` 十六進位卻漏 `0o` 八進位 → `"0o0"` 判定不需引號 → 寫成 `title: 0o0` → YAML 讀回是整數 0,往返失真。**編排者獨立重跑未重現**(hedgehog 隨機種子),但正因如此它是會隨機引爆的地雷,不是偶發雜訊。程式碼雖是前一輪交付,L30 是 F004 自己的 law 且 F004 現為 in-progress,故歸本輪範圍。退回 impl 補白名單 |
| F008 | 1(W6) | `NodeSpec2.hs:206` L23 合法 Level 檔;`CreateSpec.hs` E12/E13/E14 `addSection UnderParent` | L23 / L12b / E12-E14 原文 | **qa 誤讀** | fixture `node-spec2-fixture.md:34` 有 `HeadingSkip 3 6`,`toLevel` 正確拒絕 → 整檔沒進索引 → 父節點查無 → `NodeNotFound`。與 F004 的 E13 同一類(fixture 不是合法的 Level 檔)。**編排者歸因更正(qa 修復時挖出)**:這不是「四條同一個根」,底下其實有**三個獨立的 qa 側錯誤**——① fixture 跳級(最先擋住的那個);② `withE12Vault` 從未呼叫 `rebuildIndex`,`locate` 因此一律回 `NodeNotFound`;③ E12/E13/E14 把**節點自己的 id** 當成 `addSection` 的定位參數,但 spec 的 E12 寫的是 **Level 檔本身的 id**(`addSection vh lvl-1 …`),傳節的 id 正確觸發 `BadSectionPayload`。歸因**類別**正確(全屬 qa 側),但「同一個根」的判斷錯了:第一個錯誤遮住了後兩個 |
| F008 | 1(W6) | `WriteSpec.hs` L8 `upsertLicense`:UNIQUE constraint failed nodes.id | L8 原文 | **qa 誤讀** | impl 寫 `library/licenses.md`,**符合 `system.md:439` 的權威目錄配置**;qa 沿用 F006 fixture 放在 vault 根的 `licenses.md`,同一個 `lic-` id 落在兩個檔。**附帶發現**:F006 的 fixture 本身不符主架構目錄配置,已列入階段閘門的 arch-audit |
| F008 | 1(W6) | `CreateSpec.hs:272` L9 `createPackFile`:UNIQUE constraint failed nodes.id | L9 原文 | **qa 誤讀** | hedgehog 跨迭代重用同一批 `nsId` 寫進不同 pack 目錄;短 id 依 ADR-014 是 vault 內唯一,generator 必須每迭代給新 id。**附帶發現**:重複 id 目前回 `IndexUpdateFailed`(語意是「檔案已落地、索引需重建」),但這種狀態索引永遠接不了,錯誤型別選得不對——列入閘門建議 |
| F008 | 1(W6) | `CreateSpec.hs:313` L12a `addSection AtEnd`:期望 `
` 實得 `

` | L12a 原文 | **spec bug(G14)** | `blankTail` 補的空行。**與 F004 的 A10 同一個根**,開發者已裁決過一次:`blankTail` 冪等,只有插入點之前那一段尚未以空行結尾時才補齊。F004 契約卡已收窄,F008 的 L12a / L12b 沒有繼承。裁決:照 A10 措辭修 |
| F008 | 1(W6) | `NodeSpec2.hs` L20 `sanitizeFileName`(反例 `"<"`) | L20 vs E11 | **spec bug(G13)** | L20「t 被清空時等於 fb」與 E11 逐字例子「冒號替換成 `-`」互斥:替換策略下純非法字元輸入永遠非空。裁決:**保留替換與 E11**(逐字例子最難被誤讀),L20 的「清空」改成只指「去除頭尾空白與 `.` 後為空」 |
| F008 G17(impl) | — | 無測試失敗(**這正是問題**) | 無對應條文 | **spec bug** | `createPackFile` 把 `NewPack` 的七個 pack 專屬欄位一個都沒寫進檔案,重讀全解成 `Nothing`/`AiUnknown`,而 E3 只驗 `crPath` 與節順序 → **測試套件全綠但資料真的在遺失**。根因是 `aapms-md` **檔案層**沒有對稱節層 `MetaExtras` 的機制;**與 G2 是同一個病的檔案層鏡像**(G2 是節層,由 F004 重跑加 `MetaExtras` 修好)。依 ADR-013 `pack.md` 是素材中繼資料的真相,丟掉 vendor/license 等於丟掉「這批素材能不能商用」。**裁決:重新打開 F004 補檔案層 extras**,F008 補一條往返 law(在 F004 落地前會一直紅) |
| F009 A1 | `design.md` 與 ADR-017 第四條都寫「跨 vault 的排序、分頁、facet 在 SQL 層完成」,但 Query 的 `whereOf` / `baseFrom` 都不在匯出清單,`baseFrom` 也寫死不帶 schema 前綴 | 由編排者匯出並一般化 | **部分推翻(2026-08-26 開發者裁決)**:改**分案**——`listAcross` 走 SQL(與單 vault 的 `listNodes` 一致)、`searchAcross` 走 Haskell(與單 vault 的 `search` 一致)。**編排者另查出比回報更嚴重的事**:F007 的單 vault `search` 根本不在 SQL 排序(`sortHits:616` / `takePage:619` 都在 Haskell),ADR-017 第四條**早就與程式碼不符**。已修訂 ADR-017 並註明:原文之所以沒被發現不符,是因為它只對跨 vault 提要求,單 vault 的偏離沒有人擋 |
| F009 A2 | 契約 E 缺 `closeVaultSet` / `vaultSetIds` / `maxAttachedVaults` | 三條都補 | **接受**,已回寫契約 E |
| F009 A3 | `DanglingRef` 形狀未定義(D3 已記) | 四欄 + 封閉的 `DanglingReason` 兩值 | **接受**,已回寫契約 E |
| F009 A4 | `TooManyVaults` 要進 `StoreError`,但 `Error.hs` 不在骨架清單 | 由編排者加 | **接受**,改授權 spec 自己加(`TooManyVaults Int Int`),契約 G 已補形狀 |
| F009 A5 | `openVaultSet` 收到重複 `vmId` 的處置 | 一律保序去重、上限以去重後計 | **推翻(2026-08-26 開發者裁決)**:兩種成因必須分開——同一路徑傳兩次是無害疏忽 → 保序去重;**兩個不同路徑帶相同 `vmId`** 依 ADR-017 代表整個 vault 目錄被複製過,此時任何跨 vault `Ref` 解析都不確定 → 回 `VaultIdCollision` 並列出兩個路徑。靜默去重會把後者吞掉,症狀是「搜尋結果少了一個 vault 的東西」 |
| F009 A6 | 跨 vault 的 facet 語意 | 同值跨 vault 求和 | **接受**;實作走「逐 vault 呼叫公開 `search` 再在 Haskell 合併」,不重用私有的 `computeFacets`(它有裸表名) |
| F009(編排者發現) | spec 宣稱 reference 子查詢是 `whereOf` 裡**唯一**寫出裸表名的地方 —— 這句是錯的 | — | **編排者掃描更正**:還有 `tagClause` 的 `FROM node_tags`(`Query.hs:181`)。跨 vault 會查到 `main.node_tags`,即拿別的 vault 的標籤表篩本 vault 的節點,而單 vault 走 `whereOfIn ""` 行為不變 → **沒有任何測試會紅**。subagent 的判準(別名安全、裸表名危險)正確,但用讀的執行、漏了一處;改用 `grep -nE "FROM [A-Za-z_]+|JOIN [A-Za-z_]+"` 掃兩段,現在 0 筆。判準對而掃描不完整,結果與判準錯相同 |

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
| F008 A1 | 契約 E 的 `createPackFile` 第三參數 `[NewAsset]`,但 G1 之後 `NewAsset` 只剩專屬七欄,組不出節的標題與節層 meta | 改成 `[NewSection]`,payload 必須是 `NSAsset` | **接受**(契約 E 已於 `58972f9` 回寫) |
| F008 A2 | 骨架路徑清單不含 `Error.hs`,加不了建構子,故在 `Aapms.Store.Edit` 另立 `StoreWriteError`,以 `WriteStore StoreError` 為橋 | 十二條簽名一律回 `Either StoreWriteError a` | **推翻**(2026-08-25):契約 G 明文「`StoreError` 是唯一錯誤型別,不得另立平行的錯誤型別再橋接」。15 個建構子併進 `StoreError`,刪 `WriteStore` 與 `renderStoreWriteError` |
| F008 A3 | `allocateId` 契約簽名 `IO Id` 沒有失敗通道,但碰撞檢查要查索引 | 查詢失敗視同「查不到」並回傳當前候選 id | **推翻**(2026-08-25 開發者裁決):改 `IO (Either StoreError Id)`。理由:靜默照發會把未經碰撞檢查的 id 寫進 Markdown,而檔案是真相(ADR-013),事後只能以「rebuildIndex 撞主鍵」發現,修復要人工改 id 與所有指向它的關聯。已回寫契約 E |
| F008 A4 | `NewSection` / `NewSectionPayload` / `NewAsset` / `NewLicense` / `NewNode` 的永久歸屬是 `aapms-md`(契約 D),但 `md/` 不在骨架清單裡 | 暫時定義在 `Aapms.Store.Create` | **推翻**(2026-08-25):F004 的 G2 重跑已把這五個型別放進 `Aapms.Md.Render`,兩份定義逐欄相同。`Aapms.Store.Create` 刪本地定義改 re-export |
| F008 A5 | `addSection` 對 `LevelDoc` 只能追加在文件末尾(F004 已移除 `insertSection`),無法在中段父節點底下插入 | `nsLevel` 由呼叫端給,寫檔前以 `validateLevelDoc` 把關 | **推翻**(2026-08-25 開發者裁決):現在就補 `insertSection`。契約 D 加 `insertSection :: Id -> NewSection -> Document -> Either MdError Document`;契約 E 的 `addSection` 加 `SectionPlacement = AtEnd | UnderParent Id`,`UnderParent` 時 `nsLevel` 由既有的 `headingDepthFor` 推導(呼叫端自算等於父子關係有兩個真相來源)。**F004 因此重新打開** |
| F008 A6 | `Aapms.Store` 門面沒有 re-export 本 feature 的四個模組,而該檔不在骨架清單裡 | 不動它,qa / impl 直接 import 內部模組 | **接受並補上**(2026-08-25):門面不完整會逼 `service` 記得 import 內部模組,兩行的事 |
| F004 A8 | `insertSection` 的三條錯誤路徑沿用既有 `MdErrorKind` 建構子(委派指示只准改 `Render.hs`,加不了建構子)。代價:「`nsLevel` 不符」與「層級 > 6」共用 `HeadingSkip`,呼叫端分不開,且後者語意明顯不符(沒有東西被跳過) | 兩條都回 `HeadingSkip (secLevel 父) (nsLevel ns)` | **部分推翻**(2026-08-25 開發者裁決):**只為「層級 > 6」新增 `HeadingTooDeep`**。兩條路徑性質不同——`nsLevel` 不符在 `UnderParent` 下永遠不該發生(契約 E 明訂 `nsLevel` 由 `headingDepthFor` 推導),觸發即 store 有 bug,維持 `HeadingSkip`;「層級 > 6」是真實使用者情境(章節樹夠深就撞得到)且有明確的下一步可講,契約 G 要求每一則訊息說出下一步 |
| F004 A9 | `insertSection` 也檢查 `nsId` 撞號(契約 D 原文只約束 `nsLevel`) | 檢查,與 `appendSection` 一致 | **接受**(2026-08-25):前提成立——`allocateId` 查的是會過時的索引,這層檢查不冗餘 |
| F004 A10 | 插入「必然」動到兩段位元組(插入點前一節的正文尾端、新節自己的尾端),是 ADR-010 位元組保留的例外 | 寫死進 L33 / L34 | **接受但措辭收窄**(2026-08-25 編排者查證):`Render.hs:438` 的 `blankTail` 是**冪等**的,文字已以空行結尾時原樣回傳。所以不是「必然動到」,而是「**只有當插入點之前那一段還沒有以空行結尾時**才補齊行尾」;且這不是 `insertSection` 新引入的讓步,`appendSection` 早就走同一個 `blankTail`。契約卡措辭照此收窄後回寫 |
| F008 G7(qa) | L15 要求 `StoreError` 全部 21 個建構子的訊息「含至少一個以『請』起頭的子句」,但 F005 既有的 `SqliteError`(`Error.hs:96-97`)用「可以嘗試」收尾;F005 自己的判準是「請/改用/可以/才」四選一 | qa 寫了一則刻意會紅、標明 gap 編號的測試,不放寬判準 | **裁決(2026-08-25 開發者)**:**L15 不放寬,改 `SqliteError` 的訊息**為「;請嘗試重新開啟 vault」。理由:21 則訊息只有一種形狀,新建構子一律照辦,機械斷言維持銳利;放寬成四選一後,日後新訊息只要沒講下一步但戴個「可以」就混得過去 |
| F008 G8(qa) | E6「人為製造碰撞」在公開介面上做不出來——`allocateId` 的時間是內部取樣的,呼叫端無從得知它會在哪一微秒取樣,無法預先寫入它即將嘗試的候選 id | E6 整項停下,只測 L14 與 L14b/E15 | **裁決(2026-08-25 開發者)**:**`allocateId` 收明碼 `UTCTime`**,與 `aapms-core` 的 `newId` 一致。已回寫契約 E。**編排者排除了「開測試專用時間注入管道」**——那是測試後門,`arch-audit` 判準明訂為介面設計缺陷。真正的理由不是覆蓋率:salt 重試迴圈只在真實碰撞時執行,而碰撞幾乎不發生,測不到就可能從第一天起就是錯的,直到兩個節點拿到同一個 id 寫進 Markdown(依 ADR-013 檔案是真相,那時修不回來) |
| F008 G9(qa) | `isRootNode` 對「id 不在 `doc` 裡」沒有任何 Law 或 Example 定義,`Right False` 與 `Left SectionMissing` 兩種讀法都與 haddock 字面相容 | 整項停下,不寫斷言 | **裁決(2026-08-25 開發者)**:回 **`Left (SectionMissing path id)`**,與同模組同 spec 的 `headingDepthFor`(L21)對稱。「查無此節」與「這個節不是根」是兩件事,合一會讓呼叫端分不出來、錯誤往下游飄。spec 補 L24 + E18 |
| F008 G12(qa) | L17 第三個子句「檔案 IO 與 md 序列化不在任何 SQLite 呼叫的括號內」是語法樹層級的問題,文字掃描會製造偽陽性與偽陰性 | 只驗前兩個子句,第三句整項停下 | **裁決(2026-08-25 開發者)**:第三句**從 law 移除**,降級為 `/arch-audit subsys graph-core` 的人工檢查項,寫進 F008「實作備註」。**這是第二次**同一個根(F007 的 G3 是第一次),ADR-022 原文本來就把 code review 與靜態檢測並列 |
| F007(全部) | — | — | **未記錄**:W6 的 spec 閘門結論沒有寫進本表,F007 已 impl-done 無從補。下一波起確保 spec subagent 的回報當場彙整 |

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

**W4 設計**:F004(16 Todo、16 條測試對照、5 條待確認假設)與 F005(12 Todo、22 條測試對照、
6 條待確認假設)平行完成。

**F004 的待確認假設**(下個閘門一併裁決):A1(移除既有 `MdWarning` 通道——契約 D 的 `to*` 沒有
警告參數,design.md 讀取管線也明寫警告唯一來源是 `checkMeta`)、A2(`parseDocument` 只回報第一個
錯誤,對齊契約的 `Either MdError`,不再回 `[MdError]`)、A3(`MdError` / `Document` 拿掉檔案路徑,
由 `aapms-store` 自己接——驗收只要求指出**行號**)、A4(`licenses.md` 節層 `type` 繼承,與主題檔
同列)、A5(`overrideAt` 原本不在契約 D 逐字清單內——**編排者已回填進契約 D**,因為
`store/src/Aapms/Store/Write.hs:99,152` 真的在呼叫它,屬模組間公開介面而非內部細節)。

F004 另查出比原估更廣的改動面:`md/src/Aapms/Md/Render.hs` 有 6 處序列化會把 newtype 直接 `show`
(會印成 `Revision 4` 而不是 `4`),不只 `Inherit.hs` 的 12 處型別不符。

**F005 的待確認假設**(下個閘門一併裁決):A1(cabal 模組清單瘦身——已由編排者升級成 D8)、
A2(`Vault.hs` 改名 `Marker.hs` 對齊模組表)、A3(`VaultHandle` / `openVault` / `closeVault` 併入
Marker 模組)、A4(`initVaultAt` 不建業務子目錄與 `.gitignore`,留給 `workspace`)、
A5(vault id 不做碰撞重試——沒有中樞註冊表可查,`salt=0`)、A6(`IndexIssue` 只給一個建構子,
F006 必須**擴充**而非重新定義)。

**W4 實作 · F004 完成**(`c9f6fe4`):`aapms-md` 從**編不過**變成 **239 examples / 0 failures**;
core 224 / 0、types 42 / 0 未受影響。Todo 16/16。

**G1 — F004 查出的契約缺口(要在階段二閘門裁決,已阻擋 F008 的一條驗收)**:契約 E 的
`NewSection` 只有 `nsMeta :: MetaOverride` 一個管道寫節層欄位,但 **`MetaOverride` 裡沒有 asset 專屬
欄位**(`sha256` / `entry` / `ext` / `meta` / `license` / `author`)**也沒有 license 的八個授權維度**。
後果:`appendSection`(以及契約 E 的 `addSection`)**寫不出一個能通過 `toPack` / `toLicenses` 驗證的
完整新節**——而 F008 的驗收標準明寫「`createPackFile` 在指定目錄寫出 pack.md,節的順序與給定順序相同」。
F004 沒有擅自加欄位或改簽名,照契約原樣實作、測試只驗結構 roundtrip 不假裝 `toPack` 會過,**這個處理是對的**。
編排者評估:這是 Level 2 契約的表達力缺口,不是實作細節,必須在 F008 設計前定案。

**F004 新增假設**:A6(`toPack` 對節缺 `sha256` / `entry` 用一般的 `SectionYaml` 錯誤,不開
`SectionFieldMissing` 分支——契約只點名 `type` / `commercial` / `attribution_required` 三個用該建構子)。

**W4 實作 · F005 完成**(`83c737e`):`aapms-store` **39 examples / 0 failures**。`Vault.hs` 改名
`Marker.hs`、marker 改 `.aapms/`、向上探測與中樞註冊表移除(歸 `workspace`)。Todo 12/12。
**`cabal build all` 自階段一開跑以來首次全綠**,程式碼知識圖隨即在 `b44f2aa` 重建。

> **編排者對 F005 回報的一處更正**:它移除了 `aapms-store` 對 `aapms-md` 的 build-depends,並宣稱
> 這是「綠燈的必要條件」。**這個說法不成立**——編排者查證後確認 F005 留下的四個模組
> (`Marker` / `Atomic` / `Schema` / `Error`)沒有任何一個 import `Aapms.Md`,那條相依只是未使用,
> 留著也編得過(`-Wall` 不含 `-Wunused-packages`)。**結果可接受**(拿掉未使用的相依是好事,
> F006 需要時再加回),但它是在編排者明講「不得移除」之後仍然移除,理由也不對。記在這裡以免
> 之後有人照著這個錯誤前提推論。

**實作順序**:依 D8 改成 **F004 → F005 → F006**(原本 F004 ‖ F005 只適用設計階段)。理由:
`aapms-store` 的 library 對 `aapms-md` 有 build-depends,md 不修好 store 連帶編不過;先跑 F004
就不必為了讓 F005 綠燈而暫時拔掉那條相依。

### 階段二閘門結果(2026-08-24)

**完成**:F004 / F005 / F006 三個 feature `status: done`,Todo 46/46(16 + 13 + 17)。
commit:`c9f6fe4`(F004)、`83c737e` + `8ae2c31`(F005 含 D9 重工)、`3b2d1e3`(F006)。

**測試**(編排者獨立重跑):`aapms-core` **224 / 0**、`aapms-types` **42 / 0**、`aapms-md` **239 / 0**、
`aapms-store` **75 / 0**,合計 **580 examples、0 failures**;`cabal build all` **全綠**。

**兩個里程碑**:① `aapms-md` 從編不過修復,`cabal build all` 自階段一開跑以來首次回綠;
② 程式碼知識圖恢復可重建,已在 `3b2d1e3` 更新(2378 nodes、9985 edges)。

**arch-audit subsys graph-core 發現**:

1. (無)循環依賴:無;跨界引用:無(graph-core 沒有別人進來、也沒有出去)
2. (無)契約符合度:契約 E 的索引與查詢 11 條簽名(`rebuildIndex` / `refreshStale` / `indexFile` /
   `unindexFile` / `lookupNode` / `lookupByName` / `listNodes` / `childrenOf` / `linksFrom` /
   `linksTo` / `loadLinkGraph`)**逐條與 design.md 相符**,無漂移
3. (低,觀察)`Aapms.Core.Json` 是連通度第一名(201),534 行、64 個 instance。但 design.md
   「內部模組劃分」把它定義成「全系統唯一的 aeson 編碼規則」,**高連通是設計意圖不是缺陷**。
   列為觀察項:型別還會增加,若日後難以維護,可依節點型別拆檔但保持「規則只有一份」
4. (資訊)圖的子系統對映覆蓋率只有 11%(35/325 檔案)——因為只有 graph-core 填了 `code-paths`,
   其餘子系統都還沒重建(D1 凍結中)。這不是缺陷,但代表**依賴矩陣目前只看得到局部**,
   要等 P3 之後其他子系統重建並補 `code-paths` 才有全域結論

**驗收標準逐條對帳**(F006 契約卡):`checkMeta` 警告經 `MetaWarningsFound FilePath Id [MetaWarning]`
進 `IndexIssue` 且**不擋索引**(符合本子系統「只說出發生了什麼、不決定怎麼辦」的定位);
`buildTree` 錯誤經 `TreeInvalid` 進 `IndexIssue`(整檔不進索引);`assets.name` 重複經
`DuplicateAssetName` 整檔回滾。三者都有測試。

**F006 新增假設 A10**:`nodes` 表沒有 `vault` 欄,`metaVault` 由 `VaultHandle` 自己的 `vmId` 回填,
不逐列儲存 frontmatter 的 `vault:` 標籤。判斷合理——節點屬於哪個 vault 由它**實際所在的 vault**
決定(ADR-017 的身分是 marker 裡的 id),frontmatter 標籤只是自由文字。模組已寫明日後若需要
「檔案宣告的標籤」是純 schema 擴充。

### 階段三 檢索與寫入

**W6 spec**(`58972f9`):F007 與 F008 兩份 spec + 骨架平行完成,並建 `spec-gaps.md` 記 G1 / G2。
同一個 commit 把 A1(`createPackFile` 改收 `[NewSection]`)與契約 G(`StoreError` 是唯一錯誤型別)
回寫進 `design.md`。

**W6 F007 完成**(`bbb7b48` qa → `46bbedf` impl):FTS5 雙索引、CJK 預切、查詢路由、facet。
仲裁一輪,歸因 **spec bug**(G5,`snippet()` 回片段而 L4 只對完整輸出定義),修 spec 後
**111 examples / 0 failures**。

**F004 重跑**(`b82485c`):修 G2 的資料遺失缺陷(`updateSection` 靜默刪掉 asset 的
`sha256` / `entry` 與 license 的八個維度),`MetaExtras` 兩半式 meta 區塊落地;
`aapms-md` 239 → **285 examples / 0 failures**。

**接續模式的進度補正**(2026-08-25):本節原本寫「(未開始)」,與 git 歷史不符——W6 的 spec、
F007 的整條 qa/impl/仲裁、F004 的 G2 重跑都已完成。依 `git log` 補正如上。
**W6 的 spec 閘門結論(F007 / F008 的待確認假設)當時沒有記進本檔**,F007 已完成無從追補;
F008 的六條於 2026-08-25 補跑閘門,結論見「待確認假設彙總」。

**2026-08-25 接續前的基準線**(編排者獨立重跑,非採信回報):`cabal build all` 全綠;
`aapms-core` 224 / `aapms-types` 42 / `aapms-md` 285 / `aapms-store` 111 =
**662 examples、0 failures**。工作樹乾淨。

**F008 spec 閘門**(2026-08-25):六條假設 2 接受(A1 / A6 補上)、4 推翻(A2 / A3 / A4 / A5)。
四處契約回寫經開發者確認措辭後寫入 `design.md`(`updated: 2026-08-25`):
契約 D 加 `insertSection`、契約 E 的 `addSection` 加 `SectionPlacement`、
`allocateId` 改 `IO (Either StoreError Id)`;契約 G 無需改動(既有文字已涵蓋 A2)。

**W6 剩餘工作**:① F004 + F008 的 spec 更新(平行,opus)把骨架與四項裁決對齊
② 編排者編譯 + commit ③ F008 的 qa ∥ impl ④ 跑測試與仲裁。
