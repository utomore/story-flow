-- | 門面:re-export 執行檔(@mcp\/app\/Main.hs@)需要的最小介面
-- (llm-workshop-mcp/F005 T9)。
module Aapms.Mcp
  ( -- * 連線設定
    Config (..)
  , resolveConfig
  , mcpVersion
  , wantsVersion

    -- * 伺服器
  , runServer
  ) where

import Aapms.Mcp.Config (Config (..), mcpVersion, resolveConfig, wantsVersion)
import Aapms.Mcp.Server (runServer)
