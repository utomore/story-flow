---
id: F007
type: feature
title: notes-and-links
description: Markdown 筆記匯入、front matter 解析與實體間的關聯圖
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: []
related-adr: [ADR-003, ADR-008]
---

# F007: 筆記與關聯圖

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

知識文件與行銷素材看起來是兩個新功能,實際上它們是同一張圖上的節點:`notes` 是節點,`links` 是邊,而素材與專案早就在同一張圖上了。

所以「這篇筆記描述哪個素材」「這張截圖宣傳哪個專案」用的是與「這個關卡使用哪些 tileset」完全相同的機制——不是類比,是同一段程式碼。這也是為什麼這件事不需要獨立的子系統。

筆記本身是磁碟上的 Markdown 檔案(給人用編輯器寫、進版控),匯入時解析 front matter 並寫進資料庫;檢索則交給 catalog 的全文索引。筆記內容全部是繁體中文,所以 CJK bigram 索引在這裡不是備援而是**主力**——trigram 對中文的三字元下限會讓「行銷」「素材」這種兩字詞完全搜不到。

front matter 刻意只支援 `key: value` 一種形式,不引入 YAML 函式庫:筆記的 front matter 只需要標題、標籤、日期這幾個純量欄位,支援巢狀結構只會讓人開始把資料塞進文件裡,而那些資料應該進資料庫。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Ingest.Notes` | `ingest/src/AssetDB/Ingest/Notes.hs` | front matter 解析、筆記匯入與列舉、關聯圖讀寫、筆記全文索引重建 |

引用自 catalog:`AssetDB.Store.Tokenize` 的 CJK 判定與 bigram 切分、`AssetDB.Types` 的 `NoteKind` / `LinkRel` / `TextEnum`、`AssetDB.Id` 的 ULID。

## 對外行為

### 筆記

- `parseFrontMatter :: Text -> Text -> NoteDoc` — 純函數,參數是 (來源檔名, 原始內容)。標題的解析順序:front matter 的 `title`(會脫掉外層引號)→ 內文第一個 Markdown 標題 → 檔名。front matter 區塊不會混進內文。`---` 後直接 EOF、或只跟一個換行就 EOF 的退化輸入都不會誤判。
- `frontJson :: [(Text, Text)] -> Text` — front matter 轉成存進資料庫的 JSON 文字。**交給 aeson,不手刻拼接**:值裡的反斜線與控制字元都要合法轉義,手刻版本只處理了雙引號,寫出來的是不合法的 JSON(enhance-0005)。重複的 key 後者為準,與 JSON 物件語意一致。
- `importNotes :: Store -> NoteKind -> FilePath -> IO [(Text, Text)]` — 匯入一個目錄裡的 Markdown(只取 `.md` / `.markdown`),回傳 (標題, 來源) 清單。目錄不存在時回空清單而非錯誤。以**來源路徑為識別鍵** upsert:筆記會被反覆編輯,每次匯入都新增一筆會讓同一份文件散成好幾個版本。
- `listNotes :: Store -> Maybe NoteKind -> IO [(Text, Text, Text, Text)]` — 每筆是 (ULID, kind, 標題, 來源路徑),可依 kind 篩選。
- `reindexNotes :: Store -> IO Int` — 單一交易內清空並重建 trigram 與 CJK bigram 兩個索引,回傳筆數。含中日韓字元的內容才進 bigram 索引。

### 關聯圖

- `tableOf :: Text -> Either Text Text` — 實體型別字串 → 資料表名。五種已知型別:資源、專案、筆記、收藏、素材包。這個字串會拼進 SQL,而型別字串正是使用者在 CLI 打的,所以未知型別回 `Left` 帶可用值清單,由呼叫端轉成友善訊息,**不是崩潰**。
- `linkEntities :: Store -> Text -> Text -> Text -> Text -> LinkRel -> Maybe Text -> IO (Either Text ())` — 參數是 (來源型別, 來源 ULID, 目標型別, 目標 ULID, 關係, 備註)。(來源, 目標, 關係) 三元組唯一,重複建立是無操作。型別或 ULID 打錯回 `Left`,不拋例外。
- `entityLinks :: Store -> Text -> Text -> IO (Either Text [(Text, Text, Text, Text)])` — 某個實體的所有邊,**雙向**。每筆是 (方向 `"out"` / `"in"`, 關係, 對端型別, 對端 ULID)。「改這張 tileset 會影響哪些關卡」是從目標端出發的查詢,與反向查詢一樣常見,只做單向等於做了一半。回傳的對端識別是 **ULID**,不是內部整數 id——對外一律 ULID(ADR-003)。資料列損壞(未知型別或懸空 id)時退回原始整數,讓問題看得見而不是靜默消失。

## 驗收依據

- `ingest/test/AssetDB/Ingest/NotesSpec.hs`
  - `parseFrontMatter`:「讀 front matter 的 title」「沒有 front matter 時取第一個 Markdown 標題」「兩者都沒有時退回檔名」「title 的引號會脫掉」「front matter 不會混進內文」「解析所有 key: value」「對 --- 後直接 EOF 的內容正確解析」「對 --- 加換行即 EOF 的內容正確解析」
  - `frontJson`:「對含反斜線與控制字元的值產生合法 JSON」「空 front matter 是空物件」
  - `importNotes`:「匯入目錄裡的 Markdown」「重複匯入是更新而不是新增」「非 Markdown 檔案不理會」「依 kind 篩選」
  - `reindexNotes`:「中文筆記進 bigram 索引 —— 那是主力而非備援」
  - `tableOf`:「對未知實體型別回傳 Left 而非崩潰」「五種已知型別對應到資料表」
  - links:「建立的邊雙向都查得到」「重複建立同一條邊是無操作」「entityLinks 回傳的對端識別是 ULID 而非內部整數 id」「未知實體型別回 Left 帶友善訊息」
