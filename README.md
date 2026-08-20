# assetdb — Alchbees 資源與專案管理系統

工作室的素材庫、知識建檔、行銷資訊與遊戲專案的統一管理系統。

**核心觀念:壓縮檔是唯一真相,其餘皆為衍生物。** 廠商的原始壓縮檔不可變、
不重新打包、是備份與授權爭議時的證據。資料庫索引它們的內容而不解壓,
專案需要素材時才單筆取出並改名。

目前的實況(2026-08-20 的 `assetdb doctor` 與 `assetdb ai status`):

| | |
|---|---:|
| 素材包 | 27 |
| 壓縮檔 | 27 |
| 資源 | 6,783 |
| 唯一內容(blobs) | 6,255 |
| 已產生縮圖 | 5,320 |
| 已指定邏輯名稱 | 1,653 |
| 已分類(AI 叢集層分類套用後) | 5,794 |
| 已有視覺內容標籤 | 5 / 5,321 |
| 去重後總量 | 3.2 GiB |

系統主架構在 [`.design/system.md`](.design/system.md),各子系統設計在
[`.design/subsystems/`](.design/subsystems/),架構決策紀錄在 [`.design/adr/`](.design/adr/)。
素材包清單在 [`docs/_archive/PACKS.md`](docs/_archive/PACKS.md)。
給 AI agent 的入口是 [`CLAUDE.md`](CLAUDE.md)(建置規則、架構硬規則、開發流程)。

---

## 安裝

需要 GHC 9.14.1 + cabal 3.16(由 `ghcup` 安裝)。**不使用 stack。**

```bash
cabal install assetdb-cli assetdb-server --overwrite-policy=always
```

裝好之後 `assetdb` 與 `assetdb-server` 都在 PATH 上(`C:\Users\User\.cabal\bin`)。
開發時也可以不安裝,直接 `cabal run assetdb -- <子指令>`。

### 外部工具

| 工具 | 用途 | 狀態 |
|---|---|---|
| 7-Zip | rar / 7z 的列表與單筆取出 | ✅ `C:\Program Files\7-Zip\7z.exe` |
| ImageMagick | TIFF / PSD / HEIC 縮圖 | ❌ 未安裝(選配) |

7-Zip **裝在預設路徑但不在 PATH 上**,程式會自己去找。確認用:

```bash
assetdb tools
```

缺席的 sidecar 不會讓素材無法索引,只是沒有預覽圖。

### ⚠️ 建置路徑不可含空格

GHC 在 Windows 上的封存器 `llvm-ar` 會在空格處截斷路徑,以 `No such file or directory` 失敗。
程式碼因此位於 `Documents\alchbees-dev\assetdb\` 而不是素材庫裡面。

**素材本身的路徑可以有空格** —— 那只是資料,不經過編譯器。

---

## 五分鐘上手

所有指令預設讀 `./.assetdb/assetdb.sqlite`,所以**先切到素材庫根目錄**:

```bash
cd C:\Users\User\Documents\alchbees-assets
```

不想切目錄就用 `assetdb --db <路徑> <子指令>`。

### 找素材

```bash
assetdb search -q "book-frame" --kind image --facets
assetdb search -q "藥水" --facets            # 中文靠 AI 標註寫進索引(日常操作 7)
```

### 開圖形介面

```bash
assetdb-server .assetdb/assetdb.sqlite
```

瀏覽器開 <http://localhost:8787>。虛擬化網格、facet 側欄、縮圖預覽都在那裡。

### 建一個帶素材的專案

```bash
assetdb new-project --name Circle --path projects/Circle --pack complete-ui-book-styles --match travel-book
```

---

## 日常操作

### 1. 匯入買來的素材包

這是最常做的事,五個步驟:

**① 把壓縮檔放進 `library/packs/<廠商>/<包名 slug>/`**

原檔名不要改 —— 它是與廠商下載頁對照的依據,`packs.toml` 也以基本檔名比對。

```text
library/packs/crusenho/complete-ui-book-styles/
  └── [GUI] Complete_UI_Book_Styles_Pack_Full.7z
