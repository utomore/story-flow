---
id: system
type: system
title: aapms
description: 素材與故事設定共用一份片段圖譜的工作室資產管理工具
status: active
created: 2026-08-16
updated: 2026-08-23
subsystems: [graph-core]
---

# aapms(Alchbees Asset & Project Management System)系統主架構

> 本文件是 2026-08-23 的**重構版**:把 `assetdb`(素材庫索引)深度整合進 `story-flow`
> (故事片段圖譜),產出單一工具 `aapms`。它取代本檔 2026-08-22 版與 `assetdb` 的
> `.design/system.md`。整合評估見 `assetdb/docs/assetdb-into-storyflow-integration-report.md`;
> 本文件與該報告不一致處**以本文件為準**(報告是提案,本文件是裁決)。
>
> `subsystems` 清單只列已重建者:舊的四個子系統文檔(`entity-graph-core` / `service-and-interfaces` /
> `conflict-detection` / `llm-workshop-mcp`)描述的是合併前的邊界,已移至 `.design/legacy/`
> (連同已結案的 G-E001 / G-E002),將依本文件「子系統劃分」節逐一以 `/subsys-design` 重建並回填;
> 重建前它們只作為移植時的參考,不再是權威,狀態掃描不讀它們。

## 需求說明

工作室有兩套各自成熟、哲學相同、實作卻重複兩次的工具:

| | assetdb | story-flow |
|---|---|---|
| 管什麼 | 已經存在的素材(3.2 GiB 壓縮檔、6,783 筆資源) | 還沒畫出來/寫出來的設定(Entity 片段圖譜、Level 場景樹) |
| 真相 | 壓縮檔 | Markdown |
| 各自獨有 | 壓縮檔不解壓讀取、內容定址去重、縮圖、命名文法、檔名叢集、專案產出與授權閘門、CJK 雙索引、GBNF | 有方向語意的關聯模型、分節 Markdown 與位元組級寫回、樂觀鎖、衝突偵測、工作坊、MCP、OpenAPI |
| 重複造的 | SQLite + FTS5、多 vault、LLM 客戶端、CLI、HTTP server、型別列舉、`notes`/`links` 表(Entity 圖譜的弱化版) | SQLite + FTS5、多 vault、LLM 客戶端、CLI、HTTP server、型別註冊表 |

重複本身還能忍;真正的問題是**兩張圖譜互相看不見**:角色的設定片段在一邊、角色的立繪在另一邊,
「琳達用的是哪張立繪」「這段演出要哪首 BGM」「建專案時這個 Level 需要哪些素材」沒有任何地方
能回答。兩個工具的價值在交界處,而交界處是空的。

aapms 的核心主張只有一條:**素材與故事設定是同一張片段圖譜上的節點**。一張立繪、一段外貌描述、
一個場景 Node,共用同一份 `Meta`、同一種關聯、同一張索引、同一組指令。素材多出幾個專屬欄位
(內容雜湊、壓縮檔位置、邏輯名稱、授權),其餘一視同仁。

核心功能(依優先順序):

1. **統一片段圖譜**——Entity、Asset、Level、Node 全部是節點;有方向性的關聯可以跨素材與故事
2. **檔案是真相,索引可丟**——故事片段是 Markdown;素材的**位元組**在壓縮檔、**人給的中繼資料**
   (命名、標籤、分類、授權、AI 標註)以 pack 為單位落成 Markdown。兩種 vault 都能 `rm` 索引後
   完整重建
3. **素材落地管線**——壓縮檔不解壓讀取、SHA-256 去重、內容定址縮圖、檔名叢集命名、結構搬遷
4. **衝突偵測**——新劇情草稿對既有設定的矛盾,指到片段
5. **專案產出連動**——挑一個 Level → 帶出它牽涉的 Entity → 帶出那些 Entity 綁定的素材 →
   過授權閘門 → 產生 `manifest.json` 與型別安全的 `Assets.hs`
6. **一份契約三個殼**——CLI / HTTP / MCP 同源於同一組 servant 型別;AI Agent 只 parse 一種形狀
7. **多 vault**——全局中樞認得所有 vault 與專案;讀跨全部、寫單一
8. **地端 LLM**——素材分類標註(GBNF 約束)與故事階段式工作坊共用同一個端點抽象

使用者:單人工作室(alchbees)與它接入的 AI Agent(claude code / codex)。

明確**不在**範圍內:遊戲執行期的載入器與對話引擎、多人協作與權限、即時同步。Web 前端(原
assetdb 的唯讀縮圖瀏覽)保留在最後一期,核心重建期間不維護。

## 技術棧與環境

- **語言/建置**:Haskell,GHC 9.14.1 / cabal 3.16.x,多套件 `cabal.project`,**不使用 stack**;
  建置路徑不可含空格(Windows 上 GHC 的 `llvm-ar` 會在空格處截斷)。兩邊工具鏈本來就一致(ADR-001)
