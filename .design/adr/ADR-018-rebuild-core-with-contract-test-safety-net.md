---
id: ADR-018
type: adr
title: rebuild-core-with-contract-test-safety-net
description: 以重建核心的方式整合,契約層測試先釘死當安全網,真實資料 P2 進場
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-018: 重建核心、契約測試先行、真資料早進

## 狀態(Status)

accepted

## 背景(Context)

統一 `Meta`(ADR-012)、真相落檔(ADR-013)、單一 id(ADR-014)、八子系統(ADR-015)加起來不是
「把兩棵樹放在一起」能做到的——它要求 `core` / `store` / `service` 依新模型重寫。問題變成怎麼改:

- story-flow 有 20,297 行測試,大多綁在舊型別上;assetdb 有 7,363 行,覆蓋 54%
- 兩邊都在生產使用:assetdb 索引著 3.2 GiB 真實素材庫(6,783 筆、1,653 筆人工命名);
  story-flow 在這台機器上**沒有任何 vault**——所有資料遷移成本都在 assetdb 那一側
- 合併評估報告建議「每期可建置可交付」,但收斂核心型別這種改動很難切成小步,硬切會靠暫時的
  轉接層撐,而那些撐子最後未必拆得掉

## 決策(Decision)

**一、重建核心,舊程式碼當素材搬。** `aapms-core` / `-store` / `-service` 依新模型重寫;
assetdb 的 `archive` / `ingest` / `reorg` / `project` / `ai`,story-flow 的 `md` / `conflict` /
`workshop` / `api` / `cli` / `server` / `mcp` 當可搬的零件改接新底座。接受中間有一段兩邊功能都不
完整的時期(P1–P2),換真正一份的核心。

**二、契約層測試先釘死,在 P0 就立起來。** 這些測試只依賴對外契約,不依賴內部型別,整個重建期
都有效:

| 契約 | 測試什麼 |
|---|---|
| CLI 信封 | `--json` 輸出形狀、`code` 穩定識別碼、exit code 三級 |
| Markdown roundtrip | 解析 → 寫回 → 再解析不失真;未修改區塊位元組相同 |
| 索引等價 | `rm index.db` → rebuild 後查詢結果與重建前相同 |
| 相依方向 | `CabalSpec` 逐字清單(四條規則) |
| OpenAPI | 由型別推導的文件與 golden file 一致 |
| 命名文法 | 合法/非法名稱集 |

內部單元測試隨模組重寫,不逐一改寫舊的。

**三、真實資料 P2 進場。** `graph-core` 一完成就寫一次性匯出器,把 `alchbees-assets` 的
`assetdb.sqlite` 匯成 `pack.md`,拿 6,783 筆真資料驗證統一 `Meta` 與 schema——在 schema 還改得動
的時候發現問題,而不是建了五層之後。

**四、匯出器是拋棄式程式碼。** 不重算雜湊(沿用 `sha256` 與 85 MB 縮圖快取)、重發短 id、
對帳 1,653 筆命名零遺失、匯出後與舊 DB 對帳;完成即從 `cabal.project` 移除,不進任何子系統。

**五、P0 是純機械改動,單獨 commit。** repo 讓名改名、兩樹合一、`Aapms.*` 前綴、搬 ADR、立契約
測試——零邏輯改動,`cabal build all` 與契約測試是唯一的驗收。越晚做衝突越大。

**六、web 前端 P7 才接回。** 核心重建期間不維護;`types.ts` 是產生物,API 穩定後重產即可。

## 考慮過的替代方案(Alternatives Considered)

- **全期保持可建置可交付**(報告原案):安全。放棄的理由見背景——核心型別收斂切不成小步,
  靠轉接層撐會留下一批最後拆不掉的撐子;而且 story-flow 零生產資料,「可交付」對它沒有實質意義。
- **從零重寫**:架構最乾淨。放棄的理由是丟掉 27,000 行測試累積的行為保證與 assetdb 踩過的
  Windows / 壓縮檔 / 編碼坑(建置路徑空格、`SetConsoleOutputCP`、`Data.Text.IO` 吃 locale、
  PowerShell `Select-Object` 殺上游)。
- **舊測試全數同步改寫**:任何一刻都全綠。放棄的理由是大量工作花在改那些最後還要再改一次的
  測試上。
- **重建期間允許紅燈、最後補齊**:最快。放棄的理由是 assetdb 側本來就只有 54% 覆蓋,兩邊同時
  失去保護的話回歸會很難查;契約測試是折衷——它們便宜、穩定、不綁型別。
- **人工重建舊資料,不寫匯出器**:不寫拋棄式程式碼。放棄的理由是 1,653 筆命名背後的 6 次叢集
  確認是人工判斷,重做的成本遠高於一個匯出器。

## 影響(Consequences)

**正面**

- 核心真正只有一份,沒有轉接層遺留
- 契約測試在整個重建期間是有效的安全網,且重建完成後仍是回歸測試
- 真資料在 P2 就驗證過 schema,P3–P6 不會回頭改 `Meta`

**負面 / 成本**

- P1–P2 期間兩邊功能都不完整,素材庫的日常查詢要用 legacy repo 的舊執行檔頂著
- 匯出器是一次性程式碼,寫完即刪,測試也只活一期
- 內部單元測試覆蓋在 P1–P3 會暫時低於現況;`/arch-audit status` 會反映這點
- 測試行數會下降(舊測試不逐一改寫),不應以行數當指標
