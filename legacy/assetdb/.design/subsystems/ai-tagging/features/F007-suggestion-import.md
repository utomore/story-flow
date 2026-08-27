---
id: F007
type: feature
title: suggestion-import
description: 外部 JSONL 建議的三層驗證與全有全無寫入暫存表
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: [F002, F005, G-E003, catalog/F004, catalog/F005]
related-adr: [ADR-010]
related-feature: []
---

# F007: 外部建議匯入

## 功能概述

`ai_suggestions` 暫存表原本只有一個入口:本機 LLM 的 `ai classify` / `ai vision`。本功能開第二個
入口 —— 任何不經推論服務的程序(在終端機裡讀檔名與縮圖的 Claude Code、一支腳本、人手寫的檔案)
以 JSON Lines 把分類/標籤建議餵進**同一張**暫存表,之後走**同一道**人工閘門
(`suggest confirm` → `ai apply` → `reindexFts`)。

要解決的問題:素材庫 6,783 筆資源裡 989 筆分類是 `unknown`、逐份視覺標註只做了 5 筆。叢集層
(132 個叢集)的分類與標籤用對話判斷比 7B 模型準、也比過夜批次快,但現在沒有路把判斷結果塞進系統。

驗收標準(= 契約卡 `suggestion-import` 的 12 條):

1. 合法 JSONL 寫入後 `listSuggestions` 看得到,狀態 `pending`,`run_id` 為 NULL
2. `irWritten` = `upsertSuggestions` 實際寫入筆數;已被人工決定的列不計入、不被洗回
3. 形狀錯逐行列出行號與原因(未知 `target_type` / `field` / `lang`、`tag` 缺 `facet`、非 `tag` 帶 `facet`、`confidence` 出界、`value` 空白、JSON 壞掉)
4. `category` 值不在 `Vocab` → 擋下,理由含「不在詞彙表」
5. 不存在的 blob sha / asset ULID / pack slug → 擋下;`cluster` 鍵不驗、照收
6. 任一行有問題則**一筆都不寫**,`irWritten = 0`,`irProblems` 含全部問題
7. `ioDryRun` 回報筆數但不寫
8. 空檔 / 只有空白行 → `irLines = 0`、無問題、不寫
9. 非 UTF-8 位元組 → 行號 0 的問題,不拋例外
10. 寫入是單一交易,交易內只有 `execute`
11. 整條路徑不相依 `Llm`,推論服務不在場照常
12. 匯入 → `decideSuggestions` → `applySuggestions` → `reindexFts` 後中文搜尋命中

## 相依性

- **F005(suggestion-store-apply)**:寫入端用它的 `upsertSuggestions` 與 `Suggestion` 型別;驗收 12 走它的
  `decideSuggestions` / `applySuggestions`。程式碼已存在(`ai/src/AssetDB/AI/Suggest.hs`),下表有簽名原文。
- **F002(gbnf-constrained-output)**:第 2 層驗證用它的 `Vocab` / `loadVocab` / `lookupPath`。程式碼已存在
  (`ai/src/AssetDB/AI/Vocab.hs`)。

- **G-E003(錯誤邊界收斂)**:`guardedTry` / `renderUnexpected` 是寫入出口的依據。
- **catalog/F004、catalog/F005**:`withStore` / `storeConn` 開連線、`reindexFts` 是驗收 12 的最後一步。

以上全部 `done`,本功能**可以獨立開工**,不與任何進行中任務衝突。不相依 F001(`Llm`)、F003、F004、F006。

## 對應的 Level 2 契約

| 契約條目 | 本功能的角色 |
|---|---|
| 對外契約 §5b「外部建議匯入」:`ImportOptions`、`defaultImportOptions`、`ImportReport`、`importSuggestions`、JSONL 輸入格式 | **實作**(全部) |
| 對外契約 §5:`Suggestion`、`tagSuggestion`、`categorySuggestion`、`subjectSuggestion`、`upsertSuggestions` | 消費 |
| 模組間介面「`AssetDB.AI.Vocab`」:`Vocab`、`loadVocab`、`lookupPath` | 消費 |
| 資料流管線 E 全段 | 實作 |
| 內部模組 `AssetDB.AI.Import`(第 4 層,不認識 `Llm`) | 新模組 |
| delivery `design.md` §3 指令表:`ai suggest import` | 新子指令(cli 側) |

