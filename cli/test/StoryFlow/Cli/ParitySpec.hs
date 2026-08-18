-- | T15:內嵌與遠端輸出完全相同。
--
-- 這是 func-0008 的驗收標準 4。作法是__同一個 Vault__ 同時以兩種模式操作:
-- 'withCliServer' 起的伺服器綁在測試剛建好的那個臨時 Vault 上,所以兩邊看到的是
-- 同一份資料、同一批 id。輸出若有差,就真的是渲染路徑的差,不是資料的差。
--
-- 讀取指令逐字元比對;寫入指令不能跑兩次(會改到狀態),所以改驗「遠端寫、內嵌讀
-- 得到」與「同一個失敗在兩邊的信封相同」。
module StoryFlow.Cli.ParitySpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import StoryFlow.Cli.Fixtures
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "內嵌與遠端的輸出" $ do
  describe "人類可讀模式逐字元相等" $
    it "七條讀取指令的 stdout 一模一樣" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameHuman url) readCommands

  describe "--json 模式逐字元相等" $
    it "同樣那七條的信封一模一樣" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameJson url) readCommands

  describe "錯誤路徑" $ do
    it "業務錯誤的 code 與 message 在兩邊相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameJson url) errorCommands

    it "人類模式的錯誤訊息也逐字元相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameHumanErr url) errorCommands

    it "exit code 在兩邊相同" $ withCliServer $ \_ url -> do
      seedVault
      mapM_ (sameExit url) (readCommands <> errorCommands)

  describe "寫入" $ do
    it "遠端寫進去的,內嵌讀得到" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfRemote url ["entity", "set", "琳達", "--summary", "遠端改的"]
      out <- sfOk ["entity", "show", "琳達"]
      out `shouldContainT` "遠端改的"

    it "內嵌寫進去的,遠端讀得到" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfOk ["entity", "set", "琳達", "--summary", "內嵌改的"]
      r <- sfRemote url ["entity", "show", "琳達"]
      crOut r `shouldContainT` "內嵌改的"

    it "寫入後兩邊的讀取輸出仍然逐字元相等" $ withCliServer $ \_ url -> do
      seedVault
      _ <- sfRemote url ["entity", "set", "琳達", "--summary", "改過一次"]
      mapM_ (sameHuman url) readCommands

-- | 兩種模式都要看得到的內容:主體 + 片段 + 關聯 + 一個 Level。
seedVault :: IO ()
seedVault = do
  linda <-
    idFromJson
      <$> sfJson
        ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "埃提亞的第七織手", "--status", "canon"]
  _ <-
    sfOk
      [ "entity"
      , "add"
      , "琳達"
      , "--title"
      , "外貌"
      , "--type"
      , "character-fragment"
      , "--summary"
      , "銀灰短髮,左眼下方有織紋刺青"
      , "--link"
      , "partOf:" <> linda
      ]
  _ <-
    sfOk
      ["level", "new", "--title", "教室", "--summary", "崩塌後的午後教室", "--root-title", "午後的教室", "--root-kind", "scene"]
  _ <- sfOk ["node", "add", "午後的教室", "--title", "出場人物", "--kind", "cast"]
  pure ()

-- | 讀取指令:跑幾次都不改狀態,所以可以兩種模式各跑一次再逐字元比對。
readCommands :: [[String]]
readCommands =
  [ ["vault", "info"]
  , ["type", "list"]
  , ["entity", "list"]
  , ["entity", "show", "琳達"]
  , ["link", "list", "外貌"]
  , ["level", "show", "教室"]
  , ["search", "織紋刺青"]
  ]

-- | 失敗案例:兩邊的 code 與 message 都要一致。
errorCommands :: [[String]]
errorCommands =
  [ ["entity", "show", "ent-00000000"]
  , ["entity", "show", "沒這個人"]
  , ["entity", "new", "--type", "沒這種型別", "--title", "x", "--summary", "s"]
  , ["level", "show", "沒這個場景"]
  , ["entity", "set", "琳達", "--summary", "x", "--revision", "999"]
  ]

sameHuman :: String -> [String] -> Expectation
sameHuman url args = do
  emb <- sf args
  rem' <- sfRemote url args
  labelled args (crOut emb) (crOut rem')

sameHumanErr :: String -> [String] -> Expectation
sameHumanErr url args = do
  emb <- sf args
  rem' <- sfRemote url args
  labelled args (crErr emb) (crErr rem')

sameJson :: String -> [String] -> Expectation
sameJson url args = do
  emb <- capture ("--vault" : "liftgame" : "--json" : args)
  rem' <- capture ("--remote" : url : "--json" : args)
  labelled args (crOut emb) (crOut rem')

sameExit :: String -> [String] -> Expectation
sameExit url args = do
  emb <- sf args
  rem' <- sfRemote url args
  (unwords args, crExit emb) `shouldBe` (unwords args, crExit rem' :: ExitCode)

-- | 比對失敗時要看得出是哪一條指令,不然一堆中文字裡找不到差在哪。
labelled :: [String] -> Text -> Text -> Expectation
labelled args a b
  | a == b = pure ()
  | otherwise =
      expectationFailure . T.unpack $
        "指令「"
          <> T.pack (unwords args)
          <> "」兩種模式的輸出不同。\n內嵌:\n"
          <> a
          <> "\n遠端:\n"
          <> b
