---
id: F005
type: feature
title: project-scaffold
description: 專案樣板、單筆解壓、manifest 與 Assets.hs 產生、授權閘門
status: done
created: 2026-08-19
updated: 2026-08-19
depends-on: [F001]
related-adr: [ADR-001, ADR-002, ADR-003, ADR-004]
---

# F005: 專案產出

> **回溯建檔**:本功能在 2026-08 導入 dev-flow 三層流程之前就已完成並通過測試,
> 本文檔是遷移到 `.design/` 時依既有程式碼與測試回溯整理的紀錄,因此沒有當初的
> TodoList 與 1-to-1 測試對照表。後續變更請走 `/enhance-design` 或 `/bugfix`。

## 功能說明

素材庫的最終用途是進到遊戲專案裡。`assetdb new-project` 一次做完:建立專案鷹架、
過授權閘門、把選中的素材從壓縮檔裡**單筆取出**、產生 `manifest.json` 與型別安全的
`Assets.hs`、並把專案登記回資料庫。

四個設計決定:

1. **樣板是資料,不是程序。** 樣板以「路徑 → 內容」的清單表示,而不是一段建立目錄的
   程式,所以「這個樣板會產生什麼」可以在不碰檔案系統的情況下完整測試。
2. **永遠不整包解開壓縮檔。** 專案只拿它真正用到的東西。
3. **產生 `Assets.hs` 而不是讓遊戲用字串查表。** 載入器是 `HashMap Text Texture`,
   字串打錯的後果是執行期黑畫面,而且通常在展示前五分鐘才發現。產生一個模組之後,
   打錯變成編譯錯誤;而且 IDE 的 find-references 直接回答「這個專案用了哪些素材、
   每個素材用在哪裡」——那是資料夾與試算表都給不出的答案(ADR-004)。
4. **授權閘門是 `pack.toml` 的 `commercial` 欄位唯一有實際效果的地方**,而且
   **授權未查證(NULL)等於不可用**——沒查證時不該放行。
5. **專案要登記進資料庫**,否則 links 無從指向它,而且沒有人回答得了「這個素材被哪些專案
   用了」;`copied_sha256` 記錄複製當下的內容雜湊,讓「專案裡的素材被改過」與「來源壓縮檔
   更新了」可以分辨。

## 落地位置

- `project/src/AssetDB/Project/Template.hs` —— `TemplateFile`、`templateDirs`、
  `templateFiles`、`creditsSection`
- `project/src/AssetDB/Project/Assets.hs` —— `AssetRef`、`renderAssetsModule`、`haskellIdent`
- `project/src/AssetDB/Project/Create.hs` —— `CreateOptions` / `CreateResult` /
  `createProject`(編排)、`nonCommercialPacks`(授權閘門)
- `cli/app/AssetDB/Cli/Project.hs` —— `ProjectArgs`、`runNewProject`:參數翻譯、
  素材庫根目錄推導、進度輸出、結束碼與後續步驟提示

## 對外行為

```text
assetdb new-project --name <NAME> --path <PATH> [--pack SLUG]… [--match Q] [--allow-non-commercial]
```

- **前置條件**:目標目錄必須不存在或為空,否則不動任何檔案並回報。
- **素材選取**:限定素材包(可重複)與/或邏輯名稱子字串;只取「已指定邏輯名稱、狀態 active、
  且有內容雜湊」的素材,依邏輯名稱排序。
- **授權閘門**:不可商用、以及授權未查證的素材包**整包擋下**並逐包印出告知;
  `--allow-non-commercial` 才會關掉(旗標的說明明講「只在確定專案不商業發行時使用」)。
