-- | 版本化 migration 執行器。
--
-- 刻意做得很小。沒有 down migration —— 對單機 SQLite 來說,
-- 回退的正確作法是從 @.assetdb\/backups\/@ 還原檔案,
-- 而不是執行一段幾乎不會被測到的反向 SQL。
module AssetDB.Store.Migrate
  ( Migration (..)
  , runMigrations
  , currentVersion
  , appliedVersions
  , MigrationError (..)
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM, unless, when)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple

data Migration = Migration
  { migVersion :: Int
  , migName :: Text
  , migStatements :: [Query]
  }
  deriving stock (Eq, Show)

data MigrationError
  = -- | 版本號重複或非遞增。這是程式錯誤,寧可在啟動時就爆炸。
    MigrationsOutOfOrder [Int]
  | -- | 資料庫的版本比程式知道的還新 —— 通常代表有人用新版工具開過這個檔案。
    DatabaseNewerThanCode Int Int
  | MigrationFailed Int Text Text
  deriving stock (Show)

instance Exception MigrationError

--------------------------------------------------------------------------------

ensureMigrationTable :: Connection -> IO ()
ensureMigrationTable conn =
  execute_
    conn
    "CREATE TABLE IF NOT EXISTS schema_migrations ( \
    \  version    INTEGER PRIMARY KEY, \
    \  name       TEXT NOT NULL, \
    \  applied_at TEXT NOT NULL \
    \)"

-- | 已套用的最高版本。全新資料庫回傳 0。
currentVersion :: Connection -> IO Int
currentVersion conn = do
  ensureMigrationTable conn
  rows <- query_ conn "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
  pure $ case rows of
    [Only v] -> v
    _ -> 0

appliedVersions :: Connection -> IO [(Int, Text, Text)]
appliedVersions conn = do
  ensureMigrationTable conn
  query_ conn "SELECT version, name, applied_at FROM schema_migrations ORDER BY version"

-- | 套用所有尚未執行的 migration,回傳這次實際跑了哪些。
--
-- 冪等:重複呼叫時第二次回傳空清單。
--
-- 每個 migration 各自包在一個交易裡。一個 migration 失敗時,
-- 它自己的改動全部回滾,但**先前成功的 migration 保持已套用** ——
-- 這樣修好問題後重跑會從失敗的那個接續,而不是從頭再來。
runMigrations :: Connection -> [Migration] -> IO [Migration]
runMigrations conn migs = do
  let versions = map migVersion migs
  unless (isStrictlyAscending versions) $
    throwIO (MigrationsOutOfOrder versions)

  ensureMigrationTable conn
  cur <- currentVersion conn

  let newest = if null versions then 0 else maximum versions
  when (cur > newest) $
    throwIO (DatabaseNewerThanCode cur newest)

  let pending = sortOn migVersion (filter ((> cur) . migVersion) migs)
  forM pending $ \m -> do
    now <- iso8601Show <$> getCurrentTime
    withTransaction conn $ do
      mapM_ (execute_ conn) (migStatements m)
      execute
        conn
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?,?,?)"
        (migVersion m, migName m, T.pack now)
    pure m

isStrictlyAscending :: [Int] -> Bool
isStrictlyAscending xs = and (zipWith (<) xs (drop 1 xs))
