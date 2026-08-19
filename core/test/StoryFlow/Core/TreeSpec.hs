-- | entity-graph-core/F002 T5(建構與五條不變量)與 T6(走訪)的對照測試。
module StoryFlow.Core.TreeSpec (spec) where

import Data.Either (isRight)
import Data.List (sort)
import Data.Text (Text)
import StoryFlow.Core.Fixtures
import StoryFlow.Core.Id (Id, Ref)
import StoryFlow.Core.Level
import StoryFlow.Core.Link
import StoryFlow.Core.Meta
import StoryFlow.Core.Tree
import Test.Hspec

-- | 建教室場景的樹。fixture 是合法的,所以這裡取得到。
classroomTree :: NodeTree
classroomTree = case buildTree classroomLevel classroomNodes of
  Right t -> t
  Left es -> error ("教室 fixture 應該是合法的,卻得到:" <> show es)

ids :: [Node] -> [Id]
ids = map (metaId . nodMeta)

-- | 把 fixture 改壞用的輔助:換掉某個節點的父節點。
reparent :: Text -> Maybe Text -> [Node] -> [Node]
reparent target newParent = map f
  where
    f n
      | metaId (nodMeta n) == idOf target = n {nodParent = idOf <$> newParent}
      | otherwise = n

errorsOf :: [Node] -> [TreeError]
errorsOf ns = either id (const []) (buildTree classroomLevel ns)

