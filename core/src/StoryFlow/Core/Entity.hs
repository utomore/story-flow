-- | Entity —— 內容的最小單位。
--
-- 世界觀片段、角色片段、道具、對話內容、劇情片段。ADR-0003:Entity 是衝突偵測
-- 唯一面對的東西,結構由 'StoryFlow.Core.Level.Node' 承載。
module StoryFlow.Core.Entity
  ( Entity (..)
  ) where

import Data.Text (Text)
import StoryFlow.Core.Meta (Meta)

data Entity = Entity
  { entMeta :: Meta
  , -- | 正文 Markdown。不在 frontmatter 內,是節的內文。
    entBody :: Text
  }
  deriving stock (Show, Eq)
