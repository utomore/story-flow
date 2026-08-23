-- | T7:Level 檔的解析,標題階層即樹(ADR-009)。
module Aapms.Md.ParseLevelSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Core.Id (Id)
import Aapms.Core.Level
import Aapms.Core.Meta
import Aapms.Core.Tree (buildTree, preorder)
import Aapms.Md
import Aapms.Md.Fixtures
import Test.Hspec

kindsOf :: Either [MdError] a -> [MdErrorKind]
kindsOf = either (map errKind) (const [])

doc :: Document
doc = docOf "levels/教室.md" classroomMd

lf :: LevelFile
lf = fst (levelFileOf doc)

nodeBy :: Text -> Node
nodeBy i = case filter ((== idOf i) . metaId . nodMeta) (lfNodes lf) of
  (n : _) -> n
  [] -> error ("找不到 Node " <> T.unpack i)

parentOf :: Text -> Maybe Id
parentOf = nodParent . nodeBy

spec :: Spec
spec = do
  describe "檔案的判別" $
    it "frontmatter 的 type: level 走 Level 解析" $
      documentKind doc `shouldBe` Right DocLevel

  describe "Level 本身" $ do
    it "lvlMeta 逐欄比對 frontmatter" $ do
      let m = lvlMeta (lfLevel lf)
      metaId m `shouldBe` idOf "lvl-3a01"
      metaVault m `shouldBe` "liftgame"
      metaType m `shouldBe` "level"
      metaTitle m `shouldBe` "教室"
      metaSummary m `shouldBe` "崩塌後的午後教室,琳達與塔主的第一次對峙"
      metaStatus m `shouldBe` Canon

    it "frontmatter 沒寫 root 時以第一個節填入,作者不必手寫" $
      lvlRoot (lfLevel lf) `shouldBe` idOf "nod-0001"

    it "frontmatter 寫了相符的 root 時照收" $ do
      let withRoot = T.replace "type: level" "type: level\nroot: nod-0001" classroomMd
      fmap (lvlRoot . lfLevel . fst) (parseLevelFile (docOf "levels/教室.md" withRoot))
        `shouldBe` Right (idOf "nod-0001")

    it "frontmatter 的 root 與第一個節不符 → RootMismatch" $ do
      let withRoot = T.replace "type: level" "type: level\nroot: nod-0009" classroomMd
      kindsOf (parseLevelFile (docOf "levels/教室.md" withRoot))
        `shouldBe` [RootMismatch (idOf "nod-0009") (idOf "nod-0001")]

  describe "標題階層 → parent / order" $ do
    it "解出 6 個 Node(教室範例檔的六個標題)" $
      length (lfNodes lf) `shouldBe` 6

    it "根節點 nod-0001 的 parent 是 Nothing" $
      parentOf "nod-0001" `shouldBe` Nothing

    it "nod-0002 與 nod-0003 的 parent 皆為 nod-0001" $ do
      parentOf "nod-0002" `shouldBe` Just (idOf "nod-0001")
      parentOf "nod-0003" `shouldBe` Just (idOf "nod-0001")

    it "同一父節點下的 order 依文件順序為 1、2" $ do
      nodOrder (nodeBy "nod-0002") `shouldBe` 1
      nodOrder (nodeBy "nod-0003") `shouldBe` 2

    it "層級 +1 即子節點:nod-0004 → nod-0002、nod-0005 → nod-0004" $ do
      parentOf "nod-0004" `shouldBe` Just (idOf "nod-0002")
      parentOf "nod-0005" `shouldBe` Just (idOf "nod-0004")

    it "nod-0007 的 parent 為 nod-0005" $
      parentOf "nod-0007" `shouldBe` Just (idOf "nod-0005")

    it "每個節都是它父節點下的第 1 個子節點時 order 為 1" $
      map nodOrder [nodeBy "nod-0004", nodeBy "nod-0005", nodeBy "nod-0007"]
        `shouldBe` [1, 1, 1]

  describe "kind 與 entities" $ do
    it "kind 由 meta 區塊填入" $
      map (nodKind . nodeBy) ["nod-0001", "nod-0002", "nod-0004", "nod-0005", "nod-0007", "nod-0003"]
        `shouldBe` [KScene, KCast, KInteraction, KDialogue, KBranch, KCamera]

    it "entities 由 involves 推導:nod-0002 指向琳達與塔主" $
      nodEntities (nodeBy "nod-0002") `shouldBe` [refOf "ent-7f3a", refOf "ent-8b20"]

    it "entities 也收 references:nod-0005 指向對話 Entity" $
      nodEntities (nodeBy "nod-0005") `shouldBe` [refOf "ent-d902"]

    it "沒有 involves / references 的節,entities 為空" $
      nodEntities (nodeBy "nod-0004") `shouldBe` []

    it "所有 Node 的 level 都是本 Level 的 id" $
      map nodLevel (lfNodes lf) `shouldSatisfy` all (== idOf "lvl-3a01")

    it "缺 kind → MissingNodeKind" $ do
      let bad = T.replace "kind: camera\n" "" classroomMd
      kindsOf (parseLevelFile (docOf "levels/教室.md" bad))
        `shouldBe` [MissingNodeKind (idOf "nod-0003")]

  describe "標題層級的錯誤" $ do
    it "## 之後直接接 #### → HeadingSkip" $ do
      let bad = T.replace "### 出場人物" "#### 出場人物" classroomMd
      kindsOf (parseLevelFile (docOf "levels/教室.md" bad))
        `shouldBe` [HeadingSkip 2 4]

    it "根層級之上的標題 → HeadingAboveRoot" $ do
      let bad = T.replace "### 鏡頭" "# 鏡頭" classroomMd
      kindsOf (parseLevelFile (docOf "levels/教室.md" bad))
        `shouldBe` [HeadingAboveRoot 2 1]

  describe "與 core 的接點" $
    it "產出的 [Node] 餵給 buildTree 成功建樹,前序走訪得 6 個節點" $
      case buildTree (lfLevel lf) (lfNodes lf) of
        Left es -> expectationFailure ("buildTree 失敗:" <> show es)
        Right t -> do
          length (preorder t) `shouldBe` 6
          map (metaId . nodMeta) (preorder t)
            `shouldBe` map idOf ["nod-0001", "nod-0002", "nod-0004", "nod-0005", "nod-0007", "nod-0003"]
