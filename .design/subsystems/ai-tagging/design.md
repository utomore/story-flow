---
id: ai-tagging
type: subsystem
title: ai-tagging
description: 以本機 LLM 離線批次分類與標註素材,結果先進暫存表待人工確認
status: active
created: 2026-08-19
updated: 2026-08-19
parent: system
related-adr: [ADR-007]
---

# AI Tagging 子系統架構

## 定位與範圍

ai-tagging 是 AssetDB 的**離線語意層**。素材庫裡 27 個商業素材包的檔名、包名、作者全是
英文,CJK 全文索引機制本身沒問題,缺的是**中文語意標籤**——語料裡沒有中文字,任何中文
查詢都是零筆。這個子系統的存在理由就是把那批中文文本產生出來,寫進索引。

對應套件:`ai`(`assetdb-ai`)。相依 catalog(`assetdb-core` + `assetdb-store`),**不相依
任何其他子系統**。

### 做什麼

- 對本機 llama.cpp 的 OpenAI 相容端點發出推論請求,並把失敗分成「這一筆的問題」與
  「服務的問題」兩層(ADR-007)。
- 用 JSON Schema 約束模型輸出。llama.cpp 會把 `response_format.json_schema` 編譯成 GBNF,
  所以詞彙表外的分類值模型**物理上吐不出來**。
- **叢集層批次分類**(純文字,不看圖):同一素材包內檔名結構相同的一群檔案共用一個分類。
- **逐份內容視覺標註**(含縮圖):工作單位是 blob(sha256),不是 asset。
- 把上述輸出一律寫進 `ai_suggestions` 暫存表(狀態 `pending`),並提供讀取、人工確認/退回、
  以及**套用扇出**到 `tags` / `asset_tags` / `asset_categories`。
- 自然語句 → 搜尋條件的規劃(額外入口,非主要搜尋路徑)。

### 明確不做

- **不在查詢路徑呼叫 LLM。** 中文搜尋的主力是離線寫進索引的中文標籤;查詢時是純 SQLite,
  零延遲、零 LLM,推論服務關掉也照常運作。`planQuery` 是額外入口,單次約 3 秒,因此**不能**
  綁在打字事件上,只能是一個明確的動作。
- **不相依 ingest。** 叢集是 `AssetDB.Ingest.Cluster` 即時算出來的,不是資料表裡的列。若在
  這裡自己算,`assetdb-ai` 就得相依 `assetdb-ingest`,而 JuicyPixels、zip、`assetdb-archive`
  會一路被拖進伺服器(ADR-007)。因此:**叢集清單是輸入**,**叢集反查是注入的函式**
  (`aoResolveCluster`)。
- **不自己算叢集鍵、不自己產縮圖。** 縮圖由 ingest 產生,本子系統只按 catalog 的定址規則
  (`AssetDB.PathText.thumbPath`)去讀檔;讀不到是 `skipped`,不是 `failed`。
- **不直接寫 `tags` / `asset_tags` / `asset_categories`,除非該建議已是 `confirmed`。**
  推論輸出與索引之間永遠隔著一道人工閘門。
- **不重建全文索引。** 套用之後必須由呼叫端跑 `reindexFts`——這是刻意的邊界:本子系統不
  擁有索引。
- **不覆蓋人工決策。** 標籤一律 `source='inferred'` + `INSERT OR IGNORE`;已被決定過的建議
  列不會被下一次批次洗回 `pending`。
- **不拋例外。** 推論服務沒開時所有進入點回傳 `Left` / 中止報告,不弄壞資料庫。
- 不做模型下載、模型管理、GPU 排程、雲端 LLM API。

## 對外契約(Public Interface & DTOs)

以下是 delivery(目前實際消費端是 `cli` 的 `assetdb ai …`;`server` 套件並未相依
`assetdb-ai`)可以倚賴的介面。全部以 `Database.SQLite.Simple.Connection` 作為資料庫接縫,
不自己開關連線。

### 1. 推論連線(`AssetDB.AI.Llm`)

```haskell
data LlmConfig = LlmConfig
  { lcBaseUrl :: Text, lcModel :: Text, lcApiKey :: Maybe Text
  , lcMaxTokens :: Int, lcTemperature :: Double, lcTimeoutSecs :: Int
  , lcRetries :: Int, lcRetryBaseMs :: Int, lcThinking :: Bool }

defaultLlmConfig :: LlmConfig
newLlm  :: LlmConfig -> IO Llm
withLlm :: LlmConfig -> (Llm -> IO a) -> IO a
fakeLlm :: LlmConfig -> (Endpoint -> Value -> IO (Either LlmError Value)) -> Llm
ping    :: Llm -> IO (Either LlmError Text)
```

`Llm` 是控制代碼,內含唯一的 I/O 接縫 `llmSend :: Endpoint -> Value -> IO (Either LlmError Value)`。
`fakeLlm` 是**正式的測試契約**:替換這一個函式就能讓十小時批次的每條路徑在毫秒內跑完,
不需要 GPU 也不需要推論服務。

### 2. 錯誤分類(`AssetDB.AI.Llm`)

```haskell
data LlmError
  = LlmUnavailable Text | LlmTimeout Int | LlmHttpStatus Int Text
  | LlmBadEnvelope Text | LlmTruncated Int | LlmEmptyContent Text
  | LlmBadJson Text Text

isTransient     :: LlmError -> Bool
renderLlmError  :: LlmError -> Text
```

`isTransient` 是子系統邊界上最重要的一個布林值:它決定驅動器「跳過這一筆」還是「整批
中止」,也就是一個十小時批次在服務中途死掉之後,佇列還在不在。`renderLlmError` 保證輸出
單行,可直接存進 `blobs.ai_error`。

### 3. 叢集層分類(`AssetDB.AI.Classify`)

```haskell
data ClusterTarget = ClusterTarget
  { ctPackSlug :: Text, ctPackName :: Text, ctShape :: Text
  , ctCount :: Int, ctSamples :: [Text] }

data ClassifyOptions = ClassifyOptions
  { coForce :: Bool, coMinMembers :: Int, coLimit :: Maybe Int
  , coOnProgress :: Progress -> IO () }

defaultClassifyOptions :: ClassifyOptions

data ClassifyReport = ClassifyReport
  { crDone :: Int, crSkipped :: Int, crSuggested :: Int
  , crFailed :: [(Text, Text)], crAborted :: Maybe Text }

classifyClusters :: Connection -> Llm -> ClassifyOptions -> [ClusterTarget] -> IO ClassifyReport
```

