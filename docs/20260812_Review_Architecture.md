# AssetDB 架構健康檢查報告

> **2026-08-16 更新**:本報告的 P0/P1 問題已轉為 `docs/bugfix/bug-0001` 至 `bug-0006`,
> P2/P3 與 magic number / 硬編碼 / DRY 章節的建議已轉為 `docs/enhance/` 底下的 14 份改善提案,
> 可執行 `/code-audit status` 追蹤修正進度。本報告維持原樣作為當時分析的
> 完整記錄,不再更新。

> 審查日期:2026-08-12(依檔名);實際逐檔閱讀完成於 2026-08-13。
> 範圍:九個 Haskell 套件(core / store / archive / ingest / reorg / project / ai / server / cli,約 8,600 行)
> 與 React 前端(web/,約 1,100 行),含全部 `.cabal`、`cabal.project`、`vite.config.ts`。
> 所有指涉均附 `檔案:行號`,皆為逐檔閱讀後確認,非工具掃描猜測。

---

## 一、總評

**這是一個架構品質顯著高於平均的程式庫。** 分層乾淨、依賴方向單向、關鍵接縫有意識地設計過,
而且幾乎每一個「看起來奇怪的決定」都在註解裡留下了理由與實測證據。多數專案的健康檢查是在找
「哪裡沒想清楚」;這份報告找到的問題大多屬於「想清楚了但還沒做完」。

| 面向 | 評價 | 摘要 |
|---|---|---|
| 分層與依賴方向 | ★★★★★ | 嚴格的 DAG,無循環;server 只依賴 core+store,刻意保持精瘦 |
| 模組化 / 低耦合 | ★★★★☆ | ai↔ingest 以依賴注入解耦是教科書級;扣分在小工具函式重複五份 |
| Magic number 治理 | ★★★★☆ | 絕大多數有具名常數或實測依據註解;少數散落未命名(見第四節) |
| 硬編碼 | ★★★☆☆ | 一次性重構的路徑規則活在函式庫層;port 8787 出現在三處 |
| 錯誤處理 | ★★★★☆ | 失敗分類(transient/permanent)、中止語意都設計過;剩兩三個 partial function |
| **已知問題的收斂** | ★★☆☆☆ | **2026-08-11 診斷報告指出的修正一項都還沒落地**(見第三節 P0) |
| 測試 | ★★★☆☆ | 七個函式庫套件皆有 spec;cli 零測試、server 僅一個、web 零測試 |

---

## 二、架構與模組化評估

### 2.1 依賴圖(由 `.cabal` 逐一確認)

```
                    ┌─────────┐
                    │  core   │  型別、ULID、命名文法、Manifest(無任何內部依賴)
                    └────┬────┘
          ┌──────────┬───┴────┐
     ┌────┴───┐ ┌────┴───┐    │
     │ store  │ │archive │    │
     └───┬────┘ └───┬────┘    │
   ┌─────┼──────────┼─────────┤
┌──┴──┐ ┌┴────────┐ ┌┴───────┐│
│ ai  │ │ ingest  │ │project ││   ai → core,store(刻意不依賴 ingest)
└──┬──┘ └──┬───┬──┘ └───┬────┘│   ingest → core,store,archive
   │       │  ┌┴────┐   │     │   project → core,store,archive
   │       │  │reorg│   │     │   reorg → core,store,ingest
   │       │  └──┬──┘   │     │
   │  ┌────┴──┐  │      │     │
   │  │server │←─┼──────┼── core,store **只有這兩個**
   │  └───────┘  │      │
   └──────┬──────┴──────┘
        ┌─┴─┐
        │cli│  組合根:依賴全部
        └───┘
```

**結論:無循環依賴,方向全部朝下,cli 是唯一的組合根。** 這個形狀是低耦合的必要條件,而且它做到了。

### 2.2 值得點名的優良設計(這些是資產,改動時不要破壞)

