-- | 測試共用的資料。教室場景以 system.md 的樹為準;六種節點各留一份最小
-- fixture 供 graph-core/F001 新增的 Spec(Asset / Pack / License / AnyNode /
-- Json)重用。
module Aapms.Core.Fixtures
  ( -- * 建構輔助
    idOf
  , refOf
  , vaultOf
  , typeOf
  , day0
  , time0
  , metaOf
  , nodeOf

    -- * 教室場景(Entity / Level / Node)
  , classroomLevel
  , classroomNodes
  , entLinda
  , entTower
  , entDialogue

    -- * 六種節點各一份的最小 fixture
  , sampleEntity
  , sampleAsset
  , samplePack
  , sampleLicense
  , sampleLevel
  , sampleNode
  ) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Time (Day, UTCTime (..), fromGregorian)
import Aapms.Core.Asset
import Aapms.Core.Entity
import Aapms.Core.Id
import Aapms.Core.Level
import Aapms.Core.License
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Core.Pack

-- | 由已知合法的字面值取得 'Id'。只給測試用,格式寫錯就讓測試直接爆掉。
idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("fixture 的 id 不合法:" <> show e)

refOf :: Text -> Ref
refOf t = case parseRef t of
  Right r -> r
  Left e -> error ("fixture 的 ref 不合法:" <> show e)

-- | 由已知合法的 @vlt-\<hex\>@ 字面值取得 'VaultId'。
vaultOf :: Text -> VaultId
vaultOf t = case parseId t of
  Right (PVlt, i) -> VaultId (renderId i)
  Right (p, _) -> error ("fixture 的 vault id 前綴不是 vlt:" <> show p)
  Left e -> error ("fixture 的 vault id 不合法:" <> show e)

typeOf :: Text -> TypeKey
typeOf = TypeKey

day0 :: Day
day0 = fromGregorian 2026 8 16

time0 :: UTCTime
time0 = UTCTime day0 0

-- | 全部 fixture 共用的預設 vault,取自 design.md 的 parseRef 範例。
defaultVault :: VaultId
defaultVault = vaultOf "vlt-a0c4e1f8"

-- | 最小可用的 'Meta':給 id 與 title,其餘取預設。
metaOf :: Text -> Text -> Meta
metaOf i title =
  Meta
    { metaId = idOf i
    , metaVault = defaultVault
    , metaType = typeOf "plot-fragment"
    , metaTitle = title
    , metaSummary = title
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = Revision 1
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
    { lvlMeta = (metaOf "lvl-3a01" "教室") {metaType = typeOf "level"}
    , lvlRoot = idOf "nod-0001"
    }

-- | system.md 的教室場景樹:
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

-- | 分支末端,以 @convergesTo@ 標註合流(ADR-004:標註不是結構)。
convergingNode :: Node
convergingNode =
  let n = nodeOf "nod-0009" "動手之後" (Just "nod-0007") 1 KInteraction
   in n
        { nodMeta =
            (nodMeta n)
              { metaLinks = [Link ConvergesTo (refOf "nod-0010") Nothing]
              }
        }

-- 六種節點各一份的最小 fixture ---------------------------------------------

sampleEntity :: Entity
sampleEntity =
  Entity
    { entMeta = (metaOf "ent-7f3a" "琳達") {metaType = typeOf "character-fragment"}
    , entBody = "銀灰短髮剪到耳際……"
    }

sampleAsset :: Asset
sampleAsset =
  Asset
    { astMeta = (metaOf "ast-1a2b3c4d" "旅行手記畫框") {metaType = typeOf "asset-image"}
    , astName = Just (LogicalName "ui_gui_travel-book-frame_001")
    , astSha256 = Sha256 "deadbeefcafebabe0000000000000000000000000000000000000000000000"
    , astEntry = "ui/gui/travel-book-frame_001.png"
    , astExt = Just "png"
    , astKindMeta = object ["width" .= (512 :: Int), "height" .= (512 :: Int)]
    , astLicense = Just (refOf "lic-9f8e7d6c")
    , astAuthor = Just "Kenney"
    , astBody = ""
    }

samplePack :: Pack
samplePack =
  Pack
    { pckMeta = (metaOf "pck-2b3c4d5e" "Kenney UI Pack") {metaType = typeOf "asset-pack"}
    , pckVendor = Just "Kenney"
    , pckArchive = Just "packs/kenney/ui-pack.zip"
    , pckSha256 = Just (Sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd")
    , pckLicense = Just (refOf "lic-9f8e7d6c")
    , pckAuthor = Just (Author "Kenney" (Just "https://kenney.nl") Nothing)
    , pckSourceUrl = Just "https://kenney.nl/assets/ui-pack"
    , pckAiDisclosure = AiNone
    , pckBody = "UI 素材包……"
    }

sampleLicense :: License
sampleLicense =
  License
    { licMeta = (metaOf "lic-9f8e7d6c" "CC0") {metaType = typeOf "asset-license"}
    , licCommercial = True
    , licAttributionRequired = False
    , licCreditText = Nothing
    , licModificationAllowed = Just True
    , licRedistributionAllowed = Just True
    , licResaleAllowed = Just False
    , licNftAllowed = Just False
    , licSourceUrl = Just "https://creativecommons.org/publicdomain/zero/1.0/"
    , licFullText = Nothing
    }

sampleLevel :: Level
sampleLevel = classroomLevel

sampleNode :: Node
sampleNode = case classroomNodes of
  (n : _) -> n
  [] -> error "fixture 的教室場景不該是空的"
