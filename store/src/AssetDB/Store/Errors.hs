-- | 把「別人定義的失敗」翻成使用者看得懂的繁體中文。
--
-- == 為什麼在 store 而不是 core
--
-- 渲染需要 'SQLError',而它來自 @sqlite-simple@。@core@ 是**遊戲本體唯一依賴的
-- 套件**(ADR-001),刻意保持零重量級依賴 —— 把資料庫驅動拉進去,每個
-- @import AssetDB.Manifest@ 的遊戲專案都會跟著背上它。@store@ 已經依賴 sqlite-simple,
-- 而四個子系統都依賴 @store@。
--
-- == 這個模組要解決的問題
--
-- @SQLError@ 與 @IOException@ 不是任何子系統「自己的」錯誤型別,型別簽名上也看不
-- 出來,所以它們一路逃到最外面,使用者看到的是 GHC 的英文 @show@ 加 backtrace,
-- 或是 HTTP 的空白 500。訊息要能回答「發生什麼事」與「我現在該做什麼」兩件事,
-- 只講前者的錯誤訊息等於沒講(G-E003)。
module AssetDB.Store.Errors
  ( renderSqlError
  , renderIoError
  , renderUnexpected
  , renderMigrationError
  , isBusy
  ) where

import AssetDB.Store.Migrate (MigrationError (..))
import Control.Exception (SomeException, fromException)
import Data.Text (Text)
import Data.Text qualified as T
import Database.SQLite.Simple (Error (..), SQLError (..))
import GHC.IO.Exception (IOException (..))

-- | 這個資料庫錯誤是「暫時的、重試有意義」嗎。
--
-- 決定 HTTP 層回 503(可重試)還是 500。@SQLITE_BUSY@ 與 @SQLITE_LOCKED@ 的典型
-- 成因是背景掃描正在寫入 —— 那是**預期中的並行**,不是故障(ADR-009)。
isBusy :: SQLError -> Bool
isBusy e = sqlError e `elem` [ErrorBusy, ErrorLocked]

-- | 資料庫錯誤。
renderSqlError :: SQLError -> Text
renderSqlError e = headline <> detail
  where
    detail = "(" <> compact (sqlErrorDetails e) <> ")"
    headline = case sqlError e of
      ErrorBusy -> "資料庫正忙,這次沒寫進去。通常是背景掃描或標註正在寫入,稍後重試即可。"
      ErrorLocked -> "資料庫被鎖住,這次沒寫進去。確認沒有其他 assetdb 指令正在跑,稍後重試。"
      ErrorReadOnly -> "資料庫是唯讀的,寫不進去。檢查檔案權限,或確認磁碟沒有滿。"
      ErrorConstraint -> "這筆資料違反了資料庫的約束條件,已拒絕寫入(通常是值不在允許的範圍內,或與既有資料重複)。"
      ErrorCorrupt -> "資料庫檔案已損毀。從 .assetdb/ 的備份還原,或重新掃描素材庫重建索引。"
      ErrorFull -> "磁碟空間不足,寫不進去。"
      ErrorCan'tOpen -> "打不開資料庫檔案。確認路徑正確、檔案沒有被其他程式佔用。"
      ErrorNotADatabase -> "這個檔案不是 SQLite 資料庫(或已損毀到無法辨識)。"
      _ -> "資料庫操作失敗。"

-- | 檔案系統例外。
renderIoError :: IOException -> Text
renderIoError e =
  "檔案操作失敗" <> maybe "" (\p -> ":" <> T.pack p) (ioe_filename e) <> " —— " <> compact (T.pack (ioe_description e))

-- | migration 的失敗。
--
-- 'DatabaseNewerThanCode' 是**真實會發生的情境**:PATH 上的舊執行檔開了一個新版
-- 建立的資料庫。原本印的是 @DatabaseNewerThanCode 4 3@ 加 backtrace —— 那對使用者
-- 沒有任何意義,而正確的處置(重新安裝)也看不出來。
renderMigrationError :: MigrationError -> Text
renderMigrationError = \case
  DatabaseNewerThanCode cur newest ->
    "這個資料庫是較新版本的 assetdb 建立的(資料庫 schema v"
      <> tshow cur
      <> ",目前的執行檔只認得 v"
      <> tshow newest
      <> ")。\n"
      <> "  schema 只做正向 migration,舊版工具不會去動新版的資料庫(ADR-006)。\n"
      <> "  請重新安裝:cabal install assetdb-cli assetdb-server --overwrite-policy=always"
  MigrationsOutOfOrder vs ->
    "schema migration 的版本號不是嚴格遞增:" <> tshow vs <> "。這是程式錯誤,請回報。"
  MigrationFailed v name why ->
    "schema migration v" <> tshow v <> "(" <> name <> ")執行失敗:" <> compact why

-- | 兜底。認得的先認,其餘壓成單行 —— 多行的 GHC backtrace 在終端機裡只會蓋掉
-- 真正有用的訊息。
renderUnexpected :: SomeException -> Text
renderUnexpected e
  | Just me <- fromException e = renderMigrationError me
  | Just se <- fromException e = renderSqlError se
  | Just ioe <- fromException e = renderIoError ioe
  | otherwise = "發生未預期的錯誤:" <> compact (T.pack (show e))

compact :: Text -> Text
compact = T.unwords . T.words

tshow :: Show a => a -> Text
tshow = T.pack . show
