---
id: F003
type: feature
title: pack-metadata
description: pack.toml 的產生與讀取,讓資料庫可從磁碟完整重建
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F002]
related-adr: [ADR-002]
---

# F003: 素材包中繼資料

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

掃描能自動得到的只有「這個壓縮檔存在、裡面有這些內容」。作者、授權、AI 使用揭露、購買來源、價格——這些**無法從檔名或內容推導**,而廠商壓縮檔裡有沒有附這些資訊完全看運氣:有的附了完整授權文字,有的什麼都沒有。

所以這些資訊是**資料,由人維護**:放在版控裡的一個 TOML 檔案,而不是 migration。使用者每買一包新素材就要加一筆,不該需要改程式碼。

這個功能是雙向的:

- **讀取**:解析 TOML → 以壓縮檔基本檔名比對資料庫 → 解析作者與授權 → 更新素材包欄位與 `status`。
- **產生**:由資料庫的素材包列產生每個素材包的 `pack.toml`(F004 的階段 A 寫入磁碟)。

兩個方向合起來的意義是**資料庫可以從磁碟完整重建**。素材庫是備份目標;災難復原時如果只剩壓縮檔而沒有中繼資料,那些查證過的授權條款就得重新查一遍。

`status` 的升級規則是這個功能的核心閘門:授權與作者都齊備才升級為 `ready`,否則維持 `draft`。`draft` 的素材照樣入庫、算雜湊、產縮圖,只是不可用於建專案——授權缺漏因此是**看得見的待辦**,而不是看不見的風險。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Ingest.Catalogue` | `ingest/src/AssetDB/Ingest/Catalogue.hs` | TOML schema 定義、解析、套用到資料庫 |
| `AssetDB.Reorg.PackToml` | `reorg/src/AssetDB/Reorg/PackToml.hs` | 由 `PackRow` 產生 `pack.toml` 文字(純函數) |

`Catalogue` 用 `toml-parser` 的 schema 驅動解析(缺必填欄位是解析錯誤,不是執行期 `Nothing`)。`PackToml` 刻意**手寫產生器**而不用序列化:這個檔案給人編輯,註解要解釋每個欄位為什麼在那裡,而序列化器不會產生註解。

## 對外行為

### 讀取端

- `parseCatalogue :: Text -> Either Text Catalogue` — 純函數。`Catalogue` 是 `[[pack]]` 區塊的清單;必填欄位是 `archive` / `name` / `slug`,其餘全部可選。
- `PackEntry` 的欄位涵蓋 vendor、作者(名稱 / 網址 / 聯絡方式)、授權名稱、AI 揭露、來源網址、版本、價格、取得日期、根類型、備註。
  - `peArchive` 以**基本檔名**比對,不是完整路徑——搬遷會改變目錄結構,但廠商的壓縮檔檔名不會變。
  - `peLicense` 只是**引用** `licenses.name`;授權條款本身在 catalog 的種子資料裡,同一份授權涵蓋多個素材包時不必重複描述。
  - `peKind` 做成明確欄位而不是從路徑或授權推測:「這包是參考資料」是人的判斷,不該由某個資料夾名稱間接決定——那個資料夾搬遷後就不存在了。
- `applyCatalogue :: Store -> Catalogue -> IO ApplyResult` — **只寫入,不刪除**:目錄裡沒提到的素材包保持原狀,讓目錄可以逐步補齊。單一交易。
- `ApplyResult` — `arMatched` 每筆是 (壓縮檔名, 是否升級為 ready);`arMissingArchive` 是目錄裡有但資料庫裡找不到的(通常還沒掃描或檔名打錯);`arMissingLicense` 是引用了不存在的授權名稱。三者都是**回報**,不是靜默忽略也不是崩潰。
- 作者 upsert 的語意:不存在則建立;已存在則補上先前缺的欄位,但**不覆蓋**已有的值。
- AI 揭露與根類型採「有給才覆寫」的語意,避免部分填寫的目錄把既有資料清空。

### 產生端

- `renderPackToml :: PackRow -> Text` — 純函數。輸出含:識別欄位(slug / name)、可選的 vendor / author / 來源網址 / 版本、根類型、AI 揭露(附註解說明 `unknown`「還沒查」與 `none`「作者明確聲明未使用」的差別)、`[archive]` 區塊(**只寫檔名不寫路徑**,加上 SHA-256、位元組數、項目數)、`[license]` 區塊或缺授權的顯眼警告、`status`。
- 缺欄位不產生空白的 key(空白 key 會讓解析端讀回一個空字串,與「沒填」語意不同)。
- 字串以 TOML 基本字串輸出:反斜線與雙引號跳脫,中文原樣保留(TOML 檔案本身就是 UTF-8)。

## 驗收依據

- `ingest/test/AssetDB/Ingest/CatalogueSpec.hs`
  - `parseCatalogue`:「讀出所有欄位」「可選欄位缺席不影響解析」「缺少必填欄位就失敗」「語法錯誤就失敗」
  - `applyCatalogue`(以種子資料庫為 fixture):「以基本檔名比對,不是完整路徑」「授權與作者齊備時升級為 ready」「缺作者時維持 draft」「引用不存在的授權時回報,而不是靜靜忽略」「資料庫裡沒有的壓縮檔會被回報」「作者只建立一次」「重複套用不會產生變化」
- `reorg/test/AssetDB/Reorg/PackTomlSpec.hs`
  - `renderPackToml`:「含有識別欄位」「含有壓縮檔的雜湊與大小 —— 這是資料庫從磁碟重建的依據」「只寫壓縮檔的檔名,不寫路徑」「AI 揭露有註解說明 unknown 與 none 的差別」「缺欄位不會產生空白的 key」
  - 沒有授權時:「不產生 [license] 區塊,而是留下顯眼的說明」「status 是 draft」
  - 字串跳脫:「雙引號會跳脫」「反斜線會跳脫」「中文原樣保留 —— TOML 本來就是 UTF-8」
