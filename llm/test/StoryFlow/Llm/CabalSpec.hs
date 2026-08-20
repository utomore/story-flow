-- | T10:套件邊界。
--
-- 「@storyflow-llm@ 不直接依賴 @storyflow-store@,設定經 @ServiceM@ 取得」這條
-- 界線唯一守得住的形式,是 @.cabal@ 檔裡__沒有那些名字__ ——靠 code review 記得
-- 是守不住的。作法逐字沿用 @StoryFlow.Conflict.CabalSpec@:那個套件用同一條紀律
-- 擋著同一批名字。
--
-- @warp@ \/ @wai@ 的處理是這裡特有的:它們是測試底稿的工具(起本機 stub 端點),
-- __只准出現在 test-suite__。跑進 library 就代表這一層自己開始聽 port 了。
module StoryFlow.Llm.CabalSpec (spec) where

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
    -- 「沒有出現在禁用清單裡」擋不住順手多一個包,所以逐字釘住整份清單。
    it "逐字等於設計裡的那兩份清單" $ do
      deps <- map trim . dependencyLines <$> readCabal
      deps `shouldBe` libraryDeps ++ testDeps

    -- 設定的唯一來源。少了它,llmConfig 就沒有合法的路徑拿得到 Vault 設定。
    it "library 含 storyflow-service" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      any ("storyflow-service" `isInfixOf`) deps `shouldBe` True

    it "library 不含 store / md / sqlite / servant / warp" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

    -- 刻意不含 core:這一層不認得 Entity / Meta / Id,它只把 [Message] 搬進去、
    -- 把 Text 搬出來。相依裡一旦出現 core,下一個人就會忍不住在這裡組 prompt。
    it "library 不含 storyflow-core" $ do
      deps <- dependencyLines . librarySection <$> readCabal
      any ("storyflow-core" `isInfixOf`) deps `shouldBe` False

    it "warp / wai 只出現在 test-suite" $ do
      src <- readCabal
      let libDeps = dependencyLines (librarySection src)
          testSuiteDeps = dependencyLines (testSection src)
      any ("warp" `isInfixOf`) libDeps `shouldBe` False
      any ("wai" `isInfixOf`) libDeps `shouldBe` False
      any ("warp" `isInfixOf`) testSuiteDeps `shouldBe` True
      any ("wai" `isInfixOf`) testSuiteDeps `shouldBe` True

  describe "模組" $
    it "四個模組都註冊在 exposed-modules" $ do
      src <- readCabal
      mapM_
        (\m -> (m, m `isInfixOf` src) `shouldBe` (m, True))
        [ "StoryFlow.Llm"
        , "StoryFlow.Llm.Client"
        , "StoryFlow.Llm.Config"
        , "StoryFlow.Llm.Error"
        ]

  describe "cabal.project" $ do
    it "packages 含 llm/" $ do
      src <- readProject
      any ((== "llm/") . trim) (lines src) `shouldBe` True

    it "含 package storyflow-llm 的 ghc-options 段" $ do
      src <- readProject
      ("package storyflow-llm" `isInfixOf` src) `shouldBe` True

    -- 設計階段實測 http-client-tls-0.3.6.4 在現行政策下裝得起來,所以沒有理由
    -- 放寬它。allow-newer 的註解自己寫著「只對確定安全的套件開放」。
    it "allow-newer 仍然只開三項,沒有為了 http-client-tls 放寬" $ do
      src <- readProject
      let opened = [trim l | l <- lines src, "*:" `isPrefixOf` trim (dropWhile (== ',') (trim l))]
      opened `shouldBe` [", *:base", ", *:template-haskell", ", *:ghc-prim"]

-- | 函式庫的相依__逐字__釘住。
--
-- @containers@ 與 @toml-reader@ 是為了拆 @[llm]@ 那張表
-- (@TOML.Table = Map Text Value@);@http-client-tls@ 讓同一個 manager 同時吃
-- 地端的 http 與雲端的 https。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base              >=4.14 && <5"
  , ", bytestring"
  , ", containers"
  , ", http-client"
  , ", http-client-tls"
  , ", http-types"
  , ", storyflow-service"
  , ", text"
  , ", toml-reader"
  ]

-- | test-suite 的相依。@http-client@ 在這裡是給「那個埠真的拒絕連線」的前提
-- 斷言直接探測用的;@wai@ + @warp@ 起 stub 端點。
testDeps :: [String]
testDeps =
  [ ", aeson"
  , ", base"
  , ", bytestring"
  , ", containers"
  , ", directory"
  , ", filepath"
  , ", hspec"
  , ", http-client"
  , ", http-types"
  , ", storyflow-llm"
  , ", storyflow-service"
  , ", temporary"
  , ", text"
  , ", toml-reader"
  , ", wai"
  , ", warp"
  ]

-- | 禁用的實作端套件。「所有讀取經 @ServiceM@」這條界線靠的正是這幾個名字
-- 不出現:只要其中一個進來,這一層就有可能繞過 service 自己開索引連線。
--
-- @servant@ \/ @warp@ 是另一種違規:這一層不定義 CLI 與 REST 出口。
forbidden :: [String]
forbidden =
  [ "storyflow-store"
  , "storyflow-md"
  , "sqlite-simple"
  , "direct-sqlite"
  , "servant"
  , "warp"
  ]

-- | library 段:從檔頭到第一個 @test-suite@ 之前。
librarySection :: String -> String
librarySection = unlines . takeWhile (not . isTestSuite) . lines

-- | test-suite 段。
testSection :: String -> String
testSection = unlines . dropWhile (not . isTestSuite) . lines

isTestSuite :: String -> Bool
isTestSuite l = "test-suite" `isPrefixOf` l

-- | 以 UTF-8 讀,不走系統預設編碼:@.cabal@ 裡有繁中註解,而 Windows 的預設
-- code page 會在讀到第一個中文字時直接丟 InvalidArgument。
readCabal :: IO String
readCabal = readFirst ["storyflow-llm.cabal", "llm/storyflow-llm.cabal"]

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

-- | 只看以逗號開頭的行,避免把註解裡出現的字算進去——本套件的 @.cabal@ 註解
-- 就正好提到了 store 與 warp。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False

-- | 去掉前後空白。@.cabal@ 是 CRLF,'lines' 會把 @\\r@ 留在行尾。
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
