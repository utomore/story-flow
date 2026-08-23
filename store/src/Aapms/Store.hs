-- | @aapms-store@ 的門面:檔案落地與 SQLite 索引。
--
-- 這一層是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:__把資料安全地寫進
-- 檔案__,以及__維護一份隨時可以刪掉重建的索引__。ADR-002\/ADR-013 的核心主張
-- 「Markdown 是真相、SQLite 是衍生」在這裡被真正實現。
--
-- graph-core\/F005 交付了讀取管線的第一段:@openVault@:讀 marker → 開索引 →
-- schema 判斷。graph-core\/F006 接上索引維護(@rebuildIndex@\/@refreshStale@\/
-- @indexFile@\/@unindexFile@)與單一 vault 查詢(@lookupNode@\/@listNodes@ 等,
-- 不含全文檢索);寫入(graph-core\/F008)與跨 vault 讀(graph-core\/F009)接手後
-- 這份門面清單會再擴充。
--
-- 典型用法:
--
-- @
-- Right (handle, issues) <- 'openVault' registry vaultRoot
-- _ <- 'rebuildIndex' handle
-- metas <- 'listNodes' handle 'emptyNodeFilter'
-- ...
-- 'closeVault' handle
-- @
--
-- 'Aapms.Store.Row' __不__ re-export——那是內部列轉換,呼叫端只透過
-- 'Aapms.Store.Index'\/'Aapms.Store.Query' 的函式互動,不直接碰
-- @SQLData@\/@FromRow@ 這層。
module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Error
  , module Aapms.Store.Index
  , module Aapms.Store.Marker
  , module Aapms.Store.Query
  , module Aapms.Store.Schema
  ) where

import Aapms.Store.Atomic
import Aapms.Store.Error
import Aapms.Store.Index
import Aapms.Store.Marker
import Aapms.Store.Query
import Aapms.Store.Schema