**`[ClusterTarget]` 是輸入而不是自己查,這是子系統邊界的一部分。** 呼叫端(cli,它本來就
相依 ingest)負責分群並把清單遞進來。

### 4. 視覺標註(`AssetDB.AI.Vision`)

```haskell
data VisionOptions = VisionOptions
  { voCacheRoot :: FilePath, voPackSlug :: Maybe Text, voLarge :: Bool
  , voForce :: Bool, voRetryFailed :: Bool, voLimit :: Maybe Int
  , voOnProgress :: Progress -> IO () }

defaultVisionOptions :: FilePath -> VisionOptions

data VisionJob = VisionJob
  { vjSha :: Text, vjOriginal :: Text, vjPath :: Text, vjPackName :: Text }

data VisionReport = VisionReport
  { vrTagged :: Int, vrSkipped :: Int, vrSuggested :: Int
  , vrFailed :: [(Text, Text)], vrAborted :: Maybe Text }

selectJobs     :: Connection -> VisionOptions -> IO [VisionJob]
visionTagBlobs :: Connection -> Llm -> VisionOptions -> IO VisionReport
```

`selectJobs` 對外公開的理由是**呼叫端要能先報「共 N 份待標註」再開跑**,而那必須與批次
實際會做的那一批完全一致——所以是同一個函式,不是一個平行的計數查詢。

### 5. 建議暫存與套用(`AssetDB.AI.Suggest`)

```haskell
data Suggestion = Suggestion
  { sgTargetType :: Text   -- blob | cluster | asset | pack
  , sgTargetKey  :: Text
  , sgField      :: Text   -- category | tag | subject
  , sgValue      :: Text
  , sgFacet      :: Maybe Text  -- field='tag' 時必填,其餘必須 Nothing
  , sgLang       :: Text        -- en | zh
  , sgConfidence :: Maybe Double
  , sgRationale  :: Maybe Text }

tagSuggestion      :: Text -> Text -> Text -> Text -> Text -> Maybe Double -> Suggestion
categorySuggestion :: Text -> Text -> Text -> Maybe Double -> Maybe Text -> Suggestion
subjectSuggestion  :: Text -> Text -> Text -> Text -> Suggestion

data StoredSuggestion = StoredSuggestion
  { ssId :: Int, ssTargetType :: Text, ssTargetKey :: Text, ssField :: Text
  , ssValue :: Text, ssFacet :: Maybe Text, ssLang :: Text
  , ssConfidence :: Maybe Double, ssRationale :: Maybe Text, ssStatus :: Text }

data SuggestFilter = SuggestFilter
  { sfStatus :: Maybe Text, sfTargetType :: Maybe Text, sfField :: Maybe Text
  , sfMinConfidence :: Maybe Double, sfLimit :: Int, sfOffset :: Int }

emptyFilter        :: SuggestFilter
upsertSuggestions  :: Connection -> Maybe Int -> [Suggestion] -> IO Int
hasSuggestionsFor  :: Connection -> Text -> Text -> IO Bool
listSuggestions    :: Connection -> SuggestFilter -> IO [StoredSuggestion]
countSuggestions   :: Connection -> IO [(Text, Int)]
decideSuggestions  :: Connection -> [Int] -> Text -> Text -> IO Int
```

`upsertSuggestions` 回傳的是**實際寫入(新增或更新)的筆數**,不是輸入清單長度。已被人工
決定過的列(`confirmed` / `rejected` / `applied`)會被擋下、不計入。使用者拿這個數字判斷
要不要重跑,所以它必須誠實。

`decideSuggestions` 回傳實際更動的列數;只有 `pending` 的列會被更動。

### 6. 套用與 `aoResolveCluster` 注入點(`AssetDB.AI.Suggest`)

```haskell
data ApplyOptions = ApplyOptions
  { aoDryRun         :: Bool
  , aoResolveCluster :: Text -> IO [Int] }

defaultApplyOptions :: ApplyOptions   -- aoDryRun = True, 解析器回傳 []

data ApplyReport = ApplyReport
  { arTags :: Int, arCategories :: Int, arAssetsTouched :: Int, arUnresolved :: Int }

applySuggestions :: Connection -> ApplyOptions -> IO ApplyReport
```

**`aoResolveCluster` 是本子系統邊界最關鍵的一項設計,是正式契約而不是實作細節。**

- **型別**:`Text -> IO [Int]`。輸入是 `target_key`,輸出是這一群的 `assets.id`。
- **輸入編碼**:`"<pack_slug>|<shape>"`。這個編碼是 catalog 的 `ai_suggestions.target_key`
  資料契約的一部分,`cluster` 分類寫入端與此解析端**必須用同一套**。
- **為什麼注入**:叢集鍵是 ingest 即時算出來的。分群與反查若不是同一段程式碼,規則就會
  套到錯的檔案上。把它做成注入點,`assetdb-ai` 就不必相依 `assetdb-ingest`,伺服器也不會被
  拖進 JuicyPixels 與 zip(ADR-007)。
- **預設值的語意**:`defaultApplyOptions` 的解析器回傳空清單,那些建議會被計入
  `arUnresolved` 而**不是靜靜消失**。「沒注入解析器」因此是一個看得見的數字,不是一個
  無聲的漏洞。
- **呼叫端責任**:注入者必須用與分群相同的形狀比對邏輯;`applySuggestions` 對同一個
  `(target_type, target_key)` 在單次套用內只會呼叫解析器一次(結果快取),因此注入的函式
  不需要自己做記憶化。
- **套用後責任**:`aoDryRun = False` 之後呼叫端**必須**跑 `reindexFts`。少了這一步,上面
  全部照樣回報成功,而中文搜尋照樣零筆。

`aoDryRun = True` 時計數照算但不寫入,也不把建議推進 `applied`。

### 7. 自然語句查詢(`AssetDB.AI.Query`)

```haskell
data QueryPlan = QueryPlan
  { qpKeywords :: [Text], qpCategory :: Maybe Text, qpExplain :: Text }

planQuery :: Connection -> Llm -> Text -> IO (Either LlmError QueryPlan)
```

