---
id: service-gaps
type: spec-gaps
title: service-gaps
description: service 委派過程中 qa / impl 撞到的 spec 缺口與裁決
status: done
created: 2026-08-30
updated: 2026-09-04
parent: service
---

# service spec 缺口

> **狀態行的寫法**:`scan-status.mjs` 的正則是 `^\s*[-*]\s*狀態\s*[::]\s*(\S+)`,抓到的第一個
> 非空白詞必須逐字是 `open` 或 `resolved`。寫成 `- **狀態**:` 或 `- 狀態:**resolved**` 都會讓它
> 解析失敗、**靜默 fallback 成 open**。粗體留給值後面的說明文字。

## GAP-1(service/F002-workspace-facade / qa)

- 模糊點:**EX-10 的建構在裝了 7-Zip 的機器上不成立**。它假設「`[tools]` 未設 + `PATH` 清空」
  足以讓 `workspaceTools` 回 `NotFound`,但 `detectSevenZip` 的**第三層**查的是已知安裝路徑候選
  (`workspace/F006` 的三層探測:`[tools]` 覆寫 → `PATH` → **內建候選**),不受 `PATH` 或
  `[tools]` 影響。本機實測回的是 `Just "C:\Program Files\7-Zip\7z.exe"`。
- 卡住的項目:EX-10(`test_workspace_tools_not_found_example`)。
  **LAW-10 本身沒有卡住** —— 它上面那條 property test(`prop_workspace_tools_matches_detect`,
  直接與 `detectSevenZip (hubTools hub)` 逐欄比對)是綠的,law 有被驗到。
- 需要 spec 回答什麼:這條 example 在已裝 7-Zip 的機器上該怎麼重現?兩個候選方向 ——
  (a) 改成只斷言「三層都試過」(`tsSearched` 非空)而不斷言具體的 `NotFound`;
  (b) 要求一個測試可控的候選路徑覆寫點(但那可能是測試後門,`testing-policy.md` 禁止)。
- 狀態:resolved(2026-08-30 WAVE-2 仲裁,開發者裁決):選 (a) —— EX-10 改成斷言「三層都試過」(`tsSearched` 非空),**不再斷言具體的 `NotFound`**。理由是它在裝與沒裝 7-Zip 的機器上都可重現,CI 與開發機行為一致;`NotFound` 這個值仍由 LAW-10 的 property test 間接覆蓋(機器沒裝時那條自然比對到它)。(b) 被否決:那個覆寫點很可能就是測試後門
- 修訂:service/F002-workspace-facade §Examples(2026-08-30);EX-10 改成斷言 `tsSearched` 非空,不再斷言具體的 `NotFound`

## GAP-2(service/F002-workspace-facade / qa)

- 模糊點:**EX-19b 期待的 `viIssues` 非空是不可達的**。它要求對一個已建好索引的 vault 呼叫
  `vaultInfo` 時 `viIssues` 仍非空;但 `SchemaRebuilt` 只在該索引**檔案生命週期的第一次開啟**時
  產生,而建索引的唯一合法路徑(`openVault` + `indexFile` + `closeVault` —— F002 自己從不呼叫
  `indexFile`)**本身就是那個第一次開啟**,所以 `vaultInfo` 內部的 `handleFor` 必然是第二次開啟,
  依 LAW-22 自己的定義 `viIssues` 就該是 `[]`。
- 卡住的項目:EX-19b 的 `viIssues` 斷言(EX-19b 的其餘部分 —— 「`vaultInfo` 不受 `--vault` 範圍拘束」
  那一半 —— 是綠的,ASM-4 的裁決有被驗到)。
- 需要 spec 回答什麼:EX-19b 對 `viIssues` 的預期是否應改為「與 EX-18 同一判準:逐項等於同一個
  `Env` 的 `indexIssuesFor`,**不強制非空**」?
- 狀態:resolved(2026-08-30 WAVE-2 仲裁,開發者裁決):**是**,改成與 EX-18 同一判準、不強制非空。LAW-22 的法條文字不動(它是對的);EX-19b 驗 ASM-4 裁決的那一半原樣保留
- 修訂:service/F002-workspace-facade §Examples(2026-08-30);EX-19b 改成與 EX-18 同一判準、不強制非空,LAW-22 的法條文字不動
