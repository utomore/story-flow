-- | @aapms-store@ 的門面:檔案落地與 SQLite 索引。
--
-- 這一層是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:__把資料安全地寫進
-- 檔案__,以及__維護一份隨時可以刪掉重建的索引__。ADR-002 的核心主張
-- 「Markdown 是真相、SQLite 是衍生」只有在這裡被真正實現,而它換成兩條必須
-- 守住的底線:
--
-- * 任何寫入路徑都是「先寫檔、再更新索引」,索引更新失敗__不算資料遺失__
-- * @index rebuild@ 的結果必須與重建前等價——這是「檔案才是真相」唯一可驗證
--   的證明,測試在 @Aapms.Store.RebuildSpec@
--
-- 典型用法:
--
-- @
-- Right v <- 'resolveVault' Nothing =<< getCurrentDirectory
-- Right (conn, issues) <- 'openVaultIndex' v      -- 開索引並補上外部改動
-- metas <- 'listEntities' conn 'emptyFilter'
-- Right r <- 'writeEntityMeta' conn v i rev (\\ov -> ov { moSummary = Just \"新的總結\" })
-- @
module Aapms.Store
  ( module Aapms.Store.Atomic
  , module Aapms.Store.Create
  , module Aapms.Store.Error
  , module Aapms.Store.Index
  , module Aapms.Store.Node
  , module Aapms.Store.Query
  , module Aapms.Store.Schema
  , module Aapms.Store.Vault
  , module Aapms.Store.Write
  ) where

import Aapms.Store.Atomic
import Aapms.Store.Create
import Aapms.Store.Error
import Aapms.Store.Index
import Aapms.Store.Node
import Aapms.Store.Query
import Aapms.Store.Schema
import Aapms.Store.Vault
import Aapms.Store.Write
