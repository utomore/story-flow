{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | 'Aapms.Store.Effect.Index.Index' 的__真解譯器__:一個 vault 的 @index.db@。
--
-- 本模組住 shell 層(rules\/boundary.md「四層」):簽名帶 'Effectful.IOE',
-- 效果真的發生在這裡。效果的__描述__住 effects 層
-- ("Aapms.Store.Effect.Index"),純解譯器
-- 'Aapms.Store.Simulate.runIndexPure' 住 pure 層(ADR-023)。
--
-- == 與純解譯器的對照
--
-- 八個操作各自落到既有的 schema("Aapms.Store.Schema"),逐條對照
-- 'Aapms.Store.Simulate.runIndexPure' 的記憶體語意:
--
-- * @ReplaceFile@ \/ @RemoveFile@ 是「整檔進退」:一個路徑一組記錄,以
--   @files@ 表為根、靠外鍵級聯清乾淨(P-001-index-rebuild 的決定)。寫入包在
--   __一個短交易__裡,解析早就在交易外算完(ADR-022)。
-- * @FtsMatch@ 走既有的雙 FTS 與 'Aapms.Store.Query.whereOfIn';分數是
--   @-bm25(表名)@ ——純解譯器固定回 @1.0@,law 只用到「正」與排序鍵
--   (P-002-search 的決定)。
-- * @FilterNodes@ 把符合結構條件的節點列__還原成 'AnyNode'__。正文
--   (@body@)不在 @nodes@ 表裡(design.md「@body@ 進 FTS 但不進 @nodes@」),
--   所以從 @fts_tri.body@ 取——那一欄就是索引時
--   'Aapms.Store.Tokenize.rawFtsText' 寫進去的原文,與呼叫端拿它算片段
--   ('Aapms.Store.Search.snippetFrom')的來源同一份。
-- * @LocateId@ \/ @IdTaken@ \/ @Referrers@ 是寫入路徑的定位、配號碰撞與被引用
--   查詢(P-003-node-write)。
--
-- 'Aapms.Core.Meta.Meta' 的組裝__逐字比照__ "Aapms.Store.Query" 私有的
-- @metasFor@(同樣的三段批次 SQL、同樣的 'Aapms.Store.Row.groupPairs'):
-- @metaTags@ \/ @metaAliases@ \/ @metaLinks@ 是 list 不是 set,換一種組裝方式就
-- 會讓同一份索引 hydrate 出不相等的 'Aapms.Core.Meta.Meta'(這正是
-- "Aapms.Store.MultiVault" 的 @hydrateIds@ 也刻意不用
-- 'Aapms.Store.Row.Sql.hydrateMeta' 的理由)。
module Aapms.Store.Effect.Index.Sqlite
  ( runIndexSqlite
  ) where

import Control.Monad (forM_)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
  ( Connection
  , FromRow (..)
  , Only (..)
  , Query (..)
  , execute
  , field
  , query
  , query_
  , withTransaction
  )
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)

import Aapms.Core.AnyNode (AnyNode (..), anyMeta, prefixOf)
import Aapms.Core.Asset (Asset (..), LogicalName (..), Sha256 (..))
import Aapms.Core.Entity (Entity (..))
import Aapms.Core.Id
  ( Id
  , IdPrefix (..)
  , Ref (..)
  , VaultId (..)
  , idPrefix
  , parseId
  , parseRef
  , renderId
  , renderRef
  )
import Aapms.Core.Level (Level (..), Node (..), parseNodeKind, renderNodeKind)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), renderLinkKind)
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document (DocKind (..))
import Aapms.Store.Effect.Index (Index (..))
import Aapms.Store.Query (baseFromIn, whereOfIn)
import Aapms.Store.Row
import Aapms.Store.Row.Sql
import Aapms.Store.Schema (insertFtsRows)
import Aapms.Store.Tokenize (cjkMatchExpr, ftsRowOf, triMatchExpr)
import Aapms.Store.Types
  ( FileIndex (..)
  , FileStat (..)
  , IndexedNode (..)
  , Located (..)
  , NodeFilter
  , SearchRoute
  , usesCjk
  , usesTrigram
  )