```

**② 掃描**

```bash
assetdb scan --root library --kind packs
```

不解壓。ZIP 讀 central directory,rar / 7z 交給 7-Zip。每筆內容串流計算 SHA-256。
重掃時壓縮檔雜湊沒變就整包跳過,所以第二次執行接近 0 秒。

**③ 補上授權與作者 —— 這一步不能跳過**

掃描能自動得到的只有「這個檔案存在、裡面有這些東西」。**作者、授權、可否商用、
AI 使用揭露一律無法從內容推導**,而且廠商壓縮檔裡有沒有附這些資訊完全看運氣:
Crusenho 附了完整 License.txt,四個 Effects 包什麼都沒有。

所以在 [`data/packs.toml`](data/packs.toml) 加一段:

```toml
[[pack]]
archive = "[GUI] Complete_UI_Book_Styles_Pack_Full.7z"   # 基本檔名,不是完整路徑
name    = "Complete UI Book Styles Pack"
slug    = "complete-ui-book-styles"
vendor  = "Crusenho"
author  = "Crusenho Agus Hennihuno"
author_url = "https://crusenho.itch.io"        # 作者聯絡方式
license = "Crusenho Asset License"             # 引用 licenses 表裡的名稱
ai      = "unknown"                            # unknown / none / assisted / generated
source_url = "https://crusenho.itch.io/complete-ui-book-styles-pack"
version = "1.0"
notes   = "唯一明確要求署名的授權。專案致謝必須包含它。"
```

```bash
assetdb pack apply --catalogue data/packs.toml
```

沒有授權與作者的包狀態是 `draft`,**資料庫層級擋住它進入專案** ——
`packs` 表上有 `CHECK (status = 'draft' OR (license_id IS NOT NULL AND author_id IS NOT NULL))`。

`ai` 的 `unknown` 與 `none` 意義不同:前者是「還沒查」,後者是「作者明確聲明未使用」。
Steam 的 AI 揭露要求只接受後者。11 個 Kibyra 包是 `assisted`。

檢視所有包的授權狀態:

```bash
assetdb pack list
```

**④ 命名(見下一節)**

**⑤ 縮圖與索引**

```bash
assetdb thumbs
assetdb index
```

`scan` 已經會重建索引,`index` 是在手動改過資料之後補跑用的。
縮圖是內容定址的(`cache/thumbs/<sha256 前兩碼>/`),所以多家廠商附的同一份
免費字型只算一次。

### 2. 命名 —— 6 次確認命名 1,653 個檔案

每個廠商的命名風格都不一樣,而且互不相容:

```text
UI_TravelBook_Frame01a.png      Blue Potion 2.png      idle_down.png
potion10.png                    00.png                 #1 - Transparent Icons.png
```

逐檔改名不可行。但**同一包內的檔名一定內部一致**,所以系統把檔名 tokenize 成
「形狀」再分群 —— 1,693 個檔案的 Crusenho 包塌縮成 24 個叢集,其中前 6 個就涵蓋 1,653 個檔案。

**① 看有哪些叢集**

```bash
assetdb cluster list --pack complete-ui-book-styles
```

```text
✓ 1024   sprites|U_W_WNa|.png
          …/01_TravelBook/Sprites/UI_TravelBook_Alert01a.png
          …/04_TabletBook/Sprites/UI_TabletBook_Banner02b.png
✓ 508    animated|U_W_WNa_N|.png
          …/01_TravelBook/Sprites Animated/UI_TravelBook_Alert01a_1.png
```

形狀鍵的讀法:`<目錄角色>|<權杖形狀>|<副檔名>`。權杖形狀裡
`W` 是大寫開頭的字、`w` 是小寫字、`N` 是數字、`a` 是尾隨字母、`U` 是全大寫。

**② 預覽一個叢集的規則**(預設只預覽,不寫入)

```bash
assetdb cluster rule --pack complete-ui-book-styles --shape "sprites|U_W_WNa|.png" --kind ui --domain gui
```

```text
sprites|U_W_WNa|.png  1024 筆
  …/01_TravelBook/Sprites/UI_TravelBook_Alert01a.png
    → ui_gui_ui-travel-book-alert_01a          ← 多了一截 ui-
