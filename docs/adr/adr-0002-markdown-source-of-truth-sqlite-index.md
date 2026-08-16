---
id: adr-0002
type: adr
title: markdown-source-of-truth-sqlite-index
description: Markdown 檔為真相來源,SQLite 只當可重建的索引與檢索快取
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0002: Markdown 檔為真相來源,SQLite 為可重建索引

## 狀態(Status)

accepted

## 背景(Context)

story-flow 要同時滿足四種存取者,而它們的偏好互相拉扯:

1. **作者本人**——想直接開編輯器寫故事,想看 `git diff` 知道這次改了哪句設定
2. **AI Agent**(claude code / codex)——最擅長的事就是 read/grep 純文字檔;逼它一切走 API
   反而綁手綁腳
3. **關聯查詢**——「順著 `contradicts` 找兩層」「撈出所有 `status = canon` 且提到埃提亞的片段」
   這種查詢用檔案掃描做,資料一多就崩
4. **中文全文檢索**——衝突偵測的第 2 層要靠它撈候選,必須快且要能處理中文分詞

design-studio 用純檔案 JSON,在只有 3 份設計文件時完全夠用;但 story-flow 的粒度細到「片段」,
同樣的世界觀會變成數百個 Entity,全圖掃描與全文搜尋都會變成瓶頸。

## 決策(Decision)

**Markdown 檔是唯一的真相來源;SQLite 是純粹的衍生索引,任何時候可以刪掉重建。**

- 每個主題一份 `.md`(`characters/琳達.md`),檔內以分節切出片段,節標題帶 `{#ent-xxxx}`,
  緊接一個 ` ```meta ` YAML 區塊帶該片段的 Meta;節層未寫的欄位繼承檔案層 frontmatter
- SQLite(`.storyflow/index.db`)存 `entities` / `entity_aliases` / `links` / `levels` /
  `nodes` / `node_entities` 與 `entities_fts`(FTS5 trigram),**gitignored**
- 索引每筆記錄帶 `file_path` + `section_anchor`,能回指原始檔案的哪一節
- 提供 `story-flow index rebuild`,並以測試保證:刪掉 `index.db` 後重建的結果與刪除前等價
- 寫入路徑一律「先寫檔(原子寫入:寫暫存檔 + rename)→ 再更新索引」;索引更新失敗不算資料遺失,
  重建即可

## 考慮過的替代方案(Alternatives Considered)

- **純 SQLite 單檔**:交易一致性最好、無同步問題、關聯查詢最直接,也和 assetdb 的作法一致。
  但設計文字進不了 `git diff`——對一個「故事設定會反覆修訂、需要知道某句設定是何時為何改的」
  的工具,這個代價太大;而且 AI Agent 一定得透過 API 才能讀任何東西,少了最自然的一條路。
- **純檔案 JSON(沿用 design-studio)**:零相依、行為好預測,但關聯查詢與中文全文檢索都要
  自己在記憶體裡做,資料量成長後必然重寫。JSON 也不適合人直接手寫故事正文。
- **一片段一檔**:解析最單純、定位最直接,但一個世界觀會有數百個檔案,手動瀏覽與寫作時
  極度零碎——寫「琳達」時應該一眼看到她所有的片段。
- **SQLite 為主、匯出 Markdown 為輔**:等於 Markdown 是唯讀快照,作者改檔案不會生效,失去
  「直接開編輯器寫」這個核心體驗。

## 影響(Consequences)

**正面**

- 設計資產進 git,`git diff` / `git log` / `git blame` 直接可用,Vault 本身就是一個 repo
- AI Agent 有兩條路:走 API,或直接 grep/read 檔案——後者在探索階段特別有用
- SQLite 是可丟棄的,索引結構要改就改,不需要寫資料遷移程式(對照 design-studio 的
  bug-0003「session schema 從未遷移」)
- 中文檢索由 FTS5 trigram 承擔,assetdb 已驗證這條路可行

**負面 / 成本**

- 必須處理「檔案被外部改動後索引過時」:P1 就要做 mtime/雜湊比對與 `index rebuild`,
  不能拖到後面
- Markdown 分節格式需要一個穩健的解析器,且必須通過 round-trip 測試(解析 → 寫回 → 再解析
  不失真),否則程式寫回檔案時會破壞作者的手寫排版
- 沒有跨檔案交易。一次寫入多個檔案(例如建立關聯要同時改兩個檔)時要自己處理部分失敗——
  緩解方式是關聯只存在來源端,單一寫入只碰一個檔

**中立**

- `.storyflow/index.db` 必須進 Vault 的 `.gitignore`;Vault 初始化時自動寫入
