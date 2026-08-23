-- | T15:Level 與 Node。
--
-- 'getLevel' 回的是__樹__而不是扁平清單:'Aapms.Core.Tree.buildTree' 已經
-- 驗過合法性,把結果丟掉會讓 CLI 與 server 各自重建一次。而作者隨時可以直接
-- 編輯 Level 檔把樹改壞——那時候要回報,不是崩潰。
module Aapms.Service.LevelSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Core.Level (Level (..), Node (..), NodeKind (KCamera, KCast, KScene))
import Aapms.Core.Meta (Meta (..))
import Aapms.Core.Tree (NodeTree (..), preorder)
import Aapms.Service
import Aapms.Service.Fixtures
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "Level / Node" $ do
  it "createLevel 之後樹上只有根節點" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      lvPath lv `shouldSatisfy` T.isPrefixOf "levels/" . T.pack
      ntChildren (lvTree lv) `shouldBe` []
      nodKind (ntNode (lvTree lv)) `shouldBe` KScene
      metaId (nodMeta (ntNode (lvTree lv))) `shouldBe` lvlRoot (lvLevel lv)

  it "addNode 掛在父節點底下,order 依插入順序" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
          root = lvlRoot (lvLevel lv)
      lv2 <- runS env (addNode lvlId root 1 (newNode "出場人物" KCast))
      lv3 <- runS env (addNode lvlId root 2 (newNode "鏡頭" KCamera))
      let kids = ntChildren (lvTree lv3)
      map (nodKind . ntNode) kids `shouldBe` [KCast, KCamera]
      map (nodOrder . ntNode) kids `shouldBe` [1, 2]
      length (ntChildren (lvTree lv2)) `shouldBe` 1

  it "子節點還能再往下掛一層" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
          root = lvlRoot (lvLevel lv)
      lv2 <- runS env (addNode lvlId root 1 (newNode "出場人物" KCast))
      let cast = firstChildId (lvTree lv2)
      lv3 <- runS env (addNode lvlId cast 2 (newNode "琳達走向講台" KCamera))
      length (preorder (lvTree lv3)) `shouldBe` 3

  it "removeNode 連同子樹一起刪" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
          root = lvlRoot (lvLevel lv)
      lv2 <- runS env (addNode lvlId root 1 (newNode "出場人物" KCast))
      let cast = firstChildId (lvTree lv2)
      _ <- runS env (addNode lvlId cast 2 (newNode "琳達走向講台" KCamera))
      lv4 <- runS env (removeNode lvlId cast 3 False)
      preorder (lvTree lv4) `shouldSatisfy` ((== 1) . length)

  it "根 Node 刪不得" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
      r <- runE env (removeNode lvlId (lvlRoot (lvLevel lv)) 1 False)
      fmap (const ()) r `shouldFailWith` "cannot_remove_root_node"

  it "listLevels 只列 Level,不列 Entity" $
    withServiceEnv $ \env -> do
      _ <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      _ <- runS env (createEntity (newEntity "character" "琳達" "第七織手"))
      ls <- runS env (listLevels emptyFilter)
      map metaTitle ls `shouldBe` ["教室"]

  it "deleteLevel 刪掉整份檔案與它全部的 Node" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
      _ <- runS env (addNode lvlId (lvlRoot (lvLevel lv)) 1 (newNode "出場人物" KCast))
      r <- runS env (deleteLevel lvlId 2 False)
      length (delRemoved r) `shouldBe` 3
      ls <- runS env (listLevels emptyFilter)
      ls `shouldBe` []

  it "作者把檔案改成兩個根 → LevelTreeInvalid,不是崩潰" $
    withServiceEnv $ \env -> do
      lv <- runS env (createLevel (newLevel "教室" "午後的教室" KScene))
      let lvlId = metaId (lvlMeta (lvLevel lv))
      root <- runS env vaultInfo
      -- 直接在檔尾補一個同層級的節:兩個 `##` 就是兩個根
      let fp = vvRoot root </> lvPath lv
      old <- TE.decodeUtf8 <$> BS.readFile fp
      BS.writeFile fp (TE.encodeUtf8 (old <> extraRoot))
      _ <- runS env refreshIndex
      r <- runE env (getLevel lvlId)
      fmap (const ()) r `shouldFailWith` "level_tree_invalid"
  where
    extraRoot =
      T.unlines
        [ ""
        , "## 第二個根 {#nod-00000002}"
        , ""
        , "```meta"
        , "kind: scene"
        , "summary: 這一節與根同層,樹因此有兩個根"
        , "```"
        ]
