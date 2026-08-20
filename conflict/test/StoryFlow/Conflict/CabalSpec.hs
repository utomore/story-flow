-- | T1:套件邊界。
--
-- 這份 spec 的驗收標準 4 說「@build-depends@ 只有 @storyflow-core@,沒有
-- @storyflow-service@ / @storyflow-store@ / @storyflow-llm@」。那句話唯一守得住
-- 的形式是 @.cabal@ 檔裡沒有那些名字,所以用測試釘住,不是靠 code review 記得。
--
-- 為什麼值得釘:@storyflow-conflict@ 後續會依賴 @service@(第 2 層要用它的
-- @searchEntity@),那時這條測試要__被明確改掉__,而不是某次順手加相依就悄悄
-- 失去了「型別層不綁實作進度」這個性質。
module StoryFlow.Conflict.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "型別套件不依賴任何實作端" $ do
  it "build-depends 不含 service / store / md / llm / sqlite" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  it "build-depends 含 storyflow-core" $ do
    deps <- dependencyLines <$> readCabal
    any ("storyflow-core" `isInfixOf`) deps `shouldBe` True

  -- conflict-detection/F002 T7:第 1 層是純函式,長出一個新模組不該把
  -- service / store 拖進來。新模組要在 exposed-modules 裡,相依維持原樣。
  it "新增模組未帶進新相依" $ do
    src <- readCabal
    ("StoryFlow.Conflict.Graph" `isInfixOf` src) `shouldBe` True
    let deps = dependencyLines src
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden
    map trim deps `shouldBe` libraryDeps ++ testDeps

-- | 函式庫的相依__逐字__釘住:驗收標準 6 說的是「沒有增長」,而
-- 「沒有出現在禁用清單裡」擋不住偷偷多一個包。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base            >=4.14 && <5"
  , ", containers"
  , ", storyflow-core"
  , ", text"
  ]

-- | test-suite 的相依。第 1 層的測試靠 core 的 @buildGraph@ 蓋圖、靠
-- 'Data.Foldable.toList' 觀測 @Map@ / @Set@,所以這裡也沒有多出東西。
testDeps :: [String]
testDeps =
  [ ", aeson"
  , ", base"
  , ", bytestring"
  , ", directory"
  , ", hspec"
  , ", storyflow-conflict"
  , ", storyflow-core"
  , ", text"
  , ", time"
  ]

-- | 實作端的套件。出現在這裡就是架構違規——型別會被綁到某一層的實作進度上。
forbidden :: [String]
forbidden =
  [ "storyflow-service"
  , "storyflow-store"
  , "storyflow-md"
  , "storyflow-llm"
  , "sqlite-simple"
  ]

-- | 以 UTF-8 讀,不走系統預設編碼:@.cabal@ 裡有繁中註解,而 Windows 的預設
-- code page 會在讀到第一個中文字時直接丟 InvalidArgument。
readCabal :: IO String
readCabal = go ["storyflow-conflict.cabal", "conflict/storyflow-conflict.cabal"]
  where
    go [] = fail "找不到 storyflow-conflict.cabal"
    go (c : rest) = do
      ok <- doesFileExist c
      if ok
        then T.unpack . TE.decodeUtf8 <$> BS.readFile c
        else go rest

-- | 只看以逗號開頭的行,避免把註解裡出現的字算進去——本套件的 @.cabal@ 註解
-- 就正好提到了 service 與 store。
dependencyLines :: String -> [String]
dependencyLines = filter isDep . lines
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False

-- | 去掉前後空白。@.cabal@ 是 CRLF,'lines' 會把 @\\r@ 留在行尾。
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
