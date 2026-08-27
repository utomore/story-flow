-- | 連線管理與資料庫開啟。
--
-- 這一層存在的理由是把 PRAGMA 設定收在**唯一一個地方**。
-- SQLite 的多數「效能問題」與「資料損毀」故事,追到最後都是某條連線
-- 忘了開 @foreign_keys@ 或沒設 @busy_timeout@。
module AssetDB.Store
  ( Store (..)
  , openStore
  , withStore
  , openStoreInMemory
  , initSchema
  , storeVersion

    -- * 重新匯出
  , module AssetDB.Store.Migrate
  ) where

import AssetDB.Store.Migrate
import AssetDB.Store.Orphans ()
import AssetDB.Store.Schema (migrations)
import Control.Exception (bracket)
import Data.Text (Text)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data Store = Store
  { storeConn :: Connection
  , storePath :: FilePath
  }

-- | 開啟(必要時建立)資料庫並套用 PRAGMA。**不會**自動跑 migration ——
-- 那是 'initSchema' 的工作,分開是為了讓「檢查版本但不改動」成為可能。
openStore :: FilePath -> IO Store
openStore path = do
  createDirectoryIfMissing True (takeDirectory path)
  conn <- open path
  applyPragmas conn True
  pure (Store conn path)

-- | 記憶體資料庫。測試用;不套用 WAL(記憶體資料庫沒有 journal 檔)。
openStoreInMemory :: IO Store
openStoreInMemory = do
  conn <- open ":memory:"
  applyPragmas conn False
  pure (Store conn ":memory:")

withStore :: FilePath -> (Store -> IO a) -> IO a
withStore path = bracket (openStore path) (close . storeConn)

applyPragmas :: Connection -> Bool -> IO ()
applyPragmas conn wal = do
  -- 預設是關閉的。沒開的話所有 REFERENCES 都只是註解。
  execute_ conn "PRAGMA foreign_keys = ON"

  -- 讀取不會被寫入阻塞。前端在背景掃描進行中仍然可以搜尋。
  -- journal_mode 會回傳一列結果,所以要用 query_ 而不是 execute_。
  _ <- if wal
    then (query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text])
    else pure []

  -- WAL 模式下 NORMAL 是安全的:最壞情況是作業系統當機時損失
  -- 最後幾筆交易,而不是資料庫損毀。
  execute_ conn "PRAGMA synchronous = NORMAL"

  -- 沒設的話,並行寫入會立刻回 SQLITE_BUSY 而不是等待。
  execute_ conn "PRAGMA busy_timeout = 5000"

  -- 讓查詢規劃器認得部分索引與 CHECK 約束的選擇性。
  execute_ conn "PRAGMA optimize"

-- | 套用所有待執行的 migration。回傳這次跑了哪些。
initSchema :: Store -> IO [Migration]
initSchema st = runMigrations (storeConn st) migrations

storeVersion :: Store -> IO Int
storeVersion = currentVersion . storeConn
