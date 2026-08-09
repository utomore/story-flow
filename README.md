# assetdb — Alchbees 資源與專案管理系統

工作室的素材庫、知識建檔、行銷資訊與遊戲專案的統一管理系統。

設計文件在 `C:\Users\User\.claude\plans\haskell-sqlite-goofy-pie.md`。

## 建置

需要 GHC 9.14.1 + cabal 3.16(由 `ghcup` 安裝)。**不使用 stack。**

```bash
cabal build all
```

```bash
cabal test all
```

### ⚠️ 路徑不可含空格

GHC 在 Windows 上的封存器 `llvm-ar` 無法處理含空格的建置路徑,
會以 `No such file or directory` 失敗並在空格處截斷路徑。

這就是本專案位於 `Documents\alchbees-dev\`(而非素材庫資料夾內)的原因,
也是素材庫根目錄要改名為 `alchbees-assets` 的原因之一。

**素材本身的路徑可以有空格** —— 那只是資料,由 `roots` 表設定,不經過編譯器。

## 套件

| 套件 | 職責 |
|---|---|
| `core/` | 領域型別、ULID、命名文法、Manifest schema。**遊戲本體也依賴這個** |
| `store/` | SQLite schema、migration、全文搜尋的 token 前處理 |
| `archive/` | 壓縮檔存取:列出內容與讀取單筆項目,**不解壓到磁碟** |

`assetdb-core` 刻意保持零重量級依賴,因為遊戲會 `import AssetDB.Manifest`
來解析 `assets/manifest.json`。任何需要 IO、資料庫或影像處理的東西都不屬於那裡。

## 已完成

- **`assetdb-core`** — 89 個測試
  - `AssetDB.Types` — 資源分類與狀態列舉,全部以穩定文字而非序號持久化
  - `AssetDB.Id` — ULID 產生與 Crockford Base32 編解碼
  - `AssetDB.Naming` — 命名文法,含 `parse ∘ render == id` 的性質測試
  - `AssetDB.Manifest` — 與遊戲共用的 schema
- **`assetdb-store`** — 67 個測試
  - 完整 schema 與版本化 migration
  - `AssetDB.Store.Tokenize` — 中日韓 n-gram 前處理

- **`assetdb-archive`** — 36 個測試
  - `AssetDB.Archive` — 格式派送。ZIP 走純 Haskell,rar 與 7z 走 7-Zip
  - `AssetDB.Archive.Sidecar` — 7-Zip 呼叫與 `-slt` 輸出解析
  - `assetdb-archive-probe` — 診斷工具,印出存取層實際看到什麼

  對素材庫的 27 個真實壓縮檔驗證過:**27/27 解析成功**,共 6,431 個項目,
  去重後 6,366 —— 與獨立跑的覆蓋率統計一致。三種格式的單筆讀取都驗過,
  含 RAR 內的中文路徑。

## 三個實測發現

**1. GHC 的 `llvm-ar` 不吃含空格的路徑。** 見上。

**2. FTS5 的 `trigram` tokenizer 查詢下限是三個字元。**
中文雙字詞(金門、行銷、廟宇、素材)因此完全搜不到。
解法是額外一張 `unicode61` 索引,存放由 `AssetDB.Store.Tokenize`
預先展開的 unigram 與 bigram —— 兩者必須分成不同欄位,
混在同一欄會打亂片語查詢的相對位置。

搜尋路徑因此是:純 ASCII 與三字以上中文走 `assets_fts`(trigram),
三字以下中文走 `assets_cjk`(unicode61 + 自製 n-gram)。

**3. GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。**
素材路徑與素材包名稱大量含有中文,不設 `hSetEncoding stdout utf8` 的話輸出全是亂碼
—— 而且重導向到檔案時同樣壞掉,所以不是終端機顯示問題,是真的寫錯位元組。
**每個執行檔的 `main` 都要設。**

## 外部工具

| 工具 | 用途 | 狀態 |
|---|---|---|
| 7-Zip | rar / 7z 解壓與列表 | ❌ **未安裝,需要手動安裝** |
| ImageMagick | TIFF / PSD / HEIC 縮圖 | ❌ 未安裝(選配) |
| WinRAR | rar 備援 | ✅ 已安裝 |

缺席的 sidecar 不會讓對應素材無法索引,只是沒有預覽圖;
`assetdb doctor` 會列出受影響的項目。
