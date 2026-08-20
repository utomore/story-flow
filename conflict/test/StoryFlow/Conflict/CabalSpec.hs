-- | T1:套件邊界。
--
-- 這份 spec 的驗收標準 4 原本說「@build-depends@ 只有 @storyflow-core@,沒有
-- @storyflow-service@ / @storyflow-store@ / @storyflow-llm@」。那句話唯一守得住
-- 的形式是 @.cabal@ 檔裡沒有那些名字,所以用測試釘住,不是靠 code review 記得。
--
-- __conflict-detection/F003 T4:@storyflow-service@ 這一項被明確改掉了__ ——
-- 這正是 F001 註解預告的那一刻:
--
-- > @storyflow-conflict@ 後續會依賴 @service@(第 2 層要用它的 @searchEntity@),
-- > 那時這條測試要被明確改掉,而不是某次順手加相依就悄悄失去了「型別層不綁
-- > 實作進度」這個性質。
--
-- 放行的理由是本套件__已經不再只是型別套件__:F001 的斷言守的是「型別不被綁到
-- 某一層的實作進度上」,而第 2 層本來就是實作,它的存在前提就是 service 已經
-- 到位(service-and-interfaces 全部 done)。
--
-- 放行的同時把剩下四項守得__更緊__:斷言從單向的「不含」改成雙向的
-- 「必須含 service、仍然不含其餘四項」,而逐字釘住的相依清單則保證沒有第六個
-- 名字趁這一次順道混進來。
module StoryFlow.Conflict.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "第 2 層放行 service,其餘四項仍然擋住" $ do
  it "build-depends 含 storyflow-service(第 2 層的候選來源)" $ do
    deps <- dependencyLines <$> readCabal
    any ("storyflow-service" `isInfixOf`) deps `shouldBe` True

  it "build-depends 不含 store / md / llm / sqlite" $ do
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

  -- conflict-detection/F003 T11:第 2 層的模組要註冊得到,否則
  -- @Conflict.Pipeline@ 與 F004 都 import 不到它。
  it "exposed-modules 含 StoryFlow.Conflict.Retrieval" $ do
    src <- readCabal
    ("StoryFlow.Conflict.Retrieval" `isInfixOf` src) `shouldBe` True

-- | 函式庫的相依__逐字__釘住:驗收標準 6 說的是「沒有增長」,而
-- 「沒有出現在禁用清單裡」擋不住偷偷多一個包。
--
-- @mtl@ 是第 2 層唯一需要的新基礎相依:'Control.Monad.Except.catchError' 用來
-- 吞掉單一 @drRef@ 的 @EntityNotFound@ ——呼叫端給的 id 打錯一個,不該讓整條
-- @context@ 管線失敗。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base              >=4.14 && <5"
  , ", containers"
  , ", mtl"
  , ", storyflow-core"
  , ", storyflow-service"
  , ", text"
  ]

-- | test-suite 的相依。第 1 層的測試靠 core 的 @buildGraph@ 蓋圖;第 2 層的整合
-- 測試建臨時 Vault,而 @temporary@ \/ @directory@ \/ @filepath@ 加上
-- @storyflow-service@ 的門面就夠了——@storyflow-store@ 一次都不必露臉。
testDeps :: [String]
testDeps =
  [ ", aeson"
  , ", base"
  , ", bytestring"
  , ", directory"
  , ", filepath"
  , ", hspec"
  , ", storyflow-conflict"
  , ", storyflow-core"
  , ", storyflow-service"
  , ", temporary"
  , ", text"
  , ", time"
  ]

-- | 仍然禁用的實作端套件。「所有讀取經 @ServiceM@」這條子系統界線
-- (@conflict-detection/design.md@ 兩處明寫)靠的正是這四個名字不出現:
-- 只要其中一個進來,第 2 層就有可能繞過 service 自己開索引連線。
forbidden :: [String]
forbidden =
  [ "storyflow-store"
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
