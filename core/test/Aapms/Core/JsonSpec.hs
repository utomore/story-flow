-- | graph-core/F001 T12 的對照測試:全部核心型別(含六種節點與 AnyNode)的
-- aeson 編解碼,decode . encode 與 eitherDecodeStrictText 都要相等。
module Aapms.Core.JsonSpec (spec) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Core.AnyNode
import Aapms.Core.Asset
import Aapms.Core.Entity
import Aapms.Core.Fixtures
import Aapms.Core.Id
import Aapms.Core.Json ()
import Aapms.Core.Level
import Aapms.Core.Link
import Aapms.Core.Meta
import Aapms.Core.Pack
import Test.Hspec

-- | 一份填滿的 Meta,確保 round-trip 測到每一個欄位,含 uses / custom 關聯與
-- 跨 Vault 的 target。
fullMeta :: Meta
fullMeta =
  (metaOf "ent-7f3a" "琳達")
    { metaType = typeOf "character-fragment"
    , metaSummary = "埃提亞的第七織手,因塔主徵召失去雙親而敵視議會"
    , metaTags = ["動機", "仇恨"]
    , metaStatus = Canon
    , metaTimeline = Just (Timeline (Just "埃提亞崩塌前") (Just 3))
    , metaAliases = ["小琳", "第七織手"]
    , metaLinks =
        [ Link PartOf (refOf "ent-7f3a") Nothing
        , Link Contradicts (refOf "ent-91cc") (Just "對雙親死因的敘述不一致")
        , Link (Custom "師承於") (refOf "vlt-a0c4e1f8:ent-00ff") Nothing
        , Link Uses (refOf "ast-1a2b3c4d") Nothing
        ]
    , metaSource = Agent "claude-code"
    , metaRevision = Revision 3
    }

fullEntity :: Entity
fullEntity = Entity fullMeta "那年她十四歲……"

-- | @nodMeta@ 的 id 刻意換成 @nod-@ 前綴——'AnyNode' 的 'FromJSON' 依 id 前綴
-- 判別節點種類('Aapms.Core.AnyNode.prefixOf' 的反函式),沿用 'fullMeta' 的
-- @ent-7f3a@ 會讓 round-trip 決回 'NEntity' 而非 'NNode'。
fullNode :: Node
fullNode =
  Node
    { nodMeta = fullMeta {metaType = typeOf "node", metaId = idOf "nod-9001"}
    , nodLevel = idOf "lvl-3a01"
    , nodParent = Just (idOf "nod-0001")
    , nodOrder = 2
    , nodKind = KDialogue
    , nodEntities = [entLinda, entTower]
    }

-- | @decode . encode == Just x@,並與 'eitherDecodeStrictText' 對照同一份
-- encode 出來的文字(graph-core/F001 T12 逐字要求)。
roundTrip :: (ToJSON a, FromJSON a, Eq a, Show a) => a -> Expectation
roundTrip x = do
  decode (encode x) `shouldBe` Just x
  eitherDecodeStrictText (encodeToText x) `shouldBe` Right x

encodeToText :: (ToJSON a) => a -> T.Text
encodeToText = TE.decodeUtf8 . BSL.toStrict . encode

-- | 取出編碼後最上層的鍵。
keysOf :: (ToJSON a) => a -> [String]
keysOf x = case toJSON x of
  Object o -> map K.toString (KM.keys o)
  _ -> []

