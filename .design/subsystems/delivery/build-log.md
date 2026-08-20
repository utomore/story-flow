---
id: delivery-build
type: build-log
title: delivery-build
description: 委派展開 delivery 階段 14 的專案增量同步
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: delivery
---

# Delivery 委派展開紀錄

## 排程

功能規劃 #1–#5(階段 2 / 7 / 8 / 9)在 2026-08-19 的 `.design/` 遷移時已回溯建檔且全部
`done`,不在本次展開範圍。本次只跑階段 14 的 `project-sync`。

依賴 `#5 project-scaffold`(`F005`,`done`)已滿足,無跨子系統或全域依賴,因此單一波次。

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段 14 | W1 | project-sync | in-progress |

## 委派決策記錄

批次澄清共四題,開發者全採推薦選項。其中 D1、D2 屬契約類,已回寫
`design.md`(§6、模組間公開介面、定位與範圍、`project-sync` 契約卡),此處不重複內容,
只記錄決策來源;D3、D4 屬執行取向,不進 Level 2,由本表傳給執行者。

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 對帳要算磁碟檔案的 SHA-256,但 `sha256File` 在 `assetdb-ingest`,`project` 不依賴它 | `project` 加 `assetdb-ingest` 依賴,直接用 `AssetDB.Ingest.Hash.sha256File`;不自行實作摘要,不改用其他演算法 | project-sync(已回寫 design.md) |
| D2 | 既有登記素材的素材包後來授權降級時,重寫 manifest 怎麼處理 | 仍列入 manifest 與 `Assets.hs`,但回報逐包警告;授權閘門只擋新增不回溯既有 | project-sync(已回寫 design.md) |
| D3 | 對帳的雜湊成本 | 先比檔案大小:與登記時不同就直接判定「本地已修改」,相同才真的讀檔算雜湊。正確性不變(大小不同必然內容不同),多數情況省掉整批 IO | project-sync 實作 |
| D4 | 測試深度 | 契約卡的 10 條驗收標準各一組 1-to-1 測試;對帳分類用純函數 + 真實 SQLite 暫存庫測到;壓縮檔解壓 IO 路徑沿用 `project` 既有風格不直接測 | project-sync 測試 |

**批次澄清後仍不確定的點**(會變成 subagent 的「待確認假設」):

- 登記的專案目錄存在、但 `assets/` 子目錄被整個刪掉時,四類對帳的結果與訊息措辭
- `--match` / `--pack` 都不給時是否等同「該專案可用的全部素材」(`new-project` 是這個語意)
- 對帳結果的終端機輸出版面(分類標題、是否截斷長清單、截斷幾筆)

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| project-sync | F006 | F006-project-sync.md | 繼承 | 繼承 | pending |

模型選擇理由:`project-sync` 跨 `project` 與 `cli` 兩個套件、要新增套件依賴、四類對帳的
邊界條件多,且是唯一會動使用者既有專案檔案的指令(誤判就是覆蓋或漏判使用者的手動修改)。
契約卡雖然完整,但風險集中在「只增不刪」這條安全性質上,設計與實作都不降級。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| (待 subagent 回報) | | | |

## 階段結果

### 階段 14

(執行中)
