-- | 條件查詢與關聯查詢:單一 vault 的查詢出口(graph-core\/F006)。
--
-- 'linksTo' 是索引存在的主要理由之一:關聯只存在來源端(ADR-002),檔案裡
-- 查不到「誰指向我」,只有索引做得到反向查詢。
--
-- 'lookupNode' 的 body 一律__回讀檔案__而不從索引拿:正文可能很長,不該在
-- 可丟棄的索引裡再存一份權威副本;design.md 明寫「@body@ 進 FTS 但不進
-- @nodes@」。
--
-- == 全文檢索不在這裡(P-002-search,2026-09-06 退場波)
--
-- 舊的單 vault @search@ 與它底下整棵私有子樹(@matchHits@ \/ @mergeHits@ \/
-- @snippetOf@ \/ @computeFacets@ …)是與新核心並存的第二份實作,已經退場。
-- 全文檢索現在只有一條:pure 層的 'Aapms.Store.Search.searchVaults',shell
-- 進入點是 'Aapms.Store.MultiVault.searchAcross'(單一 vault 就是集合裡只有
-- 一個 vault 的特例)。
--
-- 本模組的__型別__('NodeFilter' \/ 'SearchQuery' \/ 'SearchHit' \/ 'FacetCounts' \/
-- 'SearchResult' 與兩個 @empty*@ 預設值)宣告在 "Aapms.Store.Types",這裡只有
-- 查詢函式與 SQL 片段組裝;匯出清單原樣 re-export 它們,呼叫端逐字不變。
module Aapms.Store.Query
  ( -- * 過濾條件
    NodeFilter (..)
  , emptyNodeFilter

    -- * 跨 vault 重用的 SQL 片段(graph-core\/F009)
    --
    -- | 「模組間公開介面」的 MultiVault → Query 那一條:
    -- 'Aapms.Store.MultiVault.listAcross' 重用__這一份__條件片段,對加了
    -- schema 前綴的 UNION 視圖執行。'NodeFilter' 的語意因此只有一個實作,
    -- 單一 vault 與跨 vault 不會慢慢分歧。
  , whereOfIn
  , baseFromIn

    -- * 查詢
  , lookupNode
  , lookupByName
  , listNodes
  , childrenOf

    -- * 關聯
  , linksFrom
  , linksTo
  , loadLinkGraph

    -- * 全文檢索的型別(宣告在 "Aapms.Store.Types",本模組原樣 re-export)
  , SearchQuery (..)
  , emptySearchQuery
  , SearchHit (..)
  , FacetCounts (..)
  , SearchResult (..)
  ) where

import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Aapms.Core.AnyNode (AnyNode (..))
import Aapms.Core.Asset (Asset (..), LogicalName (..))
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
  , renderIdPrefix
  , renderRef
  )
import Aapms.Core.Level (Level (..), Node (..), parseNodeKind)
import Aapms.Core.License (License (..))
import Aapms.Core.Link (Link (..), LinkGraph)
import Aapms.Core.Meta (Meta (..), Status (..), TypeKey (..), renderStatus)
import Aapms.Core.Pack (Pack (..))
import Aapms.Md.Document (Document, docKind, DocKind (..))
import Aapms.Md.Parse (parseDocument, toPack, toTopic)
import Aapms.Store.Atomic (readTextFile)
import Aapms.Store.Marker (VaultHandle (..))
import Aapms.Store.Row
import Aapms.Store.Row.Sql
import Aapms.Store.Types
  ( FacetCounts (..)
  , NodeFilter (..)
  , SearchHit (..)
  , SearchQuery (..)
  , SearchResult (..)
  , VaultMarker (..)
  , emptyNodeFilter
  , emptySearchQuery
  )
import System.FilePath ((</>))

--------------------------------------------------------------------------------
-- WHERE 子句組裝

-- | 'NodeFilter' → SQL 片段 + 參數。base 查詢固定是
-- @nodes n LEFT JOIN assets a ON a.id = n.id LEFT JOIN packs p ON p.id = n.id@
-- ——'nfLicense' 與 'nfNamedOnly' 要用到 @a@\/@p@;reference 排除只用 @n@
-- (見 @referenceClause@)。
--
-- 單一 vault 的三個呼叫端('listNodes' \/ 'structuralIds' \/ 'ftsHits')用的
-- 就是這個沒有前綴的特化,行為與 graph-core\/F007 交付時逐字相同。
whereOf :: NodeFilter -> (Text, [SQLData])
whereOf = whereOfIn ""