-- | 以 @conn@ 這條連線(一個 vault 的 @index.db@)跑 'Index'。
--
-- 連線由呼叫端持有與關閉:本解譯器不開、不關、不改 PRAGMA(那是
-- 'Aapms.Store.Schema.openIndexAt' 的事)。
runIndexSqlite :: IOE :> es => Connection -> Eff (Index : es) a -> Eff es a
runIndexSqlite conn = interpret $ \_ op -> liftIO $ case op of
  ReplaceFile fi -> replaceFileIn conn fi
  RemoveFile p -> removeFileIn conn p
  FileStats -> fileStatsIn conn
  FtsMatch route txt nf -> ftsMatchIn conn route txt nf
  FilterNodes nf -> filterNodesIn conn nf
  LocateId i -> locateIn conn i
  IdTaken i -> takenIn conn i
  Referrers is -> referrersIn conn is

--------------------------------------------------------------------------------
-- 索引維護(P-001-index-rebuild)

-- | 整檔替換:一個交易內先刪該檔的舊列再插新列。
--
-- 交易內只有已經算好的 'Database.SQLite.Simple.SQLData' 的 INSERT \/ DELETE,
-- 不重算、不做檔案 IO(ADR-022 寫鎖預算);'Aapms.Store.Tokenize.ftsRowOf' 的
-- 預切是純函式,列進去之前就算完了。
--
-- __不做撞名檢查__:「邏輯名稱被路徑字母序更前的檔佔走時整檔回滾」已經由
-- pure 層的 'Aapms.Store.Indexing.indexPath' 在呼叫本操作__之前__裁決完
-- (P-001-index-rebuild LAW-6),真解譯器只負責落地。@assets.name UNIQUE@ 因此
-- 只剩「不該發生」的守門角色;真的撞上會以 SQLite 例外中止,由進入點的
-- 'Aapms.Store.Error.trySqlite' 收成 'Aapms.Store.Types.SqliteError'。
replaceFileIn :: Connection -> FileIndex -> IO ()
replaceFileIn conn fi = withTransaction conn $ do
  execute conn "DELETE FROM files WHERE path = ?" (Only rel)
  execute
    conn
    "INSERT INTO files(path, mtime, size, doc_kind, is_reference) VALUES (?, ?, ?, ?, ?)"
    (rel, fsMtime (fiStat fi), fsSize (fiStat fi), renderDocKind (fiKind fi), refFlag)
  mapM_ (insertIndexedNode conn fi rel) (fiNodes fi)
  insertFtsRows conn (map (ftsRowOf . inNode) (fiNodes fi))
  where
    rel = T.pack (fiPath fi)
    -- P-002-search:reference 是__檔__的屬性,'Aapms.Store.Query.whereOfIn' 的
    -- @referenceClause@ 讀的就是這一欄;純核心已經用路徑算好
    -- ("Aapms.Store.Indexing" 的 @isReferencePath@)。
    refFlag = if fiReference fi then 1 else 0 :: Int

-- | 一個索引節點的 @nodes@ 列、附屬表列與種類專屬表列。
--
-- 三個位置逐一對照舊碼 "Aapms.Store.Index" 的 @insertNodeRow@:owner 就是
-- 'inOwner'(主題檔的片段指向主體、@pack.md@ 的 asset 指向 pack,其餘
-- 'Nothing'),anchor 由 'anchorOf' 判定,prefix 由節點種類給
-- ('Aapms.Core.AnyNode.prefixOf',不從 id 字串反推)。
insertIndexedNode :: Connection -> FileIndex -> Text -> IndexedNode -> IO ()
insertIndexedNode conn fi rel n = do
  execute
    conn
    (insertSql "nodes" nodeColumnList)
    (nodeFields meta (prefixOf node) (T.unpack rel) (renderId <$> anchorOf fi n) (inOwner n))
  insertMetaExtras conn rel meta
  insertKindRow conn fi node
  where
    node = inNode n
    meta = anyMeta node

