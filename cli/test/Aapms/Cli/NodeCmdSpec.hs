-- | T14:@node add@ \/ @rm@ 反映在樹上。
--
-- 指令列上只有節點,沒有 Level ——CLI 自己從場景樹反查它所屬的 Level,因為
-- service 的 @addNode@ \/ @removeNode@ 要的 expected revision 是 __Level 主體__
-- 的(樂觀鎖鎖的是整份檔案,標題階層一動就會影響到別的節點)。
module Aapms.Cli.NodeCmdSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "node add / rm" $ do
  it "掛到根之下後樹多一層" $ withCliVault $ \_ -> do
    _ <- newClassroom
    _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    ls <- treeLines
    length ls `shouldBe` 3
    (ls !! 2) `shouldContainT` "出場人物"
    (ls !! 2) `shouldContainT` "cast"
    (ls !! 2) `shouldContainT` "└─"

  it "連續加三個兄弟,順序與加入順序相同" $ withCliVault $ \_ -> do
    _ <- newClassroom
    mapM_
      (\(t, k) -> sfOk ["node", "add", "午後的教室", "--title", t, "--kind", k])
      [("出場人物", "cast"), ("鏡頭", "camera"), ("分支", "branch")]
    ls <- treeLines
    map (T.isInfixOf "出場人物") (take 1 (drop 2 ls)) `shouldBe` [True]
    (ls !! 3) `shouldContainT` "鏡頭"
    (ls !! 4) `shouldContainT` "分支"

  it "掛到子節點底下再深一層" $ withCliVault $ \_ -> do
    _ <- newClassroom
    _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    _ <- sfOk ["node", "add", "出場人物", "--title", "琳達走向講台", "--kind", "interaction"]
    ls <- treeLines
    length ls `shouldBe` 4
    (ls !! 3) `shouldContainT` "琳達走向講台"
    (ls !! 3) `shouldContainT` "interaction"

  it "刪掉有子孫的節點後子孫全消失" $ withCliVault $ \_ -> do
    _ <- newClassroom
    _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    _ <- sfOk ["node", "add", "出場人物", "--title", "琳達走向講台", "--kind", "interaction"]
    _ <- sfOk ["node", "rm", "出場人物"]
    ls <- treeLines
    length ls `shouldBe` 2
    T.unlines ls `shouldSatisfy` (not . T.isInfixOf "琳達走向講台")

  it "對根節點 node rm → exit 1" $ withCliVault $ \_ -> do
    _ <- newClassroom
    r <- sf ["node", "rm", "午後的教室"]
    crExit r `shouldBe` ExitFailure 1
    env <- sfJson ["node", "rm", "午後的教室"]
    env `shouldHaveCode` "cannot_remove_root_node"

  it "找不到節點時是 title_not_found,訊息提示去 level show" $ withCliVault $ \_ -> do
    _ <- newClassroom
    env <- sfJson ["node", "add", "沒這個節點", "--title", "x", "--kind", "cast"]
    env `shouldHaveCode` "title_not_found"
    r <- sf ["node", "add", "沒這個節點", "--title", "x", "--kind", "cast"]
    crErr r `shouldContainT` "aapms level show"

  it "帶過期的 --revision 時擋下來(鎖的是 Level 主體的 revision)" $ withCliVault $ \_ -> do
    _ <- newClassroom
    _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    env <- sfJson ["node", "add", "午後的教室", "--title", "鏡頭", "--kind", "camera", "--revision", "1"]
    env `shouldHaveCode` "stale_revision"

  it "node add 可以帶 --link 指到 Entity" $ withCliVault $ \_ -> do
    _ <- newClassroom
    ent <- idFromJson <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    r <- sf ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast", "--link", "involves:" <> ent]
    crExit r `shouldBe` ExitSuccess
    env <- sfJson ["level", "show", "教室"]
    case jsonPath ["data", "tree", "children"] env of
      Just (Array cs) -> length cs `shouldBe` 1
      other -> expectationFailure ("children 取不到:" <> show other)

  it "寫入類指令是一行結果" $ withCliVault $ \_ -> do
    _ <- newClassroom
    out <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    length (T.lines (T.strip out)) `shouldBe` 1

treeLines :: IO [T.Text]
treeLines = T.lines . T.strip <$> sfOk ["level", "show", "教室"]

newClassroom :: IO String
newClassroom = do
  env <-
    sfJson
      [ "level"
      , "new"
      , "--title"
      , "教室"
      , "--summary"
      , "崩塌後的午後教室"
      , "--root-title"
      , "午後的教室"
      , "--root-kind"
      , "scene"
      , "--status"
      , "canon"
      ]
  case jsonPath ["data", "level", "id"] env of
    Just (String i) -> pure (T.unpack i)
    other -> fail ("data.level.id 取不到:" <> show other)
