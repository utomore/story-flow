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
-- __conflict-detection/F005 T4:@storyflow-llm@ 這一項也被明確改掉了__——第 3 層
-- (@Conflict.Judge@)消費 @llm-workshop-mcp@ 的 @LlmClient@ / @chat@,存在前提是
-- @storyflow-llm@ 已經到位(llm-workshop-mcp/F001 已 done)。forbidden 清單因此從
-- 四項縮成三項:@storyflow-store@ / @storyflow-md@ / @sqlite-simple@。
--
-- 放行的同時把剩下三項守得__更緊__:斷言從單向的「不含」改成雙向的
-- 「必須含 service、llm,仍然不含其餘三項」,而逐字釘住的相依清單則保證沒有第七個
-- 名字趁這一次順道混進來。
module StoryFlow.Conflict.CabalSpec (spec) where

import qualified Data.ByteString as BS
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Control.Monad (filterM)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (</>))
import Test.Hspec

spec :: Spec
spec = describe "第 3 層放行 llm,其餘三項仍然擋住" $ do
  it "build-depends 含 storyflow-service(第 2 層的候選來源)" $ do
    deps <- dependencyLines <$> readCabal
    any ("storyflow-service" `isInfixOf`) deps `shouldBe` True

  -- conflict-detection/F005 T4:library 與 test-suite 各一次(假 runner 的型別
  -- LlmClient / Message / Role / LlmError 都從 storyflow-llm 來)。
  it "build-depends 含 storyflow-llm(library 與 test-suite 各一次)" $ do
    src <- readCabal
    let deps = dependencyLines src
    length (filter ("storyflow-llm" `isInfixOf`) deps) `shouldBe` 2

  it "build-depends 不含 store / md / sqlite" $ do
    deps <- dependencyLines <$> readCabal
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  -- bytestring 只在 test-suite 段(既有的整合測試相依),library 不必為了
  -- eitherDecodeStrictText 長出它。
  it "bytestring 不在 library 段" $ do
    src <- readCabal
    let (librarySection, testSuiteSection) = break ("test-suite" `isInfixOf`) (lines src)
    any ("bytestring" `isInfixOf`) librarySection `shouldBe` False
    any ("bytestring" `isInfixOf`) testSuiteSection `shouldBe` True

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

  -- conflict-detection/E001 T5:門面與實作拆開之後,Internal 也要註冊得到,
  -- 否則測試 import 不到它。
  it "exposed-modules 含 StoryFlow.Conflict.Retrieval.Internal(E001)" $ do
    src <- readCabal
    ("StoryFlow.Conflict.Retrieval.Internal" `isInfixOf` src) `shouldBe` True

  -- conflict-detection/E001 T6:__本次優化唯一的長期保護__。
  --
  -- E001 收斂匯出面是為了兌現契約卡那句「候選撈取策略本身是本模組的內部抽象」,
  -- 以及 ADR-007 的「換一種候選策略不必動第 1、3 層」。但收斂只是__一次性__的動作
  -- ——下一個 feature 隨手 @import StoryFlow.Conflict.Retrieval.Internal@ 就把閘門
  -- 重新打開,而且__一樣不會有任何測試變紅__。這條斷言就是那個會變紅的東西。
  --
  -- 只看 @src/@:測試 import Internal 正是它存在的理由。
  it "src/ 底下只有 Retrieval.hs 能碰 Retrieval.Internal(E001)" $ do
    files <- srcFiles
    offenders <- filterM (fmap (isInfixOf internalName) . readUtf8) (filter notFacade files)
    offenders `shouldBe` []

  -- 同一條守衛的重現:對真實的 src/ 斷言證明不了守衛完整——它現在本來就乾淨,
  -- 那條斷言無論守衛寫得對不對都會綠。與 service-and-interfaces/B001 同一個做法。
  it "守衛擋得住 Pipeline.hs 偷 import Internal(E001 重現)" $ do
    let mutated :: [(String, String)]
        mutated = [("Pipeline.hs", "import " ++ internalName ++ " (mergeCandidates)")]
    [f | (f, body) <- mutated, internalName `isInfixOf` body] `shouldBe` ["Pipeline.hs"]

  -- conflict-detection/F004 T6:合流與 context 出口的模組。
  --
  -- 它接上了 @service@ 的 @linkGraph@,而 @linkGraph@ 背後是
  -- @storyflow-store@ 的 @loadLinkGraph@ —— __相依清單卻一個字都不該變__:
  -- 那正是「整張圖只經 ServiceM 拿」這條界線的證明。相依若在這裡長出
  -- @storyflow-store@,就代表 Pipeline 自己去讀索引了。
  it "exposed-modules 含 StoryFlow.Conflict.Pipeline,且相依清單一個字沒變" $ do
    src <- readCabal
    ("StoryFlow.Conflict.Pipeline" `isInfixOf` src) `shouldBe` True
    let deps = dependencyLines src
    map trim deps `shouldBe` libraryDeps ++ testDeps
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

  -- conflict-detection/F005 T4:第 3 層的模組要註冊得到,否則 F006 import 不到它。
  it "exposed-modules 含 StoryFlow.Conflict.Judge,且相依清單逐字相符" $ do
    src <- readCabal
    ("StoryFlow.Conflict.Judge" `isInfixOf` src) `shouldBe` True
    let deps = dependencyLines src
    map trim deps `shouldBe` libraryDeps ++ testDeps
    mapM_ (\p -> (p, any (p `isInfixOf`) deps) `shouldBe` (p, False)) forbidden

