# aapms — 專案指示

設計文檔在 `.lawful/`,用 lawful 的開發模式;程式碼與文檔的對帳由 `lawful` CLI 機械執行。

## 先讀什麼
- `.lawful/system.md`:目的、建置 / 整套測試 / 子集測試三道指令、四層邊界、對外 I/O、Pipelines 表。
- `.lawful/modules.md`:每個模組住 types / effects / pure / shell 哪一層。import 只能往下:types ← effects ← pure ← shell。
- `.lawful/pipelines/P-00x-<slug>.md`:每條資料流的 Stages(逐字簽名)、Laws(三行:forall / given / |-)、Examples、決定、修訂記錄。
- `.lawful/adr/`:架構決策;ADR-023 是效果層(effectful)的做法。

## 規則
- `status: frozen` 的 pipeline 不直接改:簽名、law、層要動一律走 REV(`lawful:revise`),寫進「修訂記錄」,重委派 qa / impl。
- 每條 law 對應一個帶歸屬字串 `P-00x#LAW-n` / `P-00x#EX-n` 的測試(hspec + hedgehog);law 只引用 Stages 簽名、types 層匯出與字面值。
- 效果是描述(`Aapms.*.Effect.*`,`makeEffect_`),純解譯器住 pure 或 effects,真解譯器住 shell(`*.IO` / `*.Sqlite`);shell 進入點(`!` 列)只做 `runEff (run…IO (… (純的整條)))`。
- 型別層只有值型別、smart constructor、存取子、instance;非法狀態用型別收掉(例:`SourceName` 非空)。
- 新模組要登記在 `.lawful/modules.md`;`lawful lint all` 與 `lawful status --tests <log>` 是驗收的兩道指令。
- cabal 前先 `chcp.com 65001`;整套測試用 `cabal test all -j1 --test-show-details=direct`,輸出留檔給 `lawful status --tests`。
- `legacy/`、`cli/`、`api/`、`server/`、`mcp/` 是凍結的舊套件(不在建置範圍),不算呼叫端。
