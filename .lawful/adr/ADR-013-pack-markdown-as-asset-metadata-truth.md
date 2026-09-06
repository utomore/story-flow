---
id: ADR-013
type: adr
title: pack-markdown-as-asset-metadata-truth
description: 素材的人給中繼資料以 pack 為單位落成 Markdown,SQLite 全系統回歸純索引
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-013: pack Markdown 是素材中繼資料的真相,SQLite 全系統純索引

## 狀態(Status)

accepted。supersedes assetdb ADR-006(版本化正向 migration)。擴充 story-flow ADR-002。

## 背景(Context)

兩邊的 ADR-002 寫著同一句話:「檔案是真相,資料庫只是可重建的索引」。只有一邊做到。

story-flow:`rm .storyflow/index.db` → `index rebuild` 掃 Markdown,完整還原。

assetdb:壓縮檔確實是**位元組**的真相。但 `assets` 表裡的 `logical_name`(1,653 筆人工命名
決策)、`asset_tags`、`asset_categories`、`license_id`、`author_id`,以及 `ai_suggestions` 的
標註結果——壓縮檔裡通通沒有。刪掉 `assetdb.sqlite` 它們就永久消失。`pack.toml` 是單向匯出、
無讀取端,救不了。assetdb 因此需要一套版本化 migration(它的 ADR-006)、需要 `backups/` 目錄、
需要「查詢類指令找不到資料庫時拒絕自動建檔」這種防呆——全部是「DB 其實是真相」的症狀。

在統一 Meta(ADR-012)之下,這道裂縫不能留:同一份 `Meta` 不能在 story vault 是可重建的、在
asset vault 是要備份的。`index rebuild`、優先鍵衝突、備份策略、樂觀鎖全部得分兩條規則寫。

## 決策(Decision)

**一、素材的人給中繼資料落成 Markdown,以 pack 為單位。** 每個 pack 一份 `pack.md`,放在壓縮檔
旁邊(`library/packs/<vendor>/<slug>/pack.md`,取代 `pack.toml`);散檔目錄(`studio/`、
`reference/<topic>/`)整個目錄視為一個 pack,同樣一份 `pack.md`。格式與故事側的分節 Markdown
**同一套**:檔案層 frontmatter 是 pack 節點,每一節是一筆 asset(格式見 system.md)。

**二、真相分兩層,各自不可替代**:

| 真相 | 載體 | 可變性 | 誰寫 |
|---|---|---|---|
| 位元組 | 壓縮檔 | 不可變(廠商原始檔,授權爭議時的證據) | 沒有人——從不寫回 |
| 人給的中繼資料 | `pack.md` | 可編輯 | 掃描器(只填空欄)、人、AI(經 `confirm`) |

掃描產生 `pack.md` 時填 `sha256` / `entry` / `ext` / `meta` 這些**從位元組推得出來**的欄位,
`name` 留空、`source: scan`。**掃描永遠不覆寫已有的人給欄位**——重掃只補新條目、更新 `archive`
路徑、標 `missing`。

**三、SQLite 全系統純索引。** `schema_version` 不符即整庫重建,**不再有 migration 序列**。
assetdb 的 `Store/Migrate.hs` 與 ADR-006 在真相落成檔案之後失去存在理由:索引可丟,就不需要
遷移程式。

**四、縮圖是衍生物但不重算。** 它由位元組決定(內容定址),理論上可丟;實務上 85 MB 重算要讀
3.2 GB,所以放全局快取、`rm index.db` 不碰它。

**五、`pack.md` 的體積由索引的過時偵測吸收。** 一個 1,693 條目的 pack 就是一份 1,693 節的
Markdown;只在 mtime/size 變動時重讀,日常查詢走索引。

## 考慮過的替代方案(Alternatives Considered)

- **asset 側 DB 就是真相,接受兩種 vault 規則不同**:實作最小。放棄的理由見背景——同一份 `Meta`
  兩種可靠性保證,每條涉及索引的規則都要寫兩遍,而且「DB 要備份」這件事在單人工作室裡最終會
  被忘記一次。
- **一筆資源一份 sidecar 檔**:粒度最細、diff 最乾淨。放棄的理由是它會產生 6,783 個小檔——assetdb
  當初改成壓縮檔中心就是為了不要數千個小檔要雲端同步。pack 是備份與溯源的自然單位,中繼資料
  跟著它走。
- **中繼資料寫回壓縮檔內(如 zip 註解或附加檔)**:真相只有一份載體。放棄的理由是它違反
  「壓縮檔不可變」——那是授權爭議時的證據,碰一次就失去證據力;rar / 7z 也沒有安全的寫入路徑。
- **保留 `pack.toml`,擴充成完整中繼資料**:不引入第二種格式。放棄的理由是 TOML 表達 1,693 筆
  含自由文字與關聯的條目會比 Markdown 難讀難寫,而且故事側已經有一套分節格式與位元組級寫回
  (ADR-010)——用同一套,解析器與寫回器只有一份。

## 影響(Consequences)

**正面**

- `rm index.db` → `index rebuild` 在兩種 vault 都完整還原;備份策略只剩「備份 vault 目錄」一句
- 命名決策、標籤、授權進了文字檔,可以 diff、可以 git(asset vault 不進 git,但使用者可以只追蹤
  `**/pack.md`)、可以用編輯器批次改
- 刪掉 migration 機制、`backups/`、「拒絕自動建檔」防呆與對應測試
- 掃描器的職責變清楚:它是 `pack.md` 的產生器與補齊器,不是真相的擁有者

**負面 / 成本**

- 6,783 筆現有資料要一次性匯出成 `pack.md`(S2),匯出器是拋棄式程式碼
- 大 pack 的 `pack.md` 可達數百 KB,首次解析有感;過時偵測讓它只發生在變動後
- 作者可以用編輯器把 `pack.md` 改壞——與故事側同一風險,同一處置(解析失敗是使用者看得懂的錯誤,
  指出行號)
- `pack.toml` 的既有讀者(目前沒有)不再有東西可讀
