-- | 單檔索引、全量重建、過時偵測。
--
-- __整檔替換而非逐筆 diff__:一份 @.md@ 的所有 Entity 一起進退。正確性上遠比
-- 「算出哪一節被改了」可靠,而檔案級的重新索引成本本來就很低。
-- 每次 'indexFile' 全程包在一個 transaction 裡:刪 + 插要嘛全成功要嘛全不動,
-- 不會留下「舊記錄刪了、新記錄沒進去」的半殘索引。
--
-- 'refreshStale' 是 ADR-002「檔案被外部改動後索引過時」的答案:每次查詢前跑
-- 一次,成本是對每個檔案做一次 stat。作者用編輯器改完檔案直接查,結果就是新的。
module Aapms.Store.Index
  ( -- * 問題回報
    IndexIssue (..)
  , issueHasError
  , renderIndexIssue

    -- * 單檔
  , indexFile
  , unindexFile

    -- * 全量
  , rebuildIndex

    -- * 過時偵測
  , staleFiles
  , refreshStale

    -- * 開啟索引
  , openVaultIndex

    -- * 掃描
  , vaultMarkdownFiles
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import Data.Int (Int64)
import Data.List (isPrefixOf, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Ref (..), renderId, renderRef)
import Aapms.Core.Level (Level (..), Node (..), renderNodeKind)
import Aapms.Core.Link (Link (..))
import Aapms.Core.Meta (Meta (..))
import Aapms.Md
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Error (StoreError (..), trySqlite)
import Aapms.Store.Row
import Aapms.Store.Schema (closeIndex, openIndex, setVaultInfo)
import Aapms.Store.Vault (Vault (..), vaultAbsPath, vaultRelPath)
import System.Directory
  ( doesDirectoryExist
  , getFileSize
  , getModificationTime
  , listDirectory
  )
import System.FilePath (takeExtension)

-- | 索引一份檔案時遇到的問題。
--
-- 帶 @[MdWarning]@ 是刻意的:@aapms-md@ 是純函式庫,警告只能靠呼叫端輸出,
-- 而索引是唯一會走過 Vault 全部檔案的地方。不在這裡收集,'MissingSummary' /
-- 'CustomLinkKind' / 'EmptyBody' 就永遠不會被作者看到。
data IndexIssue = IndexIssue FilePath [MdError] [MdWarning]
  deriving stock (Show, Eq)

-- | 這筆是「檔案沒進索引」還是「進了但有品質警告」。
issueHasError :: IndexIssue -> Bool
issueHasError (IndexIssue _ es _) = not (null es)

renderIndexIssue :: IndexIssue -> Text
renderIndexIssue (IndexIssue fp es ws) =
  T.intercalate "\n" $
    [T.pack fp <> ":"]
      ++ map (("  錯誤 " <>) . renderMdError) es
      ++ map (("  警告 " <>) . renderMdWarning) ws

-- 掃描 ------------------------------------------------------------------------

-- | Vault 下所有 @.md@ 的相對路徑,排序後回傳。
--
-- __略過所有以 @.@ 開頭的名字__:@.storyflow\/@ 自己的檔案、編輯器的暫存目錄、
-- @.git\/@ 都不該進索引。排序讓重建的插入順序固定,這是「重建後逐筆相同」的前提。
vaultMarkdownFiles :: Vault -> IO [FilePath]
vaultMarkdownFiles v = sort <$> walk ""
  where
    walk rel = do
      names <- listDirectory (if null rel then vaultRoot v else vaultAbsPath v rel)
      concat <$> mapM (visit rel) (sort names)

    visit rel name
      | "." `isPrefixOf` name = pure []
      | otherwise = do
          let child = if null rel then name else rel <> "/" <> name
          isDir <- doesDirectoryExist (vaultAbsPath v child)
          if isDir
            then walk child
            else pure [child | takeExtension name == ".md"]

-- 單檔 ------------------------------------------------------------------------

-- | 一份檔案的索引結果。
data Outcome
  = -- | 進索引了,附帶品質警告
    Indexed [MdWarning]
  | -- | 解析失敗,沒進索引
    Failed [MdError]

-- | 單檔更新:刪掉該檔既有的全部記錄,再插入新的。
--
-- 傳入絕對路徑或 Vault 相對路徑皆可。解析失敗回 'ParseFailed';警告在這個
-- 介面上會被丟掉,要收集警告請走 'rebuildIndex' \/ 'refreshStale'。
indexFile :: Connection -> Vault -> FilePath -> IO (Either StoreError ())
indexFile conn v path =
  indexOne conn v (vaultRelPath v path) >>= \case
    Left e -> pure (Left e)
    Right (Failed es) -> pure (Left (ParseFailed (vaultRelPath v path) es))
    Right (Indexed _) -> pure (Right ())

-- | 移除一份檔案的全部索引記錄。@rel@ 是索引中儲存的相對路徑。
--
-- 除了 FTS 之外全部靠 @files@ 的外鍵級聯:@entities@ \/ @levels@ \/ @nodes@ \/
-- @links@ 都指向它,而 @entity_aliases@ \/ @entity_tags@ \/ @node_entities@ \/
-- @fts_map@ 再往下一層級聯。FTS 沒有外鍵,所以要先自己算出 rowid 刪掉。
unindexFile :: Connection -> FilePath -> IO ()
unindexFile conn rel = do
  execute
    conn
    "DELETE FROM entities_fts WHERE rowid IN\
    \ (SELECT m.rowid FROM fts_map m JOIN entities e ON e.id = m.entity_id\
    \  WHERE e.file_path = ?)"
    (Only (T.pack rel))
  execute conn "DELETE FROM files WHERE path = ?" (Only (T.pack rel))

-- | 讀檔 → 解析 → 寫索引。'rebuildIndex' 與 'refreshStale' 共用這一條路徑。
indexOne :: Connection -> Vault -> FilePath -> IO (Either StoreError Outcome)
indexOne conn v rel = do
  let abs_ = vaultAbsPath v rel
  readTextFile abs_ >>= \case
    Left e -> pure (Left e)
    Right txt ->
      statOf abs_ >>= \case
        Left e -> pure (Left e)
        Right (mtime, size) -> case interpret txt of
          Left es -> pure (Right (Failed es))
          Right (ws, write) -> do
            r <- trySqlite . withTransaction conn $ do
              unindexFile conn rel
              -- 讓連線自己知道屬於哪個 Vault:lookupEntity 要回讀檔案,
              -- 而它的簽名只有 Connection
              setVaultInfo conn v
              execute
                conn
                "INSERT INTO files(path, mtime, size) VALUES (?, ?, ?)"
                (T.pack rel, mtime, size)
              write
            pure (fmap (const (Indexed ws)) r)
  where
    -- MdError 裡帶的是相對路徑:索引與訊息都以 Vault 為原點才對得起來
    interpret :: Text -> Either [MdError] ([MdWarning], IO ())
    interpret txt = do
      doc <- parseDocument rel txt
      documentKind doc >>= \case
        DocEntity -> do
          (ef, ws) <- parseEntityFile doc
          pure (ws, writeEntityFile conn v rel ef)
        DocLevel -> do
          (lf, ws) <- parseLevelFile doc
          pure (ws, writeLevelFile conn v rel lf)

writeEntityFile :: Connection -> Vault -> FilePath -> EntityFile -> IO ()
writeEntityFile conn v rel EntityFile {..} = do
  -- 檔案層主體沒有 section_anchor:它的 meta 在 frontmatter,不在任何一節
  insertEntity conn v rel Nothing efMain
  forM_ efFragments $ \e ->
    insertEntity conn v rel (Just (renderId (metaId (entMeta e)))) e

writeLevelFile :: Connection -> Vault -> FilePath -> LevelFile -> IO ()
writeLevelFile conn v rel LevelFile {..} = do
  insertLevel conn v rel lfLevel
  forM_ lfNodes (insertNode conn v rel)

insertEntity :: Connection -> Vault -> FilePath -> Maybe Text -> Entity -> IO ()
insertEntity conn v rel anchor (Entity meta body) = do
  execute
    conn
    (insertSql "entities" (metaColumnList ++ ["file_path", "section_anchor"]))
    (metaFields meta ++ [sText (T.pack rel), sMaybeText anchor])
  forM_ (metaAliases meta) $ \a ->
    execute conn "INSERT INTO entity_aliases(entity_id, alias) VALUES (?, ?)" (idText, a)
  forM_ (metaTags meta) $ \t ->
    execute conn "INSERT INTO entity_tags(entity_id, tag) VALUES (?, ?)" (idText, t)
  insertLinks conn v rel meta
  -- FTS5 的 rowid 是整數,先進 fts_map 拿到 rowid 再寫 FTS 表
  execute conn "INSERT INTO fts_map(entity_id) VALUES (?)" (Only idText)
  rowid <- lastInsertRowId conn
  execute
    conn
    "INSERT INTO entities_fts(rowid, title, summary, body, aliases, tags)\
    \ VALUES (?, ?, ?, ?, ?, ?)"
    ( rowid
    , metaTitle meta
    , metaSummary meta
    , body
    , T.unwords (metaAliases meta)
    , T.unwords (metaTags meta)
    )
  where
    idText = renderId (metaId meta)

insertLevel :: Connection -> Vault -> FilePath -> Level -> IO ()
insertLevel conn v rel (Level meta root) = do
  execute
    conn
    (insertSql "levels" (metaColumnList ++ ["root", "file_path"]))
    (metaFields meta ++ [sText (renderId root), sText (T.pack rel)])
  insertLinks conn v rel meta

insertNode :: Connection -> Vault -> FilePath -> Node -> IO ()
insertNode conn v rel Node {..} = do
  execute
    conn
    ( insertSql
        "nodes"
        ( metaColumnList
            ++ ["level_id", "parent_id", "order_idx", "kind", "file_path", "section_anchor"]
        )
    )
    ( metaFields nodMeta
        ++ [ sText (renderId nodLevel)
           , sMaybeText (renderId <$> nodParent)
           , sInt nodOrder
           , sText (renderNodeKind nodKind)
           , sText (T.pack rel)
           , sText (renderId (metaId nodMeta))
           ]
    )
  forM_ nodEntities $ \r ->
    execute
      conn
      "INSERT INTO node_entities(node_id, entity_id) VALUES (?, ?)"
      (renderId (metaId nodMeta), renderRef (localize v r))
  insertLinks conn v rel nodMeta

insertLinks :: Connection -> Vault -> FilePath -> Meta -> IO ()
insertLinks conn v rel meta =
  forM_ (metaLinks meta) $ \l ->
    execute
      conn
      (insertSql "links" ["src", "dst_vault", "dst", "kind", "note", "file_path"])
      (linkFields (metaId meta) l {linkTarget = localize v (linkTarget l)} rel)

-- | 指向本 Vault 的參照一律去掉 vault 前綴,否則 @liftgame:ent-7f3a@ 與
-- @ent-7f3a@ 會變成反向查詢互相看不見的兩個東西。
localize :: Vault -> Ref -> Ref
localize v r
  | refVault r == Just (vaultName v) = r {refVault = Nothing}
  | otherwise = r

insertSql :: Text -> [Text] -> Query
insertSql table cols =
  Query $
    "INSERT INTO "
      <> table
      <> "("
      <> T.intercalate ", " cols
      <> ") VALUES ("
      <> T.intercalate ", " (replicate (length cols) "?")
      <> ")"

-- 全量重建 ---------------------------------------------------------------------

-- | 掃描 Vault 下所有 @.md@ 並從零建立索引。
--
-- __單檔解析失敗不中斷__:作者手改壞一份檔案不該讓整個索引建不起來,問題收集
-- 成 'IndexIssue' 一次回報。SQLite 層的錯誤則會中止——那不是資料的問題。
rebuildIndex :: Connection -> Vault -> IO (Either StoreError [IndexIssue])
rebuildIndex conn v = do
  wiped <- trySqlite . withTransaction conn $ do
    execute_ conn "DELETE FROM entities_fts"
    -- 其餘全部靠 files 的外鍵級聯
    execute_ conn "DELETE FROM files"
  case wiped of
    Left e -> pure (Left e)
    Right () -> do
      files <- vaultMarkdownFiles v
      indexEach conn v files

-- | 逐檔索引並收集問題。任何 'StoreError' 都直接中止。
indexEach :: Connection -> Vault -> [FilePath] -> IO (Either StoreError [IndexIssue])
indexEach conn v files = go files []
  where
    go [] acc = pure (Right (reverse acc))
    go (f : rest) acc =
      indexOne conn v f >>= \case
        Left e -> pure (Left e)
        Right (Failed es) -> go rest (IndexIssue f es [] : acc)
        Right (Indexed []) -> go rest acc
        Right (Indexed ws) -> go rest (IndexIssue f [] ws : acc)

-- 過時偵測 ---------------------------------------------------------------------

-- | 磁碟上有改動(或索引裡還沒有)的檔案。回傳 Vault 相對路徑。
staleFiles :: Connection -> Vault -> IO [FilePath]
staleFiles conn v = fst <$> diffFiles conn v

-- | 對過時的檔案逐一重新索引,並移除磁碟上已不存在的檔案記錄。
refreshStale :: Connection -> Vault -> IO (Either StoreError [IndexIssue])
refreshStale conn v = do
  (stale, gone) <- diffFiles conn v
  removed <-
    if null gone
      then pure (Right ())
      else trySqlite (withTransaction conn (mapM_ (unindexFile conn) gone))
  case removed of
    Left e -> pure (Left e)
    Right () -> indexEach conn v stale

-- | (需要重新索引的檔案, 索引裡有但磁碟上已消失的檔案)。
diffFiles :: Connection -> Vault -> IO ([FilePath], [FilePath])
diffFiles conn v = do
  rows <- query_ conn "SELECT path, mtime, size FROM files" :: IO [(Text, Int64, Int64)]
  disk <- vaultMarkdownFiles v
  let known = M.fromList [(T.unpack p, (m, s)) | (p, m, s) <- rows]
      diskSet = S.fromList disk
      gone = [p | p <- M.keys known, not (S.member p diskSet)]
  stale <- forM disk $ \rel -> do
    changed <- case M.lookup rel known of
      Nothing -> pure True -- 索引裡還沒有這一份
      Just (m, s) ->
        statOf (vaultAbsPath v rel) >>= \case
          Left _ -> pure True
          Right (m', s') -> pure (m /= m' || s /= s')
    pure [rel | changed]
  pure (concat stale, gone)

-- 開啟索引 ---------------------------------------------------------------------

-- | 開啟 Vault 的索引,並把過時的檔案補上。
--
-- 這是 @service@(P2)該用的進入點。'Aapms.Store.Schema.openIndex' 只保證
-- schema 是對的版本;版本不符時 schema 被重建、@files@ 表變空,於是這裡的
-- 'refreshStale' 會把整個 Vault 重新索引一次——「schema 變更不寫遷移程式」
-- 這條決策的最後一段就落在這裡。
openVaultIndex :: Vault -> IO (Either StoreError (Connection, [IndexIssue]))
openVaultIndex v =
  openIndex v >>= \case
    Left e -> pure (Left e)
    Right conn ->
      refreshStale conn v >>= \case
        Left e -> closeIndex conn >> pure (Left e)
        Right issues -> pure (Right (conn, issues))

-- 檔案輔助 ---------------------------------------------------------------------

-- | 過時偵測的兩個依據。mtime 取__奈秒__:同一秒內改兩次是測試與人手都做得到的事,
-- 秒級解析度會漏掉。
statOf :: FilePath -> IO (Either StoreError (Int64, Int64))
statOf fp = do
  r <- try act :: IO (Either IOException (Int64, Int64))
  pure $ case r of
    Left e -> Left (FileReadFailed fp (T.pack (show e)))
    Right x -> Right x
  where
    act = do
      t <- getModificationTime fp
      s <- getFileSize fp
      pure (floor (utcTimeToPOSIXSeconds t * 1e9), fromIntegral s)