回傳 `Left` 時呼叫端應該**降級成字面搜尋**而不是顯示錯誤:既有全文搜尋本來就處理得了
中文。空白輸入回傳空計畫(`Right`),不打推論服務。

### 8. 進度回報(`AssetDB.AI.Run`)

```haskell
data Progress = Progress
  { pgIndex :: Int, pgTotal :: Int, pgLabel :: Text, pgEtaSecs :: Maybe Int }

renderProgress :: Progress -> Text
```

`coOnProgress` / `voOnProgress` 的回呼型別。取樣頻率(每 5 筆、每 20 筆)由呼叫端決定,
本子系統每一筆都呼叫。

### 對資料庫的契約(catalog 擁有 schema,本子系統只讀寫)

| 表 / 欄位 | 本子系統的角色 |
|---|---|
| `ai_runs` | 寫入。批次的錨點,`done` / `failed` 每 25 筆寫回,讓別的行程看得到進度 |
| `ai_suggestions` | 讀寫。唯一鍵 `(target_type, target_key, field, value, lang)` |
| `blobs.ai_status` / `ai_error` / `ai_seen_at` | 寫入。逐份內容的續跑狀態 |
| `categories.definition` / `ai_scope` / `sort` | 唯讀。詞彙表來源 |
| `tags` / `asset_tags` / `asset_categories` | 僅在套用已確認建議時寫入,一律 `source='inferred'` |
| `assets` / `packs` / `blobs` | 唯讀。工作選取與套用扇出 |
| `assets_fts` / `assets_cjk` | **完全不碰**。重建索引是呼叫端的責任 |

## 內部模組劃分(Internal Modules)

| 模組 | 職責 | 是否有 IO |
|---|---|---|
| `AssetDB.AI.Llm` | 與 OpenAI 相容端點之間的傳輸層、失敗分類、重試。刻意不知道素材是什麼 | 有(唯一的網路 I/O) |
| `AssetDB.AI.Schema` | JSON Schema 建構積木(→ GBNF) | 純 |
| `AssetDB.AI.Vocab` | 從 `categories` 載入受控分類詞彙表,並提供父子關係判斷 | 有(讀 DB) |
| `AssetDB.AI.Prompt` | 提示詞與其對應 schema、以及回應 DTO。兩者由同一個 `Vocab` 產生 | 純 |
| `AssetDB.AI.Image` | 縮圖檔 → `data:` URL。re-export catalog 的 `ThumbSize` / `thumbPath` | 有(讀檔) |
| `AssetDB.AI.Run` | 批次驅動器:記帳、續跑、中斷語意、進度與 ETA | 有(寫 DB) |
| `AssetDB.AI.Suggest` | `ai_suggestions` 讀寫、人工決定、套用扇出。**無 HTTP 相依** | 有(寫 DB) |
| `AssetDB.AI.Classify` | 叢集層分類的組裝 | 有 |
| `AssetDB.AI.Vision` | 逐份內容視覺標註的組裝 | 有 |
| `AssetDB.AI.Query` | 自然語句 → 搜尋條件 | 有 |

分層(下層不認識上層):

```text
第 4 層  Classify   Vision   Query        ← 對外進入點(組裝)
第 3 層  Run        Suggest               ← 批次機制 / 暫存與套用
第 2 層  Prompt     Image                 ← 提示詞契約 / 影像編碼
第 1 層  Llm        Schema     Vocab      ← 傳輸層 / 文法 / 詞彙
```

兩個刻意的隔離:

- **`Suggest` 不認識 `Llm`。** 確認與套用必須在推論服務關掉的情況下照常運作——昨天跑出來
  的建議,今天不該因為模型沒開就看不了。
- **`Prompt` 是純函式。** 提示詞的迴歸可以直接用字串斷言測,不需要模型。

## 資料流管線(Data Flow Pipeline)

### 管線 A:叢集層分類(`classifyClusters`)

```text
[呼叫端算好的 ClusterTarget 清單]
  → 載入 Vocab(categories,ai_scope ∈ visionScopes)
  → 過濾(coMinMembers)→ 依成員數遞減排序 → 續跑過濾(hasSuggestionsFor,除非 coForce)
  → 取上限(coLimit)
  → beginRun(kind="cluster", model, promptVersion, params, total)
  → 逐筆驅動(driveItems):
       組 ClusterInfo → clusterSystem + clusterUser + clusterSchema
       → chatJson(單次 LLM 呼叫,transaction 之外)
       → 成功:值域收斂(信心值夾 0–1、子分類以 isChildOf 驗父子、標籤去空白取上限)
                → upsertSuggestions(target_type="cluster", key="<slug>|<shape>")
                → StepOk n
       → LlmTruncated / LlmEmptyContent:加大 token 預算重送一次(改變請求才有意義)
       → 其他錯誤:outcomeOf → StepFailed(這一筆)或 StepAbort(整批)
  → finishRun 或 abortRun
  → ClassifyReport
```

成本量級:6,393 筆資源塌縮成 132 個叢集,所以這一輪是 132 次呼叫(約 7–8 分鐘)而不是
6,238 次(約十小時)。**成員多的先做**——五分鐘後喊停時,已涵蓋的是佔最多素材的那些叢集。

### 管線 B:視覺標註(`visionTagBlobs`)

```text
[DB]
  → 載入 Vocab
  → selectJobs:blobs.kind='image' ∧ thumb_status='ok' ∧ assets.status='active'
                ∧ packs.kind='packs' ∧(voForce ∨ ai_status='pending'
                ∨ (voRetryFailed ∧ ai_status='failed'))
                GROUP BY sha256 ORDER BY sha256   ← 順序穩定,續跑可二分定位
  → beginRun(kind="vision")
  → 逐筆驅動(driveItems),工作單位是 blob(sha256):
       loadThumbDataUrl(voCacheRoot, sha, Thumb512|Thumb128)
       → Nothing:blobs.ai_status='skipped' + 理由 → StepSkipped(先跑 assetdb thumbs)
       → Just data-url:visionSystem + userTextImage(visionUser, url) + visionSchema
            → chatJson(transaction 之外)
            → 成功:值域收斂 → upsertSuggestions(category / subject / tag,en+zh)
                      → blobs.ai_status='ok' → StepOk n
            → LlmTruncated / LlmEmptyContent:加大 token 預算重送一次
            → StepFailed:blobs.ai_status='failed' + renderLlmError
            → StepAbort:**不動狀態欄**,這一筆保持 pending,佇列才留得住
  → finishRun 或 abortRun → VisionReport
```

