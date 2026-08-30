-- | 條件查詢、關聯查詢、全文檢索與 facet:單一 vault 的查詢出口
-- (graph-core\/F006 + graph-core\/F007)。
--
-- 'linksTo' 是索引存在的主要理由之一:關聯只存在來源端(ADR-002),檔案裡
-- 查不到「誰指向我」,只有索引做得到反向查詢。
--
-- 'lookupNode' 的 body 一律__回讀檔案__而不從索引拿:正文可能很長,不該在
-- 可丟棄的索引裡再存一份權威副本;design.md 明寫「@body@ 進 FTS 但不進
-- @nodes@」。
--
-- == 全文檢索的兩條路(graph-core\/F007;ADR-016)
--
-- 'search' 把文字條件交給 "Aapms.Store.Tokenize" 的 'Aapms.Store.Tokenize.routeOf'
-- 決定走 @fts_tri@(trigram)、@fts_cjk@(unicode61 + 預切)或兩者,兩邊的
-- 命中以相關度合併去重。兩條路都給得出 bm25 分數,'shScore' 因此是 'Double'
-- 而不是 @Maybe Double@。__只有這兩條路,沒有第三條__:ADR-016 第二條讓
-- @LIKE@ 子字串掃描退場(它是 trigram 三字元下限的權宜之計),而 LAW-9 \/ LAW-10
-- 把「每個查詢字串走哪一條」完全釘死在 'Aapms.Store.Tokenize.routeOf' 與兩個
-- @MATCH@ 運算式上,沒有留給第三種比對方式的位置。
--
-- 'shSnippet' __一律取自 @fts_tri@ 的原文__,與這一筆命中來自哪張表無關
-- (graph-core\/F007 的不可逆決定 DEC-6):@fts_cjk@ 存的是預切後的 n-gram 串,
-- 它的視窗片段不是原文的子字串,不能給人看。
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

    -- * 全文檢索(graph-core\/F007)
  , SearchQuery (..)
  , emptySearchQuery
  , SearchHit (..)
  , FacetCounts (..)
  , SearchResult (..)
  , search
  ) where

import Data.List (sortBy)
import Data.Maybe (listToMaybe, mapMaybe)
import qualified Data.Map.Strict as M
import Data.Ord (Down (..))
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
import Aapms.Store.Marker (VaultHandle (..), VaultMarker (..))
import Aapms.Store.Row
import Aapms.Store.Tokenize
  ( cjkMatchExpr
  , routeOf
  , triMatchExpr
  , usesCjk
  , usesTrigram
  )
import System.FilePath ((</>))

--------------------------------------------------------------------------------
-- 過濾條件(契約 F)

data NodeFilter = NodeFilter
  { nfPrefixes :: [IdPrefix]
  , nfTypes :: [TypeKey]
  , nfStatus :: [Status]
  , nfTags :: [Text]
  , nfOwner :: Maybe Id
  , nfLicense :: Maybe Ref
  , nfNamedOnly :: Bool
  , nfIncludeReference :: Bool
  , nfLimit :: Int
  , nfOffset :: Int
  }
  deriving stock (Show, Eq)

-- | 全部欄位取最寬鬆的預設值(待確認假設 ASM-9:'nfLimit' 給一個大但有限的值,
-- 契約 F 沒有逐字列出這個輔助值,比照 F005 對 'Aapms.Store.Schema.IndexIssue'
-- 「契約給骨架、由後續 feature 依需要擴充」的精神補上)。
emptyNodeFilter :: NodeFilter
emptyNodeFilter =
  NodeFilter
    { nfPrefixes = []
    , nfTypes = []
    , nfStatus = []
    , nfTags = []
    , nfOwner = Nothing
    , nfLicense = Nothing
    , nfNamedOnly = False
    , nfIncludeReference = False
    , nfLimit = 1000
    , nfOffset = 0
    }

--------------------------------------------------------------------------------
-- WHERE 子句組裝

