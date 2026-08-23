-- | 門面:re-export 執行檔(@mcp\/app\/Main.hs@)需要的最小介面
-- (llm-workshop-mcp/F005 T9)。
module StoryFlow.Mcp
  ( -- * 連線設定
    Config (..)
  , resolveConfig
  , mcpVersion
  , wantsVersion

    -- * 伺服器
  , runServer
  ) where

import StoryFlow.Mcp.Config (Config (..), mcpVersion, resolveConfig, wantsVersion)
import StoryFlow.Mcp.Server (runServer)
