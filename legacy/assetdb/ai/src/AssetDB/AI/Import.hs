-- | 外部建議的匯入:JSON Lines → 三層驗證 → 全有全無寫進 @ai_suggestions@。
--
-- 暫存表原本只有一個入口(本機 LLM 的批次)。這個模組開第二個:任何不經推論服務的
-- 程序 —— 在終端機裡看檔名與縮圖的 Claude Code、一支腳本、人手寫的檔案 —— 都能把
-- 建議餵進**同一張**表,之後走**同一道**人工閘門。推論服務不是產生建議的唯一途徑,
-- 只是其中一條(ADR-010)。
--
-- == 三層驗證,全有全無
--
-- 形狀 → 詞彙表 → 目標存在。任何一行有任何問題,一筆都不寫:手寫或生成的檔案改完
-- 重跑即可,'upsertSuggestions' 本身是冪等的。逐行「壞的跳過、好的照寫」會讓同一個
-- 檔分兩次進資料庫,對帳變難。
--
-- 詞彙表那一層是 GBNF 對模型做的事:詞彙表外的分類值進不了暫存表,不論來源。
--
-- 這個模組**不認識 'AssetDB.AI.Llm'**,推論服務關掉時照常運作。
module AssetDB.AI.Import
  ( ImportOptions (..)
  , defaultImportOptions
  , ImportReport (..)
  , importSuggestions
  ) where

import AssetDB.AI.Suggest (Suggestion (..), upsertSuggestions)
import AssetDB.AI.Vocab (Vocab, loadVocab, lookupPath)
import AssetDB.Guard (guardedTry)
import AssetDB.Store.Errors (renderUnexpected)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Database.SQLite.Simple

data ImportOptions = ImportOptions
  { ioDryRun :: Bool
  }
  deriving stock (Eq, Show)

defaultImportOptions :: ImportOptions
defaultImportOptions = ImportOptions {ioDryRun = False}

data ImportReport = ImportReport
  { irLines :: Int
  -- ^ 讀到的非空白行數。
  , irWritten :: Int
  -- ^ 實際寫入(新增或更新)筆數。dry-run 或有任何問題時為 0。
  , irProblems :: [(Int, Text)]
  -- ^ (行號, 原因),依行號排序。行號 0 是整個檔案層級的問題。
  }
  deriving stock (Eq, Show)

-- | 一行 JSON 解出來的中間紀錄。鍵名與 @ai_suggestions@ 的欄位名完全相同 ——
-- 這是對外契約,不是 Haskell 欄位名的前綴剝除。
data Row = Row
  { rowTargetType :: Text
  , rowTargetKey :: Text
  , rowField :: Text
  , rowValue :: Text
  , rowFacet :: Maybe Text
  , rowLang :: Text
  , rowConfidence :: Maybe Double
  , rowRationale :: Maybe Text
  }

instance FromJSON Row where
  parseJSON = withObject "suggestion" $ \o ->
    Row
      <$> o .: "target_type"
      <*> o .: "target_key"
      <*> o .: "field"
      <*> o .: "value"
      <*> o .:? "facet"
      <*> o .: "lang"
      <*> o .:? "confidence"
      <*> o .:? "rationale"

importSuggestions :: Connection -> ImportOptions -> ByteString -> IO ImportReport
importSuggestions conn ImportOptions {..} bytes =
  case decodeUtf8' bytes of
    -- 刻意不用 lenient:替代字元會讓 sha 或分類路徑靜默變成不存在的值,
    -- 第 3 層擋下時訊息會指向錯的原因。
    Left _ -> pure (ImportReport 0 0 [(0, "檔案不是 UTF-8 編碼")])
    Right src -> do
      let numbered = [(n, l) | (n, l) <- zip [1 ..] (T.lines src), not (T.null (T.strip l))]
          parsed = [(n, decodeRow l) | (n, l) <- numbered]
          shapeProblems = concat [either (\e -> [(n, e)]) (map (n,) . checkShape) r | (n, r) <- parsed]
          ok = [(n, r) | (n, Right r) <- parsed]
      vocabProblems <- checkVocab conn ok
      existProblems <- checkTargets conn ok
      let problems = sortOn fst (shapeProblems <> vocabProblems <> existProblems)
          lineCount = length numbered
      case () of
        _
          | not (null problems) -> pure (ImportReport lineCount 0 problems)
          | ioDryRun -> pure (ImportReport lineCount 0 [])
          | otherwise -> do
              w <- guardedTry (upsertSuggestions conn Nothing (map (toSuggestion . snd) ok))
              pure $ case w of
                Left e -> ImportReport lineCount 0 [(0, renderUnexpected e)]
                Right n -> ImportReport lineCount n []

--------------------------------------------------------------------------------
-- 第 1 層:形狀

decodeRow :: Text -> Either Text Row
decodeRow l = case eitherDecodeStrict (encodeUtf8 l) of
  Left e -> Left ("JSON 解析失敗:" <> T.pack (compactMsg e))
  Right r -> Right r
  where
    compactMsg = unwords . words

