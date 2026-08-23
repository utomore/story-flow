-- | T6:'StoryFlow.Mcp.Config' 的旗標優先序、token 只走環境變數。
module StoryFlow.Mcp.ConfigSpec (spec) where

import Control.Exception (bracket)
import qualified Data.Text as T
import StoryFlow.Mcp.Config (Config (..), mcpVersion, resolveConfig, wantsVersion)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec

spec :: Spec
spec = do
  -- G-E002 T7:--version 在 resolveConfig 之前攔截,不需要 URL、不進 JSON-RPC 迴圈。
  describe "--version" $ do
    it "wantsVersion 只認 --version 這個字" $ do
      wantsVersion ["--version"] `shouldBe` True
      wantsVersion ["--url", "http://x", "--version"] `shouldBe` True
      wantsVersion ["--url", "http://x"] `shouldBe` False
      wantsVersion [] `shouldBe` False
    it "mcpVersion 是「story-flow-mcp <版本>」,版本只含數字與點" $ do
      case T.words mcpVersion of
        [name, v] -> do
          name `shouldBe` "story-flow-mcp"
          T.all (`elem` ("0123456789." :: String)) v `shouldBe` True
        ws -> expectationFailure ("應恰好兩個字,實得 " <> show ws)

  describe "都沒設定" $
    it "回 Left,訊息說出下一步" $
      withEnv [("STORYFLOW_URL", Nothing), ("STORYFLOW_TOKEN", Nothing)] $ do
        r <- resolveConfig []
        case r of
          Left msg -> msg `shouldSatisfy` (\m -> "--url" `T.isInfixOf` m && "STORYFLOW_URL" `T.isInfixOf` m)
          Right _ -> expectationFailure "expected Left"

  describe "只設 STORYFLOW_URL" $
    it "回 Right,用那個網址" $
      withEnv [("STORYFLOW_URL", Just "http://127.0.0.1:9999"), ("STORYFLOW_TOKEN", Nothing)] $ do
        r <- resolveConfig []
        r `shouldBe` Right (Config "http://127.0.0.1:9999" Nothing)

  describe "--url 蓋過 STORYFLOW_URL" $
    it "旗標優先" $
      withEnv [("STORYFLOW_URL", Just "http://env-wins-if-bug:1"), ("STORYFLOW_TOKEN", Nothing)] $ do
        r <- resolveConfig ["--url", "http://127.0.0.1:8787"]
        r `shouldBe` Right (Config "http://127.0.0.1:8787" Nothing)

  describe "結尾斜線" $
    it "被去掉,base URL 不含結尾斜線" $
      withEnv [("STORYFLOW_URL", Nothing), ("STORYFLOW_TOKEN", Nothing)] $ do
        r <- resolveConfig ["--url", "http://127.0.0.1:8787/"]
        r `shouldBe` Right (Config "http://127.0.0.1:8787" Nothing)

  describe "STORYFLOW_TOKEN" $ do
    it "有值就帶進 cfgToken" $
      withEnv [("STORYFLOW_URL", Nothing), ("STORYFLOW_TOKEN", Just "secret")] $ do
        r <- resolveConfig ["--url", "http://127.0.0.1:8787"]
        r `shouldBe` Right (Config "http://127.0.0.1:8787" (Just "secret"))

    it "空字串視同沒設(同 cli 的 managerWith)" $
      withEnv [("STORYFLOW_URL", Nothing), ("STORYFLOW_TOKEN", Just "")] $ do
        r <- resolveConfig ["--url", "http://127.0.0.1:8787"]
        r `shouldBe` Right (Config "http://127.0.0.1:8787" Nothing)

    it "没有對應的 --token 旗標:不管給什麼旗標,token 只看環境變數" $
      withEnv [("STORYFLOW_URL", Nothing), ("STORYFLOW_TOKEN", Just "from-env")] $ do
        r <- resolveConfig ["--url", "http://127.0.0.1:8787", "--token", "ignored"]
        r `shouldBe` Right (Config "http://127.0.0.1:8787" (Just "from-env"))

withEnv :: [(String, Maybe String)] -> IO a -> IO a
withEnv vars act = bracket save restore (const act)
  where
    save = mapM apply vars
    apply (k, v) = do
      old <- lookupEnv k
      maybe (unsetEnv k) (setEnv k) v
      pure (k, old)
    restore = mapM_ (\(k, mv) -> maybe (unsetEnv k) (setEnv k) mv)
