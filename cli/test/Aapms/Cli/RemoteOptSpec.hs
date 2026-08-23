-- | T12:@--remote@ 解析與併用檢查。
module Aapms.Cli.RemoteOptSpec (spec) where

import Data.Aeson (Value, decodeStrict)
import qualified Data.Text.Encoding as TE
import Options.Applicative (getParseResult)
import Aapms.Cli.Fixtures
import Aapms.Cli.Options
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "--remote" $ do
  describe "解析" $ do
    it "進 goRemote" $ do
      let g = fst (parseOk ["--remote", "http://127.0.0.1:8787", "entity", "list"])
      goRemote g `shouldBe` Just "http://127.0.0.1:8787"

    it "不給時是 Nothing" $
      goRemote (fst (parseOk ["entity", "list"])) `shouldBe` Nothing

    it "可以與 --json 併用" $ do
      let g = fst (parseOk ["--remote", "http://x", "--json", "entity", "list"])
      (goRemote g, goJson g) `shouldBe` (Just "http://x", True)

  describe "與 --vault 併用" $ do
    it "解析層放行(那是語意問題,不是語法問題)" $ do
      let g = fst (parseOk ["--remote", "http://x", "--vault", "liftgame", "entity", "list"])
      (goRemote g, goVault g) `shouldBe` (Just "http://x", Just "liftgame")

    it "執行時是用法錯誤,exit 2,而且說得出為什麼" $ do
      r <- capture ["--remote", "http://127.0.0.1:1", "--vault", "liftgame", "entity", "list"]
      crExit r `shouldBe` ExitFailure 2
      crErr r `shouldContainT` "不能併用"
      crErr r `shouldContainT` "usage_error"

    it "--json 模式下同樣是 exit 2,而且是合法信封" $ do
      env <- sfRemoteJsonWithVault
      env `shouldHaveCode` "usage_error"

  describe "連不上" $ do
    it "code 是 remote_unavailable,exit 1" $ do
      -- 1 號埠不會有人聽
      r <- sfRemote "http://127.0.0.1:1" ["entity", "list"]
      crExit r `shouldBe` ExitFailure 1
      crErr r `shouldContainT` "remote_unavailable"

    it "訊息說得出下一步" $ do
      r <- sfRemote "http://127.0.0.1:1" ["entity", "list"]
      crErr r `shouldContainT` "aapms-serve"

    it "--json 模式下是合法信封" $ do
      env <- sfRemoteJson "http://127.0.0.1:1" ["entity", "list"]
      env `shouldHaveCode` "remote_unavailable"

  describe "網址不合法" $
    it "解不出來時是用法錯誤,不是連線錯誤" $ do
      r <- sfRemote "這不是一個網址" ["entity", "list"]
      crExit r `shouldBe` ExitFailure 2
      crErr r `shouldContainT` "usage_error"

  describe "token" $
    -- 伺服器的 401 body 若不是合法 UTF-8 JSON,這裡會退化成
    -- remote_bad_response(「對面不是 aapms 伺服器」),那個訊息會把人帶偏。
    it "token 錯時說的是認證失敗,不是「對面不是 aapms 伺服器」" $
      withCliServerToken "s3cr3t" $ \_ url ->
        withEnvVars [("STORYFLOW_TOKEN", "wr0ng!")] $ do
          env <- sfRemoteJson url ["entity", "list"]
          env `shouldHaveCode` "unauthorized"

parseOk :: [String] -> (GlobalOpts, Command)
parseOk args = case getParseResult (parseCli args) of
  Just x -> x
  Nothing -> error ("預期解析成功:" <> unwords args)

-- | 併用時 stdout 仍然是一個合法信封(exit code 才是 2)。
sfRemoteJsonWithVault :: IO Value
sfRemoteJsonWithVault = do
  r <- capture ["--remote", "http://127.0.0.1:1", "--vault", "liftgame", "--json", "entity", "list"]
  case decodeStrict (TE.encodeUtf8 (crOut r)) of
    Just v -> pure v
    Nothing -> fail ("stdout 不是合法 JSON:" <> show (crOut r))
