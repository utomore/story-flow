-- | 條件查詢、關聯查詢、FTS5 檢索。
--
-- 'linksTo' 是索引存在的主要理由之一:關聯只存在來源端(ADR-0002),檔案裡
-- 查不到「誰指向我」,只有索引做得到反向查詢。
--
-- 'lookupEntity' 的 @body@ __回讀檔案__而不從索引拿:正文可能很長,不該在
-- 可丟棄的索引裡再存一份權威副本。索引只需要能__搜到__它。
module StoryFlow.Store.Query
  ( -- * 過濾條件
    EntityFilter (..)
  , emptyFilter

    -- * 查詢
  , lookupEntity
  , listEntities
  , lookupLevel

    -- * 關聯
  , linksFrom
  , linksTo
  , loadLinkGraph

    -- * 檢索
  , searchEntities
  ) where

import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Graph (LinkGraph)
import StoryFlow.Core.Id (Id, Ref (..), parseId, parseRef, renderId)
import StoryFlow.Core.Level (Level (..), Node (..), parseNodeKind)
import StoryFlow.Core.Link (Link)
import StoryFlow.Core.Meta (Meta (..), Status, renderStatus)
import StoryFlow.Md
import StoryFlow.Store.Atomic (readTextFile)
import StoryFlow.Store.Row
import StoryFlow.Store.Schema (vaultRootOf)
import System.FilePath ((</>))

data EntityFilter = EntityFilter
  { efType :: Maybe Text
  , efStatus :: Maybe Status
  , efTag :: Maybe Text
  , efLimit :: Maybe Int
  }
  deriving stock (Show, Eq)

emptyFilter :: EntityFilter
emptyFilter = EntityFilter Nothing Nothing Nothing Nothing

-- 條件組裝 ---------------------------------------------------------------------

-- | 過濾條件 → SQL 片段 + 參數。@e@ 是 @entities@ 在該查詢裡的別名。
--
-- 一律走參數化查詢:@efTag@ 之類的值可能來自 CLI 或 API,字串拼接就是注入。
whereOf :: Text -> EntityFilter -> (Text, [SQLData])
whereOf alias EntityFilter {..} = (T.concat (map fst parts), concatMap snd parts)
  where
    col c = alias <> "." <> c
    parts =
      concat
        [ [(" AND " <> col "type" <> " = ?", [sText t]) | Just t <- [efType]]
        , [(" AND " <> col "status" <> " = ?", [sText (renderStatus s)]) | Just s <- [efStatus]]
        ,
          [ ( " AND EXISTS (SELECT 1 FROM entity_tags g WHERE g.entity_id = "
                <> col "id"
                <> " AND g.tag = ?)"
            , [sText tag]
            )
          | Just tag <- [efTag]
          ]
        ]

limitOf :: EntityFilter -> (Text, [SQLData])
limitOf EntityFilter {..} = case efLimit of
  Just n -> (" LIMIT ?", [sInt n])
  Nothing -> ("", [])

-- 查詢 ------------------------------------------------------------------------

-- | 不含 body。清單畫面不需要正文,也不該為了列表把每一份檔案都讀一遍。
listEntities :: Connection -> EntityFilter -> IO [Meta]
listEntities conn filt = do
  let (cond, condArgs) = whereOf "e" filt
      (lim, limArgs) = limitOf filt
  ids <-
    query
      conn
      (Query ("SELECT e.id FROM entities e WHERE 1 = 1" <> cond <> " ORDER BY e.id" <> lim))
      (condArgs ++ limArgs) ::
      IO [Only Text]
  metasInOrder conn [t | Only t <- ids]

-- | 含 body。'section_anchor' 決定要拿檔案層主體還是某一節。
lookupEntity :: Connection -> Id -> IO (Maybe Entity)
lookupEntity conn i = do
  rows <-
    query
      conn
      "SELECT file_path, section_anchor FROM entities WHERE id = ?"
      (Only (renderId i)) ::
      IO [(Text, Maybe Text)]
  case rows of
    [] -> pure Nothing
    ((fp, anchor) : _) ->
      vaultRootOf conn >>= \case
        Nothing -> pure Nothing
        Just root ->
          readTextFile (root </> T.unpack fp) >>= \case
            Left _ -> pure Nothing
            Right txt -> pure (pick anchor (T.unpack fp) txt)
  where
    pick anchor rel txt = do
      doc <- ok (parseDocument rel txt)
      (ef, _) <- ok (parseEntityFile doc)
      case anchor of
        Nothing -> Just (efMain ef)
        Just _ -> case [e | e <- efFragments ef, metaId (entMeta e) == i] of
          (e : _) -> Just e
          [] -> Nothing

    ok :: Either [MdError] a -> Maybe a
    ok = either (const Nothing) Just

