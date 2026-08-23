---
id: ADR-011
type: adr
title: global-hub-and-embedded-vaults
description: 狀態分兩層:全局 TOML 中樞認得 vault,每個 vault 自帶完整索引
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-011: 全局中樞 + 嵌入式 vault 的兩層狀態模型

## 狀態(Status)

Accepted(2026-08-23)。取代初版「單一素材庫」的隱含假設。

## 背景(Context)

初版把整個系統設計成**單一素材庫**的工具,而且這個假設從來沒有被寫下來過 —— 它是從實作
細節長出來的,不是決定出來的:

- `findDbUpwards` 從當前目錄逐層往上找 `.assetdb/assetdb.sqlite`,這是 `.git` 探測的翻版
- 全域狀態為零(已實測:整個 codebase 沒有一行碰 `APPDATA` / `HOME` / XDG)
- CLI 是在「階段 2:掃描與索引」時附帶長出來的,所以整個 CLI 的世界觀 = `scan` 的世界觀
  = 一個 root、一個索引
- 四個子系統(catalog / ingest / ai-tagging / delivery)全部在講「素材怎麼被處理」,
  **沒有任何一個負責「工具自己」** —— 於是安裝、設定、納管、移除這一整塊不存在,
  而契約卡是從子系統劃分長出來的,`/arch-audit` 因此永遠不會指出它缺席

git 的模式在 git 成立,是因為 git 的每個操作都是「對我 cd 進去的那個 repo」。但素材庫的
核心用途 —— README 開頭那句「找不到東西」—— 本質上是個**全局查詢**。借來的模式把
「局部視角就夠了」這個假設一起帶進來,而它在這裡不成立。

另外,本次討論中實測出一個相關缺陷:`ingest` 的 pack 身分以**相對路徑**為鍵,
所以壓縮檔一搬動就被當成另一個東西(而且因為雜湊相同會被跳過,索引留著指向已不存在的路徑)。
vault 層若重蹈同一個錯誤,代價會大得多。

## 決策(Decision)

**一、狀態分成兩層。**

| 層 | 位置 | 內容 | 性質 |
|---|---|---|---|
| 全局中樞 | `%APPDATA%\assetdb\`(其他平台依 XDG) | `config.toml` + 全局縮圖快取 | **索引,不是真相**;壞了重建即可 |
| 嵌入式 vault | `<vault>/.assetdb/assetdb.sqlite` | 該 vault 的完整素材索引 | 自足、可攜 |

**vault 帶著 `.assetdb/` 搬到另一台機器,`vault add` 一下就能繼續用**,不需要中樞裡的任何
東西。中樞只回答「這台電腦上有哪些 vault、它們現在在哪」。

**二、身分是 ULID,路徑只是位置。** 每個 vault 的索引裡存有它自己的 ULID;`config.toml`
記的是 `ULID → 目前路徑`。搬動 vault 只要重指路徑,身分不變、索引不失聯。這與 ADR-003
「對外識別一律 ULID」一路貫穿到中樞,也避開了 pack 層那個「路徑當身分」的缺陷。

**三、中樞用 TOML,不用 SQLite。** 內容只有個位數列(有哪些 vault 與專案、全局設定),
不需要 SQL。TOML 人可讀、可編輯、可版控、壞掉時看得出來,與專案既有的 `pack.toml` /
`data/packs.toml` 哲學一致。

**四、縮圖快取移到全局。** 它是內容定址的,同一份內容在兩個 vault 裡本來就該只算一次。
`.assetdb/` 因此只剩索引一個檔案。

**五、專案脫離 vault,改由中樞註冊 + `manifest.json` 自述。** 專案本來就會離開素材庫獨立
存在(它是一個 git repo),把它的真相放在某個 vault 的索引裡,等於讓專案的存在依賴一個它
不該依賴的東西。因此 `projects` / `project_assets` 不再是 vault 索引的一部分。

**六、撤除分兩層,不可逆的要獨立旗標。** 判準是「`.assetdb/` 裡全部是衍生物」:

- `vault forget` 只從註冊表移除,`.assetdb/` 原封不動;`--delete-index` 才刪索引
- `purge` 清全局設定與快取;`--all-vaults` 才連每個 vault 的 `.assetdb/` 一起清
- **任何情況下都不碰 `library/`**

**七、新增 `workspace` 子系統**承載以上全部,並刻意保持輕量(只依賴 catalog 與一個 TOML
解析器),因為 `server` 也要依賴它。

## 考慮過的替代方案(Alternatives Considered)

- **索引全部集中在中樞,vault 內只放 marker**:查詢變成單一資料庫,實作最簡單。放棄的理由
  是 vault 不再自述 —— 搬走就失聯、無法整個交給別人、無法用 git 追蹤,而「離開資料庫也
  自述得清楚」是這個專案在 `pack.toml` 上已經選過一次的立場。
- **路徑就是 vault 的身分**:註冊表直接以路徑為鍵,實作最少。放棄的理由見背景 —— 那正是
  剛在 pack 層測出來的缺陷,沒有理由在更高的層級再犯一次。
- **中樞也用 SQLite**:可交易、可查詢。放棄的理由是內容小到不需要 SQL,而且多一份 schema
  與 migration 要養;壞掉時使用者也無法直接修。
- **不做中樞,靠使用者每次 `--db` 指定**:零新狀態。放棄的理由是它把「一次找遍所有素材」
  這個核心用途永久排除在外,而那正是專案存在的第一個理由。
- **維持單一素材庫,把第二個庫當成第二個 root**:`roots` 表已經支援多 root。放棄的理由是
  root 是「同一個索引裡的多個掃描起點」,它們共用一份 `logical_name` 全域唯一空間與一份
  授權設定;兩個**互不相干**的素材庫共用一份命名空間會互相污染。

## 影響(Consequences)

- `system.md` 的檔案系統契約、子系統劃分、通訊拓撲、架構圖全部修訂;新增階段 15。
- **CLAUDE.md 的硬規則「`server` 只准依賴 `core` + `store`」放寬為 `core` + `store` +
  `workspace`。** 前提是 workspace 輕量,規則的精神(伺服器不背影像解碼 / zip / LLM)不變。
- **`manifest.json` 的 schema 由 1 升到 2**:新增專案 ULID、每筆素材的來源 vault ULID、
  樣板名稱。`FromJSON` 對版本不符是直接失敗(catalog 契約),所以**既有專案需要重新產生
  manifest**。遷移路徑:`project sync --confirm` 會以登記全集重寫 `manifest.json` 與
  `Assets.hs`,升級因此可以搭它進行,不需要另外寫工具。
- **既有素材庫的遷移**:`C:\Users\User\Documents\alchbees-assets` 已經有 `.assetdb/`,
  走 `vault add` 註冊即可,不需要重新掃描。它的索引需要補上 vault ULID(schema 變更,
  屬 catalog Level 2)。縮圖快取要從 `.assetdb/cache/` 搬到全局位置。
- 反向查詢「這個素材被哪些專案用了」改為掃過已註冊專案的 manifest,不再是一次 SQL JOIN。
  已註冊專案是個位數,可接受。
- ADR-009 的寫鎖預算規則**逐一適用於每個索引檔**,不因為伺服器同時掛了多個而改變;
  跨 vault 讀取的機制見 ADR-012。
