-- | 測試共用的資料。以 architecture.md 的「教室」場景為準,
-- 讓樹與走訪的測試對照的是文件裡真的畫出來的那棵樹。
module StoryFlow.Core.Fixtures
  ( -- * 建構輔助
    idOf
  , refOf
  , day0
  , time0
  , metaOf
  , nodeOf

    -- * 教室場景
  , classroomLevel
  , classroomNodes
  , entLinda
  , entTower
  , entDialogue
  ) where

import Data.Text (Text)
import Data.Time (Day, UTCTime (..), fromGregorian)
import StoryFlow.Core.Id
import StoryFlow.Core.Level
import StoryFlow.Core.Link
import StoryFlow.Core.Meta

-- | 由已知合法的字面值取得 'Id'。只給測試用,格式寫錯就讓測試直接爆掉。
idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("fixture 的 ref 不合法:" <> show e)

day0 :: Day
day0 = fromGregorian 2026 8 16

time0 :: UTCTime
time0 = UTCTime day0 0

-- | 最小可用的 'Meta':給 id 與 title,其餘取預設。
metaOf :: Text -> Text -> Meta
metaOf i title =
  Meta
    { metaId = idOf i
    , metaVault = "liftgame"
    , metaType = "plot-fragment"
    , metaTitle = title
    , metaSummary = title
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = emptyTimeline
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = 1
    , metaCreated = day0
    , metaUpdated = day0
    }

-- | id、標題、父節點、order、kind。
nodeOf :: Text -> Text -> Maybe Text -> Int -> NodeKind -> Node
nodeOf i title parent order kind =
  Node
    { nodMeta = metaOf i title
    , nodLevel = idOf "lvl-3a01"
    , nodParent = idOf <$> parent
    , nodOrder = order
    , nodKind = kind
    , nodEntities = []
    }

entLinda, entTower, entDialogue :: Ref
entLinda = refOf "ent-7f3a"
entTower = refOf "ent-8b20"
entDialogue = refOf "ent-d902"

classroomLevel :: Level
classroomLevel =
  Level
    { lvlMeta = (metaOf "lvl-3a01" "教室") {metaType = "level"}
    , lvlRoot = idOf "nod-0001"
    }

-- | architecture.md 的教室場景樹:
--
-- @
-- nod-0001 scene
--  ├─ nod-0002 cast            ├╌ 琳達 / 塔主
--  │   └─ nod-0004 interaction
--  │       └─ nod-0005 dialogue ╌ 對話內容
--  │           ├─ nod-0007 branch
--  │           │   └─ nod-0009 ╌convergesTo╌→ nod-0010
--  │           └─ nod-0008 branch
--  │               └─ nod-0010
--  └─ nod-0003 camera
-- @
classroomNodes :: [Node]
classroomNodes =
  [ nodeOf "nod-0001" "午後的教室" Nothing 1 KScene
  , (nodeOf "nod-0002" "出場人物" (Just "nod-0001") 1 KCast)
      { nodEntities = [entLinda, entTower]
      }
  , nodeOf "nod-0003" "鏡頭" (Just "nod-0001") 2 KCamera
  , nodeOf "nod-0004" "琳達走向講台" (Just "nod-0002") 1 KInteraction
  , (nodeOf "nod-0005" "第一次對峙" (Just "nod-0004") 1 KDialogue)
      { nodEntities = [entDialogue]
      }
  , nodeOf "nod-0007" "琳達選擇動手" (Just "nod-0005") 1 KBranch
  , nodeOf "nod-0008" "琳達選擇退讓" (Just "nod-0005") 2 KBranch
  , convergingNode
  , (nodeOf "nod-0010" "兩條路的匯合點" (Just "nod-0008") 1 KInteraction)
      { nodEntities = [entLinda]
      }
  ]

-- | 分支末端,以 @convergesTo@ 標註合流(ADR-0004:標註不是結構)。
convergingNode :: Node
convergingNode =
  let n = nodeOf "nod-0009" "動手之後" (Just "nod-0007") 1 KInteraction
   in n
        { nodMeta =
            (nodMeta n)
              { metaLinks = [Link ConvergesTo (refOf "nod-0010") Nothing]
              }
        }
