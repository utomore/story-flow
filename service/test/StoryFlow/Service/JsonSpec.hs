-- | T7:請求與 View 型別的 JSON round-trip。
--
-- service-and-interfaces/F003 的 servant API 型別直接吃這一套編碼,service-and-interfaces/F002 的 @--json@ 也是。
-- 編碼規則只有一份,所以只要 round-trip 在這裡守住,三個介面就不可能各自漂移。
module StoryFlow.Service.JsonSpec (spec) where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, toJSON, (.=))
import Data.Aeson.Key (toString)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Value (Object))
import Data.Time (fromGregorian)
import StoryFlow.Core.Entity (Entity (..))
import StoryFlow.Core.Level (Level (..), Node (..), NodeKind (KCast, KScene))
import StoryFlow.Core.Link (Link (..), LinkKind (Involves, PartOf))
import StoryFlow.Core.Meta
import StoryFlow.Core.Tree (NodeTree (..))
import StoryFlow.Service
import StoryFlow.Service.Fixtures (idOf, newEntity, newFragment, newLevel, newNode, refOf)
import Test.Hspec

spec :: Spec
spec = describe "JSON 編解碼" $ do
  it "請求型別 round-trip 不失真" $ do
    roundTrip (newEntity "character" "琳達" "第七織手")
    roundTrip
      (newEntity "character" "琳達" "第七織手")
        { nerTags = ["主角"]
        , nerAliases = ["小琳"]
        , nerTimeline = Timeline (Just "崩塌前") (Just 3)
        , nerLinks = [Link PartOf (refOf "ent-7f3a") (Just "註解")]
        , nerSource = Agent "claude-code"
        }
    roundTrip (newFragment "外貌" "銀灰短髮")
    roundTrip (newFragment "外貌" "銀灰短髮") {nfrType = Just "character-fragment", nfrStatus = Just Canon}
    roundTrip (newLevel "教室" "午後的教室" KScene)
    roundTrip (newNode "出場人物" KCast)
    roundTrip emptyPatch
    roundTrip emptyPatch {epTitle = Just "新標題", epStatus = Just Deprecated}

  it "View 型別 round-trip 不失真" $ do
    roundTrip (EntityView sampleEntity "characters/琳達.md" (Just "ent-7f3b") ["警告"])
    roundTrip (EntityView sampleEntity "characters/琳達.md" Nothing [])
    roundTrip (LevelView sampleLevel sampleTree "levels/教室.md")
    roundTrip (VaultView "liftgame" "/tmp/liftgame" (Just 12))
    roundTrip (VaultView "liftgame" "/tmp/liftgame" Nothing)
    roundTrip (SearchHit sampleMeta "……織紋……" (Just 0.8))
    roundTrip (SearchHit sampleMeta "……織紋……" Nothing)
    roundTrip (LinkReport [aLink] [(idOf "ent-7f3c", aLink)])
    roundTrip (IndexReport 5 ["某個檔案解析失敗"])
    roundTrip (DeleteReport "characters/琳達.md" [idOf "ent-7f3a"] [(idOf "ent-c41f", aLink)])

  it "EntityView 的 JSON 有 path 與 warnings 鍵" $ do
    let v = EntityView sampleEntity "characters/琳達.md" Nothing ["警告"]
    keysOf (toJSON v) `shouldContain` ["path"]
    keysOf (toJSON v) `shouldContain` ["warnings"]

  it "Maybe 欄位沒值時整個鍵不出現,不是 null" $ do
    keysOf (toJSON (EntityView sampleEntity "p" Nothing [])) `shouldNotContain` ["anchor"]
    keysOf (toJSON (VaultView "v" "r" Nothing)) `shouldNotContain` ["entity_count"]
    keysOf (toJSON emptyPatch) `shouldBe` []

  -- conflict-detection/F003 T2:相關度是選配欄位,LIKE 路徑給不出來。
  it "SearchHit 的 score 有值才出現" $ do
    let withScore = SearchHit sampleMeta "……織紋……" (Just 0.8)
        without = SearchHit sampleMeta "……織紋……" Nothing
    keysOf (toJSON withScore) `shouldContain` ["score"]
    keysOf (toJSON without) `shouldNotContain` ["score"]
    -- round-trip 不失真:0.8 進去 0.8 出來,Nothing 進去 Nothing 出來
    (shScore <$> decode (encode withScore)) `shouldBe` Just (Just 0.8)
    (shScore <$> decode (encode without)) `shouldBe` Just (Nothing :: Maybe Double)

  it "反向關聯編成有鍵名的物件,不是二元陣列" $ do
    let r = LinkReport [] [(idOf "ent-7f3c", aLink)]
    toJSON r
      `shouldBe` object
        [ "outgoing" .= ([] :: [Link])
        , "incoming" .= [object ["source" .= idOf "ent-7f3c", "link" .= aLink]]
        ]

roundTrip :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
roundTrip x = decode (encode x) `shouldBe` Just x

keysOf :: Value -> [String]
keysOf (Object o) = map toString (KM.keys o)
keysOf _ = []

-- 範例值 -----------------------------------------------------------------------

aLink :: Link
aLink = Link Involves (refOf "ent-7f3a") Nothing

sampleMeta :: Meta
sampleMeta =
  Meta
    { metaId = idOf "ent-7f3a"
    , metaVault = "liftgame"
    , metaType = "character"
    , metaTitle = "琳達"
    , metaSummary = "第七織手"
    , metaTags = ["主角"]
    , metaStatus = Canon
    , metaTimeline = Timeline (Just "崩塌前") Nothing
    , metaAliases = ["小琳"]
    , metaLinks = [aLink]
    , metaSource = Human
    , metaRevision = 3
    , metaCreated = fromGregorian 2026 8 16
    , metaUpdated = fromGregorian 2026 8 17
    }

sampleEntity :: Entity
sampleEntity = Entity sampleMeta "正文"

sampleLevel :: Level
sampleLevel = Level sampleMeta {metaId = idOf "lvl-3a01", metaType = "level"} (idOf "nod-0001")

sampleTree :: NodeTree
sampleTree = NodeTree (node "nod-0001" Nothing KScene 0) [NodeTree (node "nod-0002" (Just "nod-0001") KCast 0) []]
  where
    node i parent kind order =
      Node
        { nodMeta = sampleMeta {metaId = idOf i, metaType = "node"}
        , nodLevel = idOf "lvl-3a01"
        , nodParent = fmap idOf parent
        , nodOrder = order
        , nodKind = kind
        , nodEntities = [refOf "ent-7f3a"]
        }