不變量:**絕不跨 LLM 呼叫持有 transaction。** 單次呼叫約 5.8 秒,而 `busy_timeout` 是
5 秒;握著寫鎖跨過一次推論,同時在跑的伺服器就會寫入失敗。

### 管線 C:確認與套用(`listSuggestions` → `decideSuggestions` → `applySuggestions`)

這一段**完全不碰 LLM**。

```text
ai_suggestions(pending)
  → listSuggestions / countSuggestions(人工檢視;實務上抽樣後整批確認)
  → decideSuggestions ids 'confirmed' by      ← 唯一的人工閘門
  → applySuggestions:
       讀出 status='confirmed' 的列(ORDER BY field, target_key)
       → 對每一列解析目標 →【扇出】
            blob    → SELECT id FROM assets WHERE sha256 = ? AND status='active'
                      (內容定址:同一份內容可能被多筆 asset 指向,全部都要拿到標籤)
            asset   → assets.ulid
            pack    → packs.slug
            cluster → aoResolveCluster "<pack_slug>|<shape>"   ← 注入點
         同一個 (target_type, target_key) 在單次套用內只解析一次(結果快取)
       → 解析不到任何素材:arUnresolved += 1(不是錯誤,但要講出來)
       → 解析得到 ids:
            field='tag'      → tags(name, facet) 補列 → asset_tags(source='inferred')
            field='category' → asset_categories(source='inferred')
            field='subject'  → 不進 asset_tags(那是一句描述,不是搜尋詞),留在暫存表
            → 該建議 status='applied'
       → ApplyReport
  →【呼叫端責任】reindexFts   ← 漏掉這一步,以上全部照樣「成功」,中文搜尋照樣零筆
```

寫入一律 `INSERT OR IGNORE` + `source='inferred'`(來源強弱 `manual > rule > inferred`),
所以重跑永遠不會覆蓋人工修正過的標籤。

### 管線 D:自然語句查詢(`planQuery`)

```text
使用者輸入
  → 空白?→ Right(空計畫),不打推論服務
  → 載入 Vocab → querySystem + queryUser + querySchema → chatJson
  → Right:關鍵字去空白取上限、category='unknown' → Nothing → QueryPlan
  → Left :呼叫端降級為字面搜尋(不是錯誤畫面)
```

## 模組間公開介面(Module Interfaces)

以下是子系統**內部**跨模組倚賴的介面,是內部重構的邊界。

### `AssetDB.AI.Schema` → `Prompt`

```haskell
responseFormat :: Text -> Value -> Value          -- 包成 llama.cpp 的 json_schema
objectOf       :: [(Text, Value)] -> Value        -- 全欄位必填、additionalProperties = False
stringOf       :: Text -> Value
enumOf         :: Text -> [Text] -> Value         -- 封閉列舉,GBNF 的字面選項
arrayOf        :: Text -> Int -> Value -> Value   -- 帶 maxItems
numberOf       :: Text -> Value                   -- 0–1;GBNF 不可靠,呼叫端須自行夾範圍
```

契約:`objectOf` 刻意不提供選填欄位——選填讓模型可以靜靜略過最難的那一欄,而略過的正好
都是我們最想要的。答不出來時用列舉裡的 `unknown` 表達。

### `AssetDB.AI.Vocab` → `Prompt` / `Classify` / `Vision` / `Query`

```haskell
data Category = Category
  { catPath :: Text        -- 物化路徑,如 icon 或 icon/potion。這是合約,rowid 不是
  , catName :: Text, catSlug :: Text
  , catDefinition :: Text  -- 給「模型」看的定義,不是給人看的註解
  , catScope :: Text, catSort :: Int }

data Vocab = Vocab { vocabTop :: [Category], vocabLeaves :: [Category] }

loadVocab    :: Connection -> [Text] -> IO Vocab
visionScopes :: [Text]                          -- ["any","image"]
topSlugs     :: Vocab -> [Text]
leafPaths    :: Vocab -> [Text]
childrenOf   :: Vocab -> Text -> [Category]
isChildOf    :: Vocab -> Text -> Text -> Bool
lookupPath   :: Vocab -> Text -> Maybe Category
```

契約:**餵給模型的列舉與寫進 prompt 的定義必須出自同一個 `Vocab`。** 這不是慣例而是
不變量——實測過不一致的下場:只給列舉、沒給定義時,一張 512px 的牛排圖示被分類成
`audio`。`visionScopes` 把 `audio` / `level` / `reference` 排除在視覺標註的列舉之外:錯誤
答案在 GBNF 文法層無法被表達,遠比在 prompt 裡拜託模型不要選有效。

`isChildOf` 是驅動器**優雅降級**的依據:模型答對 `category` 卻給了不屬於它的
`subcategory` 時,保留粗的、丟掉細的,而不是整筆作廢。

### `AssetDB.AI.Prompt` → `Classify` / `Vision` / `Query`

```haskell
promptVersion :: Text                     -- 存進 ai_runs.prompt_ver,改提示詞就手動加一

data ClusterInfo = ClusterInfo
  { ciPackName :: Text, ciPackSlug :: Text, ciShape :: Text
  , ciCount :: Int, ciSamples :: [Text] }
clusterSystem :: Vocab -> Text
clusterUser   :: ClusterInfo -> Text
clusterSchema :: Vocab -> Value
data ClusterVerdict = ClusterVerdict
  { cvAnalysis :: Text, cvCategory :: Text, cvSubcategory :: Text
  , cvStyleEn :: [Text], cvStyleZh :: [Text]
  , cvThemeEn :: [Text], cvThemeZh :: [Text], cvConfidence :: Double }

data VisionInfo = VisionInfo
  { viOriginalName :: Text, viPath :: Text, viPackName :: Text }
visionSystem :: Vocab -> Text
visionUser   :: VisionInfo -> Text
visionSchema :: Vocab -> Value
data VisionVerdict = VisionVerdict
  { vvAnalysis :: Text, vvCategory :: Text, vvSubcategory :: Text
  , vvConfidence :: Double, vvSubjectEn :: Text, vvSubjectZh :: Text
  , vvTagsEn :: [Text], vvTagsZh :: [Text] }

querySystem :: Vocab -> Text
queryUser   :: Text -> Text
querySchema :: Vocab -> Value
data QueryVerdict = QueryVerdict
  { qvAnalysis :: Text, qvCategory :: Text, qvKeywords :: [Text] }
```

