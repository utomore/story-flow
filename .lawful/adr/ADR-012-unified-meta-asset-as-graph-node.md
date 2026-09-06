---
id: ADR-012
type: adr
title: unified-meta-asset-as-graph-node
description: 素材與故事設定共用同一份 Meta,Asset 是片段圖譜的一等節點
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-012: 統一 Meta,Asset 是圖譜的一等節點

## 狀態(Status)

accepted

## 背景(Context)

assetdb 與 story-flow 各有一套資料模型:

| | assetdb `Asset` | story-flow `Entity` |
|---|---|---|
| 身分 | ULID | `ent-<8 hex>` |
| 描述 | `original_name` / `logical_name` / `kind` / `meta_json` | `title` / `summary` / `type` / `body` |
| 分組 | `categories` 樹 + `tags` | `tags` + `partOf` 關聯 |
| 關聯 | `links` 表:`src_type / src_id / dst_type / dst_id / rel` 純字串 | `Link {kind, target, note}`,`LinkKind` 有方向語意 |
| 狀態 | `active / excluded / missing / archived` | `draft / canon / deprecated` |
| 並發 | 無 | `revision` 樂觀鎖 |
| 來源 | `created_by` | `source` |

合併評估報告(2026-08-23)建議「共用地基與外殼,資料模型各自獨立」,並把 Entity ↔ Asset 的
關聯列為「現階段不做」。但那樣合併後素材與故事仍是兩張不相連的圖——而**兩張圖互相看不見**正是
兩個工具各自用了幾個月後最明顯的缺口:角色的設定在一邊、角色的立繪在另一邊,沒有地方能回答
「琳達用哪張立繪」「這個 Level 要哪些素材」。

assetdb 的 `notes` / `links` 表是它自己長出來的、Entity 圖譜的弱化版(純字串、無方向語意、無
型別驗證),證明素材側本來就需要圖譜,只是當時沒有。

## 決策(Decision)

**一、所有節點共用同一份 `Meta`。** Entity、Asset、Pack、Level、Node 的 `id` / `vault` / `type` /
`title` / `summary` / `tags` / `status` / `aliases` / `links` / `source` / `revision` / `created` /
`updated` 是同一組欄位、同一個 Haskell 型別。索引表、API 序列化、CLI 輸出、檢索、衝突偵測、
專案產出對同一組欄位工作,抽象成本只付一次。

**二、Asset 的專屬欄位只有它真的專屬的那幾個**:`name`(邏輯名稱)、`sha256`、`entry`、`ext`、
`meta`(kind 專屬 JSON)、`license`、`author`。對應關係:

| assetdb 原欄位 | 去向 |
|---|---|
| `original_name` | `title` |
| `logical_name` | `name` |
| `kind` | `type`(註冊表項目 `asset-<kind>`) |
| `categories` | `tags`(物化路徑 `gui/book` 當一個 tag;樹狀查詢以前綴比對) |
| `status` `active / excluded / archived` | `canon / deprecated / deprecated`;`missing` 保留為 asset 專屬值 |
| `created_by` | `source` |
| `pack_id` | 檔案包含關係(asset 住在哪份 pack.md) |
| `notes` / `links` 表 | **退場**,由 `body` 與 `links` 欄位吸收 |

**三、Pack 是節點。** pack.md 的檔案層 frontmatter 就是一個 `type: asset-pack` 的節點,與故事側
「檔案層主體 + 節層片段」完全對稱:`characters/琳達.md` 的主體是 character、節是 character-fragment;
`packs/kenney/ui-pack/pack.md` 的主體是 asset-pack、節是 asset-image。

**四、關聯詞彙加兩個字**:`uses`(故事節點 → 素材)與 `depicts`(素材 → 故事節點)。收兩個而不是
一個,因為作者站的位置不同——素材側標「這畫的是誰」、故事側標「這裡用什麼」——強迫只能從一邊寫
會讓另一邊的作者每次都要切換脈絡。引擎把兩者都當專案連動與檢索擴充的邊。

**五、`revision` 樂觀鎖自動涵蓋 asset。** 它在共用 `Meta` 裡,asset 側不需要另做決定。

## 考慮過的替代方案(Alternatives Considered)

- **資料模型各自獨立,只共用地基與外殼**(報告原案):實作風險最低。放棄的理由是它讓合併只剩
  「兩個工具裝在同一個執行檔」,交界處仍然是空的;而且 API / CLI / 衝突偵測得對兩種形狀各寫一遍。
- **只共用 `Link` 與索引,型別各自保留**:關聯做得成、搜尋一次回兩種,但 `Meta` 分兩份意味著
  序列化、呈現、樂觀鎖、來源追溯都是兩套。省下的是一次型別設計,付出的是永久的雙份維護。
- **Asset 做成 Entity 的一個 `type`,不另立型別**:最激進的統一。放棄的理由是 `sha256` / `entry` /
  `name` 這些欄位有不變量(內容定址、命名文法、全域唯一),塞進 Entity 的自由欄位會失去型別檢查;
  而 `Assets.hs` 的產生器需要一個能靜態區分「這是素材」的型別。

## 影響(Consequences)

**正面**

- `aapms search 織紋刀` 一次回「刀的設定片段」與「刀的立繪」
- 專案產出可以從 Level 順關聯一路找到素材(ADR 未涉及的細節見 system.md 資料流 B)
- 衝突偵測的候選集自然含素材節點;S5 後可讀素材的視覺標註
- assetdb 的 `notes` / `links` 兩張表與 `note import` / `note list` / `link` 三個指令直接刪除

**負面 / 成本**

- assetdb 的 6,783 筆資源要重編號、重新落檔(見 ADR-013、ADR-014);這是一次性匯出
- `categories` 樹降級成 tag 前綴,失去「分類有自己的描述」這個能力——實際使用中分類描述從未被用到
- 共用 `Meta` 讓 `timeline` / `aliases` 這些故事欄位出現在 asset 的序列化裡(通常為空)。接受這點
  換取一種形狀
- 這份 ADR 推翻了報告 §3「Entity ↔ Asset 軟連結現階段不做」的建議
