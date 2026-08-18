-- | T1:套件邊界。
--
-- ADR-0006 說「@service@ 不涉及 HTTP 與終端輸出」,而那句話唯一守得住的形式是
-- @build-depends@ 裡沒有那些套件。用測試釘住它,不是靠 code review 記得。
module StoryFlow.Service.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "套件邊界" $ do
  it "build-depends 不含介面層套件" $ do
    txt <- readCabal
    let deps = dependencyLines txt
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "build-depends 含它真正依賴的四個內部套件" $ do
    txt <- readCabal
    let deps = dependencyLines txt
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True)) required

-- | 介面層才該有的相依。出現在這裡就是架構違規。
forbidden :: [String]
forbidden = ["servant", "warp", "optparse-applicative", "http-client"]

required :: [String]
required = ["storyflow-core", "storyflow-md", "storyflow-store", "storyflow-types"]

-- | 以 UTF-8 讀,不走系統預設編碼:.cabal 檔裡有繁中註解,而 Windows 的
-- 預設 code page 會在讀到第一個中文字時直接丟 InvalidArgument。
readCabal :: IO String
readCabal = go ["storyflow-service.cabal", "service/storyflow-service.cabal"]
  where
    go [] = fail "找不到 storyflow-service.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok
        then T.unpack . TE.decodeUtf8 <$> BS.readFile c
        else go rest

-- | 只看 @build-depends@ 之後那些以逗號開頭的行,避免把註解裡出現的字算進去
-- ——本檔的註解就正好提到了 servant。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
