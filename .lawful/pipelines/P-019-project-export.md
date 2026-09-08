---
id: P-019
description: 給一個 Level,順 involves 找 Entity、順 uses / depicts 找 Asset,過授權閘門,單筆解壓正規化落成 assets/manifest.json、Assets.hs 與 story/manifest.json
status: draft
updated: 2026-09-06
---
# P-019-project-export:給一個 Level,順 involves 找 Entity、順 uses / depicts 找 Asset,過授權閘門,單筆解壓正規化落成 assets/manifest.json、Assets.hs 與 story/manifest.json

## Brief
O-4 的 M-10,原 assetdb 的 project 擴編。input 是一個 Level 的 Ref、專案名稱與輸出目錄;output 是專案目錄:`assets/manifest.json`(schema 2)、型別安全的 `Assets.hs`(以邏輯名稱為 AssetKey)、複製進來的素材位元組、`story/manifest.json`(故事引用清單:<vault>:<id>、title、summary、用途、revision,不複製)。流向:順 Level 的 involves 找 Entity(跨 vault 用 <vault>:<id>)→ 順那些 Entity 的 uses / depicts 找 Asset → 對每筆 Asset 查授權(non-commercial 或授權未查證一律擋下並列出)→ 通過的單筆從壓縮檔取出(aapms-archive)→ 正規化命名落地 → 產生兩份 manifest 與 Assets.hs;`sync` 是增量版,`add` / `remove` 手動調整清單。連動的圖遍歷、授權閘門、manifest 與 Assets.hs 的產生是純函數(P-023-manifest-codec);讀圖譜是 `Vaults` 效果,取檔與寫專案目錄是 `Archive` 與 `ProjectDir` 效果。它讓 O-4 的 M-10 往前一步,對應 O-4 的判準「建專案 → 挑 Level → 自動帶素材 → 擋授權一條龍」。Stages 與 laws 待 lawful:pipeline 設計時寫;願望模組 `Aapms.Project.Export`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **連動只沿 involves(Level → Entity)與 uses / depicts(Entity → Asset)兩種關聯。** 否決:沿全部關聯。理由:system.md 資料流 B
- **授權閘門:non-commercial 或授權未查證(NULL)一律擋下,列出清單。** 否決:警告放行。理由:專案要能離開 vault 獨立存在且能商用
- **story/ 與 assets/ 同層,故事引用不複製、沒有授權、不進 Assets.hs。** 否決:story 放 assets 底下。理由:Assets.hs 列舉與授權閘門都綁在 assets/
- **project 依賴 aapms-archive(單筆取檔)但不依賴 ingest。** 否決:經 ingest。理由:archive 是最輕的那個套件
- **manifest 一次升到 schema 2,兩份 manifest 各自版本閘門。** 否決:漸進遷移。理由:P-023-manifest-codec 的決定

## 修訂記錄
無
