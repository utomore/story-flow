-- | lawful 測試:P-024-level-tree(qa 填入)。
--
-- 十二條 law 各一條 property test、十六個 example 各一條 example test。
-- 產生器只用 types 層的 smart constructor:'parseId' 造 'Id'、記錄建構子造
-- 'Meta' \/ 'Node' \/ 'Level' \/ 'Link'。
--
-- 產生器的形狀:先生一棵隨機的樹(深度 <= 3、分支 <= 3,節點數 <= 40),
-- 再攤平成 @[Node]@(parent 依樹填、同層 order 是 1..k 的隨機排列),最後把
-- 清單洗牌——這樣 'buildTree' 的 'Right' 案例才有分佈,而且檔案順序與樹的
-- 形狀無關。壞掉的變體(成環、孤兒、多重根、無根、同 order、重複 id、
-- 根宣告不符、空清單、純亂數節點)只餵給 LAW-12。
module Aapms.Lawful.P024Spec (spec) where

import Control.Monad (forM_)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Numeric (showHex)
import System.Timeout (timeout)

import Test.Hspec
import Test.Hspec.Hedgehog (Gen, diff, eval, evalEither, forAll, hedgehog, modifyMaxSuccess, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Aapms.Core.Id (Id, Ref (..), VaultId (..), localRef, parseId, renderId)
import Aapms.Core.Level
  ( Level (..)
  , Node (..)
  , NodeKind (..)
  , allNodeKinds
  )
import Aapms.Core.Link (Link (..), LinkKind (..))
import Aapms.Core.Meta
  ( Meta (..)
  , Revision (..)
  , Source (..)
  , Status (..)
  , TypeKey (..)
  )
import Aapms.Core.Tree
  ( NodeTree (..)
  , TreeError (..)
  , buildTree
  , convergenceReport
  , entitiesIn
  , nodesOfKind
  , pathTo
  , preorder
  , subtreeAt
  )

--------------------------------------------------------------------------------
-- 共用建構子

-- | 只走 'parseId' 這個 smart constructor;字面值全部是合法的 1–8 位小寫十六進位。
idOf :: Text -> Id
idOf t = case parseId t of
  Right (_, i) -> i
  Left e -> error ("P-024 測試:非法 id " <> T.unpack t <> " — " <> show e)

-- | 產生器用的節點 id:四位十六進位,與 fixture 的 @nod-000x@ 同格式。
nodeIdN :: Int -> Id
nodeIdN n = idOf ("nod-" <> T.justifyRight 4 '0' (T.pack (showHex n "")))

nodeId :: Node -> Id
nodeId = metaId . nodMeta

theVault :: VaultId
theVault = VaultId "vlt-a0c4e1f8"

levelId :: Id
levelId = idOf "lvl-0001"

mkMeta :: Id -> Text -> [Link] -> Meta
mkMeta i title links =
  Meta
    { metaId = i
    , metaVault = theVault
    , metaType = TypeKey "level-node"
    , metaTitle = title
    , metaSummary = ""
    , metaTags = []
    , metaStatus = Draft
    , metaTimeline = Nothing
    , metaAliases = []
    , metaLinks = links
    , metaSource = Human
    , metaRevision = Revision 1
    , metaCreated = fromGregorian 2026 9 6
    , metaUpdated = fromGregorian 2026 9 6
    }

mkNode :: Id -> Maybe Id -> Int -> NodeKind -> [Ref] -> [Link] -> Node
mkNode i parent ord kind ents links =
  Node
    { nodMeta = mkMeta i ("節點 " <> renderId i) links
    , nodLevel = levelId
    , nodParent = parent
    , nodOrder = ord
    , nodKind = kind
    , nodEntities = ents
    }

convTo :: Ref -> Link
convTo r = Link ConvergesTo r Nothing

--------------------------------------------------------------------------------
-- 產生器

-- | 樹的形狀,還沒有 id。
newtype Shape = Shape [Shape]

-- | 深度 <= 3、每層分支 <= 3:節點數上限 1 + 3 + 9 + 27 = 40。
genShape :: Gen Shape
genShape = go (3 :: Int)
  where
    go d
      | d <= 0 = pure (Shape [])
      | otherwise = Shape <$> Gen.list (Range.linear 0 3) (go (d - 1))

-- | 標上編號的樹;編號在前序走訪下遞增。
data LTree = LTree Int [LTree]

labelTree :: Int -> Shape -> (LTree, Int)
labelTree n (Shape cs) =
  let (cs', n') = goList (n + 1) cs
   in (LTree n cs', n')
  where
    goList k [] = ([], k)
    goList k (s : rest) =
      let (t, k') = labelTree k s
          (ts, k'') = goList k' rest
       in (t : ts, k'')

entityPool :: [Ref]
entityPool =
  [ localRef (idOf "ent-0001")
  , localRef (idOf "ent-0002")
  , localRef (idOf "ent-0003")
  ]

-- | 關聯:多數 @convergesTo@ 指向本 Level 內的節點,少數指向不存在的節點與
-- 跨 vault 的節點,另加非 @convergesTo@ 的雜訊關聯。
genLink :: [Id] -> Gen Link
genLink pool =
  Gen.frequency
    [ (4, convTo . localRef <$> Gen.element pool)
    , (1, pure (convTo (localRef (idOf "nod-ffff"))))
    , (1, convTo . Ref (Just theVault) <$> Gen.element pool)
    , (2, (\i -> Link Involves (localRef i) Nothing) <$> Gen.element pool)
    ]

genNodesOf :: [Id] -> Maybe Id -> Int -> LTree -> Gen [Node]
genNodesOf pool parent ord (LTree n cs) = do
  let i = nodeIdN n
  kind <- Gen.element allNodeKinds
  ents <- Gen.list (Range.linear 0 2) (Gen.element entityPool)
  links <- Gen.list (Range.linear 0 2) (genLink pool)
  orders <- Gen.shuffle [1 .. length cs]
  kids <- concat <$> traverse (\(o, c) -> genNodesOf pool (Just i) o c) (zip orders cs)
  pure (mkNode i parent ord kind ents links : kids)

-- | 合法的節點清單,以及它的根 id。清單洗過牌:檔案順序與樹的形狀無關。
genValidNodes :: Gen (Id, [Node])
genValidNodes = do
  shape <- genShape
  let (lt, next) = labelTree 1 shape
      pool = map nodeIdN [1 .. next - 1]
  ns <- genNodesOf pool Nothing 1 lt
  ns' <- Gen.shuffle ns
  pure (nodeIdN 1, ns')

genLevelFor :: Id -> Gen Level
genLevelFor root = do
  li <- Gen.element [idOf "lvl-0001", idOf "lvl-0002"]
  ttl <- Gen.element ["教室" :: Text, "走廊", "頂樓"]
  pure Level {lvlMeta = mkMeta li ttl [], lvlRoot = root}

genValid :: Gen (Level, [Node])
genValid = do
  (root, ns) <- genValidNodes
  lvl <- genLevelFor root
  pure (lvl, ns)

-- | 壞掉的變體:成環、孤兒、多重根、無根、同 order、重複 id、根宣告不符、空清單。
genBroken :: Gen (Level, [Node])
genBroken = do
  (root, ns) <- genValidNodes
  lvl <- genLevelFor root
  Gen.choice
    [ pure (lvl, [])
    , pure (lvl, map (\n -> n {nodOrder = 1}) ns)
    , pure (lvl, ns ++ take 1 ns)
    , pure (lvl, map noRoot ns)
    , pure (lvl, map orphan ns)
    , pure (lvl, map (\n -> n {nodParent = Nothing}) ns)
    , pure (lvl {lvlRoot = idOf "nod-fffe"}, ns)
    , (\i -> (lvl, map (reparent i) ns)) <$> Gen.element (map nodeId ns)
    ]
  where
    noRoot n = case nodParent n of
      Nothing -> n {nodParent = Just (idOf "nod-0002")}
      Just _ -> n
    orphan n = case nodParent n of
      Nothing -> n
      Just _ -> n {nodParent = Just (idOf "nod-fffe")}
    reparent i n = case nodParent n of
      Nothing -> n
      Just _ -> n {nodParent = Just i}

-- | 完全隨機的節點:parent 可能指向自己、指向不存在的節點,order 可能是負的。
genJunk :: Gen (Level, [Node])
genJunk = do
  ns <- Gen.list (Range.linear 0 8) genJunkNode
  root <- Gen.element (map nodeId ns ++ [idOf "nod-0001"])
  lvl <- genLevelFor root
  pure (lvl, ns)
  where
    genJunkNode = do
      n <- Gen.int (Range.linear 1 6)
      p <- Gen.maybe (nodeIdN <$> Gen.int (Range.linear 1 8))
      o <- Gen.int (Range.linear (-2) 3)
      k <- Gen.element allNodeKinds
      ents <- Gen.list (Range.linear 0 2) (Gen.element entityPool)
      links <- Gen.list (Range.linear 0 2) (genLink (map nodeIdN [1 .. 8]))
      pure (mkNode (nodeIdN n) p o k ents links)

genAny :: Gen (Level, [Node])
genAny = Gen.frequency [(2, genValid), (3, genBroken), (2, genJunk)]

--------------------------------------------------------------------------------
-- 教室場景 fixture(Examples 用)
--
--   nod-0001 (scene, 根)
--   ├─ nod-0002 (cast, order 1)
--   │   └─ nod-0004 (camera)
--   │       └─ nod-0005 (interaction)
--   │           └─ nod-0007 (branch)
--   │               ├─ nod-0009 (dialogue, order 1) --convergesTo--> nod-0010
--   │               └─ nod-0008 (branch, order 2)
--   │                   └─ nod-0010 (dialogue)
--   └─ nod-0003 (dialogue, order 2)

lindaRef, teacherRef :: Ref
lindaRef = localRef (idOf "ent-0001") -- 琳達
teacherRef = localRef (idOf "ent-0002") -- 老師

classroomLevel :: Level
classroomLevel =
  Level
    { lvlMeta = mkMeta levelId "教室" []
    , lvlRoot = idOf "nod-0001"
    }

classroomNodes :: [Node]
classroomNodes =
  [ mkNode (idOf "nod-0001") Nothing 1 KScene [] []
  , mkNode (idOf "nod-0002") (Just (idOf "nod-0001")) 1 KCast [lindaRef] []
  , mkNode (idOf "nod-0003") (Just (idOf "nod-0001")) 2 KDialogue [] []
  , mkNode (idOf "nod-0004") (Just (idOf "nod-0002")) 1 KCamera [] []
  , mkNode (idOf "nod-0005") (Just (idOf "nod-0004")) 1 KInteraction [lindaRef] []
  , mkNode (idOf "nod-0007") (Just (idOf "nod-0005")) 1 KBranch [teacherRef] []
  , mkNode (idOf "nod-0008") (Just (idOf "nod-0007")) 2 KBranch [] []
  , mkNode (idOf "nod-0009") (Just (idOf "nod-0007")) 1 KDialogue [] [convTo (localRef (idOf "nod-0010"))]
  , mkNode (idOf "nod-0010") (Just (idOf "nod-0008")) 1 KDialogue [] []
  ]

classroomPreorder :: [Id]
classroomPreorder =
  map
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

-- | 改掉指定 id 的那個節點。
withNode :: Text -> (Node -> Node) -> [Node] -> [Node]
withNode raw f = map (\n -> if nodeId n == idOf raw then f n else n)

-- | 換掉指定節點的 @convergesTo@ 目標。
withConvergence :: Text -> Ref -> [Node] -> [Node]
withConvergence raw target =
  withNode raw (\n -> n {nodMeta = (nodMeta n) {metaLinks = [convTo target]}})

--------------------------------------------------------------------------------
-- Example 用的小工具

withTree :: Level -> [Node] -> (NodeTree -> Expectation) -> Expectation
withTree lvl ns k = case buildTree lvl ns of
  Left es -> expectationFailure ("buildTree 應成功,卻回 Left " <> show es)
  Right t -> k t

withErrors :: Level -> [Node] -> ([TreeError] -> Expectation) -> Expectation
withErrors lvl ns k = case buildTree lvl ns of
  Right _ -> expectationFailure "buildTree 應失敗,卻回 Right"
  Left es -> k es

ids :: [Node] -> [Id]
ids = map nodeId

--------------------------------------------------------------------------------

-- | 每個測試項目 60 秒的上限:產生器有界,跑不完就是紅。
moduleTimeout :: SpecWith a -> SpecWith a
moduleTimeout = around_ $ \act -> do
  r <- timeout (60 * 1000 * 1000) act
  case r of
    Just () -> pure ()
    Nothing -> expectationFailure "P-024 測試逾時(60 秒)"

spec :: Spec
spec = moduleTimeout $ modifyMaxSuccess (const 100) $ do
  laws
  examples

--------------------------------------------------------------------------------
-- Laws

laws :: Spec
laws = do
  describe "P-024#LAW-1" $
    it "建得起來的樹恰好裝下全部節點,一個不多一個不少" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        forM_ ns $ \n -> diff n elem (preorder t)
        length (preorder t) === length ns

  describe "P-024#LAW-2" $
    it "樹裡每個 id 只出現一次" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        let is = map metaId (map nodMeta (preorder t))
        nub is === is

  describe "P-024#LAW-3" $
    it "以根為起點取子樹就是整棵樹" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        subtreeAt (metaId (nodMeta (head (preorder t)))) t === Just t

  describe "P-024#LAW-4" $
    it "每個節點都追得出一條從同一個根起頭、到它自己為止的路徑" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        forM_ (preorder t) $ \n -> do
          fmap head (pathTo (metaId (nodMeta n)) t) === Just (head (preorder t))
          fmap last (pathTo (metaId (nodMeta n)) t) === Just n

  describe "P-024#LAW-5" $
    it "樹裡的每個節點都找得到自己的子樹,而且那棵子樹的根就是它" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        forM_ (preorder t) $ \n ->
          fmap ntNode (subtreeAt (metaId (nodMeta n)) t) === Just n

  describe "P-024#LAW-6" $
    it "同層順序只由 order 決定,與節點在檔案裡的出現順序無關" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        buildTree lvl (reverse ns) === Right t

  describe "P-024#LAW-7" $
    it "樹的形狀只由節點決定,Level 只負責把關根的宣告" $
      hedgehog $ do
        (root, ns) <- forAll genValidNodes
        lvl1 <- forAll (genLevelFor root)
        lvl2 <- forAll (genLevelFor root)
        t1 <- evalEither (buildTree lvl1 ns)
        t2 <- evalEither (buildTree lvl2 ns)
        t1 === t2

  describe "P-024#LAW-8" $
    it "nodesOfKind 恰好是前序裡那個演出種類的節點,不多也不少" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        forM_ allNodeKinds $ \k ->
          forM_ (preorder t) $ \n ->
            (n `elem` nodesOfKind k t) === (nodKind n == k)

  describe "P-024#LAW-9" $
    it "子樹裡的 Entity 是整棵樹的子集,而且清單本身已去重" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        nub (entitiesIn t) === entitiesIn t
        forM_ (preorder t) $ \n ->
          case subtreeAt (metaId (nodMeta n)) t of
            Nothing -> pure ()
            Just s -> forM_ (entitiesIn s) $ \r -> diff r elem (entitiesIn t)

  describe "P-024#LAW-10" $
    it "合流報告的第三欄就是「目標是本 vault 且在本 Level 內」" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        let known = map metaId (map nodMeta (preorder t))
        forM_ (convergenceReport t) $ \(_, r, ok) ->
          ok === (refVault r == Nothing && refId r `elem` known)

  describe "P-024#LAW-11" $
    it "一棵子樹的根就是它的 ntNode,它的每個子樹的根都在自己的前序裡" $
      hedgehog $ do
        (lvl, ns) <- forAll genValid
        t <- evalEither (buildTree lvl ns)
        forM_ (preorder t) $ \n ->
          case subtreeAt (metaId (nodMeta n)) t of
            Nothing -> pure ()
            Just s -> do
              head (preorder s) === ntNode s
              forM_ (ntChildren s) $ \c -> diff (ntNode c) elem (preorder s)

  describe "P-024#LAW-12" $
    it "任何 Level 與節點清單丟給 buildTree 都有值,不拋例外" $
      hedgehog $ do
        (lvl, ns) <- forAll genAny
        -- 求值到正規形:show 會把整個 Either 走完。
        _ <- eval (length (show (buildTree lvl ns)))
        pure ()

--------------------------------------------------------------------------------
-- Examples

examples :: Spec
examples = do
  describe "P-024#EX-1" $
    it "教室場景 fixture 建樹成功,前序共九個節點" $
      withTree classroomLevel classroomNodes $ \t -> do
        ids (preorder t) `shouldBe` classroomPreorder
        length (preorder t) `shouldBe` 9

  describe "P-024#EX-2" $
    it "把同一組節點清單反轉後再建樹,結果相等" $
      withTree classroomLevel classroomNodes $ \t ->
        buildTree classroomLevel (reverse classroomNodes) `shouldBe` Right t

  describe "P-024#EX-3" $
    it "subtreeAt nod-0002 是七個節點的子樹;nod-9999 回 Nothing" $
      withTree classroomLevel classroomNodes $ \t -> do
        fmap (ids . preorder) (subtreeAt (idOf "nod-0002") t)
          `shouldBe` Just (map idOf ["nod-0002", "nod-0004", "nod-0005", "nod-0007", "nod-0009", "nod-0008", "nod-0010"])
        fmap (nodeId . ntNode) (subtreeAt (idOf "nod-0002") t)
          `shouldBe` Just (idOf "nod-0002")
        subtreeAt (idOf "nod-9999") t `shouldBe` Nothing

  describe "P-024#EX-4" $
    it "subtreeAt 根自己回整棵樹" $
      withTree classroomLevel classroomNodes $ \t ->
        subtreeAt (idOf "nod-0001") t `shouldBe` Just t

  describe "P-024#EX-5" $
    it "pathTo nod-0005 是四層路徑;根自己的路徑長度 1" $
      withTree classroomLevel classroomNodes $ \t -> do
        fmap ids (pathTo (idOf "nod-0005") t)
          `shouldBe` Just (map idOf ["nod-0001", "nod-0002", "nod-0004", "nod-0005"])
        fmap ids (pathTo (idOf "nod-0001") t)
          `shouldBe` Just [idOf "nod-0001"]

  describe "P-024#EX-6" $
    it "根的 ntChildren 依 order 是 nod-0002、nod-0003" $
      withTree classroomLevel classroomNodes $ \t ->
        map (nodeId . ntNode) (ntChildren t)
          `shouldBe` map idOf ["nod-0002", "nod-0003"]

  describe "P-024#EX-7" $
    it "nodesOfKind KBranch 是 nod-0007、nod-0008;KScene 只有根" $
      withTree classroomLevel classroomNodes $ \t -> do
        ids (nodesOfKind KBranch t) `shouldBe` map idOf ["nod-0007", "nod-0008"]
        ids (nodesOfKind KScene t) `shouldBe` [idOf "nod-0001"]

  describe "P-024#EX-8" $
    it "entitiesIn 去重:琳達只算一次;葉節點的子樹回空清單" $
      withTree classroomLevel classroomNodes $ \t -> do
        entitiesIn t `shouldBe` [lindaRef, teacherRef]
        length (filter (== lindaRef) (entitiesIn t)) `shouldBe` 1
        fmap entitiesIn (subtreeAt (idOf "nod-0003") t) `shouldBe` Just []

  describe "P-024#EX-9" $
    it "合流報告:本 Level 內為 True,不存在與跨 vault 都是 False" $ do
      withTree classroomLevel classroomNodes $ \t ->
        convergenceReport t
          `shouldBe` [(idOf "nod-0009", localRef (idOf "nod-0010"), True)]
      withTree classroomLevel (withConvergence "nod-0009" (localRef (idOf "nod-9999")) classroomNodes) $ \t ->
        convergenceReport t
          `shouldBe` [(idOf "nod-0009", localRef (idOf "nod-9999"), False)]
      withTree classroomLevel (withConvergence "nod-0009" (Ref (Just theVault) (idOf "nod-0010")) classroomNodes) $ \t ->
        convergenceReport t
          `shouldBe` [(idOf "nod-0009", Ref (Just theVault) (idOf "nod-0010"), False)]

  describe "P-024#EX-10" $
    it "nod-0004 的父節點改成 nod-0009 成環,錯誤以最小 id 起始" $
      withErrors
        classroomLevel
        (withNode "nod-0004" (\n -> n {nodParent = Just (idOf "nod-0009")}) classroomNodes)
        $ \es ->
          es
            `shouldContain` [ Cycle
                                (map idOf ["nod-0004", "nod-0009", "nod-0007", "nod-0005"])
                            ]

  describe "P-024#EX-11" $
    it "nod-0003 指向不存在的父節點是 OrphanNode" $
      withErrors
        classroomLevel
        (withNode "nod-0003" (\n -> n {nodParent = Just (idOf "nod-9999")}) classroomNodes)
        $ \es ->
          es `shouldContain` [OrphanNode (idOf "nod-0003") (idOf "nod-9999")]

  describe "P-024#EX-12" $
    it "兩個根是 MultipleRoots;一個根都沒有是 NoRoot" $ do
      withErrors
        classroomLevel
        (withNode "nod-0003" (\n -> n {nodParent = Nothing}) classroomNodes)
        $ \es ->
          es `shouldContain` [MultipleRoots (map idOf ["nod-0001", "nod-0003"])]
      withErrors
        classroomLevel
        (withNode "nod-0001" (\n -> n {nodParent = Just (idOf "nod-0003")}) classroomNodes)
        $ \es ->
          es `shouldContain` [NoRoot]

  describe "P-024#EX-13" $
    it "同一個父節點底下兩個 order 都是 1 是 DuplicateOrder" $
      withErrors
        classroomLevel
        (withNode "nod-0003" (\n -> n {nodOrder = 1}) classroomNodes)
        $ \es ->
          es
            `shouldContain` [ DuplicateOrder
                                (idOf "nod-0001")
                                1
                                (map idOf ["nod-0002", "nod-0003"])
                            ]

  describe "P-024#EX-14" $
    it "同一個 id 出現兩次是 DuplicateNodeId" $
      withErrors
        classroomLevel
        (classroomNodes ++ filter ((== idOf "nod-0003") . nodeId) classroomNodes)
        $ \es ->
          es `shouldContain` [DuplicateNodeId (idOf "nod-0003")]

  describe "P-024#EX-15" $
    it "lvlRoot 宣告與實際的根不符是 RootMismatch" $
      withErrors
        classroomLevel {lvlRoot = idOf "nod-0002"}
        classroomNodes
        $ \es ->
          es `shouldContain` [RootMismatch (idOf "nod-0002") (idOf "nod-0001")]

  describe "P-024#EX-16" $
    it "一次改壞兩處,兩則錯誤都在同一個清單裡" $
      withErrors
        classroomLevel
        ( withNode "nod-0004" (\n -> n {nodParent = Nothing})
            (withNode "nod-0003" (\n -> n {nodParent = Just (idOf "nod-9999")}) classroomNodes)
        )
        $ \es -> do
          es `shouldContain` [OrphanNode (idOf "nod-0003") (idOf "nod-9999")]
          es `shouldContain` [MultipleRoots (map idOf ["nod-0001", "nod-0004"])]
          length es `shouldSatisfy` (>= 2)
