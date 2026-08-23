-- | Level 場景樹的建構、驗證與走訪。
--
-- ADR-004:Level 是嚴格樹——每個 Node 恰有一個父節點(根除外)、不成環、
-- 同層兄弟以 @order@ 排序。分支合流以 @convergesTo@ 關聯標註,
-- __不參與結構__,因此本模組的走訪演算法永遠只看父子邊。
module Aapms.Core.Tree
  ( -- * 樹
    NodeTree (..)
  , TreeError (..)
  , renderTreeError
  , buildTree

    -- * 走訪
  , preorder
  , subtreeAt
  , pathTo
  , nodesOfKind
  , entitiesIn
  , convergenceReport
  ) where

import Data.List (nub, sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import qualified Data.Set as S
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, Ref (..), renderId)
import Aapms.Core.Level (Level (..), Node (..), NodeKind)
import Aapms.Core.Link (Link (..), LinkKind (ConvergesTo))
import Aapms.Core.Meta (Meta (..))

data NodeTree = NodeTree
  { ntNode :: Node
  , ntChildren :: [NodeTree]
  }
  deriving stock (Show, Eq)

-- | 樹的五條不變量各對應一個(或一組)建構子。
data TreeError
  = -- | 有多於一個 @parent = Nothing@ 的節點
    MultipleRoots [Id]
  | -- | 一個 @parent = Nothing@ 的節點都沒有
    NoRoot
  | -- | 節點, 它指向的不存在父節點
    OrphanNode Id Id
  | -- | 環上的節點序列(以最小 id 起始的正規化順序)
    Cycle [Id]
  | -- | 父節點, order 值, 衝突的子節點
    DuplicateOrder Id Int [Id]
  | -- | 同一個 id 出現多次
    DuplicateNodeId Id
  | -- | Level 宣告的 root, 實際找到的 root
    RootMismatch Id Id
  deriving stock (Show, Eq)

-- | 給人看的訊息。樹壞掉幾乎都是作者手改標題層級造成的,所以每一則都指向
-- 「去改哪一個標題」而不是描述資料結構。
renderTreeError :: TreeError -> Text
renderTreeError = \case
  MultipleRoots is ->
    "這份 Level 有多個根 Node(" <> ids is <> ");最淺的標題層級只能有一個"
  NoRoot ->
    "這份 Level 找不到根 Node;至少要有一個最淺層級的標題"
  OrphanNode i p ->
    "Node " <> renderId i <> " 的父節點 " <> renderId p <> " 不存在"
  Cycle is ->
    "Node 的父子關係成環:" <> ids is
  DuplicateOrder p o is ->
    "父節點 "
      <> renderId p
      <> " 底下有兩個以上的第 "
      <> T.pack (show o)
      <> " 個子節點(" <> ids is <> ")"
  DuplicateNodeId i ->
    "Node id " <> renderId i <> " 在同一份檔案裡出現多次"
  RootMismatch declared actual ->
    "frontmatter 宣告的 root " <> renderId declared <> " 與實際的根 Node " <> renderId actual <> " 不符"
  where
    ids = T.intercalate ", " . map renderId

