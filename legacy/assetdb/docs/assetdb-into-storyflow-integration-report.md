# assetdb → story-flow 整合評估報告

| | |
|---|---|
| 日期 | 2026-08-23 |
| 作者 | assetdb 側(Claude Code) |
| 收件 | story-flow 維護方 |
| 目的 | 評估把 `assetdb` 併入 `story-flow`,產出統一工具 `aapms-cli` |
| 狀態 | 提案,待 story-flow 側裁決 |

---

## 0. 結論先講

**建議把 assetdb 併入 story-flow,以 story-flow 為主幹。** 不是相反。

三個理由,全部可查證:

1. **story-flow 在所有共用維度上都比較成熟** —— 多 vault、全域註冊表、CLI 契約、HTTP/OpenAPI、宣告式型別註冊表、關聯模型。assetdb 只在自己的領域(壓縮檔、內容定址、縮圖、命名文法、專案產出)領先。
2. **測試文化差距明顯**:story-flow 20,297 行測試 / 18,696 行源碼(109%);assetdb 7,119 / 13,244(54%)。把成熟的一方併進較弱的一方,會拉低整體。
3. **story-flow 的 ADR-001 自己寫著「沿用 assetdb 工具鏈」** —— 同樣的 GHC 9.14 + cabal 3.16 + 多套件結構。工具鏈零風險,而架構是 story-flow 的比較新。

**但這不是一次能做完的事。** 合併後 ≈ 31,940 行源碼、27,416 行測試、22 個套件、23 份 ADR,而且兩邊現在**都在生產使用**。本報告建議分五期,每期結束都可交付。

---

## 1. assetdb 是什麼(給不熟的人)

工作室素材庫的索引、檢索與專案素材配置系統。**核心主張與 story-flow 的 ADR-002 是同一條:檔案是真相,資料庫只是可重建的索引。** 只是 assetdb 的真相是**二進位壓縮檔**,story-flow 的是 **markdown**。

### 現況(2026-08-23 實測)

| 項目 | 數字 |
|---|---:|
| 源碼 / 測試 | 13,244 / 7,119 行 |
| 套件 | 9 個 |
| 測試 | 9 suite,689 examples,0 failures |
| ADR | 12 份(全 accepted) |
| 子系統 | 4 個(catalog / ingest / ai-tagging / delivery) |
| 任務文檔 | 52 份,全部 done |
| **真實資料** | 27 個素材包、6,783 筆資源、6,255 份唯一內容、3.2 GiB 去重後、10,640 張縮圖、1,653 筆已命名 |

它不是原型,它索引了真實的 3.2 GB 素材庫,而且產出過一個真實遊戲專案(365 個素材 + 型別安全的 `Assets.hs`)。

### 套件與行數

| 套件 | 行數 | 職責 |
|---|---:|---|
| `core` | 1,369 | 領域型別、ULID、命名文法、Manifest schema。**零重量級依賴 —— 遊戲本體會 import 它** |
| `store` | 1,766 | SQLite schema、正向 migration、FTS5 雙索引、查詢與 facet |
| `archive` | 665 | 壓縮檔列表與單筆讀取。ZIP 原生、rar/7z 交給 7-Zip sidecar |
| `ingest` | 2,448 | 走訪、內容定址雜湊、格式處理器、縮圖、檔名叢集、筆記 |
| `reorg` | 938 | 一次性結構搬遷(快照 → 計畫 → 執行 → 對帳 → 回退) |
| `ai` | 2,234 | 本機 LLM 分類與標註,GBNF 約束輸出,建議暫存與套用 |
| `project` | 1,186 | 專案產出、單筆解壓、manifest、`Assets.hs`、授權閘門、增量同步 |
| `server` | 695 | servant REST(5 端點)+ 靜態前端 |
| `cli` | 2,246 | `assetdb` 指令,14 個指令群 |

另有 `web/` 754 行 TypeScript(唯讀前端)。

