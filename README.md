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
| `ingest/` | 掃描、內容雜湊、格式處理器註冊表 |
| `cli/` | `assetdb` 執行檔 |

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

- **`assetdb-ingest` + `assetdb` CLI** — 30 個測試

  ```bash
  assetdb scan --root "C:/path/to/library"
  ```

  ```bash
  assetdb doctor
  ```

  ```bash
  assetdb tools
  ```

  對真實素材庫的執行結果(3.42 GB,102 秒):

  | | |
  |---|---:|
  | 壓縮檔 | 27 |
  | 壓縮檔內項目 | 6,393 |
  | 散檔 | 5,429 |
  | 唯一內容(blobs) | 6,239 |
  | **散檔雜湊已在壓縮檔內** | **5,424 / 5,429** |

  未覆蓋的 5 個全部是工作室自有內容。重構的刪除閘門因此有 SHA-256 等級的依據。

  重掃時壓縮檔雜湊未變就整包跳過,所以第二次執行是 0 秒。

## 五個實測發現

**1. GHC 的 `llvm-ar` 不吃含空格的路徑。** 見上。

**2. FTS5 的 `trigram` tokenizer 查詢下限是三個字元。**
中文雙字詞(金門、行銷、廟宇、素材)因此完全搜不到。
解法是額外一張 `unicode61` 索引,存放由 `AssetDB.Store.Tokenize`
預先展開的 unigram 與 bigram —— 兩者必須分成不同欄位,
混在同一欄會打亂片語查詢的相對位置。

搜尋路徑因此是:純 ASCII 與三字以上中文走 `assets_fts`(trigram),
三字以下中文走 `assets_cjk`(unicode61 + 自製 n-gram)。

**3. `.7z` 與 `.zip` 的 `7z -slt` 輸出對目錄的表示方式不同。**

```
.zip 的目錄   Folder = +        Attributes = D drwxrwxrwx
.7z  的目錄   (沒有 Folder 欄位) Attributes = RD
```

原本只檢查 `Attributes` 開頭是不是 `D` —— 對 zip 正確,對 7z 全數漏判,
1,693 個檔案的素材包因此多出 38 筆假項目。正確作法是把第一個空白分隔的權杖
當成屬性旗標集合。

`.7z` 的時間戳還帶小數秒(`16:12:47.3249489`),用 `%S` 嚴格解析會**靜默**全數失敗。

**4. `Data.Text.IO` 的讀寫都用 locale 編碼,不是 UTF-8。**

這比 stdout 那個嚴重:它會**寫壞我們自己產生的檔案**。`pack.toml` 含中文註解與
`⚠`,在 Windows 上 `TIO.writeFile` 直接拋 `cannot encode character '\9888'`;
讀回來時 `TIO.readFile` 又 `cannot decode byte sequence starting from 231`。

所有文字檔 I/O 一律 `BS.writeFile p (encodeUtf8 t)` 與 `decodeUtf8 <$> BS.readFile p`。
**讀與寫都要明確** —— 只修一邊會變成寫得出去讀不回來。

**5. GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。**
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
