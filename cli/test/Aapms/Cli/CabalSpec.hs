-- | T1(service-and-interfaces/F002):套件邊界。
--
-- service-and-interfaces/F002 驗收標準 3 是「@aapms-cli.cabal@ 的 @build-depends@ 不含
-- @sqlite-simple@ \/ @direct-sqlite@ \/ @aapms-store@」。service-and-interfaces/F003 又加了一條
-- 架構上的要求:__CLI 不能依賴 @aapms-server@ 與 @warp@__ ——system.md
-- 讓 @aapms-api@ 獨立成套件的理由正是「一個預設根本不開伺服器的執行檔不該
-- 把整套 HTTP 伺服器拖進來」。
--
-- 檢查__只看 @library@ 那一段__。測試套件會為了跑遠端模式的對照而起一台真的
-- 伺服器,所以它依賴 @aapms-server@ 是合理的——那不會進到出貨的執行檔裡。
-- 舊版把整個檔案的相依行一起看,那樣一來測試套件的相依就會把這條保護稀釋掉。
module Aapms.Cli.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "套件邊界" $ do

  -- G-E002 T4:--version 從 cabal 自動產生的 Paths_ 模組讀版本,它要登記在 autogen-modules。
  it "autogen-modules 含 Paths_aapms_cli(G-E002)" $ do
    src <- readCabal
    ("Paths_aapms_cli" `isInfixOf` src) `shouldBe` True
    ("autogen-modules" `isInfixOf` src) `shouldBe` True
  it "library 的 build-depends 不含落地層,也不含伺服器" $ do
    deps <- dependencyLines . stanza "library" <$> readCabal
    deps `shouldSatisfy` (not . null) -- 沒切到東西的話下面全都是空過
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "library 含它真正依賴的套件" $ do
    deps <- dependencyLines . stanza "library" <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True)) required

  it "executable 也不含伺服器(出貨的那個二進位檔)" $ do
    deps <- dependencyLines . stanza "executable" <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

-- | 落地層 + 伺服器。出現在 library 或 executable 就是架構違規。
forbidden :: [String]
forbidden =
  [ "aapms-store"
  , "aapms-md"
  , "sqlite-simple"
  , "direct-sqlite"
  , "aapms-server"
  , "warp"
  , "servant-server"
  ]

-- | conflict-detection/F004:@aapms-conflict@ 加進來。
--
-- @aapms context@ 的 'Aapms.Cli.Options.Command' 帶 @ConflictOpts@、
-- 渲染器要認得 @ContextHit@、內嵌路徑要呼叫 @gatherContext@ ——三處都在 library。
-- 它__不在 forbidden 裡__而且不該在:它的 @build-depends@ 自己就逐字擋著落地層,
-- 所以「CLI 碰不到落地層」這條保護不會因為它而被繞過。
--
-- llm-workshop-mcp/F004:@aapms-workshop@ \/ @aapms-llm@ 同一個理由加進
-- 這張表——兩者的 @build-depends@ 各自擋著落地層,「往介面層加一個內部套件」
-- 這件事被這條測試看見,而不是被它擋下。
required :: [String]
required =
  [ "aapms-service"
  , "aapms-core"
  , "aapms-api"
  , "aapms-conflict"
  , "aapms-workshop"
  , "aapms-llm"
  , "optparse-applicative"
  , "servant-client"
  ]

-- | 取出某個 stanza 的內容:從它的標頭那一行,到下一個頂層標頭為止。
stanza :: String -> String -> [String]
stanza name = takeWhile notNextHeader . drop 1 . dropWhile (not . isHeader) . lines
  where
    isHeader l = name `isPrefixOf` l
    notNextHeader l = case l of
      (c : _) -> isSpace c
      [] -> True

readCabal :: IO String
readCabal = go ["aapms-cli.cabal", "cli/aapms-cli.cabal"]
  where
    go [] = fail "找不到 aapms-cli.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then T.unpack . TE.decodeUtf8 <$> BS.readFile c else go rest

-- | 只看以逗號開頭的行,避免把註解裡出現的字算進去——本檔案的 .cabal 註解就
-- 正好提到了 aapms-store 與 warp。
dependencyLines :: [String] -> [String]
dependencyLines = filter isDep
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