spec :: Spec
spec = do
  describe "buildTree —— 合法的教室場景" $ do
    it "建樹成功" $
      isRight (buildTree classroomLevel classroomNodes) `shouldBe` True

    it "根是 Level 宣告的 nod-0001" $
      metaId (nodMeta (ntNode classroomTree)) `shouldBe` idOf "nod-0001"

    it "根的子節點依 order 排序:出場人物(1)在鏡頭(2)之前" $
      ids (map ntNode (ntChildren classroomTree))
        `shouldBe` [idOf "nod-0002", idOf "nod-0003"]

    it "九個節點全部進了樹" $
      length (preorder classroomTree) `shouldBe` 9

  describe "buildTree —— 五條不變量各有一條反例" $ do
    it "兩個 parent = Nothing 的節點回 MultipleRoots" $
      errorsOf (reparent "nod-0003" Nothing classroomNodes)
        `shouldContain` [MultipleRoots [idOf "nod-0001", idOf "nod-0003"]]

    it "一個根都沒有時回 NoRoot" $
      errorsOf (reparent "nod-0001" (Just "nod-0003") classroomNodes)
        `shouldContain` [NoRoot]

    it "指向不存在的父節點回 OrphanNode" $
      errorsOf (reparent "nod-0003" (Just "nod-9999") classroomNodes)
        `shouldContain` [OrphanNode (idOf "nod-0003") (idOf "nod-9999")]

    it "A → B → A 的環回 Cycle" $
      let broken = reparent "nod-0004" (Just "nod-0009") classroomNodes
       in errorsOf broken
            `shouldContain` [ Cycle
                                [ idOf "nod-0004"
                                , idOf "nod-0009"
                                , idOf "nod-0007"
                                , idOf "nod-0005"
                                ]
                            ]

    it "同一個父節點下兩個子節點 order 相同回 DuplicateOrder" $
      let broken =
            map
              ( \n ->
                  if metaId (nodMeta n) == idOf "nod-0003"
                    then n {nodOrder = 1}
                    else n
              )
              classroomNodes
       in errorsOf broken
            `shouldContain` [ DuplicateOrder
                                (idOf "nod-0001")
                                1
                                [idOf "nod-0002", idOf "nod-0003"]
                            ]

    it "同一個 id 出現兩次回 DuplicateNodeId" $
      let dup = nodeOf "nod-0003" "重複的鏡頭" (Just "nod-0001") 9 KCamera
       in errorsOf (classroomNodes ++ [dup])
            `shouldContain` [DuplicateNodeId (idOf "nod-0003")]

    it "Level 宣告的 root 與實際根不符回 RootMismatch" $
      let lvl = classroomLevel {lvlRoot = idOf "nod-0002"}
       in either id (const []) (buildTree lvl classroomNodes)
            `shouldContain` [RootMismatch (idOf "nod-0002") (idOf "nod-0001")]

    it "一次放入多個錯誤時全部回報,而不是只回第一個" $
      let broken =
            reparent "nod-0003" (Just "nod-9999") $
              reparent "nod-0004" Nothing classroomNodes
          es = errorsOf broken
       in do
            es `shouldContain` [OrphanNode (idOf "nod-0003") (idOf "nod-9999")]
            es
              `shouldContain` [ MultipleRoots
                                  [idOf "nod-0001", idOf "nod-0004"]
                              ]
            length es `shouldSatisfy` (>= 2)

  describe "走訪 —— preorder" $ do
    it "順序符合前序且同層依 order" $
      ids (preorder classroomTree)
        `shouldBe` map
          idOf
          [ "nod-0001"
          , "nod-0002"
          , "nod-0004"
          , "nod-0005"
          , "nod-0007"
          , "nod-0009"
          , "nod-0008"
          , "nod-0010"
          , "nod-0003"
          ]

  describe "走訪 —— subtreeAt" $ do
    it "nod-0002 的子樹只含它自己與它的後代" $
      fmap (ids . preorder) (subtreeAt (idOf "nod-0002") classroomTree)
        `shouldBe` Just
          ( map
              idOf
              [ "nod-0002"
              , "nod-0004"
              , "nod-0005"
              , "nod-0007"
              , "nod-0009"
              , "nod-0008"
              , "nod-0010"
              ]
          )

    it "葉節點的子樹只有它自己" $
      fmap (length . preorder) (subtreeAt (idOf "nod-0003") classroomTree)
        `shouldBe` Just 1

    it "不存在的節點回 Nothing" $
      fmap (ids . preorder) (subtreeAt (idOf "nod-9999") classroomTree)
        `shouldBe` Nothing

  describe "走訪 —— pathTo" $ do
    it "nod-0005 得到根到該節點的完整路徑" $
      fmap ids (pathTo (idOf "nod-0005") classroomTree)
        `shouldBe` Just
          (map idOf ["nod-0001", "nod-0002", "nod-0004", "nod-0005"])

    it "根自己的路徑就是它自己" $
      fmap ids (pathTo (idOf "nod-0001") classroomTree)
        `shouldBe` Just [idOf "nod-0001"]

    it "不存在的節點回 Nothing" $
      fmap ids (pathTo (idOf "nod-9999") classroomTree) `shouldBe` Nothing

  describe "走訪 —— nodesOfKind" $ do
    it "KBranch 得到兩個分支節點" $
      ids (nodesOfKind KBranch classroomTree)
        `shouldBe` map idOf ["nod-0007", "nod-0008"]

    it "KScene 只有根" $
      ids (nodesOfKind KScene classroomTree) `shouldBe` [idOf "nod-0001"]

  describe "走訪 —— entitiesIn" $ do
    it "含琳達與塔主,且重複出現的琳達只算一次" $
      sort (entitiesIn classroomTree)
        `shouldBe` sort ([entLinda, entTower, entDialogue] :: [Ref])

    it "子樹只回傳該子樹內的 Entity" $
      fmap entitiesIn (subtreeAt (idOf "nod-0003") classroomTree)
        `shouldBe` Just []

  describe "走訪 —— convergenceReport(ADR-004:合流是標註不是結構)" $ do
    it "找出 nod-0009 → nod-0010 且標記為存在" $
      convergenceReport classroomTree
        `shouldBe` [(idOf "nod-0009", refOf "nod-0010", True)]

    it "指向不存在的 Node 時標記為 False" $
      let dangling = retarget "nod-0009" (refOf "nod-9999") classroomNodes
          t = case buildTree classroomLevel dangling of
            Right x -> x
            Left es -> error (show es)
       in convergenceReport t
            `shouldBe` [(idOf "nod-0009", refOf "nod-9999", False)]

    it "指向其他 Vault 的 Node 一律視為不存在" $
      let cross = retarget "nod-0009" (refOf "shared-lore:nod-0010") classroomNodes
          t = case buildTree classroomLevel cross of
            Right x -> x
            Left es -> error (show es)
       in convergenceReport t
            `shouldBe` [(idOf "nod-0009", refOf "shared-lore:nod-0010", False)]

    it "convergesTo 不影響樹的結構 —— nod-0009 的父節點仍是 nod-0007" $
      fmap ids (pathTo (idOf "nod-0009") classroomTree)
        `shouldBe` Just
          (map idOf ["nod-0001", "nod-0002", "nod-0004", "nod-0005", "nod-0007", "nod-0009"])

-- | 換掉某個節點的 convergesTo 目標。
retarget :: Text -> Ref -> [Node] -> [Node]
retarget target r = map f
  where
    f n
      | metaId (nodMeta n) == idOf target =
          n
            { nodMeta =
                (nodMeta n) {metaLinks = [Link ConvergesTo r Nothing]}
            }
      | otherwise = n
