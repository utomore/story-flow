-- | @storyflow-store@ 的門面:檔案落地與 SQLite 索引。
--
-- 這一層是系統裡第一個碰 IO 的套件,負責兩件互相牽動的事:__把資料安全地寫進
-- 檔案__,以及__維護一份隨時可以刪掉重建的索引__。ADR-002 的核心主張
-- 「Markdown 是真相、SQLite 是衍生」只有在這裡被真正實現,而它換成兩條必須
-- 守住的底線:
--
-- * 任何寫入路徑都是「先寫檔、再更新索引」,索引更新失敗__不算資料遺失__
-- * @index rebuild@ 的結果必須與重建前等價——這是「檔案才是真相」唯一可驗證
--   的證明,測試在 @StoryFlow.Store.RebuildSpec@
--
-- 典型用法:
--
-- @
-- Right v <- 'resolveVault' Nothing =<< getCurrentDirectory
-- Right (conn, issues) <- 'openVaultIndex' v      -- 開索引並補上外部改動
-- metas <- 'listEntities' conn 'emptyFilter'
-- Right r <- 'writeEntityMeta' conn v i rev (\\ov -> ov { moSummary = Just \"新的總結\" })
-- @
module StoryFlow.Store
  ( module StoryFlow.Store.Atomic
  , module StoryFlow.Store.Create
  , module StoryFlow.Store.Error
  , module StoryFlow.Store.Index
  , module StoryFlow.Store.Node
  , module StoryFlow.Store.Query
  , module StoryFlow.Store.Schema
  , module StoryFlow.Store.Vault
  , module StoryFlow.Store.Write
  ) where

import StoryFlow.Store.Atomic
import StoryFlow.Store.Create
import StoryFlow.Store.Error
import StoryFlow.Store.Index
import StoryFlow.Store.Node
import StoryFlow.Store.Query
import StoryFlow.Store.Schema
import StoryFlow.Store.Vault
import StoryFlow.Store.Write
