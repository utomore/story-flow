---
id: F006
type: feature
title: thumbnail-pipeline
description: 縮圖產生與以內容雜湊為鍵的快取
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001, F002]
related-adr: [ADR-002]
---

# F006: 縮圖管線

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

為每一份**唯一內容**產生多種尺寸的縮圖,快取在磁碟上供前端與 AI 標註讀取。

兩個設計決定值得記下來:

**縮放演算法要分方向。** 素材庫絕大多數是 32×32 的像素圖示,而網格要顯示 128px——那是**放大**,不是縮小。雙線性內插會把像素邊緣糊成一片,像素風完全消失。所以放大一律用最近鄰,而且**取整數倍**再置中,這樣每個原始像素在縮圖上都是一個乾淨的方塊。真正需要縮小的只有少數大圖(spritesheet、參考照片),那時才用面積平均——最近鄰縮小會直接丟掉大部分像素,細線條與文字會斷斷續續。

**快取以 blob 的 SHA-256 為鍵,不是以資源為鍵。** 多家廠商附上同一份免費字型或範例圖時只算一次;而且素材重新命名、搬家、重新匯入都不會讓快取失效——內容沒變,縮圖就沒變。快取路徑以雜湊前兩碼分層,避免單一目錄塞進數千個檔案。

畫布一律是正方形而不是貼合原圖比例,因為前端的虛擬化網格需要**固定的格子高度**才能正確計算捲動位置;讓每張縮圖自己決定高度會讓捲動條在載入過程中跳動。

## 落地位置

| 模組 | 檔案 | 職責 |
|---|---|---|
| `AssetDB.Ingest.Thumb` | `ingest/src/AssetDB/Ingest/Thumb.hs` | 解碼、縮放、編碼(**純函數**);定址規則 re-export |
| `AssetDB.Ingest.ThumbRun` | `ingest/src/AssetDB/Ingest/ThumbRun.hs` | 批次產生、快取存在性判斷、`blobs.thumb_status` 維護 |

`ThumbSize` / `thumbSizes` / `thumbPath` 的**唯一實作在 catalog 的 `AssetDB.PathText`**(enhance-0012):產生端(這裡)與讀取端(`ai`、`server`)必須是同一套定址規則,否則縮圖找不到卻不報錯,是靜默失敗。`AssetDB.Ingest.Thumb` 以 re-export 維持既有 API,呼叫端不變。

## 對外行為

- `makeThumb :: ThumbSize -> ByteString -> Either Text ByteString` — 解碼任意支援的點陣格式、縮放、編碼成 **PNG**。輸出 PNG 而非 WebP:WebP 需要外部編碼器,而縮圖總量只有數百 MB,省下的頻寬不值得多一個 sidecar 相依。壞掉的輸入回 `Left`,不拋例外。
- `renderThumb :: Int -> Image PixelRGBA8 -> Image PixelRGBA8` — 純縮放,匯出讓縮放行為可以逐像素驗證。輸出永遠是 n×n;來源置中,邊緣填透明;放大取整數倍最近鄰,縮小取面積平均。
- `ThumbSize` / `thumbSizes` / `thumbPath` — re-export;`thumbPath` 由快取根目錄 + 內容雜湊 + 尺寸決定檔案位置。
- `generateThumbs :: Store -> ArchiveTools -> ThumbOptions -> IO ThumbReport`
  - 待辦清單來自 `blobs`:kind 為圖片、且(非強制時)狀態為 pending,依內容雜湊去重——為每一份唯一內容產生一次,不是為每一筆資源。
  - 全部尺寸的快取檔都在且未強制時跳過並標記成功,計入 `trSkipped`。
  - 內容經 F001 的 `readEntry` 從壓縮檔取出,不落地。
  - 成功寫入全部尺寸後標記 `thumb_status = 'ok'` 並清除錯誤訊息。
  - 失敗(讀取失敗、格式錯誤、例外)**記在資料庫裡**:`thumb_status = 'failed'` 加上錯誤訊息,否則每次重跑都會再試一次同一批壞檔案。同時計入 `trFailed`。
- `ThumbOptions` / `defaultThumbOptions` — 快取根目錄、素材庫根目錄、是否強制重產、進度回呼(當前/總數/雜湊)。回呼預設無操作。
- `ThumbReport` — 產生數、跳過數、失敗清單(雜湊 + 錯誤)。

## 驗收依據

- `ingest/test/AssetDB/Ingest/ThumbSpec.hs`
  - `renderThumb`:「輸出永遠是正方形」「非正方形的來源會置中,不會被拉伸」「放大用最近鄰:原始像素變成乾淨方塊,不產生中間色」「放大取整數倍,不會產生半個像素」「縮小用面積平均:細節不會整片消失」
  - `makeThumb`:「吃得下真的 PNG,吐得出真的 PNG」「壞掉的輸入回報錯誤而不是爆炸」
  - `thumbPath`:「以雜湊前兩碼分層,避免單一目錄塞六千個檔案」「不同尺寸不同檔名」