```

主體吃到了檔名開頭的 `UI_`,而 `ui` 已經是 kind 了。丟掉第 0 個權杖:

```bash
assetdb cluster rule … --kind ui --domain gui --drop 0
```

```text
    → ui_gui_travel-book-alert_01a             ← 對了
```

**這種來回是正常流程,不是出錯。** 一個叢集調對就涵蓋上千個檔案,
所以值得花兩三次預覽把它調準。可用的參數:

| 參數 | 用途 |
|---|---|
| `--drop N` | 丟掉第 N 個權杖(0 起算),可重複 |
| `--subject S` | 固定主體前綴。檔名裡沒有主體時必填(如 `idle_down.png`) |
| `--dirs N` | 把最後 N 層目錄名納入主體。純數字檔名(`00.png`)時用來避免撞名 |
| `--numeric MODE` | 尾端數字當 `variant` 還是 `index`。預設 `auto` |
| `--tag T` | 附加標籤,可重複 |

**③ 確認**

```bash
assetdb cluster rule --pack complete-ui-book-styles --shape "sprites|U_W_WNa|.png" \
  --kind ui --domain gui --drop 0 --confirm
assetdb cluster apply --pack complete-ui-book-styles
```

**資料庫存的是「確認過的規則」而不是結果**,所以廠商出更新版時自動重套。

### 3. 搜尋

```bash
assetdb search -q "travel-book"                 # 全文,子字串也命中(362 筆)
assetdb search -q "金門" --include-reference     # 中文兩字也搜得到(見下)
assetdb search --kind audio --facets            # 依類型 + 顯示各 facet 計數
assetdb search --pack complete-ui-book-styles --named
assetdb search -q "village" --author Cainos --commercial
```

| 選項 | 說明 |
|---|---|
| `-q` | 全文查詢,中英文皆可 |
| `--kind` / `--pack` / `--author` / `--vendor` | 可重複,同欄位之間是 OR |
| `--commercial` | 只要可商用的 |
| `--named` | 只要已指定邏輯名稱的 |
| `--include-reference` | 納入參考資料。**預設排除** —— 找 GUI 框時不該跳出廟宇照片 |
| `--include-excluded` | 納入被判定為非素材的項目(廠商宣傳圖等) |
| `--facets` | 同時顯示各 facet 的計數 |

**`-q` 是子字串比對,不是斷詞。** 邏輯名稱以 `-` 連接多字,所以查 `book-frame`
有 100 筆而查 `book frame`(空格)是 0 筆 —— 索引裡沒有那個字串。
不確定的時候查單一個詞(`frame` → 127 筆、`book` → 1,736 筆)再用 facet 收斂。

中文搜尋走兩條路徑:純 ASCII 與三字以上走 FTS5 的 `trigram` 索引,
**兩字中文詞**(金門、行銷、素材)走另一張 `unicode61` 索引 + 自製 unigram/bigram。
理由見下面的「已知陷阱」。

### 4. 建專案

```bash
assetdb new-project \
  --name Circle \
  --path projects/Circle \
  --pack complete-ui-book-styles \
  --match travel-book
