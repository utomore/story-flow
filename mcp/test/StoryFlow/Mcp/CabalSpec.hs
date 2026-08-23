-- | T1 / T10:套件骨架與套件邊界。
--
-- 「@storyflow-mcp@ 不 import @storyflow-service@(只打 HTTP)」這條硬性邊界唯一
-- 守得住的形式,是 @.cabal@ 檔裡__沒有那些名字__——作法逐字沿用
-- @StoryFlow.Workshop.CabalSpec@\/@StoryFlow.Llm.CabalSpec@ 的先例:同一條紀律
-- 擋著同一批名字,再加上這個套件自己的兩個:@servant-client@\/@servant-server@
-- (查證結果 4:改用 @http-client@ 原生請求)與 @optparse-applicative@(待確認
-- 假設 A7:只有一個選項,手寫解析 argv)。
module StoryFlow.Mcp.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = do

  -- G-E002 T4:--version 從 cabal 自動產生的 Paths_ 模組讀版本,它要登記在 autogen-modules。
  it "autogen-modules 含 Paths_storyflow_mcp(G-E002)" $ do
    src <- readCabal
    ("Paths_storyflow_mcp" `isInfixOf` src) `shouldBe` True
    ("autogen-modules" `isInfixOf` src) `shouldBe` True
  describe "build-depends" $ do
    it "逐字等於設計裡的三份清單(library / executable / test-suite)" $ do
      deps <- map trim . dependencyLines <$> readCabal
      deps `shouldBe` libraryDeps ++ executableDeps ++ testDeps

    it "library 含 storyflow-api" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      any ("storyflow-api" `isInfixOf`) deps `shouldBe` True

    it "library 不含 storyflow-service / store / md / conflict / workshop / llm / core" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbiddenEverywhere

    it "整份檔案(含 test-suite)都不含 servant-client / servant-server / optparse-applicative" $ do
      deps <- dependencyLines <$> readCabal
      mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbiddenEverywhere

    it "warp / wai 只出現在 test-suite,library 不含" $ do
      src <- readCabal
      let libDeps = dependencyLines (librarySection src)
          testSuiteDeps = dependencyLines (testSection src)
      any ("warp" `isInfixOf`) libDeps `shouldBe` False
      any ("wai" `isInfixOf`) libDeps `shouldBe` False
      any ("warp" `isInfixOf`) testSuiteDeps `shouldBe` True
      any ("wai" `isInfixOf`) testSuiteDeps `shouldBe` True

  describe "模組" $ do
    it "六個 library 模組都註冊在 exposed-modules" $ do
      src <- readCabal
      mapM_
        (\m -> (m, m `isInfixOf` src) `shouldBe` (m, True))
        [ "StoryFlow.Mcp"
        , "StoryFlow.Mcp.Client"
        , "StoryFlow.Mcp.Config"
        , "StoryFlow.Mcp.Protocol"
        , "StoryFlow.Mcp.Server"
        , "StoryFlow.Mcp.Tools"
        ]

    it "執行檔 story-flow-mcp 存在" $ do
      src <- readCabal
      ("executable story-flow-mcp" `isInfixOf` src) `shouldBe` True

  describe "cabal.project" $ do
    it "packages 含 mcp/" $ do
      src <- readProject
      any ((== "mcp/") . trim) (lines src) `shouldBe` True

    it "含 package storyflow-mcp 的 ghc-options 段" $ do
      src <- readProject
      ("package storyflow-mcp" `isInfixOf` src) `shouldBe` True

    it "allow-newer 仍然只開三項,沒有為了本套件放寬" $ do
      src <- readProject
      let opened = [trim l | l <- lines src, "*:" `isPrefixOf` trim (dropWhile (== ',') (trim l))]
      opened `shouldBe` [", *:base", ", *:template-haskell", ", *:ghc-prim"]

-- | library 的相依__逐字__釘住。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base                        >=4.14 && <5"
  , ", bytestring"
  , ", http-client"
  , ", http-types"
  , ", insert-ordered-containers"
  , ", lens"
  , ", openapi3"
  , ", scientific"
  , ", storyflow-api"
  , ", text"
  ]

executableDeps :: [String]
executableDeps =
  [ ", base"
  , ", storyflow-mcp"
  , ", text"
  ]

testDeps :: [String]
testDeps =
  [ ", aeson"
  , ", base"
  , ", bytestring"
  , ", directory"
  , ", hspec"
  , ", http-types"
  , ", insert-ordered-containers"
  , ", lens"
  , ", openapi3"
  , ", storyflow-api"
  , ", storyflow-mcp"
  , ", text"
  , ", wai"
  , ", warp"
  ]

-- | 禁用的實作端套件,全檔(含 test-suite)都不准出現。「只打 HTTP」這條界線
-- 靠的正是這幾個名字不出現;@servant-client@\/@servant-server@ 是另一種違規
-- ——這一層不用 servant 產生的 client,也不是伺服器。
forbiddenEverywhere :: [String]
forbiddenEverywhere =
  [ "storyflow-service"
  , "storyflow-store"
  , "storyflow-md"
  , "storyflow-conflict"
  , "storyflow-workshop"
  , "storyflow-llm"
  , "storyflow-core"
  , "servant-client"
  , "servant-server"
  , "optparse-applicative"
  ]

librarySection :: String -> String
librarySection = unlines . takeWhile (not . isExecutableOrTestSuite) . lines

testSection :: String -> String
testSection = unlines . dropWhile (not . isTestSuite) . lines

isExecutableOrTestSuite :: String -> Bool
isExecutableOrTestSuite l = "executable" `isPrefixOf` l || isTestSuite l

isTestSuite :: String -> Bool
isTestSuite l = "test-suite" `isPrefixOf` l

readCabal :: IO String
readCabal = readFirst ["storyflow-mcp.cabal", "mcp/storyflow-mcp.cabal"]

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
