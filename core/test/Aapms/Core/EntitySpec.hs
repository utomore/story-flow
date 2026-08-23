-- | entity-graph-core/F002 T4 的對照測試:Entity / Level / Node 與 NodeKind。
module Aapms.Core.EntitySpec (spec) where

import Data.Text (Text)
import Aapms.Core.Entity
import Aapms.Core.Fixtures
import Aapms.Core.Id (Ref)
import Aapms.Core.Level
import Aapms.Core.Meta
import Test.Hspec

-- | 從教室場景取出指定 id 的 Node。取不到就是 fixture 寫錯,直接爆掉。
nodeById :: Text -> Node
nodeById i =
  case [n | n <- classroomNodes, metaId (nodMeta n) == idOf i] of
    (n : _) -> n
    [] -> error ("fixture 沒有這個 node:" <> show i)

linda :: Entity
linda =
  Entity
    { entMeta =
        (metaOf "ent-7f3a" "琳達")
          { metaType = "character-fragment"
          , metaSummary = "銀灰短髮,左眼下方有織紋刺青"
          , metaTags = ["外觀"]
          , metaAliases = ["小琳", "第七織手"]
          , metaTimeline = Timeline (Just "埃提亞崩塌前") (Just 1)
          }
    , entBody = "銀灰短髮剪到耳際……"
    }

spec :: Spec
spec = do
  describe "Entity" $ do
    it "由 Meta 加 body 組成,兩者都取得回來" $ do
      metaTitle (entMeta linda) `shouldBe` "琳達"
      entBody linda `shouldBe` "銀灰短髮剪到耳際……"

    it "Meta 的十四個欄位對照 system.md 欄位表逐項存在" $ do
      let m = entMeta linda
      metaId m `shouldBe` idOf "ent-7f3a"
      metaVault m `shouldBe` "liftgame"
      metaType m `shouldBe` "character-fragment"
      metaTitle m `shouldBe` "琳達"
      metaSummary m `shouldBe` "銀灰短髮,左眼下方有織紋刺青"
      metaTags m `shouldBe` ["外觀"]
      metaStatus m `shouldBe` Canon
      metaTimeline m `shouldBe` Timeline (Just "埃提亞崩塌前") (Just 1)
      metaAliases m `shouldBe` ["小琳", "第七織手"]
      metaLinks m `shouldBe` []
      metaSource m `shouldBe` Human
      metaRevision m `shouldBe` 1
      metaCreated m `shouldBe` day0
      metaUpdated m `shouldBe` day0

  describe "Level" $
    it "有 Meta 與 root 兩部分" $ do
      lvlRoot classroomLevel `shouldBe` idOf "nod-0001"
      metaTitle (lvlMeta classroomLevel) `shouldBe` "教室"

  describe "Node" $ do
    it "有 level / parent / order / kind / entities 五個專屬欄位" $ do
      let n = nodeById "nod-0002"
      nodLevel n `shouldBe` idOf "lvl-3a01"
      nodParent n `shouldBe` Just (idOf "nod-0001")
      nodOrder n `shouldBe` 1
      nodKind n `shouldBe` KCast
      nodEntities n `shouldBe` ([entLinda, entTower] :: [Ref])

    it "根節點的 parent 為 Nothing" $
      nodParent (nodeById "nod-0001") `shouldBe` Nothing

  describe "NodeKind" $ do
    it "恰好六個建構子" $
      length allNodeKinds `shouldBe` 6

    it "六個建構子的 render 與 parse 互為反函式" $
      mapM_ (\k -> parseNodeKind (renderNodeKind k) `shouldBe` Right k) allNodeKinds

    it "渲染成 system.md 的字串" $
      map renderNodeKind allNodeKinds
        `shouldBe` ["scene", "cast", "camera", "interaction", "dialogue", "branch"]

    it "不認得的字串回 UnknownNodeKind" $
      parseNodeKind "narration" `shouldBe` Left (UnknownNodeKind "narration")