```

`--path` 必須不存在或為空。`--match` 只納入邏輯名稱含該字串的素材,
可與 `--pack` 併用(先取包,再篩名稱)。

產生的結構:

```text
projects/Circle/
├── SKILL.md                  給 AI agent / 新成員:怎麼跑、素材在哪、命名規則、加素材流程
├── README.md
├── Circle.cabal
├── docs/{提案書,技術文檔}.md
│   └── decisions/            ADR
├── src/  app/  test/  tools/
├── assets/
│   ├── manifest.json         AssetDB.Manifest 可直接解析
│   ├── Assets.hs             ← 素材 key 的型別安全常數
│   ├── sprites/{gui,characters,items,fx}/
│   ├── tilesets/ fonts/ levels/ shaders/ theme/
│   └── audio/                先建空目錄
├── .gitattributes            Git LFS(*.png *.psd *.wav)
└── .assetdb/                 預留給專案層級的狀態(目前只建空目錄)
```

`Assets.hs` 長這樣:

```haskell
-- | @assets/sprites/ui_gui_travel-book-frame_01a.png@  (complete-ui-book-styles)
uiGuiTravelBookFrame01a :: AssetKey
uiGuiTravelBookFrame01a = AssetKey "ui_gui_travel-book-frame_01a"
```

**素材 key 打錯是編譯錯誤,不是執行期黑畫面。** IDE 的 find-references 直接回答
「這個專案用了哪些素材」。

#### 授權閘門

選到 `commercial = false` 的素材時整個指令中止並列出違規項。
**`commercial` 為 NULL 也擋** —— 「還沒查」與「不可商用」在這裡必須是同一個結果,
否則閘門會被一個沒填的欄位繞過。

確定專案不商業發行時才用 `--allow-non-commercial`。

### 5. 知識建檔與行銷資訊

這兩個看起來是兩個子系統,實際上是同一張圖上的節點:`notes` 是節點,`links` 是邊,
而素材與專案早就在同一張圖上。

```bash
assetdb note import --path knowledge/papers --kind knowledge
assetdb note import --path marketing --kind marketing
assetdb note list --kind marketing
```

匯入以 `source_path` 為鍵,**重複匯入是更新而不是新增** —— 筆記會被反覆編輯。
標題取自 YAML front matter 的 `title:`,沒有就取第一個 `# 標題`,再沒有就用檔名。

建立關聯:

```bash
assetdb link --from note:01ABC… --to asset:01XYZ… --rel documents --note "9-slice 邊界說明"
```

`--rel` 可用:`uses` / `derives-from` / `variant-of` / `similar-to` / `documents` / `promotes`。

關聯是**雙向可查**的 ——「改這張 tileset 會影響哪些關卡」與「這個關卡用了哪些 tileset」
一樣常見,只做單向等於做了一半。

### 6. 健康檢查

```bash
assetdb doctor
```

會列出:draft 狀態的包、AI 揭露未填、未命名資源數、未分類資源數、
壓縮檔之間的內容重疊、以及散檔覆蓋率(重構刪除閘門的依據)。

### 7. AI 分類與標註(選配,需要本機 llama.cpp)

前面六節都不需要 LLM。這一節是**離線**把分類與中文標籤寫進索引的流程:
素材包的檔名、包名、作者全是英文,CJK 索引本身是好的,缺的只是語料裡沒有中文。
跑過一次之後,中文搜尋就是純 SQLite 查詢 —— 零延遲、零 LLM,推論服務關掉照常運作。

推論服務是 llama.cpp 的 OpenAI 相容端點。**服務沒開時所有 `ai` 指令都會優雅退出**,
不會弄壞資料庫,也不會讓伺服器掛掉。

**① 前置**

```bash
assetdb ai ping        # 要看到 ✓ 與模型名稱;失敗就是 llama.cpp 沒開
assetdb thumbs         # 視覺標註送的是縮圖,縮圖必須先有
assetdb ai status      # 建議數、標註進度、批次紀錄,也會說還有幾份內容缺縮圖
```

**② 叢集層分類**(快,約 8 分鐘)

6,783 筆資源塌縮成約 132 個叢集,所以這一輪是 132 次呼叫,不是五千多次。
產出每個叢集的分類(`gui` / `icon/potion` / …)與共用的風格、題材標籤。

```bash
assetdb ai classify --limit 5      # 先看五個叢集的結果
assetdb ai classify                # 全跑
```

**③ 逐份內容的視覺標註**(慢,過夜的工作)

```bash
assetdb ai vision
```

**5.4 秒 / 份 × 5,321 份 ≈ 8 小時。** 它產出的是「這張圖畫的是什麼」的內容標籤,
叢集層給不了:一個 64 張圖的 treasure-icons 叢集,64 張畫的是 64 種不同的寶物。
目前真實素材庫只跑過 5 份驗證用,尚未全量執行。