1. **ai 與 ingest 的解耦(依賴注入)** — `ai/src/AssetDB/AI/Classify.hs:7-13` 與
   `ai/src/AssetDB/AI/Suggest.hs:230-237`:叢集清單由呼叫端(CLI)算好遞入、
   叢集反查以 `aoResolveCluster :: Text -> IO [Int]` 函式注入。理由寫得很清楚:
   否則 JuicyPixels 與 zip 會經由 ai 被拖進 server。這是整個程式庫最好的一道接縫。
2. **唯一 I/O 接縫的 LLM 傳輸層** — `ai/src/AssetDB/AI/Llm.hs:140-143`:`llmSend` 是整個
   ai 套件唯一的 I/O 出口,`fakeLlm` 讓十小時批次驅動器的每條路徑可以在毫秒內對 in-memory DB 測完。
3. **純函數規劃器 + IO 快照邊界** — `reorg/src/AssetDB/Reorg/Plan.hs`(純)與
   `Snapshot.hs`(唯一 IO 邊界)。刪除 5,424 個檔案的決策邏輯完全可以在測試中重現。
4. **列舉一律存文字** — `core/src/AssetDB/Types.hs:48` 的 `TextEnum` + `store/src/AssetDB/Store/Orphans.hs`
   的橋接。JSON 與 SQLite 表示由同一個函式產生,單一真相。
5. **失敗語意的分層** — `ai/src/AssetDB/AI/Run.hs:99-102`:`StepFailed`(這一筆的問題,記錄後續跑)
   與 `StepAbort`(服務掛了,整批停下、佇列保留)的區分,直接決定了十小時批次的可續跑性。
   `Run.hs:76-80` 的 `guardedTry` 不吞 Ctrl-C 也是同一等級的用心。
6. **手寫 JSON instance 保護線上格式** — `core/Manifest.hs:150-153`、`server/Api.hs:66-70`:
   欄位名不交給 Generic 推導,改名 Haskell 欄位不會無聲改掉合約。
7. **schema 即文法約束** — `ai/src/AssetDB/AI/Schema.hs`:llama.cpp 把 JSON Schema 編成 GBNF,
   `visionScopes`(`Vocab.hs:55-56`)讓「牛排圖示被分類成 audio」這種錯誤在文法層無法表達。
8. **原則 4 的實證** — 加入 WAV 支援只改了 `ingest/Handler.hs` 的一個欄位(`audioHandlerStub` 的
   `hProbe`),零 migration、零核心表改動。「核心模型不認識圖片」不是宣稱,是 git diff 可查的事實。

### 2.3 耦合度的扣分項

- **CLI 直接觸碰低層 SQL。** `cli/app/AssetDB/Cli/Ai.hs:331-353`(`runAiStatus`)在 CLI 層手寫
  `SELECT ai_status, COUNT(*) …`,同檔 `resolveCluster`(286-298)也是。這讓「ai_status 欄位改名」
  的爆炸半徑跨到 cli。屬輕微越層——邏輯上該收進 ai 套件的查詢函式。
- **server 與 ingest/ai 各自實作縮圖路徑規則(三份)。** `ingest/Thumb.hs:44-46`、
  `ai/Image.hs:35-37`、`server/App.hs:110-111` 都知道「`前兩碼/sha_size.png`」這條規則。
  ai 那份有註解說明是刻意換取不依賴 ingest——理由成立,但**這條規則是純函數,放進 core 就能
  三方共用而不引入任何相依**(core 已是三者的共同依賴)。`ThumbSize` 列舉同樣重複兩份
  (`ingest/Thumb.hs:31`、`ai/Image.hs:22`)。
- **雙真相:`naming_vocab` 資料表 vs `defaultVocab`。** `store/Schema.hs:277-285` 建表並播種,
  註解宣稱「AssetDB.Naming 的 NamingVocab 從這裡讀——加 domain 是插一列資料,不是改程式碼」。
  **但全庫沒有任何程式碼查詢 `naming_vocab`**;CLI 的 cluster 指令
  (`cli/app/AssetDB/Cli/Cluster.hs:104,141`)一律用 `core/Naming.hs:202` 寫死的 `defaultVocab`。
  這張表目前是死資料,而 states/variants 詞彙有兩份會漂移的定義。二選一:把載入接上,或刪表改註解。

