---
id: P-014
description: 未命名 asset 的檔名經叢集推論命名規則,預覽後 --confirm 才依命名文法寫回 name
status: draft
updated: 2026-09-06
---
# P-014-name-cluster:未命名 asset 的檔名經叢集推論命名規則,預覽後 --confirm 才依命名文法寫回 name

## Brief
S4 的第三條里程碑,原 assetdb 的檔名叢集命名。input 是 vault 裡尚未命名(`name` 為空)的 asset 的原始檔名與既有的命名規則;output 是推論出的規則(哪一組檔名對應到命名文法的哪個 kind / domain / subject,序號怎麼取)與套用後的邏輯名稱。流向:按 pack 與路徑把檔名分群 → 對每群推論規則(前綴、分隔符、序號樣式)→ 產出符合 P-022-logical-name 文法的候選名稱 → 預覽;`--confirm` 才經 P-008-graph-write 的 asset 命名寫回,名稱全域唯一由 P-008 擋。叢集推論與名稱產生全是純函數;它是重管線指令,只在 CLI。Stages 與 laws 待 S4 設計時寫;願望模組 `Aapms.Ingest.Cluster`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **預設只預覽,`--confirm` 才寫入。** 否決:直接套用。理由:批次與管線類動作的通則(system.md CLI 契約)
- **候選名稱必須過 P-022 的命名文法與 nvKinds,否則不列進預覽。** 否決:先寫再驗。理由:名稱是 Assets.hs 的 key
- **規則住 vault 的 Markdown(pack.md 或 naming 節),不住索引。** 否決:存 DB。理由:檔案是真相

## 修訂記錄
無
