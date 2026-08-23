-- | G-E002 T8–T10:@story-flow doctor@。
--
-- 五項讀不連的診斷。這裡驗的是:(a) 指令解析與 @--remote@ 互斥;(b) 四種環境下
-- 五項各自的 @ok@ 與退出碼;(c) 兩種輸出的形狀。
--
-- 「註冊表找不到」那一組要把三層都關掉:清掉 @STORYFLOW_REGISTRY@、把
-- @storyflow_types_datadir@(@Paths_@ 模組自己的覆寫鉤子)指到不存在的地方;
-- 執行檔旁那層在測試執行檔旁邊本來就沒有 @registry\/@。
module StoryFlow.Cli.DoctorSpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), decodeStrict)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Options.Applicative (ParserResult (..))
import StoryFlow.Cli.Fixtures
import StoryFlow.Cli.Options (Command (..), parseCli)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "doctor" $ do
  -- T8
  describe "解析(T8)" $ do
    it "doctor 解析成 Doctor" $
      case parseCli ["doctor"] of
        Success (_, Doctor) -> pure ()
        other -> expectationFailure ("應為 Doctor,實得 " <> showResult other)

    it "與 --remote 併用 → usage error,exit 2" $ withCliVault $ \_ -> do
      r <- capture ["--remote", "http://127.0.0.1:1", "doctor"]
      crExit r `shouldBe` ExitFailure 2
      crErr r `shouldContainT` "--remote"

  -- T9
  describe "五項診斷與退出碼(T9)" $ do
    it "(a) 註冊表三層都找不到 → exit 1,registry.ok = false,其餘照常報" $ withCliVault $ \dir -> do
      r <-
        withoutEnv "STORYFLOW_REGISTRY" $
          withEnvVars [("storyflow_types_datadir", dir </> "no-datadir")] $
            capture ["--vault", "liftgame", "--json", "doctor"]
      crExit r `shouldBe` ExitFailure 1
      d <- dataOf <$> decodeOut r
      boolAt ["registry", "ok"] d `shouldBe` Just False
      -- 其餘四項不受註冊表影響,照樣報得出來
      boolAt ["vault", "ok"] d `shouldBe` Just True
      boolAt ["vault_registry", "ok"] d `shouldBe` Just True

    it "(b) 註冊表在、沒有 Vault → exit 0,vault.ok = false,llm 標 unchecked" $ withCliVault $ \_ -> do
      -- 不帶 --vault,而測試行程的 cwd 往上沒有 .storyflow/
      r <- capture ["--json", "doctor"]
      crExit r `shouldBe` ExitSuccess
      d <- dataOf <$> decodeOut r
      boolAt ["registry", "ok"] d `shouldBe` Just True
      boolAt ["vault", "ok"] d `shouldBe` Just False
      textAt ["llm", "state"] d `shouldBe` Just "unchecked"

    it "(c) 完整 Vault、沒有 [llm] → exit 0,vault.ok = true,llm 標 absent" $ withCliVault $ \_ -> do
      r <- capture ["--vault", "liftgame", "--json", "doctor"]
      crExit r `shouldBe` ExitSuccess
      d <- dataOf <$> decodeOut r
      boolAt ["vault", "ok"] d `shouldBe` Just True
      textAt ["vault", "name"] d `shouldBe` Just "liftgame"
      textAt ["llm", "state"] d `shouldBe` Just "absent"
      boolAt ["llm", "ok"] d `shouldBe` Just False

    it "(c') [llm] 段在且解得開 → llm 標 configured,帶 model" $ withCliVault $ \dir -> do
      TIO.appendFile
        (dir </> ".storyflow" </> "config.toml")
        "\n[llm]\nbase_url = \"http://127.0.0.1:8080/v1\"\nmodel = \"local-model\"\n"
      r <- capture ["--vault", "liftgame", "--json", "doctor"]
      d <- dataOf <$> decodeOut r
      textAt ["llm", "state"] d `shouldBe` Just "configured"
      textAt ["llm", "model"] d `shouldBe` Just "local-model"
      boolAt ["llm", "ok"] d `shouldBe` Just True

    it "(d) vaults.toml 被中文 key 寫壞 → vault_registry.ok = false,訊息含檔案路徑" $ withCliVault $ \dir -> do
      -- 2026-08-22 實測到的壞檔形狀:裸 key 是中文,TOML 不接受
      let regFile = dir </> "vaults.toml"
      TIO.writeFile regFile "測試世界 = \".\"\n"
      r <- capture ["--json", "doctor"]
      d <- dataOf <$> decodeOut r
      boolAt ["vault_registry", "ok"] d `shouldBe` Just False
      msg <- maybe (fail "vault_registry.message 缺") pure (textAt ["vault_registry", "message"] d)
      msg `shouldContainT` "vaults.toml"

  -- T10
  describe "輸出形狀(T10)" $ do
    it "--json 的 data 恰好五個鍵,全 snake_case" $ withCliVault $ \_ -> do
      r <- capture ["--vault", "liftgame", "--json", "doctor"]
      d <- dataOf <$> decodeOut r
      case d of
        Object o -> sort (map K.toText (KM.keys o)) `shouldBe` ["llm", "registry", "vault", "vault_registry", "version"]
        _ -> expectationFailure "data 不是物件"

    it "給人看的是五行,每行以 [ok] / [!!] / [--] 開頭" $ withCliVault $ \_ -> do
      r <- capture ["--vault", "liftgame", "doctor"]
      let ls = T.lines (crOut r)
      length ls `shouldBe` 5
      mapM_ (\l -> T.take 4 l `shouldSatisfy` (`elem` ["[ok]", "[!!]", "[--]"])) ls

-- 小工具 -----------------------------------------------------------------------

decodeOut :: CliResult -> IO Value
decodeOut r = case decodeStrict (TE.encodeUtf8 (crOut r)) of
  Just v -> pure v
  Nothing -> fail ("stdout 不是合法 JSON:" <> T.unpack (crOut r) <> T.unpack (crErr r))

boolAt :: [T.Text] -> Value -> Maybe Bool
boolAt path v = case jsonPath path v of
  Just (Bool b) -> Just b
  _ -> Nothing

textAt :: [T.Text] -> Value -> Maybe T.Text
textAt path v = case jsonPath path v of
  Just (String t) -> Just t
  _ -> Nothing

showResult :: ParserResult a -> String
showResult = \case
  Success _ -> "Success(非 Doctor)"
  Failure _ -> "Failure"
  CompletionInvoked _ -> "CompletionInvoked"

-- | 清掉一個環境變數跑一段,結束後還原。Fixtures 的 'withEnvVars' 只會設,不會清。
withoutEnv :: String -> IO a -> IO a
withoutEnv name act = bracket save restore (const act)
  where
    save = lookupEnv name <* unsetEnv name
    restore = maybe (pure ()) (setEnv name)
