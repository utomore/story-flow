{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- | 時間,寫成 effectful 的__效果描述__(ADR-023)。
--
-- 配號的 salt 基準與 @updated@ 欄都要「現在」;把它做成效果之後,
-- P-003-node-write 的整條在純解譯器上跑得出可重現的結果
-- ('runClockPure' 固定回同一個時刻)。
module Aapms.Store.Effect.Clock
  ( -- * 效果描述
    Clock (..)

    -- * 操作(P-003-node-write)
  , now

    -- * 純解譯器(觀察點)
  , runClockPure
  ) where

import Data.Time (UTCTime)
import Effectful (Eff, Effect, (:>))
import Effectful.TH (makeEffect_)

-- | 只有一個操作。
data Clock :: Effect where
  Now :: Clock m UTCTime

makeEffect_ ''Clock

-- | 配號與 @updated@ 欄的時間。
now :: Clock :> es => Eff es UTCTime

-- | 觀察:固定時間的純解譯器。
runClockPure :: UTCTime -> Eff (Clock : es) a -> Eff es a
runClockPure _t _act = error "P-003#runClockPure stub"
