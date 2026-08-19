-- | 受控的分類詞彙表,從資料庫載入。
--
-- == 為什麼從資料庫載,而不是寫死在 Haskell 裡
--
-- 餵給模型的**列舉**與寫進 prompt 的**定義**必須永遠一致。實測過不一致的
-- 下場:只給列舉、沒給定義時,一張 512px 的牛排圖示被分類成 @audio@。
--
-- 若列舉寫在 Haskell、定義寫在 SQL 種子裡,兩者就會漂移,而你只能寫一個
-- 漂移偵測測試去追。從同一列資料同時產生兩者,漂移**不可能發生** ——
-- 這比測試更徹底。
--
-- 這個理由**不**適用於命名文法的 states\/variants:那批詞決定既有名稱怎麼被
-- 解析,事後改資料等於改變舊資料的意義,所以它留在 @core\/Naming.hs@ 裡跟著
-- 程式碼版本走(catalog/B001,原本的 @naming_vocab@ 表已於 store migration 004
-- 移除)。分類詞彙沒有這個性質 —— 改了定義只影響**之後**的推論。
module AssetDB.AI.Vocab
  ( Category (..)
  , Vocab (..)
  , loadVocab
  , visionScopes
  , topSlugs
  , leafPaths
  , childrenOf
  , isChildOf
  , lookupPath
  ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple

data Category = Category
  { catPath :: Text
  -- ^ 物化路徑,如 @icon@ 或 @icon\/potion@。這是合約,rowid 不是。
  , catName :: Text
  , catSlug :: Text
  , catDefinition :: Text
  -- ^ 給**模型**看的定義,不是給人看的註解。
  , catScope :: Text
  , catSort :: Int
  }
  deriving stock (Eq, Show)

instance FromRow Category where
  fromRow = Category <$> field <*> field <*> field <*> field <*> field <*> field

data Vocab = Vocab
  { vocabTop :: [Category]
  , vocabLeaves :: [Category]
  }
  deriving stock (Eq, Show)

-- | 視覺標註看得到的範圍。
--
-- @audio@ \/ @level@ \/ @reference@ 因此**不在**送給模型的列舉裡 ——
-- 錯誤答案在 GBNF 文法層無法被表達,比在 prompt 裡拜託模型不要選有效得多。
visionScopes :: [Text]
visionScopes = ["any", "image"]

-- | 載入詞彙表,只取指定 @ai_scope@ 的項目。
loadVocab :: Connection -> [Text] -> IO Vocab
loadVocab conn scopes = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT path, name, slug, COALESCE(definition,''), ai_scope, sort \
            \FROM categories WHERE ai_scope IN ("
              <> T.intercalate "," (map (const "?") scopes)
              <> ") ORDER BY sort, path"
          )
      )
      scopes
  let (tops, leaves) = span' rows
  pure Vocab {vocabTop = sortOn catSort tops, vocabLeaves = sortOn catSort leaves}
  where
    span' = foldr step ([], [])
    step c (ts, ls)
      | T.isInfixOf "/" (catPath c) = (ts, c : ls)
      | otherwise = (c : ts, ls)

topSlugs :: Vocab -> [Text]
topSlugs = map catSlug . vocabTop

leafPaths :: Vocab -> [Text]
leafPaths = map catPath . vocabLeaves

childrenOf :: Vocab -> Text -> [Category]
childrenOf v parent = filter ((== parent) . parentOf . catPath) (vocabLeaves v)

parentOf :: Text -> Text
parentOf p = case T.breakOn "/" p of
  (a, rest) | not (T.null rest) -> a
  _ -> ""

-- | 子分類是否確實屬於這個父分類。
--
-- 驅動器用它做**優雅降級**:模型答對了 @category@ 卻給了一個不屬於它的
-- @subcategory@ 時,保留粗的那一個、丟掉細的那一個,而不是整筆作廢。
-- 一個錯誤的葉節點不該賠掉一個正確的頂層。
isChildOf :: Vocab -> Text -> Text -> Bool
isChildOf v parent leaf = parentOf leaf == parent && any ((== leaf) . catPath) (vocabLeaves v)

lookupPath :: Vocab -> Text -> Maybe Category
lookupPath v p = Map.lookup p m
  where
    m = Map.fromList [(catPath c, c) | c <- vocabTop v <> vocabLeaves v]
