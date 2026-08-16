-- | func-0002 T9 的對照測試:全部核心型別的 aeson 編解碼。
module StoryFlow.Core.JsonSpec (spec) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import StoryFlow.Core.Entity
import StoryFlow.Core.Fixtures
import StoryFlow.Core.Id
import StoryFlow.Core.Json ()
import StoryFlow.Core.Level
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import Test.Hspec

-- | 一份填滿的 Meta,確保 round-trip 測到每一個欄位。
fullMeta :: Meta
fullMeta =
  (metaOf "ent-7f3a" "琳達")
    { metaType = "character-fragment"
    , metaSummary = "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
    , metaTags = ["動機", "仇恨"]
    , metaStatus = Canon
    , metaTimeline = Timeline (Just "埃提亞崩塌前") (Just 3)
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks =
        [ Link PartOf (refOf "ent-7f3a") Nothing
        , Link Contradicts (refOf "ent-91cc") (Just "對雙親死因的敘述不一致")
        , Link (Custom "師承於") (refOf "shared-lore:ent-00ff") Nothing
        ]
    , metaSource = Agent "claude-code"
    , metaRevision = 3
    }

fullEntity :: Entity
fullEntity = Entity fullMeta "那年她十四歲……"

fullNode :: Node
fullNode =
  Node
    { nodMeta = fullMeta {metaType = "node"}
    , nodLevel = idOf "lvl-3a01"
    , nodParent = Just (idOf "nod-0001")
    , nodOrder = 2
    , nodKind = KDialogue
    , nodEntities = [entLinda, entTower]
    }

-- | @decode . encode == Just x@
roundTrip :: (ToJSON a, FromJSON a, Eq a, Show a) => a -> Expectation
roundTrip x = decode (encode x) `shouldBe` Just x

-- | 取出編碼後最上層的鍵。
keysOf :: (ToJSON a) => a -> [String]
keysOf x = case toJSON x of
  Object o -> map K.toString (KM.keys o)
  _ -> []

spec :: Spec
spec = do
  describe "round-trip —— decode . encode == Just x" $ do
    it "Meta" $ roundTrip fullMeta
    it "Entity" $ roundTrip fullEntity
    it "Level" $ roundTrip classroomLevel
    it "Node" $ roundTrip fullNode
    it "Link(三種:核心、帶 note、自訂)" $
      mapM_ roundTrip (metaLinks fullMeta)
    it "Status 三種" $
      mapM_ roundTrip [Draft, Canon, Deprecated]
    it "Source 三種" $
      mapM_ roundTrip [Human, Agent "claude-code", Workshop "character"]
    it "Timeline 四種組合" $
      mapM_
        roundTrip
        [ emptyTimeline
        , Timeline (Just "崩塌前") Nothing
        , Timeline Nothing (Just 3)
        , Timeline (Just "崩塌前") (Just 3)
        ]
    it "Ref(本 Vault 與跨 Vault)" $
      mapM_ roundTrip [refOf "ent-7f3a", refOf "shared-lore:ent-00ff"]
    it "Id" $ roundTrip (idOf "ent-7f3a")
    it "NodeKind 六種" $ mapM_ roundTrip allNodeKinds
    it "LinkKind 八個核心加自訂" $
      mapM_ roundTrip (coreLinkKinds ++ [Custom "師承於"])

  describe "編碼形狀" $ do
    it "Ref 編碼為單一字串而非物件" $ do
      toJSON (refOf "shared-lore:ent-00ff") `shouldBe` String "shared-lore:ent-00ff"
      toJSON (refOf "ent-7f3a") `shouldBe` String "ent-7f3a"

    it "Id 編碼為單一字串" $
      toJSON (idOf "ent-7f3a") `shouldBe` String "ent-7f3a"

    it "Status / Source / NodeKind / LinkKind 都編碼為字串" $ do
      toJSON Canon `shouldBe` String "canon"
      toJSON (Agent "claude-code") `shouldBe` String "agent:claude-code"
      toJSON KDialogue `shouldBe` String "dialogue"
      toJSON ConvergesTo `shouldBe` String "convergesTo"

    it "Timeline 兩欄皆 Nothing 時不產生空鍵" $
      toJSON emptyTimeline `shouldBe` object []

    it "Timeline 為空時 Meta 不出現 timeline 鍵" $
      keysOf (fullMeta {metaTimeline = emptyTimeline})
        `shouldNotContain` ["timeline"]

    it "Timeline 非空時 Meta 出現 timeline 鍵" $
      keysOf fullMeta `shouldContain` ["timeline"]

    it "Link 沒有 note 時不產生 note 鍵" $
      toJSON (Link PartOf (refOf "ent-7f3a") Nothing)
        `shouldBe` object ["kind" .= String "partOf", "target" .= String "ent-7f3a"]

    it "Entity 是扁平的 —— Meta 欄位與 body 同一層" $ do
      keysOf fullEntity `shouldContain` ["body"]
      keysOf fullEntity `shouldContain` ["summary"]
      keysOf fullEntity `shouldNotContain` ["meta"]

    it "Level 的 root 與 Meta 欄位同一層" $
      keysOf classroomLevel `shouldContain` ["root"]

    it "Node 的專屬欄位與 Meta 欄位同一層" $
      mapM_
        (\k -> keysOf fullNode `shouldContain` [k])
        ["level", "parent", "order", "kind", "entities"]

    it "根節點沒有 parent 鍵" $
      keysOf (fullNode {nodParent = Nothing}) `shouldNotContain` ["parent"]

  describe "解碼的寬容度" $ do
    it "選填欄位可省略,取預設值" $
      let j =
            object
              [ "id" .= String "ent-7f3a"
              , "vault" .= String "liftgame"
              , "type" .= String "character-fragment"
              , "title" .= String "琳達"
              , "created" .= String "2026-08-16"
              , "updated" .= String "2026-08-16"
              ]
          m = decode (encode j) :: Maybe Meta
       in do
            fmap metaSummary m `shouldBe` Just ""
            fmap metaStatus m `shouldBe` Just Draft
            fmap metaRevision m `shouldBe` Just 1
            fmap metaSource m `shouldBe` Just Human
            fmap metaTags m `shouldBe` Just []
            fmap metaTimeline m `shouldBe` Just emptyTimeline

    it "id 格式不合法時解碼失敗" $
      (decode "\"ent-7g3a\"" :: Maybe Id) `shouldBe` Nothing

    it "status 不認得時解碼失敗" $
      (decode "\"published\"" :: Maybe Status) `shouldBe` Nothing

    -- 注意:這裡不能寫 decode "\"師承於\"" —— ByteString 的 IsString 實例會把
    -- 非 ASCII 字元截成低 8 位,測到的就不是 UTF-8 了。一律經由 encode 產生輸入。
    it "不認得的關聯字串解碼為 Custom,不失敗" $
      decode (encode (String "師承於")) `shouldBe` Just (Custom "師承於")