-- | 錨點:檔案層主體是 'Nothing',其餘是節點自己的 id。
--
-- 判準與 'Aapms.Store.Simulate.runIndexPure' 的 @anchorOf@ 逐字相同(主題檔是
-- 沒有 owner 的那個 'NEntity'、Level 檔是 'NLevel'、@pack.md@ 是 'NPack';
-- @licenses.md@ 的每個授權都是一節,沒有檔案層主體),也就是舊碼 @writeTopic@ \/
-- @writeLevel@ \/ @writePack@ \/ @writeLicenses@ 傳給 @insertNodeRow@ 的
-- @anchorId@。
anchorOf :: FileIndex -> IndexedNode -> Maybe Id
anchorOf fi n
  | isFileBody = Nothing
  | otherwise = Just (metaId (anyMeta (inNode n)))
  where
    isFileBody = case (fiKind fi, inNode n) of
      (TopicDoc, NEntity _) -> isNothing (inOwner n)
      (LevelDoc, NLevel _) -> True
      (PackDoc, NPack _) -> True
      _ -> False

-- | @node_aliases@ \/ @node_tags@ \/ @links@(逐字沿用舊碼的欄位與順序)。
insertMetaExtras :: Connection -> Text -> Meta -> IO ()
insertMetaExtras conn rel meta = do
  forM_ (metaAliases meta) $ \a ->
    execute conn "INSERT INTO node_aliases(node_id, alias) VALUES (?, ?)" (idT, a)
  forM_ (metaTags meta) $ \t ->
    execute conn "INSERT INTO node_tags(node_id, tag) VALUES (?, ?)" (idT, t)
  forM_ (metaLinks meta) $ \l ->
    execute
      conn
      (insertSql "links" ["src", "dst_vault", "dst", "kind", "note", "file_path"])
      [ sText idT
      , sMaybeText (unVaultId <$> refVault (linkTarget l))
      , sText (renderId (refId (linkTarget l)))
      , sText (renderLinkKind (linkKind l))
      , sMaybeText (linkNote l)
      , sText rel
      ]
  where
    idT = renderId (metaId meta)
    unVaultId (VaultId t) = t

