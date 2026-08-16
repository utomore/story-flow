-- | 樂觀鎖寫入(ADR-0003)。
--
-- 順序是不能調換的:__先寫檔、再更新索引__(ADR-0002)。最後一步失敗時檔案
-- 已經寫成功,這__不是資料遺失__,所以回的是 'IndexUpdateFailed' 而不是
-- 'FileWriteFailed' —— 呼叫端該說的是「資料已寫入,索引需重建」。
--
-- 第二步__重讀檔案__而不信任索引裡的 revision:作者可能剛用編輯器改過,
-- 索引還沒 refresh。拿過時的 revision 去比對,樂觀鎖就形同虛設。
--
-- 殘留競態見 "StoryFlow.Store.Atomic":重讀與 rename 之間的毫秒級窗口是
-- func-0004 明確接受的風險。
module StoryFlow.Store.Write
  ( WriteResult (..)
  , writeEntityMeta
  , allocateId
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Database.SQLite.Simple
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Id (Id, IdPrefix, mkId, renderId)
import StoryFlow.Core.Meta (Meta (..))
import StoryFlow.Md
import StoryFlow.Store.Atomic (atomicWriteText, readTextFile)
import StoryFlow.Store.Error (StoreError (..), renderStoreError, trySqlite)
import StoryFlow.Store.Index (indexFile)
import StoryFlow.Store.Vault (Vault, vaultAbsPath)

data WriteResult = WriteResult
  { wrNewRevision :: Int
  , wrPath :: FilePath
  -- ^ Vault 相對路徑,與索引裡存的形式一致
  }
  deriving stock (Show, Eq)

-- | 修改既有片段 Entity 的 Meta。
--
-- @expected@ 是呼叫端手上那份資料的 revision;與檔案裡的實際值不符就
-- 'StaleRevision',__一個位元組都不寫__。
--
-- 檔案層主體(frontmatter 那一份)目前不支援:@storyflow-md@ 只提供節層的
-- 'updateSection'。這個缺口記在 architecture.md 末節的「已知缺口」。
writeEntityMeta
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreError WriteResult)
writeEntityMeta conn v i expected f =
  -- 1. 查索引取得檔案位置與節錨點
  locate conn i >>= \case
    Left e -> pure (Left e)
    Right (_, Nothing) -> pure (Left (FrontmatterWriteUnsupported i))
    Right (rel, Just _) ->
      -- 2. 重讀檔案,不信任索引裡的 revision
      readTextFile (vaultAbsPath v rel) >>= \case
        Left e -> pure (Left e)
        Right txt -> case reread rel i txt of
          Left e -> pure (Left e)
          Right (doc, actual)
            -- 3. 比對
            | actual /= expected -> pure (Left (StaleRevision i expected actual))
            | otherwise -> do
                today <- utctDay <$> getCurrentTime
                -- 4 & 5. 套用修改,並重新序列化__只有這一節__的 meta 區塊
                case updateSection i (bump today . f) doc of
                  Left e -> pure (Left (ParseFailed rel [e]))
                  Right doc' -> write rel doc' (actual + 1)
  where
    bump :: Day -> MetaOverride -> MetaOverride
    bump today ov = ov {moRevision = Just (expected + 1), moUpdated = Just today}

    write rel doc' newRev =
      -- 6. 先寫檔
      atomicWriteText (vaultAbsPath v rel) (renderDocument doc') >>= \case
        Left e -> pure (Left e)
        Right () ->
          -- 7. 再更新索引;失敗了資料仍然是安全的
          indexFile conn v rel >>= \case
            Left e -> pure (Left (IndexUpdateFailed rel (renderStoreError e)))
            Right () -> pure (Right (WriteResult newRev rel))

-- | 索引裡的 @file_path@ 與 @section_anchor@。
locate :: Connection -> Id -> IO (Either StoreError (FilePath, Maybe Text))
locate conn i = do
  r <-
    trySqlite $
      query
        conn
        "SELECT file_path, section_anchor FROM entities WHERE id = ?"
        (Only (renderId i))
  pure $ case r of
    Left e -> Left e
    Right (rows :: [(Text, Maybe Text)]) -> case rows of
      ((fp, anchor) : _) -> Right (T.unpack fp, anchor)
      [] -> Left (EntityNotFound i)

-- | 重讀後解析出這一節目前的 revision。
--
-- 索引說有、檔案裡卻找不到這一節,代表索引過時——回 'UnknownSectionId'
-- 而不是 'EntityNotFound':資料沒有不見,是索引跟不上。
reread :: FilePath -> Id -> Text -> Either StoreError (Document, Int)
reread rel i txt = do
  doc <- orParseFailed (parseDocument rel txt)
  (ef, _) <- orParseFailed (parseEntityFile doc)
  case [entMeta e | e <- efFragments ef, metaId (entMeta e) == i] of
    (m : _) -> Right (doc, metaRevision m)
    [] -> Left (ParseFailed rel [mdError rel 1 (UnknownSectionId i)])
  where
    orParseFailed :: Either [MdError] a -> Either StoreError a
    orParseFailed = either (Left . ParseFailed rel) Right

-- | 產生一個索引裡還沒有人用的 ID。
--
-- @core@ 的 'mkId' 是純函式,唯一性只有持有索引的這一層做得到:撞了就
-- @salt + 1@ 重算。8 次都撞的機率可以忽略,但無上限的迴圈是不可接受的。
allocateId :: Connection -> IdPrefix -> Text -> UTCTime -> IO (Either StoreError Id)
allocateId conn p content t = go 0
  where
    go salt
      | salt > maxRetries = pure (Left (IdCollision p))
      | otherwise = do
          let i = mkId p content t salt
          idExists conn i >>= \case
            Left e -> pure (Left e)
            Right True -> go (salt + 1)
            Right False -> pure (Right i)

    maxRetries = 8 :: Int

-- | 三種實體共用同一個 ID 空間,所以三張表都要看。
idExists :: Connection -> Id -> IO (Either StoreError Bool)
idExists conn i = do
  r <-
    trySqlite $
      query
        conn
        "SELECT (SELECT count(*) FROM entities WHERE id = ?)\
        \     + (SELECT count(*) FROM levels   WHERE id = ?)\
        \     + (SELECT count(*) FROM nodes    WHERE id = ?)"
        (t, t, t)
  pure $ case r of
    Left e -> Left e
    Right (rows :: [Only Int]) -> Right $ case rows of
      (Only n : _) -> n > 0
      [] -> False
  where
    t = renderId i
