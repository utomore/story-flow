-- | T5:@level show@ 的樹形狀與架構文件一致。
--
-- 這一條是逐行比對而不是「含有某些字」:樹的價值全在分支字元的位置,
-- @└─@ 與 @│@ 錯一格,作者就看不出哪個節點掛在誰底下。用 architecture.md
-- 的教室場景當底稿——那張圖是規格的一部分,不是舉例。
module StoryFlow.Cli.TreeSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (fromGregorian)
import StoryFlow.Cli.Render (renderLevelTree)
import StoryFlow.Core.Id (Id, parseId)
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (..))
import StoryFlow.Core.Meta (Meta (..), Source (Human), Status (Canon), emptyTimeline)
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Service (LevelView (..))
import Test.Hspec

spec :: Spec
spec = describe "level show 的樹" $ do
  it "六個 Node 的教室場景逐行等於 architecture.md 的圖" $
    T.lines (renderLevelTree classroom) `shouldBe` expected

  it "只有根節點時是兩行" $ do
    let only = classroom {lvTree = NodeTree (node "nod-0001" "午後的教室" KScene "午後的教室,窗外是崩塌後的天際線") []}
    length (T.lines (renderLevelTree only)) `shouldBe` 2

expected :: [Text]
expected =
  [ "lvl-3a01 教室"
  , "└─ nod-0001 scene        午後的教室,窗外是崩塌後的天際線"
  , "   ├─ nod-0002 cast      出場人物"
  , "   │  └─ nod-0004 interaction  琳達走向講台"
  , "   └─ nod-0003 camera    自窗外緩推至講台,焦段 35mm"
  ]

-- 底稿 -------------------------------------------------------------------------

classroom :: LevelView
classroom =
  LevelView
    { lvLevel = Level (meta "lvl-3a01" "教室" "崩塌後的午後教室") (idOf "nod-0001")
    , lvTree =
        NodeTree
          (node "nod-0001" "午後的教室" KScene "午後的教室,窗外是崩塌後的天際線")
          [ NodeTree
              (node "nod-0002" "出場人物" KCast "")
              [NodeTree (node "nod-0004" "琳達走向講台" KInteraction "") []]
          , NodeTree (node "nod-0003" "鏡頭" KCamera "自窗外緩推至講台,焦段 35mm") []
          ]
    , lvPath = "levels/教室.md"
    }

-- | 沒有 summary 的節點印標題:architecture.md 的圖裡「出場人物」與
-- 「琳達走向講台」就是這種——Level 檔的 meta 區塊只有 @kind@。
node :: Text -> Text -> NodeKind -> Text -> Node
node i title k summary =
  Node
    { nodMeta = (meta i title summary) {metaType = "node"}
    , nodLevel = idOf "lvl-3a01"
    , nodParent = Nothing
    , nodOrder = 0
    , nodKind = k
    , nodEntities = []
    }

meta :: Text -> Text -> Text -> Meta
meta i title summary =
  Meta
    { metaId = idOf i
    , metaVault = "liftgame"
    , metaType = "level"
    , metaTitle = title
    , metaSummary = summary
    , metaTags = []
    , metaStatus = Canon
    , metaTimeline = emptyTimeline
    , metaAliases = []
    , metaLinks = []
    , metaSource = Human
    , metaRevision = 1
    , metaCreated = fromGregorian 2026 8 16
    , metaUpdated = fromGregorian 2026 8 16
    }

idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error (show e)