契約:三組 verdict 的 `FromJSON` 對**每一個欄位**都有預設值(缺欄位不是解析失敗,分類欄
缺席時退回 `unknown`)。`analysis` 欄位一律排在答案欄位之前——讓模型先寫判斷理由再承諾
一個值,而由於推理內容走的是另一條不受約束的通道,這是唯一可靠的帶內思考。名稱選
`analysis` 是因為它在**字母序**與**宣告序**下都早於 `category`,兩種假設下都成立。

### `AssetDB.AI.Llm` → `Classify` / `Vision` / `Query`

```haskell
data Role = System | User | Assistant
data Part = TextPart Text | ImagePart Text        -- ImagePart 是完整的 data: URL
data Message = Message { msgRole :: Role, msgParts :: [Part] }
systemMsg     :: Text -> Message
userText      :: Text -> Message
userTextImage :: Text -> Text -> Message
encodeMessage :: Message -> Value

data ChatRequest = ChatRequest
  { crMessages :: [Message], crResponseFormat :: Maybe Value
  , crMaxTokens :: Maybe Int, crTemperature :: Maybe Double }
defaultChatRequest :: [Message] -> ChatRequest
encodeRequest      :: LlmConfig -> ChatRequest -> Value

data Usage     = Usage { uPrompt :: Int, uCompletion :: Int, uTotal :: Int }
data ChatReply = ChatReply
  { clContent :: Text     -- 推理未結束時是空字串,這是常態不是異常
  , clReasoning :: Text   -- 只用於診斷,絕不當成回答
  , clFinish :: Text, clUsage :: Usage }
parseReply   :: Value -> Either LlmError ChatReply
replyPayload :: ChatReply -> Either LlmError Text
chat         :: Llm -> ChatRequest -> IO (Either LlmError ChatReply)
chatJson     :: FromJSON a => Llm -> ChatRequest -> IO (Either LlmError a)
data Endpoint = ChatCompletions | Models
```

契約(最重要的一條):**`clReasoning` 絕不可以當成回答。** 若在 `clContent` 為空時回頭讀
reasoning,等於把不受 grammar 約束的散文餵進 JSON parser,再把產生的垃圾標籤寫進
`asset_tags`——而且看起來會像是成功了。因此「content 是空的」是一個**有型別的錯誤**
(`LlmEmptyContent` / `LlmTruncated`),不是一個待補的空值。`replyPayload` 是這條不變量的
唯一守門人。

傳輸層**只重試 `isTransient` 的錯誤**。`LlmTruncated` / `LlmEmptyContent` / `LlmBadJson`
在傳輸層重試等於再送一次一模一樣的請求;它們必須由上層**改變請求**(加大 token 預算)
之後重送才有意義。

### `AssetDB.AI.Image` → `Vision`

```haskell
-- ThumbSize 與 thumbPath 由 AssetDB.PathText(catalog)re-export
data ThumbSize = Thumb128 | Thumb512
thumbPath        :: FilePath -> Text -> ThumbSize -> FilePath
dataUrl          :: ByteString -> Text
loadThumbDataUrl :: FilePath -> Text -> ThumbSize -> IO (Maybe Text)
```

契約:縮圖定址規則的**唯一實作在 catalog**,與 ingest(產生端)、server(讀取端)共用
同一套,本模組只 re-export 以維持既有 API(enhance-0012)。全程 strict `ByteString` /
`Text`,不經過 `String`——512px PNG base64 後 55–160 KB,乘以 6,238 次呼叫,中途經過
`String` 就是每張約兩百萬個 cons cell。`Nothing` 表示「這份內容還沒產生縮圖」,呼叫端
必須記成 skipped 而不是 failed。

### `AssetDB.AI.Run` → `Classify` / `Vision`

```haskell
newtype RunId = RunId Int
beginRun  :: Connection -> Text -> LlmConfig -> Text -> Text -> Int -> IO RunId
bumpRun   :: Connection -> RunId -> Int -> Int -> IO ()
finishRun :: Connection -> RunId -> Int -> Int -> IO ()
abortRun  :: Connection -> RunId -> Text -> Int -> Int -> IO ()

guardedTry :: IO a -> IO (Either SomeException a)

data StepOutcome
  = StepOk Int          -- 成功,產生了幾筆建議
  | StepSkipped Text    -- 這一筆做不了(如沒有縮圖),但不是錯誤
  | StepFailed Text     -- 「這一筆」的問題;寫進狀態欄,重跑時跳過
  | StepAbort Text      -- 「不是這一筆」的問題;整批停下,佇列保持 pending
outcomeOf :: LlmError -> StepOutcome

driveItems
  :: Connection -> RunId
  -> (Progress -> IO ())
  -> (a -> Text)                -- 這一項的顯示名稱
  -> (a -> IO StepOutcome)
  -> [a]
  -> IO (Int, Int, [(Text, Text)], Maybe Text)   -- (成功, 略過, 失敗清單, 中止原因)
```

契約:

- **`guardedTry` 不吞掉 Ctrl-C。** 每筆 5.8 秒,中斷訊號落在 LLM 呼叫裡的機率接近 100%;
  被 `SomeException` 接住之後迴圈會繼續跑下一筆,使用者按 6,238 次 Ctrl-C 也停不下來。
- **`outcomeOf` 是 `isTransient` 的唯一消費者。** 服務在第 300 筆死掉若被當成 `StepFailed`,
  剩下 5,938 筆會被逐一標成 failed,工作佇列就毀了,而且「模型讀不懂這張圖」與「那時候
  服務沒開」再也分不出來。
- **`StepAbort` 短路。** 剩下的項目保持 pending,下次重跑就是續跑。
- 進度每 25 筆寫回 `ai_runs`——那是別的行程唯一能看到一個**不是它啟動**的批次跑到哪裡的
  方式。

### `AssetDB.AI.Suggest` → `Classify` / `Vision`

