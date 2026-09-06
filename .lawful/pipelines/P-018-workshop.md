---
id: P-018
description: 工作坊依註冊表 stages 逐階段引導,每回合輸入經 LLM 產出多個片段寫入圖譜
status: draft
updated: 2026-09-06
---
# P-018-workshop:工作坊依註冊表 stages 逐階段引導,每回合輸入經 LLM 產出多個片段寫入圖譜

## Brief
S5 的第三條里程碑,原 story-flow 的 workshop 移植。input 是工作坊的回合輸入(使用者對上一階段問題的回答)與註冊表裡該型別宣告的 stages;output 是逐階段產出的多個片段(NewSection),經 P-008-graph-write 寫入,以及下一階段的提問。流向:`start` 依型別的 stages 建 session → `next` 把回答與上下文組 prompt 打 LLM(P-017 的門面)→ 解析成該階段的片段草稿 → `emit` 寫入圖譜(source 為 workshop:<型別>)。狀態機的轉移、prompt 組裝、輸出解析是純函數;session 持久化是 `WorkshopStore` 效果,LLM 呼叫是 `Llm` 效果。Stages 與 laws 待 S5 設計時寫;願望模組 `Aapms.Workshop.Run`。

## Stages
| # | 簽名 | 做什麼 | 模組 | 層 |
|---|---|---|---|---|

## Laws

## Examples
| # | 輸入 | 輸出 | 覆蓋 |
|---|---|---|---|

## 決定
- **階段由註冊表 stages 宣告,不寫死在程式碼。** 否決:固定三階段。理由:ADR-005 的宣告式註冊表
- **每階段可產出多個片段,emit 才寫入,寫入走 P-008 的 AddFragment。** 否決:每回合直接寫。理由:人先看再決定
- **LLM 門面與 P-016 / P-017 共用。** 否決:自己打端點。理由:一份客戶端

## 修訂記錄
無
