-- | T9:@entity new@ 建檔並正確解析 @--link@。
--
-- @--link \<kind\>:\<target\>[:\<note\>]@ 的緊湊格式存在的理由是 @entity new@
-- 常常要一次掛好幾條 @partOf@。它的解析在 T2 已經測過純函式那一半,這裡測的是
-- __解出來的東西真的寫進檔案了__。
module StoryFlow.Cli.EntityNewSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import StoryFlow.Cli.Fixtures
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "entity new / add" $ do
  it "建出來的檔案落在註冊表宣告的目錄" $ withCliVault $ \dir -> do
    out <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    out `shouldContainT` "已建立"
    exists <- doesFileExist (dir </> "characters" </> "琳達.md")
    exists `shouldBe` True

  it "--link 的三段解出 kind / target / note 並寫進檔案" $ withCliVault $ \_ -> do
    main <- newLinda
    env <-
      sfJson
        [ "entity"
        , "new"
        , "--type"
        , "character-fragment"
        , "--title"
        , "與塔主的過節"
        , "--summary"
        , "十四歲時因塔主徵召失去雙親"
        , "--link"
        , "partOf:" <> main <> ":對雙親死因不一致"
        ]
    case jsonPath ["data", "entity", "links"] env of
      Just (Array ls) -> do
        length ls `shouldBe` 1
        let l = firstOf ls
        jsonPath ["kind"] l `shouldBe` Just (String "partOf")
        jsonPath ["target"] l `shouldBe` Just (String (T.pack main))
        jsonPath ["note"] l `shouldBe` Just (String "對雙親死因不一致")
      other -> expectationFailure ("links 取不到:" <> show other)

  it "--link 只有兩段時沒有 note 這個鍵" $ withCliVault $ \_ -> do
    main <- newLinda
    env <-
      sfJson
        [ "entity"
        , "new"
        , "--type"
        , "character-fragment"
        , "--title"
        , "外貌"
        , "--summary"
        , "銀灰短髮"
        , "--link"
        , "partOf:" <> main
        ]
    case jsonPath ["data", "entity", "links"] env of
      Just (Array ls) -> jsonPath ["note"] (firstOf ls) `shouldBe` Nothing
      other -> expectationFailure ("links 取不到:" <> show other)

  -- service 的懸空目標檢查在 addLink,不在 createEntity(service-and-interfaces/F001 的
  -- requireTargetExists 只掛在前者)。CLI 不自己補一份——那是業務判斷,補在這裡
  -- 就會與 REST 的行為不一致。這一條把現況釘住,而不是假裝它不存在。
  it "entity new 的 --link 不驗目標存在(驗的是 link add)" $ withCliVault $ \_ -> do
    _ <- newLinda
    r <-
      sf
        ["entity", "new", "--type", "character-fragment", "--title", "外貌", "--summary", "s", "--link", "partOf:ent-00000000"]
    crExit r `shouldBe` ExitSuccess
    env <- sfJson ["link", "add", "外貌", "--kind", "partOf", "--target", "ent-00000001"]
    env `shouldHaveCode` "dangling_link_target"

  it "--tag 可重複,而且都進了檔案" $ withCliVault $ \_ -> do
    env <-
      sfJson
        ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手", "--tag", "外觀", "--tag", "動機"]
    case jsonPath ["data", "entity", "tags"] env of
      Just (Array ts) -> length ts `shouldBe` 2
      other -> expectationFailure ("tags 取不到:" <> show other)

  it "--body 進了正文,--body-file 也是" $ withCliVault $ \dir -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s", "--body", "那年她十四歲"]
    out <- sfOk ["entity", "show", "琳達"]
    out `shouldContainT` "那年她十四歲"
    -- 以 UTF-8 寫,不走 Haskell 的 writeFile ——它用系統預設編碼,
    -- 在 cp950 的機器上寫出來的位元組 CLI 讀不回來
    BS.writeFile (dir </> "body.txt") (TE.encodeUtf8 "從檔案來的正文")
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "埃提亞", "--summary", "s", "--body-file", dir </> "body.txt"]
    out2 <- sfOk ["entity", "show", "埃提亞"]
    out2 `shouldContainT` "從檔案來的正文"

  it "--body-file 讀不到時是 input_unreadable,不是崩潰" $ withCliVault $ \dir -> do
    env <-
      sfJson
        ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s", "--body-file", dir </> "沒這個檔"]
    env `shouldHaveCode` "input_unreadable"

  it "型別不在註冊表裡時 exit 1" $ withCliVault $ \_ -> do
    r <- sf ["entity", "new", "--type", "沒這種型別", "--title", "x", "--summary", "s"]
    crExit r `shouldBe` ExitFailure 1
    env <- sfJson ["entity", "new", "--type", "沒這種型別", "--title", "x", "--summary", "s"]
    env `shouldHaveCode` "unknown_type"

  it "必填欄位缺漏時拒絕寫入,一個位元組都不寫" $ withCliVault $ \dir -> do
    env <- sfJson ["entity", "new", "--type", "lore-fragment", "--title", "埃提亞"]
    env `shouldHaveCode` "validation_failed"
    exists <- doesFileExist (dir </> "lore" </> "埃提亞.md")
    exists `shouldBe` False

  it "entity add 之後主體的 revision +1" $ withCliVault $ \_ -> do
    _ <- newLinda
    rev0 <- jsonPath ["data", "entity", "revision"] <$> sfJson ["entity", "show", "琳達"]
    _ <- sfOk ["entity", "add", "琳達", "--title", "外貌", "--summary", "銀灰短髮", "--type", "character-fragment"]
    rev1 <- jsonPath ["data", "entity", "revision"] <$> sfJson ["entity", "show", "琳達"]
    (rev0, rev1) `shouldBe` (Just (Number 1), Just (Number 2))

  it "entity add 的片段是獨立的 Entity,查得到" $ withCliVault $ \_ -> do
    _ <- newLinda
    _ <- sfOk ["entity", "add", "琳達", "--title", "外貌", "--summary", "銀灰短髮", "--type", "character-fragment"]
    out <- sfOk ["entity", "show", "外貌"]
    out `shouldContainT` "銀灰短髮"

-- | 建一個當關聯目標用的主體,回它的 id。
newLinda :: IO String
newLinda =
  idFromJson
    <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]

-- | JSON 陣列的第一個元素。測試前一行已經斷言過長度,這裡只是取出來。
firstOf :: Foldable t => t Value -> Value
firstOf xs = case foldr (:) [] xs of
  (x : _) -> x
  [] -> error "預期陣列至少有一個元素"
