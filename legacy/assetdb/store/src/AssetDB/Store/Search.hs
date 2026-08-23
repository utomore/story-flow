-- | 搜尋:全文 + facet 篩選。
--
-- == 兩條全文路徑
--
-- 純 ASCII 與三字以上中文走 @assets_fts@(trigram),兩字以下中文走
-- @assets_cjk@(unicode61 + 自製 n-gram)。查詢含中日韓字元時**兩條都走**
-- 再取聯集 —— 「金門建築」在 trigram 索引找得到,「金門」只有 bigram 索引找得到,
-- 而使用者不該需要知道這件事。
--
-- == facet 計數
--
-- 側欄要顯示「在目前的篩選條件下,每個作者/分類各有幾筆」。那個數字必須
-- 套用**除了該 facet 自己以外**的所有條件,否則點選之後結果數會對不上。
module AssetDB.Store.Search
  ( SearchQuery (..)
  , emptyQuery
  , SearchHit (..)
  , search
  , searchCount
  , FacetCounts (..)
  , facetCounts
  ) where

import AssetDB.Store.Tokenize
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple

data SearchQuery = SearchQuery
  { sqText :: Maybe Text
  , sqKinds :: [Text]
  , sqPacks :: [Text]
  -- ^ 素材包 slug
  , sqAuthors :: [Text]
  , sqVendors :: [Text]
  , sqCategories :: [Text]
  -- ^ 分類路徑,如 @icon@ 或 @icon\/potion@。
  --
  -- **精確比對,不做前綴展開。** 分類器對每一筆素材同時寫入頂層與子分類
  -- 兩列(icon 與 icon\/potion),所以選 @icon@ 本來就會涵蓋子分類 ——
  -- 在查詢層再做一次 LIKE 前綴展開,只會讓「為什麼選了父分類卻多出
  -- 沒被標成父分類的東西」變成一個沒人說得清的問題。
  , sqCommercialOnly :: Bool
  , sqNamedOnly :: Bool
  -- ^ 只要已指定邏輯名稱的。
  , sqIncludeExcluded :: Bool
  -- ^ 是否納入被規則判定為非素材的項目(宣傳圖等)。
  , sqIncludeReference :: Bool
  -- ^ 是否納入參考資料。**預設不納入** —— 找 GUI 框時不該跳出廟宇照片。
  , sqLimit :: Int
  , sqOffset :: Int
  }

emptyQuery :: SearchQuery
emptyQuery =
  SearchQuery
    { sqText = Nothing
    , sqKinds = []
    , sqPacks = []
    , sqAuthors = []
    , sqVendors = []
    , sqCategories = []
    , sqCommercialOnly = False
    , sqNamedOnly = False
    , sqIncludeExcluded = False
    , sqIncludeReference = False
    , -- 函式庫層的保守預設;實際入口都會覆寫,而且各入口刻意不同
      -- (G-E001):server 預設 60 / 上限 500(Server/App.hs 的
      -- defaultSearchLimit / maxSearchLimit)、web 一頁 120(Grid.tsx 的
      -- PAGE)、CLI 預設 20(Cli/Options.hs)。
      sqLimit = 50
    , sqOffset = 0
    }

