# 素材包清冊

現有素材庫的完整盤點,作為 `pack.toml` 的種子資料。

> **狀態:待你逐項核對。** 標記 `?` 的欄位是壓縮檔內沒有中繼資料、
> 我無法從內容證實的部分,需要從原始下載頁補齊。
> 我不從資料夾名稱推測作者 —— 猜錯的授權資訊比沒有授權資訊更危險。

盤點方式:以 7-Zip **串流讀取**每個壓縮檔內的 `readme` / `License` / `.url`,
完全不解壓。這正是 ingest pipeline 之後會自動做的事。

---

## 覆蓋率驗證

| | |
|---|---|
| 壓縮檔 | 27 |
| 壓縮檔內項目(檔名+大小去重) | 6,366 |
| 散檔 | 5,429 |
| **已被壓縮檔涵蓋** | **5,424** |
| 未涵蓋 | 5 |

未涵蓋的 5 個檔案全部是工作室自有內容,不屬於刪除範圍:

```
GameProjects\Col\game-design-doc.md
GameProjects\Col\haskell-2d-game-stack.md
GameProjects\Col\icon_background_test.png
Papers\Apecs - A Type-Driven Entity-Component-System Framework.pdf
行銷\2024-Media-ebook_iKala-Cloud.pdf
```

> ⚠️ **這是前置檢查,不是刪除依據。** 比對用的是 `(檔名, 大小)` 代理指標,
> 理論上存在同名同大小的假陽性。正式驗證由 `assetdb scan` 以 SHA-256 逐筆執行,
> 刪除閘門只認雜湊。

---

## 商業素材包

### 已從壓縮檔內容證實

| 壓縮檔 | 散檔 | 作者 | 來源 | 授權 | 需署名 |
|---|---:|---|---|---|---|
| `[GUI] Complete_UI_Book_Styles_Pack_Full.7z` | 1,693 | **Crusenho Agus Hennihuno** | [crusenho.itch.io/complete-ui-book-styles-pack](https://crusenho.itch.io/complete-ui-book-styles-pack) | 商用可;禁轉售、禁 NFT | ✅ **是** |
| `[Map] Pixel Art Top Down - Village v1.0.9.zip` | 73 | **Cainos** | [docs.cainos.net/pixel-art-top-down-village](https://docs.cainos.net/pixel-art-top-down-village) | ? | ? |
| `[Map] Pixel Art Top Down - Basic v1.2.3.zip` | 16 | **Cainos** | docs.cainos.net | ? | ? |
| `[GUI] Shikashi's Fantasy Icons Pack v2.zip` | 18 | **Shikashi** | ? | 商用可 | ⚠️ 部分圖示源自 game-icons.net,**CC BY 3.0** |
| `[Characters] FULL_Adventurer 2D Pixel Art.zip` | 38 | ? | ? | 商用可;禁轉售、禁 NFT | ❌ 否(「appreciated」但非必要) |

**Crusenho 那一包是最大的一包,而且是唯一明確要求署名的。**
授權原文:

> Give appropriate credit, or provide a link to this product page, and indicate if changes were made.

專案的致謝名單必須包含它。授權閘門在建專案時會提醒。

### 待補作者與來源

| 壓縮檔 | 散檔 | 內部結構 | 需要你補 |
|---|---:|---|---|
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 2.0 Full.rar` | 1,269 | `32x32/` | 作者、來源、授權 |
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 1 Full.rar` | 407 | | 同上 |
| `[Effects] 60 Retro Effect 32x32 Pack 1 Free.rar` | 20 | | 同上 |
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 2 Free.rar` | 0 | | 同上;內容應為 Full 版的子集,待確認 |
| `[Fonts] Idylwild's Runic Codex.zip` | 680 | `runes/`、`runic_codex.ase`、`Runes Reference Sheet.rtf` | 來源、授權 |
| `[GUI] Pixel Art Icon Pack - Food.zip` | 366 | `No Outline/`、`Outlined/`、`TIFF/` | 作者、來源、授權 |
| `[GUI] Pixel Art Icon Pack - RPG.zip` | 107 | `Food/`、`Material/`、`Potion/`、`Weapon & Tool/` 等 8 類 | 作者、來源、授權 |

四個 Effects 壓縮檔內完全沒有 readme 或 license,無法從內容取得任何出處。

### Kibyra 圖示系列(11 包)

每包都有 `readme.txt`,但內容只描述張數與主題,**不含作者名或授權條款**。

| 壓縮檔 | 散檔 |
|---|---:|
| `crafting-materials-icons.zip` | 72 |
| `animal-icons.zip` | 71 |
| `ingots&refinedmetals-icons.zip` | 67 |
| `monsterparts-icons.zip` | 66 |
| `ores-minerals-icons.zip` | 66 |
| `weather-icons.zip` | 66 |
| `treasure-icons.zip` | 66 |
| `food-icons.zip` | 66 |
| `herbs&medicinal-plants.zip` | 66 |
| `book-icons.zip` | 66 |
| `Magic Potions.zip` | 65 |

「Kibyra」目前只是資料夾名。**需要確認賣場頁與授權條款** ——
11 包共 737 個圖示,是庫裡第二大的來源。

---

## 非商業

| 壓縮檔 | 狀態 | 備註 |
|---|---|---|
| `Magic Shader All.zip`(197 MB) | 從未解壓 | 目前唯一的 Non-Commercial 素材。`commercial = false`,建商業專案時會被閘門擋下。作者與授權待補 |

---

## 參考資料(非遊戲素材)

| 壓縮檔 | 大小 | 內容 |
|---|---:|---|
| `金門建築.rar` | 1,078 MB | 1990 年代台灣金門建築 |
| `金門地道.rar` | 674 MB | 1990 年代台灣金門地道 |
| `福岡廟宇.rar` | ? | 日本福岡廟宇,266 張 HEIC |

三者皆為自有素材,歸入 `library/reference/`,預設不進素材搜尋結果。
HEIC 需要 ImageMagick sidecar 才能產生縮圖。

---

## 對重構的影響

1. **授權不是資料夾。** Crusenho 要求署名這件事,目前的
   `Commercial/` 資料夾完全表達不出來。它會進 `pack.toml` 的
   `attribution_required = true`,並在建專案時產生致謝清單。

2. **11 個 Kibyra 包各自獨立。** 它們會變成
   `library/packs/kibyra/<slug>/` 十一個目錄,而不是一個。
   一包一目錄是備份與溯源的單位。

3. **四個 Effects 包沒有任何內部中繼資料。** 這類包只能靠人工填 `pack.toml`,
   正好說明為什麼 `pack.toml` 要人可編輯而不是純自動產生。
