-- | 單檔索引、全量重建、過時偵測(graph-core\/F006)。
--
-- __整檔替換而非逐筆 diff__:一份 @.md@ 的所有節點一起進退。正確性上遠比
-- 「算出哪一節被改了」可靠,而檔案級的重新索引成本本來就很低。每次
-- @indexOne@(內部)全程包在一個 SQLite transaction 裡:刪 + 插要嘛全成功要嘛
-- 全不動,不會留下「舊記錄刪了、新記錄沒進去」的半殘索引。
--
-- 'refreshStale' 是 ADR-002「檔案被外部改動後索引過時」的答案:比對 @files@
-- 表的 mtime\/size 與磁碟現況,只重讀真的變了的檔案。
--
-- ADR-022(寫鎖預算)合規性:讀檔('Aapms.Store.Atomic.readTextFile')、
-- @stat@、@parseDocument@\/@to*@\/@buildTree@\/@checkMeta@ 等純函式解析全部在
-- 交易__外__先算完;交易內只有已經算好的 'Database.SQLite.Simple.SQLData' 的
-- INSERT\/DELETE,不重算、不做檔案 IO。'rebuildIndex'\/'refreshStale' 對每個
-- 檔案各自開一個短交易,不是整個 vault 一個大交易。
--
-- __A1(委派已裁決,契約 E 改為 @openVault :: TypeRegistry -> FilePath -> ...@、
-- 'Aapms.Store.Marker.VaultHandle' 新增 'Aapms.Store.Marker.vhRegistry')__:
-- 因此本模組__完整實作__兩條驗收標準——'Aapms.Core.Tree.buildTree' 的錯誤進
-- 'Aapms.Store.Schema.TreeInvalid'(整檔不進索引),
-- 'Aapms.Core.Registry.checkMeta' 的警告進
-- 'Aapms.Store.Schema.MetaWarningsFound'(__不__擋索引——'checkMeta' 本身的
-- 契約是「只回警告,不決定要不要擋」,節點正常寫入,警告附帶回報)。
module Aapms.Store.Index
  ( -- * 單檔
    indexFile
  , unindexFile

    -- * 全量
  , rebuildIndex

    -- * 過時偵測
  , refreshStale

    -- * 內部(測試用)
  , vaultMarkdownFiles
  , statOf
  ) where

