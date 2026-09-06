---
id: P-013
description: 壓縮檔內影像單筆解碼成縮圖,寫入內容定址的全局快取,同內容只算一次
status: draft
updated: 2026-09-06
---
# P-013-thumb-cache:壓縮檔內影像單筆解碼成縮圖,寫入內容定址的全局快取,同內容只算一次

## Brief
S4 的第二條里程碑。input 是 pack 裡影像類 asset 的位元組(單筆從壓縮檔取出);output 是全局中樞 `cache/thumbs/<aa>/<sha256>.png` 的內容定址縮圖。流向:對每筆 asset-image 依 sha256 查快取 → 沒有才單筆解壓 → JuicyPixels 解碼縮到固定邊長 → 寫進快取(前兩碼分片)。同內容只算一次,兩個 vault 裡同一份位元組共用一張縮圖。解碼是純函數(位元組 → 位元組),取檔與寫快取是 `Archive` 與 `ThumbCache` 效果。只在 CLI 側跑(JuicyPixels 只准出現在 CLI 的相依),HTTP 的 `/thumb/<sha256>` 只讀快取不現場解碼(P-010)。Stages 與 laws 待 S4 設計時寫;願望模組 `Aapms.Ingest.Thumbs`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **縮圖是內容定址的,住全局中樞不住 vault。** 否決:縮圖放 vault 內。理由:兩個 vault 的同一份內容只算一次;vault 進 git 不該帶縮圖(system.md 對外介面 4)
- **JuicyPixels 只准出現在 CLI 側;server 與 mcp 禁止依賴 aapms-ingest。** 否決:server 現場解碼。理由:硬規則 3(重量級相依隔離)
- **縮圖失敗只記錄不中止,索引不受影響。** 否決:失敗即中止掃描。理由:縮圖是預覽用的衍生物

## 修訂記錄
無