---

## 三、問題清單(依嚴重度)

### P0 — 已知且已寫成報告,但尚未修正

`診斷報告-2026-08-11.md` 對「前端 0 筆」事故給出的三項程式修正,**逐一核對後確認全部未落地**:

| # | 問題 | 現況證據 |
|---|---|---|
| 1 | `resolveDbPath` 只看 cwd,找不到就**靜默建空庫** | `cli/app/AssetDB/Cli/Options.hs:484-490` 原樣未動。在錯誤目錄執行任何指令仍會無中生有一個空資料庫,之後所有查詢誠實地回 0 筆,全程無錯誤訊息 |
| 2 | 伺服器對不存在的 db 路徑**直接建檔灌 schema** | `server/src/AssetDB/Server/App.hs:34-35`(`withStore` → `initSchema`)原樣未動;啟動時也沒印出實際連到哪個檔案、有幾筆資料 |
| 3 | port 參數用 partial `read` | `server/app/Main.hs:26` `read p` —— 打錯 port 會噴無上下文的 `Prelude.read: no parse` |

事故的副產品也還在磁碟上:`assetdb\--help`、`--help-shm`、`--help-wal`(舊 bug 產物)與
`assetdb\.assetdb\assetdb.sqlite`(8/12 早上誤建的空庫)均未清理;`alchbees-dev\.assetdb\`
的重構前舊庫(11,822 筆、FTS 不同步)也仍在原地。**這一組是本報告唯一的 P0:不是新問題,
而是「同一個靜默失敗模式隨時可以再發生一次」。**

### P1 — 應儘快處理

1. **伺服器綁定所有網路介面且無任何驗證。** `server/App.hs:37` 用 `Warp.run`,預設 host 是 `*`
   ——同一個區網的任何機器都能搜尋素材、拉縮圖、讀 packs 清單。單人本機工具可以接受無驗證,
   但至少應改綁 `127.0.0.1`(`Warp.runSettings` + `setHost "127.0.0.1"`),想開放時再明確給旗標。
2. **`/thumb/:sha/:size` 未驗證 sha 格式,存在受限的路徑穿越。** `server/App.hs:109-115` 直接以
   URL 片段組檔案路徑。servant 的 `Capture` 會把 `%2F` 解碼成 `/`,`sha` 可夾帶 `../`;
   雖然尾碼被鎖定為 `_128.png`/`_512.png` 使實際危害有限,仍應在使用前驗證
   `T.all isHexDigit sha && T.length sha == 64`。順帶:同函式註解說「可以無限期快取」,
   但**實際上沒有設任何 `Cache-Control` 標頭**——註解與行為不符,快取收益也沒拿到。
3. **`naming_vocab` 死資料表 / 詞彙雙真相**(詳見 2.3)。這不只是整潔問題:cluster 規則的
   解析結果依賴 states/variants 詞彙,兩份定義一旦漂移,`parse ∘ render == id` 的性質會在
   使用者看不見的地方破掉。
4. **`Data.Text.IO.putStrLn` 與 UTF-8 修正並存的檢查。** `core/Console.hs` 的 `setupConsole`
   已解決主控台編碼(cli 與 server 的 main 都有呼叫,佳);但診斷報告 A 的教訓是「產生位元組
   與解讀位元組是兩件事」——若未來有人在 `setupConsole` 之前輸出任何文字,亂碼會回來。
   建議在 CLAUDE.md 或註解裡固定「main 第一行必須是 setupConsole」的守則(目前兩個 main 都做對了)。

### P2 — 真實但影響面小

1. **手刻 JSON 序列化,轉義不完整。** `ingest/Notes.hs:113-115` 的 `frontJson` 只跳脫雙引號,
   front matter 值含反斜線或控制字元會寫進**不合法的 JSON** 到 `notes.front_matter_json`。
   aeson 就在依賴裡,應直接 `encode (Map.fromList kvs)`。
2. **`tableOf` 是 partial function,吃使用者輸入。** `ingest/Notes.hs:146-153` 對未知實體型別
   `error` 崩潰,而 `assetdb link --from foo:xxx` 的型別字串正是使用者打的。應回 `Either` 並
   在 CLI 層轉成友善訊息。同模組 `entityLinks:176` 把內部整數 id 直接 `show` 回傳給呼叫端,
   與全系統「對外一律 ULID」的慣例不一致。
3. **散檔掃描整檔載入記憶體。** `ingest/Scan.hs:329` `BS.readFile p`——與 `Hash.hs:39-44`
   「串流讀取,1 GB 參考壓縮檔不該整檔進記憶體」的自我要求矛盾。目前散檔多為小圖示所以沒炸,
   但 `library/studio/` 與 reference 根目錄的散檔沒有大小上限保證。
4. **`upsertSuggestions` 回報值不誠實。** `ai/Suggest.hs:124-128` 回傳 `length sgs`,
   但 SQL 的 `ON CONFLICT … WHERE status='pending'` 可能實際上一筆都沒寫(已被人工決定過)。
   呼叫端顯示「產生 N 筆建議」會高估。
5. **TsTypes 的防漂移測試少了一半。** `TsTypesSpec` 保證 `Api.hs` 的 ToJSON 與 `TsTypes.hs`
   一致,但**沒有任何機制保證 `web/src/api/types.ts`(磁碟上那份、前端實際編譯用的)有重新產生**。
   忘記跑 `--emit-types` 時前端照樣編譯通過。建議在 CI 或測試中比對產生器輸出與磁碟檔案。
6. **`applySuggestions` 逐筆解析目標,cluster 目標每筆全表掃描。** `ai/Suggest.hs:269-282`
   對每筆建議呼叫 `resolveTargets`;cluster 分支(`cli/Ai.hs:286-298`)把整包 assets 撈回來在
   Haskell 端過濾。同一叢集有 8 筆建議就掃 8 次。目前資料量(6 千筆)無感,寫法上是 O(建議數 × 包大小)。
7. **`migration003` 以字串拼接組 SQL。** `store/Schema.hs:698-727`(`upd`/`sub`)。值全是
   編譯期字面值,**無注入風險**,但任何人日後在定義文字里加一個單引號,migration 會在使用者
   機器上炸。至少加一條註解警告,或改用參數化(migration 執行器目前只支援 `execute_`,是其不支援參數的結構性原因)。

### P3 — 紀錄在案即可

- `ingest/Scan.hs:117-121` `discover` 不防符號連結迴圈(Windows junction 可造成無窮遞迴)。
- `ingest/Notes.hs:53-59` front matter 解析假設 `\n---` 後恰有一個字元被 `T.drop 4` 吃掉,`---` 後直接 EOF 的邊界值會偏移。
- `web/Grid.tsx:97` effect 以 `virt.getVirtualItems()` 為依賴,每次渲染都重跑(有 `pending` 集合守門,無實害)。
- `reorg/Execute.hs:225` 跨磁碟 fallback 為 copy+delete,不是原子操作;中斷後靠 preflight 的「兩邊都在→拒絕」接住,設計自洽。

---

## 四、Magic Number 盤點

**整體紀律良好**:多數常數要嘛有名字、要嘛旁邊就是實測依據。以下為全量清單,「⚠」標記建議收斂的項目。

### 4.1 有名字或有實測依據(健康)

| 位置 | 值 | 含義與依據 |
|---|---|---|
| `core/Naming.hs:125-126` | `maxLogicalNameLength = 64` | 具名常數,註解說明路徑深度預算 |
| `core/Manifest.hs:52-53` | `currentSchemaVersion = 1` | 具名,附遞增規則 |
| `ai/Prompt.hs:43-44` | `promptVersion = "v1"` | 具名,存入 `ai_runs` 供溯源 |
| `store/Store.hs:67` | `busy_timeout = 5000` | 註解說明;且 `ai/Vision.hs:13-15` 明確記載「LLM 呼叫 5.8 秒 > 5 秒,絕不跨呼叫持有 transaction」的推理 |
| `ai/Llm.hs:111-124` | `maxTokens 1600 / temp 0.2 / timeout 120s / retries 2 / retryBase 500ms` | 每一個都附實測依據(1200 為實測下限留 33% 餘裕、5.8s×20 倍等) |
| `ingest/Handler.hs:141-152` | `uniqueColours limit = 4096` | 註解:超過即非色盤像素風,續數為浪費 |
| `ingest/Thumb.hs:31-41` | `Thumb128 / Thumb512` | 具名列舉(但見 4.2 ⚠ 重複) |
| `ai/Run.hs:180` | 每 25 筆寫回進度 | 註解:伺服器觀察 CLI 批次的唯一窗口 |
| `ai/Vision.hs:190-196`、`Prompt.hs:137,210-211,265` | 標籤上限 4 / 6 / 8 | 註解:壓制同義詞灌水索引 |
| `ingest/Cluster.hs:229-233` | 樣本頭中尾取 5 筆 | 註解:前 N 筆看不出叢集跨度 |
| `core/Id.hs:60-62` | 48/80 bits | ULID 規格,具名常數 |

### 4.2 未命名、重複、或彼此矛盾(⚠ 建議處理)

| 位置 | 值 | 問題 |
|---|---|---|
| ⚠ `server/App.hs:62` | `maybe 60 (min 500) lim` | 預設頁 60、上限 500,無名字無註解;且與 `store/Search.hs:68` 的 `sqLimit = 50`、`web/Grid.tsx:8` 的 `PAGE = 120`、`cli/Search.hs` 的 `--limit 20` 是**四個各自為政的分頁常數**。至少 server 的 60/500 應具名 |
| ⚠ `server/App.hs:110` | `if size >= 512 then "512" else "128"` | 字串重刻縮圖尺寸,與 `ThumbSize` 列舉脫鉤;新增尺寸時這裡不會跟著爆編譯錯誤 |
| ⚠ `ai/Image.hs:22` vs `ingest/Thumb.hs:31` | `ThumbSize` 列舉 ×2 | 同一概念兩份定義(收進 core 可解,見 2.3) |
| ⚠ `cli/Ai.hs:243` | `sfLimit = 100000` | 「all-pending 的無上限」以魔術大數表達;建議 `maxBound` 語意的具名常數或真正的無 LIMIT 查詢 |
| ⚠ `cli/Ai.hs:150,190`、`reorg/Execute.hs:307` | 進度節流 `mod 5` / `mod 20` / `mod 500` | 三處三個值,無名字。無實害,具名一次可統一 |
| `web/Grid.tsx:7-8` | `CELL = 132`、`PAGE = 120` | 有名字,無註解說明 132 的由來(128 縮圖 + 4?);`App.tsx:22` 去抖 200ms 有註解 |
| `web/Facets.tsx:171,188` | `slice(0, 30)` | 每組 facet 顯示上限,行內字面值出現兩次 |
| `ai/Run.hs:124` | `T.take 60 pgLabel`;`Llm.hs:300,338-342` 的 `T.take 400/200` | 截斷長度散落,無害但無名 |

---

## 五、硬編碼盤點

### 5.1 有意識的、可接受的(附理由)

| 位置 | 內容 | 評註 |
|---|---|---|
| `ai/Llm.hs:108-109` | `http://localhost:8080`、模型名 `"gemma"` | 是**預設值**而非寫死:`--llm-url`/`--llm-model` 可覆寫(`cli/Options.hs:149-158`) |
| `archive/Sidecar.hs:41-50` | 7-Zip 的七個候選安裝路徑 | 註解記載實機教訓(裝了但不在 PATH);合理的探測清單 |
| `vite.config.ts:9-12` | dev proxy 指向 `localhost:8787` | 換來前端程式碼零條件式 base URL,前端一律相對路徑(`client.ts`),是正確取捨 |
| `store/Schema.hs:491-513` | 八份授權條款逐字寫進 migration | 註解講明:查證過的證據,重打一次就是重新引入錯誤的機會 |
| `ingest/Scan.hs:140-141` | `isMetadata = ["pack.toml","manifest.json"]` | 系統自產檔案清單,與功能同步演進,放程式碼合理 |