data SearchHit = SearchHit
  { hitUlid :: Text
  , hitLogical :: Maybe Text
  , hitOriginal :: Text
  , hitKind :: Text
  , hitPack :: Maybe Text
  , hitAuthor :: Maybe Text
  , hitPath :: Text
  , hitSha :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromRow SearchHit where
  fromRow =
    SearchHit <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

--------------------------------------------------------------------------------

-- | 條件片段與其參數。分開累積是因為 facet 計數需要「除了某一個條件之外
-- 的全部條件」,而那要求條件是可以逐項組裝的資料,不是一整段字串。
data Cond = Cond {condSql :: Text, condParams :: [SQLData]}

whereClauses :: SearchQuery -> [(Text, Cond)]
whereClauses SearchQuery {..} =
  catMaybes
    [ ("text",) <$> textCond sqText
    , ("kind",) <$> inCond "a.kind" sqKinds
    , ("pack",) <$> inCond "p.slug" sqPacks
    , ("author",) <$> inCond "au.name" sqAuthors
    , ("vendor",) <$> inCond "p.vendor" sqVendors
    , ("category",) <$> categoryCond sqCategories
    , if sqCommercialOnly
        then Just ("commercial", Cond "l.commercial = 1" [])
        else Nothing
    , if sqNamedOnly
        then Just ("named", Cond "a.logical_name IS NOT NULL" [])
        else Nothing
    , if sqIncludeExcluded
        then Nothing
        else Just ("status", Cond "a.status = 'active'" [])
    , if sqIncludeReference
        then Nothing
        else Just ("kindOfPack", Cond "COALESCE(p.kind,'packs') = 'packs'" [])
    ]

inCond :: Text -> [Text] -> Maybe Cond
inCond _ [] = Nothing
inCond col vs =
  Just (Cond (col <> " IN (" <> T.intercalate "," (map (const "?") vs) <> ")") (map SQLText vs))

-- | 分類條件。
--
-- 用子查詢而不是把 @asset_categories@ 併進 'baseFrom':一筆素材有兩列分類
-- (頂層 + 子分類),JOIN 進主查詢會讓每筆結果重複出現,而 COUNT 也會跟著
-- 灌水。子查詢讓條件是純粹的成員判定,主查詢的列數不受影響。
categoryCond :: [Text] -> Maybe Cond
categoryCond [] = Nothing
categoryCond vs =
  Just
    ( Cond
        ( "a.id IN (SELECT ac.asset_id FROM asset_categories ac \
          \JOIN categories c ON c.id = ac.category_id WHERE c.path IN ("
            <> T.intercalate "," (map (const "?") vs)
            <> "))"
        )
        (map SQLText vs)
    )

-- | 全文條件。含中日韓字元時聯集兩張索引。
textCond :: Maybe Text -> Maybe Cond
textCond Nothing = Nothing
textCond (Just raw)
  | T.null (T.strip raw) = Nothing
  | otherwise =
      let term = T.strip raw
          trigram = "a.id IN (SELECT rowid FROM assets_fts WHERE assets_fts MATCH ?)"
          cjk = "a.id IN (SELECT rowid FROM assets_cjk WHERE assets_cjk MATCH ?)"
       in Just $ case cjkMatchExpr term of
            Nothing -> Cond trigram [SQLText (ftsQuoted term)]
            Just expr
              -- 三字以下的中日韓查詢在 trigram 索引裡是空結果(FTS5 的硬限制),
              -- 但寫成聯集不會有壞處,而且長詞兩邊都命中時排序更穩定。
              | otherwise ->
                  Cond
                    ("(" <> trigram <> " OR " <> cjk <> ")")
                    [SQLText (ftsQuoted term), SQLText expr]

baseFrom :: Text
baseFrom =
  "FROM assets a \
  \LEFT JOIN packs p ON p.id = a.pack_id \
  \LEFT JOIN authors au ON au.id = COALESCE(a.author_id, p.author_id) \
  \LEFT JOIN licenses l ON l.id = COALESCE(a.license_id, p.license_id) "

assemble :: [(Text, Cond)] -> (Text, [SQLData])
assemble cs =
  ( if null cs then "" else "WHERE " <> T.intercalate " AND " [condSql c | (_, c) <- cs]
  , concat [condParams c | (_, c) <- cs]
  )

--------------------------------------------------------------------------------

search :: Connection -> SearchQuery -> IO [SearchHit]
search conn q =
  let (whereSql, params) = assemble (whereClauses q)
      sql =
        "SELECT a.ulid, a.logical_name, a.original_name, a.kind, p.name, au.name, \
        \       COALESCE(a.entry_path, a.rel_path, ''), a.sha256 "
          <> baseFrom
          <> whereSql
          -- 已命名的優先,其次依邏輯名稱。未命名的還沒有穩定的排序依據,
          -- 用原始檔名至少是可預測的。
          <> " ORDER BY (a.logical_name IS NULL), a.logical_name, a.original_name \
             \ LIMIT ? OFFSET ?"
   in query conn (Query sql) (params <> [SQLInteger (fromIntegral (sqLimit q)), SQLInteger (fromIntegral (sqOffset q))])

searchCount :: Connection -> SearchQuery -> IO Int
searchCount conn q = do
  let (whereSql, params) = assemble (whereClauses q)
  rows <- query conn (Query ("SELECT COUNT(*) " <> baseFrom <> whereSql)) params
  pure (case rows of (Only n : _) -> n; _ -> 0)

--------------------------------------------------------------------------------

data FacetCounts = FacetCounts
  { fcKinds :: [(Text, Int)]
  , fcPacks :: [(Text, Int)]
  , fcAuthors :: [(Text, Int)]
  , fcVendors :: [(Text, Int)]
  , fcCategories :: [(Text, Int)]
  }
  deriving stock (Eq, Show)

-- | 每個 facet 的計數。
--
-- 關鍵:算某個 facet 的分佈時要**排除該 facet 自己的條件**。
-- 否則已經選了「作者 = Crusenho」之後,作者側欄只會剩下 Crusenho 一筆,
-- 使用者就沒辦法改選別人。
facetCounts :: Connection -> SearchQuery -> IO FacetCounts
facetCounts conn q =
  FacetCounts
    <$> counts "kind" "a.kind"
    <*> counts "pack" "p.slug"
    <*> counts "author" "au.name"
    <*> counts "vendor" "p.vendor"
    <*> categoryCounts
  where
    -- 分類要自己一份查詢:它的計數來自一張多對多表,而其餘四個 facet
    -- 都是主查詢上的欄位。COUNT(DISTINCT a.id) 是必要的 —— 一筆素材同時
    -- 掛在 icon 與 icon/potion 底下,不去重的話每個分類都會把它算進去
    -- 兩次以上。
    categoryCounts = do
      let (whereSql, params) = assemble [c | c@(n, _) <- whereClauses q, n /= "category"]
      query
        conn
        ( Query
            ( "SELECT c.path, COUNT(DISTINCT a.id) "
                <> baseFrom
                <> "JOIN asset_categories ac ON ac.asset_id = a.id \
                   \JOIN categories c ON c.id = ac.category_id "
                <> whereSql
                <> " GROUP BY c.path ORDER BY COUNT(DISTINCT a.id) DESC, c.path"
            )
        )
        params

    counts skip col = do
      let (whereSql, params) = assemble [c | c@(n, _) <- whereClauses q, n /= skip]
      query
        conn
        ( Query
            ( "SELECT " <> col <> ", COUNT(*) "
                <> baseFrom
                <> whereSql
                <> (if T.null whereSql then "WHERE " else " AND ")
                <> col
                <> " IS NOT NULL GROUP BY "
                <> col
                <> " ORDER BY COUNT(*) DESC, "
                <> col
            )
        )
        params
