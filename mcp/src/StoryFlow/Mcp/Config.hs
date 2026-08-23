-- | @--url@ \/ @STORYFLOW_URL@ \/ @STORYFLOW_TOKEN@ 的旗標優先解析
-- (llm-workshop-mcp/F005 T6)。
--
-- __沒設定不是致命錯誤__:'resolveConfig' 回 'Left' 時,行程照樣進入 stdio
-- 迴圈——失敗要延後到 @initialize@ 這個 JSON-RPC 回應才能合法地講給客戶端聽
-- (design.md「連線設定」段)。
module StoryFlow.Mcp.Config
  ( Config (..)
  , resolveConfig

    -- * 版本(G-E002)
  , mcpVersion
  , wantsVersion
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Version (showVersion)
import Paths_storyflow_mcp (version)
import System.Environment (lookupEnv)

-- | 已解析的連線設定。
data Config = Config
  { cfgBaseUrl :: Text
  -- ^ 不含結尾斜線。
  , cfgToken :: Maybe Text
  -- ^ @STORYFLOW_TOKEN@,空字串視同沒設(同 @cli@ 的 @managerWith@)。
  }
  deriving stock (Show, Eq)

-- | @--url@ 旗標 → 沒有就讀 @STORYFLOW_URL@ → 都沒有回 'Left'(給 @initialize@
-- 用)。@STORYFLOW_TOKEN@ 永遠只走環境變數,沒有對應的旗標——與
-- @cli\/src\/StoryFlow\/Cli\/Backend.hs@ 的 @managerWith@ 對稱。
resolveConfig :: [Text] -> IO (Either Text Config)
resolveConfig argv = do
  urlEnv <- fmap T.pack <$> lookupEnv "STORYFLOW_URL"
  tokenEnv <- fmap T.pack <$> lookupEnv "STORYFLOW_TOKEN"
  pure $ case flagUrl argv `orElse` urlEnv of
    Nothing ->
      Left
        "沒有設定 story-flow 伺服器的位址:請用 --url <base> 或設定環境變數 STORYFLOW_URL"
    Just base -> Right (Config (stripTrailingSlash base) (nonEmpty tokenEnv))

-- | 找 @--url \<value\>@ 這一組;不認得的旗標一律忽略(mcp 只有這一個選項,
-- 見待確認假設 A7)。
flagUrl :: [Text] -> Maybe Text
flagUrl (x : v : _) | x == "--url" = Just v
flagUrl (_ : rest) = flagUrl rest
flagUrl [] = Nothing

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y

nonEmpty :: Maybe Text -> Maybe Text
nonEmpty (Just t) | not (T.null t) = Just t
nonEmpty _ = Nothing

stripTrailingSlash :: Text -> Text
stripTrailingSlash t = case T.stripSuffix "/" t of
  Just t' -> stripTrailingSlash t'
  Nothing -> t

-- | @--version@ 印的那一行,格式與 @story-flow@ / @story-flow-serve@ 相同(G-E002)。
mcpVersion :: Text
mcpVersion = "story-flow-mcp " <> T.pack (showVersion version)

-- | argv 裡有沒有 @--version@。手刻掃描與 resolveConfig 同一個理由(A7):
-- 一個旗標不值得整套 optparse。在 resolveConfig __之前__判斷——@--version@
-- 不需要 URL,也不該進 JSON-RPC 迴圈。
wantsVersion :: [Text] -> Bool
wantsVersion = elem "--version"
