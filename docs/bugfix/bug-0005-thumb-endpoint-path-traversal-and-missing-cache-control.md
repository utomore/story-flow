---
id: bug-0005
type: bug
title: thumb-endpoint-path-traversal-and-missing-cache-control
description: 縮圖端點未驗證 sha 格式且未設定 Cache-Control
status: done
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
---

## `/thumb/:sha/:size` 未驗證 sha 格式(受限路徑穿越),且未依註解設定 Cache-Control

### 問題描述

`/thumb/:sha/:size` 端點直接用 URL 片段組出縮圖檔案路徑,沒有驗證 `sha` 是否為合法的
64 位十六進位字串。servant 的 `Capture` 會把 `%2F` 解碼成 `/`,`sha` 理論上可夾帶 `../`
片段。尾碼被鎖定為 `_128.png`/`_512.png` 使實際危害有限,但仍應在使用前驗證輸入格式。
同一個函式的註解宣稱「可以無限期快取」,但實際上沒有設定任何 `Cache-Control` 標頭 ——
註解與行為不符,快取收益也沒拿到。

### 重現方式 / 現況證據

`server/src/AssetDB/Server/App.hs:109-115`(`thumbH`):直接以 `sha` 參數組檔案路徑,
無格式驗證;回應未附加任何 `Cache-Control` 標頭。

### 根本原因

`sha` 參數的合法性(64 位十六進位、對應 `blobs.sha256`)只由呼叫端(前端 `thumbUrl`)
隱含保證,伺服器端沒有重新驗證外部輸入。快取標頭的註解是意圖記錄,但實作時遺漏。

### 影響範圍

- `server/src/AssetDB/Server/App.hs`(`thumbH`)

### 修正方案

1. 進入 `thumbH` 時驗證 `T.all isHexDigit sha && T.length sha == 64`,不合法時回 400。
2. 加上 `Cache-Control: public, max-age=31536000, immutable`(縮圖路徑是內容定址,內容
   不會變,適合永久快取)。

### TodoList

- [x] T1: `thumbH` 驗證 `sha` 為 64 位十六進位字串,不合法時回 400
- [x] T2: `thumbH` 回應加上 `Cache-Control: public, max-age=31536000, immutable`

### 1-to-1 測試對照表

| Todo | 測試 | 說明 | 結果 |
|------|------|------|------|
| T1 | `AppSpec.thumbH 對含路徑分隔符的 sha 回 400` | 驗證輸入含 `../` 或 `%2F` 時被擋下 | ✅ |
| T1 | `AppSpec.thumbH 對長度不符的 sha 回 400` | 長度邊界 | ✅ |
| T1 | `AppSpec.thumbH 對合法 64 位 hex sha 正常回應` | 確認正常路徑未被誤擋 | ✅ |
| T1 | `AppSpec.thumbH 縮圖不存在時回 404,而不是 400` | 驗證失敗與查無資料是兩件事 | ✅ |
| T1 | `AppSpec.isThumbSha 接受/拒絕` | 純函數的邊界值(63/64/65 位、非 hex、空字串) | ✅ |
| T2 | `AppSpec.thumbH 回應包含正確的 Cache-Control 標頭` | 檢查回應 header | ✅ |

### 修法摘要

- 新增 `isThumbSha :: Text -> Bool`(`T.length == 64 && T.all isHexDigit`),`thumbH` 以
  guard 擋在組路徑之前,不合法回 400。
- `Api.hs` 的 thumb 端點回傳型別改為
  `ThumbResponse = Headers '[Header "Cache-Control" Text] BS.ByteString`,handler 用
  `addHeader thumbCacheControl`。**把標頭寫進型別**而不是在 handler 裡 `pure` 一個裸
  ByteString,是為了讓「忘了加快取標頭」變成編譯錯誤 —— 這個 bug 的另一半正是註解宣稱有
  快取而實作漏掉。

### 實作備註

- 新增 `utf8Err`:`errBody` 是 lazy `ByteString`,原本 `err404 {errBody = "no thumbnail"}`
  走 `OverloadedStrings` 的 `IsString ByteString`,那會把非 ASCII 逐字元截成低位元組。
  錯誤訊息改成中文的同時必須明確走 UTF-8 編碼,否則使用者拿到亂碼。
- 測試用了一個約十行的 WAI 驅動器(`runGet`)直接打 `application`,而不是引入
  `wai-extra` 的 `Network.Wai.Test`。`wai` / `http-types` 已在相依閉包內,只需列進
  test build-depends;為十行程式碼拉進一整個套件不划算。