targetTypes, fields, langs, facets :: [Text]
targetTypes = ["blob", "cluster", "asset", "pack"]
fields = ["category", "tag", "subject"]
langs = ["en", "zh"]
facets = ["style", "theme", "palette", "free"]

-- | 一行可以有多個問題,全部列出 —— 修一個再跑一次才發現還有下一個,是最煩的那種工具。
checkShape :: Row -> [Text]
checkShape Row {..} =
  concat
    [ [ "target_type 必須是 " <> oneOf targetTypes <> ",收到 " <> quote rowTargetType
      | rowTargetType `notElem` targetTypes
      ]
    , [ "field 必須是 " <> oneOf fields <> ",收到 " <> quote rowField
      | rowField `notElem` fields
      ]
    , [ "lang 必須是 " <> oneOf langs <> ",收到 " <> quote rowLang
      | rowLang `notElem` langs
      ]
    , ["target_key 不可空白" | blank rowTargetKey]
    , ["value 不可空白" | blank rowValue]
    , -- 與 schema 的 CHECK ((field = 'tag') = (facet IS NOT NULL)) 同義,
      -- 提早擋下免得撞一個使用者看不懂的 constraint 錯誤。
      case (rowField == "tag", rowFacet) of
        (True, Nothing) -> ["field 為 tag 時 facet 必填(" <> oneOf facets <> ")"]
        (True, Just f)
          | f `notElem` facets -> ["facet 必須是 " <> oneOf facets <> ",收到 " <> quote f]
          | otherwise -> []
        (False, Just _) -> ["field 不是 tag 時不可帶 facet"]
        (False, Nothing) -> []
    , [ "confidence 必須在 0 到 1 之間,收到 " <> T.pack (show c)
      | Just c <- [rowConfidence]
      , isNaN c || c < 0 || c > 1
      ]
    ]
  where
    blank = T.null . T.strip
    quote t = "「" <> t <> "」"
    oneOf = T.intercalate " / "

--------------------------------------------------------------------------------
-- 第 2 層:詞彙表

-- | 只對 @field = category@。載完整詞彙而不是 'AssetDB.AI.Vocab.visionScopes':
-- 匯入的目標不限於圖片。scope 值從表裡實際出現過的取,不硬編。
checkVocab :: Connection -> [(Int, Row)] -> IO [(Int, Text)]
checkVocab conn rows
  | null cats = pure []
  | otherwise = do
      scopes <- query_ conn "SELECT DISTINCT ai_scope FROM categories" :: IO [Only Text]
      vocab <- loadVocab conn (map fromOnly scopes)
      pure (mapMaybe (check vocab) cats)
  where
    cats = [(n, rowValue r) | (n, r) <- rows, rowField r == "category"]
    check :: Vocab -> (Int, Text) -> Maybe (Int, Text)
    check vocab (n, path) = case lookupPath vocab path of
      Just _ -> Nothing
      Nothing -> Just (n, "分類「" <> path <> "」不在詞彙表")

--------------------------------------------------------------------------------
-- 第 3 層:目標存在

-- | blob / asset / pack 各一次批次查詢。@cluster@ 不查:反查在 ingest,本子系統刻意不相依,
-- 套用時解析不到會計入 @arUnresolved@。
checkTargets :: Connection -> [(Int, Row)] -> IO [(Int, Text)]
checkTargets conn rows = concat <$> mapM one specs
  where
    specs :: [(Text, Text, Text, Text)]
    specs =
      [ ("blob", "blobs", "sha256", "內容雜湊")
      , ("asset", "assets", "ulid", "素材 ULID")
      , ("pack", "packs", "slug", "素材包")
      ]
    one (tt, table, col, label) = do
      let wanted = [(n, rowTargetKey r) | (n, r) <- rows, rowTargetType r == tt]
          keys = Set.toList (Set.fromList (map snd wanted))
      if null keys
        then pure []
        else do
          found <-
            query
              conn
              ( Query
                  ( "SELECT " <> col <> " FROM " <> table <> " WHERE " <> col <> " IN ("
                      <> T.intercalate "," (map (const "?") keys)
                      <> ")"
                  )
              )
              keys ::
              IO [Only Text]
          let present = Set.fromList (map fromOnly found)
          pure [(n, label <> "「" <> k <> "」不存在") | (n, k) <- wanted, not (Set.member k present)]

--------------------------------------------------------------------------------
-- 寫入

-- | 直接建構而不經 'AssetDB.AI.Suggest.tagSuggestion' 那幾個 builder:它們會把
-- @lang@ / @rationale@ 寫死,而匯入的每個欄位都來自檔案。
toSuggestion :: Row -> Suggestion
toSuggestion Row {..} =
  Suggestion
    { sgTargetType = rowTargetType
    , sgTargetKey = T.strip rowTargetKey
    , sgField = rowField
    , sgValue = T.strip rowValue
    , sgFacet = rowFacet
    , sgLang = rowLang
    , sgConfidence = rowConfidence
    , sgRationale = rowRationale
    }