spec :: Spec
spec = do
  describe "round-trip —— decode . encode == Just x,eitherDecodeStrictText 相同" $ do
    it "Meta" $ roundTrip fullMeta
    it "Entity" $ roundTrip fullEntity
    it "Level" $ roundTrip classroomLevel
    it "Node" $ roundTrip fullNode
    it "Asset" $ roundTrip sampleAsset
    it "Pack" $ roundTrip samplePack
    it "License" $ roundTrip sampleLicense
    it "AnyNode(六種建構子各一次)" $
      mapM_
        roundTrip
        [ NEntity fullEntity
        , NAsset sampleAsset
        , NPack samplePack
        , NLicense sampleLicense
        , NLevel classroomLevel
        , NNode fullNode
        ]
    it "Link(核心、帶 note、自訂、uses)" $
      mapM_ roundTrip (metaLinks fullMeta)
    it "Status 四種" $
      mapM_ roundTrip [Draft, Canon, Deprecated, Missing]
    it "Source 五種" $
      mapM_ roundTrip [Human, Agent "claude-code", Workshop "character", Scan, Ai "gpt-5"]
    it "Timeline 四種組合" $
      mapM_
        roundTrip
        [ Timeline Nothing Nothing
        , Timeline (Just "崩塌前") Nothing
        , Timeline Nothing (Just 3)
        , Timeline (Just "崩塌前") (Just 3)
        ]
    it "Ref(本 Vault 與跨 Vault)" $
      mapM_ roundTrip [refOf "ent-7f3a", refOf "vlt-a0c4e1f8:ent-00ff"]
    it "Id" $ roundTrip (idOf "ent-7f3a")
    it "VaultId" $ roundTrip (vaultOf "vlt-a0c4e1f8")
    it "TypeKey" $ roundTrip (typeOf "character-fragment")
    it "Revision" $ roundTrip (Revision 7)
    it "Sha256 / LogicalName" $ do
      roundTrip (Sha256 "deadbeef")
      roundTrip (LogicalName "ui_gui_travel-book-frame_001")
    it "AiDisclosure 四種" $
      mapM_ roundTrip [AiUnknown, AiNone, AiAssisted, AiGenerated]
    it "NodeKind 六種" $ mapM_ roundTrip allNodeKinds
    it "LinkKind 十個核心加自訂" $
      mapM_ roundTrip (coreLinkKinds ++ [Custom "師承於"])

  describe "編碼形狀" $ do
    it "Ref 編碼為單一字串而非物件" $ do
      toJSON (refOf "vlt-a0c4e1f8:ent-00ff") `shouldBe` String "vlt-a0c4e1f8:ent-00ff"
      toJSON (refOf "ent-7f3a") `shouldBe` String "ent-7f3a"

    it "Id 編碼為單一字串" $
      toJSON (idOf "ent-7f3a") `shouldBe` String "ent-7f3a"

    it "Status / Source / NodeKind / LinkKind 都編碼為字串" $ do
      toJSON Canon `shouldBe` String "canon"
      toJSON (Agent "claude-code") `shouldBe` String "agent:claude-code"
      toJSON KDialogue `shouldBe` String "dialogue"
      toJSON ConvergesTo `shouldBe` String "convergesTo"
      toJSON Uses `shouldBe` String "uses"
      toJSON Depicts `shouldBe` String "depicts"

    it "Timeline 兩欄皆 Nothing 時編碼為空物件" $
      toJSON (Timeline Nothing Nothing) `shouldBe` object []

    it "Timeline 為 Nothing 時 Meta 不出現 timeline 鍵" $
      keysOf (fullMeta {metaTimeline = Nothing})
        `shouldNotContain` ["timeline"]

    it "Timeline 為 Just 時 Meta 出現 timeline 鍵" $
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

    it "Asset 是扁平的,kind 專屬 meta 與 body 同一層" $ do
      keysOf sampleAsset `shouldContain` ["meta"]
      keysOf sampleAsset `shouldContain` ["body"]
      keysOf sampleAsset `shouldContain` ["sha256"]

    it "Pack 是扁平的,ai_disclosure 與 body 同一層" $ do
      keysOf samplePack `shouldContain` ["ai_disclosure"]
      keysOf samplePack `shouldContain` ["body"]

    it "License 是扁平的,commercial 與 attribution_required 一定出現" $ do
      keysOf sampleLicense `shouldContain` ["commercial"]
      keysOf sampleLicense `shouldContain` ["attribution_required"]

    it "AnyNode 依 id 前綴解碼回正確的建構子" $ do
      decode (encode (NAsset sampleAsset)) `shouldBe` Just (NAsset sampleAsset)
      decode (encode (NPack samplePack)) `shouldBe` Just (NPack samplePack)
      decode (encode (NLicense sampleLicense)) `shouldBe` Just (NLicense sampleLicense)

  describe "解碼的寬容度" $ do
    it "選填欄位可省略,取預設值" $
      let j =
            object
              [ "id" .= String "ent-7f3a"
              , "vault" .= String "vlt-a0c4e1f8"
              , "type" .= String "character-fragment"
              , "title" .= String "琳達"
              , "created" .= String "2026-08-16"
              , "updated" .= String "2026-08-16"
              ]
          m = decode (encode j) :: Maybe Meta
       in do
            fmap metaSummary m `shouldBe` Just ""
            fmap metaStatus m `shouldBe` Just Draft
            fmap metaRevision m `shouldBe` Just (Revision 1)
            fmap metaSource m `shouldBe` Just Human
            fmap metaTags m `shouldBe` Just []
            fmap metaTimeline m `shouldBe` Just Nothing

    it "id 格式不合法時解碼失敗" $
      (decode "\"ent-7g3a\"" :: Maybe Id) `shouldBe` Nothing

    it "status 不認得時解碼失敗" $
      (decode "\"published\"" :: Maybe Status) `shouldBe` Nothing

    it "ai_disclosure 不認得時解碼失敗" $
      (decode "\"maybe\"" :: Maybe AiDisclosure) `shouldBe` Nothing

    -- 注意:這裡不能寫 decode "\"師承於\"" —— ByteString 的 IsString 實例會把
    -- 非 ASCII 字元截成低 8 位,測到的就不是 UTF-8 了。一律經由 encode 產生輸入。
    it "不認得的關聯字串解碼為 Custom,不失敗" $
      decode (encode (String "師承於")) `shouldBe` Just (Custom "師承於")
