# AI 分類與標註

本機 llama.cpp,OpenAI 相容端點。**推論服務沒開時所有指令都會優雅退出**,
不會弄壞資料庫,也不會讓伺服器掛掉。

---

## 為什麼需要這個

素材庫裡 27 個商業素材包的檔名、包名、作者**全是英文**。CJK 索引本身是好的
(搜「金門」找得到中文命名的參考包),缺的只是中文文本 —— 語料裡一個中文字
都沒有,所以任何中文查詢都是零筆。

解法是**離線**把中文標籤寫進索引,而不是每次查詢都翻譯。之後中文搜尋是純
SQLite 查詢:零延遲、零 LLM、推論服務關掉也照常運作。

---

## 前置

```bash
assetdb ai ping
```

要看到 `✓` 與模型名稱。失敗就是 llama.cpp 沒開。

視覺標註**送的是縮圖**,所以縮圖必須先產生:

```bash
assetdb thumbs
```

`assetdb ai status` 會告訴你還有多少份內容沒有縮圖。

---

## thinking 開關 —— 先量再決定

模型能不能關掉推理段落**取決於它的 chat template**,實測過兩顆結果相反:

| 模型 | `enable_thinking:false` | 影響 |
|---|---|---|
| `Gemma-4-E4B-Uncensored` | 無效 | 只能靠 `max_tokens` 開大 |
| `gemma-4-12b-it` | **有效** | 4.8s → 0.2s,答案相同 |

預設是**關閉** thinking。對支援的模型是巨大的加速,對不支援的模型只是一個
被忽略的欄位,沒有副作用。

換模型之後值得重量一次:

```bash
assetdb ai classify --limit 3 --force
```

再跟 `--thinking` 的結果比。實測 12B 那顆的差距是 **3 分 57 秒 → 14.3 秒**,
而且關掉 thinking 之後品質更好(開著時有一筆因推理吃光預算而截斷失敗)。

---

## 第一步:叢集層分類

6,393 筆資源塌縮成 132 個叢集,所以這一輪是 132 次呼叫而不是 5,320 次。

```bash
assetdb ai classify
```

實測 **8 分鐘**,零失敗。產出每個叢集的分類(`gui` / `icon/potion` / …)與
共用的風格、題材標籤。

先看再全跑:

```bash
assetdb ai classify --limit 5
```

```bash
assetdb ai suggest list --field category --limit 40
```

---

## 第二步:逐份內容的視覺標註

```bash
assetdb ai vision
```

**5.4 秒 / 份 × 5,315 份 ≈ 8 小時。** 這是過夜的工作。

它產出的是**內容**標籤 —— 「這張圖畫的是什麼」。叢集層給不了這個:一個
64 張圖的 treasure-icons 叢集,64 張畫的是 64 種不同的寶物。

### 中斷與續跑

**資料庫就是檢查點。** 每一筆的建議與狀態在同一個 transaction 裡提交,
LLM 呼叫嚴格在 transaction 之外(握著 5.8 秒的寫鎖會撞爆 `busy_timeout`,
同時在跑的伺服器就會寫入失敗)。

- Ctrl-C 最多損失進行中的那一筆。
- 推論服務中途掛掉 → **整批中止,未處理的項目維持 `pending`**。已驗證:
  指向死掉的 port 跑三筆,結果是 0 筆被標成失敗,佇列原封不動。
  這一點很重要 —— 若把服務中斷當成「這一筆失敗」,剩下幾千筆會被逐一
  標成 failed,工作佇列就毀了。
- 重跑同一個指令就是續跑。`ai_status = 'pending'` 就是佇列。
- 真正壞掉的那幾筆會記成 `failed` 並存下原因,重跑時跳過。要重試:

```bash
assetdb ai vision --retry-failed
```

### 讓它活過關掉終端機

```bash
Start-Process -FilePath assetdb -ArgumentList 'ai','vision' -WindowStyle Hidden -RedirectStandardOutput vision.log
```

從另一個終端機看進度:

```bash
assetdb ai status
```

`ai_runs` 的 `done` / `failed` 每 25 筆寫回資料庫,所以**伺服器也看得到**
一個不是它啟動的 CLI 批次跑到哪裡。

---

## 第三步:確認與套用

閘門只有一道,在 `apply`。`classify` 與 `vision` 直接寫進 `ai_suggestions`
待確認 —— **寫進暫存表本身就是預覽**,在一個八小時的批次上再加一道閘門,
等於要嘛跑兩次、要嘛把結果丟掉。

```bash
assetdb ai suggest list --status pending --limit 60
```

⚠️ **5,315 份內容會產生約六萬筆建議,逐筆看是不可能的。**
實際做法是抽樣檢查再整批確認。信心值幫不上忙 —— 這顆模型幾乎全部回
0.9 到 1.0,`--min-confidence` 沒有鑑別力。

抽樣看幾個不同分類的結果:

```bash
assetdb ai suggest list --target blob --field tag --limit 40
```

滿意之後:

```bash
assetdb ai suggest confirm --all-pending --confirm
```

```bash
assetdb ai apply --confirm
```

`apply --confirm` 會在最後自動 `reindexFts`。**漏掉這一步的話,上面全部
照樣回報成功,而中文搜尋照樣零筆** —— 這是整個功能最容易靜默失敗的地方,
所以把它綁進 apply,不留給人記得。

---

## 驗收

```bash
assetdb search -q 藥水 --limit 5
```

```bash
assetdb search --category icon/potion --facets
```

叢集層做完之後的實測結果:藥水 72 筆、像素風 5,550 筆、奇幻、中世紀、
特效、礦石、藥草都有結果。先前這些全部是零筆。

---

## 出事時

| 症狀 | 意思 | 怎麼辦 |
|---|---|---|
| `✗ 批次中止:連不上推論服務` | 服務掛了,佇列還在 | 重啟 llama.cpp,重跑同一個指令 |
| `輸出被截斷,推理用掉 N tokens 而 content 仍為空` | 模型推理吃光預算 | 確認 thinking 是關的;或加大 `max_tokens` |
| `content 為空` | 模型想了但沒答 | 同上。驅動器已自動用兩倍預算重試過一次 |
| `略過 N(缺縮圖)` | 那幾份內容沒有縮圖 | 先跑 `assetdb thumbs` |
| 套用後中文還是搜不到 | 索引沒重建 | `assetdb index` |

---

## 這個模組不做什麼

- **不改任何既有資料。** 標籤一律以 `source='inferred'` 寫入,而且用
  `INSERT OR IGNORE`。人工標籤(`manual`)永遠贏,重跑不會覆蓋。
- **不在查詢時呼叫 LLM。** 中文搜尋是純 SQLite。`assetdb ai query` 是
  額外的自然語句入口,不是主要路徑。
- **不猜。** 分類是封閉列舉,由 GBNF 在產生時約束 —— 模型吐不出不在
  詞彙表裡的值。判斷不出來時填 `unknown`。