寫入側只用 `upsertSuggestions`、`hasSuggestionsFor` 與三個 smart constructor(見「對外契約」
第 5 節)。`hasSuggestionsFor` 是**叢集層續跑的唯一依據**:叢集是即時算出來的,沒有可以
標記狀態的資料列(`name_clusters` 只存已確認的命名規則),所以續跑改看「這個
`(pack_slug, shape)` 已經有建議了嗎」。少一組欄位,也少一個會腐爛的鏡像。

## 架構圖

```text
┌───────────────────────────── delivery(cli) ─────────────────────────────┐
│  assetdb ai ping / classify / vision / suggest / apply / query / status  │
│                                                                          │
│   ClusterTarget 清單 ─┐                    ┌─ aoResolveCluster           │
│   (由 ingest 分群)    │                    │  "<slug>|<shape>" → [id]    │
└───────────────────────┼────────────────────┼─────────────────────────────┘
                        │  注入              │  注入
╔═══════════════════════▼════════════════════▼═════════ ai-tagging ════════╗
║                                                                          ║
║  第 4 層  ┌──────────┐   ┌────────┐   ┌───────┐                          ║
║           │ Classify │   │ Vision │   │ Query │                          ║
║           └────┬─────┘   └───┬────┘   └───┬───┘                          ║
║                │             │            │                              ║
║  第 3 層  ┌────▼─────────────▼──┐   ┌─────▼──────────────────┐           ║
║           │        Run          │   │       Suggest          │           ║
║           │ driveItems / RunId  │   │ upsert / decide / apply│           ║
║           │ StepOutcome 語意    │   │  ✗ 不認識 Llm          │           ║
║           └────┬────────────────┘   └─────┬──────────────────┘           ║
║                │                          │                              ║
║  第 2 層  ┌────▼──────┐  ┌───────┐        │                              ║
║           │  Prompt   │  │ Image │        │                              ║
║           │ (純函式)  │  │ data: │        │                              ║
║           └──┬─────┬──┘  └───┬───┘        │                              ║
║              │     │         │            │                              ║
║  第 1 層  ┌──▼──┐┌─▼─────┐┌──▼──────────┐ │                              ║
║           │ Llm ││Schema ││   Vocab     │ │                              ║
║           │     ││ →GBNF ││ categories  │ │                              ║
║           └──┬──┘└───────┘└──────┬──────┘ │                              ║
╚══════════════┼══════════════════ ┼════════┼══════════════════════════════╝
               │                   │        │
        ┌──────▼──────┐     ┌──────▼────────▼──────────────────────────┐
        │ llama.cpp   │     │           catalog(store)                 │
        │ OpenAI 相容 │     │ categories · ai_runs · ai_suggestions     │
        │ /v1/chat…   │     │ blobs.ai_status · tags/asset_tags         │
        │ /v1/models  │     │ asset_categories · assets · packs         │
        └─────────────┘     └───────────────┬──────────────────────────┘
                                            │ reindexFts(呼叫端責任)
                                     ┌──────▼──────┐
                                     │ assets_fts  │
                                     │ assets_cjk  │
                                     └─────────────┘
```

主資料流(以中文標籤讓中文搜尋活起來為例):

```text
縮圖(ingest 產生)
  │
  ├─► Vision ──► Llm ──► llama.cpp ──► VisionVerdict(受 GBNF 約束)
  │                                          │
  └─────────────────────────────────────►  Suggest.upsert
                                             │  ai_suggestions: pending
                                             ▼
                                      人工確認(唯一閘門)
                                             │  confirmed
                                             ▼
                              Suggest.apply ──【扇出】──► asset_tags(inferred)
                                             │
                                             ▼
                                   reindexFts(呼叫端)
                                             │
                                             ▼
                                   assets_cjk ── 中文搜尋命中
```

## 開發階段

本子系統整體對應主架構的「**階段 12:AI 離線分類與標註**」。內部依先後拆成兩個里程碑:

### 內部階段一:推論基礎設施

把「跟一顆本機模型講話」這件事變成可測、可分類失敗、可約束輸出的地基。這一階段完成時
還沒有任何素材被標註,但整條呼叫路徑已經可以在**沒有 GPU、沒有推論服務**的情況下跑完
每一條分支。涵蓋 F001、F002。

驗收:`fakeLlm` 能替換掉唯一的 I/O 接縫;`isTransient` 的兩層失敗語意成立;prompt 與
schema 的列舉出自同一個 `Vocab`,漂移不可能發生。

### 內部階段二:批次與套用

把地基變成真的會改到索引的批次。涵蓋 F003–F006。

驗收:132 個叢集的分類批次可續跑;6,238 份唯一內容的標註批次中斷後佇列不毀;確認後的
中文標籤經套用與 `reindexFts` 之後,中文搜尋確實命中。

## 功能規劃

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---|---|---|---|---|
| 1 | llm-client | 本機 llama.cpp OpenAI 相容端點客戶端與分層失敗語意 | `AssetDB.AI.Llm` | - | F001 |
| 2 | gbnf-constrained-output | JSON Schema 編譯成 GBNF 文法、詞彙表與 prompt 組裝 | `AssetDB.AI.Schema`、`AssetDB.AI.Vocab`、`AssetDB.AI.Prompt` | #1 | F002 |
| 3 | cluster-classification | 叢集層批次分類,產生分類與標籤建議 | `AssetDB.AI.Classify`、`AssetDB.AI.Run` | #1, #2, #5 | F003 |
| 4 | vision-tagging | 逐份內容的視覺標註批次 | `AssetDB.AI.Vision`、`AssetDB.AI.Image`、`AssetDB.AI.Run` | #1, #2, #5 | F004 |
| 5 | suggestion-store-apply | 建議暫存表的讀寫、人工確認與套用扇出 | `AssetDB.AI.Suggest` | - | F005 |
| 6 | nl-query-planning | 自然語句查詢規劃與推論服務離線時的降級 | `AssetDB.AI.Query` | #1, #2 | F006 |

## Feature 契約卡