- **命名**:執行檔 `aapms` / `aapms-serve` / `aapms-mcp`;cabal 套件 `aapms-<name>`;Haskell 模組
  前綴 `Aapms.*`(取代 `StoryFlow.*` 與 `AssetDB.*`);vault marker `.aapms/`;全局中樞目錄
  `%APPDATA%\aapms\`(其他平台依 XDG),環境變數前綴 `AAPMS_`
- **儲存**:檔案為真相 + SQLite **純索引**(`schema_version` 不符即整庫重建,**不寫 migration**);
  `direct-sqlite` 開 `+fulltextsearch`,FTS5 以 trigram + unicode61 雙索引支援中文二字詞
- **壓縮檔**:ZIP 原生讀 central directory(`zip`);rar / 7z 交給 7-Zip sidecar(`typed-process`)。
  sidecar 缺席只影響預覽與縮圖,不影響索引
- **影像**:`JuicyPixels` 解碼產縮圖。**只准出現在 CLI 側的套件**,伺服器不背它
- **API**:`servant` 型別即契約,同一份型別產 server(`warp`)、client(CLI `--remote`)、OpenAPI 3
- **LLM**:`http-client(-tls)` 直打 OpenAI 相容端點;GBNF 文法由 JSON Schema 編譯,約束分類輸出
- **業務層**:`mtl` 的 `ReaderT` + `ExceptT`
- **CLI**:`optparse-applicative`,名詞-動詞,`--json` 統一信封
- **設定**:TOML(`toml-reader`),中樞註冊表與 vault 設定都是人可手寫的 TOML
- **測試**:`hspec`;`CabalSpec` 逐字斷言套件相依方向
- **前端**(P7):沿用 assetdb 的 Vite/React/TypeScript,`types.ts` 由 server 產生、禁止手改

## 系統對外介面(External I/O Contract)

六個出入口。前三個是程式介面,後三個是資料本身——檔案是真相(ADR-002、ADR-013),vault、
專案與中樞的目錄格式同樣是契約,作者用編輯器直接改檔是合法輸入。

### 1. CLI

```text
aapms [--vault <名稱|id> | --remote <url>] [--json] <名詞> <動詞> [參數]
```

| 名詞 | 動詞(摘要) | 範圍 |
|---|---|---|
| `workspace` | `setup` / `doctor` / `tools` / `purge` | 中樞與本機診斷 |
| `vault` | `init` / `add` / `list` / `info` / `forget` / `check` / `migrate` | vault 生命週期;`migrate` 把舊 `.assetdb/` 或 `.storyflow/` 升成 `.aapms/` |
| `type` | `list` / `show` | 型別註冊表 |
| `entity` / `asset` / `pack` / `link` / `level` / `node` | 增刪查改 | 圖譜 CRUD;`asset` 多 `scan` / `thumbs`,`pack` 多 `reorganize` |
| `search` | — | 全文 + facet,**一次回兩種**(asset 與 entity 都命中) |
| `context` / `conflict` | `check` | 衝突偵測 |
| `cluster` | `list` / `rule` / `apply` | 檔名叢集命名 |
| `ai` | `ping` / `classify` / `tag` / `suggest` / `confirm` / `reject` / `status` / `query` | 地端 LLM 標註 |
| `workshop` | `start` / `next` / `emit` | 階段式工作坊 |
| `project` | `new` / `list` / `sync` / `add` / `remove` | 專案產出 |
| `index` | `rebuild` / `status` | 索引 |

契約:

- `--json` 輸出統一信封 `{"ok":true,"data":…}` / `{"ok":false,"error":{"code":…,"message":…}}`
- exit code `0` 成功、`1` 業務或傳輸失敗、`2` 用法錯誤
- **讀跨、寫單一**:查詢類預設涵蓋全部已註冊 vault(可 `--vault` 收窄),**結果每筆帶來源 vault**;
  寫入類的目標 vault 由 `--vault` 或從當前目錄向上探測 `.aapms/` 決定,兩者都沒有就報錯,程式不猜
- 會改狀態的動作預設只預覽,`--confirm` 才寫入;不可逆操作另需獨立旗標
- `--remote` 時改走 HTTP,行為與內嵌模式一致(同一份 servant 型別);**重管線指令在遠端模式下
  以用法錯誤拒絕**(見第 2 點)
- 非 `--json` 模式的輸出開頭顯示作用中的 vault

### 2. HTTP(`aapms-serve`)

綁 `127.0.0.1:8787`,無身分驗證,開放非回送介面印警告。`--openapi` 輸出 OpenAPI 3。

暴露的是**圖譜與判斷**:vault 清單、型別、entity / asset / pack / link / level / node 的 CRUD、
search、context / conflict、workshop、project、`/thumb/<sha256>`(讀內容定址快取,`immutable`
快取標頭,不現場解碼)。

**不暴露重管線**:`asset scan` / `asset thumbs` / `cluster apply` / `pack reorganize` 只在 CLI。
這不是省事,是相依隔離規則的必然結果(見「通訊拓撲」):伺服器不背影像解碼與壓縮檔函式庫。

錯誤 body 一律 `{"error":{"code":…,"message":…}}`,與 CLI 信封同一組 `code` 與同一句繁中訊息。

### 3. MCP(`aapms-mcp`)

stdio adapter;tools 與 REST 契約同源(依同一份 servant 型別映射),不另立一套。

### 4. Vault 檔案

一個 vault = 一個目錄 + `.aapms/` marker,`kind` 決定它主要裝什麼:

```toml
# <vault>/.aapms/config.toml
id   = "vlt-7f3b2a91"     # 身分是 id,路徑只是位置
kind = "asset"            # asset | story
name = "alchbees-assets"
refs = []                 # 引用的其他 vault(id),對本 vault 唯讀
```

`kind` 不是資料模型的分界(圖譜已統一),是**運維**的分界:asset vault 是 GiB 級、不進 git、
靠雲端同步;story vault 是 KB 級、進 git 看 diff。兩者的備份、忽略規則、掃描成本差三個數量級,
工具據 `kind` 決定預設行為。一個 vault 一種 kind;跨 kind 的關聯走 `<vault>:<id>`。

`.aapms/` 內只有 `config.toml` 與 `index.db`(gitignored,可 `rm`)。縮圖快取在全局中樞,
不在 vault 內——它是內容定址的,兩個 vault 裡的同一份內容只算一次。

檔案格式細節見「資料結構的框架格式」。

### 5. 專案目錄

```text
projects/Circle/
├── assets/
│   ├── manifest.json     ← 素材(複製進來的位元組)、授權、來源 vault;schemaVersion = 2
│   ├── Assets.hs         ← 型別安全的 AssetKey,由邏輯名稱產生
│   └── sprites/ audio/ …
└── story/
    └── manifest.json     ← 故事引用:<vault>:<id>、title、summary、用途、revision(不複製)