import Control.Exception (Exception, IOException, throwIO, try)
import Control.Monad (forM, forM_)
import Data.Int (Int64)
import Data.List (isPrefixOf, sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple
import Aapms.Core.AnyNode (AnyNode (..), anyMeta)
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id (Id, IdPrefix (..), Ref (..), VaultId (..), renderId, renderRef)
import Aapms.Core.Level (Level (..), Node (..), renderNodeKind)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Core.Registry (TypeRegistry, checkMeta)
import Aapms.Core.Tree (buildTree)
import Aapms.Md.Document (DocKind (..), Document, docKind)
import Aapms.Md.Parse (parseDocument, toLevel, toLicenses, toPack, toTopic)
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Error (StoreError (..), trySqlite)
import Aapms.Store.Marker (VaultHandle (..))
import Aapms.Store.Row
import Aapms.Store.Schema (IndexIssue (..), insertFtsRows)
import Aapms.Store.Tokenize (ftsRowOf)
import System.Directory
  ( doesDirectoryExist
  , getFileSize
  , getModificationTime
  , listDirectory
  )
import System.FilePath ((</>), isAbsolute, makeRelative, takeExtension)
import System.Directory (makeAbsolute)

-- 掃描 ------------------------------------------------------------------------

-- | Vault 根目錄下所有 @.md@ 的相對路徑(以 @/@ 分隔,不受平台影響),
-- 排序後回傳。__略過所有以 @.@ 開頭的名字__:@.aapms\/@ 自己的檔案、編輯器的
-- 暫存目錄、@.git\/@ 都不該進索引。排序讓重建的插入順序固定,這是「重建後
-- 逐筆相同」的前提,同時也是待確認假設 A2(@assets.name@ 撞名時誰保留)的
-- 依據。
vaultMarkdownFiles :: FilePath -> IO [FilePath]
vaultMarkdownFiles root = sort <$> walk ""
  where
    walk rel = do
      let dir = if null rel then root else root </> rel
      names <- listDirectory dir
      concat <$> mapM (visit rel) (sort names)

    visit rel name
      | "." `isPrefixOf` name = pure []
      | otherwise = do
          let relChild = if null rel then name else rel <> "/" <> name
          isDir <- doesDirectoryExist (root </> relChild)
          if isDir
            then walk relChild
            else pure [relChild | takeExtension name == ".md"]

-- | 過時偵測的兩個依據。mtime 取__奈秒__:同一秒內改兩次是測試與人手都做得到
-- 的事,秒級解析度會漏掉。
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

-- | 給定路徑(絕對或 vault 相對皆可)轉成索引裡儲存用的 vault 相對路徑
-- (@/@ 分隔)。
toVaultRelative :: VaultHandle -> FilePath -> IO Text
toVaultRelative vh given = do
  rel <-
    if isAbsolute given
      then do
        root <- makeAbsolute (vhRoot vh)
        absGiven <- makeAbsolute given
        pure (makeRelative root absGiven)
      else pure given
  pure (T.pack (map slash rel))
  where
    slash '\\' = '/'
    slash c = c

-- 單檔 ------------------------------------------------------------------------

-- | 內部例外:@assets.name UNIQUE@ 撞名,用來讓 'indexOne' 的 transaction
-- 整個回滾(不能用 'Either' 表達——一旦 SQLite 已經開始寫,只有拋例外能讓
-- @withTransaction@ 自動 ROLLBACK)。永遠在 'indexOne' 內被接住,不會外洩。
newtype DuplicateAssetNameException = DuplicateAssetNameException LogicalName
  deriving stock (Show)

instance Exception DuplicateAssetNameException

-- | 接受絕對路徑或 vault 相對路徑。回傳的 'IndexIssue' 清單可能是「整檔不進
-- 索引的理由」(0 或 1 筆:'Aapms.Store.Schema.ParseFailed' \/
-- 'Aapms.Store.Schema.TreeInvalid' \/ 'Aapms.Store.Schema.DuplicateAssetName')
-- __或__「已正常進索引、但有 @checkMeta@ 警告」(0 筆以上的
-- 'Aapms.Store.Schema.MetaWarningsFound',不互斥於前者以外的情況——見
-- 'indexOne' 的說明)。
indexFile :: VaultHandle -> FilePath -> IO (Either StoreError [IndexIssue])
indexFile vh given = do
  rel <- toVaultRelative vh given
  indexOne vh rel

-- | 移除一份檔案的全部索引記錄。外鍵級聯清掉其餘全部(見 Schema 的說明)。
-- 找不到該路徑的記錄不是錯誤(冪等)。
unindexFile :: VaultHandle -> FilePath -> IO (Either StoreError ())
unindexFile vh given = do
  rel <- toVaultRelative vh given
  trySqlite (execute (vhConn vh) "DELETE FROM files WHERE path = ?" (Only rel))

-- | 讀檔 → 解析 → 一個 transaction 內刪舊插新。'rebuildIndex' 與 'refreshStale'
-- 共用這一條路徑。
--
-- 回傳的 @[IndexIssue]@ 有兩種情況,由第一個元素的建構子分辨:
--
-- * @[ParseFailed _]@ \/ @[TreeInvalid _ _]@ \/ @[DuplicateAssetName _ _]@:
--   整檔__不__進索引,清單恰有一筆
-- * 其餘(可能是 @[]@,可能是零到多筆 @MetaWarningsFound@):檔案__已經__
--   正常進索引,清單是 @checkMeta@ 對檔案內每個節點的警告(空清單 = 沒有
--   警告)
indexOne :: VaultHandle -> Text -> IO (Either StoreError [IndexIssue])
indexOne vh rel = do
  let absPath = vhRoot vh </> T.unpack rel
      relStr = T.unpack rel
  readTextFile absPath >>= \case
    Left e -> pure (Left e)
    Right txt -> statOf absPath >>= \case
      Left e -> pure (Left e)
      Right (mtime, size) -> case parseDocument txt of
        Left mdErr -> pure (Right [ParseFailed relStr mdErr])
        Right doc -> case planWrite (vhRegistry vh) relStr doc of
          Left issue -> pure (Right [issue])
          Right (kind, warnings, anyNodes, action) -> do
            outcome <-
              try
                ( trySqlite . withTransaction (vhConn vh) $ do
                    execute (vhConn vh) "DELETE FROM files WHERE path = ?" (Only rel)
                    execute
                      (vhConn vh)
                      "INSERT INTO files(path, mtime, size, doc_kind) VALUES (?, ?, ?, ?)"
                      (rel, mtime, size, renderDocKind kind)
                    action (vhConn vh) rel
                    -- graph-core/F007:FTS 列與節點列同一個交易內一起進退,
                    -- 不會出現「節點在、FTS 沒進」的半殘狀態。純函式的預切
                    -- ('ftsRowOf')已經在交易外算完(ADR-022),這裡只是落地。
                    insertFtsRows (vhConn vh) (map ftsRowOf anyNodes)
                ) ::
                IO (Either DuplicateAssetNameException (Either StoreError ()))
            pure $ case outcome of
              Left (DuplicateAssetNameException nm) -> Right [DuplicateAssetName relStr nm]
              Right (Left e) -> Left e
              Right (Right ()) -> Right warnings

-- | 把 'parseDocument' 的結果轉成「這是哪種文件、@checkMeta@ 警告、要執行的
-- 寫入動作」。@LevelDoc@ 額外跑 'buildTree' 驗證;兩者都是純函式,交易外執行
-- (ADR-022)。
-- | 第三個元素是這份文件的全部節點(統一視角),graph-core\/F007 用來算
-- 'Aapms.Store.Tokenize.ftsRowOf' 寫入 FTS——本來只餵給 'metaIssues',現在
-- 一併回傳給 'indexOne'(骨架清單外的接線,委派已授權)。
planWrite
  :: TypeRegistry
  -> FilePath
  -> Document
  -> Either IndexIssue (DocKind, [IndexIssue], [AnyNode], Connection -> Text -> IO ())
planWrite registry relStr doc = case docKind doc of
  TopicDoc -> case toTopic doc of
    Left e -> Left (ParseFailed relStr e)
    Right (mainE, frags) ->
      let anyNodes = NEntity mainE : map NEntity frags
       in Right
            ( TopicDoc
            , metaIssues relStr registry anyNodes
            , anyNodes
            , \conn rel -> writeTopic conn rel mainE frags
            )
  LevelDoc -> case toLevel doc of
    Left e -> Left (ParseFailed relStr e)
    Right (lvl, nodes) -> case buildTree lvl nodes of
      Left errs -> Left (TreeInvalid relStr errs)
      Right _tree ->
        let anyNodes = NLevel lvl : map NNode nodes
         in Right
              ( LevelDoc
              , metaIssues relStr registry anyNodes
              , anyNodes
              , \conn rel -> writeLevel conn rel lvl nodes
              )
  PackDoc -> case toPack doc of
    Left e -> Left (ParseFailed relStr e)
    Right (pck, assets) ->
      let anyNodes = NPack pck : map NAsset assets
       in Right
            ( PackDoc
            , metaIssues relStr registry anyNodes
            , anyNodes
            , \conn rel -> writePack conn rel pck assets
            )
  LicenseDoc -> case toLicenses doc of
    Left e -> Left (ParseFailed relStr e)
    Right lics ->
      let anyNodes = map NLicense lics
       in Right
            ( LicenseDoc
            , metaIssues relStr registry anyNodes
            , anyNodes
            , \conn rel -> writeLicenses conn rel lics
            )

-- | 對一份文件的全部節點跑 'checkMeta',收集有警告的節點,轉成
-- 'Aapms.Store.Schema.MetaWarningsFound'。__不影響__索引與否,純附帶回報。
metaIssues :: FilePath -> TypeRegistry -> [AnyNode] -> [IndexIssue]
metaIssues relStr registry nodes =
  [ MetaWarningsFound relStr (metaId (anyMeta n)) ws
  | n <- nodes
  , let ws = checkMeta registry n
  , not (null ws)
  ]

-- 寫入 ------------------------------------------------------------------------

insertNodeRow :: Connection -> Text -> Maybe Id -> Maybe Id -> Meta -> IdPrefix -> IO ()
insertNodeRow conn rel owner anchorId meta prefix = do
  execute
    conn
    (insertSql "nodes" nodeColumnList)
    (nodeFields meta prefix (T.unpack rel) (renderId <$> anchorId) owner)
  insertMetaExtras conn rel meta

insertMetaExtras :: Connection -> Text -> Meta -> IO ()
insertMetaExtras conn rel Meta {..} = do
  let idT = renderId metaId
  forM_ metaAliases $ \a ->
    execute conn "INSERT INTO node_aliases(node_id, alias) VALUES (?, ?)" (idT, a)
  forM_ metaTags $ \t ->
    execute conn "INSERT INTO node_tags(node_id, tag) VALUES (?, ?)" (idT, t)
  forM_ metaLinks $ \Link {..} ->
    execute
      conn
      (insertSql "links" ["src", "dst_vault", "dst", "kind", "note", "file_path"])
      [ sText idT
      , sMaybeText (unVaultId <$> refVault linkTarget)
      , sText (renderId (refId linkTarget))
      , sText (renderLinkKind linkKind)
      , sMaybeText linkNote
      , sText rel
      ]
  where
    unVaultId (VaultId t) = t

writeTopic :: Connection -> Text -> Entity -> [Entity] -> IO ()
writeTopic conn rel mainE frags = do
  insertNodeRow conn rel Nothing Nothing (entMeta mainE) PEnt
  let mainId = metaId (entMeta mainE)
  forM_ frags $ \f ->
    insertNodeRow conn rel (Just mainId) (Just (metaId (entMeta f))) (entMeta f) PEnt

writeLevel :: Connection -> Text -> Level -> [Node] -> IO ()
writeLevel conn rel lvl nodes = do
  let lvlId = metaId (lvlMeta lvl)
  insertNodeRow conn rel Nothing Nothing (lvlMeta lvl) PLvl
  execute
    conn
    (insertSql "levels" (["id"] ++ levelColumnList))
    [sText (renderId lvlId), sText (renderId (lvlRoot lvl))]
  forM_ nodes $ \n -> do
    let nId = metaId (nodMeta n)
    insertNodeRow conn rel Nothing (Just nId) (nodMeta n) PNod
    execute
      conn
      (insertSql "tree_nodes" (["id"] ++ treeNodeColumnList))
      [ sText (renderId nId)
      , sText (renderId (nodLevel n))
      , sMaybeText (renderId <$> nodParent n)
      , sInt (nodOrder n)
      , sText (renderNodeKind (nodKind n))
      ]
    forM_ (nodEntities n) $ \ref ->
      execute
        conn
        "INSERT INTO tree_node_entities(node_id, ref) VALUES (?, ?)"
        (renderId nId, renderRef ref)

writePack :: Connection -> Text -> Pack -> [Asset] -> IO ()
writePack conn rel pck assets = do
  let pckId = metaId (pckMeta pck)
      isRef = isReferencePath (T.unpack rel)
  insertNodeRow conn rel Nothing Nothing (pckMeta pck) PPck
  execute
    conn
    (insertSql "packs" (["id"] ++ packColumnList))
    [ sText (renderId pckId)
    , sMaybeText (pckVendor pck)
    , sMaybeText (T.pack <$> pckArchive pck)
    , sMaybeText (unSha256 <$> pckSha256 pck)
    , sMaybeText (renderRef <$> pckLicense pck)
    , sMaybeText (encodeAuthorJson <$> pckAuthor pck)
    , sMaybeText (pckSourceUrl pck)
    , sText (aiDisclosureText (pckAiDisclosure pck))
    , sBool isRef
    ]
  forM_ assets $ \a -> do
    checkDuplicateName conn (astName a)
    let astId = metaId (astMeta a)
    insertNodeRow conn rel (Just pckId) (Just astId) (astMeta a) PAst
    execute
      conn
      (insertSql "assets" (["id"] ++ assetColumnList))
      [ sText (renderId astId)
      , sMaybeText (unLogicalName <$> astName a)
      , sText (unSha256 (astSha256 a))
      , sText (astEntry a)
      , sMaybeText (astExt a)
      , sText (encodeJsonText (astKindMeta a))
      , sMaybeText (renderRef <$> astLicense a)
      , sMaybeText (astAuthor a)
      ]
  where
    unSha256 (Sha256 t) = t
    unLogicalName (LogicalName t) = t

checkDuplicateName :: Connection -> Maybe LogicalName -> IO ()
checkDuplicateName _ Nothing = pure ()
checkDuplicateName conn (Just nm@(LogicalName t)) = do
  existing <- query conn "SELECT count(*) FROM assets WHERE name = ?" (Only t) :: IO [Only Int]
  case existing of
    (Only n : _) | n > (0 :: Int) -> throwIO (DuplicateAssetNameException nm)
    _ -> pure ()

writeLicenses :: Connection -> Text -> [License] -> IO ()
writeLicenses conn rel lics =
  forM_ lics $ \lic -> do
    let licId = metaId (licMeta lic)
    insertNodeRow conn rel Nothing (Just licId) (licMeta lic) PLic
    execute
      conn
      (insertSql "licenses" (["id"] ++ licenseColumnList))
      [ sText (renderId licId)
      , sBool (licCommercial lic)
      , sBool (licAttributionRequired lic)
      , sMaybeText (licCreditText lic)
      , sMaybeBool (licModificationAllowed lic)
      , sMaybeBool (licRedistributionAllowed lic)
      , sMaybeBool (licResaleAllowed lic)
      , sMaybeBool (licNftAllowed lic)
      , sMaybeText (licSourceUrl lic)
      ]

-- | 「是 reference」由 pack.md 的路徑決定(design.md:在 @library\/reference\/@
-- 之下),索引時算好存進 @packs.is_reference@。
isReferencePath :: FilePath -> Bool
isReferencePath p = "library/reference/" `T.isInfixOf` T.pack (map slash p)
  where
    slash '\\' = '/'
    slash c = c

-- 全量重建 ---------------------------------------------------------------------

-- | 掃描 Vault 下所有 @.md@ 並從零建立索引。__單檔解析\/驗證失敗不中斷__:
-- 作者手改壞一份檔案不該讓整個索引建不起來,問題收集成 'IndexIssue' 一次
-- 回報。SQLite 層的錯誤則會中止——那不是資料的問題。
rebuildIndex :: VaultHandle -> IO (Either StoreError [IndexIssue])
rebuildIndex vh = do
  wiped <- trySqlite (execute_ (vhConn vh) "DELETE FROM files")
  case wiped of
    Left e -> pure (Left e)
    Right () -> do
      files <- vaultMarkdownFiles (vhRoot vh)
      indexEach vh (map T.pack files)

-- | 逐檔索引並收集問題(每個檔案 0 筆以上,見 'indexOne' 的說明)。任何
-- 'StoreError' 都直接中止。
indexEach :: VaultHandle -> [Text] -> IO (Either StoreError [IndexIssue])
indexEach vh = go []
  where
    go acc [] = pure (Right (concat (reverse acc)))
    go acc (f : rest) =
      indexOne vh f >>= \case
        Left e -> pure (Left e)
        Right issues -> go (issues : acc) rest

-- 過時偵測 ---------------------------------------------------------------------

-- | 對過時的檔案逐一重新索引,並移除磁碟上已不存在的檔案記錄。
refreshStale :: VaultHandle -> IO (Either StoreError [IndexIssue])
refreshStale vh = do
  (stale, gone) <- diffFiles vh
  removed <-
    if null gone
      then pure (Right ())
      else trySqlite (withTransaction (vhConn vh) (forM_ gone (removeOne (vhConn vh))))
  case removed of
    Left e -> pure (Left e)
    Right () -> indexEach vh stale
  where
    removeOne conn p = execute conn "DELETE FROM files WHERE path = ?" (Only p)

-- | (需要重新索引的檔案, 索引裡有但磁碟上已消失的檔案),皆為 vault 相對路徑。
diffFiles :: VaultHandle -> IO ([Text], [Text])
diffFiles vh = do
  rows <- query_ (vhConn vh) "SELECT path, mtime, size FROM files" :: IO [(Text, Int64, Int64)]
  disk <- vaultMarkdownFiles (vhRoot vh)
  let known = M.fromList [(p, (m, s)) | (p, m, s) <- rows]
      diskSet = S.fromList (map T.pack disk)
      gone = [p | p <- M.keys known, not (S.member p diskSet)]
  stale <- forM disk $ \relFp -> do
    let relT = T.pack relFp
    changed <- case M.lookup relT known of
      Nothing -> pure True
      Just (m, s) ->
        statOf (vhRoot vh </> relFp) >>= \case
          Left _ -> pure True
          Right (m', s') -> pure (m /= m' || s /= s')
    pure [relT | changed]
  pure (concat stale, gone)