-- | 'whereOf' 的一般化:多吃一個 __schema 前綴__(graph-core\/F009)。
--
-- @schema@ 是要加在表名前面的前綴,__含結尾的點__:@\"\"@ 是目前連線的 @main@
-- (即 'whereOf'),@\"v1.\"@ 是 @ATTACH@ 進來的某個 vault。
--
-- 條件本身絕大部分只用 @n@ \/ @a@ \/ @p@ 三個__別名__,逐字可重用;
-- __需要前綴的是兩處直接寫出表名的子查詢__(以
-- @grep -nE \"FROM [A-Za-z_]+|JOIN [A-Za-z_]+\"@ 對本函式全段掃出來的,不是用讀的):
--
-- 1. @tagClause@ 的 @SELECT 1 FROM node_tags nt …@('nfTags')
-- 2. @referenceClause@ 的 @SELECT 1 FROM files f WHERE f.path = n.file_path AND
--    f.is_reference = 1@('nfIncludeReference')
--
-- 跨 vault 時少了前綴,它們會解析到 @main@ 的那張表(或根本沒有這張表),等於
-- 拿__別的 vault__ 的標籤 \/ reference 清單去篩這個 vault 的節點。第 2 條尤其
-- 危險:'nfIncludeReference' 預設就是 'False',那是**預設路徑**。
whereOfIn :: Text -> NodeFilter -> (Text, [SQLData])
whereOfIn schema NodeFilter {..} = (T.concat (map fst parts), concatMap snd parts)
  where
    parts =
      concat
        [ [inClause "n.prefix" (map renderIdPrefix nfPrefixes) | not (null nfPrefixes)]
        , [inClause "n.type" (map unTypeKey nfTypes) | not (null nfTypes)]
        , [statusClause]
        , [tagClause t | t <- nfTags]
        , [ownerClause]
        , [licenseClause]
        , [namedOnlyClause]
        , [referenceClause | not nfIncludeReference]
        ]

    unTypeKey (TypeKey t) = t

    inClause col vals = (" AND " <> col <> " IN " <> inList (length vals), map sText vals)

    -- 契約 F:nfStatus = [] 表示全部但排除 missing;非空時 IN (...)。
    statusClause
      | null nfStatus = (" AND n.status <> ?", [sText (renderStatus Missing)])
      | otherwise = inClause "n.status" (map renderStatus nfStatus)

    -- 裸表名之二:標籤存在性檢查。少了前綴會拿別的 vault 的 node_tags 來篩
    -- 這個 vault 的節點(與 referenceClause 同一類缺陷)。
    tagClause t =
      ( " AND EXISTS (SELECT 1 FROM "
          <> schema
          <> "node_tags nt WHERE nt.node_id = n.id AND nt.tag = ?)"
      , [sText t]
      )

    ownerClause = case nfOwner of
      Just o -> (" AND n.owner = ?", [sText (renderId o)])
      Nothing -> ("", [])

    licenseClause = case nfLicense of
      Just ref -> (" AND (a.license = ? OR p.license = ?)", [sText (renderRef ref), sText (renderRef ref)])
      Nothing -> ("", [])

    namedOnlyClause
      | nfNamedOnly = (" AND a.name IS NOT NULL", [])
      | otherwise = ("", [])

    -- nfIncludeReference = False(預設)時排除__reference 檔裡的每一個節點__
    -- (P-002-search:reference 是檔的屬性,'Aapms.Store.Types.fiReference')。
    --
    -- 舊規則是「@p.is_reference@ 排掉 pack 節點自己 + @n.owner NOT IN (reference
    -- packs)@ 排掉它的下屬」,與純的 'Aapms.Store.Filter.passesFilter' 分岔:
    -- 同一份 reference 的 @pack.md@ 裡若有 owner 為 NULL 的節點(沒有 pack 節點
    -- 的檔,或 owner 沒接上),SQL 側留著、純側整檔排除。改成看 @files@ 那一欄
    -- 之後兩邊逐字同義,@packs.is_reference@ 不再參與過濾(欄位仍在,是 pack 自
    -- 己的資料)。
    --
    -- 寫成 @NOT EXISTS@ 的相關子查詢而不是多接一張表:呼叫端各自組自己的
    -- @FROM@('baseFromIn'、'ftsHits' 的 FTS JOIN、'Aapms.Store.MultiVault' 的
    -- UNION 片段),共通的只有 @n@ 這個別名。裸表名要加 schema 前綴,理由同
    -- @tagClause@。
    referenceClause =
      ( " AND NOT EXISTS (SELECT 1 FROM "
          <> schema
          <> "files f WHERE f.path = n.file_path AND f.is_reference = 1)"
      , []
      )

-- | 單一 vault 的 @FROM@ 子句(graph-core\/F006 原文,行為不變)。
baseFrom :: Text
baseFrom = baseFromIn ""

-- | 'baseFrom' 的一般化:三張表都加上 __schema 前綴__(graph-core\/F009)。
-- @schema@ 的形式同 'whereOfIn'(含結尾的點);@\"\"@ 時逐字等於 'baseFrom'。
baseFromIn :: Text -> Text
baseFromIn schema =
  "FROM "
    <> schema
    <> "nodes n\
       \ LEFT JOIN "
    <> schema
    <> "assets a ON a.id = n.id\
       \ LEFT JOIN "
    <> schema
    <> "packs p ON p.id = n.id"

--------------------------------------------------------------------------------
-- listNodes / childrenOf(不含 body 的批次查詢)

listNodes :: VaultHandle -> NodeFilter -> IO [Meta]
listNodes vh filt = do
  let (cond, args) = whereOf filt
      sql = "SELECT n.id " <> baseFrom <> " WHERE 1 = 1" <> cond <> " ORDER BY n.id LIMIT ? OFFSET ?"
  ids <-
    query (vhConn vh) (Query sql) (args ++ [sInt (nfLimit filt), sInt (nfOffset filt)]) ::
      IO [Only Text]
  metasFor vh [t | Only t <- ids]

childrenOf :: VaultHandle -> Id -> IO [Meta]
childrenOf vh i = do
  ids <-
    query (vhConn vh) "SELECT id FROM nodes WHERE owner = ? ORDER BY rowid" (Only (renderId i)) ::
      IO [Only Text]
  metasFor vh [t | Only t <- ids]

-- | 依給定的 id 順序取回 'Meta'(含 tags\/aliases\/links)。一次把 nodes 與
-- 三張附屬表都撈回來再分組,而不是每筆各查三次——典型的 N+1 避免。
metasFor :: VaultHandle -> [Text] -> IO [Meta]
metasFor _ [] = pure []
metasFor vh ids = do
  let conn = vhConn vh
      vid = vmId (vhMarker vh)
  rows <-
    query
      conn
      (Query ("SELECT " <> nodeColumns <> " FROM nodes WHERE id IN " <> inList (length ids)))
      (map sText ids) ::
      IO [NodeRow]
  aliases <- grouped conn "SELECT node_id, alias FROM node_aliases WHERE node_id IN "
  tags <- grouped conn "SELECT node_id, tag FROM node_tags WHERE node_id IN "
  linkRows <-
    query
      conn
      ( Query
          ( "SELECT src, dst_vault, dst, kind, note FROM links WHERE src IN "
              <> inList (length ids)
              <> " ORDER BY rowid"
          )
      )
      (map sText ids) ::
      IO [LinkRow]
  let linksByNode = groupPairs [(renderId s, [l]) | (s, l) <- mapMaybe toLink linkRows]
      byId =
        M.fromList
          [ (nrId r, m)
          | r <- rows
          , Just m <-
              [ rowToMeta
                  vid
                  r
                  (M.findWithDefault [] (nrId r) aliases)
                  (M.findWithDefault [] (nrId r) tags)
                  (M.findWithDefault [] (nrId r) linksByNode)
              ]
          ]
  pure (mapMaybe (`M.lookup` byId) ids)
  where
    grouped conn sql = do
      rs <- query conn (Query (sql <> inList (length ids))) (map sText ids) :: IO [(Text, Text)]
      pure (groupPairs [(k, [v]) | (k, v) <- rs])

--------------------------------------------------------------------------------
-- lookupNode(依 prefix 分七支)

-- | 依 id 撈回一列 'NodeRow'(15 欄全撈),找不到回 'Nothing'。
lookupNodeRow :: VaultHandle -> Id -> IO (Maybe NodeRow)
lookupNodeRow vh i = do
  rows <-
    query
      (vhConn vh)
      (Query ("SELECT " <> nodeColumns <> " FROM nodes WHERE id = ?"))
      (Only (renderId i)) ::
      IO [NodeRow]
  pure (listToMaybe rows)

readDocOf :: VaultHandle -> Text -> IO (Maybe Document)
readDocOf vh relPath = do
  txtR <- readTextFile (vhRoot vh </> T.unpack relPath)
  pure $ case txtR of
    Left _ -> Nothing
    Right txt -> case parseDocument txt of
      Left _ -> Nothing
      Right doc -> Just doc

lookupNode :: VaultHandle -> Id -> IO (Maybe AnyNode)
lookupNode vh i = case idPrefix i of
  PEnt -> fmap NEntity <$> lookupEntityNode vh i
  PAst -> fmap NAsset <$> lookupAssetNode vh i
  PPck -> fmap NPack <$> lookupPackNode vh i
  PLic -> fmap NLicense <$> lookupLicenseNode vh i
  PLvl -> fmap NLevel <$> lookupLevelNode vh i
  PNod -> fmap NNode <$> lookupTreeNode vh i
  PVlt -> pure Nothing
  PPrj -> pure Nothing

-- | @docKind@ 判定文件身分後只有 'TopicDoc' 有片段清單,只有 'PackDoc' 有
-- asset 清單。主體(section_anchor 為 'Nothing')與片段共用一個 body 查詢。
lookupEntityNode :: VaultHandle -> Id -> IO (Maybe Entity)
lookupEntityNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
      docM <- readDocOf vh (nrFilePath row)
      let bodyM = docM >>= \doc -> case docKind doc of
            TopicDoc -> case toTopic doc of
              Left _ -> Nothing
              Right (mainE, frags) -> case nrSectionAnchor row of
                Nothing -> Just (entBody mainE)
                Just _ -> entBody <$> listToMaybe (filter ((== i) . metaId . entMeta) frags)
            _ -> Nothing
      pure (Entity meta <$> bodyM)

lookupAssetNode :: VaultHandle -> Id -> IO (Maybe Asset)
lookupAssetNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      arRows <-
        query
          (vhConn vh)
          (Query ("SELECT " <> assetColumns <> " FROM assets WHERE id = ?"))
          (Only (nrId row)) ::
          IO [AssetRow]
      case arRows of
        [] -> pure Nothing
        (ar : _) -> do
          meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
          docM <- readDocOf vh (nrFilePath row)
          let bodyM = docM >>= \doc -> case docKind doc of
                PackDoc -> case toPack doc of
                  Left _ -> Nothing
                  Right (_, assets) -> astBody <$> listToMaybe (filter ((== i) . metaId . astMeta) assets)
                _ -> Nothing
          pure (assetFromRow meta ar <$> bodyM)

lookupPackNode :: VaultHandle -> Id -> IO (Maybe Pack)
lookupPackNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      prRows <-
        query
          (vhConn vh)
          (Query ("SELECT " <> packColumns <> " FROM packs WHERE id = ?"))
          (Only (nrId row)) ::
          IO [PackRow]
      case prRows of
        [] -> pure Nothing
        (pr : _) -> do
          meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
          docM <- readDocOf vh (nrFilePath row)
          let bodyM = docM >>= \doc -> case docKind doc of
                PackDoc -> either (const Nothing) (Just . pckBody . fst) (toPack doc)
                _ -> Nothing
          pure (packFromRow meta pr <$> bodyM)

lookupLicenseNode :: VaultHandle -> Id -> IO (Maybe License)
lookupLicenseNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      lrRows <-
        query
          (vhConn vh)
          (Query ("SELECT " <> licenseColumns <> " FROM licenses WHERE id = ?"))
          (Only (nrId row)) ::
          IO [LicenseRow]
      case listToMaybe lrRows of
        Nothing -> pure Nothing
        Just lr -> do
          meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
          pure (Just (licenseFromRow meta lr))

lookupLevelNode :: VaultHandle -> Id -> IO (Maybe Level)
lookupLevelNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      lvRows <-
        query
          (vhConn vh)
          (Query ("SELECT " <> levelColumns <> " FROM levels WHERE id = ?"))
          (Only (nrId row)) ::
          IO [LevelRow]
      case listToMaybe lvRows of
        Nothing -> pure Nothing
        Just (LevelRow rootText) -> case parseId rootText of
          Left _ -> pure Nothing
          Right (_, rootId) -> do
            meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
            pure (Just (Level meta rootId))

lookupTreeNode :: VaultHandle -> Id -> IO (Maybe Node)
lookupTreeNode vh i = do
  mRow <- lookupNodeRow vh i
  case mRow of
    Nothing -> pure Nothing
    Just row -> do
      tnRows <-
        query
          (vhConn vh)
          (Query ("SELECT " <> treeNodeColumns <> " FROM tree_nodes WHERE id = ?"))
          (Only (nrId row)) ::
          IO [TreeNodeRow]
      case listToMaybe tnRows of
        Nothing -> pure Nothing
        Just tn -> do
          refRows <-
            query
              (vhConn vh)
              "SELECT ref FROM tree_node_entities WHERE node_id = ? ORDER BY rowid"
              (Only (nrId row)) ::
              IO [Only Text]
          meta <- hydrateMeta (vmId (vhMarker vh)) (vhConn vh) row
          pure $ do
            (_, lvlId) <- either (const Nothing) Just (parseId (tnrLevelId tn))
            kind <- either (const Nothing) Just (parseNodeKind (tnrKind tn))
            parentId <- case tnrParentId tn of
              Nothing -> Just Nothing
              Just p -> case parseId p of
                Left _ -> Nothing
                Right (_, pid) -> Just (Just pid)
            pure
              Node
                { nodMeta = meta
                , nodLevel = lvlId
                , nodParent = parentId
                , nodOrder = tnrOrderIdx tn
                , nodKind = kind
                , nodEntities = mapMaybe (either (const Nothing) Just . parseRef . fromOnly) refRows
                }

lookupByName :: VaultHandle -> LogicalName -> IO (Maybe Asset)
lookupByName vh (LogicalName nm) = do
  rows <- query (vhConn vh) "SELECT id FROM assets WHERE name = ?" (Only nm) :: IO [Only Text]
  case rows of
    [] -> pure Nothing
    (Only idText : _) -> case parseId idText of
      Left _ -> pure Nothing
      Right (_, i) -> lookupAssetNode vh i

--------------------------------------------------------------------------------
-- 關聯

linksFrom :: VaultHandle -> Id -> IO [Link]
linksFrom vh i = do
  rows <-
    query
      (vhConn vh)
      "SELECT src, dst_vault, dst, kind, note FROM links WHERE src = ? ORDER BY rowid"
      (Only (renderId i)) ::
      IO [LinkRow]
  pure (map snd (mapMaybe toLink rows))

-- | 契約 E 的簽名回傳 @[(Meta, Link)]@,不是舊版的 @[(Id, Link)]@——每個來源
-- 都要 hydrate 出完整 'Meta'(待確認假設 ASM-7:照契約做,沒有偏離空間)。
linksTo :: VaultHandle -> Ref -> IO [(Meta, Link)]
linksTo vh (Ref mv i) = do
  rows <- case mv of
    Nothing ->
      query
        (vhConn vh)
        "SELECT src, dst_vault, dst, kind, note FROM links\
        \ WHERE dst = ? AND dst_vault IS NULL ORDER BY rowid"
        (Only (renderId i)) ::
        IO [LinkRow]
    Just (VaultId vname) ->
      query
        (vhConn vh)
        "SELECT src, dst_vault, dst, kind, note FROM links\
        \ WHERE dst = ? AND dst_vault = ? ORDER BY rowid"
        (renderId i, vname) ::
        IO [LinkRow]
  let pairs = mapMaybe toLink rows
  metas <- metasFor vh (map (renderId . fst) pairs)
  let byId = M.fromList [(renderId (metaId m), m) | m <- metas]
  pure [(m, l) | (s, l) <- pairs, Just m <- [M.lookup (renderId s) byId]]

loadLinkGraph :: VaultHandle -> IO LinkGraph
loadLinkGraph vh = do
  rows <-
    query_ (vhConn vh) "SELECT src, dst_vault, dst, kind, note FROM links ORDER BY rowid" ::
      IO [LinkRow]
  pure (M.fromListWith (flip (++)) [(s, [l]) | (s, l) <- mapMaybe toLink rows])

