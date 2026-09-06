# 搬遷決定紀錄(第 0 步,開發者口頭裁決)

- D0(2026-09-06)重構範圍:**B** —— 搬遷同時做四層重構。store / workspace / service 各立效果描述(effects 層)+ 純解譯器 + shell 真解譯器;業務判斷抽成 pure 的 `=` 列。每條 pipeline 在第 3 步 build 時做。
- D0a(2026-09-06)效果機制:先開 SPK-001 驗 effectful 在 GHC 9.14.1 / base-4.22 的可編性與 runPureEff 純解譯;過了用 effectful,不過退回自家指令 ADT + 解譯器。
- D0a 定案(2026-09-06)SPK-001 結果 feasible:effectful 2.6.1.0 / effectful-core 2.6.1.0 / effectful-th 1.0.0.3 在 GHC 9.14.1 只需 root 既有三行 allow-newer;makeEffect TH 可用;runPureEff 純解譯與 IORef 解譯結果一致。**效果機制用 effectful**;描述型別 `Eff es`(不帶 IOE)住 effects,真解譯器住 shell。aapms-core 不依賴 effectful(零重量級相依不變)。
- D1(2026-09-06)分組:**甲、按資料流切**。子流 10:core-identity、registry-build、logical-name、manifest-codec、level-tree、md-document、md-edit、fts-tokenize、hub-config、scope-resolve。里程碑見 D2。名字與內容第 2 步逐條再談。
- D2(2026-09-06)里程碑切法:**A、19 條一次 claim**。S1:index-rebuild、search、node-write。S3:vault-scope、vault-lifecycle、workspace-doctor、graph-read、graph-write、cli-shell、http-shell、mcp-shell。S4:asset-scan、thumb-cache、name-cluster、pack-reorganize。S5:conflict-check(context 為子流)、ai-classify、workshop。S6:project-export。S7 不建 pipeline,發佈清單寫進 system.md。S4–S6 只有 Brief。
- D3(2026-09-06)law 形式化:**A**。F006 LAW-1~4(cabal 結構)不當 law;交給 modules.md + lint boundary;內部模組改 *.Internal 命名;BoundarySpec 保留為內部測試不標歸屬。F006 REG-6(rm index.db → rebuild 等價)成為 index-rebuild 的 = 列 law;REG-3/4 是 shell IO 函數不掛 law。
- D4(2026-09-06)簽名:**程式碼為準,全部逐字抄**。零真差異。抄寫規則:註解不抄、撞名寫全名模組、record 欄位寫存取子型別。`commit` 可見度隨 node-write 重切處理。`desegmentCjk` 已撤除,無 stage。
- D5(2026-09-06)待確認假設:**A、40 條全部追認現況**。17 條行為判斷寫進對應 pipeline「決定」(粗體結論 + 理由 + 否決的替代);23 條結構/流程類隨重構消失。workspace GAP-6 → vault-lifecycle 寫成 `vePath == canonicalizePath` 獨立 law;GAP-7 由 lint sig 逐字對帳取代。
- D6(2026-09-06)planned 12 份:**A、併入既定里程碑**。service F003/F007 → graph-read;F004/F005/F006 → graph-write(寫入請求收成一個 ADT);F008 → index-rebuild 的 shell 步驟;shell F001/F005 → http-shell;F002/F003/F004 → cli-shell(mcp-shell 註「見」);F006 → mcp-shell。

## 備忘(2026-09-06,P-025 REV-1 impl 提)
- 凍結中的 `workshop/` 套件(`cabal.project` 註解掉,不在建置範圍)在 `Aapms.Workshop.Emit` 用執行期值 `Workshop (wsType session)` 建構 `Source`;`SourceName` 收成非空後這裡要走 `mkSourceName`,`Nothing` 分支走哪條錯誤是 P-018-workshop 解凍時的契約決定,現在不決。