### 5.2 應該收斂的

1. **Port 8787 出現在三個地方**:`server/app/Main.hs:26`(預設值)、同檔 usage 文字、
   `web/vite.config.ts:10-11`。改 port 要記得改三處。建議 server 端具名常數 + usage 引用它;
   vite 端無法共用,至少註解互相指涉。
2. **一次性重構的規則活在函式庫層。** `reorg/Plan.hs:154` `isVendorAsset = "Game Assets itchio/" 前綴`、
   `Plan.hs:186-192` `mapTopLevel` 的三條中文資料夾對應(`GameProjects/`→`projects/` 等)、
   `reorg/Execute.hs:302` `pruneEmptyDirs (src </> "Game Assets itchio")`。這些是**針對 2026-08 那一次
   搬遷的舊目錄名**,重構已執行完畢(DESIGN.md 階段 3 ✅),它們如今是死碼加上誤觸風險
   (再跑一次 apply 會去舊路徑找東西)。建議:整組抽成「遷移設定」資料(或直接刪除並在 git 歷史留念)。
3. **專案模板名寫死。** `project/Create.hs:138` `"haskell-raylib-2d" :: Text` 直接進 INSERT;
   `projects.template` 欄位存在的意義是多模板,但 CLI 沒有對應參數。要嘛開參數,要嘛註解說明單模板現狀。
