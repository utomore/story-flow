-- | T8:@vault init@ 後 @list@ 與 @info@ 都看得到。
--
-- @vault init@ 與 @vault list@ 是唯二在 'Aapms.Service.Monad.Env' 存在之前
-- 就要能跑的指令(沒有 Vault 的時候當然開不了索引),所以它們走 service 的
-- 非 @ServiceM@ 函式。這一條測的就是那條特殊路徑沒有被漏掉。
module Aapms.Cli.VaultCmdSpec (spec) where

import Data.Aeson (Value (..))
import qualified Data.Text as T
import Aapms.Cli.Fixtures
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "vault / index / type" $ do
  it "init 之後 list 的 data 含它" $ withCliVault $ \_ -> do
    env <- sfJson ["vault", "list"]
    case dataOf env of
      Array vs -> map (jsonPath ["name"]) (foldr (:) [] vs) `shouldContain` [Just (String "liftgame")]
      other -> expectationFailure ("data 不是陣列:" <> show other)

  it "info 的名稱與 init 時給的相符" $ withCliVault $ \_ -> do
    env <- sfJson ["vault", "info"]
    jsonPath ["data", "name"] env `shouldBe` Just (String "liftgame")

  it "info 的 entity 數隨著建檔增加" $ withCliVault $ \_ -> do
    rev0 <- jsonPath ["data", "entity_count"] <$> sfJson ["vault", "info"]
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    rev1 <- jsonPath ["data", "entity_count"] <$> sfJson ["vault", "info"]
    (rev0, rev1) `shouldBe` (Just (Number 0), Just (Number 1))

  it "index rebuild 的 data.files 等於實際的 .md 數" $ withCliVault $ \_ -> do
    _ <- sfOk ["entity", "new", "--type", "character", "--title", "琳達", "--summary", "第七織手"]
    _ <- sfOk ["entity", "new", "--type", "lore", "--title", "埃提亞", "--summary", "崩塌前的地區"]
    env <- sfJson ["index", "rebuild"]
    jsonPath ["data", "files"] env `shouldBe` Just (Number 2)

  it "index refresh 也回同一種報告" $ withCliVault $ \_ -> do
    env <- sfJson ["index", "refresh"]
    jsonPath ["data", "files"] env `shouldBe` Just (Number 0)

  it "type list 印出註冊表裡的型別,而且不是寫死在 CLI 裡的列舉" $ withCliVault $ \_ -> do
    out <- sfOk ["type", "list"]
    mapM_ (shouldContainT out) ["character-fragment", "lore-fragment", "dialogue"]
    env <- sfJson ["type", "list"]
    case dataOf env of
      Array ts -> length ts `shouldSatisfy` (>= 5)
      other -> expectationFailure ("data 不是陣列:" <> show other)

  it "人類模式的 vault info 三行都在" $ withCliVault $ \_ -> do
    out <- sfOk ["vault", "info"]
    length (T.lines (T.strip out)) `shouldBe` 3
    out `shouldContainT` "liftgame"

  it "沒有 --vault 又不在 Vault 裡時,vault info 以 exit 1 收場" $ do
    r <- capture ["--vault", "不存在", "vault", "info"]
    crExit r `shouldBe` ExitFailure 1
