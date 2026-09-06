---
id: ADR-017
type: adr
title: unified-marker-id-registry-read-across-write-single
description: 統一 .aapms/ marker 帶 kind,中樞註冊表以 id 為鍵,讀跨全部 vault、寫單一
status: accepted
created: 2026-08-23
updated: 2026-08-29
---

# ADR-017: 統一 marker、id 為鍵的中樞、讀跨寫單一

## 狀態(Status)

accepted。擴充 ADR-008(多 vault、git 式探測);吸收並 supersede assetdb ADR-011(全局中樞與
嵌入式 vault)、ADR-012(跨 vault 讀、單一 vault 寫)。

## 背景(Context)

多 vault 兩邊都有設計,成熟度不同:

| | story-flow ADR-008 | assetdb ADR-011 / 012 |
|---|---|---|
| 狀態 | **已實作** | 2026-08-22 才寫,未實作 |
| marker | `.storyflow/` | `.assetdb/` |
| 註冊表 | `~/.config/story-flow/vaults.toml`,**名稱 → 路徑** | `%APPDATA%\assetdb\config.toml`,ULID → 路徑 |
| 探測 | `--vault <名稱>` 或向上找 marker | 全局:不探測,查中樞 |
| 查詢範圍 | 單一 vault | 跨全部 vault(`ATTACH`) |
| 專案 | 無 | 中樞註冊 + manifest 自述 |

三件事要裁決:

1. **兩個 marker 還是一個**。兩個 marker 等於探測、註冊、生命週期寫兩遍,差別只有「裡面裝什麼」
2. **註冊表的鍵**。story-flow 以名稱為鍵;assetdb 在 pack 層實測過「路徑當身分」的缺陷(搬動
   留幽靈、刪除留幽靈),ADR-011 因此堅持 id 為鍵
3. **查詢範圍**。素材庫的核心用途是「在所有素材裡找」;故事側 `cd` 進 vault 操作的 git 心智模型
   也有價值。兩邊各對一半

## 決策(Decision)

**一、一個 marker `.aapms/`,`kind` 欄位區分。** `config.toml` 帶 `id` / `kind` / `name` / `refs`。
`kind ∈ {asset, story}`,一個 vault 一種。`kind` 是運維分界(體積、git、備份、掃描成本差三個
數量級),不是資料模型分界——圖譜已統一(ADR-012)。

**二、中樞註冊表以 id 為鍵**,`%APPDATA%\aapms\config.toml`(`AAPMS_HOME` 覆寫),`[[vaults]]` 與
`[[projects]]` 兩個陣列,每筆 `id` / `name` / `kind` / `path`。名稱只是人用的別名,`--vault` 接受
名稱或 id。搬動 vault 只改 `path`。

**三、讀跨、寫單一**:

| 類別 | 預設範圍 | `--vault` 的作用 |
|---|---|---|
| 查詢(`search` / `list` / `show` / `context` / `doctor`) | 全部已註冊 vault;**結果每筆帶 vault** | 收窄 |
| 寫入(CRUD、`cluster apply`、`ai confirm`、`project new`) | 由 `--vault` 或向上探測 `.aapms/` 決定;都沒有就報錯 | 指定 |
| 管線(`scan` / `thumbs` / `index rebuild`) | 對每個符合 `kind` 的 vault 各跑一次,每次只寫自己的索引 | 收窄 |

向上探測保留(ADR-008 的 git 心智模型),但**只決定寫入目標**,不限制查詢範圍。這是兩邊各取
一半:查詢要全局,寫入要明確。

> **補充(2026-08-29,`/subsys-design workspace`)—— marker `refs` 的語意**:`refs` 原本只被定義成
> 「引用的其他 vault(id),對本 vault 唯讀」,**沒有任何消費者**。現定為「**收窄時的最小讀取集合**」:
> 無 `--vault` 時範圍不變(全部已註冊);下 `--vault X` 時範圍是 `{X} ∪ refs 遞移展開`,展開進來的
> 一律唯讀、永遠不會成為寫入目標。理由是預設查詢已涵蓋全部已註冊 vault,`refs` 在預設路徑上不增加
> 任何能力;它真正的價值在收窄之後——story vault 的 `uses` / `depicts` 指出去的 asset vault 因此
> 自動在範圍內,`project new --vault <story vault>` 不必手指素材庫。展開對環是安全的(結果是集合);
> `refs` 指向未註冊的 vault 只降級為警告,不中止查詢。
>
> **補充(同日)—— 本機設定進中樞**:中樞 `config.toml` 除 `[[vaults]]` / `[[projects]]` 外增
> `[llm]`(地端端點,per-machine;由 `workspace` 原樣捧出**不解讀**,鍵與語意屬 `ai`)與 `[tools]`
> (外部工具位置覆寫)。舊設計把 `[llm]` 放在 vault 的 `config.toml`,而重建後的 `VaultMarker`
> 只有 `id` / `kind` / `name` / `refs` 四欄,沒有承接它;端點本來就是這台機器的東西,per-vault
> 等於同一組設定抄 N 次。

