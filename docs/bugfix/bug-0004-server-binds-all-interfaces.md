---
id: bug-0004
type: bug
title: server-binds-all-interfaces
description: Server 預設綁定所有網路介面且無驗證機制
status: done
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

## Server 預設綁定所有網路介面,同區網任何機器皆可存取,無驗證機制

### 問題描述

`Warp.run` 預設 host 是 `*`(所有介面),同一區網內的任何機器都能搜尋素材、拉縮圖、
讀取 packs 清單,沒有任何身份驗證。單人本機工具目前可以接受無驗證,但不應該預設對
整個區網開放。

### 重現方式 / 現況證據

`server/src/AssetDB/Server/App.hs:37`:直接呼叫 `Warp.run (scPort cfg) app`,未指定 host,
Warp 預設綁定所有介面。

### 根本原因

初始實作沒有考慮「這台機器可能同時在區網環境」的情境,預設值選擇了 Warp 的預設行為
而非最小暴露面。

### 影響範圍

- `server/src/AssetDB/Server/App.hs`(`runServer`)

### 修正方案

改用 `Warp.runSettings` + `setHost "127.0.0.1"` 作為預設值,只綁定本機回送介面。若使用者
確實需要區網存取,提供明確的 `--host` 旗標讓使用者自行選擇並承擔風險,而非預設開放。

### TodoList

- [x] T1: `runServer` 改用 `Warp.runSettings`,預設 `setHost "127.0.0.1"`
- [x] T2: 新增 `--host` CLI 旗標,允許使用者明確指定要綁定的介面

### 1-to-1 測試對照表

| Todo | 測試 | 說明 | 結果 |
|------|------|------|------|
| T1 | `AppSpec.serverSettings 預設只綁定 127.0.0.1` | 檢查 `Settings` 物件的 host 設定值 | ✅ |
| T2 | `AppSpec.serverSettings 明確指定 --host 0.0.0.0 時綁定所有介面` | 確認明確旗標可覆寫預設值 | ✅ |
| T2 | `CliSpec.--host 可以覆寫預設綁定介面,且不影響 db 路徑與 port` | 旗標解析不會吃掉位置參數 | ✅ |
| T2 | `CliSpec.--host 後面接旗標是錯誤,不會把旗標吃掉` | `--host --init` 不得靜默綁到叫 `--init` 的介面 | ✅ |
| T2 | `AppSpec.startupBanner 綁定非回送介面時附上警告` | 開放區網要有看得見的回饋 | ✅ |

### 修法摘要

- `ServerConfig` 新增 `scHost :: String`,預設 `defaultHost = "127.0.0.1"`。
- 新增 `serverSettings :: ServerConfig -> Warp.Settings`,`runServer` 改呼叫
  `Warp.runSettings`。抽成獨立函式的理由與 bug-0002 的 `resolveServerDb` 相同 ——
  `runServer` 會阻塞在 Warp 上,不抽出來就測不到「預設綁在哪」。
- `Cli.hs` 新增 `extractHost` 前處理,支援 `--host <位址>`(可出現在任意位置,後者勝)。

### 實作備註

規格之外多做的兩件事,都源自「這個 bug 的本體是**無驗證的服務被開放**」:

1. **`--host` 的值長得像旗標時拒絕**(`extractHost`)。若照收,`--host --init` 會把伺服器
   綁到一個叫 `--init` 的主機名上,而使用者以為自己開了 `--init` —— 與 bug-0003 的
   partial read 是同一類「參數被吃掉而沒人抗議」的錯誤。
2. **`startupBanner` 印出綁定位址,非回送介面時附警告**。原簽章 `Int -> FilePath -> Int`
   改為 `String -> Int -> FilePath -> Int`。規格只要求「讓使用者自行選擇並承擔風險」,
   但開放區網原本是個完全沒有回饋的動作;不印的話使用者無從得知自己承擔了什麼。
