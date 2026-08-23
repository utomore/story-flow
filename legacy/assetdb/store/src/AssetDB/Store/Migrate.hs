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

    -- * 組裝 migration SQL
  , lit
  , num
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
-- 組裝 migration SQL
--
-- 'migStatements' 一律以 'execute_' 執行,**不吃參數**。這是刻意的:migration
-- 是一疊可以直接讀成 SQL 的敘述,把它們改成「查詢 + 參數列」的配對會讓
-- schema 檔案的可讀性換走一個這裡並不存在的好處 —— migration 的值全部是
-- 編譯期字面值,沒有任何外部輸入,所以從來不是注入問題。
--
-- 但少數 migration(如分類詞彙表的種子資料)仍需要把值組進 SQL 文字。在那裡
-- 真正會發生的事是有人在中文定義裡寫了一個單引號,SQL 變成語法錯誤,而且要
-- 等到 migration 在使用者的機器上執行時才炸開 —— 編譯器不會攔,測試如果沒跑
-- 到那個 migration 也不會攔。'lit' 與 'num' 就是為此存在:值一律經過它們,
-- 這一整類錯誤便不可能發生,寫定義的人也不必記得任何規則。
--
-- (以註解警告「請勿使用單引號」是不夠的 —— 註解攔不住任何東西。)

-- | 把一個值組成 SQL 字面值:單引號加倍,再包上外層引號。
lit :: Text -> Query
lit t = Query ("'" <> T.replace "'" "''" t <> "'")

-- | 數值同樣經過型別再進 SQL,而不是以 @\"10\"@ 這種字串形式傳遞。
num :: Int -> Query
num = Query . T.pack . show

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
