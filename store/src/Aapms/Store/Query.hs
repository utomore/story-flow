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
-- 而不是 @Maybe Double@。__沒有子字串模糊比對(SQL 萬用字元運算子)掃描路徑__:
-- 那是 trigram 三字元下限的權宜之計,ADR-016 第二條已讓它退場(L23:本套件
-- 原始碼不含那個 SQL 關鍵字的獨立詞)。
module Aapms.Store.Query
  ( -- * 過濾條件
    NodeFilter (..)
  , emptyNodeFilter

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
  , desegmentCjk
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

-- | 全部欄位取最寬鬆的預設值(待確認假設 A9:'nfLimit' 給一個大但有限的值,
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
whereOf :: NodeFilter -> (Text, [SQLData])
whereOf NodeFilter {..} = (T.concat (map fst parts), concatMap snd parts)
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

    tagClause t =
      ( " AND EXISTS (SELECT 1 FROM node_tags nt WHERE nt.node_id = n.id AND nt.tag = ?)"
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
    -- owner 指向該 pack 的節點(待確認假設 A3)。p.is_reference 對非 pack 節點
    -- 是 NULL(LEFT JOIN),所以用 IS NULL OR = 0 而非 NOT(...) = 1,避免
    -- NULL 在 WHERE 子句被當成 false 誤刪全部非 pack 節點。
    referenceClause =
      ( " AND (p.is_reference IS NULL OR p.is_reference = 0)\
        \ AND (n.owner IS NULL OR n.owner NOT IN (SELECT id FROM packs WHERE is_reference = 1))"
      , []
      )

baseFrom :: Text
baseFrom =
  "FROM nodes n\
  \ LEFT JOIN assets a ON a.id = n.id\
  \ LEFT JOIN packs p ON p.id = n.id"

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
-- 都要 hydrate 出完整 'Meta'(待確認假設 A7:照契約做,沒有偏離空間)。
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
-- 'hSnippet' 恆 @""@(對照 'listNodes' 語意,見 L12)。
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
-- FTS 表,兩邊的命中以 'shScore' 較大者去重(D2)。
matchHits :: VaultHandle -> Maybe Text -> NodeFilter -> IO [Hit]
matchHits vh Nothing filt = do
  ids <- structuralIds vh filt
  pure [Hit i 0 "" | i <- ids]
matchHits vh (Just txt) filt = do
  let route = routeOf txt
  triHits <-
    if usesTrigram route
      then case triMatchExpr txt of
        Just expr -> ftsHits vh "fts_tri" expr filt False
        Nothing -> pure []
      else pure []
  cjkHits <-
    if usesCjk route
      then case cjkMatchExpr txt of
        Just expr -> ftsHits vh "fts_cjk" expr filt True
        Nothing -> pure []
      else pure []
  pure (mergeHits (triHits ++ cjkHits))

-- | 兩張表都命中同一個節點時,取分數較大者(D2:不是相加)。
mergeHits :: [Hit] -> [Hit]
mergeHits hs = M.elems (M.fromListWith pickBetter [(hId h, h) | h <- hs])
  where
    pickBetter new old = if hScore new >= hScore old then new else old

-- | 分數非遞增,分數相同時 id 遞增(L14)。
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

-- | 對一張 FTS 表跑 @MATCH@,附上結構條件,回傳 (id, bm25 取負, snippet)。
-- @isCjkTable@ 為 'True' 時把 @snippet()@ 的輸出經 'desegmentCjk' 還原成連續
-- 文字(否則使用者會看到「藥 水 藥水」,待確認假設 A3)。
ftsHits :: VaultHandle -> Text -> Text -> NodeFilter -> Bool -> IO [Hit]
ftsHits vh table matchExpr filt isCjkTable = do
  let (cond, args) = whereOf filt
      sql =
        "SELECT n.id, -bm25("
          <> table
          <> "), snippet("
          <> table
          <> ", -1, '', '', '\x2026', 8)\
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
  rows <- query (vhConn vh) (Query sql) params :: IO [(Text, Double, Text)]
  pure
    [ Hit i sc (postprocess snip)
    | (idText, sc, snip) <- rows
    , Right (_, i) <- [parseId idText]
    ]
  where
    postprocess = if isCjkTable then desegmentCjk else id

-- | 五個分面維度。每個維度各自忽略自己的條件(D5\/L17)但保留其他結構條件與
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
