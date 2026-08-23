-- | 自然語句 → 搜尋條件。
--
-- 這是**備援**,不是主力。中文搜尋的主力是離線寫進索引的中文標籤(見
-- "AssetDB.AI.Vision"):那條路零延遲、零 LLM,推論服務關掉也照樣運作。
-- 這裡處理的是主力路徑處理不好的東西 —— 整句自然語言,例如
-- 「我想要藍色的魔法藥水圖示」,其中「我想要」不該進全文搜尋。
--
-- 每次呼叫約 3 秒,所以這**不能**綁在打字上,只能是一個明確的動作。
module AssetDB.AI.Query
  ( QueryPlan (..)
  , planQuery
  ) where

import AssetDB.AI.Llm
import AssetDB.AI.Prompt
import AssetDB.AI.Vocab
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple

data QueryPlan = QueryPlan
  { qpKeywords :: [Text]
  -- ^ 中英文混合。原始檔名是英文,AI 標籤有中文,兩邊都要搜。
  , qpCategory :: Maybe Text
  , qpExplain :: Text
  }
  deriving stock (Eq, Show)

-- | 把一句話翻成搜尋條件。
--
-- 回傳 'Left' 時呼叫端應該**降級成字面搜尋**而不是顯示錯誤:既有的
-- 全文搜尋本來就能處理中文(@assets_cjk@),把它呈現成失敗是錯的。
planQuery :: Connection -> Llm -> Text -> IO (Either LlmError QueryPlan)
planQuery conn llm raw
  | T.null (T.strip raw) = pure (Right (QueryPlan [] Nothing ""))
  | otherwise = do
      vocab <- loadVocab conn visionScopes
      let req =
            (defaultChatRequest [systemMsg (querySystem vocab), userText (queryUser raw)])
              { crResponseFormat = Just (querySchema vocab)
              }
      r <- chatJson llm req
      pure (fmap toPlan r)
  where
    toPlan v =
      QueryPlan
        { qpKeywords = take 8 (filter (not . T.null) (map T.strip (qvKeywords v)))
        , qpCategory = if qvCategory v == "unknown" then Nothing else Just (qvCategory v)
        , qpExplain = qvAnalysis v
        }