-- | 種類專屬表(逐字沿用舊碼 @writeLevel@ \/ @writePack@ \/ @writeLicenses@ 的
-- 欄位與順序)。@packs.is_reference@ 取自這個檔的 'fiReference' ——純核心已經
-- 用路徑算好了("Aapms.Store.Indexing" 的 @isReferencePath@)。
--
-- 這一欄只是 pack 自己的資料,__不是過濾的來源__:'nfIncludeReference' 走的是
-- @files.is_reference@(P-002-search,見 'Aapms.Store.Query.whereOfIn' 的
-- @referenceClause@),兩者由 'replaceFileIn' 從同一個 'fiReference' 寫出。
insertKindRow :: Connection -> FileIndex -> AnyNode -> IO ()
insertKindRow conn fi node = case node of
  NEntity _ -> pure ()
  NLevel lvl ->
    execute
      conn
      (insertSql "levels" ("id" : levelColumnList))
      [sText (renderId (metaId (lvlMeta lvl))), sText (renderId (lvlRoot lvl))]
  NNode nd -> do
    let nId = metaId (nodMeta nd)
    execute
      conn
      (insertSql "tree_nodes" ("id" : treeNodeColumnList))
      [ sText (renderId nId)
      , sText (renderId (nodLevel nd))
      , sMaybeText (renderId <$> nodParent nd)
      , sInt (nodOrder nd)
      , sText (renderNodeKind (nodKind nd))
      ]
    forM_ (nodEntities nd) $ \r ->
      execute
        conn
        "INSERT INTO tree_node_entities(node_id, ref) VALUES (?, ?)"
        (renderId nId, renderRef r)
  NPack pck ->
    execute
      conn
      (insertSql "packs" ("id" : packColumnList))
      [ sText (renderId (metaId (pckMeta pck)))
      , sMaybeText (pckVendor pck)
      , sMaybeText (T.pack <$> pckArchive pck)
      , sMaybeText (unSha256 <$> pckSha256 pck)
      , sMaybeText (renderRef <$> pckLicense pck)
      , sMaybeText (encodeAuthorJson <$> pckAuthor pck)
      , sMaybeText (pckSourceUrl pck)
      , sText (aiDisclosureText (pckAiDisclosure pck))
      , sBool (fiReference fi)
      ]
  NAsset a ->
    execute
      conn
      (insertSql "assets" ("id" : assetColumnList))
      [ sText (renderId (metaId (astMeta a)))
      , sMaybeText (unLogicalName <$> astName a)
      , sText (unSha256 (astSha256 a))
      , sText (astEntry a)
      , sMaybeText (astExt a)
      , sText (encodeJsonText (astKindMeta a))
      , sMaybeText (renderRef <$> astLicense a)
      , sMaybeText (astAuthor a)
      ]
  NLicense lic ->
    execute
      conn
      (insertSql "licenses" ("id" : licenseColumnList))
      [ sText (renderId (metaId (licMeta lic)))
      , sBool (licCommercial lic)
      , sBool (licAttributionRequired lic)
      , sMaybeText (licCreditText lic)
      , sMaybeBool (licModificationAllowed lic)
      , sMaybeBool (licRedistributionAllowed lic)
      , sMaybeBool (licResaleAllowed lic)
      , sMaybeBool (licNftAllowed lic)
      , sMaybeText (licSourceUrl lic)
      ]
  where
    unSha256 (Sha256 t) = t
    unLogicalName (LogicalName t) = t

-- | 移除一個檔案的全部記錄(外鍵級聯清掉其餘全部)。找不到不是錯誤(冪等)。
removeFileIn :: Connection -> FilePath -> IO ()
removeFileIn conn p = execute conn "DELETE FROM files WHERE path = ?" (Only (T.pack p))

-- | @files@ 表記錄的每個檔的指紋。
fileStatsIn :: Connection -> IO (Map FilePath FileStat)
fileStatsIn conn = do
  rows <- query_ conn "SELECT path, mtime, size FROM files" :: IO [(Text, Int64, Int64)]
  pure (M.fromList [(T.unpack p, FileStat m s) | (p, m, s) <- rows])

--------------------------------------------------------------------------------
-- 查詢(P-002-search)

-- | 依路由查一張或兩張 FTS 表,結構條件同時套用,兩邊命中取分數較大者去重。
--
-- 分數是 @-bm25(表名)@ ——bm25 愈小愈相關,取負之後「愈大愈相關」,與
-- 'Aapms.Store.Types.shScore' 的契約一致。兩張表都命中時取大不相加
-- (P-002-search 的決定:相加讓分數取決於命中幾張索引)。
ftsMatchIn :: Connection -> SearchRoute -> Text -> NodeFilter -> IO [(Id, Double)]
ftsMatchIn conn route txt nf = do
  tri <-
    if usesTrigram route
      then maybe (pure []) (\e -> ftsHitsOn conn "fts_tri" e nf) (triMatchExpr txt)
      else pure []
  cjk <-
    if usesCjk route
      then maybe (pure []) (\e -> ftsHitsOn conn "fts_cjk" e nf) (cjkMatchExpr txt)
      else pure []
  pure (M.toList (M.fromListWith max (tri ++ cjk)))

