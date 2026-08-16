---
id: enhance-2026-08-16-project-template-cli-parameter
type: enhance
title: project-template-cli-parameter
description: 專案模板名稱寫死,projects.template 欄位有多模板意圖但 CLI 無對應參數
status: open
created: 2026-08-16
updated: 2026-08-16
related-adr: []
related-spec: []
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

- [ ] T1: 與開發者確認方案 A 或方案 B
- [ ] T2: 依決定的方案實作

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T2(方案 A) | `CreateSpec.new-project 帶 --template 參數時使用指定模板` | 驗證新參數生效 |
| T2(方案 A) | `CreateSpec.new-project 未帶 --template 時使用預設值` | 確認預設行為不變 |
| T2(方案 B) | 人工 code review 確認註解已加上 | 純文件性修改 |

## 實作備註

(開發過程中與規格的偏差記錄於此,撰寫時留空)
