---
id: enhance-0014
type: enhance
title: ts-types-drift-check
description: 加上 CI 檢查確保前端型別檔是最新產物
status: done
created: 2026-08-16
updated: 2026-08-19
related-adr: [adr-0001]
related-spec: []
---

## 缺少 CI 檢查:`web/src/api/types.ts` 是否為最新產物

### 現況說明

`server/src/AssetDB/Server/TsTypes.hs` 是型別產生器,`TsTypesSpec` 保證它與
`Api.hs` 的 `ToJSON` 定義一致,但**沒有任何機制保證磁碟上的 `web/src/api/types.ts`
(前端實際編譯用的那份)有重新產生**。忘記執行 `--emit-types` 時,前端照樣編譯通過,
只是型別已經與後端實際回應脫鉤,問題會在執行期才被發現(如欄位改名後前端讀到
`undefined`)。

### 修正方案

在 CI(或本機 pre-push 檢查)中,執行 `--emit-types` 產生到暫存檔,與
`web/src/api/types.ts` 做逐位元組比對,不一致時使檢查失敗並提示執行
`--emit-types` 更新。

### TodoList

- [x] T1: 新增檢查(`TsTypesDriftSpec`),比對產生器輸出與 `web/src/api/types.ts`
- [x] T2: 接入 `cabal test all`(以 assetdb-server-test 的一部分執行;專案目前無 CI 設定)

### 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `TsTypesDriftSpec 對目前 checked-in 的 types.ts 比對通過` | 正常情況下應該一致(否則代表現在就已經漂移) |
| T1 | `TsTypesDriftSpec 對刻意修改過的 types.ts 偵測到差異` | 驗證檢查機制本身有效 |
| T2 | 人工確認 CI pipeline 執行此檢查 | 非單元測試,查 CI 設定檔 |

### 實作備註

- 檢查以測試而非獨立腳本實作:`server/test/AssetDB/Server/TsTypesDriftSpec.hs`
  直接拿產生器的 `tsDefinitions`(`--emit-types` 寫出的就是它)與磁碟上的
  `web/src/api/types.ts` 比對,不一致時的失敗訊息附上修復指令
  (`cabal run assetdb-server -- --emit-types web/src/api/types.ts`)。
- 比對前先剝掉 `\r`:產生器寫 LF,但 git 的 autocrlf 可能把簽出檔轉成 CRLF ——
  那是行尾政策,不是漂移。
- **T2 現況**:專案沒有任何 CI 設定檔,檢查落在文檔允許的替代位置
  (`cabal test all` 的一步);未來建 CI 時只要跑 `cabal test all` 就自動涵蓋。
- 現況驗證:目前 checked-in 的 types.ts 與產生器輸出**一致**(檢查通過,
  尚無漂移);刻意加料的內容則被偵測為差異。改善前後:漂移從「執行期才以
  undefined 欄位浮現」變成「測試階段就紅」。
