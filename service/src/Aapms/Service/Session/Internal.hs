{-# LANGUAGE DataKinds #-}

-- | P-004-vault-scope 的觀察點:兩個純解譯器一起跑到底。
--
-- 這個簽名__沒有 production 消費者__,只為 law 的觀察而匯出(rules\/boundary.md
-- 「測試與邊界」),所以住 @.Internal@:只有 "Aapms.Service.Session" 自己與測試
-- 准 import。
module Aapms.Service.Session.Internal
  ( simulateSession
  ) where

import Effectful (Eff, runPureEff)

import Aapms.Types.Effect.RegistryFs (RegistryFs, runRegistryFsPure)
import Aapms.Types.Source (RegistryWorld)
import Aapms.Workspace.Effect.HubFile (HubFile, runHubFilePure)
import Aapms.Workspace.Types (HubWorld)

-- | 觀察:'HubFile' 與 'RegistryFs' 的純解譯器跑到底。
--
-- 兩層剝完就沒有效果了,所以拿得到裸的結果——里程碑 @=@ 列的 law 因此完全不碰
-- IO。'Aapms.Workspace.Effect.HubFile.runHubFilePure' 會多交出最終的中樞世界
-- (REV-1),開場只讀不寫,這裡丟掉它。
simulateSession :: HubWorld -> RegistryWorld -> Eff '[HubFile, RegistryFs] a -> a
simulateSession hw rw act = fst (runPureEff (runRegistryFsPure rw (runHubFilePure hw act)))
