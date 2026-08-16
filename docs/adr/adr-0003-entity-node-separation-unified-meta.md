---
id: adr-0003
type: adr
title: entity-node-separation-unified-meta
description: Entity 承載內容、Node 承載結構,兩者共用同一套統一 Meta
status: accepted
created: 2026-08-16
updated: 2026-08-16
---

# ADR-0003: Entity 與 Node 分離,但共用同一套統一 Meta

## 狀態(Status)

accepted

## 背景(Context)

需求上有兩句話彼此拉扯:「**所有東西皆 Entity 化**」與「**每一個 Node 都可以關連到一個以上的
Entity**」。前者傾向單一模型(Node 就是 Entity 的一種),後者傾向兩種型別。

以教室場景的例子看實際需要:根 Node 記場景描述,往下長出「出場人物」Node、「鏡頭」Node、
「人物互動」Node、「A-to-B 對話」Node,而對話 Node 連結到對話內容 Entity。這裡 Node 真正
承載的是**順序、分支、鏡頭如何移動**——是敘事的結構與演出;而「這句對話寫什麼」「琳達是誰」
是內容。

同時,兩者的 metadata 需求高度重疊:都要唯一編號、都要總結、都要關聯、都要知道是誰建的、
都要防並發覆蓋。需求也明確要求「全部的 metadata 都設計在一起,更好抽象與管理」。

## 決策(Decision)

**型別分離,Meta 統一。**

型別上 `Entity` 與 `Node` 是兩種東西:

- **Entity = 內容**。世界觀片段、角色片段、道具、對話內容、劇情片段。是衝突偵測唯一面對的東西
- **Node = 結構**。只承載樹的位置(`parent` / `order`)、演出種類(`kind`:`scene` / `cast` /
  `camera` / `interaction` / `dialogue` / `branch`)、以及指向 Entity 的關聯(`entities`,
  允許多個但**建議一個**)

Meta 統一:`Entity` / `Level` / `Node` 共用同一份 `Meta` record——`id` / `vault` / `type` /
`title` / `summary` / `tags` / `status` / `timeline` / `aliases` / `links` / `source` /
`revision` / `created` / `updated`。專屬欄位另外掛:`Entity` 有 `body`,`Level` 有 `root`,
`Node` 有 `level` / `parent` / `order` / `kind` / `entities`。

Meta 中三個乍看多餘的欄位是刻意保留的,理由都指向衝突偵測:

- `status`(`draft` / `canon` / `deprecated`)——**只有 `canon` 參與衝突偵測的比對基準**。
  草稿不該被拿來當「過去的設定」比對,否則每個未定案的想法都會製造假衝突
- `timeline`(模糊字串 + 選配整數 `order`)——很大一部分的劇情衝突本質是時序問題(「她那時候
  應該還沒拿到織紋刀」)。沒有時間軸就只能靠 LLM 從文字裡猜
- `aliases`——角色化名、地名舊稱。不建立的話 FTS5 檢索層會整個撈不到,第 3 層 LLM 再強也沒用

`revision` 是單調遞增的樂觀鎖:寫入時比對,不符即拒絕。這直接對應 design-studio 的
bug-0004(並發寫入 lost update),而在 story-flow 情境下更嚴重——AI Agent 與作者很可能同時
在改同一個 Vault。

## 考慮過的替代方案(Alternatives Considered)

- **完全統一(Node 就是 `type = node` 的 Entity)**:只有一種型別、一組 API、一組查詢,概念上
  最漂亮,也最貼近「所有東西皆 Entity 化」的字面。但代價是:(a) 樹的約束(單一父節點、不成環、
  兄弟有序)只能靠邏輯而非型別保證;(b) 衝突偵測與全文檢索必須時時排除 `type = node` 的雜訊
  ——結構節點沒有可比對的敘事內容,卻會一直出現在候選集裡;(c) 同一段對話 Entity 要被多個場景
  重用時,「重用內容」與「重用結構」會混為一談。
- **完全分離(各自一套 metadata)**:寫起來最直觀,但索引表、API 序列化、CLI 輸出、權限與樂觀鎖
  全部要做兩份,抽象成本付兩次,而且兩邊一定會慢慢長歪。
- **精簡版 Meta(先不做 `status`/`timeline`/`aliases`)**:手寫 frontmatter 負擔小。但這三個
  欄位是 P4 衝突偵測的前提,晚加等於既有的幾百個片段都要回頭補——補設定比一開始就寫貴得多。

## 影響(Consequences)

**正面**

- 衝突偵測只需要面對 Entity 一種東西,檢索與比對的輸入乾淨
- 同一段對話 Entity 可被多個場景的 Node 重用,不會因為結構不同而複製內容
- 索引、序列化、CLI 輸出、樂觀鎖只實作一次,涵蓋三種實體
- 型別註冊表(ADR-0005)只需要描述 Entity 型別,Node 的 `kind` 是引擎自己的封閉集合

**負面 / 成本**

- API 與 CLI 要區分 `/entities` 與 `/nodes` 兩組端點,使用者需要理解這個區別;文件必須把
  「內容 vs 結構」講清楚,否則會有人想把場景描述直接寫在 Node 上
- `Meta` 是三種實體的聯集,因此對任一種都有幾個永遠用不到的欄位(例如 Node 幾乎不會用 `aliases`)
- 每建一個片段要多想 `status` / `timeline` 兩個欄位;緩解方式是節層繼承檔案層 frontmatter,
  且兩者都允許留空
