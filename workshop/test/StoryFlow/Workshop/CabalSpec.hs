-- | T1 / T12:套件骨架與套件邊界。
--
-- 「@storyflow-workshop@ 不直接依賴 @storyflow-store@ \/ @storyflow-md@ \/
-- sqlite \/ servant \/ warp,所有讀取經 @ServiceM@」這條界線唯一守得住的形式,
-- 是 @.cabal@ 檔裡__沒有那些名字__ ——作法逐字沿用
-- @StoryFlow.Llm.CabalSpec@\/@StoryFlow.Conflict.CabalSpec@:同一條紀律擋著
-- 同一批名字。
module StoryFlow.Workshop.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = do
  describe "build-depends" $ do
    it "逐字等於設計裡的那兩份清單" $ do
      deps <- map trim . dependencyLines <$> readCabal
      deps `shouldBe` libraryDeps ++ testDeps

    it "library 含 storyflow-core / storyflow-llm / storyflow-service" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      mapM_
        (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True))
        ["storyflow-core", "storyflow-llm", "storyflow-service"]

    it "library 不含 store / md / sqlite / servant / warp" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

    it "warp / wai 只出現在 test-suite" $ do
      src <- readCabal
      let libDeps = dependencyLines (librarySection src)
          testSuiteDeps = dependencyLines (testSection src)
      any ("warp" `isInfixOf`) libDeps `shouldBe` False
      any ("wai" `isInfixOf`) libDeps `shouldBe` False
      any ("warp" `isInfixOf`) testSuiteDeps `shouldBe` True
      any ("wai" `isInfixOf`) testSuiteDeps `shouldBe` True

  describe "模組" $
    it "三個模組都註冊在 exposed-modules" $ do
      src <- readCabal
      mapM_
        (\m -> (m, m `isInfixOf` src) `shouldBe` (m, True))
        [ "StoryFlow.Workshop.Error"
        , "StoryFlow.Workshop.Session"
        , "StoryFlow.Workshop.Stages"
        ]

  describe "cabal.project" $ do
    it "packages 含 workshop/" $ do
      src <- readProject
      any ((== "workshop/") . trim) (lines src) `shouldBe` True

    it "含 package storyflow-workshop 的 ghc-options 段" $ do
      src <- readProject
      ("package storyflow-workshop" `isInfixOf` src) `shouldBe` True

    it "allow-newer 仍然只開三項,沒有為了本套件放寬" $ do
      src <- readProject
      let opened = [trim l | l <- lines src, "*:" `isPrefixOf` trim (dropWhile (== ',') (trim l))]
      opened `shouldBe` [", *:base", ", *:template-haskell", ", *:ghc-prim"]

-- | library 的相依__逐字__釘住。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base              >=4.14 && <5"
  , ", bytestring"
  , ", directory"
  , ", filepath"
  , ", mtl"
  , ", storyflow-core"
  , ", storyflow-llm"
  , ", storyflow-service"
  , ", text"
  , ", time"
  ]

-- | test-suite 的相依。@http-types@ 與 @time@ 是 F002 doc 的清單漏列、實測
-- 編譯需要的兩項(見文檔「待確認假設」A6)——stub 端點組 wai 的 Response 要用
-- @Network.HTTP.Types.Status@ \/ @.Header@;T7 的碰撞重試測試需要
-- @Data.Time@。
testDeps :: [String]
testDeps =
  [ ", aeson"
  , ", base"
  , ", bytestring"
  , ", directory"
  , ", filepath"
  , ", hspec"
  , ", http-types"
  , ", storyflow-core"
  , ", storyflow-llm"
  , ", storyflow-service"
  , ", storyflow-workshop"
  , ", temporary"
  , ", text"
  , ", time"
  , ", wai"
  , ", warp"
  ]

-- | 禁用的實作端套件。「所有讀取經 @ServiceM@」這條界線靠的正是這幾個名字
-- 不出現;@servant@ \/ @warp@ 是另一種違規——這一層不定義 CLI 與 REST 出口。
forbidden :: [String]
forbidden =
  [ "storyflow-store"
  , "storyflow-md"
  , "sqlite-simple"
  , "direct-sqlite"
  , "servant"
  , "warp"
  ]

librarySection :: String -> String
librarySection = unlines . takeWhile (not . isTestSuite) . lines

testSection :: String -> String
testSection = unlines . dropWhile (not . isTestSuite) . lines

isTestSuite :: String -> Bool
isTestSuite l = "test-suite" `isPrefixOf` l

readCabal :: IO String
readCabal = readFirst ["storyflow-workshop.cabal", "workshop/storyflow-workshop.cabal"]

readProject :: IO String
readProject = readFirst ["cabal.project", "../cabal.project"]

readFirst :: [FilePath] -> IO String
readFirst = go
  where
    go [] = fail "找不到要讀的檔案"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok
        then T.unpack . TE.decodeUtf8 <$> BS.readFile c
        else go rest

dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