-- | Level 與它的全部 Node,依文件順序。
lookupLevel :: Connection -> Id -> IO (Maybe (Level, [Node]))
lookupLevel conn i = do
  rows <-
    query
      conn
      (Query ("SELECT " <> metaColumns <> ", root, file_path FROM levels WHERE id = ?"))
      (Only (renderId i)) ::
      IO [LevelRow]
  case rows of
    [] -> pure Nothing
    (LevelRow mr root _ : _) -> do
      meta <- hydrate conn mr
      nodeRows <-
        query
          conn
          ( Query
              ( "SELECT "
                  <> metaColumns
                  <> ", level_id, parent_id, order_idx, kind, file_path, section_anchor\
                     \ FROM nodes WHERE level_id = ? ORDER BY rowid"
              )
          )
          (Only (renderId i)) ::
          IO [NodeRow]
      nodes <- mapM (toNode conn) nodeRows
      pure $ do
        m <- meta
        r <- idOf root
        pure (Level m r, mapMaybe id nodes)
  where
    idOf t = either (const Nothing) (Just . snd) (parseId t)

toNode :: Connection -> NodeRow -> IO (Maybe Node)
toNode conn (NodeRow mr levelId parentId order kind _ _) = do
  meta <- hydrate conn mr
  refs <-
    query
      conn
      "SELECT entity_id FROM node_entities WHERE node_id = ? ORDER BY rowid"
      (Only (mrId mr)) ::
      IO [Only Text]
  pure $ do
    m <- meta
    lvl <- idOf levelId
    k <- either (const Nothing) Just (parseNodeKind kind)
    pure
      Node
        { nodMeta = m
        , nodLevel = lvl
        , nodParent = parentId >>= idOf
        , nodOrder = order
        , nodKind = k
        , nodEntities = mapMaybe (refOf . fromOnly) refs
        }
  where
    idOf t = either (const Nothing) (Just . snd) (parseId t)
    refOf t = either (const Nothing) Just (parseRef t)

-- 關聯 ------------------------------------------------------------------------

linksFrom :: Connection -> Id -> IO [Link]
linksFrom conn i = do
  rows <-
    query
      conn
      "SELECT src, dst_vault, dst, kind, note FROM links WHERE src = ? ORDER BY rowid"
      (Only (renderId i)) ::
      IO [LinkRow]
  pure (map snd (mapMaybe toLink rows))

-- | 反向查詢:誰指向我。
--
-- 本 Vault 的參照在索引時已把 @dst_vault@ 正規化成 @NULL@,所以查本地 id
-- 用 @IS NULL@ 而不是等於自己的 vault 名稱。
linksTo :: Connection -> Ref -> IO [(Id, Link)]
linksTo conn (Ref mv i) = do
  rows <- case mv of
    Nothing ->
      query
        conn
        "SELECT src, dst_vault, dst, kind, note FROM links\
        \ WHERE dst = ? AND dst_vault IS NULL ORDER BY rowid"
        (Only (renderId i))
    Just vname ->
      query
        conn
        "SELECT src, dst_vault, dst, kind, note FROM links\
        \ WHERE dst = ? AND dst_vault = ? ORDER BY rowid"
        (renderId i, vname)
  pure (mapMaybe toLink (rows :: [LinkRow]))

-- | 整張關聯圖,餵給 @core@ 的 'StoryFlow.Core.Graph' 純函式。
--
-- 直接由 @links@ 表組,不經過 'Meta':Entity / Level / Node 的關聯都在同一張
-- 表裡,一次查完比先撈三種實體再合併簡單得多。
loadLinkGraph :: Connection -> IO LinkGraph
loadLinkGraph conn = do
  rows <-
    query_ conn "SELECT src, dst_vault, dst, kind, note FROM links ORDER BY rowid" ::
      IO [LinkRow]
  pure (M.fromListWith (flip (++)) [(s, [l]) | (s, l) <- mapMaybe toLink rows])

-- 檢索 ------------------------------------------------------------------------

