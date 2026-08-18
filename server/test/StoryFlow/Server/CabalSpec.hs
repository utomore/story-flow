-- | T6:server 不依賴落地層。
--
-- func-0008 驗收標準 3 的一半是「@storyflow-server@ 不 import @storyflow-store@」。
-- 那句話唯一守得住的形式是 @build-depends@ 裡沒有它——而這條約束正是
-- "StoryFlow.Server.Error" 改成以 'StoryFlow.Service.errorCode' 的字串分派狀態碼、
-- 而不是對 @StoreError@ 的建構子 pattern match 的原因。
module StoryFlow.Server.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "套件邊界" $ do
  it "build-depends 不含落地層" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "build-depends 含它真正依賴的三個內部套件" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, True)) required

forbidden :: [String]
forbidden = ["storyflow-store", "storyflow-md", "sqlite-simple", "direct-sqlite", "storyflow-cli"]

required :: [String]
required = ["storyflow-api", "storyflow-core", "storyflow-service", "warp", "servant-server"]

readCabal :: IO String
readCabal = go ["storyflow-server.cabal", "server/storyflow-server.cabal"]
  where
    go [] = fail "找不到 storyflow-server.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok then T.unpack . TE.decodeUtf8 <$> BS.readFile c else go rest

-- | 只看以逗號開頭的行:本檔案的 .cabal 註解就正好提到了 storyflow-store。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False