```

`story/` 與 `assets/` **同層**而非 `assets/story/`:`Assets.hs` 列舉與授權閘門兩個機制都綁在
`assets/` 上,故事引用沒有位元組、沒有授權、不該變成 `AssetKey`,放進去要各寫一條例外。
專案不需要 marker,由中樞註冊 + 目錄內的 manifest 自述。

### 6. 全局中樞

`%APPDATA%\aapms\config.toml`(`AAPMS_HOME` 可覆寫),取代 `~/.config/story-flow/vaults.toml`
與 `%APPDATA%\assetdb\config.toml`:

```toml
[[vaults]]
id   = "vlt-7f3b2a91"
name = "alchbees-assets"
kind = "asset"
path = "C:/Users/User/Documents/alchbees-assets"

[[projects]]
id   = "prj-91c0aa12"
name = "Circle"
path = "D:/games/Circle"
```

鍵是 **id,不是名稱也不是路徑**:搬動 vault 只改 `path`,身分與關聯不失聯。`vault init` /
`vault add` / `project new` 是僅有的寫入點,只追加,保住「可手寫」。

## 子系統劃分(Subsystems & Bounded Contexts)

八個子系統,依「地基 → 契約 → 領域 → 外殼」四層。這一節只定邊界與對外介面;內部模組、資料流、
演算法在各自的 `.design/subsystems/<slug>/design.md`。兩者衝突以本文件為準。

### 地基

#### `graph-core` 片段圖譜核心 · [`subsystems/graph-core/design.md`](./subsystems/graph-core/design.md)

- **定位**:把檔案變成可查詢的統一圖譜,並守住「檔案是真相、索引可丟」
- **涵蓋**:`types/registry/*.toml`、`aapms-core`(零 IO:`Meta` / `Entity` / `Asset` / `Pack` /
  `Link` / `Level` / `Node`、短 id、命名文法、Manifest schema——**遊戲本體會 import 它,零重量級
  相依**)、`aapms-types`(註冊表載入)、`aapms-md`(分節 Markdown ↔ 型別,位元組級寫回)、
  `aapms-store`(原子寫入、SQLite 索引與重建、FTS5 雙索引、樂觀鎖、跨 vault `ATTACH` 讀取)
- **職責**:統一 `Meta` 與核心型別的純函式;宣告式型別註冊表(含 asset 族);兩種 vault 的
  Markdown 解析與寫回;索引建立、過時偵測與重建;檢索與 facet
- **對外介面**:`aapms-core` 的純型別與純函式;`aapms-store` 的 vault 定位、查詢、寫入函式。
  **唯一的業務消費者是 `service`**;`asset-ingest` 只消費純型別與寫入函式
- **不負責**:任何業務判斷;不知道壓縮檔怎麼讀(那是 `asset-ingest`)
- **來源**:story-flow `core` + `types` + `md` + `store`,吸收 assetdb `core`(Id / Naming /
  Manifest / Types)+ `store`(Schema / Search / Tokenize)。assetdb 的 Migrate 與 `notes` / `links`
  表**不移植**

#### `workspace` 全局中樞

- **定位**:工具自己的狀態——這台機器有哪些 vault 與專案、它們在哪、怎麼納管與移除
- **涵蓋**:`aapms-workspace`(刻意輕量:只依賴 `aapms-core` 與 TOML 解析)
- **職責**:中樞註冊表讀寫;vault 探測(`--vault` → 註冊表、否則向上找 `.aapms/`);
  `setup` / `init` / `add` / `forget` / `purge` 生命週期;`migrate` 舊 marker;解析「這次指令對哪些
  vault 生效」(讀跨寫單一的裁決點);全局縮圖快取的位置
- **對外介面**:「目前作用的 vault 集合」與「中樞設定」兩個查詢,加上生命週期操作
- **不負責**:vault 裡面裝什麼——它只認 marker,不讀索引內容
- **來源**:story-flow `Store.Vault` 的探測與註冊表 + assetdb ADR-011 / ADR-012 的設計(原本
  未實作)

### 契約

#### `service` 業務契約

- **定位**:所有業務操作的唯一定義處
- **涵蓋**:`aapms-service`
- **職責**:以 `ServiceM` 定義 vault / entity / asset / pack / link / level / node / search /
  index / project 註冊的全部操作;錯誤語彙(`code` + 繁中 `message`)的單一來源;樂觀鎖的執行點
- **對外介面**:`ServiceM` 的業務函式。`shell` 的三個殼與四個領域子系統都只認它
- **不負責**:呈現、參數解析、HTTP;也不 import 任何領域子系統——**契約層單向向下**,由
  `CabalSpec` 逐字斷言
- **來源**:story-flow `service`,擴編吸收 assetdb 原本住在 CLI 裡的 ~1,200 行編排邏輯
  (`Ai` / `Cluster` / `Doctor` / `Project` 的業務部分)

### 領域

#### `asset-ingest` 素材落地

- **定位**:把壓縮檔變成圖譜節點與縮圖,不解壓、不複製
- **涵蓋**:`aapms-archive`(ZIP 原生 + 7-Zip sidecar)、`aapms-ingest`(走訪、雜湊、格式處理器、
  縮圖、檔名叢集)、`aapms-reorg`(快照 → 計畫 → 執行 → 對帳 → 回退)
- **職責**:掃描 vault 的 `library/`,對每個 pack 產生或更新 pack Markdown 與索引;內容定址縮圖;
  叢集推論命名規則;結構搬遷。**pack 身分以壓縮檔 sha256 為鍵,掃描結束反向對帳 orphan**
  (修掉「搬動留幽靈、刪除留幽靈」的已知缺陷)
- **對外介面**:`scan` / `thumbs` / `cluster` / `reorganize` 四條管線,經 `service` 對外
- **不負責**:命名文法本身(在 `graph-core`)、授權判斷(在 `project`)
- **來源**:assetdb `archive` + `ingest` + `reorg` 原樣移植,改接統一 `Meta` 與 pack Markdown

#### `conflict` 衝突偵測

- **定位**:回答「這段新劇情和既有設定有沒有矛盾」,指到片段
- **涵蓋**:`aapms-conflict`
- **職責**:圖遍歷(`contradicts` / `supersedes`)→ FTS5 候選撈取(只以 `canon` 為基準)→ LLM
  逐對判斷。候選集自然含 asset 節點(同一張索引),但 P5 的判斷層只比對文字
- **對外介面**:`POST /conflict/context`、`POST /conflict/check` 與對應 CLI
- **不負責**:寫入圖譜
- **來源**:story-flow `conflict` 原樣,改接統一索引

#### `ai` LLM 與工作坊

- **定位**:把「和模型對談」變成圖譜上的節點與標註
- **涵蓋**:`aapms-llm`(OpenAI 相容端點抽象 + GBNF 文法編譯,**一份客戶端**)、`aapms-ai`
  (素材分類、視覺標註、建議暫存與套用、自然語句查詢規劃)、`aapms-workshop`(階段式引導狀態機)
- **職責**:端點抽象供 `conflict` 第 3 層與兩種標註共用;素材側的建議走暫存表 + 人工閘門;
  故事側的工作坊依註冊表 `stages` 逐階段產出多個片段
- **對外介面**:LLM 門面(供 `conflict`)、`ai *` 與 `workshop *` 操作
- **不負責**:決定建議是否採納——那是人的事,`confirm` 才寫入
- **來源**:story-flow `llm` + `workshop`,吸收 assetdb `ai`(Llm 客戶端合一、GBNF 保留)

#### `project` 專案產出

- **定位**:從圖譜挑東西,產出一個可以離開 vault 獨立存在的遊戲專案
- **涵蓋**:`aapms-project`
- **職責**:單筆解壓 → 正規化命名 → `assets/manifest.json` + `Assets.hs`;故事引用清單
  `story/manifest.json`;**連動**:給一個 Level,順 `involves` 找 Entity,再順 `uses` / `depicts`
  找 Asset,一次列出;授權閘門(不可商用與授權未查證一律擋下);增量 `sync`
- **對外介面**:`project new / sync / add / remove / list`
- **不負責**:素材的真相(只讀壓縮檔,從不寫回)、專案的 git
- **來源**:assetdb `project`,擴編吸收故事引用與連動

### 外殼

#### `shell` 介面外殼

- **定位**:三個殼、零業務邏輯。唯一負責「八個領域如何呈現成一致的一組指令」的地方
- **涵蓋**:`aapms-api`(只有 servant 型別與 `ToSchema`)、`aapms-cli`、`aapms-server`、`aapms-mcp`
- **職責**:參數解析;統一信封、exit code、錯誤格式;`--vault` / `--remote` 解析;OpenAPI;
  MCP tool 映射;人類可讀輸出的編碼(`hSetEncoding` + Windows console code page)
- **對外介面**:本文件「系統對外介面」節的 1–3
- **不負責**:任何業務判斷。`shell` 若出現一段「如果 … 就 …」的業務邏輯,它就是放錯地方
- **來源**:story-flow `api` + `cli` + `server` + `mcp`,吸收 assetdb `cli` + `server` 的
  **呈現部分**(業務部分進 `service`)

## 通訊拓撲與原則(Communication Topology)

**子系統之間全部是行程內直接呼叫**,沒有訊息佇列、沒有內部 HTTP。走 HTTP 的只有對外兩處:
`aapms --remote` 與 MCP,打的都是同一份 REST 契約。

**依賴順序**(箭頭 = 認識):

```text
graph-core · workspace  ◄──  service  ◄──  asset-ingest · conflict · ai · project  ◄──  shell
```

四條硬規則,全部由 `CabalSpec` 以逐字清單釘住(黑名單只擋得住想得到的名字):

1. **契約層單向**:`service` 不 import 任何領域子系統
2. **地基不認識上面**:`graph-core` / `workspace` 不 import `service` 以上的任何套件
3. **重量級相依的隔離**:`aapms-server` 與 `aapms-mcp` **禁止依賴** `aapms-archive` /
   `aapms-ingest` / `aapms-reorg`——擋的是 JuicyPixels、zip、conduit、子程序。只用故事功能的使用者
   不該背影像解碼函式庫;縮圖端點讀掃描時產生的快取。這條取代 assetdb 原本的「server 只准依賴
   core + store」,在新架構下後者太緊(server 本來就要 `conflict` 與 `llm`,那兩個很輕)
4. **遊戲本體的相依面只有 `aapms-core`**:它零 IO、零重量級相依,`Assets.hs` 只 import 它

**領域之間的橫向相依只有一條**:`conflict` 第 3 層用 `ai` 的 LLM 門面。介面相依,不是層級倒轉;
`ai` 反過來不認識 `conflict`。`project` 不認識 `asset-ingest`——它需要的「從壓縮檔取單筆」住在
`aapms-archive`,而 `archive` 是 `asset-ingest` 裡最輕的那個套件(無影像解碼),`project` 直接依賴它,
不經 `ingest`。

**讀跨寫單一**(ADR-017):跨 vault 讀以 SQLite `ATTACH DATABASE` 一個連線掛多個索引再 UNION,
排序與 facet 在 SQL 層完成;結果每筆帶 vault。寫入一次只進一個索引,寫鎖預算(下方第 5 條)
逐索引適用,不需要跨 vault 協調。`SQLITE_MAX_ATTACHED` 上限必須是使用者看得懂的錯誤,不是靜默截斷。

**全域錯誤處理策略**(兩邊各四條,收成六條):

1. **每層有自己的錯誤型別,上層不重寫下層的訊息**;`service` 的 `errorCode` / `renderServiceError`
   是三個殼共用 `code` 與訊息的唯一來源
2. **機器看 code、人看 message**:`code` 是 snake_case 穩定識別碼,`message` 繁體中文且每一則
   說出下一步該做什麼;執行檔與 HTTP handler 層必須攔截並翻譯所有例外,資料庫錯誤與檔案系統
   例外同樣不得逸出
3. **設定錯誤即失敗,不退回預設值**:註冊表載入失敗、marker 損壞、中樞格式錯誤都讓程序失敗——
   空註冊表會把設定錯誤偽裝成資料錯誤
4. **批次失敗分兩層**:單筆失敗(記錄後續跑)vs 整批中止(外部服務掛了,佇列保留原狀)。
   把失敗誤判成成功更糟,每一種失敗都必須有出口
5. **寫交易的持有時間以毫秒計**:檔案讀寫、影像解碼、雜湊計算、子程序、網路請求一律在交易之外。
   可稽核:看交易區塊內有沒有 IO 或重運算
6. **並發以樂觀鎖處理**:`revision` 在共用 `Meta` 裡,所有寫入路徑都是必填,asset 側自動涵蓋

## 架構圖

```text
                    ┌──────────────────────────────────────────────┐
                    │                    shell                     │
                    │   aapms-api(servant 型別,只有型別)            │
                    │   aapms-cli · aapms-server · aapms-mcp       │   零業務邏輯
                    └───┬───────────┬───────────┬───────────┬──────┘
                        │           │           │           │
              ┌─────────┘     ┌─────┘           └─────┐     └──────────┐
              ▼               ▼                       ▼                ▼
      ┌──────────────┐ ┌────────────┐ ┌──────────────────┐ ┌──────────────┐
      │ asset-ingest │ │  conflict  │ │        ai        │ │   project    │
      │ archive      │ │            │ │ llm(+GBNF)       │ │              │
      │ ingest       │ │ 圖→FTS5→LLM│ │ ai 標註           │ │ manifest ×2  │
      │ reorg        │ │            │◄┤ workshop         │ │ Assets.hs    │
      └──────┬───────┘ └─────┬──────┘ └────────┬─────────┘ │ 授權閘門·連動 │
             │               │                 │           └──┬─────┬─────┘
             │               │                 │              │     │ 單筆解壓
             │               │                 │              │     └────────► aapms-archive
             └───────────────┴────────┬────────┴──────────────┘
                                      ▼
                         ┌────────────────────────┐
                         │        service         │   ★ 唯一業務契約
                         │   ServiceM · 錯誤語彙   │     不 import 任何領域
                         └───────────┬────────────┘
                     ┌───────────────┴───────────────┐
                     ▼                               ▼
      ┌──────────────────────────┐      ┌────────────────────────┐
      │        graph-core        │      │       workspace        │
      │ types/registry/*.toml    │◄─────│ 中樞註冊表(id→路徑)     │
      │ aapms-core  零 IO ◄──────┼──────┼── 遊戲本體只 import 這個 │
      │ aapms-types · aapms-md   │      │ vault 探測·生命週期      │
      │ aapms-store 索引·FTS5×2  │      │ 讀跨寫單一的裁決點       │
      └──────────────────────────┘      └────────────────────────┘

   對外出入口:CLI(aapms)· HTTP(aapms-serve :8787)· MCP(aapms-mcp)
             · vault 檔案(.aapms/ + Markdown + 壓縮檔)· 專案目錄(assets/ + story/)
   外部相依:OpenAI 相容 LLM 端點(可缺)· 7-Zip sidecar(可缺)
```

資料流 A(素材掃描,證明 pack Markdown 是真相):

```text
aapms asset scan --vault alchbees-assets
  → asset-ingest 走訪 library/packs/**/*.zip|rar|7z,以壓縮檔 sha256 識別 pack
  → 新 pack:列出條目(不解壓)→ 逐條 SHA-256 → 格式處理器取 meta → 產生 pack.md(每條目一節,短 id)
  → 已知 pack 但路徑變了:只更新 pack.md 的 archive 欄位,id 與人給的中繼資料全部保留
  → 掃描結束:索引裡有、磁碟上沒有的 pack → 標 missing(不刪,人決定)
  → store 依 pack.md 更新索引;thumbs 另跑,縮圖寫全局快取
