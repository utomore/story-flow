-- | Level 與 Node —— 場景的結構,以及場景樹五條不變量的錯誤語彙。
--
-- ADR-003:Node 只承載樹的位置、演出種類、以及指向 Entity 的關聯;
-- 「這句對話寫什麼」「琳達是誰」一律是 Entity。
--
-- 'TreeError' \/ 'renderTreeError' 住這裡而不住 "Aapms.Core.Tree":建樹演算法
-- ('Aapms.Core.Tree.buildTree')是推導,而__它的失敗語彙是資料__——落地層的
-- 'Aapms.Store.Types.StoreError' 與 'Aapms.Store.Types.IndexIssue' 都把它捧在
-- 建構子裡,型別層的模組不該為了一個錯誤 ADT 去依賴一個做推導的模組。
-- "Aapms.Core.Tree" 原樣 re-export 這兩個名字,既有呼叫端不受影響。
module Aapms.Core.Level
  ( Level (..)
  , Node (..)
  , NodeKind (..)
  , allNodeKinds
  , renderNodeKind
  , parseNodeKind
  , LevelError (..)

    -- * 場景樹的錯誤語彙
  , TreeError (..)
  , renderTreeError
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id, Ref, renderId)
import Aapms.Core.Meta (Meta)

data Level = Level
  { lvlMeta :: Meta
  , -- | 根 Node 的 id
    lvlRoot :: Id
  }
  deriving stock (Show, Eq)

-- | 封閉集合。ADR-003:Node 的 kind 是引擎自己的東西,不進型別註冊表。
data NodeKind
  = KScene
  | KCast
  | KCamera
  | KInteraction
  | KDialogue
  | KBranch
  deriving stock (Show, Eq, Ord, Enum, Bounded)

allNodeKinds :: [NodeKind]
allNodeKinds = [minBound .. maxBound]

renderNodeKind :: NodeKind -> Text
renderNodeKind = \case
  KScene -> "scene"
  KCast -> "cast"
  KCamera -> "camera"
  KInteraction -> "interaction"
  KDialogue -> "dialogue"
  KBranch -> "branch"

parseNodeKind :: Text -> Either LevelError NodeKind
parseNodeKind t =
  case lookup t [(renderNodeKind k, k) | k <- allNodeKinds] of
    Just k -> Right k
    Nothing -> Left (UnknownNodeKind t)

data Node = Node
  { nodMeta :: Meta
  , -- | 所屬 Level
    nodLevel :: Id
  , -- | @Nothing@ = 根節點
    nodParent :: Maybe Id
  , -- | 同層兄弟排序
    nodOrder :: Int
  , nodKind :: NodeKind
  , -- | 關聯到的 Entity。允許多個,建議一個。
    -- entity-graph-core/F003 解析 Markdown 時由 @involves@ / @references@ 關聯填入。
    nodEntities :: [Ref]
  }
  deriving stock (Show, Eq)

newtype LevelError
  = UnknownNodeKind Text
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- 場景樹的錯誤語彙

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
