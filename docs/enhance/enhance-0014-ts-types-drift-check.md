---
id: enhance-0014
type: enhance
title: ts-types-drift-check
description: 加上 CI 檢查確保前端型別檔是最新產物
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0001]
related-spec: []
---

# 缺少 CI 檢查:`web/src/api/types.ts` 是否為最新產物

## 現況說明

`server/src/AssetDB/Server/TsTypes.hs` 是型別產生器,`TsTypesSpec` 保證它與
`Api.hs` 的 `ToJSON` 定義一致,但**沒有任何機制保證磁碟上的 `web/src/api/types.ts`
(前端實際編譯用的那份)有重新產生**。忘記執行 `--emit-types` 時,前端照樣編譯通過,
只是型別已經與後端實際回應脫鉤,問題會在執行期才被發現(如欄位改名後前端讀到
`undefined`)。

## 修正方案

在 CI(或本機 pre-push 檢查)中,執行 `--emit-types` 產生到暫存檔,與
`web/src/api/types.ts` 做逐位元組比對,不一致時使檢查失敗並提示執行
`--emit-types` 更新。

## TodoList

- [ ] T1: 新增檢查腳本,比對 `--emit-types` 產出與 `web/src/api/types.ts`
- [ ] T2: 將檢查腳本接入 CI(或至少接入 `cabal test all` 的其中一步)

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `TsTypesDriftSpec 對目前 checked-in 的 types.ts 比對通過` | 正常情況下應該一致(否則代表現在就已經漂移) |
| T1 | `TsTypesDriftSpec 對刻意修改過的 types.ts 偵測到差異` | 驗證檢查機制本身有效 |
| T2 | 人工確認 CI pipeline 執行此檢查 | 非單元測試,查 CI 設定檔 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