### llm-client

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段一:推論基礎設施 |
| **負責模組** | `AssetDB.AI.Llm` |
| **實作的 Level 2 介面** | 對外契約 §1「推論連線」(`LlmConfig`、`defaultLlmConfig`、`newLlm`、`withLlm`、`fakeLlm`、`ping`)、§2「錯誤分類」(`LlmError`、`isTransient`、`renderLlmError`);模組間介面「`AssetDB.AI.Llm` → `Classify` / `Vision` / `Query`」全部條目(`Role`、`Part`、`Message`、`systemMsg`、`userText`、`userTextImage`、`encodeMessage`、`ChatRequest`、`defaultChatRequest`、`encodeRequest`、`Usage`、`ChatReply`、`parseReply`、`replyPayload`、`chat`、`chatJson`、`Endpoint`) |
| **資料流管線段落** | 四條管線共用的最底層一步:管線 A/B/D 的「`chatJson`(單次 LLM 呼叫,transaction 之外)」,以及傳輸層的「只重試 `isTransient` 的錯誤」 |
| **驗收標準** | ① 有 `content` 就用 `content`;② `content` 為空且 `finish_reason == "length"` → `LlmTruncated`,附已產生 token 數;③ `content` 為空且正常結束 → `LlmEmptyContent`,附推理前綴;④ 即使 `reasoning_content` 剛好長得像 JSON,也**絕不**被當成回答;⑤ 只有空白的 `content` 也算空;⑥ 服務沒開 / 逾時 / 5xx 是 transient,`LlmTruncated` / `LlmEmptyContent` / `LlmBadJson` / 4xx 不是;⑦ 缺 `reasoning_content` 欄位不是錯誤,`choices` 空陣列是 `LlmBadEnvelope`;⑧ 單一文字段落輸出字串形式 `content`,含圖輸出兩元素 parts 陣列;⑨ `fakeLlm` 能讓 `ping` 與 `chat` 整條路徑不需要真的推論服務;⑩ `renderLlmError` 輸出不含換行 |
| **明確不做** | 不知道素材是什麼(沒有任何領域型別);不做串流;不重試模型自己的輸出問題;不在 `content` 為空時回讀 reasoning;不把非 2xx 變成例外 |

### gbnf-constrained-output

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段一:推論基礎設施 |
| **負責模組** | `AssetDB.AI.Schema`、`AssetDB.AI.Vocab`、`AssetDB.AI.Prompt` |
| **實作的 Level 2 介面** | 模組間介面「`AssetDB.AI.Schema` → `Prompt`」(`responseFormat`、`objectOf`、`stringOf`、`enumOf`、`arrayOf`、`numberOf`)、「`AssetDB.AI.Vocab` → `Prompt` / `Classify` / `Vision` / `Query`」(`Category`、`Vocab`、`loadVocab`、`visionScopes`、`topSlugs`、`leafPaths`、`childrenOf`、`isChildOf`、`lookupPath`)、「`AssetDB.AI.Prompt` → `Classify` / `Vision` / `Query`」(`promptVersion`、三組 `*System` / `*User` / `*Schema` 與 `ClusterInfo` / `VisionInfo` / 三組 `*Verdict`) |
| **資料流管線段落** | 管線 A/B/D 的「載入 Vocab」與「組 prompt + schema」兩步,以及回應解碼(三組 verdict 的 `FromJSON`) |
| **驗收標準** | ① prompt 裡出現的每個頂層分類都同時在 schema 的 `category` 列舉裡(同源不變量);② 視覺標註的列舉**不含** `audio` / `level` / `reference`;③ 列舉一定含 `unknown`;④ `gui` 與 `icon` 兩邊的定義都寫了指向對方的反例;⑤ `isChildOf` 認得真父子關係、擋掉張冠李戴與不存在的葉節點;⑥ 查詢提示詞要求中英文關鍵字都給;⑦ `promptVersion` 不是空字串;⑧ `objectOf` 產出的每個欄位都必填且 `additionalProperties = False`;⑨ `enumOf` 把列舉值原封不動放進 schema;⑩ `arrayOf` 帶 `maxItems`;⑪ `responseFormat` 是 llama.cpp 認得的 `json_schema` 形狀;⑫ `analysis` 在字母序上早於 `category` |
| **明確不做** | 不把分類列舉寫死在 Haskell 裡(定義與列舉必須同源);不提供選填欄位;不倚賴 JSON 序列化順序;不信任 GBNF 對 `minimum` / `maximum` 的約束(夾範圍是呼叫端的事);不做 IO(`Vocab` 載入除外) |

### cluster-classification

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段二:批次與套用 |
| **負責模組** | `AssetDB.AI.Classify`、`AssetDB.AI.Run` |
| **實作的 Level 2 介面** | 對外契約 §3「叢集層分類」(`ClusterTarget`、`ClassifyOptions`、`defaultClassifyOptions`、`ClassifyReport`、`classifyClusters`)、§8「進度回報」(`Progress`、`renderProgress`);模組間介面「`AssetDB.AI.Run` → `Classify` / `Vision`」(`RunId`、`beginRun`、`bumpRun`、`finishRun`、`abortRun`、`guardedTry`、`StepOutcome`、`outcomeOf`、`driveItems`)、「`AssetDB.AI.Suggest` → `Classify` / `Vision`」(`hasSuggestionsFor`、`upsertSuggestions`、`categorySuggestion`、`tagSuggestion`) |
| **資料流管線段落** | 管線 A 全段(從「呼叫端算好的 `ClusterTarget` 清單」到 `ClassifyReport`) |
| **驗收標準** | ① `[ClusterTarget]` 是輸入,子系統不查叢集、不相依 ingest;② 成員數 `< coMinMembers` 的叢集被排除,其餘依成員數遞減排序;③ 非 `coForce` 時已有建議的 `(pack_slug, shape)` 被跳過(續跑);④ 每批寫入一列 `ai_runs`(`kind='cluster'`,帶 model 與 `promptVersion`),結束時是 `done` 或 `aborted`;⑤ 信心值被夾在 0–1(NaN → 0);⑥ 子分類不屬於所選父分類時,保留父分類、丟棄子分類並在理由裡註明,而不是整筆作廢;⑦ `category == "unknown"` 時不產生分類建議;⑧ 每個 facet/語言的標籤上限 4 個且去除空白項;⑨ `LlmTruncated` / `LlmEmptyContent` 觸發一次「加大 token 預算」重送;⑩ transient 錯誤 → 整批中止且剩餘項目保持 pending,非 transient → 只有這一筆 failed;⑪ `crSuggested` 反映實際寫入筆數 |
| **明確不做** | 不看圖(純文字);不自己算叢集鍵;不寫個別檔案畫了什麼(那是 F004 的事);不在 LLM 呼叫期間持有 transaction;不吞 Ctrl-C;不在傳輸層重試模型輸出問題 |

