-- | T5:'openEnv' 的三種失敗各自可辨識。
--
-- 三件事在同一個函式裡失敗(Vault 定位、註冊表載入、開索引),而它們的修法
-- 完全不同。壓成一種錯誤的話,使用者只會得到「打不開」三個字。
module StoryFlow.Service.EnvSpec (spec) where

import Data.List (isInfixOf)
import qualified Data.Text as T
import StoryFlow.Service
import StoryFlow.Service.Fixtures
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "openEnv" $ do
  it "不在任何 Vault 裡 → VaultNotFound" $
    withVaultDir $ \dir -> do
      let outside = dir </> "no-vault-here"
      createDirectoryIfMissing True outside
      r <- openEnv Nothing outside
      fmap (const ()) r `shouldFailWith` "vault_not_found"

  it "註冊表目錄不存在 → RegistryUnavailable,訊息說出去哪裡找過" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      r <-
        withEnvVars [("STORYFLOW_REGISTRY", dir </> "沒有這個目錄")] $
          openEnv Nothing dir
      fmap (const ()) r `shouldFailWith` "registry_unavailable"
      case r of
        Left e -> T.unpack (renderServiceError e) `shouldSatisfy` isInfixOf "沒有這個目錄"
        Right _ -> expectationFailure "預期失敗"

  it "註冊表的 TOML 壞掉 → RegistryLoadFailed" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      let badReg = dir </> "badregistry"
      createDirectoryIfMissing True badReg
      writeFile (badReg </> "broken.toml") "key = \n"
      r <- withEnvVars [("STORYFLOW_REGISTRY", badReg)] (openEnv Nothing dir)
      fmap (const ()) r `shouldFailWith` "registry_load_failed"

  it "成功時帶出外部改動的 IndexIssue" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      -- 直接寫一份壞掉的檔案,模擬作者用編輯器改壞:openEnv 的 refreshStale
      -- 會掃到它,而解析失敗要能被呼叫端看見
      -- 檔名與內容都用 ASCII:writeFile 走的是系統預設編碼,
      -- 這一條測的是索引問題的回報,不是編碼
      writeFile (dir </> "lore" </> "broken.md") "no frontmatter here\n"
      (env, issues) <- orDieS =<< openEnv Nothing dir
      closeEnv env
      issues `shouldSatisfy` any issueHasError

  it "withEnv 用完就關掉連線" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      r <- withEnv Nothing dir (const (pure (1 :: Int)))
      r `shouldBe` Right 1

  it "--vault <名稱> 走全域註冊表" $
    withVaultDir $ \dir -> do
      _ <- orDieS =<< createVault dir "liftgame"
      -- 從一個完全無關的目錄出發,只靠名稱也要找得到
      withSystemTempDirectory "storyflow-elsewhere" $ \elsewhere -> do
        (env, _) <- orDieS =<< openEnv (Just "liftgame") elsewhere
        v <- runS env vaultInfo
        closeEnv env
        vvName v `shouldBe` "liftgame"
