# 素材包清冊

現有素材庫的完整盤點,作為 `pack.toml` 與 `licenses` 資料表的種子。

盤點方式:以 7-Zip **串流讀取**壓縮檔內的 `readme` / `License` / `.url`(完全不解壓),
再由使用者從 itch.io 商品頁補齊壓縮檔內沒有的部分。

---

## 覆蓋率驗證

| | |
|---|---|
| 壓縮檔 | 27 |
| 壓縮檔內項目(檔名+大小去重) | 6,366 |
| 散檔 | 5,429 |
| **已被壓縮檔涵蓋** | **5,424** |
| 未涵蓋 | 5 |

未涵蓋的 5 個全部是工作室自有內容,不屬於刪除範圍:

```
GameProjects\Col\game-design-doc.md
GameProjects\Col\haskell-2d-game-stack.md
GameProjects\Col\icon_background_test.png
Papers\Apecs - A Type-Driven Entity-Component-System Framework.pdf
行銷\2024-Media-ebook_iKala-Cloud.pdf
```

> ⚠️ **這是前置檢查,不是刪除依據。** 比對用的是 `(檔名, 大小)` 代理指標。
> 正式驗證由 `assetdb scan` 以 SHA-256 逐筆執行,刪除閘門只認雜湊。

---

## 授權總覽

已寫入 `licenses` 資料表的六份授權,全部有可查證的全文:

| 授權 | 商用 | 署名 | 修改 | 再散布 | 轉售 | NFT |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Crusenho Asset License | ✅ | ⚠️ **必須** | ✅ | ❌ | ❌ | ❌ |
| Cainos Asset License | ✅ | 否 | ✅ | ❌ | ❌ | ? |
| Shikashi Fantasy Icons | ✅ | ⚠️ **必須** | ✅ | ? | ? | ? |
| Idylwild Runic Codex | ✅ | 否 | ✅ | ✅ | ? | ? |
| Kibyra Asset License | ✅ | 否 | ✅ | ❌ | ❌ | ? |
| Adventurer 2D Pixel Art | ✅ | 否 | ✅ | ❌ | ❌ | ❌ |

`?` 在資料庫裡是 **NULL,不是 0**。NULL 是「條款沒寫」,0 是「明確禁止」。
把未知當禁止會讓素材無故不可用,當允許則是法律風險 —— 兩者都不猜。

### 必須出現在專案致謝的兩份

**Crusenho** — 1,693 個檔案,全庫最大的一包:

> Give appropriate credit, or provide a link to this product page, and indicate if changes were made.

**Shikashi** — 致謝字句由作者指定:

> Credit "Matt Firth (shikashipx)" and "game-icons.net".

`assetdb new-project` 會依專案實際使用的素材產生致謝清單。

---

## 商業素材包

### Crusenho Agus Hennihuno

