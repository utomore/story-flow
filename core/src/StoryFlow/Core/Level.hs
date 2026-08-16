-- | Level 與 Node —— 場景的結構。
--
-- ADR-0003:Node 只承載樹的位置、演出種類、以及指向 Entity 的關聯;
-- 「這句對話寫什麼」「琳達是誰」一律是 Entity。
module StoryFlow.Core.Level
  ( Level (..)
  , Node (..)
  , NodeKind (..)
  , allNodeKinds
  , renderNodeKind
  , parseNodeKind
  , LevelError (..)
  ) where

import Data.Text (Text)
import StoryFlow.Core.Id (Id, Ref)
import StoryFlow.Core.Meta (Meta)

data Level = Level
  { lvlMeta :: Meta
  , -- | 根 Node 的 id
    lvlRoot :: Id
  }
  deriving stock (Show, Eq)

-- | 封閉集合。ADR-0003:Node 的 kind 是引擎自己的東西,不進型別註冊表。
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
    -- func-0003 解析 Markdown 時由 @involves@ / @references@ 關聯填入。
    nodEntities :: [Ref]
  }
  deriving stock (Show, Eq)

newtype LevelError
  = UnknownNodeKind Text
  deriving stock (Show, Eq)