**資料庫就是檢查點。** 每一筆的建議與狀態在同一個 transaction 裡提交,LLM 呼叫
嚴格在 transaction 之外:

- Ctrl-C 最多損失進行中的那一筆;重跑同一個指令就是續跑(`pending` 就是佇列)
- 推論服務中途掛掉 → **整批中止,未處理的項目維持 `pending`**,不會被逐一標成失敗
- 真正壞掉的那幾筆記成 `failed` 並存下原因,重跑時跳過;要重試加 `--retry-failed`

讓它活過關掉終端機,並從另一個終端機看進度:

```powershell
Start-Process -FilePath assetdb -ArgumentList 'ai','vision' -WindowStyle Hidden -RedirectStandardOutput vision.log
assetdb ai status
```

**④ 確認與套用**

`classify` 與 `vision` 直接寫進建議暫存表 —— **寫進暫存表本身就是預覽**,閘門只有
一道,在 `apply`。五千份內容會產生約六萬筆建議,逐筆看是不可能的;實際做法是
抽樣檢查再整批確認(信心值沒有鑑別力,這顆模型幾乎全部回 0.9 到 1.0)。

```bash
assetdb ai suggest list --status pending --limit 60
assetdb ai suggest list --target blob --field tag --limit 40     # 抽樣看幾個分類
assetdb ai suggest confirm --all-pending --confirm
assetdb ai apply --confirm                                       # 寫入 + 自動重建索引
```

`apply --confirm` 結尾會自動重建全文索引。漏掉這一步的話上面全部照樣回報成功,
而中文搜尋照樣零筆 —— 這是整個功能最容易靜默失敗的地方,所以綁進 `apply`。

**⑤ 驗收**

```bash
assetdb search -q 藥水 --limit 5
assetdb search --category icon/potion --facets
```

叢集層做完之後的實測:藥水 72 筆、像素風 5,550 筆,奇幻、中世紀、特效、礦石、
藥草都有結果。先前這些全部是零筆。

**⑥ 自然語句查詢**(額外入口,不是主要路徑)

```bash
assetdb ai query -q "中世紀風格的藥水圖示"
```

把一句話翻成搜尋條件再執行;推論服務離線時降級為字面搜尋。

**出事時**

| 症狀 | 意思 | 怎麼辦 |
|---|---|---|
| `✗ 批次中止:連不上推論服務` | 服務掛了,佇列還在 | 重啟 llama.cpp,重跑同一個指令 |
| `輸出被截斷,推理用掉 N tokens 而 content 仍為空` | 模型推理吃光預算 | 確認 thinking 是關的(預設關);或加大 `max_tokens` |
| `content 為空` | 模型想了但沒答 | 同上。驅動器已自動用兩倍預算重試過一次 |
| `略過 N(缺縮圖)` | 那幾份內容沒有縮圖 | 先跑 `assetdb thumbs` |
| 套用後中文還是搜不到 | 索引沒重建 | `assetdb index` |

換模型之後值得重量 thinking 開關:`assetdb ai classify --limit 3 --force` 對照 `--thinking`。
實測 `gemma-4-12b-it` 關掉 thinking 是 3 分 57 秒 → 14.3 秒,而且品質更好;
`Gemma-4-E4B-Uncensored` 則不理會這個欄位,只能靠 `max_tokens` 開大。

**這個模組不做什麼**

- **不改任何既有資料。** 標籤一律以 `source='inferred'` 寫入且 `INSERT OR IGNORE`;
  人工標籤(`manual`)永遠贏,重跑不會覆蓋。
- **不在查詢時呼叫 LLM。** 中文搜尋是純 SQLite。
- **不猜。** 分類是封閉列舉,由 GBNF 在產生時約束 —— 模型吐不出詞彙表以外的值,
  判斷不出來時填 `unknown`。

---

## 圖形介面