-- | 對一張 FTS 表跑 @MATCH@,附上結構條件,回 (id, bm25 取負)。
--
-- 逐字沿用舊碼 "Aapms.Store.Query" 的 @ftsHits@ 的 SQL(同一組 JOIN、同一份
-- 'Aapms.Store.Query.whereOfIn' 條件片段),只是不再一併取片段——片段改由
-- pure 層的 'Aapms.Store.Search.snippetFrom' 從節點原文算。
ftsHitsOn :: Connection -> Text -> Text -> NodeFilter -> IO [(Id, Double)]
ftsHitsOn conn table matchExpr nf = do
  let (cond, args) = whereOfIn "" nf
      sql =
        "SELECT n.id, -bm25("
          <> table
          <> ")\
             \ FROM "
          <> table
          <> " JOIN fts_map fm ON fm.rowid = "
          <> table
          <> ".rowid\
             \ JOIN nodes n ON n.id = fm.node_id\
             \ LEFT JOIN assets a ON a.id = n.id\
             \ LEFT JOIN packs p ON p.id = n.id\
             \ WHERE "
          <> table
          <> " MATCH ?"
          <> cond
  rows <- query conn (Query sql) (sText matchExpr : args) :: IO [(Text, Double)]
  pure [(i, sc) | (idText, sc) <- rows, Right (_, i) <- [parseId idText]]

-- | 符合結構條件的全部索引節點(帶 owner),__不分頁__(分頁由
-- "Aapms.Store.Search" 對合併後的整體做)。
filterNodesIn :: Connection -> NodeFilter -> IO [IndexedNode]
filterNodesIn conn nf = do
  let (cond, args) = whereOfIn "" nf
      sql = "SELECT n.id " <> baseFromIn "" <> " WHERE 1 = 1" <> cond <> " ORDER BY n.id"
  rows <- query conn (Query sql) args :: IO [Only Text]
  hydrateNodes conn [t | Only t <- rows]

--------------------------------------------------------------------------------
-- 寫入路徑(P-003-node-write)

-- | 節點所在檔、錨點與文件種類。
locateIn :: Connection -> Id -> IO (Maybe Located)
locateIn conn i = do
  rows <-
    query
      conn
      "SELECT n.file_path, n.section_anchor, f.doc_kind FROM nodes n\
      \ JOIN files f ON f.path = n.file_path WHERE n.id = ?"
      (Only (renderId i)) ::
      IO [(Text, Maybe Text, Text)]
  pure $
    listToMaybe
      [ Located {locPath = T.unpack fp, locAnchor = anchor >>= idOfText, locKind = kind}
      | (fp, anchor, kindText) <- rows
      , Just kind <- [parseDocKind kindText]
      ]

-- | 配號的碰撞查詢。
takenIn :: Connection -> Id -> IO Bool
takenIn conn i = do
  rows <- query conn "SELECT count(*) FROM nodes WHERE id = ?" (Only (renderId i)) :: IO [Only Int]
  pure $ case rows of
    (Only n : _) -> n > 0
    [] -> False

-- | 指向這些節點的關聯(來源 id、關聯)。
--
-- 跨 vault 的 'Ref' 只有在指名的正是__本 vault__ 時才算(索引一次只認一個
-- vault),與 'Aapms.Store.Simulate.runIndexPure' 的 @referrersIn@ 同一條規則;
-- 本 vault 的身分取自 @meta_info@ 的 @vault_id@(marker 寫進去的那一份)。
referrersIn :: Connection -> [Id] -> IO [(Id, Link)]
referrersIn _ [] = pure []
referrersIn conn is = do
  vid <- vaultIdOf conn
  rows <-
    query
      conn
      ( Query
          ( "SELECT src, dst_vault, dst, kind, note FROM links WHERE dst IN "
              <> inList (length is)
              <> " ORDER BY rowid"
          )
      )
      (map (sText . renderId) is) ::
      IO [LinkRow]
  pure
    [ (s, l)
    | (s, l) <- mapMaybe toLink rows
    , maybe True (== vid) (refVault (linkTarget l))
    ]

--------------------------------------------------------------------------------
-- 索引列 → AnyNode

