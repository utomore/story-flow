-- | 所有寫入路徑共用的那一條紀律。內部模組,不對外承諾介面。
--
-- entity-graph-core/F004 只有一個寫入函式,那條紀律寫在 'Aapms.Store.Write' 裡就夠了;
-- entity-graph-core/F005 之後有十個,__再抄九遍就等於保證分裂__。順序不能調換:
--
-- @
-- 讀檔 → 解析 → 樂觀鎖比對 → 純函式編輯 → atomicWriteText → indexFile
--                                              ↑ 失敗 = FileWriteFailed(真失敗)
--                                                          ↑ 失敗 = IndexUpdateFailed(資料安全)
-- @
--
-- __重讀檔案而不信任索引裡的 revision__:作者可能剛用編輯器改過,索引還沒
-- refresh。拿過時的 revision 去比對,樂觀鎖就形同虛設。
--
-- 殘留競態見 "Aapms.Store.Atomic":重讀與 rename 之間的毫秒級窗口是
-- entity-graph-core/F004 明確接受的風險,entity-graph-core/F005 沿用同一個結論。
module Aapms.Store.Edit
  ( -- * 結果
    WriteResult (..)

    -- * 短路組合
  , (>>?)
  , (?>>)

    -- * 定位
  , Located (..)
  , locate
  , locateNode

    -- * 讀與解析
  , readDocument
  , entityFileOf
  , levelFileOf
  , orMd

    -- * 樂觀鎖
  , checkRevision

    -- * 落地
  , commit
  , ensureDir

    -- * 切片
  , sectionBodyRaw
  ) where

import Data.Bifunctor (first)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.Id (Id, renderId)
import Aapms.Md
import Aapms.Store.Atomic (atomicWriteText, readTextFile)
import Aapms.Store.Error (StoreError (..), renderStoreError, trySqlite)
import Aapms.Store.Index (indexFile)
import Aapms.Store.Vault (Vault, vaultAbsPath)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

data WriteResult = WriteResult
  { wrNewRevision :: Int
  , wrPath :: FilePath
  -- ^ Vault 相對路徑,與索引裡存的形式一致
  }
  deriving stock (Show, Eq)

-- 短路組合 ---------------------------------------------------------------------

-- | @Either@ 短路的 IO 鏈。
--
-- 每個寫入路徑都是五到七個「失敗就回 'Left'」的步驟,逐段寫 @>>= \\case@ 會讓
-- 巢狀縮排深到看不出主線。本套件不引入 @transformers@ 只為了這件事——一個中綴
-- 運算子就夠了,而且它的型別已經把「短路」講完。
(>>?) :: IO (Either StoreError a) -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)
m >>? f = m >>= either (pure . Left) f

infixl 1 >>?

-- | 純函式那一段接進同一條鏈。
(?>>) :: Either StoreError a -> (a -> IO (Either StoreError b)) -> IO (Either StoreError b)
e ?>> f = either (pure . Left) f e

infixl 1 ?>>

-- 定位 ------------------------------------------------------------------------

-- | 索引裡的 @file_path@ 與 @section_anchor@。
data Located = Located
  { locPath :: FilePath
  , locAnchor :: Maybe Text
  -- ^ @Nothing@ = 檔案層主體(它的 meta 在 frontmatter,不在任何一節)
  }
  deriving stock (Show, Eq)

-- | 在 @entities@ 表裡找。Level 與 Node 的 id 一律回 'EntityNotFound' ——
-- 對 Level 用 Entity 的操作是呼叫端的錯,不該靜默走進去。
locate :: Connection -> Id -> IO (Either StoreError Located)
locate conn i =
  runLocate conn i "SELECT file_path, section_anchor FROM entities WHERE id = ?" (Only (renderId i))

