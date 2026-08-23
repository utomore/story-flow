-- | T7:exit code 與索引警告。
--
-- 三種 exit code 是給腳本看的契約:@0@ 成功、@1@ 業務錯誤、@2@ 用法錯誤。
-- 把後兩者壓成同一個數字,腳本就分不出「我指令打錯了」與「工具告訴我這件事
-- 做不到」——前者該修腳本,後者該看訊息。
module Aapms.Cli.RunCliSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Aapms.Cli.Fixtures
import Aapms.Cli.Options (cliVersion)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "runCli 的外框" $ do
  it "成功回 ExitSuccess" $ withCliVault $ \_ -> do
    r <- sf ["vault", "info"]
    crExit r `shouldBe` ExitSuccess

  it "業務錯誤回 ExitFailure 1,訊息到 stderr" $ withCliVault $ \_ -> do
    r <- sf ["entity", "show", "ent-00000000"]
    crExit r `shouldBe` ExitFailure 1
    crOut r `shouldBe` ""
    crErr r `shouldContainT` "錯誤"

  it "引數錯誤回 ExitFailure 2" $ withCliVault $ \_ -> do
    r <- sf ["entity", "沒這個動詞"]
    crExit r `shouldBe` ExitFailure 2

  it "--help 回 ExitSuccess 並印到 stdout" $ do
    r <- capture ["--help"]
    crExit r `shouldBe` ExitSuccess
    crOut r `shouldContainT` "aapms"

  -- G-E002 T5:--version 恰好一行,與 cliVersion 逐字相同,不需要 Vault。
  it "--version 回 ExitSuccess,stdout 恰好一行 cliVersion" $ do
    r <- capture ["--version"]
    crExit r `shouldBe` ExitSuccess
    T.lines (crOut r) `shouldBe` [T.pack cliVersion]
    T.words (T.pack cliVersion) `shouldSatisfy` \case
      [name, _] -> name == "aapms"
      _ -> False

  it "--json 模式下業務錯誤仍是合法信封、仍是 exit 1" $ withCliVault $ \_ -> do
    r <- capture ["--vault", "liftgame", "--json", "entity", "show", "ent-00000000"]
    crExit r `shouldBe` ExitFailure 1
    env <- sfJson ["entity", "show", "ent-00000000"]
    env `shouldHaveCode` "entity_not_found"

  it "Vault 裡有壞掉的 .md 時,任一子指令都在 stderr 提到那個檔案" $ withCliVault $ \dir -> do
    createDirectoryIfMissing True (dir </> "characters")
    BS.writeFile (dir </> "characters" </> "壞掉.md") (TE.encodeUtf8 brokenMd)
    r <- sf ["vault", "info"]
    crExit r `shouldBe` ExitSuccess
    crErr r `shouldContainT` "壞掉.md"

  it "--json 模式下索引警告不混進 stdout" $ withCliVault $ \dir -> do
    createDirectoryIfMissing True (dir </> "characters")
    BS.writeFile (dir </> "characters" </> "壞掉.md") (TE.encodeUtf8 brokenMd)
    r <- capture ["--vault", "liftgame", "--json", "vault", "info"]
    length (T.lines (T.strip (crOut r))) `shouldBe` 1
    crErr r `shouldContainT` "壞掉.md"

  it "找不到 Vault 時是業務錯誤,不是崩潰" $ do
    r <- capture ["--vault", "沒這個 vault", "vault", "info"]
    crExit r `shouldBe` ExitFailure 1

-- | 檔案層 frontmatter 的 id 不是合法格式 —— 解析階段就會擋下來,
-- 檔案因此進不了索引,而作者應該在下一次用 CLI 時就看到這件事。
brokenMd :: T.Text
brokenMd =
  T.unlines
    [ "---"
    , "id: 這不是一個 id"
    , "type: character"
    , "title: 壞掉"
    , "---"
    , ""
    , "# 壞掉"
    ]
