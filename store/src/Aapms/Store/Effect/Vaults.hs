{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 本次生效的 vault 集合,寫成 effectful 的__效果描述__(ADR-023、ADR-017)。
--
-- 只有兩個操作:列出集合裡的 vault(保序),與「對集合裡某個 vault 跑一段
-- "Aapms.Store.Effect.Index" 程式」。合併分數、排序、分頁都在 Haskell 做
-- (P-002-search 的決定),不推進 SQL。
--
-- @InVault@ 帶的內層程式是__具體__的 @Eff '[Index] a@,不是 @m a@:每個 vault
-- 各有一份自己的索引,內層只看得到 'Index' 一個效果,借不到外層的能力。
--
-- 本模組__只有描述__:純解譯器 'Aapms.Store.Simulate.runVaultsPure' 住 pure 層
-- (P-002-search REV-2)。
module Aapms.Store.Effect.Vaults
  ( -- * 效果描述
    Vaults (..)

    -- * 操作(P-002-search)
  , vaultIds
  , inVault
  ) where

import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

import Aapms.Core.Id (VaultId)
import Aapms.Store.Effect.Index (Index)

-- | vault 集合的兩個操作。
data Vaults :: Effect where
  VaultIds :: Vaults m [VaultId]
  InVault :: VaultId -> Eff '[Index] a -> Vaults m (Maybe a)

makeEffect_ ''Vaults

-- | 集合裡的 vault,保序。
vaultIds :: Vaults :> es => Eff es [VaultId]

-- | 對集合裡某個 vault 跑一段 'Index' 程式;不在集合回 'Nothing'。
inVault :: Vaults :> es => VaultId -> Eff '[Index] a -> Eff es (Maybe a)
