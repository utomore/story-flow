---
id: F003
type: feature
title: ts-type-contract
description: 後端型別產生器與前端 TypeScript 型別契約
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F002]
related-adr: [ADR-001]
---

# F003: 前端型別契約

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

後端的 JSON 回應形狀與前端的 TypeScript 型別必須一致。這個功能用「產生器 + 一致性測試」
達成,而不是用 `servant-openapi3 → openapi-typescript`:那條路徑要拖進 OpenAPI 的整套型別
機器,再加一個 Node 工具鏈步驟,只為了描述四個端點與六個物件。API 面積小到自己產生更划算,
而且沒有額外相依。

代價是「產生器可能與 `ToJSON` 不同步」與「磁碟上的產物可能忘記重新產生」。兩者都不靠紀律,
而各有一道測試:

- **一致性**:把每個型別的 JSON 實際欄位名抽出來,與產生器宣告的欄位比對。改了一邊沒改
  另一邊,測試就紅。
- **防漂移**:比對磁碟上 checked-in 的 `web/src/api/types.ts` 是否等於產生器當下的輸出。
  少了這道的話,忘記跑 `--emit-types` 時前端照樣編譯通過,型別卻已與後端脫鉤,問題拖到
  執行期才以 `undefined` 欄位的形式浮現。

兩道測試都跑在 `cabal test all` 裡。

## 落地位置

- `server/src/AssetDB/Server/TsTypes.hs` —— `TsType` / `TsField` 的型別宣告表、
  `tsDefinitions`(渲染)、`tsFieldsOf`(供一致性測試取用)
- `server/app/Main.hs` —— `--emit-types <輸出檔>` 分支,以 UTF-8 位元組寫檔
  (`Data.Text.IO` 用 locale 編碼,Windows 上會寫壞非 ASCII 內容)
- `web/src/api/types.ts` —— checked-in 的產物,檔頭標明「請勿手動編輯」與重新產生的指令
- `server/src/AssetDB/Server/Api.hs` —— 手寫 `ToJSON` 是這個契約的另一端

## 對外行為

- 產生指令:`cabal run assetdb-server -- --emit-types web/src/api/types.ts`,
  寫檔後印出已寫入的路徑。
- 產出六個 interface:`SearchItem`、`SearchResponse`、`FacetValue`、`Facets`、
  `PackSummary`、`Health`。
- `Maybe` 欄位在 TS 側是 `string | null`,非 `Maybe` 欄位不是——否則前端會在 `name`
  為 null 時炸掉。
- `Facets` 與 `FacetValue` 只存在於 TS 側:`/api/facets` 的 handler 直接組 JSON 物件,
  Haskell 沒有對應的 record,但欄位仍由產生器集中宣告。
- 產物檔頭固定含「請勿手動編輯」字樣,避免有人手改後被下一次產生覆蓋。
- 型別只在編譯期生效:不產生執行期驗證器。查詢參數不在契約範圍內,由前端的 `Query`
  型別手動維持對應。

## 驗收依據

`server/test/`(hspec;`cabal test all` 全綠):

- **`server/test/AssetDB/Server/TsTypesSpec.hs`** —— 產生器與 `Api.hs` 的 `ToJSON` 一致
  - 「TypeScript 定義與 JSON 輸出一致」:逐型別比對 JSON 鍵集合與宣告欄位集合,
    案例為 `SearchItem`、`SearchResponse`、`PackSummary`、`Health`
  - 「產生的定義 / 含有所有型別」:六個 `export interface` 都在
  - 「標明為產生檔,避免有人手動編輯」
  - 「可為 null 的欄位在 TS 側也是可為 null」(同時確認非 `Maybe` 欄位沒有被加上 null)
- **`server/test/AssetDB/Server/TsTypesDriftSpec.hs`** —— 磁碟產物的漂移檢查
  - 「checked-in 的 types.ts 與產生器輸出一致」:讀 `../web/src/api/types.ts`
    (cabal 以套件目錄為工作目錄),檔案不存在或內容不符時失敗,並在訊息裡直接給出
    `--emit-types` 的重新產生指令;比對前濾掉 CR——git autocrlf 造成的行尾差異不是漂移
  - 「內容被改動時偵測得到差異」:驗證比對機制本身有效,多一個位元組就必須不相等