```bash
assetdb-server .assetdb/assetdb.sqlite [port]     # 預設 8787
```

伺服器同時提供 API、縮圖與靜態前端:

| 路徑 | 來源 |
|---|---|
| `/api/search`、`/api/facets`、`/api/packs`、`/api/health` | 資料庫 |
| `/thumb/<sha256>/<尺寸>` | `.assetdb/cache/thumbs/` |
| `/` | `<素材庫根>/web/`(已建置的前端) |

### 前端開發

```bash
cd web
npm install
npm run dev          # 5173,API 走 proxy 到 8787
```

正式部署是 `npm run build` 之後把 `web/dist/` 的內容複製到 `<素材庫根>/web/`。

**前端型別由後端產生,前端無法自行編造 API 形狀:**

```bash
assetdb-server --emit-types web/src/api/types.ts
```

---

## 素材庫長什麼樣

```text
C:\Users\User\Documents\alchbees-assets\
├── library/
│   ├── packs/<廠商>/<包 slug>/       ← 一包 = 一目錄 = 一個備份與溯源單位
│   │   ├── pack.toml
│   │   └── <廠商原始檔名>.7z          ← 不可變
│   ├── reference/<主題 slug>/        ← 見圖參考,預設不混進素材搜尋
│   └── studio/                      ← 自製素材,散檔(見下)
│       └── shared/audio/*.wav
├── projects/
├── knowledge/
├── marketing/
├── web/                             ← 已建置的前端
└── .assetdb/
    ├── assetdb.sqlite
    ├── cache/thumbs/<sha256 前兩碼>/
    └── backups/
```

**實體結構按來源(provenance)組織,不按分類。** 有了資料庫之後資料夾就不再是搜尋索引,
把資料夾設計成分類法會重現原本的問題 —— 一個資源同時屬於多個分類
(書本風格的 GUI 框 = GUI + Book + Crusenho + pixel-art),而資料夾只能歸一類。
分類、風格、作者全部在 DB 裡做成多對多。

所以 `Commercial/` `2D/` `GUI/` 這些層級都消失了。授權是**屬性不是位置**,
而且資料夾從來沒有真的擋下過任何違規使用 —— 現在由 `new-project` 的閘門實際擋。

### `library/studio/` 是刻意的例外

自製素材維持散檔 + git,因為它們會被頻繁編輯,壓縮檔會變成阻力。
現在裡面有四個 `.wav`(合成正弦波),是階段 11 的驗證樣本,也留作未來加音效時的參考:

```text
shared/audio/ui_click.wav          44100 Hz / 2ch / 16-bit / 250 ms
shared/audio/ui_page_turn.wav      44100 Hz / 1ch / 16-bit / 600 ms
shared/audio/bgm_village_loop.wav  22050 Hz / 2ch / 16-bit / 2000 ms
shared/audio/sfx_rune_charge.wav    8000 Hz / 1ch /  8-bit / 1500 ms
```

`doctor` 會把它們列在「未覆蓋的散檔」裡 —— 那是正確的,它們本來就不在任何壓縮檔內。

---

## 命名規範

```text
<kind>_<domain>_<subject>[_<variant>][_<state>][_<NNN>]
```

| 欄位 | 值 |
|---|---|
| `kind` | **封閉列舉**:`spr` `tex` `atlas` `ui` `fnt` `sfx` `bgm` `vo` `lvl` `shd` `src` `doc` |
| `domain` | **開放詞彙**:`gui` `ground` `book` `char` `fx` `prop` `bldg` `item` `env` `rune` … |
| `subject` | 單一分段,內部可用 `-` 連接多字 |
| `variant` | 兩位數字加可選字母(`01a`),或具名詞彙(`red` `large`) |
| `state` | 封閉詞彙:`idle` `hover` `pressed` `up` `down` … |
| `NNN` | 序號,補零三位 |

硬性規則:`^[a-z0-9]+(_[a-z0-9-]+)*$`、最長 64 字元、全域唯一、純 ASCII。