未超出範圍:不新增資料表、不改 schema(ADR-010)、不碰 `tags` / `asset_tags` / `asset_categories`、不重建索引。

## 實作方式

### 模組 `AssetDB.AI.Import`(ai 套件)

`importSuggestions :: Connection -> ImportOptions -> ByteString -> IO ImportReport`,資料流照管線 E:

1. **解碼**:`decodeUtf8'`(嚴格)。失敗 → `irProblems = [(0, "檔案不是 UTF-8:…")]`,立即回傳,
   `irLines = 0`。刻意不用 lenient:替代字元會讓 sha 或分類路徑靜默變成不存在的值,第 3 層擋下時
   訊息會指向錯的原因。
2. **切行**:以 `\n` 切、去 `\r`、濾掉 `T.strip` 後為空的行。行號是**原始行號**(含空白行),使用者對照
   編輯器時才對得上。`irLines` = 非空白行數。
3. **第 1 層 形狀**:每行 `Aeson.eitherDecodeStrict` 成中間紀錄(八個欄位,`facet` / `confidence` / `rationale`
   為 `Maybe`;未知鍵忽略)。接著:
   - `target_type` ∈ {blob, cluster, asset, pack};`field` ∈ {category, tag, subject};`lang` ∈ {en, zh}
   - `field == "tag"` ⇔ `facet` 為 `Just` 且 ∈ {style, theme, palette, free}(與 schema 的 `CHECK ((field = 'tag') = (facet IS NOT NULL))` 同義,提早擋下免得撞 constraint 錯誤)
   - `confidence` 若有則 `0 ≤ c ≤ 1` 且非 NaN
   - `value` 與 `target_key` `T.strip` 後非空
   - 每個違規一條 `(行號, 原因)`;一行可以有多條問題,全部列出
4. **第 2 層 詞彙表**:只對 `field == "category"`。`loadVocab conn ["any","image","audio","level","reference"]`
   —— 載完整詞彙而非 `visionScopes`,因為匯入的目標不限於圖片;實際 scope 值以 `categories.ai_scope` 表裡
   出現過的為準(實作時先 `SELECT DISTINCT ai_scope`,不硬編)。`lookupPath` 回 `Nothing` → 「分類 `X` 不在詞彙表」。
   Vocab 只載一次。
5. **第 3 層 目標存在**:把通過前兩層的行依 `target_type` 分組、去重 key,每組一次 `SELECT … WHERE key IN (…)`
   (blob → `blobs.sha256`、asset → `assets.ulid`、pack → `packs.slug`),缺席的 key 回推到每一行產生問題。
   `cluster` 不查。
6. **閘門**:`irProblems` 非空 → `irWritten = 0`,回傳,**不開交易**。`ioDryRun` → `irWritten = 0`,但另以
   `irLines` 讓 CLI 印「將寫入 N 筆」;回傳。
7. **寫入**:把中間紀錄轉成 `Suggestion`(直接建構,不經三個 builder —— builder 會把 `lang` / `rationale` 寫死,
   匯入的每個欄位都來自檔案),呼叫 `upsertSuggestions conn Nothing sgs`。它自己包 `withTransaction`,交易內只有
   `execute`。以 `guardedTry` 包住:資料庫錯誤 → `(0, renderUnexpected e)`,`irWritten = 0`。

`ImportReport` 的 `irProblems` 依行號排序。

### CLI `assetdb ai suggest import <檔案> [--dry-run]`(cli 套件)

- `Options.hs`:`suggestP` 加 `import` 子指令,`CmdAiSuggestImport AiImportArgs`,`AiImportArgs { iaFile :: FilePath, iaDryRun :: Bool }`。
- `Cli/Ai.hs`:`runAiSuggestImport :: FilePath -> AiImportArgs -> IO ()`。`BS.readFile` 讀位元組(檔案不存在 →
  繁中訊息 + `exitFailure`,不讓 `IOException` 逃到頂層);`withAi` 開連線;呼叫 `importSuggestions`;輸出:
  - 有問題:逐行印 `第 N 行:原因`(行號 0 印「檔案:原因」),最後印「共 M 個問題,一筆都沒寫入」,`exitFailure`
  - dry-run:「驗證通過,將寫入 N 筆(--dry-run,未寫入)」,結束碼 0
  - 成功:「已寫入 N 筆(pending)」+ `countSuggestions` 各狀態筆數(與 `suggest list` 尾段相同),結束碼 0
