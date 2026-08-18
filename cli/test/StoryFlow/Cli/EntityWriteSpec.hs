-- | T11:先讀再寫與 @--revision@ 覆寫。
--
-- service 的每個修改操作都要 expected revision(func-0006 刻意設成必填,不留
-- 逃生口)。CLI 的填法是兩條路:不帶 @--revision@ 就先讀一次拿當前值,人用起來
-- 是「改一欄就改一欄」;帶了就照用,腳本與 AI Agent 要真樂觀鎖時走那條。
--
-- 「帶過期的 @--revision@ 時檔案不變」是這一組最重要的一條——樂觀鎖失效的症狀
-- 不是報錯,而是__安靜地覆蓋掉別人寫的東西__。
module StoryFlow.Cli.EntityWriteSpec (spec) where

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
spec = describe "entity set / set-body / rm" $ do
  it "不帶 --revision 的 set 成功且 revision +1" $ withCliVault $ \_ -> do
    _ <- newLinda
    _ <- sfOk ["entity", "set", "琳達", "--summary", "改過的一句話"]
    env <- sfJson ["entity", "show", "琳達"]
    jsonPath ["data", "entity", "summary"] env `shouldBe` Just (String "改過的一句話")
    jsonPath ["data", "entity", "revision"] env `shouldBe` Just (Number 2)

  it "帶正確的 --revision 也成功" $ withCliVault $ \_ -> do
    _ <- newLinda
    r <- sf ["entity", "set", "琳達", "--summary", "s2", "--revision", "1"]
    crExit r `shouldBe` ExitSuccess

  it "帶過期的 --revision → exit 1、code 是 stale_revision、檔案不變" $ withCliVault $ \dir -> do
    _ <- newLinda
    _ <- sfOk ["entity", "set", "琳達", "--summary", "第一次改"]
    let path = dir </> "characters" </> "琳達.md"
    bytes0 <- BS.readFile path
    r <- sf ["entity", "set", "琳達", "--summary", "用過期 revision 改", "--revision", "1"]
    crExit r `shouldBe` ExitFailure 1
    env <- sfJson ["entity", "set", "琳達", "--summary", "用過期 revision 改", "--revision", "1"]
    env `shouldHaveCode` "stale_revision"
    bytes1 <- BS.readFile path
    bytes1 `shouldBe` bytes0

  it "set 改標題" $ withCliVault $ \_ -> do
    _ <- newLinda
    _ <- sfOk ["entity", "set", "琳達", "--title", "琳達（改）"]
    env <- sfJson ["entity", "show", "琳達（改）"]
    jsonPath ["data", "entity", "title"] env `shouldBe` Just (String "琳達（改）")

  it "set 沒給的欄位不動" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手", "--tag", "主角"]
    _ <- sfOk ["entity", "set", "琳達", "--status", "canon"]
    env <- sfJson ["entity", "show", "琳達"]
    jsonPath ["data", "entity", "summary"] env `shouldBe` Just (String "第七織手")
    case jsonPath ["data", "entity", "tags"] env of
      Just (Array ts) -> length ts `shouldBe` 1
      other -> expectationFailure ("tags 取不到:" <> show other)

  it "set-body --body 換掉正文" $ withCliVault $ \_ -> do
    _ <- newLinda
    _ <- sfOk ["entity", "set-body", "琳達", "--body", "換過的正文"]
    out <- sfOk ["entity", "show", "琳達"]
    out `shouldContainT` "換過的正文"

  it "set-body - 從 stdin 讀取" $ withCliVault $ \_ -> do
    _ <- newLinda
    r <- sfIn "從 stdin 來的正文\n第二行" ["entity", "set-body", "琳達", "-"]
    crExit r `shouldBe` ExitSuccess
    out <- sfOk ["entity", "show", "琳達"]
    out `shouldContainT` "從 stdin 來的正文"
    out `shouldContainT` "第二行"

  it "set-body --body-file 從檔案讀取(UTF-8)" $ withCliVault $ \dir -> do
    _ <- newLinda
    BS.writeFile (dir </> "body.md") (TE.encodeUtf8 "檔案裡的正文")
    _ <- sfOk ["entity", "set-body", "琳達", "--body-file", dir </> "body.md"]
    out <- sfOk ["entity", "show", "琳達"]
    out `shouldContainT` "檔案裡的正文"

  it "set-body 三種來源一個都沒給時是用法錯誤(exit 2)" $ withCliVault $ \_ -> do
    _ <- newLinda
    r <- sf ["entity", "set-body", "琳達"]
    crExit r `shouldBe` ExitFailure 2

  it "rm 刪掉檔案" $ withCliVault $ \dir -> do
    _ <- newLinda
    out <- sfOk ["entity", "rm", "琳達"]
    out `shouldContainT` "已刪除"
    exists <- doesFileExist (dir </> "characters" </> "琳達.md")
    exists `shouldBe` False

  it "被指向的 Entity 非 force 刪不掉,force 就刪得掉" $ withCliVault $ \_ -> do
    main <- newLinda
    _ <-
      sfOk
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
    env <- sfJson ["entity", "rm", "琳達"]
    env `shouldHaveCode` "referenced_by"
    r <- sf ["entity", "rm", "琳達", "--force"]
    crExit r `shouldBe` ExitSuccess

  it "人類模式的寫入結果是一行" $ withCliVault $ \_ -> do
    _ <- newLinda
    out <- sfOk ["entity", "set", "琳達", "--summary", "s2"]
    length (T.lines (T.strip out)) `shouldBe` 1

newLinda :: IO String
newLinda =
  idFromJson
    <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