-- | 由 'Level' 與它的 'Node' 清單建樹。
--
-- __回傳全部錯誤而非第一個__:作者手改 Markdown 後常一次壞好幾處,一次列完
-- 比修一個跑一次有用得多。
buildTree :: Level -> [Node] -> Either [TreeError] NodeTree
buildTree lvl nodes
  | not (null errs) = Left errs
  | otherwise = case roots of
      [r] -> Right (grow (nodeId r))
      _ -> Left [NoRoot] -- roots 的長度已由 errs 檢查過,此分支不可能發生
  where
    nodeId = metaId . nodMeta

    -- 第一趟:建 id → Node 的索引並收集重複 id
    byId = M.fromList [(nodeId n, n) | n <- nodes]
    dupIds = nub [i | i <- map nodeId nodes, count i > 1]
    count i = length (filter ((== i) . nodeId) nodes)

    roots = [n | n <- nodes, nodParent n == Nothing]
    rootErrs = case map nodeId roots of
      [] -> [NoRoot]
      [_] -> []
      rs -> [MultipleRoots rs]

    orphanErrs =
      [ OrphanNode (nodeId n) p
      | n <- nodes
      , Just p <- [nodParent n]
      , not (M.member p byId)
      ]

    cycleErrs = map Cycle (nub (mapMaybe (findCycle byId) (map nodeId nodes)))

    -- 每個父節點下的 order 必須唯一
    orderErrs =
      [ DuplicateOrder p o (map nodeId sibs)
      | (p, kids) <- M.toList childrenOf
      , (o, sibs) <- M.toList (groupOn nodOrder kids)
      , length sibs > 1
      ]

    rootMismatchErrs = case map nodeId roots of
      [r] | r /= lvlRoot lvl -> [RootMismatch (lvlRoot lvl) r]
      _ -> []

    errs =
      map DuplicateNodeId dupIds
        ++ rootErrs
        ++ orphanErrs
        ++ cycleErrs
        ++ orderErrs
        ++ rootMismatchErrs

    childrenOf =
      M.fromListWith
        (flip (++))
        [(p, [n]) | n <- nodes, Just p <- [nodParent n]]

    -- 環已在 errs 排除,這裡的遞迴保證終止
    grow i =
      NodeTree
        (byId M.! i)
        (map (grow . nodeId) (sortOn nodOrder (M.findWithDefault [] i childrenOf)))

groupOn :: (Ord k) => (a -> k) -> [a] -> M.Map k [a]
groupOn f xs = M.fromListWith (flip (++)) [(f x, [x]) | x <- xs]

-- | 從一個節點往上追父節點,回到自己走過的節點就是環。
-- 回傳的序列旋轉成以最小 id 起始,同一個環從不同節點出發會得到相同結果。
findCycle :: M.Map Id Node -> Id -> Maybe [Id]
findCycle byId = go []
  where
    go path cur
      | cur `elem` path = Just (canonical (dropWhile (/= cur) (reverse path)))
      | otherwise = case M.lookup cur byId >>= nodParent of
          Nothing -> Nothing
          Just p -> go (cur : path) p

canonical :: [Id] -> [Id]
canonical [] = []
canonical xs = minimum [drop n xs ++ take n xs | n <- [0 .. length xs - 1]]

-- | 前序走訪,同層依 @order@ 排序(建樹時已排好)。
preorder :: NodeTree -> [Node]
preorder (NodeTree n kids) = n : concatMap preorder kids

-- | 取出以某個節點為根的子樹。
subtreeAt :: Id -> NodeTree -> Maybe NodeTree
subtreeAt i t@(NodeTree n kids)
  | metaId (nodMeta n) == i = Just t
  | otherwise = firstJust (map (subtreeAt i) kids)

-- | 根到指定節點的完整路徑(含頭尾)。
pathTo :: Id -> NodeTree -> Maybe [Node]
pathTo i (NodeTree n kids)
  | metaId (nodMeta n) == i = Just [n]
  | otherwise = (n :) <$> firstJust (map (pathTo i) kids)

nodesOfKind :: NodeKind -> NodeTree -> [Node]
nodesOfKind k t = [n | n <- preorder t, nodKind n == k]

-- | 子樹內所有 Node 關聯到的 Entity,依前序去重。
entitiesIn :: NodeTree -> [Ref]
entitiesIn t = nub (concatMap nodEntities (preorder t))

-- | 列出所有 @convergesTo@ 標註,以及它是否指向本 Level 內存在的 Node。
--
-- ADR-004 明說合流是標註不是結構,因此只能靠檢查發現懸空——這是 P2
-- @aapms level lint@ 的資料來源。跨 Vault 的 target 一律視為不存在,
-- 因為它不可能指向本 Level 內的 Node。
convergenceReport :: NodeTree -> [(Id, Ref, Bool)]
convergenceReport t =
  [ (metaId (nodMeta n), linkTarget l, exists (linkTarget l))
  | n <- preorder t
  , l <- metaLinks (nodMeta n)
  , linkKind l == ConvergesTo
  ]
  where
    ids = S.fromList (map (metaId . nodMeta) (preorder t))
    exists r = refVault r == Nothing && S.member (refId r) ids

firstJust :: [Maybe a] -> Maybe a
firstJust xs = case [x | Just x <- xs] of
  (x : _) -> Just x
  [] -> Nothing