- `Main.hs`:加一條 `CmdAiSuggestImport a -> forQuery >>= \db -> runAiSuggestImport db a`。

不需要 `--confirm`(system.md 規則 3 的「只寫暫存表」例外)。

### 錯誤處理對照(G-E003)

| 情況 | 出口 |
|---|---|
| 檔案不存在 / 讀不到 | CLI 層繁中訊息,非 0 結束 |
| 非 UTF-8 | `irProblems` 行號 0 |
| JSON 壞、欄位不合法 | `irProblems` 該行 |
| 資料庫錯誤(busy、constraint) | `guardedTry` → `irProblems` 行號 0,`renderUnexpected` |
| Ctrl-C | `guardedTry` 重拋,頂層 `withTopLevel` 印「已中斷」 |

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Suggestion = Suggestion { sgTargetType :: Text, sgTargetKey :: Text, sgField :: Text, sgValue :: Text, sgFacet :: Maybe Text, sgLang :: Text, sgConfidence :: Maybe Double, sgRationale :: Maybe Text }` | `ai/src/AssetDB/AI/Suggest.hs` | F005 | 驗證通過的每一行轉成它 |
| `upsertSuggestions :: Connection -> Maybe Int -> [Suggestion] -> IO Int` | `ai/src/AssetDB/AI/Suggest.hs` | F005 | 寫入;`Maybe Int` 傳 `Nothing`(run_id NULL,ADR-010);回傳值即 `irWritten` |
| `listSuggestions :: Connection -> SuggestFilter -> IO [StoredSuggestion]`、`countSuggestions :: Connection -> IO [(Text, Int)]` | `ai/src/AssetDB/AI/Suggest.hs` | F005 | 測試驗收 1;CLI 成功輸出的尾段 |
| `decideSuggestions :: Connection -> [Int] -> Text -> Text -> IO Int`、`applySuggestions :: Connection -> ApplyOptions -> IO ApplyReport` | `ai/src/AssetDB/AI/Suggest.hs` | F005 | 驗收 12 的端到端測試 |
| `data Vocab = Vocab { vocabTop :: [Category], vocabLeaves :: [Category] }`、`loadVocab :: Connection -> [Text] -> IO Vocab`、`lookupPath :: Vocab -> Text -> Maybe Category` | `ai/src/AssetDB/AI/Vocab.hs` | F002 | 第 2 層驗證 |
| `guardedTry :: IO a -> IO (Either SomeException a)` | `core/src/AssetDB/Guard.hs` | G-E003 | 包住寫入,不吞 Ctrl-C |
| `renderUnexpected :: SomeException -> Text` | `store/src/AssetDB/Store/Errors.hs` | G-E003 | 資料庫錯誤翻繁中 |
| `withStore :: FilePath -> (Store -> IO a) -> IO a`、`storeConn :: Store -> Connection`(經 `Cli/Ai.hs` 的 `withAi :: FilePath -> (Connection -> IO a) -> IO a`) | `store/src/AssetDB/Store.hs`、`cli/app/AssetDB/Cli/Ai.hs` | catalog/F004 | CLI 開連線 |
| `reindexFts :: Connection -> IO Int` | `store/src/AssetDB/Store/Index.hs` | catalog/F005 | 驗收 12 測試的最後一步 |

## 新增的介面

```haskell
-- ai/src/AssetDB/AI/Import.hs(對外契約 §5b)
data ImportOptions = ImportOptions { ioDryRun :: Bool }
defaultImportOptions :: ImportOptions                       -- ioDryRun = False

data ImportReport = ImportReport
  { irLines    :: Int
  , irWritten  :: Int
  , irProblems :: [(Int, Text)] }

importSuggestions :: Connection -> ImportOptions -> ByteString -> IO ImportReport
```

```haskell
-- cli/app/AssetDB/Cli/Options.hs
data AiImportArgs = AiImportArgs { iaFile :: FilePath, iaDryRun :: Bool }
-- Command 多一個建構子 CmdAiSuggestImport AiImportArgs