### vision-tagging

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段二:批次與套用 |
| **負責模組** | `AssetDB.AI.Vision`、`AssetDB.AI.Image`、`AssetDB.AI.Run` |
| **實作的 Level 2 介面** | 對外契約 §4「視覺標註」(`VisionOptions`、`defaultVisionOptions`、`VisionJob`、`VisionReport`、`selectJobs`、`visionTagBlobs`)、§8「進度回報」;模組間介面「`AssetDB.AI.Image` → `Vision`」(`ThumbSize`、`thumbPath`、`dataUrl`、`loadThumbDataUrl`)、「`AssetDB.AI.Run` → `Classify` / `Vision`」全部條目、「`AssetDB.AI.Suggest` → `Classify` / `Vision`」(`upsertSuggestions`、`categorySuggestion`、`subjectSuggestion`、`tagSuggestion`) |
| **資料流管線段落** | 管線 B 全段(從 `selectJobs` 到 `VisionReport`) |
| **驗收標準** | ① 工作單位是 blob(`GROUP BY sha256`),同一份內容只推論一次;② 工作選取只取 `kind='image'` ∧ `thumb_status='ok'` ∧ 素材 active ∧ 素材包 `kind='packs'`,並依 `voForce` / `voRetryFailed` 決定重跑範圍;③ 排序穩定(`ORDER BY sha256`),續跑順序完全一致;④ `selectJobs` 的結果與批次實際處理的那一批完全相同(呼叫端可先報總數);⑤ 找不到縮圖 → `blobs.ai_status='skipped'` + 理由 + `StepSkipped`,**不是** failed;⑥ 成功 → 建議寫入且 `ai_status='ok'`;⑦ 非 transient 失敗 → `ai_status='failed'` + 單行錯誤訊息;⑧ **transient 中止時完全不動狀態欄**,該筆保持 pending;⑨ 縮圖尺寸由 `voLarge` 決定(512 / 128);⑩ 每語言標籤上限 4 個,`subject` 中英各一(空字串不產生建議);⑪ 信心值夾 0–1,子分類父子關係不符時只保留父分類;⑫ LLM 呼叫一律在 transaction 之外 |
| **明確不做** | 不產生縮圖(那是 ingest 的事,缺縮圖只回報 skipped);不做圖片解碼或縮放(不相依 JuicyPixels);不自行定義縮圖路徑規則(用 catalog 的);`subject` 不寫進 `asset_tags`;不處理非 `packs` 類型的素材包 |

### suggestion-store-apply

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段二:批次與套用 |
| **負責模組** | `AssetDB.AI.Suggest` |
| **實作的 Level 2 介面** | 對外契約 §5「建議暫存與套用」(`Suggestion`、`tagSuggestion`、`categorySuggestion`、`subjectSuggestion`、`StoredSuggestion`、`SuggestFilter`、`emptyFilter`、`upsertSuggestions`、`hasSuggestionsFor`、`listSuggestions`、`countSuggestions`、`decideSuggestions`)、§6「套用與 `aoResolveCluster` 注入點」(`ApplyOptions`、`defaultApplyOptions`、`ApplyReport`、`applySuggestions`) |
| **資料流管線段落** | 管線 C 全段(從 `listSuggestions` 到 `ApplyReport`),以及管線 A/B 的寫入端 |
| **驗收標準** | ① 寫入後看得到,狀態是 `pending`;② 重跑是更新而不是堆疊(唯一鍵 `(target_type, target_key, field, value, lang)`);③ `upsertSuggestions` 回傳**實際寫入筆數**——已被人工決定的列被擋下時不計入;④ 不會把已決定的建議洗回 `pending`;⑤ `hasSuggestionsFor` 能回答「這個叢集做過沒有」;⑥ 只套用 `confirmed` 的列;⑦ **以 sha256 為鍵的建議扇出到所有指向該內容的素材**(內容定址的後果);⑧ dry-run 完全不寫入;⑨ 重跑不覆蓋 `source='manual'` 的標籤;⑩ 分類寫進 `asset_categories` 且筆數與扇出一致;⑪ **同一個 `(target_type, target_key)` 的多筆建議只呼叫解析器一次,結果與逐筆解析完全相同**;⑫ 未注入 `aoResolveCluster` 時 cluster 建議計入 `arUnresolved` 而不是靜靜消失,注入後正確寫入;⑬ 驗收點:套用中文標籤 + `reindexFts` 之後中文搜尋命中,套用前搜不到;⑭ 英文標籤同樣進得了索引 |
| **明確不做** | 不相依 `AssetDB.AI.Llm`(確認與套用必須在推論服務關掉時照常運作);不自己算叢集反查;不重建全文索引;不用 `REPLACE`;`subject` 不進 `asset_tags`;不在 dry-run 時推進建議狀態 |

### nl-query-planning

| 欄位 | 內容 |
|---|---|
| **階段** | 內部階段二:批次與套用 |
| **負責模組** | `AssetDB.AI.Query` |
| **實作的 Level 2 介面** | 對外契約 §7「自然語句查詢」(`QueryPlan`、`planQuery`);消費模組間介面「`AssetDB.AI.Prompt`」的 `querySystem` / `queryUser` / `querySchema` / `QueryVerdict` 與「`AssetDB.AI.Llm`」的 `chatJson` |
| **資料流管線段落** | 管線 D 全段 |
| **驗收標準** | ① 空白輸入回傳空計畫且**不打推論服務**;② 關鍵字去除空白項並取上限 8;③ `category == "unknown"` → `Nothing`,不是字串 `"unknown"`;④ `qpExplain` 帶回模型的理解說明;⑤ 推論失敗回傳 `Left`,呼叫端據此**降級為字面搜尋**而不是顯示錯誤;⑥ 全程不寫任何資料庫表 |
| **明確不做** | 不執行搜尋(只產生條件);不寫 `ai_suggestions` 或 `ai_runs`;不快取;不綁在打字事件上(單次約 3 秒);不是主要搜尋路徑——中文搜尋的主力是離線寫進索引的中文標籤 |
