-- | 落地層的錯誤型別。
--
-- 兩組區別是本模組存在的理由,不能靠註解維持:
--
-- * 'FileWriteFailed' 是__真正的失敗__(資料沒寫進去);'IndexUpdateFailed'
--   是__檔案已經寫成功、只有索引沒跟上__(ADR-0002:索引是衍生物,重建即可)。
--   呼叫端必須能區分,所以是兩個建構子而不是一個帶旗標的建構子
-- * 'ParseFailed' 帶 'MdError' 清單,是「檔案內容不合法」;'SqliteError' 是
--   「索引層自己出事」。所有 SQLite 例外都在本套件邊界被捕捉轉成後者,
--   不讓 @SQLError@ 洩漏到 @service@(P2)
module StoryFlow.Store.Error
  ( StoreError (..)
  , renderStoreError
  , trySqlite
  ) where

import Control.Exception (Handler (..), catches)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (FormatError, ResultError, SQLError)
import StoryFlow.Core.Id (Id, IdPrefix, renderId, renderIdPrefix)
import StoryFlow.Md.Error (MdError, renderMdError)

data StoreError
  = -- | 找不到 Vault。'Text' 是 @--vault@ 指定的名稱,或空字串代表向上搜尋失敗
    VaultNotFound Text
  | VaultConfigInvalid FilePath Text
  | VaultAlreadyExists FilePath
  | EntityNotFound Id
  | -- | id, expected, actual
    StaleRevision Id Int Int
  | IdCollision IdPrefix
  | FileReadFailed FilePath Text
  | FileWriteFailed FilePath Text
  | -- | 檔案已寫成功,只有索引失敗。__不是資料遺失__
    IndexUpdateFailed FilePath Text
  | ParseFailed FilePath [MdError]
  | -- | 檔案層主體(frontmatter)的 meta 目前改不動,見 architecture.md 末節的
    -- 「已知缺口」。@storyflow-md@ 只提供節層的 'StoryFlow.Md.Render.updateSection'
    FrontmatterWriteUnsupported Id
  | SqliteError Text
  deriving stock (Show, Eq)

renderStoreError :: StoreError -> Text
renderStoreError = \case
  VaultNotFound name
    | T.null name ->
        "從目前目錄向上找不到 .storyflow/;"
          <> "請在 Vault 根目錄執行 story-flow vault init,或以 --vault <名稱> 指定"
    | otherwise ->
        "全域註冊表裡沒有名為「"
          <> name
          <> "」的 Vault;"
          <> "請執行 story-flow vault init 建立,或檢查 ~/.config/story-flow/vaults.toml"
  VaultConfigInvalid fp msg ->
    pack fp <> ": Vault 設定檔無法解析 —— " <> msg
  VaultAlreadyExists fp ->
    pack fp <> ": 這裡已經有一個 Vault(.storyflow/config.toml 已存在)"
  EntityNotFound i ->
    "索引裡找不到 " <> renderId i
  StaleRevision i expected actual ->
    "寫入被拒絕:"
      <> renderId i
      <> " 的 revision 是 "
      <> tshow actual
      <> ",但你手上那份是 "
      <> tshow expected
      <> ";請重新讀取後再改"
  IdCollision p ->
    "連續 8 次都產生已存在的 " <> renderIdPrefix p <> " id,放棄重試"
  FileReadFailed fp msg ->
    pack fp <> ": 讀檔失敗 —— " <> msg
  FileWriteFailed fp msg ->
    pack fp <> ": 寫檔失敗 —— " <> msg
  IndexUpdateFailed fp msg ->
    pack fp
      <> ": 檔案已寫入成功,但索引更新失敗 —— "
      <> msg
      <> ";資料是安全的,執行 story-flow index rebuild 即可"
  ParseFailed fp es ->
    pack fp <> ": 解析失敗\n" <> T.intercalate "\n" (map renderMdError es)
  FrontmatterWriteUnsupported i ->
    renderId i
      <> " 是檔案層主體,它的 meta 寫在 frontmatter;"
      <> "目前只能以編輯器直接修改該檔案的 frontmatter"
  SqliteError msg ->
    "索引操作失敗 —— " <> msg
  where
    pack = T.pack
    tshow :: Int -> Text
    tshow = T.pack . show

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
