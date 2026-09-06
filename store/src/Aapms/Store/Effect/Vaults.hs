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
module Aapms.Store.Effect.Vaults
  ( -- * 效果描述
    Vaults (..)

    -- * 操作(P-002-search)
  , vaultIds
  , inVault

    -- * 純解譯器(觀察點)
  , runVaultsPure
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Effectful (Eff, Effect, runPureEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.TH (makeEffect_)

import Aapms.Core.Id (VaultId)
import Aapms.Store.Effect.Index (Index, runIndexPure)
import Aapms.Store.Types (IndexState)

-- | vault 集合的兩個操作。
data Vaults :: Effect where
  VaultIds :: Vaults m [VaultId]
  InVault :: VaultId -> Eff '[Index] a -> Vaults m (Maybe a)

makeEffect_ ''Vaults

-- | 集合裡的 vault,保序。
vaultIds :: Vaults :> es => Eff es [VaultId]

-- | 對集合裡某個 vault 跑一段 'Index' 程式;不在集合回 'Nothing'。
inVault :: Vaults :> es => VaultId -> Eff '[Index] a -> Eff es (Maybe a)

-- | 觀察:'Vaults' 的純解譯器,每個 vault 一份記憶體索引。
--
-- @VaultIds@ 依 'Map' 的鍵序回傳(保序,而且與 'Aapms.Store.Types.keysOf'
-- 同一個順序);@InVault@ 對集合裡的 vault 拿它自己那一份 'IndexState' 跑
-- 'runIndexPure',不在集合就回 'Nothing'。內層程式的索引異動不會流出來——
-- @InVault@ 只回 @a@,這正是「一段查詢程式」該有的形狀。
runVaultsPure :: Map VaultId IndexState -> Eff (Vaults : es) a -> Eff es a
runVaultsPure m = interpret $ \_ op -> case op of
  VaultIds -> pure (Map.keys m)
  InVault v act -> pure $ case Map.lookup v m of
    Nothing -> Nothing
    Just ix -> Just (fst (runPureEff (runIndexPure ix act)))