-- | FTS5 檢索,回傳 (Meta, 命中片段)。
--
-- 兩條路徑:
--
-- * 三個字元以上走 trigram MATCH。使用者輸入被包成 phrase query 並跳脫內部的
--   雙引號,@OR@ \/ @NEAR@ \/ @*@ 因此是字面而不是語法
-- * __兩個字元以下走 LIKE 掃描__。trigram 以三字元為索引單位,「織紋」這種
--   二字詞 MATCH 一定不命中(func-0001 已驗證這個限制),而角色名與道具名
--   常常就是兩個字——這是本層必須自己補的那一段
searchEntities :: Connection -> Text -> EntityFilter -> IO [(Meta, Text)]
searchEntities conn raw filt
  | T.null needle = pure []
  | T.length needle >= 3 = run ftsQuery [sText (phrase needle)]
  | otherwise = run likeQuery (replicate 5 (sText likePattern))
  where
    needle = T.strip raw

    (cond, condArgs) = whereOf "e" filt
    (lim, limArgs) = limitOf filt

    run sql args = do
      rows <- query conn (Query sql) (args ++ condArgs ++ limArgs) :: IO [(Text, Text)]
      metas <- metasInOrder conn (map fst rows)
      let byId = M.fromList [(renderId (metaId m), m) | m <- metas]
      pure [(m, snip) | (i, snip) <- rows, Just m <- [M.lookup i byId]]

    ftsQuery =
      "SELECT m.entity_id, snippet(entities_fts, -1, '[', ']', '…', 12)\
      \ FROM entities_fts\
      \ JOIN fts_map m ON m.rowid = entities_fts.rowid\
      \ JOIN entities e ON e.id = m.entity_id\
      \ WHERE entities_fts MATCH ?"
        <> cond
        <> " ORDER BY rank"
        <> lim

    -- LIKE 走的是全表掃描,但只有二字詞會落到這裡,而索引本來就是單機規模
    likeQuery =
      "SELECT m.entity_id,\
      \ CASE WHEN f.title LIKE ? ESCAPE '\\' THEN f.title\
      \      WHEN f.summary LIKE ? ESCAPE '\\' THEN f.summary\
      \      WHEN f.body LIKE ? ESCAPE '\\' THEN f.body\
      \      WHEN f.aliases LIKE ? ESCAPE '\\' THEN f.aliases\
      \      ELSE f.tags END\
      \ FROM entities_fts f\
      \ JOIN fts_map m ON m.rowid = f.rowid\
      \ JOIN entities e ON e.id = m.entity_id\
      \ WHERE (f.title || ' ' || f.summary || ' ' || f.body || ' ' || f.aliases\
      \        || ' ' || f.tags) LIKE ? ESCAPE '\\'"
        <> cond
        <> " ORDER BY e.id"
        <> lim

    likePattern = "%" <> escapeLike needle <> "%"

-- | 包成 phrase query。FTS5 的雙引號字串裡,字面雙引號寫成兩個。
phrase :: Text -> Text
phrase t = "\"" <> T.replace "\"" "\"\"" t <> "\""

escapeLike :: Text -> Text
escapeLike =
  T.replace "%" "\\%" . T.replace "_" "\\_" . T.replace "\\" "\\\\"

-- 組裝 ------------------------------------------------------------------------

-- | 依給定的 id 順序取回 'Meta'(含 tags \/ aliases \/ links)。
--
-- 一次把三張附屬表都撈回來再分組,而不是每個 Entity 各查三次——後者就是
-- 典型的 N+1。
metasInOrder :: Connection -> [Text] -> IO [Meta]
metasInOrder _ [] = pure []
metasInOrder conn ids = do
  rows <-
    query
      conn
      (Query ("SELECT " <> metaColumns <> ", file_path, section_anchor FROM entities WHERE id IN " <> inList (length ids)))
      (map sText ids) ::
      IO [EntityRow]
  tags <- grouped "SELECT entity_id, tag FROM entity_tags WHERE entity_id IN "
  aliases <- grouped "SELECT entity_id, alias FROM entity_aliases WHERE entity_id IN "
  linkRows <-
    query
      conn
      (Query ("SELECT src, dst_vault, dst, kind, note FROM links WHERE src IN " <> inList (length ids) <> " ORDER BY rowid"))
      (map sText ids) ::
      IO [LinkRow]
  let links = groupPairs [(renderId s, [l]) | (s, l) <- mapMaybe toLink linkRows]
      byId =
        M.fromList
          [ (mrId mr, m)
          | EntityRow mr _ _ <- rows
          , Just m <-
              [ toMeta
                  mr
                  (M.findWithDefault [] (mrId mr) tags)
                  (M.findWithDefault [] (mrId mr) aliases)
                  (M.findWithDefault [] (mrId mr) links)
              ]
          ]
  pure (mapMaybe (`M.lookup` byId) ids)
  where
    grouped sql = do
      rows <- query conn (Query (sql <> inList (length ids) <> " ORDER BY rowid")) (map sText ids)
      pure (groupPairs [(k, [v]) | (k, v) <- rows])

-- | 單一 'MetaRow' 的附屬欄位補齊。給 Level \/ Node 用——它們一次只查一筆。
hydrate :: Connection -> MetaRow -> IO (Maybe Meta)
hydrate conn mr = do
  tags <- col "SELECT tag FROM entity_tags WHERE entity_id = ?"
  aliases <- col "SELECT alias FROM entity_aliases WHERE entity_id = ?"
  linkRows <-
    query
      conn
      "SELECT src, dst_vault, dst, kind, note FROM links WHERE src = ? ORDER BY rowid"
      (Only (mrId mr)) ::
      IO [LinkRow]
  pure (toMeta mr tags aliases (map snd (mapMaybe toLink linkRows)))
  where
    col sql = do
      rows <- query conn (Query sql) (Only (mrId mr)) :: IO [Only Text]
      pure (map fromOnly rows)

groupPairs :: [(Text, [a])] -> M.Map Text [a]
groupPairs = foldl' (\m (k, v) -> M.insertWith (flip (++)) k v m) M.empty

inList :: Int -> Text
inList n = "(" <> T.intercalate ", " (replicate n "?") <> ")"