### assetdb 帶進來的、story-flow 沒有的東西

這些是整合的**真正價值**,也是唯一不能丟的部分:

| 能力 | 為什麼重要 |
|---|---|
| **壓縮檔存取(ADR-005)** | 列出與單筆讀取而**不解壓**。ZIP 讀 central directory;rar/7z 走 7-Zip 子程序。這是「不把 3.42 GB 解開兩份」的關鍵 |
| **內容定址(ADR-002)** | SHA-256 去重。6,783 筆資源 → 6,255 份唯一內容。縮圖以雜湊定址,所以可 `immutable` 快取,多廠商附的同一份字型只算一次 |
| **命名文法(ADR-004)** | `<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,全域唯一、純 ASCII。它是對外契約,遊戲的 `AssetKey` 常數由它產生 |
| **檔名叢集推論** | 把命名決策從逐檔降到逐群。實測:1,693 個檔案的素材包塌縮成 24 個叢集,**6 次確認命名了 1,653 個檔案** |
| **縮圖管線** | JuicyPixels 解碼 + 內容定址快取,前兩碼分片 |
| **專案產出與授權閘門** | 單筆解壓 → 正規化命名 → `manifest.json` + `Assets.hs`。**不可商用與授權未查證(NULL)一律擋下**。查表打錯從執行期黑畫面變成編譯錯誤 |
| **CJK 雙索引** | FTS5 trigram 對中文有三字元下限,「藥水」「金門」這種兩字詞完全搜不到。assetdb 另建一張 `unicode61` 索引 + 自製 unigram/bigram。**story-flow 目前只有 trigram,中文兩字詞是搜不到的** |
| **GBNF 約束輸出** | JSON Schema 編譯成文法,詞彙表外的分類值模型**物理上吐不出來** |
| **兩層批次失敗語意** | 單筆失敗(記錄後續跑)vs 整批中止(服務掛了,佇列保留原狀)。ADR-009 有可稽核的寫鎖預算規則 |

---

## 2. 重疊盤點:哪些是重複造的輪子

| 能力 | assetdb | story-flow | 處置 |
|---|---|---|---|
| 檔案是真相、DB 是索引 | ADR-002 | ADR-002 | **同一哲學,獨立實作兩次**。哲學留一份,實作分兩種 vault kind |
| 多 vault | 昨天才寫 ADR-011/012,**未實作** | ADR-008 **已實作**,含跨 vault 引用 + 唯讀語意 | **採 story-flow**,assetdb 的 ADR-011/012 併入或作廢 |
| 全域註冊表 | 昨天才設計 | `~/.config/story-flow/vaults.toml` 在跑 | **採 story-flow** |
| SQLite + FTS5 | trigram + **CJK bigram 雙索引** | trigram | **採 story-flow 的結構 + assetdb 的 CJK 方案** |
| LLM 客戶端 | OpenAI 相容 + **GBNF** | OpenAI 相容抽象 | **採 story-flow 的抽象 + assetdb 的 GBNF** |
| CLI 契約 | optparse,無統一信封 | 名詞-動詞、`--json` 信封、exit code 三級、`--remote` 雙模式(ADR-006) | **採 story-flow**,assetdb 14 個指令群重新掛上去 |
| HTTP | servant 5 端點 | servant 16 路徑 25 operation + OpenAPI 推導 | **採 story-flow** |
| 型別註冊表 | 硬編碼 `AssetKind` 列舉 | `types/registry/*.toml` **宣告式** | **採 story-flow**;`AssetKind` 變成註冊表的一組項目 |
| Markdown + 關聯 | `notes` + `links` 表(`src_type/src_id/dst_type/dst_id/rel` 字串) | Entity/Link/LinkKind 方向語意 + 分節格式 + byte-preserving roundtrip + 樂觀鎖 | **assetdb 的 notes/links 整個退場**,由 storydb 吸收 |
| 衝突偵測 / 工作坊 / MCP | 無 | 有 | 原樣保留 |
| 壓縮檔 / 縮圖 / 命名文法 / 專案產出 | 有 | 無 | 原樣移植 |

**可以直接刪掉的**:assetdb 的 `notes` / `links` 兩張表與 `note import` / `note list` / `link` 三個指令。它們是 Entity 圖譜的弱化版,合併後沒有存在理由。

---

## 3. 合併後的架構

### 七個子系統

```
                      ┌──────────────────────────────┐
                      │           shell              │  CLI · HTTP · MCP
                      │  零業務邏輯,servant 型別為   │  三個介面同一份契約
                      │  單一契約(同時產 server+client)│
                      └──┬────┬────┬────┬────┬───────┘
        ┌────────────────┘    │    │    │    └──────────────┐
        ▼                     ▼    ▼    ▼                   ▼
   ┌─────────┐         ┌──────────┐ ┌─────────┐      ┌───────────┐
   │ assetdb │         │ storydb  │ │   ai    │      │  project  │
   │ 壓縮檔  │         │ Entity   │ │ LLM     │      │ 產出/閘門  │
   │ 掃描縮圖│         │ Level樹  │ │ 標註    │      │ 引用清單   │
   │ 叢集命名│         │ 衝突偵測 │ │ 工作坊  │      └───────────┘
   └────┬────┘         └────┬─────┘ └────┬────┘            │
        └───────────┬───────┴────────────┴─────────────────┘
                    ▼
            ┌───────────────┐        ┌──────────────┐
            │    catalog    │◀───────│  workspace   │
            │ 型別·ID·註冊表 │        │ 中樞·註冊表   │
            │ schema·FTS5   │        │ 生命週期      │
            └───────────────┘        └──────────────┘
```

| 子系統 | 職責 | 來源套件 |
|---|---|---|
| **workspace** | 全局中樞、vault/project 註冊表、`setup`/`init`/`forget`/`purge`、解析「這次對哪些 vault 生效」 | sf 的 vault 解析 + assetdb ADR-011/012 的生命週期設計 |
| **catalog** | 共用地基:領域型別、ID、宣告式型別註冊表、Manifest schema、SQLite schema/migration、FTS5(含 CJK) | sf `types`+`core` + assetdb `core`+`store` |
| **assetdb** | 素材落地:壓縮檔、內容定址掃描、縮圖、叢集命名、結構搬遷 | assetdb `archive`+`ingest`+`reorg` |
| **storydb** | Entity 片段圖譜、Level 場景樹、markdown 分節、衝突偵測、**吸收原 notes/links** | sf `md`+`store`+`conflict` |
| **ai** | LLM 端點抽象、GBNF、素材標註、故事工作坊 | sf `llm`+`workshop` + assetdb `ai` |
| **project** | 專案產出:素材複製、`manifest.json`、`Assets.hs`、**故事引用清單**、授權閘門 | assetdb `project` |
| **shell** | CLI + HTTP + MCP,**零業務邏輯** | sf `api`+`server`+`cli`+`mcp` + assetdb `cli`+`server` |

### 三種納管對象,一種 marker

建議**統一成一個 marker,用 `kind` 欄位區分**:

```toml
# <vault>/.aapms/config.toml
id   = "vlt-7f3b2a91"     # 身分是 id,路徑只是位置
kind = "asset"            # asset | story
name = "alchbees-assets"
```

理由:workspace 只需要一條探測規則、一份註冊表、一套生命週期。兩個 marker(`.assetdb/` + `.storyflow/`)等於同一套邏輯寫兩遍,而差別只有「裡面裝什麼」——那是 `kind` 一個欄位的事。

`project` **不需要 marker**:它由中樞註冊 + 目錄內既有的 `assets/manifest.json` 自述。

### 專案目錄:故事引用放哪

原提案是 `assets/story/`。**建議改成 `story/` 與 `assets/` 同層**,理由是 `assets/` 上綁了兩個機制的作用域:

1. `Assets.hs` 列舉 `assets/` 底下每一筆,產生型別安全常數
2. 授權閘門管的是 `assets/` 裡的東西(商用/非商用/未查證)

故事引用**兩個都不適用** —— 沒有位元組、沒有授權、不該變成 `AssetKey`。放進 `assets/story/` 要在這兩個機制各寫一條例外,而例外會被忘記。

```text
projects/Circle/
├── assets/
│   ├── manifest.json     ← 素材(複製進來的位元組)、授權
│   ├── Assets.hs         ← 型別安全的 AssetKey
│   └── sprites/ audio/ …
└── story/
    └── manifest.json     ← 故事引用(不複製,只記 <vault>:<id> + 用途)
```

`story/manifest.json` 每一筆記:`<vault>:<id>`、`title`、`summary`、用途註記、以及 story-flow 的 `revision`(讓 vault 更新時可以對帳提示複查)。

**Entity ↔ Asset 的軟連結現階段不做**,但建議每筆預留一個選配欄位指向 `AssetKey`,現在一律留空 —— 未來要接時不必改 schema 版本。

---

## 4. 對 story-flow 既有 ADR 的影響

| ADR | 影響 | 說明 |
|---|---|---|
| **ADR-011**(介面層下游,拒絕拆 interfaces 子系統) | **建議 superseded** | 它的前提是「只有一個業務契約層 `service`」。合併後有三個領域(assetdb/storydb/project),不會有單一 god service。此時 `shell` 的理由不是「讓依賴敘述好看」,而是**只有一個地方負責「三個領域如何呈現成一致的一組指令」** —— 統一信封、exit code、`--vault` 解析、錯誤格式。沒有 shell 就沒人負責這件事 |
| **ADR-006**(service 單一契約、CLI 雙模式) | **保留,擴充** | 最有價值的那條(servant 型別同時產 server 與 client,兩條路徑不可能悄悄長歪)完全沿用。但「業務邏輯只存在於 `storyflow-service`」要改寫成「**業務邏輯存在於各業務子系統的對外契約,shell 零業務邏輯**」 |
| **ADR-008**(多 vault、git 式探測) | **保留,擴充** | 加上 `kind` 欄位與 project 註冊;registry 建議從「名稱 → 路徑」改成「id → 路徑」(見風險 R2) |
| **ADR-002**(markdown 真相 + SQLite 索引) | **保留,擴充** | 擴充成「**檔案是真相**」的一般原則,兩種落地:markdown(可編輯、byte-preserving)與壓縮檔(不可變、需 sidecar) |
| **ADR-005**(宣告式型別註冊表) | **保留,受益** | assetdb 的 `AssetKind` 硬編碼列舉改成註冊表項目,直接得利 |
| ADR-001/003/004/007/009/010 | 不受影響 | 純 story 領域 |

assetdb 側:**ADR-011/012(全局中樞 + 跨 vault 讀寫)在合併後應標為 superseded**,由 story-flow 的 ADR-008 擴充版取代 —— 它們是在不知道 story-flow 已有實作的情況下寫的。

---

## 5. 分期工期

每期結束都應該是**可建置、可交付**的狀態。

| 期 | 內容 | 交付判準 | 粗估 |
|---|---|---|---|
| **P0** | 決策與骨架:確認方向、統一 marker 格式、`workspace` 的 Level 2 設計 | `subsystems/workspace/design.md` 完成,契約卡滿格 | 小 |
| **P1** | **改名 `aapms-cli` + 併 repo**。22 套件的 `*.cabal`、模組前綴(`AssetDB.*` / `StoryFlow.*` → `AAPMS.*`)、兩個執行檔 | `cabal build all` + `cabal test all` 全綠,**單獨 commit、零邏輯改動** | 中(機械但巨大) |
| **P2** | **`shell`**:統一 CLI 契約(信封 / exit code / `--vault` / `--remote`),assetdb 的 14 個指令群先原樣掛上 | 兩邊指令都能透過統一外殼跑,行為契約有測試釘住 | 中 |
| **P3** | **`catalog` 合併**:型別註冊表、schema、migration 序列、FTS5(含 CJK)收斂成一份 | 單一 schema,單一 migration 序列,中文兩字詞在兩種 vault 都搜得到 | **大** |
| **P4** | `project` 吸收 `story/manifest.json`;assetdb 的 notes/links 退場給 storydb | 「建專案 → 挑素材 → 挑故事」一條龍打通 | 中 |

**P1 越晚做,衝突越大** —— 它會讓所有既有分支/PR 需要重解。建議在任何大規模邏輯改動之前完成。

---

## 6. 會遇到的問題(依嚴重度)

### R1 — assetdb 的業務邏輯有一部分住在 CLI 層 【高】

story-flow 有 `service` 契約層,assetdb **沒有** —— 它的 `cli` 就是組合根。`cli/app` 有 2,172 行,其中 `Options.hs`(630)是純參數解析沒問題,但 `Ai.hs`(420)、`Cluster.hs`(215)、`Doctor.hs`(187)、`Project.hs`(174)**混了編排與呈現**。

要進 shell 的「薄包裝」模型,這 ~1,200 行必須拆成「業務 → 各子系統對外契約」與「呈現 → shell」。**這是整個移植最大的單項工作量**,而且沒有捷徑。

### R2 — ID 體系硬衝突 【高】

| | assetdb | story-flow |
|---|---|---|
| 格式 | ULID,26 字元 Crockford base32 | `<prefix>-<8 hex>`,FNV-1a 64-bit 取低 32 位 |
| 性質 | 時間可排序、全域唯一 | 短、人類可讀、**靠 store 以 salt 遞增重試保證唯一** |

兩者不相容。必須擇一或明確共存(例如 asset 用 ULID、entity 用短 id,而跨界引用一律帶 `kind` 前綴)。**這個決定會滲透到 schema、manifest、對外契約、所有 API 回應** —— 應該在 P0 就拍板,不能拖到 P3。

順帶:story-flow 的 registry 目前是「名稱 → 路徑」。建議改成「id → 路徑」,理由見 R7。

### R3 — 重量級相依會傳染到伺服器 【高】

assetdb 帶進來的相依:`JuicyPixels`(影像解碼)、`zip`、`crypton`、`conduit`、`typed-process`。

assetdb 用一條硬規則守住:**`server` 只准依賴 `core` + `store`**,把重量級相依全留在 CLI 側。story-flow 的 server 目前也很精瘦。

合併後如果不小心,一個只用 storydb 的使用者會背上影像解碼函式庫。**這條規則必須在合併後重新表述並用測試釘住**(assetdb 的做法是 `CabalSpec` 相依斷言 —— story-flow 的 ADR-011 也用同一招,兩邊有共識)。

### R4 — FTS5 的中文兩字詞問題 【中高】

story-flow 只用 trigram。**FTS5 的 trigram 對中文有三字元下限**,所以「藥水」「金門」「行銷」這類兩字詞**完全搜不到**。

assetdb 為此另建一張 `unicode61` 索引 + 自製 unigram/bigram(`Store/Tokenize.hs`),而且 `direct-sqlite` 需要 `flags: +fulltextsearch` 才編得進 FTS5。

合併後必須採 assetdb 的雙索引方案,否則故事側的中文檢索一直是壞的 —— **而且現在可能沒人發現,因為沒有人測過兩字詞**。建議 story-flow 側先自行驗證這一點。

### R5 — 兩種真相的性質不同,不能假裝統一 【中高】

| | assetdb | story-flow |
|---|---|---|
| 真相 | 二進位壓縮檔 | markdown 文字 |
| 可變性 | **不可變**(廠商原始檔,授權爭議時的證據) | 可編輯,要 byte-preserving roundtrip(ADR-010) |
| 讀取 | 需要 sidecar(7-Zip)或 zip 函式庫 | 直接讀檔 |
| 寫入 | 從不寫回 | 常寫回,有樂觀鎖(`revision`) |
| 體積 | 3.2 GiB | KB 級 |

「檔案是真相」是同一條哲學,但**落地機制完全相反**。vault kind 必須真的分開處理 —— 共用的只有「索引可重建」這件事,不是實作。

### R6 — 寫入模型不同 【中】

story-flow 有樂觀鎖(`revision`,防 AI Agent 與作者同時寫入互相覆蓋)。assetdb **沒有** —— 它假設單一寫入者,靠 `busy_timeout=5000` 與「寫交易持有時間以毫秒計」(ADR-009)。

合併後 storydb 的樂觀鎖必須保留;asset 側要不要補是一個決定。**至少 ADR-009 的寫鎖預算規則應該套用到整個合併後的系統** —— 它是可稽核的(看一眼交易區塊內有沒有 IO 或重運算),值得推廣。

### R7 — assetdb 有兩個已實測的缺陷,不要帶進新系統 【中】

在本次調查中實測出來(暫存區全新 vault,一個 `pack-a.zip`):

| 動作 | 重掃結果 | `doctor` |
|---|---|---|
| 建於 `v1/p1/` | 壓縮檔 1 | 1 包 / 1 檔 / 1 資源 |
| 搬到 `v2/p2/` | `0(另有 1 個雜湊未變已跳過)` | 仍 1 包 —— **但 DB 指著已不存在的 `v1/p1`** |
| **整個刪掉** | `0` | **仍然 1 包 / 1 檔 / 1 資源,`search` 照樣回傳** |

根因是兩處判準不一致:pack 身分用**相對路徑**當鍵,但跳過與否用 **sha256 全域查詢**。搬動 → 被跳過 → 路徑不更新;刪除 → 沒有任何反向比對 → 幽靈資料。

**這正是「路徑當身分」的教訓**,而 story-flow 的 registry 目前也是「名稱 → 路徑」。合併前建議:
- assetdb 側修掉(pack 身分改用 sha256,掃描結束反向比對 orphan)
- story-flow 側順勢把 registry 改成「id → 路徑」

### R8 — 測試覆蓋率會被稀釋 【中】

story-flow 109%,assetdb 54%。合併後整體降到約 86%,而降的部分集中在 assetdb 移植進來的模組 —— 也就是**最需要測試的、剛被大改的那些**。

建議:P1 改名時測試必須維持全綠(它是純機械改動,測試是唯一的安全網);P3 catalog 合併前,assetdb 側先補測試到可接受水準。

### R9 — Windows 特有陷阱 【中】

assetdb 踩過並寫進 `CLAUDE.md` 的,story-flow 若沒踩過會重踩:

- **建置路徑不可含空格** —— GHC 的 `llvm-ar` 會在空格處截斷路徑
- **`hSetEncoding stdout utf8` + `SetConsoleOutputCP`** —— 只做前者的話檔案對、螢幕亂碼
- **文字檔 I/O 一律 `BS.readFile`/`BS.writeFile` 配 `decodeUtf8`** —— `Data.Text.IO` 吃 locale 編碼,Windows 上寫壞非 ASCII
- **PowerShell 有副作用的指令不要接 `Select-Object -First N`** —— 會在寫入前殺掉上游行程

### R10 — 外部 sidecar 的優雅降級 【低】

assetdb 需要 7-Zip(rar/7z)。合併後只用 storydb 的使用者不該被 7-Zip 缺席困擾 —— assetdb 既有的做法是「缺席的 sidecar 不會讓素材無法索引,只是沒有預覽圖」,這個語意要延伸到「story-only 的使用者完全不會看到它」。

### R11 — manifest schema 只該升一次 【低】

assetdb 的 `manifest.json` 目前 `schemaVersion = 1`,`FromJSON` 對版本不符**直接失敗**。已知有兩個升版壓力:

1. 多 vault 溯源(每筆素材的來源 vault)
2. 本次的 story 引用清單

**應該一次升到 2,不要升兩次** —— 每升一次所有既有專案都要重新產生 manifest。

---

## 7. 需要 story-flow 側拍板的事

| # | 問題 | assetdb 側的建議 |
|---|---|---|
| 1 | 同意方向嗎:assetdb 併入 story-flow,以 story-flow 為主幹 | 同意則進 P0 |
| 2 | **ID 體系**(R2):ULID / 短 id / 共存 | 建議明確共存並以 kind 前綴區分;但這是 story-flow 的主場,你們決定 |
| 3 | 統一 marker `.aapms/` + `kind` 欄位,還是維持兩個 marker | 建議統一 |
| 4 | `shell` 子系統(等於 supersede 你們的 ADR-011) | 建議做,理由見 §4 |
| 5 | registry 從「名稱 → 路徑」改成「id → 路徑」 | 建議改,理由見 R7 |
| 6 | 專案的故事引用放 `story/` 同層(而非 `assets/story/`) | 建議同層,理由見 §3 |
| 7 | 合併在哪個 repo 進行 | 建議 story-flow repo,assetdb 以 subtree/import 併入 |

---

## 8. 附錄:assetdb 的關鍵契約速查

給移植時對照用。

**命名文法(ADR-004)** — 全系統穩定的對外契約
`<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]`,形狀近似 `^[a-z0-9]+(_[a-z0-9-]+)*$`,最長 64 字元、全域唯一、純 ASCII。實際驗證另外要求至少三段、第一段必須是 `kind` 列舉成員、分段內不得有開頭/結尾/連續連字號。

**檔案系統契約**
```text
<vault-root>/
├── library/
│   ├── packs/<vendor>/<pack-slug>/   ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml                 ← 中繼資料快照(目前是單向匯出,無讀取端)
│   │   └── <廠商原始檔名>.zip         ← 不可變,唯一真相
│   ├── reference/<topic-slug>/       ← 參考資料,預設不進搜尋
│   └── studio/                       ← 自製素材,散檔 + git(唯一不走壓縮檔的例外)
├── projects/  knowledge/  marketing/  web/
└── .assetdb/                         ← 索引與快取,全部是衍生物
```

**全域錯誤處理策略**(四條,建議整套沿用)
1. 失敗必須是使用者看得懂的繁體中文,不是逃逸的例外。呼叫端能做不同處置的位置回 `Either`/`Maybe`;其餘可拋,但**執行檔與 HTTP handler 層必須攔截並翻譯**。資料庫錯誤與檔案系統例外同樣不得逸出。
2. 批次失敗分兩層:單筆失敗(記錄後續跑)vs 整批中止(外部服務掛了,佇列保留原狀)。**把失敗誤判成成功更糟** —— 每一種失敗都必須有出口。
3. 會改動狀態的動作預設只預覽,`--confirm` 才寫入;不可逆操作另需獨立旗標。**只寫暫存表的動作除外**(後面還有人工閘門)。
4. **寫交易的持有時間必須以毫秒計。** 任何檔案讀寫、影像解碼、雜湊計算、子程序呼叫與網路請求一律在交易之外完成。這條是可稽核的:看一眼交易區塊內有沒有 IO 或重運算就知道違不違規。

**執行檔**
`assetdb`(CLI,14 個指令群)與 `assetdb-server`(HTTP,綁 `127.0.0.1:8787`,無身分驗證,開放非回送介面會印警告)。兩者皆有 `--version`。

---

*本報告基於 2026-08-23 對兩個 repo 的實際程式碼、設計文檔與執行結果調查。所有數字均為當日實測,非引用文檔。*
