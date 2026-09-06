-- | @aapms-store@ 的門面:檔案落地與 SQLite 索引。
--
-- 這一層是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:__把資料安全地寫進
-- 檔案__,以及__維護一份隨時可以刪掉重建的索引__。ADR-002\/ADR-013 的核心主張
-- 「Markdown 是真相、SQLite 是衍生」在這裡被真正實現。
--
-- graph-core\/F005 交付了讀取管線的第一段:@openVault@:讀 marker → 開索引 →
-- schema 判斷。索引維護、全文檢索與寫入現在各只有__一條__ shell 進入點
-- (2026-09-06 退場波):'rebuildIndex'(P-001-index-rebuild)、
-- 'searchAcross'(P-002-search)、'applyWriteIO'(P-003-node-write);
-- 單一 vault 的條件查詢與關聯查詢(@lookupNode@\/@listNodes@ 等)在
-- 'Aapms.Store.Query',跨 vault 讀在 'Aapms.Store.MultiVault'。
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
-- @SQLData@\/@FromRow@ 這層。同理 'Aapms.Store.Node'(Level 樹的純推導)是
-- 寫入路徑的內部模組,不進門面。
--
-- 'Aapms.Store.Types'(本套件全部對外型別的宣告)也 re-export:各功能模組
-- 本來就把自己那一份原樣帶出來,門面收下整個模組讓「只要型別」的消費端
-- (@workspace@ \/ @service@ 的 Types)有一個不碰 IO 的 import 目標;建檔\/
-- 刪除的輸入與結果型別('NewEntity' \/ 'NewLevel' \/ 'NewPack' \/
-- 'SectionPlacement' \/ 'CreateResult' \/ 'DeleteMode' \/ 'DeleteResult')
-- 就是從那裡來的。
module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Error
  , module Aapms.Store.Index
  , module Aapms.Store.Marker
  , module Aapms.Store.MultiVault
  , module Aapms.Store.Query
  , module Aapms.Store.Schema
  , module Aapms.Store.Types
  , module Aapms.Store.Write
  ) where

import Aapms.Store.Atomic
import Aapms.Store.Error
import Aapms.Store.Index
import Aapms.Store.Marker
import Aapms.Store.MultiVault
import Aapms.Store.Query
import Aapms.Store.Schema
import Aapms.Store.Types
import Aapms.Store.Write
