---
id: P-012
description: library/ 下的壓縮檔以 sha256 為身分,不解壓列條目、逐條雜湊、格式處理器取 meta,產生或更新 pack.md 與索引,結尾反向對帳 orphan
status: draft
updated: 2026-09-06
---
# P-012-asset-scan:library/ 下的壓縮檔以 sha256 為身分,不解壓列條目、逐條雜湊、格式處理器取 meta,產生或更新 pack.md 與索引,結尾反向對帳 orphan

## Brief
S4 的第一條里程碑,原 assetdb 的 ingest 移植。input 是 asset vault 的 `library/` 下每個壓縮檔(zip 原生讀 central directory,rar / 7z 交給 7-Zip sidecar)與既有的 `pack.md`;output 是每個 pack 一份 `pack.md`(檔案層是 pack、每節一筆 asset,短 id、sha256、entry、ext、kind 專屬 meta)與索引更新,以及掃描結束的 orphan 對帳報告。流向:走訪 `library/packs/**` 與 `reference/`、`studio/` → 以壓縮檔 sha256 識別 pack(新 pack:列條目不解壓、逐條 SHA-256、格式處理器取 meta、產生 pack.md;已知 pack 但路徑變了:只更新 archive 欄位,id 與人給欄位全部保留)→ 掃描結束索引裡有、磁碟上沒有的 pack 標 missing 不刪 → 經 P-003-node-write 落地、P-001-index-rebuild 更新索引。壓縮檔的走訪與條目讀取是 `Archive` 效果,純解譯器跑在記憶體的壓縮檔目錄表上;掃描的規劃(哪些 pack 新、哪些搬了、哪些消失、每筆 asset 的 id 與欄位)是純函數。它是 S4 的里程碑「搬動與刪除 pack 不留幽靈;對真 vault 27 個 pack、6,783 筆資源跑得完,rm index.db 後重建等價」。Stages 與 laws 待 S4 設計時寫;願望模組 `Aapms.Ingest.Scan`、`Aapms.Archive.Effect`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **pack 身分以壓縮檔 sha256 為鍵,不以路徑;掃描結束反向對帳 orphan。** 否決:以路徑為鍵。理由:修掉「搬動留幽靈、刪除留幽靈」的已知缺陷(system.md 資料流 A)
- **掃描永遠不覆寫已有的人給欄位(name、tags、summary、license、author、links);掃描寫 `source: scan`。** 否決:每次掃描重寫整份 pack.md。理由:pack.md 是人給中繼資料的真相(ADR-013)
- **不解壓、不複製:條目清單與 sha256 直接從壓縮檔讀。** 否決:先解壓到暫存。理由:3.2 GiB 的素材庫,解壓成本與磁碟都付不起(ADR-020)
- **rar / 7z 交給 7-Zip sidecar,缺席只影響那些 pack 的預覽與縮圖,不影響 zip 的索引。** 否決:自己實作 rar。理由:ADR-020
- **消失的 pack 標 missing,不刪節點。** 否決:自動刪。理由:人決定;雲端同步中途的暫時消失不該毀掉中繼資料

## 修訂記錄
無