-- | 這個索引屬於哪個 vault(@meta_info@ 的 @vault_id@,由
-- 'Aapms.Store.Schema.setVaultInfo' 以 marker 的內容寫入)。
--
-- 'Aapms.Core.Meta.Meta' 的 vault 欄不逐列存(見 "Aapms.Store.Row" 的待確認
-- 假設 A10),hydrate 時一律用這一個來源填回(P-001-index-rebuild LAW-7)。
vaultIdOf :: Connection -> IO VaultId
vaultIdOf conn = do
  rows <-
    query conn "SELECT value FROM meta_info WHERE key = ?" (Only ("vault_id" :: Text)) ::
      IO [Only Text]
  pure (VaultId (case rows of (Only t : _) -> t; [] -> T.empty))

-- | 一批節點 id → 'IndexedNode',依給定順序;還原不出來的列直接略過(索引是
-- 可重建的衍生物,一列壞掉不該讓查詢整個炸掉)。
hydrateNodes :: Connection -> [Text] -> IO [IndexedNode]
hydrateNodes _ [] = pure []
hydrateNodes conn ids = do
  vid <- vaultIdOf conn
  rows <-
    query
      conn
      (Query ("SELECT " <> nodeColumns <> " FROM nodes WHERE id IN " <> inList n))
      params ::
      IO [NodeRow]
  aliases <- grouped "SELECT node_id, alias FROM node_aliases WHERE node_id IN "
  tags <- grouped "SELECT node_id, tag FROM node_tags WHERE node_id IN "
  linkRows <-
    query
      conn
      ( Query
          ( "SELECT src, dst_vault, dst, kind, note FROM links WHERE src IN "
              <> inList n
              <> " ORDER BY rowid"
          )
      )
      params ::
      IO [LinkRow]
  refRows <-
    query
      conn
      ( Query
          ( "SELECT node_id, ref FROM tree_node_entities WHERE node_id IN "
              <> inList n
              <> " ORDER BY rowid"
          )
      )
      params ::
      IO [(Text, Text)]
  bodies <- bodiesOf conn ids
  assets <- keyedBy conn ids assetColumns "assets"
  packs <- keyedBy conn ids packColumns "packs"
  licenses <- keyedBy conn ids licenseColumns "licenses"
  levels <- keyedBy conn ids levelColumns "levels"
  trees <- keyedBy conn ids treeNodeColumns "tree_nodes"
  let linksByNode = groupPairs [(renderId s, [l]) | (s, l) <- mapMaybe toLink linkRows]
      tbl =
        Tables
          { tbAssets = assets
          , tbPacks = packs
          , tbLicenses = licenses
          , tbLevels = levels
          , tbTrees = trees
          , tbRefs = M.fromListWith (flip (++)) [(k, [v]) | (k, v) <- refRows]
          , tbBodies = bodies
          }
      byRowId =
        M.fromList
          [ (nrId r, node)
          | r <- rows
          , Just m <-
              [ rowToMeta
                  vid
                  r
                  (M.findWithDefault [] (nrId r) aliases)
                  (M.findWithDefault [] (nrId r) tags)
                  (M.findWithDefault [] (nrId r) linksByNode)
              ]
          , Just node <- [nodeOf tbl r m]
          ]
  pure (mapMaybe (`M.lookup` byRowId) ids)
  where
    n = length ids
    params = map sText ids

    -- 逐字比照 "Aapms.Store.Query" 私有的 @metasFor@:沒有 ORDER BY 的批次查詢
    -- 加 'Aapms.Store.Row.groupPairs'。換一種寫法就會讓 @metaTags@ \/
    -- @metaAliases@ 的實際列序與 @listNodes@ \/ @search@ 不同。
    grouped sql = do
      rs <- query conn (Query (sql <> inList n)) params :: IO [(Text, Text)]
      pure (groupPairs [(k, [v]) | (k, v) <- rs])

