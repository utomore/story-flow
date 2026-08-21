-- | T1:套件邊界。
--
-- 兩件不同的事,用兩種強度守:
--
-- * __第三方介面套件__(@servant@ \/ @warp@ \/ @optparse-applicative@ \/
--   @http-client@)用__黑名單__。ADR-006 說「@service@ 不涉及 HTTP 與終端輸出」,
--   而那句話唯一守得住的形式是 @build-depends@ 裡沒有那些套件。其餘第三方套件
--   (@time@ \/ @containers@ …)沒有架構意義,合法新增時不該讓測試噪音
--
-- * __內部 @storyflow-*@ 相依__用__逐字釘住的完整清單__(service-and-interfaces\/B001)。
--   往契約層加一個內部套件正是我們要抓的架構事件,黑名單抓不住「還沒被想到的那個名字」
--   ——@storyflow-workshop@ 與 @storyflow-mcp@ 都還不存在
--
-- __為什麼內部相依值得用最嚴的那一種__:子系統層級的依賴圖上有一個三跳環
--
-- > service-and-interfaces ──► conflict-detection ──► llm-workshop-mcp ──► service-and-interfaces
-- >   (api / server / cli)       (storyflow-conflict)   (storyflow-llm)      (storyflow-service)
--
-- 它之所以__不是__真的循環相依,完全靠 @storyflow-service@ 的 @build-depends@ 乾淨
-- ——ADR-011 把敘事拆成「契約層單向」與「介面包裝層是全面下游」,整套論證的地基就是
-- 這一條。@system.md@ 因此寫著它「由 @CabalSpec@ 的相依斷言釘住,不是靠自律」;
-- B001 發現那句話在 2026-08-22 之前是不成立的。
module StoryFlow.Service.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
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

  -- B001 T3:逐字釘住。library 段只准這四個 storyflow-* ——多一個就紅,
  -- 而「多出來的那一個」不必事先被列進任何黑名單。
  it "library 段的 storyflow-* 相依逐字相符" $ do
    txt <- readCabal
    internalDeps (librarySection txt) `shouldBe` sort libraryInternal

  it "test-suite 段的 storyflow-* 相依逐字相符" $ do
    txt <- readCabal
    internalDeps (testSuiteSection txt) `shouldBe` sort testInternal

  -- B001 T1:重現。把守衛套在一份「被動過手腳的」build-depends 上——契約層之上的
  -- 套件混進來時,守衛必須指得出來。
  --
  -- 直接對真實 .cabal 斷言證明不了這件事:service 目前的相依本來就乾淨,那條斷言
  -- 無論守衛完不完整都會綠。這正是 B001 的成因——舊守衛只有黑名單,而
  -- storyflow-conflict 不在黑名單上,測試卻依然全綠。
  it "守衛擋得住往契約層加 storyflow-conflict(B001 重現)" $ do
    let mutated = map (", " ++) (libraryInternal ++ ["storyflow-conflict"])
    internalDeps mutated `shouldNotBe` sort libraryInternal

  -- 同一個洞的另一半:未來才會出現的套件也要被擋住,而它們現在還不存在,
  -- 所以任何黑名單都列不到它們。
  it "守衛擋得住未來才出現的 storyflow-workshop / storyflow-mcp" $
    mapM_
      ( \p -> do
          let mutated = map (", " ++) (libraryInternal ++ [p])
          (p, internalDeps mutated == sort libraryInternal) `shouldBe` (p, False)
      )
      ["storyflow-workshop", "storyflow-mcp", "storyflow-llm"]

-- | 介面層才該有的相依。出現在這裡就是架構違規(ADR-006)。
--
-- __只列第三方套件__:內部 @storyflow-*@ 走下面的逐字清單,不靠黑名單。
forbidden :: [String]
forbidden = ["servant", "warp", "optparse-applicative", "http-client"]

required :: [String]
required = ["storyflow-core", "storyflow-md", "storyflow-store", "storyflow-types"]

-- | library 段允許的內部相依,__完整清單__。
--
-- 要往這裡加名字之前先問:@service@ 是「所有業務操作的唯一定義處」,
-- 而契約層一旦認識比它上層的東西,ADR-011 的依賴敘事就不成立了。
libraryInternal :: [String]
libraryInternal = ["storyflow-core", "storyflow-md", "storyflow-store", "storyflow-types"]

-- | test-suite 段允許的內部相依,__完整清單__。比 library 多一個
-- @storyflow-service@(測試要 import 受測套件本身)。
testInternal :: [String]
testInternal = "storyflow-service" : libraryInternal

-- | 一段 @build-depends@ 裡出現的 @storyflow-*@ 套件名,排序後回傳。
--
-- 取的是名字本身而不是整行,版本約束改動不會讓斷言紅。
internalDeps :: [String] -> [String]
internalDeps = sort . concatMap pick
  where
    pick l = [w | w <- words (map sep (trim l)), "storyflow-" `isPrefixOf` w]
    sep c = if c == ',' then ' ' else c

-- | @.cabal@ 的 library 段:從 @library@ 到第一個 @test-suite@ 之前。
librarySection :: String -> [String]
librarySection = dependencyLines' . takeWhile (not . ("test-suite" `isInfixOf`)) . lines

-- | @.cabal@ 的 test-suite 段。
testSuiteSection :: String -> [String]
testSuiteSection = dependencyLines' . dropWhile (not . ("test-suite" `isInfixOf`)) . lines

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
dependencyLines = dependencyLines' . lines

dependencyLines' :: [String] -> [String]
dependencyLines' = filter isDep
  where
    isDep l = case dropWhile isSpace l of
      (',' : _) -> True
      _ -> False

trim :: String -> String
trim = dropWhile isSpace