`kind` 封閉是因為它驅動處理器與目錄;`domain` 開放是因為每加一種素材領域都要改程式碼
會違反「核心模型不認識圖片」的原則。

實際轉換:

| 原檔名 | 邏輯名稱 |
|---|---|
| `UI_TravelBook_Frame01a.png` | `ui_gui_travel-book-frame_01a` |
| `UI_HoloBook_Alert01a_1.png` | `ui_gui_holo-book-alert-01a_001` |
| `Blue Potion 2.png` | `spr_item_blue-potion_02` |
| `TX Tileset Grass.png` | `tex_ground_tileset-grass` |
| `#1 - Transparent Icons.png` | *(排除 —— 廠商宣傳圖)* |
| `福岡廟宇.HEIC` | *(拒絕 —— `NoAsciiContent`,要求人工命名)* |

最後一條是刻意的:自動音譯會產生沒人查得到的名稱,不如當場要求人工命名。

---

## 給遊戲本體的介面

遊戲是 Haskell(h-raylib + apecs + effectful),直接依賴 `assetdb-core`:

```haskell
import AssetDB.Manifest   -- 解析 assets/manifest.json
import Assets             -- 專案自己的素材 key 常數
```

**兩邊共用同一份型別定義,所以 schema 改動在編譯期爆炸而不是執行期黑畫面。**
這是選 Haskell 後端的實質理由 —— 換成 Python 或 TS 的話,這裡會是兩份手寫、
緩慢漂移的 parser。

`assetdb-core` 因此刻意保持零重量級依賴。任何需要 IO、資料庫或影像處理的東西
都不屬於那裡。

---

## 尚未實作

| 缺口 | 影響 | 目前的替代作法 |
|---|---|---|
| `assetdb project sync` | **無法增量加素材進既有專案** | 用新條件重新產生到新目錄,把 `assets/`、`manifest.json`、`Assets.hs` 換過去 |
| `ai vision` 全量執行 | 5,321 份內容只有 5 份有視覺內容標籤;中文搜尋目前只靠叢集層的風格 / 題材標籤 | 過夜跑 `assetdb ai vision`(約 8 小時,見日常操作 7) |
| 前端匯入 UI | 匯入仍走 CLI | `scan` + 手寫 `packs.toml` |
| 前端叢集確認 UI | 命名仍走 CLI | `cluster list` / `rule` / `apply` |
| 989 筆未分類 | 叢集層分類判不出來的填 `unknown` | 用 `--pack` / `--match` / 全文搜尋,或等視覺標註補上 |
| ogg / mp3 / flac 解碼 | 只分類不取時長 | 已是 `KAudio`,照樣進搜尋 |
| ImageMagick sidecar | TIFF / PSD / HEIC 沒有預覽圖 | 仍可索引與搜尋 |

第一項是最痛的一個,已列入規劃:
[`.design/subsystems/delivery/design.md`](.design/subsystems/delivery/design.md) 功能規劃 #6
`project-sync`,契約卡已備妥,可用 `/feature-design delivery/project-sync` 展開。

---

## 開發

```bash
cabal build all
cabal test all      # 558 examples, 0 failures(9 個 test suite,2026-08-20)
```

| 套件 | 職責 | 測試 |
|---|---|---:|
| `core/` | 領域型別、ULID、命名文法、Manifest schema。**遊戲也依賴這個** | 101 |
| `store/` | SQLite schema、migration、FTS 與 token 前處理 | 109 |
| `archive/` | 壓縮檔存取:列出內容與讀取單筆項目,**不解壓到磁碟** | 39 |
| `ingest/` | 掃描、內容雜湊、格式處理器註冊表、叢集推論、縮圖、筆記 | 116 |
| `reorg/` | 重構計畫、執行、對帳、undo | 32 |
| `project/` | 專案樣板、`manifest.json`、`Assets.hs` 產生 | 24 |
| `ai/` | 本機 LLM 客戶端、GBNF 文法、叢集分類、視覺標註、建議暫存與套用、自然語句查詢 | 42 |
| `server/` | servant HTTP API、靜態服務、TS 型別產生 | 58 |
| `cli/` | `assetdb` 執行檔:參數解析、資料庫路徑解析、端到端 | 37 |
| `web/` | Vite + React + TanStack Virtual | |

