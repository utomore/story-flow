-- | 落地層錯誤型別的 re-export,以及本套件與 SQLite 之間的唯一邊界。
--
-- __'StoreError' 是 @aapms-store@ 的唯一錯誤型別__(design.md 契約 G,
-- 2026-08-24 釐清):寫入、索引、marker、跨 vault 的失敗全部是它的建構子,由各
-- feature 依需要__擴充__(F005 建骨架、F006 加索引類、graph-core\/F008 加寫入類),
-- __不得另立平行的錯誤型別再橋接__ ——契約 E 的每個函式都寫
-- @Either StoreError a@,多一個型別就是多一套 @render*@ 與多一次翻譯。
--
-- 型別本身與 'renderStoreError' 的__宣告__住 "Aapms.Store.Types"(型別層,零
-- IO);本模組只留 'trySqlite' ——它碰 @sqlite-simple@ 的例外,不可能住型別層
-- ——並原樣 re-export 那兩個名字,匯出清單與既有呼叫端逐字不變。
module Aapms.Store.Error
  ( StoreError (..)
  , renderStoreError
  , trySqlite
  ) where

import Control.Exception (Handler (..), catches)
import qualified Data.Text as T
import Database.SQLite.Simple (FormatError, ResultError, SQLError)
import Aapms.Store.Types (StoreError (..), renderStoreError)

-- | 本套件與 SQLite 之間的唯一邊界。
--
-- @sqlite-simple@ 的三種例外都在這裡收斂成 'SqliteError';其餘例外(例如
-- 非同步中斷)照常往上拋,不被誤吞。
trySqlite :: IO a -> IO (Either StoreError a)
trySqlite act =
  (Right <$> act)
    `catches` [ Handler (\e -> failWith (e :: SQLError))
              , Handler (\e -> failWith (e :: FormatError))
              , Handler (\e -> failWith (e :: ResultError))
              ]
  where
    failWith :: (Show e) => e -> IO (Either StoreError a)
    failWith = pure . Left . SqliteError . T.pack . show
