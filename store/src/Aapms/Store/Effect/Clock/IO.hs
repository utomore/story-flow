{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | 'Aapms.Store.Effect.Clock.Clock' 的__真解譯器__:向作業系統取現在時刻。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶
-- 'Effectful.IOE' 這個執行能力,是效果真的發生的地方。效果的__描述__與純解譯器
-- ('Aapms.Store.Effect.Clock.runClockPure')住 effects 層,兩者不共用模組
-- (ADR-023)。
module Aapms.Store.Effect.Clock.IO
  ( runClockIO
  ) where

import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)

import Aapms.Store.Effect.Clock (Clock (..))

-- | 把 @Now@ 落到 'Data.Time.getCurrentTime'。
--
-- 每次 @Now@ 各取樣一次(不快取):同一段程式裡兩次 @now@ 本來就可能落在不同
-- 時刻,快取會把「時間會走」這件事藏起來,而配號的 salt 基準正是靠它區分。
runClockIO :: IOE :> es => Eff (Clock : es) a -> Eff es a
runClockIO = interpret $ \_ Now -> liftIO getCurrentTime