子系統與套件的對應:`catalog` = core + store;`ingest` = archive + ingest + reorg;
`ai-tagging` = ai;`delivery` = cli + server + web + project。設計文檔在
[`.design/subsystems/`](.design/subsystems/)。

### 加一種新素材格式

**只改一個清單。** `ingest/src/AssetDB/Ingest/Handler.hs` 的 `handlers`
append 一筆 `Handler`,填 `hExtensions`、`hKind`、`hProbe`。

不需要新資料表、不需要 migration、不動 `assets` 或 `blobs` ——
kind 專屬的中繼資料一律以 JSON 存進 `meta_json`。

這不是宣稱。階段 11 加入 WAV 解析時,`git diff` 只動了兩個檔案,
`Schema.hs` 與 `Migrate.hs` 的 diff 是空的。

---

## 已知陷阱(都是實際撞到的)

**1. GHC 的 `llvm-ar` 不吃含空格的建置路徑。** 見上面的安裝章節。

**2. FTS5 的 `trigram` tokenizer 查詢下限是三個字元。**
中文雙字詞(金門、行銷、廟宇、素材)因此完全搜不到。解法是額外一張 `unicode61` 索引,
存放由 `AssetDB.Store.Tokenize` 預先展開的 unigram 與 bigram ——
**兩者必須分成不同欄位**,混在同一欄會打亂片語查詢的相對位置。

**3. `.7z` 與 `.zip` 的 `7z -slt` 輸出對目錄的表示方式不同。**

```text
.zip 的目錄   Folder = +         Attributes = D drwxrwxrwx
.7z  的目錄   (沒有 Folder 欄位)  Attributes = RD
```

原本只檢查 `Attributes` 開頭是不是 `D` —— 對 zip 正確,對 7z 全數漏判,
1,693 個檔案的素材包因此多出 38 筆假項目。正確作法是把第一個空白分隔的權杖
當成屬性旗標集合。`.7z` 的時間戳還帶小數秒(`16:12:47.3249489`),
用 `%S` 嚴格解析會**靜默**全數失敗。

**4. `Data.Text.IO` 的讀寫都用 locale 編碼,不是 UTF-8。**
`pack.toml` 含中文與 `⚠`,`TIO.writeFile` 直接拋 `cannot encode character '\9888'`;
讀回來時 `TIO.readFile` 又 `cannot decode byte sequence starting from 231`。
所有文字檔 I/O 一律 `BS.writeFile p (encodeUtf8 t)` 與 `decodeUtf8 <$> BS.readFile p`。
**讀與寫都要明確** —— 只修一邊會變成寫得出去讀不回來。

**5. GHC 在 Windows 上預設以系統 ANSI 字碼頁寫 stdout。**
不設 `hSetEncoding stdout utf8` 的話含中文的輸出全是亂碼,而且重導向到檔案時同樣壞掉
—— 不是終端機顯示問題,是真的寫錯位元組。**每個執行檔的 `main` 都要設。**

**6. PowerShell 的 `Select-Object -First N` 會終止上游行程。**
`assetdb cluster rule --confirm | Select-Object -First 20` 會在寫入規則之前把程式殺掉,
結果是「看起來跑完了但只做了一半」。**有副作用的指令一律重導向到檔案再讀。**

**7. PATH 上的 `assetdb` 是 `cabal install` 當下的快照,不會跟著程式碼走。**
schema 改版後用舊執行檔開資料庫會直接丟 `DatabaseNewerThanCode 4 3`(資料庫 v4、程式碼 v3)
—— 這是刻意的:沒有 down migration(ADR-006),舊程式碼不該碰新資料庫。
`git pull` 之後重跑一次安裝章節的 `cabal install … --overwrite-policy=always`;
開發時一律 `cabal run assetdb -- <子指令>`,不要拿 PATH 上的那份驗證行為。
