---
id: ADR-023
description: effects 層用 effectful 的效果描述,每個效果配純解譯器與 shell 真解譯器;業務判斷抽成 pure 的整條
updated: 2026-09-06
---
# ADR-023-effectful-effects-layer:effects 層用 effectful 的效果描述,每個效果配純解譯器與 shell 真解譯器;業務判斷抽成 pure 的整條

## 情境
2026-09-06 從 dev-flow 搬到 lawful 時盤點:`aapms-core` 與 `aapms-md` 零 IO,但 `aapms-store` / `aapms-workspace` / `aapms-service` 幾乎全 IO(`Store.Index` 17 條簽名 15 條 IO、`Workspace.Lifecycle` 12/12、`Service.Machine` 25/19,`ServiceM` 是 `ReaderT Env (ExceptT ServiceError IO)`),沒有效果描述層。lawful 要求每條里程碑有一列純的整條掛端到端 law、qa 靠純解譯器測不碰 IO;以現況,索引重建、搜尋、寫入、範圍裁決、生命週期、service 讀寫都沒有純的整條。牽動 P-001 到 P-011 全部里程碑與 P-021 / P-028 / P-029 三條子流。

## 決定
每個跨過 IO 的能力寫成 effectful 的效果(`Effect` GADT,`makeEffect` 生 smart constructor),描述型別 `Eff es a` 不帶 `IOE` 住 effects 層;配一個純解譯器(`Effectful.State.Static.Local` 跑在記憶體 `Map` 上,`runPureEff` 收尾)當 law 的觀察點,一個真解譯器(sqlite / directory / http-client / typed-process)住 shell。業務判斷(重建規劃、寫入規劃、範圍裁決、前置檢查、View 投影)寫成純函數或只帶效果描述的 `Eff` 程式,是里程碑的 `=` 列;`!` 列只做「跑真解譯器」。效果先按能力切:`Index`(索引列讀寫)、`VaultFs`(vault 目錄裡 Markdown 與 marker)、`HubFile`(中樞 config.toml)、`Clock`、`ToolProbe`;每條里程碑 build 時只立它需要的,不預先立全。`aapms-core` 不依賴 effectful(遊戲本體的相依面只有它,零重量級相依不變)。`ServiceM` 退成 shell 裡跑真解譯器的入口,列入「效果型別追加」讓 `lint boundary` 擋它進 pure / effects。

## 否決的替代方案
- 文檔對帳現況,store / workspace / service 整包登記 shell:六成程式碼沒 law 可掛,只剩 IO 測試,「殼零業務邏輯」與「業務契約」在 lint 眼裡分不開。
- 先對帳再逐條抽效果層:文檔寫兩次,「待抽效果層」GAP 長期 open 讓 `lawful status` 永遠 exit 1。
- 自家指令 ADT + Free / 解譯器:零外部相依,但多個效果組合時樣板多;SPK-001 證明 effectful 2.6.1.0 在 GHC 9.14.1 只需既有的三行 allow-newer 就能編,`makeEffect` 與 `runPureEff` 都可用,沒有理由自己造。
- mtl 的 `MonadIndex m` 這類 tagless-final class:純解譯器要另寫 newtype 與 instance,class 不是純資料,`lint boundary` 的「描述是純資料」判不出來。

## 後果
- 三個月後每條 law 都是純測試;新子系統 asset-ingest / conflict / ai / project 從第一天就長在 effects + pure。
- `Aapms.Store.Error` / `Aapms.Store.Row` / `Aapms.Workspace.Hub` / `Aapms.Workspace.Location` / `Aapms.Types.Loader` 五個純與 IO 混住的模組要拆;拆完模組表要補 effects 列與 `*.Internal`。
- 純解譯器與真解譯器的一致要有 `equiv` law(尤其 FTS 搜尋:純參考實作 vs sqlite trigram);這是每條里程碑 `=` 列的必備 law。
- 換效果框架等於重寫 effects 層,三個月後不可逆;證據:SPK-001-effectful。
