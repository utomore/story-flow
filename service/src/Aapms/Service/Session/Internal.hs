{-# LANGUAGE DataKinds #-}

-- | P-004-vault-scope 的觀察點:兩個純解譯器一起跑到底。
--
-- 這個簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Service.Session" 自己與測試
-- 准 import。
module Aapms.Service.Session.Internal
  ( simulateSession
  ) where

import Effectful (Eff)

import Aapms.Types.Effect.RegistryFs (RegistryFs)
import Aapms.Types.Source (RegistryWorld)
import Aapms.Workspace.Effect.HubFile (HubFile)
import Aapms.Workspace.Types (HubWorld)

-- | 觀察:'HubFile' 與 'RegistryFs' 的純解譯器跑到底。
simulateSession :: HubWorld -> RegistryWorld -> Eff '[HubFile, RegistryFs] a -> a
simulateSession _hw _rw _act = error "P-004#simulateSession stub"
