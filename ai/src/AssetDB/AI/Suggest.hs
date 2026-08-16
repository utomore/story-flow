-- | @ai_suggestions@ 的讀寫,以及**套用**這一步。
--
-- 這個模組沒有 HTTP 相依,而且是刻意的:確認與套用必須在推論服務關掉的
-- 情況下照常運作。昨天跑出來的建議,今天不該因為模型沒開就看不了。
--
-- == 套用這一步是整個功能的收斂點
--
-- @Index.hs@ 的全文索引是靠 @asset_tags@ 的 @GROUP_CONCAT@ 餵養的,而它
-- **以 asset_id 連接**。視覺標註產生的建議卻是以 sha256 為鍵(內容定址,
-- 一份內容只算一次)。中間這道扇出如果漏掉,@assets_fts.tags@ 會維持空
-- 字串 —— 也就是它現在的樣子 —— 於是「功能正常」與「靜默地什麼都沒做」
-- 在外觀上完全一樣。'applySuggestions' 的測試因此是整個 AI 功能的驗收點。
module AssetDB.AI.Suggest
  ( Suggestion (..)
  , StoredSuggestion (..)
  , SuggestFilter (..)
  , emptyFilter
  , tagSuggestion
  , categorySuggestion
  , subjectSuggestion
  , upsertSuggestions
  , listSuggestions
  , countSuggestions
  , decideSuggestions
  , hasSuggestionsFor
  , ApplyOptions (..)
  , defaultApplyOptions
  , ApplyReport (..)
  , applySuggestions
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple

--------------------------------------------------------------------------------
-- 型別

-- | 一筆尚未寫進資料庫的建議。
data Suggestion = Suggestion
  { sgTargetType :: Text
  -- ^ blob | cluster | asset | pack
  , sgTargetKey :: Text
  , sgField :: Text
  -- ^ category | tag | subject
  , sgValue :: Text
  , sgFacet :: Maybe Text
  -- ^ field='tag' 時必填,其餘必須是 Nothing(資料庫有 CHECK 把關)。
  , sgLang :: Text
  , sgConfidence :: Maybe Double
  , sgRationale :: Maybe Text
  }
  deriving stock (Eq, Show)

tagSuggestion :: Text -> Text -> Text -> Text -> Text -> Maybe Double -> Suggestion
tagSuggestion tt tk facet lang value conf =
  Suggestion tt tk "tag" value (Just facet) lang conf Nothing

categorySuggestion :: Text -> Text -> Text -> Maybe Double -> Maybe Text -> Suggestion
categorySuggestion tt tk path conf why =
  Suggestion tt tk "category" path Nothing "en" conf why

subjectSuggestion :: Text -> Text -> Text -> Text -> Suggestion
subjectSuggestion tt tk lang value =
  Suggestion tt tk "subject" value Nothing lang Nothing Nothing

data StoredSuggestion = StoredSuggestion
  { ssId :: Int
  , ssTargetType :: Text
  , ssTargetKey :: Text
  , ssField :: Text
  , ssValue :: Text
  , ssFacet :: Maybe Text
  , ssLang :: Text
  , ssConfidence :: Maybe Double
  , ssRationale :: Maybe Text
  , ssStatus :: Text
  }
  deriving stock (Eq, Show)

instance FromRow StoredSuggestion where
  fromRow =
    StoredSuggestion
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data SuggestFilter = SuggestFilter
  { sfStatus :: Maybe Text
  , sfTargetType :: Maybe Text
  , sfField :: Maybe Text
  , sfMinConfidence :: Maybe Double
  , sfLimit :: Int
  , sfOffset :: Int
  }
  deriving stock (Eq, Show)

emptyFilter :: SuggestFilter
emptyFilter = SuggestFilter Nothing Nothing Nothing Nothing 50 0

--------------------------------------------------------------------------------
-- 寫入

nowText :: IO Text
nowText = isoText <$> getCurrentTime

isoText :: UTCTime -> Text
isoText = T.pack . iso8601Show

-- | 寫入建議。重跑是**更新**而不是堆疊 —— 唯一鍵是
-- (target_type, target_key, field, value, lang)。
--
-- 已經被人決定過的列(confirmed / rejected / applied)不會被覆蓋回
-- pending:那會把人的判斷洗掉。
upsertSuggestions :: Connection -> Maybe Int -> [Suggestion] -> IO Int
upsertSuggestions conn runId sgs = do
  ts <- nowText
  withTransaction conn $ mapM_ (one ts) sgs
  pure (length sgs)
  where
    one ts Suggestion {..} =
      execute
        conn
        "INSERT INTO ai_suggestions \
        \  (run_id, target_type, target_key, field, value, facet, lang, \
        \   confidence, rationale, status, created_at) \
        \VALUES (?,?,?,?,?,?,?,?,?, 'pending', ?) \
        \ON CONFLICT (target_type, target_key, field, value, lang) DO UPDATE SET \
        \  run_id     = excluded.run_id, \
        \  confidence = excluded.confidence, \
        \  rationale  = excluded.rationale \
        \WHERE ai_suggestions.status = 'pending'"
        ( runId
        , sgTargetType
        , sgTargetKey
        , sgField
        , sgValue
        , sgFacet
        , sgLang
        , sgConfidence
        , sgRationale
        , ts
        )

-- | 這個目標已經有建議了嗎。叢集層的續跑靠它 —— 叢集是即時算出來的,
-- 沒有可以標記狀態的資料列。
hasSuggestionsFor :: Connection -> Text -> Text -> IO Bool
hasSuggestionsFor conn tt tk = do
  r <-
    query
      conn
      "SELECT 1 FROM ai_suggestions WHERE target_type = ? AND target_key = ? LIMIT 1"
      (tt, tk) ::
      IO [Only Int]
  pure (not (null r))

--------------------------------------------------------------------------------
-- 讀取

listSuggestions :: Connection -> SuggestFilter -> IO [StoredSuggestion]
listSuggestions conn f =
  queryNamed
    conn
    "SELECT id, target_type, target_key, field, value, facet, lang, \
    \       confidence, rationale, status \
    \FROM ai_suggestions \
    \WHERE (:status IS NULL OR status = :status) \
    \  AND (:tt IS NULL OR target_type = :tt) \
    \  AND (:fld IS NULL OR field = :fld) \
    \  AND (:minc IS NULL OR COALESCE(confidence, 0) >= :minc) \
    \ORDER BY target_type, target_key, field, value \
    \LIMIT :lim OFFSET :off"
    [ ":status" := sfStatus f
    , ":tt" := sfTargetType f
    , ":fld" := sfField f
    , ":minc" := sfMinConfidence f
    , ":lim" := sfLimit f
    , ":off" := sfOffset f
    ]

countSuggestions :: Connection -> IO [(Text, Int)]
countSuggestions conn =
  query_ conn "SELECT status, COUNT(*) FROM ai_suggestions GROUP BY status ORDER BY status"

-- | 確認或退回。回傳實際更動的列數。
decideSuggestions :: Connection -> [Int] -> Text -> Text -> IO Int
decideSuggestions _ [] _ _ = pure 0
decideSuggestions conn ids decision by = do
  ts <- nowText
  withTransaction conn $
    mapM_
      ( \i ->
          execute
            conn
            "UPDATE ai_suggestions SET status = ?, decided_by = ?, decided_at = ? \
            \WHERE id = ? AND status = 'pending'"
            (decision, by, ts, i)
      )
      ids
  changesFor conn ids decision

changesFor :: Connection -> [Int] -> Text -> IO Int
changesFor conn ids decision = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT COUNT(*) FROM ai_suggestions WHERE status = ? AND id IN ("
              <> T.intercalate "," (map (const "?") ids)
              <> ")"
          )
      )
      (toRow (Only decision) <> concatMap (toRow . Only) ids) ::
      IO [Only Int]
  pure (case rows of (Only n : _) -> n; _ -> 0)