**四、跨 vault 讀以 `ATTACH DATABASE`** 一個連線掛多個索引再 UNION。

> **修訂(2026-08-26,graph-core/F009 spec 閘門)**:本條原文是「排序、分頁、facet 在 SQL 層完成」,
> 經查證與程式碼不符、且不宜一律要求,改為**分案**:
> - **結構查詢(`listAcross`)**:排序、分頁、facet 在 SQL 層完成——與單 vault 的 `listNodes` 一致,
>   它本來就這樣做。
> - **全文查詢(`searchAcross`)**:各 vault 各自取命中,bm25 分數在 Haskell 合併去重後排序分頁——
>   與單 vault 的 `search` 一致(F007 的 `sortHits` / `takePage` 就在 Haskell)。理由:一次查詢要
>   合併 `fts_tri` 與 `fts_cjk` **兩張表**的分數,跨 vault 後變成兩張表 × N 個 vault;推進 SQL
>   做得到,但會把 SQL 組裝弄髒,而收益只在命中數極大時才出現。
>
> 原文之所以會與程式碼不符卻沒被發現,是因為本條只對**跨 vault** 提要求,單 vault 的偏離沒有人擋。

短 id(ADR-014)在 vault 內唯一,跨 vault 不撞是因為結果帶 vault 欄位、定址用 `<vault-id>:<id>`。
`SQLITE_MAX_ATTACHED`(預設 10)超過時是使用者看得懂的錯誤,不是靜默截斷。

**五、生命週期與撤除分層**,承 assetdb ADR-011:`vault forget` 只動註冊表,`--delete-index` 才刪
`.aapms/index.db`;`workspace purge` 清中樞與快取,`--all-vaults` 才連各 vault 的 `.aapms/`;
**任何情況不碰 `library/` 與 Markdown**——它們是真相。

**六、`vault migrate`** 把 `.assetdb/`(舊 assetdb)或 `.storyflow/`(舊 story-flow)升成 `.aapms/`:
寫入 `id` / `kind`,舊索引檔丟棄(純索引,重建即可)。asset 側的人給資料由 S2 匯出器處理,
不在 `migrate` 裡。

> **修訂(2026-08-29,`/subsys-design workspace`)——本條收成 `vault init --adopt`**:S2 匯出器已
> 取消(逐欄查證後,舊庫的標籤 / 分類 100% 機器產、命名由 6 條規則展開,見 system.md 開發階段表)。
> 扣掉資料搬遷後,`migrate` 剩下的「在既有目錄上寫出 `.aapms/config.toml`、不碰 `library/`」與
> 「在既有目錄上 `init`」是同一件事;而 `.storyflow/` 那條分支在目標機器上**沒有任何真實對象**
> (全機器只有一個 `.assetdb/`)。因此改為 `vault init --adopt`:發新 id、要求明給 `kind`、
> 掃出目錄下的舊 marker **只報告不刪除**。留著一條永遠不會被呼叫、卻要進 CLI 說明與 OpenAPI 的
> 指令,成本大於它的價值。

**七、縮圖快取在中樞**(`cache/thumbs/<aa>/<sha256>`),內容定址,跨 vault 共用。

## 考慮過的替代方案(Alternatives Considered)

- **兩個 marker 並存**:零遷移風險。放棄的理由是探測邏輯永久維護兩條路徑,而差別只是一個欄位。
- **註冊表維持名稱為鍵**:人最好讀。放棄的理由是 assetdb 在 pack 層已經付過「路徑/名稱當身分」的
  學費;改名一個 vault 不該讓所有跨 vault 引用斷掉。
- **查詢也要求顯式 `--vault`**:最安全。放棄的理由是查詢不改狀態,讓它背寫入的紀律等於永久失去
  「一次找遍所有素材」——那是 assetdb 要解決的第一個問題。
- **寫入自動跨 vault、程式挑落點**:人體工學最好。放棄的理由是邏輯名稱全域唯一、授權 per-vault,
  挑錯的代價過高。
- **取消 `kind`,一個 vault 可混裝**:概念最乾淨。放棄的理由是探測、掃描、備份、gitignore 全部
  變成「視目錄內容而定」的條件邏輯,而 `kind` 作為不變量讓這些都是一個查表。

## 影響(Consequences)

**正面**

- 探測、註冊、生命週期只有一套;`doctor` 只有一個
- `aapms search` 一次看遍所有 vault 的素材與故事,每筆知道來自哪裡
- vault 改名、搬家不斷關聯

**負面 / 成本**

- 現有 `~/.config/story-flow/vaults.toml`(目前機器上不存在)與 `.storyflow/` 格式作廢;
  `.assetdb/` 要跑一次 `vault init --adopt`(2026-08-29 修訂,原為 `migrate`)
- `ATTACH` 上限 10 個 vault;超過時分批查詢屬 Level 2,但錯誤訊息是 Level 1 契約
- 向上探測與 `--vault` 兩條路徑決定寫入目標,誤操作風險真實存在——緩解同 ADR-008:非 `--json`
  模式的輸出開頭顯示作用中的 vault,破壞性操作先印路徑再 `--confirm`
