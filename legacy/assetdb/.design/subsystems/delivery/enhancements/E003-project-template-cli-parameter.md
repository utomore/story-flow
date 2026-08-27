---
id: E003
type: enhance
title: project-template-cli-parameter
description: 讓 CLI 能指定專案模板,不再寫死單一模板
status: done
created: 2026-08-16
updated: 2026-08-19
depends-on: []
related-adr: []
related-feature: []
---

# 專案模板名稱寫死,`projects.template` 欄位存在多模板的意圖但 CLI 無對應參數

## 現況說明

`project/src/AssetDB/Project/Create.hs:138` 直接把 `"haskell-raylib-2d" :: Text` 寫進
`INSERT`。資料庫的 `projects.template` 欄位設計上是為了支援多模板,但 CLI 的
`new-project` 指令目前沒有對應的參數可以指定其他模板,實質上是單模板系統。

## 修正方案

二選一,由開發者決定:

- **方案 A(開放參數)**:若確實有規劃第二個模板,`new-project` 新增 `--template`
  參數,預設值仍是 `"haskell-raylib-2d"`。
- **方案 B(註解說明現況)**:若目前不需要多模板,在 `Create.hs:138` 加註解說明
  「目前僅支援單模板,`projects.template` 為未來擴充預留」,避免未來的開發者誤以為
  多模板已經是可用功能。

## TodoList

- [x] T1: 與開發者確認方案 A 或方案 B —— **決定:方案 B**(2026-08-18)
- [x] T2: 依決定的方案實作

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T2(方案 A) | `CreateSpec.new-project 帶 --template 參數時使用指定模板` | 驗證新參數生效 |
| T2(方案 A) | `CreateSpec.new-project 未帶 --template 時使用預設值` | 確認預設行為不變 |
| T2(方案 B) | 人工 code review 確認註解已加上 | 純文件性修改 |

## 實作備註

- **開發者決策:方案 B(註解說明現況)。** 關鍵考量:鷹架產生
  (`templateFiles` / `cabalFile`)本身也是單一模板實作,若只開 `--template`
  參數而沒有第二套鷹架,參數只會改到資料庫欄位 —— 一個「可以指定但沒有效果」
  的假選項比沒有選項更誤導。
- 註解加在 `project/src/AssetDB/Project/Create.hs` 的 `registerProject`
  寫入 template 值處,說明單模板現況與 `projects.template` 的預留用途。
- 無行為變更、無新測試(照 1-to-1 表 T2(方案 B) 為人工 code review)。
  未來真要多模板時,以 `/func-spec:feature` 展開完整規格(含第二套鷹架)。