--------------------------------------------------------------------------------
-- 套用

data ApplyOptions = ApplyOptions
  { aoDryRun :: Bool
  , aoResolveCluster :: Text -> IO [Int]
  -- ^ @"<pack_slug>|<shape>"@ → 這一群的 asset id。
  --
  -- 由呼叫端注入,因為叢集是 @AssetDB.Ingest.Cluster@ 即時算出來的,
  -- 而讓 assetdb-ai 相依 assetdb-ingest 會把 JuicyPixels 與 zip 一路
  -- 拖進伺服器。預設回傳空清單並被計入 'arUnresolved'。
  }

defaultApplyOptions :: ApplyOptions
defaultApplyOptions = ApplyOptions {aoDryRun = True, aoResolveCluster = \_ -> pure []}

data ApplyReport = ApplyReport
  { arTags :: Int
  , arCategories :: Int
  , arAssetsTouched :: Int
  , arUnresolved :: Int
  -- ^ 目標解析不到任何素材的建議數。不是錯誤,但要講出來。
  }
  deriving stock (Eq, Show)

-- | 把 confirmed 的建議寫進 @tags@ \/ @asset_tags@ \/ @asset_categories@。
--
-- 呼叫端在這之後**必須**跑 @reindexFts@,否則全文索引不會知道有新標籤 ——
-- 這正是 @runClusterApply@ 的作法。
applySuggestions :: Connection -> ApplyOptions -> IO ApplyReport
applySuggestions conn ApplyOptions {..} = do
  rows <-
    query_
      conn
      "SELECT id, target_type, target_key, field, value, facet, lang, \
      \       confidence, rationale, status \
      \FROM ai_suggestions WHERE status = 'confirmed' \
      \ORDER BY field, target_key" ::
      IO [StoredSuggestion]
  ts <- nowText
  foldMloop ts rows (ApplyReport 0 0 0 0)
  where
    foldMloop _ [] acc = pure acc
    foldMloop ts (s : rest) acc = do
      ids <- resolveTargets conn aoResolveCluster (ssTargetType s) (ssTargetKey s)
      acc' <-
        if null ids
          then pure acc {arUnresolved = arUnresolved acc + 1}
          else do
            n <- applyOne ts s ids
            pure
              acc
                { arTags = arTags acc + (if ssField s == "tag" then n else 0)
                , arCategories = arCategories acc + (if ssField s == "category" then n else 0)
                , arAssetsTouched = arAssetsTouched acc + n
                }
      foldMloop ts rest acc'

    applyOne ts s ids
      | aoDryRun = pure (length ids)
      | otherwise = withTransaction conn $ do
          n <- case ssField s of
            "tag" -> applyTag s ids
            "category" -> applyCategory s ids
            -- subject 不進 asset_tags:它是一句描述,不是搜尋詞。
            -- 留在 ai_suggestions 裡供人參考與日後命名使用。
            _ -> pure 0
          execute
            conn
            "UPDATE ai_suggestions SET status = 'applied', decided_at = ? WHERE id = ?"
            (ts, ssId s)
          pure n

    applyTag s ids = do
      let facet = maybe "free" id (ssFacet s)
      execute
        conn
        "INSERT OR IGNORE INTO tags (name, facet) VALUES (?,?)"
        (ssValue s, facet)
      tid <-
        query conn "SELECT id FROM tags WHERE facet = ? AND name = ?" (facet, ssValue s) ::
          IO [Only Int]
      case tid of
        (Only t : _) -> do
          -- source='inferred' 是三個來源裡最弱的一個(見 Schema.hs 的
          -- manual > rule > inferred)。搭配 INSERT OR IGNORE,重跑永遠
          -- 不會覆蓋掉人工修正過的標籤。絕不用 REPLACE。
          mapM_
            ( \aid ->
                execute
                  conn
                  "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id, source, confidence) \
                  \VALUES (?,?, 'inferred', ?)"
                  (aid, t, ssConfidence s)
            )
            ids
          pure (length ids)
        [] -> pure 0

    applyCategory s ids = do
      cid <- query conn "SELECT id FROM categories WHERE path = ?" (Only (ssValue s)) :: IO [Only Int]
      case cid of
        (Only c : _) -> do
          mapM_
            ( \aid ->
                execute
                  conn
                  "INSERT OR IGNORE INTO asset_categories (asset_id, category_id, source) \
                  \VALUES (?,?, 'inferred')"
                  (aid, c)
            )
            ids
          pure (length ids)
        [] -> pure 0

-- | 目標 → 素材 id。**這就是那道扇出。**
resolveTargets :: Connection -> (Text -> IO [Int]) -> Text -> Text -> IO [Int]
resolveTargets conn resolveCluster tt tk = case tt of
  -- 內容定址:同一份內容可能被多筆 asset 指向(不同素材包裡的同一個檔案),
  -- 全部都要拿到標籤。這一步漏掉,assets_fts.tags 就會保持空字串。
  "blob" -> ints <$> query conn "SELECT id FROM assets WHERE sha256 = ? AND status = 'active'" (Only tk)
  "asset" -> ints <$> query conn "SELECT id FROM assets WHERE ulid = ?" (Only tk)
  "pack" ->
    ints
      <$> query
        conn
        "SELECT a.id FROM assets a JOIN packs p ON p.id = a.pack_id \
        \WHERE p.slug = ? AND a.status = 'active'"
        (Only tk)
  "cluster" -> resolveCluster tk
  _ -> pure []
  where
    ints = map fromOnly