-- | 'NodeFilter' → SQL 片段 + 參數。base 查詢固定是
-- @nodes n LEFT JOIN assets a ON a.id = n.id LEFT JOIN packs p ON p.id = n.id@
-- ——'nfLicense'\/'nfNamedOnly'\/reference 排除都要用到 @a@\/@p@。
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
-- 2. @referenceClause@ 的 @SELECT id FROM packs WHERE is_reference = 1@
--    ('nfIncludeReference')
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

    -- nfIncludeReference = False(預設)時排除是 reference 的 pack 本身,以及
    -- owner 指向該 pack 的節點(待確認假設 ASM-3)。p.is_reference 對非 pack 節點
    -- 是 NULL(LEFT JOIN),所以用 IS NULL OR = 0 而非 NOT(...) = 1,避免
    -- NULL 在 WHERE 子句被當成 false 誤刪全部非 pack 節點。
    referenceClause =
      ( " AND (p.is_reference IS NULL OR p.is_reference = 0)\
        \ AND (n.owner IS NULL OR n.owner NOT IN (SELECT id FROM "
          <> schema
          <> "packs WHERE is_reference = 1))"
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

--------------------------------------------------------------------------------
-- 全文檢索(契約 F,graph-core/F007)

-- | 一次檢索:文字條件(可無)+ 結構條件 + 要不要順便算 facet。
data SearchQuery = SearchQuery
  { sqText :: Maybe Text
  -- ^ 全文條件。'Nothing' 或去掉頭尾空白後為空字串時__不__走 FTS,退化成
  -- 純結構查詢(等同 'listNodes')。
  , sqFilter :: NodeFilter
  -- ^ 結構條件,語意與 'listNodes' 完全相同(含 'nfLimit' \/ 'nfOffset')。
  , sqFacets :: Bool
  -- ^ 'True' 時 'srFacets' 為 'Just',否則為 'Nothing'。
  }
  deriving stock (Show, Eq)

-- | 沒有文字條件、最寬鬆的結構條件、不算 facet。
emptySearchQuery :: SearchQuery
emptySearchQuery =
  SearchQuery
    { sqText = Nothing
    , sqFilter = emptyNodeFilter
    , sqFacets = False
    }

-- | 一筆命中。'shVault' 讓跨 vault 的 @searchAcross@(graph-core\/F009)與單一
-- vault 的 'search' 回同一種形狀。
data SearchHit = SearchHit
  { shVault :: VaultId
  , shMeta :: Meta
  , shSnippet :: Text
  -- ^ 命中片段的純文字,不含任何標記;沒有文字條件時為空字串。
  , shScore :: Double
  -- ^ 相關度,愈大愈相關。有文字條件時恆 @> 0@;沒有文字條件時恆 @0@。
  }
  deriving stock (Show, Eq)

-- | 五個維度的分面計數。每個維度都是(值, 筆數),計數遞減、同計數以值遞增;
-- 值為 NULL 或計數為 0 的不出現。
data FacetCounts = FacetCounts
  { fcTypes :: [(Text, Int)]
  , fcVaults :: [(Text, Int)]
  , fcTags :: [(Text, Int)]
  , fcOwners :: [(Text, Int)]
  , fcLicenses :: [(Text, Int)]
  }
  deriving stock (Show, Eq)

-- | 'srTotal' 是套用全部條件、__未__套用 'nfLimit' \/ 'nfOffset' 的總筆數。
data SearchResult = SearchResult
  { srHits :: [SearchHit]
  , srTotal :: Int
  , srFacets :: Maybe FacetCounts
  }
  deriving stock (Show, Eq)

-- | 單一 vault 的全文檢索出口(契約 E)。
--
-- 不會失敗:索引是衍生物,查不到就是空結果,沒有 'Aapms.Store.Error.StoreError'
-- 這一層——與 'listNodes' \/ 'lookupNode' 一致。
search :: VaultHandle -> SearchQuery -> IO SearchResult
search vh q = do
  let filt = sqFilter q
      textM = normalizeText (sqText q)
  merged <- matchHits vh textM filt
  let total = length merged
      sorted = sortHits merged
      paged = takePage filt sorted
      byId = M.fromList [(hId h, h) | h <- paged]
  metas <- metasFor vh (map (renderId . hId) paged)
  let vid = vmId (vhMarker vh)
      toSearchHit m =
        SearchHit
          { shVault = vid
          , shMeta = m
          , shSnippet = maybe "" hSnippet (M.lookup (metaId m) byId)
          , shScore = maybe 0 hScore (M.lookup (metaId m) byId)
          }
  facets <-
    if sqFacets q
      then Just <$> computeFacets vh textM filt total
      else pure Nothing
  pure
    SearchResult
      { srHits = map toSearchHit metas
      , srTotal = total
      , srFacets = facets
      }

-- | 一筆內部命中:哪個節點、相關度、片段。沒有文字條件時 'hScore' 恆 @0@、
-- 'hSnippet' 恆 @""@(對照 'listNodes' 語意,見 LAW-12)。
data Hit = Hit
  { hId :: Id
  , hScore :: Double
  , hSnippet :: Text
  }
  deriving stock (Show, Eq)

normalizeText :: Maybe Text -> Maybe Text
normalizeText mt = case T.strip <$> mt of
  Nothing -> Nothing
  Just s | T.null s -> Nothing
  Just s -> Just s

-- | 沒有文字條件時退化成 'listNodes' 的結構條件(不套用 'nfLimit'\/'nfOffset',
-- 分頁在 'search' 統一處理);有文字條件時依 'routeOf' 決定的路由查一張或兩張
-- FTS 表,兩邊的命中以 'shScore' 較大者去重(DEC-2)。
matchHits :: VaultHandle -> Maybe Text -> NodeFilter -> IO [Hit]
matchHits vh Nothing filt = do
  ids <- structuralIds vh filt
  pure [Hit i 0 "" | i <- ids]
matchHits vh (Just txt) filt = do
  let route = routeOf txt
  triHits <-
    if usesTrigram route
      then case triMatchExpr txt of
        Just expr -> ftsHits vh "fts_tri" expr txt filt
        Nothing -> pure []
      else pure []
  cjkHits <-
    if usesCjk route
      then case cjkMatchExpr txt of
        Just expr -> ftsHits vh "fts_cjk" expr txt filt
        Nothing -> pure []
      else pure []
  pure (mergeHits (triHits ++ cjkHits))

-- | 兩張表都命中同一個節點時,取分數較大者(DEC-2:不是相加)。
mergeHits :: [Hit] -> [Hit]
mergeHits hs = M.elems (M.fromListWith pickBetter [(hId h, h) | h <- hs])
  where
    pickBetter new old = if hScore new >= hScore old then new else old

-- | 分數非遞增,分數相同時 id 遞增(LAW-14)。
sortHits :: [Hit] -> [Hit]
sortHits = sortBy (\a b -> compare (Down (hScore a)) (Down (hScore b)) <> compare (hId a) (hId b))

takePage :: NodeFilter -> [Hit] -> [Hit]
takePage filt = take (nfLimit filt) . drop (nfOffset filt)

-- | 全部符合結構條件的 id(不套用 'nfLimit'\/'nfOffset')。
structuralIds :: VaultHandle -> NodeFilter -> IO [Id]
structuralIds vh filt = do
  let (cond, args) = whereOf filt
      sql = "SELECT n.id " <> baseFrom <> " WHERE 1 = 1" <> cond <> " ORDER BY n.id"
  rows <- query (vhConn vh) (Query sql) args :: IO [Only Text]
  pure [i | Only t <- rows, Right (_, i) <- [parseId t]]

-- | 對一張 FTS 表跑 @MATCH@,附上結構條件,回傳每個命中節點的
-- (id, bm25 取負, 片段)。
--
-- 參數依序是:@table@ 要 @MATCH@ 的表名(@fts_tri@ 或 @fts_cjk@)、
-- @matchExpr@ 該表對應的 @MATCH@ 運算式、@queryText@ 使用者原本的查詢字串
-- (已去頭尾空白)、@filt@ 結構條件。
--
-- __片段一律取自該節點在 @fts_tri@ 的六欄原文__,與 @table@ 是哪一張無關
-- (不可逆決定 DEC-6 \/ 待確認假設 ASM-3)。@fts_cjk@ 存的是「先所有 unigram、再所有
-- bigram」的 token 串,@snippet()@ 對它取出的視窗不是原文的子字串,接不回
-- 連續文字。spec 對片段只要求兩件事:有文字條件且命中時非空;@queryText@ 在
-- 該節點的 @fts_tri@ 原文裡確實出現時,片段必須包含它。視窗怎麼挑(先找完整
-- 查詢字串、再找個別詞、都對不上時取第一個非空欄位的開頭,長度取多少)是實作
-- 層級的選擇。
--
-- 注意 CJK-only 的查詢(如二字詞)在 @fts_tri@ 上沒有 @MATCH@,FTS5 的
-- @snippet()@ 輔助函式因此不可用,片段要由 @fts_tri@ 的欄位內容自行取窗。
--
-- __實作筆記__:取片段__不__與 @MATCH@ 查詢同一句 SQL 自我 JOIN @fts_tri@
-- (@table == "fts_tri"@ 時會把同一張虛擬表接兩次)——實測 FTS5 的
-- @MATCH@\/@bm25()@ 認的是隱藏欄位「表名」而非 SQL 別名,同一句話裡出現兩次
-- 會讓 SQLite 回報 @ambiguous column name@。因此片段改由 'ftsTriSnippets'
-- batch 成獨立一次查詢,不受 @table@ 是哪一張影響。
ftsHits :: VaultHandle -> Text -> Text -> Text -> NodeFilter -> IO [Hit]
ftsHits vh table matchExpr queryText filt = do
  let (cond, args) = whereOf filt
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
      params = sText matchExpr : args
  rows <- query (vhConn vh) (Query sql) params :: IO [(Text, Double)]
  let hits = [(i, sc) | (idText, sc) <- rows, Right (_, i) <- [parseId idText]]
  snippets <- ftsTriSnippets vh queryText (map fst hits)
  pure [Hit i sc (M.findWithDefault "" i snippets) | (i, sc) <- hits]

-- | 一批命中節點 → 各自的 'snippetOf' 結果,一次查詢(避免 N+1)。查不到
-- @fts_tri@ 列的 id(理論上不會發生,兩張表的列同進同出)乾脆不放進 map,
-- 'ftsHits' 用 'M.findWithDefault' 落到空字串。
ftsTriSnippets :: VaultHandle -> Text -> [Id] -> IO (M.Map Id Text)
ftsTriSnippets _ _ [] = pure M.empty
ftsTriSnippets vh queryText ids = do
  let idTexts = map renderId ids
      sql =
        "SELECT n.id, ft.title, ft.summary, ft.body, ft.aliases, ft.tags, ft.name\
        \ FROM nodes n\
        \ JOIN fts_map fm ON fm.node_id = n.id\
        \ JOIN fts_tri ft ON ft.rowid = fm.rowid\
        \ WHERE n.id IN "
          <> inList (length idTexts)
  rows <- query (vhConn vh) (Query sql) (map sText idTexts) :: IO [FtsTriRow]
  pure
    (M.fromList
      [ (i, snippetOf queryText (ftsTriColumns r))
      | r <- rows
      , Right (_, i) <- [parseId (ftrId r)]
      ])

-- | 一列 @fts_tri@ 原文:命中節點的 id 與六欄原文,順序對應 SQL 的
-- @SELECT@(DEC-6:片段一律從這裡取)。
data FtsTriRow = FtsTriRow
  { ftrId :: Text
  , ftrTitle :: Text
  , ftrSummary :: Text
  , ftrBody :: Text
  , ftrAliases :: Text
  , ftrTags :: Text
  , ftrName :: Text
  }

instance FromRow FtsTriRow where
  fromRow =
    FtsTriRow
      <$> field -- n.id
      <*> field -- ft.title
      <*> field -- ft.summary
      <*> field -- ft.body
      <*> field -- ft.aliases
      <*> field -- ft.tags
      <*> field -- ft.name

ftsTriColumns :: FtsTriRow -> [Text]
ftsTriColumns r = [ftrTitle r, ftrSummary r, ftrBody r, ftrAliases r, ftrTags r, ftrName r]

-- | 從 @fts_tri@ 六欄原文取一段片段(ASM-3\/DEC-6)。先找 'queryText' 在哪一欄裡以
-- 連續子字串出現,取到就以那個出現位置為中心裁窗、片段裡必定含
-- 'queryText'(spec 對片段的第二條要求);沒有任何一欄含 'queryText' 時,
-- 退而取第一個非空欄位的開頭。裁掉的地方補一個省略號 @…@。視窗長度、挑選
-- 順序都是實作層級的選擇,spec 未逐字規定。
snippetOf :: Text -> [Text] -> Text
snippetOf queryText cols = case windowed of
  Just s -> s
  Nothing -> case filter (not . T.null) cols of
    (c : _) -> truncateFront c
    [] -> ""
  where
    windowed
      | T.null queryText = Nothing
      | otherwise =
          listToMaybe
            [ truncateBack before <> queryText <> truncateFront after
            | c <- cols
            , not (T.null c)
            , let (before, rest) = T.breakOn queryText c
            , not (T.null rest)
            , let after = T.drop (T.length queryText) rest
            ]

    truncateBack t
      | T.length t > snippetContext = "\x2026" <> T.takeEnd snippetContext t
      | otherwise = t

    truncateFront t
      | T.length t > snippetContext = T.take snippetContext t <> "\x2026"
      | otherwise = t

-- | 片段視窗一側取多少字元(不含省略號),實作層級的選擇。
snippetContext :: Int
snippetContext = 24

-- | 五個分面維度。每個維度各自忽略自己的條件(DEC-5\/LAW-17)但保留其他結構條件與
-- 文字條件,計算候選集再依維度分組計數。
computeFacets :: VaultHandle -> Maybe Text -> NodeFilter -> Int -> IO FacetCounts
computeFacets vh textM filt total = do
  types <- facetColumn vh textM filt {nfTypes = []} "n.type"
  tags <- facetTags vh textM filt {nfTags = []}
  owners <- facetColumn vh textM filt {nfOwner = Nothing} "n.owner"
  licenses <- facetLicenses vh textM filt {nfLicense = Nothing}
  let (VaultId vidText) = vmId (vhMarker vh)
  pure
    FacetCounts
      { fcTypes = types
      , fcVaults = [(vidText, total)]
      , fcTags = tags
      , fcOwners = owners
      , fcLicenses = licenses
      }

-- | 忽略某一維度後仍符合的候選節點 id(文字條件照舊套用)。
candidateIds :: VaultHandle -> Maybe Text -> NodeFilter -> IO [Id]
candidateIds vh textM filt = map hId <$> matchHits vh textM filt

facetColumn :: VaultHandle -> Maybe Text -> NodeFilter -> Text -> IO [(Text, Int)]
facetColumn vh textM filt column = do
  ids <- candidateIds vh textM filt
  if null ids
    then pure []
    else do
      let idTexts = map renderId ids
          sql = "SELECT " <> column <> " FROM nodes n WHERE n.id IN " <> inList (length idTexts)
      rows <- query (vhConn vh) (Query sql) (map sText idTexts) :: IO [Only (Maybe Text)]
      pure (tally [v | Only (Just v) <- rows])

facetTags :: VaultHandle -> Maybe Text -> NodeFilter -> IO [(Text, Int)]
facetTags vh textM filt = do
  ids <- candidateIds vh textM filt
  if null ids
    then pure []
    else do
      let idTexts = map renderId ids
          sql = "SELECT tag FROM node_tags WHERE node_id IN " <> inList (length idTexts)
      rows <- query (vhConn vh) (Query sql) (map sText idTexts) :: IO [Only Text]
      pure (tally [t | Only t <- rows])

facetLicenses :: VaultHandle -> Maybe Text -> NodeFilter -> IO [(Text, Int)]
facetLicenses vh textM filt = do
  ids <- candidateIds vh textM filt
  if null ids
    then pure []
    else do
      let idTexts = map renderId ids
          sql =
            "SELECT COALESCE(a.license, p.license) FROM nodes n\
            \ LEFT JOIN assets a ON a.id = n.id\
            \ LEFT JOIN packs p ON p.id = n.id\
            \ WHERE n.id IN "
              <> inList (length idTexts)
      rows <- query (vhConn vh) (Query sql) (map sText idTexts) :: IO [Only (Maybe Text)]
      pure (tally [v | Only (Just v) <- rows])

-- | 計數遞減、同計數以值遞增(契約 F 'FacetCounts' 的說明)。
tally :: [Text] -> [(Text, Int)]
tally xs =
  sortBy (\(v1, c1) (v2, c2) -> compare (Down c1) (Down c2) <> compare v1 v2)
    (M.toList (M.fromListWith (+) [(x, 1 :: Int) | x <- xs]))
