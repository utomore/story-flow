{-# LANGUAGE DataKinds #-}

-- | "Aapms.Workspace.Effect.HubFile" 的__真解譯器__(shell)。
--
-- 中樞位置由 'Aapms.Workspace.Types.HubLocation' 傳進來(@AAPMS_HOME@ 或平台
-- 預設在進入點解析一次),檔案的讀寫走 @directory@ 與原子寫入。
module Aapms.Workspace.Effect.HubFile.IO
  ( runHubFileIO
  ) where

import Effectful (Eff, IOE, (:>))

import Aapms.Workspace.Effect.HubFile (HubFile)
import Aapms.Workspace.Types (HubLocation)

-- | 以真的檔案系統跑 'HubFile'。
runHubFileIO :: IOE :> es => HubLocation -> Eff (HubFile : es) a -> Eff es a
runHubFileIO _loc _act = error "P-004#runHubFileIO stub"
