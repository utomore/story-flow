# .design/ 退場計畫(2026-09-06,等批准)

## 前置確認
- 退場清單 10 份(4 份 build-log / design.md、3 份 spec-gaps、3 份 B 文檔):內容已在 `.lawful/system.md`、各 pipeline 的 Brief 與「決定」、ADR-023;E 文檔(graph-core / workspace 的 archive/E00x-*-migrated.md 共 4 份)已 migrated,內容在 P-005 / P-003 的決定裡。
- B 文檔的回歸測試:B001(fixture vault layout)在 store/test/Aapms/Store/VaultLayoutSpec.hs / Fixtures.hs;B002(initVaultAt 不漏 IOException)由 P-005 真解譯器 `runVaultDirIO` 承接,LifecycleSpec 的對應斷言仍在(第 604 行附近);G-B001(contract rules frozen out of build)在 contract/test/RulesMain.hs。
- spec-gaps 還 open 的:graph-core 0、service 0、workspace 2(GAP-6 vePath 正規化 → 已寫進 P-005 決定「vePath 一律是 canonicalizePath 的結果」;GAP-7 initVault 簽名逐字 → 該函式已退場,簽名由 `lawful lint sig` 對每條 stage 逐字守,不需 GAP)。`.lawful/gaps.md` 目前不存在(0 條 open)。
- 程式碼與 cabal 只在註解裡提到 `.design/…`(20 個檔),沒有任何 runtime 讀取。

## 動作
1. `git rm -r .design/`(84 份非 legacy + 59 份 legacy),含 `.design/adr/`(22 份已原樣在 `.lawful/adr/`)。
2. 程式碼與 cabal 註解裡的 `.design/...` 引用改成對應的 `.lawful/...`(pipeline 全名 / ADR),只動註解。
3. README.md「設計文檔」節與開頭的重構註記改指 `.lawful/system.md`、`.lawful/pipelines/`、`.lawful/adr/`,只寫現在的規則。
4. 新建專案根 `CLAUDE.md`(目前沒有):指向 `.lawful/`,寫 lawful 的工作規則(pipeline / law / lint / status 三道指令、四層邊界、qa 與 impl 的分工),不寫搬遷史。
5. `wip/` 保留到 branch 合併前(搬遷帳本與各輪 log),合併時一併刪。