| 壓縮檔 | 散檔 | 來源 | AI |
|---|---:|---|---|
| `[GUI] Complete_UI_Book_Styles_Pack_Full.7z` | 1,693 | [crusenho.itch.io/complete-ui-book-styles-pack](https://crusenho.itch.io/complete-ui-book-styles-pack) | 未聲明 |

授權逐字取自壓縮檔內 `License.txt`。禁轉售、禁再散布、禁 NFT。

### Cainos

四包同一作者、同一授權。原本我把兩個 Icon Pack 標成作者未知,商品頁證實也是 Cainos。

| 壓縮檔 | 散檔 | 價格 | 發佈 | AI |
|---|---:|---|---|---|
| `[Map] Pixel Art Top Down - Village v1.0.9.zip` | 73 | $39.99 | 2025-04-29 | 聲明未使用 |
| `[GUI] Pixel Art Icon Pack - Food.zip` | 366 | $4.99 | 2019-03-26(更新 2021-10-19) | 聲明未使用 |
| `[GUI] Pixel Art Icon Pack - RPG.zip` | 107 | ? | ? | ? |
| `[Map] Pixel Art Top Down - Basic v1.2.3.zip` | 16 | ? | ? | ? |

文件:[docs.cainos.net/pixel-art-top-down-village](https://docs.cainos.net/pixel-art-top-down-village)
Food 包是 122 個 32×32 圖示,同時附 PNG 與**含圖層的 TIFF** —— 那 122 個 `.tif` 屬於 `KSource`,不進遊戲。

### Shikashi(Matt Firth)

| 壓縮檔 | 散檔 | 來源 |
|---|---:|---|
| `[GUI] Shikashi's Fantasy Icons Pack v2.zip` | 18 | [shikashipx.itch.io](https://shikashipx.itch.io) |

⚠️ **版本差異必須記錄。** 我們持有的 v2 內附 txt 寫「209 unique icons and 36 recolours,
245 icons in total」與 **CC BY 3.0**;商品頁現在寫 284 icons 與 **CC BY 4.0**。
以手上這份為準,不要照抄網頁。

作者另有新版 [shikashis-600-icon-pack](https://shikashipx.itch.io/shikashis-600-icon-pack)(607 個圖示),
若日後升級要當成**新的一包**匯入,不是覆蓋。

### BDragon1727

| 壓縮檔 | 散檔 | 價格 |
|---|---:|---|
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 2.0 Full.rar` | 1,269 | $4+ |
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 1 Full.rar` | 407 | $3.50+ |
| `[Effects] 60 Retro Effect 32x32 Pack 1 Free.rar` | 20 | **免費** |
| `[Effects] Super Package Retro Pixel Effects 32x32 pack 2 Free.rar` | 0 | **免費** |

發佈 2023-10-20 / 2023-10-24,更新 2026-04-11。色盤 **ENDESGA 32**。聲明未使用生成式 AI。

兩個 Free 版是免費下載(自行出價),Full 版付費。Free 版的內容應為 Full 版的子集 ——
`pack 2 Free.rar` 的 0 個獨有散檔正好與此一致,但仍待 SHA-256 確認。

🔴 **授權全文仍待確認。** itch.io 只有「Royalty Free」標籤,那是分類標籤不是授權條款。
四包共 1,696 個檔案,是庫裡第二大的來源。**在確認之前這四包維持 `draft`,不可用於專案。**

### Idylwild

| 壓縮檔 | 散檔 | 價格 | 發佈 |
|---|---:|---|---|
| `[Fonts] Idylwild's Runic Codex.zip` | 680 | 免費(自行出價) | 2026-01-14 |

> Attribution - You may attribute me, but it is not mandatory.

**這批素材裡唯一允許再散布的。** 商品頁另附 `Runes Reference Sheet.rtf`(440 kB),
壓縮檔內也有一份。標籤含 `No AI`。

### Kibyra(11 包)

| 壓縮檔 | 散檔 | | 壓縮檔 | 散檔 |
|---|---:|---|---|---:|
| `crafting-materials-icons.zip` | 72 | | `weather-icons.zip` | 66 |
| `animal-icons.zip` | 71 | | `treasure-icons.zip` | 66 |
| `ingots&refinedmetals-icons.zip` | 67 | | `food-icons.zip` | 66 |
| `monsterparts-icons.zip` | 66 | | `herbs&medicinal-plants.zip` | 66 |
| `ores-minerals-icons.zip` | 66 | | `book-icons.zip` | 66 |
| | | | `Magic Potions.zip` | 65 |

每包 $2.00,或 Fantasy Pixel Art Icon Bundle $11.99 含 11 包。

🟡 **AI Disclosure:AI Assisted(Graphics)。** 這是 11 包共 737 個圖示的共同屬性。
Steam 等平台上架要求申報生成式 AI 使用,發行前必須交代。
資料庫的 `packs.ai_disclosure = 'assisted'`。

### Adventurer 2D Pixel Art

| 壓縮檔 | 散檔 |
|---|---:|
| `[Characters] FULL_Adventurer 2D Pixel Art.zip` | 38 |

授權逐字取自壓縮檔內 `License.txt`:商用可、禁轉售、禁 NFT、署名非必要。
🔴 **作者名待補** —— License.txt 本身沒有署名。

---

## 非商業

| 壓縮檔 | 狀態 |
|---|---|
| `Magic Shader All.zip`(197 MB) | 從未解壓。🔴 作者、來源、授權全部未知 |

目前唯一的非商業素材。在授權查清之前維持 `draft`,建商業專案時會被閘門擋下。

---

## 參考資料(非遊戲素材)

| 壓縮檔 | 大小 | 內容 |
|---|---:|---|
| `金門建築.rar` | 1,078 MB | 1990 年代台灣金門建築 |
| `金門地道.rar` | 674 MB | 1990 年代台灣金門地道 |
| `福岡廟宇.rar` | ? | 日本福岡廟宇,266 張 HEIC |

三者皆自有,歸入 `library/reference/`,預設不進素材搜尋結果。
HEIC 需要 ImageMagick sidecar 才能產生縮圖。

---

## 匯入時的必填欄位

從這次盤點得到的教訓:**廠商壓縮檔裡有沒有授權資訊完全看運氣。**
Crusenho 與 Adventurer 附了完整 License.txt;Cainos 只附一個 `.url`;
四個 Effects 包什麼都沒有。所以授權資訊不能倚賴自動抽取。

`assetdb import` 因此要求以下欄位,缺一則素材包維持 `draft`:

| 欄位 | 必填 | 說明 |
|---|:-:|---|
| 作者名 | ✅ | |
| 作者聯絡方式 | ✅ | 商店頁 URL / Discord / email。「作者叫 Kibyra」在出問題時沒有用 |
| 授權 | ✅ | 從已知授權挑選,或新建 |
| 可否商用 | 自動 | 由授權推導,不重複問 |
| 需否署名 + 致謝字句 | 自動 | 同上 |
| AI 使用揭露 | ✅ | `unknown` / `none` / `assisted` / `generated` |
| 來源 URL | | |
| 版本、取得日期、價格 | | |

### `draft` 的意義

`draft` 的素材包**照樣入庫、照樣算雜湊與縮圖**,只是不進搜尋預設結果、
不可用於建專案。強迫當場填完會讓匯入卡住,乾脆不填則會讓授權風險靜靜累積 ——
`draft` 讓授權缺漏變成一個看得見的待辦。

資料庫層以 CHECK 約束強制,不靠應用層自律:

```sql
CHECK (status = 'draft' OR (license_id IS NOT NULL AND author_id IS NOT NULL))
```

`ready` 的素材包必須兩者皆備,連 `UPDATE ... SET status='ready'` 也擋。

---

## 待辦

| 項目 | 影響檔案數 |
|---|---:|
| 🔴 BDragon1727 四包的授權全文 | 1,696 |
| 🔴 Magic Shader All 的作者、來源、授權 | — |
| 🔴 Adventurer 2D Pixel Art 的作者名 | 38 |
| 🟡 Cainos Icon Pack RPG / Map Basic 的價格與發佈日 | 123 |
| 🟡 Kibyra 各包的發佈日與版本 | 737 |