4. **副檔名清單三份。** 壓縮格式:`archive/Types.hs:46-49`(`formatExtensions`,權威)、
   `ingest/Handler.hs:213`(archiveHandler 的 `.zip/.rar/.7z/.tar/.gz`——**比權威版多了 tar/gz**,
   代表 tar.gz 會被標為 KArchive 但 `detectFormat` 不認得、掃描時當散檔雜湊,行為不一致但無害)、
   `reorg/Execute.hs:291`(`isArchiveLike` 又一份 `.zip/.rar/.7z`)。建議統一引用 `formatExtensions`。
5. **`web/` 靜態根與 `cache/thumbs` 的位置慣例**由 db 路徑推導(`server/app/Main.hs:30-31`),
   慣例本身沒問題且 usage 有說明;但配合 P0-2(不存在就建庫)會出現「三個目錄慣例全對、
   資料庫卻是空的」的靜默組合——修 P0 時一併把實際路徑印出來即可。

---

## 六、重複知識(DRY)清單

單一套件內沒有明顯重複;跨套件的重複集中在**五個小工具函式**,全部是純函數,收進 core 零成本:

| 重複的知識 | 出現位置(數) |
|---|---|
| `leafOf`(取 `/` 路徑最後一段) | `ingest/Scan.hs:443`、`ingest/Cluster.hs:236`(stemOf 內)、`reorg/Execute.hs:405`、`reorg/PackToml.hs:81`、`project/Create.hs:286`(5 份) |
| 副檔名抽取(小寫含點) | `ingest/Handler.hs:81-86`、`ingest/Cluster.hs:242-247`、`project/Create.hs:285-290`(3 份,邏輯微異:Handler 有 `map toLower` 完整版) |
| `slugify` | `ingest/Scan.hs:418-428`、`reorg/Plan.hs:196-206`(2 份,實作幾乎逐字相同) |
| 縮圖快取路徑規則 | `ingest/Thumb.hs:44`、`ai/Image.hs:35`、`server/App.hs:110`(3 份;前兩份互相知情,第三份沒有註解指涉) |
| `nowText`(ISO-8601 現在時刻)與 `compact`(壓平例外訊息) | 各出現 6+ 份 |

