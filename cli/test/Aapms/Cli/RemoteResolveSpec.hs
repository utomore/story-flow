-- | T13:遠端模式的標題定址與先讀再寫。
--
-- 定址與「先讀再寫」的邏輯只有一份("Aapms.Cli.Resolve"),兩種模式的差別
-- 只在底下那幾個查詢是本機呼叫還是 HTTP GET。這一組驗的是那份共用邏輯在遠端
-- 後端上真的跑得動——包含它多打的那幾次 round-trip。
module Aapms.Cli.RemoteResolveSpec (spec) where

import Data.Aeson (Value (Number, String))
import Data.Text (Text)
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "遠端模式的定址" $ do
  it "以標題定址成功" $ withCliServer $ \_ url -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    out <- sfRemoteOk url ["entity", "show", "琳達"]
    out `shouldContainT` "第七織手"

  it "以 id 定址也成功" $ withCliServer $ \_ url -> do
    i <- idFromJson <$> sfJson ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s"]
    out <- sfRemoteOk url ["entity", "show", i]
    out `shouldContainT` "琳達"

  it "兩筆同名 → title_ambiguous,候選與內嵌模式相同" $ withCliServer $ \_ url -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "琳達", "--summary", "同名的地名"]
    remote <- sfRemoteJson url ["entity", "show", "琳達"]
    embedded <- sfJson ["entity", "show", "琳達"]
    remote `shouldHaveCode` "title_ambiguous"
    -- 同一個錯誤在兩種模式下是同一個信封,不只是同一個代碼
    remote `shouldBe` embedded

  it "找不到的標題 → title_not_found,訊息也相同" $ withCliServer $ \_ url -> do
    remote <- sfRemoteJson url ["entity", "show", "沒這個人"]
    embedded <- sfJson ["entity", "show", "沒這個人"]
    remote `shouldHaveCode` "title_not_found"
    remote `shouldBe` embedded

  it "不帶 --revision 的 entity set 在遠端也成功,而且 revision +1" $ withCliServer $ \_ url -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfRemoteOk url ["entity", "set", "琳達", "--summary", "遠端改的"]
    env <- sfJson ["entity", "show", "琳達"]
    jsonPath ["data", "entity", "summary"] env `shouldBe` Just (String "遠端改的")
    jsonPath ["data", "entity", "revision"] env `shouldBe` Just (Number 2)

  it "帶過期的 --revision 在遠端一樣被擋,code 相同" $ withCliServer $ \_ url -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "s"]
    _ <- sfOk ["entity", "set", "琳達", "--summary", "第一次改"]
    remote <- sfRemoteJson url ["entity", "set", "琳達", "--summary", "x", "--revision", "1"]
    remote `shouldHaveCode` "stale_revision"

  it "節點定址在遠端走 HTTP 把每棵樹讀回來" $ withCliServer $ \_ url -> do
    _ <- sfOk ["level", "new", "--title", "教室", "--root-title", "午後的教室", "--root-kind", "scene"]
    _ <- sfRemoteOk url ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    out <- sfOk ["level", "show", "教室"]
    out `shouldContainT` "出場人物"

  it "節點多筆命中時遠端也列候選" $ withCliServer $ \_ url -> do
    _ <- sfOk ["level", "new", "--title", "教室", "--root-title", "出場人物", "--root-kind", "scene"]
    _ <- sfOk ["level", "new", "--title", "走廊", "--root-title", "出場人物", "--root-kind", "scene"]
    remote <- sfRemoteJson url ["node", "add", "出場人物", "--title", "x", "--kind", "cast"]
    remote `shouldHaveCode` "title_ambiguous"

  it "Level 的 revision 由遠端讀回來(node 操作鎖的是 Level 主體)" $ withCliServer $ \_ url -> do
    _ <- sfOk ["level", "new", "--title", "教室", "--root-title", "午後的教室", "--root-kind", "scene"]
    _ <- sfRemoteOk url ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
    -- 第二次不帶 --revision:CLI 自己重讀,所以不會撞到過期
    r <- sfRemote url ["node", "add", "午後的教室", "--title", "鏡頭", "--kind", "camera"]
    crExit r `shouldBe` ExitSuccess

-- | 預期成功;失敗就把 stderr 印出來讓測試看得懂發生什麼事。
sfRemoteOk :: String -> [String] -> IO Text
sfRemoteOk url args = do
  r <- sfRemote url args
  case crExit r of
    ExitSuccess -> pure (crOut r)
    c ->
      fail $
        "遠端指令 " <> unwords args <> " 以 " <> show c <> " 收場:\n" <> T.unpack (crErr r)
