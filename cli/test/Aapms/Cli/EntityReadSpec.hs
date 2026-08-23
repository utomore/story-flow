-- | T10:@show@ \/ @list@ \/ @search@ 的兩種輸出模式。
--
-- 兩種模式共用同一組資料、分開 render,所以每一條都要對照著測:只測 JSON 會漏掉
-- 人類模式的表格,只測人類模式會漏掉 Agent 真正在讀的那一份。
module Aapms.Cli.EntityReadSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import Test.Hspec

spec :: Spec
spec = describe "entity show / list / search" $ do
  it "show 的兩種模式含相同的 id 與 title" $ withCliVault $ \_ -> do
    i <- newLinda
    out <- sfOk ["entity", "show", "琳達"]
    env <- sfJson ["entity", "show", "琳達"]
    out `shouldContainT` T.pack i
    out `shouldContainT` "琳達"
    jsonPath ["data", "entity", "id"] env `shouldBe` Just (String (T.pack i))
    jsonPath ["data", "entity", "title"] env `shouldBe` Just (String "琳達")

  it "show 也接受 id" $ withCliVault $ \_ -> do
    i <- newLinda
    out <- sfOk ["entity", "show", i]
    out `shouldContainT` "琳達"

  it "list 的表格每列欄數相同" $ withCliVault $ \_ -> do
    _ <- newLinda
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "埃提亞", "--summary", "崩塌前的地區"]
    out <- sfOk ["entity", "list"]
    let ls = T.lines (T.strip out)
    length ls `shouldBe` 3
    map (length . T.splitOn "|") ls `shouldBe` replicate 3 5

  it "--type / --status / --tag / --limit 各自縮小結果集" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s", "--status", "canon", "--tag", "主角"]
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "埃提亞", "--summary", "s", "--status", "draft"]
    all' <- count []
    byType <- count ["--type", "character"]
    byStatus <- count ["--status", "draft"]
    byTag <- count ["--tag", "主角"]
    byLimit <- count ["--limit", "1"]
    (all', byType, byStatus, byTag, byLimit) `shouldBe` (2, 1, 1, 1, 1)

  it "沒有命中時人類模式有一句話,JSON 是空陣列" $ withCliVault $ \_ -> do
    out <- sfOk ["entity", "list", "--type", "沒這種"]
    out `shouldSatisfy` (not . T.null . T.strip)
    env <- sfJson ["entity", "list", "--type", "沒這種"]
    dataOf env `shouldBe` Array mempty

  it "search 的 JSON 每一筆都有 snippet" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手"]
    env <- sfJson ["search", "第七織手"]
    case dataOf env of
      Array hs -> do
        length hs `shouldSatisfy` (>= 1)
        mapM_ (\h -> jsonPath ["snippet"] h `shouldSatisfy` isJust') (foldr (:) [] hs)
      other -> expectationFailure ("data 不是陣列:" <> show other)

  it "search 的人類模式多一欄 snippet" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手"]
    out <- sfOk ["search", "第七織手"]
    out `shouldContainT` "snippet"
    out `shouldContainT` "琳達"

  it "search 吃得下同一組過濾選項" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手", "--status", "canon"]
    hit <- countSearch ["第七織手", "--status", "canon"]
    miss <- countSearch ["第七織手", "--status", "deprecated"]
    (hit, miss) `shouldSatisfy` \(a, b) -> a >= 1 && b == 0

  it "標題多筆命中時列出候選並以 exit 1 收場" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "琳達", "--summary", "同名的地名"]
    env <- sfJson ["entity", "show", "琳達"]
    env `shouldHaveCode` "title_ambiguous"
    r <- sf ["entity", "show", "琳達"]
    crErr r `shouldContainT` "第七織手"
    crErr r `shouldContainT` "同名的地名"

count :: [String] -> IO Int
count extra = do
  env <- sfJson ("entity" : "list" : extra)
  case dataOf env of
    Array ms -> pure (length ms)
    other -> fail ("data 不是陣列:" <> show other)

countSearch :: [String] -> IO Int
countSearch args = do
  env <- sfJson ("search" : args)
  case dataOf env of
    Array hs -> pure (length hs)
    other -> fail ("data 不是陣列:" <> show other)

isJust' :: Maybe a -> Bool
isJust' = maybe False (const True)

newLinda :: IO String
newLinda =
  idFromJson
    <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手"]