-- | 在 @levels@ \/ @nodes@ 兩張表裡找。@levels@ 沒有 @section_anchor@ 欄位,
-- 補一個 @NULL@ 讓兩邊的形狀一致——Level 主體本來就住在 frontmatter。
locateNode :: Connection -> Id -> IO (Either StoreError Located)
locateNode conn i =
  runLocate
    conn
    i
    "SELECT file_path, NULL FROM levels WHERE id = ?\
    \ UNION ALL\
    \ SELECT file_path, section_anchor FROM nodes WHERE id = ?"
    (t, t)
  where
    t = renderId i

runLocate :: (ToRow q) => Connection -> Id -> Query -> q -> IO (Either StoreError Located)
runLocate conn i sql args = do
  r <- trySqlite (query conn sql args)
  pure $ case r of
    Left e -> Left e
    Right (rows :: [(Text, Maybe Text)]) -> case rows of
      ((fp, anchor) : _) -> Right (Located (T.unpack fp) anchor)
      [] -> Left (EntityNotFound i)

-- 讀與解析 ---------------------------------------------------------------------

-- | 重讀檔案並切塊。@rel@ 是 Vault 相對路徑,同時當作錯誤訊息的原點。
readDocument :: Vault -> FilePath -> IO (Either StoreError Document)
readDocument v rel =
  readTextFile (vaultAbsPath v rel) >>? \txt ->
    pure (first (ParseFailed rel) (parseDocument rel txt))

entityFileOf :: FilePath -> Document -> Either StoreError (EntityFile, [MdWarning])
entityFileOf rel = first (ParseFailed rel) . parseEntityFile

levelFileOf :: FilePath -> Document -> Either StoreError (LevelFile, [MdWarning])
levelFileOf rel = first (ParseFailed rel) . parseLevelFile

-- | 單一 'MdError'(md 的編輯函式回的那種)包成 'StoreError'。
orMd :: FilePath -> Either MdError a -> Either StoreError a
orMd rel = first (\e -> ParseFailed rel [e])

-- 樂觀鎖 -----------------------------------------------------------------------

-- | 不符即 'StaleRevision',而呼叫端在這之後才會碰到 'commit' ——
-- __一個位元組都不會被寫出去__。
checkRevision :: Id -> Int -> Int -> Either StoreError ()
checkRevision i expected actual
  | expected == actual = Right ()
  | otherwise = Left (StaleRevision i expected actual)

-- 落地 ------------------------------------------------------------------------

-- | 先寫檔、再更新索引。
--
-- 索引那一步失敗時檔案__已經寫成功__,所以回的是 'IndexUpdateFailed' 而不是
-- 'FileWriteFailed':呼叫端該說的是「資料已寫入,索引需重建」。
commit :: Connection -> Vault -> FilePath -> Document -> Int -> IO (Either StoreError WriteResult)
commit conn v rel doc newRev =
  atomicWriteText (vaultAbsPath v rel) (renderDocument doc) >>? \() ->
    indexFile conn v rel >>= \case
      Left e -> pure (Left (IndexUpdateFailed rel (renderStoreError e)))
      Right () -> pure (Right (WriteResult newRev rel))

-- | 節的正文切片:@```meta@ 區塊(或標題行)之後隔一個空行,結尾補行尾。
--
-- 新節與改正文都要走同一個形狀,不然同一份檔案裡兩種節的排版會不一樣。
sectionBodyRaw :: LineEnding -> Text -> Text
sectionBodyRaw le b
  | T.null s = nl
  | otherwise = nl <> s <> nl
  where
    s = T.strip b
    nl = renderLineEnding le

-- | 建出檔案所在的目錄。
--
-- 'initVault' 只建了五個標準子目錄;註冊表宣告的自訂 @dir@ 與呼叫端指定的路徑
-- 都可能還不存在,而 'atomicWriteText' 的暫存檔就開在目標目錄裡——目錄沒有,
-- 連暫存檔都建不起來。
ensureDir :: Vault -> FilePath -> IO ()
ensureDir v rel = createDirectoryIfMissing True (takeDirectory (vaultAbsPath v rel))
