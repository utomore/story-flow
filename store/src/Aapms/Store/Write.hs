-- | 改既有實體:meta、正文、關聯(ADR-003 的樂觀鎖)。
--
-- 「建檔 / 增節 / 刪除」在 "Aapms.Store.Create",「Level 樹編輯」在
-- "Aapms.Store.Node";三者共用的那條紀律(讀 → 鎖 → 純函式編輯 → 寫檔 →
-- 索引)在 "Aapms.Store.Edit",本模組不重寫一遍。
--
-- 檔案層主體與片段走__同一組介面__:差別只在 @section_anchor@ 是不是 @NULL@,
-- 而那件事由 'locate' 回答,不必呼叫端指定。片段改的是節的 @```meta@ 區塊
-- (只有那一段被重新序列化),主體改的是 frontmatter(整段重新序列化,見
-- 'Aapms.Md.Render.updateFrontmatter')。
module Aapms.Store.Write
  ( WriteResult (..)

    -- * Meta
  , writeEntityMeta
  , writeEntityPatch

    -- * 正文
  , writeEntityBody

    -- * 關聯
  , addEntityLink
  , removeEntityLink

    -- * ID
  , allocateId
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Database.SQLite.Simple
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix, Ref, mkId, renderId)
import Aapms.Core.Link (Link (..), LinkKind)
import Aapms.Core.Meta (Meta (..), bumpRevision)
import Aapms.Md
import Aapms.Store.Edit
import Aapms.Store.Error (StoreError (..), trySqlite)
import Aapms.Store.Vault (Vault)

-- | 修改既有 Entity 的 Meta。片段與檔案層主體都支援。
--
-- @expected@ 是呼叫端手上那份資料的 revision;與檔案裡的實際值不符就
-- 'StaleRevision',__一個位元組都不寫__。
--
-- 修改函式吃 'MetaOverride' 而不是 'Meta':片段的 meta 區塊本來就是「只寫與
-- 檔案層不同的欄位」,寫成完整的 'Meta' 會讓每次修改都把繼承來的欄位全部釘死
-- 在節上。檔案層主體沒有「目前的覆寫」可用,以
-- 'Aapms.Md.Inherit.overrideOf' 把 'Meta' 展開成每欄都是 @Just@ 的覆寫,
-- 改完再 'Aapms.Md.Inherit.applyOverride' 疊回去。
--
-- @id@ 與 @title@ 'MetaOverride' 表達不了,因此改不動——改標題請走 md 的
-- 'Aapms.Md.Render.updateFrontmatter'(P2 的 service 會包一層)。
writeEntityMeta
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreError WriteResult)
writeEntityMeta conn v i expected f = editEntityMeta conn v i expected Nothing (Right . f)

-- | 改 Meta,並可__在同一次寫入裡__換掉標題。
--
-- 標題與其他欄位分兩次寫的話,第二次失敗就會留下「標題改了、summary 沒改」
-- 的半套結果,而且 revision 會平白跳兩號。所以是一個函式吃兩件事,不是兩個
-- 函式各寫一次。
--
-- 標題的落點兩層不同:檔案層主體在 frontmatter 的 @title@,片段在標題行本身
-- (走 'Aapms.Md.Render.renameSection')。'MetaOverride' 兩者都表達不了,
-- 因此標題是獨立的 @Maybe Text@ 參數而不是覆寫裡的一欄。
writeEntityPatch
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> Maybe Text
  -- ^ 新標題;@Nothing@ = 不動標題
  -> (MetaOverride -> MetaOverride)
  -> IO (Either StoreError WriteResult)
writeEntityPatch conn v i expected mTitle f =
  editEntityMeta conn v i expected mTitle (Right . f)

-- | 換掉正文:片段換該節的 @secBodyRaw@,主體換 frontmatter 之後的 preamble。
--
-- 兩條路徑都會遞增 revision——正文才是片段真正的內容,改了它卻不動 revision,
-- 樂觀鎖就對「內容被改過」視而不見。
writeEntityBody
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> Text
  -> IO (Either StoreError WriteResult)
writeEntityBody conn v i expected body =
  editEntity conn v i expected $ \today anchor rel doc _ -> case anchor of
    Just _ -> do
      cur <- orMd rel (overrideAt i doc)
      doc' <- orMd rel (updateSection i (const (bumpOverride expected today cur)) doc)
      orMd rel (replaceSectionBody i (sectionBodyRaw (docEnding doc) body) doc')
    Nothing -> do
      doc' <- orMd rel (updateFrontmatter (bumpRevision today) doc)
      Right (replacePreamble body doc')

-- | 加一筆關聯。
--
-- 關聯__只存在來源端__(ADR-002),所以這是單邊、單檔操作:目標端的檔案
-- 一個位元組都不會被碰到。反向查詢由索引負責。
addEntityLink
  :: Connection -> Vault -> Id -> Int -> Link -> IO (Either StoreError WriteResult)
addEntityLink conn v i expected l =
  editEntityMeta conn v i expected Nothing $ \ov ->
    Right ov {moLinks = Just (fromMaybe [] (moLinks ov) ++ [l])}

-- | 以 @(LinkKind, Ref)@ 配對刪除;同一對出現多次時全部刪掉。
--
-- __一筆都沒命中時回 'LinkNotFound' 而不是靜默成功__:呼叫端以為刪掉了、
-- 實際上關聯還在,是最難查的那種錯。
--
-- 比對的是__檔案裡寫的那個 'Ref'__:作者寫 @liftgame:ent-7f3a@ 時要以同樣的
-- 形式來刪。索引為了反向查詢會把本 Vault 的前綴正規化掉,檔案不會。
removeEntityLink
  :: Connection -> Vault -> Id -> Int -> LinkKind -> Ref -> IO (Either StoreError WriteResult)
removeEntityLink conn v i expected k target =
  editEntityMeta conn v i expected Nothing $ \ov ->
    let current = fromMaybe [] (moLinks ov)
        kept = [x | x <- current, not (hit x)]
        hit x = linkKind x == k && linkTarget x == target
     in if length kept == length current
          then Left (LinkNotFound i k target)
          else Right ov {moLinks = Just kept}

-- 共同骨架 ---------------------------------------------------------------------

-- | 「改一個既有 Entity 的 meta」的共同骨架。
--
-- 修改函式回 'Left' 時__整個操作中止且不寫檔__——'removeEntityLink' 的
-- 'LinkNotFound' 走的就是這條。
editEntityMeta
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> Maybe Text
  -> (MetaOverride -> Either StoreError MetaOverride)
  -> IO (Either StoreError WriteResult)
editEntityMeta conn v i expected mTitle f =
  editEntity conn v i expected $ \today anchor rel doc m -> case anchor of
    -- 節層:只有這一節的 meta 區塊(必要時再加標題行)被重新序列化,其餘逐字不動
    Just _ -> do
      cur <- orMd rel (overrideAt i doc)
      ov <- f cur
      doc' <- orMd rel (updateSection i (const (bumpOverride expected today ov)) doc)
      case mTitle of
        Nothing -> Right doc'
        Just t -> orMd rel (renameSection i t doc')
    -- 檔案層主體:frontmatter 整段重新序列化
    Nothing -> do
      ov <- f (overrideOf m)
      orMd rel (updateFrontmatter (retitle . bumpRevision today . applyOverride ov) doc)
  where
    retitle = maybe id (\t x -> x {metaTitle = t}) mTitle

-- | 讀 → 樂觀鎖 → 純函式編輯 → 寫檔 → 索引。
--
-- 編輯函式拿到今天的日期、目標的 @section_anchor@、Vault 相對路徑、切好塊的
-- 'Document',以及__目標實體目前的 'Meta'__(節層的那份已經套過繼承規則)。
editEntity
  :: Connection
  -> Vault
  -> Id
  -> Int
  -> (Day -> Maybe Text -> FilePath -> Document -> Meta -> Either StoreError Document)
  -> IO (Either StoreError WriteResult)
editEntity conn v i expected edit =
  locate conn i >>? \(Located rel anchor) ->
    readDocument v rel >>? \doc ->
      entityFileOf rel doc ?>> \(ef, _) ->
        currentMeta rel i anchor ef ?>> \m ->
          checkRevision i expected (metaRevision m) ?>> \() -> do
            today <- utctDay <$> getCurrentTime
            edit today anchor rel doc m ?>> \doc' ->
              commit conn v rel doc' (expected + 1)

-- | 目標實體目前的 'Meta'。
--
-- 索引說有、檔案裡卻找不到,代表索引過時——回 'UnknownSectionId' 而不是
-- 'EntityNotFound':資料沒有不見,是索引跟不上。
currentMeta :: FilePath -> Id -> Maybe Text -> EntityFile -> Either StoreError Meta
currentMeta rel i anchor ef = case anchor of
  Nothing
    | metaId (entMeta (efMain ef)) == i -> Right (entMeta (efMain ef))
    | otherwise -> stale
  Just _ -> case [entMeta e | e <- efFragments ef, metaId (entMeta e) == i] of
    (m : _) -> Right m
    [] -> stale
  where
    stale = Left (ParseFailed rel [mdError rel 1 (UnknownSectionId i)])

-- | revision +1、@updated@ 改今天。樂觀鎖的另一半:不遞增的話,兩個並發的
-- 寫入拿同一個 revision 都會通過。
bumpOverride :: Int -> Day -> MetaOverride -> MetaOverride
bumpOverride expected today ov =
  ov {moRevision = Just (expected + 1), moUpdated = Just today}

-- ID ---------------------------------------------------------------------------

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
