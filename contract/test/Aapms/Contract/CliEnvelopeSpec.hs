-- | 契約 1:CLI 信封與 exit code(system.md「系統對外介面 › 1. CLI」)。
--
-- * @--json@ 輸出統一信封 @{"ok":true,"data":…}@ / @{"ok":false,"error":{"code","message"}}@
-- * exit code @0@ 成功、@1@ 業務或傳輸失敗、@2@ 用法錯誤
-- * @code@ 是 snake_case 穩定識別碼,@message@ 是繁中且非空
module Aapms.Contract.CliEnvelopeSpec (spec) where

import Aapms.Contract.Harness
import Data.Aeson (Value (..))
import Data.Char (isAsciiLower, isDigit)
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "CLI 信封與 exit code" $ do
  it "--version 恰好一行,第一個字是執行檔名 aapms" $ do
    r <- serveless ["--version"]
    runExit r `shouldBe` ExitSuccess
    case T.lines (runOut r) of
      [l] -> T.words l `shouldSatisfy` \case
        [name, _] -> name == "aapms"
        _ -> False
      ls -> expectationFailure ("預期恰好一行,實際:" <> show ls)

  it "成功:exit 0,信封 ok=true 且有 data" $ withVault $ \v -> do
    r <- aapms v ["--json", "vault", "info"]
    runExit r `shouldBe` ExitSuccess
    env <- decodeValue (runOutBytes r) (runErr r)
    jsonPath ["ok"] env `shouldBe` Just (Bool True)
    jsonPath ["data"] env `shouldSatisfy` \case
      Just (Object _) -> True
      _ -> False

  it "業務錯誤:exit 1,信封 ok=false,error.code 是 snake_case,message 非空" $ withVault $ \v -> do
    r <- aapms v ["--json", "entity", "show", "ent-00000000"]
    runExit r `shouldBe` ExitFailure 1
    env <- decodeValue (runOutBytes r) (runErr r)
    jsonPath ["ok"] env `shouldBe` Just (Bool False)
    env `shouldHaveCode` "entity_not_found"
    code <- jsonText ["error", "code"] env
    T.unpack code `shouldSatisfy` all (\c -> isAsciiLower c || isDigit c || c == '_')
    msg <- jsonText ["error", "message"] env
    msg `shouldSatisfy` (not . T.null)

  it "非 --json 模式的業務錯誤:stdout 空、stderr 有訊息、exit 1" $ withVault $ \v -> do
    r <- aapms v ["entity", "show", "ent-00000000"]
    runExit r `shouldBe` ExitFailure 1
    runOut r `shouldBe` ""
    runErr r `shouldSatisfy` (not . T.null)

  it "用法錯誤:exit 2" $ withVault $ \v -> do
    r <- aapms v ["entity", "沒這個動詞"]
    runExit r `shouldBe` ExitFailure 2

  it "用法錯誤在 --json 下仍是 exit 2(腳本要分得出「我打錯」與「做不到」)" $ withVault $ \v -> do
    r <- aapms v ["--json", "entity", "沒這個動詞"]
    runExit r `shouldBe` ExitFailure 2
  where
    -- @--version@ 不需要 Vault;借 withVault 只是為了拿到隔離的環境變數。
    serveless args = withVault $ \v -> aapms v args