這些不是「壞味道等級」的問題——每份都很短——但 `slugify` 與縮圖路徑是**會咬人的重複**:
兩份 `slugify` 若有一份日後修改(例如保留數字開頭的處理),pack 目錄名與掃描 slug 會分家;
縮圖路徑規則變動(例如改兩層分桶)則需要同時記得三處。建議在 core 開一個
`AssetDB.PathText`(或類似)模組收容,一次還清。

---

## 七、測試覆蓋

| 套件 | Spec 檔數 | 觀察 |
|---|---|---|
| core | 3(Id/Manifest/Naming) | Naming 有 QuickCheck `parse ∘ render == id` 性質測試,輸入取自真實素材庫 |
| store | 5(Schema/Migrate/Fts/Search/Tokenize) | Schema 測到種子資料筆數;FTS 有中文雙字詞回歸測試 |
| ingest | 8 | Handler(WAV chunk 走訪、padding byte)、ClusterDb(撞名攔截)皆有 |
| archive | 3 | Sidecar 的 `-slt` 解析、zip/7z 目錄判定差異有測 |
| reorg | 3 | Execute 冪等性、Plan 刪除閘門有測 |
| ai | 4(Llm/Prompt/Schema/Suggest) | SuggestSpec 是「扇出」驗收點,選對了測試標的 |
| project | 2 | TemplateSpec 薄;授權閘門邏輯在 Create.hs 未見直接測試 |
| **server** | **1**(TsTypesSpec) | search/facets/health handler 無測試;`mkQuery` 的 limit 夾制無測試 |
| **cli** | **0** | 參數解析、`resolveDbPath`(P0 事故的正主)、doctor 全裸奔 |
| **web** | **0** | 無任何測試設施 |