-- | 函式庫的相依__逐字__釘住:驗收標準 6 說的是「沒有增長」,而
-- 「沒有出現在禁用清單裡」擋不住偷偷多一個包。
--
-- @mtl@ 是第 2 層唯一需要的新基礎相依:'Control.Monad.Except.catchError' 用來
-- 吞掉單一 @drRef@ 的 @EntityNotFound@ ——呼叫端給的 id 打錯一個,不該讓整條
-- @context@ 管線失敗。
--
-- @storyflow-llm@ 是第 3 層(conflict-detection/F005)放行的新相依:
-- @Conflict.Judge@ 消費它的 @LlmClient@ / @chat@,不實作端點。本 feature
-- __不新增任何其他相依__:@aeson@ 的 @eitherDecodeStrictText@ 讓 @bytestring@
-- 不必進 library 段,@liftIO@ 在 @base@,@mtl@ 早就在了。
libraryDeps :: [String]
libraryDeps =
  [ ", aeson"
  , ", base              >=4.14 && <5"
  , ", containers"
  , ", mtl"
  , ", storyflow-core"
  , ", storyflow-llm"
  , ", storyflow-service"
  , ", text"
  ]

-- | test-suite 的相依。第 1 層的測試靠 core 的 @buildGraph@ 蓋圖;第 2 層的整合
-- 測試建臨時 Vault,而 @temporary@ \/ @directory@ \/ @filepath@ 加上
-- @storyflow-service@ 的門面就夠了——@storyflow-store@ 一次都不必露臉。
-- @storyflow-llm@ 是第 3 層假 runner 的型別來源(@LlmClient@ / @Message@ /
-- @Role@ / @LlmError@),測試套件不建立任何真正指向網路端點的用戶端,不必新增
-- @mtl@ 相依
-- (假 runner 跑在 @IO@ 上,用 @Data.IORef@ 記錄呼叫,@IORef@ 在 @base@)。
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
  , ", storyflow-llm"
  , ", storyflow-service"
  , ", temporary"
  , ", text"
  , ", time"
  ]

-- | 仍然禁用的實作端套件。「所有讀取經 @ServiceM@」這條子系統界線
-- (@conflict-detection/design.md@ 兩處明寫)靠的正是這三個名字不出現:
-- 只要其中一個進來,就有可能繞過 service 自己開索引連線。
-- @storyflow-llm@ 自 conflict-detection/F005 起已放行(見上方 library 段落),
-- 不再是禁用名單的一員。
forbidden :: [String]
forbidden =
  [ "storyflow-store"
  , "storyflow-md"
  , "sqlite-simple"
  ]

-- | 以 UTF-8 讀,不走系統預設編碼:@.cabal@ 裡有繁中註解,而 Windows 的預設
-- code page 會在讀到第一個中文字時直接丟 InvalidArgument。
-- | 兩個檔案本來就會出現那個字串,不算違規:
--
-- * @Internal.hs@ —— 它的 @module@ 宣告就是那個名字
-- * @Retrieval.hs@ —— 門面是__唯一__允許 import 它的 @src/@ 檔案
notFacade :: FilePath -> Bool
notFacade f = takeFileName f `notElem` ["Retrieval.hs", "Internal.hs"]

internalName :: String
internalName = "StoryFlow.Conflict.Retrieval.Internal"

-- | @conflict/src/@ 底下所有 @.hs@,遞迴。
srcFiles :: IO [FilePath]
srcFiles = go =<< srcRoot
  where
    go dir = do
      names <- listDirectory dir
      fmap concat . mapM (step . (dir </>)) $ names
    step path = do
      isDir <- doesDirectoryExist path
      if isDir
        then go path
        else pure [path | takeExtension path == ".hs"]

-- | 測試可能從專案根目錄或從 @conflict/@ 底下跑。
srcRoot :: IO FilePath
srcRoot = go ["src", "conflict" </> "src"]
  where
    go [] = fail "找不到 conflict/src"
    go (d : rest) = do
      ok <- doesDirectoryExist d
      if ok then pure d else go rest

readUtf8 :: FilePath -> IO String
readUtf8 f = T.unpack . TE.decodeUtf8 <$> BS.readFile f

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