-- | 一批節點的正文,取自 @fts_tri.body@ ——那一欄就是索引時
-- 'Aapms.Store.Tokenize.rawFtsText' 寫進去的原文(@body@ 不進 @nodes@)。
-- 查不到列的節點視為空正文。
bodiesOf :: Connection -> [Text] -> IO (Map Text Text)
bodiesOf conn ids = do
  rs <-
    query
      conn
      ( Query
          ( "SELECT fm.node_id, ft.body FROM fts_map fm\
            \ JOIN fts_tri ft ON ft.rowid = fm.rowid\
            \ WHERE fm.node_id IN "
              <> inList (length ids)
          )
      )
      (map sText ids) ::
      IO [(Text, Text)]
  pure (M.fromList rs)

-- | @(id, 該表的列)@:六張專屬表共用同一個批次撈法。
data Keyed r = Keyed Text r

instance FromRow r => FromRow (Keyed r) where
  fromRow = Keyed <$> field <*> fromRow

-- | 一張專屬表裡這批 id 的列,以 id 為鍵。
keyedBy :: FromRow r => Connection -> [Text] -> Text -> Text -> IO (Map Text r)
keyedBy conn ids cols table = do
  rs <-
    query
      conn
      (Query ("SELECT id, " <> cols <> " FROM " <> table <> " WHERE id IN " <> inList (length ids)))
      (map sText ids)
  pure (M.fromList [(k, v) | Keyed k v <- rs])

-- | 還原一個節點會用到的全部專屬表。
data Tables = Tables
  { tbAssets :: Map Text AssetRow
  , tbPacks :: Map Text PackRow
  , tbLicenses :: Map Text LicenseRow
  , tbLevels :: Map Text LevelRow
  , tbTrees :: Map Text TreeNodeRow
  , tbRefs :: Map Text [Text]
  , tbBodies :: Map Text Text
  }

-- | 一列 @nodes@ + 已組好的 'Aapms.Core.Meta.Meta' → 'IndexedNode'。
--
-- 分支依 'Aapms.Core.Id.idPrefix',與 "Aapms.Store.Query" 的 @lookupNode@ 同一套
-- 分法;差別只在正文來自 @fts_tri@ 而不是回讀檔案(索引效果碰不到檔案系統)。
nodeOf :: Tables -> NodeRow -> Meta -> Maybe IndexedNode
nodeOf tbl r meta = do
  node <- case idPrefix (metaId meta) of
    PEnt -> Just (NEntity (Entity meta body))
    PAst -> NAsset . (\ar -> assetFromRow meta ar body) <$> M.lookup key (tbAssets tbl)
    PPck -> NPack . (\pr -> packFromRow meta pr body) <$> M.lookup key (tbPacks tbl)
    PLic -> NLicense . licenseFromRow meta <$> M.lookup key (tbLicenses tbl)
    PLvl -> do
      LevelRow rootText <- M.lookup key (tbLevels tbl)
      rootId <- idOfText rootText
      Just (NLevel (Level meta rootId))
    PNod -> do
      tn <- M.lookup key (tbTrees tbl)
      lvlId <- idOfText (tnrLevelId tn)
      kind <- either (const Nothing) Just (parseNodeKind (tnrKind tn))
      parentId <- case tnrParentId tn of
        Nothing -> Just Nothing
        Just p -> Just <$> idOfText p
      Just
        ( NNode
            Node
              { nodMeta = meta
              , nodLevel = lvlId
              , nodParent = parentId
              , nodOrder = tnrOrderIdx tn
              , nodKind = kind
              , nodEntities =
                  mapMaybe
                    (either (const Nothing) Just . parseRef)
                    (M.findWithDefault [] key (tbRefs tbl))
              }
        )
    PVlt -> Nothing
    PPrj -> Nothing
  pure IndexedNode {inNode = node, inOwner = nrOwner r >>= idOfText}
  where
    key = nrId r
    body = M.findWithDefault T.empty key (tbBodies tbl)

-- | 索引裡的 id 文字 → 'Id';壞掉的列回 'Nothing'(不讓查詢炸掉)。
idOfText :: Text -> Maybe Id
idOfText t = either (const Nothing) (Just . snd) (parseId t)
