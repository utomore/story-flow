-- | story-flow 落地層的佔位模組。
module StoryFlow.Store (storeVersion) where

import Data.Text (Text)

-- | 套件骨架的佔位常數,func-0004 建立真正的落地層後可移除。
storeVersion :: Text
storeVersion = "0.1.0.0"
