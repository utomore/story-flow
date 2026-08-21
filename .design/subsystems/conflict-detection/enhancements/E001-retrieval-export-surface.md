---
id: E001
type: enhance
title: retrieval-export-surface
description: 收斂 Conflict.Retrieval 的匯出面,讓「換一種候選策略」真的不必動其他兩層
status: open
created: 2026-08-21
updated: 2026-08-21
depends-on: [F003, F005, F006]
related-adr: [ADR-007]
related-feature: [F003]
---

# E001: 收斂 Conflict.Retrieval 的匯出面

> 本文檔由 `/arch-audit subsys conflict-detection` 在**階段二閘門**建立,開發者裁定「先記下來」。
> 這裡只記錄現況分析與問題陳述;**量化目標、介面變動、TodoList 與 1-to-1 測試尚未討論**,
> 動工前要先走 `/enhance-design` 補完 scope。

## 發現的來源

同一條發現橫跨兩個階段的 arch-audit:

- **階段一 A-3**(2026-08-20):`Conflict.Retrieval` 公開匯出 13 個純函式部件與 6 個調校常數
- **階段二 B-5**(2026-08-21):未處理,匯出面仍為 23 個名字

## 現況分析

`conflict-retrieval` 契約卡寫得很清楚:

> 候選撈取策略本身是本模組的**內部抽象**,對外只露「候選」這個結果

而 `design.md` 的「內部模組劃分」把這一點列為第 2 層的設計要點:

> **第 2 層的候選撈取策略刻意設計成可替換**。ADR-007 決定先不做 embedding 語意檢索
> ……但把介面留成「策略」——未來要加只是多一個策略並在排序時合併,不必動其他兩層

實際的匯出面(`conflict/src/StoryFlow/Conflict/Retrieval.hs`)是 23 個名字,其中包含六個
調校常數:`segMinLen`、`chunkLen`、`maxKeywordLen`、`maxKeywords`、`overFetchFactor`、
`expansionDecay`。

## 問題陳述

目前的消費者只有測試與 `Conflict.Pipeline`(用 `metaSnippet`),所以**還沒有真的壞掉**。
風險在於這是一條**單向的閘門**:常數一旦被模組外引用,「換一種候選策略不需要改動第 1、3 層」
這個承諾就會悄悄失效,而失效的那一刻不會有任何測試變紅——它只會在未來真的要接
embedding 策略時,以「動不了」的形式浮現。

ADR-007 明說 embedding 是被推遲、不是被否決的選項,所以這個承諾有真實的兌現日期。

階段二讓風險擴大了一點:`Conflict.Judge`(F005)現在也 import `Conflict.Retrieval` 的
`Candidate (..)` 與 `metaSnippet`,第 2 層的匯出面因此多了一個跨層消費者。

## 尚待討論的 scope(走 `/enhance-design` 時要決定)

- 六個調校常數是收進模組內部、還是集中成一個具名的「策略參數」型別
- 13 個純函式部件裡,哪些是測試**真正需要**單獨觀測的,哪些可以透過門面測
- `Candidate (..)` 與 `metaSnippet` 給 `Judge` / `Pipeline` 用是否算合法的模組間介面
  ——若算,要補進 `design.md` 的「模組間公開介面與資料結構」表
- 收斂之後既有測試要怎麼改寫,以及會不會因此降低覆蓋
