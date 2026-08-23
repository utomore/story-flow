-- | T13:@level@ 四個子指令。
--
-- @level new@ 一定連根 Node 一起建(空殼 Level 解析不出 @root@),所以剛建好的
-- 場景樹是「Level 一行 + 根節點一行」——這是後面 @node add@ 的起點。
module Aapms.Cli.LevelCmdSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "level new / show / list / rm" $ do
  it "new 之後檔案落在 levels/" $ withCliVault $ \dir -> do
    _ <- newClassroom
    exists <- doesFileExist (dir </> "levels" </> "教室.md")
    exists `shouldBe` True

  it "剛建好的 show 只有根節點" $ withCliVault $ \_ -> do
    _ <- newClassroom
    out <- sfOk ["level", "show", "教室"]
    let ls = T.lines (T.strip out)
    length ls `shouldBe` 2
    firstLine ls `shouldContainT` "教室"
    (ls !! 1) `shouldContainT` "scene"
    (ls !! 1) `shouldContainT` "午後的教室"

  it "list 含它,而且表格欄數與 entity list 一致" $ withCliVault $ \_ -> do
    _ <- newClassroom
    out <- sfOk ["level", "list"]
    out `shouldContainT` "教室"
    map (length . T.splitOn "|") (T.lines (T.strip out)) `shouldBe` replicate 2 5

  it "list 吃得下 --status 與 --limit" $ withCliVault $ \_ -> do
    _ <- newClassroom
    _ <- sfOk ["level", "new", "--title", "走廊", "--root-title", "長廊", "--root-kind", "scene", "--status", "draft"]
    canon <- countLevels ["--status", "canon"]
    one <- countLevels ["--limit", "1"]
    (canon, one) `shouldBe` (1, 1)

  it "show 的 JSON 回的是樹,不是扁平清單" $ withCliVault $ \_ -> do
    _ <- newClassroom
    env <- sfJson ["level", "show", "教室"]
    jsonPath ["data", "tree", "node", "kind"] env `shouldBe` Just (String "scene")
    jsonPath ["data", "tree", "children"] env `shouldBe` Just (Array mempty)

  it "被引用時非 force 刪不掉,訊息列出來源" $ withCliVault $ \_ -> do
    lvl <- newClassroom
    ent <- idFromJson <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfOk ["link", "add", ent, "--kind", "references", "--target", lvl]
    env <- sfJson ["level", "rm", "教室"]
    env `shouldHaveCode` "referenced_by"
    r <- sf ["level", "rm", "教室"]
    crErr r `shouldContainT` T.pack ent

  it "--force 刪得掉,而且檔案不見了" $ withCliVault $ \dir -> do
    lvl <- newClassroom
    ent <- idFromJson <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfOk ["link", "add", ent, "--kind", "references", "--target", lvl]
    r <- sf ["level", "rm", "教室", "--force"]
    crExit r `shouldBe` ExitSuccess
    exists <- doesFileExist (dir </> "levels" </> "教室.md")
    exists `shouldBe` False

  it "沒有被引用時直接刪得掉" $ withCliVault $ \_ -> do
    _ <- newClassroom
    r <- sf ["level", "rm", "教室"]
    crExit r `shouldBe` ExitSuccess

  it "--root-kind 是必填" $ withCliVault $ \_ -> do
    r <- sf ["level", "new", "--title", "教室", "--root-title", "午後的教室"]
    crExit r `shouldBe` ExitFailure 2

countLevels :: [String] -> IO Int
countLevels extra = do
  env <- sfJson ("level" : "list" : extra)
  case dataOf env of
    Array ms -> pure (length ms)
    other -> fail ("data 不是陣列:" <> show other)

-- | 建「教室」場景,回 Level 的 id。
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

firstLine :: [T.Text] -> T.Text
firstLine (x : _) = x
firstLine [] = error "預期輸出至少有一行"