- **產出目錄樹**:
  - `assets/<kind 預設目錄>/<邏輯名稱><副檔名>` —— 單筆解壓,副檔名抽取走 catalog 的
    共用實作
  - `assets/manifest.json` —— catalog 的 `Manifest` schema(schema 版本、專案名、時間戳、
    素材清單、素材包與授權中繼資料),以 pretty JSON 寫出
  - `assets/Assets.hs` —— 每個素材一個 `AssetKey` 常數,依 key 排序,識別字撞名時去重
  - `<NAME>.cabal` —— 以專案名為套件名的最小 executable,h-raylib / apecs 相依先註解起來
  - 樣板檔案:`SKILL.md`(接手的人或 AI agent 第一件事就是讀它)、`README.md`、
    `docs/提案書.md`、`docs/技術文檔.md`、`docs/decisions/ADR-0001-記錄架構決策.md`、
    `.gitattributes`(二進位素材交給 LFS)、`.gitignore`、`assets/theme/theme.json`
  - 目錄骨架含尚未使用的 `assets/audio/{sfx,bgm}` 與 `docs/decisions`、`.assetdb`
    ——先建好,音效功能上線時不需要有人記得補
- **致謝區塊**:依實際納入的素材包產生,需署名的素材包會被特別標出;完成訊息提醒
  「若致謝區塊有標記需署名的素材包,發行時必須列入致謝畫面」。
- **識別字轉換**:`ui_gui_travel-book-frame_01a` → `uiGuiTravelBookFrame01a`;
  開頭是數字時前置底線(Haskell 識別字不能以數字開頭,而 `00.png` 這種檔名真的存在)。
- **回報與結束碼**:印出複製筆數、讀取失敗筆數(最多列出前幾筆)、被擋下的素材包;
  一筆都沒複製時以非 0 結束碼結束,並提示可能是條件太窄或素材尚未命名(`assetdb cluster apply`)。
- **檔案編碼**:一律以 UTF-8 位元組寫檔(`Data.Text.IO` 用 locale 編碼,Windows 上寫不出
  中文與符號)。
- **單模板**:`projects.template` 一律記為 `haskell-raylib-2d`。該欄位是為未來多模板預留,
  在第二套鷹架存在之前**刻意不開 `--template` 參數**,免得出現「可以指定但沒有效果」的假選項。

## 驗收依據

`project/test/` 與 `cli/test/`(hspec;`cabal test all` 全綠):

- **`project/test/AssetDB/Project/CreateSpec.hs`** —— 授權閘門(`nonCommercialPacks`
  單獨匯出正是為了讓這道帶法律後果的防線被直接測到;走 `createProject` 需要一整組真實
  壓縮檔與 `ArchiveTools`,那樣的測試貴到不會有人寫)
  - 「擋下 license_id 為 NULL 的素材包」
  - 「擋下明確標記不可商用的素材包」
  - 「放行可商用的素材包」
  - 「混合輸入時只回傳擋下的那些」
  - 「NULL 與 0 在閘門這一側等價」
  - 「空清單直接回空,不查資料庫」
  - 「重複的 slug 不會讓同一包被擋兩次以上而改變語意」
- **`project/test/AssetDB/Project/TemplateSpec.hs`**
  - `templateDirs`:「音效目錄先建好」、「含 ADR 目錄」
  - `templateFiles`:「SKILL.md 是給接手的人與 AI agent 讀的第一份文件」、
    「SKILL.md 明確禁止手動複製素材」、「gitattributes 把二進位素材交給 LFS」、
    「產生提案書與技術文檔」、「所有路徑都是相對的」
  - `creditsSection`:「需署名的素材包會被特別標出」、「沒有需署名的就不加警告」、
    「沒有素材時給明確訊息而不是空表格」
- **`project/test/AssetDB/Project/AssetsSpec.hs`**
  - `haskellIdent`:「邏輯名稱轉成 camelCase」、「開頭是數字時前置底線」、
    「空輸入不會產生非法識別字」
  - `renderAssetsModule`:「產生可編譯的模組標頭」、「每個素材一個常數,型別是 AssetKey」、
    「標明為產生檔」、「識別字撞名時去重 —— 產生重複定義的模組根本編不過」
- **`cli/test/AssetDB/Cli/ParserSpec.hs`** —— 指令介面側(`new-project` 段):
  「--name 與 --path 都是必填」、「授權閘門預設是開的」、
  「--allow-non-commercial 要明講才會關掉閘門」
