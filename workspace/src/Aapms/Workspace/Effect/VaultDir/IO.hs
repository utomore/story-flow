{-# LANGUAGE DataKinds #-}

-- | "Aapms.Workspace.Effect.VaultDir" 的__真解譯器__(shell)。
--
-- 建 marker 與空索引走 graph-core 的 @initVaultAtWith@;它__不逸出 IOException__
-- (建目錄失敗回 'Aapms.Workspace.Types.VaultInitFailed',不留半成品),這條紀律
-- 由 shell 的內部測試守(P-005 的決定)。
module Aapms.Workspace.Effect.VaultDir.IO
  ( runVaultDirIO
  ) where

import Effectful (Eff, IOE, (:>))

import Aapms.Workspace.Effect.VaultDir (VaultDir)

-- | 以真的檔案系統跑 'VaultDir'。
runVaultDirIO :: IOE :> es => Eff (VaultDir : es) a -> Eff es a
runVaultDirIO _act = error "P-005#runVaultDirIO stub"