```

資料流 B(專案產出連動,合併後才存在的能力):

```text
aapms project new Circle --level lvl-3a01
  → service 順 Level 的 involves 找 Entity(跨 vault 用 <vault>:<id>)
  → 再順那些 Entity 的 uses / depicts 找 Asset
  → project 對每筆 Asset 查授權:non-commercial 或 NULL → 擋下並列出
  → 通過:archive 單筆解壓 → 正規化命名 → assets/manifest.json + Assets.hs
  → 同時寫 story/manifest.json:每筆 Entity 的 <vault>:<id>、title、summary、revision
```

資料流 C(索引重建,兩種 vault 同一條路):

```text
rm .aapms/index.db → aapms index rebuild
  → 掃描 vault 全部 .md(story:主題檔;asset:pack.md)→ aapms-md 解析 → 重建節點/關聯/FTS5×2
  → 結果與刪除前等價。asset vault 不需要重讀壓縮檔:sha256 與條目清單都在 pack.md 裡
```

## 資料結構的框架格式

### 目錄結構

```text
alchbees-dev/aapms/                 ← 程式碼 repo(原 story-flow 改名)
├── cabal.project
├── types/registry/*.toml           ← 宣告式型別註冊表(entity 族 + asset 族)
├── core/ types/ md/ store/         ← graph-core
├── workspace/
├── service/
├── archive/ ingest/ reorg/         ← asset-ingest
├── conflict/
├── llm/ ai/ workshop/              ← ai
├── project/
├── api/ cli/ server/ mcp/          ← shell
├── web/                            ← P7 才接回
├── scripts/  docs/  .design/

<asset vault>/                      ← kind = asset,不進 git
├── .aapms/{config.toml, index.db}
├── library/
│   ├── licenses.md                 ← 授權節點(lic-),每節一種授權的八個維度
│   ├── packs/<vendor>/<pack-slug>/
│   │   ├── pack.md                 ← 這個 pack 的真相(人給的中繼資料),取代 pack.toml
│   │   └── <廠商原始檔名>.zip       ← 不可變,位元組的真相
│   ├── reference/<topic>/          ← 同樣一目錄一 pack.md,預設不進搜尋
│   └── studio/                     ← 散檔,整個目錄視為一個 pack
└── projects/ knowledge/ marketing/ web/

<story vault>/                      ← kind = story,自己的 git repo
├── .aapms/{config.toml, index.db}
├── characters/琳達.md  lore/  items/  dialogues/  levels/

%APPDATA%\aapms\                    ← 全局中樞
├── config.toml                     ← vault 與專案註冊表(id → 路徑)
└── cache/thumbs/<aa>/<sha256>.png  ← 內容定址縮圖,前兩碼分片
```

### 統一 Meta

所有節點共用一份 `Meta`,抽象成本只付一次:索引表、API 序列化、CLI 輸出、檢索、衝突偵測、
專案產出全部對同一組欄位工作。

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | Text | `<prefix>-<8 hex>`,prefix:`ent` / `ast` / `pck` / `lic` / `lvl` / `nod` / `vlt` / `prj`。FNV-1a 64-bit 取低 32 位,唯一性由持有索引的 store 以 salt 遞增重試保證(ADR-014) |
| `vault` | Text | 所屬 vault 的 **id**;跨 vault 以 `<vault>:<id>` 定址 |
| `type` | Text | 型別註冊表的鍵。core 只當它是字串 |
| `title` | Text | 人類可讀標題 |
| `summary` | Text | 一句話總結;衝突偵測與 AI 撈 context 優先用它 |
| `tags` | [Text] | 自由標籤 |
| `status` | Enum | `draft` / `canon` / `deprecated`;asset 另有 `missing`(壓縮檔不在了)。只有 `canon` 參與衝突比對 |
| `timeline` | Maybe | 故事內時間點,asset 通常空 |
| `aliases` | [Text] | 別名 |
| `links` | [Link] | 有方向性的關聯,存在來源端 |
| `source` | Text | `human` / `agent:claude-code` / `workshop:<型別>` / `scan` / `ai:<model>` |
| `revision` | Int | 樂觀鎖 |
| `created` / `updated` | Date | |

專屬欄位:

- **Entity**:`body`
- **Asset**:`name`(邏輯名稱,命名文法產物,全域唯一,是 `Assets.hs` 的 key)、`sha256`、
  `entry`(壓縮檔內路徑;散檔為相對路徑)、`ext`、`meta`(kind 專屬,如影像寬高、音訊長度)、
  `license`、`author`。所屬 pack 由**檔案包含關係**決定,不寫 `links`
- **Pack**(pack.md 的檔案層):`vendor`、`archive`(相對 vault 的路徑)、`sha256`(壓縮檔本身)、
  `license`(指向 `lic-` 節點)、`author`(name / url / contact 內嵌)、`source_url`
- **License**(`library/licenses.md` 的每一節):`commercial`、`attribution_required`、`credit_text`、
  `modification_allowed`、`redistribution_allowed`、`resale_allowed`、`nft_allowed`、`source_url`、`full_text`;
  授權閘門查它,27 個 pack 共用同一份 CC0 不重複寫八欄
- **Level**:`root`;**Node**:`level` / `parent` / `order` / `kind` / `entities`

### 核心關聯詞彙(`LinkKind`)

| 關聯 | 方向語意 | 引擎行為 |
|---|---|---|
| `contradicts` / `supersedes` / `derivedFrom` / `partOf` / `involves` / `occursIn` / `references` / `convergesTo` | 同 2026-08-22 版 | 同前 |
| **`uses`** | 故事節點 A 用素材 B(這段演出用這首 BGM) | 專案連動沿它找素材;檢索擴充 |
| **`depicts`** | 素材 A 畫/演的是 B(這張立繪是琳達) | 專案連動反向沿它;衝突偵測 P5 後可讀素材的視覺標註 |

兩個都收進詞彙表,因為作者站的位置不同:素材側標「這畫的是誰」,故事側標「這裡用什麼」。

### 型別註冊表

沿用宣告式 `types/registry/*.toml`(ADR-005),每筆項目新增 `family`:`entity`(原有五種)或
`asset`(原 `AssetKind` 八種:`asset-image` / `asset-audio` / `asset-font` / `asset-level` /
`asset-shader` / `asset-doc` / `asset-source` / `asset-archive`)。`asset-pack`、`asset-license` 與 `level` 是保留鍵。
asset 族的 `dir` 無意義(位置由 pack 決定),`allowed_links` 預設含 `depicts`,並宣告 `name_kinds`(命名文法
第一段的合法值);domain 詞彙在 `types/registry/naming.toml`——命名文法的詞彙表因此與型別同一個宣告
機制,不再有程式碼與 DB 兩份真相。新增一種素材格式
仍只改 `ingest` 的格式處理器,kind 專屬資料進 `meta`,不開新表。

### pack Markdown(素材側的分節格式)

與故事側**同一套格式**:檔案層 frontmatter 是 pack,每一節是一筆 asset。

````markdown
---
id: pck-4a1e9c02
vault: vlt-7f3b2a91
type: asset-pack
title: Kenney UI Pack
vendor: kenney
archive: library/packs/kenney/ui-pack/kenney_ui-pack.zip
sha256: 3c1f…
license: cc0
status: canon
source: scan
revision: 4
created: 2026-08-10
updated: 2026-08-23
---

# Kenney UI Pack

掃描時產生的摘要;作者可以在這裡寫筆記。

## panel_book.png {#ast-3f9c1d20}

```meta
type: asset-image
name: ui_gui_travel-book-frame_001
entry: PNG/panel_book.png
sha256: 9f3a…
tags: [gui, book]
summary: 書本風格的面板框
meta: {width: 256, height: 192}
links:
  - {kind: depicts, target: vlt-a0c4e1f8:ent-7f3a}
```
````

規則與故事側一致:第一個帶 `{#id}` 的標題開始分節、節層繼承檔案層(`vault` / `type` 不繼承——
asset 的 type 一定和 pack 不同——其餘同原規則)、未修改區塊逐字保留(ADR-010)。
**一個 1,693 條目的 pack 就是一份 1,693 節的 Markdown**;解析成本由索引的 mtime/size 過時偵測
吸收,只在檔案真的變動時重讀。

掃描寫 `name` 為空、`source: scan`;人或 AI 命名後 `name` 填上、`source` 改 `human` / `ai:<model>`。
**掃描永遠不覆寫已有的人給欄位**。

### SQLite 索引

純索引(ADR-013),`schema_version` 不符整庫重建,**不再有 migration 序列**——assetdb 的正向
migration 機制在真相落成檔案後失去存在理由。內部表結構屬 `graph-core` Level 2。

外溢到其他子系統的事實只有一件:FTS5 以 **trigram + unicode61 雙索引**(ADR-016)。trigram 給
相關度分數,unicode61 + 自製 unigram/bigram 讓中文二字詞命中;兩者都能給分,`conflict` 第 2 層的
`ByRetrieval` 因此吃 `Double` 而非 `Maybe Double`——這是對 2026-08-22 版那條「LIKE 給不出分數」
契約的修正。

## 開發階段

每期結束都是可建置狀態;P3 起每期結束都是可交付狀態。真實資料(`alchbees-assets`)在 P2 就進來,
schema 還改得動的時候拿真資料驗證。

| 期 | 內容 | 交付判準 |
|---|---|---|
| **P0** 讓名與合樹 | `utomore/aapms` 改名封存為 `assetdb-legacy`;`utomore/story-flow` 改名 `aapms`;assetdb 程式碼以保留歷史的方式併入;全樹改 `Aapms.*` 與 `aapms-*`;搬入 assetdb 的四份純技術 ADR;**契約層測試先立起來**(CLI 信封 / exit code / Markdown roundtrip / index rebuild 等價,不依賴內部型別) | `cabal build all` 綠;契約測試綠;零邏輯改動 |
| **P1** graph-core | 統一 `Meta` 與短 id;註冊表 `family`;pack Markdown 解析與寫回;一份 schema;FTS5 雙索引;跨 vault `ATTACH` | `rm index.db` → rebuild 兩種 vault 都等價;「藥水」搜得到;`aapms-core` 零重量級相依 |
| **P2** 真資料進場 | **一次性匯出器**:讀舊 `assetdb.sqlite` → 對每個 pack 產 `pack.md`(重發短 id,帶命名 / 標籤 / 分類 / 授權 / AI 標註);sha256 與 85 MB 縮圖沿用,不重讀 3.2 GB;`vault migrate` | 6,783 筆資源、1,653 筆命名零遺失;匯出後 rebuild 與舊 DB 對帳一致;匯出器隨即從 `cabal.project` 移除 |
| **P3** 骨幹 | `workspace` + `service` + `shell`(CLI / HTTP / MCP 同期,同一份 servant 型別);舊 marker 探測;`doctor` 合一 | 兩種 vault 都能經統一外殼 CRUD、search 一次回兩種;`--remote` 行為一致;OpenAPI 輸出 |
| **P4** 素材管線 | `asset-ingest` 移植:pack 身分改 sha256、orphan 反向對帳、掃描寫 pack.md 不覆寫人給欄位;縮圖到全局快取;cluster / reorganize | 搬動與刪除 pack 不留幽靈;`asset scan` 對真 vault 與 P2 匯出結果等價 |
| **P5** 智慧 | `conflict` 接統一索引;`ai`:LLM 客戶端合一、GBNF、素材標註走暫存表、workshop | 衝突偵測候選集含 asset;`ai classify` 與 `workshop` 共用端點 |
| **P6** 連動 | `project`:Level → Entity → Asset 連動;`story/manifest.json`;manifest **一次升 schema 2**;授權閘門 | 「建專案 → 挑 Level → 自動帶素材 → 擋授權」一條龍 |
| **P7** 收尾 | web 前端接回新 API;`types.ts` 漂移測試;發佈 zip;`docs/` 與 README 改寫 | 縮圖瀏覽可用;從乾淨機器跑 `aapms workspace setup` 到 `project new` |

**P0 越晚做衝突越大**——它讓所有既有分支需要重解,必須在任何邏輯改動之前完成。

> **進度**:P0 於 2026-08-23 完成,三個 commit:全樹改名(`6f41745`)、assetdb 以 subtree merge 併入
> `legacy/assetdb/`(`6d0c31c`,不進 `cabal.project`,P4–P6 再依各子系統搬到最終位置)、契約測試
> `contract/` 與 ADR-019~022。刻意留到 P3 的執行期名稱:marker `.storyflow/`、`STORYFLOW_*` 環境變數、
> `~/.config/story-flow/vaults.toml`、MCP 錯誤碼 `story_flow_*`(由 `workspace` / `shell` 依 ADR-017 改)。
> GitHub 上 `utomore/aapms` → `assetdb-legacy`、`utomore/story-flow` → `aapms` 的改名與本機目錄改名
> 由開發者手動執行。

## 與既有文檔的關係

| 文檔 | 處置 |
|---|---|
| story-flow ADR-001 / 002 / 003 / 004 / 005 / 007 / 009 / 010 | 保留;ADR-002 與 ADR-005 的適用範圍由 ADR-012 / ADR-013 擴充 |
| story-flow ADR-006 | 保留;「業務邏輯只存在於 service」一句由 ADR-015 改寫為「存在於 `service`,`shell` 零業務」 |
| story-flow ADR-008 | 保留;`kind`、id 鍵、讀跨寫單一由 ADR-017 擴充 |
| story-flow **ADR-011** | **superseded by ADR-015**;G-E001 隨之結案 |
| assetdb ADR-004(命名文法)/ 005(ZIP + 7-Zip)/ 007(GBNF)/ 009(寫鎖預算) | P0 原樣搬入為 ADR-019 ~ 022,純技術決策不受合併影響 |
| assetdb ADR-003(ULID) | superseded by ADR-014 |
| assetdb ADR-006(正向 migration) | superseded by ADR-013 |
| assetdb ADR-011 / 012(全局中樞、讀跨寫單一) | 設計吸收進 ADR-017,文檔 superseded |
| assetdb ADR-008(TextEnum)/ 010(匯入建議無 run 紀錄) | Level 2 細節,併入各 `design.md`,不立 ADR |
| 舊四個子系統 `design.md`、G-E001 / G-E002 | 已移至 `.design/legacy/` 作移植參考;依本節八個子系統以 `/subsys-design` 重建後刪除 |
| `assetdb/docs/assetdb-into-storyflow-integration-report.md` | 歷史提案,隨 legacy repo 封存 |