**優先補位**:`resolveDbPath`(修 P0 時連測試一起補)、server 的 handler(至少 health 與
limit 夾制)、`project/Create.hs` 的 `nonCommercialPacks`(NULL 也擋的語意是法律風險防線,
值得一條直接的測試)。web 的測試投資報酬率低,可暫緩。

---

## 八、建議行動(優先序)

1. **【P0,半天】落實 2026-08-11 診斷報告的三項修正**:`findDbUpwards` + 找不到就 `die`、
   伺服器拒絕建庫並印出「db 路徑 + 筆數」、port 改 `readMaybe`。報告裡連程式碼都寫好了,照抄即可。
   順手刪除 `--help*` 三個檔案與 `assetdb\.assetdb\` 空庫。
2. **【P1,一小時】** server 綁定 `127.0.0.1`;`/thumb` 驗證 sha 為 64 位十六進位;補上 `Cache-Control: public, max-age=31536000, immutable`。
3. **【P1,半天】** 解決 `naming_vocab` 雙真相:接上載入(`loadNamingVocab :: Connection -> IO NamingVocab`,
   模式照抄 `ai/Vocab.hs:59` 的 `loadVocab`)或刪表。
4. **【P2,半天】** 開 `core` 的共用純函數模組,收容 `leafOf`/`extensionOf`/`slugify`/`thumbPath`/`ThumbSize`,
   刪掉五處重複;`reorg` 的一次性路徑規則抽成資料或除役。
5. **【P2,一小時】** `Notes.hs` 的 `frontJson` 改用 aeson;`tableOf` 去 partial 化。
6. **【P2,持續】** 給 cli 的 `resolveDbPath` 與 server handler 補測試;CI 中比對 `--emit-types` 輸出與 `web/src/api/types.ts`。

## 九、一句話結論

**架構是穩固的、模組化是真的、低耦合是設計出來而非碰巧的**;目前最大的風險不在程式碼的形狀,
而在**已診斷出的靜默失敗路徑(空資料庫三兄弟)仍然敞開**,以及少數「註解承諾了但程式碼沒兌現」
的漂移點(`naming_vocab`、縮圖快取標頭)。把第八節的前三項做完,這個專案的健康狀態就與它的
文件品質相稱了。
