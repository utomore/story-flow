-- | @aapms-store@ 的門面:檔案落地與 SQLite 索引。
--
-- 這一層是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:__把資料安全地寫進
-- 檔案__,以及__維護一份隨時可以刪掉重建的索引__。ADR-002\/ADR-013 的核心主張
-- 「Markdown 是真相、SQLite 是衍生」在這裡被真正實現。
--
-- 目前(graph-core\/F005)只有讀取管線的第一段:@openVault@:讀 marker → 開
-- 索引 → schema 判斷。索引維護、查詢、寫入由後續 feature(graph-core\/F006\/F008\/F009)
-- 接手,接手後這份門面清單會擴充。
--
-- 典型用法:
--
-- @
-- Right (handle, issues) <- 'openVault' vaultRoot
-- ...
-- 'closeVault' handle
-- @
module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Error
  , module Aapms.Store.Marker
  , module Aapms.Store.Schema
  ) where

import Aapms.Store.Atomic
import Aapms.Store.Error
import Aapms.Store.Marker
import Aapms.Store.Schema