-- cli/app/AssetDB/Cli/Ai.hs
runAiSuggestImport :: FilePath -> AiImportArgs -> IO ()
```

`ai.cabal` 的 `exposed-modules` 加 `AssetDB.AI.Import`;不新增任何套件依賴(`aeson`、`bytestring`、`text`
已在)。

## TodoList

- [x] T1: `AssetDB.AI.Import` 骨架:型別、`defaultImportOptions`、UTF-8 嚴格解碼、切行與原始行號、空檔處理  `dep: -`
- [x] T2: 第 1 層形狀驗證(JSON 解析 + 七條規則,一行多問題全列)  `dep: T1`
- [x] T3: 第 2 層詞彙表驗證(`loadVocab` 一次、`lookupPath`)  `dep: T2, F002`
- [x] T4: 第 3 層目標存在驗證(blob / asset / pack 批次查詢;cluster 跳過)  `dep: T2`
- [x] T5: 全有全無閘門、dry-run、`upsertSuggestions` 寫入與 `guardedTry` 出口  `dep: T3, T4, F005`
- [x] T6: CLI `ai suggest import` 子指令:`Options.hs`、`Cli/Ai.hs`、`Main.hs`,含檔案讀取失敗的繁中出口  `dep: T5`
- [x] T7: 端到端:匯入中文標籤 → confirm → apply → reindexFts → 中文搜尋命中  `dep: T5`

## 1-to-1 測試對照表

測試檔:`ai/test/AssetDB/AI/ImportSpec.hs`(沿用 `SuggestSpec` 的 `withSeeded` 形式另建種子),
CLI 解析在 `cli/test/AssetDB/Cli/ParserSpec.hs`。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `ImportSpec "空檔與只有空白行:irLines 0、無問題、不寫"`、`"非 UTF-8 位元組:行號 0 問題,不拋例外"`、`"行號是原始行號,跳過的空白行也算"` | 驗收 8、9;行號語意 |
| T2 | `ImportSpec "形狀:七種違規各自列出行號與原因"`、`"一行多個問題全部列出"` | 驗收 3;含 JSON 壞掉、未知列舉、tag/facet 互斥、confidence 出界、空 value |
| T3 | `ImportSpec "分類不在詞彙表時擋下,理由含「不在詞彙表」"`、`"詞彙表裡的葉節點與頂層都通過"` | 驗收 4 |
| T4 | `ImportSpec "不存在的 blob / asset / pack 被擋下"`、`"cluster 鍵不驗、照收"` | 驗收 5 |
| T5 | `ImportSpec "任一行有問題則一筆都不寫"`、`"dry-run 回報筆數但不寫"`、`"合法匯入後 listSuggestions 看得到 pending 且 run_id NULL"`、`"irWritten 是實際寫入數:已決定的列不計入不洗回"` | 驗收 1、2、6、7、10(run_id 以 SQL 直接查) |
| T6 | `ParserSpec "ai suggest import 需要檔案路徑,--dry-run 為選填"`;`ImportSpec` 不測 CLI 輸出文字 | CLI 文法 |
| T7 | `ImportSpec "匯入 → confirm → apply → reindexFts 後中文搜尋命中"` | 驗收 12;與 `SuggestSpec` 的驗收點同一條路,證明第二入口接得上 |

驗收 11(不相依 `Llm`)由模組 import 清單保證:`ImportSpec` 不建 `Llm`,`Import.hs` 不 import `AssetDB.AI.Llm`。

## 實作備註

- **第 2、3 層對「所有解析得出 JSON 的行」執行,不只對通過第 1 層的行**。「實作方式」第 5 點寫的是
  「通過前兩層的行」;實作改成只要 JSON 解得開就三層都跑,讓一行的形狀問題與目標不存在一次列完
  (煙霧測試第 4 行同時印出 `facet 必填`、`confidence 出界`、`內容雜湊不存在` 三條)。對外行為只差
  「問題清單更完整」,契約不變。
- 對真實資料庫煙霧測試(2026-08-23):壞檔 6 個問題全列、exit 1;不存在的檔走 `renderUnexpected`
  的繁中訊息;`--dry-run` 回「將寫入 1 筆」;實際匯入 `pack:magic-potions` 的 `藥水`(zh/theme)成為
  建議 #1398,`pending`,`run_id` NULL。
- 測試:`ai` 套件 46 → 60 examples(`ImportSpec` 14 條),`cli` 56 → 58(`ParserSpec` 2 條);
  `cabal test all` 683 examples, 0 failures。
