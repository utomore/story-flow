# Changelog — assetdb-core

## 0.1.0.0 (未發布)

- 領域型別 `AssetDB.Types`:`AssetKind` / `KindPrefix` / 狀態 / 關聯圖列舉,
  全部以穩定文字而非序號持久化。
- `AssetDB.Id`:ULID 產生與 Crockford Base32 編解碼。
- `AssetDB.Naming`:統一命名規範的文法 —— 建構、渲染、解析、驗證,
  外加給 ingest 用的文字正規化基本操作。
- `AssetDB.Manifest`:`assets/manifest.json` schema(schemaVersion 1),
  與遊戲本體共用。
