-- | 落地層的錯誤型別。
--
-- 兩組區別是本模組存在的理由,不能靠註解維持:
--
-- * 'FileWriteFailed' 是__真正的失敗__(資料沒寫進去);'IndexUpdateFailed'
--   是__檔案已經寫成功、只有索引沒跟上__(ADR-002:索引是衍生物,重建即可)。
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
import StoryFlow.Core.Id (Id, IdPrefix, Ref, renderId, renderIdPrefix, renderRef)
import StoryFlow.Core.Link (Link (..), LinkKind, renderLinkKind)
import StoryFlow.Core.Tree (TreeError, renderTreeError)
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
  | -- | 被刪目標, 誰指向它。'DeleteSafe' 的拒絕理由,附上來源 id 讓呼叫端
    -- 能直接告訴作者去改哪裡
    ReferencedBy Id [(Id, Link)]
  | -- | 對片段用了只能用在檔案層主體的操作(如 'addFragment')
    NotAFileMain Id
  | -- | 反之:對檔案層主體用了只能用在片段的操作
    NotAFragment Id
  | -- | 父 Node, 算出來的新層級。Markdown 只有六級標題
    NodeDepthExceeded Id Int
  | -- | 根 Node 刪不得——刪了整份 Level 檔就解析不出 @root@
    CannotRemoveRootNode Id
  | -- | 來源 id, 關聯種類, 目標。'removeEntityLink' 一筆都沒命中
    LinkNotFound Id LinkKind Ref
  | FileAlreadyExists FilePath
  | -- | 編輯後的 Level 樹不合法。__已擋在寫檔之前__,檔案沒有被改到
    TreeInvalid FilePath [TreeError]
  | -- | 型別鍵。註冊表沒宣告 @dir@ 且呼叫端也沒給路徑
    RegistryDirUnknown Text
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
  ReferencedBy i srcs ->
    "刪除被拒絕:還有 "
      <> tshow (length srcs)
      <> " 筆關聯指向 "
      <> renderId i
      <> "\n"
      <> T.intercalate "\n" (map srcLine srcs)
      <> "\n請先移除這些關聯,或改用強制刪除(會留下指不到目標的孤兒關聯)"
  NotAFileMain i ->
    renderId i
      <> " 是檔案裡的一個片段,不是檔案層主體;"
      <> "請改用該檔案主體的 id(索引裡 section_anchor 為空的那一筆)"
  NotAFragment i ->
    renderId i
      <> " 是檔案層主體,不是檔內的節;"
      <> "請改用該檔案裡某一節的 id(Level 檔就是某個 Node 的 id)"
  NodeDepthExceeded i lvl ->
    "在 "
      <> renderId i
      <> " 底下新增會讓標題層級變成 "
      <> tshow lvl
      <> ",而 Markdown 只有六級標題;"
      <> "請把這棵子樹拆成另一份 Level,再以關聯串接(見 ADR-009)"
  CannotRemoveRootNode i ->
    renderId i
      <> " 是這份 Level 的根 Node,刪掉之後整份檔案就解析不出 root;"
      <> "要整份場景不要了請改用刪除 Level"
  LinkNotFound i k target ->
    renderId i
      <> " 身上沒有「"
      <> renderLinkKind k
      <> " → "
      <> renderRef target
      <> "」這一筆關聯;請先確認關聯的種類與目標是否寫對"
  FileAlreadyExists fp ->
    pack fp <> ": 這個路徑已經有檔案了;請換一個標題,或明確指定另一個路徑"
  TreeInvalid fp es ->
    pack fp
      <> ": 編輯後的場景樹不合法,檔案沒有被改到\n"
      <> T.intercalate "\n" (map (("  " <>) . renderTreeError) es)
      <> "\n請先在編輯器裡把標題層級修好,再重新執行這個操作"
  RegistryDirUnknown k ->
    "型別「"
      <> k
      <> "」沒有在 types/registry/ 宣告 dir,不知道新檔案該放哪個目錄;"
      <> "請在該型別的 .toml 補上 dir(或 owner_type),或直接指定檔案路徑"
  SqliteError msg ->
    "索引操作失敗 —— " <> msg
  where
    pack = T.pack
    tshow :: Int -> Text
    tshow = T.pack . show

    srcLine (src, l) =
      "  " <> renderId src <> " —— " <> renderLinkKind (linkKind l)

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
